#!/usr/bin/env python3
"""quit-while-held: run TextMouth's held-quit decisions through real AppKit.

Not part of the hosted suite: no test may quit the test host, so each case
here runs in a child process of its own, a small AppKit program built from
the app's real quit sources (App/QuitRequest.swift, App/QuitHold.swift, and
App/QuitFinisher.swift) and Scripts/test/quit-while-held/, with a watchdog.
Nothing is shown, played, or written but the compiled probe, which goes to a
fixed folder (overwritten each run, never deleted).

The cases (see Scripts/test/quit-while-held/main.swift):

  old-queue     CONTROL. A quit held with .terminateLater, asked again with
                terminate(nil) from a main-queue block, as Quit Anyway and
                the editors did: the reply never comes. Shown as REPRODUCED.
  ask-queue     The same hold, asked again through QuitRequest.ask() from a
                main-queue block: the reply comes and the work ends first.
  ask-task      The same, from a main-actor Task.
  old-second    CONTROL. A second quit while a reply is pending: AppKit
                quits at once, cutting the work off. Shown as REPRODUCED.
  second-timer  The fix: a second quit from a timer while the work is
                finished is cancelled, says the same words again, and the
                work ends before TextMouth does.
  second-key    The same, with Command-Q through the Quit menu item.
  second-dock   The same, with the Dock's Quit (a quit Apple event).
  logout        The system ending the session is answered later, not
                cancelled, with the work ended.
  no-work       Nothing to finish: the quit goes ahead at once.

It also checks that no app source asks AppKit to quit again except through
QuitRequest.ask() (the memory guard's own quit excepted, and said so there).

Usage:
    python3 -I Scripts/test/quit-while-held.py                 # all cases
    python3 -I Scripts/test/quit-while-held.py ask-queue       # some cases
    python3 -I Scripts/test/quit-while-held.py --overlay DIR   # DIR's files
        stand in for the sources of the same names: the way to prove a
        case fails with a fix undone, on a scratch copy
    python3 -I Scripts/test/quit-while-held.py --log           # each probe's log

Builds go through the heavy-work lock: run it as
    python3 -I Scripts/agents/run_locked.py NAME python3 -I Scripts/test/quit-while-held.py

Exit status: 0 every case showed what it should, 1 one did not, 2 a usage
or compile problem.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# The repository this script belongs to.
REPO = Path(__file__).resolve().parents[2]
# The probe's own sources.
PROBE_DIR = REPO / "Scripts" / "test" / "quit-while-held"
# The app's quit sources the probe builds in unchanged.
APP_SOURCES = [REPO / "TextMouth" / "App" / name for name in ("QuitRequest.swift", "QuitHold.swift", "QuitFinisher.swift")]
# The probe's own files, built with them.
PROBE_SOURCES = [PROBE_DIR / "Stubs.swift", PROBE_DIR / "main.swift"]

# What each case's exit code must be: 0 it behaved as the fix says, 2 the
# watchdog ended it (a reply that never came), 3 the work was cut off. The
# controls undo the fix on purpose and are expected to show the fault.
EXPECTED = {
    "old-queue": 2,
    "ask-queue": 0,
    "ask-task": 0,
    "old-second": 3,
    "second-timer": 0,
    "second-key": 0,
    "second-dock": 0,
    "logout": 0,
    "no-work": 0,
}
# The cases that are controls.
CONTROLS = {name for name, code in EXPECTED.items() if code != 0}

# A line that asks AppKit to quit with terminate(...): in code, not a comment.
TERMINATE_CALL = re.compile(r"\bterminate\((nil|self|sender)\)")
# The files that may: the helper itself, and the memory guard's emergency quit.
MAY_TERMINATE = {"QuitRequest.swift", "PlaybackMemoryGuard.swift"}


def sources_with_overlay(paths, overlay):
    """`paths`, each replaced by the file of the same name in `overlay`, if any."""
    if overlay is None:
        return [str(path) for path in paths]
    return [str(overlay / path.name) if (overlay / path.name).exists() else str(path) for path in paths]


def compile_probe(work, overlay):
    """Builds the probe into `work`, overwriting the last one; returns its path."""
    work.mkdir(parents=True, exist_ok=True)
    binary = work / "quit-probe"
    sources = sources_with_overlay(APP_SOURCES + PROBE_SOURCES, overlay)
    command = ["swiftc", "-swift-version", "6", "-Onone", "-o", str(binary), *sources]
    print("compiling:", " ".join(Path(s).name for s in sources), flush=True)
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        print(result.stdout + result.stderr, file=sys.stderr)
        sys.exit(2)
    return binary


def run_case(binary, name, show_log):
    """Runs one case in a child process with a time limit; returns (code, last RESULT line)."""
    try:
        done = subprocess.run([str(binary), name], capture_output=True, text=True, timeout=30)
        code, output = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as error:
        # The probe's own watchdog failed: treat as hung.
        code, output = 2, (error.stdout or b"").decode(errors="replace") + "RESULT: killed after 30 seconds\n"
    if show_log:
        print("".join("    " + line + "\n" for line in output.splitlines()), end="")
    results = [line for line in output.splitlines() if line.startswith("RESULT")]
    return code, (results[-1] if results else "RESULT: no verdict\n" + output[-300:])


def judge(name, code, verdict):
    """Prints the verdict of one case; returns whether it showed what it should."""
    wanted = EXPECTED[name]
    shown = code == wanted
    if name in CONTROLS:
        label = "REPRODUCED" if shown else "NOT REPRODUCED"
    else:
        label = "PASS" if shown else "FAIL"
    print(f"{label:<14} {name:<13} exit {code} (wanted {wanted})  {verdict}")
    return shown


def check_ask_sites():
    """Finds the app sources that ask AppKit to quit other than through the helper."""
    stray = []
    for path in sorted((REPO / "TextMouth").rglob("*.swift")):
        if path.name in MAY_TERMINATE:
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if TERMINATE_CALL.search(line) and not line.lstrip().startswith("//"):
                stray.append(f"{path.relative_to(REPO)}:{number}: {line.strip()}")
    return stray


def main():
    """Builds the probe, runs the cases, checks the sites, prints a verdict per case."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("cases", nargs="*", help="cases to run (default: all)")
    parser.add_argument("--overlay", type=Path, help="a folder whose files replace the sources of the same names")
    parser.add_argument("--work", type=Path, default=REPO / "build" / "quit-while-held", help="where the probe is built")
    parser.add_argument("--log", action="store_true", help="show each probe's log")
    parser.add_argument("--no-sites", action="store_true", help="skip the check of where quits are asked")
    args = parser.parse_args()

    unknown = [name for name in args.cases if name not in EXPECTED]
    if unknown:
        print("no such case:", ", ".join(unknown), "; cases:", ", ".join(EXPECTED), file=sys.stderr)
        return 2
    names = args.cases or list(EXPECTED)

    binary = compile_probe(args.work, args.overlay)
    failures = 0
    for name in names:
        code, verdict = run_case(binary, name, args.log)
        if not judge(name, code, verdict):
            failures += 1
    if not args.no_sites and args.overlay is None and not args.cases:
        stray = check_ask_sites()
        for line in stray:
            print("STRAY QUIT     ", line)
        print(("FAIL" if stray else "PASS") + "           ask-sites     "
              + (f"{len(stray)} source(s) ask AppKit to quit other than through QuitRequest.ask()" if stray
                 else "every quit is asked through QuitRequest.ask()"))
        failures += bool(stray)
    print("every case showed what it should" if failures == 0 else f"{failures} case(s) did not")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
