"""Tests of run-on-runner.py: what the GitHub workflow runs once the project is generated.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test builds or runs the app. Each replaces the test command with a small Python child that
prints what a test run prints, and gives the script a request and an output folder in a
temporary directory. The one real command run is run-area.py reading a canned log.
"""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from heavy_lock_case import HeavyLockTestCase  # noqa: F401  (puts the scripts' folder on the path)
import test_command  # noqa: E402

AGENTS = Path(test_command.AGENTS)
# The script's name has hyphens, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("run_on_runner", AGENTS / "run-on-runner.py")
runner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runner)

# What a finished suite's log ends with, and the summary run-area.py prints for it.
LOG_PASSED = ("Test Suite 'Selected tests' passed at 2026-11-09 10:00:00.000.\n"
              "\t Executed 3 tests, with 0 failures (0 unexpected) in 1.0 (1.1) seconds\n** TEST SUCCEEDED **\n")
SUMMARY_PASSED = "Executed 3 tests, with 0 failures\nPASSED in 5 seconds\n"
SUMMARY_FAILED = ("Executed 3 tests, with 1 failures\nFAILED FooTests.testBar at Foo.swift:9: wrong\n"
                  "FAILED in 5 seconds\n")


class RunnerTestCase(unittest.TestCase):
    """A request file and an output folder in a temporary directory."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.out = self.folder / "out"
        self.request = self.folder / "request.json"
        self.write_request({"areas": ["stats"], "classes": ["FooTests"]})

    def write_request(self, request):
        """Writes the request file the runner will read."""
        self.request.write_text(json.dumps(request))

    def child(self, printed, log_text=None, sleep=0, status=0):
        """A command for the runner to run: a Python child that writes `log_text` to the log
        path it is given (as run-area.py does), prints `printed`, sleeps, and exits with `status`."""
        program = ("import sys, time\n"
                   "log = sys.argv[1]\n"
                   f"text = {log_text!r}\n"
                   "if text is not None:\n"
                   "    open(log, 'w').write(text)\n"
                   f"sys.stdout.write({printed!r}); sys.stdout.flush()\n"
                   f"time.sleep({sleep})\n"
                   f"sys.exit({status})\n")
        return lambda areas, classes, derived, log, jobs=3: [sys.executable, "-I", "-B", "-c", program, str(log)]

    def run_main(self, limit_minutes=5, extra=()):
        """Runs the script's main() on the request; returns (status, stdout)."""
        out = io.StringIO()
        argv = ["--request", str(self.request), "--out", str(self.out), "--limit-minutes", str(limit_minutes), *extra]
        with contextlib.redirect_stdout(out):
            status = runner.main(argv)
        return status, out.getvalue()

    def files(self):
        """The names of the files the runner wrote."""
        return sorted(path.name for path in self.out.iterdir())


class AreaRunTests(RunnerTestCase):
    """A request for areas and classes."""

    def test_a_passing_run_writes_its_four_files_and_exits_zero(self):
        with mock.patch.object(test_command, "area_command", self.child(SUMMARY_PASSED, LOG_PASSED)):
            status, out = self.run_main()
        self.assertEqual(status, 0, out)
        self.assertEqual(self.files(), ["request.json", "run-summary.txt", "run.log", "summary.md"])
        self.assertEqual((self.out / "run.log").read_text(), LOG_PASSED)
        self.assertEqual((self.out / "run-summary.txt").read_text(), SUMMARY_PASSED)
        summary = (self.out / "summary.md").read_text()
        self.assertIn("- Verdict: PASSED", summary)
        self.assertIn("Executed 3 tests, with 0 failures", summary)
        self.assertIn("areas stats; classes FooTests", summary)

    def test_the_summary_is_one_the_trains_own_reader_reads_as_passed(self):
        train = test_command.load_build_train()
        with mock.patch.object(test_command, "area_command", self.child(SUMMARY_PASSED, LOG_PASSED)):
            self.run_main()
        verdict, executed, failures, errors, _ = train.summarize((self.out / "run-summary.txt").read_text())
        self.assertEqual((verdict, executed, failures, errors), ("PASSED", "Executed 3 tests, with 0 failures", [], []))

    def test_a_failing_run_exits_one_and_lists_the_failure(self):
        train = test_command.load_build_train()
        with mock.patch.object(test_command, "area_command", self.child(SUMMARY_FAILED, None, status=1)):
            status, _ = self.run_main()
        self.assertEqual(status, 1)
        summary = (self.out / "summary.md").read_text()
        self.assertIn("- Verdict: FAILED", summary)
        self.assertIn("FAILED FooTests.testBar at Foo.swift:9: wrong", summary)
        verdict, _, failures, _, _ = train.summarize((self.out / "run-summary.txt").read_text())
        self.assertEqual((verdict, len(failures)), ("FAILED", 1))

    def test_a_host_that_restarted_fails_though_the_summary_says_passed(self):
        restarted = "Restarting after unexpected exit, crash, or test timeout\n" + LOG_PASSED
        with mock.patch.object(test_command, "area_command", self.child(SUMMARY_PASSED, restarted)):
            status, _ = self.run_main()
        self.assertEqual(status, 1)
        summary = (self.out / "run-summary.txt").read_text()
        self.assertTrue(summary.rstrip().splitlines()[-1].startswith("FAILED: the log shows the test host restarted"),
                        summary)

    def test_a_build_that_prints_nothing_is_a_failure_that_says_so(self):
        with mock.patch.object(test_command, "area_command", self.child("", None, status=1)):
            status, _ = self.run_main()
        self.assertEqual(status, 1)
        self.assertTrue((self.out / "run-summary.txt").read_text().rstrip().endswith("FAILED: the tests did not pass"))

    def test_a_run_past_its_time_limit_is_stopped_and_fails_with_the_reason(self):
        with mock.patch.object(test_command, "area_command", self.child(SUMMARY_PASSED, LOG_PASSED, sleep=60)):
            status, _ = self.run_main(limit_minutes=0.02)
        self.assertEqual(status, 1)
        self.assertIn("the run was stopped after 0.02 minutes", (self.out / "run-summary.txt").read_text())

    def test_a_request_may_shorten_the_time_limit_but_not_lengthen_it(self):
        for asked, expected in ((0.02, 0.02), (500, 5)):
            with self.subTest(asked=asked):
                self.write_request({"areas": ["stats"], "classes": [], "limit_minutes": asked})
                limits = []
                real_judge = runner.judge

                def spy(train, output, log, timed_out, limit):
                    limits.append(limit)
                    return real_judge(train, output, log, timed_out, limit)

                with mock.patch.object(runner, "judge", spy), \
                        mock.patch.object(test_command, "area_command", self.child(SUMMARY_PASSED, LOG_PASSED)):
                    self.run_main(limit_minutes=5)
                self.assertEqual(limits, [expected])

    def test_the_command_gets_the_requests_areas_classes_and_the_runners_jobs(self):
        seen = {}

        def spy(areas, classes, derived, log, jobs=3):
            seen.update(areas=areas, classes=classes, derived=derived, log=log, jobs=jobs)
            return self.child(SUMMARY_PASSED, LOG_PASSED)(areas, classes, derived, log)

        with mock.patch.object(test_command, "area_command", spy):
            self.run_main()
        self.assertEqual((seen["areas"], seen["classes"], seen["jobs"]), (["stats"], ["FooTests"], runner.RUNNER_JOBS))
        self.assertEqual(Path(seen["log"]).resolve(), (self.out / "run.log").resolve())


class ProgressTests(RunnerTestCase):
    """The runner says where a long run has got to, since a step's log is empty until it ends."""

    def test_a_slow_run_prints_the_last_line_of_its_log(self):
        log = self.folder / "live.log"
        log.write_text("Compiling Foo.swift\nCompiling Bar.swift\n")
        out = io.StringIO()
        with mock.patch.object(runner, "PROGRESS_SECONDS", 0.05), contextlib.redirect_stdout(out):
            finished = runner.threading.Event()
            thread = runner.threading.Thread(target=runner.print_progress, args=(log, finished))
            thread.start()
            runner.time.sleep(0.3)
            finished.set()
            thread.join(5)
        self.assertIn("last: Compiling Bar.swift", out.getvalue())
        self.assertIn("log 40 bytes", out.getvalue())

    def test_a_log_not_written_yet_is_said_so(self):
        out = io.StringIO()
        with mock.patch.object(runner, "PROGRESS_SECONDS", 0.05), contextlib.redirect_stdout(out):
            finished = runner.threading.Event()
            thread = runner.threading.Thread(target=runner.print_progress, args=(self.folder / "none.log", finished))
            thread.start()
            runner.time.sleep(0.2)
            finished.set()
            thread.join(5)
        self.assertIn("(nothing yet)", out.getvalue())


class FullSuiteTests(RunnerTestCase):
    """A request for the full suite, whose output is its log."""

    def test_the_full_suite_is_run_with_the_shared_command_and_its_log_is_summarised(self):
        self.write_request({"areas": [], "classes": [], "full": True})
        seen = {}

        def fake_full(derived, result_bundle=None):
            seen.update(derived=derived, bundle=result_bundle)
            program = f"import sys; sys.stdout.write({LOG_PASSED!r})"
            return [sys.executable, "-I", "-B", "-c", program]

        with mock.patch.object(test_command, "full_suite_command", fake_full):
            status, out = self.run_main()
        self.assertEqual(status, 0, out)
        self.assertEqual((self.out / "run.log").read_text(), LOG_PASSED)
        self.assertEqual(Path(seen["bundle"]).resolve(), (self.out / "result.xcresult").resolve())
        # The summary is run-area.py's own reading of that log.
        self.assertIn("Executed 3 tests", (self.out / "run-summary.txt").read_text())
        self.assertIn("the full suite", (self.out / "summary.md").read_text())


class RequestTests(RunnerTestCase):
    """Reading the request."""

    def test_missing_lists_and_flag_are_filled_in(self):
        self.write_request({})
        self.assertEqual(runner.read_request(self.request), {"areas": [], "classes": [], "full": False})

    def test_a_request_that_cannot_be_read_exits_two_and_says_so(self):
        self.request.write_text("{not json")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status, _ = self.run_main()
        self.assertEqual(status, 2)
        self.assertIn("cannot read the request", err.getvalue())

    def test_a_missing_request_exits_two(self):
        self.request = self.folder / "nothing.json"
        with contextlib.redirect_stderr(io.StringIO()):
            status, _ = self.run_main()
        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main()
