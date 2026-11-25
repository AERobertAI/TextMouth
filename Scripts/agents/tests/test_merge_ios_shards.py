"""Tests of merge_ios_shards.py, and of merge_shards.py reading the iPhone jobs when there are several.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import merge_ios_shards  # noqa: E402
import merge_shards  # noqa: E402


def build_summary(verdict="PASSED", errors=0, files=0, minutes=5.0, reasons=(), sizes=()):
    """The text run-ios-build.py writes (`sizes`: the size lines it adds when the request asks for the app's size)."""
    return "\n".join([f"iOS build: {verdict}", f"Errors in the app: {errors} in {files} files",
                      "Built: scheme TextMouthiOS (...)", f"Minutes: {minutes}", *sizes,
                      *[f"Reason: {r}" for r in reasons]]) + "\n"


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


class JoinCase(unittest.TestCase):
    """A throwaway folder for the iPhone jobs' results, with a way to write one job's files and to read a joined one."""

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


class JoiningTests(JoinCase):
    """merge_ios_shards.join on throwaway `ios-results-N` folders."""

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

    def test_the_size_lines_come_through_from_the_first_job_that_has_them(self):
        sizes = ["Size: iPhone app: 20.0 MB (20,000,000 bytes) in 90 files, within the 30 MB limit.",
                 "Size detail: 9.0 MB (9,000,000 bytes)  TextMouth"]
        self.job(1, build_summary(), test_summary())
        self.job(2, build_summary(sizes=sizes), test_summary())
        self.job(3, build_summary(sizes=["Size: another job's"]), test_summary())
        merge_ios_shards.join(self.ios, self.out, 3)
        joined = self.joined("ios-summary.txt").splitlines()
        self.assertEqual([line for line in joined if line.startswith("Size")], sizes)
        self.assertEqual(merge_ios_shards.size_lines(joined), sizes)

    def test_a_request_that_did_not_ask_for_the_size_joins_with_no_size_line(self):
        self.job(1, build_summary(), test_summary())
        merge_ios_shards.join(self.ios, self.out, 1)
        self.assertEqual(merge_ios_shards.size_lines(self.joined("ios-summary.txt").splitlines()), [])

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


class AJobThatCameAloneTests(JoinCase):
    """The download leaves one artifact's files in the folder itself, not in a folder of its own."""

    def test_files_in_the_folder_itself_are_the_job_their_summary_names_and_the_others_reported_nothing(self):
        self.ios.mkdir()
        (self.ios / "ios-summary.txt").write_text(build_summary())
        (self.ios / "ios-ui-summary.txt").write_text(test_summary(extra=["Shard: 2 of 2"]))
        self.assertEqual(sorted(merge_ios_shards.shard_folders(self.ios, 2)), [2])
        merge_ios_shards.join(self.ios, self.out, 2)
        self.assertIn("iPhone job 1 of 2 reported nothing", self.joined("ios-ui-summary.txt"))
        self.assertTrue(self.joined("ios-ui-summary.txt").startswith("iOS UI tests: NOT RUN"))

    def test_with_one_job_expected_the_files_are_left_to_the_single_job_reading(self):
        self.ios.mkdir()
        (self.ios / "ios-summary.txt").write_text(build_summary())
        self.assertEqual(merge_ios_shards.shard_folders(self.ios, 1), {})


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


SIZE_LINES = ["Size: iPhone app: 16.4 MB (16,392,677 bytes) in 48 files, within the 30 MB limit.",
              "Size: iPhone app IPA: 10.4 MB (10,361,401 bytes).",
              "Size detail: 13.2 MB (13,176,592 bytes)  TextMouth"]


class SizeJobTests(JoinCase):
    """The size job's result (run-ios-build.py --size-only, its own artifact) joined into the iPhone build's summary."""

    def size_job(self, summary=None, log="the device build's last lines"):
        """Writes the size job's folder: a None summary leaves its file out, as a job that failed before the build does."""
        folder = self.root / "size"
        folder.mkdir()
        if summary is not None:
            (folder / merge_ios_shards.SIZE_SUMMARY_FILE).write_text(summary)
        (folder / "ios.log").write_text(log)
        return folder

    def joined_with(self, size_dir, jobs=2):
        """Joins `jobs` passing iPhone jobs, then the size job's folder; returns the joined summary's lines."""
        for number in range(1, jobs + 1):
            self.job(number, build_summary(), test_summary())
        merge_ios_shards.join(self.ios, self.out, jobs)
        merge_ios_shards.join_size(size_dir, self.out)
        return self.joined("ios-summary.txt").splitlines()

    def test_the_size_jobs_lines_are_read_by_the_trains_as_a_jobs_own_would_be(self):
        lines = self.joined_with(self.size_job("\n".join(SIZE_LINES) + "\n"))
        self.assertEqual(lines[0], "iOS build: PASSED", "the size never changes the build's verdict")
        self.assertEqual(merge_ios_shards.size_lines(lines), SIZE_LINES)

    def test_the_size_jobs_log_follows_the_builds_under_a_heading(self):
        self.joined_with(self.size_job("\n".join(SIZE_LINES) + "\n", log="LAST LINES"))
        log = self.joined("ios.log")
        self.assertIn("===== iPhone job 1 of 2: build log =====", log)
        self.assertLess(log.index("iPhone job 2 of 2"), log.index("===== size job: device build ====="))
        self.assertTrue(log.rstrip().endswith("LAST LINES"))

    def test_a_size_job_that_reported_nothing_is_a_not_measured_line_the_train_can_read(self):
        lines = self.joined_with(self.size_job(summary=None))
        sizes = merge_ios_shards.size_lines(lines)
        self.assertEqual(len(sizes), 1)
        self.assertTrue(sizes[0].startswith("Size: not measured: the size job reported nothing"), sizes)
        self.assertEqual(lines[0], "iOS build: PASSED")

    def test_a_size_job_that_found_the_request_did_not_ask_adds_nothing(self):
        lines = self.joined_with(self.size_job(""))
        self.assertEqual(merge_ios_shards.size_lines(lines), [])
        self.assertNotIn("size job", self.joined("ios.log"))

    def test_a_failed_measurement_comes_through_as_the_jobs_one_line(self):
        failed = "Size: not measured: the device build failed (xcodebuild status 65, 1 errors)."
        self.assertEqual(merge_ios_shards.size_lines(self.joined_with(self.size_job(failed + "\n"))), [failed])

    def test_the_lines_are_added_to_a_summary_that_says_the_iphone_build_did_not_run(self):
        # merge_shards.merge_ios writes this when no iPhone job reported; the size lines still follow it.
        self.out.mkdir()
        (self.out / "ios-summary.txt").write_text("iOS build: NOT RUN\nReason: its job reported nothing")
        merge_ios_shards.join_size(self.size_job("\n".join(SIZE_LINES) + "\n"), self.out)
        lines = self.joined("ios-summary.txt").splitlines()
        self.assertEqual(lines[:2], ["iOS build: NOT RUN", "Reason: its job reported nothing"])
        self.assertEqual(merge_ios_shards.size_lines(lines), SIZE_LINES)

    def test_a_run_that_did_not_ask_for_the_size_never_says_size_not_measured(self):
        for request in ('{}', '{"ios_size": false}', '{"ios_size": "yes"}'):
            with self.subTest(request=request), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                shard = root / "shards" / "shard-results-1"
                shard.mkdir(parents=True)
                (shard / "request.json").write_text(request)
                (root / "ios").mkdir()
                (root / "ios" / "ios-summary.txt").write_text(build_summary())
                (root / "ios" / "ios-ui-summary.txt").write_text(test_summary())
                (root / "size").mkdir()  # a size folder with no result in it, as a skipped size job leaves
                merge_shards.merge(root / "shards", root / "out", 1, root / "ios", 1, root / "size")
                self.assertNotIn("Size", (root / "out" / "ios-summary.txt").read_text())

    def test_merge_shards_passes_the_size_folder_on_and_the_command_line_takes_it_last(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "shards").mkdir()
            (root / "ios").mkdir()
            (root / "ios" / "ios-summary.txt").write_text(build_summary())
            (root / "ios" / "ios-ui-summary.txt").write_text(test_summary())
            (root / "size").mkdir()
            (root / "size" / merge_ios_shards.SIZE_SUMMARY_FILE).write_text("\n".join(SIZE_LINES) + "\n")
            shard = root / "shards" / "shard-results-1"
            shard.mkdir()
            (shard / "request.json").write_text('{"ios_size": true}')
            with contextlib.redirect_stdout(io.StringIO()):
                merge_shards.main([str(root / "shards"), str(root / "out"), "1", str(root / "ios"), "1", str(root / "size")])
            lines = (root / "out" / "ios-summary.txt").read_text().splitlines()
            self.assertEqual(merge_ios_shards.size_lines(lines), SIZE_LINES)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(merge_shards.main(["a", "b", "1", "c", "1", "d", "e"]), 2)


if __name__ == "__main__":
    unittest.main()
