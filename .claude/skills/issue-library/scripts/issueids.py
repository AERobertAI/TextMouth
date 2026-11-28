"""Issue IDs: their shape, their families, the next free one, and the IDs the TODO uses.

An ID is capital letters, digits, and hyphens, starting with a letter, as the TODO's
items have always been named: B15, FR23, FMT50, PG14, FU-FFMPEG2, A11Y-GOTO, Q-flake.
It holds a digit or a hyphen, so a plain word in capitals (EPUB, README) is not one.

A *numbered* ID is a family's letters and a number, B15 or FMT50, sometimes with a
suffix after a hyphen (B12-OCT). A new issue takes one more than the highest number
its family has ever had, with at least two digits (B16, FU01), so a number is never
given twice; B12 and B13 each named two bugs before this rule.

"Ever had" is wide on purpose. It counts every family-and-number token anywhere in
the TODO, in its text today and in every version git has of it, because other lists
are numbered there too: the optimization audit's C1 to C18 and REV15's V16 and V23
are named in the TODO, though no item opens with them. A mention can only raise the
next number, never lower it, so counting too much is safe and counting too little is
not.

This module reads text only; `issuestore` brings it the files and git's history.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Set, Tuple

# The longest ID accepted: the TODO's longest is about a dozen characters.
MAX_ID_LENGTH = 40

# A whole ID: a capital letter, then capitals and digits, then any hyphenated parts.
_ID_SHAPE = re.compile(r"^[A-Z][A-Z0-9]*(?:-[A-Za-z0-9]+)*$")

# An ID inside other text: the same shape, not glued to a letter or digit after it.
_ID_IN_TEXT = re.compile(r"[A-Z][A-Z0-9]*(?:-[A-Za-z0-9]+)*(?![A-Za-z0-9])")

# A numbered ID: the family's capitals, the number, and then the end or a hyphen.
_NUMBERED = re.compile(r"^([A-Z]+)(\d+)(?=-|$)")

# A family-and-number token anywhere in text, as `_NUMBERED` reads it at an ID's start:
# not preceded by a letter, digit, underscore or hyphen (so the FFMPEG2 of FU-FFMPEG2
# is not one), and not followed by a letter, digit or underscore (so A11Y is not one).
FAMILY_TOKEN = re.compile(r"(?<![A-Za-z0-9_-])([A-Z]+)(\d+)(?![A-Za-z0-9_])")

# The digits a new number is written with at least: B01, not B1.
MIN_DIGITS = 2

# The family a new issue of each kind is numbered in. The first five are the TODO's
# own families; tooling, docs, and question had none, so they start their own.
FAMILY_OF_KIND = {
    "bug": "B",
    "feature": "FR",
    "format": "FMT",
    "follow-up": "FU",
    "test": "Q",
    "tooling": "TL",
    "docs": "DOC",
    "question": "QN",
}

# A family name, for --family: capitals only.
_FAMILY_SHAPE = re.compile(r"^[A-Z]{1,8}$")


def is_issue_id(text: str) -> bool:
    """Whether ``text`` is an ID: the shape above, with a digit or a hyphen, at most MAX_ID_LENGTH long."""
    return (len(text) <= MAX_ID_LENGTH and bool(_ID_SHAPE.match(text))
            and any(char.isdigit() or char == "-" for char in text))


def is_family(text: str) -> bool:
    """Whether ``text`` can name a family of numbered IDs (one to eight capitals)."""
    return bool(_FAMILY_SHAPE.match(text))


def family_number(issue_id: str) -> Optional[Tuple[str, int]]:
    """The family and number of a numbered ID (B12-OCT gives ("B", 12)), or None for a named one."""
    match = _NUMBERED.match(issue_id)
    if match is None:
        return None
    return match.group(1), int(match.group(2))


def sort_key(issue_id: str) -> Tuple[str, int, str]:
    """A key that orders IDs as a reader expects: B2 before B10, and FU-FORMATS after FU01."""
    numbered = family_number(issue_id)
    if numbered is None:
        return issue_id, -1, issue_id
    return numbered[0], numbered[1], issue_id


def numbers_in(text: str) -> Dict[str, Set[int]]:
    """Every family-and-number token in ``text``, as {family: {numbers}}."""
    found: Dict[str, Set[int]] = {}
    for match in FAMILY_TOKEN.finditer(text):
        found.setdefault(match.group(1), set()).add(int(match.group(2)))
    return found


def merge_numbers(into: Dict[str, Set[int]], more: Dict[str, Set[int]]) -> Dict[str, Set[int]]:
    """Add the numbers of ``more`` to ``into``, family by family, and return ``into``."""
    for family, numbers in more.items():
        into.setdefault(family, set()).update(numbers)
    return into


def numbers_of_ids(ids: Iterable[str]) -> Dict[str, Set[int]]:
    """The families and numbers of the numbered IDs among ``ids``."""
    found: Dict[str, Set[int]] = {}
    for issue_id in ids:
        numbered = family_number(issue_id)
        if numbered is not None:
            found.setdefault(numbered[0], set()).add(numbered[1])
    return found


def next_id(family: str, used: Dict[str, Set[int]]) -> str:
    """The next free ID of ``family``: one past the highest number ever used, with at least two digits."""
    highest = max(used.get(family, set()), default=0)
    return f"{family}{highest + 1:0{MIN_DIGITS}d}"


def ids_in(text: str) -> List[str]:
    """The IDs named in ``text``, in order of first appearance, each once."""
    seen: List[str] = []
    for match in _ID_IN_TEXT.finditer(text):
        token = match.group(0)
        # A token glued to a letter, digit, or hyphen before it is part of a longer word.
        before = text[match.start() - 1] if match.start() else ""
        if before and (before.isalnum() or before in "_-"):
            continue
        if is_issue_id(token) and token not in seen:
            seen.append(token)
    return seen


# ---------------------------------------------------------------------------
# The TODO's items.
# ---------------------------------------------------------------------------

# The TODO, in the repository's top folder.
TODO_NAME = "TODO-2026-09-04.md"

# The level-2 heading of the TODO's merge record, whose entries name IDs without being items.
MERGE_RECORD_SECTION = "Completed fixes"

# A list item whose text starts in bold, as every TODO item does: its indent, its box, its text.
_OPENING = re.compile(r"^( *)- (?:\[([ xX])\] )?\*\*(.*)$")

# The line an imported item leaves in the TODO, "- [ ] **B14** moved to Issues/B14.md", ticked
# once its issue is closed: its box, the ID it names, and the file it leads to.
POINTER = re.compile(r"^- \[([ xX])\] \*\*([^*\s]+)\*\* moved to Issues/([^\s]+)\.md\b")

# What may follow an opening's IDs and asides: a dash or colon before the title, a period,
# a comma, or the end of the bold run. Anything else ("FR03 follow-ups") is no opening.
_TERMINATORS = (" — ", " – ", " - ", ":", ".", ",", "**")

# The words that join an opening's IDs: "B11, B10, and FR21".
_ID_JOINER = re.compile(r"(?:, and |, | and )")

# An alias, written as an aside after the one ID it renames: "**B12 (alias B12-OCT) — ...".
_ALIAS_ASIDE = re.compile(r"^alias ([^\s()]+)$")

# A level-2 heading.
_SECTION = re.compile(r"^## (.*)$")


@dataclass
class TodoItem:
    """One list item of the TODO whose bold opening names IDs, or a pointer to an issue file.

    ``line`` is 1-based. ``indent`` is the column of its dash (0 for a top-level item),
    ``checked`` is True for ``[x]``, False for ``[ ]``, and None for an item with no box.
    ``aliases`` maps each alias to the ID it renames. ``title_start`` is where the
    title begins in the line, after the opening's IDs and the dash or colon.
    """

    line: int
    indent: int
    checked: Optional[bool]
    ids: List[str]
    section: str
    pointer: bool = False
    target: str = ""
    aliases: Dict[str, str] = field(default_factory=dict)
    title_start: int = 0

    @property
    def in_backlog(self) -> bool:
        """Whether this is a top-level item with a box outside the merge record: an item of work."""
        return self.indent == 0 and self.checked is not None and self.section != MERGE_RECORD_SECTION


def _closing_paren(text: str, start: int) -> int:
    """The index just past the parenthesis that closes the one at ``start``, or -1."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return -1


def parse_opening(head: str) -> Tuple[List[str], List[str], int]:
    """The IDs a bold opening names, the asides in parentheses after them, and where its title starts.

    ``head`` is an item's text after its ``**``. Returns ``([], [], -1)`` when the
    bold run does not open with IDs followed by a dash, colon, period, comma, or the
    end of the run. The title starts after " — " or ": ", else where the IDs end.
    """
    ids: List[str] = []
    position = 0
    while True:
        match = _ID_IN_TEXT.match(head, position)
        if match is None or not is_issue_id(match.group(0)):
            break
        ids.append(match.group(0))
        position = match.end()
        # Take the joining words only when another ID follows them.
        joiner = _ID_JOINER.match(head, position)
        if joiner is None:
            break
        following = _ID_IN_TEXT.match(head, joiner.end())
        if following is None or not is_issue_id(following.group(0)):
            break
        position = joiner.end()
    if not ids:
        return [], [], -1
    asides: List[str] = []
    while head.startswith(" (", position):
        end = _closing_paren(head, position + 1)
        if end < 0:
            return [], [], -1
        asides.append(head[position + 2:end - 1])
        position = end
    rest = head[position:]
    for terminator in _TERMINATORS:
        if rest.startswith(terminator):
            title_start = position + (len(terminator) if terminator.strip() in ("—", "–", "-", ":") else 0)
            return ids, asides, title_start
    return [], [], -1


def scan_todo(text: str) -> List[TodoItem]:
    """Every item of the TODO that opens with IDs, and every pointer line, in line order.

    Lines inside fenced code are skipped. The section of an item is the text of the
    level-2 heading above it.
    """
    items: List[TodoItem] = []
    section = ""
    fence = ""
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.lstrip()
        # Fenced code: nothing in it is an item or a heading.
        if fence:
            if stripped.startswith(fence):
                fence = ""
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
            continue
        heading = _SECTION.match(line)
        if heading:
            section = heading.group(1).strip()
            continue
        pointer = POINTER.match(line)
        if pointer:
            items.append(TodoItem(line=number, indent=0, checked=pointer.group(1) != " ",
                                  ids=[pointer.group(2)], section=section, pointer=True,
                                  target=pointer.group(3)))
            continue
        opening = _OPENING.match(line)
        if not opening:
            continue
        ids, asides, title_start = parse_opening(opening.group(3))
        if not ids:
            continue
        box = opening.group(2)
        aliases = {}
        for aside in asides:
            alias = _ALIAS_ASIDE.match(aside.strip())
            if alias and len(ids) == 1 and is_issue_id(alias.group(1)):
                aliases[alias.group(1)] = ids[0]
        prefix = len(line) - len(opening.group(3))
        items.append(TodoItem(line=number, indent=len(opening.group(1)),
                              checked=None if box is None else box != " ",
                              ids=ids, section=section, aliases=aliases,
                              title_start=prefix + title_start))
    return items


def pointer_line(issue_id: str, closed: bool = False) -> str:
    """The TODO's line for an item moved to its issue file, its box ticked once the issue is closed."""
    return f"- [{'x' if closed else ' '}] **{issue_id}** moved to Issues/{issue_id}.md"


def set_pointers(text: str, issue_id: str, closed: bool) -> Tuple[str, int]:
    """``text`` with each pointer line of ``issue_id`` ticked (or unticked), and how many it has."""
    lines = text.split("\n")
    count = 0
    for index, line in enumerate(lines):
        match = POINTER.match(line)
        if match and match.group(2) == issue_id and match.group(3) == issue_id:
            lines[index] = pointer_line(issue_id, closed) + line[match.end():]
            count += 1
    return "\n".join(lines), count


def is_open_item(line: str) -> bool:
    """Whether a TODO line opens an open item at the margin that is not a pointer to an issue file."""
    return line.startswith("- [ ] ") and not POINTER.match(line)


def open_item_lines(text: str) -> List[int]:
    """The lines (1-based) of the TODO's open items that are not pointers, outside fenced code."""
    found: List[int] = []
    fence = ""
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.lstrip()
        if fence:
            if stripped.startswith(fence):
                fence = ""
        elif stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
        elif is_open_item(line):
            found.append(number)
    return found


def todo_ids(items: Iterable[TodoItem]) -> Set[str]:
    """Every ID the TODO's items open with, their aliases, and the IDs its pointers name."""
    found: Set[str] = set()
    for item in items:
        found.update(item.ids)
        found.update(item.aliases)
    return found


def todo_aliases(items: Iterable[TodoItem]) -> Dict[str, str]:
    """Every alias the TODO's openings give, mapped to the ID it renames."""
    found: Dict[str, str] = {}
    for item in items:
        found.update(item.aliases)
    return found
