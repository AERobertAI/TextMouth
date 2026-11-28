"""``mark PAGE [--dry-run]``: give every heading of a page without a marker one, for an agent to fill in.

    python3 -I .claude/skills/doc-library/scripts/doclib.py mark docs/architecture/platforms.md --dry-run

``docs/agents/writing-docs.md`` asks every section to carry a marker on the line under
its heading:

    <!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->

``mark`` saves typing them. Each heading that has no marker gets one on the line
straight after it, holding a suggested ``id`` (made from the heading's words), the
``src`` that ``suggest_paths`` finds, and an empty ``keys`` for the agent to fill in.
Nothing else on the page changes: a section with a marker (a stray one too) is left
alone, and so is the text before the first heading.

The pure parts are ``suggest_id`` and ``marker_line``. The command reads the page with
``pagewrite.read_page_text``, checks that taking the added lines out gives back the old
text and that the new text parses to the ids it gave, and writes through
``pagewrite.rewrite``, which adds its own word check. Any failed check writes nothing.

Output: one hit for each added marker (the page and the marker's line in the new text,
the section's heading, the marker line), and a count on standard error. Exit status: 0
when markers were added or none were needed (``--dry-run`` too); 1 when a check failed.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from typing import Any, Iterator, List, Set

import docmodel
import output
import pagewrite
import targets
from cmd_suggest_src import Suggestion, suggest_paths
from docmodel import Page, Section
from output import Hit
from repofiles import RepoFiles
from swiftindex import SwiftIndex

# Words an id leaves out (while other words remain).
STOP_WORDS = frozenset({"a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "by", "its", "is"})
# The most words of a heading an id holds, and the most characters.
ID_WORDS = 5
ID_LENGTH = 40
# The most suggestions that are not from a Files: line a marker's src holds.
MOST_OTHER_PATHS = 5
# The reason ``suggest_paths`` gives a path taken from a Files: line.
_FILES_REASON = "Files: line"
# What a marker's src list cannot hold: it splits at "," and ";", and the comment ends at "-->".
_UNWRITABLE_IN_SRC = (",", ";", "-->")

# A run of lowercase letters and digits: one word of an id.
_WORD = re.compile(r"[a-z0-9]+")
# A possessive ending (straight or curly apostrophe), which an id leaves out: "phone's" is "phone".
_POSSESSIVE = re.compile(r"['’]s\b")
# Any other apostrophe joins its word's halves: "don't" is "dont", not "don" and "t".
_APOSTROPHE = re.compile(r"['’]")


# ---------------------------------------------------------------------------
# Ids and marker lines.
# ---------------------------------------------------------------------------

def _words(text: str) -> List[str]:
    """The words of ``text`` for an id: lowercase runs of letters and digits, ``&`` read as ``and``.

    A possessive ``'s`` is left out and other apostrophes dropped, so a word is never cut in two.
    """
    text = _APOSTROPHE.sub("", _POSSESSIVE.sub("", text.lower()))
    return _WORD.findall(text.replace("&", " and "))


def _cut_at_hyphen(base: str, length: int) -> str:
    """``base`` cut to at most ``length`` characters, at a hyphen when it has one to cut at."""
    if len(base) <= length:
        return base
    # One character more is looked at, so a hyphen exactly at ``length`` leaves whole words.
    hyphen = base[:length + 1].rfind("-")
    return base[:hyphen] if hyphen > 0 else base[:length]


def suggest_id(title: str, page_stem: str, taken: Set[str]) -> str:
    """An id for the heading ``title`` that is not in ``taken``.

    The base is the heading's first ``ID_WORDS`` words, stop words dropped while
    other words remain, joined with hyphens and cut at a hyphen to ``ID_LENGTH``
    characters (``section`` when the title has no letter or digit). The first of
    these not in ``taken`` is the id: the base, ``PAGE_STEM-BASE``, then
    ``PAGE_STEM-BASE-2``, ``-3``, and so on. ``page_stem`` is made into the same
    shape as an id first (``page`` when it has no letter or digit).
    """
    words = _words(targets.strip_markup(title))
    kept = [word for word in words if word not in STOP_WORDS] or words
    base = _cut_at_hyphen("-".join(kept[:ID_WORDS]), ID_LENGTH) or "section"
    stem = "-".join(_words(page_stem)) or "page"
    candidate = base
    if candidate in taken:
        candidate = f"{stem}-{base}"
    number = 2
    while candidate in taken:
        candidate = f"{stem}-{base}-{number}"
        number += 1
    return candidate


def marker_line(ident: str, src: List[str]) -> str:
    """The marker for id ``ident`` with no keys and the paths ``src`` (``src:`` alone when none)."""
    paths = " " + ", ".join(src) if src else ""
    return f"<!-- id: {ident}; keys: ; src:{paths} -->"


def src_paths(suggestions: List[Suggestion]) -> List[str]:
    """The paths a new marker's ``src`` holds: every Files: line path, then at most five others.

    ``suggest_paths`` already lists the Files: paths first, and the others by how
    often the section names them; both orders are kept. A path the marker could not
    write back (one with a comma, a semicolon, or ``-->``) is left out.
    """
    writable = [s for s in suggestions if not any(bad in s.path for bad in _UNWRITABLE_IN_SRC)]
    listed = [s.path for s in writable if s.reason == _FILES_REASON]
    others = [s.path for s in writable if s.reason != _FILES_REASON]
    return listed + others[:MOST_OTHER_PATHS]


# ---------------------------------------------------------------------------
# The command.
# ---------------------------------------------------------------------------

@dataclass
class Addition:
    """One marker to add: its section, its text, and the line it will have in the new text."""

    section: Section   # the section of the old page, whose heading the marker goes under
    line: str          # the marker line
    new_number: int    # 1-based line of the marker in the new text


def _page_ids(page: Page) -> Iterator[str]:
    """Every id the markers of ``page`` give, a stray marker's included."""
    for section in page.sections:
        for marker in ([section.marker] if section.marker else []) + section.stray_markers:
            if marker.id:
                yield marker.id


def taken_ids(root: Any, page: Page) -> Set[str]:
    """The ids of every marker on the lint pages and on ``page`` itself (which may lie outside them)."""
    taken = set(_page_ids(page))
    for lint_page in docmodel.load_pages(root, docmodel.lint_pages(root)):
        taken.update(_page_ids(lint_page))
    return taken


def plan_additions(root: Any, path: str, page: Page) -> List[Addition]:
    """The markers ``page`` needs, in page order: one for each section with a heading and no marker.

    A section with a marker (a stray one too) and the text before the first heading
    give none. Each id is new on the lint pages, on the page, and among those given.
    """
    needing = [s for s in page.sections if s.level >= 1 and s.marker is None and not s.stray_markers]
    if not needing:
        return []
    repo = RepoFiles.load(root)
    index = SwiftIndex.load(repo)
    taken = taken_ids(root, page)
    stem = path.rsplit("/", 1)[-1].removesuffix(".md")
    additions: List[Addition] = []
    for section in needing:
        ident = suggest_id(section.title, stem, taken)
        taken.add(ident)
        line = marker_line(ident, src_paths(suggest_paths(page, section, repo, index)))
        # The marker goes straight under the heading; each earlier addition pushed it one line down.
        additions.append(Addition(section, line, section.start + 1 + len(additions)))
    return additions


def apply_additions(text: str, additions: List[Addition]) -> str:
    """``text`` with each addition's line put straight under its section's heading.

    Only lines are inserted: the page's other lines, its blank lines, and whether it
    ends in a line end or not are as they were. ``text`` must use ``\\n`` line ends.
    """
    bom = "﻿" if text.startswith("﻿") else ""
    body = text[len(bom):]
    ending = "\n" if body.endswith("\n") else ""
    lines = body[:len(body) - len(ending)].split("\n")
    # Insert from the bottom up, so the heading lines above stay where the sections say they are.
    for addition in reversed(additions):
        lines.insert(addition.section.start, addition.line)
    return bom + "\n".join(lines) + ending


def problems_with(old: str, new: str, path: str, additions: List[Addition]) -> List[str]:
    """What is wrong with ``new`` as ``old`` plus the additions, as short sentences; [] when nothing is.

    Three checks: taking the added lines out gives back ``old`` exactly (its last line
    end too); the new text has the same sections (level, title, stray markers); and
    each heading that got a marker now has it, read back with the id it was given.
    """
    problems: List[str] = []
    old_page = docmodel.parse(path, old)
    new_page = docmodel.parse(path, new)
    added = {addition.new_number for addition in additions}
    kept = [line for number, line in enumerate(new_page.lines, 1) if number not in added]
    if kept != old_page.lines or new.endswith("\n") != old.endswith("\n"):
        problems.append("removing the added lines does not give back the old text")
    if [(s.level, s.title, len(s.stray_markers)) for s in old_page.sections] != \
            [(s.level, s.title, len(s.stray_markers)) for s in new_page.sections]:
        problems.append("the new text has other headings or stray markers than the old")
    by_heading_line = {section.start: section for section in new_page.sections}
    for addition in additions:
        wanted = docmodel.parse_marker(addition.new_number, addition.line)
        # The heading is the line just above the marker.
        section = by_heading_line.get(addition.new_number - 1)
        got = section.marker if section else None
        if got is None or wanted is None or got.id != wanted.id or got.errors:
            problems.append(f"line {addition.new_number}: the new marker is not read back as the one made")
    return problems


def run(args: Any) -> int:
    """Add a marker to each section of the page ``args.page`` that lacks one.

    The page is named as every command names one (``targets.resolve_page``): its
    path, or the unique end of it. With ``--dry-run`` everything is done but the write.
    """
    path = targets.resolve_page(args.root, args.page)
    old = pagewrite.read_page_text(args.root, path)
    additions = plan_additions(args.root, path, docmodel.parse(path, old))
    if not additions:
        print(f"mark: {path}: every section has a marker", file=sys.stderr)
        return output.EXIT_OK
    new = apply_additions(old, additions)
    problems = problems_with(old, new, path, additions)
    if not problems and not args.dry_run:
        # rewrite adds its own check (every word is as it was) and writes only when it passes.
        problems = pagewrite.rewrite(args.root, path, old, new)
    if problems:
        print(f"mark: {path}: refused, nothing written")
        for line in problems:
            print(line)
        return output.EXIT_NONE
    output.emit((Hit(path, a.new_number, a.new_number, a.section.heading, a.line) for a in additions),
                args, noun="markers")
    done = "would be added (--dry-run: nothing written)" if args.dry_run else "added"
    print(f"mark: {path}: {len(additions)} markers {done}", file=sys.stderr)
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``mark`` subcommand."""
    parser = subparsers.add_parser(
        "mark", parents=[common],
        help="give every heading of a page without a marker one, to be filled in",
        description="Put a marker on the line under each heading of PAGE that has none: a suggested id, "
                    "an empty keys, and the src that suggest-src finds. Nothing else on the page changes.")
    parser.add_argument("page", help="the page to mark: its path, or the unique end of it")
    parser.add_argument("--dry-run", action="store_true", help="print the markers that would be added; write nothing")
    parser.set_defaults(func=run, default_max=0)
