"""The format of one issue file, ``Issues/<ID>.md``: read it, check its values, and build its new text.

An issue file is plain Markdown in three parts, made to read well in a plain editor
and on a braille display (no tables, and dates written 2026-11-16):

    ---
    id: B16
    title: A valid audio file whose sample format TextMouth can't read is called damaged
    kind: bug
    status: open
    ...
    labels: audio, import
    ---

    ## Description

    What is wrong or wanted, as long as it needs.

    ## Comments

    ### 2026-11-16, orchestrator, 1 line

    One comment: a heading with its date, author, and line count, then its text.

The header is the lines between the first two ``---`` lines: one ``name: value``
line for each name of FIELDS, in that order, with nothing after the colon for an
empty value. A value is everything after the first colon, so a title may hold
colons; the list fields hold their entries separated by commas.

Two branches that change one issue meet in git's merge, and ``.gitattributes``
gives these files a merge driver of their own (``issuemerge``): the header merges
field by field, the description as git would, and each comment whole, appended in
date order. So a comment changes no line of the header, not even ``updated``:
``updated`` is the date a header field last changed, and each comment carries its
own date. Where the driver is not defined, git merges the file as text, with
conflict markers; a field given twice, or a comment whose line count its text no
longer has, is reported by ``parse`` and ``check_comments``.

This module only reads and builds text; ``issuestore`` reads and writes the files.
"""

from __future__ import annotations

import datetime as dt
import re
import string
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import issueids

# The header's fields, in the order every file holds them.
FIELDS = (
    "id", "title", "kind", "status", "priority", "platform", "assignee",
    "created", "updated", "found-by", "branch", "merged", "reason",
    "related", "docs", "labels",
)
# The fields that may not be empty.
REQUIRED = ("id", "title", "kind", "status", "priority", "platform", "created", "updated", "found-by")
# The fields that hold a list, separated by commas.
LIST_FIELDS = ("related", "docs", "labels")

# The allowed values of the fields that have a fixed set, in the order lists and summaries use.
KINDS = ("bug", "feature", "format", "follow-up", "test", "tooling", "docs", "question")
STATUSES = ("in-progress", "blocked", "open", "done", "wontfix", "duplicate")
PRIORITIES = ("P1", "P2", "P3")
PLATFORMS = ("mac", "iphone", "both")
CHOICES = {"kind": KINDS, "status": STATUSES, "priority": PRIORITIES, "platform": PLATFORMS}

# The statuses that close an issue, and the ones a closing needs a reason for (not a merge).
CLOSED = ("done", "wontfix", "duplicate")
NEEDS_REASON = ("wontfix", "duplicate")
# The statuses an agent may set on the issue it is assigned, on its own branch.
AGENT_STATUSES = ("in-progress", "blocked")

# The header's fence, and the body's two headings.
FENCE = "---"
DESCRIPTION_HEADING = "## Description"
COMMENTS_HEADING = "## Comments"
# A comment's heading: its date, its author, and how many lines its text has
# ("### 2026-11-16, floatrender, 3 lines"). The count is a second guard of a merge:
# a comment whose lines were mixed with another's no longer has its count.
COMMENT_HEADING = re.compile(r"^### (\d{4}-\d{2}-\d{2}), ([^,]+?)(?:, (\d+) lines?)?\s*$")
# A line no comment may hold, since it would end the comment or the Comments section.
_COMMENT_BREAKER = re.compile(r"^#{1,3}(?:\s|$)")

# The shapes of the free-form values.
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# An agent's name, as the message board allows one: letters, digits, '.', '_' and '-'.
_AGENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
_HASH = re.compile(r"^[0-9a-f]{7,40}$")
_LABEL = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


class IssueFormatError(ValueError):
    """A file that cannot be changed safely, or a change that would make it invalid; the message says why."""


@dataclass
class Problem:
    """One thing wrong with an issue file: the 1-based line it is on (0: the file as a whole) and what."""

    line: int
    message: str


@dataclass
class Comment:
    """One comment: the line of its heading, its date and author, its text without the heading,
    and the line count its heading gives (None when it gives none)."""

    line: int
    date: str
    author: str
    text: str
    count: Optional[int] = None


@dataclass
class Issue:
    """An issue file as read: its header's fields, its body as written, and what is wrong with its layout.

    ``fields`` holds the first value of each field the header gives, ``field_lines``
    the line each came from, and ``body`` everything after the header's closing
    line, exactly as it was; ``comments_line`` is the line of ``## Comments`` (0
    without one), and ``text`` the whole file as read. ``problems`` names what is
    wrong with the layout (the header, the headings, the comments); the values are
    checked by ``check_values``.
    """

    path: str
    fields: Dict[str, str]
    field_lines: Dict[str, int]
    body: str
    body_line: int
    problems: List[Problem] = field(default_factory=list)
    comments: List[Comment] = field(default_factory=list)
    description: str = ""
    comments_line: int = 0
    text: str = ""

    def value(self, name: str) -> str:
        """A field's value, or "" when the header lacks it."""
        return self.fields.get(name, "")

    def values(self, name: str) -> List[str]:
        """A list field's entries, each trimmed, empty ones left out."""
        return split_list(self.value(name))

    @property
    def issue_id(self) -> str:
        """The issue's ID, as its header gives it."""
        return self.value("id")

    @property
    def closed(self) -> bool:
        """Whether its status is one that closes it."""
        return self.value("status") in CLOSED


def split_list(value: str) -> List[str]:
    """A list field's value as its entries: split at commas, each trimmed, empty ones left out."""
    return [part.strip() for part in value.split(",") if part.strip()]


def join_list(entries: List[str]) -> str:
    """A list field's value for its entries: "B12, B13"."""
    return ", ".join(entries)


def is_date(text: str) -> bool:
    """Whether ``text`` is a real date written YYYY-MM-DD."""
    if not _DATE.match(text):
        return False
    try:
        dt.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def is_agent_name(text: str) -> bool:
    """Whether ``text`` can name an agent (or a comment's author): the message board's rule."""
    return bool(_AGENT.match(text))


def is_hash(text: str) -> bool:
    """Whether ``text`` is a commit's name: 7 to 40 lowercase hexadecimal digits."""
    return bool(_HASH.match(text))


def is_label(text: str) -> bool:
    """Whether ``text`` is a label: lowercase words of letters and digits joined by hyphens."""
    return bool(_LABEL.match(text))


# ---------------------------------------------------------------------------
# Reading a file.
# ---------------------------------------------------------------------------

def _read_header(lines: List[str], issue: Issue) -> int:
    """Read the header into ``issue`` and return the index of the first body line.

    The file must open with a ``---`` line; the header runs to the next one. A
    field given twice keeps its first value and is a problem, as are a line that
    is not ``name: value`` and a name that is not a field.
    """
    if not lines or lines[0] != FENCE:
        issue.problems.append(Problem(1, "the file must open with a header: a line of three hyphens"))
        return 0
    for index in range(1, len(lines)):
        line = lines[index]
        number = index + 1
        if line == FENCE:
            return index + 1
        if ":" not in line:
            issue.problems.append(Problem(number, f"a header line must read 'name: value', not {line!r}"))
            continue
        name, value = line.split(":", 1)
        name, value = name.strip(), value.strip()
        if name not in FIELDS:
            issue.problems.append(Problem(number, f"unknown field {name!r}"))
            continue
        if name in issue.fields:
            issue.problems.append(Problem(
                number, f"field {name} given twice, here and on line {issue.field_lines[name]}"
                        " (a merge kept both sides' lines; keep the right one)"))
            continue
        issue.fields[name] = value
        issue.field_lines[name] = number
    issue.problems.append(Problem(1, "the header has no closing line of three hyphens"))
    return len(lines)


def _read_body(lines: List[str], start: int, issue: Issue) -> None:
    """Find the body's two headings and its comments, outside fenced code.

    The description is the text between ``## Description`` and ``## Comments``.
    Each comment runs from its heading to the next one or the file's end. Nothing
    but comments may follow ``## Comments``.
    """
    description_at = comments_at = -1
    fence = ""
    current: Optional[Comment] = None
    text_lines: List[str] = []

    def finish() -> None:
        """Close the comment being read, keeping its text without the blank lines around it."""
        if current is not None:
            current.text = "\n".join(text_lines).strip("\n")
            issue.comments.append(current)

    for index in range(start, len(lines)):
        line = lines[index]
        number = index + 1
        stripped = line.lstrip()
        if fence:
            if stripped.startswith(fence):
                fence = ""
        elif stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
        elif comments_at < 0 and line == DESCRIPTION_HEADING and description_at < 0:
            description_at = index
            continue
        elif comments_at < 0 and line == COMMENTS_HEADING:
            comments_at = index
            issue.comments_line = number
            if description_at < 0:
                issue.problems.append(Problem(number, f"'{COMMENTS_HEADING}' comes before '{DESCRIPTION_HEADING}'"))
            continue
        elif comments_at >= 0 and line.startswith("#"):
            heading = COMMENT_HEADING.match(line)
            if heading:
                finish()
                count = int(heading.group(3)) if heading.group(3) else None
                current = Comment(number, heading.group(1), heading.group(2).strip(), "", count)
                text_lines = []
                if not is_date(current.date):
                    issue.problems.append(Problem(number, f"comment date {current.date} is not a real date"))
                continue
            if _COMMENT_BREAKER.match(line):
                issue.problems.append(Problem(
                    number, f"after '{COMMENTS_HEADING}' a heading must be a comment's: '### YYYY-MM-DD, author'"))
        if comments_at >= 0:
            if current is None and line.strip():
                issue.problems.append(Problem(number, f"text after '{COMMENTS_HEADING}' before its first comment"))
            elif current is not None:
                text_lines.append(line)
    finish()
    if description_at < 0:
        issue.problems.append(Problem(0, f"no '{DESCRIPTION_HEADING}' heading"))
    if comments_at < 0:
        issue.problems.append(Problem(0, f"no '{COMMENTS_HEADING}' heading (an issue without comments still has it)"))
    if description_at >= 0:
        end = comments_at if comments_at > description_at else len(lines)
        issue.description = "\n".join(lines[description_at + 1:end]).strip("\n")


def parse(path: str, text: str) -> Issue:
    """Read an issue file's text; ``path`` names it in problems ("Issues/B16.md")."""
    lines = text.split("\n")
    issue = Issue(path=path, fields={}, field_lines={}, body="", body_line=1, text=text)
    start = _read_header(lines, issue)
    issue.body_line = start + 1
    issue.body = "\n".join(lines[start:])
    _read_body(lines, start, issue)
    return issue


# ---------------------------------------------------------------------------
# Checking the values.
# ---------------------------------------------------------------------------

def check_values(issue: Issue) -> List[Problem]:
    """What is wrong with the header's values, each on the line of its field.

    Every field must be present, and the required ones not empty. Each value must
    have its field's shape, ``updated`` may not come before ``created``, and the
    status rules hold: a closed issue says why (``merged`` for done, or a
    ``reason``; wontfix and duplicate need a reason), and an issue that is not
    closed has neither. Whether ``related`` and ``docs`` name something real, and
    whether the ID is unique, is the store's to check: it needs the other files.
    """
    found: List[Problem] = []

    def say(name: str, message: str) -> None:
        """Record a problem on the line of field ``name`` (line 1 when the field is missing)."""
        found.append(Problem(issue.field_lines.get(name, 1), message))

    for name in FIELDS:
        if name not in issue.fields:
            say(name, f"missing field {name}")
    for name in REQUIRED:
        if name in issue.fields and not issue.fields[name]:
            say(name, f"field {name} is empty")
    for name, choices in CHOICES.items():
        value = issue.value(name)
        if value and value not in choices:
            say(name, f"{name} {value!r} is not one of {', '.join(choices)}")
    issue_id = issue.value("id")
    if issue_id and not issueids.is_issue_id(issue_id):
        say("id", f"id {issue_id!r} is not an ID: capitals, digits, and hyphens, with a digit or a hyphen")
    for name in ("created", "updated"):
        value = issue.value(name)
        if value and not is_date(value):
            say(name, f"{name} {value!r} is not a date written YYYY-MM-DD")
    created, updated = issue.value("created"), issue.value("updated")
    if is_date(created) and is_date(updated) and updated < created:
        say("updated", f"updated {updated} comes before created {created}")
    if issue.value("assignee") and not is_agent_name(issue.value("assignee")):
        say("assignee", f"assignee {issue.value('assignee')!r} is not an agent's name")
    if issue.value("branch") and not _BRANCH.match(issue.value("branch")):
        say("branch", f"branch {issue.value('branch')!r} is not a branch name")
    if issue.value("merged") and not is_hash(issue.value("merged")):
        say("merged", f"merged {issue.value('merged')!r} is not a commit: 7 to 40 lowercase hexadecimal digits")
    for entry in issue.values("related"):
        if not issueids.is_issue_id(entry):
            say("related", f"related {entry!r} is not an ID")
        elif entry == issue_id:
            say("related", f"related names the issue itself, {entry}")
    for entry in issue.values("labels"):
        if not is_label(entry):
            say("labels", f"label {entry!r} is not lowercase words joined by hyphens")
    found.extend(_status_problems(issue))
    return found


def line_count(text: str) -> int:
    """How many lines a comment's text has, from its first line with text to its last."""
    return len(text.split("\n")) if text else 0


def comment_heading(date: str, author: str, text: str) -> str:
    """A comment's heading: "### 2026-11-16, floatrender, 3 lines" (1 line, for one)."""
    count = line_count(text)
    return f"### {date}, {author}, {count} {'line' if count == 1 else 'lines'}"


def check_comments(issue: Issue) -> List[Problem]:
    """What is wrong with the comments: one with no text, and a heading whose line count is missing or wrong."""
    found: List[Problem] = []
    for comment in issue.comments:
        actual = line_count(comment.text)
        if not actual:
            found.append(Problem(comment.line, f"the comment of {comment.date} by {comment.author} has no text"))
        elif comment.count is None:
            found.append(Problem(comment.line, f"the heading gives no line count: "
                                               f"'{comment_heading(comment.date, comment.author, comment.text)}'"))
        elif comment.count != actual:
            found.append(Problem(comment.line, f"the heading says {comment.count} lines, and the comment has {actual}"
                                               " (lines of two comments mixed in a merge, or an edit that left the count)"))
    return found


def _status_problems(issue: Issue) -> List[Problem]:
    """The status rules: what a closed issue must say, and what an open one must not hold."""
    status = issue.value("status")
    line = issue.field_lines.get("status", 1)
    merged, reason = issue.value("merged"), issue.value("reason")
    if status in NEEDS_REASON and not reason:
        return [Problem(line, f"a {status} issue needs a reason")]
    if status == "done" and not (merged or reason):
        return [Problem(line, "a done issue needs merged (the merge commit) or a reason")]
    if status and status not in CLOSED and (merged or reason):
        held = "merged" if merged else "reason"
        return [Problem(line, f"an issue that is {status} holds {held}; reopen clears it")]
    return []


# ---------------------------------------------------------------------------
# Building new text.
# ---------------------------------------------------------------------------

def field_line(name: str, value: str) -> str:
    """One header line: "name: value", or "name:" for an empty value."""
    return f"{name}: {value}" if value else f"{name}:"


def header_text(fields: Dict[str, str]) -> str:
    """The header for ``fields``: every field of FIELDS in order, between the two fences."""
    lines = [FENCE] + [field_line(name, fields.get(name, "")) for name in FIELDS] + [FENCE]
    return "\n".join(lines) + "\n"


def _require_sound(issue: Issue) -> None:
    """Refuse to rewrite a file whose layout is broken, since rewriting could lose what it holds."""
    if issue.problems:
        first = issue.problems[0]
        raise IssueFormatError(f"{issue.path}:{first.line}: {first.message}; fix the file by hand first "
                               "(issuelib check lists every problem)")


def with_fields(issue: Issue, changes: Dict[str, str]) -> str:
    """The file's text with ``changes`` made to its header, the body kept exactly as it was.

    Raises IssueFormatError when the file's layout is broken or when the changed
    values would not pass ``check_values``.
    """
    _require_sound(issue)
    fields = dict(issue.fields)
    fields.update(changes)
    text = header_text(fields) + issue.body
    changed = parse(issue.path, text)
    problems = check_values(changed)
    if problems:
        raise IssueFormatError(f"{issue.path}: {problems[0].message}")
    return text


def check_comment_text(text: str) -> str:
    """A comment's text, trimmed, or IssueFormatError when it is empty or holds a heading of level 1 to 3."""
    trimmed = text.strip("\n").rstrip()
    if not trimmed.strip():
        raise IssueFormatError("a comment needs some text")
    for line in trimmed.split("\n"):
        if _COMMENT_BREAKER.match(line):
            raise IssueFormatError(f"a comment may not hold a heading of level 1 to 3 ({line!r}); use #### or plain text")
    return trimmed


def with_comment(issue: Issue, date: str, author: str, text: str) -> str:
    """The file's text with one comment added at its end, and nothing else changed.

    The comment is a blank line, its heading, a blank line, and its text, added to
    the file's text as it was read: no line before it changes, the header's
    spacing included, and the merge driver finds it whole.
    """
    _require_sound(issue)
    if not is_date(date):
        raise IssueFormatError(f"comment date {date!r} is not a date written YYYY-MM-DD")
    if not is_agent_name(author):
        raise IssueFormatError(f"comment author {author!r} is not a name: letters, digits, '.', '_', '-'")
    original = issue.text if issue.text.endswith("\n") else issue.text + "\n"
    trimmed = check_comment_text(text)
    return original + f"\n{comment_heading(date, author, trimmed)}\n\n{trimmed}\n"


def fill_template(template: str, path: str, values: Dict[str, str]) -> str:
    """A new issue's text: ``template`` with its ``$name`` places filled, read back and checked.

    Raises IssueFormatError when a value would break a line of the header or the
    result does not pass ``parse`` and ``check_values``.
    """
    for name, value in values.items():
        if name != "description" and "\n" in value:
            raise IssueFormatError(f"{name} must be one line")
    try:
        text = string.Template(template).substitute(values)
    except (KeyError, ValueError) as error:
        raise IssueFormatError(f"the template has a place this command does not fill: {error}") from None
    issue = parse(path, text)
    problems = issue.problems + check_values(issue)
    if problems:
        raise IssueFormatError(f"{path}: {problems[0].message}")
    # Written back through header_text, so the first change to the file moves no line.
    return header_text(issue.fields) + issue.body
