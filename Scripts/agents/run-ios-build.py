#!/usr/bin/env python3
"""run-ios-build.py: builds the iPhone app and its UI-test bundle for the iOS Simulator, on a GitHub Actions runner.

The workflow's `ios` job (.github/workflows/tests.yml) calls this once the project is generated. It runs
`xcodebuild build-for-testing` on the scheme TextMouthiOS, which compiles the app (TextMouthiOS) and both of its test
bundles, TextMouthiOSTests and TextMouthiOSUITests, for a generic iOS Simulator destination. It runs no test, signs
nothing (CODE_SIGNING_ALLOWED=NO), and needs the Simulator SDK but no simulator device. It writes three files into the
output folder, which the workflow uploads and the Mac downloads:

  ios-summary.txt   a few lines: "iOS build: PASSED" or "iOS build: FAILED", the error count by file count, the
                    minutes, the reason when the build could not run at all, and a "Retried:" line when the build
                    ran twice (see below)
  ios-errors.txt    each compile or link error on a line of its own, "path:line:col: error: message", with the path
                    relative to the repository root, as the Mac train's iOS census lists its errors (build-train.py
                    reads both files)
  ios.log           xcodebuild's whole output (both tries', when it ran twice)

A build that fails to compile is a result, not a failure of this script: it exits 0 whenever it wrote a summary, so
the run's tests and the iPhone build are judged apart, and the Mac shows the errors by file. It exits 2 only when it
cannot start (a missing output folder it cannot make). Every wait has a limit (--limit-minutes): a build that outlives
it is stopped, and the summary says so.

The restored derived-data folder may hold module caches made on another runner image, which fail a build with "file
'...module.modulemap' has been modified since the module file ... was built" (runner_module_cache.py). So the build is
preceded by runner_module_cache.prepare, which empties those caches when the toolchain differs from the one that made
them, and a build that still fails with that error is run once more with the caches emptied, in what is left of the same
time limit; the summary's "Retried:" line says so and why.

Usage: python3 -I -B Scripts/agents/run-ios-build.py [--out DIR] [--derived-data DIR] [--limit-minutes N]
Run it from the repository root. Python 3 standard library only.
"""
import argparse
import platform
import re
import subprocess
import sys
import time
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_module_cache  # noqa: E402  (the path above must be set first)

# The repository's root, where the build runs.
ROOT = Path(__file__).resolve().parents[2]
# The longest the build may take, in minutes: under the workflow job's limit of 30, which the platform download (about 3
# minutes) comes out of. A build from nothing took 8 to 10 minutes on November 10, 2026.
DEFAULT_LIMIT_MINUTES = 20
# The least time, in minutes, that must be left of the limit for the retry to be worth starting: less would stop it before
# it had compiled anything.
MINIMUM_RETRY_MINUTES = 1.0
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


def host_architecture(machine=None):
    """The one architecture to build for: the machine's own ("arm64" or "x86_64"), since the simulator the tests run in
    is built for the machine it runs on. A generic Simulator destination builds both architectures when none is named,
    which compiled every Swift file twice (1,086 files each way in run 43716590818: about half of the build's minutes
    on a runner with three cores). `machine` is platform.machine()'s answer; an unknown one gives None, and the build
    then names no architecture."""
    machine = platform.machine() if machine is None else machine
    return {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}.get(machine.lower())


def build_command(derived_data, architecture=None):
    """The argv of the build: build-for-testing of the TextMouthiOS scheme into `derived_data`, unsigned, for one
    architecture (this machine's, see host_architecture, unless `architecture` is given)."""
    architecture = architecture or host_architecture()
    only = [f"ARCHS={architecture}"] if architecture else []
    return ["xcodebuild", "build-for-testing", "-project", "TextMouth.xcodeproj", "-scheme", SCHEME,
            "-destination", DESTINATION, "-derivedDataPath", str(derived_data),
            "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", *only]


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


def run_build(command, log, limit_minutes, append=False):
    """Runs `command` with its whole output in `log` (added to the end of it when `append` is true, as a retry's is);
    returns (its exit status, whether the limit stopped it). A build past the limit is asked to end, then killed a
    minute later."""
    with open(log, "ab" if append else "wb") as sink:
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


def needs_retry(status, timed_out, log_text):
    """Whether a build failed (not by its time limit) with the stale-module error, which emptying the module caches cures."""
    return status != 0 and not timed_out and runner_module_cache.is_stale_module_error(log_text)


def retry_note(first_minutes):
    """The summary's "Retried:" line: that the first try failed with the stale-module error, that the module caches were
    emptied and the build run again, and how long the first try took."""
    return (f"Retried: the first try ({first_minutes:.1f} minutes) failed with \"{runner_module_cache.STALE_MARKER}\", "
            "so the module caches were emptied and the build ran once more")


def write_results(out, errors, log_text, status, timed_out, seconds, limit_minutes, retried=None):
    """Writes ios-summary.txt and ios-errors.txt into `out`; returns whether the build passed. `retried` is the
    "Retried:" line of a build that ran twice (see retry_note), or None. The errors and the verdict are the last try's."""
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
             f"Minutes: {seconds / 60:.1f}", *([retried] if retried else []),
             *[f"Reason: {reason}" for reason in reasons]]
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
    derived = (ROOT / args.derived_data).resolve()
    # Empties the restored module caches when they were made on another toolchain, and stamps this one.
    runner_module_cache.prepare(derived)
    command = build_command(derived)
    print("command:", " ".join(command), flush=True)
    started = time.monotonic()
    log = out / "ios.log"
    status, timed_out = run_build(command, log, args.limit_minutes)
    log_text = log.read_text(encoding="utf-8", errors="replace")
    retried = None
    if needs_retry(status, timed_out, log_text):
        first_seconds = time.monotonic() - started
        left = args.limit_minutes - first_seconds / 60
        if left >= MINIMUM_RETRY_MINUTES:
            # The caches that failed the build are emptied and the build runs again in what is left of the limit. Its
            # output is added to the same log, and only that part is read for the result.
            print(f"run-ios-build: {runner_module_cache.STALE_MARKER}; emptying the module caches and building once more",
                  flush=True)
            runner_module_cache.empty_module_caches(derived)
            first_size = log.stat().st_size
            status, timed_out = run_build(command, log, left, append=True)
            log_text = log.read_bytes()[first_size:].decode("utf-8", errors="replace")
            retried = retry_note(first_seconds)
    write_results(out, parse_errors(log_text), log_text, status, timed_out, time.monotonic() - started,
                  args.limit_minutes, retried)
    print((out / "ios-summary.txt").read_text(), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
