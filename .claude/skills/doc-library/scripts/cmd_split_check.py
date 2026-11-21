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

``--loose`` compares each prose word lowercased and without the punctuation at its two
ends (``.,;:!?()[]"'`` and the curly quotes), and leaves out a word that is only
punctuation (a lone ``-``). Code stays exact: code blocks, tables, and inline code keep
their case and punctuation. It proves that a re-punctuation (a semicolon made a full
stop and a capital, a clause list made a list) changed no word; see ``splitcheck.loose_key``.

``--update-baseline``, when the check passes, moves the lint baseline's counts with the
words: the OLD pages' counts become the NEW pages' (see ``update_baseline``).

Prints ``split-check: same words (N words)`` (``same words, loosely (N words)`` under
``--loose``) and exits 0, or the first difference (both places, up to eight words
around it, both counts) and exits 1. A path outside the repository or a ref git does
not know is a usage error (exit status 2).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, List

import baseline
import cmd_lint
import docmodel
import lintrules
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


def words_of(pages: List[Page], files_to_src: bool, loose: bool = False) -> List[Word]:
    """The words of the pages one after another, each labelled with its page's source.

    ``loose`` reads each prose word by its lowercase, end-punctuation-free key.
    """
    found: List[Word] = []
    for page in pages:
        found.extend(splitcheck.page_words(page, page.path, files_to_src, loose))
    return found


def unique_paths(root: Path, specs: List[str]) -> List[str]:
    """The pages the specs name as paths from the root, each once, in the order given."""
    return list(dict.fromkeys(splitcheck.spec_path(root, spec) for spec in specs))


def update_baseline(root: Path, old_specs: List[str], new_specs: List[str]) -> int:
    """Hand the OLD pages' lint baseline counts to the NEW pages, after the words matched.

    Nothing is done when the baseline holds nothing for the OLD pages. Each rule's
    count over the NEW pages may not pass its pool (``splitcheck.rule_pools``): when
    one does, nothing is written and the rule is named (exit 1). Otherwise each NEW
    page's entry becomes its counts today, and an OLD page that is not a NEW page and
    no longer exists loses its entry.
    """
    old_pages, new_pages = unique_paths(root, old_specs), unique_paths(root, new_specs)
    base = baseline.load_baseline(root) or {}
    if not any(base.get(page) for page in old_pages):
        print("split-check: the baseline holds nothing for the OLD pages; left as it is")
        return output.EXIT_OK
    now = baseline.counts(lintrules.lint(root))
    overruns = splitcheck.pool_overruns(base, now, old_pages, new_pages)
    if overruns:
        for rule, held, pool in overruns:
            print(f"split-check: the baseline is not updated: the NEW pages have {held} violations of {rule}, "
                  f"the OLD pages and the baseline allow {pool}")
        return output.EXIT_NONE
    gone = {page for page in old_pages if page not in new_pages and not (root / page).exists()}
    updated = splitcheck.hand_over(base, now, new_pages, gone)
    cmd_lint.print_changes(base, updated)
    if updated != base:
        baseline.write_baseline(root, updated)
    print("split-check: the baseline now holds the OLD pages' counts on the NEW pages")
    return output.EXIT_OK


def run(args: Any) -> int:
    """Compare OLD with the NEW files; print the verdict and return the exit status."""
    old_pages = read_pages(args.root, args.old.split(","))
    new_pages = read_pages(args.root, args.new)

    old_words = words_of(old_pages, args.files_to_src, args.loose)
    new_words = words_of(new_pages, args.files_to_src, args.loose)

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
    # A loose pass says so, so a commit message quoting it cannot pass for an exact check.
    mode = ", loosely" if args.loose else ""
    print(f"split-check: same words{mode} ({len(old_words)} words)")
    if args.update_baseline:
        return update_baseline(args.root, args.old.split(","), args.new)
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
    parser.add_argument("--loose", action="store_true",
                        help="compare words without their case and end punctuation, outside code")
    parser.add_argument("--update-baseline", action="store_true",
                        help="when the words match, hand the OLD pages' lint baseline counts to the NEW pages "
                             "(never raising a rule's total)")
    parser.set_defaults(func=run, default_max=0)
