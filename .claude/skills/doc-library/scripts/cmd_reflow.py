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

from typing import Any, List, Tuple

import docmodel
import output
import pagewrite
import targets
# The block logic lives in a plain module so the lint's ``line-length`` rule can use it too.
from reflowblocks import PROSE_KINDS, reflow_block


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
        if block.kind in PROSE_KINDS:
            new = reflow_block(block, page.lines[block.start - 1:block.end])
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
