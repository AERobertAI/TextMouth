"""Tests of the --tests option of Scripts/ios/typecheck.py: the Mac's hosted tests, type-checked.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test works in a throwaway repository inside a temporary folder, points the
script's work folder, results, and heavy-work lock there, and stands in for the
`swift build` command, so no test builds anything, reads the real repository's
work folders, or touches the Mac's real lock.
"""
import contextlib
import importlib.util
import io
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from heavy_lock_case import AGENTS
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set by heavy_lock_case)

# typecheck.py is in Scripts/ios, beside Scripts/agents.
_spec = importlib.util.spec_from_file_location("typecheck", AGENTS.parent / "ios" / "typecheck.py")
typecheck = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(typecheck)

# A project.yml with the hosted test target among other targets, as the real one lists its sources.
PROJECT_YML = """\
targets:
  TextMouth:
    sources:
      - TextMouth
      - TextMouthTests/Sources/Tests/NotMine.swift
  TextMouthProductionTests:
    type: bundle.unit-test
    sources:
      - TextMouthProductionTests
      # A comment between the entries.
      - TextMouthTests/Sources/Tests/ListedA.swift
      - TextMouthTests/Sources/Tests/ListedB.swift
    settings:
      base:
        PRODUCT_NAME: x
  TextMouthiOSTests:
    sources:
      - TextMouthiOSTests
      # A Mac test file the iPhone's unit tests share, listed by path.
      - TextMouthProductionTests/FirstTests.swift
    settings:
      base:
        PRODUCT_NAME: y
"""

# The files of the throwaway repository: path to text.
FILES = {
    "project.yml": PROJECT_YML,
    "TextMouth/App.swift": "// app\n",
    "TextMouth/Resources/R.txt": "resource\n",
    "TextMouth/Localization/Localizable.xcstrings": "{}",
    "Vendor/lame/include/lame.h": "// h\n",
    "TextMouthBraille/include/b.h": "// h\n",
    "TextMouthFFmpeg/include/f.h": "// h\n",
    "TextMouthProductionTests/FirstTests.swift": "// first\n",
    "TextMouthProductionTests/Info.plist": "<plist/>\n",
    "TextMouthProductionTests/performance-baselines.json": "{}\n",
    "TextMouthTests/Sources/Tests/ListedA.swift": "// a\n",
    "TextMouthTests/Sources/Tests/ListedB.swift": "// b\n",
    "TextMouthTests/Sources/Tests/NotMine.swift": "// not listed for the tests\n",
    "TextMouthiOSTests/PhoneTests.swift": "// the iPhone's own\n",
    "TextMouthiOSUITests/LibraryUITests.swift": "import XCTest\n",
    "TextMouthiOSUITests/Notes.txt": "not Swift\n",
    "Scripts/test/areas.conf": "[demo] a demo area\nFirstTests\n",
    str(typecheck.RESOLVED): json.dumps({"pins": [
        {"identity": identity, "location": f"https://example.invalid/{identity}", "state": {"revision": "0" * 40}}
        for identity, _, _ in typecheck.PACKAGES]}),
}


class TypecheckTestsCase(unittest.TestCase):
    """A throwaway repository holding FILES, committed, and a temporary work area."""

    def git(self, *args):
        """Runs git in the throwaway repository; returns its output."""
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True,
                              check=True).stdout.strip()

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "T")
        self.git("config", "commit.gpgsign", "false")
        for name, text in FILES.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "files")
        self.commit = self.git("rev-parse", "HEAD")
        self.src = self.folder / "work" / "src"
        self.assertTrue(str(self.src).startswith(str(self.folder)))


class SourceTests(TypecheckTestsCase):
    """Which files the tests' copy holds."""

    def test_the_listed_files_are_those_of_the_hosted_test_target_only(self):
        self.assertEqual(typecheck.listed_test_files(self.repo, self.commit),
                         ["TextMouthTests/Sources/Tests/ListedA.swift", "TextMouthTests/Sources/Tests/ListedB.swift"])

    def test_a_project_without_the_target_is_refused(self):
        (self.repo / "project.yml").write_text("targets:\n  TextMouth:\n    settings:\n")
        self.git("commit", "-q", "-am", "no tests")
        with self.assertRaises(RuntimeError):
            typecheck.listed_test_files(self.repo, self.git("rev-parse", "HEAD"))

    def test_the_tests_copy_holds_the_swift_files_of_the_folder_and_the_listed_ones_only(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests=True)
        found = sorted(str(p.relative_to(self.src / typecheck.TEST_TARGET)) for p in
                       (self.src / typecheck.TEST_TARGET).rglob("*") if p.is_file())
        self.assertEqual(found, ["FirstTests.swift", "_ListedInProjectYml/ListedA.swift",
                                 "_ListedInProjectYml/ListedB.swift"],
                         "the target's folder should hold only Swift files, and the listed ones in their own folder")
        self.assertTrue((self.src / "TextMouth" / "App.swift").exists())

    def test_the_listed_files_of_the_iphone_target_are_the_mac_files_it_shares(self):
        self.assertEqual(typecheck.listed_test_files(self.repo, self.commit, typecheck.IOS_TEST_TARGET),
                         ["TextMouthProductionTests/FirstTests.swift"])

    def test_the_iphone_tests_copy_holds_its_own_files_and_the_shared_ones_beside_them(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="ios")
        found = sorted(str(p.relative_to(self.src / typecheck.IOS_TEST_TARGET)) for p in
                       (self.src / typecheck.IOS_TEST_TARGET).rglob("*") if p.is_file())
        self.assertEqual(found, ["PhoneTests.swift", "_SharedWithTheMac/FirstTests.swift"])

    def test_the_iphone_tests_copy_holds_the_interface_tests_swift_files_only(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="ios")
        found = sorted(p.name for p in (self.src / typecheck.IOS_UI_TEST_TARGET).rglob("*") if p.is_file())
        self.assertEqual(found, ["LibraryUITests.swift"])

    def test_the_mac_tests_copy_holds_no_interface_tests(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests=True)
        self.assertFalse((self.src / typecheck.IOS_UI_TEST_TARGET).exists())

    def test_the_census_copy_holds_all_of_the_mac_tests_and_the_area_list(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="census")
        self.assertTrue((self.src / typecheck.TEST_TARGET / "FirstTests.swift").exists())
        self.assertFalse((self.src / typecheck.IOS_TEST_TARGET).exists())

    def test_without_tests_the_copy_holds_no_test_files(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False)
        self.assertFalse((self.src / typecheck.TEST_TARGET).exists())
        self.assertFalse((self.src / "project.yml").exists())


class CensusTests(TypecheckTestsCase):
    """What the tests census finds before and after its builds."""

    def test_a_file_that_imports_a_module_the_iphone_lacks_is_found_without_a_build(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="census")
        (self.src / typecheck.TEST_TARGET / "Power.swift").write_text("import XCTest\n@testable import TextMouth\nimport IOKit.pwr_mgt\n")
        (self.src / typecheck.TEST_TARGET / "Plain.swift").write_text("import Foundation\nimport XCTest\n")
        asked = []

        def fake_swiftc(command, **options):
            """The compiler: it lacks IOKit and has everything else."""
            asked.append(Path(command[-1]).read_text().strip())
            return SimpleNamespace(returncode=1 if "IOKit" in asked[-1] else 0)

        with mock.patch.object(typecheck.subprocess, "run", fake_swiftc):
            found = typecheck.unavailable_imports(self.src, "/sdk", "26.0", lambda text: None)
        self.assertEqual(found, {"Power.swift": ["IOKit.pwr_mgt"]})
        self.assertNotIn("import XCTest", asked, "the test framework is not asked about")

    def test_those_files_are_left_out_of_the_first_build_and_the_closure_ends_when_a_build_is_clean(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="census")
        skipped_seen = []

        def build(skipped):
            """A build that is clean once nothing but the file named is left out."""
            skipped_seen.append(list(skipped))
            return "Build of target: 'TextMouthProductionTests' complete!\n"

        result = typecheck.run_census(build, self.src, lambda text: None, None, {"FirstTests.swift": ["IOKit"]})
        self.assertEqual(skipped_seen, [["FirstTests.swift"]])
        self.assertTrue(result["ok"])
        self.assertEqual(result["skipped"]["FirstTests.swift"]["messages"], ["no such module 'IOKit' on iOS"])

    def test_a_build_that_names_a_file_makes_the_next_one_leave_it_out(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="census")
        seen = []

        def build(skipped):
            """The first build fails in FirstTests; the second is clean."""
            seen.append(list(skipped))
            if not skipped:
                return f"{self.src / typecheck.TEST_TARGET / 'FirstTests.swift'}:3:1: error: cannot find 'NSWindow' in scope\n"
            return "Build of target: 'TextMouthProductionTests' complete!\n"

        result = typecheck.run_census(build, self.src, lambda text: None)
        self.assertEqual(seen, [[], ["FirstTests.swift"]])
        self.assertEqual(result["skipped"]["FirstTests.swift"]["round"], 1)


class PackageTests(TypecheckTestsCase):
    """The package written around the copy."""

    def package(self, tests):
        """The text of the Package.swift written for a copy with or without the tests."""
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests=tests)
        typecheck.write_package(self.src, self.folder / "pkgs", "macos", "26.0", tests)
        return (self.src / "Package.swift").read_text()

    def test_the_tests_package_has_the_hosted_test_target_on_the_app(self):
        text = self.package(tests=True)
        self.assertIn(f'.testTarget(\n            name: "{typecheck.TEST_TARGET}"', text)
        self.assertIn(f'path: "{typecheck.TEST_TARGET}"', text)
        self.assertIn('"TextMouth",', text.split(".testTarget(")[1], "the test target does not depend on the app")

    def test_the_iphone_package_names_its_target_its_folder_and_where_xctest_is(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="ios")
        with mock.patch.object(typecheck, "run", lambda *a, **k: SimpleNamespace(stdout="/platform\n")):
            typecheck.write_package(self.src, self.folder / "pkgs", "ios", "26.0", "ios")
        text = (self.src / "Package.swift").read_text()
        self.assertIn(f'name: "{typecheck.IOS_TEST_TARGET}"', text)
        self.assertIn(f'path: "{typecheck.IOS_TEST_TARGET}"', text)
        self.assertIn('"-F", "/platform/Developer/Library/Frameworks"', text)

    def test_the_iphone_package_has_the_interface_test_target_on_xctest_alone(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="ios")
        with mock.patch.object(typecheck, "run", lambda *a, **k: SimpleNamespace(stdout="/platform\n")):
            typecheck.write_package(self.src, self.folder / "pkgs", "ios", "26.0", "ios")
        text = (self.src / "Package.swift").read_text()
        block = text.split(f'name: "{typecheck.IOS_UI_TEST_TARGET}"')[1].split("),")[0]
        self.assertIn(f'path: "{typecheck.IOS_UI_TEST_TARGET}"', block)
        self.assertNotIn("dependencies", block, "the interface tests drive the app from outside and link none of it")
        self.assertIn('"-F", "/platform/Developer/Library/Frameworks"', block, "XCTest is found as the unit tests find it")
        self.assertEqual(text.count(".testTarget("), 2)

    def test_only_the_iphone_tests_package_has_the_interface_test_target(self):
        for kind, platform in ((True, "macos"), ("census", "ios"), (False, "ios")):
            typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests=kind)
            with mock.patch.object(typecheck, "run", lambda *a, **k: SimpleNamespace(stdout="/platform\n")):
                typecheck.write_package(self.src, self.folder / "pkgs", platform, "26.0", kind)
            self.assertNotIn(typecheck.IOS_UI_TEST_TARGET, (self.src / "Package.swift").read_text(), (kind, platform))

    def test_the_string_catalog_is_not_an_unhandled_resource_of_either_platforms_app(self):
        # The catalog is the pack's source, in no app's resources; SwiftPM warns about every file of a target it does not handle, and a
        # warning about it is a failure of the type-check, so both platforms' app targets leave the catalog file out. Only
        # the file, not its folder: Localization/InterfaceText/ holds the interface-text engine's Swift sources (FR39),
        # which the type-check must compile.
        for platform in ("macos", "ios"):
            typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests=False)
            with mock.patch.object(typecheck, "run", lambda *a, **k: SimpleNamespace(stdout="/platform\n")):
                typecheck.write_package(self.src, self.folder / "pkgs", platform, "26.0", False)
            block = (self.src / "Package.swift").read_text().split('path: "TextMouth",')[1].split("swiftSettings")[0]
            self.assertIn('"Localization/Localizable.xcstrings"', block, platform)
            self.assertNotIn('"Localization"', block, f"{platform}: the folder itself is not left out")

    def test_files_to_skip_are_left_out_of_the_target(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False, tests="census")
        typecheck.write_package(self.src, self.folder / "pkgs", "macos", "26.0", "census", ["FirstTests.swift"])
        self.assertRegex((self.src / "Package.swift").read_text(), r'exclude: \[[^\]]*"FirstTests.swift"')

    def test_the_plain_package_has_no_test_target(self):
        self.assertNotIn(".testTarget(", self.package(tests=False))

    def test_only_the_iphone_app_links_the_braille_library_and_liblouis(self):
        # The iPhone app calls the braille translation in its own process (DR34), so its package builds both C targets
        # and its app depends on them; the Mac app's braille helper links them instead, so the Mac's package has
        # neither.
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False)
        typecheck.write_package(self.src, self.folder / "pkgs", "ios", "26.0")
        ios = (self.src / "Package.swift").read_text()
        app = ios.split(".executableTarget(")[1]
        for name in ("liblouis", typecheck.BRAILLE_LIBRARY_TARGET):
            self.assertIn(f'.target(\n            name: "{name}"', ios)
            self.assertIn(f'"{name}",', app, f"the iPhone app does not depend on {name}")
        self.assertIn('exclude: ["main.c", "include"]', ios, "the helper's main is built into the iPhone's library")
        self.assertIn(f'publicHeadersPath: "{typecheck.NO_PUBLIC_HEADERS}"', ios)
        # SwiftPM refuses a public-headers folder that is not there, so the iPhone's package makes each one, empty.
        for folder in ("Vendor/liblouis", "TextMouthBraille"):
            headers = self.src / folder / typecheck.NO_PUBLIC_HEADERS
            self.assertTrue(headers.is_dir(), headers)
            self.assertEqual(list(headers.iterdir()), [], headers)
        mac = self.package(tests=False)
        self.assertNotIn("liblouis", mac)
        self.assertNotIn(typecheck.BRAILLE_LIBRARY_TARGET, mac)
        # SwiftPM makes a module of each C target's name, so the library's target must not be named as its module is.
        self.assertNotEqual(typecheck.BRAILLE_LIBRARY_TARGET, "TextMouthBrailleLibrary")

    def test_only_the_iphone_app_links_the_ffmpeg_sessions_stand_in(self):
        # The iPhone app runs the FFmpeg session in its own process (FMT54), and the session needs FFmpeg's own
        # build, so the iPhone's package builds a stand-in of it and its app depends on that; the Mac app runs the
        # session in its helper, so the Mac's package has neither.
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False)
        typecheck.write_package(self.src, self.folder / "pkgs", "ios", "26.0")
        ios = (self.src / "Package.swift").read_text()
        app = ios.split(".executableTarget(")[1]
        self.assertIn(f'.target(\n            name: "{typecheck.FFMPEG_SESSION_STUB_TARGET}"', ios)
        self.assertIn(f'"{typecheck.FFMPEG_SESSION_STUB_TARGET}",', app, "the iPhone app does not link the stand-in")
        folder = self.src / typecheck.FFMPEG_SESSION_STUB_FOLDER
        self.assertEqual((folder / "session_stub.c").read_text(), typecheck.FFMPEG_SESSION_STUB)
        self.assertEqual(list((folder / typecheck.NO_PUBLIC_HEADERS).iterdir()), [])
        # SwiftPM makes a module of the target's name, which must not be the session's own module.
        self.assertNotEqual(typecheck.FFMPEG_SESSION_STUB_TARGET, "TextMouthFFmpegSession")
        mac = self.package(tests=False)
        self.assertNotIn(typecheck.FFMPEG_SESSION_STUB_TARGET, mac)
        self.assertFalse((self.src / typecheck.FFMPEG_SESSION_STUB_FOLDER / "session_stub.c").exists())

    def test_the_stand_in_defines_every_function_the_sessions_header_declares(self):
        # A function the header gains without its stand-in would fail the iPhone's type-check only at the link; this
        # names it at once. The header is the repository's own; each declaration is a line ending its name with "(",
        # outside comments, and the stand-in must define each name once.
        header = (AGENTS.parent.parent / "TextMouthFFmpeg" / "include" / "TextMouthFFmpegSession.h").read_text()
        code = re.sub(r"/\*.*?\*/", "", header, flags=re.S)
        declared = set(re.findall(r"\b(tmff_\w+)\(", code))
        self.assertIn("tmff_session_next", declared, "no declaration was read from the header")
        defined = re.findall(r"^[\w][\w \*]*\b(tmff_\w+)\([^;]*\{", typecheck.FFMPEG_SESSION_STUB, flags=re.M)
        self.assertEqual(sorted(defined), sorted(declared))


class SummaryTests(TypecheckTestsCase):
    """Errors and warnings in the tests' files, as the summary reports them."""

    def summarize(self, log_lines, tests=True):
        """Summarizes a made-up build log; returns (summary text, error count, errors.txt text)."""
        out = self.folder / "out"
        log = "\n".join(log_lines) + "\n"
        summary, count, _, _ = typecheck.summarize(log, self.src, "# header", out, tests)
        return summary, count, (out / "errors.txt").read_text()

    def line(self, relative, kind, message, number=7):
        """A compiler diagnostic for a file of the copy."""
        return f"{self.src / relative}:{number}:3: {kind}: {message}"

    def test_an_error_in_a_listed_file_is_reported_under_its_repository_path(self):
        summary, count, errors = self.summarize([
            self.line(f"{typecheck.LISTED_TESTS_FOLDER}/ListedA.swift", "error", "oops")])
        self.assertEqual(count, 1)
        self.assertEqual(errors, "TextMouthTests/Sources/Tests/ListedA.swift:7:3: error: oops\n")
        self.assertIn("Errors in the app and its tests: **1**", summary)

    def test_an_error_in_the_target_folder_is_reported_under_its_path(self):
        _, _, errors = self.summarize([self.line("TextMouthProductionTests/FirstTests.swift", "error", "oops", 713)])
        self.assertEqual(errors, "TextMouthProductionTests/FirstTests.swift:713:3: error: oops\n")

    def test_a_colored_error_is_reported_as_its_plain_line(self):
        # Xcode 27's compiler colors each diagnostic and links it to its documentation, even in a log file.
        colored = (f"{self.src / 'TextMouthProductionTests/FirstTests.swift'}:24:50: \x1b[1;31merror: \x1b[1;39m"
                   "too complex \x1b]8;;https://docs.swift.org/x\x1b\\[#Complex]\x1b]8;;\x1b\\\x1b[0;0m")
        summary, count, errors = self.summarize([colored])
        self.assertEqual(count, 1)
        self.assertEqual(errors, "TextMouthProductionTests/FirstTests.swift:24:50: error: too complex [#Complex]\n")
        self.assertIn("Errors in the app and its tests: **1**", summary)

    def test_terminal_escapes_are_removed_and_plain_text_is_kept(self):
        self.assertEqual(typecheck.without_terminal_escapes("\x1b[0;36m24 |\x1b[0;0m let a\x1b]8;;u\x07b\x1b]8;;\x07"), "24 | let ab")
        self.assertEqual(typecheck.without_terminal_escapes("/a.swift:1:2: error: plain"), "/a.swift:1:2: error: plain")

    def test_two_errors_in_two_files_are_both_counted(self):
        _, count, _ = self.summarize([
            self.line("TextMouthProductionTests/FirstTests.swift", "error", "a", 713),
            self.line(f"{typecheck.LISTED_TESTS_FOLDER}/ListedB.swift", "error", "b", 256)])
        self.assertEqual(count, 2)

    def test_an_error_in_an_interface_test_is_reported_under_its_path(self):
        _, count, errors = self.summarize([
            self.line("TextMouthiOSUITests/LibraryUITests.swift", "error", "cannot find 'x' in scope", 42)])
        self.assertEqual(count, 1)
        self.assertEqual(errors, "TextMouthiOSUITests/LibraryUITests.swift:42:3: error: cannot find 'x' in scope\n")

    def test_two_builds_succeed_only_when_both_finished(self):
        one = "Build of target: 'TextMouthiOSTests' complete! (1.00s)"
        two = "Build of target: 'TextMouthiOSUITests' complete! (1.00s)"
        out = self.folder / "out"
        for log, builds, wanted in ((f"{one}\n{two}\n", 2, True), (f"{one}\n[1/2] Compiling\n", 2, False),
                                    (f"{one}\n", 1, True)):
            _, _, _, succeeded = typecheck.summarize(log, self.src, "# header", out, True, builds=builds)
            self.assertEqual(succeeded, wanted, (log, builds))

    def test_a_warning_in_a_test_file_counts_and_one_in_vendored_code_does_not(self):
        summary, count, _ = self.summarize([
            self.line("TextMouthProductionTests/FirstTests.swift", "warning", "w"),
            self.line("Vendor/lame/x.c", "warning", "hidden")])
        self.assertEqual(count, 0)
        self.assertIn("Warnings in the app and its tests: 1", summary)

    def test_a_clean_build_of_the_test_target_alone_succeeds(self):
        summary, count, _ = self.summarize(["Build of target: 'TextMouthProductionTests' complete! (1.00s)"])
        self.assertEqual(count, 0)
        self.assertIn("BUILD SUCCEEDED", summary)

    def test_a_build_that_neither_finished_nor_named_an_error_does_not_succeed(self):
        summary, count, _ = self.summarize(["[3/9] Compiling TextMouth A.swift"])
        self.assertIn("FAILED", summary)

    def test_a_clean_build_succeeds(self):
        summary, count, _ = self.summarize(["Build complete! (1.0s)"])
        self.assertEqual(count, 0)
        self.assertIn("BUILD SUCCEEDED", summary)
        self.assertIn("compiled, not linked", summary)


class MainTests(TypecheckTestsCase):
    """main() with `swift build` stood in for."""

    def setUp(self):
        super().setUp()
        self.commands = []
        work, results = self.folder / "work-root", self.folder / "results"
        patches = [mock.patch.object(typecheck, "WORK_ROOT", work), mock.patch.object(typecheck, "RESULTS", results),
                   mock.patch.object(typecheck, "checkout_root", lambda: self.repo),
                   mock.patch.object(typecheck, "prepare_packages", lambda *a, **k: None),
                   mock.patch.object(heavy_lock, "LOCK", self.folder / "heavy-lock"),
                   mock.patch.object(heavy_lock, "FIRST", self.folder / "heavy-lock-first.json"),
                   mock.patch.object(heavy_lock, "POLL_SECONDS", 0.02),
                   mock.patch.object(typecheck, "run", self.fake_run)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        for path in (typecheck.WORK_ROOT, typecheck.RESULTS, heavy_lock.LOCK, heavy_lock.FIRST):
            self.assertTrue(str(path).startswith(str(self.folder)), path)
        # `swift build` itself, which main() runs with subprocess.run.
        self.real_run = subprocess.run
        fake = mock.patch.object(typecheck.subprocess, "run", self.fake_build)
        fake.start()
        self.addCleanup(fake.stop)
        self.lock_seen = []

    def fake_run(self, command, cwd=None, env=None, check=True):
        """The script's run() helper: xcrun is answered, git is real."""
        if command[0] == "xcrun":
            return SimpleNamespace(stdout="/sdk\n", stderr="", returncode=0)
        return self.real_run(command, cwd=cwd, env=env, capture_output=True, text=True, check=check)

    def fake_build(self, command, **options):
        """Records the `swift build` command and the state of the lock, and succeeds;
        any other command (tar, git) runs for real."""
        if command[0] != "swift":
            return self.real_run(command, **options)
        self.commands.append(command)
        self.lock_seen.append(heavy_lock.LOCK.exists())
        return SimpleNamespace(stdout="Build complete! (0.1s)\n", stderr="", returncode=0)

    def canned_builds(self, *logs):
        """A context in which each `swift build` prints the next of `logs` (and is recorded in `self.commands`); any other
        command runs for real."""
        remaining = iter(logs)

        def build(command, **options):
            """`swift build` with the next canned log; any other command runs for real."""
            if command[0] != "swift":
                return self.real_run(command, **options)
            self.commands.append(command)
            return SimpleNamespace(stdout=next(remaining), stderr="", returncode=0)
        return mock.patch.object(typecheck.subprocess, "run", build)

    def main(self, *arguments):
        """Runs main() quietly; returns its exit status."""
        with contextlib.redirect_stdout(io.StringIO()):
            return typecheck.main(["--agent", "t", "--ref", self.commit, *arguments])

    def test_tests_mode_builds_the_tests_under_the_lock_in_a_folder_of_its_own(self):
        self.assertEqual(self.main("--platform", "macos", "--tests"), 0)
        # Only the test target's module is built (--build-tests cannot be combined with --target,
        # and its test-runner link step fails on this toolchain).
        self.assertNotIn("--build-tests", self.commands[0])
        self.assertEqual(self.commands[0][self.commands[0].index("--target") + 1], typecheck.TEST_TARGET)
        self.assertEqual(self.lock_seen, [True], "the build ran without the heavy-work lock")
        self.assertFalse(heavy_lock.LOCK.exists(), "the lock was left held")
        self.assertTrue((typecheck.WORK_ROOT / "macos-tests" / "src" / typecheck.TEST_TARGET).is_dir())

    def test_the_plain_mac_check_does_not_build_the_tests(self):
        self.assertEqual(self.main("--platform", "macos"), 0)
        self.assertNotIn("--target", self.commands[0])
        self.assertFalse((typecheck.WORK_ROOT / "macos" / "src" / typecheck.TEST_TARGET).exists())

    def test_the_iphone_tests_build_the_iphone_target_under_the_lock_in_a_folder_of_their_own(self):
        self.assertEqual(self.main("--platform", "ios", "--tests"), 0)
        # Two builds, the unit tests' and then the interface tests', both for the iPhone and both under the one lock.
        self.assertEqual([c[c.index("--target") + 1] for c in self.commands],
                         [typecheck.IOS_TEST_TARGET, typecheck.IOS_UI_TEST_TARGET])
        self.assertTrue(all("--triple" in c for c in self.commands))
        self.assertEqual(self.lock_seen, [True, True])
        self.assertTrue((typecheck.WORK_ROOT / "ios-tests" / "src" / typecheck.IOS_UI_TEST_TARGET).is_dir())
        self.assertTrue((typecheck.WORK_ROOT / "ios-tests" / "src" / typecheck.IOS_TEST_TARGET / "_SharedWithTheMac").is_dir())

    def test_an_interface_test_that_does_not_compile_fails_the_run_even_when_the_unit_tests_do(self):
        """The unit tests' build is clean and the interface tests' is not: the run fails and names the file, as GitHub would."""
        bad = typecheck.WORK_ROOT / "ios-tests" / "src" / "TextMouthiOSUITests" / "LibraryUITests.swift"
        with self.canned_builds("Build of target: 'TextMouthiOSTests' complete! (1s)\n",
                                f"{bad}:9:5: error: cannot find 'nothing' in scope\n"):
            self.assertEqual(self.main("--platform", "ios", "--tests"), 1)
        errors = (next(typecheck.RESULTS.iterdir()) / "errors.txt").read_text()
        self.assertEqual(errors, "TextMouthiOSUITests/LibraryUITests.swift:9:5: error: cannot find 'nothing' in scope\n")
        self.assertEqual(len(self.commands), 2, "the interface tests were not built after the unit tests")

    def test_an_interface_test_build_that_never_finishes_fails_the_run(self):
        """A second build that stops with no recognizable error (a package problem) is not a pass."""
        with self.canned_builds("Build of target: 'TextMouthiOSTests' complete! (1s)\n", "error: something odd\n"):
            self.assertEqual(self.main("--platform", "ios", "--tests"), 1)

    def test_a_census_that_finds_no_error_is_one_build(self):
        with mock.patch.object(typecheck, "census_report", lambda result, src: "report\n"):
            self.assertEqual(self.main("--platform", "ios", "--tests-census"), 0)
        self.assertEqual(len(self.commands), 1)
        out = next((typecheck.RESULTS).iterdir())
        self.assertEqual((out / "census.md").read_text(), "report\n")
        self.assertTrue(json.loads((out / "census.json").read_text())["ok"])

    def test_the_working_tree_run_copies_a_changed_file_a_new_one_and_leaves_out_what_git_ignores_or_lost(self):
        (self.repo / ".gitignore").write_text("Ignored.swift\n")
        (self.repo / "TextMouth" / "App.swift").write_text("// changed after the commit\n")
        (self.repo / "TextMouth" / "Brand New.swift").write_text("// not committed\n")
        (self.repo / "TextMouth" / "Ignored.swift").write_text("// ignored\n")
        (self.repo / "TextMouthBraille" / "include" / "b.h").unlink()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(typecheck.main(["--agent", "t", "--platform", "macos", "--worktree"]), 0)
        copy = typecheck.WORK_ROOT / "macos" / "src"
        self.assertEqual((copy / "TextMouth" / "App.swift").read_text(), "// changed after the commit\n")
        self.assertEqual((copy / "TextMouth" / "Brand New.swift").read_text(), "// not committed\n")
        self.assertFalse((copy / "TextMouth" / "Ignored.swift").exists())
        self.assertFalse((copy / "TextMouthBraille" / "include" / "b.h").exists(), "a tracked file deleted on disk was copied")
        # The run is named for the commit it is on, with -wt: its results folder says so.
        self.assertIn(f"-{self.git('rev-parse', '--short', 'HEAD')}-wt-", next(typecheck.RESULTS.iterdir()).name)

    def test_the_ref_run_still_copies_the_commit_and_not_the_working_tree(self):
        (self.repo / "TextMouth" / "App.swift").write_text("// changed after the commit\n")
        (self.repo / "TextMouth" / "Brand New.swift").write_text("// not committed\n")
        self.assertEqual(self.main("--platform", "macos"), 0)
        copy = typecheck.WORK_ROOT / "macos" / "src"
        self.assertEqual((copy / "TextMouth" / "App.swift").read_text(), "// app\n")
        self.assertFalse((copy / "TextMouth" / "Brand New.swift").exists())

    def test_a_ref_and_the_working_tree_cannot_both_be_asked_for(self):
        with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            typecheck.main(["--agent", "t", "--platform", "macos", "--ref", self.commit, "--worktree"])
        self.assertEqual(stopped.exception.code, 2)

    def test_the_options_that_do_not_go_together_are_refused(self):
        for arguments in (("--platform", "macos", "--tests-census"), ("--platform", "ios", "--tests", "--census"),
                          ("--platform", "ios", "--tests", "--tests-census"), ("--platform", "macos", "--tests", "--census")):
            with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
                self.main(*arguments)
            self.assertEqual(stopped.exception.code, 2)
        self.assertEqual(self.commands, [])

    def test_a_ref_that_does_not_exist_is_refused_without_building(self):
        with contextlib.redirect_stderr(io.StringIO()):
            status = typecheck.main(["--agent", "t", "--platform", "macos", "--tests", "--ref", "no-such-ref"])
        self.assertEqual(status, 2)
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
