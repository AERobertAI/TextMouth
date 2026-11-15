"""Tests of merge_ios_shards.py, and of merge_shards.py reading the iPhone jobs when there are several.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import merge_ios_shards  # noqa: E402
import merge_shards  # noqa: E402


def build_summary(verdict="PASSED", errors=0, files=0, minutes=5.0, reasons=()):
    """The text run-ios-build.py writes."""
    return "\n".join([f"iOS build: {verdict}", f"Errors in the app: {errors} in {files} files",
                      "Built: scheme TextMouthiOS (...)", f"Minutes: {minutes}", *[f"Reason: {r}" for r in reasons]]) + "\n"


def test_summary(verdict="PASSED", unit=(0, 0, 0), ui=(2, 0, 0), seconds=100.0, extra=(), shard=None):
    """The text run-ios-ui-tests.py writes for a run of the two bundles (a bundle with zero ran is 'not asked')."""
    def bundle(kind, bundle_name, counts):
        return f"{kind} ({bundle_name}): " + (f"{counts[0]} ran, {counts[1]} skipped, {counts[2]} failed" if counts[0] else "not asked")
    tests = unit[0] + ui[0]
    lines = [f"iOS UI tests: {verdict}",
             f"Executed {tests} tests, with {unit[1] + ui[1]} tests skipped and {unit[2] + ui[2]} failures (0 unexpected) "
             f"in {seconds:.3f} ({seconds:.3f}) seconds",
             bundle("Unit tests", "TextMouthiOSTests", unit), bundle("Interface tests", "TextMouthiOSUITests", ui),
             "Classes: A", "Minutes: 9.0 (the simulator's set-up took 4.0)", *extra]
    return "\n".join(lines) + "\n"


class JoiningTests(unittest.TestCase):
    """merge_ios_shards.join on throwaway `ios-results-N` folders."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.ios = self.root / "ios"
        self.out = self.root / "joined"

    def job(self, number, build=None, tests=None, errors="", build_log="b", test_log="t"):
        """Writes one job's files; a None summary leaves its file out."""
        folder = self.ios / f"ios-results-{number}"
        folder.mkdir(parents=True)
        if build is not None:
            (folder / "ios-summary.txt").write_text(build)
        if tests is not None:
            (folder / "ios-ui-summary.txt").write_text(tests)
        (folder / "ios-errors.txt").write_text(errors)
        (folder / "ios.log").write_text(build_log)
        (folder / "ios-ui.log").write_text(test_log)

    def joined(self, name):
        """The text of a joined file."""
        return (self.out / name).read_text()

    def test_every_job_passing_is_one_passed_with_the_tests_added_up(self):
        self.job(1, build_summary(minutes=6.0), test_summary(ui=(3, 0, 0), seconds=300.0))
        self.job(2, build_summary(minutes=8.0), test_summary(unit=(19, 1, 0), ui=(2, 0, 0), seconds=200.0))
        merge_ios_shards.join(self.ios, self.out, 2)
        build, tests = self.joined("ios-summary.txt"), self.joined("ios-ui-summary.txt")
        self.assertTrue(build.startswith("iOS build: PASSED\nErrors in the app: 0 in 0 files\n"), build)
        self.assertIn("Minutes: 8.0 (the longest of 2 jobs)", build)
        self.assertTrue(tests.startswith("iOS UI tests: PASSED\nExecuted 24 tests, with 1 tests skipped and 0 failures"), tests)
        self.assertIn("Unit tests (TextMouthiOSTests): 19 ran, 1 skipped, 0 failed", tests)
        self.assertIn("Interface tests (TextMouthiOSUITests): 5 ran, 0 skipped, 0 failed", tests)
        self.assertIn("in 300.000 (300.000) seconds", tests, "the longest job's time")

    def test_one_failed_test_fails_the_join_and_is_kept_by_name(self):
        failed = "FAILED ReaderUITests.testA (TextMouthiOSUITests) at TextMouthiOSUITests/R.swift:9: nope"
        self.job(1, build_summary(), test_summary())
        self.job(2, build_summary(), test_summary(verdict="FAILED", ui=(2, 0, 1), extra=[failed, "Reason: 1 test(s) failed"]))
        merge_ios_shards.join(self.ios, self.out, 2)
        tests = self.joined("ios-ui-summary.txt")
        self.assertTrue(tests.startswith("iOS UI tests: FAILED\n"), tests)
        self.assertIn(failed, tests)
        self.assertIn("Reason: job 2 of 2: 1 test(s) failed", tests)

    def test_a_job_that_reported_nothing_is_named_and_the_others_passing_is_not_a_pass(self):
        self.job(1, build_summary(), test_summary())
        merge_ios_shards.join(self.ios, self.out, 2)
        self.assertTrue(self.joined("ios-summary.txt").startswith("iOS build: NOT RUN\n"))
        self.assertIn("iPhone job 2 of 2 reported nothing", self.joined("ios-summary.txt"))
        self.assertTrue(self.joined("ios-ui-summary.txt").startswith("iOS UI tests: NOT RUN\n"))
        self.assertIn("iPhone job 2 of 2 reported nothing", self.joined("ios-ui-summary.txt"))

    def test_no_job_reporting_at_all_is_not_run(self):
        merge_ios_shards.join(self.ios, self.out, 2)
        self.assertTrue(self.joined("ios-summary.txt").startswith("iOS build: NOT RUN\n"))
        self.assertTrue(self.joined("ios-ui-summary.txt").startswith("iOS UI tests: NOT RUN\n"))

    def test_compile_errors_of_every_job_are_listed_once_with_their_files_counted(self):
        error = "TextMouth/A.swift:1:2: error: bad"
        self.job(1, build_summary("FAILED", 1, 1), test_summary(verdict="NOT RUN"), errors=error + "\n")
        self.job(2, build_summary("FAILED", 2, 2), test_summary(verdict="NOT RUN"),
                 errors=error + "\nTextMouth/B.swift:3:4: error: worse\n")
        merge_ios_shards.join(self.ios, self.out, 2)
        self.assertEqual(self.joined("ios-errors.txt"), error + "\nTextMouth/B.swift:3:4: error: worse\n")
        self.assertIn("Errors in the app: 2 in 2 files", self.joined("ios-summary.txt"))
        self.assertTrue(self.joined("ios-ui-summary.txt").startswith("iOS UI tests: NOT RUN\n"))

    def test_a_job_dealt_no_class_does_not_change_a_pass(self):
        idle = "iOS UI tests: NOT ASKED\nReason: shard 3 of 3 was dealt no iPhone test class\n"
        self.job(1, build_summary(), test_summary())
        self.job(2, build_summary(), idle)
        merge_ios_shards.join(self.ios, self.out, 2)
        tests = self.joined("ios-ui-summary.txt")
        self.assertTrue(tests.startswith("iOS UI tests: PASSED\n"), tests)
        self.assertIn("Executed 2 tests", tests)

    def test_a_request_that_asked_for_no_iphone_tests_stays_not_asked(self):
        idle = "iOS UI tests: NOT ASKED\nReason: the request does not ask for the iPhone tests\n"
        self.job(1, build_summary(), idle)
        merge_ios_shards.join(self.ios, self.out, 1)
        tests = self.joined("ios-ui-summary.txt")
        self.assertTrue(tests.startswith("iOS UI tests: NOT ASKED\n"), tests)
        self.assertNotIn("Executed", tests)

    def test_the_logs_are_joined_under_headings_in_job_order(self):
        self.job(1, build_summary(), test_summary(), build_log="first build", test_log="first tests")
        self.job(2, build_summary(), test_summary(), build_log="second build", test_log="second tests")
        merge_ios_shards.join(self.ios, self.out, 2)
        log = self.joined("ios-ui.log")
        self.assertLess(log.index("iPhone job 1 of 2"), log.index("first tests"))
        self.assertLess(log.index("first tests"), log.index("iPhone job 2 of 2"))
        self.assertIn("second build", self.joined("ios.log"))

    def test_folders_are_found_by_their_number_and_other_names_are_ignored(self):
        self.job(1, build_summary(), test_summary())
        (self.ios / "something-else").mkdir()
        self.assertEqual(sorted(merge_ios_shards.shard_folders(self.ios)), [1])
        self.assertEqual(merge_ios_shards.shard_folders(self.root / "absent"), {})


class MergeShardsReadsSeveralJobsTests(unittest.TestCase):
    """merge_shards.merge with the iPhone jobs' folders: summary.md reads as it does for one job."""

    def test_the_summary_shows_the_joined_iphone_verdicts(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shard_one = root / "shards" / "shard-results-1"
            shard_one.mkdir(parents=True)
            (shard_one / "run-summary.txt").write_text("Executed 1 tests, with 0 tests skipped and 0 failures (0 unexpected) in 1.000 (1.000) seconds\nPASSED\n")
            (shard_one / "run.log").write_text("Test Case '-[A b]' passed (0.1 seconds).\n")
            for number in (1, 2):
                job = root / "ios" / f"ios-results-{number}"
                job.mkdir(parents=True)
                (job / "ios-summary.txt").write_text(build_summary())
                (job / "ios-ui-summary.txt").write_text(test_summary(ui=(2, 0, 0)))
            passed = merge_shards.merge(root / "shards", root / "out", 1, root / "ios", 2)
            self.assertTrue(passed, "the iPhone jobs never decide the Mac tests' verdict")
            summary = (root / "out" / "summary.md").read_text()
            self.assertIn("iOS build: PASSED", summary)
            self.assertIn("iOS UI tests: PASSED; executed 4 tests", summary)
            self.assertTrue((root / "out" / "ios-ui-summary.txt").read_text().startswith("iOS UI tests: PASSED"))

    def test_one_jobs_files_in_the_folder_itself_are_read_as_before(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "shards").mkdir()
            (root / "ios").mkdir()
            (root / "ios" / "ios-summary.txt").write_text(build_summary())
            (root / "ios" / "ios-ui-summary.txt").write_text(test_summary())
            merge_shards.merge(root / "shards", root / "out", 1, root / "ios")
            self.assertIn("iOS build: PASSED", (root / "out" / "summary.md").read_text())


if __name__ == "__main__":
    unittest.main()
