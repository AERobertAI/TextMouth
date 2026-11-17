#!/usr/bin/env python3
"""Record one merge in TODO-2026-09-04.md, making the edits AGENTS.md names.

1. The merge's `- [x]` entry goes before the paragraph that begins
   "**Open follow-ups noted by the September 28 agents**".
2. A sentence with the suite's exact counts ("After the X merge: **N tests,
   S skipped, 0 failures**.") goes after the last such sentence of the long
   verification paragraph; a merge that ran no suite (a Markdown-only
   documentation pass) gives a plain sentence with --note instead, which
   goes in the same place.
3. Optional: open items found by the branch are appended to the paragraph
   that begins "**Open follow-ups noted on October 3 afternoon and evening**".
4. Optional: a feature request or bug entry (FR09, B01, ...) is ticked and
   given "Merged <hash>, <date> (see the merge entry above)."
5. Optional: an issue file (Issues/B16.md) is closed as done, merged <hash> on
   the merge's date, with a comment that says so, and its pointer line in the
   TODO ("- [ ] **B16** moved to Issues/B16.md") is ticked. --close may be
   given more than once. The issue-library skill makes the change, so its
   rules hold: the issue must be open, and the change is the orchestrator's.

Every anchor must be found exactly where expected, and every issue must close,
or nothing is written.

Usage:
  record-merge.py --entry ENTRY.md --counts "After the reading-list merge: **4700 tests, 56 skipped, 0 failures**."
                  [--followups FOLLOWUPS.txt] [--tick FR09 --hash 1a2b3c4d --date "October 7"]
                  [--close B16 --hash 1a2b3c4d --date "November 16"] [--todo PATH]
  record-merge.py --entry ENTRY.md --note "The October 7 documentation pass changed only README.md and ARCHITECTURE.md."
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

# No bytecode beside the issue-library skill, whose modules --close imports by path.
sys.dont_write_bytecode = True
# The issue-library skill's scripts, in the same checkout as this script.
ISSUE_SCRIPTS = Path(__file__).resolve().parents[2] / ".claude" / "skills" / "issue-library" / "scripts"
# The date --tick writes when --date is not given, as it always has.
TICK_DATE = "October 7"

ENTRY_ANCHOR = "**Open follow-ups noted by the September 28 agents**"
FOLLOWUPS_ANCHOR = "**Open follow-ups noted on October 3 afternoon and evening**"
# A counts sentence: "After the <something> merge<anything but a bold mark>: **N tests"
COUNTS_PATTERN = re.compile(r"After the [^*]*?merge[^*]*?: \*\*\d+ tests[^*]*\*\*")


def fail(message):
    """Stop without writing anything."""
    print(f"record-merge: {message}; nothing written", file=sys.stderr)
    sys.exit(1)


def sentence_end(text, start):
    """Index just past the period that ends the sentence running from `start`.

    A period inside parentheses (a note on the run) does not end it; the
    sentence ends at the first period outside them that is followed by a
    space, a newline, or the end of the text.
    """
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth = max(0, depth - 1)
        elif char == "." and depth == 0:
            following = text[index + 1:index + 2]
            if following in ("", " ", "\n"):
                return index + 1
    fail("the last counts sentence has no end")


def insert_entry(text, entry):
    """Put the merge entry, a paragraph of its own, just before the anchor.

    The anchor paragraph starts a line after a blank one, so the entry lands
    after the last entry's blank line and gets a blank line of its own.
    """
    position = text.find("\n" + ENTRY_ANCHOR)
    if position < 0:
        fail("the September 28 follow-ups paragraph was not found")
    anchor_start = position + 1
    return text[:anchor_start] + entry.strip("\n") + "\n\n" + text[anchor_start:]


def insert_counts(text, sentence):
    """Put the counts sentence after the last counts sentence."""
    matches = list(COUNTS_PATTERN.finditer(text))
    if not matches:
        fail("no 'After the ... merge: **N tests' sentence was found")
    end = sentence_end(text, matches[-1].start())
    return text[:end] + " " + sentence.strip() + text[end:]


def append_followups(text, followups):
    """Append to the end of the October 3 afternoon follow-ups paragraph."""
    start = text.find(FOLLOWUPS_ANCHOR)
    if start < 0:
        fail("the October 3 afternoon follow-ups paragraph was not found")
    end = text.find("\n\n", start)
    if end < 0:
        fail("the October 3 afternoon follow-ups paragraph has no end")
    return text[:end] + "\n" + followups.strip() + text[end:]


def tick(text, item, merge_hash, date):
    """Tick the feature or bug entry `item` and say where it was merged."""
    pattern = re.compile(r"^- \[ \] (\*\*" + re.escape(item) + r" — .*?\*\*)", re.MULTILINE)
    found = list(pattern.finditer(text))
    if len(found) != 1:
        fail(f"expected one open entry for {item}, found {len(found)}")
    replacement = f"- [x] \\1 Merged {merge_hash}, {date} (see the merge entry above)."
    return pattern.sub(replacement, text, count=1)


def issue_library():
    """The issue-library skill's issuestore module, found by path; fail when this checkout has none."""
    if not (ISSUE_SCRIPTS / "issuestore.py").is_file():
        fail(f"--close needs the issue-library skill, and {ISSUE_SCRIPTS} is missing")
    if str(ISSUE_SCRIPTS) not in sys.path:
        sys.path.insert(1, str(ISSUE_SCRIPTS))
    import issuestore  # noqa: E402  (the skill's own module, found by path)
    return issuestore


def iso_date(text, today):
    """The merge's date as YYYY-MM-DD, from "2026-11-16", "November 16, 2026", or "November 16" (issuedates.py)."""
    import issuedates  # noqa: E402  (the issue-library skill's, on the path once issue_library() ran)
    date = issuedates.parse_date(text, today)
    if date is None:
        fail(f"--date {text!r} is not a date: write 2026-11-16, November 16, 2026, or November 16")
    return date


def close_issues(text, todo_path, issues, merge_hash, date_text):
    """Close each issue at the merge, and tick its pointer lines in `text`.

    Returns the TODO's new text, the issue files' changes, and the lines to print
    (one for an issue that has no pointer line, and one for each doc section that
    cites a closed issue, for the next docs pass), written by the caller only once
    everything has passed; fails on the first issue that cannot close (missing,
    closed already, or a file the skill refuses to change).
    """
    issuestore = issue_library()
    store = issuestore.Store(todo_path.resolve().parent, todo=todo_path.resolve())
    try:
        today = datetime.date.fromisoformat(store.today())
        date = iso_date(date_text, today) if date_text is not None else today.isoformat()
        changes = [issuestore.close(store, issue_id, issuestore.ORCHESTRATOR, merged=merge_hash, date=date)
                   for issue_id in issues]
    except (issuestore.UsageError, issuestore.Refused) as error:
        fail(f"--close: {error}")
    notes = []
    for issue_id in issues:
        text, count = issuestore.issueids.set_pointers(text, issue_id, closed=True)
        if not count:
            notes.append(f"{issue_id} has no pointer line in {todo_path.name}, so only its issue file changed")
        notes.extend(issuestore.citing_notes(store, issue_id))
    return text, changes, notes


def main():
    """Read the command line, make every edit in memory, check them all, and only then write the TODO and the issues."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--todo", default=str(Path(__file__).resolve().parents[2] / "TODO-2026-09-04.md"))
    parser.add_argument("--entry", required=True, help="file holding the merge's '- [x]' entry")
    sentence = parser.add_mutually_exclusive_group(required=True)
    sentence.add_argument("--counts", help="the counts sentence")
    sentence.add_argument("--note", help="a plain sentence, for a merge that ran no suite")
    parser.add_argument("--followups", help="file holding sentences for the open follow-ups paragraph")
    parser.add_argument("--tick", help="a feature or bug entry to tick, such as FR09")
    parser.add_argument("--close", action="append", default=[], metavar="ID",
                        help="an issue file (Issues/ID.md) to close at this merge; more than one may be given")
    parser.add_argument("--hash", help="the merge commit, with --tick or --close")
    parser.add_argument("--date", default=None,
                        help=f"the merge's date: with --tick as the TODO writes it (default {TICK_DATE}); "
                             "with --close 2026-11-16 or November 16 (default today)")
    args = parser.parse_args()

    if args.counts is not None and not COUNTS_PATTERN.search(args.counts):
        fail("the counts sentence must read 'After the ... merge: **N tests, S skipped, F failures**'")
    if args.tick and not args.hash:
        fail("--tick needs --hash")
    if args.close and not args.hash:
        fail("--close needs --hash")
    if len(set(args.close)) != len(args.close):
        fail("--close names an issue twice")

    path = Path(args.todo)
    text = path.read_text(encoding="utf-8")
    text = insert_entry(text, Path(args.entry).read_text(encoding="utf-8"))
    text = insert_counts(text, args.counts if args.counts is not None else args.note)
    if args.followups:
        text = append_followups(text, Path(args.followups).read_text(encoding="utf-8"))
    if args.tick:
        text = tick(text, args.tick, args.hash, args.date if args.date is not None else TICK_DATE)
    changes, notes = [], []
    if args.close:
        text, changes, notes = close_issues(text, path, args.close, args.hash, args.date)
    path.write_text(text, encoding="utf-8")
    for change in changes:
        change.path.write_text(change.text, encoding="utf-8")
    print(f"record-merge: recorded in {path.name}" + (f"; ticked {args.tick}" if args.tick else "")
          + "".join(f"; {change.message}" for change in changes))
    for note in notes:
        print(f"record-merge: {note}")


if __name__ == "__main__":
    main()
