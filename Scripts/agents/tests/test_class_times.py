"""Tests of class_times.py: per-class times from an xcodebuild log, for shard.py.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import class_times  # noqa: E402

LOG = """Test Suite 'All tests' started at 2026-11-10 01:41:53.927.
Test Suite 'TextMouthProductionTests.xctest' started at 2026-11-10 01:41:53.929.
Test Suite 'FooTests' started at 2026-11-10 01:41:53.929.
Test Suite 'FooTests' passed at 2026-11-10 01:41:59.037.
\t Executed 12 tests, with 1 tests skipped and 0 failures (0 unexpected) in 5.100 (5.108) seconds
Test Suite 'TinyTests' passed at 2026-11-10 01:41:59.100.
\t Executed 3 tests, with 0 failures (0 unexpected) in 0.020 (0.021) seconds
Test Suite 'BarTests' failed at 2026-11-10 01:42:09.100.
\t Executed 4 tests, with 1 failures (1 unexpected) in 9.500 (9.600) seconds
Test Suite 'TextMouthProductionTests.xctest' passed at 2026-11-10 01:42:10.000.
\t Executed 19 tests, with 1 tests skipped and 1 failures (1 unexpected) in 14.620 (14.700) seconds
Test Suite 'All tests' passed at 2026-11-10 01:42:10.001.
\t Executed 19 tests, with 1 tests skipped and 1 failures (1 unexpected) in 14.620 (14.700) seconds
"""


class ClassTimesTests(unittest.TestCase):
    """Reading a log."""

    def test_each_class_gets_its_own_time_and_the_run_and_bundle_are_left_out(self):
        self.assertEqual(class_times.class_times(LOG), {"FooTests": 5.108, "TinyTests": 0.021, "BarTests": 9.6})

    def test_a_class_run_twice_keeps_its_longest_time(self):
        twice = LOG + LOG.replace("5.100 (5.108)", "7.000 (7.100)")
        self.assertEqual(class_times.class_times(twice)["FooTests"], 7.1)

    def test_a_log_with_no_suites_has_no_times(self):
        self.assertEqual(class_times.class_times("Compiling Foo.swift\n"), {})

    def test_the_file_leaves_out_classes_under_half_a_second_and_rounds(self):
        with tempfile.TemporaryDirectory() as folder:
            log, out = Path(folder) / "run.log", Path(folder) / "times.json"
            log.write_text(LOG)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(class_times.main([str(log), str(out)]), 0)
            self.assertEqual(json.loads(out.read_text()), {"BarTests": 9.6, "FooTests": 5.1})

    def test_without_an_out_file_the_times_are_printed_as_json(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "run.log"
            log.write_text(LOG)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                class_times.main([str(log)])
            self.assertEqual(json.loads(out.getvalue()), {"BarTests": 9.6, "FooTests": 5.1})

    def test_a_missing_log_is_an_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(class_times.main(["/nonexistent/run.log"]), 2)

    def test_the_times_file_in_the_repository_is_what_shard_py_reads(self):
        import shard
        times = shard.load_times()
        self.assertGreater(len(times), 100)
        self.assertTrue(all(isinstance(seconds, float) and seconds > 0 for seconds in times.values()))


if __name__ == "__main__":
    unittest.main()
