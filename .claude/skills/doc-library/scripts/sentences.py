"""Splitting a paragraph into sentences, and finding the spans no sentence may end inside.

Both functions are pure and work on one block of prose (a paragraph or a list
item, possibly several lines joined with ``\\n``). Offsets are character offsets
into that text. The rule everywhere is: when in doubt, don't split, because a
missed split only leaves two sentences on one line, while a wrong split breaks one
sentence in two.

``code_spans`` lives here, not in ``citations``, because the sentence splitter and
the citation finder must agree on what an inline code span is.
"""

from __future__ import annotations

import bisect
import re
from functools import lru_cache
from typing import List, Tuple

# Words (compared case-insensitively, without their final period) after which a
# period does not end a sentence.
ABBREVIATIONS = frozenset({
    "e.g", "i.e", "etc", "vs", "cf", "a.m", "p.m", "mr", "mrs", "ms", "dr", "st",
    "jr", "sr", "fig", "vol", "approx", "incl", "esp", "u.s", "u.k", "inc", "ltd",
    "ch", "sec", "pp",
})

# Characters that may follow a terminator and still belong to its sentence.
CLOSERS = ")]\"'”’*_"
# Characters, besides uppercase letters and digits, that may start a sentence.
OPENERS = "`\"'“‘([*_"
# Characters a bare URL does not end with: a sentence's own punctuation.
URL_TRAILING = ".,;:!?)]'\""

_TERMINATOR = re.compile(r"[.!?]")
_BACKTICK_RUN = re.compile(r"`+")
# A terminator, its closers, and white space: all a sentence's end needs before the checks
# of ``_sentence_end_at``; a text with none of these has a single sentence.
_POSSIBLE_END = re.compile("[.!?][" + re.escape(CLOSERS) + r"]*\s")
_BARE_URL = re.compile(r"https?://\S+")
_AUTOLINK = re.compile(r"<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*>")
# A word of single capital letters separated by periods ("J", "J.R"): initials.
_INITIALS = re.compile(r"[A-Z](?:\.[A-Z])*")

# A half-open span of offsets into a text.
Span = Tuple[int, int]


# How many blocks' spans stay cached: the citation finder and the name finder scan each
# block of a section twice, and the cache lets the second scan cost nothing.
_CODE_SPAN_CACHE = 4096


@lru_cache(maxsize=_CODE_SPAN_CACHE)
def code_spans(text: str) -> List[Tuple[int, int, str]]:
    """The inline code spans of ``text`` as ``(start, end, content)``.

    The result is cached for equal texts, so a caller must not change the list.

    A span is a run of N backticks up to the next run of exactly N backticks (the
    CommonMark rule); it may cross a line break. A run with no matching closer is
    plain text and starts no span. The content has its line breaks turned into
    spaces, and one leading and one trailing space removed when both are there.
    """
    # No backtick, no span: the commonest case, settled before any pattern runs.
    if "`" not in text:
        return []
    runs = [match.span() for match in _BACKTICK_RUN.finditer(text)]
    spans: List[Tuple[int, int, str]] = []
    index = 0
    while index < len(runs):
        start, open_end = runs[index]
        width = open_end - start
        # The first later run of the same width closes this one.
        closer = next((j for j in range(index + 1, len(runs)) if runs[j][1] - runs[j][0] == width), None)
        if closer is None:
            index += 1
            continue
        close_start, end = runs[closer]
        content = text[open_end:close_start].replace("\n", " ")
        if len(content) >= 2 and content[0] == " " and content[-1] == " ":
            content = content[1:-1]
        spans.append((start, end, content))
        # Runs inside the span are its content; resume after its closer.
        index = closer + 1
    return spans


def _inside(position: int, spans: List[Span]) -> bool:
    """True when ``position`` lies inside one of ``spans`` (``[start, end)``).

    ``spans`` must be sorted and must not overlap, as code spans and the merged
    protected spans are, so the one span that could hold ``position`` is the last
    one starting at or before it.
    """
    index = bisect.bisect_right(spans, (position, float("inf"))) - 1
    return index >= 0 and spans[index][0] <= position < spans[index][1]


def _link_destinations(text: str, code: List[Span]) -> List[Span]:
    """The ``](`` ... ``)`` spans of links and images, counting nested parentheses.

    A ``](`` inside an inline code span is not a link. A destination that is never
    closed protects nothing.
    """
    spans: List[Span] = []
    for match in re.finditer(r"\]\(", text):
        start = match.start()
        if _inside(start, code):
            continue
        depth = 1
        position = match.end()
        while position < len(text):
            char = text[position]
            if char == "\\":
                position += 1  # an escaped character never counts
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    spans.append((start, position + 1))
                    break
            position += 1
    return spans


def link_destinations(text: str) -> List[Span]:
    """The ``](`` ... ``)`` spans of the links and images in ``text``, outside inline code.

    The sentence splitter protects these spans; the lint reads each link's
    destination out of them, so both see the same links.
    """
    return _link_destinations(text, [(start, end) for start, end, _ in code_spans(text)])


def _bare_urls(text: str, code: List[Span]) -> List[Span]:
    """Bare ``http(s)://`` URLs, without the punctuation that ends a sentence."""
    spans: List[Span] = []
    for match in _BARE_URL.finditer(text):
        if _inside(match.start(), code):
            continue
        end = match.end()
        # Give back the trailing punctuation, so a URL at a sentence's end still ends it.
        while end > match.start() and text[end - 1] in URL_TRAILING:
            end -= 1
        spans.append((match.start(), end))
    return spans


def _markup_spans(text: str, code: List[Span]) -> List[Span]:
    """Autolinks (``<scheme:...>``) and HTML comments, outside inline code."""
    spans: List[Span] = []
    for match in _AUTOLINK.finditer(text):
        if not _inside(match.start(), code):
            spans.append(match.span())
    position = text.find("<!--")
    while position != -1:
        close = text.find("-->", position + 4)
        if close == -1:
            break
        if not _inside(position, code):
            spans.append((position, close + 3))
        position = text.find("<!--", close + 3)
    return spans


def protected_spans(text: str) -> List[Span]:
    """The ``[start, end)`` spans of ``text`` that no sentence may end inside.

    Inline code, link and image destinations, autolinks, HTML comments, and bare
    URLs. The result is sorted, and overlapping spans are merged into one.
    """
    code = [(start, end) for start, end, _ in code_spans(text)]
    spans = code + _link_destinations(text, code) + _bare_urls(text, code) + _markup_spans(text, code)
    merged: List[Span] = []
    for start, end in sorted(spans):
        if merged and start < merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _word_before(text: str, position: int) -> Tuple[str, int]:
    """The run of letters and periods ending just before ``position``, and where it starts.

    Leading periods are dropped, so ``..etc`` gives ``etc``.
    """
    start = position
    while start > 0 and (text[start - 1].isalpha() or text[start - 1] == "."):
        start -= 1
    word = text[start:position]
    stripped = word.lstrip(".")
    return stripped, start + (len(word) - len(stripped))


def _is_initial(text: str, word: str, word_start: int) -> bool:
    """True when ``word`` is initials ("J", "J.R") standing where a name's initials do.

    The word must be preceded by white space or the text's start, so the ``F`` of
    ``Command-F.`` is not an initial.
    """
    if not _INITIALS.fullmatch(word):
        return False
    return word_start == 0 or text[word_start - 1].isspace()


def _sentence_end_at(text: str, index: int, protected: List[Span]) -> int:
    """Where a sentence ends if the character at ``index`` ends it, else -1.

    The sentence ends after the terminator and its closers when: the terminator is
    ``.``, ``!`` or ``?``, outside every protected span, and not part of an
    ellipsis; closers and then white space follow; the next character opens a
    sentence (uppercase, a digit, or an opening mark); and for a period, the word
    it ends is neither an abbreviation nor a name's initials.
    """
    char = text[index]
    if char not in ".!?" or _inside(index, protected):
        return -1
    # A run of two or more periods is an ellipsis.
    if char == "." and (text[index - 1: index] == "." or text[index + 1: index + 2] == "."):
        return -1
    end = index + 1
    while end < len(text) and text[end] in CLOSERS:
        end += 1
    has_closers = end > index + 1
    # White space must follow, and then the start of a new sentence.
    if end >= len(text) or not text[end].isspace():
        return -1
    after = _first_nonspace(text, end)
    if after >= len(text):
        return -1
    opener = text[after]
    if not (opener.isupper() or opener.isdigit() or opener in OPENERS):
        return -1
    if char == ".":
        word, word_start = _word_before(text, index)
        if word.lower() in ABBREVIATIONS:
            return -1
        # "J. R. Tolkien": initials followed at once by white space do not end a
        # sentence. A closer ("(See X.) Next") shows the period closes one.
        if not has_closers and _is_initial(text, word, word_start):
            return -1
    return end


def _first_nonspace(text: str, start: int) -> int:
    """The offset of the first non-space character at or after ``start``."""
    while start < len(text) and text[start].isspace():
        start += 1
    return start


def split_sentences(text: str) -> List[Span]:
    """The sentences of ``text`` as ``[start, end)`` spans, in order.

    Each span starts and ends on a non-space character, spans never overlap, and
    every non-space character of ``text`` is inside exactly one span.
    """
    spans: List[Span] = []
    start = 0
    # Most lines hold no terminator that could end a sentence; one search settles that,
    # before the protected spans (the costly part) are found.
    possible = _POSSIBLE_END.search(text) is not None
    protected = protected_spans(text) if possible else []
    # Only a terminator can end a sentence, so visit those alone: a Python call
    # per character cost a fifth of a second over the docs.
    for match in (_TERMINATOR.finditer(text) if possible else ()):
        index = match.start()
        if index < start:
            continue  # among the closers of the sentence just ended
        end = _sentence_end_at(text, index, protected)
        if end == -1:
            continue
        spans.append((_first_nonspace(text, start), end))
        start = end
    # The last sentence runs to the last non-space character.
    first = _first_nonspace(text, start)
    last = len(text.rstrip())
    if first < last:
        spans.append((first, last))
    return spans
