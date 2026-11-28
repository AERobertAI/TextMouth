"""Reads the `InterfaceText.line` calls of Swift sources (FR39), for the converter, `l10n.py sync`, and the lint.

A converted call looks like this, its translator's note on the line above:

    // Translators: VoiceOver announcement as the next book starts. %@ is the book's title.
    InterfaceText.line("endOfBook.starting", "Starting: \\(title)")

This module finds each such call and reads its ID, its English as the catalog holds it (a literal's `%` doubled where the
literal holds interpolations, `\\(number: n)` as `%lld`, any other interpolation as `%@`), its note, and its place. It
refuses what it cannot read exactly (an ID or English that is not one plain literal) with a sentence that names the file and
line, and holds each ID to the pattern and the retired list (`problems_of`).

Standard library only; the tools that use it run under Xcode's Python 3.9.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import ids  # noqa: E402
from swiftscan import classify, scanner  # noqa: E402
from swiftscan.lexer import Literal, lex  # noqa: E402

# The table the catalog's strings live in, as Xcode's `.stringsdata` files name it.
TABLE = "Localizable"
# The call, as written: `InterfaceText.line(`, with any spaces the code has around the dot.
_CALL = re.compile(r"\bInterfaceText\s*\.\s*line\s*\(")
# What an interpolation of a number looks like inside: `number: n`.
_NUMBER_LABEL = re.compile(r"\s*number\s*:")
# The words a file must hold for it to be worth reading.
_MARKER = "InterfaceText"
_WHITESPACE = " \t\r\n"


@dataclass
class Call:
    """One `InterfaceText.line` call of a source file."""

    file: str                     # the path the source was given under (relative to the repository root)
    line: int                     # the 1-based line of the English's literal, which the note sits above
    column: int                   # the 1-based UTF-8 byte column of that literal's first character, as Xcode counts
    id: Optional[str] = None      # the ID literal's text, None when the call's first argument is not a plain literal
    english: Optional[str] = None  # the English as the catalog holds it, None when it is not one plain literal
    note: str = ""                # the translator's note above the line, "" when there is none
    problems: List[str] = field(default_factory=list)  # what stops the call being read exactly

    def where(self) -> str:
        """`file:line`, for a sentence about the call."""
        return f"{self.file}:{self.line}"


def english_of(text: str, literal: Literal) -> Optional[str]:
    """The English of a literal as the catalog holds it, from the source `text` it is in: the literal's own text with each `%`
    doubled when the literal holds interpolations, each `\\(number: n)` as `%lld`, any other interpolation as `%@`. None for
    a literal that cannot be read this way (a multi-line one, or a raw one)."""
    if literal.multiline or text[literal.start] != '"':
        return None
    out: List[str] = []
    holes = iter(literal.interps)
    for piece in literal.pieces:
        if piece is None:
            begin, end = next(holes)
            # The interpolation's code sits between the `\\(` and the `)` that closes it.
            out.append("%lld" if _NUMBER_LABEL.match(text, begin + 2, end - 1) else "%@")
        else:
            out.append(piece.replace("%", "%%") if literal.has_interp else piece)
    return "".join(out)


def _skip(text: str, position: int) -> int:
    """The offset of the first character at or after `position` that is neither whitespace nor part of a `//` comment (a
    wrapped call may carry its note between its parenthesis and its ID)."""
    while position < len(text):
        if text[position] in _WHITESPACE:
            position += 1
        elif text.startswith("//", position):
            newline = text.find("\n", position)
            position = len(text) if newline < 0 else newline
        else:
            break
    return position


def inside_comment_or_string(text: str, position: int, literals: Sequence[Literal]) -> bool:
    """Whether the offset is in a `//` comment (on its line, before it) or in the text of a string literal (an
    interpolation's code does not count as text), so that a mention of the call in prose is not taken for a call. (apple_lookups.py asks it too, for the names of Apple's lookups.)"""
    line_start = text.rfind("\n", 0, position) + 1
    if "//" in text[line_start:position]:
        return True
    for lit in literals:
        if lit.start < position < lit.end and not any(begin <= position < end for begin, end in lit.interps):
            return True
    return False


def find_calls(text: str, path: str) -> List[Call]:
    """Every `InterfaceText.line(` call of the source `text` (of the file `path`), in order. A call whose arguments cannot be
    read as one plain literal ID and one plain literal English gets `problems`; the engine's own declaration and prose that
    only mentions the call are not calls."""
    if _MARKER not in text:
        return []
    literals = lex(text, path)
    by_start = {lit.start: lit for lit in literals}
    lines = text.split("\n")
    calls: List[Call] = []
    for match in _CALL.finditer(text):
        if inside_comment_or_string(text, match.start(), literals):
            continue
        calls.append(read_call(text, lines, path, match, by_start))
    return calls


def read_call(text: str, lines: List[str], path: str, match: "re.Match[str]", by_start: Dict[int, Literal]) -> Call:
    """The call that `match` found (its opening parenthesis ends the match): its ID, English, note, and place."""
    opening = match.end()
    line_of_call = text.count("\n", 0, match.start()) + 1
    call = Call(path, line_of_call, 0)
    id_literal = by_start.get(_skip(text, opening))
    if id_literal is None or id_literal.has_interp or id_literal.multiline or text[id_literal.start] != '"':
        call.problems.append("the ID is not one plain string literal")
    else:
        call.id = id_literal.text
    after_id = _skip(text, id_literal.end) if id_literal is not None else opening
    english_literal = by_start.get(_skip(text, after_id + 1)) if text[after_id:after_id + 1] == "," else None
    if english_literal is None:
        call.problems.append("the English is not one string literal given right after the ID")
        return call
    line_start = text.rfind("\n", 0, english_literal.start) + 1
    call.line = english_literal.line
    call.column = len(text[line_start:english_literal.start].encode("utf-8")) + 1
    call.english = english_of(text, english_literal)
    if call.english is None:
        call.problems.append("the English is a multi-line or raw literal, which this tool does not read")
    elif text[_skip(text, english_literal.end):][:1] not in (",", ")"):
        call.problems.append("the English is joined to something else; it must be one literal")
        call.english = None
    call.note = classify.note_text(lines, call.line)
    return call


def source_files(root: Path, only: Optional[Iterable[str]] = None) -> List[str]:
    """The Swift files under `root`'s TextMouth/ that mention the call, as paths from `root` (or only those of `only`)."""
    names = [p.as_posix() for p in scanner.swift_files(root)] if only is None else list(only)
    found = []
    for name in names:
        try:
            if _MARKER in (root / name).read_text(encoding="utf-8", errors="replace"):
                found.append(name)
        except OSError:
            continue
    return found


def calls_in_tree(root: Path, only: Optional[Iterable[str]] = None) -> Dict[str, List[Call]]:
    """{path: its calls} for each Swift file of `root`'s TextMouth/ that holds one (or only the files of `only`)."""
    found: Dict[str, List[Call]] = {}
    for name in source_files(root, only):
        calls = find_calls((root / name).read_text(encoding="utf-8", errors="replace"), name)
        if calls:
            found[name] = calls
    return found


def problems_of(root: Path, calls_by_file: Dict[str, List[Call]], retired: Set[str], notes: bool = True) -> List[str]:
    """The sentences that name what is wrong with the calls, each starting with `file:line`; none when every call is right.

    A call is right when it is one plain ID literal and one plain English literal; its ID is in the ID pattern and not
    retired; its note is above it; and no other call is on its line. With `notes` false the last two are left out (the
    lint's scanner holds every localized call to them already). That one ID has one English text is `sync`'s check, which
    sees every call at once."""
    problems: List[str] = []
    for name, calls in sorted(calls_by_file.items()):
        per_line: Dict[int, int] = {}
        for call in calls:
            per_line[call.line] = per_line.get(call.line, 0) + 1
        for call in calls:
            problems += [f"{call.where()}: {problem}" for problem in call.problems]
            if call.id is None or call.english is None:
                continue
            problems += id_problems(call, retired)
            if notes and not call.note:
                problems.append(f"{call.where()}: no `{classify.NOTE_MARKER} ...` line directly above the call")
            if notes and per_line[call.line] > 1:
                problems.append(f"{call.where()}: another call is on this line, and a note belongs to one call")
    return problems


def id_problems(call: Call, retired: Set[str]) -> List[str]:
    """What is wrong with one readable call's ID: outside the pattern (or over the longest an ID may be), or retired."""
    assert call.id is not None and call.english is not None
    out: List[str] = []
    if not ids.ID_PATTERN.fullmatch(call.id) or len(call.id) > ids.MAX_ID_LENGTH:
        out.append(f"{call.where()}: the ID {call.id!r} is outside the pattern (two to four lower camel case segments, "
                   f"at most {ids.MAX_ID_LENGTH} characters)")
    if call.id in retired:
        out.append(f"{call.where()}: the ID {call.id!r} is retired and must not be used again")
    return out
