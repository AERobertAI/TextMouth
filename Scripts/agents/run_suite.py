#!/usr/bin/env python3
"""run_suite.py NAME LOG: runs the full hosted suite under the Mac's heavy lock.

This is the orchestrator's check before a merge into main. It does what
run_locked.py does for `xcodebuild test`, and also ends an xcodebuild that outlives
its tests: on the night of November 6, 2026 trains' xcodebuilds sat silent after
their last test had ended, for 14 minutes in one case. Under the lock, with no
watchdog, that would hold every agent's request behind it for up to 3 hours.

It prints the log's Executed line and exits 0 only if the log says every test passed.
Run it with `python3 -I`, from the checkout to test, in the Bash tool's background mode.

With `--remote COMMIT` (November 9, 2026) the suite runs on GitHub Actions instead: the tree
of COMMIT, plus a request for the full suite, is pushed to the branch TestBuild, and the run
of that commit is waited for (github_run.py). The run's log is written to LOG, and the Executed
line and the exit status come from it exactly as for a local run. It loads this Mac with a push
only, so it takes no heavy-work lock; it takes the build train's own lock instead, since only
one run can be on TestBuild at a time (a newer push cancels the older run). Exit status 3 means
it found a train on GitHub the whole time it waited, and 4 that the push or the run failed, not
the tests.

Usage: run_suite.py [--remote COMMIT] NAME LOG
"""
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

# Importing these must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The folder this file is in, so the script works from any checkout or worktree.
AGENTS = Path(__file__).resolve().parent
sys.path.insert(0, str(AGENTS))
import heavy_lock  # noqa: E402

import github_run  # noqa: E402
import shard  # noqa: E402
import test_command  # noqa: E402

# The train's own reading of a log, so the two can't disagree.
_train = test_command.load_build_train()

# How long to wait for the lock before giving up: longer than a train's build.
WAIT_SECONDS = 3 * 60 * 60

# How often the watchdog looks at the log, in seconds.
WATCH_SECONDS = 30

# The suite's command, as the merge method in AGENTS.md gives it (test_command.py
# makes it, for this script and for the runner on GitHub alike).
COMMAND = test_command.full_suite_command("build/DerivedData")

# How long a remote suite waits for a train on GitHub to end before it pushes, in seconds:
# a remote train can take as long as RUN_LIMIT_MINUTES.
TRAIN_WAIT_SECONDS = github_run.RUN_LIMIT_MINUTES * 60
# How often it looks for the train lock to be free, in seconds.
TRAIN_POLL_SECONDS = 20


def stop_if_it_outlives_its_tests(process, log, finished):
    """Sends xcodebuild SIGTERM once the log shows its tests ended and has gone quiet."""
    while not finished.wait(WATCH_SECONDS):
        try:
            idle = time.time() - os.stat(log).st_mtime
            ended = _train.tests_have_ended(log)
        except OSError:
            continue  # The run has not written its log yet.
        if ended and idle >= _train.HUNG_AFTER_TESTS_MINUTES * 60:
            print("run_suite: xcodebuild was silent after its tests ended, so it was stopped", flush=True)
            process.send_signal(signal.SIGTERM)
            return


def main():
    """Takes the lock, runs the suite, and exits by what the log says of the tests."""
    arguments = sys.argv[1:]
    remote = None
    if len(arguments) == 4 and arguments[0] == "--remote":
        remote, arguments = arguments[1], arguments[2:]
    if len(arguments) != 2:
        print("usage: run_suite.py [--remote COMMIT] NAME LOG", file=sys.stderr)
        return 2
    name, log = arguments
    if remote:
        return run_remote(name, log, remote)
    with heavy_lock.held(name, WAIT_SECONDS) as taken:
        if not taken:
            print(f"run_suite: {name} did not get the lock in time", file=sys.stderr)
            return 3
        with open(log, "wb") as output:
            process = subprocess.Popen(COMMAND, stdout=output, stderr=subprocess.STDOUT)
            finished = threading.Event()
            threading.Thread(target=stop_if_it_outlives_its_tests, args=(process, log, finished),
                             daemon=True).start()
            process.wait()
            finished.set()
    return judge_log(log)


def judge_log(log):
    """Prints the log's Executed line and returns the exit status its verdict gives:
    0 when every test passed, 1 when not. Local and remote suites are judged alike."""
    with open(log, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - 4096))
        tail = handle.read().decode("utf-8", "replace")
    executed = [line.strip() for line in tail.splitlines() if "Executed " in line]
    print(executed[-1] if executed else "no tests ran", flush=True)
    # xcodebuild's own verdict is the last word when it printed one; the log's
    # reading (no host restarted, the last suite passed) must also hold, and
    # stands alone only when xcodebuild had to be stopped before its verdict.
    if "** TEST FAILED **" in tail:
        print("run_suite: xcodebuild says TEST FAILED", flush=True)
        return 1
    return 0 if _train.tests_all_passed(log) else 1


def take_train_lock():
    """Takes the build train's own lock, waiting up to TRAIN_WAIT_SECONDS for a train to
    finish, since only one run can be on TestBuild at a time. Returns True when taken."""
    waited = 0
    while not _train.take_lock():
        if waited >= TRAIN_WAIT_SECONDS:
            return False
        time.sleep(TRAIN_POLL_SECONDS)
        waited += TRAIN_POLL_SECONDS
    _train.set_state("a remote full suite")
    return True


def fresh_folder(stem):
    """`stem-1`, or `stem-2` and on when earlier runs already made theirs: a name nothing is in yet."""
    number = 1
    while Path(f"{stem}-{number}").exists():
        number += 1
    return f"{stem}-{number}"


# How many files a remote suite names in its report of the iPhone build's errors.
IOS_FILES_NAMED = 30


def report_interface_tests(folder):
    """Prints what the remote run's iPhone interface tests made (they press Play and type in the iOS Simulator, for a
    full suite): their verdict and Executed line, then each failed test, named as the Mac's failures are. Prints nothing
    when the run made no summary or was not asked for them. Like the iPhone build, it is information: the suite's
    verdict and exit status are the Mac tests'. The details are in ios-ui-summary.txt and ios-ui.log in `folder`."""
    found = _train.remote_ios_ui_result(Path(folder))
    line = _train.ios_ui_line(found)
    if not line:
        return
    print(f"run_suite:{line[1:]}", flush=True)
    for failure in found[2]:
        print(f"run_suite:   {failure}", flush=True)


def report_iphone_build(folder):
    """Prints what the remote run's iPhone build (the app and its UI tests, built for the iOS Simulator beside the
    tests) made: its verdict and error count, then the files its errors are in, with how many each holds. Prints nothing
    when the run made none (a request that left it out). It is information: the suite's verdict and exit status
    are the tests'. The details are in ios-errors.txt and ios.log in `folder`."""
    report_interface_tests(folder)
    found = _train.remote_ios_result(Path(folder))
    if not found:
        return
    count, errors, label = found
    print(f"run_suite: {label}: {count}", flush=True)
    per_file = {}
    for error in errors:
        path = error.split(":", 1)[0] if re.match(r"^[^ :]+:\d+:\d+: error", error) else "(no file)"
        per_file[path] = per_file.get(path, 0) + 1
    for path, number in sorted(per_file.items())[:IOS_FILES_NAMED]:
        print(f"run_suite:   {path}: {number} error{'s' if number != 1 else ''}", flush=True)
    if len(per_file) > IOS_FILES_NAMED:
        print(f"run_suite:   and {len(per_file) - IOS_FILES_NAMED} more files, in {Path(folder) / 'ios-errors.txt'}", flush=True)


def run_remote(name, log, commit, cwd=None):
    """Runs the full suite on GitHub Actions for `commit`'s tree, writes the run's log
    to `log`, and returns the exit status: as a local run's, or 3 when a train held
    TestBuild throughout, or 4 when the push or the run failed and so says nothing
    about the tests. `cwd` is the checkout that holds `commit` (by default, the current folder)."""
    if not take_train_lock():
        print(f"run_suite: {name} found a train on GitHub for {TRAIN_WAIT_SECONDS // 60} minutes", file=sys.stderr)
        return 3
    # A folder of this run's own, never one an earlier run of the same LOG left: gh will not overwrite
    # files, and a run that brings nothing back must not be judged by an earlier run's log.
    folder = fresh_folder(f"{log}.remote")
    try:
        # The full suite is long, so it runs as the most shards there are. It names "all" as well as "full" so
        # the runner can deal its classes out: the area "all" is every test of the scheme (11,854 counted in
        # the sources, 11,853 run on the Mac on November 9, 2026), so the shards' classes add up to the suite.
        request = {"areas": ["all"], "classes": [], "full": True, "shards": shard.MAX_SHARDS,
                   "requests": [{"agent": name, "head": commit}]}
        try:
            result = github_run.run_remotely(cwd or os.getcwd(), commit, request, folder,
                                             f"Test build: full suite for {name}",
                                             progress=lambda text: print(f"run_suite: {text}", flush=True))
        except github_run.RemoteFailure as failure:
            print(f"run_suite: the run on GitHub failed: {failure}", file=sys.stderr)
            return 4
    finally:
        _train.release_lock()
    print(f"run_suite: run {result['url']} {result['conclusion']} after {result['minutes']} minutes", flush=True)
    report_iphone_build(folder)
    downloaded = Path(folder) / "run.log"
    if (result["conclusion"] in _train.UNFINISHED_RUNS or not result["downloaded"]
            or not downloaded.exists()):
        print(f"run_suite: the run ended {result['conclusion']} without a log, so the tests have no verdict",
              file=sys.stderr)
        return 4
    # The run's log is the suite's log, where a local run's would be.
    Path(log).parent.mkdir(parents=True, exist_ok=True)
    Path(log).write_bytes(downloaded.read_bytes())
    return judge_log(log)


if __name__ == "__main__":
    sys.exit(main())
