#!/usr/bin/env python3
"""run-ios-build.py: builds the iPhone app and its UI-test bundle for the iOS Simulator, on a GitHub Actions runner.

The workflow's `ios` job (.github/workflows/tests.yml) calls this once the project is generated. It runs
`xcodebuild build-for-testing` on the scheme TextMouthiOS, which compiles the app (TextMouthiOS) and both of its test
bundles, TextMouthiOSTests and TextMouthiOSUITests, for a generic iOS Simulator destination. It runs no test, signs
nothing (CODE_SIGNING_ALLOWED=NO), and needs the Simulator SDK but no simulator device. It writes three files into the
output folder, which the workflow uploads and the Mac downloads:

  ios-summary.txt   a few lines: "iOS build: PASSED" or "iOS build: FAILED", the error count by file count, the
                    minutes, and the reason when the build could not run at all
  ios-errors.txt    each compile or link error on a line of its own, "path:line:col: error: message", with the path
                    relative to the repository root, as the Mac train's iOS census lists its errors (build-train.py
                    reads both files)
  ios.log           xcodebuild's whole output

A build that fails to compile is a result, not a failure of this script: it exits 0 whenever it wrote a summary, so
the run's tests and the iPhone build are judged apart, and the Mac shows the errors by file. It exits 2 only when it
cannot start (a missing output folder it cannot make). Every wait has a limit (--limit-minutes): a build that outlives
it is stopped, and the summary says so.

Usage: python3 -I -B Scripts/agents/run-ios-build.py [--out DIR] [--derived-data DIR] [--limit-minutes N]
Run it from the repository root. Python 3 standard library only.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The repository's root, where the build runs.
ROOT = Path(__file__).resolve().parents[2]
# The longest the build may take, in minutes: under the workflow job's limit of 30, which the platform download (about 3
# minutes) comes out of. A build from nothing took 8 to 10 minutes on November 10, 2026.
DEFAULT_LIMIT_MINUTES = 20
# The scheme and destination: the committed TextMouthiOS scheme, and any iOS Simulator (no device needs to exist).
SCHEME = "TextMouthiOS"
DESTINATION = "generic/platform=iOS Simulator"
# A compiler or linker diagnostic with a file: "<path>:<line>:<column>: error: <message>".
LOCATED_ERROR = re.compile(r"^(?P<path>/[^:\n]+?):(?P<line>\d+):(?P<column>\d+): error: (?P<message>.*)$")
# An error that names no file ("error: ...", "ld: ...", "clang: error: ..."), such as a missing SDK or a link failure.
UNLOCATED_ERROR = re.compile(r"^(?:xcodebuild: error: |error: |ld: |clang: error: |fatal error: )(?P<message>.*)$")
# What xcodebuild prints when the runner image has no iOS Simulator SDK or platform.
MISSING_PLATFORM = ("iOS 26.0 is not installed", "is not installed. To use with Xcode", "Unable to find a destination",
                    "SDK \"iphonesimulator\" cannot be located")


def build_command(derived_data):
    """The argv of the build: build-for-testing of the TextMouthiOS scheme into `derived_data`, unsigned."""
    return ["xcodebuild", "build-for-testing", "-project", "TextMouth.xcodeproj", "-scheme", SCHEME,
            "-destination", DESTINATION, "-derivedDataPath", str(derived_data),
            "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]


def relative(path, root):
    """`path` with the repository root (and the slash after it) taken off, or unchanged when it is elsewhere."""
    prefix = str(root).rstrip("/") + "/"
    return path[len(prefix):] if path.startswith(prefix) else path


def parse_errors(log_text, root=ROOT):
    """The errors in an xcodebuild log, each once and in the order first seen, as "path:line:col: error: message"
    with the path relative to `root`, or "error: message" for one that names no file. xcodebuild prints a
    diagnostic again in its closing summary of the failed commands, so repeats are dropped."""
    found = {}
    for raw in log_text.splitlines():
        line = raw.strip()
        located = LOCATED_ERROR.match(line)
        if located:
            error = (f"{relative(located['path'], root)}:{located['line']}:{located['column']}: "
                     f"error: {located['message']}")
        else:
            unlocated = UNLOCATED_ERROR.match(line)
            if not unlocated:
                continue
            error = f"error: {unlocated['message']}"
        found.setdefault(error, None)
    return list(found)


def files_of(errors):
    """The distinct files the errors name (an error without a file names none)."""
    return sorted({error.split(":", 1)[0] for error in errors if re.match(r"^[^ ]+:\d+:\d+: error: ", error)})


def platform_missing(log_text):
    """Whether the log says the runner image lacks the iOS Simulator platform or SDK the build needs."""
    return any(phrase in log_text for phrase in MISSING_PLATFORM)


def run_build(command, log, limit_minutes):
    """Runs `command` with its whole output in `log`; returns (its exit status, whether the limit stopped it).
    A build past the limit is asked to end, then killed a minute later."""
    with open(log, "wb") as sink:
        process = subprocess.Popen(command, cwd=ROOT, stdout=sink, stderr=subprocess.STDOUT)
        try:
            return process.wait(timeout=limit_minutes * 60), False
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return process.returncode, True


def write_results(out, errors, log_text, status, timed_out, seconds, limit_minutes):
    """Writes ios-summary.txt and ios-errors.txt into `out`; returns whether the build passed."""
    # build-for-testing ends "** TEST BUILD SUCCEEDED **", a plain build "** BUILD SUCCEEDED **".
    passed = status == 0 and not timed_out and not errors and "BUILD SUCCEEDED **" in log_text
    files = files_of(errors)
    reasons = []
    if timed_out:
        reasons.append(f"the build was stopped after {limit_minutes:g} minutes")
    if platform_missing(log_text) and not passed:
        reasons.append("the runner image lacks the iOS Simulator platform or SDK that this build needs")
    if not passed and not errors and not timed_out and not reasons:
        reasons.append(f"xcodebuild ended with status {status} and no error line")
    lines = [f"iOS build: {'PASSED' if passed else 'FAILED'}",
             f"Errors in the app: {len(errors)} in {len(files)} files",
             f"Built: scheme {SCHEME} (the app and its test bundles TextMouthiOSTests and TextMouthiOSUITests), "
             f"{DESTINATION}, build-for-testing, unsigned; no test was run",
             f"Minutes: {seconds / 60:.1f}", *[f"Reason: {reason}" for reason in reasons]]
    (out / "ios-summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "ios-errors.txt").write_text("".join(error + "\n" for error in errors), encoding="utf-8")
    return passed


def main(argv):
    """Builds, writes the results, prints the summary, and exits 0 whenever the results were written."""
    parser = argparse.ArgumentParser(prog="run-ios-build.py", description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="build/remote-ios")
    parser.add_argument("--derived-data", default="build/remote-DerivedData-ios")
    parser.add_argument("--limit-minutes", type=float, default=DEFAULT_LIMIT_MINUTES)
    args = parser.parse_args(argv)
    out = (ROOT / args.out).resolve()
    try:
        out.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        print(f"run-ios-build: cannot make {out}: {error}", file=sys.stderr)
        return 2
    command = build_command((ROOT / args.derived_data).resolve())
    print("command:", " ".join(command), flush=True)
    started = time.monotonic()
    status, timed_out = run_build(command, out / "ios.log", args.limit_minutes)
    log_text = (out / "ios.log").read_text(encoding="utf-8", errors="replace")
    write_results(out, parse_errors(log_text), log_text, status, timed_out, time.monotonic() - started,
                  args.limit_minutes)
    print((out / "ios-summary.txt").read_text(), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
