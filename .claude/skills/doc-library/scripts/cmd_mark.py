"""``mark PAGE [--dry-run]``: give every heading of a page without a marker one, for an agent to fill in.

    python3 -I .claude/skills/doc-library/scripts/doclib.py mark docs/architecture/platforms.md --dry-run

``docs/agents/writing-docs.md`` asks every section to carry a marker on the line under
its heading:

    <!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->

``mark`` saves typing them. Each heading that has no marker gets one on the line
straight after it, holding a suggested ``id`` (made from the heading's words), the
``src`` that ``suggest_paths`` finds, and an empty ``keys`` for the agent to fill in.
Nothing else on the page changes: a section with a marker (a stray one too) is left
alone, and so is the text before the first heading.

The pure parts are ``suggest_id`` and ``marker_line``. The command reads the page with
``pagewrite.read_page_text``, checks that taking the added lines out gives back the old
text and that the new text parses to the ids it gave, and writes through
``pagewrite.rewrite``, which adds its own word check. Any failed check writes nothing.

Output: one hit for each added marker (the page and the marker's line in the new text,
the section's heading, the marker line), and a count on standard error. Exit status: 0
when markers were added or none were needed (``--dry-run`` too); 1 when a check failed.
"""

from __future__ import annotations

import re
from typing import List, Set

import targets
from cmd_suggest_src import Suggestion

# Words an id leaves out (while other words remain).
STOP_WORDS = frozenset({"a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "by", "its", "is"})
# The most words of a heading an id holds, and the most characters.
ID_WORDS = 5
ID_LENGTH = 40
# The most suggestions that are not from a Files: line a marker's src holds.
MOST_OTHER_PATHS = 5
# The reason ``suggest_paths`` gives a path taken from a Files: line.
_FILES_REASON = "Files: line"
# What a marker's src list cannot hold: it splits at "," and ";", and the comment ends at "-->".
_UNWRITABLE_IN_SRC = (",", ";", "-->")

# A run of lowercase letters and digits: one word of an id.
_WORD = re.compile(r"[a-z0-9]+")


# ---------------------------------------------------------------------------
# Ids and marker lines.
# ---------------------------------------------------------------------------

def _words(text: str) -> List[str]:
    """The words of ``text`` for an id: lowercase runs of letters and digits, ``&`` read as ``and``."""
    return _WORD.findall(text.lower().replace("&", " and "))


def _cut_at_hyphen(base: str, length: int) -> str:
    """``base`` cut to at most ``length`` characters, at a hyphen when it has one to cut at."""
    if len(base) <= length:
        return base
    # One character more is looked at, so a hyphen exactly at ``length`` leaves whole words.
    hyphen = base[:length + 1].rfind("-")
    return base[:hyphen] if hyphen > 0 else base[:length]


def suggest_id(title: str, page_stem: str, taken: Set[str]) -> str:
    """An id for the heading ``title`` that is not in ``taken``.

    The base is the heading's first ``ID_WORDS`` words, stop words dropped while
    other words remain, joined with hyphens and cut at a hyphen to ``ID_LENGTH``
    characters (``section`` when the title has no letter or digit). The first of
    these not in ``taken`` is the id: the base, ``PAGE_STEM-BASE``, then
    ``PAGE_STEM-BASE-2``, ``-3``, and so on. ``page_stem`` is made into the same
    shape as an id first (``page`` when it has no letter or digit).
    """
    words = _words(targets.strip_markup(title))
    kept = [word for word in words if word not in STOP_WORDS] or words
    base = _cut_at_hyphen("-".join(kept[:ID_WORDS]), ID_LENGTH) or "section"
    stem = "-".join(_words(page_stem)) or "page"
    candidate = base
    if candidate in taken:
        candidate = f"{stem}-{base}"
    number = 2
    while candidate in taken:
        candidate = f"{stem}-{base}-{number}"
        number += 1
    return candidate


def marker_line(ident: str, src: List[str]) -> str:
    """The marker for id ``ident`` with no keys and the paths ``src`` (``src:`` alone when none)."""
    paths = " " + ", ".join(src) if src else ""
    return f"<!-- id: {ident}; keys: ; src:{paths} -->"


def src_paths(suggestions: List[Suggestion]) -> List[str]:
    """The paths a new marker's ``src`` holds: every Files: line path, then at most five others.

    ``suggest_paths`` already lists the Files: paths first, and the others by how
    often the section names them; both orders are kept. A path the marker could not
    write back (one with a comma, a semicolon, or ``-->``) is left out.
    """
    writable = [s for s in suggestions if not any(bad in s.path for bad in _UNWRITABLE_IN_SRC)]
    listed = [s.path for s in writable if s.reason == _FILES_REASON]
    others = [s.path for s in writable if s.reason != _FILES_REASON]
    return listed + others[:MOST_OTHER_PATHS]
