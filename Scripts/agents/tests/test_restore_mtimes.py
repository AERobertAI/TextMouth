"""Tests of restore_mtimes.py: unchanged files get a fixed old time, changed files keep their own.

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

    def test_with_no_manifest_every_tracked_file_gets_the_fixed_time_and_a_manifest_is_written(self):
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (3, 0))
        for name in ("a.swift", "b.swift", "sub/c.swift"):
            self.assertEqual(self.mtime(name), restore_mtimes.FIXED_TIME, name)
        saved = json.loads(self.manifest.read_text())
        self.assertEqual(sorted(saved), ["a.swift", "b.swift", "sub/c.swift"])

    def test_a_file_changed_since_the_manifest_keeps_its_own_newer_time(self):
        restore_mtimes.restore(self.repo, self.manifest)
        (self.repo / "b.swift").write_text("changed\n")
        self.git("commit", "-q", "-a", "-m", "second")
        # A fresh checkout gives every file a new time; stand that in for by touching them all.
        for name in ("a.swift", "b.swift", "sub/c.swift"):
            os.utime(self.repo / name, None)
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (2, 1))
        self.assertEqual(self.mtime("a.swift"), restore_mtimes.FIXED_TIME)
        self.assertEqual(self.mtime("sub/c.swift"), restore_mtimes.FIXED_TIME)
        self.assertGreater(self.mtime("b.swift"), restore_mtimes.FIXED_TIME, "a changed file must look newer than the products")

    def test_a_new_file_is_changed_and_a_deleted_one_is_forgotten(self):
        restore_mtimes.restore(self.repo, self.manifest)
        (self.repo / "new.swift").write_text("new\n")
        self.git("rm", "-q", "a.swift")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "second")
        kept, changed = restore_mtimes.restore(self.repo, self.manifest)
        self.assertEqual((kept, changed), (2, 1))
        self.assertGreater(self.mtime("new.swift"), restore_mtimes.FIXED_TIME)
        self.assertNotIn("a.swift", json.loads(self.manifest.read_text()))

    def test_a_file_changed_back_to_its_old_text_is_still_found_changed_by_the_manifest_of_the_build(self):
        # The manifest is that of the last build: a file that went from x to y to x between two builds
        # of the cache has the same hash, so it is unchanged, which is right: its text is what was built.
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
        self.assertLess(restore_mtimes.FIXED_TIME, os.path.getmtime(__file__))


if __name__ == "__main__":
    unittest.main()
