"""``incomplete``: the sections that describe something missing, limited, or not built yet, with their issues.

    python3 -I .claude/skills/doc-library/scripts/doclib.py incomplete
    python3 -I .claude/skills/doc-library/scripts/doclib.py incomplete --issue DR04 --status planned

Such a section's marker gives ``status: incomplete`` (or ``planned``) and the issues
that track it:

    <!-- id: library-search-limits; keys: ...; status: incomplete; issues: DR01, DR02 -->

One hit for each, ``path:start-end  heading  incomplete: DR01, DR02``; a marker with
issues and no status shows ``no status``, which ``doclib check`` fails. ``--issue``
keeps the sections that name that issue, and ``--status`` those with that status.
The pages are the lint's (the docs, AGENTS.md, and CLAUDE.md), so ``--scope`` does
not apply. Exit status 0 when some section is listed, 1 when none is.
"""

from __future__ import annotations

from typing import Any, Iterator

import docmodel
import issuelinks
import output
from output import Hit


def run(args: Any) -> int:
    """List the marked sections that pass the filters; 0 when there are some, else 1."""

    def hits() -> Iterator[Hit]:
        """One hit for each section whose marker gives a status or issues."""
        for page, section, marker in issuelinks.marked_sections(args.root):
            if args.issue and args.issue not in marker.issues:
                continue
            if args.status and marker.status != args.status:
                continue
            text = f"{marker.status or 'no status'}: {', '.join(marker.issues) or 'no issue'}"
            yield Hit(page.path, section.start, section.end, section.heading, text,
                      extra={"id": marker.id, "status": marker.status, "issues": marker.issues})

    total = output.emit(hits(), args, noun="sections")
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``incomplete`` subcommand."""
    parser = subparsers.add_parser(
        "incomplete", parents=[common], help="the sections marked incomplete or planned, with their issues",
        description="List the sections whose marker gives a status (incomplete or planned) or issues.")
    parser.add_argument("--issue", metavar="ID", help="only the sections that name this issue")
    parser.add_argument("--status", choices=docmodel.MARKER_STATUSES, help="only the sections with this status")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
