"""Tests of run-ios-ui-tests.py: the iPhone interface tests the GitHub workflow runs in the iOS Simulator.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test boots a simulator or runs xcodebuild. The parts that read `simctl`'s answers and xcodebuild's log are pure
functions, tested with the text those tools print; the whole script is run with a stand-in for each tool.
"""
import contextlib
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from heavy_lock_case import HeavyLockTestCase  # noqa: F401  (puts the scripts' folder on the path)
import test_command  # noqa: E402

AGENTS = Path(test_command.AGENTS)
ROOT = AGENTS.parents[1]
# The script's name has hyphens, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("run_ios_ui_tests", AGENTS / "run-ios-ui-tests.py")
uitests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uitests)

RUNNER_ROOT = Path("/Users/runner/work/TextMouth/TextMouth")
# A log as xcodebuild prints it for two classes: one pass, one failure with its message, one skip with its reason.
LOG = f"""\
Test Suite 'Selected tests' started at 2026-11-10 10:00:00.000.
Test Case '-[TextMouthiOSUITests.ReaderUITests testTheReaderHasTheSpecsOrder]' started.
Test Case '-[TextMouthiOSUITests.ReaderUITests testTheReaderHasTheSpecsOrder]' passed (3.2 seconds).
Test Case '-[TextMouthiOSUITests.PlaybackUITests testPlayBecomesPauseAndPauseBecomesPlay]' started.
{RUNNER_ROOT}/TextMouthiOSUITests/PlaybackUITests.swift:60: error: -[TextMouthiOSUITests.PlaybackUITests testPlayBecomesPauseAndPauseBecomesPlay] : XCTAssertTrue failed - Play was pressed and the control never read Pause
{RUNNER_ROOT}/TextMouthiOSUITests/PlaybackUITests.swift:61: error: -[TextMouthiOSUITests.PlaybackUITests testPlayBecomesPauseAndPauseBecomesPlay] : a second message
Test Case '-[TextMouthiOSUITests.PlaybackUITests testPlayBecomesPauseAndPauseBecomesPlay]' failed (61.0 seconds).
Test Case '-[TextMouthiOSUITests.SearchUITests testWithNothingSearchedTheSheetSaysSo]' started.
{RUNNER_ROOT}/TextMouthiOSUITests/TextMouthUITestCase.swift:40: -[TextMouthiOSUITests.SearchUITests testATermTypedWhole] : Test skipped - Typing makes sound
Test Case '-[TextMouthiOSUITests.SearchUITests testATermTypedWhole]' skipped (0.0 seconds).
Test Case '-[TextMouthiOSUITests.SearchUITests testWithNothingSearchedTheSheetSaysSo]' passed (4.1 seconds).
Test case 'ReaderUITests.testTheReaderHasTheSpecsOrder()' passed on 'iPhone 17 - TextMouthiOS (4242)' (3.3 seconds)
** TEST FAILED **
"""
PASSED_LOG = ("Test Case '-[TextMouthiOSUITests.ReaderUITests testA]' passed (1.0 seconds).\n"
              "Test case 'ReaderUITests.testB()' passed on 'iPhone 17 - TextMouthiOS (1)' (1.0 seconds)\n"
              "** TEST SUCCEEDED **\n")

RUNTIMES = [
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0.1", "isAvailable": True},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2", "version": "26.2", "isAvailable": True},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "isAvailable": True},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-0", "version": "26.0", "isAvailable": True},
]


class ChoosingTheSimulatorTests(unittest.TestCase):
    """The runtime is the downloaded iOS 26.0; the device an iPhone 17 on it."""

    def test_the_wanted_runtime_is_chosen_over_a_newer_one(self):
        self.assertEqual(uitests.choose_runtime(RUNTIMES)["identifier"], "com.apple.CoreSimulator.SimRuntime.iOS-26-0")

    def test_without_it_the_newest_ios_runtime_is_used_and_never_another_platforms(self):
        newer = [RUNTIMES[1], RUNTIMES[2], RUNTIMES[3]]
        self.assertEqual(uitests.choose_runtime(newer)["version"], "26.2")

    def test_an_unavailable_runtime_is_not_chosen(self):
        broken = [{**RUNTIMES[0], "isAvailable": False}, RUNTIMES[2]]
        self.assertEqual(uitests.choose_runtime(broken)["version"], "18.6")

    def test_no_ios_runtime_is_none(self):
        self.assertIsNone(uitests.choose_runtime([RUNTIMES[3]]))
        self.assertIsNone(uitests.choose_runtime([]))

    def test_versions_order_by_number_and_not_by_text(self):
        self.assertGreater(uitests.version_key("26.10"), uitests.version_key("26.9"))
        self.assertEqual(uitests.version_key("26.x"), (26, 0))

    def test_an_existing_iphone_17_on_the_runtime_is_used(self):
        devices = {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 16", "udid": "A", "isAvailable": True}, {"name": "iPhone 17", "udid": "B", "isAvailable": True}]}
        self.assertEqual(uitests.choose_device(devices, "com.apple.CoreSimulator.SimRuntime.iOS-26-0"), "B")

    def test_no_device_on_the_runtime_is_none_and_so_is_an_unavailable_one(self):
        runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
        self.assertIsNone(uitests.choose_device({}, runtime))
        self.assertIsNone(uitests.choose_device({runtime: [{"name": "iPhone 17", "udid": "B", "isAvailable": False}]}, runtime))
        self.assertIsNone(uitests.choose_device({"other": [{"name": "iPhone 17", "udid": "B"}]}, runtime))


class ReadingTheLogTests(unittest.TestCase):
    """Each test's outcome, its first failure message with where it was, and a skip's reason, come from the log."""

    def parsed(self, text=LOG):
        """The log read as the script reads it."""
        return uitests.parse_results(text, RUNNER_ROOT)

    def test_each_test_has_the_outcome_the_log_gives_it_in_either_form(self):
        self.assertEqual(self.parsed()["cases"], {
            "ReaderUITests.testTheReaderHasTheSpecsOrder": "passed",
            "PlaybackUITests.testPlayBecomesPauseAndPauseBecomesPlay": "failed",
            "SearchUITests.testATermTypedWhole": "skipped",
            "SearchUITests.testWithNothingSearchedTheSheetSaysSo": "passed"})

    def test_a_failed_test_is_named_with_its_file_line_and_first_message_as_the_macs_are(self):
        self.assertEqual(self.parsed()["failures"], [
            "FAILED PlaybackUITests.testPlayBecomesPauseAndPauseBecomesPlay at "
            "TextMouthiOSUITests/PlaybackUITests.swift:60: XCTAssertTrue failed - Play was pressed and the control never read Pause"])

    def test_a_skipped_test_says_why(self):
        self.assertEqual(self.parsed()["skips"], ["SearchUITests.testATermTypedWhole: Typing makes sound"])

    def test_a_failure_with_no_message_line_still_names_the_test(self):
        parsed = self.parsed("Test Case '-[TextMouthiOSUITests.AUITests testX]' failed (1.0 seconds).\n")
        self.assertEqual(parsed["failures"], ["FAILED AUITests.testX at (no location): failed"])

    def test_a_long_message_is_cut(self):
        long = "x" * 1000
        parsed = self.parsed(
            f"{RUNNER_ROOT}/A.swift:1: error: -[M.AUITests testX] : {long}\n"
            "Test Case '-[M.AUITests testX]' failed (1.0 seconds).\n")
        self.assertLessEqual(len(parsed["failures"][0]), len("FAILED AUITests.testX at A.swift:1: ") + uitests.MESSAGE_LIMIT)

    def test_a_test_printed_twice_counts_once(self):
        parsed = self.parsed("Test Case '-[M.AUITests testX]' passed (1.0 seconds).\n"
                             "Test case 'AUITests.testX()' passed on 'iPhone 17 - X (1)' (1.0 seconds)\n")
        self.assertEqual(parsed["cases"], {"AUITests.testX": "passed"})


class TheVerdictTests(unittest.TestCase):
    """A run passes only when xcodebuild says so, nothing failed, and something ran."""

    def judge(self, log, status=0, timed_out=False, expected=0):
        """The verdict for a log."""
        return uitests.judge(status, timed_out, log, uitests.parse_results(log, RUNNER_ROOT), expected=expected)

    # What the review of 1f5f5f4a fed the old verdict: every sound test skipped (the variable never reached the runner),
    # and one passing test out of 34 asked. Both were judged passed.
    SKIPPED_FOR_SOUND = "".join(
        f"{RUNNER_ROOT}/TextMouthiOSUITests/TextMouthUITestCase.swift:44: -[TextMouthiOSUITests.PlaybackUITests testPlay{n}] : "
        f"Test skipped - Pressing Play makes sound, so it {uitests.SOUND_SKIP_MARKER}, where TEXTMOUTH_UI_SOUND is 1 "
        f"(Scripts/agents/run-ios-ui-tests.py sets it); on this Mac it is skipped.\n"
        f"Test Case '-[TextMouthiOSUITests.PlaybackUITests testPlay{n}]' skipped (0.0 seconds).\n" for n in range(12)
    ) + "Test Case '-[TextMouthiOSUITests.ReaderUITests testA]' passed (1.0 seconds).\n** TEST EXECUTE SUCCEEDED **\n"

    def test_a_run_whose_sound_tests_all_skipped_for_sound_is_not_a_pass(self):
        passed, reasons = self.judge(self.SKIPPED_FOR_SOUND)
        self.assertFalse(passed)
        self.assertIn("12 test(s) skipped because they make sound", reasons[0])
        self.assertIn("TEXTMOUTH_UI_SOUND did not reach the test runner", reasons[0])

    def test_a_skip_for_another_reason_is_not_judged_as_a_sound_skip(self):
        log = ("/x/A.swift:3: -[M.AUITests testX] : Test skipped - not on this device\n"
               "Test Case '-[M.AUITests testX]' skipped (0.0 seconds).\n"
               "Test Case '-[M.AUITests testY]' passed (0.0 seconds).\n** TEST EXECUTE SUCCEEDED **\n")
        self.assertEqual(self.judge(log), (True, []))

    def test_fewer_results_than_the_asked_classes_hold_is_not_a_pass(self):
        log = "Test Case '-[M.ReaderUITests testA]' passed (1.0 seconds).\n** TEST EXECUTE SUCCEEDED **\n"
        passed, reasons = self.judge(log, expected=34)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["1 test results came back, and the classes asked for hold 34"])
        self.assertEqual(self.judge(log, expected=1), (True, []), "as many results as tests is a pass")

    def test_the_skip_marker_is_the_text_the_swift_helper_writes(self):
        swift = (ROOT / "TextMouthiOSUITests" / "TextMouthUITestCase.swift").read_text()
        self.assertIn(f'static let soundSkipMarker = "{uitests.SOUND_SKIP_MARKER}"', swift)
        self.assertIn("so it \\(Self.soundSkipMarker)", swift, "requireSound writes the marker in its reason")

    def test_the_counts_of_tests_are_read_from_the_swift_files_of_each_class(self):
        counts = uitests.ios_ui_tests.test_counts(ROOT)
        self.assertEqual(counts["ReaderUITests"], 4)
        self.assertEqual(set(counts), set(uitests.ios_ui_tests.ui_classes(ROOT)))
        self.assertGreaterEqual(sum(counts.values()), 30)

    def test_a_log_of_passing_tests_with_the_success_line_passes(self):
        self.assertEqual(self.judge(PASSED_LOG), (True, []))

    def test_a_failed_test_fails_the_run_and_is_counted_in_the_reason(self):
        passed, reasons = self.judge(LOG, status=65)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["1 test(s) failed"])

    def test_test_without_building_ends_with_execute_succeeded_and_that_is_a_pass(self):
        # Run 42957244945: 34 tests passed and the run was judged FAILED for want of "** TEST SUCCEEDED **".
        log = PASSED_LOG.replace("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **")
        self.assertEqual(self.judge(log), (True, []))

    def test_a_run_that_ran_nothing_is_not_a_pass(self):
        passed, reasons = self.judge("** TEST SUCCEEDED **\n")
        self.assertFalse(passed)
        self.assertIn("no test result was found in the log", reasons)

    def test_a_zero_exit_without_the_success_line_is_not_a_pass(self):
        passed, reasons = self.judge("Test Case '-[M.AUITests testX]' passed (1.0 seconds).\n")
        self.assertFalse(passed)
        self.assertTrue(reasons[0].startswith("xcodebuild ended with status 0 and did not print TEST SUCCEEDED"))

    def test_a_run_stopped_at_its_limit_fails(self):
        passed, reasons = self.judge(PASSED_LOG, status=-15, timed_out=True)
        self.assertFalse(passed)
        self.assertEqual(reasons, ["the run was stopped at its time limit"])


class TheSummaryTests(unittest.TestCase):
    """The summary has the verdict, the Executed line the Mac's tools read, and every failure."""

    def lines(self, verdict="FAILED", reasons=("1 test(s) failed",), classes=()):
        """The summary lines for the sample log."""
        return uitests.summary_lines(verdict, uitests.parse_results(LOG, RUNNER_ROOT), 120.0, 60.0,
                                     "iPhone 17, iOS 26.0.1 (ABC)", list(classes), list(reasons))

    def test_the_first_line_is_the_verdict_and_the_second_the_executed_line_with_the_counts(self):
        lines = self.lines()
        self.assertEqual(lines[0], "iOS UI tests: FAILED")
        self.assertEqual(lines[1], "Executed 4 tests, with 1 tests skipped and 1 failures (0 unexpected) in 120.000 (120.000) seconds")

    def test_failures_skips_and_reasons_each_have_a_line_of_their_own(self):
        lines = self.lines()
        self.assertEqual(sum(line.startswith("FAILED ") for line in lines), 1)
        self.assertIn("Skipped SearchUITests.testATermTypedWhole: Typing makes sound", lines)
        self.assertIn("Reason: 1 test(s) failed", lines)

    def test_the_minutes_include_the_simulators_set_up_and_say_how_long_that_took(self):
        self.assertIn("Minutes: 3.0 (the simulator's set-up took 1.0)", self.lines())

    def test_the_classes_are_named_or_every_class_is_said(self):
        self.assertIn("Classes: every class", self.lines())
        self.assertIn("Classes: ReaderUITests, SearchUITests", self.lines(classes=("ReaderUITests", "SearchUITests")))

    def test_it_says_the_sound_was_allowed_and_by_whom(self):
        self.assertTrue(any(line.startswith("Sound: allowed (TEXTMOUTH_UI_SOUND=1, set by this script alone") for line in self.lines()))


class TheCommandTests(unittest.TestCase):
    """The run is the committed scheme's test bundle, in the simulator by its id, with a limit on any one test."""

    def command(self, classes=()):
        """The command for a simulator and the given classes."""
        return uitests.test_command("UDID-1", "build/dd", "build/out/result.xcresult", list(classes))

    def test_it_tests_without_building_in_the_simulator_by_id(self):
        command = self.command()
        self.assertEqual(command[:2], ["xcodebuild", "test-without-building"])
        self.assertEqual(command[command.index("-destination") + 1], "id=UDID-1")
        self.assertEqual(command[command.index("-scheme") + 1], "TextMouthiOS")
        self.assertEqual(command[command.index("-derivedDataPath") + 1], "build/dd")

    def test_it_runs_the_whole_interface_bundle_or_only_the_classes_named(self):
        self.assertEqual([a for a in self.command() if a.startswith("-only-testing")], ["-only-testing:TextMouthiOSUITests"])
        self.assertEqual([a for a in self.command(["ReaderUITests", "SearchUITests"]) if a.startswith("-only-testing")],
                         ["-only-testing:TextMouthiOSUITests/ReaderUITests", "-only-testing:TextMouthiOSUITests/SearchUITests"])

    def test_one_test_has_a_time_limit(self):
        command = self.command()
        self.assertEqual(command[command.index("-test-timeouts-enabled") + 1], "YES")
        self.assertEqual(command[command.index("-maximum-test-execution-time-allowance") + 1], str(uitests.TEST_SECONDS))

    def test_the_tests_run_in_one_simulator_and_clones_only_when_more_workers_are_asked_for(self):
        single = self.command()
        self.assertEqual(single[single.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-parallel-testing-worker-count", single)
        with mock.patch.object(uitests, "PARALLEL_WORKERS", 2):
            clones = self.command()
        self.assertEqual(clones[clones.index("-parallel-testing-enabled") + 1], "YES")
        self.assertEqual(clones[clones.index("-parallel-testing-worker-count") + 1], "2")

    def test_the_tests_are_handed_the_sound_variable_without_its_prefix_by_xcodebuild(self):
        self.assertEqual(uitests.RUNNER_SOUND_VARIABLE, "TEST_RUNNER_TEXTMOUTH_UI_SOUND")
        self.assertEqual(uitests.test_environment()["TEST_RUNNER_TEXTMOUTH_UI_SOUND"], "1")

    def test_the_scheme_the_command_names_is_committed_and_holds_the_interface_bundle(self):
        scheme = ROOT / "TextMouth.xcodeproj" / "xcshareddata" / "xcschemes" / "TextMouthiOS.xcscheme"
        self.assertIn("TextMouthiOSUITests", scheme.read_text())


class TheSoundRuleTests(unittest.TestCase):
    """Only the runner's script lets a test make sound, and every test that does skips without it."""

    # The folders and files that may name the variable: the script and its tests, the UI tests that read it, the workflow
    # whose comments explain the rule (test_the_workflow_never_sets_the_variable... checks it sets nothing), and the
    # documents. Nothing else may name it.
    ALLOWED = ("Scripts/agents/run-ios-ui-tests.py", "Scripts/agents/tests/", "TextMouthiOSUITests/",
               ".github/workflows/tests.yml", "project.yml", "docs/", "AGENTS.md", "Scripts/agents/briefs/")

    def tracked_files(self):
        """The files of the repository that git tracks (and not the build folders)."""
        import subprocess
        listing = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        return [name for name in listing.split("\0") if name and not name.startswith(("build/", "Vendor/", "TestData/"))]

    def test_no_file_but_the_runners_script_and_the_test_case_sets_the_sound_variable(self):
        # The workflow and every other script must not set it, in any spelling.
        offenders = []
        for name in self.tracked_files():
            path = ROOT / name
            if not path.is_file() or path.suffix in {".png", ".epub", ".zip", ".pbxproj", ".xcprivacy"}:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if "TEXTMOUTH_UI_SOUND" in text and not name.startswith(self.ALLOWED):
                offenders.append(name)
        self.assertEqual(offenders, [], "only run-ios-ui-tests.py may set TEXTMOUTH_UI_SOUND; these name it")

    def test_the_workflow_never_sets_the_variable_and_runs_the_scripts_step(self):
        workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text()
        self.assertNotRegex(workflow, r"(?m)^\s*(TEST_RUNNER_)?TEXTMOUTH_UI_SOUND\s*:", "the workflow sets the variable itself")
        self.assertNotRegex(workflow, r"export\s+(TEST_RUNNER_)?TEXTMOUTH_UI_SOUND")
        self.assertIn("run-ios-ui-tests.py", workflow)

    def test_the_script_sets_the_variable_only_for_the_test_command(self):
        # Importing the script or building its command leaves this process's environment alone.
        import os
        self.assertNotIn("TEST_RUNNER_TEXTMOUTH_UI_SOUND", os.environ)
        self.assertNotIn("TEXTMOUTH_UI_SOUND", os.environ)
        uitests.test_environment()
        self.assertNotIn("TEST_RUNNER_TEXTMOUTH_UI_SOUND", os.environ)

    def test_every_helper_that_makes_sound_asks_first_and_no_test_file_makes_sound_by_hand(self):
        folder = ROOT / "TextMouthiOSUITests"
        base = (folder / "TextMouthUITestCase.swift").read_text()
        for helper in ("pressPlay", "pressPause", "startSleepTimer", "type"):
            body = re.search(rf"func {helper}\([^{{]*\{{(.*?)\n    \}}\n", base, re.S)
            self.assertIsNotNone(body, f"the helper {helper} is not in TextMouthUITestCase")
            self.assertIn("try requireSound(", body.group(1).split("\n", 3)[1] + body.group(1).split("\n", 3)[2],
                          f"{helper} does not ask requireSound first")
        # No other file types or presses Play and Pause itself, or sets a timer: they go through the helpers.
        for path in folder.glob("*UITests.swift"):
            text = path.read_text()
            for pattern in (r"\.typeText\(", r'buttons\["Play"\]\.tap\(', r'buttons\["Pause"\]\.tap\(',
                            r'"Set timer for', r'"Stop at the end of'):
                for match in re.finditer(pattern, text):
                    line = text.count("\n", 0, match.start()) + 1
                    surrounding = text.splitlines()[line - 1]
                    # A string that names a button to look for (assertOrder lists, a helper's argument) is not a press.
                    self.assertTrue(
                        surrounding.strip().startswith(('"', "//", "///")) or "startSleepTimer(" in surrounding
                        or "assertOrder" in surrounding,
                        f"{path.name}:{line} makes sound by hand: {surrounding.strip()}")


class SettingUpTheSimulatorTests(unittest.TestCase):
    """ready_simulator with a stand-in for simctl: what it asks of the tool, in order, and what it does when a step fails."""

    RUNTIME = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0.1", "isAvailable": True}

    def run_setup(self, devices=None, runtimes=None, boot_status=0, create=("NEWUDID\n", 0)):
        """Runs ready_simulator; returns (its answer, the simctl calls made, the log text)."""
        calls = []
        listing = {"runtimes": [self.RUNTIME] if runtimes is None else runtimes,
                   "devices": devices if devices is not None else {self.RUNTIME["identifier"]: [{"name": "iPhone 17", "udid": "OLDUDID", "isAvailable": True}]}}

        def fake_simctl(*args, timeout=0):
            """Answers simctl calls from the canned state."""
            calls.append(args)
            if args[0] == "create":
                return mock.Mock(stdout=create[0], stderr="made" if create[1] == 0 else "no", returncode=create[1])
            if args[0] == "bootstatus":
                return mock.Mock(stdout="booted", stderr="" if boot_status == 0 else "failed", returncode=boot_status)
            return mock.Mock(stdout="listing", stderr="", returncode=0)

        def fake_json(*args):
            """Answers `simctl list <what> -j`."""
            return {"runtimes": listing["runtimes"]} if args[0] == "runtimes" else {"devices": listing["devices"]}

        log = io.StringIO()
        with mock.patch.object(uitests, "simctl", fake_simctl), mock.patch.object(uitests, "simctl_json", fake_json):
            try:
                answer = uitests.ready_simulator(log)
            except uitests.SimulatorFailure as failure:
                answer = failure
        return answer, calls, log.getvalue()

    def test_an_existing_iphone_17_is_booted_and_the_keyboard_settings_are_written(self):
        (udid, sentence), calls, _ = self.run_setup()
        self.assertEqual(udid, "OLDUDID")
        self.assertIn("iPhone 17, iOS 26.0.1 (OLDUDID)", sentence)
        self.assertNotIn("create", [call[0] for call in calls])
        self.assertIn(("bootstatus", "OLDUDID", "-b"), calls)
        written = [call for call in calls if call[:3] == ("spawn", "OLDUDID", "defaults")]
        self.assertEqual([call[5] for call in written], [key for key, _ in uitests.KEYBOARD_SETTINGS])
        self.assertIn(("spawn", "OLDUDID", "defaults", "write", "com.apple.keyboard.preferences",
                       "DidShowContinuousPathIntroduction", "-bool", "true"), calls)

    def test_with_no_iphone_17_one_is_made_on_the_runtime(self):
        (udid, _), calls, _ = self.run_setup(devices={})
        self.assertEqual(udid, "NEWUDID")
        self.assertIn(("create", "TextMouth iPhone 17", uitests.DEVICE_TYPE, self.RUNTIME["identifier"]), calls)

    def test_a_device_that_cannot_be_made_is_a_failure_that_says_so(self):
        failure, _, _ = self.run_setup(devices={}, create=("", 1))
        self.assertIsInstance(failure, uitests.SimulatorFailure)
        self.assertIn("could not make an iPhone 17", str(failure))

    def test_no_ios_runtime_is_a_failure(self):
        failure, _, _ = self.run_setup(runtimes=[])
        self.assertIsInstance(failure, uitests.SimulatorFailure)
        self.assertIn("no iOS simulator runtime", str(failure))

    def test_a_simulator_that_does_not_boot_is_a_failure_and_the_settings_are_not_written(self):
        failure, calls, log = self.run_setup(boot_status=1)
        self.assertIsInstance(failure, uitests.SimulatorFailure)
        self.assertIn("did not boot", str(failure))
        self.assertFalse(any(call[0] == "spawn" for call in calls))
        self.assertIn("bootstatus", log)

    def test_a_different_ios_version_than_the_wanted_one_is_said(self):
        other = {**self.RUNTIME, "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2", "version": "26.2"}
        (_, sentence), _, _ = self.run_setup(runtimes=[other], devices={other["identifier"]: [{"name": "iPhone 17", "udid": "X"}]})
        self.assertIn("the wanted iOS 26.0 runtime was not there", sentence)


class TheSearchTestsRulesTests(unittest.TestCase):
    """Rules of the typed search tests that a break would otherwise slip past (review of 1f5f5f4a, finding 7)."""

    def source(self):
        """SearchUITests.swift."""
        return (ROOT / "TextMouthiOSUITests" / "SearchUITests.swift").read_text()

    def test_a_status_ending_in_matches_is_never_waited_for_without_the_results_heading_first(self):
        # "No matches" ends with " matches", so waiting for that ending alone passes a search that found nothing.
        text = self.source()
        waiting = text.count('waitForStatus(ending: [" matches", " match"]')
        # The one inside waitForResults, and the correction test's, which waits for the heading just before it.
        self.assertEqual(waiting, 2, "a test waits for the ' matches' status without waitForResults")
        correction = text[text.index("func testACorrectionMadeWhileTypingIsSearchedFor"):]
        self.assertLess(correction.index('staticTexts["Search results"].waitForExistence'),
                        correction.index('waitForStatus(ending: [" matches", " match"]'))

    def test_type_taps_the_field_only_when_the_keyboard_is_not_up(self):
        base = (ROOT / "TextMouthiOSUITests" / "TextMouthUITestCase.swift").read_text()
        body = base[base.index("func type("):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("if !app.keyboards.firstMatch.exists {\n            field.tap()", body)


class RunningTheScriptTests(unittest.TestCase):
    """main() with a stand-in for simctl and for xcodebuild, in a throwaway repository."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.out = self.root / "out"
        self.out.mkdir()
        (self.root / ".github").mkdir()
        (self.root / "TextMouthiOSUITests").mkdir()
        (self.root / "TextMouthiOSUITests" / "ReaderUITests.swift").write_text("final class ReaderUITests: TextMouthUITestCase {}\n")
        self.request({"full": True, "areas": ["all"]})
        (self.out / "ios-summary.txt").write_text("iOS build: PASSED\nErrors in the app: 0 in 0 files\n")

    def request(self, request):
        """Writes the request file the script reads."""
        (self.root / ".github" / "test-request.json").write_text(json.dumps(request))

    def run_main(self, script="print('** TEST SUCCEEDED **')", ready=("UDID", "iPhone 17, iOS 26.0.1 (UDID)"), arguments=()):
        """Runs main with the simulator ready (or failing, when `ready` is an exception) and the tests replaced by
        `script` (Python source); returns (status, the summary text, the printed text)."""
        fake = [sys.executable, "-c", script]
        printed = io.StringIO()
        simulator = mock.Mock(side_effect=ready) if isinstance(ready, Exception) else mock.Mock(return_value=ready)
        with mock.patch.object(uitests, "ROOT", self.root), mock.patch.object(uitests, "ready_simulator", simulator), \
                mock.patch.object(uitests, "test_command", return_value=fake), contextlib.redirect_stdout(printed):
            status = uitests.main(["--out", "out", *arguments])
        return status, (self.out / "ios-ui-summary.txt").read_text(), printed.getvalue()

    def test_passing_tests_write_a_passing_summary_and_exit_0(self):
        script = ("print(\"Test Case '-[M.ReaderUITests testA]' passed (1.0 seconds).\"); print('** TEST SUCCEEDED **')")
        status, summary, printed = self.run_main(script)
        self.assertEqual(status, 0)
        self.assertTrue(summary.startswith("iOS UI tests: PASSED\nExecuted 1 tests, with 0 tests skipped and 0 failures"))
        self.assertIn("iOS UI tests: PASSED", printed)
        self.assertIn("TEST SUCCEEDED", (self.out / "ios-ui.log").read_text())

    def test_a_failed_test_is_named_in_the_summary_and_the_exit_status_is_1(self):
        script = ("import sys\nprint('/x/ReaderUITests.swift:9: error: -[M.ReaderUITests testA] : XCTAssertEqual failed')\n"
                  "print(\"Test Case '-[M.ReaderUITests testA]' failed (1.0 seconds).\")\nprint('** TEST FAILED **')\nsys.exit(65)")
        status, summary, _ = self.run_main(script)
        self.assertEqual(status, 1, "a failed interface test fails the iPhone job")
        self.assertTrue(summary.startswith("iOS UI tests: FAILED"))
        self.assertIn("FAILED ReaderUITests.testA at /x/ReaderUITests.swift:9: XCTAssertEqual failed", summary)

    def test_a_log_left_by_an_earlier_run_in_the_same_folder_is_not_read_as_this_runs(self):
        # An old run's failed case and banner must not become this run's results (review of 1f5f5f4a, finding 11).
        (self.out / "ios-ui.log").write_text("Test Case '-[M.ReaderUITests testOld]' failed (1.0 seconds).\n** TEST FAILED **\n")
        script = "print(\"Test Case '-[M.ReaderUITests testA]' passed (1.0 seconds).\"); print('** TEST EXECUTE SUCCEEDED **')"
        status, summary, _ = self.run_main(script)
        self.assertEqual(status, 0, summary)
        self.assertNotIn("testOld", summary)
        self.assertNotIn("testOld", (self.out / "ios-ui.log").read_text())

    def test_a_request_that_does_not_ask_writes_not_asked_and_starts_no_simulator(self):
        self.request({"full": False, "areas": ["feeds"], "classes": ["FooTests"]})
        status, summary, _ = self.run_main(ready=AssertionError("the simulator must not start"))
        self.assertEqual(status, 0)
        self.assertTrue(summary.startswith("iOS UI tests: NOT ASKED"))

    def test_a_missing_request_asks_for_nothing(self):
        (self.root / ".github" / "test-request.json").unlink()
        status, summary, _ = self.run_main(ready=AssertionError("the simulator must not start"))
        self.assertEqual((status, summary.splitlines()[0]), (0, "iOS UI tests: NOT ASKED"))

    def test_a_build_that_did_not_pass_leaves_nothing_to_run_and_does_not_fail_the_job(self):
        (self.out / "ios-summary.txt").write_text("iOS build: FAILED\nErrors in the app: 2 in 1 files\n")
        status, summary, _ = self.run_main(ready=AssertionError("the simulator must not start"))
        self.assertEqual(status, 0, "the build's failure is the build's result, not this one's")
        self.assertTrue(summary.startswith("iOS UI tests: NOT RUN\nReason: the iPhone build did not pass"))

    def test_a_simulator_that_cannot_be_made_ready_fails_the_run_and_says_why(self):
        status, summary, _ = self.run_main(ready=uitests.SimulatorFailure("the runner has no iOS simulator runtime"))
        self.assertEqual(status, 1)
        self.assertEqual(summary.splitlines()[0], "iOS UI tests: FAILED")
        self.assertIn("Reason: the simulator could not be made ready: the runner has no iOS simulator runtime", summary)
        self.assertIn("simulator set-up failed", (self.out / "ios-ui.log").read_text())

    def test_tests_that_outlive_their_limit_are_stopped_and_fail(self):
        status, summary, _ = self.run_main("import time; time.sleep(60)", arguments=("--limit-minutes", "0.01"))
        self.assertEqual(status, 1)
        self.assertIn("Reason: the run was stopped at its time limit", summary)

    def test_a_set_up_that_leaves_the_step_too_little_time_fails_at_once_and_says_so(self):
        with mock.patch.object(uitests, "STEP_BUDGET_MINUTES", 3):
            status, summary, _ = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("Reason: the simulator's set-up took", summary)
        self.assertIn("for the tests", summary)

    def test_the_tests_limit_is_what_the_step_has_left_after_the_set_up_and_never_more_than_asked(self):
        seen = []
        with mock.patch.object(uitests, "run_tests", lambda command, log, limit: seen.append(limit) or (0, False)), \
                mock.patch.object(uitests, "ready_simulator", return_value=("U", "sim")), \
                mock.patch.object(uitests, "ROOT", self.root), contextlib.redirect_stdout(io.StringIO()):
            uitests.main(["--out", "out"])
            with mock.patch.object(uitests, "STEP_BUDGET_MINUTES", 20):
                uitests.main(["--out", "out"])
        self.assertEqual(seen[0], uitests.DEFAULT_LIMIT_MINUTES, "a step with room gives the whole asked limit")
        self.assertAlmostEqual(seen[1], 20 - uitests.KILL_GRACE_SECONDS / 60, delta=0.1)

    def test_a_request_naming_classes_runs_only_those(self):
        (self.root / "TextMouthiOSUITests" / "Other.swift").write_text("final class SearchUITests: TextMouthUITestCase {}\n")
        self.request({"classes": ["SearchUITests"]})
        seen = []
        real = uitests.test_command

        def spy(udid, derived, bundle, classes):
            """Records the classes the command is made for."""
            seen.append(classes)
            return real(udid, derived, bundle, classes)

        with mock.patch.object(uitests, "test_command", spy), mock.patch.object(uitests, "run_tests", return_value=(0, False)):
            fake = io.StringIO()
            with mock.patch.object(uitests, "ROOT", self.root), mock.patch.object(uitests, "ready_simulator", return_value=("U", "sim")), \
                    contextlib.redirect_stdout(fake):
                uitests.main(["--out", "out"])
        self.assertEqual(seen, [["SearchUITests"]])


if __name__ == "__main__":
    unittest.main()
