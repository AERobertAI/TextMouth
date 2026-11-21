"""``suggest-src TARGET``: the paths a section's marker ``src`` should cite.

    python3 -I .claude/skills/doc-library/scripts/doclib.py suggest-src state/saving-failures:3

For an agent (or the ``mark`` command) to copy into a marker. A suggestion is a
path the section's text points at and its marker's ``src`` does not already cover:

1. each path of the section's ``Files:`` lists;
2. the one or two files that declare a type the section names, or a function it calls;
3. each backticked bare file name (``EPUBParser.swift``) that resolves.

Each path comes once, at its first reason. ``Files:`` paths come first, then the rest by
how often the section names them, then in order of first mention. One hit for each,
as ``path:L-L`` (the declaration's line, or 1), the section's heading, and the reason.
Exit status 0 with suggestions, 1 without, 2 for a target that names nothing.

With ``--strings`` the suggestions come from the section's interface words instead
(``wordingsearch``): the heading and each quoted or bold name or menu path are looked up
among the Swift string literals, and the files holding them are listed, a ``…Wording``
file first with the files that use it, for a user page that names no code.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Any, Dict, Iterator, List

import output
import sectionrefs
import swiftindex
import targets
import wordingsearch
from citations import KIND_FILES, KIND_TEXT
from docmodel import Page, Section
from output import Hit
from repofiles import RepoFiles
from swiftindex import SwiftIndex

# The most files a name may lead to before it is too common to suggest any.
MOST_FILES_PER_NAME = 2


@dataclass(frozen=True)
class Suggestion:
    """A path to cite: repository-relative (a folder ends in ``/``), a line, and why."""

    path: str       # repository-relative; a folder ends in /
    line: int       # the declaration's line, or 1
    reason: str     # "Files: line", "declares ReaderViewModel (named 4 times)", "file name EPUBParser.swift"


@dataclass
class _Candidate:
    """A suggestion being collected: its first reason, and how often the section names it."""

    suggestion: Suggestion
    count: int


def _times(count: int) -> str:
    """``1 time`` or ``N times``."""
    return f"{count} time" + ("" if count == 1 else "s")


def suggest_paths(page: Page, section: Section, repo: RepoFiles, index: SwiftIndex) -> List[Suggestion]:
    """The paths the section's marker ``src`` should hold and does not yet (see the module)."""
    marker = section.marker
    already = [path for entry in (marker.src if marker else []) for path in repo.resolve(entry)]
    cites = sectionrefs.section_citations(page, section, repo)
    blocks = sectionrefs.section_blocks(page, section)

    # path -> candidate, in the order each path was first found.
    found: Dict[str, _Candidate] = {}
    files_first: List[str] = []

    def add(path: str, line: int, reason: str, count: int) -> None:
        """Count one more naming of ``path``; keep its first reason, unless ``src`` covers it."""
        if any(RepoFiles.covers(cover, path) for cover in already):
            return
        if path in found:
            found[path].count += count
        else:
            found[path] = _Candidate(Suggestion(path, line, reason), count)

    # 1. The Files: lists.
    for cite in cites:
        if cite.kind == KIND_FILES:
            for path in cite.paths:
                add(path, 1, "Files: line", 1)
                if path not in files_first and path in found:
                    files_first.append(path)
    # 2. The files declaring each named type, or called function.
    # A backticked file name is no code name; step 3 takes it.
    named = Counter(mention.name for mention in swiftindex.mentions(blocks, index)
                    if not swiftindex.is_file_name(mention.name))
    for name, count in named.items():
        declarations = index.defining_declarations(name)
        if 0 < len(declarations) <= MOST_FILES_PER_NAME:
            for declaration in declarations:
                add(declaration.path, declaration.line, f"declares {name} (named {_times(count)})", count)
    # 3. The bare file names in backticks.
    for cite in cites:
        if cite.kind == KIND_TEXT and "/" not in cite.token:
            for path in cite.paths:
                add(path, 1, f"file name {cite.token}", 1)

    rest = [path for path in found if path not in files_first]
    # sorted is stable, so equal counts keep the order of first mention.
    rest.sort(key=lambda path: -found[path].count)
    return [found[path].suggestion for path in files_first + rest]


def suggestion_hits(suggestions: List[Suggestion], section: Section) -> Iterator[Hit]:
    """One hit for each suggestion: its path and line, the section's heading, and the reason."""
    for suggestion in suggestions:
        yield Hit(suggestion.path, suggestion.line, suggestion.line, section.heading, suggestion.reason,
                  extra={"reason": suggestion.reason})


def run_strings(args: Any, page: Page, section: Section, repo: RepoFiles) -> int:
    """Print the Swift files whose string literals hold the section's interface words (``--strings``)."""
    phrases = wordingsearch.interface_phrases(
        section.title, sectionrefs.section_blocks(page, section))
    results = wordingsearch.find_in_swift(repo, phrases)
    total = wordingsearch.emit_files(results, section.heading, args)
    return output.EXIT_OK if total else output.EXIT_NONE


def run(args: Any) -> int:
    """Print the paths the section ``args.target`` names should cite (or, with ``--strings``, the files of its words)."""
    page, section = targets.resolve_target(args.root, args.target)
    repo = RepoFiles.load(args.root)
    if args.strings:
        return run_strings(args, page, section, repo)
    suggestions = suggest_paths(page, section, repo, SwiftIndex.load(repo))
    total = output.emit(suggestion_hits(suggestions, section), args, noun="suggestions")
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``suggest-src`` subcommand."""
    parser = subparsers.add_parser(
        "suggest-src", parents=[common], help="the paths a section's marker src should cite",
        description="Suggest the paths for a section's marker src: its Files: lists, the files that "
                    "declare the names it mentions, and the file names it writes. TARGET is "
                    "PAGE#HEADING, PAGE:LINE, or a section id.")
    parser.add_argument("target", help="PAGE#HEADING, PAGE:LINE, or a section id")
    parser.add_argument(
        "--strings", action="store_true",
        help="find the code through the section's interface words (its heading and the quoted or bold "
             "names and menu paths in it) among the app's Swift string literals, a user page's way in")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
