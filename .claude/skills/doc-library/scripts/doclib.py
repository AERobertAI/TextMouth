#!/usr/bin/env python3
"""doc-library: find, show, and check the sections of TextMouth's docs and memory files.

Run from anywhere inside the repository or one of its worktrees:

    python3 -I .claude/skills/doc-library/scripts/doclib.py COMMAND [ARGS] [OPTIONS]

Every command lives in a module of its own beside this file, named ``cmd_<name>.py``
(``cmd_split_check.py`` for ``split-check``). This file imports each of them and lets
each add its own subcommand, so a new command needs no edit here and two agents
adding commands never edit the same file. A command module defines:

    register(subparsers, common) -> None
        adds its parser with ``subparsers.add_parser(NAME, parents=[common], ...)``
        and sets ``func`` (called with the parsed arguments, returning the exit
        status) and ``default_max`` (its cap on hits when ``--max`` is not given).

The options every command takes (``--root``, ``--scope``, ``--json``, ``--max``) come
from ``common``, and follow the command name. Exit status: 0 when a search found
something or a check passed, 1 when a search found nothing or a check failed, 2 for
a usage error, reported as one line on standard error.

Only the Python standard library is used, and nothing outside the repository's
own folder is ever read.
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from pathlib import Path
from typing import List, Optional

# `python3 -I` leaves the script's own folder off sys.path, so put it back to
# import the modules beside this file. They are this skill's own code; none
# shares a name with a standard-library module.
SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import output  # noqa: E402  (imported after sys.path is set)


def nonnegative_int(text: str) -> int:
    """argparse type for --max: a whole number of at least 0 (0 means no cap)."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a whole number, got {text!r}") from None
    if value < 0:
        raise argparse.ArgumentTypeError(f"expected 0 or more, got {value}")
    return value


def common_options() -> argparse.ArgumentParser:
    """The options every command takes, as a parent parser for each subcommand."""
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--root", type=Path, default=None,
        help="the repository (or worktree) folder; by default the one holding the current folder",
    )
    common.add_argument(
        "--scope", choices=("docs", "memory", "all"), default="docs",
        help="docs: README.md, ARCHITECTURE.md and docs/ (the default); memory: AGENTS.md, "
             "CLAUDE.md, the TODO, AGENT-NOTES, research/, the briefs and humanQuestions/; all: both",
    )
    common.add_argument("--json", action="store_true", help="print each hit as a JSON object on its own line")
    common.add_argument(
        "--max", type=nonnegative_int, default=None, metavar="N",
        help=f"print at most N hits (default {output.DEFAULT_MAX} unless the command says otherwise; 0 prints all)",
    )
    return common


def command_modules() -> list:
    """Import every ``cmd_*.py`` module beside this file, in name order."""
    modules = []
    for path in sorted(SCRIPTS.glob("cmd_*.py")):
        modules.append(importlib.import_module(path.stem))
    return modules


def build_parser() -> argparse.ArgumentParser:
    """The command line: one subcommand for each command module."""
    parser = argparse.ArgumentParser(
        prog="doclib.py",
        description="Find, show, and check the sections of TextMouth's docs and memory files.",
    )
    subparsers = parser.add_subparsers(dest="command", metavar="COMMAND")
    subparsers.required = True
    common = common_options()
    for module in command_modules():
        module.register(subparsers, common)
    return parser


def find_root(start: Path) -> Path:
    """The nearest folder at or above ``start`` that holds a ``.git`` entry.

    A worktree's ``.git`` is a file, the main checkout's a folder; either marks the
    top of the tree whose docs are read. Raises UsageError when there is none.
    """
    start = start.resolve()
    for folder in (start, *start.parents):
        if (folder / ".git").exists():
            return folder
    raise output.UsageError(f"{start} is not inside a git repository; pass --root")


def main(argv: Optional[List[str]] = None) -> int:
    """Parse the command line, run the command, and return its exit status."""
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.root is None:
            args.root = find_root(Path.cwd())
        else:
            args.root = args.root.resolve()
            if not args.root.is_dir():
                raise output.UsageError(f"--root {args.root} is not a folder")
        return args.func(args)
    except output.UsageError as error:
        print(f"doclib: {error}", file=sys.stderr)
        return output.EXIT_USAGE
    except BrokenPipeError:
        # The reader of a pipe (head, say) went away: stop quietly. Point stdout
        # at nothing so Python's own flush at exit does not complain again.
        sys.stdout = open(os.devnull, "w")
        return output.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
