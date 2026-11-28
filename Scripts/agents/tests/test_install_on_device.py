"""Tests of Scripts/ios/install-on-device.py: the iPhone app onto the user's own iPhone, from the command line.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test uses made-up data: invented teams, devices, and device lists, a repository root in a temporary folder, and a
stand-in for each tool (defaults, xcodebuild, devicectl). Nothing reads Xcode's real preferences, lists a real device,
builds, signs, or installs; the tests of main() replace every function that would.
"""
import contextlib
import importlib.util
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

IOS = Path(__file__).resolve().parents[2] / "ios"
sys.path.insert(0, str(IOS.parent))
sys.path.insert(0, str(IOS))
# install-on-device.py has hyphens in its name, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("install_on_device", IOS / "install-on-device.py")
tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tool)
import size_settings  # noqa: E402

# Made-up teams, in the form of Xcode's IDEProvisioningTeamByIdentifier: each account maps to a list of teams.
TEAM_A = {"teamID": "AAAAAAAAAA", "teamName": "Test Person (Personal Team)", "isFreeProvisioningTeam": True}
TEAM_B = {"teamID": "BBBBBBBBBB", "teamName": "Test Company", "isFreeProvisioningTeam": False}


def device_entry(name="Test Phone", identifier="11111111-AAAA", udid="00001111-AAAA", pairing="paired",
                 tunnel="disconnected", kind="iPhone", reality="physical"):
    """One device of devicectl's JSON, with the fields the tool reads, made up."""
    return {"identifier": identifier,
            "connectionProperties": {"pairingState": pairing, "tunnelState": tunnel, "transportType": "wired"},
            "deviceProperties": {"name": name},
            "hardwareProperties": {"deviceType": kind, "udid": udid, "reality": reality}}


def listing(*entries):
    """devicectl's JSON for these device entries."""
    return {"info": {"outcome": "success"}, "result": {"devices": list(entries)}}


class TeamTests(unittest.TestCase):
    """Choosing the team: the flag, the environment, and Xcode's preferences."""

    def prefs(self, *accounts):
        """Preferences holding these accounts, each a list of teams."""
        return lambda: {"IDEProvisioningTeamByIdentifier": {f"account{n}": teams for n, teams in enumerate(accounts)}}

    def test_the_flag_wins_and_nothing_is_read(self):
        team = tool.choose_team("FLAGFLAG01", {"TEXTMOUTH_TEAM": "ENVENVENV1"}, self.fail)
        self.assertEqual(team.team_id, "FLAGFLAG01")

    def test_the_environment_comes_next_and_nothing_is_read(self):
        team = tool.choose_team(None, {"TEXTMOUTH_TEAM": "ENVENVENV1"}, self.fail)
        self.assertEqual(team.team_id, "ENVENVENV1")

    def test_the_one_team_in_xcodes_preferences_is_used(self):
        team = tool.choose_team(None, {}, self.prefs([TEAM_A]))
        self.assertEqual((team.team_id, team.name, team.free), ("AAAAAAAAAA", "Test Person (Personal Team)", True))

    def test_the_same_team_under_two_accounts_is_one_team(self):
        self.assertEqual(tool.choose_team(None, {}, self.prefs([TEAM_A], [TEAM_A])).team_id, "AAAAAAAAAA")

    def test_several_teams_are_listed_by_name_and_refused(self):
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_team(None, {}, self.prefs([TEAM_A, TEAM_B]))
        message = str(caught.exception)
        self.assertIn("Test Person (Personal Team)", message)
        self.assertIn("Test Company", message)
        self.assertIn("TEAM=", message)
        # The identifiers are not shown, only the names.
        self.assertNotIn("AAAAAAAAAA", message)

    def test_no_team_says_how_to_add_an_apple_id(self):
        for preferences in ({}, {"IDEProvisioningTeamByIdentifier": {}}, {"IDEProvisioningTeamByIdentifier": {"a": []}}):
            with self.subTest(preferences=preferences), self.assertRaises(tool.MissingStep) as caught:
                tool.choose_team(None, {}, lambda: preferences)
            self.assertIn("Xcode > Settings > Accounts", str(caught.exception))

    def test_an_apple_id_without_a_team_says_to_finish_signing_in(self):
        # Made-up identifiers, in a list, a dict of lists, and as dict keys.
        for held in (["reader@example.com"], {"Xcode": ["reader@example.com"]}, {"reader@example.com": {}}):
            preferences = {"DVTDeveloperAccountManagerAppleIDLists": held, "IDEProvisioningTeamByIdentifier": {}}
            with self.subTest(held=held), self.assertRaises(tool.MissingStep) as caught:
                tool.choose_team(None, {}, lambda: preferences)
            message = str(caught.exception)
            self.assertIn("sign-in is not finished", message)
            self.assertIn("Sign in to your Apple ID again", message)
            self.assertNotIn("Add your Apple ID", message)
            # The identifier itself is never spoken.
            self.assertNotIn("reader@example.com", message)

    def test_an_empty_apple_id_list_still_says_to_add_one(self):
        for held in ([], {}, [""], None):
            with self.subTest(held=held), self.assertRaises(tool.MissingStep) as caught:
                tool.choose_team(None, {}, lambda: {"DVTDeveloperAccountManagerAppleIDLists": held})
            self.assertIn("Add your Apple ID", str(caught.exception))

    def test_a_team_wins_over_an_apple_id_list(self):
        preferences = {"DVTDeveloperAccountManagerAppleIDLists": ["reader@example.com"],
                       "IDEProvisioningTeamByIdentifier": {"a": [TEAM_A]}}
        self.assertEqual(tool.choose_team(None, {}, lambda: preferences).team_id, "AAAAAAAAAA")

    def test_a_form_it_does_not_know_asks_for_the_team(self):
        for odd in ({"IDEProvisioningTeamByIdentifier": {"a": [{"id": 5}]}},
                    {"IDEProvisioningTeamByIdentifier": {"a": "text"}},
                    {"IDEProvisioningTeamByIdentifier": ["not", "a", "dict"]}):
            with self.subTest(odd=odd), self.assertRaises(tool.MissingStep) as caught:
                tool.choose_team(None, {}, lambda: odd)
            self.assertIn("a form this script does not know", str(caught.exception))
            self.assertIn("TEAM=", str(caught.exception))

    def test_a_team_without_a_name_is_shown_by_its_identifier(self):
        found, recognized = tool.teams_in_preferences(
            {"IDEProvisioningTeamByIdentifier": {"a": [{"teamID": "CCCCCCCCCC"}]}})
        self.assertTrue(recognized)
        self.assertEqual(found, [tool.Team("CCCCCCCCCC", "CCCCCCCCCC", False)])

    def test_the_team_line_names_the_team_and_a_free_one_says_so(self):
        self.assertEqual(tool.describe_team(tool.Team("X", "Test Company", False)), "Team: Test Company.")
        self.assertIn("free personal team", tool.describe_team(tool.Team("X", "Test Person", True)))
        self.assertEqual(tool.describe_team(tool.Team("X", "", False)), "Team: the one you gave.")

    def test_preferences_come_from_defaults_export_and_a_failure_gives_none(self):
        xml = plistlib.dumps({"IDEProvisioningTeamByIdentifier": {"a": [TEAM_A]}})
        seen = []

        def good(argv, **_):
            seen.append(argv)
            return subprocess.CompletedProcess(argv, 0, xml, b"")

        self.assertIn("IDEProvisioningTeamByIdentifier", tool.read_xcode_preferences(good))
        self.assertEqual(seen, [["defaults", "export", "com.apple.dt.Xcode", "-"]])
        for bad in (b"", b"not a plist", b"<?xml version='1.0'?><plist><bad"):
            self.assertEqual(tool.read_xcode_preferences(
                lambda argv, **_: subprocess.CompletedProcess(argv, 1, bad, b"")), {})

        def missing(argv, **_):
            raise OSError("no defaults")

        self.assertEqual(tool.read_xcode_preferences(missing), {})


class DeviceTests(unittest.TestCase):
    """Choosing the device from devicectl's list."""

    def test_one_paired_iphone_is_chosen(self):
        usable, others = tool.devices_in_listing(listing(device_entry()))
        self.assertEqual(usable, [tool.Device("11111111-AAAA", "00001111-AAAA", "Test Phone")])
        self.assertEqual(others, [])
        self.assertEqual(tool.choose_device(None, usable, others).name, "Test Phone")

    def test_a_paired_iphone_on_the_network_counts_as_ready(self):
        # devicectl's "available (paired)": paired, tunnel disconnected.
        usable, _ = tool.devices_in_listing(listing(device_entry(tunnel="disconnected"), device_entry(
            name="Other", identifier="2", udid="u2", tunnel="connected")))
        self.assertEqual([device.name for device in usable], ["Test Phone", "Other"])

    def test_a_simulator_is_never_ready(self):
        # Xcode 27's devicectl lists simulators, with reality "simulated".
        usable, others = tool.devices_in_listing(listing(
            device_entry(name="Test Simulator", identifier="S1", udid="s1", reality="simulated"), device_entry()))
        self.assertEqual([device.name for device in usable], ["Test Phone"])
        self.assertEqual(others, [])
        self.assertEqual(tool.choose_device(None, usable, others).name, "Test Phone")

    def test_a_listing_with_only_a_simulator_has_no_ready_phone(self):
        usable, others = tool.devices_in_listing(listing(device_entry(reality="simulated")))
        self.assertEqual((usable, others), ([], []))

    def test_an_entry_without_a_reality_counts_as_physical(self):
        entry = device_entry()
        del entry["hardwareProperties"]["reality"]
        self.assertEqual(len(tool.devices_in_listing(listing(entry))[0]), 1)

    def test_no_devices_says_how_to_connect(self):
        usable, others = tool.devices_in_listing(listing())
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device(None, usable, others)
        message = str(caught.exception)
        for words in ("USB", "unlock", "Trust", "Developer Mode"):
            self.assertIn(words, message)
        self.assertNotIn("Seen but not ready", message)

    def test_an_unpaired_device_is_not_ready_and_is_named(self):
        usable, others = tool.devices_in_listing(listing(device_entry(pairing="unpaired")))
        self.assertEqual(usable, [])
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device(None, usable, others)
        self.assertIn("Seen but not ready:\n  Test Phone: not paired", str(caught.exception))

    def test_an_unavailable_device_is_not_ready(self):
        usable, others = tool.devices_in_listing(listing(device_entry(tunnel="unavailable")))
        self.assertEqual(usable, [])
        self.assertIn("not reachable", others[0][1])

    def test_watches_and_other_hardware_are_left_out_without_a_word(self):
        usable, others = tool.devices_in_listing(listing(device_entry(kind="appleWatch"), device_entry(kind="mac")))
        self.assertEqual((usable, others), ([], []))

    def test_several_devices_are_listed_and_refused(self):
        usable, others = tool.devices_in_listing(listing(
            device_entry(), device_entry(name="Other Phone", identifier="2", udid="u2")))
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device(None, usable, others)
        message = str(caught.exception)
        self.assertIn("Test Phone", message)
        self.assertIn("Other Phone", message)
        self.assertIn("DEVICE=", message)

    def test_a_selector_names_a_device_by_name_udid_or_identifier(self):
        usable, others = tool.devices_in_listing(listing(
            device_entry(), device_entry(name="Other Phone", identifier="2-BB", udid="u2-bb")))
        for selector, name in (("other phone", "Other Phone"), ("U2-BB", "Other Phone"),
                               ("2-bb", "Other Phone"), ("00001111-aaaa", "Test Phone")):
            with self.subTest(selector=selector):
                self.assertEqual(tool.choose_device(selector, usable, others).name, name)

    def test_a_straight_or_curly_apostrophe_matches_either(self):
        curly = tool.Device("1", "u1", "Reader\u2019s Phone")
        straight = tool.Device("2", "u2", "Other's Phone")
        for selector, expected in (("Reader's Phone", curly), ("Reader\u2019s Phone", curly),
                                   ("READER\u2019S phone", curly), ("Other\u2019s Phone", straight),
                                   ("other's phone", straight)):
            with self.subTest(selector=selector):
                self.assertEqual(tool.match_device(selector, [curly, straight]), [expected])
        self.assertEqual(tool.match_device("Readers Phone", [curly, straight]), [])

    def test_a_selector_that_names_nothing_lists_the_ready_ones(self):
        usable, others = tool.devices_in_listing(listing(device_entry()))
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device("Nowhere", usable, others)
        self.assertIn("No ready iPhone is named 'Nowhere'", str(caught.exception))
        self.assertIn("Test Phone", str(caught.exception))

    def test_a_selector_with_no_ready_device_says_how_to_connect(self):
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device("Test Phone", [], [])
        self.assertIn("Developer Mode", str(caught.exception))

    def test_two_devices_with_one_name_need_the_udid(self):
        usable, others = tool.devices_in_listing(listing(device_entry(), device_entry(identifier="2", udid="u2")))
        with self.assertRaises(tool.MissingStep) as caught:
            tool.choose_device("Test Phone", usable, others)
        self.assertIn("UDID", str(caught.exception))

    def test_json_in_an_unknown_form_is_refused(self):
        for odd in ({}, {"result": {}}, {"result": {"devices": "none"}}, {"result": {"devices": [7]}},
                    {"result": {"devices": [{"name": "no identifier"}]}}, [], None):
            with self.subTest(odd=odd), self.assertRaises(tool.UnknownDeviceList):
                tool.devices_in_listing(odd)

    def test_a_device_without_a_udid_uses_its_identifier(self):
        entry = device_entry()
        del entry["hardwareProperties"]["udid"]
        usable, _ = tool.devices_in_listing(listing(entry))
        self.assertEqual(usable[0].udid, "11111111-AAAA")

    def test_an_unknown_list_prints_the_tools_table_and_asks_for_device(self):
        with tempfile.TemporaryDirectory() as folder:
            def fake(argv, **_):
                if "--json-output" in argv:
                    Path(argv[argv.index("--json-output") + 1]).write_text(json.dumps({"surprise": 1}))
                    return subprocess.CompletedProcess(argv, 0, "", "")
                return subprocess.CompletedProcess(argv, 0, "Name  State\nTest Phone  available\n", "")

            with mock.patch.object(tool.subprocess, "run", fake), self.assertRaises(tool.MissingStep) as caught:
                tool.list_devices(Path(folder), folder)
            self.assertIn("Test Phone  available", str(caught.exception))
            self.assertIn("DEVICE=", str(caught.exception))

    def test_a_failing_list_command_does_the_same(self):
        with tempfile.TemporaryDirectory() as folder:
            def fake(argv, **_):
                return subprocess.CompletedProcess(argv, 1 if "--json-output" in argv else 0, "table", "")

            with mock.patch.object(tool.subprocess, "run", fake), self.assertRaises(tool.MissingStep) as caught:
                tool.list_devices(Path(folder), folder)
            self.assertIn("status 1", str(caught.exception))


class CommandTests(unittest.TestCase):
    """The command lines of the build, the install, and the launch."""

    def build(self, profile):
        return tool.xcodebuild_command("/repo", "/repo/build/ios-device", "AAAAAAAAAA", "00001111-AAAA", profile)

    def test_the_build_signs_for_the_team_and_the_device_with_provisioning_allowed(self):
        argv = self.build("light")
        self.assertEqual(argv[:2], ["xcodebuild", "build"])
        for pair in (["-scheme", "TextMouthiOS"], ["-configuration", "Release"],
                     ["-destination", "id=00001111-AAAA"], ["-derivedDataPath", "/repo/build/ios-device"],
                     ["-project", "/repo/TextMouth.xcodeproj"]):
            with self.subTest(pair=pair):
                self.assertEqual(argv[argv.index(pair[0]) + 1], pair[1])
        for word in ("DEVELOPMENT_TEAM=AAAAAAAAAA", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"):
            self.assertIn(word, argv)
        # It is a signed build: nothing turns signing off.
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", argv)

    def test_each_profile_takes_its_size_settings(self):
        light, full = self.build("light"), self.build("full")
        for word in size_settings.settings(profile="light"):
            self.assertIn(word, light)
        for word in size_settings.settings(profile="full"):
            self.assertIn(word, full)
        self.assertNotIn("SWIFT_LTO=YES", light)
        self.assertIn("SWIFT_LTO=YES", full)
        self.assertIn("GCC_OPTIMIZATION_LEVEL=z", light)
        # Every profile builds small code for the device, as app-size.py does.
        for argv in (light, full):
            for word in ("ARCHS=arm64", "SWIFT_OPTIMIZATION_LEVEL=-Osize", "DEPLOYMENT_POSTPROCESSING=YES",
                         "CLANG_COVERAGE_MAPPING=NO"):
                self.assertIn(word, argv)

    def test_auto_follows_the_environment(self):
        with mock.patch.dict("os.environ", {"GITHUB_ACTIONS": "true"}):
            self.assertIn("SWIFT_LTO=YES", self.build("auto"))
        with mock.patch.dict("os.environ", {"GITHUB_ACTIONS": "false"}):
            self.assertNotIn("SWIFT_LTO=YES", self.build("auto"))

    def test_the_build_shares_its_settings_with_the_size_tool(self):
        # app-size.py takes the same small-code settings from the same module, so the two cannot drift apart.
        spec = importlib.util.spec_from_file_location("app_size", IOS / "app-size.py")
        app_size = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(app_size)
        shared = app_size.iphone_release.release_settings()
        self.assertTrue(all(word in app_size.build_command("/x/dd") for word in shared))
        self.assertTrue(all(word in self.build("auto") for word in shared))

    def test_install_and_launch_name_the_device_and_the_app(self):
        self.assertEqual(tool.install_command("11111111-AAAA", "/repo/TextMouth.app"),
                         ["xcrun", "devicectl", "device", "install", "app", "--device", "11111111-AAAA",
                          "/repo/TextMouth.app"])
        self.assertEqual(tool.launch_command("11111111-AAAA", "com.example.App"),
                         ["xcrun", "devicectl", "device", "process", "launch", "--device", "11111111-AAAA",
                          "com.example.App"])

    def test_the_list_command_writes_json_to_the_given_file(self):
        self.assertEqual(tool.list_command("/repo/build/ios-device/devices.json"),
                         ["xcrun", "devicectl", "list", "devices", "--json-output", "/repo/build/ios-device/devices.json"])


class FailureHintTests(unittest.TestCase):
    """The words that fix the errors a person is likely to meet."""

    def test_each_likely_error_names_its_fix(self):
        cases = (
            ("error: Developer Mode is disabled on the device", "Privacy & Security > Developer Mode"),
            ("The request was denied: the app has not been explicitly trusted by the user", "VPN & Device Management"),
            ("Provisioning profile \"x\" has expired", "Run this command again"),
            ("error: Failed to register bundle identifier. The app identifier \"a.b\" cannot be registered to your "
             "development team because it is not available.", "Another team already holds"),
            ("error: No Account for Team \"AAAAAAAAAA\"", "Settings > Accounts"),
            ("The device is locked.", "Unlock it"),
            ("iOS 26.0 is not installed. Please download and install the platform", "Settings > Components"),
            ("Unable to find a destination matching the provided destination specifier", "destination"),
        )
        for text, fix in cases:
            with self.subTest(text=text):
                self.assertIn(fix, " ".join(tool.failure_hints(text)))

    def test_an_error_it_does_not_know_gives_no_fix_and_a_fix_is_said_once(self):
        self.assertEqual(tool.failure_hints("error: something nobody foresaw"), [])
        twice = tool.failure_hints("Developer Mode is disabled\nDeveloper Mode is not enabled")
        self.assertEqual(len(twice), 1)

    def test_a_failure_prints_the_status_the_fixes_and_the_log(self):
        out = io.StringIO()
        tool.say_failure("The build", 65, "/repo/build/ios-device/install.log", "The device is locked.", out=out)
        text = out.getvalue()
        self.assertIn("The build failed (exit status 65).", text)
        self.assertIn("Unlock it", text)
        self.assertIn("The full log is /repo/build/ios-device/install.log", text)


class RunBuildTests(unittest.TestCase):
    """Running a tool: its output goes to the log, and only errors and the verdict are printed."""

    def test_output_goes_to_the_log_and_errors_and_the_verdict_are_printed_once(self):
        script = ("print('CompileSwift normal arm64 a.swift')\n"
                  "print('a.swift:1:1: error: boom')\n"
                  "print('a.swift:1:1: error: boom')\n"
                  "print('** BUILD FAILED **')\n"
                  "raise SystemExit(65)\n")
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "install.log"
            out = io.StringIO()
            status = tool.run_build([sys.executable, "-I", "-c", script], log, folder, out=out)
            self.assertEqual(status, 65)
            self.assertIn("CompileSwift normal arm64 a.swift", log.read_text())
            self.assertEqual(out.getvalue().splitlines(), ["a.swift:1:1: error: boom", "** BUILD FAILED **"])

    def test_a_long_build_says_it_is_still_going(self):
        ticks = iter([0, 0, 61, 61, 130, 130, 130, 130])
        with tempfile.TemporaryDirectory() as folder:
            out = io.StringIO()
            tool.run_build([sys.executable, "-I", "-c", "print('a'); print('b'); print('c')"],
                           Path(folder) / "log", folder, out=out, clock=lambda: next(ticks))
            self.assertIn("Still building: 1 minutes in.", out.getvalue())


class DryRunTests(unittest.TestCase):
    """--dry-run prints each command and runs none."""

    def run_main(self, *argv, environ=None):
        """main() with a root in a temporary folder and every tool replaced by one that fails the test."""
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(tool.subprocess, "run", side_effect=AssertionError), \
                mock.patch.object(tool.subprocess, "Popen", side_effect=AssertionError), \
                mock.patch.object(tool, "read_xcode_preferences", side_effect=AssertionError), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = tool.main(list(argv), root=folder, environ=environ or {})
            made = list(Path(folder).iterdir())
        return status, out.getvalue(), err.getvalue(), made

    def test_it_prints_the_commands_with_placeholders_and_runs_nothing(self):
        status, out, err, made = self.run_main("--dry-run")
        self.assertEqual(status, 0)
        self.assertIn("devicectl list devices", out)
        self.assertIn("xcodebuild build", out)
        self.assertIn("team identifier from Xcode", out)
        self.assertIn("devicectl device install app", out)
        self.assertNotIn("process launch", out)
        self.assertIn("Profile: light.", out)
        # It makes no folder either.
        self.assertEqual(made, [])
        self.assertEqual(err, "")

    def test_it_uses_what_was_given_and_adds_the_launch(self):
        status, out, _, _ = self.run_main("--dry-run", "--launch", "--profile", "full", "--team", "AAAAAAAAAA",
                                          "--device", "00001111-AAAA")
        self.assertEqual(status, 0)
        self.assertIn("DEVELOPMENT_TEAM=AAAAAAAAAA", out)
        self.assertIn("id=00001111-AAAA", out)
        self.assertIn("SWIFT_LTO=YES", out)
        self.assertIn("process launch --device 00001111-AAAA", out)
        self.assertIn("Profile: full.", out)

    def test_the_team_comes_from_the_environment_too(self):
        _, out, _, _ = self.run_main("--dry-run", environ={"TEXTMOUTH_TEAM": "ENVENVENV1"})
        self.assertIn("DEVELOPMENT_TEAM=ENVENVENV1", out)

    def test_a_profile_it_does_not_know_is_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            tool.main(["--dry-run", "--profile", "fulll"])
        self.assertEqual(caught.exception.code, 2)


class MainTests(unittest.TestCase):
    """A whole run, with each tool replaced: the order of the steps, the exit statuses, and the words."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.commands = []
        # A built app, in the place a real build leaves it, with an Info.plist holding a made-up identifier.
        self.app = self.root / "build" / "ios-device" / "Build" / "Products" / "Release-iphoneos" / "TextMouth.app"
        self.app.mkdir(parents=True)
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.Reader"}))
        self.statuses = {"build": 0, "install": 0, "launch": 0}
        self.prefs = {"IDEProvisioningTeamByIdentifier": {"a": [TEAM_A]}}
        self.devices = listing(device_entry())

    def fake_build(self, argv, log_path, cwd, **_):
        """Stands in for run_build: records the command and writes a log."""
        self.commands.append(argv)
        Path(log_path).write_text("The device is locked.\n" if self.statuses["build"] else "ok\n")
        return self.statuses["build"]

    def fake_logged(self, argv, log_path, cwd):
        """Stands in for run_logged: answers a device list, an install, or a launch."""
        self.commands.append(argv)
        if "--json-output" in argv:
            Path(argv[argv.index("--json-output") + 1]).write_text(json.dumps(self.devices))
            return 0, ""
        key = "install" if "install" in argv else "launch"
        return self.statuses[key], ("Developer Mode is disabled" if self.statuses[key] else "done")

    def run_main(self, *argv, environ=None):
        """main() with the tools replaced; returns (status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(tool, "read_xcode_preferences", lambda: self.prefs), \
                mock.patch.object(tool, "run_build", self.fake_build), \
                mock.patch.object(tool, "run_logged", self.fake_logged), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = tool.main(list(argv), root=self.root, environ=environ or {})
        return status, out.getvalue(), err.getvalue()

    def test_a_good_run_builds_installs_and_says_so(self):
        status, out, err = self.run_main()
        self.assertEqual(status, 0, err)
        self.assertIn("Team: Test Person (Personal Team) (a free personal team)", out)
        self.assertIn("Device: Test Phone.", out)
        self.assertIn("Installed. Open TextMouth on your iPhone.", out)
        self.assertIn("run this command again then", out)
        kinds = [argv[0] if argv[0] == "xcodebuild" else argv[3] for argv in self.commands]
        self.assertEqual(kinds, ["devices", "xcodebuild", "install"])
        build = self.commands[1]
        self.assertIn("DEVELOPMENT_TEAM=AAAAAAAAAA", build)
        self.assertIn("id=00001111-AAAA", build)
        self.assertEqual(self.commands[2][-1], str(self.app.resolve()))

    def test_launch_starts_the_app_by_the_identifier_in_its_plist(self):
        status, out, _ = self.run_main("--launch")
        self.assertEqual(status, 0)
        self.assertIn("Launched.", out)
        self.assertEqual(self.commands[-1], ["xcrun", "devicectl", "device", "process", "launch", "--device",
                                             "11111111-AAAA", "com.example.Reader"])

    def test_a_paid_team_gets_no_week_warning(self):
        self.prefs = {"IDEProvisioningTeamByIdentifier": {"a": [TEAM_B]}}
        _, out, _ = self.run_main()
        self.assertNotIn("a week", out)

    def test_no_team_stops_with_status_2_before_anything_runs(self):
        self.prefs = {}
        status, out, err = self.run_main()
        self.assertEqual(status, 2)
        self.assertIn("Xcode > Settings > Accounts", err)
        self.assertEqual(self.commands, [])

    def test_no_device_stops_with_status_2_before_the_build(self):
        self.devices = listing()
        status, _, err = self.run_main()
        self.assertEqual(status, 2)
        self.assertIn("Developer Mode", err)
        self.assertEqual([argv[0] for argv in self.commands], ["xcrun"])

    def test_several_devices_stop_with_status_2_and_a_device_flag_chooses(self):
        self.devices = listing(device_entry(), device_entry(name="Other Phone", identifier="2", udid="u2"))
        status, _, err = self.run_main()
        self.assertEqual(status, 2)
        self.assertIn("Other Phone", err)
        status, out, _ = self.run_main("--device", "Other Phone")
        self.assertEqual(status, 0)
        self.assertIn("id=u2", self.commands[-2])

    def test_a_failed_build_exits_with_its_status_and_names_the_fix_and_the_log(self):
        self.statuses["build"] = 65
        status, _, err = self.run_main()
        self.assertEqual(status, 65)
        self.assertIn("The build failed (exit status 65).", err)
        self.assertIn("Unlock it", err)
        self.assertIn("install.log", err)
        # Nothing was installed.
        self.assertFalse(any("install" in argv for argv in self.commands))

    def test_a_failed_install_exits_with_its_status_and_names_the_fix(self):
        self.statuses["install"] = 1
        status, _, err = self.run_main()
        self.assertEqual(status, 1)
        self.assertIn("Developer Mode is off", err)
        self.assertIn("devicectl.log", err)

    def test_a_failed_launch_exits_with_its_status(self):
        self.statuses["launch"] = 1
        status, out, err = self.run_main("--launch")
        self.assertEqual(status, 1)
        self.assertIn("Installed.", out)
        self.assertIn("Launching the app failed", err)

    def test_the_profile_flag_reaches_the_build(self):
        self.run_main("--profile", "full")
        self.assertIn("SWIFT_LTO=YES", self.commands[1])
        self.run_main()
        self.assertNotIn("SWIFT_LTO=YES", self.commands[-2])


if __name__ == "__main__":
    unittest.main()
