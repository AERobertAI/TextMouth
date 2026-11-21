"""``where NAME``: which sections of the docs cite a path, a file name, or a Swift name.

    python3 -I .claude/skills/doc-library/scripts/doclib.py where TextMouth/Models/Book.swift
    python3 -I .claude/skills/doc-library/scripts/doclib.py where TextMouth/Parsers/
    python3 -I .claude/skills/doc-library/scripts/doclib.py where EPUBParser.swift
    python3 -I .claude/skills/doc-library/scripts/doclib.py where Book

NAME is read as, in this order:

1. a path, when it holds ``/``: a section cites it when a citation (a marker
   ``src`` entry, a ``Files:`` entry, or a path in backticks) names the file, a
   folder holding it, or a file inside it when NAME is a folder. A path that no
   longer exists still finds the sections that cite it by the same spelling.
2. a file name, when it has no ``/`` and ends in a ``.`` and an extension such as
   ``.swift`` or ``.md``: the same, for every file of that name.
3. a Swift name: a section cites it when one of its units (a sentence, a line of
   code, the marker, the heading) holds the name as a whole name, so ``Book``
   finds ``Book.Storage`` and ```Book``` but not ``BookBox``.

One hit for each section, at its first matching place: the marker, then a
``Files:`` line, then the rest in line order. Exit status 0 when something matched,
1 when nothing did, 2 for a NAME of none of the three kinds.
"""

from __future__ import annotations

import re
from typing import Any, Iterator, List, Optional, Tuple

import citations
import docmodel
import output
import sectionrefs
from citations import Citation
from docmodel import Page, Section
from output import Hit, UsageError
from repofiles import SOURCE_EXTENSIONS, RepoFiles

# What a file name ends in: a dot and an extension that starts with a letter.
_EXTENSION = re.compile(r"\.([A-Za-z][A-Za-z0-9]*)\Z")
# The extensions, besides source files', that a name is taken to be a file's for even
# when no such file exists now (a removed one). Any other ending (``Book.Storage``,
# ``AppState.shared``) is a Swift name unless a file of that name exists.
DOC_EXTENSIONS = SOURCE_EXTENSIONS | frozenset({
    "md", "yml", "yaml", "json", "plist", "txt", "strings", "entitlements", "xcconfig", "html", "css",
})

USAGE_MESSAGE = "where takes a path, a file name, or a Swift name; find searches words"


def classify(name: str, repo: RepoFiles) -> str:
    """What kind of NAME this is: ``path``, ``file``, or ``swift``; a UsageError for none.

    A name with ``/`` is a path. One with no ``/`` that ends in an extension is a
    file name when a file of that name exists or the extension is a file's, not a
    Swift member's. Anything else must be shaped like a Swift name.
    """
    if "/" in name:
        return "path"
    match = _EXTENSION.search(name)
    if match and (repo.by_name(name) or match.group(1) in DOC_EXTENSIONS):
        return "file"
    if citations.IDENTIFIER.match(name):
        return "swift"
    raise UsageError(USAGE_MESSAGE)


def citation_hit(page: Page, section: Section, citation: Citation, prefix: str = "") -> Hit:
    """The hit for a section at one of its citations: the citing line, focused on the token.

    ``prefix`` is put before the line (``affected`` leads with the change's status).
    """
    line = page.lines[citation.line - 1] if 0 < citation.line <= len(page.lines) else ""
    found = line.find(citation.token)
    focus: Optional[Tuple[int, int]] = None
    if found >= 0:
        focus = (len(prefix) + found, len(prefix) + found + len(citation.token))
    return Hit(
        path=page.path, start=citation.line, end=citation.line, heading=section.heading,
        text=prefix + line, focus=focus,
        extra={"kind": citation.kind, "token": citation.token,
               "id": section.marker.id if section.marker else None,
               "section_start": section.start, "section_end": section.end},
    )


def path_targets(name: str, kind: str, repo: RepoFiles) -> List[str]:
    """The repository paths a path or file NAME stands for; NAME itself when it names none."""
    found = repo.resolve(name) if kind == "path" else repo.by_name(name)
    return found or [name]


def path_hit(page: Page, section: Section, repo: RepoFiles, name: str, kind: str,
             targets: List[str]) -> Optional[Hit]:
    """The hit at the section's first citation of NAME, or None when it cites none."""
    for citation in sectionrefs.section_citations(page, section, repo):
        named = any(citations.names_path(citation, target, name) for target in targets)
        # A file name also finds a citation whose last component it is, even when
        # that file no longer exists.
        if not named and kind == "file":
            named = citation.token.rstrip("/").rsplit("/", 1)[-1] == name
        if named:
            return citation_hit(page, section, citation)
    return None


def name_hit(page: Page, section: Section, whole_name: "re.Pattern[str]", name: str) -> Optional[Hit]:
    """The hit at the section's first unit that holds the Swift name, or None."""
    for unit in docmodel.units(page, section):
        match = whole_name.search(unit.text)
        if match is None:
            continue
        return Hit(
            path=page.path, start=unit.start, end=unit.end, heading=section.heading, text=unit.text,
            focus=match.span(),
            extra={"kind": "name", "token": name, "id": section.marker.id if section.marker else None,
                   "section_start": section.start, "section_end": section.end},
        )
    return None


def whole_name_pattern(name: str) -> "re.Pattern[str]":
    """The pattern for ``name`` as a whole name: not preceded or followed by a letter, digit, or ``_``."""
    return re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")


def hits_for(args: Any, repo: RepoFiles) -> Iterator[Hit]:
    """The hits for ``args.name``: one for each section of the scope that cites it."""
    name = args.name
    kind = classify(name, repo)
    targets = path_targets(name, kind, repo) if kind != "swift" else []
    whole_name = whole_name_pattern(name)
    for path in docmodel.scope_pages(args.root, args.scope):
        page = docmodel.load_page(args.root, path)
        for section in page.sections:
            if kind == "swift":
                hit = name_hit(page, section, whole_name, name)
            else:
                hit = path_hit(page, section, repo, name, kind, targets)
            if hit is not None:
                yield hit


def run(args: Any) -> int:
    """Print the sections that cite NAME; 0 when there were some, else 1."""
    if not args.name.strip():
        raise UsageError(USAGE_MESSAGE)
    repo = RepoFiles.load(args.root)
    total = output.emit(hits_for(args, repo), args, noun="sections")
    return output.EXIT_OK if total else output.EXIT_NONE


def register(subparsers: Any, common: Any) -> None:
    """Add the ``where`` subcommand."""
    parser = subparsers.add_parser(
        "where", parents=[common], help="which sections cite a path, a file name, or a Swift name",
        description="List the sections of the docs that cite a repository path, a file name, or a Swift name.")
    parser.add_argument("name", metavar="NAME", help="a path (holds /), a file name (Book.swift), or a Swift name (Book)")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
