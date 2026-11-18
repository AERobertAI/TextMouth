/*
 * session.c: one audio file read with FFmpeg, as the records of TextMouthFFmpegProtocol.h
 * (FMT50). TextMouthFFmpegSession.h says what each function does; this file says how.
 *
 * The stream is made one record at a time, on demand (tmff_session_next): HEAD, INFO, the
 * file's tags, the chosen stream's tags, the chapters, then, in a decode, the samples in PCM
 * records of about PCM_RECORD_TARGET bytes, and END. A decode reads the first frame before INFO,
 * so that INFO describes the samples that follow.
 *
 * Every frame is written in one sample format, chosen from the first frame: 32-bit floating
 * point for a decoder that gives floating point, 16-bit whole numbers for one that gives 8 or 16
 * bits, and 32-bit whole numbers of the decoder's own depth for one that gives more. A frame
 * whose rate, channels, or format differ from the first frame's (joined recordings, such as
 * chained streams, and MP3 that changes its rate partway, do that) is converted to the first
 * frame's form with libswresample, so the stream keeps one form from start to end and END counts
 * the frames of that form. Only sound that cannot be converted ends the stream
 * (TMFF_EXIT_FORM_CHANGED).
 *
 * It stops when it is told to (must_stop): by tmff_session_stop from any thread, or by the check
 * it was given (tmff_session_set_stop_check), which the iPhone's engine turns to stop once a
 * call's time is spent or its import is cancelled (FMT54). The session asks it before every read
 * and seek of the file, through its own I/O callbacks, since FFmpeg asks its interrupt callback
 * only at checkpoints of its own and never on a read through custom I/O; once the open has found
 * the streams (FFmpeg can finish a step it was told to stop); before each packet; and before each
 * record. FFmpeg's interrupt callback asks it too, at those checkpoints.
 *
 * It uses only FFmpeg's documented public API (the headers' documentation, published at
 * https://ffmpeg.org/doxygen/); nothing of FFmpeg's own code is copied here. It grew from the
 * research harness (research/ffmpeg-minimal/harness.c), TextMouth's own.
 *
 * This file is TextMouth's own, under TextMouth's MIT License.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/cpu.h>
#include <libavutil/dict.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "../include/TextMouthFFmpegProtocol.h"
#include "../include/TextMouthFFmpegSession.h"
/* The FFmpeg build's own header (Scripts/vendor/ffmpeg/build.py): a new build changes it, so
   this file is compiled again and everything that links it is linked again. */
#include "textmouth_ffmpeg_build.h"

/* zlib, which Matroska's compressed tracks need, is the system's on the Mac and the iPhone: the
   object asks the linker for it, so whatever links the library needs no flag of its own. */
__asm__(".linker_option \"-lz\"");

/* The bytes of each read the I/O callbacks are asked for. */
enum { READ_BUFFER_BYTES = 64 * 1024 };

/* The most samples, over all its channels, one decoded frame may hold (AVCodecContext's
   max_samples): 16,777,216, 64 MiB of 32-bit samples and 128 MiB of 64-bit ones, under
   av_max_alloc's 256 MB and the iPhone's memory floor. A good file's frames are within it: one
   chunk of PCM in AVI, ASF, or Matroska of almost three minutes of 48 kHz stereo, or 44 seconds of
   eight channels; Monkey's Audio's largest frame, about 2.4 million in stereo; FLAC's largest
   block, about 0.5 million in eight channels. Past it, a crafted packet of PCM or an ALAC frame
   length could make one decoder call allocate hundreds of megabytes, which nothing could stop
   until the call returned. The session's own buffer callback (frame_buffer) keeps it, so that a
   frame past it is told for what it is (TMFF_EXIT_FRAME_TOO_LARGE), not as a damaged packet. */
#define MAX_DECODED_SAMPLES (16 * 1024 * 1024)

/* About how many bytes of samples one PCM record holds: a quarter of a megabyte, a second and a
   half of 44.1 kHz stereo in 32 bits, small for the pipe and few records a book. */
enum { PCM_RECORD_TARGET = 256 * 1024 };

/* The most memory FFmpeg may ask for at once: far more than any audio frame or index needs. */
#define MAX_ALLOCATION_BYTES TMFF_MAX_ALLOCATION_BYTES

/* The cap every open gives FFmpeg (tmff_set_allocation_cap), MAX_ALLOCATION_BYTES unless lowered. */
static size_t allocation_cap = MAX_ALLOCATION_BYTES;

/* The loudspeakers a WAVE channel mask names (its bits 0 to 17), which FFmpeg's native order
   names with the same bits; a layout with any other bit is sent as unknown. */
#define WAVE_CHANNEL_BITS 0x3FFFFull

/* The most errors in a row the decoder may give without a frame between: past them the file is
   damaged, rather than a decoder that answers every call with an error being asked for ever. It
   counts the errors of avcodec_receive_frame with no request for a packet between them, which a
   damaged packet never makes (the decoder refuses it when it is sent, and is then asked for the
   next): any number of damaged packets are counted in END and their place kept as silence (FU03),
   as the tests of FFmpegHelperHostileFileTests show with 900 and with 1,200 of them. */
enum { MAX_ERRORS_IN_A_ROW = 1000 };

/* The most times the sound may change its form: past them the file is refused
   (TMFF_EXIT_FORM_CHANGED), so a file that changes its rate at every frame costs a refusal
   rather than a resampler set up again for ever. A real joined recording has a few. */
enum { MAX_FORM_CHANGES = 1000 };

/* The most one rate may be over the other when the sound changes it: past 16 to 1, either way,
   the sound is refused (TMFF_EXIT_FORM_CHANGED). Real joined recordings differ by 2 to 1 or 4 to 1;
   a wider ratio would turn one short packet into a very long stretch of samples. */
enum { MAX_RATE_RATIO = 16 };

/* The most bytes one converted frame may hold: a frame that would convert to more is fed to the
   resampler in slices, each of which gives at most this. */
enum { MAX_CONVERTED_BYTES = 16 * 1024 * 1024 };

/* Sound the decoder refuses is kept as silence, so the book keeps its length and its chapter marks
   (FU03). The silence is bounded: the most a file may be given is the duration the file states
   (the stream's or the container's, whichever is longer; a file that states none, this many
   seconds), what the file's size can hold at 1 kbit/s (as the app believes a stated length), and
   never more than the ceiling, however long it claims to be. A refused stretch that would pass the
   bound is given no silence, and the gap closes up as it did before FU03, with the decode going
   on: a hostile file's timestamps, or a duration it made up, cannot make hours of silence, and
   cannot refuse a book that the sound around the damage makes. */
enum { MAX_UNSTATED_SILENCE_SECONDS = 3600, MAX_SILENCE_SECONDS = 12 * 3600 };

/* Microseconds in a second: the unit the timeline is kept in (FFmpeg's own AV_TIME_BASE). */
#define MICROSECONDS 1000000

/* Where the stream has got to: each stage gives its records in turn. */
typedef enum {
    STAGE_HEAD,
    STAGE_INFO,
    STAGE_TAGS,
    STAGE_STREAM_TAGS,
    STAGE_CHAPTERS,
    STAGE_PCM,
    STAGE_END,
    STAGE_OVER,
} stage;

/* The sample format of the PCM records. */
typedef enum { OUT_S16, OUT_S32, OUT_F32 } out_format;

struct tmff_session {
    tmff_session_mode mode;
    int descriptor;
    int64_t size;
    /* Set by tmff_session_stop from any thread, or by must_stop once the check has said stop;
       read by FFmpeg's interrupt callback and before each step. */
    atomic_int stopped;
    /* The check the session asks besides the flag, and its context (tmff_session_set_stop_check;
       NULL: none, as on the Mac). Changed only on the thread that calls tmff_session_next, between
       its calls, and asked only on that thread, where FFmpeg's interrupt callback runs too (one
       decoding thread, open_decoder). */
    tmff_stop_check stop_check;
    void *stop_context;

    AVIOContext *io;
    AVFormatContext *format;
    AVCodecContext *decoder;
    AVPacket *packet;
    AVFrame *frame;
    int stream_index;

    stage stage;
    const AVDictionaryEntry *tag;   /* the last tag given, of the dictionary being walked */
    unsigned int tags_given;
    unsigned int chapter;

    /* The samples' form, from the first frame (a decode) or the decoder (a probe). */
    int sample_rate;
    int channels;
    uint64_t channel_mask;
    out_format out;
    int bits;
    int frame_format;               /* the decoder's AVSampleFormat the first frame had */
    AVChannelLayout first_layout;   /* the first frame's channel layout, as it came */
    AVChannelLayout layout;         /* the same as a resampler can use it (make_layout) */
    AVFrame *source;                /* the frame being written: `frame` itself, or `converted` */
    int have_frame;                 /* `source` holds a frame, from `frame_position` on */
    int frame_position;             /* the first of its frames not yet written */

    /* The conversion of a frame whose form is not the first's (FORM_CHANGED's old refusal). */
    AVFrame *converted;             /* the frames the resampler gave, in the first frame's form */
    SwrContext *swr;                /* converts the form below to the first one; NULL when none is open */
    int swr_rate;                   /* the form the resampler takes in: its rate, */
    int swr_format;                 /*   sample format, */
    AVChannelLayout swr_layout;     /*   and channel layout */
    int frame_waits;                /* a decoded frame waits in `frame`, not yet taken into the records */
    int input_position;             /* the first of its frames the resampler has not yet been given */
    unsigned int form_changes;      /* how many resamplers have been opened: the changes of form away
                                       from the first one (a return to the first form is not counted) */
#ifdef DEBUG
    int (*made_up)(tmff_session *session);  /* the Debug checks' decoder: frames made up in memory */
#endif

    /* The decoder's progress. */
    int demuxer_ended;
    int decoder_ended;
    uint64_t frames_written;
    uint32_t packet_errors;
    uint32_t frame_errors;
    /* Set by frame_buffer when the decoder asked for a frame past MAX_DECODED_SAMPLES. */
    int frame_too_large;

    /* The timeline of the sound the decoder refuses (FU03), in microseconds. A packet the decoder
       refuses sets `refused_since_frame` and adds its length to `refused_us`; the next frame that
       comes out, or the end of the sound, turns that into silence owed (`silence_owed_us`, then
       whole frames at the first form's rate, `silence_owed_frames`, which make_pcm writes before
       the frame that follows). */
    int refused_since_frame;
    int64_t refused_us;
    int64_t last_packet_us;          /* the length of the last packet the decoder took */
    int64_t prev_end_us;             /* where the last frame that came out ended, when `have_end` */
    int have_end;
    int64_t silence_owed_us;
    uint64_t silence_owed_frames;
    int64_t silence_total_us;        /* all the silence owed so far, held to its bound */
    int64_t silence_limit_us;        /* the bound, 0: the file's own (set by the Debug checks) */

    /* The record being given, header and payload. */
    unsigned char *record;
    size_t record_length;
    size_t record_capacity;
};

/* ---------------------------------------------------------------------------------------------
 * The file, through FFmpeg's I/O callbacks
 * ------------------------------------------------------------------------------------------- */

static int must_stop(tmff_session *session);

/* FFmpeg's read callback: up to `capacity` bytes of the file; the bytes read, AVERROR_EOF at
   its end, AVERROR(EIO), or AVERROR_EXIT once the session must stop, asked before every read:
   FFmpeg's interrupt callback is never asked on a read through custom I/O (review finding 2), so
   without this a header read for long, or one packet read across a stream it discards, could be
   ended only by abandoning its call. open_failure and next_frame answer AVERROR_EXIT as a stop. */
static int read_file(void *opaque, uint8_t *buffer, int capacity) {
    tmff_session *session = opaque;
    if (must_stop(session)) {
        return AVERROR_EXIT;
    }
    if (capacity <= 0) {
        return AVERROR(EINVAL);
    }
    for (;;) {
        const ssize_t count = read(session->descriptor, buffer, (size_t)capacity);
        if (count > 0) {
            return (int)count;
        }
        if (count == 0) {
            return AVERROR_EOF;
        }
        if (errno != EINTR) {
            return AVERROR(EIO);
        }
    }
}

/* FFmpeg's seek callback: moves to `offset` as `whence` says (SEEK_SET, SEEK_CUR, or SEEK_END,
   maybe with AVSEEK_FORCE), or answers the size for AVSEEK_SIZE; the new position, or a negative
   AVERROR: AVERROR_EXIT once the session must stop, asked before every seek, as before every
   read. */
static int64_t seek_file(void *opaque, int64_t offset, int whence) {
    tmff_session *session = opaque;
    if (must_stop(session)) {
        return AVERROR_EXIT;
    }
    if (whence & AVSEEK_SIZE) {
        return session->size >= 0 ? session->size : AVERROR(ENOSYS);
    }
    whence &= ~AVSEEK_FORCE;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) {
        return AVERROR(EINVAL);
    }
    const off_t position = lseek(session->descriptor, (off_t)offset, whence);
    return position < 0 ? AVERROR(EIO) : (int64_t)position;
}

/* Whether the session must stop now: tmff_session_stop has been called, or the check it was given
   says so, which stops it for good (the flag is set), so that every later look agrees. The one
   question the I/O callbacks, FFmpeg's interrupt callback, and every step of the session ask. */
static int must_stop(tmff_session *session) {
    if (atomic_load(&session->stopped)) {
        return 1;
    }
    if (session->stop_check && session->stop_check(session->stop_context)) {
        atomic_store(&session->stopped, 1);
        return 1;
    }
    return 0;
}

/* FFmpeg's interrupt callback, asked at FFmpeg's own checkpoints (finding a file's streams,
   among others), never on a read through custom I/O: nonzero once the session must stop. */
static int interrupted(void *opaque) {
    return must_stop(opaque);
}

/* ---------------------------------------------------------------------------------------------
 * Records
 * ------------------------------------------------------------------------------------------- */

/* Makes room for `more` bytes past the record's current length; 0, or -1 when the memory is
   refused. */
static int reserve(tmff_session *session, size_t more) {
    const size_t needed = session->record_length + more;
    if (needed <= session->record_capacity) {
        return 0;
    }
    size_t capacity = session->record_capacity ? session->record_capacity : 4096;
    while (capacity < needed) {
        capacity *= 2;
    }
    unsigned char *grown = realloc(session->record, capacity);
    if (!grown) {
        return -1;
    }
    session->record = grown;
    session->record_capacity = capacity;
    return 0;
}

/* Appends `count` bytes to the record; 0, or -1 when the memory is refused. */
static int append(tmff_session *session, const void *bytes, size_t count) {
    if (reserve(session, count) != 0) {
        return -1;
    }
    memcpy(session->record + session->record_length, bytes, count);
    session->record_length += count;
    return 0;
}

/* Appends `value` as 4 little-endian bytes. */
static int append_u32(tmff_session *session, uint32_t value) {
    const unsigned char bytes[4] = {
        (unsigned char)value, (unsigned char)(value >> 8), (unsigned char)(value >> 16), (unsigned char)(value >> 24),
    };
    return append(session, bytes, sizeof bytes);
}

/* Appends `value` as 8 little-endian bytes. */
static int append_u64(tmff_session *session, uint64_t value) {
    if (append_u32(session, (uint32_t)value) != 0) {
        return -1;
    }
    return append_u32(session, (uint32_t)(value >> 32));
}

/* Appends the bits of `value` as 8 little-endian bytes. */
static int append_double(tmff_session *session, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return append_u64(session, bits);
}

/* Starts a record of `kind`: its header, with the length filled in by finish_record. */
static int start_record(tmff_session *session, uint32_t kind) {
    session->record_length = 0;
    if (append_u32(session, kind) != 0) {
        return -1;
    }
    return append_u32(session, 0);
}

/* Writes the payload's length into the record's header; 0, or -1 when it is past `limit`. */
static int finish_record(tmff_session *session, size_t limit) {
    const size_t payload = session->record_length - TMFF_RECORD_HEADER_BYTES;
    if (payload > limit) {
        return -1;
    }
    for (int index = 0; index < 4; index++) {
        session->record[4 + index] = (unsigned char)(payload >> (8 * index));
    }
    return 0;
}

/* The length of `text` cut to at most `limit` bytes, at a UTF-8 character's boundary (never
   inside one), so the cut text is still UTF-8 when the whole was. */
static size_t cut_length(const char *text, size_t limit) {
    size_t length = strlen(text);
    if (length <= limit) {
        return length;
    }
    length = limit;
    /* Back over continuation bytes (10xxxxxx) to the first byte of the character cut. */
    while (length > 0 && ((unsigned char)text[length] & 0xC0) == 0x80) {
        length--;
    }
    return length;
}

/* Appends `text` cut to `limit` bytes (cut_length). */
static int append_cut(tmff_session *session, const char *text, size_t limit) {
    const char *shown = text ? text : "";
    return append(session, shown, cut_length(shown, limit));
}

/* Appends one INFO line, "key=value\n", the value printed with `format`. */
static int append_line(tmff_session *session, const char *key, const char *format, ...) __attribute__((format(printf, 3, 4)));
static int append_line(tmff_session *session, const char *key, const char *format, ...) {
    char value[128];
    va_list arguments;
    va_start(arguments, format);
    const int written = vsnprintf(value, sizeof value, format, arguments);
    va_end(arguments);
    if (written < 0 || (size_t)written >= sizeof value) {
        return -1;
    }
    if (append(session, key, strlen(key)) != 0 || append(session, "=", 1) != 0) {
        return -1;
    }
    if (append(session, value, (size_t)written) != 0) {
        return -1;
    }
    return append(session, "\n", 1);
}

/* ---------------------------------------------------------------------------------------------
 * Opening the file and choosing the sound
 * ------------------------------------------------------------------------------------------- */

/* Whether `rate` and `channels` are a real file's, within the protocol's limits. */
static int is_real_form(int rate, int channels) {
    return rate > 0 && rate <= TMFF_MAX_SAMPLE_RATE && channels > 0 && channels <= TMFF_MAX_CHANNELS;
}

/* Whether `stream` is sound a book could be made of: audio, not a cover picture, with a rate
   and channels a real file has. */
static int is_usable_sound(const AVStream *stream) {
    const AVCodecParameters *parameters = stream->codecpar;
    return parameters->codec_type == AVMEDIA_TYPE_AUDIO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
        && is_real_form(parameters->sample_rate, parameters->ch_layout.nb_channels);
}

/* The sound stream the book is made of: the first usable one this build decodes that the file
   marks as its default, else the first usable one it decodes (the rule the import followed with
   the installed ffmpeg before FMT50, less the sound no decoder here reads). Returns
   its index, or a negative TMFF_EXIT_ number: NO_DECODER when there is usable sound but none
   decodes here, NO_SOUND when there is none at all. */
static int choose_stream(const AVFormatContext *format) {
    int first = -1, first_default = -1, usable = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        const AVStream *stream = format->streams[index];
        if (!is_usable_sound(stream)) {
            continue;
        }
        usable = 1;
        if (!avcodec_find_decoder(stream->codecpar->codec_id)) {
            continue;
        }
        if (first < 0) {
            first = (int)index;
        }
        if (first_default < 0 && (stream->disposition & AV_DISPOSITION_DEFAULT)) {
            first_default = (int)index;
        }
    }
    if (first_default >= 0) {
        return first_default;
    }
    if (first >= 0) {
        return first;
    }
    return usable ? -TMFF_EXIT_NO_DECODER : -TMFF_EXIT_NO_SOUND;
}

/* The TMFF_EXIT_ number for an FFmpeg error from opening or reading: memory, a stop, or a file
   the demuxer refuses. */
static int open_failure(const tmff_session *session, int error) {
    if (error == AVERROR(ENOMEM)) {
        return TMFF_EXIT_MEMORY;
    }
    if (atomic_load(&session->stopped) || error == AVERROR_EXIT) {
        return TMFF_EXIT_STOPPED;
    }
    return TMFF_EXIT_NOT_RECOGNIZED;
}

/* The decoder's buffer callback (AVCodecContext.get_buffer2, whose context's opaque is the
   session): FFmpeg's own buffers (avcodec_default_get_buffer2) for a frame of at most
   MAX_DECODED_SAMPLES samples over its channels, and AVERROR(EINVAL) for a larger one, before any
   of it is allocated, with frame_too_large set, so that the decode ends saying so. FFmpeg sets an
   audio frame's samples and channel layout before it asks for its buffers. */
static int frame_buffer(AVCodecContext *decoder, AVFrame *frame, int flags) {
    tmff_session *session = decoder->opaque;
    const int channels = frame->ch_layout.nb_channels > 0 ? frame->ch_layout.nb_channels : decoder->ch_layout.nb_channels;
    if ((int64_t)frame->nb_samples * (channels > 0 ? channels : 1) > MAX_DECODED_SAMPLES) {
        session->frame_too_large = 1;
        return AVERROR(EINVAL);
    }
    return avcodec_default_get_buffer2(decoder, frame, flags);
}

/* Opens the decoder of the chosen stream; 0, or a TMFF_EXIT_ number. */
static int open_decoder(tmff_session *session) {
    const AVStream *stream = session->format->streams[session->stream_index];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        return TMFF_EXIT_NO_DECODER;
    }
    session->decoder = avcodec_alloc_context3(codec);
    if (!session->decoder) {
        return TMFF_EXIT_MEMORY;
    }
    if (avcodec_parameters_to_context(session->decoder, stream->codecpar) < 0) {
        return TMFF_EXIT_DAMAGED;
    }
    session->decoder->pkt_timebase = stream->time_base;
    /* One thread, so that every frame is decoded on the thread whose signal guard the helper set
       up (a fault on a decoding thread of FFmpeg's own would not meet it), and no thread's stack
       is left out of the helper's memory count. Set before avcodec_open2, which starts threads. */
    session->decoder->thread_count = 1;
    /* No decoded frame larger than MAX_DECODED_SAMPLES: the session's own buffer callback refuses
       one before any of it is allocated. */
    session->decoder->opaque = session;
    session->decoder->get_buffer2 = frame_buffer;
    const int error = avcodec_open2(session->decoder, codec, NULL);
    if (error < 0) {
        return error == AVERROR(ENOMEM) ? TMFF_EXIT_MEMORY : TMFF_EXIT_DAMAGED;
    }
    return 0;
}

int tmff_session_prepare(void) {
    return av_get_cpu_flags();
}

int tmff_session_cpu_features(void) {
    return av_get_cpu_flags();
}

void tmff_set_allocation_cap(size_t bytes) {
    allocation_cap = bytes > 0 && bytes < MAX_ALLOCATION_BYTES ? bytes : MAX_ALLOCATION_BYTES;
    av_max_alloc(allocation_cap);
}

/* O_NOFOLLOW makes the open fail (ELOOP) when the path's last part is a symbolic link, so a link
   is refused as the sentence for a file that cannot be opened, before any fstat could pass the
   regular file it points at. O_NONBLOCK keeps a FIFO from being waited on. */
int tmff_open_regular_file(const char *path) {
    const int descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return -1;
    }
    struct stat status;
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode)) {
        close(descriptor);
        return -1;
    }
    const int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

tmff_session *tmff_session_open(int descriptor, const char *demuxer_name, tmff_session_mode mode, int *status) {
    return tmff_session_open_checked(descriptor, demuxer_name, mode, NULL, NULL, status);
}

void tmff_session_set_stop_check(tmff_session *session, tmff_stop_check check, void *context) {
    if (session) {
        session->stop_check = check;
        session->stop_context = context;
    }
}

tmff_session *tmff_session_open_checked(int descriptor, const char *demuxer_name, tmff_session_mode mode,
                                        tmff_stop_check check, void *context, int *status) {
    int failure = TMFF_EXIT_MEMORY;
    unsigned char *buffer = NULL;
    av_log_set_level(AV_LOG_QUIET);
    av_max_alloc(allocation_cap);

    tmff_session *session = calloc(1, sizeof *session);
    if (!session) {
        goto failed;
    }
    session->mode = mode;
    session->descriptor = descriptor;
    session->stream_index = -1;
    session->stage = STAGE_HEAD;
    atomic_init(&session->stopped, 0);
    /* The check is asked from the first read on, through the interrupt callback set below. */
    session->stop_check = check;
    session->stop_context = context;

    struct stat status_of_file;
    if (fstat(descriptor, &status_of_file) != 0 || !S_ISREG(status_of_file.st_mode)) {
        failure = TMFF_EXIT_UNREADABLE;
        goto failed;
    }
    session->size = (int64_t)status_of_file.st_size;

    const AVInputFormat *demuxer = av_find_input_format(demuxer_name ? demuxer_name : "");
    if (!demuxer) {
        failure = TMFF_EXIT_NO_DEMUXER;
        goto failed;
    }
    /* FFmpeg reads through read_file and seek_file; the buffer becomes the I/O context's, which
       may replace it, so it is freed through the context (tmff_session_close). */
    buffer = av_malloc(READ_BUFFER_BYTES);
    if (!buffer) {
        goto failed;
    }
    session->io = avio_alloc_context(buffer, READ_BUFFER_BYTES, 0, session, read_file, NULL, seek_file);
    if (!session->io) {
        av_free(buffer);
        goto failed;
    }
    session->format = avformat_alloc_context();
    if (!session->format) {
        goto failed;
    }
    session->format->pb = session->io;
    session->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    session->format->interrupt_callback.callback = interrupted;
    session->format->interrupt_callback.opaque = session;

    /* On a failure avformat_open_input frees the context and sets it to NULL; the I/O context
       stays the session's to free. */
    int error = avformat_open_input(&session->format, NULL, demuxer, NULL);
    if (error < 0) {
        failure = open_failure(session, error);
        goto failed;
    }
    error = avformat_find_stream_info(session->format, NULL);
    if (error < 0) {
        failure = open_failure(session, error);
        goto failed;
    }
    /* FFmpeg can finish a step whose interrupt callback said stop as if it had not been told
       (train 1117-1406: an ASF file opened whole on the iPhone after its check had said stop), so
       once FFmpeg has read the header and found the streams, the session asks itself: an open
       told to stop ends stopped, as the header promises, before any decoder is opened. */
    if (must_stop(session)) {
        failure = TMFF_EXIT_STOPPED;
        goto failed;
    }
    const int chosen = choose_stream(session->format);
    if (chosen < 0) {
        failure = -chosen;
        goto failed;
    }
    session->stream_index = chosen;
    /* The demuxer hands over only the chosen stream's packets. */
    for (unsigned int index = 0; index < session->format->nb_streams; index++) {
        if ((int)index != chosen) {
            session->format->streams[index]->discard = AVDISCARD_ALL;
        }
    }
    failure = open_decoder(session);
    if (failure != 0) {
        goto failed;
    }
    session->packet = av_packet_alloc();
    session->frame = av_frame_alloc();
    session->converted = av_frame_alloc();
    if (!session->packet || !session->frame || !session->converted) {
        failure = TMFF_EXIT_MEMORY;
        goto failed;
    }
    *status = TMFF_EXIT_DONE;
    return session;

failed:
    tmff_session_close(session);
    *status = failure;
    return NULL;
}

void tmff_session_stop(tmff_session *session) {
    if (session) {
        atomic_store(&session->stopped, 1);
    }
}

void tmff_session_close(tmff_session *session) {
    if (!session) {
        return;
    }
    swr_free(&session->swr);
    av_channel_layout_uninit(&session->swr_layout);
    av_channel_layout_uninit(&session->layout);
    av_channel_layout_uninit(&session->first_layout);
    av_frame_free(&session->converted);
    av_frame_free(&session->frame);
    av_packet_free(&session->packet);
    avcodec_free_context(&session->decoder);
    avformat_close_input(&session->format);
    if (session->io) {
        av_freep(&session->io->buffer);
        avio_context_free(&session->io);
    }
    free(session->record);
    free(session);
}

/* ---------------------------------------------------------------------------------------------
 * The samples' form
 * ------------------------------------------------------------------------------------------- */

/* The WAVE channel mask of `layout` with `channels` channels: its own in FFmpeg's native order,
   FFmpeg's default for that many channels when it says none, and 0 (unknown) when it names a
   loudspeaker past a WAVE mask's or does not hold as many channels. */
static uint64_t wave_mask(const AVChannelLayout *layout, int channels) {
    uint64_t mask = 0;
    if (layout->order == AV_CHANNEL_ORDER_NATIVE) {
        mask = layout->u.mask;
    } else {
        AVChannelLayout fallback;
        memset(&fallback, 0, sizeof fallback);
        av_channel_layout_default(&fallback, channels);
        if (fallback.order == AV_CHANNEL_ORDER_NATIVE) {
            mask = fallback.u.mask;
        }
        av_channel_layout_uninit(&fallback);
    }
    if ((mask & ~WAVE_CHANNEL_BITS) != 0 || __builtin_popcountll(mask) != channels) {
        return 0;
    }
    return mask;
}

/* Settles the PCM records' form from a decoder's sample format `format` and depth `raw_bits`
   (its bits_per_raw_sample, 0 when it says none): floating point stays floating point; 8 and 16
   bits are written as 16-bit whole numbers; more as 32-bit whole numbers of the decoder's own
   depth. */
static void settle_form(tmff_session *session, int format, int raw_bits) {
    session->frame_format = format;
    switch (av_get_packed_sample_fmt((enum AVSampleFormat)format)) {
    case AV_SAMPLE_FMT_FLT:
    case AV_SAMPLE_FMT_DBL:
        session->out = OUT_F32;
        session->bits = 32;
        break;
    case AV_SAMPLE_FMT_U8:
        session->out = OUT_S16;
        session->bits = 8;
        break;
    case AV_SAMPLE_FMT_S16:
        session->out = OUT_S16;
        session->bits = 16;
        break;
    default: /* S32 and S64 */
        session->out = OUT_S32;
        session->bits = raw_bits > 16 && raw_bits <= 32 ? raw_bits : 32;
        break;
    }
}

/* ---------------------------------------------------------------------------------------------
 * Decoding
 * ------------------------------------------------------------------------------------------- */

/* `ticks` of `base` in microseconds; 0 for a base that is no time or a number that does not fit. */
static int64_t ticks_to_us(int64_t ticks, AVRational base) {
    if (base.num <= 0 || base.den <= 0) {
        return 0;
    }
    const int64_t us = av_rescale_q(ticks, base, AV_TIME_BASE_Q);
    return us == INT64_MIN ? 0 : us;
}

/* The most refused sound the session may fill with silence: what the file states of its own
   length (MAX_UNSTATED_SILENCE_SECONDS when it states none), never past MAX_SILENCE_SECONDS. */
static int64_t silence_limit(const tmff_session *session) {
    int64_t limit = session->silence_limit_us;
    if (limit <= 0 && session->format) {
        const AVStream *stream = session->format->streams[session->stream_index];
        if (stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
            limit = ticks_to_us(stream->duration, stream->time_base);
        }
        if (session->format->duration != AV_NOPTS_VALUE && session->format->duration > limit) {
            limit = session->format->duration;
        }
    }
    if (limit <= 0) {
        limit = (int64_t)MAX_UNSTATED_SILENCE_SECONDS * MICROSECONDS;
    }
    /* A length the file's size cannot hold is no length (the app's rule, at 1 kbit/s): 8 bits a
       byte, and 1,000 microseconds a bit, with the size capped so the product fits. */
    if (session->size > 0) {
        const int64_t held = (session->size < INT64_MAX / 8000 ? session->size : INT64_MAX / 8000) * 8000;
        limit = limit < held ? limit : held;
    }
    const int64_t ceiling = (int64_t)MAX_SILENCE_SECONDS * MICROSECONDS;
    return limit < ceiling ? limit : ceiling;
}

/* Owes `gap_us` of silence, the place of sound the decoder refused, unless the gap, or all the
   silence owed with it, would pass the bound (silence_limit): then none is owed and the gap
   closes, as it did before FU03. A gap of nothing, or less, owes none either. */
static void owe_silence(tmff_session *session, int64_t gap_us) {
    if (gap_us <= 0) {
        return;
    }
    const int64_t limit = silence_limit(session);
    if (gap_us > limit || session->silence_total_us > limit - gap_us) {
        return;
    }
    session->silence_total_us += gap_us;
    session->silence_owed_us += gap_us;
}

/* Notes a packet of `length_us` the decoder refused (0: the packet states none, which is taken to
   be as long as the last one the decoder took). A length past the ceiling counts as the ceiling,
   so the sum never overflows, and is then past the bound, which owe_silence leaves unfilled. */
static void note_refused_packet(tmff_session *session, int64_t length_us) {
    const int64_t ceiling = (int64_t)MAX_SILENCE_SECONDS * MICROSECONDS;
    if (length_us <= 0) {
        length_us = session->last_packet_us;
    }
    session->refused_since_frame = 1;
    session->refused_us += length_us < ceiling ? length_us : ceiling;
    if (session->refused_us > ceiling) {
        session->refused_us = ceiling;
    }
}

/* Notes a frame that came out of the decoder, of `samples` at `rate`, whose start is `start_us`
   (AV_NOPTS_VALUE: it states none). When packets were refused since the last frame, the silence
   they owe is the gap between where that frame ended and where this one starts, by their
   timestamps, when both are stated and the gap is forward and within the bound; otherwise (a
   timestamp missing, a jump backward, or a jump past the bound) the sum of the refused packets'
   own lengths. A file with no refused packet owes none, whatever its timestamps say. */
static void note_frame(tmff_session *session, int64_t start_us, int samples, int rate) {
    if (session->refused_since_frame) {
        int64_t gap = session->refused_us;
        int64_t stamped = 0;
        if (start_us != AV_NOPTS_VALUE && session->have_end && !__builtin_sub_overflow(start_us, session->prev_end_us, &stamped)
            && stamped > 0 && stamped <= silence_limit(session)) {
            gap = stamped;
        }
        session->refused_since_frame = 0;
        session->refused_us = 0;
        owe_silence(session, gap);
    }
    int64_t end = 0;
    session->have_end = start_us != AV_NOPTS_VALUE && rate > 0 && samples >= 0
        && !__builtin_add_overflow(start_us, (int64_t)samples * MICROSECONDS / rate, &end);
    session->prev_end_us = end;
}

/* The silence owed at the end of the sound: what the packets refused since the last frame add up
   to, within the bound; asked again, nothing more is owed. Returns 0, which next_frame gives as
   the end of the sound. */
static int owe_trailing_silence(tmff_session *session) {
    if (session->refused_since_frame) {
        const int64_t gap = session->refused_us;
        session->refused_since_frame = 0;
        session->refused_us = 0;
        owe_silence(session, gap);
    }
    return 0;
}

/* Takes at most `most` frames of the silence owed (turned into whole frames at the first form's
   rate once it is known), and returns how many. */
static uint64_t take_silence_frames(tmff_session *session, uint64_t most) {
    if (session->silence_owed_us > 0 && session->sample_rate > 0) {
        /* Rounded to the nearest frame: at most 12 hours at the greatest rate fits 64 bits. */
        session->silence_owed_frames +=
            ((uint64_t)session->silence_owed_us * (uint64_t)session->sample_rate + MICROSECONDS / 2) / MICROSECONDS;
        session->silence_owed_us = 0;
    }
    const uint64_t taken = session->silence_owed_frames < most ? session->silence_owed_frames : most;
    session->silence_owed_frames -= taken;
    return taken;
}

/* The length of `packet` in microseconds, 0 when it states none. */
static int64_t packet_length_us(const tmff_session *session, const AVPacket *packet) {
    if (packet->duration <= 0) {
        return 0;
    }
    return ticks_to_us(packet->duration, session->format->streams[session->stream_index]->time_base);
}

/* Takes the next decoded frame into session->frame. Returns 1 when a frame is there, 0 when the
   decoder has given its last, or a negative TMFF_EXIT_ number. A packet the decoder refuses is
   counted, and its place is kept as silence (FU03); a frame it refuses is counted and skipped,
   up to MAX_ERRORS_IN_A_ROW in a row (TMFF_EXIT_DAMAGED past them). */
static int next_frame(tmff_session *session) {
#ifdef DEBUG
    if (session->made_up) {
        return session->made_up(session);
    }
#endif
    int errors_in_a_row = 0;
    for (;;) {
        if (must_stop(session)) {
            return -TMFF_EXIT_STOPPED;
        }
        if (session->decoder_ended) {
            return owe_trailing_silence(session);
        }
        const int received = avcodec_receive_frame(session->decoder, session->frame);
        if (received == 0) {
            /* One thread decodes (open_decoder), so the decoder describes the frame it has just
               given, and its rate is the true one: MP3's first frame after a change of rate comes
               with the old rate in frame->sample_rate (measured, from 22,050 to 44,100 Hz: a
               1,152-sample frame labelled 22,050), which would be resampled at the wrong speed. */
            if (session->decoder->sample_rate > 0 && session->frame->sample_rate != session->decoder->sample_rate) {
                session->frame->sample_rate = session->decoder->sample_rate;
            }
            const AVFrame *frame = session->frame;
            const int64_t start = frame->best_effort_timestamp == AV_NOPTS_VALUE
                ? AV_NOPTS_VALUE
                : ticks_to_us(frame->best_effort_timestamp, session->format->streams[session->stream_index]->time_base);
            note_frame(session, start, frame->nb_samples, frame->sample_rate);
            return 1;
        }
        if (received == AVERROR_EOF) {
            session->decoder_ended = 1;
            return owe_trailing_silence(session);
        }
        if (received == AVERROR(ENOMEM)) {
            return -TMFF_EXIT_MEMORY;
        }
        if (received != AVERROR(EAGAIN)) {
            /* A frame past the bound ends the decode as such, never skipped as damaged. */
            if (session->frame_too_large) {
                return -TMFF_EXIT_FRAME_TOO_LARGE;
            }
            session->frame_errors++;
            if (++errors_in_a_row > MAX_ERRORS_IN_A_ROW) {
                return -TMFF_EXIT_DAMAGED;
            }
            continue;
        }
        errors_in_a_row = 0;
        /* The decoder wants more: the next packet of the chosen stream, or, at the file's end,
           none, which drains the decoder. */
        if (session->demuxer_ended) {
            /* Already drained once and still asking: there is nothing more. */
            session->decoder_ended = 1;
            return owe_trailing_silence(session);
        }
        const int read = av_read_frame(session->format, session->packet);
        if (read < 0) {
            if (read == AVERROR(ENOMEM)) {
                return -TMFF_EXIT_MEMORY;
            }
            if (atomic_load(&session->stopped) || read == AVERROR_EXIT) {
                return -TMFF_EXIT_STOPPED;
            }
            /* The end of the file, or damage past which nothing can be read: drain. */
            session->demuxer_ended = 1;
            if (avcodec_send_packet(session->decoder, NULL) < 0) {
                session->decoder_ended = 1;
                return owe_trailing_silence(session);
            }
            continue;
        }
        if (session->packet->stream_index == session->stream_index) {
            const int64_t length_us = packet_length_us(session, session->packet);
            const int sent = avcodec_send_packet(session->decoder, session->packet);
            if (sent == AVERROR(ENOMEM)) {
                av_packet_unref(session->packet);
                return -TMFF_EXIT_MEMORY;
            }
            if (sent < 0 && sent != AVERROR(EAGAIN)) {
                if (session->frame_too_large) {
                    av_packet_unref(session->packet);
                    return -TMFF_EXIT_FRAME_TOO_LARGE;
                }
                session->packet_errors++;
                note_refused_packet(session, length_us);
            } else if (length_us > 0) {
                session->last_packet_us = length_us;
            }
        }
        av_packet_unref(session->packet);
    }
}

/* Appends one sample of `frame`, channel `channel` of frame position `position`, as the PCM
   records' form says. The frame is in the first frame's format (checked by append_frame). */
static int append_sample(tmff_session *session, const AVFrame *frame, int channel, int position) {
    const enum AVSampleFormat format = (enum AVSampleFormat)frame->format;
    const int planar = av_sample_fmt_is_planar(format);
    const int channels = frame->ch_layout.nb_channels;
    const int width = av_get_bytes_per_sample(format);
    const uint8_t *plane = frame->extended_data[planar ? channel : 0];
    const uint8_t *at = plane + (size_t)(planar ? position : position * channels + channel) * (size_t)width;
    switch (av_get_packed_sample_fmt(format)) {
    case AV_SAMPLE_FMT_U8: {
        const int16_t value = (int16_t)((int)at[0] - 128);
        return append(session, &value, 2);
    }
    case AV_SAMPLE_FMT_S16:
        return append(session, at, 2);
    case AV_SAMPLE_FMT_S32: {
        int32_t value;
        memcpy(&value, at, 4);
        /* FFmpeg holds a sample of fewer than 32 bits in the top bits: moved down to its own
           depth (clang shifts a negative number arithmetically, keeping its sign). */
        value >>= (32 - session->bits);
        return append(session, &value, 4);
    }
    case AV_SAMPLE_FMT_S64: {
        int64_t wide;
        memcpy(&wide, at, 8);
        const int32_t value = (int32_t)(wide >> 32);
        return append(session, &value, 4);
    }
    case AV_SAMPLE_FMT_FLT:
        return append(session, at, 4);
    case AV_SAMPLE_FMT_DBL: {
        double wide;
        memcpy(&wide, at, 8);
        const float value = (float)wide;
        return append(session, &value, 4);
    }
    default:
        return -1;
    }
}

/* Whether `frame` has the first frame's rate, channel layout, and format, as every frame must. */
static int has_the_first_form(const tmff_session *session, const AVFrame *frame) {
    return frame->sample_rate == session->sample_rate && frame->format == session->frame_format
        && av_channel_layout_compare(&frame->ch_layout, &session->first_layout) == 0;
}

/* The negative TMFF_EXIT_ number for an FFmpeg `error`: MEMORY for a refused allocation, else
   `otherwise` (the one place the mapping is made). */
static int exit_for(int error, int otherwise) {
    return error == AVERROR(ENOMEM) ? -TMFF_EXIT_MEMORY : -otherwise;
}

/* Makes `frame` the one being written, from its first frame. */
static void set_source(tmff_session *session, AVFrame *frame) {
    session->source = frame;
    session->have_frame = 1;
    session->frame_position = 0;
}

/* Sets `layout` to `wanted` as a resampler can use it: an unspecified order (a channel count
   that names no loudspeaker) becomes FFmpeg's default layout for that many channels, which may
   itself be unspecified. Returns 0, or a negative AVERROR when the memory is refused. */
static int make_layout(AVChannelLayout *layout, const AVChannelLayout *wanted) {
    av_channel_layout_uninit(layout);
    if (wanted->order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(layout, wanted->nb_channels);
        return 0;
    }
    return av_channel_layout_copy(layout, wanted);
}

/* Whether `frame` is a form the resampler can be asked for: a rate, channel count, and sample
   format of a real file (the limits the first frame is held to), which a frame of a damaged
   decoder may not have. */
static int is_convertible(const AVFrame *frame) {
    return is_real_form(frame->sample_rate, frame->ch_layout.nb_channels) && frame->format >= 0
        && av_get_bytes_per_sample((enum AVSampleFormat)frame->format) > 0;
}

/* Whether the open resampler takes in `frame`'s form, so the frame can go through it. */
static int resampler_takes(const tmff_session *session, const AVFrame *frame) {
    return session->swr_rate == frame->sample_rate && session->swr_format == frame->format
        && av_channel_layout_compare(&session->swr_layout, &frame->ch_layout) == 0;
}

/* Opens a resampler from `frame`'s form to the first frame's. Returns 0, or a negative
   TMFF_EXIT_ number: FORM_CHANGED for a form that cannot be converted, a rate more than
   MAX_RATE_RATIO to one from the first frame's either way, or more than MAX_FORM_CHANGES
   changes; MEMORY when memory is refused. */
static int open_resampler(tmff_session *session, const AVFrame *frame) {
    if (!is_convertible(frame) || ++session->form_changes > MAX_FORM_CHANGES
        || (int64_t)frame->sample_rate > (int64_t)session->sample_rate * MAX_RATE_RATIO
        || (int64_t)session->sample_rate > (int64_t)frame->sample_rate * MAX_RATE_RATIO) {
        return -TMFF_EXIT_FORM_CHANGED;
    }
    AVChannelLayout in_layout;
    memset(&in_layout, 0, sizeof in_layout);
    if (make_layout(&in_layout, &frame->ch_layout) != 0) {
        return -TMFF_EXIT_MEMORY;
    }
    int result = 0;
    int error = swr_alloc_set_opts2(&session->swr, &session->layout, (enum AVSampleFormat)session->frame_format,
                                    session->sample_rate, &in_layout, (enum AVSampleFormat)frame->format,
                                    frame->sample_rate, 0, NULL);
    if (error >= 0) {
        error = swr_init(session->swr);
        if (error < 0) {
            /* A layout the resampler has no way from (it names no loudspeakers and the count differs). */
            swr_free(&session->swr);
        }
    }
    if (error < 0) {
        result = exit_for(error, TMFF_EXIT_FORM_CHANGED);
    } else {
        /* Remember the form it takes in, to know the next frame of that form from another. */
        session->swr_rate = frame->sample_rate;
        session->swr_format = frame->format;
        av_channel_layout_uninit(&session->swr_layout);
        if (av_channel_layout_copy(&session->swr_layout, &frame->ch_layout) != 0) {
            swr_free(&session->swr);
            result = -TMFF_EXIT_MEMORY;
        }
    }
    av_channel_layout_uninit(&in_layout);
    return result;
}

/* Runs the next part of `input` (from session->input_position; NULL: nothing more, which drains
   what the resampler still holds) through the resampler into session->converted, in the first
   frame's form. At most MAX_CONVERTED_BYTES come out at a time: a longer frame is fed in slices,
   each the part of it that fits, and the rest of what the resampler holds is given by the calls
   that follow. Returns the frames given, 0 when none came out, or a negative TMFF_EXIT_ number. */
static int resample_into_converted(tmff_session *session, const AVFrame *input) {
    AVFrame *out = session->converted;
    av_frame_unref(out);
    const int64_t sample_bytes = (int64_t)session->channels * av_get_bytes_per_sample((enum AVSampleFormat)session->frame_format);
    const int64_t room = MAX_CONVERTED_BYTES / sample_bytes; /* the frames one converted frame may hold, 32,768 or more */
    /* The slice of the input to feed: all that is left of it, or the part whose output fits `room`. */
    int in_count = input ? input->nb_samples - session->input_position : 0;
    while (in_count > 1 && swr_get_out_samples(session->swr, in_count) + 32 > room) {
        in_count /= 2;
    }
    const uint8_t *slice[TMFF_MAX_CHANNELS];
    if (input) {
        const int planar = av_sample_fmt_is_planar((enum AVSampleFormat)input->format);
        const int width = av_get_bytes_per_sample((enum AVSampleFormat)input->format);
        const int planes = planar ? input->ch_layout.nb_channels : 1;
        const size_t step = (size_t)session->input_position * (size_t)(planar ? 1 : input->ch_layout.nb_channels) * (size_t)width;
        for (int plane = 0; plane < planes; plane++) {
            slice[plane] = input->extended_data[plane] + step;
        }
    }
    /* What the resampler can give for this slice and what it holds, with a little to spare. */
    const int64_t held = swr_get_delay(session->swr, session->sample_rate);
    const int64_t bound = swr_get_out_samples(session->swr, in_count);
    int64_t capacity = (bound > held ? bound : held) + 32;
    if (capacity > room) {
        capacity = room;
    }
    out->format = session->frame_format;
    out->sample_rate = session->sample_rate;
    out->nb_samples = (int)capacity;
    if (av_channel_layout_copy(&out->ch_layout, &session->layout) != 0) {
        return -TMFF_EXIT_MEMORY;
    }
    const int allocated = av_frame_get_buffer(out, 0);
    if (allocated < 0) {
        return exit_for(allocated, TMFF_EXIT_FORM_CHANGED);
    }
    const int count = swr_convert(session->swr, out->extended_data, out->nb_samples, input ? slice : NULL, in_count);
    if (count < 0) {
        return exit_for(count, TMFF_EXIT_FORM_CHANGED);
    }
    session->input_position += in_count;
    out->nb_samples = count;
    return count;
}

/* Gives what the open resampler still holds (the end of its last stretch), as the next source.
   Returns 1 when frames came out (the resampler stays open: it may hold more), 0 when it held
   none, and it is closed, or a negative TMFF_EXIT_ number. Without a resampler, 0. */
static int drain_resampler(tmff_session *session) {
    if (!session->swr) {
        return 0;
    }
    const int count = resample_into_converted(session, NULL);
    if (count < 0) {
        return count;
    }
    if (count == 0) {
        swr_free(&session->swr);
        return 0;
    }
    set_source(session, session->converted);
    return 1;
}

/* Takes the next frames to write into session->source: a decoded frame of the first form as it
   is, one of another form converted to it (a long one in slices, over several calls), or what a
   resampler still holds when the form changes back or the decoder is done. Returns 1 when frames
   wait in `source`, 0 when the sound is over, or a negative TMFF_EXIT_ number. */
static int take_next_source(tmff_session *session) {
    for (;;) {
        if (!session->frame_waits) {
            const int found = next_frame(session);
            if (found < 0) {
                return found;
            }
            if (found == 0) {
                /* The decoder has given its last frame; the resampler may hold the end of the sound. */
                return drain_resampler(session);
            }
            session->frame_waits = 1;
            session->input_position = 0;
        }
        AVFrame *frame = session->frame;
        const int first_form = has_the_first_form(session, frame);
        if (session->swr && (first_form || !resampler_takes(session, frame))) {
            /* The form changed since the resampler was set: its last frames come first. */
            const int drained = drain_resampler(session);
            if (drained != 0) {
                return drained;
            }
            continue;
        }
        if (first_form) {
            session->frame_waits = 0;
            set_source(session, frame);
            return 1;
        }
        if (frame->nb_samples <= 0) {
            /* No sound in it: nothing to convert. */
            av_frame_unref(frame);
            session->frame_waits = 0;
            continue;
        }
        if (!session->swr) {
            const int opened = open_resampler(session, frame);
            if (opened < 0) {
                return opened;
            }
        }
        const int count = resample_into_converted(session, frame);
        if (count < 0) {
            return count;
        }
        if (session->input_position >= frame->nb_samples) {
            /* All of it is in the resampler now; what it kept comes with the next frames. */
            av_frame_unref(frame);
            session->frame_waits = 0;
        }
        if (count > 0) {
            set_source(session, session->converted);
            return 1;
        }
        /* The resampler kept it all for its next call (a long step down in rate): the next part. */
    }
}

/* Appends `count` frames of `frame`, from frame position `from`, interleaved, to the PCM record
   being made. Returns 0, or TMFF_EXIT_MEMORY when the record cannot grow. */
static int append_frames(tmff_session *session, const AVFrame *frame, int from, int count) {
    const size_t width = session->out == OUT_S16 ? 2 : 4;
    if (reserve(session, (size_t)count * (size_t)session->channels * width) != 0) {
        return TMFF_EXIT_MEMORY;
    }
    for (int position = from; position < from + count; position++) {
        for (int channel = 0; channel < session->channels; channel++) {
            if (append_sample(session, frame, channel, position) != 0) {
                return TMFF_EXIT_MEMORY;
            }
        }
    }
    session->frames_written += (uint64_t)count;
    return 0;
}

/* Settles the samples' form from `frame`, the first the decoder gave, with `raw_bits` its depth
   (the decoder's bits_per_raw_sample, 0 when it says none), and makes it the frame being
   written. Returns 0, or a TMFF_EXIT_ number: DAMAGED for a rate or channels no real file has. */
static int adopt_first_form(tmff_session *session, AVFrame *frame, int raw_bits) {
    if (!is_real_form(frame->sample_rate, frame->ch_layout.nb_channels)) {
        return TMFF_EXIT_DAMAGED;
    }
    session->sample_rate = frame->sample_rate;
    session->channels = frame->ch_layout.nb_channels;
    session->channel_mask = wave_mask(&frame->ch_layout, session->channels);
    av_channel_layout_uninit(&session->first_layout);
    if (av_channel_layout_copy(&session->first_layout, &frame->ch_layout) != 0
        || make_layout(&session->layout, &frame->ch_layout) != 0) {
        return TMFF_EXIT_MEMORY;
    }
    settle_form(session, frame->format, raw_bits);
    set_source(session, frame);
    return 0;
}

/* A decode: reads the first frame and settles the samples' form from it. Returns 0, or a
   TMFF_EXIT_ number: DAMAGED when the decoder gives no frame at all. */
static int read_first_frame(tmff_session *session) {
    const int found = next_frame(session);
    if (found < 0) {
        return -found;
    }
    if (found == 0) {
        return TMFF_EXIT_DAMAGED;
    }
    return adopt_first_form(session, session->frame, session->decoder->bits_per_raw_sample);
}

/* A probe: settles the samples' form from the decoder as it opened, without decoding. */
static void read_form_from_decoder(tmff_session *session) {
    const AVCodecContext *decoder = session->decoder;
    const AVCodecParameters *parameters = session->format->streams[session->stream_index]->codecpar;
    session->sample_rate = decoder->sample_rate > 0 ? decoder->sample_rate : parameters->sample_rate;
    session->channels = decoder->ch_layout.nb_channels > 0 ? decoder->ch_layout.nb_channels : parameters->ch_layout.nb_channels;
    session->channel_mask = wave_mask(decoder->ch_layout.nb_channels > 0 ? &decoder->ch_layout : &parameters->ch_layout,
                                      session->channels);
    const int raw = decoder->bits_per_raw_sample > 0 ? decoder->bits_per_raw_sample : parameters->bits_per_raw_sample;
    settle_form(session, decoder->sample_fmt != AV_SAMPLE_FMT_NONE ? decoder->sample_fmt : parameters->format, raw);
}

/* ---------------------------------------------------------------------------------------------
 * The records, one by one
 * ------------------------------------------------------------------------------------------- */

/* The HEAD record: the protocol's version and FFmpeg's. */
static int make_head(tmff_session *session) {
    if (start_record(session, TMFF_RECORD_HEAD) != 0 || append_u32(session, TMFF_PROTOCOL_VERSION) != 0
        || append_cut(session, av_version_info(), 128) != 0) {
        return TMFF_EXIT_MEMORY;
    }
    return finish_record(session, TMFF_MAX_RECORD_BYTES) == 0 ? 0 : TMFF_EXIT_MEMORY;
}

/* The INFO record: what the chosen stream is, as the header file lists its keys. */
static int make_info(tmff_session *session) {
    const AVFormatContext *format = session->format;
    const AVStream *stream = format->streams[session->stream_index];
    const AVCodecParameters *parameters = stream->codecpar;
    unsigned int audio = 0;
    int more_than_sound = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        const AVStream *other = format->streams[index];
        if (other->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audio++;
        } else if (!(other->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            more_than_sound = 1;
        }
    }
    static const char *const sample_formats[] = {TMFF_SAMPLE_FORMAT_S16, TMFF_SAMPLE_FORMAT_S32, TMFF_SAMPLE_FORMAT_F32};
    int failed = start_record(session, TMFF_RECORD_INFO);
    failed |= append_line(session, "format", "%s", format->iformat && format->iformat->name ? format->iformat->name : "");
    failed |= append_line(session, "codec", "%s", avcodec_get_name(parameters->codec_id));
    failed |= append_line(session, "stream", "%d", session->stream_index);
    failed |= append_line(session, "streams", "%u", format->nb_streams);
    failed |= append_line(session, "audio_streams", "%u", audio);
    failed |= append_line(session, "more_than_sound", "%d", more_than_sound);
    failed |= append_line(session, "default", "%d", (stream->disposition & AV_DISPOSITION_DEFAULT) ? 1 : 0);
    failed |= append_line(session, "sample_rate", "%d", session->sample_rate);
    failed |= append_line(session, "channels", "%d", session->channels);
    failed |= append_line(session, "channel_mask", "%llu", (unsigned long long)session->channel_mask);
    failed |= append_line(session, "sample_format", "%s", sample_formats[session->out]);
    failed |= append_line(session, "bits", "%d", session->bits);
    if (stream->duration != AV_NOPTS_VALUE && stream->duration > 0 && stream->time_base.den > 0) {
        failed |= append_line(session, "duration", "%.6f", (double)stream->duration * av_q2d(stream->time_base));
    }
    if (format->duration != AV_NOPTS_VALUE && format->duration > 0) {
        failed |= append_line(session, "format_duration", "%.6f", (double)format->duration / AV_TIME_BASE);
    }
    if (parameters->bit_rate > 0) {
        failed |= append_line(session, "bit_rate", "%lld", (long long)parameters->bit_rate);
    }
    if (format->bit_rate > 0) {
        failed |= append_line(session, "format_bit_rate", "%lld", (long long)format->bit_rate);
    }
    if (failed || finish_record(session, TMFF_MAX_RECORD_BYTES) != 0) {
        return TMFF_EXIT_MEMORY;
    }
    return 0;
}

/* The next TAG or STAG record of `dictionary`, as `kind`: 1 when one was made, 0 when there is
   none left (or TMFF_MAX_TAGS have been given), or a negative TMFF_EXIT_ number. */
static int make_tag(tmff_session *session, const AVDictionary *dictionary, uint32_t kind) {
    if (session->tags_given >= TMFF_MAX_TAGS) {
        return 0;
    }
    session->tag = av_dict_iterate(dictionary, session->tag);
    if (!session->tag) {
        return 0;
    }
    if (start_record(session, kind) != 0 || append_cut(session, session->tag->key, TMFF_MAX_TAG_KEY_BYTES) != 0
        || append(session, "", 1) != 0 || append_cut(session, session->tag->value, TMFF_MAX_TAG_VALUE_BYTES) != 0
        || finish_record(session, TMFF_MAX_RECORD_BYTES) != 0) {
        return -TMFF_EXIT_MEMORY;
    }
    session->tags_given++;
    return 1;
}

/* The next CHAP record: 1 when one was made, 0 when there is none left, or a negative
   TMFF_EXIT_ number. */
static int make_chapter(tmff_session *session) {
    const AVFormatContext *format = session->format;
    if (session->chapter >= format->nb_chapters || session->chapter >= TMFF_MAX_CHAPTERS) {
        return 0;
    }
    const AVChapter *chapter = format->chapters[session->chapter++];
    const double unit = chapter->time_base.den > 0 ? av_q2d(chapter->time_base) : 0;
    const double start = (double)chapter->start * unit;
    const double end = chapter->end != AV_NOPTS_VALUE && chapter->end > chapter->start ? (double)chapter->end * unit : NAN;
    const AVDictionaryEntry *title = av_dict_get(chapter->metadata, "title", NULL, 0);
    if (start_record(session, TMFF_RECORD_CHAP) != 0 || append_double(session, start) != 0
        || append_double(session, end) != 0 || append_cut(session, title ? title->value : "", TMFF_MAX_TAG_VALUE_BYTES) != 0
        || finish_record(session, TMFF_MAX_RECORD_BYTES) != 0) {
        return -TMFF_EXIT_MEMORY;
    }
    return 1;
}

/* The next PCM record, of about PCM_RECORD_TARGET bytes: 1 when one was made, 0 when the
   decoder has given every frame, or a negative TMFF_EXIT_ number. A frame larger than the room
   left in the record (FLAC allows 65,535 samples of 8 channels, 2 MB in 32 bits) is split: what
   does not fit waits for the next record, from `frame_position` on. */
static int make_pcm(tmff_session *session) {
    if (start_record(session, TMFF_RECORD_PCM) != 0) {
        return -TMFF_EXIT_MEMORY;
    }
    const size_t frame_bytes = (size_t)session->channels * (session->out == OUT_S16 ? 2u : 4u);
    while (session->record_length - TMFF_RECORD_HEADER_BYTES < PCM_RECORD_TARGET) {
        if (!session->have_frame) {
            /* 0 here is not yet the end: the packets refused at the end of the sound owe silence. */
            const int found = take_next_source(session);
            if (found < 0) {
                return found;
            }
        }
        /* Silence owed for refused sound comes before the frame that follows it (FU03), in whole
           frames of zeros, which is silence in each of the three forms. */
        const size_t quiet_room = (TMFF_MAX_PCM_RECORD_BYTES - (session->record_length - TMFF_RECORD_HEADER_BYTES)) / frame_bytes;
        const uint64_t quiet = take_silence_frames(session, quiet_room);
        if (quiet > 0) {
            if (reserve(session, (size_t)quiet * frame_bytes) != 0) {
                return -TMFF_EXIT_MEMORY;
            }
            memset(session->record + session->record_length, 0, (size_t)quiet * frame_bytes);
            session->record_length += (size_t)quiet * frame_bytes;
            session->frames_written += quiet;
            continue;
        }
        if (!session->have_frame) {
            break;
        }
        AVFrame *frame = session->source;
        const int left = frame->extended_data ? frame->nb_samples - session->frame_position : 0;
        /* The frames that fit below the record's limit; the loop's test leaves room for at least
           (TMFF_MAX_PCM_RECORD_BYTES - PCM_RECORD_TARGET) bytes, so at least one fits. */
        const size_t room = (TMFF_MAX_PCM_RECORD_BYTES - (session->record_length - TMFF_RECORD_HEADER_BYTES)) / frame_bytes;
        const int taken = left > 0 ? (int)((size_t)left < room ? (size_t)left : room) : 0;
        if (taken > 0) {
            const int appended = append_frames(session, frame, session->frame_position, taken);
            if (appended != 0) {
                return -appended;
            }
            session->frame_position += taken;
        }
        if (session->frame_position >= frame->nb_samples || taken == 0) {
            av_frame_unref(frame);
            session->have_frame = 0;
        }
    }
    if (session->record_length == TMFF_RECORD_HEADER_BYTES) {
        return 0;
    }
    return finish_record(session, TMFF_MAX_PCM_RECORD_BYTES) == 0 ? 1 : -TMFF_EXIT_DAMAGED;
}

/* The END record: the frames written and the decoder's refusals. */
static int make_end(tmff_session *session) {
    if (start_record(session, TMFF_RECORD_END) != 0 || append_u64(session, session->frames_written) != 0
        || append_u32(session, session->packet_errors) != 0 || append_u32(session, session->frame_errors) != 0
        || finish_record(session, TMFF_MAX_RECORD_BYTES) != 0) {
        return TMFF_EXIT_MEMORY;
    }
    return 0;
}

int tmff_session_next(tmff_session *session, const unsigned char **bytes, size_t *length) {
    *bytes = NULL;
    *length = 0;
    if (!session) {
        return TMFF_EXIT_USAGE;
    }
    if (must_stop(session)) {
        session->stage = STAGE_OVER;
        return TMFF_EXIT_STOPPED;
    }
    int result = 0;
    for (;;) {
        switch (session->stage) {
        case STAGE_HEAD:
            result = make_head(session);
            session->stage = STAGE_INFO;
            goto give;
        case STAGE_INFO:
            if (session->mode == TMFF_SESSION_DECODE) {
                result = read_first_frame(session);
            } else {
                read_form_from_decoder(session);
            }
            if (result == 0) {
                result = make_info(session);
            }
            session->stage = STAGE_TAGS;
            session->tag = NULL;
            session->tags_given = 0;
            goto give;
        case STAGE_TAGS:
        case STAGE_STREAM_TAGS: {
            const int file_tags = session->stage == STAGE_TAGS;
            const AVDictionary *dictionary = file_tags ? session->format->metadata
                                                       : session->format->streams[session->stream_index]->metadata;
            const int made = make_tag(session, dictionary, file_tags ? TMFF_RECORD_TAG : TMFF_RECORD_STAG);
            if (made != 0) {
                result = made < 0 ? -made : 0;
                goto give;
            }
            session->stage = file_tags ? STAGE_STREAM_TAGS : STAGE_CHAPTERS;
            session->tag = NULL;
            session->tags_given = 0;
            continue;
        }
        case STAGE_CHAPTERS: {
            const int made = make_chapter(session);
            if (made != 0) {
                result = made < 0 ? -made : 0;
                goto give;
            }
            session->stage = session->mode == TMFF_SESSION_DECODE ? STAGE_PCM : STAGE_END;
            continue;
        }
        case STAGE_PCM: {
            const int made = make_pcm(session);
            if (made != 0) {
                result = made < 0 ? -made : 0;
                goto give;
            }
            session->stage = STAGE_END;
            continue;
        }
        case STAGE_END:
            result = make_end(session);
            session->stage = STAGE_OVER;
            goto give;
        case STAGE_OVER:
            return TMFF_EXIT_DONE;
        }
    }

give:
    if (result != 0) {
        session->stage = STAGE_OVER;
        return result;
    }
    *bytes = session->record;
    *length = session->record_length;
    return TMFF_EXIT_DONE;
}

#ifdef DEBUG
/* ---------------------------------------------------------------------------------------------
 * The Debug checks of the conversion (TMFF_MODE_FORMCHECK)
 * ------------------------------------------------------------------------------------------- */

/* One stretch of the frames the made-up decoder gives: `times` frames, each of `samples` samples
   of silence in `format`, at `rate`, in the channel layout `mask` names (a WAVE channel mask),
   or the default layout for `channels` when `mask` is 0. The rest is for the refused sound (FU03),
   and left out, a run has none: `timed` gives each frame a start (`start_us` for the first, then
   one frame's length on for each next), `refused` packets of `refused_us` each are refused just
   before the run's first frame, and `after_refused` just after its last. */
typedef struct {
    int times;
    int rate;
    int channels;
    int format;
    int samples;
    uint64_t mask;
    int timed;
    int64_t start_us;
    int refused;
    int64_t refused_us;
    int after_refused;
} made_up_run;

/* The script the made-up decoder is reading, and where it has got to (one check runs at a time). */
static const made_up_run *script;
static int script_count, script_run, script_given;

/* The made-up decoder: the next frame of the script in session->frame (1), or the end (0). */
static int made_up_next(tmff_session *session) {
    while (script_run < script_count && script_given >= script[script_run].times) {
        script_run++;
        script_given = 0;
    }
    if (script_run >= script_count) {
        return owe_trailing_silence(session);
    }
    const made_up_run *run = &script[script_run];
    script_given++;
    if (script_given == 1) {
        for (int refused = 0; refused < run->refused; refused++) {
            note_refused_packet(session, run->refused_us);
        }
    }
    AVFrame *frame = session->frame;
    av_frame_unref(frame);
    frame->format = run->format;
    frame->sample_rate = run->rate;
    frame->nb_samples = run->samples;
    if (run->mask) {
        av_channel_layout_from_mask(&frame->ch_layout, run->mask);
    } else {
        av_channel_layout_default(&frame->ch_layout, run->channels);
    }
    if (av_frame_get_buffer(frame, 0) < 0) {
        return -TMFF_EXIT_MEMORY;
    }
    av_samples_set_silence(frame->extended_data, 0, run->samples, run->channels, (enum AVSampleFormat)run->format);
    /* The frame's start, as the decoder would give it: the run's, then one frame's length on each. */
    const int64_t start = run->timed ? run->start_us + (int64_t)(script_given - 1) * run->samples * MICROSECONDS / run->rate
                                     : AV_NOPTS_VALUE;
    note_frame(session, start, run->samples, run->rate);
    if (script_given == run->times) {
        for (int refused = 0; refused < run->after_refused; refused++) {
            note_refused_packet(session, run->refused_us);
        }
    }
    return 1;
}

/* What one check found: how it ended, the frames written, the most bytes any of the frames given
   to be written held (its first one included), and how many resamplers it opened. */
typedef struct {
    int status;
    long long frames;
    long long largest;
    unsigned int changes;
    long long silence;
} formcheck_result;

/* Runs `runs` (`count` of them) through the session's conversion as the PCM records' writer does,
   from the first frame on: no file and no decoder, only frames made up in memory. The silence
   owed for refused sound is bounded by `limit_us` (0: the default for a file that states no
   length) and by a file of `size_bytes` (0: no size), and counted in the result's frames of
   silence, as make_pcm would write them. */
static formcheck_result run_script_limited(const made_up_run *runs, int count, int64_t limit_us, int64_t size_bytes) {
    formcheck_result result = {0, 0, 0, 0, 0};
    script = runs;
    script_count = count;
    script_run = script_given = 0;
    tmff_session *session = calloc(1, sizeof *session);
    if (!session) {
        result.status = TMFF_EXIT_MEMORY;
        return result;
    }
    session->frame = av_frame_alloc();
    session->converted = av_frame_alloc();
    session->made_up = made_up_next;
    session->silence_limit_us = limit_us;
    session->size = size_bytes;
    int found = session->frame && session->converted ? next_frame(session) : -TMFF_EXIT_MEMORY;
    if (found > 0) {
        result.status = adopt_first_form(session, session->frame, 0);
        result.silence += (long long)take_silence_frames(session, UINT64_MAX);
    } else {
        result.status = found < 0 ? -found : TMFF_EXIT_DAMAGED;
    }
    const long long bytes_a_frame = session->channels * av_get_bytes_per_sample((enum AVSampleFormat)session->frame_format);
    while (result.status == 0) {
        const AVFrame *given = session->source;
        result.frames += given->nb_samples;
        if (given->nb_samples * bytes_a_frame > result.largest) {
            result.largest = given->nb_samples * bytes_a_frame;
        }
        av_frame_unref(session->source);
        session->have_frame = 0;
        found = take_next_source(session);
        result.silence += (long long)take_silence_frames(session, UINT64_MAX);
        if (found <= 0) {
            result.status = found < 0 ? -found : 0;
            break;
        }
    }
    result.changes = session->form_changes;
    tmff_session_close(session);
    return result;
}

/* The same with the default bound on the silence. */
static formcheck_result run_script(const made_up_run *runs, int count) {
    return run_script_limited(runs, count, 0, 0);
}

/* Appends "name=status frames=N largest=B changes=C silence=S\n" for `result` to `out` (of
   `capacity` bytes). */
static void formcheck_line(char *out, size_t capacity, const char *name, formcheck_result result) {
    const size_t used = strlen(out);
    snprintf(out + used, capacity - used, "%s=%d frames=%lld largest=%lld changes=%u silence=%lld\n", name, result.status, result.frames,
             result.largest, result.changes, result.silence);
}

/* The two rates of a ratio check: the first frame's, then the other's, in mono floating point. */
static formcheck_result run_ratio(int first_rate, int other_rate) {
    const made_up_run runs[] = {
        {1, first_rate, 1, AV_SAMPLE_FMT_FLT, 1152, 0},
        {1, other_rate, 1, AV_SAMPLE_FMT_FLT, 1152, 0},
    };
    return run_script(runs, 2);
}

/* `changes` changes away from the first form and back: a frame of another rate, then one of the first. */
static formcheck_result run_changes(int changes) {
    made_up_run *runs = calloc((size_t)(2 * changes + 1), sizeof *runs);
    formcheck_result result = {TMFF_EXIT_MEMORY, 0, 0, 0, 0};
    if (runs) {
        runs[0] = (made_up_run){1, 22050, 1, AV_SAMPLE_FMT_FLT, 1152, 0};
        for (int index = 0; index < changes; index++) {
            runs[1 + 2 * index] = (made_up_run){1, 44100, 1, AV_SAMPLE_FMT_FLT, 1152, 0};
            runs[2 + 2 * index] = (made_up_run){1, 22050, 1, AV_SAMPLE_FMT_FLT, 1152, 0};
        }
        result = run_script(runs, 2 * changes + 1);
        free(runs);
    }
    return result;
}

int tmff_session_formcheck(char *out, size_t capacity) {
    av_log_set_level(AV_LOG_QUIET);
    out[0] = '\0';
    /* The rates, at the limit (16 to 1) and one step past it, both ways; and below, the changes at
       the limit (1,000) and one past it. The numbers are written out, so that changing the limits
       fails the checks rather than moving them. */
    formcheck_line(out, capacity, "ratio-up-16", run_ratio(8000, 8000 * 16));
    formcheck_line(out, capacity, "ratio-up-17", run_ratio(8000, 8000 * 17));
    formcheck_line(out, capacity, "ratio-down-16", run_ratio(8000 * 16, 8000));
    formcheck_line(out, capacity, "ratio-down-17", run_ratio(8000 * 17, 8000));
    /* A frame whose conversion would be 268 MB (65,535 frames at 48,000 Hz in 32 channels, to the
       first form's 768,000 Hz: 16 times as many): fed in slices, none of which holds more than the cap. */
    {
        const made_up_run runs[] = {
            {1, 768000, 32, AV_SAMPLE_FMT_FLTP, 16, 0},
            {1, 48000, 32, AV_SAMPLE_FMT_FLTP, 65535, 0},
        };
        formcheck_line(out, capacity, "cap", run_script(runs, 2));
    }
    /* Frames of 8 samples at twice the rate: each is held back whole by the resampler (it keeps up
       to 32 input samples), and every one of the 80 comes out in the end, as 40 frames. */
    {
        const made_up_run runs[] = {
            {1, 22050, 1, AV_SAMPLE_FMT_FLT, 1152, 0},
            {10, 44100, 1, AV_SAMPLE_FMT_FLT, 8, 0},
        };
        formcheck_line(out, capacity, "held-back", run_script(runs, 2));
    }
    /* The same number of channels in another layout (6.0 after 5.1: the back centre would land on
       the LFE) is another form, converted; the same layout again is not. */
    {
        const made_up_run same[] = {
            {1, 22050, 6, AV_SAMPLE_FMT_FLT, 1152, AV_CH_LAYOUT_5POINT1},
            {1, 22050, 6, AV_SAMPLE_FMT_FLT, 1152, AV_CH_LAYOUT_5POINT1},
        };
        formcheck_line(out, capacity, "layout-same", run_script(same, 2));
        const made_up_run other[] = {
            {1, 22050, 6, AV_SAMPLE_FMT_FLT, 1152, AV_CH_LAYOUT_5POINT1},
            {1, 22050, 6, AV_SAMPLE_FMT_FLT, 1152, AV_CH_LAYOUT_6POINT0},
        };
        formcheck_line(out, capacity, "layout-other", run_script(other, 2));
    }
    /* Refused sound, kept as silence (FU03). At 8,000 Hz, mono, in frames of 16 samples (2 ms): the
       sample of 900 refused packets between 100 and 400 good ones (flac-900-bad-packets.mka) has
       its stretch of 1.8 s filled to the next frame's start, 14,400 frames. */
    {
        const made_up_run runs[] = {
            {100, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 0, 0, 0},
            {400, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 2000000, 900, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-timed", run_script(runs, 2));
    }
    /* With no timestamps, the refused packets' own lengths are the gap: 3 of 2 ms and then 1
       of 2 ms are 8 ms, 64 frames. */
    {
        const made_up_run runs[] = {
            {2, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 0, 0, 0},
            {2, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 3, 2000, 0},
            {2, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 1, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-untimed", run_script(runs, 3));
    }
    /* Refused packets at the start and at the end of the sound are silence too: 2 before the
       first frame and 5 after the last, of 2 ms each (14 ms, 112 frames). */
    {
        const made_up_run runs[] = {
            {3, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 2, 2000, 5},
        };
        formcheck_line(out, capacity, "silence-ends", run_script(runs, 1));
    }
    /* A good file is never given silence, whatever its timestamps say: an hour between two
       frames, no packet refused. */
    {
        const made_up_run runs[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 3600000000, 0, 0, 0},
        };
        formcheck_line(out, capacity, "silence-none", run_script(runs, 2));
    }
    /* Past the bound, no silence is owed and the decode goes on, the gap closing as it did before
       FU03 (status 0): an hour of timestamp between two frames with a packet refused between them,
       against a bound of 10 s, gives the packet's own 2 ms (16 frames); a stretch of the bound
       itself is filled (10 s, 80,000 frames); a packet claiming a length past the ceiling owes
       none; and the bound is what the stretches add up to, not each one (6 s, then no more); a
       jump backward gives the packets' own lengths (3 of 2 ms, 48 frames); and a file of 10 KB,
       which holds 81.92 s at 1 kbit/s, is given the packet's own length instead of a gap of 100 s. */
    {
        const made_up_run hour[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 3600000000, 1, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-absurd", run_script_limited(hour, 2, 10000000, 0));
        const made_up_run exact[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 10002000, 1, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-at-bound", run_script_limited(exact, 2, 10000000, 0));
        const made_up_run claimed[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 1, INT64_MAX, 0},
        };
        formcheck_line(out, capacity, "silence-claimed", run_script(claimed, 2));
        const made_up_run sums[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 1, 6000000, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 0, 0, 1, 6000000, 0},
        };
        formcheck_line(out, capacity, "silence-sums", run_script_limited(sums, 3, 10000000, 0));
        const made_up_run backward[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 1000000, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 3, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-backward", run_script(backward, 2));
        const made_up_run sized[] = {
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 0, 0, 0, 0},
            {1, 8000, 1, AV_SAMPLE_FMT_S16, 16, 0, 1, 100002000, 1, 2000, 0},
        };
        formcheck_line(out, capacity, "silence-size", run_script_limited(sized, 2, 43200000000, 10240));
    }
    /* The most changes of form, and one more. */
    formcheck_line(out, capacity, "changes-1000", run_changes(1000));
    formcheck_line(out, capacity, "changes-1001", run_changes(1001));
    return TMFF_EXIT_DONE;
}
#endif /* DEBUG */
