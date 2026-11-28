"""Tests of how the readers of a test log treat a test that is tried again (-retry-tests-on-failure).

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The logs are in retry_logs.py, trimmed from real runs. Every reader must count a test that passed on a
later try as passed, list it apart (RETRIED), and still fail a test that failed on every try, with its message.
"""
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import retry_logs
from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import merge_shards  # noqa: E402
import run_suite  # noqa: E402
import test_command  # noqa: E402
import test_tries  # noqa: E402
import testkit_path  # noqa: F401,E402  (puts Scripts/test on the path)
import testkit  # noqa: E402

ROOT = Path("/not/a/checkout")

# A final try's line, to turn a log's pass on try two into a failure on every try.
PASS_LINE = "Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' passed (0.001 seconds)."
FAIL_LINE = PASS_LINE.replace("passed", "failed")


def summary_of(text):
    """The run-area.py summary lines of a log."""
    return testkit.format_summary(testkit.summarize_log(text, ROOT))


class TriesTests(unittest.TestCase):
    """test_tries.py reads each test's last result as its outcome."""

    def test_a_test_that_passed_on_try_two_is_retried_and_passed(self):
        found = test_tries.outcomes(retry_logs.PASSED_ON_TRY_TWO)
        flaky = found["CountWordingTests.testFlaky"]
        self.assertEqual((flaky.result, flaky.tries, flaky.allowed), ("passed", 2, 3))
        self.assertEqual([test_tries.retried_line(o) for o in test_tries.retried(found)],
                         ["RETRIED CountWordingTests.testFlaky passed on try 2 of 3"])

    def test_a_test_that_failed_every_try_is_failed_with_three_tries(self):
        always = test_tries.outcomes(retry_logs.FAILED_ALL_TRIES_AND_A_CRASH)["CountWordingTests.testAlways"]
        self.assertEqual((always.result, always.tries), ("failed", 3))

    def test_counts_are_of_final_outcomes(self):
        self.assertEqual(test_tries.counts(test_tries.outcomes(retry_logs.PASSED_ON_TRY_TWO)), (2, 0, 0))

    def test_a_log_that_never_retried_has_no_iterations(self):
        self.assertFalse(test_tries.has_retries("Test Case '-[M.C t]' started.\nTest Case '-[M.C t]' passed (1 seconds).\n"))
        self.assertTrue(test_tries.has_retries(retry_logs.PASSED_ON_TRY_TWO))


class RunAreaSummaryTests(unittest.TestCase):
    """testkit's summary, which every train and runner result is made from."""

    def test_a_pass_on_try_two_passes_and_is_listed_apart(self):
        summary = testkit.summarize_log(retry_logs.PASSED_ON_TRY_TWO, ROOT)
        self.assertTrue(summary.passed)
        lines = testkit.format_summary(summary)
        self.assertEqual(lines[0], "Executed 2 tests, with 0 tests skipped and 0 failures (0 unexpected) in 0.170 (0.172) seconds")
        self.assertIn("RETRIED CountWordingTests.testFlaky passed on try 2 of 3", lines)
        self.assertFalse(any(line.startswith("FAILED ") and "testFlaky" in line for line in lines))
        self.assertEqual(lines[-1], "PASSED")

    def test_a_test_that_failed_all_three_tries_still_fails_with_its_message(self):
        lines = summary_of(retry_logs.FAILED_ALL_TRIES_AND_A_CRASH)
        failed = [line for line in lines if line.startswith("FAILED ")]
        self.assertEqual(len(failed), 1)
        self.assertIn("CountWordingTests.testAlways at CountWordingTests.swift:126", failed[0])
        self.assertIn("fails on every try", failed[0])
        self.assertIn("RETRIED CountWordingTests.testFlaky passed on try 2 of 3", lines)
        self.assertEqual(lines[-1], "FAILED")

    def test_a_failed_result_with_text_in_front_of_it_still_names_the_test(self):
        """Another process's log text before a result line (no error line printed) must not hide which test failed."""
        lines = summary_of(
            "Test Case '-[TextMouthProductionTests.AUITests testX]' started.\n"
            "2026-11-22 09:10:26.3+0000 TextMouth[1:2] [AMCP] skippingTest Case "
            "'-[TextMouthProductionTests.AUITests testX]' failed (0.161 seconds).\n"
            "Executed 1 test, with 1 failure (0 unexpected) in 0.2 (0.2) seconds\n")
        self.assertIn("FAILED AUITests.testX", lines)

    def test_a_crash_is_still_a_crash_and_a_failure(self):
        lines = summary_of(retry_logs.FAILED_ALL_TRIES_AND_A_CRASH)
        self.assertTrue(any(line.startswith("CRASH") for line in lines))

    def test_a_crash_during_a_retry_fails_the_run(self):
        summary = testkit.summarize_log(retry_logs.CRASH_DURING_A_RETRY, ROOT)
        self.assertFalse(summary.passed)
        self.assertIsNotNone(summary.crash)

    def test_the_executed_line_counts_tests_not_tries(self):
        summary = testkit.summarize_log(retry_logs.FAILED_ALL_TRIES_AND_A_CRASH, ROOT)
        # testBooks, testAlways and testFlaky have results: 3 tests (xcodebuild says 8), 1 final failure (it says 4).
        self.assertEqual((summary.executed, summary.failures), (3, 1))

    def test_a_log_without_retries_is_read_as_before(self):
        log = ("Test Case '-[M.C testOne]' passed (0.1 seconds).\n\t Executed 13 tests, with 1 test skipped and 0 failures"
               " (0 unexpected) in 0.5 (0.6) seconds\n** TEST SUCCEEDED **\n")
        lines = summary_of(log)
        self.assertEqual(lines[0], "Executed 13 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.5 (0.6) seconds")
        self.assertFalse(any(line.startswith("RETRIED") for line in lines))


class TrainAndSuiteReadingTests(unittest.TestCase):
    """build-train.py's and run_suite.py's reading of a log."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.train = test_command.load_build_train()

    def log(self, text):
        path = self.folder / "run.log"
        path.write_text(text)
        return path

    def test_a_pass_on_a_later_try_passes_though_its_suite_line_says_failed(self):
        self.assertTrue(self.train.tests_all_passed(self.log(retry_logs.PASSED_ON_TRY_TWO)))

    def test_a_test_that_failed_every_try_does_not_pass(self):
        # The same log with the second try failing too: its last result is a failure.
        self.assertFalse(self.train.tests_all_passed(self.log(retry_logs.PASSED_ON_TRY_TWO.replace(PASS_LINE, FAIL_LINE))))

    def test_a_restart_during_a_retry_does_not_pass(self):
        self.assertFalse(self.train.tests_all_passed(self.log(retry_logs.CRASH_DURING_A_RETRY)))

    def test_the_suite_judge_passes_a_pass_on_a_later_try_and_names_it(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(run_suite.judge_log(str(self.log(retry_logs.PASSED_ON_TRY_TWO))), 0)
        self.assertIn("RETRIED CountWordingTests.testFlaky passed on try 2 of 3", out.getvalue())

    def test_the_suite_judge_fails_a_test_that_failed_every_try(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(run_suite.judge_log(str(self.log(retry_logs.FAILED_ALL_TRIES_AND_A_CRASH))), 1)

    def test_the_trains_summary_keeps_the_retried_tests_apart(self):
        output = "\n".join(summary_of(retry_logs.PASSED_ON_TRY_TWO))
        verdict, executed, failures, _, _ = self.train.summarize(output)
        self.assertEqual((verdict, failures), ("PASSED", []))
        self.assertTrue(executed.startswith("Executed 2 tests"))
        self.assertEqual(self.train.retried_tests(output), ["RETRIED CountWordingTests.testFlaky passed on try 2 of 3"])


class MergedShardsTests(unittest.TestCase):
    """merge_shards.py joins shards that retried."""

    def test_the_merge_counts_final_outcomes_and_lists_the_retried_apart(self):
        with tempfile.TemporaryDirectory() as folder:
            shards, out = Path(folder) / "shards", Path(folder) / "out"
            for number in (1, 2):
                shard = shards / f"shard-results-{number}"
                shard.mkdir(parents=True)
                (shard / "run-summary.txt").write_text("\n".join(summary_of(retry_logs.PASSED_ON_TRY_TWO)) + "\n")
                (shard / "run.log").write_text(retry_logs.PASSED_ON_TRY_TWO)
                (shard / "request.json").write_text(json.dumps({"areas": ["all"], "shards": 2}))
            self.assertTrue(merge_shards.merge(shards, out, 2))
            summary = (out / "run-summary.txt").read_text()
            self.assertIn("Executed 4 tests, with 0 tests skipped and 0 failures", summary)
            self.assertEqual(summary.count("RETRIED CountWordingTests.testFlaky passed on try 2 of 3"), 2)
            text = (out / "summary.md").read_text()
            self.assertIn("- Failures and errors: 0", text)
            self.assertIn("- Passed on a later try: 2", text)
            self.assertTrue(test_command.load_build_train().tests_all_passed(out / "run.log"))


if __name__ == "__main__":
    unittest.main()
