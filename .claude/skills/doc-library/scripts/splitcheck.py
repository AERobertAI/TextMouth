"""What ``split-check`` stands on: the words of a page, in order, and where two versions first differ.

A page that is split, merged, or reflowed must hold the same words in the same order.
``words`` reduces a page to its words (leaving out what a rework may change: front
matter, headings, markers, list and quote markers, white space), ``read_version``
reads a page from the working tree or from a git ref, and ``compare`` walks two word
lists once and says where they first differ.

Only the standard library is used, and a page is read only from inside the repository.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Set, Tuple

import docmodel
from citations import FILES_LINE, files_block_paths
from docmodel import Block, Page
from output import UsageError
from repofiles import RepoFiles

# The block kinds whose words are never counted: they hold no prose of the page.
_LEFT_OUT = frozenset({"front-matter", "heading", "marker"})
# The block kinds a ``Files:`` list can be written in (a code block or a table never is).
_FILES_KINDS = frozenset({"paragraph", "list-item", "list-para"})
# The block kinds whose lines start with markers to strip: a list item's first line has its
# bullet or number, and every line of a quote has its ``>``.
_QUOTE_KIND = "quote"
_ITEM_KIND = "list-item"

# One marker at the start of a line: a quote's ``>``, or a bullet or number followed by
# white space (or the line's end). Applied repeatedly, it strips ``> - 1. text`` down to ``text``.
_LEADING_MARKER = re.compile(r"[ \t]*(?:>|(?:[-*+]|\d{1,9}[.)])(?=[ \t]|$))")

# How many words of context a difference shows on each side of the differing word.
CONTEXT_WORDS = 8


@dataclass(frozen=True)
class Word:
    """One word of a page: its text, the file it came from, and its (1-based) line there."""

    text: str
    source: str      # the file (or REF:PATH) it came from
    line: int


@dataclass(frozen=True)
class Difference:
    """The first place two word lists differ, with what to print about it.

    ``index`` is the 0-based position of the first differing word. ``old`` and ``new``
    are the words there, or None on the side that ended first. ``old_last`` and
    ``new_last`` are each side's last word (None for an empty side), which places a
    side that ended. ``old_context`` and ``new_context`` show the differing word in
    brackets between up to ``CONTEXT_WORDS`` words on each side of it.
    """

    index: int
    old: Optional[Word]
    new: Optional[Word]
    old_last: Optional[Word]
    new_last: Optional[Word]
    old_context: str
    new_context: str
    old_count: int
    new_count: int


def strip_leading_markers(line: str) -> str:
    """``line`` without the list bullets, numbers, and quote ``>`` marks it starts with."""
    while True:
        match = _LEADING_MARKER.match(line)
        if match is None or match.end() == 0:
            return line
        line = line[match.end():]


def is_files_block(page: Page, block: Block) -> bool:
    """Whether ``block`` is a ``Files:`` list (continuation lines included)."""
    return block.kind in _FILES_KINDS and FILES_LINE.match(page.text(block.start, block.end)) is not None


def page_words(page: Page, source: str, files_to_src: bool = False) -> List[Word]:
    """The words of ``page``, as ``words`` describes, labelled with ``source``.

    Code blocks and tables keep every word as written, markers included. With
    ``files_to_src`` a ``Files:`` block is left out too.
    """
    found: List[Word] = []
    for block in page.blocks:
        if block.kind in _LEFT_OUT:
            continue
        if files_to_src and is_files_block(page, block):
            continue
        for number in range(block.start, block.end + 1):
            line = page.lines[number - 1]
            # Only the lines that can start with a marker lose it; a code line is left as written.
            if block.kind == _QUOTE_KIND or (block.kind == _ITEM_KIND and number == block.start):
                line = strip_leading_markers(line)
            found.extend(Word(piece, source, number) for piece in line.split())
    return found


def words(text: str, source: str, files_to_src: bool = False) -> List[Word]:
    """The words of the page ``text`` in order, as ``Word``s labelled with ``source``.

    Front matter, heading lines, marker lines, and blank lines add none; from every
    other line the leading list marker (``-``, ``*``, ``+``, ``1.``, ``1)``) and quote
    marker (``>``) are dropped, and the rest is split at white space. Code blocks and
    tables keep their words. With ``files_to_src``, ``Files:`` blocks add none either.
    """
    return page_words(docmodel.parse(source, text), source, files_to_src)


def page_paths(page: Page) -> Tuple[List[str], List[str]]:
    """The paths a page names: ``(Files: block tokens, marker src entries)``, in page order.

    A ``Files:`` token is kept only when ``is_repo_path`` is the judge, so the caller
    filters them; here they are the raw path tokens of each block.
    """
    files: List[str] = []
    sources: List[str] = []
    for block in page.blocks:
        if block.kind == "marker" and block.marker is not None:
            sources.extend(block.marker.src)
        elif is_files_block(page, block):
            listed = files_block_paths(page.text(block.start, block.end)) or []
            files.extend(token for _offset, token in listed)
    return files, sources


def spellings(repo: RepoFiles, token: str) -> Set[str]:
    """What a written path stands for: the paths it resolves to, and the token as written.

    Comparing these sets makes ``Parser.swift`` and ``TextMouth/Parsers/Parser.swift``
    one path when the first resolves to the second.
    """
    return set(repo.resolve(token)) | {token}


def missing_paths(old_pages: Iterable[Page], new_pages: Iterable[Page], repo: RepoFiles) -> List[str]:
    """The tokens of the OLD pages' ``Files:`` blocks that no NEW marker ``src`` or ``Files:`` block names.

    Only a token ``repo.is_repo_path`` accepts counts. A token is named when it, or
    anything it resolves to, is among the names the NEW pages give. Each missing
    token is listed once, in the order the OLD pages write it.
    """
    named: Set[str] = set()
    for page in new_pages:
        files, sources = page_paths(page)
        for token in sources + [token for token in files if repo.is_repo_path(token)]:
            named |= spellings(repo, token)
    missing: List[str] = []
    for old in old_pages:
        for token in page_paths(old)[0]:
            if repo.is_repo_path(token) and token not in missing and not (spellings(repo, token) & named):
                missing.append(token)
    return missing


def read_version(root: Path, spec: str) -> Tuple[str, str]:
    """``(source label, text)`` of the page ``spec`` names: a path inside ``root``, or ``REF:PATH``.

    ``REF:PATH`` is read with git from the repository at ``root`` (and labelled with
    the whole spec); anything else is a file of the working tree. A path outside the
    root, a ref git does not know, or a file that is not there is a UsageError.
    """
    if ":" not in spec:
        return spec, docmodel.read_page_bytes(root, spec).decode("utf-8", errors="replace")
    ref, path = spec.split(":", 1)
    # A ref that starts with ``-`` would be read as an option; PATH must stay inside the root.
    if not ref or ref.startswith("-") or docmodel.name_inside(root, path) is None:
        raise UsageError(f"{spec} is not REF:PATH with a path inside the repository")
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "cat-file", "blob", f"{ref}:{path}"],
            capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        raise UsageError(f"git has no file {spec}") from None
    return spec, result.stdout.decode("utf-8", errors="replace")


def spec_path(root: Path, spec: str) -> str:
    """The page ``spec`` names as a path from ``root``: the PATH of ``REF:PATH``, else the path itself.

    ``read_version`` has checked the spec by then, so a path that leaves the root is not met here.
    """
    path = spec.split(":", 1)[1] if ":" in spec else spec
    return docmodel.name_inside(root, path) or path


def _context(listed: List[Word], index: int) -> str:
    """The words around ``index``, the one at ``index`` (when there is one) in brackets."""
    before = [word.text for word in listed[max(0, index - CONTEXT_WORDS):index]]
    at = [f"[{listed[index].text}]"] if index < len(listed) else ["[end of text]"]
    after = [word.text for word in listed[index + 1:index + 1 + CONTEXT_WORDS]]
    return " ".join(before + at + after)


def compare(old: List[Word], new: List[Word]) -> Optional[Difference]:
    """The first difference between two word lists, or None when their texts are the same.

    One walk over the shared length finds the first word that differs; when one list
    is a prefix of the other, the difference is where the shorter one ends.
    """
    shared = min(len(old), len(new))
    index = 0
    while index < shared and old[index].text == new[index].text:
        index += 1
    if index == shared and len(old) == len(new):
        return None
    return Difference(
        index=index,
        old=old[index] if index < len(old) else None,
        new=new[index] if index < len(new) else None,
        old_last=old[-1] if old else None,
        new_last=new[-1] if new else None,
        old_context=_context(old, index),
        new_context=_context(new, index),
        old_count=len(old),
        new_count=len(new),
    )


def place(word: Optional[Word], last: Optional[Word], label: str) -> str:
    """Where a side of a difference is: ``SOURCE:LINE``, or after the last word of a side that ended."""
    if word is not None:
        return f"{word.source}:{word.line}"
    if last is not None:
        return f"{last.source}:{last.line} (the end)"
    return f"{label} (no words)"


def describe(difference: Difference, old_label: str, new_label: str) -> List[str]:
    """The lines ``split-check`` prints for a difference, naming both places and both counts."""
    return [
        f"split-check: the words differ at word {difference.index + 1}",
        f"  OLD {place(difference.old, difference.old_last, old_label)}: {difference.old_context}",
        f"  NEW {place(difference.new, difference.new_last, new_label)}: {difference.new_context}",
        f"  OLD has {difference.old_count} words, NEW has {difference.new_count}",
    ]


__all__ = [
    "Word", "Difference", "words", "page_words", "page_paths", "missing_paths", "read_version",
    "compare", "describe", "strip_leading_markers",
]
