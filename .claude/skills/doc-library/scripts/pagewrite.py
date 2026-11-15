"""Writing a page back: the one way a doc-library command changes a file.

The writing commands (``reflow``, ``mark``) read a page with ``read_page_text``,
build its new text, and hand both texts to ``rewrite``. ``rewrite`` refuses a new
text that loses, adds, or reorders a word (split-check's words, so headings,
markers, list markers, and white space may change), and otherwise replaces the
file in one step: the new text goes to a temporary file beside the page, which
``os.replace`` then puts in the page's place, so a failed write never leaves half
a page. A command adds its own stricter checks before calling it.
"""

from __future__ import annotations

import os
import stat
import tempfile
from pathlib import Path
from typing import List

import docmodel
import splitcheck
from output import UsageError


def read_page_text(root: Path, path: str) -> str:
    """The text of the page at ``root/path``, for a rewrite.

    A rewrite must keep every byte it does not mean to change, so a page that is not
    valid UTF-8, or that holds a carriage return (which the parser drops), is a
    UsageError rather than something to rewrite. The page must lie inside the root.
    """
    data = docmodel.read_page_bytes(root, path)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise UsageError(f"{path} is not UTF-8; it is left as it is") from None
    if "\r" in text:
        raise UsageError(f"{path} has carriage returns; it is left as it is")
    return text


def word_problems(old: str, new: str, path: str) -> List[str]:
    """What split-check says when ``new`` does not hold ``old``'s words in order; [] when it does."""
    difference = splitcheck.compare(splitcheck.words(old, f"OLD {path}"), splitcheck.words(new, f"NEW {path}"))
    if difference is None:
        return []
    return splitcheck.describe(difference, f"OLD {path}", f"NEW {path}")


def write_page(root: Path, path: str, text: str) -> None:
    """Replace the existing page at ``root/path`` with ``text``, in one step.

    The text is written to a temporary file in the page's own folder, given the
    page's permissions, and moved over the page with ``os.replace``. A page outside
    the root, or one that does not exist, is a UsageError.
    """
    relative = docmodel.name_inside(root, path)
    if relative is None:
        raise UsageError(f"{path} is outside the repository")
    root_real = Path(os.path.realpath(root))
    target = Path(os.path.realpath(root_real / relative))
    try:
        target.relative_to(root_real)
    except ValueError:
        raise UsageError(f"{path} is outside the repository") from None
    if not target.is_file():
        raise UsageError(f"no such page: {path}")
    mode = stat.S_IMODE(target.stat().st_mode)
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", newline="", dir=target.parent,
        prefix=f".{target.name}.", suffix=".doclib-tmp", delete=False)
    with handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(handle.name, mode)
    os.replace(handle.name, target)


def rewrite(root: Path, path: str, old: str, new: str) -> List[str]:
    """Write ``new`` over the page ``path`` when it keeps ``old``'s words; return the problems.

    An empty list means the page was written (or needed no change: ``new == old``
    writes nothing). Otherwise nothing is written, and the list holds split-check's
    lines saying where the words first differ.
    """
    if new == old:
        return []
    problems = word_problems(old, new, path)
    if not problems:
        write_page(root, path, new)
    return problems
