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

Every anchor must be found exactly where expected, or nothing is written.

Usage:
  record-merge.py --entry ENTRY.md --counts "After the reading-list merge: **4700 tests, 56 skipped, 0 failures**."
                  [--followups FOLLOWUPS.txt] [--tick FR09 --hash 1a2b3c4d --date "October 7"]
                  [--todo PATH]
  record-merge.py --entry ENTRY.md --note "The October 7 documentation pass changed only README.md and ARCHITECTURE.md."
"""
import argparse
import re
import sys
from pathlib import Path

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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--todo", default=str(Path(__file__).resolve().parents[2] / "TODO-2026-09-04.md"))
    parser.add_argument("--entry", required=True, help="file holding the merge's '- [x]' entry")
    sentence = parser.add_mutually_exclusive_group(required=True)
    sentence.add_argument("--counts", help="the counts sentence")
    sentence.add_argument("--note", help="a plain sentence, for a merge that ran no suite")
    parser.add_argument("--followups", help="file holding sentences for the open follow-ups paragraph")
    parser.add_argument("--tick", help="a feature or bug entry to tick, such as FR09")
    parser.add_argument("--hash", help="the merge commit, with --tick")
    parser.add_argument("--date", default="October 7", help="the merge's date, with --tick")
    args = parser.parse_args()

    if args.counts is not None and not COUNTS_PATTERN.search(args.counts):
        fail("the counts sentence must read 'After the ... merge: **N tests, S skipped, F failures**'")
    if args.tick and not args.hash:
        fail("--tick needs --hash")

    path = Path(args.todo)
    text = path.read_text(encoding="utf-8")
    text = insert_entry(text, Path(args.entry).read_text(encoding="utf-8"))
    text = insert_counts(text, args.counts if args.counts is not None else args.note)
    if args.followups:
        text = append_followups(text, Path(args.followups).read_text(encoding="utf-8"))
    if args.tick:
        text = tick(text, args.tick, args.hash, args.date)
    path.write_text(text, encoding="utf-8")
    print(f"record-merge: recorded in {path.name}" + (f"; ticked {args.tick}" if args.tick else ""))


if __name__ == "__main__":
    main()
