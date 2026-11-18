/*
 * TextMouthFFmpegProtocol.h: the stream that TextMouth's FFmpeg session writes, in the one place
 * both sides read it (FMT50).
 *
 * The session (TextMouthFFmpegSession.h, beside this file) opens one audio file with FFmpeg and
 * turns it into this stream: what the file holds, its tags and chapters, and, when asked, its
 * sound as plain samples. On the Mac the helper program TextMouthFFmpeg runs the session and
 * writes the stream to its standard output, which the app reads (FFmpegHelperStream); the
 * iPhone, which starts no program, runs the same session inside the app and reads the same
 * records. The app imports this header as the Clang module TextMouthFFmpegProtocol
 * (module.modulemap beside it), so the two sides cannot disagree about the records, their
 * limits, or the exit statuses. A change to the stream is made here, with a new
 * TMFF_PROTOCOL_VERSION.
 *
 * Protocol 1 (November 16, 2026):
 *
 * - The stream is a sequence of records. Each record is an 8-byte header, its kind (four ASCII
 *   letters, below, read as one little-endian 32-bit number) and the length of its payload (a
 *   little-endian 32-bit number), then the payload. Every number in a payload is
 *   little-endian.
 * - The first record is HEAD: the protocol's version (32 bits), then FFmpeg's version as text.
 *   A reader refuses a stream whose first record is not HEAD of its own version, so an app and a
 *   session built from different sources fail by name, never by misreading.
 * - INFO describes the one sound stream the session chose (the first that the file marks as its
 *   default, else the first; only sound the build can decode counts): UTF-8 lines of
 *   "key=value", each ending in a line feed. Keys: format (the demuxer's name), codec (FFmpeg's
 *   name of the codec), stream (its index), streams, audio_streams, more_than_sound (1 when the
 *   file holds a stream other than sound and a cover picture), default (1 when the file marks it
 *   so), sample_rate, channels, channel_mask (the loudspeakers, as a WAVE channel mask; 0 when
 *   unknown), sample_format (s16, s32, or f32, as the PCM records hold it), bits (of each sample:
 *   1 to 16 for s16, 17 to 32 for s32, 32 for f32), and, when the file says them, duration
 *   (seconds, the stream's own), format_duration (the file's), bit_rate (the stream's, in bits
 *   a second), and format_bit_rate (the file's). In a decode the record comes after the first
 *   samples are decoded and describes them, which may differ from what the header says (an
 *   HE-AAC stream decodes at twice its header's rate).
 * - TAG and STAG are one tag of the file and of the chosen stream: its key, a zero byte, and
 *   its value, as FFmpeg gives them (UTF-8). A value is cut at TMFF_MAX_TAG_VALUE_BYTES, at a
 *   character's boundary, and at most TMFF_MAX_TAGS of each are written.
 * - CHAP is one chapter: its start and its end in seconds (64-bit floating point; the end is
 *   not a number when the file does not say), then its title (UTF-8, cut as a tag's value). At
 *   most TMFF_MAX_CHAPTERS are written.
 * - PCM holds samples, in whole frames, interleaved by channel, in INFO's sample_format: s16 is
 *   16-bit signed whole numbers, s32 32-bit signed whole numbers of `bits` bits (a 24-bit
 *   sample's value is from -8,388,608 to 8,388,607), and f32 32-bit floating point, from -1 to
 *   1. Only a decode writes them. Every PCM record has the one form INFO names, from the first to
 *   the last: sound whose rate, channels, or format change partway is converted to the first
 *   frame's form (the session's resampler), and END counts the frames of that form.
 * - END closes the stream: the frames written (64 bits), and how many packets and frames the
 *   decoder refused (32 bits each), which a damaged file shows as more than none.
 *
 * TAG, STAG, and CHAP records come after INFO and before any PCM record. Every record's payload
 * is at most TMFF_MAX_RECORD_BYTES, and a PCM record's at most TMFF_MAX_PCM_RECORD_BYTES.
 *
 * The helper's exit statuses are TMFF_EXIT_ below: TextMouth turns each into the sentence a
 * listener hears (FFmpegHelperStream.Failure). The session returns the same numbers.
 *
 * This file is TextMouth's own, under TextMouth's MIT License.
 */
#ifndef TEXTMOUTH_FFMPEG_PROTOCOL_H
#define TEXTMOUTH_FFMPEG_PROTOCOL_H

/* The protocol's version, the first number of the HEAD record. */
#define TMFF_PROTOCOL_VERSION 1u

/* The records' kinds: four ASCII letters read as one little-endian 32-bit number. */
#define TMFF_RECORD_HEAD 0x44414548u /* "HEAD" */
#define TMFF_RECORD_INFO 0x4F464E49u /* "INFO" */
#define TMFF_RECORD_TAG 0x20474154u  /* "TAG " */
#define TMFF_RECORD_STAG 0x47415453u /* "STAG" */
#define TMFF_RECORD_CHAP 0x50414843u /* "CHAP" */
#define TMFF_RECORD_PCM 0x204D4350u  /* "PCM " */
#define TMFF_RECORD_END 0x20444E45u  /* "END " */

/* The bytes of a record's header: its kind and its payload's length. */
#define TMFF_RECORD_HEADER_BYTES 8u

/* The most bytes of a record's payload, and of a PCM record's. */
#define TMFF_MAX_RECORD_BYTES 65536u
#define TMFF_MAX_PCM_RECORD_BYTES 1048576u

/* The most bytes of a tag's value or a chapter's title (each tag is capped at 4 KB, the TODO's
   FU-FFMPEG item), of a tag's key, and how many tags of the file, tags of the stream, and
   chapters are written. */
#define TMFF_MAX_TAG_VALUE_BYTES 4096u
#define TMFF_MAX_TAG_KEY_BYTES 256u
#define TMFF_MAX_TAGS 512u
#define TMFF_MAX_CHAPTERS 4096u

/* The highest sample rate, in hertz, and the most channels of sound a book is made of: 768 kHz,
   the highest any recording format writes, and 64. The session chooses no stream beyond them,
   and the app believes no report beyond them (FFmpegReport). Plain ints, as FFmpeg's fields are. */
#define TMFF_MAX_SAMPLE_RATE 768000
#define TMFF_MAX_CHANNELS 64

/* The helper's exit statuses, and the session's results. */
#define TMFF_EXIT_DONE 0             /* the stream is whole */
#define TMFF_EXIT_USAGE 1            /* the arguments are wrong */
#define TMFF_EXIT_UNREADABLE 2       /* the file cannot be opened, or is not a regular file */
#define TMFF_EXIT_NOT_RECOGNIZED 3   /* the demuxer refuses the file */
#define TMFF_EXIT_NO_SOUND 4         /* the file holds no sound stream */
#define TMFF_EXIT_NO_DECODER 5       /* its sound is in a codec this build does not decode */
#define TMFF_EXIT_DAMAGED 6          /* the decoder will not open, or decodes nothing */
#define TMFF_EXIT_FORM_CHANGED 7     /* the sound changes its rate, channels, or format partway, and cannot be converted to the first form */
#define TMFF_EXIT_OUTPUT 8           /* the stream cannot be written (the reader is gone) */
#define TMFF_EXIT_MEMORY 9           /* an allocation was refused */
#define TMFF_EXIT_NO_DEMUXER 10      /* this build has no demuxer of that name */
#define TMFF_EXIT_STOPPED 11         /* the session was told to stop */
#define TMFF_EXIT_NOT_CONFINED 12    /* the helper could not confine itself, so it read nothing */
#define TMFF_EXIT_FRAME_TOO_LARGE 13 /* one frame of the sound holds more samples than the session decodes at once */
#define TMFF_EXIT_CRASHED 70         /* a fatal signal (the helper ends itself, with no crash report) */
#define TMFF_EXIT_PROCESSOR_TIME 71  /* the processor time limit's signal, SIGXCPU */

/* The sample formats a PCM record can hold, as INFO's sample_format names them. */
#define TMFF_SAMPLE_FORMAT_S16 "s16"
#define TMFF_SAMPLE_FORMAT_S32 "s32"
#define TMFF_SAMPLE_FORMAT_F32 "f32"

/* The helper's two modes, its first argument: what the file holds, or that and its sound. */
#define TMFF_MODE_PROBE "probe"
#define TMFF_MODE_DECODE "decode"

/* A third mode, which only a Debug build of the helper has (a Release build answers it with
   TMFF_EXIT_USAGE): it confines itself as a run does, then tries what the confinement must
   refuse, and writes one line for each, "input=readable" (the file it opened is still read),
   "hosts=refused" (the system's hosts file is not opened), "socket=refused" (a network
   connection is not made), and "cpu=kept" (the processor features FFmpeg found before the
   confinement are still its belief), exiting TMFF_EXIT_DONE only when all four are so. */
#define TMFF_MODE_CONFINEMENT "confinement"

/* A fourth mode, which only a Debug build of the helper has (a Release build answers it with
   TMFF_EXIT_USAGE): it opens no file (its other two arguments are ignored) and writes one line
   for each check tmff_session_formcheck makes of the conversion of sound that changes its form. */
#define TMFF_MODE_FORMCHECK "formcheck"

/* A fifth mode, which only a Debug build of the helper has (a Release build answers it with
   TMFF_EXIT_USAGE, and carries none of its code): its second argument names a way to crash
   (TMFF_SIGNALCHECK_*), the helper opens no file, and then crashes that way. With its signal guard
   in place, each ends with TMFF_EXIT_CRASHED and no crash report; it is run only on GitHub's
   runners, where a failure puts no crash report in front of anyone (FU-FFMPEG2). */
#define TMFF_MODE_SIGNALCHECK "signalcheck"
#define TMFF_SIGNALCHECK_SEGFAULT "segfault"       /* a write through a null pointer */
#define TMFF_SIGNALCHECK_ABORT "abort"             /* abort() */
#define TMFF_SIGNALCHECK_OVERFLOW "overflow"       /* recursion until the stack is gone */
#define TMFF_SIGNALCHECK_DOUBLE_FREE "doublefree"  /* free() of the same memory twice */

#endif /* TEXTMOUTH_FFMPEG_PROTOCOL_H */
