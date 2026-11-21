"""``stale``: the paths and code names the docs cite that no longer exist.

    python3 -I .claude/skills/doc-library/scripts/doclib.py stale
    python3 -I .claude/skills/doc-library/scripts/doclib.py stale --scope all
    python3 -I .claude/skills/doc-library/scripts/doclib.py stale --logs

Two kinds of stale reference, one hit for each, at its line:

1. A path a section cites (``src``, a ``Files:`` list, or backticks in prose) that
   names no file or folder of the repository.
2. A backticked code name that the Swift index does not know: a type-shaped part of
   it that no ``class``, ``struct``, ``enum``, ``protocol``, ``actor``, ``typealias``
   or ``extension`` declares, or a call to something that is no function and no type.

What the check cannot judge, or that is not TextMouth's own (Apple's SDK, a vendored
package, an Info.plist key), is listed in ``stale-allowlist.txt`` beside the skill;
``load_allowlist`` reads it. ``stale_items`` is the function the lint counts.

The two log pages (``docmodel.LOG_PAGES``) are left out, as the lint's ``stale`` rule
leaves them out: a log may name what was removed, since it is history. ``--logs`` reads
them too, to see what history names.

Always one line on standard error: ``doclib: N stale references (P paths, M names)``.
Exit status 0 when there are none, 1 when there are some.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, List, Optional, Tuple

import docmodel
import output
import sectionrefs
import swiftindex
from citations import KIND_SRC
from docmodel import Page, Section
from output import Hit
from repofiles import SOURCE_EXTENSIONS, RepoFiles
from swiftindex import SwiftIndex

# Where the allowlist is, from the repository's root.
ALLOWLIST_PATH = ".claude/skills/doc-library/stale-allowlist.txt"

# The two kinds of stale reference (the ``kind`` of a ``StaleItem``).
KIND_PATH = "path"
KIND_NAME = "name"


@dataclass(frozen=True)
class Allowlist:
    """What ``stale`` never reports: path prefixes, name prefixes, and exact names."""

    paths: Tuple[str, ...] = ()
    name_prefixes: Tuple[str, ...] = ()
    names: frozenset = frozenset()

    def allows_path(self, token: str) -> bool:
        """True when ``token`` starts with an allowlisted path prefix."""
        return any(token.startswith(prefix) for prefix in self.paths)

    def allows_name(self, name: str) -> bool:
        """True when ``name`` is an allowlisted exact name or starts with an allowlisted name prefix."""
        return name in self.names or any(name.startswith(prefix) for prefix in self.name_prefixes)

    def allows_file(self, token: str) -> bool:
        """True when ``token``, a bare file name, is named exactly by the allowlist."""
        return token in self.names


def parse_allowlist(text: str) -> Allowlist:
    """The allowlist an entry file's ``text`` describes.

    One entry a line; ``#`` starts a comment and blank lines are ignored. An entry
    with ``/`` is a path prefix; one ending in ``*`` is a name prefix; any other is
    an exact name.
    """
    paths: List[str] = []
    prefixes: List[str] = []
    names: List[str] = []
    for line in text.splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        if "/" in entry:
            paths.append(entry)
        elif entry.endswith("*"):
            prefixes.append(entry[:-1])
        else:
            names.append(entry)
    return Allowlist(tuple(paths), tuple(prefixes), frozenset(names))


def load_allowlist(root: Path) -> Allowlist:
    """The allowlist of the repository at ``root``; empty when its file is missing."""
    path = Path(root) / ALLOWLIST_PATH
    try:
        return parse_allowlist(path.read_text(encoding="utf-8"))
    except OSError:
        return Allowlist()


@dataclass(frozen=True)
class StaleItem:
    """One stale reference: where it is, which kind, what was written, and what is wrong."""

    page: str
    line: int
    heading: str
    kind: str                       # "path" or "name"
    token: str                      # the path or name as written
    citation_kind: Optional[str]    # "src", "files" or "text" for a path; None for a name
    detail: str                     # "missing path: TOKEN" or "unknown name: NAME"
    section_id: Optional[str] = None


def is_doubtful_path(token: str, citation_kind: str) -> bool:
    """True for a token too doubtful to report: its last part has no ``.`` and it is no folder.

    Such a token may be a branch name (``docs/oct19``). A marker's ``src`` entry is
    always meant as a path, so it is never doubtful.
    """
    if citation_kind == KIND_SRC or token.endswith("/"):
        return False
    return "." not in token.rsplit("/", 1)[-1]


def path_is_stale(token: str, citation_kind: str, allow: Allowlist) -> bool:
    """True when a citation that resolves to nothing is to be reported (see ``stale_items``)."""
    if is_doubtful_path(token, citation_kind) or allow.allows_path(token):
        return False
    return not ("/" not in token and allow.allows_file(token))


def names_repo_file(word: str, repo: RepoFiles) -> bool:
    """True when ``word`` is a file or folder at the repository's top (or under ``TextMouth/``), or a source file's name without its extension.

    A doc may write ``Scripts`` for a folder or ``PlatformTypes`` for ``PlatformTypes.swift``;
    it is then a path, not a code name, and stays valid for as long as the file does.
    """
    return word in repo.tops or any(repo.by_name(f"{word}.{ext}") for ext in sorted(SOURCE_EXTENSIONS))


def first_unknown_part(parts: List[str], called: bool, index: SwiftIndex, allow: Allowlist) -> Optional[str]:
    """The first of a name's ``parts`` that nothing declares and the allowlist does not name, or None.

    Each part that starts with a capital and holds a lowercase letter must be a type; the
    last part of a call must be a function or a type (an initializer). Other lowercase
    parts are not checked.
    """
    for position, part in enumerate(parts):
        if called and position == len(parts) - 1:
            if not (index.is_callable(part) or index.is_type(part) or allow.allows_name(part)):
                return part + "()"
        elif swiftindex.is_capitalised_word(part):
            if not (index.is_type(part) or allow.allows_name(part)):
                return part
    return None


def unknown_part(written: str, repo: RepoFiles, index: SwiftIndex, allow: Allowlist) -> Optional[str]:
    """The part of a backticked name that nothing declares, or None when every part is known.

    The name loses a leading ``.`` and a call's arguments; each part is checked by
    ``first_unknown_part``. A name that has an unknown part is still let off when it is
    a file name (``Info.plist``), a single name that is a file or folder of the
    repository (``names_repo_file``), or a whole name the allowlist knows (a bundle
    identifier, ``com.*``). The cheap check comes first: most names are known.
    """
    bare = written.split("(", 1)[0].lstrip(".")
    parts = bare.split(".")
    unknown = first_unknown_part(parts, swiftindex.is_call(written), index, allow)
    if unknown is None:
        return None
    if swiftindex.is_file_name(written) or allow.allows_name(bare):
        return None
    if len(parts) == 1 and names_repo_file(bare, repo):
        return None
    return unknown


def section_items(page: Page, section: Section, repo: RepoFiles, index: SwiftIndex,
                  allow: Allowlist) -> Iterator[StaleItem]:
    """The stale references of one section, in the order of their lines."""
    ident = section.marker.id if section.marker else None
    found: List[StaleItem] = []
    for cite in sectionrefs.section_citations(page, section, repo):
        if not cite.paths and path_is_stale(cite.token, cite.kind, allow):
            found.append(StaleItem(page.path, cite.line, section.heading, KIND_PATH, cite.token,
                                   cite.kind, f"missing path: {cite.token}", ident))
    for mention in swiftindex.mentions(sectionrefs.section_blocks(page, section)):
        unknown = unknown_part(mention.name, repo, index, allow)
        if unknown is not None:
            found.append(StaleItem(page.path, mention.line, section.heading, KIND_NAME, mention.name,
                                   None, f"unknown name: {unknown}", ident))
    # sorted is stable: a path and a name on one line keep their order.
    yield from sorted(found, key=lambda item: item.line)


def stale_items(pages: Iterable[Page], repo: RepoFiles, index: SwiftIndex, allow: Allowlist) -> List[StaleItem]:
    """Every stale reference of ``pages``, in page, section and line order."""
    items: List[StaleItem] = []
    for page in pages:
        for section in page.sections:
            items.extend(section_items(page, section, repo, index, allow))
    return items


def item_hit(item: StaleItem) -> Hit:
    """The hit that reports one stale reference."""
    return Hit(item.page, item.line, item.line, item.heading, item.detail,
               extra={"kind": item.kind, "token": item.token, "citation_kind": item.citation_kind,
                      "id": item.section_id})


def run(args: Any) -> int:
    """Report the stale references of the scope's pages, the log pages only with ``--logs``."""
    paths = docmodel.scope_pages(args.root, args.scope)
    if not args.logs:
        # The same page test the lint's rule applies (docmodel.is_log_page).
        paths = [path for path in paths if not docmodel.is_log_page(path)]
    pages = docmodel.load_pages(args.root, paths)
    repo = RepoFiles.load(args.root)
    items = stale_items(pages, repo, SwiftIndex.load(repo), load_allowlist(args.root))
    output.emit((item_hit(item) for item in items), args, noun="stale references")
    path_count = sum(1 for item in items if item.kind == KIND_PATH)
    print(f"doclib: {len(items)} stale references ({path_count} paths, {len(items) - path_count} names)",
          file=sys.stderr)
    return output.EXIT_NONE if items else output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``stale`` subcommand."""
    parser = subparsers.add_parser(
        "stale", parents=[common], help="paths and code names the docs cite that no longer exist",
        description="Report each cited path that names nothing and each backticked code name "
                    "the Swift sources do not declare, except what the allowlist names.")
    parser.add_argument("--logs", action="store_true",
                        help="include the log pages (changelog, history), which name what was removed")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
