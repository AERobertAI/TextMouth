"""git's merge driver for issue files: one ``Issues/<ID>.md`` merged three ways, part by part.

git calls it for an issue file that both sides of a merge, rebase, or cherry-pick
changed, once the repository's config defines it, which ``make issues-merge-driver``
does once for every worktree:

    git config merge.issuefile.name "an issue file, merged by its parts"
    git config merge.issuefile.driver "python3 -I -B .claude/skills/issue-library/scripts/issuelib.py merge-driver %O %A %B %L %P"

``.gitattributes`` names it for ``Issues/*.md``. git runs it from the top of the
work tree on three temporary files: the common ancestor (%O), the current side
(%A, which receives the result), and the other side (%B); %L is the length of a
conflict marker. In a merge into main, the current side is main and the other the
branch; in a rebase onto main, too. Where the config does not define the driver,
git merges the file as any text, with conflict markers.

The three parts of a file merge apart:

- The header, field by field against the base. A field one side changed takes
  that side's value, so changes to different fields both win. One field changed
  both ways is a conflict: its two lines between git's markers, inside the header.
  ``updated`` takes the later date instead, since every header change sets it.
- The description, everything from the header to ``## Comments``, as git's own
  three-way merge would (``git merge-file``), with markers on a real conflict.
- The comments. Those the base had merge one by one, an edit on one side winning
  and edits on both meeting in markers. Every comment a side added goes after
  them, whole, in date order (the current side's first on one date), and one
  both sides added alike is kept once. So two comments are never mixed, whatever
  lines they share.

A side that does not read as an issue file, or that drops or reorders comments
the base had, gets git's three-way merge of the whole file instead.
"""

from __future__ import annotations

import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import issuefile

# The labels of the two sides in conflict markers, and git's usual marker length.
CURRENT, BASE, OTHER = "current", "base", "other"
MARKER_SIZE = 7
# How long git merge-file may take, in seconds; it takes milliseconds.
GIT_TIMEOUT_SECONDS = 60
# The text encoding of issue files, kept byte for byte even where a file is not UTF-8.
ENCODING, ERRORS = "utf-8", "surrogateescape"


@dataclass
class Parts:
    """An issue file in the three parts the driver merges.

    ``description`` is the lines from the header's closing fence to ``## Comments``,
    as written; ``comments`` is each comment's (date, author, text).
    """

    fields: Dict[str, str]
    description: List[str]
    comments: List[Tuple[str, str, str]]


def split(text: str) -> Optional[Parts]:
    """``text`` in its parts, or None when it does not read as an issue file."""
    issue = issuefile.parse("merge", text)
    if issue.problems or not issue.comments_line:
        return None
    lines = text.split("\n")
    description = lines[issue.body_line - 1:issue.comments_line - 1]
    return Parts(dict(issue.fields), description, [(c.date, c.author, c.text) for c in issue.comments])


def merge_lines(base: str, current: str, other: str, size: int) -> Tuple[str, int]:
    """Three texts merged as git merges files: the result and its number of conflicts.

    A change on one side alone needs no git; otherwise ``git merge-file`` merges
    them, and when it cannot run, the two sides go whole between markers.
    """
    if current == other or other == base:
        return current, 0
    if current == base:
        return other, 0
    with tempfile.TemporaryDirectory(prefix="issuelib-merge-") as folder:
        paths = []
        for name, text in ((CURRENT, current), (BASE, base), (OTHER, other)):
            path = Path(folder) / name
            path.write_text(text, encoding=ENCODING, errors=ERRORS)
            paths.append(str(path))
        try:
            result = subprocess.run(
                ["git", "merge-file", "-p", f"--marker-size={size}", "-L", CURRENT, "-L", BASE, "-L", OTHER, *paths],
                capture_output=True, timeout=GIT_TIMEOUT_SECONDS)
        except (OSError, subprocess.SubprocessError):
            result = None
    if result is not None and 0 <= result.returncode < 128:
        return result.stdout.decode(ENCODING, ERRORS), result.returncode
    marked = (f"{'<' * size} {CURRENT}\n{with_line_end(current)}{'=' * size}\n"
              f"{with_line_end(other)}{'>' * size} {OTHER}\n")
    return marked, 1


def with_line_end(text: str) -> str:
    """``text`` ending in a line end, so a marker after it starts a line of its own."""
    return text if not text or text.endswith("\n") else text + "\n"


def as_text(lines: List[str]) -> str:
    """Lines as a text that git can merge: each with its line end."""
    return "".join(line + "\n" for line in lines)


def as_lines(text: str) -> List[str]:
    """The lines of a text that ``as_text`` made (or git merged): its last line end dropped first."""
    return (text[:-1] if text.endswith("\n") else text).split("\n") if text else []


def merge_header(base: Dict[str, str], current: Dict[str, str], other: Dict[str, str], size: int) -> Tuple[List[str], int]:
    """The merged header's lines, fences included, and how many fields conflict."""
    lines = [issuefile.FENCE]
    conflicts = 0
    for name in issuefile.FIELDS:
        old, mine, theirs = base.get(name, ""), current.get(name, ""), other.get(name, "")
        if mine == theirs or theirs == old:
            value = mine
        elif mine == old:
            value = theirs
        elif name == "updated" and issuefile.is_date(mine) and issuefile.is_date(theirs):
            value = max(mine, theirs)
        else:
            conflicts += 1
            lines += [f"{'<' * size} {CURRENT}", issuefile.field_line(name, mine), "=" * size,
                      issuefile.field_line(name, theirs), f"{'>' * size} {OTHER}"]
            continue
        lines.append(issuefile.field_line(name, value))
    lines.append(issuefile.FENCE)
    return lines, conflicts


def merge_comments(base: List[Tuple[str, str, str]], current: List[Tuple[str, str, str]],
                   other: List[Tuple[str, str, str]], size: int) -> Optional[Tuple[List[Tuple[str, str, str]], int]]:
    """The merged comments and their conflicts, or None when a side dropped or reordered the base's."""
    kept = len(base)
    for side in (current, other):
        if len(side) < kept or [(d, a) for d, a, _t in side[:kept]] != [(d, a) for d, a, _t in base]:
            return None
    merged: List[Tuple[str, str, str]] = []
    conflicts = 0
    for (date, author, old), (_d1, _a1, mine), (_d2, _a2, theirs) in zip(base, current, other):
        text, count = merge_lines(as_text(old.split("\n")), as_text(mine.split("\n")), as_text(theirs.split("\n")), size)
        merged.append((date, author, "\n".join(as_lines(text))))
        conflicts += count
    added = list(current[kept:])
    added += [comment for comment in other[kept:] if comment not in added]
    # A stable sort: on one date the current side's come first, each side's in its own order.
    added.sort(key=lambda comment: comment[0])
    return merged + added, conflicts


def render(header: List[str], description: List[str], comments: List[Tuple[str, str, str]]) -> str:
    """An issue file's text from its merged parts, each comment written as issuelib writes one."""
    lines = header + description + [issuefile.COMMENTS_HEADING]
    for date, author, text in comments:
        lines += ["", issuefile.comment_heading(date, author, text), "", *text.split("\n")]
    return "\n".join(lines) + "\n"


def merge_texts(base: str, current: str, other: str, size: int = MARKER_SIZE) -> Tuple[str, int]:
    """Three versions of an issue file merged: the result and how many conflicts it holds.

    A change on one side alone keeps that side byte for byte.
    """
    if current == other or other == base:
        return current, 0
    if current == base:
        return other, 0
    parts = [split(text) for text in (base, current, other)]
    if any(part is None for part in parts):
        return merge_lines(base, current, other, size)
    old, mine, theirs = parts
    comments = merge_comments(old.comments, mine.comments, theirs.comments, size)
    if comments is None:
        return merge_lines(base, current, other, size)
    header, header_conflicts = merge_header(old.fields, mine.fields, theirs.fields, size)
    description, description_conflicts = merge_lines(
        as_text(old.description), as_text(mine.description), as_text(theirs.description), size)
    merged_comments, comment_conflicts = comments
    text = render(header, as_lines(description), merged_comments)
    return text, header_conflicts + description_conflicts + comment_conflicts


def merge_files(base_path: str, current_path: str, other_path: str, size: int = MARKER_SIZE) -> int:
    """The driver: merge the three files into ``current_path``; 0 when clean, 1 when it holds conflicts."""
    texts = [Path(path).read_text(encoding=ENCODING, errors=ERRORS) for path in (base_path, current_path, other_path)]
    try:
        result, conflicts = merge_texts(*texts, size=size)
    except Exception:  # noqa: BLE001  (any surprise falls back to git's own merge, never to a silent "ours")
        result, conflicts = merge_lines(*texts, size=size)
    Path(current_path).write_text(result, encoding=ENCODING, errors=ERRORS)
    return 0 if conflicts == 0 else 1
