/*
 * harness.c: the open-and-decode path of an FFmpeg built into a program, for
 * measuring what FFmpeg's libraries add to it. Research only
 * (research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md): nothing in TextMouth
 * builds or runs it. build.py, beside it, compiles it twice.
 *
 * Usage: harness DEMUXER INPUT OUTPUT
 *
 * With FFmpeg, it reads INPUT with the demuxer DEMUXER forced, as TextMouth's
 * import forces one from its own sniff of the first bytes (FFmpegContainer).
 * FFmpeg reads the file only through this program's own callbacks (custom
 * I/O), so no FFmpeg protocol is compiled in and no path or URL reaches
 * FFmpeg at all. It decodes the best audio stream to its end, writes the
 * samples to OUTPUT interleaved in the decoder's own sample format, and
 * prints one line of JSON: the demuxer, the decoder, the sample format, the
 * rate, the channels, the samples, the chapters, and the tags. The chapters
 * and tags are what TextMouth's conversion keeps today with -map_chapters
 * and -map_metadata.
 *
 * Compiled with -DHARNESS_BASELINE, it reads INPUT the same way with no
 * FFmpeg call at all: the difference in size between the two programs is
 * what FFmpeg adds.
 *
 * It uses only FFmpeg's documented public API (the headers' documentation,
 * published at https://ffmpeg.org/doxygen/); nothing of FFmpeg's own code
 * is copied here.
 *
 * It must never end in a crash report on the Mac it runs on, so every
 * signal that would end it with one ends it with _exit instead, on a stack
 * of its own, and a run longer than a minute ends itself the same way.
 */

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef HARNESS_BASELINE
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#endif

/* The most seconds one run may take before it ends itself. */
enum { RUN_SECONDS = 60 };

/* The bytes of each read FFmpeg asks the callbacks for, and of the baseline's reads. */
enum { READ_BUFFER_BYTES = 64 * 1024 };

/* The exit statuses: a fatal signal, and the time limit. */
enum { EXIT_SIGNAL = 70, EXIT_TIME_LIMIT = 71 };

/* The stack the signal handler runs on, so that even a stack overflow ends
   in _exit rather than in a crash report. */
static char alternate_stack[64 * 1024];

/* Ends the process at once, with no crash report: on a fatal signal with
   EXIT_SIGNAL, and at the time limit (SIGALRM) with EXIT_TIME_LIMIT. Only
   async-signal-safe calls (write and _exit) are made here. */
static void end_on_signal(int signal_number) {
    static const char message[] = "harness: stopped by a signal\n";
    ssize_t ignored = write(STDERR_FILENO, message, sizeof message - 1);
    (void)ignored;
    _exit(signal_number == SIGALRM ? EXIT_TIME_LIMIT : EXIT_SIGNAL);
}

/* Installs end_on_signal, on its own stack, for every signal that would
   otherwise end the process with a crash report, and starts the time limit. */
static void install_guards(void) {
    stack_t stack;
    memset(&stack, 0, sizeof stack);
    stack.ss_sp = alternate_stack;
    stack.ss_size = sizeof alternate_stack;
    if (sigaltstack(&stack, NULL) != 0) {
        perror("harness: sigaltstack");
    }
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = end_on_signal;
    action.sa_flags = SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS, SIGALRM};
    for (size_t index = 0; index < sizeof signals / sizeof signals[0]; index++) {
        sigaction(signals[index], &action, NULL);
    }
    alarm(RUN_SECONDS);
}

/* Prints `text` as a JSON string: quotation marks, backslashes, and control
   characters escaped, every other byte (UTF-8 included) as it is. */
static void print_json_string(FILE *out, const char *text) {
    fputc('"', out);
    for (const unsigned char *byte = (const unsigned char *)(text ? text : ""); *byte; byte++) {
        if (*byte == '"' || *byte == '\\') {
            fprintf(out, "\\%c", *byte);
        } else if (*byte < 0x20) {
            fprintf(out, "\\u%04x", *byte);
        } else {
            fputc(*byte, out);
        }
    }
    fputc('"', out);
}

/* The size of the open file `file` in bytes, leaving it at its start; -1
   when it cannot be told. */
static int64_t file_size(FILE *file) {
    if (fseeko(file, 0, SEEK_END) != 0) {
        return -1;
    }
    const off_t size = ftello(file);
    if (fseeko(file, 0, SEEK_SET) != 0) {
        return -1;
    }
    return (int64_t)size;
}

#ifdef HARNESS_BASELINE

/* The baseline: reads all of `input_path` in reads of READ_BUFFER_BYTES,
   creates `output_path` empty, and prints what it read. Returns the exit
   status. */
static int run(const char *demuxer_name, const char *input_path, const char *output_path) {
    FILE *input = fopen(input_path, "rb");
    if (!input) {
        perror("harness: input");
        return 1;
    }
    FILE *output = fopen(output_path, "wb");
    if (!output) {
        perror("harness: output");
        fclose(input);
        return 1;
    }
    /* A buffer from the heap, as the FFmpeg path's is, so the two programs
       differ only by FFmpeg. */
    unsigned char *buffer = malloc(READ_BUFFER_BYTES);
    if (!buffer) {
        fclose(output);
        fclose(input);
        return 1;
    }
    int64_t total = 0;
    size_t count;
    while ((count = fread(buffer, 1, READ_BUFFER_BYTES, input)) > 0) {
        total += (int64_t)count;
    }
    const int64_t size = file_size(input);
    printf("{\"baseline\": true, \"demuxer\": ");
    print_json_string(stdout, demuxer_name);
    printf(", \"bytes_read\": %lld, \"size\": %lld}\n", (long long)total, (long long)size);
    free(buffer);
    fclose(output);
    fclose(input);
    return 0;
}

#else

/* The file FFmpeg reads through the callbacks below, and its size. */
typedef struct {
    FILE *file;
    int64_t size;
} Source;

/* FFmpeg's read callback: fills `buffer` with up to `capacity` bytes of the
   source; the bytes read, AVERROR_EOF at the end, or AVERROR(EIO). */
static int read_source(void *opaque, uint8_t *buffer, int capacity) {
    Source *source = opaque;
    if (capacity <= 0) {
        return AVERROR(EINVAL);
    }
    const size_t count = fread(buffer, 1, (size_t)capacity, source->file);
    if (count == 0) {
        return ferror(source->file) ? AVERROR(EIO) : AVERROR_EOF;
    }
    return (int)count;
}

/* FFmpeg's seek callback: moves to `offset` as `whence` says (SEEK_SET,
   SEEK_CUR, or SEEK_END, maybe with AVSEEK_FORCE), or answers the size for
   AVSEEK_SIZE; the new position, or a negative AVERROR. */
static int64_t seek_source(void *opaque, int64_t offset, int whence) {
    Source *source = opaque;
    if (whence & AVSEEK_SIZE) {
        return source->size >= 0 ? source->size : AVERROR(ENOSYS);
    }
    whence &= ~AVSEEK_FORCE;
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) {
        return AVERROR(EINVAL);
    }
    if (fseeko(source->file, (off_t)offset, whence) != 0) {
        return AVERROR(EIO);
    }
    return (int64_t)ftello(source->file);
}

/* What was decoded: the first frame's format, rate, and channels (once
   `have_format` says a frame came), how many samples, and what went wrong
   along the way. */
typedef struct {
    int have_format;
    int sample_format;
    int sample_rate;
    int channels;
    int64_t samples;
    int format_changes;
    int packet_errors;
    int frame_errors;
} Decoded;

/* Writes `frame`'s samples to `output`, interleaved, each in the frame's own
   sample format. Returns 0, or -1 when the frame is malformed or a write
   fails. */
static int write_samples(FILE *output, const AVFrame *frame) {
    const int bytes = av_get_bytes_per_sample((enum AVSampleFormat)frame->format);
    const int channels = frame->ch_layout.nb_channels;
    if (bytes <= 0 || channels <= 0 || frame->nb_samples < 0 || !frame->extended_data) {
        return -1;
    }
    if (!av_sample_fmt_is_planar((enum AVSampleFormat)frame->format)) {
        const size_t length = (size_t)frame->nb_samples * (size_t)channels * (size_t)bytes;
        return fwrite(frame->extended_data[0], 1, length, output) == length ? 0 : -1;
    }
    for (int sample = 0; sample < frame->nb_samples; sample++) {
        for (int channel = 0; channel < channels; channel++) {
            const uint8_t *start = frame->extended_data[channel] + (size_t)sample * (size_t)bytes;
            if (fwrite(start, 1, (size_t)bytes, output) != (size_t)bytes) {
                return -1;
            }
        }
    }
    return 0;
}

/* Takes every frame `context` has ready into `frame`, writing each to
   `output` and counting it in `decoded`. Returns 0 when the decoder wants
   more input or has ended, or -1 when a write fails. */
static int take_frames(AVCodecContext *context, AVFrame *frame, FILE *output, Decoded *decoded) {
    for (;;) {
        const int error = avcodec_receive_frame(context, frame);
        if (error == AVERROR(EAGAIN) || error == AVERROR_EOF) {
            return 0;
        }
        if (error < 0) {
            decoded->frame_errors++;
            return 0;
        }
        if (!decoded->have_format) {
            decoded->have_format = 1;
            decoded->sample_format = frame->format;
            decoded->sample_rate = frame->sample_rate;
            decoded->channels = frame->ch_layout.nb_channels;
        } else if (frame->format != decoded->sample_format || frame->ch_layout.nb_channels != decoded->channels) {
            decoded->format_changes++;
        }
        const int written = write_samples(output, frame);
        decoded->samples += frame->nb_samples;
        av_frame_unref(frame);
        if (written != 0) {
            return -1;
        }
    }
}

/* Prints `dictionary`'s entries as the members of a JSON object, each key
   prefixed with `prefix`, after a comma when `*first` is false. */
static void print_tags(const AVDictionary *dictionary, const char *prefix, int *first) {
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_get(dictionary, "", entry, AV_DICT_IGNORE_SUFFIX))) {
        if (!*first) {
            printf(", ");
        }
        *first = 0;
        printf("\"%s", prefix);
        /* The key, escaped, without print_json_string's own quotation marks. */
        for (const unsigned char *byte = (const unsigned char *)entry->key; *byte; byte++) {
            if (*byte == '"' || *byte == '\\' || *byte < 0x20) {
                putchar('_');
            } else {
                putchar(*byte);
            }
        }
        printf("\": ");
        print_json_string(stdout, entry->value);
    }
}

/* Prints the one line of JSON that says what was read and decoded. */
static void print_summary(const AVFormatContext *format, const AVCodec *decoder, int stream_index,
                          const Decoded *decoded) {
    printf("{\"demuxer\": ");
    print_json_string(stdout, format->iformat ? format->iformat->name : "");
    printf(", \"decoder\": ");
    print_json_string(stdout, decoder->name);
    printf(", \"streams\": %u, \"stream\": %d, \"sample_format\": ", format->nb_streams, stream_index);
    print_json_string(stdout, av_get_sample_fmt_name((enum AVSampleFormat)decoded->sample_format));
    printf(", \"sample_rate\": %d, \"channels\": %d, \"samples\": %lld", decoded->sample_rate, decoded->channels,
           (long long)decoded->samples);
    printf(", \"format_changes\": %d, \"packet_errors\": %d, \"frame_errors\": %d", decoded->format_changes,
           decoded->packet_errors, decoded->frame_errors);
    printf(", \"chapters\": [");
    for (unsigned int index = 0; index < format->nb_chapters; index++) {
        const AVChapter *chapter = format->chapters[index];
        const AVDictionaryEntry *title = av_dict_get(chapter->metadata, "title", NULL, 0);
        printf("%s{\"start\": %.3f, \"title\": ", index ? ", " : "", (double)chapter->start * av_q2d(chapter->time_base));
        print_json_string(stdout, title ? title->value : "");
        printf("}");
    }
    printf("], \"tags\": {");
    int first = 1;
    print_tags(format->metadata, "", &first);
    print_tags(format->streams[stream_index]->metadata, "stream:", &first);
    printf("}}\n");
}

/* Opens `input_path` with the demuxer named `demuxer_name`, decodes its best
   audio stream to `output_path`, and prints the summary. Returns the exit
   status: 0, or 1 when anything fails. */
static int run(const char *demuxer_name, const char *input_path, const char *output_path) {
    int status = 1;
    Source source = {NULL, -1};
    FILE *output = NULL;
    unsigned char *buffer = NULL;
    AVIOContext *io = NULL;
    AVFormatContext *format = NULL;
    AVCodecContext *context = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    Decoded decoded;
    memset(&decoded, 0, sizeof decoded);
    decoded.sample_format = AV_SAMPLE_FMT_NONE;

    /* Nothing of FFmpeg's chatter but its errors, and no single allocation
       over 256 MB, far more than any audio frame or index needs. */
    av_log_set_level(AV_LOG_ERROR);
    av_max_alloc(256u * 1024u * 1024u);

    const AVInputFormat *demuxer = av_find_input_format(demuxer_name);
    if (!demuxer) {
        fprintf(stderr, "harness: no demuxer named %s in this build\n", demuxer_name);
        goto done;
    }
    source.file = fopen(input_path, "rb");
    if (!source.file) {
        perror("harness: input");
        goto done;
    }
    source.size = file_size(source.file);
    output = fopen(output_path, "wb");
    if (!output) {
        perror("harness: output");
        goto done;
    }

    /* FFmpeg reads through read_source and seek_source; the buffer becomes
       the I/O context's, which may replace it, so it is freed through the
       context below. */
    buffer = av_malloc(READ_BUFFER_BYTES);
    if (!buffer) {
        goto done;
    }
    io = avio_alloc_context(buffer, READ_BUFFER_BYTES, 0, &source, read_source, NULL, seek_source);
    if (!io) {
        av_free(buffer);
        goto done;
    }
    format = avformat_alloc_context();
    if (!format) {
        goto done;
    }
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;

    /* On a failure avformat_open_input frees the context and sets it to NULL;
       the I/O context stays this program's to free. */
    int error = avformat_open_input(&format, NULL, demuxer, NULL);
    if (error < 0) {
        fprintf(stderr, "harness: the demuxer refused the file (%s)\n", av_err2str(error));
        goto done;
    }
    error = avformat_find_stream_info(format, NULL);
    if (error < 0) {
        fprintf(stderr, "harness: no stream information (%s)\n", av_err2str(error));
        goto done;
    }
    const AVCodec *decoder = NULL;
    const int stream_index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    if (stream_index < 0 || !decoder) {
        fprintf(stderr, "harness: no audio stream this build decodes (%s)\n", av_err2str(stream_index));
        goto done;
    }
    const AVStream *stream = format->streams[stream_index];
    context = avcodec_alloc_context3(decoder);
    if (!context) {
        goto done;
    }
    error = avcodec_parameters_to_context(context, stream->codecpar);
    if (error < 0) {
        goto done;
    }
    context->pkt_timebase = stream->time_base;
    error = avcodec_open2(context, decoder, NULL);
    if (error < 0) {
        fprintf(stderr, "harness: the decoder would not open (%s)\n", av_err2str(error));
        goto done;
    }
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!packet || !frame) {
        goto done;
    }

    /* Every packet of the chosen stream goes to the decoder, and every
       frame it gives back to the output; a packet it refuses is counted and
       skipped, as a damaged packet would be. Then the decoder is drained. */
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream_index) {
            if (avcodec_send_packet(context, packet) < 0) {
                decoded.packet_errors++;
            }
            if (take_frames(context, frame, output, &decoded) != 0) {
                av_packet_unref(packet);
                goto done;
            }
        }
        av_packet_unref(packet);
    }
    if (avcodec_send_packet(context, NULL) >= 0 && take_frames(context, frame, output, &decoded) != 0) {
        goto done;
    }
    print_summary(format, decoder, stream_index, &decoded);
    status = 0;

done:
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    avformat_close_input(&format);
    if (io) {
        av_freep(&io->buffer);
        avio_context_free(&io);
    }
    if (output && fclose(output) != 0) {
        status = 1;
    }
    if (source.file) {
        fclose(source.file);
    }
    return status;
}

#endif

/* Reads the three arguments and runs, under the guards. */
int main(int argc, char **argv) {
    install_guards();
    if (argc != 4) {
        fprintf(stderr, "usage: harness DEMUXER INPUT OUTPUT\n");
        return 2;
    }
    return run(argv[1], argv[2], argv[3]);
}
