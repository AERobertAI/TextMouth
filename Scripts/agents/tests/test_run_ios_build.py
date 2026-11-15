"""Tests of run-ios-build.py: the iPhone build the GitHub workflow runs beside the tests.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test builds anything. Each replaces the xcodebuild command with a small Python child that prints what a build
prints, and gives the script an output folder in a temporary directory.
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
_spec = importlib.util.spec_from_file_location("run_ios_build", AGENTS / "run-ios-build.py")
ios = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ios)

# Where a runner checks the repository out, and a log of a build that failed to compile in two files.
RUNNER_ROOT = Path("/Users/runner/work/TextMouth/TextMouth")
LOG_FAILED = f"""\
CompileSwift normal arm64 {RUNNER_ROOT}/TextMouth/Phone/PhoneAppModel.swift
{RUNNER_ROOT}/TextMouth/Phone/PhoneAppModel.swift:41:9: error: cannot find 'NSWorkspace' in scope
        NSWorkspace.shared.open(url)
        ^~~~~~~~~~~
{RUNNER_ROOT}/TextMouth/Phone/PhoneAppModel.swift:77:3: warning: variable 'x' was never mutated
{RUNNER_ROOT}/TextMouth/Services/Foo.swift:5:1: error: expected declaration
{RUNNER_ROOT}/TextMouth/Services/Foo.swift:5:1: error: expected declaration
{RUNNER_ROOT}/TextMouth/Phone/PhoneAppModel.swift:41:9: error: cannot find 'NSWorkspace' in scope
** TEST BUILD FAILED **
"""
LOG_PASSED = "CompileSwift normal arm64 Foo.swift\n** TEST BUILD SUCCEEDED **\n"


class ParsingTests(unittest.TestCase):
    """The errors are read from the log once each, with paths relative to the repository."""

    def test_errors_are_listed_once_in_first_seen_order_with_repository_relative_paths(self):
        self.assertEqual(ios.parse_errors(LOG_FAILED, RUNNER_ROOT), [
            "TextMouth/Phone/PhoneAppModel.swift:41:9: error: cannot find 'NSWorkspace' in scope",
            "TextMouth/Services/Foo.swift:5:1: error: expected declaration"])

    def test_warnings_and_notes_are_not_errors(self):
        log = f"{RUNNER_ROOT}/A.swift:1:1: warning: w\n{RUNNER_ROOT}/A.swift:1:1: note: n\n"
        self.assertEqual(ios.parse_errors(log, RUNNER_ROOT), [])

    def test_an_error_that_names_no_file_is_kept_without_one(self):
        log = "error: Unable to find a destination matching the provided destination specifier\nld: symbol(s) not found\n"
        self.assertEqual(ios.parse_errors(log, RUNNER_ROOT), [
            "error: Unable to find a destination matching the provided destination specifier",
            "error: symbol(s) not found"])

    def test_xcodebuilds_own_error_line_is_an_error_without_a_file(self):
        log = "xcodebuild: error: Unable to find a destination matching the provided destination specifier:\n"
        self.assertEqual(ios.parse_errors(log, RUNNER_ROOT),
                         ["error: Unable to find a destination matching the provided destination specifier:"])

    def test_a_path_outside_the_repository_stays_whole(self):
        log = "/Users/runner/Library/Foo.swift:2:3: error: bad\n"
        self.assertEqual(ios.parse_errors(log, RUNNER_ROOT), ["/Users/runner/Library/Foo.swift:2:3: error: bad"])

    def test_files_are_counted_once_each_and_an_unlocated_error_names_none(self):
        errors = ["a/B.swift:1:2: error: x", "a/B.swift:9:9: error: y", "c/D.swift:1:1: error: z", "error: no file"]
        self.assertEqual(ios.files_of(errors), ["a/B.swift", "c/D.swift"])

    def test_a_missing_platform_is_recognised(self):
        self.assertTrue(ios.platform_missing("error: iOS 26.0 is not installed. To use with Xcode, first download and install the platform"))
        self.assertFalse(ios.platform_missing(LOG_FAILED))


class SummaryTests(unittest.TestCase):
    """The summary says passed or failed, with the counts and the reason a build could not run."""

    def write(self, errors, log, status=0, timed_out=False, seconds=90.0):
        """Writes the results into a temporary folder; returns (passed, summary text, errors text)."""
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            passed = ios.write_results(out, errors, log, status, timed_out, seconds, 45)
            return passed, (out / "ios-summary.txt").read_text(), (out / "ios-errors.txt").read_text()

    def test_a_build_that_succeeded_passes_with_no_errors_listed(self):
        passed, summary, errors = self.write([], LOG_PASSED)
        self.assertTrue(passed)
        self.assertEqual(summary.splitlines()[:3][0], "iOS build: PASSED")
        self.assertIn("Errors in the app: 0 in 0 files", summary)
        self.assertIn("Minutes: 1.5", summary)
        self.assertEqual(errors, "")

    def test_a_build_with_errors_fails_and_lists_them_by_file(self):
        found = ios.parse_errors(LOG_FAILED, RUNNER_ROOT)
        passed, summary, errors = self.write(found, LOG_FAILED, status=65)
        self.assertFalse(passed)
        self.assertIn("iOS build: FAILED", summary)
        self.assertIn("Errors in the app: 2 in 2 files", summary)
        self.assertEqual(errors.splitlines(), found)

    def test_a_zero_exit_without_the_success_line_is_not_a_pass(self):
        passed, summary, _ = self.write([], "nothing useful\n", status=0)
        self.assertFalse(passed)
        self.assertIn("Reason: xcodebuild ended with status 0 and no error line", summary)

    def test_a_stopped_build_says_so(self):
        passed, summary, _ = self.write([], LOG_PASSED, status=-15, timed_out=True)
        self.assertFalse(passed)
        self.assertIn("Reason: the build was stopped after 45 minutes", summary)

    def test_a_missing_platform_is_named_as_the_reason(self):
        log = "error: iOS 26.0 is not installed. To use with Xcode, first download and install the platform\n"
        passed, summary, _ = self.write(ios.parse_errors(log, RUNNER_ROOT), log, status=70)
        self.assertFalse(passed)
        self.assertIn("lacks the iOS Simulator platform or SDK", summary)


class CommandTests(unittest.TestCase):
    """The build is the committed iPhone scheme, for a generic Simulator, unsigned, and runs no test."""

    def test_the_command_builds_for_testing_without_signing_or_a_device(self):
        command = ios.build_command("build/x")
        self.assertEqual(command[:2], ["xcodebuild", "build-for-testing"])
        self.assertEqual(command[command.index("-scheme") + 1], "TextMouthiOS")
        self.assertEqual(command[command.index("-destination") + 1], "generic/platform=iOS Simulator")
        self.assertEqual(command[command.index("-derivedDataPath") + 1], "build/x")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertNotIn("test", command[1:2])

    def test_the_scheme_the_command_names_is_committed(self):
        scheme = AGENTS.parents[1] / "TextMouth.xcodeproj" / "xcshareddata" / "xcschemes" / "TextMouthiOS.xcscheme"
        self.assertTrue(scheme.exists(), "the iPhone scheme is gone, so the runner's build has nothing to build")


class RunTests(unittest.TestCase):
    """main() with a stand-in for xcodebuild."""

    def run_main(self, script, *arguments):
        """Runs main with the build replaced by `script` (Python source); returns (status, output folder text files)."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        out = Path(folder.name) / "out"
        fake = [sys.executable, "-c", script]
        output = io.StringIO()
        with mock.patch.object(ios, "build_command", return_value=fake), mock.patch.object(ios, "ROOT", Path(folder.name)), \
                contextlib.redirect_stdout(output):
            status = ios.main(["--out", "out", *arguments])
        return status, {path.name: path.read_text() for path in out.iterdir()}, output.getvalue()

    def test_a_build_that_compiles_writes_a_passing_summary_and_exits_0(self):
        status, files, printed = self.run_main("print('** TEST BUILD SUCCEEDED **')")
        self.assertEqual(status, 0)
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: PASSED"))
        self.assertIn("TEST BUILD SUCCEEDED", files["ios.log"])
        self.assertIn("iOS build: PASSED", printed)

    def test_a_build_that_does_not_compile_is_a_result_and_still_exits_0(self):
        script = ("import sys; print('/x/Foo.swift:3:4: error: no such thing'); print('** TEST BUILD FAILED **'); "
                  "sys.exit(65)")
        status, files, _ = self.run_main(script)
        self.assertEqual(status, 0, "the tests and the iPhone build are judged apart")
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: FAILED"))
        self.assertEqual(files["ios-errors.txt"], "/x/Foo.swift:3:4: error: no such thing\n")

    def test_a_build_that_outlives_its_limit_is_stopped_and_says_so(self):
        status, files, _ = self.run_main("import time; time.sleep(60)", "--limit-minutes", "0.01")
        self.assertEqual(status, 0)
        self.assertIn("Reason: the build was stopped after 0.01 minutes", files["ios-summary.txt"])


class EarlyBootTests(unittest.TestCase):
    """The simulator boots beside the build only when the request and the machine say so."""

    RUNNER = {"GITHUB_ACTIONS": "true"}

    def request_file(self, request):
        """A request file in a temporary folder; returns its path."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "request.json"
        path.write_text(json.dumps(request))
        return path

    def test_it_is_wanted_only_on_a_runner_for_a_request_that_asks_for_it_and_for_iphone_tests(self):
        asking = {"full": True, "ios_early_boot": True}
        self.assertTrue(ios.early_boot_wanted(asking, self.RUNNER))
        self.assertFalse(ios.early_boot_wanted(asking, {}), "never on the development Mac")
        self.assertFalse(ios.early_boot_wanted(asking, {"GITHUB_ACTIONS": "false"}))
        self.assertFalse(ios.early_boot_wanted({"full": True}, self.RUNNER), "off unless the request says so")
        self.assertFalse(ios.early_boot_wanted({"full": True, "ios_early_boot": "yes"}, self.RUNNER))
        self.assertFalse(ios.early_boot_wanted({"classes": ["SomeMacTests"], "ios_early_boot": True}, self.RUNNER),
                         "a request with no iPhone tests has nothing to boot for")
        self.assertFalse(ios.early_boot_wanted({"full": True, "ios": False, "ios_early_boot": True}, self.RUNNER))

    def test_the_boot_starts_on_a_thread_when_wanted_and_not_otherwise(self):
        started = []
        path = self.request_file({"full": True, "ios_early_boot": True})
        thread = ios.start_early_boot(Path("out"), path, self.RUNNER, boot=lambda out: started.append(out))
        thread.join(5)
        self.assertEqual(started, [Path("out")])
        self.assertIsNone(ios.start_early_boot(Path("out"), self.request_file({"full": True}), self.RUNNER, boot=started.append))
        self.assertIsNone(ios.start_early_boot(Path("out"), path.parent / "absent.json", self.RUNNER, boot=started.append))
        self.assertEqual(len(started), 1)

    def test_a_boot_that_fails_is_said_and_never_raised(self):
        said = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(said):
            ios.boot_simulator(folder, load=mock.Mock(side_effect=RuntimeError("no simulator")),
                               run=mock.Mock(), sleep=lambda _: None)
        self.assertIn(ios.EARLY_BOOT_PREFIX + "did not finish", said.getvalue())
        self.assertIn("no simulator", said.getvalue())

    def test_a_boot_restarts_the_audio_service_first_and_then_sets_the_simulator_up(self):
        order = []
        fake_ui = mock.Mock()
        fake_ui.ready_simulator.side_effect = lambda log: order.append("ready") or ("UDID", "iPhone 17")
        said = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(said):
            ios.boot_simulator(folder, load=lambda: fake_ui, run=lambda command, **_: order.append(command[:3]),
                               sleep=lambda _: order.append("sleep"))
        self.assertEqual(order, [["sudo", "killall", "coreaudiod"], "sleep", "ready"])
        self.assertIn(ios.EARLY_BOOT_PREFIX + "ready in", said.getvalue())


if __name__ == "__main__":
    unittest.main()
