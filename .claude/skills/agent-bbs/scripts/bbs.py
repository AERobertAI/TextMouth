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
is 0 on success and 1 on a user error, which is reported as one line on
standard error. Only the Python standard library is used: no network, no
daemons, no third-party packages.

Run ``bbs.py --help`` or ``bbs.py COMMAND --help`` for the commands.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import difflib
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Iterator, List, Optional

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

#: Version of the table layout, kept in SQLite's user_version header field.
SCHEMA_VERSION = 1

#: Seconds a command waits for another process's write before giving up.
BUSY_TIMEOUT_SECONDS = 30.0

#: Recipient name that addresses every agent; no agent may register it.
EVERYONE = "all"

#: Agent names: lower-case letters, digits, '.', '_' and '-', at most 40.
NAME_RULE = re.compile(r"[a-z0-9][a-z0-9._-]{0,39}")

#: Longest accepted one-line field (role, branch, topic, activity note).
MAX_LINE_LENGTH = 200

#: Exit statuses.
EXIT_OK = 0
EXIT_USER_ERROR = 1

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
    ``code`` becomes the exit status.
    """

    data: Any
    text: str
    code: int = EXIT_OK


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


# ---------------------------------------------------------------------------
# Field validation
# ---------------------------------------------------------------------------


def normalize_name(raw: str) -> str:
    """Return the canonical form of an agent name, or raise UserError.

    Names are case-insensitive: they are stored and shown in lower case, so
    "Orchestrator" and "orchestrator" are the same agent.
    """
    name = raw.strip().lower()
    if name == EVERYONE:
        raise UserError(f"'{EVERYONE}' addresses every agent and cannot be an agent name")
    if not NAME_RULE.fullmatch(name):
        raise UserError(
            f"invalid agent name {raw!r}: use 1 to 40 letters, digits, '.', '_' "
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


def _create_schema(conn: sqlite3.Connection) -> None:
    """Create the tables on first use and refuse boards from newer scripts."""
    if conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION:
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
        for statement in SCHEMA:
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


def _did_you_mean(conn: sqlite3.Connection, name: str) -> str:
    """Suggest the registered agent name closest to a mistyped one, if any."""
    names = [row["name"] for row in conn.execute("SELECT name FROM agents")]
    close = difflib.get_close_matches(name, names, n=1)
    return f" (did you mean '{close[0]}'?)" if close else ""


def load_agents(
    conn: sqlite3.Connection, *, name: Optional[str] = None, seen_since: Optional[str] = None
) -> List[dict]:
    """Return agents as JSON-ready dicts, ordered by name.

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
    return [
        {
            "name": row["name"],
            "role": row["role"],
            "branch": row["branch"],
            "registered": row["registered_at"],
            "last_seen": row["last_seen"],
            "activity": row["activity"],
            "activity_note": row["activity_note"],
            "activity_since": row["activity_since"],
        }
        for row in rows
    ]


def describe_agent(agent: dict) -> str:
    """Describe one agent in a few lines: status line, then role and branch."""
    activity = f"{agent['activity']} since {local_label(agent['activity_since'])}"
    if agent["activity_note"]:
        activity += f" ({agent['activity_note']})"
    seen = agent["last_seen"]
    return "\n".join(
        [
            f"{agent['name']}: {activity}; last seen {local_label(seen)}, {ago_label(seen)}",
            f"  Role: {agent['role']}",
            f"  Branch: {agent['branch']}",
        ]
    )


def cmd_register(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Create an agent, or update an existing one's role and branch.

    The first registration needs both --role and --branch; later ones may
    give either, and what they leave out is kept.
    """
    name = normalize_name(args.name)
    role = None if args.role is None else one_line(args.role, "role")
    branch = None if args.branch is None else one_line(args.branch, "branch")
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
        agent = load_agents(conn, name=name)[0]
    verb = "Registered" if created else "Updated"
    return Outcome({"created": created, "agent": agent}, f"{verb} {name}.\n{describe_agent(agent)}")


def cmd_heartbeat(args: argparse.Namespace, conn: sqlite3.Connection) -> Outcome:
    """Refresh an agent's last-seen time."""
    with write_transaction(conn):
        name = require_agent(conn, args.name)
        agent = load_agents(conn, name=name)[0]
    return Outcome(agent, f"{name} last seen {local_label(agent['last_seen'])}.")


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

    def command(name: str, handler: Any, summary: str) -> argparse.ArgumentParser:
        """Add one command, remembering the function that runs it."""
        sub = commands.add_parser(
            name, help=summary, description=summary, parents=[json_flag], allow_abbrev=False
        )
        sub.set_defaults(handler=handler)
        return sub

    register = command("register", cmd_register, "create or update an agent")
    register.add_argument("name", help="your agent name, such as your task slug")
    register.add_argument("--role", help="one line saying what you are working on (needed the first time)")
    register.add_argument("--branch", help="the git branch you work on (needed the first time)")

    heartbeat = command("heartbeat", cmd_heartbeat, "refresh an agent's last-seen time")
    heartbeat.add_argument("name", help="your agent name")

    agents = command("agents", cmd_agents, "list agents and what they are doing")
    agents.add_argument(
        "--active-within",
        type=positive_int,
        metavar="MINUTES",
        help="only agents seen in the last MINUTES minutes",
    )
    return parser


def run_command(args: argparse.Namespace) -> Outcome:
    """Open the board and run the parsed command against it."""
    with contextlib.closing(open_board()) as conn:
        return args.handler(args, conn)


def print_outcome(outcome: Outcome, as_json: bool) -> None:
    """Print a command's result as JSON or as text."""
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
