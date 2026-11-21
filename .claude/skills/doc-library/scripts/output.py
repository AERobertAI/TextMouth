"""Printing hits for every doc-library command.

A hit is one line of output, the same for every command:

    path:start-end  heading path  text

``path`` is the repository-relative file the hit is in, ``start-end`` the lines
(1-based, inclusive) that hold the text shown, the heading path names the section
(``-`` when there is none), and the text is cut to 200 characters, keeping the part
a search matched in view. Under ``--json`` each hit is one JSON object per line with
the same fields plus any the command adds. ``--max N`` caps the hits printed (0 for
no cap); when the cap leaves hits out, one line on standard error says how many.
"""

from __future__ import annotations

import bisect
import json
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, Optional, Tuple

# The longest text a hit prints, in characters.
TEXT_LIMIT = 200
# The cap on hits when neither --max nor the command says otherwise.
DEFAULT_MAX = 20

# Exit statuses shared by every command.
EXIT_OK = 0      # a search found something, or a check passed
EXIT_NONE = 1    # a search found nothing, or a check failed
EXIT_USAGE = 2   # the command line or a target was wrong

# The mark left where a hit's text was cut.
ELLIPSIS = "…"

_WHITESPACE = re.compile(r"\s+")


class UsageError(Exception):
    """A mistake in the command line, or a target that names nothing.

    doclib.py prints the message as one line on standard error and exits with
    EXIT_USAGE; raise it with a message that says what to type instead.
    """


@dataclass
class Hit:
    """One line of a command's output.

    ``focus`` is the span of ``text`` (start and end offsets, as from a regex
    match) that must stay visible when the text is cut; ``extra`` holds the fields
    only ``--json`` prints, such as a section's id or its whole line range.
    """

    path: str
    start: int
    end: int
    heading: str = ""
    text: str = ""
    focus: Optional[Tuple[int, int]] = None
    extra: Dict[str, Any] = field(default_factory=dict)


def collapse(text: str) -> str:
    """``text`` with every run of white space, line breaks included, made one space."""
    return _WHITESPACE.sub(" ", text).strip()


def _flatten(text: str, focus: Optional[Tuple[int, int]]) -> Tuple[str, Optional[Tuple[int, int]]]:
    """``collapse(text)``, with the focus span carried over to the collapsed text.

    Collapsing moves every offset after a run of white space, so each character
    kept remembers where it came from; a collapsed space stands for the last
    character of its run, so a span that starts at a word does not take in the
    space before it.
    """
    if focus is None:
        return collapse(text), None
    kept = []
    source = []
    for match in re.finditer(r"\S+", text):
        if kept:
            kept.append(" ")
            source.append(match.start() - 1)
        kept.append(match.group())
        source.extend(range(match.start(), match.end()))
    flat = "".join(kept)
    start = bisect.bisect_left(source, focus[0])
    end = max(start, bisect.bisect_left(source, focus[1]))
    return flat, (start, end)


def clip(text: str, focus: Optional[Tuple[int, int]] = None, limit: int = TEXT_LIMIT) -> str:
    """``text`` with white space collapsed and cut to ``limit`` characters.

    Without a focus, or with one that the start already shows, the start is kept.
    Otherwise the focus is placed a third of the way into the window (or the end
    is kept, when the focus is near it), and ``…`` marks each cut end. The result
    is never longer than ``limit``.
    """
    flat, focus = _flatten(text, focus)
    if len(flat) <= limit:
        return flat
    # The characters shown beside one ellipsis, and between two.
    one_cut = limit - 1
    room = limit - 2
    if focus is None or focus[1] <= one_cut or focus[0] <= room // 3:
        return flat[:one_cut] + ELLIPSIS
    if focus[0] >= len(flat) - one_cut:
        return ELLIPSIS + flat[len(flat) - one_cut:]
    begin = min(focus[0] - room // 3, len(flat) - room - 1)
    return ELLIPSIS + flat[begin: begin + room] + ELLIPSIS


def format_hit(hit: Hit) -> str:
    """The text form of a hit: ``path:start-end  heading  text``."""
    heading = hit.heading or "-"
    return f"{hit.path}:{hit.start}-{hit.end}  {heading}  {clip(hit.text, hit.focus)}"


def hit_object(hit: Hit) -> Dict[str, Any]:
    """The JSON form of a hit: the same fields as the text form, plus ``extra``."""
    data: Dict[str, Any] = {
        "path": hit.path,
        "start": hit.start,
        "end": hit.end,
        "heading": hit.heading,
        "text": clip(hit.text, hit.focus),
    }
    data.update(hit.extra)
    return data


def cap(args: Any) -> int:
    """The number of hits to print: ``--max``, else the command's default (0: all)."""
    chosen = getattr(args, "max", None)
    if chosen is not None:
        return chosen
    return getattr(args, "default_max", DEFAULT_MAX)


def emit(hits: Iterable[Hit], args: Any, noun: str = "hits") -> int:
    """Print hits up to the cap and return how many there were in all.

    When the cap leaves some out, one line on standard error says so, naming
    ``noun`` ("hits", "sections", ...), so standard output holds only hits.
    """
    limit = cap(args)
    as_json = getattr(args, "json", False)
    total = 0
    for hit in hits:
        total += 1
        if limit and total > limit:
            continue
        if as_json:
            print(json.dumps(hit_object(hit), ensure_ascii=False))
        else:
            print(format_hit(hit))
    if limit and total > limit:
        print(f"doclib: {limit} of {total} {noun} shown; --max 0 shows all", file=sys.stderr)
    return total
