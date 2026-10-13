#!/usr/bin/env python3
"""Message board (BBS) for coding agents working in one repository at once.

Several agents work on this repository concurrently, each in its own git
worktree on its own branch. The board lets them register, say which files
they are editing, post short notices about builds, commits, findings and
questions, and read what concerns them. It is one SQLite file that every
worktree shares:

* ``$TEXTMOUTH_BBS_DIR/board.sqlite`` when that variable is set;
* otherwise ``.claude/agent-bbs/board.sqlite`` in the main working tree of
  the repository that contains the current directory. A linked worktree's
  ``.git`` file is followed back to the repository that owns it, so every
  worktree finds the same board.

Each command prints readable text, or JSON with ``--json``. The exit status
is 0 on success, 1 on a user error (reported as one line on standard
error), and 2 when ``watch`` printed messages. Only the Python standard
library is used: no network, no daemons, no third-party packages.

Run ``bbs.py --help`` or ``bbs.py COMMAND --help`` for the commands.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import difflib
import fnmatch
import functools
import json
import math
import os
import posixpath
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, FrozenSet, Iterable, Iterator, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Program name used in messages and help.
PROG = "bbs.py"

#: Environment variable that chooses the board directory explicitly.
BOARD_DIR_ENV = "TEXTMOUTH_BBS_DIR"

#: Board directory inside the main working tree when no override is set.
DEFAULT_BOARD_SUBDIR = Path(".claude") / "agent-bbs"

#: File name of the board database inside the board directory.
BOARD_FILENAME = "board.sqlite"

#: Version of the base table layout, kept in SQLite's user_version header field.
#: Scripts from before teams refuse a board whose version is higher than theirs,
#: so additive changes never raise it: SCHEMA_ADDITIONS applies them instead.
SCHEMA_VERSION = 1

#: Seconds a command waits for another process's write before giving up.
BUSY_TIMEOUT_SECONDS = 30.0

#: Recipient name that addresses every agent; no agent may register it.
EVERYONE = "all"

#: Prefix that turns a team's name into the address of its channel, as in "team:board".
TEAM_PREFIX = "team:"

#: Agent names: lower-case letters, digits, '.', '_' and '-', at most 40.
NAME_RULE = re.compile(r"[a-z0-9][a-z0-9._-]{0,39}")

#: Longest accepted one-line field (role, branch, topic, activity note).
MAX_LINE_LENGTH = 200

#: Kinds of message; `notice` is the default. `task` marks the lines the board
#: posts to a team's channel when a task changes.
TAGS = ("build", "commit", "finding", "question", "notice", "merge", "task")

#: What an agent can say it is doing; shown by `agents`.
ACTIVITIES = ("building", "testing", "committing", "idle", "merging")

#: A task's states, in the order of its life: `open` (no one has it yet), then
#: `assigned`, `working`, and `review`, ending `done` or `dropped`.
TASK_STATES = ("open", "assigned", "working", "review", "done", "dropped")

#: Largest accepted message body, in bytes of UTF-8 (16 KB).
MAX_BODY_BYTES = 16 * 1024

#: How many messages `read` shows when neither --last nor --since is given.
DEFAULT_READ_COUNT = 20

#: Seconds between checks when `watch` waits for new messages.
DEFAULT_WATCH_INTERVAL = 5.0

#: Exit statuses.
EXIT_OK = 0
EXIT_USER_ERROR = 1
EXIT_HAS_MESSAGES = 2  # `watch` printed at least one message

#: Stored times are UTC ISO 8601 text to the second, so they sort as text.
UTC_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


# ---------------------------------------------------------------------------
# Results and errors
# ---------------------------------------------------------------------------


class UserError(Exception):
    """A mistake the caller can fix; reported as one line with exit status 1."""


@dataclasses.dataclass
class Outcome:
    """What a command produced.

    ``data`` is printed as JSON under ``--json`` and ``text`` otherwise;
    ``code`` becomes the exit status. ``printed`` means the command already
    wrote its output as it went, so there is nothing left to print.
    """

    data: Any
    text: str
    code: int = EXIT_OK
    printed: bool = False


# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------


def utc_now() -> dt.datetime:
    """Return the current time as an aware UTC datetime, to the second."""
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def to_utc_text(moment: dt.datetime) -> str:
    """Format an aware datetime the way the board stores times."""
    return moment.astimezone(dt.timezone.utc).strftime(UTC_FORMAT)


def from_utc_text(text: str) -> dt.datetime:
    """Parse a stored board time back into an aware UTC datetime."""
    return dt.datetime.strptime(text, UTC_FORMAT).replace(tzinfo=dt.timezone.utc)


def local_label(text: str) -> str:
    """Show a stored time in local time, as briefly as stays unambiguous.

    Today's times read "14:05", earlier ones this year "Oct 1 14:05", and
    older ones "2025-10-01 14:05".
    """
    moment = from_utc_text(text).astimezone()
    today = dt.datetime.now().astimezone().date()
    clock = moment.strftime("%H:%M")
    if moment.date() == today:
        return clock
    if moment.year == today.year:
        return f"{moment.strftime('%b')} {moment.day} {clock}"
    return f"{moment.strftime('%Y-%m-%d')} {clock}"


def ago_label(text: str) -> str:
    """Say in words how long ago a stored time was, such as "3 minutes ago"."""
    seconds = (utc_now() - from_utc_text(text)).total_seconds()
    if seconds < 60:
        # Includes small negative gaps from clocks that disagree slightly.
        return "just now"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{plural(minutes, 'minute')} ago"
    hours = minutes // 60
    if hours < 24:
        return f"{plural(hours, 'hour')} ago"
    return f"{plural(hours // 24, 'day')} ago"


def plural(count: int, noun: str) -> str:
    """Return "1 agent" or "3 agents" (regular plurals only)."""
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


@dataclasses.dataclass(frozen=True)
class Since:
    """A parsed --since value: after a message id, or from a moment on."""

    message_id: Optional[int] = None
    moment: Optional[str] = None  # UTC text

    def condition(self) -> Tuple[str, Any]:
        """Return the SQL condition on messages (alias m) and its parameter."""
        if self.message_id is not None:
            return "m.id > ?", self.message_id
        return "m.posted_at >= ?", self.moment


def parse_since(text: str) -> Since:
    """argparse type for --since: a message id, or a date and time.

    A whole number is a message id and selects the messages after it.
    Anything else is a moment and selects messages posted at or after it:
    an ISO 8601 date and time ("2026-10-02T14:05", "2026-10-02 14:05Z"), a
    date (its midnight), or a time of day ("14:05", today). A moment with
    no time zone is local time.
    """
    value = text.strip()
    if value.isdigit():
        return Since(message_id=int(value))
    if value.endswith(("Z", "z")):
        value = value[:-1] + "+00:00"  # Python before 3.11 does not read "Z"
    try:
        try:
            moment = dt.datetime.fromisoformat(value)
        except ValueError:
            moment = dt.datetime.combine(dt.date.today(), dt.time.fromisoformat(value))
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"expected a message id or an ISO date and time such as 2026-10-02T14:05, got {text!r}"
        ) from None
    if moment.tzinfo is None:
        moment = moment.astimezone()  # a naive moment is local time
    return Since(moment=to_utc_text(moment))


# ---------------------------------------------------------------------------
# Field validation
# ---------------------------------------------------------------------------


def normalize_name(raw: str, kind: str = "agent") -> str:
    """Return the canonical form of an agent or team name, or raise UserError.

    ``kind`` is "agent" or "team" and only shapes the error messages; both
    follow the same rule. Names are case-insensitive: they are stored and
    shown in lower case, so "Orchestrator" and "orchestrator" are the same
    agent.
    """
    article = "an" if kind == "agent" else "a"
    name = raw.strip().lower()
    if name == EVERYONE:
        raise UserError(f"'{EVERYONE}' addresses every agent and cannot be {article} {kind} name")
    if not NAME_RULE.fullmatch(name):
        raise UserError(
            f"invalid {kind} name {raw!r}: use 1 to 40 letters, digits, '.', '_' "
            "or '-', starting with a letter or digit"
        )
    return name


def one_line(value: str, field: str, *, allow_empty: bool = False) -> str:
    """Collapse a one-line field's whitespace and enforce its length limit."""
    text = " ".join(value.split())
    if not text and not allow_empty:
        raise UserError(f"{field} is empty")
    if len(text) > MAX_LINE_LENGTH:
        raise UserError(f"{field} is {len(text)} characters long; the limit is {MAX_LINE_LENGTH}")
    return text


def clip_line(text: str) -> str:
    """Return ``text`` cut to MAX_LINE_LENGTH characters, ending in "…" when cut.

    For topics that the board writes itself, which can outgrow the limit when
    they quote a title or list names. A user's own fields go through
    ``one_line`` instead, which refuses a line that is too long.
    """
    if len(text) <= MAX_LINE_LENGTH:
        return text
    return text[: MAX_LINE_LENGTH - 1] + "…"


# ---------------------------------------------------------------------------
# Paths and globs
# ---------------------------------------------------------------------------

#: Characters that make a claim a glob rather than the name of one path.
GLOB_CHARACTERS = frozenset("*?[")

#: A test that a pattern automaton applies to one character of a path.
CharacterTest = Callable[[str], bool]


def normalize_pattern(raw: str, worktree: Optional[Path] = None) -> str:
    """Return a claimed path or glob in the board's canonical form.

    Paths are relative to the top of the repository, the way ``git status``
    prints them from a worktree's root, and use '/' separators. An absolute
    path inside any working tree (the main one or a linked worktree) is made
    relative to that tree, so agents in different worktrees name a file the
    same way. "." stands for the whole repository.

    A directory ends in '/': one typed that way, or a plain path that is a
    directory on disk (relative paths are looked up in ``worktree``, the
    caller's working tree). A glob typed with a trailing '/' claims what is
    inside the directories it matches, so it gains '/**'.
    """
    text = os.path.expanduser(raw.strip())
    if not text:
        raise UserError("a path is empty")
    directory = text.endswith("/")
    if os.path.isabs(text):
        absolute = Path(os.path.normpath(text))
        directory = directory or absolute.is_dir()
        text = _relative_to_working_tree(absolute)
    pattern = posixpath.normpath(text)
    if pattern == ".":
        return "**"
    if pattern == ".." or pattern.startswith("../"):
        raise UserError(f"{raw!r} is outside the repository")
    if is_glob(pattern):
        return pattern + "/**" if directory and not pattern.endswith("**") else pattern
    if not directory and worktree is not None and not os.path.isabs(pattern):
        directory = (worktree / pattern).is_dir()
    return pattern + "/" if directory else pattern


def _relative_to_working_tree(path: Path) -> str:
    """Express an absolute path relative to the working tree that holds it.

    The nearest ancestor with a ``.git`` entry is the tree's top. Paths
    outside every working tree stay absolute.
    """
    for directory in (path, *path.parents):
        if (directory / ".git").exists():
            return path.relative_to(directory).as_posix()
    return path.as_posix()


def current_worktree() -> Optional[Path]:
    """Return the working tree that holds the current directory, if any."""
    try:
        return find_worktree_root(Path.cwd())
    except OSError:  # the current directory was deleted
        return None


def normalize_patterns(raws: Iterable[str]) -> List[str]:
    """Normalize several paths or globs against the caller's working tree."""
    worktree = current_worktree()
    return list(dict.fromkeys(normalize_pattern(raw, worktree) for raw in raws))


def is_glob(pattern: str) -> bool:
    """Whether a pattern uses glob syntax instead of naming one path."""
    return not GLOB_CHARACTERS.isdisjoint(pattern)


@functools.lru_cache(maxsize=4096)
def patterns_overlap(first: str, second: str) -> bool:
    """Whether two claimed paths or globs can name a common file.

    * A plain path names one file. A directory (ending in '/') covers
      everything inside it. A plain path is also a directory when the other
      pattern's fixed leading text continues past it with a '/', because
      naming something inside a path proves that the path is a directory.
    * Globs follow the gitignore conventions: '*' and '?' match within one
      path segment, '[...]' is a character class ('[!...]' or '[^...]'
      negated), and a '**' segment spans any number of directories. A glob
      claims exactly the paths it matches.
    * Letter case is ignored, as macOS file names ignore it by default.
    """
    first, second = first.casefold(), second.casefold()
    first, second = _directory_if_named(first, second), _directory_if_named(second, first)
    if not (is_glob(first) or is_glob(second)):
        return _plain_paths_overlap(first, second)
    return _CoverageAutomaton(first).intersects(_CoverageAutomaton(second))


def _directory_if_named(pattern: str, other: str) -> str:
    """Mark a plain path as a directory if ``other`` names something inside it."""
    if is_glob(pattern) or pattern.endswith("/"):
        return pattern
    first_glob = next((i for i, character in enumerate(other) if character in GLOB_CHARACTERS), len(other))
    return pattern + "/" if other[:first_glob].startswith(pattern + "/") else pattern


def _plain_paths_overlap(first: str, second: str) -> bool:
    """Whether two plain paths name the same path or a directory holds the other."""
    if first.rstrip("/") == second.rstrip("/"):
        return True
    return (first.endswith("/") and second.startswith(first)) or (
        second.endswith("/") and first.startswith(second)
    )


def _any_character(character: str) -> bool:
    """Character test for '**': every character, '/' included."""
    return True


def _segment_character(character: str) -> bool:
    """Character test for '*' and '?': any character except '/'."""
    return character != "/"


def _literal(expected: str) -> CharacterTest:
    """Return a character test that accepts exactly ``expected``."""
    return expected.__eq__


def _character_class(text: str) -> CharacterTest:
    """Return the character test for a '[...]' class, which never matches '/'.

    fnmatch translates the class itself. A leading '^' negates the class
    like '!', as it does for git and the shells.
    """
    if text.startswith("[^"):
        text = "[!" + text[2:]
    regex = re.compile(fnmatch.translate(text))
    return lambda character: character != "/" and regex.match(character) is not None


def _class_end(segment: str, start: int) -> int:
    """Return the index after the ']' closing the class opened at ``start``.

    A '!' or '^' right after '[' negates the class, and a ']' right after
    that is a member rather than the end. Returns -1 when the class is never
    closed, in which case its '[' is an ordinary character.
    """
    index = start + 1
    if index < len(segment) and segment[index] in "!^":
        index += 1
    if index < len(segment) and segment[index] == "]":
        index += 1
    end = segment.find("]", index)
    return -1 if end < 0 else end + 1


def _witness_characters(text: str) -> FrozenSet[str]:
    """Return enough characters to tell whether two character tests overlap.

    Every test is built from characters of the patterns (literals, class
    members, range ends), so the characters a test accepts form runs that
    begin at one of those characters, just after one, or at the very first
    character, NUL. Two tests that accept a common character therefore
    accept a common one from this set. NUL also stands for every character
    no pattern mentions, since paths never contain it.
    """
    witnesses = {"\0", "/"}
    for character in text:
        witnesses.add(character)
        if ord(character) < sys.maxunicode:
            witnesses.add(chr(ord(character) + 1))
    return frozenset(witnesses)


class _CoverageAutomaton:
    """A small nondeterministic automaton for the paths a pattern covers.

    States are numbered from 0, the start. ``moves[state]`` lists
    ``(test, target)`` pairs that read one character; ``skips[state]``
    lists targets reached without reading any. The automaton accepts every
    path the pattern matches and, for a directory (a pattern ending in
    '/'), everything inside it as well.
    """

    def __init__(self, pattern: str) -> None:
        """Compile a case-folded pattern one '/'-separated segment at a time."""
        self.pattern = pattern
        self.moves: List[List[Tuple[CharacterTest, int]]] = []
        self.skips: List[List[int]] = []
        state = self._new_state()
        segments = pattern.rstrip("/").split("/")
        for index, segment in enumerate(segments):
            last = index == len(segments) - 1
            if segment == "**" and last:
                # A final '**' matches anything at all.
                self.moves[state].append((_any_character, state))
            elif segment == "**":
                state = self._any_directories(state)
            else:
                state = self._segment(state, segment)
                if not last:
                    state = self._step(state, _literal("/"))
        self.accepting = {state}
        if pattern.endswith("/"):
            # A directory also covers everything inside it: '/' then anything.
            inside = self._step(state, _literal("/"))
            self.moves[inside].append((_any_character, inside))
            self.accepting.add(inside)

    def _new_state(self) -> int:
        """Add a state with no moves and return its number."""
        self.moves.append([])
        self.skips.append([])
        return len(self.moves) - 1

    def _step(self, state: int, test: CharacterTest) -> int:
        """Add a move reading one character into a new state; return that state."""
        target = self._new_state()
        self.moves[state].append((test, target))
        return target

    def _any_directories(self, state: int) -> int:
        """Add a '**/' segment, which reads nothing or anything ending in '/'."""
        inside, end = self._new_state(), self._new_state()
        self.skips[state] += [inside, end]
        self.moves[inside].append((_any_character, inside))
        self.moves[inside].append((_literal("/"), end))
        return end

    def _segment(self, state: int, segment: str) -> int:
        """Add the moves for one segment other than '**'; return its end state."""
        index = 0
        while index < len(segment):
            character = segment[index]
            if character == "*":
                # A run of stars inside a segment acts as one '*': stay in
                # this state while reading any characters but '/'.
                while index < len(segment) and segment[index] == "*":
                    index += 1
                self.moves[state].append((_segment_character, state))
                continue
            end = _class_end(segment, index) if character == "[" else -1
            if end > 0:
                state = self._step(state, _character_class(segment[index:end]))
                index = end
                continue
            test = _segment_character if character == "?" else _literal(character)
            state = self._step(state, test)
            index += 1
        return state

    def intersects(self, other: "_CoverageAutomaton") -> bool:
        """Whether some path is accepted by both automata.

        A search over pairs of states: from each pair either automaton may
        take a skip on its own, or both may read one character that both of
        their tests accept. Reaching a pair of accepting states proves that
        a common path exists.
        """
        alphabet = _witness_characters(self.pattern + other.pattern)
        accepted: Dict[CharacterTest, FrozenSet[str]] = {}

        def reads(test: CharacterTest) -> FrozenSet[str]:
            """Return the witness characters a test accepts, once per test."""
            if test not in accepted:
                accepted[test] = frozenset(filter(test, alphabet))
            return accepted[test]

        start = (0, 0)
        seen, pending = {start}, [start]
        while pending:
            mine, theirs = pending.pop()
            if mine in self.accepting and theirs in other.accepting:
                return True
            successors = [(target, theirs) for target in self.skips[mine]]
            successors += [(mine, target) for target in other.skips[theirs]]
            for my_test, my_target in self.moves[mine]:
                for their_test, their_target in other.moves[theirs]:
                    if not reads(my_test).isdisjoint(reads(their_test)):
                        successors.append((my_target, their_target))
            for pair in successors:
                if pair not in seen:
                    seen.add(pair)
                    pending.append(pair)
        return False


# ---------------------------------------------------------------------------
# Finding the board
# ---------------------------------------------------------------------------


def find_worktree_root(start: Path) -> Optional[Path]:
    """Return the nearest directory at or above ``start`` with a ``.git`` entry.

    The entry is a directory in a repository's main working tree and a file
    in a linked worktree (or a submodule); either one marks the top of a
    working tree.
    """
    for directory in (start, *start.parents):
        if (directory / ".git").exists():
            return directory
    return None


def main_worktree_root(worktree: Path) -> Path:
    """Map any working tree of a repository to that repository's main one.

    A linked worktree's ``.git`` file names its private git directory
    (``<repo>/.git/worktrees/<name>``), whose ``commondir`` file points at
    the repository's shared git directory. Like git itself, this takes the
    main working tree to be that shared directory minus a trailing
    ``/.git``; for a bare repository it is the shared directory itself.
    A ``.git`` file without ``commondir`` (a submodule, or a repository made
    with ``--separate-git-dir``) already belongs to a main working tree.
    """
    marker = worktree / ".git"
    if marker.is_dir():
        return worktree
    try:
        gitdir = _gitdir_named_by(marker)
        commondir = gitdir / "commondir"
        if not commondir.is_file():
            return worktree
        # Usually "../.."; relative paths are relative to the private git dir.
        common = (gitdir / commondir.read_text(encoding="utf-8").strip()).resolve()
    except OSError as error:
        raise UserError(
            f"cannot follow {marker} to its repository ({error.strerror or error}); "
            f"set {BOARD_DIR_ENV} to choose a board directory"
        ) from error
    return common.parent if common.name == ".git" else common


def _gitdir_named_by(marker: Path) -> Path:
    """Return the git directory named by a ``.git`` file's ``gitdir:`` line."""
    for line in marker.read_text(encoding="utf-8").splitlines():
        if line.startswith("gitdir:"):
            # Git writes an absolute path unless asked for relative ones,
            # which are relative to the directory holding the .git file.
            return (marker.parent / line[len("gitdir:"):].strip()).resolve()
    raise UserError(f"{marker} has no 'gitdir:' line; set {BOARD_DIR_ENV} to choose a board directory")


def repository_board_directory(starts: Iterable[Path]) -> Path:
    """Return the board directory of the first start inside a git repository.

    Each start is walked upward to its working tree, which is mapped to the
    repository's main working tree, so every worktree shares one board.
    """
    for start in starts:
        worktree = find_worktree_root(start)
        if worktree is not None:
            return main_worktree_root(worktree) / DEFAULT_BOARD_SUBDIR
    raise UserError(
        f"not inside a git repository; run from a worktree of the repository or set {BOARD_DIR_ENV}"
    )


def board_directory() -> Path:
    """Return the directory that holds the board.

    ``$TEXTMOUTH_BBS_DIR`` wins when set. Otherwise the repository is found
    from the current directory, falling back to this script's own location
    so that a command run from outside any repository still reaches the
    board of the repository the script belongs to.
    """
    override = os.environ.get(BOARD_DIR_ENV, "").strip()
    if override:
        return Path(override).expanduser().absolute()
    starts = []
    with contextlib.suppress(OSError):  # the current directory may be gone
        starts.append(Path.cwd())
    starts.append(Path(__file__).resolve().parent)
    return repository_board_directory(starts)


# ---------------------------------------------------------------------------
# The database
# ---------------------------------------------------------------------------

#: Statements that create the board's tables; each is safe to run again.
#: Times are UTC text in UTC_FORMAT.
SCHEMA = (
    # One row per registered agent. `activity` is what the agent is doing
    # now (idle until it says otherwise) and `activity_since` when it began.
    """
    CREATE TABLE IF NOT EXISTS agents (
        name           TEXT PRIMARY KEY,
        role           TEXT NOT NULL,
        branch         TEXT NOT NULL,
        registered_at  TEXT NOT NULL,
        last_seen      TEXT NOT NULL,
        activity       TEXT NOT NULL DEFAULT 'idle',
        activity_note  TEXT NOT NULL DEFAULT '',
        activity_since TEXT NOT NULL
    )
    """,
    # The paths and globs each agent is editing, in normalize_pattern form.
    """
    CREATE TABLE IF NOT EXISTS claims (
        agent      TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
        pattern    TEXT NOT NULL,
        claimed_at TEXT NOT NULL,
        PRIMARY KEY (agent, pattern)
    )
    """,
    # Messages. AUTOINCREMENT never reuses an id, even after purges, so ids
    # only grow and a remembered --since id never hides a newer message.
    # `recipient` is an agent name or 'all'; `reply_to` is kept as a plain
    # number so a reply survives the purge of the message it answers.
    """
    CREATE TABLE IF NOT EXISTS messages (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        posted_at TEXT NOT NULL,
        sender    TEXT NOT NULL,
        recipient TEXT NOT NULL,
        tag       TEXT NOT NULL,
        topic     TEXT NOT NULL,
        body      TEXT NOT NULL,
        reply_to  INTEGER
    )
    """,
    # The paths and globs a message is about (post --file).
    """
    CREATE TABLE IF NOT EXISTS message_files (
        message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        path       TEXT NOT NULL,
        PRIMARY KEY (message_id, path)
    )
    """,
    # Which agent has been shown which message by inbox or watch.
    """
    CREATE TABLE IF NOT EXISTS reads (
        agent      TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
        message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        PRIMARY KEY (agent, message_id)
    )
    """,
)

#: Tables and indexes that came after layout 1 shipped. Each is created
#: whenever it is missing, so older scripts (which ignore them) and newer ones
#: share one board. Every change here must be additive: a new table or index,
#: never a changed column. A table that refers to agents or messages must
#: cascade or hold plain names, because older scripts delete agents and
#: messages without knowing that the table exists.
SCHEMA_ADDITIONS = (
    # Teams. `lead` is a plain agent name rather than a reference to agents,
    # so purging or resetting agents never fails on it, and never deletes the
    # team.
    """
    CREATE TABLE IF NOT EXISTS teams (
        name       TEXT PRIMARY KEY,
        lead       TEXT NOT NULL,
        purpose    TEXT NOT NULL,
        created_at TEXT NOT NULL
    )
    """,
    # Each team's members besides its lead, and when each joined. A member row
    # goes with its team, and with its agent when the agent is purged.
    """
    CREATE TABLE IF NOT EXISTS team_members (
        team      TEXT NOT NULL REFERENCES teams(name) ON DELETE CASCADE,
        agent     TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
        joined_at TEXT NOT NULL,
        PRIMARY KEY (team, agent)
    )
    """,
    # Finds an agent's teams, and lets deleting an agent find its member rows
    # quickly.
    "CREATE INDEX IF NOT EXISTS team_members_by_agent ON team_members (agent)",
    # Each team's tasks. AUTOINCREMENT never reuses an id. `assignee`,
    # `created_by` and `updated_by` are plain agent names, so a task outlives
    # its agents; `brief` is a path, or NULL when the task has none.
    """
    CREATE TABLE IF NOT EXISTS tasks (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        team       TEXT NOT NULL REFERENCES teams(name) ON DELETE CASCADE,
        title      TEXT NOT NULL,
        brief      TEXT,
        state      TEXT NOT NULL DEFAULT 'open',
        assignee   TEXT,
        note       TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        created_by TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        updated_by TEXT NOT NULL
    )
    """,
    # Finds a team's tasks, and lets deleting a team find them quickly.
    "CREATE INDEX IF NOT EXISTS tasks_by_team ON tasks (team)",
    # The paths and globs each task touches, in normalize_pattern form.
    """
    CREATE TABLE IF NOT EXISTS task_files (
        task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        path    TEXT NOT NULL,
        PRIMARY KEY (task_id, path)
    )
    """,
)


def open_board() -> sqlite3.Connection:
    """Open the shared board, creating its directory and tables if needed.

    The connection runs in autocommit mode; changes go through
    ``write_transaction``. Several processes may use the board at once:
    write-ahead logging lets readers proceed during a write, and the busy
    timeout makes a writer wait its turn instead of failing.
    """
    directory = board_directory()
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(
        str(directory / BOARD_FILENAME),
        timeout=BUSY_TIMEOUT_SECONDS,
        isolation_level=None,
    )
    try:
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        _use_write_ahead_log(conn)
        # NORMAL is durable enough in WAL mode and avoids a sync per commit.
        conn.execute("PRAGMA synchronous = NORMAL")
        _create_schema(conn)
    except BaseException:
        conn.close()
        raise
    return conn


def _use_write_ahead_log(conn: sqlite3.Connection) -> None:
    """Switch the board to WAL journaling; the mode persists in the file.

    Processes that create a brand-new board at the same moment race for the
    switch, and the loser may be told the database is locked even though it
    waited; it simply tries again until the busy timeout runs out.
    """
    deadline = time.monotonic() + BUSY_TIMEOUT_SECONDS
    while True:
        try:
            if conn.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal":
                conn.execute("PRAGMA journal_mode = WAL")
            return
        except sqlite3.OperationalError as error:
            if "locked" not in str(error) or time.monotonic() > deadline:
                raise
            time.sleep(0.05)


def _created_name(statement: str) -> str:
    """Return the name of the table or index that one CREATE statement makes."""
    match = re.search(r"IF NOT EXISTS\s+(\w+)", statement)
    if match is None:  # a programming error: every schema statement says IF NOT EXISTS
        raise ValueError(f"not a CREATE ... IF NOT EXISTS statement: {statement!r}")
    return match.group(1)


def _board_is_current(conn: sqlite3.Connection) -> bool:
    """Say whether the board has its version and every added table and index.

    It only reads, so opening a current board takes no write lock.
    """
    if conn.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
        return False
    present = {row[0] for row in conn.execute("SELECT name FROM sqlite_master")}
    return all(_created_name(statement) in present for statement in SCHEMA_ADDITIONS)


def _create_schema(conn: sqlite3.Connection) -> None:
    """Create what the board is missing and refuse boards from newer scripts.

    Layout 1 keeps its version number; the later tables and indexes in
    SCHEMA_ADDITIONS are created whenever they are missing, so a board made by
    an older script gains them the first time this script opens it.
    """
    if _board_is_current(conn):
        return
    with write_transaction(conn):
        # Read again under the write lock: another process may have just
        # created the tables, or a newer script may own this board.
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version > SCHEMA_VERSION:
            raise UserError(
                f"the board uses layout {version} but this {PROG} knows only "
                f"{SCHEMA_VERSION}; update the agent-bbs skill"
            )
        for statement in SCHEMA + SCHEMA_ADDITIONS:
            conn.execute(statement)
        conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")


@contextlib.contextmanager
def write_transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """Run a block as one transaction that holds the write lock throughout.

    ``BEGIN IMMEDIATE`` takes the lock up front, so a transaction that reads
    and then writes cannot be overtaken by another writer in between (which
    in WAL mode would fail at once instead of waiting). Any exception,
    including an interrupt, rolls the whole block back.
    """
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        # SQLite rolls some failures back by itself; a second ROLLBACK
        # would then raise and hide the original error.
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------


def require_agent(conn: sqlite3.Connection, raw_name: str, *, touch: bool = True) -> str:
    """Return the canonical name of a registered agent, or raise UserError.

    With ``touch`` the agent's last-seen time is refreshed as well, because
    any command an agent runs shows that it is alive; call it inside a
    write transaction then.
    """
    name = normalize_name(raw_name)
    if touch:
        found = conn.execute(
            "UPDATE agents SET last_seen = ? WHERE name = ?", (to_utc_text(utc_now()), name)
        ).rowcount == 1
    else:
        found = conn.execute("SELECT 1 FROM agents WHERE name = ?", (name,)).fetchone() is not None
    if not found:
        raise UserError(
            f"unknown agent '{name}'{_did_you_mean(conn, name)}; register it first with: "
            f"{PROG} register {name} --role \"...\" --branch BRANCH"
        )
    return name


def _did_you_mean(conn: sqlite3.Connection, name: str, table: str = "agents") -> str:
    """Suggest the registered name closest to a mistyped one, if any.

    ``table`` is "agents" or "teams". It is always a constant from the code,
    never the user's text, because it is placed in the query as it is.
    """
    names = [row["name"] for row in conn.execute(f"SELECT name FROM {table}")]
    close = difflib.get_close_matches(name, names, n=1)
    return f" (did you mean '{close[0]}'?)" if close else ""


def load_agents(
    conn: sqlite3.Connection, *, name: Optional[str] = None, seen_since: Optional[str] = None
) -> List[dict]:
    """Return agents with their claims as JSON-ready dicts, ordered by name.

    ``name`` selects one agent; ``seen_since`` (UTC text) keeps only agents
    seen at or after that time.
    """
    conditions, params = [], []
    if name is not None:
        conditions.append("name = ?")
        params.append(name)
    if seen_since is not None:
        conditions.append("last_seen >= ?")
        params.append(seen_since)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    rows = conn.execute(f"SELECT * FROM agents {where} ORDER BY name", params).fetchall()
    claims: Dict[str, List[str]] = {}
    for claim in load_claims(conn, name=name):
        claims.setdefault(claim["agent"], []).append(claim["pattern"])
    return [
        {
            "name": row["name"],
            "role": row["role"],
            "branch": row["branch"],
            "claims": claims.get(row["name"], []),
            "registered": row["registered_at"],
            "last_seen": row["last_seen"],
            "activity": row["activity"],
            "activity_note": row["activity_note"],
            "activity_since": row["activity_since"],
        }
        for row in rows
    ]


def describe_agent(agent: dict) -> str:
    """Describe one agent: a status line, then role, branch, and claims."""
    activity = f"{agent['activity']} since {local_label(agent['activity_since'])}"
    if agent["activity_note"]:
        activity += f" ({agent['activity_note']})"
    seen = agent["last_seen"]
    return "\n".join(
        [
            f"{agent['name']}: {activity}; last seen {local_label(seen)}, {ago_label(seen)}",
            f"  Role: {agent['role']}",
            f"  Branch: {agent['branch']}",
            f"  Claims: {', '.join(agent['claims']) or 'none'}",
        ]
    )


def cmd_register(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Create an agent, or update an existing one's role and branch.

    The first registration needs both --role and --branch; later ones may
    give either, and what they leave out is kept. --files adds claims, just
    like `claim`, and never drops earlier ones. --team joins existing teams,
    posting "Joined team ..." to each channel; a team the agent already
    leads or belongs to changes nothing, and an unknown team undoes the
    whole registration.
    """
    name = normalize_name(args.name)
    role = None if args.role is None else one_line(args.role, "role")
    branch = None if args.branch is None else one_line(args.branch, "branch")
    patterns = normalize_patterns(args.files)
    now = to_utc_text(utc_now())
    with write_transaction(conn):
        created = conn.execute("SELECT 1 FROM agents WHERE name = ?", (name,)).fetchone() is None
        if created:
            if role is None or branch is None:
                raise UserError(f"registering {name} for the first time needs --role and --branch")
            conn.execute(
                "INSERT INTO agents (name, role, branch, registered_at, last_seen, activity_since)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (name, role, branch, now, now, now),
            )
        else:
            conn.execute(
                "UPDATE agents SET role = COALESCE(?, role), branch = COALESCE(?, branch),"
                " last_seen = ? WHERE name = ?",
                (role, branch, now, name),
            )
        add_claims(conn, name, patterns)
        joined = join_teams(conn, name, args.team)
        agent = load_agents(conn, name=name)[0]
        overlaps = overlaps_involving(conn, name)
        unread, reminder = unread_reminder(conn, name)
    verb = "Registered" if created else "Updated"
    lines = [f"{verb} {name}.", describe_agent(agent)]
    if agent["claims"]:
        lines.append(describe_overlaps(overlaps, none="No overlaps with other agents' claims."))
    lines.extend(f"Joined team {team}." for team in joined)
    if reminder:
        lines.append(reminder)
    data = {"created": created, "agent": agent, "overlaps": overlaps, "joined": joined, "unread": unread}
    return Outcome(data, "\n".join(lines))


def cmd_heartbeat(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Refresh an agent's last-seen time and mention any unread messages."""
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        agent = load_agents(conn, name=name)[0]
        unread, reminder = unread_reminder(conn, name)
    lines = [f"{name} last seen {local_label(agent['last_seen'])}."] + ([reminder] if reminder else [])
    return Outcome({**agent, "unread": unread}, "\n".join(lines))


def cmd_agents(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """List agents with their role, branch, last-seen time, and activity."""
    seen_since, scope = None, ""
    if args.active_within is not None:
        seen_since = to_utc_text(utc_now() - dt.timedelta(minutes=args.active_within))
        scope = f" active in the last {plural(args.active_within, 'minute')}"
    agents = load_agents(conn, seen_since=seen_since)
    if not agents:
        text = f"No agents{scope}." if scope else "No agents registered."
    else:
        heading = f"{plural(len(agents), 'agent')}{scope}:"
        text = "\n\n".join([heading] + [describe_agent(agent) for agent in agents])
    return Outcome(agents, text)


def cmd_activity(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Record what an agent is doing now; a new activity replaces the old note."""
    note = "" if args.note is None else one_line(args.note, "note", allow_empty=True)
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        conn.execute(
            "UPDATE agents SET activity = ?, activity_note = ?, activity_since = ? WHERE name = ?",
            (args.activity, note, to_utc_text(utc_now()), name),
        )
        agent = load_agents(conn, name=name)[0]
    return Outcome(agent, f"{name} is {args.activity}{': ' + note if note else ''}.")


# ---------------------------------------------------------------------------
# Claims
# ---------------------------------------------------------------------------


def load_claims(conn: sqlite3.Connection, *, name: Optional[str] = None) -> List[dict]:
    """Return claims as JSON-ready dicts, by agent and then in claiming order."""
    where, params = ("WHERE agent = ?", (name,)) if name is not None else ("", ())
    rows = conn.execute(
        f"SELECT agent, pattern, claimed_at FROM claims {where} ORDER BY agent, claimed_at, rowid", params
    ).fetchall()
    return [{"agent": row["agent"], "pattern": row["pattern"], "claimed": row["claimed_at"]} for row in rows]


def add_claims(conn: sqlite3.Connection, name: str, patterns: Iterable[str]) -> None:
    """Record claims for an agent, skipping any it already holds."""
    now = to_utc_text(utc_now())
    held = {claim["pattern"].casefold() for claim in load_claims(conn, name=name)}
    for pattern in patterns:
        if pattern.casefold() not in held:
            held.add(pattern.casefold())
            conn.execute(
                "INSERT INTO claims (agent, pattern, claimed_at) VALUES (?, ?, ?)", (name, pattern, now)
            )


def _claim_key(pattern: str) -> str:
    """Key on which `release` matches claims: letter case and a final '/' aside."""
    return pattern.rstrip("/").casefold()


def find_overlaps(claims: List[dict]) -> List[dict]:
    """Return every pair of claims, held by different agents, that overlap."""
    return [
        {"first": first, "second": second}
        for index, first in enumerate(claims)
        for second in claims[index + 1 :]
        if first["agent"] != second["agent"] and patterns_overlap(first["pattern"], second["pattern"])
    ]


def overlaps_involving(conn: sqlite3.Connection, name: str) -> List[dict]:
    """Return the overlaps between one agent's claims and other agents' claims.

    Each pair lists the agent's own claim first.
    """
    overlaps = []
    for overlap in find_overlaps(load_claims(conn)):
        first, second = overlap["first"], overlap["second"]
        if second["agent"] == name:
            first, second = second, first
        if first["agent"] == name:
            overlaps.append({"first": first, "second": second})
    return overlaps


def describe_overlaps(overlaps: List[dict], *, none: str) -> str:
    """List overlapping claims, one pair per line, or return ``none``."""
    if not overlaps:
        return none
    lines = [f"{plural(len(overlaps), 'overlap')} between agents:"]
    for overlap in overlaps:
        first, second = overlap["first"], overlap["second"]
        lines.append(
            f"  {first['agent']} claims {first['pattern']} and {second['agent']} claims {second['pattern']}"
        )
    return "\n".join(lines)


def describe_claims(claims: List[dict]) -> List[str]:
    """Return one line per agent listing its claims in order."""
    by_agent: Dict[str, List[str]] = {}
    for claim in claims:
        by_agent.setdefault(claim["agent"], []).append(claim["pattern"])
    return [f"  {agent}: {', '.join(patterns)}" for agent, patterns in by_agent.items()]


def cmd_claim(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Record paths or globs an agent is editing, and report overlaps."""
    patterns = normalize_patterns(args.paths)
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        add_claims(conn, name, patterns)
        claims = [claim["pattern"] for claim in load_claims(conn, name=name)]
        overlaps = overlaps_involving(conn, name)
    text = "\n".join(
        [
            f"{name} now claims: {', '.join(claims)}.",
            describe_overlaps(overlaps, none="No overlaps with other agents' claims."),
        ]
    )
    return Outcome({"agent": name, "claims": claims, "overlaps": overlaps}, text)


def cmd_release(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Drop some or all of an agent's claims.

    A claim is released by the path or glob it was made with (letter case
    and a final '/' aside); releasing one file never narrows a broader claim.
    """
    if bool(args.paths) == args.all:
        raise UserError("name the claims to release, or use --all, but not both")
    patterns = normalize_patterns(args.paths)
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        held = [claim["pattern"] for claim in load_claims(conn, name=name)]
        wanted = {_claim_key(pattern) for pattern in patterns}
        released = held if args.all else [pattern for pattern in held if _claim_key(pattern) in wanted]
        found = {_claim_key(pattern) for pattern in released}
        missing = [pattern for pattern in patterns if _claim_key(pattern) not in found]
        conn.executemany(
            "DELETE FROM claims WHERE agent = ? AND pattern = ?", [(name, pattern) for pattern in released]
        )
        remaining = [pattern for pattern in held if pattern not in released]
    lines = [f"Released for {name}: {', '.join(released)}." if released else f"Released nothing for {name}."]
    if missing:
        lines.append(
            f"{name} had not claimed: {', '.join(missing)} "
            "(release a claim by the path or glob it was made with)."
        )
    lines.append(f"{name} now claims: {', '.join(remaining) or 'nothing'}.")
    data = {"agent": name, "released": released, "not_claimed": missing, "claims": remaining}
    return Outcome(data, "\n".join(lines))


def cmd_claims(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """List every claim, or those covering one path, flagging overlaps between agents."""
    claims = load_claims(conn)
    path = None
    if args.path is not None:
        path = normalize_patterns([args.path])[0]
        claims = [claim for claim in claims if patterns_overlap(claim["pattern"], path)]
    overlaps = find_overlaps(claims)
    if not claims:
        text = f"No agent claims {path}." if path else "No claims."
    else:
        heading = f"Claims covering {path}:" if path else "Claims:"
        overlap_text = describe_overlaps(overlaps, none="No overlaps between agents.")
        text = "\n".join([heading, *describe_claims(claims), overlap_text])
    return Outcome({"path": path, "claims": claims, "overlaps": overlaps}, text)


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------


def query_messages(
    conn: sqlite3.Connection,
    *,
    where: Iterable[str] = (),
    params: Iterable[Any] = (),
    reader: Optional[str] = None,
) -> List[dict]:
    """Return the messages meeting every condition, oldest first, with files.

    Conditions refer to the messages table as ``m``. With ``reader`` each
    message also says whether that agent has been shown it (``unread``),
    and conditions may test ``r.message_id IS NULL`` for unread messages.
    """
    columns, joins, values = "m.*, f.path AS file", "", []
    if reader is not None:
        columns += ", r.message_id IS NULL AS unread"
        joins = " LEFT JOIN reads r ON r.message_id = m.id AND r.agent = ?"
        values.append(reader)
    clause = " AND ".join(where)
    rows = conn.execute(
        f"SELECT {columns} FROM messages m"
        " LEFT JOIN message_files f ON f.message_id = m.id"
        f"{joins}{' WHERE ' + clause if clause else ''}"
        " ORDER BY m.id, f.rowid",
        values + list(params),
    )
    # The join yields one row per file, so gather each message's files.
    messages: Dict[int, dict] = {}
    for row in rows:
        message = messages.get(row["id"])
        if message is None:
            message = messages[row["id"]] = {
                "id": row["id"],
                "posted": row["posted_at"],
                "from": row["sender"],
                "to": row["recipient"],
                "tag": row["tag"],
                "topic": row["topic"],
                "body": row["body"],
                "files": [],
                "reply_to": row["reply_to"],
            }
            if reader is not None:
                message["unread"] = bool(row["unread"])
        if row["file"] is not None:
            message["files"].append(row["file"])
    return list(messages.values())


def require_message(conn: sqlite3.Connection, message_id: int) -> dict:
    """Return one message by id, or raise UserError."""
    found = query_messages(conn, where=["m.id = ?"], params=[message_id])
    if not found:
        raise UserError(f"there is no message #{message_id}")
    return found[0]


def message_filters(conn: sqlite3.Connection, args: argparse.Namespace) -> Tuple[List[str], List[Any]]:
    """Return the SQL conditions for the --since, --tag, and --team options.

    --team keeps only the messages in that team's channel, and fails when
    there is no such team.
    """
    where: List[str] = []
    params: List[Any] = []
    if args.since is not None:
        condition, value = args.since.condition()
        where.append(condition)
        params.append(value)
    if args.tag is not None:
        where.append("m.tag = ?")
        params.append(args.tag)
    if args.team is not None:
        where.append("m.recipient = ?")
        params.append(team_address(require_team(conn, args.team)))
    return where, params


def describe_message(message: dict, *, mark_unread: bool = False) -> str:
    """Describe one message: a header line, then reply, files, and body.

    With ``mark_unread`` the header of an unread message says so.
    """
    unread = " (unread)" if mark_unread and message.get("unread") else ""
    lines = [
        f"#{message['id']}{unread} {message['tag']} from {message['from']} to {message['to']}, "
        f"{local_label(message['posted'])}: {message['topic']}"
    ]
    if message["reply_to"] is not None:
        lines.append(f"  In reply to #{message['reply_to']}.")
    if message["files"]:
        lines.append(f"  Files: {', '.join(message['files'])}")
    lines += [f"  {line}".rstrip() for line in message["body"].splitlines()]
    return "\n".join(lines)


def describe_messages(heading: str, messages: List[dict], *, mark_unread: bool = False) -> str:
    """Return a heading and then the messages, separated by blank lines."""
    described = [describe_message(message, mark_unread=mark_unread) for message in messages]
    return "\n\n".join([heading] + described)


def read_body(args: argparse.Namespace) -> str:
    """Return a post's body from --body or --body-file, within the size limit.

    Leading blank lines and trailing white space are dropped.
    """
    try:
        if args.body_file is None:
            body = args.body or ""
        elif args.body_file == "-":
            body = sys.stdin.read()
        else:
            body = Path(args.body_file).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise UserError(f"cannot read the message body: {error}") from error
    body = body.rstrip().lstrip("\n")
    size = len(body.encode("utf-8"))
    if size > MAX_BODY_BYTES:
        raise UserError(
            f"the body is {size:,} bytes and the limit is {MAX_BODY_BYTES:,} (16 KB); "
            "keep posts short, since the board is for coordination, not reports"
        )
    return body


def resolve_recipient(
    conn: sqlite3.Connection, raw: Optional[str], sender: str, parent: Optional[dict]
) -> str:
    """Return who a new post is addressed to.

    --to wins: 'all', a registered agent other than the sender, or a team's
    channel (team:TEAM, which the sender may belong to). Without it a reply
    goes back to the author of the message it answers (or, when the sender
    wrote that message, to its recipient), and any other post goes to all.

    A reply to a team's message stays in that team's channel: --to may name
    that channel again but nothing else. Nor can a reply to a message
    outside every channel move into one.
    """
    in_channel = None if parent is None else team_from_address(parent["to"])
    names_team = raw is not None and raw.strip().lower().startswith(TEAM_PREFIX)
    if in_channel is not None:
        # Compare addresses, not text, so "Team:Board" matches "team:board".
        if raw is not None and not (names_team and team_address(normalize_team(raw)) == parent["to"]):
            raise UserError(
                f"#{parent['id']} is in team {in_channel}'s channel, and a reply stays there; "
                "leave out --to, or post without --reply-to"
            )
        return parent["to"]
    if names_team:
        address = team_address(require_team(conn, raw))
        if parent is not None:
            raise UserError(
                f"#{parent['id']} is not in a team's channel, and a reply stays where the message it "
                f"answers was posted; post to {address} without --reply-to"
            )
        return address
    if raw is None:
        if parent is None:
            return EVERYONE
        return parent["from"] if parent["from"] != sender else parent["to"]
    if raw.strip().lower() == EVERYONE:
        return EVERYONE
    name = normalize_name(raw)
    if name == sender:
        raise UserError("a post to yourself reaches nobody; address another agent or all")
    if conn.execute("SELECT 1 FROM agents WHERE name = ?", (name,)).fetchone() is None:
        raise UserError(f"unknown agent '{name}'{_did_you_mean(conn, name)}; address a registered agent or all")
    return name


def reply_topic(topic: str) -> str:
    """Return a reply's default topic: "Re: " and the original, never doubled."""
    if not topic.lower().startswith("re: "):
        topic = f"Re: {topic}"
    return topic[:MAX_LINE_LENGTH]


def insert_message(
    conn: sqlite3.Connection,
    sender: str,
    recipient: str,
    tag: str,
    topic: str,
    body: str = "",
    *,
    reply_to: Optional[int] = None,
    files: Iterable[str] = (),
) -> int:
    """Store one message with the files it is tied to, and return its id.

    Runs inside the caller's write transaction. Everything is already
    validated; the caller owns the rules, this only writes the rows.
    """
    cursor = conn.execute(
        "INSERT INTO messages (posted_at, sender, recipient, tag, topic, body, reply_to)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        (to_utc_text(utc_now()), sender, recipient, tag, topic, body, reply_to),
    )
    conn.executemany(
        "INSERT INTO message_files (message_id, path) VALUES (?, ?)",
        [(cursor.lastrowid, path) for path in files],
    )
    return cursor.lastrowid


def cmd_post(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Post a message to one agent, a team's channel, or all, optionally tied to files."""
    topic = None if args.topic is None else one_line(args.topic, "topic")
    body = read_body(args)
    files = normalize_patterns(args.file)
    with write_transaction(conn):
        sender = require_agent(conn, args.sender)
        parent = None if args.reply_to is None else require_message(conn, args.reply_to)
        recipient = resolve_recipient(conn, args.to, sender, parent)
        if topic is None:
            if parent is None:
                raise UserError("post needs --topic (only a reply may leave it out)")
            topic = reply_topic(parent["topic"])
        message_id = insert_message(
            conn, sender, recipient, args.tag, topic, body, reply_to=args.reply_to, files=files
        )
        message = require_message(conn, message_id)
        holders = [
            {"agent": claim["agent"], "pattern": claim["pattern"]}
            for claim in load_claims(conn)
            if claim["agent"] != sender and any(patterns_overlap(claim["pattern"], path) for path in files)
        ]
    replying = f", in reply to #{parent['id']}" if parent else ""
    lines = [f"Posted #{message['id']} ({message['tag']}) to {recipient}{replying}."]
    if holders:
        lines.append("Claimed by: " + ", ".join(f"{h['agent']} ({h['pattern']})" for h in holders) + ".")
    elif files:
        lines.append("No other agent claims these files.")
    return Outcome({**message, "claimed_by": holders}, "\n".join(lines))


def cmd_read(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Show the public log, oldest first: every message, whoever it was for.

    Without --since only the last DEFAULT_READ_COUNT messages are shown,
    unless --last asks for another number.
    """
    where, params = message_filters(conn, args)
    if args.sender is not None:
        where.append("m.sender = ?")
        params.append(normalize_name(args.sender))
    messages = query_messages(conn, where=where, params=params)
    limit = args.last if args.last is not None else (None if args.since else DEFAULT_READ_COUNT)
    shown = messages[-limit:] if limit else messages
    if not shown:
        text = "No messages match." if where else "No messages yet."
    elif len(shown) < len(messages):
        heading = (
            f"The last {len(shown)} of {len(messages)} messages"
            " (use --last N or --since ID to see others):"
        )
        text = describe_messages(heading, shown)
    else:
        text = describe_messages(f"{plural(len(shown), 'message')}:", shown)
    return Outcome(shown, text)


def cmd_thread(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Show a whole conversation: its first message and every reply under it."""
    root = require_message(conn, args.id)
    # Climb to the first message. Each reply's parent is an older message,
    # so the climb ends; it stops early where a parent has been purged.
    while root["reply_to"] is not None:
        parents = query_messages(conn, where=["m.id = ?"], params=[root["reply_to"]])
        if not parents:
            break
        root = parents[0]
    replies: Dict[int, List[int]] = {}
    for row in conn.execute(
        "SELECT id, reply_to FROM messages WHERE reply_to IS NOT NULL AND id > ?", (root["id"],)
    ):
        replies.setdefault(row["reply_to"], []).append(row["id"])
    ids, pending = [root["id"]], [root["id"]]
    while pending:
        children = replies.get(pending.pop(), [])
        ids += children
        pending += children
    placeholders = ", ".join("?" for _ in ids)
    messages = query_messages(conn, where=[f"m.id IN ({placeholders})"], params=ids)
    purged = "" if root["reply_to"] is None else f" (it answers #{root['reply_to']}, which was purged)"
    heading = f"Thread #{root['id']}{purged}, {plural(len(messages), 'message')}:"
    return Outcome(messages, describe_messages(heading, messages))


# ---------------------------------------------------------------------------
# Inbox
# ---------------------------------------------------------------------------


def team_channels(conn: sqlite3.Connection, name: str, registered: str) -> Dict[str, str]:
    """Map the address of each team an agent is in onto when its posts begin to concern it.

    A lead hears its team's channel from ``registered`` (the moment the
    agent registered), as it hears posts to all. A member hears it from the
    moment it joined, so it is not handed the history before.
    """
    channels = {
        team_address(row["name"]): registered
        for row in conn.execute("SELECT name FROM teams WHERE lead = ?", (name,))
    }
    for row in conn.execute("SELECT team, joined_at FROM team_members WHERE agent = ?", (name,)):
        channels[team_address(row["team"])] = row["joined_at"]
    return channels


def collect_inbox(
    conn: sqlite3.Connection,
    name: str,
    *,
    where: Iterable[str] = (),
    params: Iterable[Any] = (),
    unread_only: bool = False,
) -> List[dict]:
    """Return the messages that concern an agent, oldest first.

    A message concerns the agent when it is addressed to the agent or to
    all and was posted since the agent first registered, or is posted to
    the channel of a team the agent is in and was posted since the agent
    led or joined that team (see ``team_channels``), or, whenever it was
    posted, when one of its files falls under one of the agent's current
    claims. So a newcomer is not handed the board's whole history as
    unread, yet still hears of findings about the files it takes on.
    The agent's own posts never concern it.
    """
    registered = conn.execute("SELECT registered_at FROM agents WHERE name = ?", (name,)).fetchone()[0]
    claims = [claim["pattern"] for claim in load_claims(conn, name=name)]
    channels = team_channels(conn, name, registered)
    conditions, values = ["m.sender != ?", *where], [name, *params]
    if unread_only:
        conditions.append("r.message_id IS NULL")
    return [
        message
        for message in query_messages(conn, where=conditions, params=values, reader=name)
        if (message["to"] in (name, EVERYONE) and message["posted"] >= registered)
        or (message["to"] in channels and message["posted"] >= channels[message["to"]])
        or any(patterns_overlap(path, claim) for path in message["files"] for claim in claims)
    ]


def mark_read(conn: sqlite3.Connection, name: str, messages: Iterable[dict]) -> None:
    """Record that an agent has been shown these messages."""
    conn.executemany(
        "INSERT OR IGNORE INTO reads (agent, message_id) VALUES (?, ?)",
        [(name, message["id"]) for message in messages],
    )


def unread_reminder(conn: sqlite3.Connection, name: str) -> Tuple[int, str]:
    """Count an agent's unread messages and phrase a reminder (empty if none)."""
    count = len(collect_inbox(conn, name, unread_only=True))
    if not count:
        return 0, ""
    return count, f"Unread messages for {name}: {count}. Run: {PROG} inbox {name} --unread"


def cmd_inbox(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Show the messages that concern an agent, newest last, and mark them read.

    Only the messages shown are marked; --peek marks none.
    """
    where, params = message_filters(conn, args)
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        messages = collect_inbox(conn, name, where=where, params=params, unread_only=args.unread)
        if args.last is not None:
            messages = messages[-args.last :]
        if not args.peek:
            mark_read(conn, name, messages)
    unread = sum(message["unread"] for message in messages)
    if not messages:
        text = f"No {'unread ' if args.unread else ''}messages for {name}."
    elif args.unread:
        text = describe_messages(f"{plural(len(messages), 'unread message')} for {name}:", messages)
    else:
        heading = f"{plural(len(messages), 'message')} for {name}, {unread} unread:"
        text = describe_messages(heading, messages, mark_unread=True)
    return Outcome(messages, text)


def take_unread(
    conn: sqlite3.Connection, name: str, *, after: int = 0, peek: bool = False, team: Optional[str] = None
) -> List[dict]:
    """Return an agent's unread inbox messages with ids above ``after``.

    With ``team`` (an existing team's name) only that team's channel is
    taken; the agent's other unread messages stay unread. They are marked
    read in the same transaction, unless ``peek``.
    """
    where, params = ["m.id > ?"], [after]
    if team is not None:
        where.append("m.recipient = ?")
        params.append(team_address(team))
    with write_transaction(conn):
        messages = collect_inbox(conn, name, where=where, params=params, unread_only=True)
        if not peek:
            mark_read(conn, name, messages)
    return messages


def cmd_watch(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Print an agent's unread messages, then new ones as they arrive.

    With --once it prints what is unread now and returns at once. Otherwise
    it checks every --interval seconds until --timeout seconds have passed,
    or until interrupted, printing each message as it comes (one JSON
    object per line under --json). Messages are marked read as they are
    printed, unless --peek. Nothing is printed when nothing is new. The
    exit status is 2 when at least one message was printed and 0 when
    none was, so a script can branch on it. With --team only that team's
    channel is watched.
    """
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        team = None if args.team is None else require_team(conn, args.team)
    if args.once:
        messages = take_unread(conn, name, peek=args.peek, team=team)
        text = "\n\n".join(describe_message(message) for message in messages)
        return Outcome(messages, text, EXIT_HAS_MESSAGES if messages else EXIT_OK)
    deadline = None if args.timeout is None else time.monotonic() + args.timeout
    newest = 0  # highest id printed so far, so --peek never prints one twice
    printed = False
    while True:
        for message in take_unread(conn, name, after=newest, peek=args.peek, team=team):
            # Text gets a blank line after each message; JSON is one object per line.
            line = json.dumps(message, ensure_ascii=False) if args.json else describe_message(message) + "\n"
            print(line, flush=True)
            newest, printed = message["id"], True
        if deadline is not None and time.monotonic() >= deadline:
            break
        # Sleep until the next check, but never past the deadline; the loop
        # then checks once more before stopping.
        pause = args.interval if deadline is None else min(args.interval, deadline - time.monotonic())
        time.sleep(max(pause, 0.0))
    return Outcome(None, "", EXIT_HAS_MESSAGES if printed else EXIT_OK, printed=True)


# ---------------------------------------------------------------------------
# Teams
# ---------------------------------------------------------------------------


def team_address(team: str) -> str:
    """Return the address of a team's channel, such as "team:board"."""
    return TEAM_PREFIX + team


def team_from_address(address: str) -> Optional[str]:
    """Return the team a channel address names ("team:board" gives "board"), or None.

    Anything that is not a team address, such as "all" or an agent's name, gives None.
    """
    return address[len(TEAM_PREFIX):] if address.startswith(TEAM_PREFIX) else None


def normalize_team(raw: str) -> str:
    """Return a team's canonical name from its plain name or its address.

    "Board", "board", "team:board" and "TEAM:Board" all give "board".
    """
    text = raw.strip()
    if text.lower().startswith(TEAM_PREFIX):
        text = text[len(TEAM_PREFIX):]
    return normalize_name(text, "team")


def require_team(conn: sqlite3.Connection, raw: str) -> str:
    """Return the canonical name of an existing team, or raise UserError."""
    name = normalize_team(raw)
    if conn.execute("SELECT 1 FROM teams WHERE name = ?", (name,)).fetchone() is None:
        raise UserError(
            f"there is no team '{name}'{_did_you_mean(conn, name, 'teams')}; list the teams with: {PROG} teams"
        )
    return name


def load_teams(conn: sqlite3.Connection, *, name: Optional[str] = None) -> List[dict]:
    """Return teams as JSON-ready dicts, ordered by name.

    Each has its name, lead, purpose, creation time, channel address, and
    members in the order they joined (the lead is not listed among them),
    and their tasks. ``name`` selects one team.
    """
    where, params = ("WHERE name = ?", (name,)) if name is not None else ("", ())
    teams = []
    for row in conn.execute(f"SELECT name, lead, purpose, created_at FROM teams {where} ORDER BY name", params):
        members = conn.execute(
            "SELECT agent FROM team_members WHERE team = ? ORDER BY joined_at, rowid", (row["name"],)
        )
        teams.append(
            {
                "name": row["name"],
                "lead": row["lead"],
                "purpose": row["purpose"],
                "created": row["created_at"],
                "channel": team_address(row["name"]),
                "members": [member["agent"] for member in members],
                "tasks": load_tasks(conn, team=row["name"]),
            }
        )
    return teams


def describe_team(team: dict) -> str:
    """Describe one team: a heading line, then purpose, channel, members, and task counts."""
    return "\n".join(
        [
            f"{team['name']}: led by {team['lead']}, created {local_label(team['created'])}",
            f"  Purpose: {team['purpose']}",
            f"  Channel: {team['channel']}",
            f"  Members: {', '.join(team['members']) or 'none'}",
            f"  Tasks: {describe_task_counts(team['tasks'])}",
        ]
    )


def add_member(conn: sqlite3.Connection, team: str, agent: str) -> bool:
    """Add ``agent`` to ``team`` unless it leads the team or is already in it.

    Returns whether a member row was added. Runs inside a write transaction;
    the team and the agent must exist.
    """
    lead = conn.execute("SELECT lead FROM teams WHERE name = ?", (team,)).fetchone()["lead"]
    if agent == lead:
        return False
    cursor = conn.execute(
        "INSERT OR IGNORE INTO team_members (team, agent, joined_at) VALUES (?, ?, ?)",
        (team, agent, to_utc_text(utc_now())),
    )
    return cursor.rowcount == 1


def post_to_team(
    conn: sqlite3.Connection, sender: str, team: str, topic: str, *, tag: str = "notice", body: str = ""
) -> int:
    """Post one line of a team's history to its channel and return the message id.

    The topic is clipped to the line limit, because it may quote names or titles.
    """
    return insert_message(conn, sender, team_address(team), tag, clip_line(topic), body)


def join_teams(conn: sqlite3.Connection, agent: str, raw_teams: List[str]) -> List[str]:
    """Make ``agent`` a member of each named team and return the teams it joined.

    Every name must be an existing team (plain or as an address); repeats
    are dropped. A team the agent already leads or belongs to is skipped
    without a post; each team joined gets one "Joined team" line in its
    channel. Runs inside a write transaction, so an unknown team undoes the
    joins before it.
    """
    joined = []
    for team in dict.fromkeys(require_team(conn, raw) for raw in raw_teams):
        if add_member(conn, team, agent):
            post_to_team(conn, agent, team, f"Joined team {team}")
            joined.append(team)
    return joined


def cmd_team_create(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Create a team with a lead and a purpose, and announce it in its channel."""
    team = normalize_team(args.team)
    purpose = one_line(args.purpose, "purpose")
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        lead = actor if args.lead is None else require_agent(conn, args.lead, touch=False)
        if conn.execute("SELECT 1 FROM teams WHERE name = ?", (team,)).fetchone() is not None:
            raise UserError(f"team {team} exists already; see it with: {PROG} teams {team}")
        conn.execute(
            "INSERT INTO teams (name, lead, purpose, created_at) VALUES (?, ?, ?, ?)",
            (team, lead, purpose, to_utc_text(utc_now())),
        )
        post_to_team(conn, actor, team, f"Created team {team}, led by {lead}", body=purpose)
        created = load_teams(conn, name=team)[0]
    return Outcome(created, f"Created team {team}.\n{describe_team(created)}")


def cmd_team_add(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Add registered agents to a team; the lead and current members are skipped."""
    agents = list(dict.fromkeys(normalize_name(raw) for raw in args.agents))
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        team = require_team(conn, args.team)
        # Check every agent first, so that one unknown name adds nobody.
        for agent in agents:
            require_agent(conn, agent, touch=False)
        added = [agent for agent in agents if add_member(conn, team, agent)]
        if added:
            post_to_team(conn, actor, team, f"Added {', '.join(added)} to team {team}")
        details = load_teams(conn, name=team)[0]
    already = [agent for agent in agents if agent not in added]
    lines = [f"Added {', '.join(added)} to team {team}."] if added else []
    for agent in already:
        lines.append(
            f"{agent} already leads team {team}."
            if agent == details["lead"]
            else f"{agent} is already a member of team {team}."
        )
    lines.append(describe_team(details))
    return Outcome({"team": details, "added": added, "already": already}, "\n".join(lines))


def cmd_team_remove(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Remove members from a team; strangers and the lead are reported, not removed.

    The agents need not be registered any more, so a member who was purged
    can still be named. The lead holds no member row, so it is never removed.
    """
    agents = list(dict.fromkeys(normalize_name(raw) for raw in args.agents))
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        team = require_team(conn, args.team)
        removed = [
            agent
            for agent in agents
            if conn.execute("DELETE FROM team_members WHERE team = ? AND agent = ?", (team, agent)).rowcount == 1
        ]
        if removed:
            post_to_team(conn, actor, team, f"Removed {', '.join(removed)} from team {team}")
        details = load_teams(conn, name=team)[0]
    not_members = [agent for agent in agents if agent not in removed]
    lines = [f"Removed {', '.join(removed)} from team {team}."] if removed else []
    lines.extend(f"{agent} is not a member of team {team}." for agent in not_members)
    lines.append(describe_team(details))
    return Outcome({"team": details, "removed": removed, "not_members": not_members}, "\n".join(lines))


def cmd_teams(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """List every team with its lead and members, or show one."""
    if args.team is not None:
        teams = load_teams(conn, name=require_team(conn, args.team))
        return Outcome(teams, describe_team(teams[0]))
    teams = load_teams(conn)
    if not teams:
        return Outcome(teams, "No teams yet.")
    heading = f"{plural(len(teams), 'team')}:"
    return Outcome(teams, "\n\n".join([heading] + [describe_team(team) for team in teams]))


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------


def load_tasks(
    conn: sqlite3.Connection,
    *,
    task_id: Optional[int] = None,
    team: Optional[str] = None,
    state: Optional[str] = None,
    assignee: Optional[str] = None,
) -> List[dict]:
    """Return tasks as JSON-ready dicts, ordered by id, each with its files.

    Every argument that is given adds one condition. A task's ``assignee``
    and ``brief`` are None when it has none, and its files come in the order
    they were stored.
    """
    # (condition, value) pairs for the arguments that were given.
    conditions = [
        (f"t.{column} = ?", value)
        for column, value in (("id", task_id), ("team", team), ("state", state), ("assignee", assignee))
        if value is not None
    ]
    clause = " AND ".join(condition for condition, _ in conditions)
    rows = conn.execute(
        "SELECT t.*, f.path AS file FROM tasks t"
        " LEFT JOIN task_files f ON f.task_id = t.id"
        f"{' WHERE ' + clause if clause else ''}"
        " ORDER BY t.id, f.rowid",
        [value for _, value in conditions],
    )
    # The join yields one row per file, so gather each task's files.
    tasks: Dict[int, dict] = {}
    for row in rows:
        task = tasks.get(row["id"])
        if task is None:
            task = tasks[row["id"]] = {
                "id": row["id"],
                "team": row["team"],
                "title": row["title"],
                "state": row["state"],
                "assignee": row["assignee"],
                "brief": row["brief"],
                "files": [],
                "note": row["note"],
                "created": row["created_at"],
                "created_by": row["created_by"],
                "updated": row["updated_at"],
                "updated_by": row["updated_by"],
            }
        if row["file"] is not None:
            task["files"].append(row["file"])
    return list(tasks.values())


def describe_task(task: dict) -> str:
    """Describe one task: a first line, then only the detail lines with something to say.

    An assigned task's state and assignee say the same thing, so its first
    line gives the assignee alone, rather than "assigned, assigned to ...".
    """
    if task["assignee"] is None:
        who = task["state"]
    elif task["state"] == "assigned":
        who = f"assigned to {task['assignee']}"
    else:
        who = f"{task['state']}, assigned to {task['assignee']}"
    lines = [f"Task {task['id']} in {task['team']}, {who}: {task['title']}"]
    if task["brief"]:
        lines.append(f"  Brief: {task['brief']}")
    if task["files"]:
        lines.append(f"  Files: {', '.join(task['files'])}")
    if task["note"]:
        lines.append(f"  Note: {task['note']}")
    lines.append(f"  Changed: {local_label(task['updated'])} by {task['updated_by']}")
    return "\n".join(lines)


def describe_task_counts(tasks: List[dict]) -> str:
    """Count tasks in each state, in life order, such as "1 open, 1 in review"; "none" for no tasks."""
    counts = {state: sum(1 for task in tasks if task["state"] == state) for state in TASK_STATES}
    # `review` reads better as "in review"; the other states read as they are named.
    parts = [
        f"{count} {'in review' if state == 'review' else state}" for state, count in counts.items() if count
    ]
    return ", ".join(parts) or "none"


def assignee_reminder(conn: sqlite3.Connection, task: dict) -> str:
    """Return a line saying the task's assignee has not registered, or "" when there is no need.

    A lead may plan a task for an agent that registers later, so this is a
    reminder and not an error.
    """
    assignee = task["assignee"]
    if assignee is None or conn.execute("SELECT 1 FROM agents WHERE name = ?", (assignee,)).fetchone():
        return ""
    return f"{assignee} has not registered yet."


def cmd_task_add(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Add a task to a team's list and announce it in the team's channel."""
    title = one_line(args.title, "title")
    brief = normalize_patterns([args.brief])[0] if args.brief is not None else None
    files = normalize_patterns(args.files)
    assignee = normalize_name(args.assign) if args.assign is not None else None
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        team = require_team(conn, args.team)
        now = to_utc_text(utc_now())
        cursor = conn.execute(
            "INSERT INTO tasks (team, title, brief, state, assignee, created_at, created_by, updated_at, updated_by)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (team, title, brief, "open" if assignee is None else "assigned", assignee, now, actor, now, actor),
        )
        task_id = cursor.lastrowid
        conn.executemany("INSERT INTO task_files (task_id, path) VALUES (?, ?)", [(task_id, path) for path in files])
        for_whom = "" if assignee is None else f" for {assignee}"
        post_to_team(conn, actor, team, f"Added task {task_id}{for_whom}: {title}", tag="task")
        task = load_tasks(conn, task_id=task_id)[0]
        reminder = assignee_reminder(conn, task)
    lines = [f"Added task {task_id} to team {team}.", describe_task(task)]
    if reminder:
        lines.append(reminder)
    return Outcome(task, "\n".join(lines))


def require_task(conn: sqlite3.Connection, task_id: int) -> dict:
    """Return the task numbered ``task_id`` as a dict, or raise a UserError saying how to list the tasks."""
    tasks = load_tasks(conn, task_id=task_id)
    if not tasks:
        raise UserError(f"there is no task {task_id}; list the tasks with: {PROG} tasks")
    return tasks[0]


def change_task(
    conn: sqlite3.Connection,
    actor: str,
    task: dict,
    *,
    state: str,
    assignee: Optional[str],
    note: str,
    topic: str,
) -> dict:
    """Give ``task`` a new state, assignee, and note, announce it, and return the task as stored.

    ``topic`` is the line posted to the task's team channel, with the note as
    its body. The change is stamped with the time and ``actor``; the task's
    creation stamps stay as they were. Runs inside a write transaction.
    """
    conn.execute(
        "UPDATE tasks SET state = ?, assignee = ?, note = ?, updated_at = ?, updated_by = ? WHERE id = ?",
        (state, assignee, note, to_utc_text(utc_now()), actor, task["id"]),
    )
    post_to_team(conn, actor, task["team"], topic, tag="task", body=note)
    return load_tasks(conn, task_id=task["id"])[0]


def cmd_task_assign(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Give a task to an agent, which marks it assigned from whatever state it was in.

    The agent may register later. A finished or dropped task assigned again
    comes back to life.
    """
    assignee = normalize_name(args.agent)
    note = one_line(args.note, "note", allow_empty=True) if args.note is not None else ""
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        task = require_task(conn, args.id)
        task = change_task(
            conn,
            actor,
            task,
            state="assigned",
            assignee=assignee,
            note=note,
            topic=f"Assigned task {task['id']} to {assignee}: {task['title']}",
        )
        reminder = assignee_reminder(conn, task)
    lines = [f"Assigned task {task['id']} to {assignee}.", describe_task(task)]
    if reminder:
        lines.append(reminder)
    return Outcome(task, "\n".join(lines))


def cmd_task_move(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Move a task to another state, or to the same state again to post a progress note.

    ``open`` clears the assignee, because an open task is one that no one has.
    ``assigned``, ``working``, and ``review`` need an assignee already;
    ``done`` and ``dropped`` keep whoever the task has. A move without a
    note clears the old note.
    """
    note = one_line(args.note, "note", allow_empty=True) if args.note is not None else ""
    with write_transaction(conn):
        actor = require_agent(conn, args.name)
        task = require_task(conn, args.id)
        if args.state == "open":
            assignee = None
        elif args.state in ("assigned", "working", "review") and task["assignee"] is None:
            raise UserError(
                f"task {task['id']} has no assignee; assign it with: {PROG} task assign {actor} {task['id']} AGENT"
            )
        else:
            assignee = task["assignee"]
        task = change_task(
            conn,
            actor,
            task,
            state=args.state,
            assignee=assignee,
            note=note,
            topic=f"Moved task {task['id']} to {args.state}: {task['title']}",
        )
    return Outcome(task, f"Moved task {task['id']} to {args.state}.\n{describe_task(task)}")


def cmd_tasks(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """List tasks, narrowed by team, state, and assignee."""
    team = require_team(conn, args.team) if args.team is not None else None
    assignee = normalize_name(args.agent) if args.agent is not None else None
    tasks = load_tasks(conn, team=team, state=args.state, assignee=assignee)
    if not tasks:
        filtered = any(value is not None for value in (team, args.state, assignee))
        return Outcome(tasks, "No tasks match." if filtered else "No tasks yet.")
    heading = f"{plural(len(tasks), 'task')}:"
    return Outcome(tasks, "\n\n".join([heading] + [describe_task(task) for task in tasks]))


# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------


def cmd_purge(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Delete messages posted, agents last seen, and teams idle, before a cutoff.

    A message's files and read marks go with it; an agent's claims, read
    marks, and team memberships go with it. Ids are never reused, so new
    messages keep counting up from the highest id the board has ever given.

    A team is idle when it was created before the cutoff and its channel
    holds no message at all once the old messages are gone. That is a fair
    test of idleness, because every change to a team or to its tasks posts
    to its channel: a channel with nothing newer than the cutoff means a
    team untouched that long. Its members, tasks, and task files go with it.
    A team's lead may be purged without the team, which keeps its lead's name.
    """
    cutoff = to_utc_text(utc_now() - dt.timedelta(days=args.older_than))
    with write_transaction(conn):
        messages = conn.execute("DELETE FROM messages WHERE posted_at < ?", (cutoff,)).rowcount
        agents = conn.execute("DELETE FROM agents WHERE last_seen < ?", (cutoff,)).rowcount
        teams = conn.execute(
            "DELETE FROM teams WHERE created_at < ? AND NOT EXISTS"
            " (SELECT 1 FROM messages m WHERE m.recipient = ? || teams.name)",
            (cutoff, TEAM_PREFIX),
        ).rowcount
    days = f"{args.older_than:g} day{'' if args.older_than == 1 else 's'}"
    text = (
        f"Purged {plural(messages, 'message')}, {plural(agents, 'agent')}, "
        f"and {plural(teams, 'team')} older than {days}."
    )
    return Outcome({"messages": messages, "agents": agents, "teams": teams, "cutoff": cutoff}, text)


def cmd_reset(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Delete every agent, claim, message, team, and task; refuses without --yes.

    Message ids keep counting up afterwards, so an id that an agent
    remembers for --since never hides a newer message. Task ids keep
    counting up for the same reason.
    """
    if not args.yes:
        raise UserError(
            "reset deletes every agent, claim, message, team, and task on the board; add --yes to confirm"
        )
    with write_transaction(conn):
        counts = {
            table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("agents", "claims", "messages", "teams", "tasks")
        }
        # Foreign keys cascade: files and read marks go with the messages,
        # claims, read marks, and memberships with the agents, and members,
        # tasks, and task files with the teams.
        conn.execute("DELETE FROM messages")
        conn.execute("DELETE FROM agents")
        conn.execute("DELETE FROM teams")
    text = (
        f"Reset the board: removed {plural(counts['agents'], 'agent')}, "
        f"{plural(counts['claims'], 'claim')}, {plural(counts['messages'], 'message')}, "
        f"{plural(counts['teams'], 'team')}, and {plural(counts['tasks'], 'task')}."
    )
    return Outcome(counts, text)


# ---------------------------------------------------------------------------
# Protocol
# ---------------------------------------------------------------------------

#: The skill's documentation; the protocol is the text between the markers.
SKILL_DOCUMENT = Path(__file__).resolve().parent.parent / "SKILL.md"
PROTOCOL_BEGIN = "<!-- protocol:begin -->"
PROTOCOL_END = "<!-- protocol:end -->"


def protocol_text() -> str:
    """Return the agents' protocol, read from between its markers in SKILL.md.

    SKILL.md is the protocol's only copy, so what this prints can never
    drift from what the skill documents.
    """
    try:
        document = SKILL_DOCUMENT.read_text(encoding="utf-8")
    except OSError as error:
        raise UserError(f"cannot read the protocol from {SKILL_DOCUMENT}: {error.strerror or error}") from error
    begin, end = document.find(PROTOCOL_BEGIN), document.find(PROTOCOL_END)
    if begin < 0 or end < begin:
        raise UserError(f"{SKILL_DOCUMENT} lacks the {PROTOCOL_BEGIN} and {PROTOCOL_END} markers")
    return document[begin + len(PROTOCOL_BEGIN) : end].strip()


def cmd_protocol(args: argparse.Namespace, conn: Optional[sqlite3.Connection]) -> Outcome:
    """Print the protocol agents follow, ready to paste into a brief.

    It needs no board, so ``conn`` is None.
    """
    text = protocol_text()
    return Outcome({"protocol": text}, text)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


class BoardArgumentParser(argparse.ArgumentParser):
    """An argument parser whose usage errors are one-line UserErrors.

    argparse normally prints the usage and exits with status 2; here every
    user error exits with status 1 and a single line instead.
    """

    def error(self, message: str) -> None:  # type: ignore[override]
        """Turn an argparse usage error into a UserError."""
        raise UserError(f"{message} (see '{self.prog} --help')")


def positive_int(text: str) -> int:
    """argparse type for a whole number of at least 1."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a whole number, got {text!r}") from None
    if value < 1:
        raise argparse.ArgumentTypeError(f"expected a number of at least 1, got {value}")
    return value


def positive_number(text: str) -> float:
    """argparse type for a finite number greater than zero, such as seconds or days."""
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a number, got {text!r}") from None
    if not (math.isfinite(value) and value > 0):
        raise argparse.ArgumentTypeError(f"expected a number above 0, got {text!r}")
    return value


def build_parser() -> BoardArgumentParser:
    """Build the parser for every command.

    ``--json`` is accepted before or after the command name. The copy each
    command gets defaults to SUPPRESS so that, when left out there, it does
    not overwrite a ``--json`` given before the command.
    """
    json_flag = argparse.ArgumentParser(add_help=False)
    json_flag.add_argument(
        "--json", action="store_true", default=argparse.SUPPRESS, help="print JSON instead of text"
    )
    parser = BoardArgumentParser(
        prog=PROG,
        description="Message board for coding agents that share this repository.",
        allow_abbrev=False,
    )
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    commands = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)

    def command(
        name: str, handler: Any, summary: str, *, needs_board: bool = True, group: Any = None
    ) -> argparse.ArgumentParser:
        """Add one command, remembering the function that runs it.

        It is a top-level command, or a subcommand of ``group`` (made by
        ``command_group``) when one is given.
        """
        sub = (commands if group is None else group).add_parser(
            name, help=summary, description=summary, parents=[json_flag], allow_abbrev=False
        )
        sub.set_defaults(handler=handler, needs_board=needs_board)
        return sub

    def command_group(name: str, summary: str) -> Any:
        """Add a top-level command that only holds subcommands; return their collection."""
        sub = commands.add_parser(name, help=summary, description=summary, allow_abbrev=False)
        return sub.add_subparsers(dest=f"{name}_command", metavar="SUBCOMMAND", required=True)

    register = command("register", cmd_register, "create or update an agent")
    register.add_argument("name", help="your agent name, such as your task slug")
    register.add_argument("--role", help="one line saying what you are working on (needed the first time)")
    register.add_argument("--branch", help="the git branch you work on (needed the first time)")
    register.add_argument(
        "--files",
        nargs="+",
        action="extend",
        default=[],
        metavar="PATH",
        help="paths or globs you expect to edit, relative to the repository root (added to your claims)",
    )
    register.add_argument(
        "--team",
        nargs="+",
        action="extend",
        default=[],
        metavar="TEAM",
        help="teams to join (TEAM or team:TEAM; the team must exist)",
    )

    heartbeat = command("heartbeat", cmd_heartbeat, "refresh an agent's last-seen time")
    heartbeat.add_argument("name", help="your agent name")

    agents = command("agents", cmd_agents, "list agents and what they are doing")
    agents.add_argument(
        "--active-within",
        type=positive_int,
        metavar="MINUTES",
        help="only agents seen in the last MINUTES minutes",
    )

    activity = command("activity", cmd_activity, "say what you are doing now")
    activity.add_argument("name", help="your agent name")
    activity.add_argument("activity", choices=ACTIVITIES, help="what you are doing")
    activity.add_argument("--note", help="one line of detail, such as the command being run")

    claim = command("claim", cmd_claim, "claim paths or globs you are editing")
    claim.add_argument("name", help="your agent name")
    claim.add_argument(
        "paths", nargs="+", metavar="PATH", help="paths or globs relative to the repository root"
    )

    release = command("release", cmd_release, "release paths or globs you claimed")
    release.add_argument("name", help="your agent name")
    release.add_argument("paths", nargs="*", metavar="PATH", help="claims to release, as they were claimed")
    release.add_argument("--all", action="store_true", help="release every claim you hold")

    claims = command("claims", cmd_claims, "list claims and flag overlaps between agents")
    claims.add_argument("path", nargs="?", metavar="PATH", help="only the claims that cover this path or glob")

    since_help = (
        "a message id (messages after it) or a local date and time such as "
        "2026-10-02T14:05 or 14:05 (messages from then on)"
    )

    team_help = "only messages in this team's channel (TEAM or team:TEAM)"

    post = command("post", cmd_post, "post a message to one agent, a team's channel, or all")
    post.add_argument("sender", metavar="FROM", help="your agent name")
    post.add_argument("--topic", help="a one-line subject (a reply may leave it out)")
    post.add_argument(
        "--to",
        metavar="NAME",
        help=(
            "an agent name, team:TEAM for a team's channel, or 'all' (default: all; a reply goes back to the "
            "author of the message it answers, or stays in its team's channel)"
        ),
    )
    post.add_argument("--tag", choices=TAGS, default="notice", help="the kind of message (default: notice)")
    post.add_argument(
        "--file",
        action="append",
        default=[],
        metavar="PATH",
        help="a path or glob the message is about, so it reaches whoever claims it; repeat for more",
    )
    body = post.add_mutually_exclusive_group()
    body.add_argument("--body", help="the message text (at most 16 KB)")
    body.add_argument("--body-file", metavar="FILE", help="read the text from FILE, or from standard input if FILE is -")
    post.add_argument("--reply-to", type=positive_int, metavar="ID", help="the message this one answers")

    read = command("read", cmd_read, "show the public log of messages")
    read.add_argument("--since", type=parse_since, metavar="ID_OR_TIME", help=since_help)
    read.add_argument("--tag", choices=TAGS, help="only messages of this kind")
    read.add_argument("--team", metavar="TEAM", help=team_help)
    read.add_argument("--from", dest="sender", metavar="NAME", help="only messages from this agent")
    read.add_argument(
        "--last",
        type=positive_int,
        metavar="N",
        help=f"only the last N messages (default {DEFAULT_READ_COUNT} unless --since is given)",
    )

    thread = command("thread", cmd_thread, "show a message with its replies")
    thread.add_argument("id", type=positive_int, metavar="ID", help="any message in the conversation")

    inbox = command("inbox", cmd_inbox, "show messages to you, to all, or about files you claim")
    inbox.add_argument("name", help="your agent name")
    inbox.add_argument("--unread", action="store_true", help="only messages you have not been shown yet")
    inbox.add_argument("--since", type=parse_since, metavar="ID_OR_TIME", help=since_help)
    inbox.add_argument("--tag", choices=TAGS, help="only messages of this kind")
    inbox.add_argument("--last", type=positive_int, metavar="N", help="only the last N messages")
    inbox.add_argument("--peek", action="store_true", help="leave the messages shown unread")
    inbox.add_argument("--team", metavar="TEAM", help=team_help)

    watch = command("watch", cmd_watch, "print your unread messages, then new ones as they arrive")
    watch.add_argument("name", help="your agent name")
    watch.add_argument(
        "--once",
        action="store_true",
        help="print what is unread now and return at once (exit status 2 if anything was printed, else 0)",
    )
    watch.add_argument(
        "--interval",
        type=positive_number,
        default=DEFAULT_WATCH_INTERVAL,
        metavar="SECONDS",
        help=f"how often to check for new messages (default {DEFAULT_WATCH_INTERVAL:g})",
    )
    watch.add_argument(
        "--timeout", type=positive_number, metavar="SECONDS", help="stop after this long (default: run until interrupted)"
    )
    watch.add_argument("--peek", action="store_true", help="leave the messages printed unread")
    watch.add_argument("--team", metavar="TEAM", help=team_help)

    team = command_group("team", "create a team or change its members")
    team_create = command("create", cmd_team_create, "create a team with its lead and purpose", group=team)
    team_create.add_argument("name", help="your agent name")
    team_create.add_argument("team", metavar="TEAM", help="the new team's name, such as board")
    team_create.add_argument("--purpose", required=True, help="one line saying what the team is for")
    team_create.add_argument("--lead", metavar="AGENT", help="the agent who leads the team (default: you)")
    team_add = command("add", cmd_team_add, "add members to a team", group=team)
    team_add.add_argument("name", help="your agent name")
    team_add.add_argument("team", metavar="TEAM", help="the team to add them to")
    team_add.add_argument("agents", nargs="+", metavar="AGENT", help="registered agents to add")
    team_remove = command("remove", cmd_team_remove, "remove members from a team", group=team)
    team_remove.add_argument("name", help="your agent name")
    team_remove.add_argument("team", metavar="TEAM", help="the team to remove them from")
    team_remove.add_argument("agents", nargs="+", metavar="AGENT", help="members to remove")

    teams = command("teams", cmd_teams, "list teams with their lead and members, or show one")
    teams.add_argument("team", nargs="?", metavar="TEAM", help="only this team")

    task = command_group("task", "add tasks to a team's list and move them through their states")
    task_add = command("add", cmd_task_add, "add a task to a team's list", group=task)
    task_add.add_argument("name", help="your agent name")
    task_add.add_argument("team", metavar="TEAM", help="the team whose list gets the task")
    task_add.add_argument("--title", required=True, help="one line saying what the task is")
    task_add.add_argument("--brief", metavar="PATH", help="the task's brief, relative to the repository root")
    task_add.add_argument(
        "--files",
        nargs="+",
        action="extend",
        default=[],
        metavar="PATH",
        help="paths or globs the task will touch",
    )
    task_add.add_argument("--assign", metavar="AGENT", help="the agent who takes the task; it may register later")
    task_assign = command("assign", cmd_task_assign, "give a task to an agent", group=task)
    task_assign.add_argument("name", help="your agent name")
    task_assign.add_argument("id", type=positive_int, metavar="ID", help="the task's number")
    task_assign.add_argument(
        "agent", metavar="AGENT", help="the agent who takes the task; it may register later"
    )
    task_assign.add_argument("--note", help="one line to go with the change")
    task_move = command("move", cmd_task_move, "move a task to another state", group=task)
    task_move.add_argument("name", help="your agent name")
    task_move.add_argument("id", type=positive_int, metavar="ID", help="the task's number")
    task_move.add_argument("state", choices=TASK_STATES, help="the task's new state")
    task_move.add_argument("--note", help="one line to go with the change")

    tasks = command("tasks", cmd_tasks, "list tasks by team, state, or agent")
    tasks.add_argument("--team", metavar="TEAM", help="only this team's tasks")
    tasks.add_argument("--state", choices=TASK_STATES, help="only tasks in this state")
    tasks.add_argument("--agent", metavar="AGENT", help="only tasks assigned to this agent")

    purge = command("purge", cmd_purge, "delete old messages, and agents and teams idle for a while")
    purge.add_argument(
        "--older-than",
        type=positive_number,
        required=True,
        metavar="DAYS",
        help=(
            "delete messages posted, agents last seen, and teams last active more than DAYS days ago"
            " (fractions allowed)"
        ),
    )

    reset = command("reset", cmd_reset, "delete every agent, claim, message, team, and task")
    reset.add_argument("--yes", action="store_true", help="confirm that everything should go")

    command("protocol", cmd_protocol, "print the protocol agents follow, for an agent brief", needs_board=False)
    return parser


def run_command(args: argparse.Namespace) -> Outcome:
    """Run the parsed command, opening the board only for commands that use it."""
    if not args.needs_board:
        return args.handler(args, None)
    with contextlib.closing(open_board()) as conn:
        return args.handler(args, conn)


def print_outcome(outcome: Outcome, as_json: bool) -> None:
    """Print a command's result as JSON or as text, unless already printed."""
    if outcome.printed:
        return
    if as_json:
        print(json.dumps(outcome.data, indent=2, ensure_ascii=False))
    elif outcome.text:
        print(outcome.text)


def report_error(message: str) -> int:
    """Print an error as a single line on standard error; return status 1."""
    print(f"{PROG}: error: {' '.join(message.split())}", file=sys.stderr)
    return EXIT_USER_ERROR


def main(argv: Optional[List[str]] = None) -> int:
    """Run one command and return its exit status."""
    try:
        args = build_parser().parse_args(argv)
        outcome = run_command(args)
    except UserError as error:
        return report_error(str(error))
    except sqlite3.Error as error:
        return report_error(f"board database error: {error}")
    except BrokenPipeError:
        raise  # handled at the entry point below
    except OSError as error:
        return report_error(f"cannot use the board: {error}")
    print_outcome(outcome, args.json)
    return outcome.code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # Whoever read our output stopped early (for example `| head`); point
        # stdout at /dev/null so Python's exit-time flush stays quiet.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(EXIT_USER_ERROR)
    except KeyboardInterrupt:
        sys.exit(130)
