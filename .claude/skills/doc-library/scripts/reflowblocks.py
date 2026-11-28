"""How one prose block is reflowed: the block logic ``reflow`` and the ``line-length`` rule share.

``docs/agents/writing-docs.md`` asks for one sentence per line. ``cmd_reflow`` rewrites a
page so, and ``lintrules.rule_line_length`` asks what the lines of a prose block would be
after that rewrite, so a reflow can never raise a page's count. Both read the lines from
this one module, so the two cannot drift apart.

The module is plain (no command, no lint): it imports only ``docmodel`` and ``sentences``,
which lets ``lintrules`` use it although ``cmd_reflow`` itself reaches ``lintrules``
(through ``pagewrite``, ``splitcheck`` and ``baseline``).

A prose block is a paragraph, a list item, or a list paragraph (``PROSE_KINDS``). The
public parts:

* ``starts_a_block``: whether a sentence may not begin a line of its own;
* ``reflow_pieces``: the new lines of a block, each with the line of the old block its
  sentence started on;
* ``reflow_block``: just the new lines.
"""

from __future__ import annotations

import bisect
import re
from typing import List, Optional, Tuple

from docmodel import Block
from sentences import split_sentences

# A list item's first line: its indentation, marker, and one to four spaces, then text.
# Anything else (a tab, no text after the marker, five or more spaces) leaves the item alone.
_ITEM_START = re.compile(r"^( *)(?:[-*+]|\d{1,9}[.)]) {1,4}(?=\S)")
# A list marker at the start of a line of text: the marker, then a space or the line's end.
_LIST_MARKER_LEAD = re.compile(r"^(?:[-*+]|\d{1,9}[.)])(?:\s|$)")
# A thematic break (three or more of one of - * _, spaces between allowed) filling the line.
_THEMATIC_BREAK = re.compile(r"^([-*_])(?:\s*\1){2,}\s*$")
# A line of only = or - signs: the underline of a setext heading.
_SETEXT_UNDERLINE = re.compile(r"^[=-]+\s*$")
# The characters that, at the start of a line, begin a heading, quote, table, or HTML.
_BLOCK_LEAD_CHARS = "#>|<"

# The block kinds whose lines are rewritten.
PROSE_KINDS = frozenset({"paragraph", "list-item", "list-para"})

# One new line of a reflowed block: the index (0-based) of the old line its first sentence
# started on, and the line's text.
Piece = Tuple[int, str]


def starts_a_block(text: str) -> bool:
    """Whether ``text``, put at the start of a line, would begin a block of its own.

    That is a list marker followed by a space or the end (``- ``, ``1. ``, ``1) ``),
    a character that opens a heading, quote, table, or HTML (``#``, ``>``, ``|``,
    ``<``), a code fence (three backticks or tildes), a thematic break, or a line of
    only ``=`` or ``-``. ``reflow`` never starts a line with such a sentence.
    """
    text = text.lstrip()
    if not text:
        return False
    return bool(
        text[0] in _BLOCK_LEAD_CHARS
        or _LIST_MARKER_LEAD.match(text)
        or text.startswith(("```", "~~~"))
        or _THEMATIC_BREAK.match(text)
        or _SETEXT_UNDERLINE.match(text)
    )


def _is_kept(clean_lines: List[str], raw_lines: List[str]) -> bool:
    """Whether a prose block must stay as it is.

    That is when a line ends in a hard line break (two or more spaces, or a
    backslash), when a line starts with ``<`` after its indentation (and list
    marker), or when a line is only ``=`` signs (joining it to the line above would
    undo a setext heading). ``clean_lines`` are the lines without their list marker
    and indentation, ``raw_lines`` the lines as written.
    """
    for raw in raw_lines:
        if raw.endswith("  ") or raw.endswith("\\"):
            return True
    for clean in clean_lines:
        if clean.startswith("<") or re.fullmatch(r"=+", clean.strip()):
            return True
    return False


def _leading(line: str) -> str:
    """The white space a line starts with."""
    return line[:len(line) - len(line.lstrip())]


def _first_line_lead(block: Block, line: str) -> Optional[str]:
    """What the block's first line keeps unchanged before its text: indentation, and an item's marker.

    None when the block cannot be reflowed (an item whose first line has an
    unusual marker, a tab, or no text after the marker).
    """
    if block.kind == "list-item":
        match = _ITEM_START.match(line)
        return match.group(0) if match else None
    lead = _leading(line)
    return lead if line[len(lead):] else None


def _join_sentences(text: str) -> List[Tuple[int, str]]:
    """The lines ``text`` becomes, each with the offset in ``text`` its first sentence starts at.

    One line for each sentence, but never one that starts a block: a sentence that
    ``starts_a_block`` stays on the line before it, after the white space that was
    between them (a line break in it becoming a space). A line break inside a
    sentence becomes a space too.
    """
    lines: List[Tuple[int, str]] = []
    previous_end = 0
    for start, end in split_sentences(text):
        sentence = text[start:end].replace("\n", " ")
        if not lines:
            lines.append((start, sentence))
        elif starts_a_block(sentence):
            first, joined = lines[-1]
            lines[-1] = (first, joined + text[previous_end:start].replace("\n", " ") + sentence)
        else:
            lines.append((start, sentence))
        previous_end = end
    return lines


def reflow_pieces(block: Block, old: List[str]) -> Optional[List[Piece]]:
    """The new lines of one prose block, each with the old line it starts on; None when it stays as it is.

    ``old`` are the block's lines as written. The first sentence keeps the block's
    first line's own start; each later one is indented as the first line is (a
    paragraph or list paragraph), or to the item's text (a list item). A piece's
    line index counts from the block's first line (0), and is the line its first
    sentence began on before the lines were joined.
    """
    lead = _first_line_lead(block, old[0])
    if lead is None:
        return None
    clean = [old[0][len(lead):]] + [line.lstrip() for line in old[1:]]
    if _is_kept(clean, old):
        return None
    joined = _join_sentences("\n".join(clean))
    if not joined:
        return None
    # Where each old line starts in the joined text (every line but the last is followed by "\n").
    line_starts: List[int] = []
    offset = 0
    for line in clean:
        line_starts.append(offset)
        offset += len(line) + 1
    later = " " * block.content_col if block.kind == "list-item" else lead
    pieces: List[Piece] = []
    for index, (start, sentence) in enumerate(joined):
        pieces.append((bisect.bisect_right(line_starts, start) - 1, (lead if index == 0 else later) + sentence))
    return pieces


def reflow_block(block: Block, old: List[str]) -> Optional[List[str]]:
    """The new lines of one prose block, or None when it stays as it is (see ``reflow_pieces``)."""
    pieces = reflow_pieces(block, old)
    return None if pieces is None else [text for _, text in pieces]
