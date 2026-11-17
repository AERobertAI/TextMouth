/*
 * TextMouthFFmpegSession.h: one audio file read with FFmpeg, as the records of
 * TextMouthFFmpegProtocol.h (FMT50).
 *
 * The session is TextMouth's own C around FFmpeg's public API, built into the FFmpeg library
 * targets (FFmpeg for the Mac, FFmpeg_iOS for the iPhone; project.yml). The Mac's helper program
 * (TextMouthFFmpeg/main.c) runs it and writes its records to standard output; the iPhone, which
 * can start no program, calls it inside the app (the Swift module TextMouthFFmpegSession,
 * module.modulemap beside this file). No FFmpeg type appears here, so the app's Swift needs none
 * of FFmpeg's headers.
 *
 * How it reads: FFmpeg reads the file only through the session's own callbacks on the
 * descriptor it is given, so no FFmpeg protocol is compiled in and no path or address reaches
 * FFmpeg at all; the demuxer is named by TextMouth's own sniff of the first bytes
 * (FFmpegContainer), so FFmpeg never guesses a format; no single allocation may pass 256 MB;
 * and FFmpeg's log is silent.
 *
 * This file is TextMouth's own, under TextMouth's MIT License.
 */
#ifndef TEXTMOUTH_FFMPEG_SESSION_H
#define TEXTMOUTH_FFMPEG_SESSION_H

#include <stddef.h>

/* An open session: the file, FFmpeg's state, and where the stream has got to. */
typedef struct tmff_session tmff_session;

/* What a session is asked for: what the file holds (HEAD, INFO, tags, chapters, END), or that
   and its sound (PCM records before END). */
typedef enum {
    TMFF_SESSION_PROBE = 0,
    TMFF_SESSION_DECODE = 1,
} tmff_session_mode;

/* Does, once, what FFmpeg asks the system for and remembers, before the process confines itself
   (main.c: the pure-computation sandbox refuses the system's sysctl, which FFmpeg's detection of
   the processor's features reads: asked afterwards it finds fewer, and decodes with slower
   code). Returns the features found, a nonzero number on this build's processors. Calling it
   again is harmless. */
int tmff_session_prepare(void);

/* The processor features FFmpeg now believes in: what tmff_session_prepare found when it came
   first, and what a confined process still reports (the Debug confinement check compares). */
int tmff_session_cpu_features(void);

/* Opens the file read from `descriptor` (open for reading, a regular file; it stays the
   caller's to close, after tmff_session_close) with the demuxer named `demuxer`, and chooses
   its sound stream. Returns the session, or NULL with *status set to a TMFF_EXIT_ number. */
tmff_session *tmff_session_open(int descriptor, const char *demuxer, tmff_session_mode mode, int *status);

/* The next record of the stream, header and payload: *bytes points at it until the next call,
   and *length is its length. Returns TMFF_EXIT_DONE, with *length 0 once END has been given, or
   another TMFF_EXIT_ number, after which the stream is over. */
int tmff_session_next(tmff_session *session, const unsigned char **bytes, size_t *length);

/* Asks a session to stop, from any thread: FFmpeg's reading ends at its next look, and the
   next call of tmff_session_next returns TMFF_EXIT_STOPPED. */
void tmff_session_stop(tmff_session *session);

/* Frees the session and everything FFmpeg holds for it (not the descriptor). NULL is allowed. */
void tmff_session_close(tmff_session *session);

#ifdef DEBUG
/* Debug builds only (TMFF_MODE_FORMCHECK): runs the checks of the session's conversion of sound
   that changes its form, on frames made up in memory (no file, no decoder, nothing from outside),
   and writes one line for each into `out` (of `capacity` bytes): "name=status frames=N largest=B
   changes=C", the status being the TMFF_EXIT_ number it ended with, N the frames it wrote, B the most
   bytes one frame it wrote held, and C the resamplers it opened. Returns TMFF_EXIT_DONE. */
int tmff_session_formcheck(char *out, size_t capacity);
#endif

#endif /* TEXTMOUTH_FFMPEG_SESSION_H */
