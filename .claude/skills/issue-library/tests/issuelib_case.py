"""Shared helpers for the issue-library tests.

Run every test from the repository root with:

    python3 -I -B -m unittest discover -s .claude/skills/issue-library/tests

Each test builds a small repository of its own in a temporary folder and runs the
commands in-process through ``run_cli`` (or as a real process through ``run_process``
when git must run them, as a merge does), so no test reads or writes the real
``Issues/`` folder or the real TODO. Importing this module puts the scripts folder on
sys.path, so a test can import any module of the skill by name, and fixes "today"
at 2026-11-16 through ISSUELIB_TODAY.
"""

from __future__ import annotations

import contextlib
import io
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, Iterator, Optional, Tuple

# No bytecode beside the skill when the tests run without -B.
sys.dont_write_bytecode = True
SKILL = Path(__file__).resolve().parent.parent
SCRIPTS = SKILL / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

# The template a new issue is made from.
TEMPLATE = SKILL / "template.md"

# The date every test runs on.
TODAY = "2026-11-16"

# A fixed identity and no user configuration for every git command a test runs,
# so the tests behave the same on any Mac and never read ~/.gitconfig.
GIT_ENV = {
    "GIT_AUTHOR_NAME": "issuelib test",
    "GIT_AUTHOR_EMAIL": "issuelib-test@example.invalid",
    "GIT_COMMITTER_NAME": "issuelib test",
    "GIT_COMMITTER_EMAIL": "issuelib-test@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}

# A small TODO in the real one's shape: a merge record, open and done items, an ID
# given twice with an alias on the older one, and a mention of another list's item.
TODO = """\
# TODO

## Completed fixes

- [x] **B12 — the float merge.** Merged 6b09b2ee2 (`fix/float64-render`).

## Bugs

- [x] **B12 — A 64-bit float book crashes a render.** Merged 6b09b2ee2, November 16.
- [x] **B14 — A save's temporary file can make a move fail.** Found November 16, 2026 by `review-rulesmove`.
- [x] **B15 — A valid audio file is called damaged.** Found November 16, 2026 by `review-floatrender`.
- [x] **B12 (alias B12-OCT) — An update replaces edited text.** Merged 77e798a0, October 21. The audit's C18 waits.
"""

# A valid issue file, as ``new`` writes one for B16.
B16 = """\
---
id: B16
title: A test bug
kind: bug
status: open
priority: P2
platform: mac
assignee:
created: 2026-11-16
updated: 2026-11-16
found-by: orchestrator
branch:
merged:
reason:
related: B12
docs:
labels: audio
---

## Description

What is wrong.

## Comments
"""


# B16, given to the agent that works on it.
ASSIGNED = B16.replace("assignee:\n", "assignee: floatrender\n").replace("branch:\n", "branch: fix/float64-render\n")

# The repository's own .gitattributes, three folders above the skill's.
ATTRIBUTES = (SKILL.parents[2] / ".gitattributes").read_text(encoding="utf-8")


def driver_command() -> str:
    """The merge driver as a test's repository defines it: this checkout's script, by its full path."""
    script = shlex.quote(str(SCRIPTS / "issuelib.py"))
    return f"{shlex.quote(sys.executable)} -I -B {script} merge-driver %O %A %B %L %P"


class IssueCase(unittest.TestCase):
    """A test case with a temporary repository folder at ``self.root``."""

    def setUp(self) -> None:
        """Make the temporary folder (removed when the test ends) and fix today's date."""
        super().setUp()
        self._tmp = tempfile.TemporaryDirectory(prefix="issuelib-test-")
        self.addCleanup(self._tmp.cleanup)
        # Resolved, because macOS's temporary folder is reached through a symlink.
        self.root = Path(self._tmp.name).resolve()
        # Imported here, not above, so the tests of the modules beneath the store need only those.
        import issuestore
        self._today_env = issuestore.TODAY_ENV
        self._saved_today = os.environ.get(self._today_env)
        os.environ[self._today_env] = TODAY
        self.addCleanup(self._restore_today)

    def _restore_today(self) -> None:
        """Put ISSUELIB_TODAY back as it was before the test."""
        if self._saved_today is None:
            os.environ.pop(self._today_env, None)
        else:
            os.environ[self._today_env] = self._saved_today

    def write_tree(self, files: Dict[str, str], root: Optional[Path] = None) -> Path:
        """Write each ``{relative path: text}`` under ``root`` (default ``self.root``)."""
        root = root or self.root
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return root

    def read(self, relative: str, root: Optional[Path] = None) -> str:
        """The text of one file under ``root`` (default ``self.root``)."""
        return ((root or self.root) / relative).read_text(encoding="utf-8")

    def git(self, *args: str, root: Optional[Path] = None, check: bool = True) -> subprocess.CompletedProcess:
        """Run one git command in ``root`` (default ``self.root``) with the fixed identity."""
        env = dict(os.environ)
        env.update(GIT_ENV)
        return subprocess.run(["git", *args], cwd=root or self.root, env=env, capture_output=True,
                              text=True, check=check, timeout=60)

    def git_repo(self, files: Dict[str, str], root: Optional[Path] = None) -> Path:
        """Write ``files``, make the folder a git repository on ``main``, and commit them."""
        root = root or self.root
        self.write_tree(files, root)
        self.git("init", "-q", "-b", "main", root=root)
        self.commit_all("base", root=root)
        return root

    def commit_all(self, message: str, root: Optional[Path] = None) -> str:
        """Stage everything, commit it, and return the new commit's hash."""
        self.git("add", "-A", root=root)
        self.git("commit", "-q", "--allow-empty", "-m", message, root=root)
        return self.git("rev-parse", "HEAD", root=root).stdout.strip()

    def run_cli(self, *argv: str, root: Optional[Path] = None) -> Tuple[int, str, str]:
        """Run ``issuelib.py ARGV --root ROOT`` in-process; return (status, stdout, stderr).

        ``--root`` is added unless the arguments give one, and argparse's own exits
        (``--help``, a usage error) come back as a status.
        """
        import issuelib
        args = list(argv)
        if "--root" not in args:
            args += ["--root", str(root or self.root)]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = issuelib.main(args)
            except SystemExit as exit_:
                status = exit_.code if isinstance(exit_.code, int) else 2
        return status, out.getvalue(), err.getvalue()

    def run_process(self, *argv: str, root: Optional[Path] = None) -> subprocess.CompletedProcess:
        """Run ``issuelib.py ARGV`` as its own process in ``root``, as an agent would."""
        env = dict(os.environ)
        env.update(GIT_ENV)
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPTS / "issuelib.py"), *argv],
                              cwd=root or self.root, env=env, capture_output=True, text=True, timeout=120)

    @contextlib.contextmanager
    def on(self, date: str) -> Iterator[None]:
        """Run what the block runs as if today were ``date``."""
        saved = os.environ.get(self._today_env)
        os.environ[self._today_env] = date
        try:
            yield
        finally:
            os.environ[self._today_env] = saved or TODAY

    def new_issue(self, title: str = "A test bug", kind: str = "bug", platform: str = "mac",
                  *extra: str, root: Optional[Path] = None) -> Tuple[int, str, str]:
        """File one issue as the orchestrator, with a one-line description."""
        return self.run_cli("new", "--kind", kind, "--title", title, "--platform", platform,
                            "--description", "What is wrong.", "--as", "orchestrator", *extra, root=root)


class RepositoryCase(IssueCase):
    """A repository on main with the TODO, B16 assigned to floatrender, the real .gitattributes, and the driver."""

    def make_repository(self, driver: bool = True, attributes: bool = True, files: Optional[Dict[str, str]] = None) -> None:
        """Commit the starting files (and ``files``) on main, and define the merge driver unless told not to."""
        start = {"TODO-2026-09-04.md": TODO, "Issues/README.md": "# Issues\n", "Issues/B16.md": ASSIGNED}
        if attributes:
            start[".gitattributes"] = ATTRIBUTES
        start.update(files or {})
        self.git_repo(start)
        if driver:
            self.git("config", "merge.issuefile.driver", driver_command())

    def as_agent(self, *argv: str) -> Tuple[int, str, str]:
        """Run a command as the agent floatrender."""
        return self.run_cli(*argv, "--as", "floatrender")

    def as_orchestrator(self, *argv: str) -> Tuple[int, str, str]:
        """Run a command as the orchestrator."""
        return self.run_cli(*argv, "--as", "orchestrator")

    def merge(self, branch: str, check: bool = False) -> subprocess.CompletedProcess:
        """Merge ``branch`` into the current branch with a merge commit, as the orchestrator does."""
        return self.git("merge", "--no-ff", "-m", f"Merge {branch}", branch, check=check)
