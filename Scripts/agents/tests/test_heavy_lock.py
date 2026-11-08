"""Tests of heavy_lock.py: one heavy job at a time, with the build train first in line.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test points the module at a temporary folder before it calls anything, so
the Mac's real lock in build/orchestrator/ is never read, taken, or removed.
"""
import json
import os
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


class AcquireTests(HeavyLockTestCase):
    """The lock as every caller takes it."""

    def test_a_free_lock_is_taken_at_once_and_released(self):
        self.assertTrue(heavy_lock.acquire("a type-check", 0))
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")
        self.assertEqual(heavy_lock.owner()["pid"], os.getpid())
        heavy_lock.release()
        self.assertFalse(heavy_lock.LOCK.exists(), "release() should remove the lock")

    def test_a_held_lock_is_waited_for_and_taken_when_its_job_ends(self):
        self.hold_lock(self.live_pid())
        told = []
        self.later(0.15, self.free_lock)
        self.assertTrue(heavy_lock.acquire("a type-check", 5, told.append))
        self.assertEqual([record["name"] for record in told], ["holder"],
                         "the waiter should be told once whom it waits for")
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")

    def test_a_held_lock_is_not_taken_when_the_wait_runs_out(self):
        self.hold_lock(self.live_pid())
        self.assertFalse(heavy_lock.acquire("a type-check", 0.1))
        self.assertEqual(heavy_lock.owner()["name"], "holder", "the holder's lock should be left alone")

    def test_a_lock_whose_owner_has_ended_is_taken_over(self):
        self.hold_lock(self.ended_pid())
        self.assertTrue(heavy_lock.acquire("a type-check", 1))
        self.assertEqual(heavy_lock.owner()["name"], "a type-check")


class FirstInLineTests(HeavyLockTestCase):
    """The build train's turn, which comes before every other caller's."""

    def test_a_caller_first_in_line_holds_off_others_even_from_a_free_lock(self):
        self.mark_first(self.live_pid(), time.time() + 60)
        told = []
        self.assertFalse(heavy_lock.acquire("a type-check", 0.15, told.append))
        self.assertFalse(heavy_lock.LOCK.exists(), "no one but the train should take the lock while it waits")
        self.assertEqual([record["name"] for record in told], ["build-train, first in line"])

    def test_a_mark_whose_process_has_ended_counts_for_nothing(self):
        self.mark_first(self.ended_pid(), time.time() + 60)
        self.assertTrue(heavy_lock.acquire("a type-check", 0))

    def test_a_mark_whose_wait_has_ended_counts_for_nothing(self):
        # A live process that took the ID of a train killed as it waited, say.
        self.mark_first(self.live_pid(), time.time() - 1)
        self.assertTrue(heavy_lock.acquire("a type-check", 0))

    def test_the_first_caller_marks_its_wait_and_removes_the_mark_once_it_has_the_lock(self):
        self.hold_lock(self.live_pid())
        seen = {}

        def look_then_free():
            seen["mark"] = json.loads(heavy_lock.FIRST.read_text())
            self.free_lock()

        self.later(0.15, look_then_free)
        self.assertTrue(heavy_lock.acquire("build-train", 5, first=True))
        self.assertEqual(seen["mark"]["name"], "build-train")
        self.assertEqual(seen["mark"]["pid"], os.getpid())
        self.assertGreater(seen["mark"]["until"], time.time(), "the mark should say when the wait ends")
        self.assertFalse(heavy_lock.FIRST.exists(), "the mark should go once the lock is taken")
        self.assertEqual(heavy_lock.owner()["name"], "build-train")

    def test_the_first_caller_removes_its_mark_when_it_gives_up(self):
        self.hold_lock(self.live_pid())
        self.assertFalse(heavy_lock.acquire("build-train", 0.1, first=True))
        self.assertFalse(heavy_lock.FIRST.exists(), "a train that gave up should hold no one back")

    def test_another_callers_mark_is_left_in_place(self):
        self.mark_first(self.live_pid(), time.time() + 60)
        heavy_lock._leave_the_line()
        self.assertTrue(heavy_lock.FIRST.exists(), "only the mark's own process may remove it")

    def test_held_passes_first_on(self):
        self.hold_lock(self.live_pid())
        with heavy_lock.held("build-train", 0.1, first=True) as taken:
            self.assertFalse(taken)
        self.assertFalse(heavy_lock.FIRST.exists())
        self.assertEqual(heavy_lock.owner()["name"], "holder", "a lock not taken should not be released")


if __name__ == "__main__":
    unittest.main()
