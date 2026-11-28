"""The skill's files in git: its source and data only, never Python's bytecode caches.

Everything under ``.claude/`` is ignored, so the skill's files are staged with
``git add -f``; given a folder, that takes the ``__pycache__`` folders the tests and
commands leave beside the scripts too. Bytecode records the absolute path of the
checkout it was made in, and this repository is public, so none may be committed.
"""

from __future__ import annotations

import subprocess

from doclib_case import SCRIPTS, DocLibCase

import doclib
import output

# The skill's folder, from the repository's root.
SKILL = ".claude/skills/doc-library"


class TrackedFilesTests(DocLibCase):
    """git's list of the skill's files (staged ones included) holds no bytecode."""

    def test_no_bytecode_is_staged_or_committed(self) -> None:
        try:
            root = doclib.find_root(SCRIPTS)
        except output.UsageError:
            self.skipTest("the skill is not inside a git repository here")
        result = subprocess.run(["git", "-C", str(root), "ls-files", "--", SKILL],
                                capture_output=True, text=True)
        if result.returncode != 0:
            self.skipTest("git could not list the skill's files")
        caches = [path for path in result.stdout.splitlines()
                  if "__pycache__/" in path or path.endswith((".pyc", ".pyo"))]
        self.assertEqual(caches, [], "Python's caches are in git; unstage them with git reset HEAD -- PATH")
