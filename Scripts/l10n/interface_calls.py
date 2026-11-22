"""Reads the `InterfaceText.line` calls of Swift sources (FR39), for the converter, `l10n.py sync`, and the lint.

A converted call looks like this, its translator's note on the line above:

    // Translators: VoiceOver announcement as the next book starts. %@ is the book's title.
    InterfaceText.line("endOfBook.starting", "Starting: \\(title)")

This module finds each such call and reads its ID, its English as the catalog's key (a literal's `%` doubled where the
literal holds interpolations, `\\(number: n)` as `%lld`, any other interpolation as `%@`, which is what `String(localized:)`
extracts today), its note, and its place. It refuses what it cannot read exactly (an ID or English that is not one plain
literal) with a sentence that names the file and line, and it checks each call against `ids.json`: the ID is the key's, or
the right split's, and the English is a key character for character.

Standard library only; the tools that use it run under Xcode's Python 3.9.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

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
    english: Optional[str] = None  # the English as the catalog's key, None when it is not one plain literal
    note: str = ""                # the translator's note above the line, "" when there is none
    problems: List[str] = field(default_factory=list)  # what stops the call being read exactly

    def where(self) -> str:
        """`file:line`, for a sentence about the call."""
        return f"{self.file}:{self.line}"


def english_of(text: str, literal: Literal) -> Optional[str]:
    """The English of a literal as the catalog's key, from the source `text` it is in: the literal's own text with each `%`
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


def _inside_comment_or_string(text: str, position: int, literals: Sequence[Literal]) -> bool:
    """Whether the offset is in a `//` comment (on its line, before it) or in the text of a string literal (an
    interpolation's code does not count as text), so that a mention of the call in prose is not taken for a call."""
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
        if _inside_comment_or_string(text, match.start(), literals):
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


def problems_of(root: Path, calls_by_file: Dict[str, List[Call]], table: dict, retired: Set[str],
                notes: bool = True) -> List[str]:
    """The sentences that name what is wrong with the calls, each starting with `file:line`; none when every call is right.

    A call is right when it is one plain ID literal and one plain English literal; its ID is in the ID pattern, not retired,
    and the ID `ids.json` gives the key (the call's English, as a key, character for character) at the call's site; its
    note is above it; and no other call is on its line. With `notes` false the last two are left out (the lint's scanner
    holds every localized call to them already)."""
    problems: List[str] = []
    keys = table.get("ids", {})
    for name, calls in sorted(calls_by_file.items()):
        lines = (root / name).read_text(encoding="utf-8", errors="replace").split("\n")
        per_line: Dict[int, int] = {}
        for call in calls:
            per_line[call.line] = per_line.get(call.line, 0) + 1
        for call in calls:
            problems += [f"{call.where()}: {problem}" for problem in call.problems]
            if call.id is None or call.english is None:
                continue
            problems += id_problems(call, lines, keys, table, retired)
            if notes and not call.note:
                problems.append(f"{call.where()}: no `{classify.NOTE_MARKER} ...` line directly above the call")
            if notes and per_line[call.line] > 1:
                problems.append(f"{call.where()}: another call is on this line, and a note belongs to one call")
    return problems


def id_problems(call: Call, lines: List[str], keys: Dict[str, str], table: dict, retired: Set[str]) -> List[str]:
    """What is wrong with one readable call's ID against `ids.json`: outside the pattern, retired, or not the ID of its key
    at its site; or an English that is no key."""
    assert call.id is not None and call.english is not None
    out: List[str] = []
    if not ids.ID_PATTERN.fullmatch(call.id) or len(call.id) > ids.MAX_ID_LENGTH:
        out.append(f"{call.where()}: the ID {call.id!r} is outside the pattern (two to four lower camel case segments, "
                   f"at most {ids.MAX_ID_LENGTH} characters)")
    if call.id in retired:
        out.append(f"{call.where()}: the ID {call.id!r} is retired and must not be used again")
    if call.english not in keys:
        out.append(f"{call.where()}: the English {call.english!r} is not a key in ids.json (character for character)")
        return out
    expected = ids.id_for_site(table, call.english, ids.site_at(lines, call.file, call.line, call.english))
    if expected is None:
        out.append(f"{call.where()}: no ID in ids.json for the English {call.english!r} at this site "
                   "(a split key's uses must name it)")
    elif expected != call.id:
        out.append(f"{call.where()}: the ID is {call.id!r}, but ids.json gives {expected!r} for {call.english!r} here")
    return out


def stringsdata(source: str, calls: Sequence[Call]) -> dict:
    """The content of a `.stringsdata` file for the calls of one source file: the shape Xcode writes (`source`, `tables`, one
    entry a key with its note as the `comment` and the English literal's line and column), so that `xcstringstool sync`
    keeps the key and its note. `source` is the path the file is recorded under."""
    entries = [{"comment": call.note, "key": call.english,
                "location": {"startingColumn": call.column, "startingLine": call.line}}
               for call in calls if call.english is not None]
    return {"source": source, "tables": {TABLE: entries} if entries else {}, "version": 1}
