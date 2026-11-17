"""Tests of issuefile: reading an issue file, checking its values, and building its new text."""

from __future__ import annotations

import unittest

from issuelib_case import B16, TEMPLATE
import issuefile
from issuefile import IssueFormatError


def messages(problems) -> list:
    """The problems' messages, for a readable comparison."""
    return [problem.message for problem in problems]


class ParseTests(unittest.TestCase):
    """parse: the header, the description, and the comments."""

    def test_a_valid_file_reads_whole(self) -> None:
        issue = issuefile.parse("Issues/B16.md", B16 + "\n### 2026-11-16, floatrender\n\nFirst.\n\nSecond paragraph.\n")
        self.assertEqual(issue.problems, [])
        self.assertEqual(issuefile.check_values(issue), [])
        self.assertEqual(issue.issue_id, "B16")
        self.assertEqual(issue.value("title"), "A test bug")
        self.assertEqual(issue.values("related"), ["B12"])
        self.assertEqual(issue.value("assignee"), "")
        self.assertEqual(issue.description, "What is wrong.")
        self.assertEqual([(c.date, c.author, c.text) for c in issue.comments],
                         [("2026-11-16", "floatrender", "First.\n\nSecond paragraph.")])
        self.assertEqual(issue.field_lines["labels"], 17)

    def test_a_value_may_hold_colons(self) -> None:
        issue = issuefile.parse("x", B16.replace("title: A test bug", "title: Speak Info: the selection"))
        self.assertEqual(issue.value("title"), "Speak Info: the selection")

    def test_a_field_given_twice_is_reported_with_both_lines(self) -> None:
        # A header holding one field twice, as a union merge of two branches once left one.
        text = B16.replace("status: open\n", "status: in-progress\nstatus: blocked\n")
        issue = issuefile.parse("Issues/B16.md", text)
        self.assertEqual(messages(issue.problems),
                         ["field status given twice, here and on line 5 (a merge kept both sides' lines; keep the right one)"])
        self.assertEqual(issue.problems[0].line, 6)
        self.assertEqual(issue.value("status"), "in-progress")

    def test_broken_layouts_are_problems(self) -> None:
        cases = {
            "no header": ("id: B16\n", "the file must open with a header"),
            "no closing fence": ("---\nid: B16\n", "no closing line"),
            "unknown field": (B16.replace("labels: audio", "labels: audio\ncolour: red"), "unknown field 'colour'"),
            "line without colon": (B16.replace("labels: audio", "labels audio"), "a header line must read"),
            "no description": (B16.replace("## Description", "## About"), "no '## Description' heading"),
            "no comments": (B16.replace("## Comments", ""), "no '## Comments' heading"),
            "stray heading": (B16 + "\n## Notes\n", "a heading must be a comment's"),
            "bad comment heading": (B16 + "\n### November 16, floatrender\n\nText.\n", "a heading must be a comment's"),
            "text before comments": (B16 + "\nLoose text.\n", "text after '## Comments' before its first comment"),
            "impossible date": (B16 + "\n### 2026-02-30, x\n\nText.\n", "is not a real date"),
        }
        for name, (text, expected) in cases.items():
            with self.subTest(name):
                found = messages(issuefile.parse("x", text).problems)
                self.assertTrue(any(expected in message for message in found), f"{name}: {found}")

    def test_a_heading_gives_its_line_count(self) -> None:
        issue = issuefile.parse("x", B16 + "\n### 2026-11-16, floatrender, 3 lines\n\nOne.\n\nThree.\n"
                                           "\n### 2026-11-17, the user\n\nNo count.\n")
        self.assertEqual(issue.problems, [])
        self.assertEqual([(c.author, c.count) for c in issue.comments], [("floatrender", 3), ("the user", None)])
        self.assertEqual(issuefile.comment_heading("2026-11-16", "x", "One."), "### 2026-11-16, x, 1 line")
        self.assertEqual(issuefile.comment_heading("2026-11-16", "x", "One.\n\nThree."), "### 2026-11-16, x, 3 lines")
        self.assertEqual(messages(issuefile.check_comments(issue)),
                         ["the heading gives no line count: '### 2026-11-17, the user, 1 line'"])

    def test_headings_in_fenced_code_are_text(self) -> None:
        text = B16 + "\n### 2026-11-16, x\n\n```\n## Comments\n# not a heading\n```\n"
        issue = issuefile.parse("x", text)
        self.assertEqual(issue.problems, [])
        self.assertIn("# not a heading", issue.comments[0].text)


class ValueTests(unittest.TestCase):
    """check_values: each field's shape and the status rules."""

    def problems_of(self, **changes: str) -> list:
        """The value problems of B16 with ``changes`` made to its header (underscores for hyphens)."""
        text = B16
        for name, value in changes.items():
            name = name.replace("_", "-")
            old = next(line for line in B16.split("\n") if line.startswith(name + ":"))
            text = text.replace(old + "\n", (f"{name}: {value}" if value else f"{name}:") + "\n")
        return messages(issuefile.check_values(issuefile.parse("x", text)))

    def test_each_bad_value_is_named(self) -> None:
        cases = {
            "kind": ("crash", "kind 'crash' is not one of"),
            "status": ("closed", "status 'closed' is not one of"),
            "priority": ("P4", "priority 'P4' is not one of"),
            "platform": ("ipad", "platform 'ipad' is not one of"),
            "created": ("November 16", "is not a date written YYYY-MM-DD"),
            "assignee": ("two words", "is not an agent's name"),
            "merged": ("XYZ", "is not a commit"),
            "related": ("B16", "related names the issue itself"),
            "labels": ("Audio", "is not lowercase words"),
            "id": ("b16", "is not an ID"),
            "found_by": ("", "field found-by is empty"),
        }
        for name, (value, expected) in cases.items():
            with self.subTest(name):
                found = self.problems_of(**{name: value})
                self.assertTrue(any(expected in message for message in found), f"{name}={value}: {found}")

    def test_a_missing_field_and_dates_out_of_order(self) -> None:
        text = B16.replace("docs:\n", "")
        self.assertIn("missing field docs", messages(issuefile.check_values(issuefile.parse("x", text))))
        self.assertIn("updated 2026-11-15 comes before created 2026-11-16", self.problems_of(updated="2026-11-15"))

    def test_the_status_rules(self) -> None:
        self.assertEqual(self.problems_of(status="done"), ["a done issue needs merged (the merge commit) or a reason"])
        self.assertEqual(self.problems_of(status="done", merged="abc1234"), [])
        self.assertEqual(self.problems_of(status="done", reason="fixed on main by hand"), [])
        self.assertEqual(self.problems_of(status="wontfix", merged="abc1234"), ["a wontfix issue needs a reason"])
        self.assertEqual(self.problems_of(status="duplicate", reason="duplicate of B12"), [])
        self.assertEqual(self.problems_of(merged="abc1234"), ["an issue that is open holds merged; reopen clears it"])
        self.assertEqual(self.problems_of(status="blocked", reason="waits"), ["an issue that is blocked holds reason; reopen clears it"])


class WriteTests(unittest.TestCase):
    """with_fields, with_comment, and fill_template build text that reads back the same."""

    def test_changing_a_field_changes_its_line_and_no_other(self) -> None:
        issue = issuefile.parse("x", B16)
        text = issuefile.with_fields(issue, {"priority": "P1"})
        self.assertEqual(text, B16.replace("priority: P2", "priority: P1"))

    def test_a_change_that_breaks_a_value_is_refused(self) -> None:
        with self.assertRaisesRegex(IssueFormatError, "priority 'P9' is not one of"):
            issuefile.with_fields(issuefile.parse("x", B16), {"priority": "P9"})

    def test_a_broken_file_is_not_rewritten(self) -> None:
        broken = issuefile.parse("Issues/B16.md", B16.replace("status: open\n", "status: open\nstatus: done\n"))
        with self.assertRaisesRegex(IssueFormatError, "Issues/B16.md:6: field status given twice"):
            issuefile.with_fields(broken, {"priority": "P1"})
        with self.assertRaisesRegex(IssueFormatError, "fix the file by hand"):
            issuefile.with_comment(broken, "2026-11-16", "x", "Text.")

    def test_a_comment_is_appended_and_the_header_is_untouched(self) -> None:
        text = issuefile.with_comment(issuefile.parse("x", B16), "2026-11-17", "floatrender", "\nStarted.\n\n")
        self.assertEqual(text, B16 + "\n### 2026-11-17, floatrender, 1 line\n\nStarted.\n")
        # A second comment goes after the first.
        again = issuefile.with_comment(issuefile.parse("x", text), "2026-11-18", "orchestrator", "Seen.")
        self.assertEqual(again, text + "\n### 2026-11-18, orchestrator, 1 line\n\nSeen.\n")
        issue = issuefile.parse("x", again)
        self.assertEqual([c.author for c in issue.comments], ["floatrender", "orchestrator"])

    def test_a_comment_leaves_every_line_before_it_as_it_was(self) -> None:
        # Spacing a hand edit left in the header, which a rebuilt header would lose.
        odd = B16.replace("title: A test bug", "title: A test bug ").replace("labels: audio", "labels:   audio")
        text = issuefile.with_comment(issuefile.parse("x", odd), "2026-11-17", "floatrender", "Seen.")
        self.assertEqual(text, odd + "\n### 2026-11-17, floatrender, 1 line\n\nSeen.\n")

    def test_a_comment_needs_text_and_no_heading_that_would_end_it(self) -> None:
        issue = issuefile.parse("x", B16)
        for text in ("", "  \n", "Text.\n## Next part", "### 2026-11-16, someone else", "# Title"):
            with self.subTest(text=text), self.assertRaises(IssueFormatError):
                issuefile.with_comment(issue, "2026-11-16", "x", text)
        # Deeper headings are text.
        self.assertIn("#### Notes", issuefile.with_comment(issue, "2026-11-16", "x", "#### Notes\nText."))

    def test_the_template_has_every_field_in_order_and_fills_to_a_valid_file(self) -> None:
        template = TEMPLATE.read_text(encoding="utf-8")
        header = template.split("---\n")[1]
        self.assertEqual(tuple(line.split(":")[0] for line in header.strip().split("\n")), issuefile.FIELDS)
        values = {"id": "B16", "title": "A test bug", "kind": "bug", "priority": "P2", "platform": "mac",
                  "today": "2026-11-16", "found_by": "orchestrator", "related": "B12", "docs": "",
                  "labels": "audio", "description": "What is wrong."}
        self.assertEqual(issuefile.fill_template(template, "Issues/B16.md", values), B16)

    def test_a_value_that_would_break_the_header_is_refused(self) -> None:
        template = TEMPLATE.read_text(encoding="utf-8")
        values = {"id": "B16", "title": "Two\nlines", "kind": "bug", "priority": "P2", "platform": "mac",
                  "today": "2026-11-16", "found_by": "x", "related": "", "docs": "", "labels": "", "description": "d"}
        with self.assertRaisesRegex(IssueFormatError, "title must be one line"):
            issuefile.fill_template(template, "Issues/B16.md", values)


if __name__ == "__main__":
    unittest.main()
