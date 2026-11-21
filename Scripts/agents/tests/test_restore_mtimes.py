"""Tests of restore_mtimes.py: every tracked file gets a time that depends only on its text.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test works in a throwaway repository in a temporary folder.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import restore_mtimes  # noqa: E402

NAMES = ("a.swift", "b.swift", "sub/c.swift")


class RestoreMtimesTests(unittest.TestCase):
    """A throwaway repository with a few tracked files."""

    def git(self, *args):
        """Runs git in the repository; returns its output."""
        return subprocess.run(["git", *args], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Path(folder.name) / "repo"
        self.repo.mkdir()
        self.manifest = Path(folder.name) / "cache" / "manifest.json"
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "T")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "sub").mkdir()
        for name, text in (("a.swift", "a"), ("b.swift", "b"), ("sub/c.swift", "c")):
            (self.repo / name).write_text(text + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "first")

    def mtime(self, name):
        """The modification time of a file in the repository."""
        return int((self.repo / name).stat().st_mtime)

    def blob_of(self, name):
        """The git blob hash of a tracked file, as the script reads it."""
        return self.git("rev-parse", f"HEAD:{name}")

    def checkout_again(self):
        """Stands in for a fresh checkout, which gives every file a new time."""
        for name in NAMES:
            os.utime(self.repo / name, None)

    def test_with_no_manifest_every_tracked_file_gets_its_content_time_and_a_manifest_is_written(self):
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (3, 0))
        for name in NAMES:
            self.assertEqual(self.mtime(name), restore_mtimes.content_time(self.blob_of(name)), name)
        self.assertEqual(sorted(json.loads(self.manifest.read_text())), list(NAMES))

    def test_the_same_text_has_the_same_time_whichever_run_it_is_checked_out_in(self):
        # The cause of the November 14 recompiles: a file's time must not depend on the run, only on its text.
        restore_mtimes.restore(self.repo, self.manifest)
        first = {name: self.mtime(name) for name in NAMES}
        self.checkout_again()
        restore_mtimes.restore(self.repo, self.manifest.parent / "other-manifest.json")
        self.assertEqual({name: self.mtime(name) for name in NAMES}, first)

    def test_a_file_changed_since_the_manifest_gets_another_time_and_is_counted_changed(self):
        restore_mtimes.restore(self.repo, self.manifest)
        before = self.mtime("b.swift")
        (self.repo / "b.swift").write_text("changed\n")
        self.git("commit", "-q", "-a", "-m", "second")
        self.checkout_again()
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (2, 1))
        self.assertNotEqual(self.mtime("b.swift"), before, "changed text must look changed to the build")
        self.assertEqual(self.mtime("b.swift"), restore_mtimes.content_time(self.blob_of("b.swift")))

    def test_every_time_is_in_the_past_of_a_checkout_and_in_the_spread(self):
        for blob in ("0" * 40, "f" * 40, "7fffffff" + "0" * 32):
            stamp = restore_mtimes.content_time(blob)
            self.assertGreaterEqual(stamp, restore_mtimes.FIXED_TIME)
            self.assertLess(stamp, restore_mtimes.FIXED_TIME + restore_mtimes.TIME_SPREAD)

    def test_a_new_file_is_changed_and_a_deleted_one_is_forgotten(self):
        restore_mtimes.restore(self.repo, self.manifest)
        (self.repo / "new.swift").write_text("new\n")
        self.git("rm", "-q", "a.swift")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "second")
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (2, 1))
        self.assertEqual(self.mtime("new.swift"), restore_mtimes.content_time(self.blob_of("new.swift")))
        self.assertNotIn("a.swift", json.loads(self.manifest.read_text()))

    def test_changed_names_lists_the_files_that_differ_from_the_manifest(self):
        current = {"a": "1", "b": "2", "c": "3"}
        self.assertEqual(restore_mtimes.changed_names(current, {"a": "1", "b": "x"}), ["b", "c"])
        self.assertEqual(restore_mtimes.changed_names(current, None), [])

    def test_a_file_changed_back_to_its_old_text_is_unchanged(self):
        # A file that went from x to y to x between two builds has the same hash, so the same time: right, since its
        # text is what was built.
        restore_mtimes.restore(self.repo, self.manifest)
        (self.repo / "a.swift").write_text("temporarily\n")
        (self.repo / "a.swift").write_text("a\n")
        os.utime(self.repo / "a.swift", None)
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (3, 0))

    def test_an_unreadable_manifest_is_the_same_as_none(self):
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text("{not json")
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (3, 0))
        json.loads(self.manifest.read_text())  # and a good one is written over it

    def test_untracked_files_are_not_touched(self):
        (self.repo / "untracked.txt").write_text("x\n")
        before = self.mtime("untracked.txt")
        restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual(self.mtime("untracked.txt"), before)

    def test_the_fixed_time_is_older_than_now(self):
        self.assertLess(restore_mtimes.FIXED_TIME + restore_mtimes.TIME_SPREAD, os.path.getmtime(__file__))


if __name__ == "__main__":
    unittest.main()
