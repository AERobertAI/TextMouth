"""``find PATTERN``: search the docs for a phrase, and print each match as one sentence or line.

    python3 -I .claude/skills/doc-library/scripts/doclib.py find "nav document"
    python3 -I .claude/skills/doc-library/scripts/doclib.py find --fixed "Files:" --area architecture

The pattern is a Python regular expression matched ignoring case (``--fixed``: plain
text). It is matched against *units*: a section's heading, its marker line (so an id,
a search word, or a source path is found), each sentence of its prose, and each line
of its code, tables, and HTML. White space in a unit is collapsed first, so a phrase
broken over two lines still matches. A hit is the unit alone, not its whole paragraph.
Exit status 0 when something matched, 1 when nothing did, 2 for a bad pattern.
"""

from __future__ import annotations

import re
from typing import Any, Iterator, List

import docmodel
import output
from docmodel import Page, Section
from output import Hit, UsageError

# The folders of docs/ that --area can name.
AREAS = ("user", "architecture", "developer", "agents")


def compile_pattern(pattern: str, fixed: bool) -> "re.Pattern[str]":
    """The case-insensitive regular expression for ``pattern`` (plain text when ``fixed``).

    A pattern Python cannot compile is a UsageError that says why.
    """
    if not pattern:
        raise UsageError("the pattern is empty")
    try:
        return re.compile(re.escape(pattern) if fixed else pattern, re.IGNORECASE)
    except re.error as error:
        raise UsageError(f"bad pattern {pattern!r}: {error}") from None


def section_hits(page: Page, section: Section, regex: "re.Pattern[str]") -> Iterator[Hit]:
    """One hit for each unit of the section whose collapsed text the pattern matches."""
    marker_id = section.marker.id if section.marker else None
    for unit in docmodel.units(page, section):
        text = output.collapse(unit.text)
        match = regex.search(text)
        if match is None:
            continue
        yield Hit(
            path=page.path, start=unit.start, end=unit.end, heading=section.heading, text=text,
            focus=match.span(),
            extra={"kind": unit.kind, "id": marker_id,
                   "section_start": section.start, "section_end": section.end},
        )


def pages_to_search(args: Any) -> List[str]:
    """The pages of ``--scope``, narrowed to ``docs/AREA/`` when ``--area`` is given."""
    if args.area and args.scope == "memory":
        raise UsageError("--area names a folder of docs/, so it cannot be used with --scope memory")
    pages = docmodel.scope_pages(args.root, args.scope)
    if args.area:
        prefix = f"docs/{args.area}/"
        pages = [page for page in pages if page.startswith(prefix)]
    return pages


def run(args: Any) -> int:
    """Search the pages and print the hits; 0 when there were some, else 1."""
    regex = compile_pattern(args.pattern, args.fixed)
    pages = pages_to_search(args)

    def all_hits() -> Iterator[Hit]:
        """The hits of every page, pages in scope order, units in line order."""
        for path in pages:
            page = docmodel.load_page(args.root, path)
            for section in page.sections:
                yield from section_hits(page, section, regex)

    total = output.emit(all_hits(), args)
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``find`` subcommand."""
    parser = subparsers.add_parser(
        "find", parents=[common], help="search the docs; each hit is one sentence or line",
        description="Search the docs for a regular expression (ignoring case); print each matching sentence or line.")
    parser.add_argument("pattern", help="a Python regular expression (or plain text with --fixed)")
    parser.add_argument("--fixed", action="store_true", help="treat the pattern as plain text")
    parser.add_argument("--area", choices=AREAS, default=None,
                        help="only the pages under docs/AREA/ (not with --scope memory)")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
