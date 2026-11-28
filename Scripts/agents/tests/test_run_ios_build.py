"""Tests of run-ios-build.py: the iPhone build the GitHub workflow runs beside the tests.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test builds anything. Each replaces the xcodebuild command with a small Python child that prints what a build
prints, and gives the script an output folder in a temporary directory.
"""
import contextlib
import importlib.util
import io
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

    def test_the_swift_frontends_unknown_location_error_is_an_error_without_a_file(self):
        # Train 1116-2122's stale-module errors came as "<unknown>:0: error: ..." and the build was reported as ending
        # "with no error line".
        log = ("<unknown>:0: error: file '/r/TextMouthBraille/include/module.modulemap' has been modified since the module "
               "file '/r/dd/SwiftExplicitPrecompiledModules/A.pcm' was built: size changed (was 383, now 849)\n"
               "<unknown>:0: note: please rebuild precompiled file '/r/dd/SwiftExplicitPrecompiledModules/A.pcm'\n")
        errors = ios.parse_errors(log, RUNNER_ROOT)
        self.assertEqual(len(errors), 1, errors)
        self.assertTrue(errors[0].startswith("error: file '/r/TextMouthBraille/include/module.modulemap' has been modified"))
        self.assertTrue(ios.runner_module_cache.stale_cache_only(errors), "all of them are the stale cache's")

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

    def test_the_command_builds_for_one_architecture_only(self):
        """Both architectures compiled every file twice on the runner; the command names the machine's own."""
        self.assertIn("ARCHS=arm64", ios.build_command("build/x", architecture="arm64"))
        self.assertIn("ARCHS=x86_64", ios.build_command("build/x", architecture="x86_64"))
        with mock.patch.object(ios.platform, "machine", return_value="arm64"):
            self.assertIn("ARCHS=arm64", ios.build_command("build/x"))

    def test_the_host_architecture_is_named_by_xcodes_word(self):
        self.assertEqual(ios.host_architecture("arm64"), "arm64")
        self.assertEqual(ios.host_architecture("aarch64"), "arm64")
        self.assertEqual(ios.host_architecture("x86_64"), "x86_64")
        self.assertEqual(ios.host_architecture("AMD64"), "x86_64")
        # A machine that is neither names no architecture, and the build asks for none.
        self.assertIsNone(ios.host_architecture("riscv64"))
        with mock.patch.object(ios.platform, "machine", return_value="riscv64"):
            self.assertFalse([word for word in ios.build_command("build/x") if word.startswith("ARCHS=")])

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


# The error of train 1116-1349's iPhone build, which no branch's code caused: a module cache from another runner image.
STALE_ERROR = ("error: Clang dependency scanner failure: fatal error: file '/Applications/Xcode_26.0.1.app/Contents/Developer/"
               "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include/module.modulemap' has been modified since the "
               "module file '/Users/runner/work/TextMouth/TextMouth/build/remote-DerivedData-ios/ModuleCache.noindex/"
               "1TV4X376J16CB/_Builtin_stdbool-FTUUUU4ZHFEK.pcm' was built: mtime changed (was 1793595417, now 1794497068)")


# What train 1117-0527 (TextMouthBrailleLibrary.c, a race) and train 1117-1219 (a restored cache) printed: the error has a
# file in front of it as "fatal error:", so the error census reads no error line, and it is not the stale-module error.
MISSING_ERROR = ("/Users/runner/work/TextMouth/TextMouth/TextMouthBraille/TextMouthBrailleLibrary.c:39:2: fatal error: module "
                 "file '/Users/runner/work/TextMouth/TextMouth/build/remote-DerivedData-ios/Build/Intermediates.noindex/"
                 "ExplicitPrecompiledModules/_Builtin_stdint-KLL6A9NC5YCI0GN88HDENJNR.pcm' not found: module file not found")
# Train 1117-1219's line, from the toolchain's own header.
MISSING_ERROR_STDDEF = ("/Applications/Xcode_26.0.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/"
                        "include/stddef.h:89:2: fatal error: module file '/Users/runner/work/TextMouth/TextMouth/build/"
                        "remote-DerivedData-ios/Build/Intermediates.noindex/ExplicitPrecompiledModules/"
                        "_Builtin_stddef-9GGUBAMBUN08H8VY1LWYJDQUK.pcm' not found: module file not found")


class RetryTests(unittest.TestCase):
    """A build that fails with the stale-module error is run once more with the module caches emptied, in the same limit."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        # The derived-data folder the script uses by default, with a module cache and a product in it.
        self.derived = self.folder / "build" / "remote-DerivedData-ios"
        (self.derived / "ModuleCache.noindex").mkdir(parents=True)
        (self.derived / "ModuleCache.noindex" / "old.pcm").write_text("x")
        (self.derived / "Build" / "Products").mkdir(parents=True)
        (self.derived / "Build" / "Products" / "kept.o").write_text("x")
        # Xcode 26's explicitly built Swift modules, which a stale build of train 1116-2122 failed on (TL02).
        self.explicit = self.derived / "Build" / "Intermediates.noindex" / "SwiftExplicitPrecompiledModules"
        self.explicit.mkdir(parents=True)
        (self.explicit / "Stale-ABC.pcm").write_text("x")
        self.limits = []

    def fake_build(self, first, second):
        """A stand-in build: its first run prints `first` and exits 65 when `first` is not None, and every later run does
        what `second` says (its text, exiting 0 if it holds SUCCEEDED, else 65). It also prints whether the module cache
        was still there when it started, so that a test sees what the retry emptied."""
        marker = self.folder / "tried"
        program = (
            "import os, sys\n"
            f"marker = {str(marker)!r}\n"
            f"cache = {str(self.derived / 'ModuleCache.noindex')!r}\n"
            "print('MODULE CACHE', 'present' if os.path.exists(cache) else 'gone')\n"
            "again = os.path.exists(marker)\n"
            "open(marker, 'w').write('x')\n"
            f"text = {second!r} if again else {first!r}\n"
            "print(text)\n"
            "sys.exit(0 if 'SUCCEEDED' in text else 65)\n")
        return [sys.executable, "-c", program]

    def run_main(self, command, limit="20"):
        """Runs main with `command` as the build; returns (status, the output folder's files, what was printed)."""
        real = ios.run_build

        def spy(build, log, limit_minutes, append=False):
            self.limits.append(limit_minutes)
            return real(build, log, limit_minutes, append)

        output = io.StringIO()
        with mock.patch.object(ios, "build_command", return_value=command), mock.patch.object(ios, "ROOT", self.folder), \
                mock.patch.object(ios, "run_build", spy), contextlib.redirect_stdout(output):
            status = ios.main(["--out", "out", "--limit-minutes", limit])
        out = self.folder / "out"
        return status, {path.name: path.read_text() for path in out.iterdir()}, output.getvalue()

    def test_a_build_that_fails_for_the_stale_cache_is_run_again_with_the_caches_emptied_and_passes(self):
        status, files, printed = self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"))
        self.assertEqual(status, 0)
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: PASSED"), files["ios-summary.txt"])
        # The first try saw the old cache and the second did not.
        self.assertEqual(files["ios.log"].count("MODULE CACHE present"), 1)
        self.assertEqual(files["ios.log"].count("MODULE CACHE gone"), 1)
        self.assertEqual(files["ios-errors.txt"], "", "only the retry's errors count")
        # Everything but the module caches is kept: this is not a clean build.
        self.assertTrue((self.derived / "Build" / "Products" / "kept.o").exists())
        self.assertFalse(self.explicit.exists(), "the retry emptied the explicitly built Swift modules too")

    def test_a_build_that_fails_for_a_module_file_not_found_is_run_again_with_the_caches_emptied_and_passes(self):
        # TL06: the same cure as for the stale module, from the same test of the log.
        status, files, _ = self.run_main(self.fake_build(MISSING_ERROR, "** TEST BUILD SUCCEEDED **"))
        self.assertEqual(status, 0)
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: PASSED"), files["ios-summary.txt"])
        self.assertEqual(files["ios.log"].count("MODULE CACHE gone"), 1, "the retry started with the caches emptied")
        retried = [line for line in files["ios-summary.txt"].splitlines() if line.startswith("Retried: ")]
        self.assertEqual(len(retried), 1)
        self.assertIn(ios.runner_module_cache.MISSING_MARKER, retried[0])

    def test_a_module_file_not_found_starts_from_an_empty_folder_on_a_runner_and_restamps(self):
        # The build database still claims the missing module, so emptying the caches is not the cure (TL06 review 2).
        for line in (MISSING_ERROR, MISSING_ERROR_STDDEF):
            (self.derived / "Build" / "Products").mkdir(parents=True, exist_ok=True)
            (self.derived / "Build" / "Products" / "kept.o").write_text("x")
            (self.derived / "tried-marker-folder").mkdir(exist_ok=True)
            stamped = []
            (self.folder / "tried").unlink(missing_ok=True)
            with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": "true"}), \
                    mock.patch.object(ios.runner_module_cache, "prepare", lambda derived: stamped.append(Path(derived))):
                _, files, _ = self.run_main(self.fake_build(line, "** TEST BUILD SUCCEEDED **"))
            self.assertTrue(files["ios-summary.txt"].startswith("iOS build: PASSED"), files["ios-summary.txt"])
            self.assertFalse((self.derived / "Build" / "Products" / "kept.o").exists(), "the whole folder was started over")
            self.assertFalse((self.derived / "tried-marker-folder").exists())
            # Once before the first build, and once more for the folder that was started over.
            self.assertEqual([path.resolve() for path in stamped], [self.derived.resolve()] * 2,
                             "the toolchain's stamp is written again for the folder")

    def test_a_module_file_not_found_off_a_runner_only_empties_the_caches(self):
        with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": "false"}):
            _, files, _ = self.run_main(self.fake_build(MISSING_ERROR, "** TEST BUILD SUCCEEDED **"))
        self.assertTrue((self.derived / "Build" / "Products" / "kept.o").exists())
        self.assertEqual(files["ios.log"].count("MODULE CACHE gone"), 1)

    def test_a_stale_module_on_a_runner_still_keeps_everything_but_the_caches(self):
        stamped = []
        with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": "true"}), \
                mock.patch.object(ios.runner_module_cache, "prepare", lambda derived: stamped.append(derived)):
            self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"))
        self.assertTrue((self.derived / "Build" / "Products" / "kept.o").exists())

    def test_the_folder_started_over_is_never_the_repositorys_root(self):
        with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": "true"}), mock.patch.object(ios, "ROOT", self.folder):
            self.assertFalse(ios.start_device_folder_over(self.folder, names=(self.folder.name,)))
        self.assertTrue(self.folder.is_dir())

    def test_a_module_file_not_found_that_fails_again_is_named_not_reported_as_no_error_line(self):
        _, files, _ = self.run_main(self.fake_build(MISSING_ERROR, MISSING_ERROR))
        self.assertEqual(len(self.limits), 2, "one retry, never more")
        self.assertNotIn("no error line", files["ios-summary.txt"])
        self.assertIn("Reason: the module cache failed the build", files["ios-summary.txt"])

    def test_a_real_error_beside_a_cache_error_is_not_blamed_on_the_cache(self):
        # The retry hit the cache error again and the log also holds an error of the branch's code.
        real = "/x/Foo.swift:3:4: error: cannot find 'x' in scope"
        _, files, _ = self.run_main(self.fake_build(MISSING_ERROR + "\n" + real, MISSING_ERROR + "\n" + real))
        self.assertIn("Errors in the app: 1 in 1 files", files["ios-summary.txt"])
        self.assertNotIn("not this branch's code", files["ios-summary.txt"])
        self.assertNotIn("Reason:", files["ios-summary.txt"])

    def test_a_real_compile_error_is_neither_retried_nor_blamed_on_the_cache(self):
        _, files, _ = self.run_main(self.fake_build("/x/Foo.swift:3:4: error: cannot find 'x' in scope", ""))
        self.assertEqual(len(self.limits), 1)
        self.assertNotIn("module cache failed", files["ios-summary.txt"])

    def test_the_summary_says_the_retry_happened_and_why(self):
        _, files, printed = self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"))
        retried = [line for line in files["ios-summary.txt"].splitlines() if line.startswith("Retried: ")]
        self.assertEqual(len(retried), 1, files["ios-summary.txt"])
        self.assertIn("has been modified since the module file", retried[0])
        self.assertIn("module caches were emptied", retried[0])
        self.assertIn("building once more", printed)

    def test_the_retry_note_counts_the_first_tries_minutes_not_its_seconds(self):
        # A pretend clock that moves 87 seconds at every reading: the first try lasted 87 seconds, 1.4 minutes.
        readings = iter(range(0, 10000, 87))
        with mock.patch.object(ios.time, "monotonic", lambda: next(readings)):
            _, files, _ = self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"))
        retried = [line for line in files["ios-summary.txt"].splitlines() if line.startswith("Retried: ")]
        self.assertIn("(1.4 minutes)", retried[0])
        self.assertEqual(ios.retry_note(2.9).count("2.9 minutes"), 1)

    def test_both_tries_are_in_the_log_and_the_retry_has_what_is_left_of_the_limit(self):
        _, files, _ = self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"), limit="20")
        self.assertIn("1TV4X376J16CB", files["ios.log"])
        self.assertIn("TEST BUILD SUCCEEDED", files["ios.log"])
        self.assertEqual(len(self.limits), 2)
        self.assertEqual(self.limits[0], 20.0)
        self.assertTrue(19.0 < self.limits[1] <= 20.0, self.limits)

    def test_a_retry_that_fails_again_is_the_end_and_its_errors_are_the_results(self):
        again = "/x/Foo.swift:3:4: error: no such thing"
        status, files, _ = self.run_main(self.fake_build(STALE_ERROR, again))
        self.assertEqual(status, 0)
        self.assertEqual(len(self.limits), 2, "one retry, never more")
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: FAILED"))
        self.assertEqual(files["ios-errors.txt"], "/x/Foo.swift:3:4: error: no such thing\n",
                         "the first try's stale error is not among the retry's results")

    def test_a_retry_that_fails_with_the_stale_error_again_is_not_retried_a_third_time(self):
        _, files, _ = self.run_main(self.fake_build(STALE_ERROR, STALE_ERROR))
        self.assertEqual(len(self.limits), 2)
        self.assertEqual(files["ios-errors.txt"].count("has been modified since the module file"), 1)

    def test_any_other_error_is_not_retried(self):
        _, files, _ = self.run_main(self.fake_build("/x/Foo.swift:3:4: error: no such thing", "** TEST BUILD SUCCEEDED **"))
        self.assertEqual(len(self.limits), 1)
        self.assertNotIn("Retried:", files["ios-summary.txt"])
        self.assertTrue((self.derived / "ModuleCache.noindex" / "old.pcm").exists(), "an ordinary failure leaves the caches")

    def test_a_build_that_passed_the_first_time_is_not_retried(self):
        _, files, _ = self.run_main(self.fake_build("** TEST BUILD SUCCEEDED **", ""))
        self.assertEqual(len(self.limits), 1)
        self.assertNotIn("Retried:", files["ios-summary.txt"])

    def test_with_less_than_a_minute_of_the_limit_left_there_is_no_retry(self):
        _, files, _ = self.run_main(self.fake_build(STALE_ERROR, "** TEST BUILD SUCCEEDED **"), limit="0.5")
        self.assertEqual(len(self.limits), 1)
        self.assertNotIn("Retried:", files["ios-summary.txt"])
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: FAILED"))

    def test_the_stamp_is_checked_before_the_build_in_the_runs_own_derived_data_folder(self):
        seen = []
        with mock.patch.object(ios.runner_module_cache, "prepare", lambda derived: seen.append(Path(derived))):
            self.run_main(self.fake_build("** TEST BUILD SUCCEEDED **", ""))
        self.assertEqual(seen, [self.derived.resolve()])
# A stand-in for the device build: it makes a small app in the products folder the real build writes, named by its
# first argument (the derived-data folder), the way Xcode lays it out.
FAKE_DEVICE_BUILD = """
import os, sys
app = os.path.join(sys.argv[1], 'Build', 'Products', 'Release-iphoneos', 'TextMouth.app')
os.makedirs(app)
open(os.path.join(app, 'TextMouth'), 'wb').write(b'\\xcf\\xfa\\xed\\xfe' + b'x' * 5000)
open(os.path.join(app, 'Info.plist'), 'wb').write(b'plist' * 100)
print('** BUILD SUCCEEDED **')
"""


class SizeTests(unittest.TestCase):
    """main() when the request asks for the app's size: the Simulator build, then a device build that is measured."""

    def run_main(self, request, device_script=FAKE_DEVICE_BUILD, *arguments):
        """Runs main in a temporary repository whose request file holds `request` (None: no file), with both builds
        replaced by stand-ins; returns (the summary text, the folder of output files, the device build's folder)."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / ".github").mkdir()
        if request is not None:
            (root / ".github" / "test-request.json").write_text(request)
        simulator = [sys.executable, "-c", "print('** TEST BUILD SUCCEEDED **')"]

        def device(derived):
            """The fake device build's argv, handed the derived-data folder it is asked to build into."""
            return [sys.executable, "-c", device_script, str(derived)]

        with mock.patch.object(ios, "build_command", return_value=simulator), mock.patch.object(ios, "ROOT", root), \
                mock.patch.object(ios, "device_build_command", device), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ios.main(["--out", "out", *arguments]), 0)
        out = root / "out"
        return (out / "ios-summary.txt").read_text(), out, root / "build" / "remote-DerivedData-ios" / "device"

    def test_a_request_for_the_size_adds_the_measurement_after_the_simulator_builds_lines(self):
        summary, out, _ = self.run_main('{"ios_size": true}')
        lines = summary.splitlines()
        self.assertEqual(lines[0], "iOS build: PASSED")
        sizes = [line for line in lines if line.startswith(("Size: ", "Size detail: "))]
        self.assertTrue(sizes[0].startswith("Size: iPhone app: 0.0 MB (5,504 bytes) in 2 files, within the 30 MB limit."), sizes)
        self.assertTrue(sizes[1].startswith("Size: iPhone app IPA: "), sizes)
        self.assertTrue(sizes[2].startswith("Size: iPhone app App Store download, estimated"), sizes)
        self.assertIn("device build for the app's size", (out / "ios.log").read_text())

    def test_the_lines_are_the_ones_the_trains_and_the_joins_read_back(self):
        summary, _, _ = self.run_main('{"ios_size": true}')
        sys.path.insert(0, str(AGENTS))
        import merge_ios_shards
        # Three headlines, the two files, and the minutes the build took.
        self.assertEqual(len(merge_ios_shards.size_lines(summary.splitlines())), 3 + 2 + 1)

    def test_a_request_that_does_not_ask_builds_no_device_app(self):
        for request in (None, "{}", '{"ios_size": false}', '{"ios_size": "yes"}', "not json", "[1]"):
            summary, _, device = self.run_main(request)
            self.assertNotIn("Size", summary, request)
            self.assertFalse(device.exists(), f"a device build ran for {request!r}")

    def test_a_device_build_that_fails_says_so_in_one_line_and_leaves_the_simulator_verdict_alone(self):
        script = "import sys; print('/x/Foo.swift:3:4: error: no slice for arm64'); sys.exit(65)"
        summary, out, _ = self.run_main('{"ios_size": true}', script)
        self.assertTrue(summary.startswith("iOS build: PASSED"))
        self.assertIn("Size: not measured: the device build failed (xcodebuild status 65, 1 errors: /x/Foo.swift:3:4: "
                      "error: no slice for arm64).", summary)
        self.assertIn("no slice for arm64", (out / "ios.log").read_text())

    def limits_passed(self, *arguments):
        """Runs main for a size request with the device build replaced by a spy, and returns the limits it was given."""
        limits = []

        def spy(derived_data, out, limit_minutes):
            limits.append(limit_minutes)
            return ["Size: not measured: a stand-in."]

        with mock.patch.object(ios, "device_size_lines", spy):
            self.run_main('{"ios_size": true}', FAKE_DEVICE_BUILD, *arguments)
        return limits

    def test_the_device_build_takes_what_the_simulator_build_left_of_its_limit(self):
        # Without --size-limit-minutes, the device build has its own share and what the Simulator build, a moment here,
        # left of its limit: nearly both (trains 1125-0350 and 1125-0501 were stopped at 15 with about 12 left unused).
        limits = self.limits_passed()
        self.assertEqual(len(limits), 1)
        both = ios.DEFAULT_SIZE_LIMIT_MINUTES + ios.DEFAULT_LIMIT_MINUTES
        self.assertGreater(limits[0], both - 1)
        self.assertLessEqual(limits[0], both)

    def test_a_size_limit_given_is_the_limit_whatever_the_simulator_build_left(self):
        self.assertEqual(self.limits_passed("--size-limit-minutes", "7"), [7.0])

    def test_the_size_limit_adds_only_what_the_simulator_build_left_rounded_down(self):
        self.assertEqual(ios.size_limit(20, 8), 27.0)
        self.assertEqual(ios.size_limit(20, 8.04), 26.9, "rounded down to a tenth of a minute")
        self.assertEqual(ios.size_limit(20, 0), 35.0)
        self.assertEqual(ios.size_limit(20, 20), ios.DEFAULT_SIZE_LIMIT_MINUTES)
        self.assertEqual(ios.size_limit(20, 26), ios.DEFAULT_SIZE_LIMIT_MINUTES, "a Simulator build past its limit leaves nothing")

    def test_a_device_build_that_outlives_its_limit_is_stopped_and_says_so(self):
        summary, _, _ = self.run_main('{"ios_size": true}', "import time; time.sleep(60)", "--size-limit-minutes", "0.01")
        self.assertIn("Size: not measured: the device build was stopped after 0.01 minutes.", summary)
        self.assertTrue(summary.startswith("iOS build: PASSED"))

    def test_a_device_build_that_fails_with_the_stale_module_error_runs_once_more_and_is_measured(self):
        # The first try prints the runner's stale-module error and stops; the second finds the flag file and builds.
        script = ("import os, sys\n"
                  "flag = sys.argv[1] + '-tried'\n"
                  "if not os.path.exists(flag):\n"
                  "    os.makedirs(os.path.dirname(flag), exist_ok=True)\n"
                  "    open(flag, 'w').close()\n"
                  f"    print({ios.runner_module_cache.STALE_MARKER!r})\n"
                  "    sys.exit(65)\n") + FAKE_DEVICE_BUILD
        seen = []
        with mock.patch.object(ios.runner_module_cache, "prepare", lambda derived: seen.append(Path(derived).name)):
            summary, _, _ = self.run_main('{"ios_size": true}', script)
        self.assertEqual(seen[-1], "device", "the stamp is checked in the device build's own folder, before it")
        self.assertIn("Size: iPhone app: 0.0 MB (5,504 bytes)", summary)
        self.assertNotIn("not measured", summary)

    def test_a_device_build_that_fails_for_any_other_reason_also_runs_once_more(self):
        # A restored cache that lacks a precompiled module fails "module file ... not found", not the stale-module error.
        script = ("import os, sys\n"
                  "flag = sys.argv[1] + '-tried'\n"
                  "if not os.path.exists(flag):\n"
                  "    os.makedirs(os.path.dirname(flag), exist_ok=True)\n"
                  "    open(flag, 'w').close()\n"
                  "    print('fatal error: module file x.pcm not found: module file not found')\n"
                  "    sys.exit(65)\n") + FAKE_DEVICE_BUILD
        summary, _, _ = self.run_main('{"ios_size": true}', script)
        self.assertIn("Size: iPhone app: 0.0 MB (5,504 bytes)", summary)
        self.assertIn("the first try failed, so the module caches were emptied and it ran once more", summary)

    def test_the_second_try_of_a_device_build_starts_from_an_empty_folder_on_a_runner_only(self):
        # The first try leaves a file in the device folder and fails; the second finds it gone only on a runner.
        script = ("import os, sys\n"
                  "marker = os.path.join(sys.argv[1], 'left-by-the-first-try')\n"
                  "if not os.path.exists(sys.argv[1] + '-tried'):\n"
                  "    os.makedirs(sys.argv[1], exist_ok=True)\n"
                  "    open(marker, 'w').close()\n"
                  "    open(sys.argv[1] + '-tried', 'w').close()\n"
                  "    sys.exit(65)\n"
                  "print('second try saw the leftover:', os.path.exists(marker))\n") + FAKE_DEVICE_BUILD
        for on_runner, expected in (("true", "saw the leftover: False"), ("false", "saw the leftover: True")):
            # The stamp check is stood in for: it would ask this machine's toolchain, which the test does not need.
            with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": on_runner}), \
                    mock.patch.object(ios.runner_module_cache, "prepare", lambda derived: "kept"):
                _, out, _ = self.run_main('{"ios_size": true}', script)
            self.assertIn(expected, (out / "ios-size.log").read_text(), f"GITHUB_ACTIONS={on_runner}")

    def test_only_a_folder_named_device_is_ever_removed(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        other = Path(folder.name) / "remote-DerivedData-ios"
        device = other / "device"
        device.mkdir(parents=True)
        with mock.patch.dict(ios.os.environ, {"GITHUB_ACTIONS": "true"}):
            self.assertFalse(ios.start_device_folder_over(other), "the Simulator build's folder is never removed")
            self.assertTrue(other.is_dir() and device.is_dir())
            self.assertTrue(ios.start_device_folder_over(device))
            self.assertFalse(device.exists() and any(device.iterdir()))
            self.assertTrue(other.is_dir(), "its parent stays")
            self.assertFalse(ios.start_device_folder_over(device), "a folder that is already gone is not removed again")

    def test_a_device_build_that_fails_twice_is_not_measured_and_says_how_it_failed(self):
        script = "import sys; print('/x/Foo.swift:3:4: error: second try'); sys.exit(65)"
        summary, out, _ = self.run_main('{"ios_size": true}', script)
        self.assertIn("Size: not measured: the device build failed (xcodebuild status 65, 1 errors: /x/Foo.swift:3:4: "
                      "error: second try).", summary)

    def test_a_device_build_that_made_no_app_is_not_measured(self):
        summary, _, _ = self.run_main('{"ios_size": true}', "print('** BUILD SUCCEEDED **')")
        self.assertIn("Size: not measured: the device build failed (xcodebuild status 0, 0 errors)", summary)


class SplitSizeTests(unittest.TestCase):
    """The two modes that split the device build off the iPhone jobs: --no-size (the Simulator build only) and --size-only
    (the device build only, written to ios-size-summary.txt). Uses SizeTests' device build stand-in."""

    def run_split(self, request, flag, device_script=FAKE_DEVICE_BUILD):
        """Runs main with `flag` for a request file holding `request`; returns (the output folder's files by name, the
        device build's folder, the number of times the Simulator build was started)."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / ".github").mkdir()
        if request is not None:
            (root / ".github" / "test-request.json").write_text(request)
        simulator_runs = []

        def simulator(derived, architecture=None):
            """A Simulator build that counts itself."""
            simulator_runs.append(1)
            return [sys.executable, "-c", "print('** TEST BUILD SUCCEEDED **')"]

        with mock.patch.object(ios, "build_command", simulator), mock.patch.object(ios, "ROOT", root), \
                mock.patch.object(ios, "device_build_command", lambda derived: [sys.executable, "-c", device_script, str(derived)]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ios.main(["--out", "out", flag]), 0)
        out = root / "out"
        files = {path.name: path.read_text() for path in out.iterdir()}
        return files, root / "build" / "remote-DerivedData-ios" / "device", len(simulator_runs)

    def test_no_size_builds_the_simulator_app_and_never_the_device_app_even_when_asked(self):
        files, device, simulator_runs = self.run_split('{"ios_size": true}', "--no-size")
        self.assertEqual(simulator_runs, 1)
        self.assertTrue(files["ios-summary.txt"].startswith("iOS build: PASSED"))
        self.assertNotIn("Size", files["ios-summary.txt"])
        self.assertFalse(device.exists())
        self.assertNotIn(ios.SIZE_SUMMARY_FILE, files)

    def test_size_only_builds_the_device_app_alone_and_writes_the_size_lines_to_their_own_file(self):
        files, device, simulator_runs = self.run_split('{"ios_size": true}', "--size-only")
        self.assertEqual(simulator_runs, 0, "no Simulator build in the size job")
        self.assertNotIn("ios-summary.txt", files, "the verdict of the iPhone build is the iPhone jobs' alone")
        lines = files[ios.SIZE_SUMMARY_FILE].splitlines()
        self.assertTrue(lines[0].startswith("Size: iPhone app: 0.0 MB (5,504 bytes) in 2 files, within the 30 MB limit."), lines)
        self.assertTrue(all(line.startswith(("Size: ", "Size detail: ")) for line in lines), "nothing but size lines")
        self.assertIn("device build for the app's size", files["ios.log"])
        self.assertTrue(device.is_dir())

    def test_size_only_without_a_request_for_the_size_writes_an_empty_file_and_builds_nothing(self):
        for request in (None, "{}", '{"ios_size": false}'):
            files, device, simulator_runs = self.run_split(request, "--size-only")
            self.assertEqual((files, device.exists(), simulator_runs), ({ios.SIZE_SUMMARY_FILE: ""}, False, 0), request)

    def test_size_only_says_when_the_device_build_fails_and_still_writes_the_file(self):
        files, _, _ = self.run_split('{"ios_size": true}', "--size-only", "import sys; sys.exit(65)")
        self.assertIn("Size: not measured: the device build failed (xcodebuild status 65", files[ios.SIZE_SUMMARY_FILE])

    def test_size_only_has_the_limits_of_both_builds_unless_one_is_given(self):
        self.assertEqual(ios.SIZE_ONLY_LIMIT_MINUTES, ios.DEFAULT_LIMIT_MINUTES + ios.DEFAULT_SIZE_LIMIT_MINUTES)
        limits = []

        def spy(derived_data, out, limit_minutes):
            limits.append(limit_minutes)
            return []

        with mock.patch.object(ios, "device_size_lines", spy):
            self.run_split('{"ios_size": true}', "--size-only")
        self.assertEqual(limits, [ios.SIZE_ONLY_LIMIT_MINUTES])

    def test_the_two_modes_cannot_be_asked_together(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            ios.main(["--no-size", "--size-only"])


if __name__ == "__main__":
    unittest.main()
