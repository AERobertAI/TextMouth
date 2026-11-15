"""What a section cites: the repository paths and the code names its prose mentions.

The model hands over a section's prose blocks as ``(first_line, text)``: the
block's raw lines joined with ``\\n`` (list markers and indentation included), with
code blocks, front matter, and the marker line left out. Every function here is
pure; whether a cited path exists is decided by a ``RepoFiles``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Set, Tuple

from repofiles import APP_FOLDER, RepoFiles
# The one scanner of backtick runs, shared with the sentence splitter.
from sentences import code_spans

__all__ = [
    "FILES_LINE", "IDENTIFIER", "KIND_SRC", "KIND_FILES", "KIND_TEXT", "Citation", "code_spans",
    "line_of", "path_tokens", "files_block_paths", "citations", "identifier_positions",
    "identifier_spans", "is_top_folder", "names_path",
]

# A block that starts, after optional indentation and an optional list marker,
# with ``Files:`` (or the bold ``**Files:**``).
FILES_LINE = re.compile(r"[ \t]*(?:[-*+][ \t]+)?(?:\*\*Files:?\*\*:?|Files:)")

# The shape of a backticked Swift name: ``Book``, ``Book.Storage``, ``startLibrary()``,
# ``NSHostingController.sizeThatFits(in:)``, ``.terminateCancel``.
IDENTIFIER = re.compile(r"\A\.?[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*(?:\([^\s()]*\))?\Z")

# What a written path may be wrapped in: stripped from a token's front and end.
_LEADING_WRAPPERS = "([{\"'"
_TRAILING_WRAPPERS = ".,;:)]}\"'"

# The kinds of citation.
KIND_SRC = "src"
KIND_FILES = "files"
KIND_TEXT = "text"


@dataclass(frozen=True)
class Citation:
    """One path a section cites, and what it names.

    ``token`` is the path as written, ``kind`` where it was written (``src``: the
    marker; ``files``: a ``Files:`` list; ``text``: backticks in prose), ``line`` the
    line it is on, and ``paths`` what ``RepoFiles.resolve`` gives, empty when it
    names nothing that exists.
    """

    token: str
    kind: str
    line: int
    paths: Tuple[str, ...]


def path_tokens(text: str) -> List[Tuple[int, str]]:
    """The tokens of ``text`` that might be paths, as ``(offset, token)``.

    ``text`` is split at white space and commas, and each piece loses the wrappers
    ``([{"'`` from its front and ``.,;:)]}"'`` from its end. Nothing is judged here:
    ``RepoFiles.is_repo_path`` does that.
    """
    tokens: List[Tuple[int, str]] = []
    for match in re.finditer(r"[^\s,]+", text):
        piece = match.group()
        stripped = piece.lstrip(_LEADING_WRAPPERS)
        offset = match.start() + (len(piece) - len(stripped))
        stripped = stripped.rstrip(_TRAILING_WRAPPERS)
        if stripped:
            tokens.append((offset, stripped))
    return tokens


def files_block_paths(text: str) -> Optional[List[Tuple[int, str]]]:
    """The path tokens, with offsets, of a ``Files:`` block; ``None`` for any other block.

    The list is everything after ``Files:``, continuation lines included.
    """
    match = FILES_LINE.match(text)
    if match is None:
        return None
    return [(match.end() + offset, token) for offset, token in path_tokens(text[match.end():])]


def line_of(first_line: int, text: str, offset: int) -> int:
    """The line of the character at ``offset`` in a block that starts on ``first_line``."""
    return first_line + text.count("\n", 0, offset)


def _span_content_offset(text: str, start: int, end: int, content: str) -> int:
    """Where a code span's ``content`` starts in ``text``, given the span's ``start`` and ``end``.

    ``code_spans`` strips one space from each side of the content when both are
    there; the content is then two characters shorter than what lies between the
    backtick runs.
    """
    run = 0
    while text[start + run] == "`":
        run += 1
    inner = end - start - 2 * run
    return start + run + (1 if len(content) == inner - 2 else 0)


def _add(found: List[Citation], seen: Set[Tuple[str, str]], repo: RepoFiles, token: str, kind: str, line: int) -> None:
    """Append a citation of ``token`` unless one of this kind already has that token."""
    if (kind, token) in seen:
        return
    seen.add((kind, token))
    found.append(Citation(token, kind, line, tuple(repo.resolve(token))))


def citations(
    blocks: Iterable[Tuple[int, str]],
    marker_src: Sequence[str],
    marker_line: Optional[int],
    repo: RepoFiles,
) -> List[Citation]:
    """The paths a section cites, in this order.

    1. The marker's ``src`` entries, every one (a bad entry is reported later), on
       ``marker_line``.
    2. The tokens of each ``Files:`` block that look like repository paths.
    3. The tokens inside inline code spans of every other block that look like
       repository paths.

    A token appears once for each kind, at the first place it is written.
    """
    blocks = list(blocks)
    found: List[Citation] = []
    seen: Set[Tuple[str, str]] = set()
    for entry in marker_src:
        _add(found, seen, repo, entry, KIND_SRC, marker_line or 0)
    # The Files: blocks, then the rest, each in the order given.
    for first_line, text in blocks:
        listed = files_block_paths(text)
        if listed is None:
            continue
        for offset, token in listed:
            if repo.is_repo_path(token):
                _add(found, seen, repo, token, KIND_FILES, line_of(first_line, text, offset))
    for first_line, text in blocks:
        if FILES_LINE.match(text):
            continue
        for start, end, content in code_spans(text):
            base = _span_content_offset(text, start, end, content)
            for offset, token in path_tokens(content):
                if repo.is_repo_path(token):
                    _add(found, seen, repo, token, KIND_TEXT, line_of(first_line, text, base + offset))
    return found


def identifier_positions(blocks: Iterable[Tuple[int, str]]) -> List[Tuple[int, int, int, str]]:
    """Each code span that is a Swift name, outside ``Files:`` blocks, as ``(block, offset, line, content)``.

    ``block`` is the index of the block in ``blocks``, ``offset`` where the span's
    opening backtick is in that block's text, ``line`` the line it is on, and
    ``content`` the name. The offset lets a caller merge these with words it finds
    itself in the same text, in the order they are written.
    """
    found: List[Tuple[int, int, int, str]] = []
    for number, (first_line, text) in enumerate(blocks):
        if FILES_LINE.match(text):
            continue
        for start, _, content in code_spans(text):
            if IDENTIFIER.match(content):
                found.append((number, start, line_of(first_line, text, start), content))
    return found


def identifier_spans(blocks: Iterable[Tuple[int, str]]) -> List[Tuple[int, str]]:
    """The ``(line, content)`` of each code span that is a Swift name, outside ``Files:`` blocks.

    Whether a name is defined anywhere is for a later check to decide.
    """
    return [(line, content) for _, _, line, content in identifier_positions(blocks)]


def is_top_folder(path: str) -> bool:
    """Whether ``path`` is a folder at the repository's top, such as ``TextMouth/`` or ``docs/``.

    A page that names such a folder is speaking of the folder, not of each of its
    files: ``docs/developer/testing.md`` names ``TextMouth/``, which would otherwise
    make it cite every one of the app's files.
    """
    return path.endswith("/") and path.count("/") == 1


def names_path(citation: Citation, target: str, written: str) -> bool:
    """Whether ``citation`` names ``target``, a file or a folder (ending in ``/``).

    ``written`` is the path as the caller wrote it (``where``'s NAME, or the changed
    file's path), for a citation that resolves to nothing. A citation names the
    target when the target is among its paths, one of its paths is a folder holding
    the target (unless it is a top folder, see ``is_top_folder``), or the target is
    a folder holding one of its paths. A citation that resolves to nothing (a file
    since removed) names it when its token, or ``TextMouth/`` plus its token, is the
    target or ``written``.
    """
    for path in citation.paths:
        if path == target or RepoFiles.covers(target, path):
            return True
        if RepoFiles.covers(path, target) and not is_top_folder(path):
            return True
    if citation.paths:
        return False
    # Docs may leave out the ``TextMouth/`` prefix of an app source path.
    spellings = (citation.token, f"{APP_FOLDER}/{citation.token}")
    return target in spellings or written in spellings
