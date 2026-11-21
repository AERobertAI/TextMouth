"""``import-todo``: move the TODO's open items into issue files, once.

Every open item of the TODO, a line ``- [ ] **ID — title.** ...`` at the left
margin with the lines that continue it, becomes ``Issues/<ID>.md``. Its
description is the item's whole text, sub-bullets included, without the
``- [ ]`` and with its continuation lines moved two columns left; its lines in the
TODO become one line, ``- [ ] **ID** moved to Issues/ID.md``. Done items stay where
they are: they are the record of the merges.

An open item with no ID (the manual acceptance matrix's rows) belongs to the item
its section's heading names first ("Manual acceptance matrix for A01/P09/Q05" is
A01's). Its rows go into that issue under the section's title, after the section's
opening paragraphs (copied, so the TODO keeps them), and leave one pointer line.

The header takes the facts the text gives, by the rules of ``facts``: who found it
and when, the platform, the priority where one is stated (P2 otherwise), and the
IDs it names that something else holds. Nothing is written unless every item's
words appear, in order, in its issue's description, and no issue file is there
already.
"""

from __future__ import annotations

import datetime as dt
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import issuedates
import issueids
import issuefile
import issuestore
from issuestore import Refused, Store, UsageError

# A line at the left margin that starts a block of its own, so it does not continue an item.
_BLOCK_START = re.compile(r"^(?:#|[-*+] |\d{1,9}[.)] |>|```|~~~|\||<!--)")
# The TODO's own date, in its first lines: "Audit date: September 4, 2026."
_AUDIT_DATE = re.compile(r"^Audit date: (.*)$", re.M)
# How far past an item's bold opening its date and finder are looked for, and how far from
# its start its priority is (the bold opening included, for "(low priority)").
_OPENING_CHARS = 250
_HEAD_CHARS = 400
# A section of the code audit of September 4: "P — Playback, navigation, and lifecycle".
_AUDIT_SECTION = re.compile(r"^[A-Z] — |^Manual acceptance matrix\b")

# The kind of an imported item, by its ID's family; the audit's evidence label Manual makes it a test.
KIND_OF_FAMILY = {
    "B": "bug", "FR": "feature", "FMT": "format", "FU": "follow-up", "Q": "test", "PG": "feature",
    "V": "feature", "DR": "feature", "A11Y": "bug", "TL": "tooling", "DOC": "docs", "QN": "question",
    "A": "bug", "P": "bug", "T": "bug", "S": "bug", "I": "bug", "C": "bug", "ST": "bug",
    "PERF": "feature", "REV": "follow-up",
}
_MANUAL = re.compile(r"· Manual\b")
# The label an item the audit marks Manual gets: a check by hand, with VoiceOver or hardware.
MANUAL_LABEL = "manual"

# Who found an item, as its opening says it: "by `review-rulesmove`", "From `ffmpegimport`'s
# report", "From the ChatGPT docs review of ...", "Requested ...", "The user's wish", "train 1115-1800".
_BY_AGENT = re.compile(r"\bby `([A-Za-z0-9._-]+)`")
_FROM_AGENT = re.compile(r"\bFrom `([A-Za-z0-9._-]+)`")
_FROM_SOURCE = re.compile(r"\bFrom (the [^`(,;.]+?) of (?:" + "|".join(issuedates.MONTHS) + r")\b")
_BY_USER = re.compile(r"\bRequested\b|\bThe user's wish\b")
_TRAIN = re.compile(r"\b[Tt]rain (\d{4}-\d{4})\b")
# The priority an item states: the audit's "P1 · Impact 4", the review's "suggested priority P1", or "(low priority)".
_PRIORITY = (
    (re.compile(r"\b(P[1-3]) · Impact\b"), None),
    (re.compile(r"\bpriority (P[1-3])\b"), None),
    (re.compile(r"\(low priority\)"), "P3"),
    (re.compile(r"\(high priority\)"), "P1"),
)
# The platform: a review item's "Platform: ..." sentence, or the iPhone named in the title or text.
_PLATFORM_SENTENCE = re.compile(r"\bPlatform: ([^.]*)")
_IPHONE = re.compile(r"\biPhone\b|\biOS\b|Platform/iOS")
_MAC = re.compile(r"\bMac\b|\bmacOS\b")
# What the first word of a "Platform:" sentence says: "Mac (the iPhone has no export)" is mac.
_PLATFORM_WORDS = {"both": "both", "iphone": "iphone", "ios": "iphone", "mac": "mac", "macos": "mac"}
# The docs a review item names: "Docs: `docs/user/x.md`, "Section": "a sentence"", or
# "Docs: as DR04" ("Docs and code: as DR24"). Each page runs to the next page it names.
_DOCS_PART = re.compile(r"\bDocs(?: and code)?: (.*?)(?:\bCode:|$)")
_DOCS_PAGE = re.compile(r"`((?:docs/[^`]+|README|ARCHITECTURE)\.md)`")
_DOCS_TITLE = re.compile(r'^, "([^"]+)"')
_DOCS_AS = re.compile(r"^as ([A-Z][A-Za-z0-9-]*)\b")
_QUOTE = re.compile(r'"([^"]{15,})"')
# The shortest piece of a quoted sentence worth looking for in a section.
_QUOTE_PIECE = 15
# Marks a quoted sentence's shortening, and the Markdown a doc's own words may carry.
_ELISION = re.compile(r"…|\.\.\.")
_MARKUP = re.compile(r"[*`_]")


@dataclass
class TodoEntry:
    """One open item of the TODO, or a run of ID-less rows that belong to another item.

    ``start`` and ``end`` are 1-based line numbers, inclusive. ``owner`` is the ID
    of the issue the entry goes into; ``rows`` is True for ID-less rows.
    """

    start: int
    end: int
    lines: List[str]
    section: str
    section_line: int
    owner: str = ""
    rows: bool = False


@dataclass
class Plan:
    """What the import will write: each issue's text and facts, and the TODO's new text."""

    issues: Dict[str, str] = field(default_factory=dict)
    facts: Dict[str, Dict[str, str]] = field(default_factory=dict)
    entries: List[TodoEntry] = field(default_factory=list)
    todo: str = ""
    moved_lines: int = 0


# ---------------------------------------------------------------------------
# Finding the open items.
# ---------------------------------------------------------------------------

def _item_end(lines: List[str], start: int) -> int:
    """The index of the last line of the item that starts at index ``start``.

    An item goes on over indented lines, over a blank line when the next text is
    indented (a paragraph of the item), and over a line at the margin that starts
    no block of its own (a lazy continuation of its paragraph).
    """
    end = start
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            following = next((n for n in range(index + 1, len(lines)) if lines[n].strip()), None)
            if following is None or not lines[following].startswith("  "):
                break
            index = following
            end = index
        elif line[0] in " \t" or (lines[index - 1].strip() and not _BLOCK_START.match(line)):
            end = index
        else:
            break
        index += 1
    return end


def find_entries(text: str) -> List[TodoEntry]:
    """The TODO's open items, in line order, with each run of ID-less rows joined into one entry."""
    lines = text.split("\n")
    entries: List[TodoEntry] = []
    section, section_line, fence = "", 0, ""
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.lstrip()
        if fence:
            if stripped.startswith(fence):
                fence = ""
            index += 1
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
            index += 1
            continue
        if line.startswith("## "):
            section, section_line = line[3:].strip(), index + 1
        if issueids.is_open_item(line):
            end = _item_end(lines, index)
            entry = TodoEntry(index + 1, end + 1, lines[index:end + 1], section, section_line)
            ids, _asides, _title = issueids.parse_opening(line[len("- [ ] **"):]) if line.startswith("- [ ] **") else ([], [], -1)
            if ids:
                if len(ids) > 1:
                    raise Refused(f"line {index + 1} opens with {len(ids)} IDs ({', '.join(ids)}); "
                                  "split it into one item per ID first")
                entry.owner = ids[0]
            else:
                entry.rows = True
                previous = entries[-1] if entries else None
                # Rows that follow each other in one section are one entry.
                if previous and previous.rows and previous.end == index and previous.section_line == section_line:
                    previous.end = end + 1
                    previous.lines.extend(lines[index:end + 1])
                    index = end + 1
                    continue
            entries.append(entry)
            index = end + 1
            continue
        index += 1
    return entries


def assign_rows(entries: List[TodoEntry]) -> None:
    """Give each run of ID-less rows the open item its section's heading names first; Refused when there is none."""
    open_ids = {entry.owner for entry in entries if not entry.rows}
    for entry in entries:
        if not entry.rows:
            continue
        named = [issue_id for issue_id in issueids.ids_in(entry.section) if issue_id in open_ids]
        if not named:
            raise Refused(f"the open item on line {entry.start} has no ID, and its section, \"{entry.section}\", "
                          "names no open item it could belong to; give it an ID first")
        entry.owner = named[0]


# ---------------------------------------------------------------------------
# Reading the facts.
# ---------------------------------------------------------------------------

def item_text(lines: List[str]) -> str:
    """An item's text as its issue's description holds it: no ``- [ ]``, continuation lines two columns left."""
    out = [lines[0][len("- [ ] "):] if lines[0].startswith("- [ ] ") else lines[0]]
    for line in lines[1:]:
        out.append(line[2:] if line.startswith("  ") else line.lstrip(" "))
    return "\n".join(out).rstrip()


def flat(text: str) -> str:
    """``text`` on one line, every run of white space one space."""
    return " ".join(text.split())


def title_of(text: str) -> str:
    """The title in an item's bold opening: after its IDs and dash, before the closing ``**``, without the last period."""
    body = flat(text)
    if not body.startswith("**"):
        return ""
    _ids, _asides, start = issueids.parse_opening(body[2:])
    end = body.find("**", 2 + max(start, 0))
    title = body[2 + max(start, 0): end if end >= 0 else len(body)].strip()
    return title[:-1].rstrip() if title.endswith(".") else title


def todo_year_and_date(todo: str) -> Tuple[int, str]:
    """The TODO's own year and date, from its "Audit date:" line (the clock's year and "" without one)."""
    found = _AUDIT_DATE.search(todo[:2000])
    match = issuedates.DATE_IN_WORDS.search(found.group(1)) if found else None
    if match and match.group(3):
        return int(match.group(3)), issuedates.iso_of(match, int(match.group(3)))
    return dt.date.today().year, ""


def created_of(title: str, opening: str, section: str, year: int, todo_date: str) -> str:
    """When an item was written: the first date in its title or opening, else its section's, else the TODO's."""
    for text in (title + " " + opening, section):
        match = issuedates.DATE_IN_WORDS.search(text)
        if match and issuedates.iso_of(match, year):
            return issuedates.iso_of(match, year)
    return todo_date


def found_by_of(opening: str, section: str, created: str) -> str:
    """Who found an item, by the patterns its opening uses, else from its section."""
    for pattern in (_BY_AGENT, _FROM_AGENT):
        match = pattern.search(opening)
        if match:
            return match.group(1)
    match = _FROM_SOURCE.search(opening)
    if match:
        return match.group(1).strip()
    if _BY_USER.search(opening):
        return "the user"
    match = _TRAIN.search(opening)
    if match:
        return f"train {match.group(1)}"
    if "(researched" in section:
        return f"the research of {created}"
    if "(planned" in section:
        return f"the plan of {created}"
    if _AUDIT_SECTION.match(section):
        return f"the code audit of {created}"
    return issuestore.ORCHESTRATOR


def priority_of(opening: str) -> str:
    """The priority an item's opening states, else P2."""
    for pattern, fixed in _PRIORITY:
        match = pattern.search(opening)
        if match:
            return fixed or match.group(1)
    return "P2"


def platform_of(title: str, text: str) -> str:
    """mac, iphone, or both: a "Platform:" sentence's first word, else the iPhone in the title, else in the text.

    Only the first word counts, since what follows explains it: "Mac (the iPhone
    has no export)" is mac, and "iPhone (a parity gap; the Mac has it)" iphone.
    """
    sentence = _PLATFORM_SENTENCE.search(text)
    words = sentence.group(1).split() if sentence else []
    first = words[0].strip(".,;:()").lower() if words else ""
    if first in _PLATFORM_WORDS:
        return _PLATFORM_WORDS[first]
    if _IPHONE.search(title):
        return "both" if _MAC.search(title) else "iphone"
    return "both" if _IPHONE.search(text) else "mac"


def kind_of(issue_id: str, opening: str) -> str:
    """An item's kind: a test when the audit marks it Manual, else by its ID's family."""
    if _MANUAL.search(opening):
        return "test"
    numbered = issueids.family_number(issue_id)
    family = numbered[0] if numbered else issue_id.split("-")[0]
    return KIND_OF_FAMILY.get(family, "feature")


def _plain(text: str) -> str:
    """Words to compare a quote with a doc by: no Markdown marks, white space as single spaces, lowercase."""
    return flat(_MARKUP.sub("", text)).lower()


def _section_texts(root: Path, sections: List[issuestore.DocSection], page: str) -> List[Tuple[str, str]]:
    """Each marked section of ``page`` with its own lines' plain words, as (id, words)."""
    path = root / page
    if not path.is_file():
        return []
    lines = path.read_text(encoding="utf-8").split("\n")
    return [(section.section_id, _plain("\n".join(lines[section.start - 1:section.end])))
            for section in sections if section.path == page]


def docs_of(text: str, store: Store, earlier: Dict[str, Dict[str, str]]) -> List[str]:
    """The doc sections a review item names in its "Docs:" part.

    "as DR04" takes DR04's. A page followed by a section's title takes that
    section, and every section on that page that holds a piece of a sentence the
    item quotes from it (a quote may be shortened with an ellipsis), since one
    limitation can be stated in more than one section.
    """
    part = _DOCS_PART.search(flat(text))
    if part is None:
        return []
    docs = part.group(1)
    same = _DOCS_AS.match(docs)
    if same:
        return issuefile.split_list(earlier.get(same.group(1), {}).get("docs", ""))
    sections = store.doc_sections()
    found: List[str] = []
    pages = list(_DOCS_PAGE.finditer(docs))
    for number, page in enumerate(pages):
        rest = docs[page.end(): pages[number + 1].start() if number + 1 < len(pages) else len(docs)]
        title = _DOCS_TITLE.match(rest)
        chosen = [s.section_id for s in sections if title and s.path == page.group(1) and s.title == title.group(1)]
        # The quoted sentences after the title. A piece ends where the quote was cut,
        # so its last mark may differ from the doc's.
        quotes = _QUOTE.findall(rest[title.end():] if title else rest)
        pieces = [_plain(piece).rstrip(".,;:!? ") for quote in quotes for piece in _ELISION.split(quote)]
        pieces = [piece for piece in pieces if len(piece) >= _QUOTE_PIECE]
        chosen += [section_id for section_id, words in _section_texts(store.root, sections, page.group(1))
                   if section_id not in chosen and any(piece in words for piece in pieces)]
        found.extend(section_id for section_id in chosen if section_id not in found)
    return found


def related_of(issue_id: str, text: str, created: str, known: set, renamed: Dict[str, Tuple[str, str]]) -> List[str]:
    """The IDs an item names that something holds, itself left out, in the order it names them.

    ``renamed`` maps an ID given twice to (its alias, the date its newer item was
    written): a text written before that date means the older item, its alias.
    """
    related: List[str] = []
    for named in issueids.ids_in(text):
        if named == issue_id or named not in known:
            continue
        if named in renamed and created < renamed[named][1]:
            named = renamed[named][0]
        if named not in related and named != issue_id:
            related.append(named)
    return related


def renamed_ids(store: Store, year: int, todo_date: str) -> Dict[str, Tuple[str, str]]:
    """Each ID given twice, with the alias of its older item and the date its newer item was written."""
    lines = store.todo_text().split("\n")
    aliased: Dict[str, str] = {}
    newest: Dict[str, str] = {}
    for item in store.todo_items():
        if not item.in_backlog or item.pointer or len(item.ids) != 1:
            continue
        if item.aliases:
            aliased[item.ids[0]] = next(iter(item.aliases))
            continue
        line = lines[item.line - 1]
        written = created_of(title_of(line[6:]), flat(line)[:_OPENING_CHARS + 200], item.section, year, todo_date)
        newest[item.ids[0]] = max(newest.get(item.ids[0], ""), written)
    return {issue_id: (alias, newest[issue_id]) for issue_id, alias in aliased.items() if issue_id in newest}


# ---------------------------------------------------------------------------
# Building the plan, checking it, and writing it.
# ---------------------------------------------------------------------------

def _relate(facts: Dict[str, str], issue_id: str) -> None:
    """Add ``issue_id`` to the end of an issue's related IDs, once."""
    related = issuefile.split_list(facts["related"])
    if issue_id not in related:
        facts["related"] = issuefile.join_list(related + [issue_id])


def rows_text(entry: TodoEntry, todo_lines: List[str]) -> str:
    """ID-less rows as their owner's description holds them: the section's title, its opening paragraphs, the rows."""
    intro: List[str] = []
    for line in todo_lines[entry.section_line:entry.start - 1]:
        if line.startswith("- "):
            break
        intro.append(line)
    paragraphs = "\n".join(intro).strip("\n")
    parts = [f"### {entry.section}"] + ([paragraphs] if paragraphs else []) + ["\n".join(entry.lines).rstrip()]
    return "\n\n".join(parts)


def words(text: str) -> List[str]:
    """``text`` as words, for the proof that nothing was lost."""
    return text.split()


def holds_in_order(haystack: List[str], needle: List[str]) -> bool:
    """Whether every word of ``needle`` appears in ``haystack`` in the same order."""
    position = 0
    for word in needle:
        try:
            position = haystack.index(word, position) + 1
        except ValueError:
            return False
    return True


def plan_import(store: Store, as_name: str) -> Plan:
    """Everything the import would write; Refused when an item cannot be moved, or its words would not all arrive."""
    if not issuefile.is_agent_name(as_name):
        raise UsageError(f"--as {as_name!r} is not a name")
    todo = store.todo_text()
    if not todo:
        raise UsageError(f"there is no {store.todo_path.name} to import from")
    todo_lines = todo.split("\n")
    entries = find_entries(todo)
    assign_rows(entries)
    year, todo_date = todo_year_and_date(todo)
    known = store.known_ids()
    renamed = renamed_ids(store, year, todo_date)
    today = store.today()
    plan = Plan(entries=entries)
    descriptions: Dict[str, List[str]] = {}
    spans: Dict[str, List[Tuple[int, int]]] = {}
    for entry in entries:
        if entry.rows:
            continue
        issue_id = entry.owner
        if store.path_of(issue_id).exists() or issue_id in plan.facts:
            raise Refused(f"{issue_id} (line {entry.start}) has an issue file already, or two open items")
        text = item_text(entry.lines)
        title = title_of(text)
        if not title:
            raise Refused(f"the item on line {entry.start} has no title in its bold opening")
        body = flat(text)
        bold_end = body.find("**", 2)
        # The text just after the bold opening, where the TODO says who found an item and when.
        opening = body[bold_end + 2:][:_OPENING_CHARS] if bold_end >= 0 else body[:_OPENING_CHARS]
        created = created_of(title, opening, entry.section, year, todo_date) or today
        plan.facts[issue_id] = {
            "id": issue_id, "title": title, "kind": kind_of(issue_id, opening),
            "priority": priority_of(body[:_HEAD_CHARS]), "platform": platform_of(title, body),
            "created": created, "found_by": found_by_of(opening, entry.section, created),
            "related": issuefile.join_list(related_of(issue_id, body, created, known, renamed)),
            "labels": MANUAL_LABEL if _MANUAL.search(opening) else "",
        }
        spans[issue_id] = [(entry.start, entry.end)]
        plan.facts[issue_id]["docs"] = issuefile.join_list(docs_of(text, store, plan.facts))
        descriptions[issue_id] = [text]
    for entry in entries:
        if entry.rows:
            descriptions[entry.owner].append(rows_text(entry, todo_lines))
            spans[entry.owner].append((entry.start, entry.end))
            # The other open items the rows' section names share them ("for A01/P09/Q05"),
            # so each and the owner name one another, and closing one does not hide the rows.
            for other in issueids.ids_in(entry.section):
                if other != entry.owner and other in plan.facts:
                    _relate(plan.facts[entry.owner], other)
                    _relate(plan.facts[other], entry.owner)
    for issue_id, facts in plan.facts.items():
        facts["lines"] = spans_text(spans[issue_id])
    template = store.template()
    for issue_id, facts in plan.facts.items():
        description = "\n\n".join(descriptions[issue_id])
        for line in description.split("\n"):
            if line in (issuefile.DESCRIPTION_HEADING, issuefile.COMMENTS_HEADING):
                raise Refused(f"{issue_id}'s text holds a line {line!r}, which would end its description")
        values = {"id": issue_id, "title": facts["title"], "kind": facts["kind"], "priority": facts["priority"],
                  "platform": facts["platform"], "today": facts["created"], "found_by": facts["found_by"],
                  "related": facts["related"], "docs": facts["docs"], "labels": facts["labels"],
                  "description": description}
        path = store.path_of(issue_id)
        try:
            text = issuefile.fill_template(template, store.relative(path), values)
            # Updated today, and a comment by the importer saying where the text came from.
            issue = issuefile.parse(store.relative(path), text)
            text = issuefile.with_fields(issue, {"updated": max(today, facts["created"])})
            note = (f"Moved from {store.todo_path.name}, {facts['lines']} of the version this import "
                    f"read, where it was an open item; the description is its text as it was.")
            text = issuefile.with_comment(issuefile.parse(store.relative(path), text), today, as_name, note)
        except issuefile.IssueFormatError as error:
            raise Refused(f"{issue_id}: {error}") from None
        plan.issues[issue_id] = text
    plan.todo = _rewritten_todo(todo_lines, entries)
    plan.moved_lines = sum(entry.end - entry.start + 1 for entry in entries)
    _prove(plan, store)
    return plan


def spans_text(spans: List[Tuple[int, int]]) -> str:
    """Line spans as words: "line 5433", "lines 5005 to 5012", "line 4908 and lines 5005 to 5012"."""
    parts = [f"line {start}" if start == end else f"lines {start} to {end}" for start, end in spans]
    return issuestore.and_list(parts)


def _rewritten_todo(lines: List[str], entries: List[TodoEntry]) -> str:
    """The TODO with each entry's lines made one pointer line, every other line as it was."""
    out: List[str] = []
    by_start = {entry.start: entry for entry in entries}
    index = 1
    while index <= len(lines):
        entry = by_start.get(index)
        if entry is None:
            out.append(lines[index - 1])
            index += 1
            continue
        out.append(issueids.pointer_line(entry.owner))
        index = entry.end + 1
    return "\n".join(out)


def _prove(plan: Plan, store: Store) -> None:
    """Refuse the plan unless each entry's words are in order in its issue's description, and the TODO lost only them."""
    for entry in plan.entries:
        issue = issuefile.parse("x", plan.issues[entry.owner])
        wanted = words(item_text(entry.lines))
        if not holds_in_order(words(issue.description), wanted):
            raise Refused(f"the words of the item on line {entry.start} would not all reach {entry.owner}'s file")
    original = store.todo_text().split("\n")
    moved = {number for entry in plan.entries for number in range(entry.start, entry.end + 1)}
    kept = [line for line in plan.todo.split("\n") if not issueids.POINTER.match(line)]
    expected = [line for number, line in enumerate(original, 1) if number not in moved and not issueids.POINTER.match(line)]
    if kept != expected:
        raise Refused("the TODO would change beyond the moved items' lines")


def cmd_import(store: Store, args: Any) -> int:
    """``import-todo``: plan the move, prove it, and (unless --dry-run) write the issue files and the TODO."""
    plan = plan_import(store, args.as_name)
    for issue_id, facts in plan.facts.items():
        line = (f"{store.relative(store.path_of(issue_id))}: {issue_id}, {facts['kind']}, {facts['priority']}, "
                f"{facts['platform']}, found by {facts['found_by']} on {facts['created']}")
        extras = [f"related {facts['related']}" if facts["related"] else "",
                  f"docs {facts['docs']}" if facts["docs"] else "",
                  f"labels {facts['labels']}" if facts["labels"] else "", f"TODO {facts['lines']}"]
        print(f"issuelib: {line}" + "".join(f"; {extra}" for extra in extras if extra))
    print(f"issuelib: {store.todo_path.name}: {len(plan.entries)} open entries, {plan.moved_lines} lines, "
          f"made {len(plan.entries)} pointer lines; {len(plan.issues)} issue files"
          + (" (dry run: nothing written)" if args.dry_run else ""))
    if args.dry_run:
        return 0
    for issue_id, text in plan.issues.items():
        path = store.path_of(issue_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    store.todo_path.write_text(plan.todo, encoding="utf-8")
    return 0


def register(add: Any) -> None:
    """Add the ``import-todo`` subcommand through issuelib's ``add``."""
    sub = add("import-todo", cmd_import, "move the TODO's open items into issue files (once)", writes=True)
    sub.add_argument("--dry-run", action="store_true", help="print what would be written, and write nothing")
