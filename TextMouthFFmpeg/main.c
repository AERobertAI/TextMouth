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
 * Confinement: FFmpeg is C that parses what an attacker may have written, so once the helper
 * has opened its one input file it confines itself with the system's pure-computation sandbox
 * (sandbox_init, named "pure-computation"): from then on it can compute, read the descriptor
 * it already holds, and write its standard output, and nothing else. It opens no file, makes
 * no network connection, and starts no program, whatever FFmpeg does with a hostile file. A
 * helper that cannot confine itself reads nothing and ends with TMFF_EXIT_NOT_CONFINED. What
 * FFmpeg needs after it is checked, not assumed: allocation, threads, and the clock are
 * allowed; it opens no file once running (the session reads the held descriptor through its
 * own callbacks); a random seed (av_get_random_seed) is still given, measured; and the
 * processor's features, which FFmpeg reads from sysctl, the sandbox refuses, so they are
 * asked first (tmff_session_prepare), as measured: asked after, FFmpeg found fewer. A Debug
 * build also has a third mode, TMFF_MODE_CONFINEMENT, that proves what is refused and what is
 * kept (confinement_report below).
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
#include <sandbox.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#ifdef DEBUG
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <sys/socket.h>
#endif

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

/* The system's built-in pure-computation profile, by the name sandbox_init looks it up under.
   The macOS 27 SDK's <sandbox.h> no longer declares kSBXProfilePureComputation, though the
   system library still exports it, holding exactly this string; naming the profile here builds
   with every SDK and asks for the same profile. */
static const char pure_computation_profile[] = "pure-computation";

/* Confines the process to computing, reading the descriptors it already holds, and writing its
   standard output (the system's pure-computation sandbox, which nothing undoes); 0, or -1 when
   the system refuses. sandbox_init and sandbox_free_error are deprecated, though they are the
   one interface that is not a private profile language, and the warning is silenced for these
   two calls only. */
static int confine_process(void) {
    char *message = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const int result = sandbox_init(pure_computation_profile, SANDBOX_NAMED, &message);
    if (message) {
        sandbox_free_error(message);
    }
#pragma clang diagnostic pop
    return result == 0 ? 0 : -1;
}

#ifdef DEBUG
/* Writes "<name>=<answer>\n" to standard output; 0, or -1 when the write fails. */
static int write_answer(const char *name, const char *answer) {
    char line[64];
    const int length = snprintf(line, sizeof line, "%s=%s\n", name, answer);
    return length > 0 ? write_all((const unsigned char *)line, (size_t)length) : -1;
}

/* The Debug-only proof of the confinement, run after confine_process (TMFF_MODE_CONFINEMENT):
   writes whether the descriptor opened before it still reads, whether the hosts file is refused
   (EPERM, which only the sandbox gives: a missing file or a closed door would not), and whether
   a network connection is refused (a socket can still be made, but connecting to the loopback
   address is EPERM). Returns TMFF_EXIT_DONE when all three are as a confined helper has them,
   TMFF_EXIT_NOT_CONFINED when any is not, and TMFF_EXIT_OUTPUT when the answers cannot be
   written. */
static int confinement_report(int descriptor, int prepared_features) {
    unsigned char byte;
    const int readable = pread(descriptor, &byte, 1, 0) == 1;
    errno = 0;
    const int hosts = open("/etc/hosts", O_RDONLY);
    const int hosts_refused = hosts < 0 && errno == EPERM;
    if (hosts >= 0) {
        close(hosts);
    }
    int socket_refused = 0;
    const int network = socket(AF_INET, SOCK_STREAM, 0);
    if (network < 0) {
        socket_refused = errno == EPERM;
    } else {
        struct sockaddr_in loopback;
        memset(&loopback, 0, sizeof loopback);
        loopback.sin_family = AF_INET;
        loopback.sin_port = htons(9);
        loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        errno = 0;
        socket_refused = connect(network, (const struct sockaddr *)&loopback, sizeof loopback) < 0 && errno == EPERM;
        close(network);
    }
    /* The processor's features, found before the confinement, are still what FFmpeg believes. */
    const int features_kept = prepared_features != 0 && tmff_session_cpu_features() == prepared_features;
    if (write_answer("input", readable ? "readable" : "unreadable") != 0
        || write_answer("hosts", hosts_refused ? "refused" : "opened") != 0
        || write_answer("socket", socket_refused ? "refused" : "connected") != 0
        || write_answer("cpu", features_kept ? "kept" : "lost") != 0) {
        return TMFF_EXIT_OUTPUT;
    }
    return readable && hosts_refused && socket_refused && features_kept ? TMFF_EXIT_DONE : TMFF_EXIT_NOT_CONFINED;
}
#endif

#ifdef DEBUG
/* Recurses without end, each call holding a kilobyte the compiler must keep, until the stack is
   gone. Its result is used by the caller so the recursion is never taken out. The compiler's
   warning that it never ends is the point of the function, and is silenced for it alone, as the
   deprecated sandbox calls' is. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winfinite-recursion"
static unsigned recurse_until_the_stack_ends(unsigned depth) {
    volatile char frame[1024];
    frame[0] = (char)depth;
    return recurse_until_the_stack_ends(depth + 1) + (unsigned)frame[0];
}
#pragma clang diagnostic pop

/* The Debug-only proof of the signal guard (TMFF_MODE_SIGNALCHECK): crashes the way `kind` names.
   With the guard installed it never returns, since the process ends with TMFF_EXIT_CRASHED; it
   returns TMFF_EXIT_USAGE for a kind it does not know, and TMFF_EXIT_DONE when the crash did not
   end the process, which is a guard (or a test) that does not work. The pointers are volatile so
   the compiler cannot see the crash and remove it. */
static int signal_check(const char *kind) {
    if (strcmp(kind, TMFF_SIGNALCHECK_SEGFAULT) == 0) {
        volatile int *nowhere = NULL;
        *nowhere = 1;
    } else if (strcmp(kind, TMFF_SIGNALCHECK_ABORT) == 0) {
        abort();
    } else if (strcmp(kind, TMFF_SIGNALCHECK_OVERFLOW) == 0) {
        return (int)recurse_until_the_stack_ends(0);
    } else if (strcmp(kind, TMFF_SIGNALCHECK_DOUBLE_FREE) == 0) {
        void *volatile memory = malloc(64);
        free(memory);
        free(memory);
    } else {
        return TMFF_EXIT_USAGE;
    }
    return TMFF_EXIT_DONE;
}
#endif

/* Reads the arguments, runs the session, and writes its records. Returns the exit status. */
int main(int argc, char **argv) {
    install_guards();
    if (argc != 4) {
        return TMFF_EXIT_USAGE;
    }
    tmff_session_mode mode;
    int prepared_features;
#ifdef DEBUG
    int only_confinement = 0;
    int only_formcheck = 0;
    int only_signalcheck = 0;
#endif
    if (strcmp(argv[1], TMFF_MODE_PROBE) == 0) {
        mode = TMFF_SESSION_PROBE;
    } else if (strcmp(argv[1], TMFF_MODE_DECODE) == 0) {
        mode = TMFF_SESSION_DECODE;
#ifdef DEBUG
    } else if (strcmp(argv[1], TMFF_MODE_CONFINEMENT) == 0) {
        mode = TMFF_SESSION_PROBE;
        only_confinement = 1;
    } else if (strcmp(argv[1], TMFF_MODE_FORMCHECK) == 0) {
        mode = TMFF_SESSION_PROBE;
        only_formcheck = 1;
    } else if (strcmp(argv[1], TMFF_MODE_SIGNALCHECK) == 0) {
        mode = TMFF_SESSION_PROBE;
        only_signalcheck = 1;
#endif
    } else {
        return TMFF_EXIT_USAGE;
    }
#ifdef DEBUG
    if (only_signalcheck) {
        /* No file: the helper only crashes as it is told to, under the guard installed above. */
        return signal_check(argv[2]);
    }
    if (only_formcheck) {
        /* No file: the frames are made up in memory, and nothing needs the confinement. */
        char answers[4096];
        const int answered = tmff_session_formcheck(answers, sizeof answers);
        return write_all((const unsigned char *)answers, strlen(answers)) == 0 ? answered : TMFF_EXIT_OUTPUT;
    }
#endif
    /* A regular file only, never a FIFO waited on (the session's own opener, which the iPhone's
       import uses too). */
    const int descriptor = tmff_open_regular_file(argv[3]);
    if (descriptor < 0) {
        return TMFF_EXIT_UNREADABLE;
    }
    /* What FFmpeg asks the system for once (the processor's features) is asked before the
       confinement, which would refuse it. */
    prepared_features = tmff_session_prepare();
    /* The one file is open: from here the helper can do nothing but compute and write. */
    if (confine_process() != 0) {
        close(descriptor);
        return TMFF_EXIT_NOT_CONFINED;
    }
#ifdef DEBUG
    if (only_confinement) {
        const int answer = confinement_report(descriptor, prepared_features);
        close(descriptor);
        return answer;
    }
#endif
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
