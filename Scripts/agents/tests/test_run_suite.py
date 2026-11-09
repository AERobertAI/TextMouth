"""Tests of run_suite.py: the full hosted suite under the heavy-work lock, judged by its log.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test runs xcodebuild. Each replaces the suite's command with a small Python
child that prints what a test run prints, points heavy_lock at a temporary folder
(see heavy_lock_case.py), writes its log there, and shortens every wait, so the
Mac's real lock is never touched and no test can hang.
"""
import contextlib
import io
import sys
import time
import unittest
from unittest import mock

from heavy_lock_case import HeavyLockTestCase
import run_suite  # noqa: E402  (imported by path, after sys.path is set by heavy_lock_case)

# The last lines of a passing run, as xcodebuild prints them.
PASSED = ("Test Suite 'All tests' passed at 2026-11-09 10:00:00.000.\n"
          "\t Executed 8230 tests, with 0 failures (0 unexpected) in 250.0 (250.5) seconds\n")
# The last lines of a run whose tests failed, with xcodebuild's own verdict.
FAILED = ("Test Suite 'All tests' failed at 2026-11-09 10:00:00.000.\n"
          "\t Executed 8230 tests, with 2 failures (0 unexpected) in 250.0 (250.5) seconds\n"
          "** TEST FAILED **\n")


class RunSuiteTests(HeavyLockTestCase):
    """The runner, run in this process with a fake command and short waits."""

    def setUp(self):
        super().setUp()
        self.log = self.folder / "suite.log"
        self.assertTrue(str(self.log).startswith(str(self.folder)))
        # Short waits, so nothing can hang: the watchdog looks every 50 ms and
        # counts a run as silent at once; the lock is waited for half a second.
        for target, name, value in ((run_suite, "WATCH_SECONDS", 0.05),
                                    (run_suite, "WAIT_SECONDS", 0.5),
                                    (run_suite._train, "HUNG_AFTER_TESTS_MINUTES", 0)):
            patcher = mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_command(self, printed, then_sleep=0, status=0):
        """Makes the suite's command a Python child that prints `printed`, sleeps
        `then_sleep` seconds (an xcodebuild that outlives its tests), and exits with `status`."""
        program = (f"import sys, time; sys.stdout.write({printed!r}); sys.stdout.flush(); "
                   f"time.sleep({then_sleep}); sys.exit({status})")
        patcher = mock.patch.object(run_suite, "COMMAND", [sys.executable, "-I", "-B", "-c", program])
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_runner(self, name="suite"):
        """Runs main() as `run_suite.py NAME LOG` would; returns (status, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["run_suite.py", name, str(self.log)]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = run_suite.main()
        return status, out.getvalue(), err.getvalue()

    def test_a_passing_run_prints_its_executed_line_and_exits_zero(self):
        self.fake_command(PASSED)
        status, out, _ = self.run_runner()
        self.assertEqual(status, 0, out)
        self.assertEqual(out.strip(), "Executed 8230 tests, with 0 failures (0 unexpected) in 250.0 (250.5) seconds")
        self.assertFalse(self.lock_exists(), "the lock was still held after the run")

    def test_a_failing_run_exits_nonzero_and_says_xcodebuild_said_so(self):
        self.fake_command(FAILED, status=65)
        status, out, _ = self.run_runner()
        self.assertEqual(status, 1)
        self.assertIn("run_suite: xcodebuild says TEST FAILED", out)
        self.assertIn("with 2 failures", out, "the Executed line was not printed")

    def test_a_run_with_a_restarted_host_does_not_pass_though_its_last_suite_did(self):
        # November 7, 2026: the suite after a host restart passed, and the run still failed.
        self.fake_command("Restarting after unexpected exit, crash, or test timeout\n" + PASSED)
        status, _, _ = self.run_runner()
        self.assertEqual(status, 1)

    def test_a_log_with_no_verdict_is_not_a_pass(self):
        self.fake_command("Compiling...\n")
        status, out, _ = self.run_runner()
        self.assertEqual(status, 1)
        self.assertEqual(out.strip(), "no tests ran")

    def test_a_command_that_outlives_its_tests_is_ended(self):
        # The child prints a finished run, then sits silent for 20 s. The watchdog
        # must end it long before; the run is judged by its log, which passed.
        self.fake_command(PASSED, then_sleep=20)
        started = time.monotonic()
        status, out, _ = self.run_runner()
        self.assertLess(time.monotonic() - started, 15, "the runner waited for a command that outlived its tests")
        self.assertIn("run_suite: xcodebuild was silent after its tests ended, so it was stopped", out)
        self.assertEqual(status, 0, out)

    def test_a_command_still_running_its_tests_is_not_ended(self):
        # The log shows no end of the tests, so the watchdog leaves the child alone
        # and the run lasts as long as the child does.
        self.fake_command("Test Case 'A.test' started.\n", then_sleep=1)
        started = time.monotonic()
        status, out, _ = self.run_runner()
        self.assertGreaterEqual(time.monotonic() - started, 1, "the runner ended a run whose tests had not ended")
        self.assertNotIn("was stopped", out)
        self.assertEqual(status, 1)

    def test_it_gives_up_when_another_job_holds_the_lock_and_runs_nothing(self):
        self.fake_command(PASSED)
        self.hold_lock(self.live_pid())
        status, out, err = self.run_runner()
        self.assertEqual(status, 3)
        self.assertIn("did not get the lock in time", err)
        self.assertFalse(self.log.exists(), "the suite ran though another job held the lock")

    def test_a_command_line_without_a_log_is_refused(self):
        with mock.patch.object(sys, "argv", ["run_suite.py", "suite"]), contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(run_suite.main(), 2)
        self.assertIn("usage: run_suite.py NAME LOG", err.getvalue())

    def test_the_command_is_the_hosted_suite_and_never_changes_unnoticed(self):
        # The real command, read without running it: the merge method in AGENTS.md names these.
        command = run_suite.COMMAND
        self.assertEqual(command[:2], ["xcodebuild", "test"])
        for part in ("TextMouth.xcodeproj", "platform=macOS", "CODE_SIGNING_ALLOWED=NO",
                     "SWIFT_STRICT_CONCURRENCY=complete", "build/DerivedData"):
            self.assertIn(part, command)

    def lock_exists(self):
        """Whether the temporary lock is held."""
        return run_suite.heavy_lock.LOCK.exists()


if __name__ == "__main__":
    unittest.main()
