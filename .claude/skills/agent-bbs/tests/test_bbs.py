"""Tests for the agent message board (scripts/bbs.py).

Run from the repository root with:

    python3 -m unittest discover -s .claude/skills/agent-bbs/tests

Every test uses its own temporary board through TEXTMOUTH_BBS_DIR, so the
shared board in the main repository is never touched.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import List, Tuple
from unittest import mock

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = SKILL_DIR / "scripts"
SCRIPT = SCRIPTS_DIR / "bbs.py"

# Import the script as a module; worker processes started by multiprocessing
# import this file again, so the path must be set up at import time.
sys.path.insert(0, str(SCRIPTS_DIR))
import bbs  # noqa: E402  (imported after the path is set up)

#: A fixed moment for tests that control the clock.
NOON = dt.datetime(2026, 10, 2, 12, 0, 0, tzinfo=dt.timezone.utc)


def environment_without_board_override() -> dict:
    """Return a copy of the environment with TEXTMOUTH_BBS_DIR removed."""
    return {key: value for key, value in os.environ.items() if key != bbs.BOARD_DIR_ENV}


def git(*args: str, cwd: Path) -> None:
    """Run git quietly, ignoring the user's own git configuration."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    identity = ["-c", "user.name=Board Test", "-c", "user.email=board-test@example.invalid"]
    subprocess.run(["git", *identity, *args], cwd=cwd, env=env, check=True, capture_output=True, text=True)


class TemporaryDirectoryMixin(unittest.TestCase):
    """Gives each test a fresh temporary directory, removed afterwards."""

    def make_temp_dir(self) -> Path:
        """Create a temporary directory (symlinks resolved) for this test."""
        path = Path(tempfile.mkdtemp(prefix="bbs-test-")).resolve()
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path


class BoardTestCase(TemporaryDirectoryMixin):
    """Base class: each test runs commands against its own empty board."""

    def setUp(self) -> None:
        """Point TEXTMOUTH_BBS_DIR at a fresh directory for this test."""
        super().setUp()
        self.board_dir = self.make_temp_dir() / "board"
        patcher = mock.patch.dict(os.environ, {bbs.BOARD_DIR_ENV: str(self.board_dir)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_bbs(self, *args: str, stdin: str = "") -> Tuple[int, str, str]:
        """Run one command in this process; return (status, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(
            sys, "stdin", io.StringIO(stdin)
        ):
            status = bbs.main(list(args))
        return status, out.getvalue(), err.getvalue()

    def ok(self, *args: str, stdin: str = "") -> str:
        """Run a command that must succeed; return its standard output."""
        status, out, err = self.run_bbs(*args, stdin=stdin)
        self.assertEqual(status, 0, f"{args} failed: {err}")
        self.assertEqual(err, "")
        return out

    def ok_json(self, *args: str, stdin: str = "") -> object:
        """Run a command with --json that must succeed; return the parsed JSON."""
        return json.loads(self.ok(*args, "--json", stdin=stdin))

    def fails(self, *args: str, stdin: str = "") -> str:
        """Run a command that must fail as a user error; return its message.

        A user error exits with status 1, prints nothing on standard output,
        and explains itself in exactly one line on standard error.
        """
        status, out, err = self.run_bbs(*args, stdin=stdin)
        self.assertEqual(status, 1, f"{args} should have failed: {out}")
        self.assertEqual(out, "")
        self.assertEqual(len(err.splitlines()), 1, err)
        self.assertTrue(err.startswith("bbs.py: error: "), err)
        return err

    def register(self, name: str, *files: str) -> None:
        """Register an agent with a stock role and branch, claiming ``files``."""
        args = ["register", name, "--role", f"{name} work", "--branch", f"feature/{name}"]
        if files:
            args += ["--files", *files]
        self.ok(*args)

    @contextlib.contextmanager
    def clock(self, moment: dt.datetime):
        """Make the board believe the current time is ``moment``."""
        with mock.patch.object(bbs, "utc_now", return_value=moment):
            yield


class RegistrationTests(BoardTestCase):
    """register, heartbeat, agents, and how unknown agents are refused."""

    def test_register_creates_an_agent(self) -> None:
        data = self.ok_json("register", "Alpha", "--role", "Fixes  the\nimporter", "--branch", "fix/importer")
        self.assertTrue(data["created"])
        agent = data["agent"]
        self.assertEqual(agent["name"], "alpha", "names are stored in lower case")
        self.assertEqual(agent["role"], "Fixes the importer", "the role is collapsed to one line")
        self.assertEqual(agent["branch"], "fix/importer")
        self.assertEqual(agent["activity"], "idle")
        self.assertRegex(agent["last_seen"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", "times are stored in UTC")

    def test_reregistering_updates_the_same_agent(self) -> None:
        with self.clock(NOON):
            self.register("alpha")
        later = NOON + dt.timedelta(minutes=5)
        with self.clock(later):
            data = self.ok_json("register", "ALPHA", "--branch", "fix/other")
        self.assertFalse(data["created"])
        agent = data["agent"]
        self.assertEqual(agent["branch"], "fix/other")
        self.assertEqual(agent["role"], "alpha work", "an omitted role is kept")
        self.assertEqual(agent["registered"], bbs.to_utc_text(NOON))
        self.assertEqual(agent["last_seen"], bbs.to_utc_text(later))
        self.assertEqual([a["name"] for a in self.ok_json("agents")], ["alpha"])

    def test_first_registration_needs_role_and_branch(self) -> None:
        self.assertIn("needs --role and --branch", self.fails("register", "alpha", "--role", "x"))
        self.assertEqual(self.ok_json("agents"), [])

    def test_invalid_and_reserved_names_are_rejected(self) -> None:
        for name in ("all", "ALL", "two words", "dot/slash", "x" * 41, ""):
            with self.subTest(name=name):
                self.fails("register", name, "--role", "r", "--branch", "b")

    def test_one_line_fields_have_a_length_limit(self) -> None:
        message = self.fails("register", "alpha", "--role", "r" * 201, "--branch", "b")
        self.assertIn("the limit is 200", message)
        self.fails("register", "alpha", "--role", "   ", "--branch", "b")

    def test_heartbeat_refreshes_last_seen(self) -> None:
        with self.clock(NOON):
            self.register("alpha")
        later = NOON + dt.timedelta(minutes=9)
        with self.clock(later):
            self.assertEqual(self.ok_json("heartbeat", "alpha")["last_seen"], bbs.to_utc_text(later))

    def test_unknown_agents_are_rejected_with_a_hint_to_register(self) -> None:
        self.register("alpha")
        message = self.fails("heartbeat", "alpah")
        self.assertIn("unknown agent 'alpah'", message)
        self.assertIn("did you mean 'alpha'", message)
        self.assertIn("register alpah --role", message)

    def test_agents_shows_role_branch_activity_and_last_seen(self) -> None:
        self.register("alpha")
        text = self.ok("agents")
        self.assertIn("1 agent:", text)
        self.assertIn("alpha: idle since", text)
        self.assertIn("last seen", text)
        self.assertIn("Role: alpha work", text)
        self.assertIn("Branch: feature/alpha", text)

    def test_agents_active_within_filters_by_last_seen(self) -> None:
        with self.clock(NOON - dt.timedelta(hours=2)):
            self.register("sleepy")
        with self.clock(NOON):
            self.register("busy")
            names = [a["name"] for a in self.ok_json("agents", "--active-within", "30")]
            self.assertEqual(names, ["busy"])
            self.assertIn("1 agent active in the last 30 minutes:", self.ok("agents", "--active-within", "30"))
        with self.clock(NOON + dt.timedelta(hours=1)):
            self.assertIn("No agents active in the last 5 minutes.", self.ok("agents", "--active-within", "5"))
        self.assertEqual(len(self.ok_json("agents")), 2)

    def test_json_flag_is_accepted_before_or_after_the_command(self) -> None:
        self.register("alpha")
        before = json.loads(self.ok("--json", "agents"))
        after = json.loads(self.ok("agents", "--json"))
        self.assertEqual(before, after)

    def test_usage_errors_exit_with_status_1_and_one_line(self) -> None:
        self.fails()
        self.fails("no-such-command")
        self.fails("agents", "--active-within", "0")
        self.fails("agents", "--no-such-option")
        self.fails("heartbeat")


class RepositoryDiscoveryTests(TemporaryDirectoryMixin):
    """Where the board lives when TEXTMOUTH_BBS_DIR is not set."""

    @unittest.skipUnless(shutil.which("git"), "git is not installed")
    def test_a_linked_worktree_uses_the_main_repository_board(self) -> None:
        root = self.make_temp_dir()
        main = root / "main"
        main.mkdir()
        git("init", "-q", cwd=main)
        (main / "README").write_text("board test\n")
        git("add", "README", cwd=main)
        git("commit", "-q", "-m", "Initial commit", cwd=main)
        linked = root / "linked"
        git("worktree", "add", "-q", "-b", "side", str(linked), cwd=main)
        nested = linked / "deep" / "er"
        nested.mkdir(parents=True)
        expected = main / ".claude" / "agent-bbs"

        self.assertEqual(bbs.repository_board_directory([nested]), expected)
        self.assertEqual(bbs.repository_board_directory([main]), expected)

        # End to end: run inside the worktree with no override, then read the
        # board from the main working tree in another process.
        env = environment_without_board_override()
        registered = subprocess.run(
            [sys.executable, str(SCRIPT), "register", "probe", "--role", "probe", "--branch", "side"],
            cwd=nested, env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(registered.returncode, 0, registered.stderr)
        self.assertTrue((expected / "board.sqlite").is_file())
        self.assertFalse((linked / ".claude").exists(), "the worktree must not get a board of its own")
        listed = subprocess.run(
            [sys.executable, str(SCRIPT), "agents", "--json"],
            cwd=main, env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual([agent["name"] for agent in json.loads(listed.stdout)], ["probe"])

    def test_relative_gitdir_and_commondir_are_followed(self) -> None:
        root = self.make_temp_dir()
        private = root / "repo" / ".git" / "worktrees" / "wt"
        private.mkdir(parents=True)
        (private / "commondir").write_text("../..\n")
        (root / "wt").mkdir()
        (root / "wt" / ".git").write_text("gitdir: ../repo/.git/worktrees/wt\n")
        self.assertEqual(bbs.repository_board_directory([root / "wt"]), root / "repo" / ".claude" / "agent-bbs")

    def test_a_git_file_without_commondir_is_its_own_main_tree(self) -> None:
        # A submodule's .git file points into the superproject's modules.
        root = self.make_temp_dir()
        (root / "super" / ".git" / "modules" / "sub").mkdir(parents=True)
        (root / "super" / "sub").mkdir()
        (root / "super" / "sub" / ".git").write_text("gitdir: ../.git/modules/sub\n")
        self.assertEqual(
            bbs.repository_board_directory([root / "super" / "sub"]),
            root / "super" / "sub" / ".claude" / "agent-bbs",
        )

    def test_a_bare_repository_worktree_uses_the_shared_git_directory(self) -> None:
        root = self.make_temp_dir()
        private = root / "project.git" / "worktrees" / "wt"
        private.mkdir(parents=True)
        (private / "commondir").write_text("../..\n")
        (root / "wt").mkdir()
        (root / "wt" / ".git").write_text(f"gitdir: {private}\n")
        self.assertEqual(
            bbs.repository_board_directory([root / "wt"]), root / "project.git" / ".claude" / "agent-bbs"
        )

    def test_a_malformed_git_file_is_a_user_error(self) -> None:
        root = self.make_temp_dir()
        (root / ".git").write_text("not a gitdir line\n")
        with self.assertRaises(bbs.UserError):
            bbs.repository_board_directory([root])

    def test_later_starts_are_tried_when_earlier_ones_are_outside_a_repository(self) -> None:
        outside = self.make_temp_dir()
        repo = self.make_temp_dir()
        (repo / ".git").mkdir()
        (repo / "sub").mkdir()
        self.assertEqual(bbs.repository_board_directory([outside, repo / "sub"]), repo / ".claude" / "agent-bbs")
        with self.assertRaises(bbs.UserError):
            bbs.repository_board_directory([outside])

    def test_the_environment_variable_overrides_discovery(self) -> None:
        chosen = self.make_temp_dir() / "elsewhere"
        with mock.patch.dict(os.environ, {bbs.BOARD_DIR_ENV: str(chosen)}):
            self.assertEqual(bbs.board_directory(), chosen)


if __name__ == "__main__":
    unittest.main()
