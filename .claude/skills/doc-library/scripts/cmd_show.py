"""``show TARGET``: print one section exactly as written.

    python3 -I .claude/skills/doc-library/scripts/doclib.py show docs/user/feeds.md#Subscribing
    python3 -I .claude/skills/doc-library/scripts/doclib.py show docs/user/feeds.md:120
    python3 -I .claude/skills/doc-library/scripts/doclib.py show epub-headings

The first line is a hit for the section (its place, heading, and id), then the
section's lines. A section longer than 12,000 characters is cut at a line end, with
a last line that says which lines are missing; ``--all`` prints every line. The
last lines are the marker's ``src`` paths, ``src: PATH``, with ``(missing)`` after one
that names no file.
A target that names nothing is a usage error (exit status 2); otherwise exit 0.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, List, Tuple

import output
import targets
from docmodel import Page, Section
from output import Hit
from repofiles import RepoFiles

# The most characters of a section printed unless --all is given.
CHAR_LIMIT = 12000


def numbered(page: Page, number: int, with_numbers: bool) -> str:
    """Line ``number`` as printed: with its number and a tab when ``with_numbers``."""
    text = page.lines[number - 1]
    return f"{number}\t{text}" if with_numbers else text


def shown_lines(page: Page, section: Section, with_numbers: bool, show_all: bool) -> Tuple[List[str], int]:
    """The lines to print and the number of the last line printed.

    Printing stops before the line that would take the total past ``CHAR_LIMIT``
    characters (line ends counted); the first line is always printed.
    """
    printed: List[str] = []
    total = 0
    last = section.start - 1
    for number in range(section.start, section.end + 1):
        line = numbered(page, number, with_numbers)
        if not show_all and printed and total + len(line) + 1 > CHAR_LIMIT:
            break
        printed.append(line)
        total += len(line) + 1
        last = number
    return printed, last


def section_summary(section: Section) -> str:
    """The text of the first line: the section's id, or that it has no marker."""
    if section.marker and section.marker.id:
        return f"id: {section.marker.id}"
    return "no marker"


def src_entries(root: Path, section: Section) -> List[Tuple[str, bool]]:
    """The marker's ``src`` paths, each with whether it names a file of the repository."""
    sources = section.marker.src if section.marker else []
    if not sources:
        return []  # nothing to check, so skip listing the repository's files
    repo = RepoFiles.load(root)
    return [(path, bool(repo.resolve(path))) for path in sources]


def json_object(page: Page, section: Section, show_all: bool, sources: List[Tuple[str, bool]]) -> dict:
    """The ``--json`` form: the section's place, marker fields, and printed lines."""
    marker = section.marker
    lines, last = shown_lines(page, section, False, show_all)
    return {
        "path": page.path, "start": section.start, "end": section.end, "span_end": section.span_end,
        "heading": section.heading, "title": section.title, "level": section.level,
        "id": marker.id if marker else None, "keys": marker.keys if marker else [],
        "status": marker.status if marker else None, "issues": marker.issues if marker else [],
        "src": [{"path": path, "exists": exists} for path, exists in sources], "lines": lines, "truncated": last < section.end,
    }


def run(args: Any) -> int:
    """Print the section that ``args.target`` names."""
    page, section = targets.resolve_target(args.root, args.target)
    sources = src_entries(args.root, section)
    if args.json:
        print(json.dumps(json_object(page, section, args.all, sources), ensure_ascii=False))
        return output.EXIT_OK
    printed, last = shown_lines(page, section, args.numbers, args.all)
    print(output.format_hit(Hit(page.path, section.start, section.end, section.heading,
                                section_summary(section))))
    for line in printed:
        print(line)
    if last < section.end:
        print(f"{output.ELLIPSIS} lines {last + 1}-{section.end} not shown; --all shows them")
    for path, exists in sources:
        print(f"src: {path}" + ("" if exists else " (missing)"))
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``show`` subcommand."""
    parser = subparsers.add_parser(
        "show", parents=[common], help="print one section as written",
        description="Print one section. TARGET is PAGE#HEADING, PAGE:LINE, or a marker id.")
    parser.add_argument("target", help="PAGE#HEADING, PAGE:LINE, or a section id")
    parser.add_argument("--numbers", action="store_true", help="start each line with its number and a tab")
    parser.add_argument("--all", action="store_true", help=f"do not stop after {CHAR_LIMIT} characters")
    parser.set_defaults(func=run, default_max=0)
