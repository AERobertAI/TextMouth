"""Tests of record-merge.py: the merge record it writes in the TODO, --tick, and --close.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test writes a small TODO (with the anchors the script looks for) and, for
--close, an issue file, in a temporary folder of its own, and runs the real script
on them as a process, with "today" fixed through ISSUELIB_TODAY. No test reads or
writes the real TODO or the real Issues/ folder, and none runs git in a repository.
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The script under test, beside this tests folder.
SCRIPT = Path(__file__).resolve().parent.parent / "record-merge.py"

# A TODO with the script's anchors, an open entry for --tick, and a pointer line for --close.
TODO = """\
# TODO

## Completed fixes

- [x] **An older merge.** Merged 1234567.

**Open follow-ups noted by the September 28 agents** were handled.

## Verification record

- Baseline. After the first merge: **10 tests, 0 skipped, 0 failures**.

**Open follow-ups noted on October 3 afternoon and evening**: none yet.

## Bugs

- [ ] **FR09 — A wish of the user's.** Requested October 3.
- [ ] **B16** moved to Issues/B16.md
"""

# An open issue file, as issuelib writes one.
B16 = """\
---
id: B16
title: A test bug
kind: bug
status: in-progress
priority: P2
platform: mac
assignee: floatrender
created: 2026-11-16
updated: 2026-11-16
found-by: orchestrator
branch: fix/float64-render
merged:
reason:
related:
docs:
labels:
---

## Description

What is wrong.

## Comments
"""

ENTRY = "- [x] **B16 — the fix.** Merged 6b09b2ee2 (`fix/float64-render`).\n"
COUNTS = "After the B16 merge: **12 tests, 0 skipped, 0 failures**."


class RecordMergeCase(unittest.TestCase):
    """A temporary folder holding the TODO above, B16's issue file, and the merge entry."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="record-merge-test-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name).resolve()
        (self.root / "Issues").mkdir()
        self.todo = self.root / "TODO-2026-09-04.md"
        self.todo.write_text(TODO, encoding="utf-8")
        self.issue = self.root / "Issues" / "B16.md"
        self.issue.write_text(B16, encoding="utf-8")
        self.entry = self.root / "entry.md"
        self.entry.write_text(ENTRY, encoding="utf-8")

    def record(self, *extra, today="2026-11-17"):
        """Run record-merge.py on the folder's TODO with the entry and counts, plus ``extra``."""
        env = dict(os.environ, ISSUELIB_TODAY=today)
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--todo", str(self.todo),
                               "--entry", str(self.entry), "--counts", COUNTS, *extra],
                              capture_output=True, text=True, env=env, cwd=self.root, timeout=60)

    def assert_nothing_written(self, result):
        """The run failed and left the TODO and the issue file as they were."""
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("nothing written", result.stderr)
        self.assertEqual(self.todo.read_text(encoding="utf-8"), TODO)
        self.assertEqual(self.issue.read_text(encoding="utf-8"), B16)


class RecordTests(RecordMergeCase):
    """The record and --tick, as before --close."""

    def test_the_entry_and_counts_go_where_the_anchors_say(self):
        result = self.record()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.todo.read_text(encoding="utf-8")
        self.assertIn("- [x] **An older merge.** Merged 1234567.\n\n" + ENTRY + "\n**Open follow-ups noted by the September 28", text)
        self.assertIn("**10 tests, 0 skipped, 0 failures**. " + COUNTS + "\n", text)
        self.assertEqual(result.stdout, "record-merge: recorded in TODO-2026-09-04.md\n")

    def test_tick_still_marks_an_entry_left_in_the_todo(self):
        result = self.record("--tick", "FR09", "--hash", "6b09b2ee2", "--date", "November 16")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("- [x] **FR09 — A wish of the user's.** Merged 6b09b2ee2, November 16 (see the merge entry above). "
                      "Requested October 3.\n", self.todo.read_text(encoding="utf-8"))
        # Without --date it writes the date it always has.
        self.todo.write_text(TODO, encoding="utf-8")
        self.record("--tick", "FR09", "--hash", "6b09b2ee2")
        self.assertIn("Merged 6b09b2ee2, October 7 (see", self.todo.read_text(encoding="utf-8"))

    def test_tick_does_not_take_a_pointer_line(self):
        result = self.record("--tick", "B16", "--hash", "6b09b2ee2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected one open entry for B16, found 0", result.stderr)


class CloseTests(RecordMergeCase):
    """--close: the issue file closed at the merge, and its pointer ticked, or nothing written."""

    def test_close_marks_the_issue_done_with_the_merge_and_ticks_its_pointer(self):
        result = self.record("--close", "B16", "--hash", "6b09b2ee2", "--date", "November 16")
        self.assertEqual(result.returncode, 0, result.stderr)
        issue = self.issue.read_text(encoding="utf-8")
        self.assertEqual(issue, B16.replace("status: in-progress", "status: done").replace("merged:\n", "merged: 6b09b2ee2\n")
                         + "\n### 2026-11-16, orchestrator, 1 line\n\nClosed as done: merged in 6b09b2ee2.\n")
        text = self.todo.read_text(encoding="utf-8")
        self.assertIn("- [x] **B16** moved to Issues/B16.md\n", text)
        self.assertIn(ENTRY, text)
        self.assertEqual(result.stdout, "record-merge: recorded in TODO-2026-09-04.md; "
                                        "Issues/B16.md: closed as done, merged 6b09b2ee2, on 2026-11-16\n")

    def test_the_date_may_be_written_three_ways_and_defaults_to_today(self):
        cases = [("2026-11-18", "2026-11-18"), ("November 18, 2026", "2026-11-18"), ("November 18", "2026-11-18"), (None, "2026-11-20")]
        for given, expected in cases:
            with self.subTest(given=given):
                self.issue.write_text(B16, encoding="utf-8")
                self.todo.write_text(TODO, encoding="utf-8")
                extra = ["--date", given] if given else []
                result = self.record("--close", "B16", "--hash", "6b09b2ee2", *extra, today="2026-11-20")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"updated: {expected}\n", self.issue.read_text(encoding="utf-8"))

    def test_a_merge_dated_before_the_issue_was_filed_is_refused(self):
        result = self.record("--close", "B16", "--hash", "6b09b2ee2", "--date", "November 15")
        self.assert_nothing_written(result)
        self.assertIn("updated 2026-11-15 comes before created 2026-11-16", result.stderr)

    def test_a_date_without_a_year_ahead_of_today_is_last_years(self):
        result = self.record("--close", "B16", "--hash", "6b09b2ee2", "--date", "December 31", today="2027-01-01")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### 2026-12-31, orchestrator", self.issue.read_text(encoding="utf-8"))

    def test_what_cannot_close_writes_nothing(self):
        cases = {
            "no hash": (["--close", "B16"], "--close needs --hash"),
            "no such issue": (["--close", "B99", "--hash", "6b09b2ee2"], "B99 has no file in Issues/"),
            "a bad date": (["--close", "B16", "--hash", "6b09b2ee2", "--date", "16 November"], "is not a date"),
            "a bad hash": (["--close", "B16", "--hash", "XYZ"], "is not a commit"),
            "twice": (["--close", "B16", "--close", "B16", "--hash", "6b09b2ee2"], "names an issue twice"),
        }
        for name, (extra, message) in cases.items():
            with self.subTest(name):
                result = self.record(*extra)
                self.assert_nothing_written(result)
                self.assertIn(message, result.stderr)

    def test_an_issue_closed_already_stops_the_whole_record(self):
        done = B16.replace("status: in-progress", "status: done").replace("merged:\n", "merged: 1234567\n")
        self.issue.write_text(done, encoding="utf-8")
        result = self.record("--close", "B16", "--hash", "6b09b2ee2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("B16 is done already", result.stderr)
        self.assertEqual(self.todo.read_text(encoding="utf-8"), TODO)
        self.assertEqual(self.issue.read_text(encoding="utf-8"), done)

    def test_an_issue_with_no_pointer_line_is_closed_and_said_so(self):
        self.todo.write_text(TODO.replace("- [ ] **B16** moved to Issues/B16.md\n", ""), encoding="utf-8")
        result = self.record("--close", "B16", "--hash", "6b09b2ee2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1],
                         "record-merge: B16 has no pointer line in TODO-2026-09-04.md, so only its issue file changed")
        self.assertIn("status: done\n", self.issue.read_text(encoding="utf-8"))

    def test_close_names_the_doc_sections_that_cite_the_issue(self):
        page = self.root / "docs" / "user" / "x.md"
        page.parent.mkdir(parents=True)
        page.write_text("# X\n<!-- id: x-top; status: incomplete; issues: B16 -->\n\nNot yet.\n", encoding="utf-8")
        result = self.record("--close", "B16", "--hash", "6b09b2ee2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1],
                         "record-merge: docs/user/x.md:1 (x-top, status incomplete) cites B16: the next docs pass "
                         "updates that section (doclib check lists it)")

    def test_two_issues_close_at_one_merge(self):
        (self.root / "Issues" / "B17.md").write_text(B16.replace("id: B16", "id: B17"), encoding="utf-8")
        result = self.record("--close", "B16", "--close", "B17", "--hash", "6b09b2ee2")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("B16.md", "B17.md"):
            self.assertIn("status: done\n", (self.root / "Issues" / name).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
