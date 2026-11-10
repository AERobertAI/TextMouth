"""Tests of test_command.py: the one place the hosted tests' command is made.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The train, the full suite, and the GitHub workflow all take the command from here, so these
tests pin it: what the Mac's train and suite ran before November 9, 2026 is what they run now.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from heavy_lock_case import HeavyLockTestCase  # noqa: F401  (puts the scripts' folder on the path)
import run_suite  # noqa: E402
import test_command  # noqa: E402

# The full suite's command as run_suite.py spelled it before it took the command from test_command.
OLD_SUITE_COMMAND = ["xcodebuild", "test", "-project", "TextMouth.xcodeproj", "-scheme", "TextMouth",
                     "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                     "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete",
                     "-derivedDataPath", "build/DerivedData"]


class FullSuiteCommandTests(unittest.TestCase):
    """The orchestrator's full suite."""

    def test_the_command_is_what_run_suite_ran_before(self):
        self.assertEqual(test_command.full_suite_command("build/DerivedData"), OLD_SUITE_COMMAND)

    def test_run_suite_takes_its_command_from_here(self):
        self.assertEqual(run_suite.COMMAND, OLD_SUITE_COMMAND)

    def test_a_result_bundle_is_added_at_the_end_when_asked_for(self):
        command = test_command.full_suite_command("/d", "/r/result.xcresult")
        self.assertEqual(command[-2:], ["-resultBundlePath", "/r/result.xcresult"])
        self.assertEqual(command[:-2], [*OLD_SUITE_COMMAND[:-1], "/d"])

    def test_the_suite_signs_nothing_and_does_not_run_in_parallel(self):
        command = test_command.full_suite_command("/d")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")


class AreaCommandTests(unittest.TestCase):
    """The train's run of areas and classes."""

    def test_areas_and_classes_make_the_trains_command(self):
        self.assertEqual(
            test_command.area_command(["feeds", "logs"], ["FooTests", "BarTests"], "/d", "/l"),
            ["python3", "-I", "Scripts/test/run-area.py", "feeds", "logs", "--classes", "FooTests,BarTests",
             "--jobs", "2", "--no-slot", "--derived-data", "/d", "--log", "/l"])

    def test_all_stands_for_everything_and_drops_the_classes(self):
        command = test_command.area_command(["feeds", "all"], ["FooTests"], "/d", "/l")
        self.assertEqual(command[3:5], ["all", "--jobs"])
        self.assertNotIn("--classes", command)

    def test_classes_alone_need_no_area(self):
        command = test_command.area_command([], ["FooTests"], "/d", "/l")
        self.assertEqual(command[2:5], ["Scripts/test/run-area.py", "--classes", "FooTests"])

    def test_jobs_and_the_build_slot_are_the_callers_to_choose(self):
        command = test_command.area_command(["feeds"], [], "/d", "/l", jobs=3, slot=True)
        self.assertEqual(command[command.index("--jobs") + 1], "3")
        self.assertNotIn("--no-slot", command)

    def test_extra_xcodebuild_arguments_are_passed_with_an_equals_sign(self):
        command = test_command.area_command(["feeds"], [], "/d", "/l", extra=["-test-timeouts-enabled", "YES"])
        self.assertEqual(command[-2:], ["--xcodebuild-arg=-test-timeouts-enabled", "--xcodebuild-arg=YES"])

    def test_extra_arguments_reach_the_full_suite_before_its_result_bundle(self):
        command = test_command.full_suite_command("/d", "/r.xcresult", extra=["-test-timeouts-enabled", "YES"])
        self.assertEqual(command[-4:], ["-test-timeouts-enabled", "YES", "-resultBundlePath", "/r.xcresult"])

    def test_the_command_is_made_of_plain_strings(self):
        command = test_command.area_command(["feeds"], [], Path("/d"), Path("/l"))
        self.assertTrue(all(isinstance(word, str) for word in command))


class TrainRunsTheSharedCommandTests(unittest.TestCase):
    """build-train.py's local run_tests builds its command with area_command."""

    def test_the_local_train_runs_what_it_ran_before_November_9(self):
        train = test_command.load_build_train()
        with tempfile.TemporaryDirectory() as folder:
            train_dir = Path(folder)
            seen = {}

            def fake_run(command, **more):
                seen["command"] = command
                return SimpleNamespace(stdout="Executed 1 tests, with 0 failures\nPASSED in 1 seconds\n", stderr="")

            with mock.patch.object(train, "DERIVED", Path("/derived")), \
                    mock.patch.object(train, "known_names", lambda cwd: ({"all", "feeds"}, {"FooTests"})), \
                    mock.patch.object(train.subprocess, "run", fake_run):
                output = train.run_tests([{"areas": ["feeds"], "classes": ["FooTests"]}], train_dir)
            self.assertEqual(seen["command"],
                             ["python3", "-I", "Scripts/test/run-area.py", "feeds", "--classes", "FooTests",
                              "--jobs", "2", "--no-slot", "--derived-data", "/derived",
                              "--log", str(train_dir / "run.log")])
            self.assertIn("PASSED", output)
            self.assertEqual((train_dir / "run-summary.txt").read_text(), output)


class LoadBuildTrainTests(unittest.TestCase):
    """Loading build-train.py by path must not disturb the caller."""

    def test_the_callers_command_line_is_put_back(self):
        before = list(sys.argv)
        test_command.load_build_train()
        self.assertEqual(sys.argv, before)

    def test_it_leaves_no_pycache_folder_in_the_repository(self):
        agents = Path(test_command.AGENTS)
        test_command.load_build_train()
        self.assertFalse((agents / "__pycache__").exists())

    def test_the_trains_reading_of_a_log_is_reachable(self):
        train = test_command.load_build_train()
        self.assertTrue(all(callable(getattr(train, name)) for name in
                            ("summarize", "tests_have_ended", "tests_all_passed", "watch_for_a_hung_run")))


class DryRunTests(unittest.TestCase):
    """The area command is one run-area.py really accepts."""

    def test_run_area_accepts_the_command_the_runner_builds(self):
        root = Path(test_command.AGENTS).parents[1]
        if not (root / "Scripts" / "test" / "run-area.py").exists():
            self.skipTest("this checkout has no run-area.py")
        command = test_command.area_command(["stats", "logs"], ["CountWordingTests"], "/tmp/none", "/tmp/none.log")
        # A dry run prints the xcodebuild command and builds nothing.
        dry = subprocess.run([*command, "--dry-run"], cwd=root, capture_output=True, text=True)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("xcodebuild test", dry.stdout)
        self.assertIn("-only-testing:TextMouthProductionTests/CountWordingTests", dry.stdout)


if __name__ == "__main__":
    unittest.main()
