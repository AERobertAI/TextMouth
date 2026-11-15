"""Tests of ``mark``: the ids and marker lines it makes, and the command.

Every page here is written in a test's own temporary folder; no test reads the
real docs.
"""

from __future__ import annotations

import unittest

from doclib_case import DocLibCase  # noqa: F401  (also puts the scripts folder on sys.path)

import cmd_mark
import docmodel
from cmd_mark import ID_LENGTH, marker_line, suggest_id
from cmd_suggest_src import Suggestion


class SuggestIdTests(unittest.TestCase):
    """suggest_id(): the base of an id, and what it does about a taken one."""

    def test_stop_words_are_dropped(self) -> None:
        self.assertEqual(suggest_id("The Shape of the Reader", "p", set()), "shape-reader")

    def test_a_title_of_only_stop_words_keeps_them(self) -> None:
        self.assertEqual(suggest_id("To the", "p", set()), "to-the")

    def test_digits_are_kept(self) -> None:
        self.assertEqual(suggest_id("Version 0.4.10 notes", "p", set()), "version-0-4-10-notes")

    def test_only_five_words_are_kept(self) -> None:
        self.assertEqual(suggest_id("One two three four five six seven", "p", set()), "one-two-three-four-five")

    def test_the_cut_at_forty_characters_is_at_a_hyphen(self) -> None:
        title = "alphabetical configuration serializations infrastructure"
        ident = suggest_id(title, "p", set())
        self.assertEqual(ident, "alphabetical-configuration")
        self.assertLessEqual(len(ident), ID_LENGTH)

    def test_a_hyphen_exactly_at_the_limit_keeps_whole_words(self) -> None:
        # 20 + 1 + 19 = 40 characters, then a hyphen and a word that does not fit.
        title = "a" * 20 + " " + "b" * 19 + " cccc"
        self.assertEqual(suggest_id(title, "p", set()), "a" * 20 + "-" + "b" * 19)

    def test_a_single_long_word_is_cut_hard(self) -> None:
        self.assertEqual(suggest_id("x" * 60, "p", set()), "x" * ID_LENGTH)

    def test_markup_is_stripped_and_an_ampersand_reads_as_and(self) -> None:
        self.assertEqual(suggest_id("`EPUBParser` & [the NCX](ncx.md)", "p", set()), "epubparser-ncx")
        self.assertEqual(suggest_id("Tom & Jerry", "p", set()), "tom-jerry")
        self.assertEqual(suggest_id("&", "p", set()), "and")

    def test_a_title_of_punctuation_gives_section(self) -> None:
        self.assertEqual(suggest_id("?! --", "p", set()), "section")
        self.assertEqual(suggest_id("", "p", set()), "section")

    def test_a_taken_id_gives_the_page_stem_form_then_numbers(self) -> None:
        taken = {"saving"}
        self.assertEqual(suggest_id("Saving", "What_TextMouth Reads", taken), "what-textmouth-reads-saving")
        taken.add("what-textmouth-reads-saving")
        self.assertEqual(suggest_id("Saving", "What_TextMouth Reads", taken), "what-textmouth-reads-saving-2")
        taken.add("what-textmouth-reads-saving-2")
        self.assertEqual(suggest_id("Saving", "What_TextMouth Reads", taken), "what-textmouth-reads-saving-3")

    def test_a_page_stem_without_letters_is_page(self) -> None:
        self.assertEqual(suggest_id("Saving", "---", {"saving"}), "page-saving")

    def test_every_id_has_the_shape_of_an_id(self) -> None:
        for title in ("Hello, World!", "  ", "Ünïcode only", "1", "a-b_c", "`x` `y`"):
            with self.subTest(title=title):
                self.assertTrue(docmodel.ID_SHAPE.match(suggest_id(title, "Page Stem", {"x"})))


class MarkerLineTests(unittest.TestCase):
    """marker_line() and src_paths(): the line, and what parse_marker reads back."""

    def assert_round_trip(self, ident: str, src: list) -> None:
        """The marker line for ``ident`` and ``src`` parses back to them, with no keys and no errors."""
        marker = docmodel.parse_marker(1, marker_line(ident, src))
        self.assertIsNotNone(marker)
        self.assertEqual((marker.id, marker.keys, marker.src, marker.errors), (ident, [], src, []))

    def test_the_line_with_paths(self) -> None:
        self.assertEqual(marker_line("a-b", ["TextMouth/A.swift", "Views/"]),
                         "<!-- id: a-b; keys: ; src: TextMouth/A.swift, Views/ -->")

    def test_the_line_without_paths(self) -> None:
        self.assertEqual(marker_line("a-b", []), "<!-- id: a-b; keys: ; src: -->")

    def test_parse_marker_reads_every_line_back(self) -> None:
        self.assert_round_trip("a-b", [])
        self.assert_round_trip("a-b", ["TextMouth/A.swift"])
        self.assert_round_trip("x1", ["A.swift", "B/", "docs/with space.md"])

    def test_src_takes_every_files_path_then_five_others(self) -> None:
        files = [Suggestion(f"F{n}.swift", 1, "Files: line") for n in range(7)]
        others = [Suggestion(f"O{n}.swift", 1, "declares X (named 1 time)") for n in range(8)]
        paths = cmd_mark.src_paths(files[:3] + others[:2] + files[3:] + others[2:])
        self.assertEqual(paths, [f"F{n}.swift" for n in range(7)] + [f"O{n}.swift" for n in range(5)])

    def test_src_leaves_out_a_path_the_marker_cannot_hold(self) -> None:
        suggestions = [Suggestion("a,b.swift", 1, "Files: line"), Suggestion("c;d.swift", 1, "other"),
                       Suggestion("ok.swift", 1, "other")]
        self.assertEqual(cmd_mark.src_paths(suggestions), ["ok.swift"])


if __name__ == "__main__":
    unittest.main()
