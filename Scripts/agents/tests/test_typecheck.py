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
      - TextMouthTests/Sources/Tests/OtherTarget.swift
    settings:
      base:
        PRODUCT_NAME: y
"""

# The files of the throwaway repository: path to text.
FILES = {
    "project.yml": PROJECT_YML,
    "TextMouth/App.swift": "// app\n",
    "TextMouth/Resources/R.txt": "resource\n",
    "Vendor/lame/include/lame.h": "// h\n",
    "TextMouthBraille/include/b.h": "// h\n",
    "TextMouthProductionTests/FirstTests.swift": "// first\n",
    "TextMouthProductionTests/Info.plist": "<plist/>\n",
    "TextMouthProductionTests/performance-baselines.json": "{}\n",
    "TextMouthTests/Sources/Tests/ListedA.swift": "// a\n",
    "TextMouthTests/Sources/Tests/ListedB.swift": "// b\n",
    "TextMouthTests/Sources/Tests/NotMine.swift": "// not listed for the tests\n",
    "TextMouthTests/Sources/Tests/OtherTarget.swift": "// another target's\n",
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

    def test_without_tests_the_copy_holds_no_test_files(self):
        typecheck.prepare_sources(self.repo, self.commit, self.src, census=False)
        self.assertFalse((self.src / typecheck.TEST_TARGET).exists())
        self.assertFalse((self.src / "project.yml").exists())


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

    def test_the_plain_package_has_no_test_target(self):
        self.assertNotIn(".testTarget(", self.package(tests=False))


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

    def test_two_errors_in_two_files_are_both_counted(self):
        _, count, _ = self.summarize([
            self.line("TextMouthProductionTests/FirstTests.swift", "error", "a", 713),
            self.line(f"{typecheck.LISTED_TESTS_FOLDER}/ListedB.swift", "error", "b", 256)])
        self.assertEqual(count, 2)

    def test_a_warning_in_a_test_file_counts_and_one_in_vendored_code_does_not(self):
        summary, count, _ = self.summarize([
            self.line("TextMouthProductionTests/FirstTests.swift", "warning", "w"),
            self.line("Vendor/lame/x.c", "warning", "hidden")])
        self.assertEqual(count, 0)
        self.assertIn("Warnings in the app and its tests: 1", summary)

    def test_a_clean_build_succeeds(self):
        summary, count, _ = self.summarize(["Build complete! (1.0s)"])
        self.assertEqual(count, 0)
        self.assertIn("BUILD SUCCEEDED", summary)


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

    def main(self, *arguments):
        """Runs main() quietly; returns its exit status."""
        with contextlib.redirect_stdout(io.StringIO()):
            return typecheck.main(["--agent", "t", "--ref", self.commit, *arguments])

    def test_tests_mode_builds_the_tests_under_the_lock_in_a_folder_of_its_own(self):
        self.assertEqual(self.main("--platform", "macos", "--tests"), 0)
        self.assertIn("--build-tests", self.commands[0])
        self.assertEqual(self.lock_seen, [True], "the build ran without the heavy-work lock")
        self.assertFalse(heavy_lock.LOCK.exists(), "the lock was left held")
        self.assertTrue((typecheck.WORK_ROOT / "macos-tests" / "src" / typecheck.TEST_TARGET).is_dir())

    def test_the_plain_mac_check_does_not_build_the_tests(self):
        self.assertEqual(self.main("--platform", "macos"), 0)
        self.assertNotIn("--build-tests", self.commands[0])
        self.assertFalse((typecheck.WORK_ROOT / "macos" / "src" / typecheck.TEST_TARGET).exists())

    def test_tests_mode_is_for_the_mac_only(self):
        for arguments in (("--platform", "ios", "--tests"), ("--platform", "macos", "--tests", "--census")):
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
