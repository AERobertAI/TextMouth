"""``check``: every section's status names open issues, and every issue it names is one.

    python3 -I .claude/skills/doc-library/scripts/doclib.py check

For each section of the docs, AGENTS.md, and CLAUDE.md whose marker gives a
``status`` or ``issues``, it fails:

- a status that names no issue, and issues given without a status;
- an issue that has no file in ``Issues/`` (the TODO's open items are issue files,
  so an ID only the TODO holds is a done item);
- an issue that is closed: done, wontfix, or duplicate.

Each problem is one hit, ``path:line-line  heading  problem``, all of them printed.
Exit status 0 when there are none, 1 otherwise. The issue files are read with the
issue-library skill's own reader.
"""

from __future__ import annotations

import sys
from types import ModuleType
from typing import Any, Dict, Iterator

import issuelinks
import output
from docmodel import Marker
from output import Hit


def problems_of(marker: Marker, library: ModuleType, store: Any, statuses: Dict[str, str]) -> Iterator[str]:
    """What is wrong with one marker's status and issues, given each issue file's status."""
    if marker.status and not marker.issues:
        yield f"status {marker.status} names no issue: add issues: ID for the work that would finish it"
    if marker.issues and not marker.status:
        yield "issues without a status: give status: incomplete or planned"
    for issue_id in marker.issues:
        if not library.issueids.is_issue_id(issue_id):
            yield f"{issue_id} is not an ID"
        elif issue_id not in statuses:
            yield f"{issue_id} has no file in Issues/{store.whereabouts(issue_id)}"
        elif statuses[issue_id] in library.issuefile.CLOSED:
            yield (f"{issue_id} is {statuses[issue_id]}: update the section, and drop the issue "
                   "(and the status, if no other is open)")


def run(args: Any) -> int:
    """Check every marked section; 0 when nothing is wrong, else 1."""
    library = issuelinks.issue_library()
    store = library.Store(args.root)
    statuses = {path.stem: store.read(path).value("status") for path in store.issue_files()}
    checked = 0

    def hits() -> Iterator[Hit]:
        """One hit for each problem of each marked section."""
        nonlocal checked
        for page, section, marker in issuelinks.marked_sections(args.root):
            checked += 1
            for problem in problems_of(marker, library, store, statuses):
                yield Hit(page.path, marker.line, marker.line, section.heading, problem,
                          extra={"id": marker.id, "status": marker.status, "issues": marker.issues})

    total = output.emit(hits(), args, noun="problems")
    if total:
        print(f"doclib check: {total} problems in the {checked} sections with a status or issues", file=sys.stderr)
        return output.EXIT_NONE
    print(f"doclib check: {checked} sections with a status or issues, no problems", file=sys.stderr)
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``check`` subcommand."""
    parser = subparsers.add_parser(
        "check", parents=[common], help="fail a section status that names no open issue",
        description="Check that every section marked incomplete or planned names issues, and that each is an "
                    "open issue file in Issues/.")
    parser.set_defaults(func=run, default_max=0)
