"""``code TARGET``: from a section straight to the code it describes.

    python3 -I .claude/skills/doc-library/scripts/doclib.py code state/saving-failures:40
    python3 -I .claude/skills/doc-library/scripts/doclib.py code epub-headings

TARGET is a section as ``show`` takes it. The hits come in two groups:

1. Each distinct path the section cites (its marker's ``src``, its ``Files:`` lists,
   and the paths in backticks), as ``path:1-N`` (``TOKEN:0-0`` and ``missing`` for a
   citation that names nothing).
2. Each distinct code name the section mentions, in order of first mention, with
   up to three of its declarations as ``path:L-L``: types first, then extensions,
   then functions. When there are more, the third says how many.

Exit status 0 with hits, 1 without, 2 for a target that names nothing.
"""

from __future__ import annotations

import os
from typing import Any, Iterator, List

import docmodel
import output
import sectionrefs
import swiftindex
import targets
from citations import Citation
from docmodel import Page, Section
from output import Hit
from repofiles import RepoFiles
from swiftindex import SwiftIndex

# The most declarations printed for one name.
DECLARATIONS_PER_NAME = 3


def line_count(repo: RepoFiles, path: str) -> int:
    """The number of lines of the repository file ``path`` (at least 1; 1 when it cannot be read)."""
    relative = docmodel.name_inside(repo.root, path)
    full = os.path.join(repo.root, relative) if relative else ""
    try:
        # A symbolic link may point outside the repository: never open one.
        if not relative or os.path.islink(full):
            return 1
        with open(full, "rb") as handle:
            data = handle.read()
    except OSError:
        return 1
    # A last line without its line end still counts.
    return max(1, data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1))


def path_hits(cites: List[Citation], repo: RepoFiles) -> Iterator[Hit]:
    """One hit for each distinct path the citations resolve to, and for each that resolves to nothing."""
    seen = set()
    for cite in cites:
        heading = f"cited ({cite.kind})"
        if not cite.paths:
            if cite.token not in seen:
                seen.add(cite.token)
                yield Hit(cite.token, 0, 0, heading, "missing",
                          extra={"kind": "path", "name": cite.token, "decl_kind": None})
            continue
        for path in cite.paths:
            if path in seen:
                continue
            seen.add(path)
            if path.endswith("/"):
                text, end = f"folder of {len(repo.under(path))} files", 1
            else:
                text, end = "file", line_count(repo, path)
            yield Hit(path, 1, end, heading, text,
                      extra={"kind": "path", "name": cite.token, "decl_kind": None})


def declaration_hits(names: List[str], index: SwiftIndex) -> Iterator[Hit]:
    """Up to three declarations for each of ``names`` (distinct, in order of first mention)."""
    for name in names:
        found = index.lookup(name)
        for number, declaration in enumerate(found[:DECLARATIONS_PER_NAME], start=1):
            text = declaration.text
            more = len(found) - DECLARATIONS_PER_NAME
            if number == DECLARATIONS_PER_NAME and more > 0:
                text = f"{text} (+{more} more)"
            yield Hit(declaration.path, declaration.line, declaration.line, name, text,
                      extra={"kind": "declaration", "name": name, "decl_kind": declaration.kind})


def section_hits(page: Page, section: Section, repo: RepoFiles, index: SwiftIndex) -> Iterator[Hit]:
    """All the hits of ``code`` for one section: its cited paths, then its named declarations."""
    yield from path_hits(sectionrefs.section_citations(page, section, repo), repo)
    blocks = sectionrefs.section_blocks(page, section)
    # A backticked file name is a path, cited above, not a code name. dict keeps the order of
    # first mention while dropping repeats.
    names = list(dict.fromkeys(m.name for m in swiftindex.mentions(blocks, index)
                               if not swiftindex.is_file_name(m.name)))
    yield from declaration_hits(names, index)


def run(args: Any) -> int:
    """Print the code of the section ``args.target`` names."""
    page, section = targets.resolve_target(args.root, args.target)
    repo = RepoFiles.load(args.root)
    index = SwiftIndex.load(repo)
    total = output.emit(section_hits(page, section, repo, index), args)
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``code`` subcommand."""
    parser = subparsers.add_parser(
        "code", parents=[common], help="the code a section cites and names",
        description="List the files a section cites and the declarations of the code names "
                    "it mentions. TARGET is PAGE#HEADING, PAGE:LINE, or a section id.")
    parser.add_argument("target", help="PAGE#HEADING, PAGE:LINE, or a section id")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
