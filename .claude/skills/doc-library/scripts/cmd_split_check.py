"""``split-check OLD NEW [NEW ...]``: prove a reworked page holds the same words in the same order.

    python3 -I .claude/skills/doc-library/scripts/doclib.py split-check HEAD:docs/user/feeds.md docs/user/feeds.md docs/user/feed-rules.md

OLD and each NEW is a file inside the repository, or ``REF:PATH`` for the file as
git has it at REF. The NEW files' words are taken one file after another, in the order
given, so a page split in three is ``OLD NEW1 NEW2 NEW3``. OLD may also be several
versions joined by commas (paths hold no commas), read in the order given, so sections
moved from one page into another existing page are one check:
``REF:AGENTS.md,REF:docs/agents/history.md AGENTS.md docs/agents/orchestrator.md docs/agents/history.md``. Headings, markers, list and
quote markers, front matter, and white space do not count (see ``splitcheck.words``).

``--files-to-src`` is for turning ``Files:`` lists into section markers: no ``Files:``
block counts as words on either side, and every repository path OLD's blocks name must
be named by a NEW marker's ``src`` or a NEW ``Files:`` block.

Prints ``split-check: same words (N words)`` and exits 0, or the first difference
(both places, up to eight words around it, both counts) and exits 1. A path outside
the repository or a ref git does not know is a usage error (exit status 2).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, List

import docmodel
import output
import splitcheck
from docmodel import Page
from repofiles import RepoFiles
from splitcheck import Word


def read_pages(root: Path, specs: List[str]) -> List[Page]:
    """The pages the specs name (files, or ``REF:PATH``), parsed, in the order given."""
    pages = []
    for spec in specs:
        label, text = splitcheck.read_version(root, spec)
        pages.append(docmodel.parse(label, text))
    return pages


def words_of(pages: List[Page], files_to_src: bool) -> List[Word]:
    """The words of the pages one after another, each labelled with its page's source."""
    found: List[Word] = []
    for page in pages:
        found.extend(splitcheck.page_words(page, page.path, files_to_src))
    return found


def run(args: Any) -> int:
    """Compare OLD with the NEW files; print the verdict and return the exit status."""
    old_pages = read_pages(args.root, args.old.split(","))
    new_pages = read_pages(args.root, args.new)

    old_words = words_of(old_pages, args.files_to_src)
    new_words = words_of(new_pages, args.files_to_src)

    failed = False
    difference = splitcheck.compare(old_words, new_words)
    if difference is not None:
        failed = True
        for line in splitcheck.describe(difference, args.old, new_pages[0].path):
            print(line)
    if args.files_to_src:
        missing = splitcheck.missing_paths(old_pages, new_pages, RepoFiles.load(args.root))
        if missing:
            failed = True
            print(f"split-check: {len(missing)} Files: paths of OLD are named by no NEW marker src or Files: block:")
            for token in missing:
                print(f"  {token}")
    if failed:
        return output.EXIT_NONE
    print(f"split-check: same words ({len(old_words)} words)")
    return output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``split-check`` subcommand."""
    parser = subparsers.add_parser(
        "split-check", parents=[common],
        help="check that a reworked page holds the same words in the same order",
        description="Check that the NEW files, taken in order, hold the words of OLD in the same order. "
                    "OLD and NEW are files in the repository or REF:PATH.")
    parser.add_argument("old", help="the page before: a file, or REF:PATH; several joined by commas, in reading order")
    parser.add_argument("new", nargs="+", help="the page(s) after, in reading order: a file, or REF:PATH")
    parser.add_argument("--files-to-src", action="store_true",
                        help="leave Files: blocks out, and require each path OLD's name to be named in NEW")
    parser.set_defaults(func=run, default_max=0)
