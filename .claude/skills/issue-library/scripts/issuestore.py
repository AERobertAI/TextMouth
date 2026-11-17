"""The issues of one checkout: read them, check them all, and make each change the rules allow.

``Store(root)`` stands for the repository or worktree at ``root``: its ``Issues/``
folder, its TODO, its docs, and git's view of it. Each change is a function that
returns a ``Change``, the file to write and its new text, without writing it, so a
caller such as ``record-merge.py`` can check every change before it writes any.

Who may change what (AGENTS.md's merge flow, which this enforces where git can tell
the branch):

- On ``main``, the orchestrator files, assigns, closes, and reopens issues, and may
  change any field.
- On any other branch, an agent may only add comments to the issue assigned to it
  and set its status to in-progress or blocked. Filing on a branch is refused, since
  two branches would both take the same next ID.
- Outside git, as in a test's folder or a copy, no rule applies.

``import-todo`` is the one-time move of the TODO's open items and runs anywhere.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

import issueids
import issuefile
from issuefile import Issue, IssueFormatError, Problem

# The folder of issue files in the repository's top folder, and the one file in it that is not an issue.
ISSUES_DIR = "Issues"
README_NAME = "README.md"
# The template ``new`` fills, beside the scripts folder.
TEMPLATE = Path(__file__).resolve().parent.parent / "template.md"
# The doc-library skill's scripts, whose docmodel reads the docs' section markers.
DOCLIB_SCRIPTS = Path(__file__).resolve().parents[2] / "doc-library" / "scripts"

# The orchestrator's name, and the branch its changes belong on.
ORCHESTRATOR = "orchestrator"
MAIN_BRANCH = "main"
# Stands for today's date (YYYY-MM-DD) when set; the tests set it so their files are fixed.
TODAY_ENV = "ISSUELIB_TODAY"
# How long one git command may take, in seconds: a log of the TODO's history takes under one.
GIT_TIMEOUT_SECONDS = 60
# The variables that would point git at another repository than the one it is run in.
_GIT_LOCATION_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX")


class UsageError(Exception):
    """A command line that names nothing or gives a bad value; the message says what to type instead."""


class Refused(Exception):
    """A change the rules do not allow, or one that would make a file invalid; the message says why."""


@dataclass
class Change:
    """One file to write: where, its whole new text, and the sentence that says what changed."""

    path: Path
    text: str
    message: str
    unchanged: bool = False


@dataclass
class DocSection:
    """A section of the docs that has a marker: its place, heading path, own title, id, and the status and issues it cites."""

    path: str
    start: int
    end: int
    heading: str
    section_id: str
    title: str = ""
    status: Optional[str] = None
    issues: List[str] = field(default_factory=list)


def plural(count: int, noun: str) -> str:
    """``noun`` for one, ``noun`` with an s for any other count: "1 line", "2 lines"."""
    return noun if count == 1 else noun + "s"


def and_list(parts: List[str]) -> str:
    """Parts joined as a sentence lists them: "5", "5 and 6", "5, 6, and 9"."""
    if len(parts) < 3:
        return " and ".join(parts)
    return ", ".join(parts[:-1]) + ", and " + parts[-1]


def _git_environment() -> Dict[str, str]:
    """This process's environment, less the variables that would redirect git elsewhere."""
    return {name: value for name, value in os.environ.items() if name not in _GIT_LOCATION_VARIABLES}


class Store:
    """The issue files, TODO, docs, and git of the checkout at ``root``; ``todo`` names another TODO."""

    def __init__(self, root: Path, todo: Optional[Path] = None) -> None:
        """The checkout at ``root``; ``todo`` names a TODO elsewhere (a copy, or a test's), read in place of the root's."""
        self.root = Path(root)
        self.issues_dir = self.root / ISSUES_DIR
        self.todo_path = Path(todo) if todo is not None else self.root / issueids.TODO_NAME
        self._todo_items: Optional[List[issueids.TodoItem]] = None
        self._doc_sections: Optional[List[DocSection]] = None
        self._top: Optional[bool] = None

    # -- Files ---------------------------------------------------------------

    def relative(self, path: Path) -> str:
        """``path`` as the commands print it: from the root, with forward slashes."""
        try:
            return path.relative_to(self.root).as_posix()
        except ValueError:
            return str(path)

    def issue_files(self) -> List[Path]:
        """Every Markdown file of ``Issues/`` but its README, sorted by ID as a reader expects."""
        if not self.issues_dir.is_dir():
            return []
        files = [path for path in self.issues_dir.glob("*.md") if path.name != README_NAME and path.is_file()]
        return sorted(files, key=lambda path: issueids.sort_key(path.stem))

    def path_of(self, issue_id: str) -> Path:
        """Where the issue file of ``issue_id`` is, or would be; UsageError for a name that is no ID.

        Refusing every other name keeps a path such as ``../x`` from leading out of ``Issues/``.
        """
        if not issueids.is_issue_id(issue_id):
            raise UsageError(f"{issue_id!r} is not an ID: capitals, digits, and hyphens, with a digit or a hyphen")
        return self.issues_dir / f"{issue_id}.md"

    def read(self, path: Path) -> Issue:
        """Read and parse one issue file."""
        return issuefile.parse(self.relative(path), path.read_text(encoding="utf-8"))

    def load(self, issue_id: str) -> Issue:
        """The issue ``issue_id``; UsageError when it has no file, naming the TODO item or alias it may be."""
        path = self.path_of(issue_id)
        if not path.is_file():
            raise UsageError(f"{issue_id} has no file in {ISSUES_DIR}/{self.whereabouts(issue_id)}")
        return self.read(path)

    def load_all(self) -> List[Issue]:
        """Every issue file, read."""
        return [self.read(path) for path in self.issue_files()]

    def whereabouts(self, issue_id: str) -> str:
        """A clause saying where else ``issue_id`` is named: an alias, or the TODO's lines; "" when nowhere."""
        aliases = self.aliases()
        if issue_id in aliases:
            return f"; it is an alias of {aliases[issue_id]} in {self.todo_path.name}"
        lines = [str(item.line) for item in self.todo_items() if issue_id in item.ids]
        if lines:
            return f"; {self.todo_path.name} names it on {plural(len(lines), 'line')} {and_list(lines)}"
        return ""

    def today(self) -> str:
        """Today's date, YYYY-MM-DD, from the clock or from ISSUELIB_TODAY."""
        value = os.environ.get(TODAY_ENV, "")
        if value:
            if not issuefile.is_date(value):
                raise UsageError(f"{TODAY_ENV}={value!r} is not a date written YYYY-MM-DD")
            return value
        return dt.date.today().isoformat()

    def template(self) -> str:
        """The text of the template a new issue is made from."""
        return TEMPLATE.read_text(encoding="utf-8")

    # -- The TODO --------------------------------------------------------------

    def todo_text(self) -> str:
        """The TODO's text, or "" when the checkout has none."""
        if not self.todo_path.is_file():
            return ""
        return self.todo_path.read_text(encoding="utf-8")

    def todo_items(self) -> List[issueids.TodoItem]:
        """The TODO's items that open with IDs, and its pointer lines, read once."""
        if self._todo_items is None:
            self._todo_items = issueids.scan_todo(self.todo_text())
        return self._todo_items

    def aliases(self) -> Dict[str, str]:
        """Every alias the TODO gives, mapped to the ID it renames."""
        return issueids.todo_aliases(self.todo_items())

    def known_ids(self) -> Set[str]:
        """Every ID something can cite today: the issue files', the TODO's, and the aliases."""
        found = {path.stem for path in self.issue_files()}
        found.update(issueids.todo_ids(self.todo_items()))
        return found

    # -- git -------------------------------------------------------------------

    def _git(self, *args: str) -> Optional[str]:
        """Run one git command in the root; its output, or None when git fails or cannot run."""
        try:
            result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True,
                                    encoding="utf-8", errors="replace", timeout=GIT_TIMEOUT_SECONDS,
                                    env=_git_environment())
        except (OSError, subprocess.SubprocessError):
            return None
        return result.stdout if result.returncode == 0 else None

    def in_git(self) -> bool:
        """Whether the root is the top of a git work tree (a folder inside one, such as a copy, is not)."""
        if self._top is None:
            top = self._git("rev-parse", "--show-toplevel")
            self._top = bool(top) and Path(top.strip()).resolve() == self.root.resolve()
        return self._top

    def branch(self) -> Optional[str]:
        """The branch checked out at the root, "(no branch)" when HEAD is detached, or None outside git."""
        if not self.in_git():
            return None
        name = self._git("symbolic-ref", "--short", "-q", "HEAD")
        return name.strip() if name and name.strip() else "(no branch)"

    def changed_paths(self) -> Optional[Set[str]]:
        """The files that differ from HEAD (a merge's staged result included) and new ones; None outside git."""
        if not self.in_git():
            return None
        changed = self._git("diff", "--name-only", "HEAD")
        added = self._git("ls-files", "--others", "--exclude-standard")
        if changed is None:
            return None
        return set(changed.splitlines()) | set((added or "").splitlines())

    def history_numbers(self) -> Dict[str, Set[int]]:
        """The family numbers in every version git has of the TODO; empty outside git."""
        if not self.in_git() or self.todo_path != self.root / issueids.TODO_NAME:
            return {}
        log = self._git("log", "-p", "--no-color", "--format=", "--", issueids.TODO_NAME)
        return issueids.numbers_in(log) if log else {}

    def history_issue_ids(self) -> Set[str]:
        """The IDs of every issue file ``Issues/`` has had in git; empty outside git."""
        if not self.in_git():
            return set()
        log = self._git("log", "--format=", "--name-only", "--", f"{ISSUES_DIR}/")
        found = set()
        for line in (log or "").splitlines():
            name = Path(line.strip()).name
            if name.endswith(".md") and name != README_NAME:
                found.add(name[:-3])
        return found

    def used_numbers(self) -> Dict[str, Set[int]]:
        """Every number each family has ever had (see issueids): the files, the TODO, and git's history.

        An issue's ``related`` values are not counted: they name IDs that exist
        already, and a typo in one (B99) would move B's next number for good.
        """
        ids: Set[str] = {path.stem for path in self.issue_files()}
        ids.update(self.aliases())
        ids.update(self.history_issue_ids())
        used = issueids.numbers_of_ids(ids)
        issueids.merge_numbers(used, issueids.numbers_in(self.todo_text()))
        issueids.merge_numbers(used, self.history_numbers())
        return used

    # -- The docs ----------------------------------------------------------------

    def doc_sections(self) -> List[DocSection]:
        """Every section of the docs that has a marker, read with the doc-library skill's model.

        The pages are those doclib's lint covers: README.md, ARCHITECTURE.md, docs/,
        AGENTS.md, and CLAUDE.md. Empty when the skill is not in this checkout.
        """
        if self._doc_sections is not None:
            return self._doc_sections
        self._doc_sections = []
        if not (DOCLIB_SCRIPTS / "docmodel.py").is_file():
            return self._doc_sections
        if str(DOCLIB_SCRIPTS) not in sys.path:
            sys.path.insert(0, str(DOCLIB_SCRIPTS))
        import docmodel  # noqa: E402  (the doc-library skill's own model, found by path)
        for page_path in docmodel.lint_pages(self.root):
            page = docmodel.load_page(self.root, page_path)
            for section in page.sections:
                marker = section.marker
                if marker is None or not marker.id:
                    continue
                self._doc_sections.append(DocSection(
                    path=page.path, start=section.start, end=section.end, heading=section.heading,
                    section_id=marker.id, title=section.title, status=getattr(marker, "status", None),
                    issues=list(getattr(marker, "issues", []))))
        return self._doc_sections

    def sections_citing(self, issue_id: str) -> List[DocSection]:
        """The doc sections whose marker names ``issue_id`` among its issues."""
        return [section for section in self.doc_sections() if issue_id in section.issues]


# ---------------------------------------------------------------------------
# Who may change what.
# ---------------------------------------------------------------------------

def permit(store: Store, action: str, as_name: str, issue: Optional[Issue] = None, agent_may: bool = False,
           allow_branch: bool = False) -> None:
    """Refuse ``action`` unless the rules above allow it to ``as_name`` on the root's branch.

    ``agent_may`` marks the changes an agent may make to the issue assigned to it;
    ``allow_branch`` lets the action happen on any branch (``new --on-branch``).
    """
    if not issuefile.is_agent_name(as_name):
        raise UsageError(f"--as {as_name!r} is not a name: letters, digits, '.', '_', '-'")
    branch = store.branch()
    if branch is None or branch == MAIN_BRANCH or allow_branch:
        return
    if agent_may and issue is not None:
        assignee = issue.value("assignee")
        if assignee == as_name:
            return
        raise Refused(f"{issue.issue_id} is assigned to {assignee or 'no one'}, not {as_name}: on a branch "
                      f"({branch}), an agent only comments on the issue assigned to it and sets it in-progress "
                      "or blocked; post anything else on the board")
    raise Refused(f"{action} is the orchestrator's, on {MAIN_BRANCH}, and this is {branch}: post a finding "
                  "or a question on the board instead")


# ---------------------------------------------------------------------------
# The changes.
# ---------------------------------------------------------------------------

def _normalized(name: str, value: str) -> str:
    """A value as a field holds it: a list field's entries joined by ", ", any other value trimmed."""
    if name in issuefile.LIST_FIELDS:
        entries = [entry for part in value.split(",") for entry in part.split()]
        return issuefile.join_list(entries)
    return " ".join(value.split())


def _choice(name: str, value: str) -> str:
    """``value`` when it is one of field ``name``'s choices; UsageError naming them otherwise."""
    choices = issuefile.CHOICES[name]
    if value not in choices:
        raise UsageError(f"{name} {value!r} is not one of {', '.join(choices)}")
    return value


def check_references(store: Store, name: str, entries: List[str]) -> None:
    """Refuse a ``related`` entry that names no issue file, TODO item, or alias, and a ``docs`` entry that names no doc section.

    ``check`` reports such entries in a file too; refusing them here keeps a typo
    out of the file in the first place.
    """
    if name == "related":
        known = store.known_ids()
        for entry in entries:
            if not issueids.is_issue_id(entry):
                raise UsageError(f"related {entry!r} is not an ID")
            if entry not in known:
                raise Refused(f"related {entry} names no issue file, TODO item, or alias")
    elif name == "docs":
        sections = {section.section_id for section in store.doc_sections()}
        for entry in entries:
            if entry not in sections:
                raise Refused(f"docs {entry} names no doc section (doclib find {entry} finds none)")


def _sound(store: Store, issue_id: str) -> Issue:
    """The issue ``issue_id``, refused when its layout is broken, since a rewrite could lose what it holds."""
    issue = store.load(issue_id)
    if issue.problems:
        first = issue.problems[0]
        raise Refused(f"{issue.path}:{first.line}: {first.message}; fix the file by hand first")
    return issue


def new_issue(store: Store, *, kind: str, title: str, priority: str, platform: str, description: str,
              as_name: str, found_by: str = "", related: Iterable[str] = (), docs: Iterable[str] = (),
              labels: Iterable[str] = (), family: str = "", issue_id: str = "", on_branch: bool = False) -> Change:
    """File a new issue from the template: the next free ID of its family, or ``issue_id`` when given.

    The family is the kind's (issueids.FAMILY_OF_KIND) unless ``family`` names
    another. A given ID must be unused, as must its number. ``on_branch`` files
    it on a branch other than main, which only the orchestrator's asking allows:
    another branch could take the same ID, so the agent says it on the board.
    """
    if on_branch:
        permit(store, "filing an issue", as_name, allow_branch=True)
    else:
        permit(store, "filing an issue", as_name)
    _choice("kind", kind)
    _choice("priority", priority)
    _choice("platform", platform)
    title = " ".join(title.split())
    if not title:
        raise UsageError("a new issue needs a title")
    if not description.strip():
        raise UsageError("a new issue needs a description (--description TEXT or --file FILE)")
    used = store.used_numbers()
    if issue_id:
        issue_id = _unused_id(store, issue_id, used)
    else:
        family = family or issueids.FAMILY_OF_KIND[kind]
        if not issueids.is_family(family):
            raise UsageError(f"family {family!r} is not one to eight capitals")
        issue_id = issueids.next_id(family, used)
    path = store.path_of(issue_id)
    if path.exists():
        raise Refused(f"{store.relative(path)} already exists")
    today = store.today()
    values = {
        "id": issue_id, "title": title, "kind": kind, "priority": priority, "platform": platform,
        "today": today, "found_by": " ".join((found_by or as_name).split()),
        "related": _normalized("related", ",".join(related)),
        "docs": _normalized("docs", ",".join(docs)),
        "labels": _normalized("labels", ",".join(labels)),
        "description": description.strip("\n").rstrip(),
    }
    for name in ("related", "docs"):
        check_references(store, name, issuefile.split_list(values[name]))
    try:
        text = issuefile.fill_template(store.template(), store.relative(path), values)
    except IssueFormatError as error:
        raise Refused(str(error)) from None
    return Change(path, text, f"filed {store.relative(path)}: {issue_id}, {kind}, {priority}, {platform}: {title}")


def _unused_id(store: Store, issue_id: str, used: Dict[str, Set[int]]) -> str:
    """``issue_id`` when nothing has ever used it or its number; UsageError or Refused otherwise."""
    if not issueids.is_issue_id(issue_id):
        raise UsageError(f"{issue_id!r} is not an ID: capitals, digits, and hyphens, with a digit or a hyphen")
    if issue_id in store.known_ids() or issue_id in store.history_issue_ids():
        raise Refused(f"{issue_id} is used already{store.whereabouts(issue_id)}")
    numbered = issueids.family_number(issue_id)
    if numbered and numbered[1] in used.get(numbered[0], set()):
        raise Refused(f"{numbered[0]}{numbered[1]:02d} has been used already; the next free one is "
                      f"{issueids.next_id(numbered[0], used)}")
    return issue_id


def set_field(store: Store, issue_id: str, name: str, value: str, as_name: str) -> Change:
    """Set one field of an issue's header, and ``updated`` to today.

    ``id`` and ``updated`` are not set by hand; a closing status goes through
    ``close`` and leaving one through ``reopen``, so their reasons are recorded.
    """
    if name not in issuefile.FIELDS:
        raise UsageError(f"{name!r} is not a field: {', '.join(issuefile.FIELDS)}")
    if name in ("id", "updated"):
        raise UsageError(f"{name} is not set by hand" + (": an ID is kept for good" if name == "id" else ""))
    issue = _sound(store, issue_id)
    value = _normalized(name, value)
    agent_may = False
    if name == "status":
        _choice("status", value)
        if value in issuefile.CLOSED:
            raise Refused(f"close closes an issue (with --merged or --reason), not set status {value}")
        if issue.closed:
            raise Refused(f"{issue_id} is {issue.value('status')}: reopen opens it again, with a reason")
        agent_may = value in issuefile.AGENT_STATUSES
    elif name in issuefile.CHOICES:
        _choice(name, value)
    permit(store, f"setting {name}", as_name, issue, agent_may=agent_may)
    if name in ("merged", "reason") and not issue.closed:
        raise Refused(f"{name} belongs to a closed issue: close sets it")
    check_references(store, name, issuefile.split_list(value))
    old = issue.value(name)
    if old == value:
        return Change(store.path_of(issue_id), "", f"{issue.path}: {name} is {value or 'empty'} already", unchanged=True)
    text = _changed(issue, {name: value, "updated": store.today()})
    return Change(store.path_of(issue_id), text, f"{issue.path}: {name} {old or 'empty'} -> {value or 'empty'}")


def _changed(issue: Issue, changes: Dict[str, str]) -> str:
    """``issuefile.with_fields``, with its refusal turned into Refused."""
    try:
        return issuefile.with_fields(issue, changes)
    except IssueFormatError as error:
        raise Refused(str(error)) from None


def assign(store: Store, issue_id: str, agent: str, as_name: str, branch: Optional[str] = None) -> Change:
    """Give an issue to ``agent`` (or to no one, for ""), and name its branch when ``branch`` is given."""
    issue = _sound(store, issue_id)
    permit(store, "assigning an issue", as_name)
    if agent and not issuefile.is_agent_name(agent):
        raise UsageError(f"{agent!r} is not an agent's name")
    if issue.closed:
        raise Refused(f"{issue_id} is {issue.value('status')}: reopen it first")
    changes = {"assignee": agent}
    if branch is not None:
        changes["branch"] = branch
    said = [f"assignee {issue.value('assignee') or 'none'} -> {agent or 'none'}"]
    if branch is not None:
        said.append(f"branch {issue.value('branch') or 'none'} -> {branch or 'none'}")
    if all(issue.value(name) == value for name, value in changes.items()):
        return Change(store.path_of(issue_id), "", f"{issue.path}: unchanged", unchanged=True)
    changes["updated"] = store.today()
    return Change(store.path_of(issue_id), _changed(issue, changes), f"{issue.path}: " + "; ".join(said))


def _commented(issue: Issue, date: str, author: str, text: str) -> str:
    """``issuefile.with_comment``, with its refusal turned into Refused."""
    try:
        return issuefile.with_comment(issue, date, author, text)
    except IssueFormatError as error:
        raise Refused(str(error)) from None


def add_comment(store: Store, issue_id: str, text: str, as_name: str) -> Change:
    """Add a comment by ``as_name``, dated today, at the end of the issue; the header stays as it was."""
    issue = _sound(store, issue_id)
    permit(store, "commenting", as_name, issue, agent_may=True)
    new_text = _commented(issue, store.today(), as_name, text)
    lines = len(issuefile.check_comment_text(text).split("\n"))
    return Change(store.path_of(issue_id), new_text,
                  f"{issue.path}: comment by {as_name} on {store.today()} added ({lines} line{'s' if lines != 1 else ''})")


def close(store: Store, issue_id: str, as_name: str, merged: str = "", reason: str = "",
          status: str = "done", date: str = "") -> Change:
    """Close an issue: its status, ``merged`` or ``reason``, ``updated``, and a comment saying so.

    A done issue needs the merge commit or a reason; wontfix and duplicate need a
    reason. ``date`` (YYYY-MM-DD) is the merge's, today by default.
    """
    issue = _sound(store, issue_id)
    permit(store, "closing an issue", as_name)
    if status not in issuefile.CLOSED:
        raise UsageError(f"an issue closes as {', '.join(issuefile.CLOSED)}, not {status!r}")
    if issue.closed:
        raise Refused(f"{issue_id} is {issue.value('status')} already")
    merged, reason = merged.strip(), " ".join(reason.split())
    if merged and not issuefile.is_hash(merged):
        raise UsageError(f"--merged {merged!r} is not a commit: 7 to 40 lowercase hexadecimal digits")
    if status in issuefile.NEEDS_REASON and not reason:
        raise UsageError(f"closing as {status} needs --reason")
    if not (merged or reason):
        raise UsageError("closing as done needs --merged HASH or --reason TEXT")
    date = date or store.today()
    if not issuefile.is_date(date):
        raise UsageError(f"date {date!r} is not written YYYY-MM-DD")
    header = _changed(issue, {"status": status, "merged": merged, "reason": reason, "updated": date})
    why = "; ".join(part for part in (f"merged in {merged}" if merged else "", reason.rstrip(".")) if part)
    text = _commented(issuefile.parse(issue.path, header), date, as_name, f"Closed as {status}: {why}.")
    said = f"{issue.path}: closed as {status}" + (f", merged {merged}" if merged else "") + f", on {date}"
    return Change(store.path_of(issue_id), text, said)


def reopen(store: Store, issue_id: str, reason: str, as_name: str) -> Change:
    """Open a closed issue again, clearing ``merged`` and ``reason``, with a comment that keeps them."""
    issue = _sound(store, issue_id)
    permit(store, "reopening an issue", as_name)
    if not issue.closed:
        raise Refused(f"{issue_id} is {issue.value('status')}, not closed")
    reason = " ".join(reason.split())
    if not reason:
        raise UsageError("reopening needs --reason TEXT")
    was = f"It was {issue.value('status')}"
    if issue.value("merged"):
        was += f", merged in {issue.value('merged')}"
    if issue.value("reason"):
        was += f": {issue.value('reason')}"
    today = store.today()
    header = _changed(issue, {"status": "open", "merged": "", "reason": "", "updated": today})
    text = _commented(issuefile.parse(issue.path, header), today, as_name, f"Reopened: {reason.rstrip('.')}. {was}.")
    return Change(store.path_of(issue_id), text, f"{issue.path}: reopened ({was[0].lower() + was[1:]})")


def citing_notes(store: Store, issue_id: str) -> List[str]:
    """A sentence for each doc section whose marker cites ``issue_id``, said when it closes: the docs pass updates them."""
    return [f"{section.path}:{section.start} ({section.section_id}, status {section.status or 'none'}) cites "
            f"{issue_id}: the next docs pass updates that section (doclib check lists it)"
            for section in store.sections_citing(issue_id)]


def pointer_change(store: Store, issue_id: str, closed: bool) -> Optional[Change]:
    """The TODO with ``issue_id``'s pointer lines ticked (or unticked), or None when it has none to change."""
    text = store.todo_text()
    new_text, count = issueids.set_pointers(text, issue_id, closed)
    if not count or new_text == text:
        return None
    said = "ticked" if closed else "unticked"
    return Change(store.todo_path, new_text, f"{store.todo_path.name}: {issue_id}'s pointer line {said}")


def write(change: Change) -> None:
    """Write one change's file (nothing for an unchanged one)."""
    if change.unchanged:
        return
    change.path.parent.mkdir(parents=True, exist_ok=True)
    change.path.write_text(change.text, encoding="utf-8")


# ---------------------------------------------------------------------------
# Checking every file.
# ---------------------------------------------------------------------------

def check(store: Store) -> List[Tuple[str, Problem]]:
    """Everything wrong with the issue files and the TODO's IDs, as (file, problem) pairs in file order.

    Beyond each file's layout and values: its name is its ID; no alias or other
    TODO item takes its ID; ``related`` names a known ID and ``docs`` a doc section;
    the TODO's pointers lead to files; and no ID opens two of the TODO's items
    unless all but one of them carry an alias.
    """
    found: List[Tuple[str, Problem]] = []
    issues = store.load_all()
    known = store.known_ids()
    aliases = store.aliases()
    section_ids = {section.section_id for section in store.doc_sections()}
    backlog: Dict[str, List[issueids.TodoItem]] = {}
    for item in store.todo_items():
        if item.in_backlog and not item.pointer:
            for issue_id in item.ids:
                backlog.setdefault(issue_id, []).append(item)
    for issue in issues:
        stem = Path(issue.path).stem
        problems = list(issue.problems) + issuefile.check_values(issue) + issuefile.check_comments(issue)
        if not issueids.is_issue_id(stem):
            problems.append(Problem(0, f"{stem}.md is not named for an ID; only issue files and {README_NAME} belong here"))
        elif issue.issue_id and issue.issue_id != stem:
            problems.append(Problem(issue.field_lines.get("id", 1), f"id {issue.issue_id} differs from the file's name, {stem}"))
        if stem in aliases:
            problems.append(Problem(0, f"{stem} is also an alias of {aliases[stem]} in {store.todo_path.name}"))
        for item in backlog.get(stem, []):
            problems.append(Problem(0, f"{stem} also opens an item of {store.todo_path.name} (line {item.line}): "
                                       "an ID names one thing"))
        line = issue.field_lines.get("related", 1)
        for entry in issue.values("related"):
            if issueids.is_issue_id(entry) and entry != stem and entry not in known:
                problems.append(Problem(line, f"related {entry} names no issue file, TODO item, or alias"))
        line = issue.field_lines.get("docs", 1)
        for entry in issue.values("docs"):
            if entry not in section_ids:
                problems.append(Problem(line, f"docs {entry} names no doc section (doclib find {entry} finds none)"))
        found.extend((issue.path, problem) for problem in problems)
    statuses = {Path(issue.path).stem: issue.value("status") for issue in issues}
    found.extend(_todo_problems(store, backlog, statuses))
    return found


def problem_key(path: str, message: str) -> Tuple[str, str]:
    """What makes two runs' problems the same one: the file and the message, its numbers left out, since lines move."""
    return path, re.sub(r"\d+", "#", message)


def new_problems(store: Store, problems: List[Tuple[str, Problem]], earlier: Path) -> Tuple[List[Tuple[str, Problem]], int]:
    """The problems not in ``earlier`` (JSON lines from an earlier ``check --json``) and in a file changed against HEAD.

    This is the merge chain's ratchet: main's own problems, and those in files the
    merge left alone, are not the merge's. A missing or empty ``earlier`` holds none;
    outside git every file counts as changed. Returns the new problems and how
    many others were left out.
    """
    before = set()
    if earlier.is_file():
        for line in earlier.read_text(encoding="utf-8").splitlines():
            try:
                data = json.loads(line)
            except ValueError:
                continue
            if isinstance(data, dict):
                before.add(problem_key(str(data.get("path", "")), str(data.get("message", ""))))
    changed = store.changed_paths()
    new = [(path, problem) for path, problem in problems
           if problem_key(path, problem.message) not in before and (changed is None or path in changed)]
    return new, len(problems) - len(new)


def _todo_problems(store: Store, backlog: Dict[str, List[issueids.TodoItem]],
                   statuses: Dict[str, str]) -> List[Tuple[str, Problem]]:
    """The TODO's own problems: pointers that lead nowhere or whose box disagrees with their issue, open items
    left in it, an alias given twice, and IDs that name two items."""
    found: List[Tuple[str, Problem]] = []
    name = store.todo_path.name
    seen_aliases: Dict[str, int] = {}
    for item in store.todo_items():
        if item.pointer:
            target = item.target
            if item.ids[0] != target:
                found.append((name, Problem(item.line, f"the pointer of {item.ids[0]} leads to {target}.md")))
            elif target not in statuses:
                found.append((name, Problem(item.line, f"{target} moved to {ISSUES_DIR}/{target}.md, which does not exist")))
            elif item.checked != (statuses[target] in issuefile.CLOSED):
                state = "ticked" if item.checked else "not ticked"
                found.append((name, Problem(item.line, f"{target}'s pointer is {state}, but {target} is {statuses[target]} "
                                                       "(issuelib close and reopen tick and untick it)")))
        for alias in item.aliases:
            if alias in seen_aliases:
                found.append((name, Problem(item.line, f"alias {alias} is given on line {seen_aliases[alias]} too")))
            seen_aliases.setdefault(alias, item.line)
    for line in issueids.open_item_lines(store.todo_text()):
        found.append((name, Problem(line, f"an open item left in {name}: open work is an issue "
                                          "(issuelib new on main, or import-todo)")))
    for issue_id, items in sorted(backlog.items(), key=lambda pair: issueids.sort_key(pair[0])):
        plain = [item for item in items if not item.aliases]
        if len(plain) > 1:
            lines = and_list([str(item.line) for item in plain])
            for item in plain:
                found.append((name, Problem(item.line, f"{issue_id} opens {len(plain)} items (lines {lines}): give all "
                                                       f"but one an alias in its opening, as in '**{issue_id} (alias "
                                                       f"{issue_id}-OCT) — '")))
    return found
