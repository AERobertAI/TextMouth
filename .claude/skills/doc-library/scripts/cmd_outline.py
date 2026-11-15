"""``outline PAGE``: every section of one page, with its id, size, and lines.

    python3 -I .claude/skills/doc-library/scripts/doclib.py outline docs/user/feeds.md

One hit for each section, in page order, none left out: the section's lines, its
heading as written (``(top)`` for text before the first heading), and its marker id
(``no id`` when it has none) with its size in lines and bytes. The name of the page may
be its tail (see ``targets.resolve_page``). Exit status 0.
"""

from __future__ import annotations

from typing import Any, Iterator

import docmodel
import output
import targets
from docmodel import Page, Section
from output import Hit

# What the heading column shows for text before a page's first heading.
TOP_LABEL = "(top)"
# What the text shows for a section without a marker id. Words, not a dash, and commas
# between the fields, so a screen reader does not speak "minus 4 lines".
NO_ID = "no id"


def section_bytes(page: Page, section: Section) -> int:
    """The UTF-8 size of the section's lines ``start..end``, each with its line end."""
    return sum(len(line.encode("utf-8")) + 1 for line in page.lines[section.start - 1:section.end])


def outline_hit(page: Page, section: Section) -> Hit:
    """The hit that describes one section of ``page``."""
    heading = "#" * section.level + " " + section.title if section.level else TOP_LABEL
    ident = section.marker.id if section.marker and section.marker.id else None
    lines = section.end - section.start + 1
    size = section_bytes(page, section)
    return Hit(
        path=page.path, start=section.start, end=section.end, heading=heading,
        text=f"{ident or NO_ID}, {lines} lines, {size} bytes",
        extra={"id": ident, "level": section.level, "title": section.title, "lines": lines,
               "bytes": size, "path_titles": list(section.path)},
    )


def hits_for(page: Page) -> Iterator[Hit]:
    """One hit for each section of the page, in order."""
    for section in page.sections:
        yield outline_hit(page, section)


def run(args: Any) -> int:
    """Print the outline of the named page; the exit status is always 0."""
    page = docmodel.load_page(args.root, targets.resolve_page(args.root, args.page))
    output.emit(hits_for(page), args, noun="sections")
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``outline`` subcommand."""
    parser = subparsers.add_parser(
        "outline", parents=[common], help="list the sections of one page, with ids and sizes",
        description="List every section of a page: its lines, heading, marker id, and size.")
    parser.add_argument("page", help="a page path, or its tail (feeds, user/feeds)")
    parser.set_defaults(func=run, default_max=0)
