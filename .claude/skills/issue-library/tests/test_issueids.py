"""Tests of issueids: the shape of an ID, its family, the next free one, and the TODO's openings."""

from __future__ import annotations

import unittest

import issuelib_case  # noqa: F401  (puts the scripts folder on sys.path)
import issueids


class ShapeTests(unittest.TestCase):
    """What is an ID, and what is a plain word in capitals."""

    def test_the_todos_ids_are_ids(self) -> None:
        for issue_id in ("B15", "FR23", "FMT50", "PG14", "FU-FFMPEG2", "A11Y-GOTO", "Q-flake", "T-ROOT", "B12-OCT"):
            self.assertTrue(issueids.is_issue_id(issue_id), issue_id)

    def test_words_in_capitals_and_malformed_names_are_not(self) -> None:
        for text in ("EPUB", "README", "b16", "B 16", "16B", "B16-", "-B16", "B16--OCT", "", "B" + "1" * 40):
            self.assertFalse(issueids.is_issue_id(text), text)

    def test_a_numbered_id_has_a_family_and_a_number(self) -> None:
        self.assertEqual(issueids.family_number("B16"), ("B", 16))
        self.assertEqual(issueids.family_number("FMT05"), ("FMT", 5))
        self.assertEqual(issueids.family_number("B12-OCT"), ("B", 12))
        # Named IDs have no number, even when a digit is in their name.
        for named in ("FU-FFMPEG2", "A11Y-GOTO", "Q-HANG"):
            self.assertIsNone(issueids.family_number(named), named)

    def test_ids_sort_by_family_then_number(self) -> None:
        ids = ["B10", "FU-FORMATS", "B2", "B12-OCT", "B12", "A01", "FU01"]
        self.assertEqual(sorted(ids, key=issueids.sort_key), ["A01", "B2", "B10", "B12", "B12-OCT", "FU01", "FU-FORMATS"])


class NextIdTests(unittest.TestCase):
    """A family's next ID is one past every number it has ever had."""

    def test_mentions_count_but_parts_of_longer_names_do_not(self) -> None:
        text = "C01 and C07 are items; the other audit's C11 and C18 are named in prose. FU-FFMPEG2, A11Y, xB99, B5x."
        numbers = issueids.numbers_in(text)
        self.assertEqual(numbers["C"], {1, 7, 11, 18})
        self.assertNotIn("FFMPEG", numbers)
        self.assertNotIn("A", numbers)
        self.assertNotIn("B", numbers)

    def test_the_next_id_is_past_the_highest_number_with_two_digits(self) -> None:
        used = {"B": {1, 15, 8}, "C": {18}}
        self.assertEqual(issueids.next_id("B", used), "B16")
        self.assertEqual(issueids.next_id("C", used), "C19")
        # A family never used starts at 01.
        self.assertEqual(issueids.next_id("FU", used), "FU01")
        self.assertEqual(issueids.next_id("B", {"B": {99}}), "B100")

    def test_every_kind_has_a_family(self) -> None:
        import issuefile
        self.assertEqual(set(issueids.FAMILY_OF_KIND), set(issuefile.KINDS))
        for family in issueids.FAMILY_OF_KIND.values():
            self.assertTrue(issueids.is_family(family), family)

    def test_ids_in_text_come_once_in_order(self) -> None:
        self.assertEqual(issueids.ids_in("After FR15 and B12, see FR15 again; FU-FFMPEG2 too, not xB3."),
                         ["FR15", "B12", "FU-FFMPEG2"])


class OpeningTests(unittest.TestCase):
    """The IDs a TODO item's bold opening names."""

    def test_one_id_and_a_title(self) -> None:
        ids, asides, start = issueids.parse_opening("B14 — A save's temporary file.** Found")
        self.assertEqual((ids, asides), (["B14"], []))
        self.assertEqual("B14 — A save's temporary file.** Found"[start:].strip(), "A save's temporary file.** Found")

    def test_several_ids_asides_and_other_terminators(self) -> None:
        self.assertEqual(issueids.parse_opening("B11, B10, and FR21: the Move sheet")[0], ["B11", "B10", "FR21"])
        self.assertEqual(issueids.parse_opening("S07 and S08 — Folder names")[0], ["S07", "S08"])
        self.assertEqual(issueids.parse_opening("I07 and T04 (DAISY) — Inline")[:2], (["I07", "T04"], ["DAISY"]))
        self.assertEqual(issueids.parse_opening("FR16 (low priority) — Pauses")[:2], (["FR16"], ["low priority"]))
        self.assertEqual(issueids.parse_opening("B12.** A finished edit")[0], ["B12"])
        self.assertEqual(issueids.parse_opening("ST04, wording only:**")[0], ["ST04"])
        self.assertEqual(issueids.parse_opening("Q07 (partial): log writes")[0], ["Q07"])

    def test_bold_runs_that_do_not_open_with_ids(self) -> None:
        for head in ("FR03 follow-ups from the first feed", "Tooling — the board", "EPUB page lists", "Audio speed"):
            self.assertEqual(issueids.parse_opening(head)[0], [], head)


class ScanTests(unittest.TestCase):
    """scan_todo: items, pointers, aliases, sections, and code."""

    TEXT = """\
# TODO

## Completed fixes

- [x] **B13, Q-flake — rules saved during a move.** Merged.
  - **B12.** A finished edit.

## Bugs

- [ ] **B14** moved to Issues/B14.md
- [x] **B13 (alias B13-OCT) — DOC books run words together.** Merged.
- [ ] **FR03 follow-ups.** Not an opening.

```
- [ ] **B99 — in code.**
```
"""

    def test_items_carry_their_section_box_indent_and_aliases(self) -> None:
        items = issueids.scan_todo(self.TEXT)
        found = [(item.line, item.ids, item.section, item.checked, item.indent, item.pointer, item.aliases)
                 for item in items]
        self.assertEqual(found, [
            (5, ["B13", "Q-flake"], "Completed fixes", True, 0, False, {}),
            (6, ["B12"], "Completed fixes", None, 2, False, {}),
            (10, ["B14"], "Bugs", False, 0, True, {}),
            (11, ["B13"], "Bugs", True, 0, False, {"B13-OCT": "B13"}),
        ])
        self.assertFalse(items[0].in_backlog)
        self.assertFalse(items[1].in_backlog)
        self.assertTrue(items[3].in_backlog)
        self.assertEqual(items[2].target, "B14")

    def test_known_ids_and_aliases(self) -> None:
        items = issueids.scan_todo(self.TEXT)
        self.assertEqual(issueids.todo_ids(items), {"B13", "Q-flake", "B12", "B14", "B13-OCT"})
        self.assertEqual(issueids.todo_aliases(items), {"B13-OCT": "B13"})


if __name__ == "__main__":
    unittest.main()
