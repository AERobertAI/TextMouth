"""The Markdown model every doc-library command stands on.

A page is split into *blocks* (headings, paragraphs, list items, code, ...) by a small
line-by-line parser, and the blocks into *sections* (one for each heading). A section
may carry a *marker*, the comment line under its heading that names it:

    <!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->

A section that describes something missing, limited, or not built yet also says so,
with the issues (``Issues/<ID>.md``) that track it:

    <!-- id: library-search-limits; keys: ...; status: incomplete; issues: DR01, DR02 -->

The parser knows only as much Markdown as the project's docs use: ATX headings, fenced
and indented code, HTML comments, tables, block quotes, lists, thematic breaks, and
front matter. Setext headings and reference definitions are not recognised.

This module also lists the pages of a scope (``scope_pages``), and reads a page from
disk without ever leaving the repository (``load_page``).
"""

from __future__ import annotations

import bisect
import fnmatch
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

from output import UsageError
from sentences import split_sentences

# ---------------------------------------------------------------------------
# Scopes: which Markdown files a command reads.
# ---------------------------------------------------------------------------

# Each scope is a tuple of entries: a file, a pattern for files in one folder
# (``TODO-*.md``), or ``FOLDER/**/*.md`` for every Markdown file below a folder.
SCOPES = {
    "docs": ("README.md", "ARCHITECTURE.md", "docs/**/*.md"),
    "memory": ("AGENTS.md", "CLAUDE.md", "TODO-*.md", "AGENT-NOTES-*.md", "research/**/*.md",
               "Scripts/agents/briefs/**/*.md", "humanQuestions/**/*.md"),
}
# Pages that are logs: dated history is allowed there, so the lint skips its date rules.
LOG_PAGES = frozenset({"docs/user/changelog.md", "docs/agents/history.md"})


def is_log_page(path: str) -> bool:
    """Whether ``path`` (POSIX, from the root) is a log page, where dated history, and names of what was removed, are allowed.

    The one test the lint's rules and ``stale`` share, so that they agree on what a log is.
    """
    return path in LOG_PAGES


# Pages that index the others, whose lines are links.
INDEX_PAGES = ("README.md", "ARCHITECTURE.md")
# The pages beyond the ``docs`` scope that the lint covers and an id is looked up in.
LINT_EXTRA_PAGES = ("AGENTS.md", "CLAUDE.md")

# The separator of a recursive entry such as ``docs/**/*.md``.
_RECURSIVE = "/**/"


def _is_plain_inside(root_real: str, relative: str) -> bool:
    """Whether ``root/relative`` exists and no part of its path is a symlink.

    A symlink anywhere on the way (the file, or a folder above it) would let a
    page lead out of the repository, so such a path is treated as absent.
    """
    full = os.path.join(root_real, relative)
    return os.path.realpath(full) == full and os.path.lexists(full)


def _entry_pages(root_real: str, entry: str) -> List[str]:
    """The Markdown files one scope entry names, repository-relative, POSIX, sorted."""
    found: List[str] = []
    if _RECURSIVE in entry:
        # ``FOLDER/**/PATTERN``: walk the folder, never following a symlinked folder.
        base, pattern = entry.split(_RECURSIVE, 1)
        if _is_plain_inside(root_real, base) and os.path.isdir(os.path.join(root_real, base)):
            for folder, _dirs, names in os.walk(os.path.join(root_real, base), followlinks=False):
                for name in names:
                    if fnmatch.fnmatchcase(name, pattern):
                        found.append(os.path.relpath(os.path.join(folder, name), root_real))
    elif "*" in entry:
        # ``PATTERN`` for files directly in the repository's top folder.
        for name in os.listdir(root_real):
            if fnmatch.fnmatchcase(name, entry):
                found.append(name)
    else:
        found.append(entry)
    pages = []
    for relative in found:
        relative = relative.replace(os.sep, "/")
        if _is_plain_inside(root_real, relative) and os.path.isfile(os.path.join(root_real, relative)):
            pages.append(relative)
    return sorted(pages)


def scope_pages(root: Path, scope: str) -> List[str]:
    """The Markdown pages of ``scope`` ("docs", "memory", or "all"), as POSIX paths from ``root``.

    The pages come in the order of the scope's entries, each entry's matches sorted;
    ``all`` is ``docs`` then ``memory`` with no page twice. Files are listed from
    the disk, not from git, since briefs and ``humanQuestions/`` are untracked. An
    entry whose file or folder is missing is skipped, and nothing behind a symlink
    is listed.
    """
    if scope == "all":
        entries = SCOPES["docs"] + SCOPES["memory"]
    elif scope in SCOPES:
        entries = SCOPES[scope]
    else:
        raise UsageError(f"unknown scope {scope!r}; choose docs, memory, or all")
    root_real = os.path.realpath(root)
    if not os.path.isdir(root_real):
        return []
    pages: List[str] = []
    seen = set()
    for entry in entries:
        for page in _entry_pages(root_real, entry):
            if page not in seen:
                seen.add(page)
                pages.append(page)
    return pages


def lint_pages(root: Path) -> List[str]:
    """The pages the lint covers: the ``docs`` scope plus ``AGENTS.md`` and ``CLAUDE.md``."""
    pages = scope_pages(root, "docs")
    root_real = os.path.realpath(root)
    for extra in LINT_EXTRA_PAGES:
        if extra not in pages and _is_plain_inside(root_real, extra) \
                and os.path.isfile(os.path.join(root_real, extra)):
            pages.append(extra)
    return pages


# ---------------------------------------------------------------------------
# Markers.
# ---------------------------------------------------------------------------

# What an id looks like: lowercase words joined by single hyphens.
ID_SHAPE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
# The fields a marker may hold.
MARKER_FIELDS = ("id", "keys", "src", "status", "issues")
# The statuses a section may give itself: it describes something missing or limited
# (incomplete), or something not built yet (planned). ``doclib check`` makes each name
# the open issues that track it.
MARKER_STATUSES = ("incomplete", "planned")


@dataclass
class Marker:
    """A parsed marker line: the id, the search words, the code paths, the status and the
    issues that track it, and what is wrong with it."""

    line: int
    raw: str
    id: Optional[str]
    keys: List[str]
    src: List[str]
    errors: List[str]
    status: Optional[str] = None
    issues: List[str] = field(default_factory=list)


def _split_list(value: str) -> List[str]:
    """A comma-separated field value as a list, each part trimmed, empty parts dropped."""
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_marker(line_number: int, text: str) -> Optional[Marker]:
    """Parse ``text`` as a marker, or return None when it is not one.

    A marker is a whole line that is one HTML comment with an ``id:`` field. Fields
    are split at ``;`` and each is ``name: value``. A marker that breaks a rule is
    still returned, with ``errors`` naming each problem in a short phrase.
    """
    stripped = text.strip()
    if len(stripped) < 7 or not stripped.startswith("<!--") or not stripped.endswith("-->"):
        return None
    body = stripped[4:-3]
    if "-->" in body:
        return None  # two comments on one line: not a marker
    parts = [part.strip() for part in body.split(";") if part.strip()]
    # Only a comment that has an id field is a marker; any other comment is plain HTML.
    if not any(part.split(":", 1)[0].strip() == "id" and ":" in part for part in parts):
        return None
    marker = Marker(line=line_number, raw=stripped, id=None, keys=[], src=[], errors=[])
    seen = set()
    for part in parts:
        if ":" not in part:
            marker.errors.append(f"part without a colon: {part!r}")
            continue
        name, value = (piece.strip() for piece in part.split(":", 1))
        if name not in MARKER_FIELDS:
            marker.errors.append(f"unknown field: {name!r}")
            continue
        if name in seen:
            marker.errors.append(f"field given twice: {name}")
            continue
        seen.add(name)
        if name == "id":
            if not value:
                marker.errors.append("no id")
            else:
                marker.id = value
                if not ID_SHAPE.match(value):
                    marker.errors.append(f"id not lowercase words joined by hyphens: {value!r}")
        elif name == "keys":
            marker.keys = _split_list(value)
        elif name == "src":
            marker.src = _split_list(value)
        elif name == "status":
            if value in MARKER_STATUSES:
                marker.status = value
            else:
                marker.errors.append(f"status not {' or '.join(MARKER_STATUSES)}: {value!r}")
        else:
            marker.issues = _split_list(value)
    return marker


# ---------------------------------------------------------------------------
# Blocks.
# ---------------------------------------------------------------------------

@dataclass
class Block:
    """A run of lines that forms one piece of a page (see the module's block kinds).

    ``kind`` is one of heading, paragraph, list-item, list-para, quote, code, table,
    html, marker, rule, front-matter. ``start`` and ``end`` are 1-based line numbers,
    inclusive. A heading has its ``level`` and ``title``; a list item its marker's
    column (``indent``) and the column its text starts at (``content_col``); a list
    paragraph the content column of the item it belongs to (``indent``).
    """

    kind: str
    start: int
    end: int
    level: int = 0
    title: str = ""
    indent: int = 0
    content_col: int = 0
    marker: Optional[Marker] = None


# The shapes of the lines that begin a block.
_HEADING = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
_RULE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
_ITEM = re.compile(r"^( *)([-*+]|\d{1,9}[.)])([ \t]+|$)")
_FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")


def _indent(expanded: str) -> int:
    """The number of leading spaces of a line whose tabs are already expanded."""
    return len(expanded) - len(expanded.lstrip(" "))


def _fence_opening(expanded: str) -> Optional[Tuple[str, int]]:
    """The fence character and length when the line opens a code fence, else None."""
    match = _FENCE.match(expanded)
    if not match:
        return None
    fence, rest = match.groups()
    if fence[0] == "`" and "`" in rest:
        return None  # inline code at the start of a line, not a fence
    return fence[0], len(fence)


def _is_fence_close(expanded: str, char: str, length: int) -> bool:
    """Whether the line holds only a fence of ``char``, at least ``length`` long."""
    stripped = expanded.strip()
    return len(stripped) >= length and stripped == char * len(stripped)


def _split_lines(text: str) -> List[str]:
    """The lines of ``text``: ``\\r\\n`` and ``\\n`` end a line, and a last line end adds no line."""
    if text.startswith("﻿"):
        text = text[1:]
    lines = [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    return lines


class _BlockParser:
    """One pass over a page's lines that cuts them into blocks.

    ``current`` is the block that a following line may still continue (a paragraph,
    list item, list paragraph, quote, or table). ``stack`` holds the open list
    items as ``(marker column, content column)`` pairs, the outermost first.
    ``blank_before`` is true at the page's start and after a blank line, which is
    when an indented line may be code or a list paragraph.
    """

    def __init__(self, lines: List[str]) -> None:
        self.lines = lines
        # Tabs expanded to four-column stops, so every column below is a plain count.
        self.expanded = [line.expandtabs(4) for line in lines]
        self.blocks: List[Block] = []
        self.current: Optional[Block] = None
        self.stack: List[Tuple[int, int]] = []
        self.blank_before = True

    # -- helpers ----------------------------------------------------------

    def add(self, block: Block) -> Block:
        """Append a finished or open block to the page's blocks and return it."""
        self.blocks.append(block)
        return block

    def prune_content(self, indent: int) -> None:
        """Close the open items whose text starts to the right of a line at ``indent``."""
        while self.stack and self.stack[-1][1] > indent:
            self.stack.pop()

    def is_blank(self, number: int) -> bool:
        """Whether the 1-based line is empty or only white space."""
        return not self.expanded[number - 1].strip()

    def code_run(self, first: int, threshold: int) -> int:
        """The last line of the indented code that starts at ``first``.

        The block runs while lines are indented at least ``threshold`` columns or
        are blank; trailing blank lines are left out of it.
        """
        last = first
        number = first + 1
        while number <= len(self.lines):
            if not self.is_blank(number):
                if _indent(self.expanded[number - 1]) < threshold:
                    break
                last = number
            number += 1
        return last

    # -- the pass ---------------------------------------------------------

    def run(self) -> List[Block]:
        """Cut every line into blocks and return them in order."""
        number = 1
        total = len(self.lines)
        # Front matter: line 1 is ``---`` and a later line is ``---`` or ``...``.
        if total and self.lines[0].rstrip() == "---":
            for later in range(2, total + 1):
                if self.lines[later - 1].rstrip() in ("---", "..."):
                    self.add(Block("front-matter", 1, later))
                    number = later + 1
                    break
        while number <= total:
            number = self.step(number)
        return self.blocks

    def step(self, number: int) -> int:
        """Handle the block that starts at line ``number``; return the next line to handle."""
        expanded = self.expanded[number - 1]
        if not expanded.strip():
            # A blank line ends the open block but not the list.
            self.current = None
            self.blank_before = True
            return number + 1
        indent = _indent(expanded)
        raw = self.lines[number - 1]
        blank_before = self.blank_before
        self.blank_before = False
        stripped = expanded.lstrip()

        # Rule 3: a code fence, at any indentation.
        fence = _fence_opening(expanded)
        if fence:
            return self.fence(number, fence)
        # Rule 4: an HTML comment, possibly a marker.
        if indent <= 3 and stripped.startswith("<!--"):
            return self.comment(number, indent)
        # Rule 5: a heading ends the list.
        heading = _HEADING.match(raw)
        if heading:
            self.current = None
            self.stack.clear()
            title = (heading.group(2) or "").strip()
            self.add(Block("heading", number, number, level=len(heading.group(1)), title=title))
            return number + 1
        # Rule 6: a thematic break.
        if _RULE.match(expanded):
            self.current = None
            self.stack.clear()
            self.add(Block("rule", number, number))
            return number + 1
        # Rules 7 and 8: tables and quotes, a line at a time.
        for kind, lead in (("table", "|"), ("quote", ">")):
            if indent <= 3 and stripped.startswith(lead):
                if self.current is None or self.current.kind != kind:
                    self.prune_content(indent)
                    self.current = self.add(Block(kind, number, number))
                else:
                    self.current.end = number
                return number + 1
        return self.list_or_text(number, expanded, indent, blank_before)

    def fence(self, number: int, fence: Tuple[str, int]) -> int:
        """A fenced code block from the opening line to its closing fence (or the last line)."""
        char, length = fence
        self.prune_content(_indent(self.expanded[number - 1]))
        self.current = None
        end = len(self.lines)
        for later in range(number + 1, len(self.lines) + 1):
            if _is_fence_close(self.expanded[later - 1], char, length):
                end = later
                break
        self.add(Block("code", number, end))
        return end + 1

    def comment(self, number: int, indent: int) -> int:
        """An HTML comment block, a marker when it is one line holding an ``id:`` field."""
        self.prune_content(indent)
        self.current = None
        raw = self.lines[number - 1]
        opening = raw.index("<!--") + 4
        end = number
        if "-->" not in raw[opening:]:
            end = len(self.lines)
            for later in range(number + 1, len(self.lines) + 1):
                if "-->" in self.lines[later - 1]:
                    end = later
                    break
        marker = parse_marker(number, raw) if end == number else None
        if marker:
            self.add(Block("marker", number, number, marker=marker))
        else:
            self.add(Block("html", number, end))
        return end + 1

    def list_or_text(self, number: int, expanded: str, indent: int, blank_before: bool) -> int:
        """Rules 9 to 11: list items, list paragraphs, indented code, and paragraphs."""
        # The open items a line after a blank line can still belong to.
        if blank_before:
            open_items = [item for item in self.stack if item[1] <= indent]
        else:
            open_items = self.stack

        # Indented code: outside a list, four columns in; inside, four past the item's text.
        if blank_before:
            threshold = open_items[-1][1] + 4 if open_items else 4
            if indent >= threshold:
                self.stack = open_items
                self.current = None
                end = self.code_run(number, threshold)
                self.add(Block("code", number, end))
                return end + 1

        item = _ITEM.match(expanded)
        if item:
            marker_col = len(item.group(1))
            marker_end = marker_col + len(item.group(2))
            spaces = len(item.group(3))
            content_col = marker_end + (spaces if 1 <= spaces <= 4 else 1)
            # A new item closes the items whose marker is at or beyond its own column.
            while self.stack and self.stack[-1][0] >= marker_col:
                self.stack.pop()
            self.stack.append((marker_col, content_col))
            self.current = self.add(
                Block("list-item", number, number, indent=marker_col, content_col=content_col))
            return number + 1

        # Plain text. Right after a block that takes continuation lines it continues that block.
        if not blank_before and self.current is not None and self.current.kind != "table":
            self.current.end = number
            return number + 1
        self.current = None
        if not blank_before:
            self.prune_content(indent)
            open_items = self.stack
        if open_items:
            # A paragraph inside a list item (after a blank line, or after a nested block).
            self.stack = open_items
            self.current = self.add(Block("list-para", number, number, indent=open_items[-1][1]))
        else:
            self.stack = []
            self.current = self.add(Block("paragraph", number, number))
        return number + 1


# ---------------------------------------------------------------------------
# Sections and pages.
# ---------------------------------------------------------------------------

@dataclass
class Section:
    """The lines under one heading, up to the next heading.

    ``start`` is the heading's line; ``end`` the last non-blank line of the section;
    ``span_end`` the line before the next heading (or the page's last line), so
    ``start..span_end`` covers the blank lines between sections too. ``blocks`` are
    those after the heading line. ``marker`` is the marker that is the section's
    first block, ``stray_markers`` any other marker block in it. ``drop_top`` says
    the page's one top heading is left out of ``heading``.
    """

    page: str
    index: int
    level: int
    title: str
    path: Tuple[str, ...]
    start: int
    end: int
    span_end: int
    blocks: List[Block]
    marker: Optional[Marker]
    stray_markers: List[Marker]
    drop_top: bool = False

    @property
    def heading(self) -> str:
        """The heading path to print in a hit.

        The titles of ``path`` joined with `` > ``, without the page's top heading
        when the page has just one level-1 heading and this section is below it (a
        hit's file path already names the page).
        """
        titles = self.path[1:] if self.drop_top and len(self.path) > 1 else self.path
        return " > ".join(titles)


@dataclass
class Page:
    """A parsed page: its lines, blocks, and sections."""

    path: str
    lines: List[str]
    blocks: List[Block]
    sections: List[Section]
    size: int

    def section_at(self, line: int) -> Section:
        """The section whose ``start..span_end`` holds ``line`` (clamped into the page)."""
        if not self.sections:
            raise LookupError(f"{self.path} has no sections")
        starts = [section.start for section in self.sections]
        position = bisect.bisect_right(starts, line) - 1
        return self.sections[max(position, 0)]

    def text(self, start: int, end: int) -> str:
        """Lines ``start`` to ``end`` (1-based, inclusive) joined with newlines."""
        return "\n".join(self.lines[start - 1:end])


def _build_sections(path: str, lines: List[str], blocks: List[Block]) -> List[Section]:
    """Group the blocks into sections, one for each heading and one for text before the first."""
    # (heading block or None for the level-0 section, the section's other blocks)
    groups: List[Tuple[Optional[Block], List[Block]]] = []
    for block in blocks:
        if block.kind == "front-matter":
            continue
        if block.kind == "heading":
            groups.append((block, []))
        else:
            if not groups:
                groups.append((None, []))
            groups[-1][1].append(block)

    top_headings = sum(1 for head, _ in groups if head is not None and head.level == 1)
    sections: List[Section] = []
    ancestors: List[Tuple[int, str]] = []  # (level, title) of the headings above the current one
    for index, (head, inside) in enumerate(groups):
        start = 1 if head is None else head.start
        following = groups[index + 1][0].start if index + 1 < len(groups) else len(lines) + 1
        span_end = following - 1
        end = span_end
        while end > start and not lines[end - 1].strip():
            end -= 1
        if head is None:
            level, title, titles, drop_top = 0, "", (), False
        else:
            level, title = head.level, head.title
            while ancestors and ancestors[-1][0] >= level:
                ancestors.pop()
            ancestors.append((level, title))
            titles = tuple(entry[1] for entry in ancestors)
            drop_top = top_headings == 1 and ancestors[0][0] == 1
        first = inside[0] if inside else None
        marker = first.marker if first is not None and first.kind == "marker" else None
        stray = [b.marker for b in inside if b.kind == "marker" and b.marker is not marker and b.marker]
        sections.append(Section(
            page=path, index=index, level=level, title=title, path=titles, start=start,
            end=end, span_end=span_end, blocks=inside, marker=marker, stray_markers=stray,
            drop_top=drop_top))
    return sections


def parse(path: str, text: str) -> Page:
    """Parse ``text`` as the page ``path``: its lines, blocks, and sections."""
    lines = _split_lines(text)
    blocks = _BlockParser(lines).run()
    return Page(path=path, lines=lines, blocks=blocks, sections=_build_sections(path, lines, blocks),
                size=len(text.encode("utf-8")))


def name_inside(root: Path, name: str) -> Optional[str]:
    """``name`` as a path relative to ``root``, or None when its spelling leaves the root.

    Decided from the text alone, before the file system is asked anything, so a
    name such as ``/Users/x/.TextMouth/library.json`` or ``~/.TextMouth`` is never
    looked at: a home path or a ``..`` component is refused, and an absolute path
    is accepted only when it starts with the root's own path.
    """
    if not name or name.startswith("~"):
        return None
    if os.path.isabs(name):
        prefix = str(root).rstrip("/") + "/"
        if not name.startswith(prefix):
            return None
        name = name[len(prefix):]
    if not name or ".." in Path(name).parts:
        return None
    return name


def read_page_bytes(root: Path, path: str) -> bytes:
    """The raw bytes of the page at ``root/path``, which must lie inside ``root``.

    A path that leaves the root (by its spelling, or through a symlink pointing
    out) or names no file is a UsageError.
    """
    relative = name_inside(root, path)
    if relative is None:
        raise UsageError(f"{path} is outside the repository")
    root_real = Path(os.path.realpath(root))
    target = Path(os.path.realpath(root_real / relative))
    try:
        target.relative_to(root_real)
    except ValueError:
        raise UsageError(f"{path} is outside the repository") from None
    if not target.is_file():
        raise UsageError(f"no such page: {path}")
    return target.read_bytes()


def parse_bytes(path: str, data: bytes) -> Page:
    """Parse a page's bytes as UTF-8 (bad bytes become U+FFFD); its ``size`` is ``len(data)``."""
    page = parse(path, data.decode("utf-8", errors="replace"))
    page.size = len(data)
    return page


def load_page(root: Path, path: str) -> Page:
    """Read and parse the page at ``root/path``, which must lie inside ``root``."""
    return parse_bytes(path, read_page_bytes(root, path))


def load_pages(root: Path, paths: Iterable[str]) -> List[Page]:
    """``load_page`` for each of ``paths``, in order."""
    return [load_page(root, path) for path in paths]


# The block kinds whose text is not prose (citations and the like are not read in them).
_NON_PROSE = frozenset({"code", "front-matter", "marker", "rule", "html"})


def prose_blocks(page: Page, section: Section) -> List[Tuple[int, str]]:
    """The section's prose as ``(first line, text)`` pairs: its heading and each prose block.

    Code, front matter, markers, rules, and HTML comments are left out. The text is
    the block's raw lines joined with newlines.
    """
    pairs: List[Tuple[int, str]] = []
    if section.level > 0:
        pairs.append((section.start, page.lines[section.start - 1]))
    for block in section.blocks:
        if block.kind not in _NON_PROSE:
            pairs.append((block.start, page.text(block.start, block.end)))
    return pairs


# ---------------------------------------------------------------------------
# Units: the pieces a text search matches and prints.
# ---------------------------------------------------------------------------

@dataclass
class Unit:
    """One searchable piece of a section: a heading, a marker, a sentence, or a code, table, or HTML line.

    ``kind`` is heading, marker, sentence, code, table, or html; ``start`` and
    ``end`` are the 1-based lines the text is on (inclusive); ``text`` is the text
    as written, with its line breaks (a sentence's own list marker is not part of it).
    """

    kind: str
    start: int
    end: int
    text: str


# The block kinds whose text is split into sentences.
_SENTENCE_BLOCKS = frozenset({"paragraph", "list-item", "list-para", "quote"})
# The block kinds searched a line at a time, and the unit kind each gives.
_LINE_UNIT_KINDS = {"code": "code", "table": "table", "html": "html", "marker": "marker"}
# What leads a list item's first line, and what leads a line of a quote.
_LIST_MARKER = re.compile(r"^\s*(?:[-*+]|\d{1,9}[.)])[ \t]*")
_QUOTE_LEAD = re.compile(r"^\s*(?:>[ \t]?)+")


def _clean_line(block: Block, number: int, line: str) -> str:
    """One line of a prose block without its list marker, quote marks, and indentation."""
    if block.kind == "quote":
        line = _QUOTE_LEAD.sub("", line)
    elif block.kind == "list-item" and number == block.start:
        line = _LIST_MARKER.sub("", line)
    return line.strip()


def _sentence_units(page: Page, block: Block) -> List[Unit]:
    """The sentences of a paragraph, list item, list paragraph, or quote, each with its lines."""
    cleaned = [_clean_line(block, number, page.lines[number - 1])
               for number in range(block.start, block.end + 1)]
    text = "\n".join(cleaned)
    # The offset at which each cleaned line starts in ``text``.
    offsets: List[int] = []
    position = 0
    for line in cleaned:
        offsets.append(position)
        position += len(line) + 1
    found = []
    for start, end in split_sentences(text):
        first = bisect.bisect_right(offsets, start) - 1
        last = bisect.bisect_right(offsets, end - 1) - 1
        found.append(Unit("sentence", block.start + first, block.start + last, text[start:end]))
    return found


def units(page: Page, section: Section) -> List[Unit]:
    """The section's searchable units in line order.

    The heading (its title); then, for each block, either its sentences (a
    paragraph, list item, list paragraph, or quote, found with the list markers,
    ``>``, and indentation removed) or one unit for each non-blank line (code, table,
    HTML, and marker blocks, a stray marker too). Rules and front matter give none.
    """
    found: List[Unit] = []
    if section.level > 0:
        found.append(Unit("heading", section.start, section.start, section.title))
    for block in section.blocks:
        if block.kind in _SENTENCE_BLOCKS:
            found.extend(_sentence_units(page, block))
        elif block.kind in _LINE_UNIT_KINDS:
            kind = _LINE_UNIT_KINDS[block.kind]
            for number in range(block.start, block.end + 1):
                line = page.lines[number - 1]
                if line.strip():
                    found.append(Unit(kind, number, number, line))
    return found
