#!/usr/bin/env python3
"""run_suite.py NAME LOG: runs the full hosted suite under the Mac's heavy lock.

This is the orchestrator's check before a merge into main. It does what
run_locked.py does for `xcodebuild test`, and also ends an xcodebuild that outlives
its tests: on the night of November 6, 2026 trains' xcodebuilds sat silent after
their last test had ended, for 14 minutes in one case. Under the lock, with no
watchdog, that would hold every agent's request behind it for up to 3 hours.

It prints the log's Executed line and exits 0 only if the log says every test passed.
Run it with `python3 -I`, from the checkout to test, in the Bash tool's background mode.
"""
import importlib.util
import os
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

# The train's own reading of a log, so the two can't disagree. Its name has a hyphen,
# so it is loaded by path, and it is read with its command line out of the way.
_spec = importlib.util.spec_from_file_location("build_train", AGENTS / "build-train.py")
_train = importlib.util.module_from_spec(_spec)
_arguments, sys.argv = sys.argv, ["build-train.py"]
_spec.loader.exec_module(_train)
sys.argv = _arguments

# How long to wait for the lock before giving up: longer than a train's build.
WAIT_SECONDS = 3 * 60 * 60

# How often the watchdog looks at the log, in seconds.
WATCH_SECONDS = 30

# The suite's command, as the merge method in AGENTS.md gives it.
COMMAND = ["xcodebuild", "test", "-project", "TextMouth.xcodeproj", "-scheme", "TextMouth",
           "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
           "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete",
           "-derivedDataPath", "build/DerivedData"]


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
    if len(sys.argv) != 3:
        print("usage: run_suite.py NAME LOG", file=sys.stderr)
        return 2
    name, log = sys.argv[1], sys.argv[2]
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


if __name__ == "__main__":
    sys.exit(main())
