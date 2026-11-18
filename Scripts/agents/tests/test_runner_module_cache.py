"""Tests of runner_module_cache.py: the stamp that keeps a restored module cache from outliving its toolchain.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

No test runs Xcode. The toolchain is a made-up developer directory in a temporary folder, `xcodebuild -version` is a
stand-in, and every deletion happens inside the test's own temporary directory.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from heavy_lock_case import HeavyLockTestCase  # noqa: F401  (puts the scripts' folder on the path)
import runner_module_cache as cache  # noqa: E402

# The environment of a step on a GitHub runner, as far as the module reads it.
RUNNER = {"GITHUB_ACTIONS": "true", "ImageVersion": "20261112.0504.1"}
# What the stand-in `xcodebuild -version` prints.
XCODE = "Xcode 26.0.1\nBuild version 17A400\n"


def fake_run(xcode=XCODE, status=0):
    """A stand-in for subprocess.run that answers `xcodebuild -version` with `xcode` (and `xcode-select -p` with nothing,
    so that only DEVELOPER_DIR names the toolchain)."""
    def run(command, **_):
        if command[0] == "xcodebuild":
            return subprocess.CompletedProcess(command, status, stdout=xcode, stderr="")
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="")
    return run


class CacheTestCase(unittest.TestCase):
    """A made-up developer directory and a derived-data folder holding module caches, in a temporary directory."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.developer = self.folder / "Xcode.app" / "Contents" / "Developer"
        self.set_modulemap_time(1794497068)
        self.derived = self.folder / "work" / "build" / "remote-DerivedData-ios"
        self.environment = {**RUNNER, "DEVELOPER_DIR": str(self.developer)}
        self.lines = []

    def set_modulemap_time(self, seconds):
        """Makes the toolchain's module.modulemap, with this modification time."""
        path = self.developer / cache.MODULEMAP_IN_DEVELOPER_DIR
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("module _Builtin_stdbool {}\n")
        os.utime(path, (seconds, seconds))

    def fill_caches(self, with_stamp=None):
        """Puts a file in each of the folders the helper empties, one in a folder it keeps, and the stamp when given."""
        for name in (*cache.CACHE_FOLDERS, "Build/Products", "Build/Intermediates.noindex/App.build"):
            folder = self.derived / name
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "kept-or-not.pcm").write_text("x")
        if with_stamp is not None:
            cache.write_stamp(self.derived, with_stamp)

    def prepare(self, environment=None, run=None):
        """Runs prepare on the derived-data folder; returns what it did. What it said is in self.lines."""
        return cache.prepare(self.derived, self.environment if environment is None else environment,
                             run or fake_run(), say=self.lines.append)

    def present(self, name):
        """Whether the folder `name` is in the derived-data folder."""
        return (self.derived / name).exists()


class StampTests(CacheTestCase):
    """The stamp names the image, Xcode, and the toolchain's module.modulemap time."""

    def test_the_stamp_holds_the_image_version_xcodes_version_and_the_modulemaps_time(self):
        self.assertEqual(cache.current_stamp(self.environment, fake_run()),
                         {"image_version": "20261112.0504.1", "xcodebuild_version": "Xcode 26.0.1 Build version 17A400",
                          "modulemap_mtime": 1794497068})

    def test_what_cannot_be_read_is_none(self):
        stamp = cache.current_stamp({}, fake_run(status=1))
        self.assertEqual(stamp, {"image_version": None, "xcodebuild_version": None, "modulemap_mtime": None})
        self.assertFalse(cache.stamp_known(stamp))

    def test_a_missing_modulemap_is_none_not_an_error(self):
        environment = {**self.environment, "DEVELOPER_DIR": str(self.folder / "no-such-xcode")}
        self.assertIsNone(cache.modulemap_mtime(environment, fake_run()))

    def test_xcode_select_names_the_toolchain_when_developer_dir_is_not_set(self):
        def run(command, **_):
            return subprocess.CompletedProcess(command, 0, stdout=f"{self.developer}\n", stderr="")
        self.assertEqual(cache.modulemap_mtime({}, run), 1794497068)

    def test_a_stamp_is_written_and_read_back(self):
        stamp = {"image_version": "a", "xcodebuild_version": "b", "modulemap_mtime": 3}
        cache.write_stamp(self.derived, stamp)
        self.assertEqual(cache.read_stamp(self.derived), stamp)

    def test_a_missing_or_broken_stamp_reads_as_none(self):
        self.assertIsNone(cache.read_stamp(self.derived))
        self.derived.mkdir(parents=True)
        (self.derived / cache.STAMP_NAME).write_text("not json")
        self.assertIsNone(cache.read_stamp(self.derived))
        (self.derived / cache.STAMP_NAME).write_text("[1, 2]")
        self.assertIsNone(cache.read_stamp(self.derived))


class PrepareTests(CacheTestCase):
    """A matching stamp keeps the caches; a missing or different one empties them, and only them."""

    def test_a_matching_stamp_keeps_every_cache(self):
        self.fill_caches(cache.current_stamp(self.environment, fake_run()))
        self.assertEqual(self.prepare(), "kept")
        for name in cache.CACHE_FOLDERS:
            self.assertTrue(self.present(name), name)
        self.assertTrue(any("the stamp matches" in line for line in self.lines), self.lines)

    def test_a_missing_stamp_empties_the_module_caches_and_writes_one(self):
        self.fill_caches()
        self.assertEqual(self.prepare(), "emptied")
        for name in cache.CACHE_FOLDERS:
            self.assertFalse(self.present(name), name)
        self.assertEqual(cache.read_stamp(self.derived), cache.current_stamp(self.environment, fake_run()))
        self.assertTrue(any("stamp is missing" in line for line in self.lines), self.lines)

    def test_a_new_runner_image_empties_them(self):
        self.fill_caches(cache.current_stamp(self.environment, fake_run()))
        self.assertEqual(self.prepare({**self.environment, "ImageVersion": "20261102.0473.1"}), "emptied")
        self.assertFalse(self.present("ModuleCache.noindex"))
        # The new stamp is the new image's, so the next build on it keeps what this build makes.
        self.assertEqual(cache.read_stamp(self.derived)["image_version"], "20261102.0473.1")

    def test_a_new_xcode_empties_them(self):
        self.fill_caches(cache.current_stamp(self.environment, fake_run()))
        self.assertEqual(self.prepare(run=fake_run("Xcode 26.1\nBuild version 17B100\n")), "emptied")
        self.assertFalse(self.present("ModuleCache.noindex"))

    def test_a_modulemap_with_a_new_time_empties_them(self):
        """The very failure of train 1116-1349: the toolchain's module.modulemap has a new time."""
        self.fill_caches(cache.current_stamp(self.environment, fake_run()))
        self.set_modulemap_time(1793595417)
        self.assertEqual(self.prepare(), "emptied")
        self.assertFalse(self.present("ModuleCache.noindex"))
        self.assertEqual(cache.read_stamp(self.derived)["modulemap_mtime"], 1793595417)

    def test_everything_else_the_build_can_reuse_stays(self):
        self.fill_caches()
        self.prepare()
        self.assertTrue(self.present("Build/Products/kept-or-not.pcm"))
        self.assertTrue(self.present("Build/Intermediates.noindex/App.build/kept-or-not.pcm"))
        # The Intermediates folder itself stays, with only the two folders of modules and headers taken out of it.
        self.assertTrue(self.present("Build/Intermediates.noindex"))

    def test_the_stamp_survives_and_is_the_next_builds_to_match(self):
        self.fill_caches()
        self.assertEqual(self.prepare(), "emptied")
        (self.derived / "ModuleCache.noindex").mkdir()  # What the build makes.
        self.assertEqual(self.prepare(), "kept")
        self.assertTrue(self.present("ModuleCache.noindex"))

    def test_a_stamp_that_knows_nothing_never_matches(self):
        """A runner whose toolchain cannot be read vouches for nothing, so a cache is never kept on that word."""
        nothing = {"image_version": None, "xcodebuild_version": None, "modulemap_mtime": None}
        self.fill_caches(nothing)
        self.assertEqual(self.prepare(environment={"GITHUB_ACTIONS": "true"}, run=fake_run(status=1)), "emptied")
        self.assertFalse(self.present("ModuleCache.noindex"))

    def test_a_folder_with_nothing_to_empty_still_gets_its_stamp(self):
        self.assertEqual(self.prepare(), "emptied")
        self.assertTrue((self.derived / cache.STAMP_NAME).exists())
        self.assertTrue(any("emptied nothing" in line for line in self.lines), self.lines)

    def test_nothing_is_touched_off_a_github_runner(self):
        self.fill_caches()
        before = sorted(str(path) for path in self.derived.rglob("*"))
        self.assertEqual(self.prepare({"DEVELOPER_DIR": str(self.developer)}), "skipped")
        self.assertEqual(sorted(str(path) for path in self.derived.rglob("*")), before)

    def test_the_log_says_what_the_restored_cache_held(self):
        """What a stale cache looked like is printed before it is judged, for the next reader of the job's log."""
        self.fill_caches()
        old = self.derived / "ModuleCache.noindex" / "old.pcm"
        old.write_text("x")
        os.utime(old, (1793595417, 1793595417))
        self.prepare()
        self.assertTrue(any("holds 2 .pcm files, 1 older than the toolchain's module.modulemap" in line
                            for line in self.lines), self.lines)

    def test_the_stamp_is_valid_json_a_person_can_read(self):
        self.prepare()
        text = (self.derived / cache.STAMP_NAME).read_text()
        self.assertEqual(json.loads(text)["xcodebuild_version"], "Xcode 26.0.1 Build version 17A400")


class EmptyingTests(CacheTestCase):
    """Emptying removes the named folders inside the derived-data folder and nothing outside it."""

    def test_only_the_named_folders_are_removed_and_they_are_listed(self):
        self.fill_caches()
        removed = cache.empty_module_caches(self.derived, say=self.lines.append)
        self.assertEqual(removed, list(cache.CACHE_FOLDERS))
        self.assertTrue(self.present("Build/Products"))

    def test_xcode_26s_explicit_swift_modules_are_emptied_by_the_retry_and_by_a_new_toolchain(self):
        # TL02: train 1116-2122's iPhone build failed both tries on a stale .pcm in this folder (the one the log names).
        folder = "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
        self.assertIn(folder, cache.CACHE_FOLDERS)
        self.fill_caches()
        self.assertEqual(cache.empty_module_caches(self.derived, say=self.lines.append).count(folder), 1)
        self.assertFalse(self.present(folder))
        self.fill_caches()
        self.assertEqual(self.prepare(), "emptied", "no stamp: the same folders go")
        self.assertFalse(self.present(folder))

    def test_a_link_is_removed_as_a_link_and_never_followed(self):
        outside = self.folder / "outside"
        outside.mkdir()
        (outside / "precious.txt").write_text("keep")
        self.derived.mkdir(parents=True)
        (self.derived / "ModuleCache.noindex").symlink_to(outside)
        self.assertEqual(cache.empty_module_caches(self.derived, say=self.lines.append), ["ModuleCache.noindex"])
        self.assertTrue((outside / "precious.txt").exists())
        self.assertFalse((self.derived / "ModuleCache.noindex").exists())

    def test_a_folder_that_is_not_there_is_not_an_error(self):
        self.assertEqual(cache.empty_module_caches(self.folder / "no-such-folder", say=self.lines.append), [])


class ReadingErrorsTests(unittest.TestCase):
    """A log or an error list that holds the stale-module error is told apart from every other."""

    ERROR = ("error: Clang dependency scanner failure: fatal error: file '/Applications/Xcode_26.0.1.app/Contents/"
             "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include/module.modulemap' has been "
             "modified since the module file '/Users/runner/work/TextMouth/TextMouth/build/remote-DerivedData-ios/"
             "ModuleCache.noindex/1TV4X376J16CB/_Builtin_stdbool-FTUUUU4ZHFEK.pcm' was built: mtime changed "
             "(was 1793595417, now 1794497068)")

    def test_the_real_error_of_train_1116_1349_is_recognised_in_a_log_and_as_an_error(self):
        self.assertTrue(cache.is_stale_module_error("CompileSwift ...\n" + self.ERROR + "\n"))
        self.assertTrue(cache.stale_cache_only([self.ERROR, self.ERROR.replace("error: Clang", "error: x Clang")]))

    def test_another_error_is_not_the_caches(self):
        self.assertFalse(cache.is_stale_module_error("A.swift:1:2: error: cannot find 'x' in scope"))
        self.assertFalse(cache.stale_cache_only([]))

    def test_one_error_of_the_codes_makes_the_failure_the_codes(self):
        self.assertFalse(cache.stale_cache_only([self.ERROR, "TextMouth/A.swift:1:2: error: cannot find 'x' in scope"]))

    # Train 1117-1219's line, as the log printed it (its paths are the runner's).
    MISSING = ("/Applications/Xcode_26.0.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/include/"
               "stddef.h:89:2: fatal error: module file '/Users/runner/work/TextMouth/TextMouth/build/remote-DerivedData-ios/"
               "Build/Intermediates.noindex/ExplicitPrecompiledModules/_Builtin_stddef-9GGUBAMBUN08H8VY1LWYJDQUK.pcm' "
               "not found: module file not found")

    def test_a_precompiled_module_that_is_not_there_is_named_as_the_caches_failure(self):
        # TL06 and train 1117-1219: neither the stale-module words nor an "error:" line.
        self.assertEqual(cache.cache_failure("CompileC ...\n" + self.MISSING + "\n"), cache.MISSING_MARKER)
        self.assertEqual(cache.cache_failure(self.ERROR), cache.STALE_MARKER)
        self.assertTrue(cache.stale_cache_only([self.MISSING, self.ERROR]))

    def test_a_real_error_that_mentions_a_module_is_not_the_caches_failure(self):
        for text in ("A.swift:1:8: error: no such module 'Foo'", "A.swift:1:8: error: module 'Foo' not found",
                     "A.swift:1:2: error: cannot find 'x' in scope", ""):
            self.assertIsNone(cache.cache_failure(text), text)
        self.assertFalse(cache.stale_cache_only([self.MISSING, "A.swift:1:2: error: cannot find 'x' in scope"]))

    def test_the_sentence_says_it_is_not_the_branchs_code(self):
        self.assertIn("not this branch's code", cache.STALE_SENTENCE)


if __name__ == "__main__":
    unittest.main()
