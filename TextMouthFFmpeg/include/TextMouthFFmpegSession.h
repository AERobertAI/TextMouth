/*
 * TextMouthFFmpegSession.h: one audio file read with FFmpeg, as the records of
 * TextMouthFFmpegProtocol.h (FMT50).
 *
 * The session is TextMouth's own C around FFmpeg's public API, built into the FFmpeg library
 * targets (FFmpeg for the Mac, FFmpeg_iOS for the iPhone; project.yml). The Mac's helper program
 * (TextMouthFFmpeg/main.c) runs it and writes its records to standard output; the iPhone, which
 * can start no program, calls it inside the app (the Swift module TextMouthFFmpegSession,
 * module.modulemap beside this file), one record a call on a thread of its own, each call within
 * a time limit that its stop check carries in (FMT54). No FFmpeg type appears here, so the app's
 * Swift needs none of FFmpeg's headers.
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

/* The most FFmpeg may allocate at once (av_max_alloc), 256 MB: far more than any audio frame or
   index needs, and what every session allows unless tmff_set_allocation_cap lowers it. */
#define TMFF_MAX_ALLOCATION_BYTES 268435456u

/* Sets the most FFmpeg may allocate at once, from now on, for every session of the process: `bytes`,
   or TMFF_MAX_ALLOCATION_BYTES for 0 or more than that. FFmpeg's cap is the process's alone, so the
   iPhone, whose runs' calls take turns on one thread, sets its run's before each call (FMT54); the
   Mac's helper, one session a process, never sets it. */
void tmff_set_allocation_cap(size_t bytes);

/* Opens `path` for reading as a session reads its file: a regular file only (a symbolic link is
   refused, by O_NOFOLLOW), opened without blocking, so that a FIFO or a device is never waited on,
   then checked, then made blocking for the reads, and closed on exec. Returns the descriptor, or
   -1. The Mac's helper opens its file so before it confines itself, and the iPhone's import
   before it opens a session in the app (FMT54). */
int tmff_open_regular_file(const char *path);

/* A check a session asks before every read and seek of its file, before each of its steps, and
   at FFmpeg's own checkpoints through the session's interrupt callback: nonzero to stop, 0 to go
   on. `context` is what the check was set with.
   The iPhone gives each engine call one (SessionStopCheck), which turns to stop once the call's
   time is spent, its import is cancelled, or the app has less memory left than its floor. */
typedef int (*tmff_stop_check)(void *context);

/* Opens the file read from `descriptor` (open for reading, a regular file; it stays the
   caller's to close, after tmff_session_close) with the demuxer named `demuxer`, and chooses
   its sound stream. Returns the session, or NULL with *status set to a TMFF_EXIT_ number. */
tmff_session *tmff_session_open(int descriptor, const char *demuxer, tmff_session_mode mode, int *status);

/* tmff_session_open, asking `check` with `context` too while it opens the file (NULL: no check,
   as tmff_session_open asks none); a check that says stop ends the open with TMFF_EXIT_STOPPED.
   The session keeps asking it afterwards, until tmff_session_set_stop_check changes it. */
tmff_session *tmff_session_open_checked(int descriptor, const char *demuxer, tmff_session_mode mode,
                                        tmff_stop_check check, void *context, int *status);

/* Sets the check the session asks from now on, with `context` (NULL: none, as after
   tmff_session_open): the session asks it before every read and seek of the file and before each
   step, and FFmpeg's interrupt callback at FFmpeg's own checkpoints, besides tmff_session_stop's
   flag. Once it has said stop, the session stays
   stopped, as after tmff_session_stop. Set it on the thread that calls tmff_session_next, between
   two calls, never during one. NULL is allowed for `session`, and does nothing. */
void tmff_session_set_stop_check(tmff_session *session, tmff_stop_check check, void *context);

/* The next record of the stream, header and payload: *bytes points at it until the next call,
   and *length is its length. Returns TMFF_EXIT_DONE, with *length 0 once END has been given, or
   another TMFF_EXIT_ number, after which the stream is over. */
int tmff_session_next(tmff_session *session, const unsigned char **bytes, size_t *length);

/* Asks a session to stop, from any thread: FFmpeg's reading ends at its next read, and the
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
