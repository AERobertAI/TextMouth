"""HeavyLockTestCase: the base of every test that takes the heavy-work lock.

It points heavy_lock at a temporary folder before a test calls anything, so the
Mac's real lock in build/orchestrator/ is never read, taken, or removed. The
tests of heavy_lock.py, run_locked.py, and run_suite.py share it.
"""
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

# heavy_lock.py is beside this folder; python3 -I leaves both out of sys.path.
AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)


class HeavyLockTestCase(unittest.TestCase):
    """Points heavy_lock at a temporary folder and polls fast, for each test."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        for name, value in (("LOCK", self.folder / "heavy-lock"),
                            ("FIRST", self.folder / "heavy-lock-first.json"),
                            ("POLL_SECONDS", 0.02)):
            original = getattr(heavy_lock, name)
            self.addCleanup(setattr, heavy_lock, name, original)
            setattr(heavy_lock, name, value)
        # Never let a test reach the real lock, whatever it does.
        self.assertTrue(str(heavy_lock.LOCK).startswith(str(self.folder)))
        self.assertTrue(str(heavy_lock.FIRST).startswith(str(self.folder)))

    def live_pid(self):
        """The process ID of another process that runs until the test ends."""
        process = subprocess.Popen(["sleep", "60"])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid

    @staticmethod
    def ended_pid():
        """The process ID of a process that has ended."""
        process = subprocess.Popen(["true"])
        process.wait()
        return process.pid

    def hold_lock(self, pid, name="holder"):
        """Makes the lock as another job holding it would."""
        heavy_lock.LOCK.mkdir()
        (heavy_lock.LOCK / "owner.json").write_text(json.dumps({"pid": pid, "name": name, "since": "now"}))

    def free_lock(self):
        """Frees the lock as its job would on ending, in one step (a rename, so
        no waiter ever sees the folder without its owner's file)."""
        heavy_lock.LOCK.rename(self.folder / f"freed-{time.monotonic_ns()}")

    def mark_first(self, pid, until, name="build-train"):
        """Writes a first-in-line mark as a waiting train would."""
        heavy_lock.FIRST.write_text(json.dumps({"pid": pid, "name": name, "since": "now", "until": until}))

    def later(self, seconds, action):
        """Runs `action` on a thread of its own after `seconds`, unless the test has ended."""
        timer = threading.Timer(seconds, action)
        self.addCleanup(timer.cancel)
        timer.start()
