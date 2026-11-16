/*
 * TextMouthFFmpeg: the helper that runs FFmpeg for TextMouth's import on the Mac (FMT50).
 *
 * FFmpeg is C that reads files TextMouth cannot trust, and it has had memory-safety bugs, so the
 * Mac app never runs it in its own process (the app is not sandboxed). It runs this small
 * program instead, one run per file, under its watchdog (WatchedProcess: a time limit, a memory
 * limit, a stall limit, an output cap, and the import's Stop): a hang or a crash in FFmpeg costs
 * one run of this helper, never the app. FFmpegHelperStream in the app is its only caller.
 *
 * Usage:
 *   TextMouthFFmpeg probe  <demuxer> <file>
 *   TextMouthFFmpeg decode <demuxer> <file>
 *
 * It opens <file> with the demuxer named <demuxer> (TextMouth's own sniff names it:
 * FFmpegContainer.demuxer) and writes to its standard output the stream that
 * include/TextMouthFFmpegProtocol.h defines, the one place the app reads it from too: what the
 * file's sound stream is, its tags and chapters, and, for `decode`, its samples. The work is the
 * session's (Session/session.c, in the FFmpeg library target), which the iPhone calls inside its
 * own app instead.
 *
 * Exit status: the TMFF_EXIT_ numbers of TextMouthFFmpegProtocol.h. Nothing is printed but the
 * stream; FFmpeg's own log is silenced, and the app discards standard error.
 *
 * It must never end in a crash report, which on the Mac puts a dialog on the user's screen: every
 * signal that would end it with one ends it with _exit instead, on a stack of its own so that a
 * stack overflow does too (TMFF_EXIT_CRASHED), and the processor-time limit's SIGXCPU the same
 * way (TMFF_EXIT_PROCESSOR_TIME). A broken pipe (the app stopped reading) is an ordinary failed
 * write (TMFF_EXIT_OUTPUT).
 *
 * This file is TextMouth's own, under TextMouth's MIT License. It calls only the session's API
 * (include/TextMouthFFmpegSession.h), which calls FFmpeg's public API.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "include/TextMouthFFmpegProtocol.h"
#include "include/TextMouthFFmpegSession.h"

/* The stack the signal handler runs on, so that even a stack overflow ends in _exit. */
static char alternate_stack[64 * 1024];

/* Ends the process at once, with no crash report: TMFF_EXIT_PROCESSOR_TIME on SIGXCPU, and
   TMFF_EXIT_CRASHED on any other fatal signal. Only _exit, which is async-signal-safe, runs. */
static void end_on_signal(int signal_number) {
    _exit(signal_number == SIGXCPU ? TMFF_EXIT_PROCESSOR_TIME : TMFF_EXIT_CRASHED);
}

/* Installs end_on_signal, on its own stack, for every signal that would otherwise end the
   process with a crash report or a core, and ignores SIGPIPE, so a write to a closed pipe
   fails with EPIPE. */
static void install_guards(void) {
    stack_t stack;
    memset(&stack, 0, sizeof stack);
    stack.ss_sp = alternate_stack;
    stack.ss_size = sizeof alternate_stack;
    (void)sigaltstack(&stack, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = end_on_signal;
    action.sa_flags = SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    const int fatal[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS, SIGXCPU};
    for (size_t index = 0; index < sizeof fatal / sizeof fatal[0]; index++) {
        (void)sigaction(fatal[index], &action, NULL);
    }
    signal(SIGPIPE, SIG_IGN);
}

/* Writes all `length` bytes of `bytes` to standard output; 0, or -1 when the write fails. */
static int write_all(const unsigned char *bytes, size_t length) {
    while (length > 0) {
        const ssize_t written = write(STDOUT_FILENO, bytes, length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        bytes += written;
        length -= (size_t)written;
    }
    return 0;
}

/* Opens `path` for reading, refusing anything but a regular file: opened without blocking, so
   a FIFO or a device is never waited on, then checked, then made blocking for the reads.
   Returns the descriptor, or -1. */
static int open_regular_file(const char *path) {
    const int descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
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

/* Reads the arguments, runs the session, and writes its records. Returns the exit status. */
int main(int argc, char **argv) {
    install_guards();
    if (argc != 4) {
        return TMFF_EXIT_USAGE;
    }
    tmff_session_mode mode;
    if (strcmp(argv[1], TMFF_MODE_PROBE) == 0) {
        mode = TMFF_SESSION_PROBE;
    } else if (strcmp(argv[1], TMFF_MODE_DECODE) == 0) {
        mode = TMFF_SESSION_DECODE;
    } else {
        return TMFF_EXIT_USAGE;
    }
    const int descriptor = open_regular_file(argv[3]);
    if (descriptor < 0) {
        return TMFF_EXIT_UNREADABLE;
    }
    int status = TMFF_EXIT_DONE;
    tmff_session *session = tmff_session_open(descriptor, argv[2], mode, &status);
    if (!session) {
        close(descriptor);
        return status;
    }
    for (;;) {
        const unsigned char *bytes = NULL;
        size_t length = 0;
        status = tmff_session_next(session, &bytes, &length);
        if (status != TMFF_EXIT_DONE || length == 0) {
            break;
        }
        if (write_all(bytes, length) != 0) {
            status = TMFF_EXIT_OUTPUT;
            break;
        }
    }
    tmff_session_close(session);
    close(descriptor);
    return status;
}
