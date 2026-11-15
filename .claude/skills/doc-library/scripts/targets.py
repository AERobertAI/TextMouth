"""Naming a page or a section on the command line.

``resolve_page`` turns a page name (a path, or just its tail) into the page's
repository-relative path. ``resolve_target`` turns a section's name into the page and
the section, in one of three forms:

    docs/user/feeds.md:120        the section holding line 120
    docs/user/feeds.md#Heading    the section with that heading
    epub-headings                 the section whose marker has that id

A name that matches nothing, or too much, is a UsageError that says what was not
found and lists the closest names, so a caller can correct it without another search.
"""

from __future__ import annotations

import difflib
import os
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import docmodel
from docmodel import Page, Section
from output import UsageError

# How many candidates an error message lists.
LIST_LIMIT = 10
CLOSE_LIMIT = 5

# What a bare page name is told when a section was wanted.
SECTION_HINT = "name a section: PAGE#HEADING, PAGE:LINE, or an id (outline PAGE lists them)"

_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_EMPHASIS_UNDERSCORES = re.compile(r"(?<!\w)_+(.+?)_+(?!\w)")


def strip_markup(title: str) -> str:
    """A heading's text without inline Markdown: links keep their text, and backticks, ``*``, and emphasis ``_`` go."""
    text = _LINK.sub(r"\1", title)
    text = text.replace("`", "").replace("*", "")
    return _EMPHASIS_UNDERSCORES.sub(r"\1", text)


def plain_title(title: str) -> str:
    """``title`` as compared by name: no inline markup, lowercase, white space collapsed."""
    return " ".join(strip_markup(title).lower().split())


def github_slug(title: str) -> str:
    """GitHub's anchor for a heading.

    Backticks and ``*``/``_`` emphasis are removed, the text is lowercased, every
    character that is not a letter, digit, space, hyphen, or underscore is dropped,
    and each space becomes a hyphen.
    """
    text = strip_markup(title).lower()
    text = "".join(char for char in text if char.isalnum() or char in " -_")
    return text.replace(" ", "-")


def page_slugs(page: Page) -> Dict[str, Section]:
    """Each heading's anchor on the page; a repeated anchor gets GitHub's ``-1``, ``-2``."""
    slugs: Dict[str, Section] = {}
    for section in page.sections:
        if section.level == 0:
            continue
        base = github_slug(section.title)
        # GitHub numbers a repeat from -1, and skips a number another heading already took.
        candidate, repeat = base, 0
        while candidate in slugs:
            repeat += 1
            candidate = f"{base}-{repeat}"
        slugs[candidate] = section
    return slugs


def _close(word: str, candidates: List[str]) -> List[str]:
    """Up to five of ``candidates`` that resemble ``word``, the closest first."""
    return difflib.get_close_matches(word, candidates, n=CLOSE_LIMIT, cutoff=0.5)


def _stem(path: str) -> str:
    """A page path without its ``.md``."""
    return path[:-3] if path.endswith(".md") else path


def _named_file(root: Path, name: str) -> Optional[str]:
    """The page at ``root/name`` (or ``root/name.md``) when it is a file inside the root.

    A name whose spelling leaves the root is not looked up at all (see
    ``docmodel.name_inside``).
    """
    inside = docmodel.name_inside(root, name)
    if inside is None:
        return None
    name = inside
    root_real = Path(os.path.realpath(root))
    for candidate in ((name,) if name.endswith(".md") else (name, name + ".md")):
        target = Path(os.path.realpath(root_real / candidate))
        try:
            relative = target.relative_to(root_real)
        except ValueError:
            continue  # leads outside the repository
        if target.suffix == ".md" and target.is_file():
            return relative.as_posix()
    return None


def resolve_page(root: Path, name: str) -> str:
    """The repository-relative path of the page ``name`` stands for.

    ``name`` is a Markdown file under ``root`` (with or without ``.md``), or else the
    tail of exactly one page of the ``all`` scope: ``feeds`` finds ``docs/user/feeds.md``
    unless another page ends in ``feeds`` too, in which case ``user/feeds`` is needed.
    Several matches or none is a UsageError that lists up to ten candidates.
    """
    direct = _named_file(root, name)
    if direct:
        return direct
    wanted = _stem(name).strip("/")
    pages = docmodel.scope_pages(root, "all")
    matches = [page for page in pages if wanted and (_stem(page) == wanted or _stem(page).endswith("/" + wanted))]
    if len(matches) == 1:
        return matches[0]
    if matches:
        listed = ", ".join(matches[:LIST_LIMIT])
        raise UsageError(f"{name!r} names {len(matches)} pages; write more of the path: {listed}")
    # Nothing matched: offer pages whose whole path or last part resembles the name.
    by_tail = {_stem(page).rsplit("/", 1)[-1]: page for page in pages}
    near = [by_tail[tail] for tail in _close(wanted.rsplit("/", 1)[-1], list(by_tail))]
    stems = {_stem(page): page for page in pages}
    near += [stems[stem] for stem in _close(wanted, list(stems))]
    near = list(dict.fromkeys(near))[:CLOSE_LIMIT]
    hint = f"; did you mean {', '.join(near)}?" if near else ""
    raise UsageError(f"no page named {name!r}{hint}")


def _ambiguous(page: Page, what: str, sections: List[Section]) -> UsageError:
    """The error for a name that fits several sections: each one's heading and line."""
    listed = ", ".join(f"{page.path}:{s.start} ({s.title})" for s in sections[:LIST_LIMIT])
    return UsageError(f"{what} fits {len(sections)} sections; use PAGE:LINE: {listed}")


def _plain_path(section: Section) -> str:
    """A section's printed heading path as compared by name (see ``plain_title``)."""
    return " > ".join(plain_title(title) for title in section.path)


def _by_heading(page: Page, heading: str) -> Section:
    """The section of ``page`` that ``heading`` names.

    In turn: a title equal to it (ignoring case and inline markup); a title whose
    GitHub anchor equals its anchor; the only title it starts; the only title
    containing it. A heading holding `` > `` is matched against the end of each
    section's printed heading path instead. A tier with several sections is an
    ambiguity error rather than a guess.
    """
    sections = [s for s in page.sections if s.level > 0]
    if not heading.strip():
        raise UsageError(f"no heading after the # in a target for {page.path}; outline {page.path} lists them")
    what = f"heading {heading!r}"
    wanted = plain_title(heading)
    if " > " in heading:
        wanted = " > ".join(plain_title(part) for part in heading.split(" > "))
        tiers = [[s for s in sections
                  if _plain_path(s) == wanted or _plain_path(s).endswith(" > " + wanted)]]
    else:
        slug = github_slug(heading)
        slugs = page_slugs(page)
        tiers = [
            [s for s in sections if plain_title(s.title) == wanted],
            [slugs[slug]] if slug and slug in slugs else [],
            [s for s in sections if plain_title(s.title).startswith(wanted)],
            [s for s in sections if wanted in plain_title(s.title)],
        ]
    for tier in tiers:
        if len(tier) == 1:
            return tier[0]
        if len(tier) > 1:
            raise _ambiguous(page, what, tier)
    titles = [s.title for s in sections]
    near = _close(heading, titles)
    hint = f"; close: {', '.join(near)}" if near else ""
    raise UsageError(f"no section of {page.path} is titled {heading!r}{hint}; outline {page.path} lists them")


def _by_line(page: Page, line: int) -> Section:
    """The section of ``page`` holding ``line``."""
    if not page.sections or not 1 <= line <= len(page.lines):
        raise UsageError(f"{page.path} has no line {line} (it has {len(page.lines)})")
    return page.section_at(line)


def _by_id(root: Path, ident: str) -> Tuple[Page, Section]:
    """The one section among the lint pages whose marker id is ``ident``."""
    needle = ident.encode("utf-8")
    pages = docmodel.lint_pages(root)
    found: List[Tuple[Page, Section]] = []
    for path in pages:
        data = docmodel.read_page_bytes(root, path)
        if needle not in data:
            continue  # cheap test first: most pages never mention the id
        page = docmodel.parse_bytes(path, data)
        found += [(page, s) for s in page.sections if s.marker and s.marker.id == ident]
    if len(found) == 1:
        return found[0]
    if found:
        where = ", ".join(f"{page.path}:{s.start}" for page, s in found[:LIST_LIMIT])
        raise UsageError(f"id {ident!r} is on {len(found)} sections: {where}")
    raise _unknown_id(root, ident, pages)


def _unknown_id(root: Path, ident: str, pages: List[str]) -> UsageError:
    """The error for a target that is no id: the closest ids, or the hint for a page name."""
    # A page name was probably meant: say what a section name looks like.
    try:
        page_path = resolve_page(root, ident)
    except UsageError:
        page_path = None
    if page_path:
        return UsageError(f"{ident!r} is the page {page_path}, not a section; {SECTION_HINT}")
    known: List[str] = []
    for page in docmodel.load_pages(root, pages):
        known += [s.marker.id for s in page.sections if s.marker and s.marker.id]
    near = _close(ident, known)
    hint = f"; close: {', '.join(near)}" if near else ""
    return UsageError(f"no section has the id {ident!r}, and no page has that name{hint}")


def resolve_target(root: Path, target: str) -> Tuple[Page, Section]:
    """The page and section that ``target`` names (see the module's three forms).

    ``PAGE:LINE`` is tried first (the text after the last ``:`` is all digits and the
    page part holds no ``#``), then ``PAGE#HEADING``, then an id.
    """
    head, colon, tail = target.rpartition(":")
    if colon and tail.isascii() and tail.isdigit() and head and "#" not in head:
        page = docmodel.load_page(root, resolve_page(root, head))
        return page, _by_line(page, int(tail))
    if "#" in target:
        name, _, heading = target.partition("#")
        page = docmodel.load_page(root, resolve_page(root, name))
        return page, _by_heading(page, heading)
    return _by_id(root, target)
