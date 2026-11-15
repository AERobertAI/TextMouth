"""Tests of ``reflow``: the pure ``reflow_text`` and ``starts_a_block``, and the command.

Every page here is written in a test's own temporary folder; no test reads the
real docs.
"""

from __future__ import annotations

import unittest
from unittest import mock

from doclib_case import DocLibCase

import cmd_reflow
from cmd_reflow import reflow_text, starts_a_block


class StartsABlockTests(unittest.TestCase):
    """starts_a_block(): what may not begin a line of its own."""

    def test_things_that_begin_a_block(self) -> None:
        for text in ("- item", "* item", "+ item", "1. item", "12) item", "2.", "-", "# Heading",
                     "> quote", "| cell |", "<b>bold</b>", "```swift", "~~~", "---", "* * *", "___",
                     "===", "--"):
            with self.subTest(text=text):
                self.assertTrue(starts_a_block(text))

    def test_ordinary_sentences_do_not(self) -> None:
        for text in ("It works.", "2.5 is a number.", "-5 is negative.", "1.5 more", "*Emphasis* here.",
                     "`code` first.", "Use - sparingly.", "", "é accent."):
            with self.subTest(text=text):
                self.assertFalse(starts_a_block(text))


class ReflowTextTests(unittest.TestCase):
    """reflow_text(): which blocks change, and how."""

    def test_a_paragraph_of_three_sentences_becomes_three_lines(self) -> None:
        self.assertEqual(reflow_text("# T\n\nOne is here. Two is here. Three is here.\n"),
                         "# T\n\nOne is here.\nTwo is here.\nThree is here.\n")

    def test_a_sentence_wrapped_over_two_lines_becomes_one_line(self) -> None:
        self.assertEqual(reflow_text("A sentence that was\nwrapped by hand.\n"),
                         "A sentence that was wrapped by hand.\n")

    def test_a_wrapped_sentence_loses_the_indentation_of_its_continuation(self) -> None:
        self.assertEqual(reflow_text("Wrapped\n   and indented. Next one.\n"),
                         "Wrapped and indented.\nNext one.\n")

    def test_a_bullet_item_continues_at_the_text(self) -> None:
        self.assertEqual(reflow_text("- First one. Second one.\n"), "- First one.\n  Second one.\n")

    def test_a_numbered_item_continues_at_the_text(self) -> None:
        self.assertEqual(reflow_text("1. First one. Second one.\n"), "1. First one.\n   Second one.\n")
        self.assertEqual(reflow_text("10) First one. Second one.\n"), "10) First one.\n    Second one.\n")

    def test_a_nested_item_continues_at_its_own_text(self) -> None:
        self.assertEqual(
            reflow_text("- Outer one. Outer two.\n  - Inner one. Inner two.\n"),
            "- Outer one.\n  Outer two.\n  - Inner one.\n    Inner two.\n")

    def test_an_item_with_wrapped_lines_is_joined_first(self) -> None:
        self.assertEqual(reflow_text("- One that runs\n  on. Two.\n"), "- One that runs on.\n  Two.\n")

    def test_a_list_paragraph_keeps_its_indentation(self) -> None:
        text = "- Item.\n\n  Para one. Para two.\n"
        self.assertEqual(reflow_text(text), "- Item.\n\n  Para one.\n  Para two.\n")

    def test_a_sentence_that_would_start_a_block_stays_on_the_line_before(self) -> None:
        # The splitter does split before each of these; starts_a_block puts them back.
        for text, expected in (
                ("Alpha is first. 2) Beta follows.\n", "Alpha is first. 2) Beta follows.\n"),
                ("- Alpha is first. 2) Beta follows. Gamma.\n", "- Alpha is first. 2) Beta follows.\n  Gamma.\n"),
                ("Alpha is first. 2. Beta follows.\n", "Alpha is first. 2.\nBeta follows.\n")):
            with self.subTest(text=text):
                self.assertEqual(reflow_text(text), expected)

    def test_the_refused_split_would_have_been_made_without_the_test(self) -> None:
        with mock.patch.object(cmd_reflow, "starts_a_block", return_value=False):
            self.assertEqual(reflow_text("Alpha is first. 2) Beta follows.\n"),
                             "Alpha is first.\n2) Beta follows.\n")

    def test_other_blocks_are_byte_identical(self) -> None:
        text = (
            "---\ntitle: One. Two.\n---\n"
            "# Head. Of the page\n\n"
            "<!-- id: a-section; keys: one. two -->\n"
            "<!-- a comment. With two sentences. -->\n\n"
            "```text\nA line. Another sentence.\n```\n\n"
            "    indented code. Two sentences.\n\n"
            "| A. B. | C. D. |\n|---|---|\n| One. Two. | Three. Four. |\n\n"
            "> Quoted one. Quoted two.\n\n"
            "---\n"
        )
        self.assertEqual(reflow_text(text), text)

    def test_a_block_with_a_hard_line_break_is_kept(self) -> None:
        for text in ("One here.  \nTwo here. Three here.\n", "One here.\\\nTwo here. Three here.\n",
                     "- One here.  \n  Two here. Three here.\n"):
            with self.subTest(text=text):
                self.assertEqual(reflow_text(text), text)

    def test_a_block_with_a_line_starting_with_html_is_kept(self) -> None:
        for text in ("One here. Two here.\n<br>Three here. Four here.\n", "<kbd>X</kbd> does it. Then more.\n",
                     "- <kbd>X</kbd> does it. Then more.\n"):
            with self.subTest(text=text):
                self.assertEqual(reflow_text(text), text)

    def test_a_setext_underline_keeps_its_block(self) -> None:
        text = "Title words. More words.\n=====\n"
        self.assertEqual(reflow_text(text), text)

    def test_the_last_line_end_is_kept_as_it_was(self) -> None:
        self.assertEqual(reflow_text("One is here. Two is here."), "One is here.\nTwo is here.")
        self.assertEqual(reflow_text("One is here. Two is here.\n\n"), "One is here.\nTwo is here.\n\n")
        self.assertEqual(reflow_text(""), "")
        self.assertEqual(reflow_text("\n"), "\n")

    def test_blank_lines_and_a_byte_order_mark_are_kept(self) -> None:
        self.assertEqual(reflow_text("﻿One is here. Two is here.\n\n\n\nThree.\n"),
                         "﻿One is here.\nTwo is here.\n\n\n\nThree.\n")

    def test_running_it_twice_changes_nothing_the_second_time(self) -> None:
        text = ("# T\n\nOne is here. Two\nis here. 2. Three.\n\n- Item one. Item two.\n"
                "  - Inner one. Inner two.\n\n  Para one. Para two.\n")
        once = reflow_text(text)
        self.assertNotEqual(once, text)
        self.assertEqual(reflow_text(once), once)

    def test_non_ascii_text_is_kept(self) -> None:
        self.assertEqual(reflow_text("Café is open. The cell ⠁ is dot one.\n"),
                         "Café is open.\nThe cell ⠁ is dot one.\n")

    def test_inline_code_and_abbreviations_do_not_end_a_sentence(self) -> None:
        self.assertEqual(reflow_text("Use `a. b` here, e.g. now. Then stop.\n"),
                         "Use `a. b` here, e.g. now.\nThen stop.\n")

    def test_the_first_line_keeps_its_own_start(self) -> None:
        # Two spaces of indentation on a paragraph, and the spaces after a marker.
        self.assertEqual(reflow_text("  Indented one. Indented two.\n"), "  Indented one.\n  Indented two.\n")
        self.assertEqual(reflow_text("-   Wide marker one. Two.\n"), "-   Wide marker one.\n    Two.\n")


if __name__ == "__main__":
    unittest.main()
