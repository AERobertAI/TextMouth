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

A request may carry "limit_minutes" to shorten that limit (it cannot lengthen it).

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
import platform
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
import shard  # noqa: E402
import test_command  # noqa: E402

# The repository's root, where the commands run.
ROOT = AGENTS.parents[1]
# The whole run may take this long, in minutes: less than the workflow's job limit,
# so this script ends the run and writes its results before the job is cancelled.
DEFAULT_LIMIT_MINUTES = 80
# The longest one test may take on the runner, in seconds. xcodebuild fails a test that passes it, so a test
# that waits for something the runner lacks costs this and not its own limit (5 minutes for an audio read).
# The slowest test on the development Mac takes 21 seconds, so 90 leaves a wide margin.
TEST_SECONDS = 90
# xcodebuild's -jobs on the runner (a free macOS runner has 3 or 4 cores).
RUNNER_JOBS = 3


def time_limit_arguments(request):
    """The xcodebuild arguments that fail a test passing its time limit: the request's
    "test_seconds", or TEST_SECONDS."""
    seconds = str(int(request.get("test_seconds", TEST_SECONDS)))
    return ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", seconds,
            "-maximum-test-execution-time-allowance", seconds]


def runner_arguments(request, skips):
    """Every extra xcodebuild argument the runner adds: the time limit, and the tests left out."""
    return time_limit_arguments(request) + skip_arguments(selected_skips(request, skips))


# The tests that are not run on the runner, one "Class.testName  # reason" per line, beside this script.
SKIPS_FILE = AGENTS / "runner-skips.conf"


def read_skips(path=SKIPS_FILE):
    """The tests the runner leaves out, as [(class, test, reason)], from the skips file: a line is
    "Class.testName", then optionally "# reason"; a line that is blank or starts with "#" is a comment.
    A missing file is no skips."""
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    skips = []
    for line in lines:
        name, _, reason = line.partition("#")
        name = name.strip()
        if not name:
            continue
        owner, _, test = name.partition(".")
        if owner and test:
            skips.append((owner, test, reason.strip()))
    return skips


def selected_skips(request, skips):
    """The skips that apply to this job: all of them for a full-suite run or a run of areas (which could
    hold any class), and only those of its own classes for a run of named classes (a shard's command stays short)."""
    if request["full"] or request["areas"]:
        return list(skips)
    return [skip for skip in skips if skip[0] in set(request["classes"])]


def skip_arguments(skips):
    """The xcodebuild arguments that leave `skips` out: -skip-testing for each test."""
    return [f"-skip-testing:TextMouthProductionTests/{owner}/{test}" for owner, test, _ in skips]


def read_request(path):
    """The request file as a dictionary, with its lists and flag filled in."""
    request = json.loads(Path(path).read_text(encoding="utf-8"))
    request.setdefault("areas", [])
    request.setdefault("classes", [])
    request.setdefault("full", False)
    return request


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
    if request.get("shard") and not request["classes"]:
        # A shard dealt no classes (more shards than classes) has nothing to run.
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
                                            jobs=RUNNER_JOBS, extra=runner_arguments(request, read_skips()))
        sink = subprocess.PIPE
    print("command:", " ".join(command), flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=sink, stderr=subprocess.STDOUT)
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
        output += f"\nFAILED: {reason or 'the tests did not pass'}\n"
    return output, passed


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
             f"- Left out on the runner: {left_out} tests (Scripts/agents/runner-skips.conf)",
             f"- Failures and errors: {len(failed)}", *[f"  - {line}" for line in failed[:40]]]
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
    request = sliced(request, args.shard, args.of)
    started = time.monotonic()
    train = test_command.load_build_train()
    # A request may ask for a shorter limit than the default (never a longer one), as a trial run does.
    limit = min(args.limit_minutes, float(request.get("limit_minutes", args.limit_minutes)))
    output, timed_out = run_tests(train, request, out, limit)
    output, passed = judge(train, output, out / "run.log", timed_out, limit)
    write_results(request, out, output, passed, time.monotonic() - started,
                  len(selected_skips(request, read_skips())))
    print((out / "summary.md").read_text())
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
