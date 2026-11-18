#!/usr/bin/env python3
"""issue-library: TextMouth's issue tracker, one Markdown file per issue in ``Issues/``.

Run from anywhere inside the repository or one of its worktrees:

    python3 -I -B .claude/skills/issue-library/scripts/issuelib.py COMMAND [ARGS] [OPTIONS]

The commands that read (list, show, search, summary, check) change nothing. Each
command that writes (new, set, assign, comment, close, reopen) changes one file and
prints one line saying what it did; it needs ``--as NAME``, the name it acts and
comments under. ``import-todo`` moves the TODO's open items into issue files once.

Exit status: 0 when the command did its work, 1 when a check found problems, a
search found nothing, or a change was refused (one line on standard error says
why), 2 for a command line that names nothing or gives a bad value.

The format is in Issues/README.md and issuefile.py; who may change what is in
issuestore.py. Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

# No bytecode beside the skill: the scripts run with -B, and this covers a run without it,
# and the doc-library modules imported from here. Set before the folder joins the path.
sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import issueids  # noqa: E402  (imported after sys.path is set)
import issuefile  # noqa: E402
import issuemerge  # noqa: E402
import issuestore  # noqa: E402
from issuefile import Issue  # noqa: E402
from issuestore import Refused, Store, UsageError  # noqa: E402

EXIT_OK = 0      # the command did its work
EXIT_FAIL = 1    # a check found problems, a search found nothing, or a change was refused
EXIT_USAGE = 2   # the command line named nothing or gave a bad value

# How long a line of ``list`` or ``search`` may be, in characters, unless --width says otherwise:
# two pans of a 40-cell braille display.
DEFAULT_WIDTH = 80
# The mark left where a line was cut.
ELLIPSIS = "…"
# The statuses ``list`` shows unless --status says otherwise: every issue not closed.
OPEN_STATUSES = tuple(status for status in issuefile.STATUSES if status not in issuefile.CLOSED)


# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------

def clip(text: str, width: int, focus: Optional[int] = None) -> str:
    """``text`` on one line, cut to ``width`` characters (0: no cut), keeping ``focus`` (an offset) in view."""
    flat = " ".join(text.split())
    if not width or len(flat) <= width:
        return flat
    if focus is None or focus < width - width // 3:
        return flat[:width - 1] + ELLIPSIS
    start = min(focus - width // 3, len(flat) - (width - 1))
    return ELLIPSIS + flat[start:start + width - 2] + ELLIPSIS


def choice_list(choices: Iterable[str]) -> Any:
    """An argparse type: one or more of ``choices`` separated by commas, as a list."""
    allowed = tuple(choices)

    def parse(text: str) -> List[str]:
        """Split ``text`` at commas and check each part."""
        parts = [part.strip() for part in text.split(",") if part.strip()]
        for part in parts:
            if part not in allowed:
                raise argparse.ArgumentTypeError(f"{part!r} is not one of {', '.join(allowed)}")
        return parts

    return parse


def width_type(text: str) -> int:
    """An argparse type for --width: a whole number of at least 0 (0: no cut)."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a whole number, got {text!r}") from None
    if value < 0 or 0 < value < 20:
        raise argparse.ArgumentTypeError("expected 0 (no cut) or at least 20")
    return value


def read_text_argument(text: Optional[str], file: Optional[str], what: str) -> str:
    """The text given inline or in a file ("-": standard input); UsageError when both or neither are."""
    if (text is None) == (file is None):
        raise UsageError(f"give the {what} either inline or with --file, not both or neither")
    if file is None:
        return text or ""
    if file == "-":
        return sys.stdin.read()
    path = Path(file)
    if not path.is_file():
        raise UsageError(f"--file {file}: no such file")
    return path.read_text(encoding="utf-8")


def summary_line(issue: Issue, width: int) -> str:
    """One issue on one line: ``ID P1 status platform[ assignee]: title``, cut to ``width``."""
    parts = [issue.issue_id, issue.value("priority"), issue.value("status"), issue.value("platform")]
    if issue.value("assignee"):
        parts.append(issue.value("assignee"))
    return clip(" ".join(part for part in parts if part) + ": " + issue.value("title"), width)


def issue_object(issue: Issue) -> Dict[str, Any]:
    """An issue as JSON: its path, its fields (lists as lists), and how many comments it has."""
    data: Dict[str, Any] = {"path": issue.path}
    for name in issuefile.FIELDS:
        data[name] = issue.values(name) if name in issuefile.LIST_FIELDS else issue.value(name)
    data["comments"] = len(issue.comments)
    return data


def finish(change: issuestore.Change) -> int:
    """Write a change and print what it did."""
    issuestore.write(change)
    print(f"issuelib: {change.message}")
    return EXIT_OK


# ---------------------------------------------------------------------------
# The commands that read.
# ---------------------------------------------------------------------------

def sort_issues(issues: List[Issue]) -> List[Issue]:
    """Issues in the order ``list`` prints them: by priority, then status (in-progress first), then ID."""
    def key(issue: Issue) -> Any:
        """Unknown values sort last, so a broken file is still listed."""
        priority = issue.value("priority")
        status = issue.value("status")
        return (issuefile.PRIORITIES.index(priority) if priority in issuefile.PRIORITIES else 9,
                issuefile.STATUSES.index(status) if status in issuefile.STATUSES else 9,
                issueids.sort_key(issue.issue_id or Path(issue.path).stem))
    return sorted(issues, key=key)


def matches(issue: Issue, args: Any) -> bool:
    """Whether ``issue`` passes every filter of ``list`` (and of ``search``'s --status)."""
    statuses = args.status if args.status else list(OPEN_STATUSES)
    if "all" not in statuses and issue.value("status") not in statuses:
        return False
    for name in ("priority", "kind"):
        wanted = getattr(args, name, None)
        if wanted and issue.value(name) not in wanted:
            return False
    platforms = getattr(args, "platform", None)
    if platforms and not concerns(issue.value("platform"), platforms):
        return False
    assignee = getattr(args, "assignee", None)
    if assignee is not None:
        if assignee == "none" and issue.value("assignee"):
            return False
        if assignee != "none" and issue.value("assignee") != assignee:
            return False
    label = getattr(args, "label", None)
    if label and label not in issue.values("labels"):
        return False
    return True


def concerns(platform: str, wanted: List[str]) -> bool:
    """Whether an issue filed for ``platform`` concerns one of ``wanted``: one filed for both concerns mac and iphone."""
    return platform in wanted or (platform == "both" and any(name in ("mac", "iphone") for name in wanted))


def cmd_list(store: Store, args: Any) -> int:
    """``list``: the issues that pass the filters, one per line, by priority; a count on standard error."""
    issues = store.load_all()
    shown = sort_issues([issue for issue in issues if matches(issue, args)])
    for issue in shown:
        print(json.dumps(issue_object(issue), ensure_ascii=False) if args.json else summary_line(issue, args.width))
    print(f"issuelib: {len(shown)} of {len(issues)} {issuestore.plural(len(issues), 'issue')}", file=sys.stderr)
    return EXIT_OK


def cmd_show(store: Store, args: Any) -> int:
    """``show ID``: the issue file as written, then the doc sections that cite it.

    For an ID with no file, the TODO's lines that name it, an alias among them.
    """
    issue_id = args.id
    aliases = store.aliases()
    if not store.path_of(issue_id).is_file():
        return show_todo_items(store, issue_id, aliases, args)
    issue = store.load(issue_id)
    sections = store.sections_citing(issue_id)
    if args.json:
        data = issue_object(issue)
        data["description"] = issue.description
        data["comment_list"] = [{"date": c.date, "author": c.author, "text": c.text} for c in issue.comments]
        data["cited_by"] = [{"path": s.path, "start": s.start, "end": s.end, "heading": s.heading,
                             "id": s.section_id, "status": s.status} for s in sections]
        print(json.dumps(data, ensure_ascii=False))
        return EXIT_OK
    print(issue.path)
    print(store.path_of(issue_id).read_text(encoding="utf-8").rstrip("\n"))
    print()
    if not sections:
        print(f"No doc section cites {issue_id}.")
    else:
        print(f"Doc sections that cite {issue_id}: {len(sections)}")
        for section in sections:
            print(f"{section.path}:{section.start}-{section.end}  {section.heading}  "
                  f"{section.section_id}, status {section.status or 'none'}")
    return EXIT_OK


def show_todo_items(store: Store, issue_id: str, aliases: Dict[str, str], args: Any) -> int:
    """``show`` for an ID without a file: the TODO's lines that open with it, or the one an alias renames."""
    lines = store.todo_text().split("\n")
    if issue_id in aliases:
        items = [item for item in store.todo_items() if issue_id in item.aliases]
        intro = f"{issue_id} is an alias of {aliases[issue_id]}, given in {store.todo_path.name}:"
    else:
        items = [item for item in store.todo_items() if issue_id in item.ids]
        intro = f"{issue_id} has no file in {issuestore.ISSUES_DIR}/; {store.todo_path.name} names it:"
    if not items:
        raise UsageError(f"{issue_id} names no issue file, TODO item, or alias")
    if args.json:
        print(json.dumps({"id": issue_id, "alias_of": aliases.get(issue_id),
                          "todo": [{"line": item.line, "text": lines[item.line - 1]} for item in items]},
                         ensure_ascii=False))
        return EXIT_OK
    print(intro)
    for item in items:
        print(f"{store.todo_path.name}:{item.line}: {clip(lines[item.line - 1], 300)}")
    return EXIT_OK


def cmd_search(store: Store, args: Any) -> int:
    """``search REGEX``: every line of an issue file that matches, as ``ID:LINE: text``, ignoring case."""
    try:
        regex = re.compile(args.pattern, re.IGNORECASE)
    except re.error as error:
        raise UsageError(f"bad pattern {args.pattern!r}: {error}") from None
    if not args.status:
        args.status = ["all"]
    found = 0
    for path in store.issue_files():
        issue = store.read(path)
        if not matches(issue, args):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
            match = regex.search(line)
            if match is None:
                continue
            found += 1
            if args.json:
                print(json.dumps({"id": path.stem, "path": issue.path, "line": number, "text": line}, ensure_ascii=False))
            else:
                prefix = f"{path.stem}:{number}: "
                room = max(20, args.width - len(prefix)) if args.width else 0
                flat_focus = len(" ".join(line[:match.start()].split()))
                print(prefix + clip(line, room, flat_focus))
    if not found:
        print(f"issuelib: no line matches {args.pattern!r}", file=sys.stderr)
        return EXIT_FAIL
    return EXIT_OK


def cmd_summary(store: Store, args: Any) -> int:
    """``summary``: how many issues each status has, each split by priority, without a table."""
    issues = store.load_all()
    counts: Dict[str, Dict[str, int]] = {}
    for issue in issues:
        by_priority = counts.setdefault(issue.value("status") or "none", {})
        priority = issue.value("priority") or "none"
        by_priority[priority] = by_priority.get(priority, 0) + 1
    if args.json:
        print(json.dumps({"issues": len(issues), "by_status": counts}, ensure_ascii=False))
        return EXIT_OK
    not_closed = sum(sum(counts.get(status, {}).values()) for status in OPEN_STATUSES)
    open_priorities: Dict[str, int] = {}
    for status in OPEN_STATUSES:
        for priority, number in counts.get(status, {}).items():
            open_priorities[priority] = open_priorities.get(priority, 0) + number
    print(f"{len(issues)} {issuestore.plural(len(issues), 'issue')}: {not_closed} not closed "
          f"({priority_text(open_priorities)}), {len(issues) - not_closed} closed.")
    ordered = list(issuefile.STATUSES) + sorted(set(counts) - set(issuefile.STATUSES))
    for status in ordered:
        if status in counts:
            print(f"{status} {sum(counts[status].values())}: {priority_text(counts[status])}")
    return EXIT_OK


def priority_text(counts: Dict[str, int]) -> str:
    """``P1 3, P2 24`` for counts by priority, in priority order; "none" when empty."""
    ordered = [p for p in issuefile.PRIORITIES if p in counts] + sorted(set(counts) - set(issuefile.PRIORITIES))
    return ", ".join(f"{priority} {counts[priority]}" for priority in ordered) or "none"


def cmd_check(store: Store, args: Any) -> int:
    """``check``: every problem of the issue files and the TODO's IDs, one per line; 1 when there are any.

    With ``--new-since FILE``, only the problems a merge brings: not in FILE (an
    earlier ``check --json``) and in a file changed against HEAD.
    """
    problems = issuestore.check(store)
    plural = issuestore.plural
    if args.new_since is not None:
        problems, left_out = issuestore.new_problems(store, problems, args.new_since)
        print_problems(problems, args.json)
        noun = plural(len(problems), "problem")
        print(f"issuelib check: {len(problems) or 'no'} new {noun} in the files changed against HEAD "
              f"({left_out} others left out: there before, or in files it left alone)", file=sys.stderr)
        return EXIT_FAIL if problems else EXIT_OK
    print_problems(problems, args.json)
    files = len(store.issue_files())
    if problems:
        paths = len({path for path, _ in problems})
        print(f"issuelib check: {len(problems)} {plural(len(problems), 'problem')} in {paths} "
              f"{plural(paths, 'file')} ({files} issue {plural(files, 'file')})", file=sys.stderr)
        return EXIT_FAIL
    print(f"issuelib check: {files} issue {plural(files, 'file')}, no problems", file=sys.stderr)
    return EXIT_OK


def print_problems(problems: List[Any], as_json: bool) -> None:
    """Print each (file, problem) pair: ``file:line: message``, or a JSON object per line."""
    for path, problem in problems:
        if as_json:
            print(json.dumps({"path": path, "line": problem.line, "message": problem.message}, ensure_ascii=False))
        else:
            print(f"{path}:{problem.line}: {problem.message}" if problem.line else f"{path}: {problem.message}")


# ---------------------------------------------------------------------------
# The commands that write.
# ---------------------------------------------------------------------------

def cmd_new(store: Store, args: Any) -> int:
    """``new``: file an issue from the template, taking its family's next free ID."""
    description = read_text_argument(args.description, args.file, "description")
    change = issuestore.new_issue(
        store, kind=args.kind, title=args.title, priority=args.priority, platform=args.platform,
        description=description, as_name=args.as_name, found_by=args.found_by or "",
        related=args.related or [], docs=args.docs or [], labels=args.labels or [],
        family=args.family or "", issue_id=args.id or "", on_branch=args.on_branch)
    return finish(change)


def cmd_set(store: Store, args: Any) -> int:
    """``set ID FIELD VALUE``: one field of the header, and updated."""
    return finish(issuestore.set_field(store, args.id, args.field, " ".join(args.value), args.as_name))


def cmd_assign(store: Store, args: Any) -> int:
    """``assign ID AGENT``: give the issue to an agent ("none" for no one), and its branch with --branch."""
    agent = "" if args.agent in ("none", "-") else args.agent
    return finish(issuestore.assign(store, args.id, agent, args.as_name, branch=args.branch))


def cmd_comment(store: Store, args: Any) -> int:
    """``comment ID TEXT``: add a dated comment by --as at the issue's end."""
    text = read_text_argument(args.text, args.file, "comment")
    return finish(issuestore.add_comment(store, args.id, text, args.as_name))


def cmd_close(store: Store, args: Any) -> int:
    """``close ID``: close as done (--merged or --reason), wontfix, or duplicate, and name the docs that cite it."""
    change = issuestore.close(store, args.id, args.as_name, merged=args.merged or "", reason=args.reason or "",
                              status=args.status, date=args.date or "")
    finish(change)
    pointer = issuestore.pointer_change(store, args.id, closed=True)
    if pointer is not None:
        finish(pointer)
    for note in issuestore.citing_notes(store, args.id):
        print(f"issuelib: {note}")
    return EXIT_OK


def cmd_reopen(store: Store, args: Any) -> int:
    """``reopen ID --reason TEXT``: open a closed issue again, and untick its pointer line in the TODO."""
    finish(issuestore.reopen(store, args.id, args.reason, args.as_name))
    pointer = issuestore.pointer_change(store, args.id, closed=False)
    return finish(pointer) if pointer is not None else EXIT_OK


def cmd_merge_driver(args: Any) -> int:
    """``merge-driver BASE CURRENT OTHER [SIZE] [PATH]``: git's merge of one issue file (issuemerge.py)."""
    return issuemerge.merge_files(args.base, args.current, args.other, args.marker_size)


# ---------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------

class IntermixedParser(argparse.ArgumentParser):
    """A command's parser that lets options and positionals come in any order (TL04).

    Plain argparse hands an optional positional (``comment``'s TEXT, ``set``'s VALUE...) the
    arguments that follow the required ones the moment it meets them, so ``comment ID --as NAME
    "text"`` found no place for "text" and failed with "unrecognized arguments". The intermixed
    parse reads the options first and the positionals after, so ``comment ID "text" --as NAME``
    and ``comment ID --as NAME "text"`` both work. It is a command's own parser (argparse's
    subparsers call parse_known_args), which cannot hold subparsers of its own.
    """

    # True while parse_known_intermixed_args runs: it calls parse_known_args itself, which must then parse plainly.
    _intermixing = False

    def leading_double_dash(self, args: List[str]) -> bool:
        """Whether ``--`` comes before the first positional word of ``args``, such as ``set --as NAME -- ID FIELD``.

        Python before 3.12.8 loses such a ``--`` in the intermixed parse and then reads the words after it as options,
        so a dash-leading word is refused or, worse, written. A ``--`` after a positional (``comment ID --as NAME --
        -x``) is kept by that parse, and the plain parse would refuse it, so only the first case is told apart. Words
        count as positional unless they start with a dash or are the value of an option that takes one.
        """
        words = iter(args)
        for word in words:
            if word == "--":
                return True
            action = self._option_string_actions.get(word)
            if action is not None:
                # An option with a value takes the next word along with it.
                if action.nargs != 0:
                    next(words, None)
            elif not word.startswith("-") or word == "-":
                return False
        return False

    def parse_known_args(self, args: Any = None, namespace: Any = None) -> Any:
        """Parse intermixed, unless already inside the intermixed parse (which asks for the plain one) or a ``--`` comes
        before the first positional (see leading_double_dash): the plain parse honours it, as it always did."""
        words = list(sys.argv[1:] if args is None else args)
        if self._intermixing or self.leading_double_dash(words):
            return super().parse_known_args(args, namespace)
        self._intermixing = True
        try:
            return self.parse_known_intermixed_args(args, namespace)
        finally:
            self._intermixing = False


def common_options() -> argparse.ArgumentParser:
    """The options every command takes, given after the command's name."""
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--root", type=Path, default=None,
                        help="the repository or worktree; by default the one holding the current folder")
    common.add_argument("--todo", type=Path, default=None,
                        help=f"the TODO to read IDs from (default: {issueids.TODO_NAME} in the root)")
    common.add_argument("--json", action="store_true", help="print JSON, one object per line")
    return common


def writer_options() -> argparse.ArgumentParser:
    """The option every command that writes takes: the name it acts and comments under."""
    writer = argparse.ArgumentParser(add_help=False)
    writer.add_argument("--as", dest="as_name", required=True, metavar="NAME",
                        help=f"who makes the change: your agent name, or {issuestore.ORCHESTRATOR}")
    return writer


def filter_options(parser: argparse.ArgumentParser, default_status: str) -> None:
    """The filters of ``list`` and ``search``."""
    parser.add_argument("--status", type=choice_list(issuefile.STATUSES + ("all",)), default=None,
                        metavar="S[,S]", help=f"statuses to show, or all (default: {default_status})")
    parser.add_argument("--priority", type=choice_list(issuefile.PRIORITIES), metavar="P[,P]")
    parser.add_argument("--kind", type=choice_list(issuefile.KINDS), metavar="K[,K]")
    parser.add_argument("--platform", type=choice_list(issuefile.PLATFORMS), metavar="X[,X]",
                        help="mac or iphone includes the issues filed for both; both, only those")
    parser.add_argument("--assignee", metavar="NAME", help="an agent's name, or none for the unassigned")
    parser.add_argument("--label", metavar="LABEL")
    parser.add_argument("--width", type=width_type, default=DEFAULT_WIDTH,
                        help=f"cut each line to this many characters (default {DEFAULT_WIDTH}; 0: no cut)")


def build_parser() -> argparse.ArgumentParser:
    """The command line: one subcommand for each command."""
    parser = argparse.ArgumentParser(prog="issuelib.py", description="TextMouth's issue tracker: Issues/<ID>.md.")
    commands = parser.add_subparsers(dest="command", metavar="COMMAND", parser_class=IntermixedParser)
    commands.required = True
    common, writer = common_options(), writer_options()

    def add(name: str, func: Any, help_text: str, writes: bool = False) -> argparse.ArgumentParser:
        """Add one subcommand that runs ``func``."""
        parents = [common, writer] if writes else [common]
        sub = commands.add_parser(name, parents=parents, help=help_text, description=help_text)
        sub.set_defaults(func=func)
        return sub

    sub = add("list", cmd_list, "the issues, one per line, by priority (open, in-progress, and blocked unless --status)")
    filter_options(sub, "the ones not closed")
    sub = add("show", cmd_show, "one issue as written, and the doc sections that cite it")
    sub.add_argument("id", metavar="ID")
    sub = add("search", cmd_search, "every line of the issues matching a regular expression, ignoring case")
    sub.add_argument("pattern", metavar="REGEX")
    filter_options(sub, "all")
    add("summary", cmd_summary, "how many issues each status has, by priority")
    sub = add("check", cmd_check, "check every issue file and the TODO's IDs")
    sub.add_argument("--new-since", type=Path, metavar="FILE",
                     help="only problems not in FILE (an earlier check --json) and in files changed against HEAD")

    sub = add("new", cmd_new, "file an issue, numbered next in its kind's family", writes=True)
    sub.add_argument("--kind", required=True, choices=issuefile.KINDS)
    sub.add_argument("--title", required=True)
    sub.add_argument("--priority", default="P2", choices=issuefile.PRIORITIES, help="default P2")
    sub.add_argument("--platform", required=True, choices=issuefile.PLATFORMS)
    sub.add_argument("--description", help="the description; or --file")
    sub.add_argument("--file", help="a file holding the description (- for standard input)")
    sub.add_argument("--found-by", help="who found it (default: --as)")
    sub.add_argument("--related", action="append", metavar="ID[,ID]", help="related IDs")
    sub.add_argument("--docs", action="append", metavar="SECTION[,SECTION]", help="doc section ids")
    sub.add_argument("--labels", action="append", metavar="LABEL[,LABEL]")
    sub.add_argument("--family", help="number it in another family, such as PG or DR")
    sub.add_argument("--id", help="file it under this ID, which nothing may have used")
    sub.add_argument("--on-branch", action="store_true",
                     help="file it on a branch other than main, only when the orchestrator asks; say the ID on the board")
    sub = add("set", cmd_set, "set one field (status: open, in-progress, or blocked)", writes=True)
    sub.add_argument("id", metavar="ID")
    sub.add_argument("field", metavar="FIELD")
    sub.add_argument("value", nargs="*", metavar="VALUE", help="the new value; nothing clears it")
    sub = add("assign", cmd_assign, "give an issue to an agent (none: to no one)", writes=True)
    sub.add_argument("id", metavar="ID")
    sub.add_argument("agent", metavar="AGENT")
    sub.add_argument("--branch", help="the branch it is worked on")
    sub = add("comment", cmd_comment, "add a dated comment at the issue's end", writes=True)
    sub.add_argument("id", metavar="ID")
    sub.add_argument("text", nargs="?", metavar="TEXT")
    sub.add_argument("--file", help="a file holding the comment (- for standard input)")
    sub = add("close", cmd_close, "close an issue at its merge, or with a reason", writes=True)
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--merged", metavar="HASH", help="the merge commit that closes it")
    sub.add_argument("--reason", help="why, when no merge closes it (needed for wontfix and duplicate)")
    sub.add_argument("--status", default="done", choices=issuefile.CLOSED, help="default done")
    sub.add_argument("--date", help="the merge's date, YYYY-MM-DD (default today)")
    sub = add("reopen", cmd_reopen, "open a closed issue again", writes=True)
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--reason", required=True)
    sub = commands.add_parser("merge-driver", help="git's merge driver for issue files (make issues-merge-driver defines it)",
                              description="Merge one issue file three ways, as git's merge driver: the header field "
                                          "by field, the description as git would, each comment whole.")
    sub.add_argument("base", metavar="BASE", help="the common ancestor (git's %%O)")
    sub.add_argument("current", metavar="CURRENT", help="the current side, which receives the result (%%A)")
    sub.add_argument("other", metavar="OTHER", help="the other side (%%B)")
    sub.add_argument("marker_size", metavar="SIZE", nargs="?", type=int, default=issuemerge.MARKER_SIZE,
                     help="the conflict markers' length (%%L)")
    sub.add_argument("path", metavar="PATH", nargs="?", default="", help="the file's path in the tree (%%P)")
    sub.set_defaults(func=cmd_merge_driver, needs_store=False)
    register_import(add)
    return parser


def register_import(add: Any) -> None:
    """Add ``import-todo``, which moves the TODO's open items into issue files once (issuetodo.py)."""
    import issuetodo  # noqa: E402  (the import's own module, beside this one)
    issuetodo.register(add)


def find_root(start: Path) -> Path:
    """The nearest folder at or above ``start`` holding a ``.git`` entry (a worktree's is a file)."""
    start = start.resolve()
    for folder in (start, *start.parents):
        if (folder / ".git").exists():
            return folder
    raise UsageError(f"{start} is not inside a git repository; pass --root")


def main(argv: Optional[List[str]] = None) -> int:
    """Parse the command line, run the command, and return its exit status."""
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "needs_store", True):
        # The merge driver works on git's three files alone, wherever git runs it.
        return args.func(args)
    try:
        root = find_root(Path.cwd()) if args.root is None else args.root.resolve()
        if not root.is_dir():
            raise UsageError(f"--root {root} is not a folder")
        store = Store(root, todo=args.todo.resolve() if args.todo else None)
        return args.func(store, args)
    except UsageError as error:
        print(f"issuelib: {error}", file=sys.stderr)
        return EXIT_USAGE
    except Refused as error:
        print(f"issuelib: refused: {error}", file=sys.stderr)
        return EXIT_FAIL
    except BrokenPipeError:
        # The reader of a pipe went away: stop quietly, and keep Python's own flush at exit quiet too.
        sys.stdout = open(os.devnull, "w")
        return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
