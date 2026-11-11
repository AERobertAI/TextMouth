#!/usr/bin/env python3
"""run-on-runner.py: runs the tests a request file names, on a GitHub Actions runner.

The workflow (.github/workflows/test-build.yml) calls this once the project is
generated. It reads the request the train or the suite pushed
(.github/test-request.json), runs the tests with the command every caller
shares (test_command.py), and writes four files into the output folder, which
the workflow uploads and the Mac downloads:

  request.json       the request, as it ran
  run.log            xcodebuild's whole output
  run-summary.txt    the short result, in the form build-train.py's `summarize`
                     reads: the Executed line, each FAILED and ERROR line, and
                     a last line of PASSED or FAILED
  summary.md         the same in a few lines, for the run's summary page

A request may carry "limit_minutes" to shorten that limit (it cannot lengthen it). It may also carry
"strict_performance": true, which runs the performance baselines strictly (a number more than twice its baseline
fails, and a busy machine does not skip them), and "no_warnings": true, which fails the run when the build's log
shows a Swift warning (xcodebuild reports a file's warnings only when it compiles that file, so this means
something only for a build from nothing, "cold": true). Both are what the reproducibility gate (check.yml) asks.

It exits 0 when the tests passed and 1 when they did not. Every wait has a
limit: the whole run (--limit-minutes), and a test host that writes nothing
to the log for too long is killed, as the Mac's train kills one.

With --shard I --of N (N above 1) the job runs only its share of the request's classes, the I-th of N
slices shard.py makes of them, so that N jobs run the request side by side; merge_shards.py joins
their results.

Usage: python3 -I -B Scripts/agents/run-on-runner.py [--request FILE] [--out DIR] [--limit-minutes N] [--shard I --of N]
Run it from the repository root.
"""
import argparse
import json
import os
import platform
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

# Importing these must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

AGENTS = Path(__file__).resolve().parent
sys.path.insert(0, str(AGENTS))
import github_run  # noqa: E402  (the path above must be set first)
import ios_ui_tests  # noqa: E402
import shard  # noqa: E402
import test_command  # noqa: E402
from runner_skips import (BadSkipLine, SKIPS_FILE, read_skips, selected_skips, skip_arguments)  # noqa: E402,F401

# The repository's root, where the commands run.
ROOT = AGENTS.parents[1]
# The whole run may take this long, in minutes: less than the workflow's job limit,
# so this script ends the run and writes its results before the job is cancelled.
DEFAULT_LIMIT_MINUTES = 80
# The longest one test may take on the runner, in seconds. xcodebuild fails a test that passes it, so a test
# that waits for something the runner lacks costs this and not its own limit (5 minutes for an audio read).
# xcodebuild rounds the limit up to a whole minute (its logs say "exceeded execution time allowance of 2
# minutes"), so 120 is what is meant: a hung test costs two minutes plus the host's restart.
# The slowest test on the development Mac takes 21 seconds, so 120 leaves a wide margin.
TEST_SECONDS = 120
# xcodebuild's -jobs on the runner (a free macOS runner has 3 or 4 cores).
RUNNER_JOBS = 3


def time_limit_arguments(request):
    """The xcodebuild arguments that fail a test passing its time limit: the request's
    "test_seconds", or TEST_SECONDS."""
    seconds = str(int(request.get("test_seconds", TEST_SECONDS)))
    return ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", seconds,
            "-maximum-test-execution-time-allowance", seconds]


# How much longer than on the development Mac the few timing tests that cannot compare the app with itself may let it
# take on the runner (TestMachine.timeScale in HostedTestIsolationSupport.swift). The runner is a virtual machine with
# 3 or 4 slower cores: a hostile-index read that is within 1.0 second here took 1.35 there. The development Mac never
# sets it, so its limits stay as written. A request may carry "time_scale" to try another.
RUNNER_TIME_SCALE = 2.5
# The most a request may widen the limits: a hand-sent request cannot make a timing test pass by waiting for ever.
MAX_TIME_SCALE = 10.0


def time_scale_problem(request):
    """Why the request's "time_scale" cannot be used, or None when it can (or is absent): it must be a number (not a
    truth value or a word) from 1 to MAX_TIME_SCALE. A scale below 1 would only be read as 1 by the tests, and one
    above the most would hide a slow test."""
    if "time_scale" not in request:
        return None
    value = request["time_scale"]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return f"the request's time_scale {value!r} is not a number"
    if not 1 <= value <= MAX_TIME_SCALE:
        return f"the request's time_scale {value!r} is not from 1 to {MAX_TIME_SCALE:g}"
    return None


def runner_environment(request):
    """The environment the test command runs in: this process's own, plus TEST_RUNNER_TEXTMOUTH_TEST_TIME_SCALE (the
    runner's time scale), and, for a request that asks for strict performance baselines,
    TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1. xcodebuild hands each to the test host without its TEST_RUNNER_ prefix
    (as `make test PERFORMANCE_STRICT=1` does for the gate on the Mac)."""
    environment = dict(os.environ)
    # main() refuses a request whose scale is no good before it gets here; the default stands in if one gets through.
    scale = RUNNER_TIME_SCALE if time_scale_problem(request) else float(request.get("time_scale", RUNNER_TIME_SCALE))
    environment["TEST_RUNNER_TEXTMOUTH_TEST_TIME_SCALE"] = str(scale)
    if request.get("strict_performance"):
        environment["TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT"] = "1"
    return environment


def runner_arguments(request, skips):
    """Every extra xcodebuild argument the runner adds: the time limit, and the tests left out."""
    return time_limit_arguments(request) + skip_arguments(selected_skips(request, skips))


def read_request(path):
    """The request file as a dictionary, with its lists and flag filled in. The names of the iPhone's interface test
    classes are moved out of its "classes" into "ios_ui_classes": they are run by the iPhone job
    (run-ios-ui-tests.py), and run-area.py would refuse them as unknown."""
    request = json.loads(Path(path).read_text(encoding="utf-8"))
    request.setdefault("areas", [])
    request.setdefault("classes", [])
    request.setdefault("full", False)
    return ios_ui_tests.split_classes(request, ROOT)


# How often, in seconds, the runner prints where the log has got to.
PROGRESS_SECONDS = 60


def print_progress(log, finished):
    """Prints, every PROGRESS_SECONDS until `finished` is set, how long the run has
    gone and the last line of its log, so that the run's page shows what a long
    build or a silent test is doing; a step's log is otherwise empty until it ends."""
    started = time.monotonic()
    while not finished.wait(PROGRESS_SECONDS):
        try:
            with open(log, "rb") as handle:
                handle.seek(0, 2)
                size = handle.tell()
                handle.seek(max(0, size - 4096))
                lines = [l for l in handle.read().decode("utf-8", "replace").splitlines() if l.strip()]
        except OSError:
            size, lines = 0, []
        print(f"progress: {(time.monotonic() - started) / 60:.0f} min, log {size} bytes, last: "
              f"{lines[-1].strip()[:160] if lines else '(nothing yet)'}", flush=True)


def classes_of(request):
    """The test classes a request names, in order and without repeats: its areas expanded by
    run-area.py (which lists an area's classes, and every class for "all"), then its own classes."""
    names = test_command.area_names(request["areas"])
    listed = []
    if names:
        listed = subprocess.run(["python3", "-I", "Scripts/test/run-area.py", "--list", *names], cwd=ROOT,
                                capture_output=True, text=True, check=True).stdout.split()
    return list(dict.fromkeys(listed + list(request["classes"])))


def sliced(request, number, count):
    """The request narrowed to shard `number` of `count` (1-based): only that shard's classes, never
    the full-suite flag. With a count of 1 the request is returned as it is."""
    if count <= 1:
        return request
    mine = shard.split(classes_of(request), shard.load_times(), count)[number - 1]
    return {**request, "areas": [], "classes": mine, "full": False, "shard": f"{number} of {count}"}


def run_tests(train, request, out, limit_minutes):
    """Runs the request's tests; returns (the printed result, whether the time
    limit stopped the run). The result is run-area.py's own output, or, for the
    full suite, run-area.py's reading of the log the suite wrote."""
    derived = (ROOT / "build" / "remote-DerivedData").resolve()
    log = out / "run.log"
    # The train's watchdog (a silent test host is killed, an xcodebuild that
    # outlives its tests is stopped) names the derived-data folder it watches,
    # and posts to the Mac's message board, which the runner has not. It is the
    # train's own code on purpose: one definition of "hung" for the Mac and the runner.
    train.DERIVED = derived
    train.post = lambda to, topic, tag="build": print(f"{tag}: {topic}", flush=True)
    if not request["full"] and not request["classes"] and (request.get("shard") or not request["areas"]):
        # A shard dealt no classes (more shards than classes) has nothing to run, nor has a request that names only
        # the iPhone's interface tests (which the iPhone job runs).
        log.write_text("This shard was dealt no test classes.\n"
                       "Test Suite 'Selected tests' passed at (nothing to run).\n")
        return ("Executed 0 tests, with 0 tests skipped and 0 failures (0 unexpected) in 0.000 (0.000) seconds\n"
                "PASSED in 0 seconds\n"), False
    if request["full"]:
        command = test_command.full_suite_command(derived, out / "result.xcresult",
                                                  extra=runner_arguments(request, read_skips()))
        # The suite's whole output is its log; run-area.py writes its own log.
        sink = open(log, "wb")
    else:
        command = test_command.area_command(request["areas"], request["classes"], derived, log,
                                            jobs=RUNNER_JOBS,
                                            extra=runner_arguments(request, read_skips())
                                            + ["-resultBundlePath", str(out / "result.xcresult")])
        sink = subprocess.PIPE
    print("command:", " ".join(command), flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=sink, stderr=subprocess.STDOUT, env=runner_environment(request))
    finished = threading.Event()
    threading.Thread(target=train.watch_for_a_hung_run, args=(log, finished, threading.Event()),
                     daemon=True).start()
    threading.Thread(target=print_progress, args=(log, finished), daemon=True).start()
    timed_out = False
    try:
        output, _ = process.communicate(timeout=limit_minutes * 60)
    except subprocess.TimeoutExpired:
        # Ask first, then insist, so that xcodebuild can write what it has.
        timed_out = True
        process.terminate()
        try:
            output, _ = process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
    finally:
        finished.set()
    if request["full"]:
        sink.close()
        read = subprocess.run(["python3", "-I", "Scripts/test/run-area.py", "--summarize", str(log)],
                              cwd=ROOT, capture_output=True, text=True)
        return read.stdout + read.stderr, timed_out
    return (output or b"").decode("utf-8", "replace"), timed_out


def judge(train, output, log, timed_out, limit_minutes):
    """Returns (the output with a closing FAILED line when the run did not pass,
    whether it passed). The train's reading of the output decides, and its
    reading of the log has the last word, as it has for the Mac's own runs: a
    test host that restarted can leave a passing last suite behind a failure."""
    passed = train.summarize(output)[0] == "PASSED" and not timed_out
    reason = f"the run was stopped after {limit_minutes:g} minutes" if timed_out else ""
    if passed and log.exists() and not train.tests_all_passed(log):
        passed, reason = False, "the log shows the test host restarted or its last suite did not pass"
    if not passed:
        # "FAILED:" with a colon is not a failed-test line, which has a space after FAILED.
        output += f"\nFAILED: {reason or unexplained_failure(train, output, log)}\n"
    return output, passed


def unexplained_failure(train, output, log):
    """Why a run that did not pass says so, when no time limit or restart explains it: the first compile or log
    ERROR line, else the first CRASH line, else (with a log that lacks it) that xcodebuild never printed TEST SUCCEEDED.
    A failed test needs no reason, for it is named in the summary. Run 42911613586 had 11,849 tests and no failure and
    was judged FAILED for an ERROR line of the log, and its page said only "the tests did not pass"."""
    _, _, failures, errors, crashed = train.summarize(output)
    if failures:
        return "the tests did not pass"
    if errors:
        return f"no test failed, but the log holds an error: {errors[0][:240]}"
    if crashed:
        line = next((l.strip() for l in output.splitlines() if l.strip().startswith("CRASH")), "CRASH")
        return f"no test failed, but {line[:240]}"
    if log.exists() and "** TEST SUCCEEDED **" not in log.read_text(encoding="utf-8", errors="replace"):
        return "no test failed, but xcodebuild never printed ** TEST SUCCEEDED ** in the log"
    return "the tests did not pass"


# A line in which the Swift compiler reports a warning: "<file>.swift:<line>:<column>: warning: ..." or, about its own
# settings, "<unknown>:0: warning: ...". The same definition as Scripts/check.sh's SWIFT_WARNING_PATTERN; other tools'
# warnings (the linker's) and anything a test prints are not Swift warnings.
SWIFT_WARNING = re.compile(r"^(.+\.swift:[0-9]+:[0-9]+|<unknown>:0): warning: ")
# How many warnings a failed run names.
WARNINGS_NAMED = 5


def swift_warnings(log_text, root=ROOT):
    """The Swift warnings in a build log, each once and in the order first reported, with the checkout's root left off
    the path (a Debug build compiles each file once, but a file shared by two targets can be reported twice)."""
    prefix = str(root).rstrip("/") + "/"
    seen = {}
    for line in log_text.splitlines():
        if SWIFT_WARNING.match(line):
            seen.setdefault(line.replace(prefix, "", 1), None)
    return list(seen)


def enforce_no_warnings(request, output, passed, log):
    """Returns (the output, whether the run passed) after the rule of a request that says "no_warnings": true, that
    the build's log shows no Swift warning. A run that broke it fails, and says how many warnings and the first few."""
    if not request.get("no_warnings") or not log.exists():
        return output, passed
    warnings = swift_warnings(log.read_text(encoding="utf-8", errors="replace"))
    if not warnings:
        return output, passed
    named = " | ".join(warnings[:WARNINGS_NAMED])
    output += (f"\nFAILED: {len(warnings)} Swift warnings in the build (the gate allows none), "
               f"the first {min(len(warnings), WARNINGS_NAMED)}: {named}\n")
    return output, False


def write_results(request, out, output, passed, seconds, left_out=0):
    """Writes request.json, run-summary.txt and summary.md into `out`."""
    (out / "request.json").write_text(json.dumps(request, indent=2) + "\n")
    (out / "run-summary.txt").write_text(output)
    executed = next((l.strip() for l in reversed(output.splitlines()) if "Executed" in l), "no tests ran")
    failed = [l.strip() for l in output.splitlines() if l.strip().startswith(("FAILED ", "ERROR "))]
    wanted = "the full suite" if request["full"] else (
        "areas " + (", ".join(request["areas"]) or "none") + "; classes " + (", ".join(request["classes"][:20]) or "none")
        + (f" and {len(request['classes']) - 20} more" if len(request["classes"]) > 20 else ""))
    if request.get("shard"):
        wanted += f" (shard {request['shard']})"
    lines = ["# Test build", "", f"- Verdict: {'PASSED' if passed else 'FAILED'}", f"- {executed}",
             f"- Asked for: {wanted}", f"- Minutes: {seconds / 60:.1f}",
             f"- Runner: macOS {platform.mac_ver()[0]}, {platform.machine()}",
             f"- Left out on the runner: {left_out} tests or classes (Scripts/agents/runner-skips.conf)",
             f"- Failures and errors: {len(failed)}", *[f"  - {line}" for line in failed[:40]]]
    # Why a run with no failed test failed (a host that restarted, a time limit, a Swift warning the gate allows none of),
    # on the run's page and in the job's log, where the next reader looks first.
    lines += [f"- Reason: {line.strip()[len('FAILED:'):].strip()}" for line in output.splitlines()
              if line.strip().startswith("FAILED:")]
    if len(failed) > 40:
        lines += [f"  - and {len(failed) - 40} more, in run-summary.txt"]
    (out / "summary.md").write_text("\n".join(lines) + "\n")


def main(argv):
    """Runs the request, writes the results, and exits by the verdict."""
    parser = argparse.ArgumentParser(prog="run-on-runner.py", description=__doc__.splitlines()[0])
    parser.add_argument("--request", default=github_run.REQUEST_PATH)
    parser.add_argument("--out", default="build/remote")
    parser.add_argument("--limit-minutes", type=float, default=DEFAULT_LIMIT_MINUTES)
    parser.add_argument("--shard", type=int, default=1, help="this job's number among the shards, from 1")
    parser.add_argument("--of", type=int, default=1, help="how many shards the request is split into")
    args = parser.parse_args(argv)
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    try:
        request = read_request(ROOT / args.request)
    except (OSError, ValueError) as error:
        print(f"run-on-runner: cannot read the request {args.request}: {error}", file=sys.stderr)
        return 2
    if not 1 <= args.shard <= max(1, args.of):
        print(f"run-on-runner: shard {args.shard} is not among {args.of}", file=sys.stderr)
        return 2
    try:
        read_skips()  # A bad line stops the job before the build, naming the line.
    except BadSkipLine as error:
        print(f"run-on-runner: {error}", file=sys.stderr)
        return 2
    problem = time_scale_problem(request)
    if problem:
        # An error, not a crash: the results are written, saying why no test ran, and the run fails.
        write_results(request, out, f"no tests ran\nFAILED: {problem}\n", False, 0.0, len(selected_skips(request, read_skips())))
        print((out / "summary.md").read_text())
        return 1
    request = sliced(request, args.shard, args.of)
    started = time.monotonic()
    train = test_command.load_build_train()
    # A request may ask for a shorter limit than the default (never a longer one), as a trial run does.
    limit = min(args.limit_minutes, float(request.get("limit_minutes", args.limit_minutes)))
    output, timed_out = run_tests(train, request, out, limit)
    output, passed = judge(train, output, out / "run.log", timed_out, limit)
    output, passed = enforce_no_warnings(request, output, passed, out / "run.log")
    write_results(request, out, output, passed, time.monotonic() - started,
                  len(selected_skips(request, read_skips())))
    print((out / "summary.md").read_text())
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
