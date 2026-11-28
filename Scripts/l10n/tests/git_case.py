"""A scratch git repository for tests that need real merges or diffs (l10n tests).

Every repository is a temporary folder with a configuration of its own: the user's and the system's git configuration are
not read, so nothing here touches the repository the tests run in, and `git config` is run only inside the scratch folder.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HAS_GIT = shutil.which("git") is not None


class GitCase(unittest.TestCase):
    """A fresh scratch repository (`self.repo`, branch `main`) for each test; subclasses add files and commits."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Path(folder.name)
        # The user's and the system's git configuration are not read: only the scratch repository's own.
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *arguments, check=True):
        """Runs git in the scratch repository; returns the completed process (text output). Fails the test when `check` and
        git exits with a status other than 0."""
        done = subprocess.run(["git", *arguments], cwd=self.repo, env=self.env, capture_output=True, text=True)
        if check and done.returncode != 0:
            self.fail(f"git {' '.join(arguments)} failed: {done.stdout}{done.stderr}")
        return done

    def put(self, name, text):
        """Writes the text file `name` (a path under the repository, folders made) and returns its path."""
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def commit_all(self, message):
        """Stages everything and commits it."""
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)

    def branch_from_main(self, name):
        """Switches to a new branch `name` made from main."""
        self.git("switch", "-q", "main")
        self.git("switch", "-q", "-c", name)
