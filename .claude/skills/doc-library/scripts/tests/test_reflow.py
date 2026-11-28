"""Tests of ``reflow``: the pure ``reflow_text`` and ``starts_a_block``, and the command.

Every page here is written in a test's own temporary folder; no test reads the
real docs.
"""

from __future__ import annotations

import unittest
from unittest import mock

from doclib_case import DocLibCase

import cmd_reflow
import reflowblocks
from cmd_reflow import reflow_text
from reflowblocks import starts_a_block


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
        with mock.patch.object(reflowblocks, "starts_a_block", return_value=False):
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



PAGE = "docs/user/page.md"
# A page with every kind of block that must not change, around two prose blocks that do.
MIXED = (
    "---\ntitle: A page. Really.\n---\n# Page\n\n<!-- id: page-top; keys: one -->\n"
    "One is here. Two is here.\n\n```text\nCode. Two.\n```\n\n| A. B. |\n|---|\n\n> Quote. Two.\n\n"
    "- Item one. Item two.\n\n<!-- note. two. -->\n\nHard break here.  \nSecond line. Third.\n"
)
MIXED_AFTER = MIXED.replace("One is here. Two is here.", "One is here.\nTwo is here.").replace(
    "- Item one. Item two.", "- Item one.\n  Item two.")


class ReflowCommandTests(DocLibCase):
    """reflow: the page it writes, its output lines, --check, and every refusal."""

    def page_bytes(self, path: str = PAGE) -> bytes:
        """The page's bytes on disk."""
        return (self.root / path).read_bytes()

    def reflow(self, *args: str):
        """Run ``reflow`` on the page with ``args``; return (status, standard output, standard error)."""
        return self.run_cli("reflow", PAGE, *args)

    def test_blocks_are_rewritten_and_the_rest_is_byte_identical(self) -> None:
        self.write_tree({PAGE: MIXED})
        status, out, err = self.reflow()
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(self.page_bytes(), MIXED_AFTER.encode("utf-8"))
        self.assertEqual(out, f"reflow: {PAGE}: {len(MIXED.splitlines())} lines became {len(MIXED_AFTER.splitlines())}\n")

    def test_a_page_already_one_sentence_per_line_is_left_alone(self) -> None:
        self.write_tree({PAGE: MIXED_AFTER})
        before = (self.root / PAGE).stat().st_mtime_ns
        status, out, _ = self.reflow()
        self.assertEqual((status, out), (0, f"reflow: {PAGE}: already one sentence per line\n"))
        self.assertEqual(self.page_bytes(), MIXED_AFTER.encode("utf-8"))
        self.assertEqual((self.root / PAGE).stat().st_mtime_ns, before)

    def test_running_it_twice_changes_nothing_the_second_time(self) -> None:
        self.write_tree({PAGE: MIXED})
        self.reflow()
        once = self.page_bytes()
        status, out, _ = self.reflow()
        self.assertEqual((status, out), (0, f"reflow: {PAGE}: already one sentence per line\n"))
        self.assertEqual(self.page_bytes(), once)

    def test_a_page_without_a_last_line_end_stays_without_one(self) -> None:
        self.write_tree({PAGE: "# T\n\nOne is here. Two is here."})
        self.assertEqual(self.reflow()[0], 0)
        self.assertEqual(self.page_bytes(), b"# T\n\nOne is here.\nTwo is here.")

    def test_check_writes_nothing_and_exits_1_when_the_page_would_change(self) -> None:
        self.write_tree({PAGE: MIXED})
        status, out, _ = self.reflow("--check")
        self.assertEqual(status, 1)
        self.assertEqual(out, f"reflow: {PAGE}: {len(MIXED.splitlines())} lines became {len(MIXED_AFTER.splitlines())}\n")
        self.assertEqual(self.page_bytes(), MIXED.encode("utf-8"))

    def test_the_page_may_be_named_by_the_end_of_its_path(self) -> None:
        # As every command names a page: "page" is the one page ending so.
        self.write_tree({PAGE: MIXED})
        status, out, _ = self.run_cli("reflow", "page", "--check")
        self.assertEqual(status, 1)
        self.assertTrue(out.startswith(f"reflow: {PAGE}: "), out)

    def test_check_exits_0_when_nothing_would_change(self) -> None:
        self.write_tree({PAGE: MIXED_AFTER})
        status, out, _ = self.reflow("--check")
        self.assertEqual((status, out), (0, f"reflow: {PAGE}: already one sentence per line\n"))

    def test_a_page_with_carriage_returns_is_refused(self) -> None:
        (self.root / "docs/user").mkdir(parents=True)
        (self.root / PAGE).write_bytes(b"# T\r\n\r\nOne is here. Two is here.\r\n")
        status, out, err = self.reflow()
        self.assertEqual((status, out), (2, ""))
        self.assertIn("carriage returns", err)
        self.assertEqual(self.page_bytes(), b"# T\r\n\r\nOne is here. Two is here.\r\n")

    def test_a_page_that_is_not_utf8_or_not_there_is_refused(self) -> None:
        (self.root / "docs/user").mkdir(parents=True)
        (self.root / PAGE).write_bytes(b"# T\n\nOne \xff here. Two.\n")
        self.assertEqual(self.reflow()[0], 2)
        self.assertEqual(self.run_cli("reflow", "docs/user/none.md")[0], 2)
        self.assertEqual(self.run_cli("reflow", "../outside.md")[0], 2)

    def test_the_block_check_stops_a_reflow_that_turns_a_sentence_into_an_item(self) -> None:
        text = "# T\n\nAlpha is first. 2) Beta follows.\n"
        self.write_tree({PAGE: text})
        # Without starts_a_block's refusal, the second sentence would start an ordered list item.
        with mock.patch.object(reflowblocks, "starts_a_block", return_value=False):
            status, out, _ = self.reflow()
        self.assertEqual(status, 1)
        self.assertIn("blocks or headings differ", out)
        self.assertEqual(self.page_bytes(), text.encode("utf-8"))

    def test_the_character_check_stops_a_reflow_that_changes_a_character(self) -> None:
        text = "# T\n\nOne is here. Two is here.\n"
        self.write_tree({PAGE: text})
        with mock.patch.object(cmd_reflow, "reflow_text", return_value="# T\n\nOne is here.\nTwo is hxre.\n"):
            status, out, _ = self.reflow()
        self.assertEqual(status, 1)
        self.assertIn("non-space characters differ", out)
        self.assertEqual(self.page_bytes(), text.encode("utf-8"))

    def test_the_words_check_of_pagewrite_still_applies(self) -> None:
        text = "# T\n\nOne is here. Two is here.\n"
        self.write_tree({PAGE: text})
        with mock.patch.object(cmd_reflow, "problems_with", return_value=[]), \
                mock.patch.object(cmd_reflow, "reflow_text", return_value="# T\n\nOne is here.\nTwo was here.\n"):
            status, out, _ = self.reflow()
        self.assertEqual(status, 1)
        self.assertIn("the words differ", out)
        self.assertEqual(self.page_bytes(), text.encode("utf-8"))

    def test_non_ascii_text_survives_the_file_round_trip(self) -> None:
        self.write_tree({PAGE: "# T\n\nCaf\u00e9 is open. The cell \u2801 is dot one.\n"})
        self.assertEqual(self.reflow()[0], 0)
        self.assertEqual(self.page_bytes().decode("utf-8"), "# T\n\nCaf\u00e9 is open.\nThe cell \u2801 is dot one.\n")

    def test_the_page_keeps_its_permissions(self) -> None:
        self.write_tree({PAGE: "# T\n\nOne is here. Two is here.\n"})
        (self.root / PAGE).chmod(0o640)
        self.reflow()
        self.assertEqual((self.root / PAGE).stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
