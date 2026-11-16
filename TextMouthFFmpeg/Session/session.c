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
 * whose rate, channels, or format differ from the first frame's ends the stream
 * (TMFF_EXIT_FORM_CHANGED): no audiobook does that, and converting it would take a resampler.
 *
 * It uses only FFmpeg's documented public API (the headers' documentation, published at
 * https://ffmpeg.org/doxygen/); nothing of FFmpeg's own code is copied here. It grew from the
 * research harness (research/ffmpeg-minimal/harness.c), TextMouth's own.
 *
 * This file is TextMouth's own, under TextMouth's MIT License.
 */
#include <errno.h>
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
#include <libavutil/dict.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>

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

/* About how many bytes of samples one PCM record holds: a quarter of a megabyte, a second and a
   half of 44.1 kHz stereo in 32 bits, small for the pipe and few records a book. */
enum { PCM_RECORD_TARGET = 256 * 1024 };

/* The most memory FFmpeg may ask for at once: far more than any audio frame or index needs. */
#define MAX_ALLOCATION_BYTES (256u * 1024u * 1024u)

/* The loudspeakers a WAVE channel mask names (its bits 0 to 17), which FFmpeg's native order
   names with the same bits; a layout with any other bit is sent as unknown. */
#define WAVE_CHANNEL_BITS 0x3FFFFull

/* The most errors in a row the decoder may give without a frame between: past them the file is
   damaged, rather than a decoder that answers every call with an error being asked for ever. */
enum { MAX_ERRORS_IN_A_ROW = 1000 };

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
    /* Set by tmff_session_stop from any thread; read by FFmpeg's interrupt callback. */
    atomic_int stopped;

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
    int have_frame;                 /* a decoded frame waits in `frame`, from `frame_position` on */
    int frame_position;             /* the first of its frames not yet written */

    /* The decoder's progress. */
    int demuxer_ended;
    int decoder_ended;
    uint64_t frames_written;
    uint32_t packet_errors;
    uint32_t frame_errors;

    /* The record being given, header and payload. */
    unsigned char *record;
    size_t record_length;
    size_t record_capacity;
};

/* ---------------------------------------------------------------------------------------------
 * The file, through FFmpeg's I/O callbacks
 * ------------------------------------------------------------------------------------------- */

/* FFmpeg's read callback: up to `capacity` bytes of the file; the bytes read, AVERROR_EOF at
   its end, or AVERROR(EIO). */
static int read_file(void *opaque, uint8_t *buffer, int capacity) {
    tmff_session *session = opaque;
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
   AVERROR. */
static int64_t seek_file(void *opaque, int64_t offset, int whence) {
    tmff_session *session = opaque;
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

/* FFmpeg's interrupt callback, asked during long reads: nonzero once the session must stop. */
static int interrupted(void *opaque) {
    tmff_session *session = opaque;
    return atomic_load(&session->stopped);
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

/* Whether `stream` is sound a book could be made of: audio, not a cover picture, with a rate
   and channels a real file has. */
static int is_usable_sound(const AVStream *stream) {
    const AVCodecParameters *parameters = stream->codecpar;
    return parameters->codec_type == AVMEDIA_TYPE_AUDIO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
        && parameters->sample_rate > 0 && parameters->sample_rate <= TMFF_MAX_SAMPLE_RATE
        && parameters->ch_layout.nb_channels > 0 && parameters->ch_layout.nb_channels <= TMFF_MAX_CHANNELS;
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
    const int error = avcodec_open2(session->decoder, codec, NULL);
    if (error < 0) {
        return error == AVERROR(ENOMEM) ? TMFF_EXIT_MEMORY : TMFF_EXIT_DAMAGED;
    }
    return 0;
}

tmff_session *tmff_session_open(int descriptor, const char *demuxer_name, tmff_session_mode mode, int *status) {
    int failure = TMFF_EXIT_MEMORY;
    unsigned char *buffer = NULL;
    av_log_set_level(AV_LOG_QUIET);
    av_max_alloc(MAX_ALLOCATION_BYTES);

    tmff_session *session = calloc(1, sizeof *session);
    if (!session) {
        goto failed;
    }
    session->mode = mode;
    session->descriptor = descriptor;
    session->stream_index = -1;
    session->stage = STAGE_HEAD;
    atomic_init(&session->stopped, 0);

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
    if (!session->packet || !session->frame) {
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

/* Takes the next decoded frame into session->frame. Returns 1 when a frame is there, 0 when the
   decoder has given its last, or a negative TMFF_EXIT_ number. A packet or frame the decoder
   refuses is counted and skipped, as a damaged packet would be, up to MAX_ERRORS_IN_A_ROW in a
   row (TMFF_EXIT_DAMAGED past them). */
static int next_frame(tmff_session *session) {
    int errors_in_a_row = 0;
    for (;;) {
        if (atomic_load(&session->stopped)) {
            return -TMFF_EXIT_STOPPED;
        }
        if (session->decoder_ended) {
            return 0;
        }
        const int received = avcodec_receive_frame(session->decoder, session->frame);
        if (received == 0) {
            return 1;
        }
        if (received == AVERROR_EOF) {
            session->decoder_ended = 1;
            return 0;
        }
        if (received == AVERROR(ENOMEM)) {
            return -TMFF_EXIT_MEMORY;
        }
        if (received != AVERROR(EAGAIN)) {
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
            return 0;
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
                return 0;
            }
            continue;
        }
        if (session->packet->stream_index == session->stream_index) {
            const int sent = avcodec_send_packet(session->decoder, session->packet);
            if (sent == AVERROR(ENOMEM)) {
                av_packet_unref(session->packet);
                return -TMFF_EXIT_MEMORY;
            }
            if (sent < 0 && sent != AVERROR(EAGAIN)) {
                session->packet_errors++;
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

/* Whether `frame` has the first frame's rate, channels, and format, as every frame must. */
static int has_the_first_form(const tmff_session *session, const AVFrame *frame) {
    return frame->sample_rate == session->sample_rate && frame->ch_layout.nb_channels == session->channels
        && frame->format == session->frame_format;
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
    const AVFrame *frame = session->frame;
    if (frame->sample_rate <= 0 || frame->sample_rate > TMFF_MAX_SAMPLE_RATE || frame->ch_layout.nb_channels <= 0
        || frame->ch_layout.nb_channels > TMFF_MAX_CHANNELS) {
        return TMFF_EXIT_DAMAGED;
    }
    session->sample_rate = frame->sample_rate;
    session->channels = frame->ch_layout.nb_channels;
    session->channel_mask = wave_mask(&frame->ch_layout, session->channels);
    settle_form(session, frame->format, session->decoder->bits_per_raw_sample);
    session->have_frame = 1;
    session->frame_position = 0;
    return 0;
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
            const int found = next_frame(session);
            if (found < 0) {
                return found;
            }
            if (found == 0) {
                break;
            }
            if (!has_the_first_form(session, session->frame)) {
                av_frame_unref(session->frame);
                return -TMFF_EXIT_FORM_CHANGED;
            }
            session->have_frame = 1;
            session->frame_position = 0;
        }
        const AVFrame *frame = session->frame;
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
            av_frame_unref(session->frame);
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
    if (atomic_load(&session->stopped)) {
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
