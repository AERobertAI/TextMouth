"""Tests for the agent message board (scripts/bbs.py).

Run from the repository root with:

    python3 -m unittest discover -s .claude/skills/agent-bbs/tests

Every test uses a temporary board, named by TEXTMOUTH_BBS_DIR or found in
a temporary repository, so the shared board of this repository is never
touched. The build-slot wrapper tests use a temporary slot directory too.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import io
import json
import multiprocessing
import os
import re
import shutil
import sqlite3
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

#: Stored times look like this: UTC, to the second.
UTC_TEXT = r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"


def run_in_worker(label: int, board_dir: str, workdir: str, commands: List[List[str]], start, results) -> None:
    """Body of a worker process in the concurrency tests.

    Waits for the shared start signal so that every worker begins at once,
    runs its board commands in order, and reports ``(label, outcomes)``
    through ``results``, each outcome being (exit status, stdout, stderr).
    """
    os.environ[bbs.BOARD_DIR_ENV] = board_dir
    os.chdir(workdir)
    start.wait(60)
    outcomes = []
    for argv in commands:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = bbs.main(argv)
        outcomes.append((status, out.getvalue(), err.getvalue()))
    results.put((label, outcomes))


def environment_without_board_override() -> dict:
    """Return a copy of the environment with TEXTMOUTH_BBS_DIR removed."""
    return {key: value for key, value in os.environ.items() if key != bbs.BOARD_DIR_ENV}


def git(*args: str, cwd: Path) -> None:
    """Run git quietly, ignoring the user's own git configuration."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    identity = ["-c", "user.name=Board Test", "-c", "user.email=board-test@example.invalid"]
    subprocess.run(["git", *identity, *args], cwd=cwd, env=env, check=True, capture_output=True, text=True)


class TemporaryDirectoryTestCase(unittest.TestCase):
    """Gives each test a fresh temporary directory, removed afterwards."""

    def make_temp_dir(self) -> Path:
        """Create a temporary directory (symlinks resolved) for this test."""
        path = Path(tempfile.mkdtemp(prefix="bbs-test-")).resolve()
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path


class BoardTestCase(TemporaryDirectoryTestCase):
    """Base class: each test runs commands against its own empty board.

    Commands run from a scratch working tree (``self.worktree``), so that
    paths resolve against it rather than against this repository.
    """

    def setUp(self) -> None:
        """Point TEXTMOUTH_BBS_DIR at a fresh directory and enter a scratch tree."""
        super().setUp()
        self.board_dir = self.make_temp_dir() / "board"
        patcher = mock.patch.dict(os.environ, {bbs.BOARD_DIR_ENV: str(self.board_dir)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.worktree = self.make_temp_dir()
        (self.worktree / ".git").mkdir()
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.worktree)

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

    def test_activity_is_shown_by_agents_until_replaced(self) -> None:
        with self.clock(NOON):
            self.register("alpha")
        building_at = NOON + dt.timedelta(minutes=3)
        with self.clock(building_at):
            text = self.ok("activity", "alpha", "building", "--note", "xcodebuild  test")
        self.assertEqual(text, "alpha is building: xcodebuild test.\n")
        agent = self.ok_json("agents")[0]
        self.assertEqual((agent["activity"], agent["activity_note"]), ("building", "xcodebuild test"))
        self.assertEqual(agent["activity_since"], bbs.to_utc_text(building_at))
        self.assertEqual(agent["last_seen"], bbs.to_utc_text(building_at), "setting an activity shows the agent is alive")
        self.assertIn(f"alpha: building since {bbs.local_label(agent['activity_since'])} (xcodebuild test)", self.ok("agents"))
        agent = self.ok_json("activity", "alpha", "idle")
        self.assertEqual((agent["activity"], agent["activity_note"]), ("idle", ""), "a new activity clears the note")

    def test_activity_accepts_only_known_states_and_agents(self) -> None:
        self.register("alpha")
        self.assertIn("invalid choice: 'compiling'", self.fails("activity", "alpha", "compiling"))
        self.fails("activity", "nobody", "idle")
        self.fails("activity", "alpha", "testing", "--note", "n" * 201)

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


class PatternTests(TemporaryDirectoryTestCase):
    """normalize_pattern and patterns_overlap: the rules behind claims."""

    #: Pairs that can name a common file, whichever comes first.
    OVERLAPPING = [
        ("TextMouth/A.swift", "TextMouth/A.swift"),
        ("TextMouth/A.swift", "textmouth/a.swift"),  # letter case is ignored
        ("TextMouth/", "TextMouth/A.swift"),  # a directory covers its contents
        ("TextMouth", "TextMouth/A.swift"),  # naming a path inside proves a directory
        ("TextMouth/New", "TextMouth/New/*.swift"),
        ("a/", "a/b/"),
        ("TextMouth/*.swift", "TextMouth/A.swift"),
        ("TextMouth/**/*.swift", "TextMouth/A.swift"),  # '**/' may be empty
        ("TextMouth/**/*.swift", "TextMouth/Views/Deep/A.swift"),
        ("**/Info.plist", "TextMouth/Info.plist"),
        ("**/Info.plist", "Info.plist"),
        ("**/Info.plist", "TextMouth/"),
        ("TextMouth/Views/*.swift", "TextMouth/**/Library*.swift"),  # glob against glob
        ("TextMouth/*.swift", "TextMouth/Library*"),
        ("TextMouth/Views/", "TextMouth/*/LibraryView.swift"),
        ("TextMouth/Lib?ary.swift", "TextMouth/Library.swift"),
        ("TextMouth/[A-C]*.swift", "TextMouth/Book.swift"),
        ("x/[!a-c]q", "x/[a-e]q"),
        ("x/[!a-cx-z]q", "x/[a-z]q"),  # meet only between the excluded ranges
        ("x/[]a]q", "x/]q"),
        ("**", "anything/at/all"),
        ("a/**", "a"),
        ("*a*", "*b*"),
    ]

    #: Pairs that cannot name a common file.
    SEPARATE = [
        ("TextMouth/A.swift", "TextMouth/B.swift"),
        ("TextMouth/A", "TextMouth/AB.swift"),
        ("TextMouth/A/", "TextMouth/AB.swift"),
        ("TextMouth/*.swift", "TextMouth/Views/A.swift"),  # '*' stays within a segment
        ("TextMouth/*", "TextMouth/Views/A.swift"),
        ("TextMouth/**/*.swift", "TextMouthTests/A.swift"),
        ("**/Info.plist", "Info.plistx"),  # a file has nothing inside it
        ("**/Info.plist", "Makefile"),
        ("TextMouth/*.swift", "TextMouth/*.md"),
        ("TextMouth/Lib?ary.swift", "TextMouth/Lib/ary.swift"),
        ("TextMouth/[!A-C]*.swift", "TextMouth/Book.swift"),
        ("TextMouth/[^A-C]*.swift", "TextMouth/Book.swift"),
        ("x/[ab]q", "x/[cd]q"),
        ("a/**", "ab"),
        ("a/**/b", "a/xb"),
        ("a/**/b/*.c", "a/**/d/*.c"),
        ("*", "TextMouth/A.swift"),
        ("a*", "b*"),
    ]

    def test_overlapping_patterns(self) -> None:
        for first, second in self.OVERLAPPING:
            with self.subTest(first=first, second=second):
                self.assertTrue(bbs.patterns_overlap(first, second))
                self.assertTrue(bbs.patterns_overlap(second, first))

    def test_separate_patterns(self) -> None:
        for first, second in self.SEPARATE:
            with self.subTest(first=first, second=second):
                self.assertFalse(bbs.patterns_overlap(first, second))
                self.assertFalse(bbs.patterns_overlap(second, first))

    def test_relative_paths_are_tidied(self) -> None:
        cases = {
            "./TextMouth/Views/A.swift": "TextMouth/Views/A.swift",
            "a//b": "a/b",
            "a/./b/../c": "a/c",
            "TextMouth/Views/": "TextMouth/Views/",
            "TextMouth/*/": "TextMouth/*/**",
            "TextMouth/**/": "TextMouth/**",
            ".": "**",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(bbs.normalize_pattern(raw), expected)

    def test_directories_on_disk_are_claimed_whole(self) -> None:
        tree = self.make_temp_dir()
        (tree / ".git").mkdir()
        (tree / "Sources" / "Views").mkdir(parents=True)
        (tree / "Sources" / "main.swift").write_text("")
        self.assertEqual(bbs.normalize_pattern("Sources/Views", tree), "Sources/Views/")
        self.assertEqual(bbs.normalize_pattern("Sources/main.swift", tree), "Sources/main.swift")
        self.assertEqual(bbs.normalize_pattern("Sources/New.swift", tree), "Sources/New.swift")

    def test_absolute_paths_become_relative_to_their_working_tree(self) -> None:
        root = self.make_temp_dir()
        (root / "main" / ".git").mkdir(parents=True)
        (root / "linked").mkdir()
        (root / "linked" / ".git").write_text("gitdir: ../main/.git/worktrees/linked\n")
        for tree in ("main", "linked"):
            with self.subTest(tree=tree):
                self.assertEqual(bbs.normalize_pattern(str(root / tree / "Sources" / "A.swift")), "Sources/A.swift")
                self.assertEqual(bbs.normalize_pattern(str(root / tree)), "**")
        outside = self.make_temp_dir() / "notes.txt"
        self.assertEqual(bbs.normalize_pattern(str(outside)), str(outside))

    def test_empty_and_escaping_paths_are_rejected(self) -> None:
        for raw in ("", "   ", "..", "../elsewhere", "a/../../b"):
            with self.subTest(raw=raw):
                with self.assertRaises(bbs.UserError):
                    bbs.normalize_pattern(raw)


class ClaimTests(BoardTestCase):
    """claim, release, claims, and register --files."""

    def test_claims_are_recorded_and_shown_by_agents(self) -> None:
        self.register("alpha")
        data = self.ok_json("claim", "alpha", "TextMouth/A.swift", "./TextMouth/B.swift", "TextMouth/A.swift")
        self.assertEqual(data["claims"], ["TextMouth/A.swift", "TextMouth/B.swift"])
        agent = self.ok_json("agents")[0]
        self.assertEqual(agent["claims"], ["TextMouth/A.swift", "TextMouth/B.swift"])
        self.assertIn("Claims: TextMouth/A.swift, TextMouth/B.swift", self.ok("agents"))

    def test_register_files_adds_claims_without_dropping_earlier_ones(self) -> None:
        self.register("alpha", "TextMouth/A.swift")
        self.ok("register", "alpha", "--files", "TextMouth/B.swift")
        self.assertEqual(self.ok_json("agents")[0]["claims"], ["TextMouth/A.swift", "TextMouth/B.swift"])

    def test_claims_flags_overlaps_between_agents_only(self) -> None:
        self.register("alpha", "TextMouth/Views/LibraryView.swift", "TextMouth/Views/*.swift")
        self.register("beta", "TextMouth/**/Library*.swift")
        self.register("gamma", "Docs/")
        data = self.ok_json("claims")
        self.assertEqual(len(data["claims"]), 4)
        pairs = {
            (overlap["first"]["agent"], overlap["first"]["pattern"], overlap["second"]["agent"])
            for overlap in data["overlaps"]
        }
        # alpha's two claims overlap each other too, but one agent never conflicts with itself.
        self.assertEqual(
            pairs,
            {
                ("alpha", "TextMouth/Views/LibraryView.swift", "beta"),
                ("alpha", "TextMouth/Views/*.swift", "beta"),
            },
        )
        text = self.ok("claims")
        self.assertIn("2 overlaps between agents:", text)
        self.assertIn("alpha claims TextMouth/Views/*.swift and beta claims TextMouth/**/Library*.swift", text)

    def test_claiming_reports_overlaps_with_other_agents(self) -> None:
        self.register("alpha", "TextMouth/Views/")
        text = self.ok("claim", "alpha", "Docs/README.md")
        self.assertIn("No overlaps with other agents' claims.", text)
        self.register("beta")
        text = self.ok("claim", "beta", "TextMouth/Views/LibraryView.swift")
        self.assertIn("beta claims TextMouth/Views/LibraryView.swift and alpha claims TextMouth/Views/", text)

    def test_claims_for_one_path_lists_who_covers_it(self) -> None:
        self.register("alpha", "TextMouth/Views/")
        self.register("beta", "TextMouth/**/*.swift")
        self.register("gamma", "Docs/")
        data = self.ok_json("claims", "TextMouth/Views/LibraryView.swift")
        self.assertEqual({claim["agent"] for claim in data["claims"]}, {"alpha", "beta"})
        self.assertEqual(len(data["overlaps"]), 1)
        self.assertIn("No agent claims Makefile.", self.ok("claims", "Makefile"))

    def test_release_by_path_or_all(self) -> None:
        self.register("alpha", "TextMouth/A.swift", "TextMouth/B.swift", "Docs/")
        data = self.ok_json("release", "alpha", "textmouth/a.swift", "Docs", "TextMouth/Missing.swift")
        self.assertEqual(data["released"], ["TextMouth/A.swift", "Docs/"])
        self.assertEqual(data["not_claimed"], ["TextMouth/Missing.swift"])
        self.assertEqual(data["claims"], ["TextMouth/B.swift"])
        self.assertEqual(self.ok_json("release", "alpha", "--all")["released"], ["TextMouth/B.swift"])
        self.assertEqual(self.ok_json("agents")[0]["claims"], [])

    def test_release_needs_paths_or_all_but_not_both(self) -> None:
        self.register("alpha", "TextMouth/A.swift")
        self.fails("release", "alpha")
        self.fails("release", "alpha", "TextMouth/A.swift", "--all")

    def test_claims_by_unknown_agents_are_rejected(self) -> None:
        self.assertIn("unknown agent 'nobody'", self.fails("claim", "nobody", "TextMouth/A.swift"))
        self.assertIn("unknown agent 'nobody'", self.fails("release", "nobody", "--all"))

    def test_paths_resolve_against_the_working_tree(self) -> None:
        (self.worktree / "TextMouth" / "Views").mkdir(parents=True)
        self.register("alpha")
        absolute = str(self.worktree / "TextMouth" / "Library.swift")
        data = self.ok_json("claim", "alpha", absolute, "TextMouth/Views")
        self.assertEqual(data["claims"], ["TextMouth/Library.swift", "TextMouth/Views/"])


class SinceTests(unittest.TestCase):
    """parse_since, the --since option shared by read and inbox."""

    def test_a_whole_number_is_a_message_id(self) -> None:
        self.assertEqual(bbs.parse_since("17"), bbs.Since(message_id=17))

    def test_times_with_a_zone_are_converted_to_utc(self) -> None:
        self.assertEqual(bbs.parse_since("2026-10-02T12:30Z").moment, "2026-10-02T12:30:00Z")
        self.assertEqual(bbs.parse_since("2026-10-02 14:30:15+02:00").moment, "2026-10-02T12:30:15Z")

    def test_times_without_a_zone_are_local(self) -> None:
        local_midnight = dt.datetime(2026, 10, 2).astimezone()
        self.assertEqual(bbs.parse_since("2026-10-02").moment, bbs.to_utc_text(local_midnight))
        today_at = dt.datetime.combine(dt.date.today(), dt.time(12, 30)).astimezone()
        self.assertEqual(bbs.parse_since("12:30").moment, bbs.to_utc_text(today_at))

    def test_other_text_is_rejected(self) -> None:
        for text in ("yesterday", "", "12:75", "-3"):
            with self.subTest(text=text):
                with self.assertRaises(argparse.ArgumentTypeError):
                    bbs.parse_since(text)


class PostingTests(BoardTestCase):
    """post and read: putting messages on the board and the public log."""

    def setUp(self) -> None:
        """Register alpha, who claims TextMouth/Services/, and beta."""
        super().setUp()
        self.register("alpha", "TextMouth/Services/")
        self.register("beta")

    def post(self, *args: str, stdin: str = "") -> dict:
        """Post a message and return it as stored."""
        return self.ok_json("post", *args, stdin=stdin)

    def test_a_post_is_stored_whole_and_goes_to_all_by_default(self) -> None:
        message = self.post(
            "beta", "--tag", "finding", "--topic", "Leaky  parser",
            "--file", "TextMouth/Services/DOCXParser.swift", "--file", "./TextMouth/Services/Zip.swift",
            "--body", "line one\nline two\n\n",
        )
        self.assertEqual(message["id"], 1)
        self.assertEqual((message["from"], message["to"], message["tag"]), ("beta", "all", "finding"))
        self.assertEqual(message["topic"], "Leaky parser")
        self.assertEqual(message["body"], "line one\nline two")
        self.assertEqual(message["files"], ["TextMouth/Services/DOCXParser.swift", "TextMouth/Services/Zip.swift"])
        self.assertIsNone(message["reply_to"])
        self.assertRegex(message["posted"], UTC_TEXT)
        self.assertEqual(message["claimed_by"], [{"agent": "alpha", "pattern": "TextMouth/Services/"}])
        self.assertEqual([m["id"] for m in self.ok_json("read")], [1])

    def test_a_post_can_be_addressed_to_one_agent(self) -> None:
        self.assertEqual(self.post("alpha", "--to", "BETA", "--topic", "hello")["to"], "beta")
        self.assertEqual(self.post("alpha", "--to", "All", "--topic", "hello")["to"], "all")

    def test_bad_senders_and_recipients_are_rejected(self) -> None:
        self.assertIn("register gamma --role", self.fails("post", "gamma", "--topic", "x"))
        self.assertIn("did you mean 'beta'", self.fails("post", "alpha", "--to", "bet", "--topic", "x"))
        self.assertIn("reaches nobody", self.fails("post", "alpha", "--to", "alpha", "--topic", "x"))
        self.fails("post", "alpha", "--topic", "x", "--tag", "bild")
        self.assertEqual(self.ok_json("read"), [])

    def test_a_topic_is_required(self) -> None:
        self.assertIn("needs --topic", self.fails("post", "alpha", "--body", "no topic"))

    def test_the_body_may_come_from_standard_input_or_a_file(self) -> None:
        self.assertEqual(self.post("alpha", "--topic", "x", "--body-file", "-", stdin="\n\nfrom stdin\n")["body"], "from stdin")
        (self.worktree / "note.txt").write_text("from a file\n")
        self.assertEqual(self.post("alpha", "--topic", "x", "--body-file", "note.txt")["body"], "from a file")
        self.fails("post", "alpha", "--topic", "x", "--body-file", "missing.txt")
        self.fails("post", "alpha", "--topic", "x", "--body", "both", "--body-file", "-")

    def test_bodies_are_limited_to_16_kb(self) -> None:
        exactly = "é" * (16 * 1024 // 2)  # two bytes each in UTF-8
        self.assertEqual(self.post("alpha", "--topic", "x", "--body", exactly)["body"], exactly)
        message = self.fails("post", "alpha", "--topic", "x", "--body", "x" * (16 * 1024 + 1))
        self.assertIn("16,385 bytes", message)
        self.assertEqual(len(self.ok_json("read")), 1)

    def test_ids_increase_with_every_post(self) -> None:
        ids = [self.post("alpha", "--topic", f"post {n}")["id"] for n in range(5)]
        self.assertEqual(ids, [1, 2, 3, 4, 5])

    def test_read_filters_by_since_tag_and_sender(self) -> None:
        self.post("alpha", "--topic", "one", "--tag", "build")
        self.post("beta", "--topic", "two", "--tag", "commit")
        self.post("alpha", "--topic", "three", "--tag", "commit")

        def topics(*args: str) -> List[str]:
            """Topics of the messages `read` shows with these options."""
            return [message["topic"] for message in self.ok_json("read", *args)]

        self.assertEqual(topics("--since", "1"), ["two", "three"])
        self.assertEqual(topics("--tag", "commit"), ["two", "three"])
        self.assertEqual(topics("--from", "Alpha"), ["one", "three"])
        self.assertEqual(topics("--from", "alpha", "--tag", "commit"), ["three"])
        self.assertIn("No messages match.", self.ok("read", "--tag", "merge"))

    def test_read_since_a_time(self) -> None:
        with self.clock(NOON):
            self.post("alpha", "--topic", "at noon")
        with self.clock(NOON + dt.timedelta(hours=1)):
            self.post("alpha", "--topic", "an hour later")
        half_past_local = (NOON + dt.timedelta(minutes=30)).astimezone().strftime("%Y-%m-%dT%H:%M")
        for since in ("2026-10-02T12:30Z", half_past_local):
            with self.subTest(since=since):
                self.assertEqual([m["topic"] for m in self.ok_json("read", "--since", since)], ["an hour later"])

    def test_read_shows_the_last_twenty_unless_asked_otherwise(self) -> None:
        for number in range(25):
            self.post("alpha", "--topic", f"post {number}")
        self.assertEqual([m["id"] for m in self.ok_json("read")], list(range(6, 26)))
        self.assertIn("The last 20 of 25 messages", self.ok("read"))
        self.assertEqual([m["id"] for m in self.ok_json("read", "--last", "3")], [23, 24, 25])
        self.assertEqual(len(self.ok_json("read", "--since", "2")), 23, "--since shows everything after the id")

    def test_read_text_shows_each_message(self) -> None:
        self.post("beta", "--tag", "finding", "--topic", "Leaky", "--file", "TextMouth/Services/A.swift", "--body", "Details\nhere")
        text = self.ok("read")
        self.assertIn("#1 finding from beta to all, ", text)
        self.assertIn(": Leaky\n  Files: TextMouth/Services/A.swift\n  Details\n  here", text)


class ThreadTests(BoardTestCase):
    """Replies (post --reply-to) and thread."""

    def setUp(self) -> None:
        """Register alpha and beta."""
        super().setUp()
        self.register("alpha")
        self.register("beta")

    def post(self, *args: str) -> dict:
        """Post a message and return it as stored."""
        return self.ok_json("post", *args)

    def test_a_reply_goes_back_to_the_author_under_the_same_topic(self) -> None:
        self.post("alpha", "--to", "beta", "--tag", "question", "--topic", "Merge order?")
        answer = self.post("beta", "--reply-to", "1", "--body", "After T07.")
        self.assertEqual((answer["to"], answer["topic"], answer["reply_to"]), ("alpha", "Re: Merge order?", 1))
        follow_up = self.post("alpha", "--reply-to", "2", "--body", "Will do.")
        self.assertEqual((follow_up["to"], follow_up["topic"]), ("beta", "Re: Merge order?"))
        own = self.post("alpha", "--reply-to", "3", "--body", "Done.")
        self.assertEqual(own["to"], "beta", "answering yourself reaches whoever you wrote to")
        self.assertEqual(self.post("beta", "--reply-to", "1", "--to", "all", "--topic", "FYI")["to"], "all")

    def test_thread_shows_the_whole_conversation_from_any_of_its_messages(self) -> None:
        self.post("alpha", "--topic", "root")  # 1
        self.post("beta", "--reply-to", "1")  # 2
        self.post("alpha", "--reply-to", "2")  # 3
        self.post("beta", "--topic", "unrelated")  # 4
        self.post("beta", "--reply-to", "1")  # 5
        for start in ("1", "3", "5"):
            with self.subTest(start=start):
                self.assertEqual([m["id"] for m in self.ok_json("thread", start)], [1, 2, 3, 5])
        self.assertEqual([m["id"] for m in self.ok_json("thread", "4")], [4])
        self.assertIn("Thread #1, 4 messages:", self.ok("thread", "3"))

    def test_missing_messages_are_errors(self) -> None:
        self.assertIn("no message #9", self.fails("post", "alpha", "--reply-to", "9", "--body", "x"))
        self.assertIn("no message #9", self.fails("thread", "9"))


class InboxTests(BoardTestCase):
    """inbox: the messages that concern one agent, and read marks."""

    def setUp(self) -> None:
        """Register alpha (claiming a directory and a glob), beta, and gamma."""
        super().setUp()
        self.register("alpha", "TextMouth/Views/", "TextMouth/**/Library*.swift")
        self.register("beta")
        self.register("gamma")

    def post(self, sender: str, *args: str) -> int:
        """Post a message with a stock topic and return its id."""
        return self.ok_json("post", sender, "--topic", "news", *args)["id"]

    def inbox_ids(self, *args: str) -> List[int]:
        """Ids of the messages alpha's inbox shows with these options."""
        return [message["id"] for message in self.ok_json("inbox", "alpha", *args)]

    def test_the_inbox_holds_messages_to_the_agent_to_all_and_about_its_files(self) -> None:
        to_alpha = self.post("beta", "--to", "alpha")
        to_all = self.post("beta")
        self.post("beta", "--to", "gamma")
        under_directory = self.post("beta", "--to", "gamma", "--file", "TextMouth/Views/LibraryView.swift")
        under_glob = self.post("gamma", "--to", "beta", "--file", "TextMouth/Models/LibraryItem.swift")
        elsewhere = self.post("gamma", "--to", "beta", "--file", "Docs/README.md")
        self.post("alpha", "--to", "all")  # an agent's own posts never reach its inbox
        self.assertEqual(self.inbox_ids("--peek"), [to_alpha, to_all, under_directory, under_glob])
        # Claims count as they are when the inbox is read, not when the post was made.
        self.ok("claim", "alpha", "Docs/")
        self.assertIn(elsewhere, self.inbox_ids("--peek"))

    def test_the_inbox_marks_what_it_shows_as_read(self) -> None:
        first = self.post("beta", "--to", "alpha")
        self.assertEqual([(m["id"], m["unread"]) for m in self.ok_json("inbox", "alpha")], [(first, True)])
        self.assertEqual(self.inbox_ids("--unread"), [])
        self.assertEqual([(m["id"], m["unread"]) for m in self.ok_json("inbox", "alpha")], [(first, False)])
        second = self.post("beta")
        self.assertEqual(self.inbox_ids("--unread"), [second])

    def test_peek_leaves_messages_unread(self) -> None:
        message = self.post("beta", "--to", "alpha")
        self.assertEqual(self.inbox_ids("--unread", "--peek"), [message])
        self.assertEqual(self.inbox_ids("--unread", "--peek"), [message])
        self.assertEqual(self.inbox_ids("--unread"), [message])
        self.assertEqual(self.inbox_ids("--unread"), [])

    def test_read_marks_are_kept_for_each_agent(self) -> None:
        message = self.post("gamma")
        self.ok("inbox", "alpha")
        self.assertEqual([m["id"] for m in self.ok_json("inbox", "beta", "--unread")], [message])

    def test_filters_choose_which_messages_are_shown_and_marked(self) -> None:
        build = self.post("beta", "--tag", "build")
        commit = self.post("beta", "--tag", "commit")
        later = self.post("beta", "--tag", "commit")
        self.assertEqual(self.inbox_ids("--unread", "--tag", "commit", "--last", "1"), [later])
        self.assertEqual(self.inbox_ids("--unread", "--since", str(build)), [commit])
        self.assertEqual(self.inbox_ids("--unread"), [build])

    def test_the_text_flags_unread_messages(self) -> None:
        self.post("beta", "--to", "alpha")
        self.ok("inbox", "alpha")
        self.post("beta")
        text = self.ok("inbox", "alpha")
        self.assertIn("2 messages for alpha, 1 unread:", text)
        self.assertIn("#2 (unread) notice from beta to all", text)
        self.assertNotIn("#1 (unread)", text)
        self.assertIn("No unread messages for alpha.", self.ok("inbox", "alpha", "--unread"))

    def test_register_and_heartbeat_mention_unread_messages(self) -> None:
        self.post("beta", "--to", "alpha")
        self.assertIn("Unread messages for alpha: 1. Run: bbs.py inbox alpha --unread", self.ok("heartbeat", "alpha"))
        self.assertEqual(self.ok_json("register", "alpha")["unread"], 1)
        self.ok("inbox", "alpha")
        self.assertEqual(self.ok_json("heartbeat", "alpha")["unread"], 0)
        self.assertNotIn("Unread", self.ok("heartbeat", "alpha"))

    def test_an_unknown_agent_has_no_inbox(self) -> None:
        self.assertIn("unknown agent 'delta'", self.fails("inbox", "delta"))

    def test_a_newcomer_gets_findings_about_its_files_but_not_old_traffic(self) -> None:
        with self.clock(NOON):
            self.post("beta", "--tag", "build", "--topic", "old notice for everyone")
            finding = self.post("beta", "--tag", "finding", "--file", "TextMouth/Audio/Player.swift")
        with self.clock(NOON + dt.timedelta(minutes=5)):
            self.register("delta", "TextMouth/Audio/")
            self.assertEqual([m["id"] for m in self.ok_json("inbox", "delta", "--peek")], [finding])
            fresh = self.post("beta", "--topic", "new notice for everyone")
        with self.clock(NOON + dt.timedelta(minutes=9)):
            self.ok("register", "delta", "--role", "a new role")  # re-registering keeps the start
            self.assertEqual([m["id"] for m in self.ok_json("inbox", "delta")], [finding, fresh])
        self.assertEqual(len(self.ok_json("read")), 3, "the public log still holds everything")


class WatchTests(BoardTestCase):
    """watch: waiting for messages, and its exit statuses."""

    def setUp(self) -> None:
        """Register alpha and beta."""
        super().setUp()
        self.register("alpha")
        self.register("beta")

    def test_once_exits_0_silently_when_nothing_is_unread(self) -> None:
        self.assertEqual(self.run_bbs("watch", "alpha", "--once"), (0, "", ""))

    def test_once_exits_2_with_unread_messages_and_marks_them_read(self) -> None:
        self.ok("post", "beta", "--to", "alpha", "--topic", "Heads up", "--body", "Rebasing now.")
        status, out, err = self.run_bbs("watch", "alpha", "--once")
        self.assertEqual((status, err), (2, ""))
        self.assertIn("#1 notice from beta to alpha", out)
        self.assertIn("Rebasing now.", out)
        self.assertEqual(self.run_bbs("watch", "alpha", "--once"), (0, "", ""))

    def test_once_with_peek_leaves_messages_unread(self) -> None:
        self.ok("post", "beta", "--topic", "For everyone")
        self.assertEqual(self.run_bbs("watch", "alpha", "--once", "--peek")[0], 2)
        self.assertEqual(self.run_bbs("watch", "alpha", "--once", "--peek")[0], 2)
        self.assertEqual([m["id"] for m in self.ok_json("inbox", "alpha", "--unread")], [1])

    def test_once_with_json_prints_an_array(self) -> None:
        self.assertEqual(self.run_bbs("watch", "alpha", "--once", "--json"), (0, "[]\n", ""))
        self.ok("post", "beta", "--topic", "For everyone")
        status, out, _ = self.run_bbs("watch", "alpha", "--once", "--json")
        self.assertEqual(status, 2)
        self.assertEqual([m["topic"] for m in json.loads(out)], ["For everyone"])

    def test_watching_stops_quietly_after_the_timeout(self) -> None:
        started = dt.datetime.now()
        self.assertEqual(self.run_bbs("watch", "alpha", "--interval", "0.1", "--timeout", "0.3"), (0, "", ""))
        self.assertGreaterEqual((dt.datetime.now() - started).total_seconds(), 0.3)

    def test_watching_prints_messages_as_they_arrive(self) -> None:
        self.ok("post", "beta", "--to", "alpha", "--topic", "before")
        watcher = subprocess.Popen(
            [sys.executable, str(SCRIPT), "watch", "alpha", "--interval", "0.1", "--timeout", "3", "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            first = json.loads(watcher.stdout.readline())  # the message already waiting
            self.ok("post", "beta", "--topic", "after")
            second = json.loads(watcher.stdout.readline())
            rest, errors = watcher.communicate(timeout=30)
        finally:
            if watcher.poll() is None:
                watcher.kill()
                watcher.wait()
        self.assertEqual([first["topic"], second["topic"]], ["before", "after"])
        self.assertEqual((rest, errors, watcher.returncode), ("", "", 2))
        self.assertEqual(self.ok_json("inbox", "alpha", "--unread"), [], "printed messages are marked read")

    def test_watch_rejects_bad_durations_and_unknown_agents(self) -> None:
        for option, value in (("--interval", "0"), ("--timeout", "-1"), ("--interval", "nan"), ("--timeout", "inf")):
            with self.subTest(option=option, value=value):
                self.fails("watch", "alpha", option, value)
        self.assertIn("unknown agent", self.fails("watch", "nobody", "--once"))


class HousekeepingTests(BoardTestCase):
    """purge and reset."""

    def count_rows(self, table: str) -> int:
        """Count the rows of one board table, read straight from the file."""
        with contextlib.closing(sqlite3.connect(str(self.board_dir / "board.sqlite"))) as conn:
            return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def test_purge_deletes_old_messages_and_agents_with_what_belongs_to_them(self) -> None:
        with self.clock(NOON - dt.timedelta(days=5)):
            self.register("gone", "TextMouth/Old.swift")
            self.register("alpha")
            self.ok("post", "alpha", "--topic", "old news", "--file", "TextMouth/Old.swift")
            self.ok("inbox", "gone")
        with self.clock(NOON - dt.timedelta(hours=1)):
            self.ok("heartbeat", "alpha")
            self.ok("post", "alpha", "--topic", "recent", "--reply-to", "1")
        with self.clock(NOON):
            data = self.ok_json("purge", "--older-than", "2")
        self.assertEqual((data["messages"], data["agents"]), (1, 1))
        self.assertEqual([m["topic"] for m in self.ok_json("read")], ["recent"])
        self.assertEqual([a["name"] for a in self.ok_json("agents")], ["alpha"])
        for table in ("claims", "message_files", "reads"):
            with self.subTest(table=table):
                self.assertEqual(self.count_rows(table), 0, "rows belonging to purged messages and agents go too")
        self.assertIn("(it answers #1, which was purged)", self.ok("thread", "2"))

    def test_ids_keep_increasing_after_a_purge(self) -> None:
        self.register("alpha")
        with self.clock(NOON - dt.timedelta(days=3)):
            for number in range(3):
                self.ok("post", "alpha", "--topic", f"old {number}")
        with self.clock(NOON):
            self.ok("heartbeat", "alpha")
            self.assertIn("Purged 3 messages and 0 agents older than 1 day.", self.ok("purge", "--older-than", "1"))
            self.assertEqual(self.ok_json("post", "alpha", "--topic", "new")["id"], 4)

    def test_purge_needs_a_positive_age(self) -> None:
        self.fails("purge")
        self.fails("purge", "--older-than", "0")
        self.fails("purge", "--older-than", "-2")

    def test_reset_needs_yes_and_then_empties_the_board(self) -> None:
        self.register("alpha", "TextMouth/A.swift")
        self.ok("post", "alpha", "--topic", "hello")
        self.assertIn("add --yes to confirm", self.fails("reset"))
        self.assertEqual(len(self.ok_json("agents")), 1, "nothing is deleted without --yes")
        self.assertEqual(self.ok_json("reset", "--yes"), {"agents": 1, "claims": 1, "messages": 1})
        self.assertEqual((self.ok_json("agents"), self.ok_json("read")), ([], []))
        self.register("alpha")
        self.assertEqual(self.ok_json("post", "alpha", "--topic", "again")["id"], 2, "ids are never reused")


class SkillDocumentTests(BoardTestCase):
    """SKILL.md, and the protocol that `bbs.py protocol` prints from it."""

    DOCUMENT = SKILL_DIR / "SKILL.md"

    def test_protocol_prints_the_protocol_section_of_the_skill(self) -> None:
        text = self.ok("protocol").strip()
        self.assertIn(text, self.DOCUMENT.read_text(encoding="utf-8"))
        self.assertNotIn("<!--", text)
        for step in (
            "bbs register NAME --role",
            "bbs inbox NAME --unread",
            "before every build, before every commit, and before your final report",
            "--tag build",
            "--tag commit",
            "--tag finding --file",
            "--tag question",
            "bbs release NAME --all",
            "--tag notice",
            "not reports",
        ):
            self.assertIn(step, text)
        self.assertFalse(self.board_dir.exists(), "printing the protocol needs no board")

    def test_protocol_as_json(self) -> None:
        self.assertEqual(self.ok_json("protocol"), {"protocol": self.ok("protocol").strip()})

    def test_the_front_matter_names_and_describes_the_skill(self) -> None:
        lines = self.DOCUMENT.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "---")
        fields = dict(line.split(": ", 1) for line in lines[1 : lines.index("---", 1)])
        self.assertEqual(set(fields), {"name", "description"})
        self.assertEqual(fields["name"], "agent-bbs")
        self.assertNotIn(": ", fields["description"], "a plain YAML value cannot hold ': '")

    def test_every_documented_command_exists(self) -> None:
        documented = set(re.findall(r"\bbbs ([a-z]+)\b", self.DOCUMENT.read_text(encoding="utf-8")))
        self.assertGreaterEqual(len(documented), 15)
        for name in sorted(documented):
            with self.subTest(command=name):
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_info:
                    bbs.main([name, "--help"])
                self.assertEqual(exit_info.exception.code, 0)


class BuildSlotWrapperTests(BoardTestCase):
    """scripts/build-slot-with-bbs.sh, run against a scratch slot directory."""

    WRAPPER = SCRIPTS_DIR / "build-slot-with-bbs.sh"

    def setUp(self) -> None:
        """Give the wrapper its own slot directory, never the real one."""
        super().setUp()
        self.slot_root = self.make_temp_dir() / "slots"

    def run_wrapper(self, *command: str, agent: str = "") -> subprocess.CompletedProcess:
        """Run the wrapper around ``command``, as ``agent`` if one is named."""
        env = dict(os.environ, BUILD_SLOT_ROOT=str(self.slot_root))
        env.pop("BBS_AGENT", None)
        if agent:
            env["BBS_AGENT"] = agent
        return subprocess.run(
            ["bash", str(self.WRAPPER), *command], env=env, capture_output=True, text=True, timeout=120
        )

    def test_without_an_agent_it_only_holds_a_slot(self) -> None:
        result = self.run_wrapper("sh", "-c", 'ls "$BUILD_SLOT_ROOT"; echo built; exit 3')
        self.assertEqual(result.returncode, 3, "the command's exit status passes through")
        self.assertEqual(result.stdout, "slot1\nbuilt\n", "the slot is held while the command runs")
        self.assertIn("[build-slot] acquired slot1 at", result.stderr)
        self.assertNotIn("board", result.stderr)
        self.assertEqual(list(self.slot_root.iterdir()), [], "the slot is released afterwards")
        self.assertFalse(self.board_dir.exists(), "no board hooks run without BBS_AGENT")

    def test_with_an_agent_it_shows_unread_messages_and_reports_building(self) -> None:
        self.register("alpha")
        self.register("beta")
        self.ok("post", "beta", "--to", "alpha", "--topic", "Hold off", "--body", "Merging main now.")
        probe = f'"{sys.executable}" "{SCRIPT}" agents --json'
        result = self.run_wrapper("sh", "-c", probe, agent="alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        during = {agent["name"]: agent for agent in json.loads(result.stdout)}["alpha"]
        self.assertEqual(during["activity"], "building")
        self.assertTrue(during["activity_note"].startswith(f'sh -c "{sys.executable}"'), during["activity_note"])
        self.assertLessEqual(len(during["activity_note"]), 180, "a long command is cut to fit the note")
        self.assertIn("unread board messages for alpha", result.stderr)
        self.assertIn("#1 notice from beta to alpha", result.stderr)
        self.assertLess(result.stderr.index("Hold off"), result.stderr.index("acquired"))
        after = {agent["name"]: agent for agent in self.ok_json("agents")}["alpha"]
        self.assertEqual((after["activity"], after["activity_note"]), ("idle", ""))
        self.assertEqual([m["id"] for m in self.ok_json("inbox", "alpha", "--unread")], [1], "messages stay unread")

    def test_a_board_problem_never_stops_the_build(self) -> None:
        result = self.run_wrapper("sh", "-c", "echo built", agent="ghost")
        self.assertEqual((result.returncode, result.stdout), (0, "built\n"))
        self.assertEqual(result.stderr.count("unknown agent 'ghost'"), 1, "the board error is shown once")
        self.assertEqual(list(self.slot_root.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "the slot lock reads ages with BSD stat")
    def test_a_live_owners_slot_is_skipped_and_a_dead_owners_is_reclaimed(self) -> None:
        live, dead = self.slot_root / "slot1", self.slot_root / "slot2"
        for slot, owner in ((live, os.getpid()), (dead, 999999)):
            slot.mkdir(parents=True)
            (slot / "pid").write_text(f"{owner}\n")
        result = self.run_wrapper("true")
        self.assertIn("acquired slot3", result.stderr)
        self.assertTrue(live.exists(), "a slot whose owner is alive stays held")
        self.assertFalse(dead.exists(), "a slot whose owner died is reclaimed")


class TransactionTests(BoardTestCase):
    """write_transaction, which every change to the board goes through."""

    def test_an_error_rolls_the_whole_block_back(self) -> None:
        self.register("alpha")
        with contextlib.closing(bbs.open_board()) as conn:
            with self.assertRaises(RuntimeError):
                with bbs.write_transaction(conn):
                    conn.execute("UPDATE agents SET role = 'changed'")
                    raise RuntimeError("stop halfway")
        self.assertEqual(self.ok_json("agents")[0]["role"], "alpha work")

    def test_a_transaction_sqlite_already_ended_keeps_the_original_error(self) -> None:
        with contextlib.closing(bbs.open_board()) as conn:
            with self.assertRaisesRegex(RuntimeError, "the original error"):
                with bbs.write_transaction(conn):
                    conn.execute("ROLLBACK")  # as SQLite does by itself after some failures
                    raise RuntimeError("the original error")


class ConcurrencyTests(BoardTestCase):
    """Several processes using the board at the same moment."""

    def run_in_parallel(self, command_lists: List[List[List[str]]]) -> List[List[Tuple[int, str, str]]]:
        """Run each list of commands in its own process, all started at once.

        Returns each process's outcomes, in the order the lists were given.
        """
        context = multiprocessing.get_context("spawn")
        start, results = context.Event(), context.Queue()
        workers = [
            context.Process(
                target=run_in_worker,
                args=(label, str(self.board_dir), str(self.worktree), commands, start, results),
            )
            for label, commands in enumerate(command_lists)
        ]
        for worker in workers:
            worker.start()
        start.set()
        reported = dict(results.get(timeout=120) for _ in workers)
        for worker in workers:
            worker.join(timeout=60)
            self.assertEqual(worker.exitcode, 0)
        return [reported[label] for label in range(len(workers))]

    def test_parallel_posters_get_unique_increasing_ids(self) -> None:
        posters, per_poster = [f"poster{n}" for n in range(6)], 15
        for name in posters:
            self.register(name)
        outcomes = self.run_in_parallel(
            [[["post", name, "--topic", f"{name} {n}", "--json"] for n in range(per_poster)] for name in posters]
        )
        all_ids = []
        for name, results in zip(posters, outcomes):
            for status, out, err in results:
                self.assertEqual((status, err), (0, ""), f"{name}: {err}")
            ids = [json.loads(out)["id"] for _, out, _ in results]
            self.assertEqual(ids, sorted(ids), f"{name}'s posts must get increasing ids")
            all_ids += ids
        total = len(posters) * per_poster
        self.assertEqual(sorted(all_ids), list(range(1, total + 1)), "every post is stored once with a unique id")
        stored = self.ok_json("read", "--since", "0")
        self.assertEqual([m["id"] for m in stored], list(range(1, total + 1)))
        for name in posters:
            numbers = [int(m["topic"].split()[1]) for m in stored if m["from"] == name]
            self.assertEqual(numbers, list(range(per_poster)), f"{name}'s posts are stored in the order sent")

    def test_parallel_first_use_creates_one_shared_board(self) -> None:
        self.assertFalse(self.board_dir.exists())
        names = [f"agent{n}" for n in range(6)]
        outcomes = self.run_in_parallel([[["register", name, "--role", "r", "--branch", "b"]] for name in names])
        for (status, _, err), in outcomes:
            self.assertEqual((status, err), (0, ""))
        self.assertEqual([agent["name"] for agent in self.ok_json("agents")], names)
        with contextlib.closing(sqlite3.connect(str(self.board_dir / "board.sqlite"))) as conn:
            self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0], "wal")


class RepositoryDiscoveryTests(TemporaryDirectoryTestCase):
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
