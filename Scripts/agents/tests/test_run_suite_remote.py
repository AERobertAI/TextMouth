"""Tests of run_suite.py --remote: the full suite on GitHub Actions, judged as a local run is.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Like test_remote_train.py, nothing reaches GitHub or the Mac's real locks: the push
goes to a bare repository in a temporary folder, `gh` is a stand-in, the clock is
pretend, and the build train's lock, which a remote suite takes, is in a temporary folder.
"""
import contextlib
import io
import json
import subprocess
import sys
import unittest
from unittest import mock

from remote_case import (FAILING_LOG, PASSING_LOG, STARTED, RemoteTestCase, results)
import github_run  # noqa: E402
import heavy_lock  # noqa: E402
import run_suite  # noqa: E402

DONE = {"status": "completed", "conclusion": "success", "url": "https://github.example/runs/7001"}
# The tail of a full run's log, as xcodebuild prints it.
SUITE_PASSED = ("Test Suite 'All tests' passed at 2026-11-09 10:00:00.000.\n"
                "\t Executed 11853 tests, with 81 tests skipped and 0 failures (0 unexpected) in 900.0 (901.0) seconds\n"
                "** TEST SUCCEEDED **\n")
SUITE_FAILED = ("Test Suite 'All tests' failed at 2026-11-09 10:00:00.000.\n"
                "\t Executed 11853 tests, with 2 failures (0 unexpected) in 900.0 (901.0) seconds\n"
                "** TEST FAILED **\n")


class RunSuiteRemoteTests(RemoteTestCase):
    """run_suite.py --remote COMMIT NAME LOG, with a fake gh and a fake remote."""

    def setUp(self):
        super().setUp()
        train = run_suite._train
        records = self.folder / "train"
        for name, value in (("TRAIN_DIR", records), ("LOCK", records / "lock"), ("STATE", records / "lock" / "state.txt")):
            patcher = mock.patch.object(train, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.assertTrue(str(train.LOCK).startswith(str(self.folder)), "the real train lock must be out of reach")
        # A remote suite must never ask for the heavy-work lock.
        patcher = mock.patch.object(heavy_lock, "held", side_effect=AssertionError("no heavy-work lock for a remote suite"))
        patcher.start()
        self.addCleanup(patcher.stop)
        # The wait for a train is short here, so nothing can hang.
        for name, value in (("TRAIN_WAIT_SECONDS", 0.2), ("TRAIN_POLL_SECONDS", 0.02)):
            patcher = mock.patch.object(run_suite, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.log = self.folder / "suite.log"

    def run_remote(self, name="suite"):
        """Runs run_suite's remote path from the throwaway repository; returns (status, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = run_suite.run_remote(name, str(self.log), self.head, cwd=self.repo)
        return status, out.getvalue(), err.getvalue()

    def gh_runs(self, *downloads, view=DONE):
        """Tells the fake gh a run starts, ends as `view` says, and uploads each of `downloads`."""
        self.gh_state({"list": [[STARTED]], "view": [view], "download": list(downloads)})

    def test_a_passing_remote_suite_exits_zero_and_leaves_the_log_where_a_local_one_would(self):
        self.gh_runs(results("PASSED\n", SUITE_PASSED))
        status, out, _ = self.run_remote()
        self.assertEqual(status, 0, out)
        self.assertEqual(self.log.read_text(), SUITE_PASSED)
        self.assertIn("Executed 11853 tests, with 81 tests skipped and 0 failures", out)
        self.assertIn("https://github.example/runs/7001", out)

    def test_a_log_in_a_folder_that_does_not_exist_yet_is_written_all_the_same(self):
        self.log = self.folder / "new-folder" / "suite.log"
        self.gh_runs(results("PASSED\n", SUITE_PASSED))
        status, out, _ = self.run_remote()
        self.assertEqual(status, 0, out)
        self.assertEqual(self.log.read_text(), SUITE_PASSED)

    def test_the_suite_pushed_is_the_full_suite_of_the_commit_to_testbuild_only(self):
        self.gh_runs(results("PASSED\n", SUITE_PASSED))
        self.run_remote("orchestrator-suite")
        refs = self.pushed_refs()
        self.assertEqual(list(refs), ["refs/heads/TestBuild"])
        request = self.pushed_request(refs["refs/heads/TestBuild"])
        self.assertTrue(request["full"])
        self.assertEqual(request["requests"], [{"agent": "orchestrator-suite", "head": self.head}])

    def test_a_remote_suite_with_failing_tests_exits_one(self):
        self.gh_runs(results("FAILED\n", SUITE_FAILED), view={**DONE, "conclusion": "failure"})
        status, out, _ = self.run_remote()
        self.assertEqual(status, 1)
        self.assertIn("run_suite: xcodebuild says TEST FAILED", out)

    def test_a_host_that_restarted_does_not_pass_though_its_last_suite_did(self):
        self.gh_runs(results("PASSED\n", "Restarting after unexpected exit, crash, or test timeout\n" + SUITE_PASSED))
        status, _, _ = self.run_remote()
        self.assertEqual(status, 1)

    def test_a_cancelled_run_has_no_verdict_and_writes_no_log(self):
        self.gh_runs({"fail": True}, view={**DONE, "conclusion": "cancelled"})
        status, _, err = self.run_remote()
        self.assertEqual(status, 4)
        self.assertIn("cancelled", err)
        self.assertFalse(self.log.exists(), "a log from an older run must not be mistaken for this one's")

    def test_a_push_that_fails_is_exit_four_and_frees_the_train_lock(self):
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        status, _, err = self.run_remote()
        self.assertEqual(status, 4)
        self.assertIn("failed", err)
        self.assertFalse(run_suite._train.LOCK.exists(), "the train lock should be released")

    def test_the_train_lock_is_released_after_a_run(self):
        self.gh_runs(results("PASSED\n", SUITE_PASSED))
        self.run_remote()
        self.assertFalse(run_suite._train.LOCK.exists())

    def test_a_remote_suite_waits_for_a_train_on_testbuild_and_gives_up_without_pushing(self):
        # Only one run can be on TestBuild at a time: a newer push cancels the older.
        run_suite._train.LOCK.mkdir(parents=True)
        holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        (run_suite._train.LOCK / "pid").write_text(str(holder.pid))
        status, _, err = self.run_remote()
        self.assertEqual(status, 3)
        self.assertIn("found a train on GitHub", err)
        self.assertEqual(self.pushed_refs(), {})
        self.assertTrue((run_suite._train.LOCK / "pid").exists(), "the train's lock must be left alone")

    def test_the_command_line_takes_the_remote_option_before_name_and_log(self):
        self.gh_runs(results("PASSED\n", SUITE_PASSED))
        out = io.StringIO()
        argv = ["run_suite.py", "--remote", self.head, "suite", str(self.log)]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(run_suite.os, "getcwd", return_value=str(self.repo)), \
                contextlib.redirect_stdout(out):
            status = run_suite.main()
        self.assertEqual(status, 0, out.getvalue())

    def test_the_remote_option_needs_its_commit_name_and_log(self):
        err = io.StringIO()
        with mock.patch.object(sys, "argv", ["run_suite.py", "--remote", self.head, "suite"]), \
                contextlib.redirect_stderr(err):
            self.assertEqual(run_suite.main(), 2)
        self.assertIn("usage: run_suite.py [--remote COMMIT] NAME LOG", err.getvalue())


if __name__ == "__main__":
    unittest.main()
