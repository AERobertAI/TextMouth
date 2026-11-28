"""Shared helpers for the doc-library tests.

Run every test from the repository root with:

    python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests

Each test builds a small repository of its own in a temporary folder
(``write_tree``, or ``git_repo`` for one under git) and runs commands in-process
through ``run_cli``, so no test reads the real repository's docs or depends on
what they say. Importing this module puts the scripts folder on sys.path, so a
test can import any module of the skill by name.
"""

from __future__ import annotations

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, Optional, Tuple

SCRIPTS = Path(__file__).resolve().parent.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import doclib  # noqa: E402  (imported after sys.path is set)

# A fixed identity and no user configuration for every git command a test runs,
# so the tests behave the same on any Mac and never read ~/.gitconfig.
GIT_ENV = {
    "GIT_AUTHOR_NAME": "doclib test",
    "GIT_AUTHOR_EMAIL": "doclib-test@example.invalid",
    "GIT_COMMITTER_NAME": "doclib test",
    "GIT_COMMITTER_EMAIL": "doclib-test@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}


class DocLibCase(unittest.TestCase):
    """A test case with a temporary repository folder at ``self.root``."""

    def setUp(self) -> None:
        """Make the temporary folder; it is removed again when the test ends."""
        super().setUp()
        self._tmp = tempfile.TemporaryDirectory(prefix="doclib-test-")
        self.addCleanup(self._tmp.cleanup)
        # Resolved, because macOS's temporary folder is reached through a symlink
        # (/var is /private/var) and the commands print resolved paths.
        self.root = Path(self._tmp.name).resolve()

    def write_tree(self, files: Dict[str, str], root: Optional[Path] = None) -> Path:
        """Write each ``{relative path: text}`` under ``root`` (default ``self.root``)."""
        root = root or self.root
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return root

    def git(self, *args: str, root: Optional[Path] = None) -> str:
        """Run one git command in ``root`` and return its standard output."""
        env = dict(os.environ)
        env.update(GIT_ENV)
        result = subprocess.run(
            ["git", *args], cwd=root or self.root, env=env,
            capture_output=True, text=True, check=True,
        )
        return result.stdout

    def git_repo(self, files: Dict[str, str]) -> Path:
        """Write ``files`` into ``self.root``, make it a git repository on ``main``, and commit."""
        self.write_tree(files)
        self.git("init", "-q", "-b", "main")
        self.commit_all("base")
        return self.root

    def commit_all(self, message: str) -> str:
        """Stage everything in ``self.root``, commit it, and return the new commit's hash."""
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def run_cli(self, *argv: str, root: Optional[Path] = None) -> Tuple[int, str, str]:
        """Run ``doclib.py ARGV --root ROOT`` in-process; return (status, stdout, stderr).

        ``--root`` is added after the arguments unless they already give one, and
        argparse's own exits (``--help``, a usage error) come back as a status.
        """
        args = list(argv)
        if "--root" not in args:
            args += ["--root", str(root or self.root)]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = doclib.main(args)
            except SystemExit as exit_:
                status = exit_.code if isinstance(exit_.code, int) else 2
        return status, out.getvalue(), err.getvalue()
