"""``reflow PAGE [--check]``: put each sentence of a page on a line of its own, changing no word.

    python3 -I .claude/skills/doc-library/scripts/doclib.py reflow docs/user/feeds.md
    python3 -I .claude/skills/doc-library/scripts/doclib.py reflow docs/user/feeds.md --check

``docs/agents/writing-docs.md`` asks for one sentence per line. This command makes a
page so without retyping it, so the change needs no review: only the line breaks
and the indentation of paragraphs, list items, and list paragraphs move. Every other
block (headings, code, tables, quotes, HTML comments, markers, rules, front matter)
and every blank line stays byte for byte, and so does a prose block that holds a
hard line break or starts a line with ``<``.

The pure part is ``reflow_text``. The command reads the page with
``pagewrite.read_page_text``, makes two checks of its own on top of the one
``pagewrite.rewrite`` makes (every non-space character is the same, in the same
order; the page has the same blocks and headings), and writes only when all pass.

Exit status: 0 when the page was reflowed or needed nothing; with ``--check``, 1 when
the page would change (and nothing is written); 1 also when a check failed.
"""

from __future__ import annotations

import re
from typing import Any, List, Optional, Tuple

import docmodel
import output
import pagewrite
import targets
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
_PROSE_KINDS = frozenset({"paragraph", "list-item", "list-para"})


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


def _join_sentences(text: str) -> List[str]:
    """The lines ``text`` becomes: one for each sentence, but never one that starts a block.

    A sentence that ``starts_a_block`` stays on the line before it, after the white
    space that was between them (a line break in it becoming a space). A line
    break inside a sentence becomes a space too.
    """
    lines: List[str] = []
    previous_end = 0
    for start, end in split_sentences(text):
        sentence = text[start:end].replace("\n", " ")
        if not lines:
            lines.append(sentence)
        elif starts_a_block(sentence):
            lines[-1] += text[previous_end:start].replace("\n", " ") + sentence
        else:
            lines.append(sentence)
        previous_end = end
    return lines


def _reflow_block(block: Block, old: List[str]) -> Optional[List[str]]:
    """The new lines of one prose block, or None when it stays as it is.

    ``old`` are the block's lines as written. The first sentence keeps the block's
    first line's own start; each later one is indented as the first line is (a
    paragraph or list paragraph), or to the item's text (a list item).
    """
    lead = _first_line_lead(block, old[0])
    if lead is None:
        return None
    clean = [old[0][len(lead):]] + [line.lstrip() for line in old[1:]]
    if _is_kept(clean, old):
        return None
    sentences = _join_sentences("\n".join(clean))
    if not sentences:
        return None
    later = " " * block.content_col if block.kind == "list-item" else lead
    return [lead + sentences[0]] + [later + sentence for sentence in sentences[1:]]


def reflow_text(text: str) -> str:
    """``text`` with each sentence of every paragraph, list item, and list paragraph on its own line.

    Only line breaks and indentation change: every other block, every blank line,
    and the page's last line end (or the lack of one) are kept as they were. The
    text must use ``\\n`` line ends; ``pagewrite.read_page_text`` guarantees it.
    """
    # A byte order mark is not part of the first line; set it aside and put it back.
    bom = "﻿" if text.startswith("﻿") else ""
    body = text[len(bom):]
    page = docmodel.parse("page.md", body)
    # The new lines of each prose block that changes, by the line number it starts at.
    replaced = {}
    for block in page.blocks:
        if block.kind in _PROSE_KINDS:
            new = _reflow_block(block, page.lines[block.start - 1:block.end])
            if new is not None:
                replaced[block.start] = (block.end, new)
    out: List[str] = []
    number = 1
    while number <= len(page.lines):
        if number in replaced:
            end, new = replaced[number]
            out.extend(new)
            number = end + 1
        else:
            out.append(page.lines[number - 1])
            number += 1
    ending = "\n" if body.endswith("\n") else ""
    return bom + "\n".join(out) + ending



def block_shape(text: str) -> List[Tuple[str, int, str]]:
    """The page's blocks as ``(kind, heading level, heading title)``, in order.

    Two texts with the same shape have the same blocks, kind for kind, and the same
    headings; a split that made a sentence into a list item or a heading changes it.
    """
    return [(block.kind, block.level, block.title) for block in docmodel.parse("page.md", text).blocks]


def problems_with(old: str, new: str) -> List[str]:
    """What is wrong with ``new`` as a reflow of ``old``, as short sentences; [] when nothing is.

    Two checks, stricter than the words' check ``pagewrite.rewrite`` makes: every
    non-space character is the same and in the same order, and the blocks and
    headings are the same.
    """
    problems = []
    if "".join(old.split()) != "".join(new.split()):
        problems.append("the non-space characters differ")
    if block_shape(old) != block_shape(new):
        problems.append("the blocks or headings differ")
    return problems


def run(args: Any) -> int:
    """Reflow the page ``args.page``; with ``--check``, only say whether it would change.

    The page is named as every command names one (``targets.resolve_page``): its
    path, or the unique end of it.
    """
    page = targets.resolve_page(args.root, args.page)
    old = pagewrite.read_page_text(args.root, page)
    new = reflow_text(old)
    if new == old:
        print(f"reflow: {page}: already one sentence per line")
        return output.EXIT_OK
    problems = problems_with(old, new)
    if problems:
        print(f"reflow: {page}: refused, nothing written: " + "; ".join(problems))
        return output.EXIT_NONE
    summary = (f"reflow: {page}: {len(docmodel.parse(page, old).lines)} lines became "
               f"{len(docmodel.parse(page, new).lines)}")
    if args.check:
        print(summary)
        return output.EXIT_NONE
    problems = pagewrite.rewrite(args.root, page, old, new)
    if problems:
        print(f"reflow: {page}: refused, nothing written: the words differ")
        for line in problems:
            print(line)
        return output.EXIT_NONE
    print(summary)
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``reflow`` subcommand."""
    parser = subparsers.add_parser(
        "reflow", parents=[common],
        help="put each sentence of a page on a line of its own, changing no word",
        description="Rewrite PAGE with one sentence on each line of its paragraphs and list items. "
                    "No word, heading, or other block changes; the page is written only when every check passes.")
    parser.add_argument("page", help="the page to reflow: its path, or the unique end of it")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; exit 1 when the page would change, 0 when it would not")
    parser.set_defaults(func=run, default_max=0)
