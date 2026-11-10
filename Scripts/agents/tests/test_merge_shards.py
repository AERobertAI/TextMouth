"""Tests of merge_shards.py: the shards' results joined into the one result the Mac reads.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The merged files are read back with the readers the Mac uses: the train's `summarize`, and run_suite.py's
and the train's reading of a log.
"""
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import merge_shards  # noqa: E402
import run_suite  # noqa: E402
import test_command  # noqa: E402

PASSING = "Executed {n} tests, with {s} tests skipped and 0 failures (0 unexpected) in {t} ({t}) seconds\nPASSED in 5 seconds\n"
FAILING = ("Executed 10 tests, with 0 tests skipped and 1 failures (1 unexpected) in 30.0 (30.0) seconds\n"
           "FAILED FooTests.testBar at Foo.swift:9: wrong\nFAILED in 5 seconds\n")
LOG_PASSED = ("Test Suite 'Selected tests' passed at 2026-11-09 10:00:00.000.\n"
              "\t Executed 5 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n** TEST SUCCEEDED **\n")
LOG_FAILED = ("Test Suite 'Selected tests' failed at 2026-11-09 10:00:00.000.\n"
              "\t Executed 10 tests, with 1 failures (1 unexpected) in 1.0 (1.0) seconds\n** TEST FAILED **\n")


class MergeShardsTests(unittest.TestCase):
    """Shard folders made in a temporary directory."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.shards = Path(folder.name) / "shards"
        self.out = Path(folder.name) / "out"
        self.train = test_command.load_build_train()

    def shard(self, number, summary, log=LOG_PASSED, request=True):
        """Makes the folder an uploaded shard artifact downloads into."""
        folder = self.shards / f"shard-results-{number}"
        folder.mkdir(parents=True)
        if summary is not None:
            (folder / "run-summary.txt").write_text(summary)
            (folder / "run.log").write_text(log)
            if request:
                (folder / "request.json").write_text(json.dumps({"areas": ["all"], "shards": 3}))

    def merged(self, expected):
        """Merges; returns (passed, summary text)."""
        passed = merge_shards.merge(self.shards, self.out, expected)
        return passed, (self.out / "run-summary.txt").read_text()

    def test_passing_shards_add_up_to_one_passing_result(self):
        for number, (n, s, t) in enumerate([(100, 2, 30.0), (200, 3, 50.5), (50, 0, 10.0)], 1):
            self.shard(number, PASSING.format(n=n, s=s, t=t))
        passed, summary = self.merged(3)
        self.assertTrue(passed)
        verdict, executed, failures, errors, _ = self.train.summarize(summary)
        self.assertEqual(verdict, "PASSED")
        self.assertIn("Executed 350 tests, with 5 tests skipped and 0 failures", executed)
        self.assertIn("in 50.500 (50.500) seconds", executed, "the wall time is the longest shard's")
        self.assertEqual((failures, errors), ([], []))

    def test_one_failing_shard_fails_the_run_and_its_failure_is_listed(self):
        self.shard(1, PASSING.format(n=100, s=0, t=20.0))
        self.shard(2, FAILING, log=LOG_FAILED)
        passed, summary = self.merged(2)
        self.assertFalse(passed)
        verdict, executed, failures, _, _ = self.train.summarize(summary)
        self.assertEqual(verdict, "FAILED")
        self.assertEqual(failures, ["FAILED FooTests.testBar at Foo.swift:9: wrong"])
        self.assertIn("Executed 110 tests", executed)
        self.assertIn("1 failures", executed)
        self.assertEqual(failures and self.train.failure_class(failures[0]), "FooTests")

    def test_a_shard_that_reported_nothing_fails_the_run_and_is_named(self):
        self.shard(1, PASSING.format(n=100, s=0, t=20.0))
        self.shard(2, None)  # A folder with no summary: its job failed before the tests.
        passed, summary = self.merged(2)
        self.assertFalse(passed)
        self.assertIn("shard 2 of 2 reported nothing", summary)

    def test_a_shard_with_no_folder_at_all_fails_the_run(self):
        self.shard(1, PASSING.format(n=100, s=0, t=20.0))
        passed, summary = self.merged(3)
        self.assertFalse(passed)
        self.assertIn("shard 2 of 3 reported nothing", summary)
        self.assertIn("shard 3 of 3 reported nothing", summary)

    def test_a_shard_that_ran_no_tests_does_not_pass_the_run(self):
        self.shard(1, "PASSED in 1 seconds\n")
        passed, summary = self.merged(1)
        self.assertFalse(passed)
        self.assertIn("ran no tests", summary)

    def test_compile_errors_and_crashes_are_kept_and_the_closing_lines_are_not_repeated(self):
        self.shard(1, "no tests ran\nERROR Broken.swift:1:1: error: nope\nCRASH the host restarted\nFAILED in 9 seconds\n")
        _, summary = self.merged(1)
        lines = summary.splitlines()
        self.assertIn("ERROR Broken.swift:1:1: error: nope", lines)
        self.assertIn("CRASH the host restarted", lines)
        self.assertNotIn("FAILED in 9 seconds", lines)
        self.assertEqual(lines[-1], "FAILED")

    def test_the_merged_log_is_judged_by_the_whole_run_not_the_last_shard(self):
        # The first shard failed and the last passed: reading only the last shard's tail would say PASSED.
        self.shard(1, FAILING, log=LOG_FAILED)
        # A long second log, so that the first shard's failure is far from the end, out of the tail a reader looks at.
        self.shard(2, PASSING.format(n=5, s=0, t=1.0), log="Test Case '-[FooTests testBar]' passed (0.1 seconds).\n" * 200 + LOG_PASSED)
        self.merged(2)
        log = self.out / "run.log"
        text = log.read_text()
        self.assertGreater(len(text) - text.index("** TEST FAILED **"), 4096, "the first failure must be out of the tail")
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(run_suite.judge_log(str(log)), 1)
        self.assertIn("xcodebuild says TEST FAILED", out.getvalue())

    def test_a_passing_merged_log_passes_the_suite_judge(self):
        self.shard(1, PASSING.format(n=5, s=0, t=1.0))
        self.shard(2, PASSING.format(n=5, s=0, t=1.0))
        self.merged(2)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(run_suite.judge_log(str(self.out / "run.log")), 0)

    def test_a_restarted_host_in_any_shard_fails_the_merged_log(self):
        self.shard(1, PASSING.format(n=5, s=0, t=1.0), log="Restarting after unexpected exit, crash, or test timeout\n" + LOG_PASSED)
        self.shard(2, PASSING.format(n=5, s=0, t=1.0))
        self.merged(2)
        self.assertFalse(self.train.tests_all_passed(self.out / "run.log"))

    def test_tests_are_counted_from_the_logs_results_not_the_closing_line_after_restarts(self):
        # The closing Executed line counts only the last launch of a host that restarted.
        cases = "".join(f"Test Case '-[FooTests testNumber{i}]' passed (0.1 seconds).\n" for i in range(50))
        cases += "Test Case '-[FooTests testSkipped]' skipped (0.0 seconds).\nTest Case '-[FooTests testBad]' failed (0.1 seconds).\n"
        self.shard(1, PASSING.format(n=7, s=0, t=1.0), log=cases + LOG_PASSED)
        _, summary = self.merged(1)
        self.assertIn("Executed 52 tests, with 1 tests skipped and 1 failures", summary)

    def test_a_shard_stopped_at_its_time_limit_says_so_in_the_merged_problem(self):
        self.shard(1, "FAILED in 80 minutes\nFAILED: the run was stopped after 80 minutes\nFAILED\n")
        _, summary = self.merged(1)
        self.assertIn("shard 1 of 1 did not pass (the run was stopped after 80 minutes)", summary)

    def test_the_count_of_entries_the_runner_left_out_is_kept_in_the_merged_summary(self):
        for number, left_out in ((1, 3), (2, 5)):
            self.shard(number, PASSING.format(n=5, s=0, t=1.0))
            (self.shards / f"shard-results-{number}" / "summary.md").write_text(
                f"# Test build\n\n- Left out on the runner: {left_out} tests or classes (Scripts/agents/runner-skips.conf)\n")
        self.merged(2)
        self.assertIn("- Left out on the runner: 8 tests or classes", (self.out / "summary.md").read_text())

    def test_the_four_files_are_written_and_the_request_is_one_shards(self):
        self.shard(1, PASSING.format(n=5, s=0, t=1.0))
        self.merged(1)
        self.assertEqual(sorted(path.name for path in self.out.iterdir()),
                         ["request.json", "run-summary.txt", "run.log", "summary.md"])
        self.assertEqual(json.loads((self.out / "request.json").read_text())["areas"], ["all"])
        self.assertIn("Shards: 1", (self.out / "summary.md").read_text())

    def test_shards_are_numbered_by_their_folder_not_listed_in_name_order(self):
        # shard-results-10 sorts before shard-results-2 as text.
        for number in (1, 2, 10):
            self.shard(number, PASSING.format(n=1, s=0, t=1.0))
        passed, summary = self.merged(10)
        self.assertFalse(passed)  # Shards 3 to 9 are missing, and said so by number.
        self.assertIn("shard 3 of 10 reported nothing", summary)
        self.assertNotIn("shard 10 of 10 reported nothing", summary)
        self.assertNotIn("shard 2 of 10 reported nothing", summary)

    def test_one_artifact_downloaded_without_a_folder_of_its_own_is_the_only_shard(self):
        # actions/download-artifact puts a lone matching artifact's files straight into the target folder.
        self.shards.mkdir(parents=True)
        (self.shards / "run-summary.txt").write_text(PASSING.format(n=40, s=1, t=2.0))
        (self.shards / "run.log").write_text(LOG_PASSED)
        (self.shards / "request.json").write_text(json.dumps({"areas": ["stats"]}))
        passed, summary = self.merged(1)
        self.assertTrue(passed, summary)
        self.assertIn("Executed 40 tests", summary)
        self.assertEqual(json.loads((self.out / "request.json").read_text())["areas"], ["stats"])

    def test_a_lone_artifact_says_which_shard_it_is_by_its_request(self):
        self.shards.mkdir(parents=True)
        (self.shards / "run-summary.txt").write_text(PASSING.format(n=40, s=1, t=2.0))
        (self.shards / "run.log").write_text(LOG_PASSED)
        (self.shards / "request.json").write_text(json.dumps({"shard": "2 of 3"}))
        passed, summary = self.merged(3)
        self.assertFalse(passed)
        self.assertIn("shard 1 of 3 reported nothing", summary)
        self.assertIn("shard 3 of 3 reported nothing", summary)
        self.assertNotIn("shard 2 of 3 reported nothing", summary, "shard 2 is the one that came")

    def test_a_missing_shards_folder_fails_the_run(self):
        passed, summary = self.merged(2)
        self.assertFalse(passed)
        self.assertIn("shard 1 of 2 reported nothing", summary)


if __name__ == "__main__":
    unittest.main()
