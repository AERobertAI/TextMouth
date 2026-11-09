"""Tests of run_locked.py: one command under the heavy-work lock, and its exit status passed on.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test points heavy_lock at a temporary folder (see heavy_lock_case.py), runs
only small Python commands, and gives the wrapper a wait of a second or less, so the
Mac's real lock is never touched and no test can hang.
"""
import contextlib
import io
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

from heavy_lock_case import HeavyLockTestCase, AGENTS
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)
import run_locked  # noqa: E402

# A command that records whether the lock is held while it runs, then exits with a status.
# Arguments: the lock's path, the file to write the answer to, the status to exit with.
RECORD_THE_LOCK = ("import os, sys; "
                   "open(sys.argv[2], 'w').write('held' if os.path.isdir(sys.argv[1]) else 'free'); "
                   "sys.exit(int(sys.argv[3]))")


class RunLockedTests(HeavyLockTestCase):
    """The wrapper, run in this process with its wait shortened."""

    def setUp(self):
        super().setUp()
        # Never wait long enough to look like a hang.
        patcher = mock.patch.object(run_locked, "WAIT_SECONDS", 0.5)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_wrapper(self, *arguments):
        """Runs main() as `run_locked.py <arguments>` would; returns (status, stderr text)."""
        errors = io.StringIO()
        with mock.patch.object(sys, "argv", ["run_locked.py", *arguments]), contextlib.redirect_stderr(errors):
            status = run_locked.main()
        return status, errors.getvalue()

    def recording_command(self, status):
        """The command arguments that record the lock's state in self.answer, then exit with `status`."""
        self.answer = self.folder / "answer.txt"
        self.assertTrue(str(self.answer).startswith(str(self.folder)))
        return [sys.executable, "-I", "-B", "-c", RECORD_THE_LOCK, str(heavy_lock.LOCK), str(self.answer), str(status)]

    def test_it_runs_the_command_while_holding_the_lock_and_releases_it_after(self):
        status, _ = self.run_wrapper("job", *self.recording_command(0))
        self.assertEqual(status, 0)
        self.assertEqual(self.answer.read_text(), "held", "the command ran without the lock held")
        self.assertFalse(heavy_lock.LOCK.exists(), "the lock was still held after the command ended")

    def test_it_passes_on_the_commands_exit_status(self):
        status, _ = self.run_wrapper("job", *self.recording_command(7))
        self.assertEqual(status, 7, "the wrapper did not return the command's own status")

    def test_it_releases_the_lock_when_the_command_fails(self):
        status, _ = self.run_wrapper("job", sys.executable, "-I", "-B", "-c", "raise SystemExit(1)")
        self.assertEqual(status, 1)
        self.assertFalse(heavy_lock.LOCK.exists(), "a failed command left the lock held")
        # And the next caller can take it at once.
        self.assertTrue(heavy_lock.acquire("next", 0))
        heavy_lock.release()

    def test_it_releases_the_lock_when_the_command_cannot_start(self):
        # A missing program makes subprocess raise; the lock must still be released.
        with self.assertRaises(FileNotFoundError):
            self.run_wrapper("job", str(self.folder / "no-such-program"))
        self.assertFalse(heavy_lock.LOCK.exists(), "a command that could not start left the lock held")

    def test_it_gives_up_at_its_limit_when_the_lock_is_held_and_does_not_run_the_command(self):
        self.hold_lock(self.live_pid())
        started = time.monotonic()
        status, errors = self.run_wrapper("job", *self.recording_command(0))
        self.assertEqual(status, 3)
        self.assertFalse(self.answer.exists(), "the command ran though another job held the lock")
        self.assertIn("did not get the lock in time", errors)
        self.assertLess(time.monotonic() - started, 10, "the wrapper waited far past its limit")
        self.assertTrue(heavy_lock.LOCK.exists(), "the wrapper took over a lock it did not hold")

    def test_it_waits_while_the_lock_is_held_and_runs_once_it_is_free(self):
        self.hold_lock(self.live_pid())
        self.later(0.2, self.free_lock)
        status, _ = self.run_wrapper("job", *self.recording_command(0))
        self.assertEqual(status, 0)
        self.assertEqual(self.answer.read_text(), "held")

    def test_a_command_line_without_a_command_is_refused(self):
        status, errors = self.run_wrapper("job")
        self.assertEqual(status, 2)
        self.assertIn("usage: run_locked.py NAME COMMAND...", errors)

    def test_it_finds_heavy_lock_beside_itself_not_by_an_absolute_path(self):
        self.assertEqual(Path(run_locked.__file__).resolve().parent, AGENTS)
        self.assertIs(run_locked.heavy_lock, heavy_lock)


if __name__ == "__main__":
    unittest.main()
