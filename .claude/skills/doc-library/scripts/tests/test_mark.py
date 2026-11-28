"""Tests of ``mark``: the ids and marker lines it makes, and the command.

Every page here is written in a test's own temporary folder; no test reads the
real docs.
"""

from __future__ import annotations

import unittest
from unittest import mock

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

    def test_a_possessive_is_left_out_and_an_apostrophe_joins_its_word(self) -> None:
        # platforms.md has "PhoneTextStyle: the phone's text at full contrast".
        self.assertEqual(suggest_id("the phone's text", "p", set()), "phone-text")
        self.assertEqual(suggest_id("the sheet’s buttons", "p", set()), "sheet-buttons")
        self.assertEqual(suggest_id("Don't stop", "p", set()), "dont-stop")

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


# A page with a heading of each kind: bare, with a Files: line, naming a type, repeated, and ones that have a marker.
PAGE = """\
Text before any heading stays as it is.

# Reading

Intro words.

## Saving

- Files: Services/Saver.swift, Views/Library/.
- Owner: ReaderViewModel is named here, and ReaderViewModel again.

## Loading

<!-- id: loading-done; keys: load; src: TextMouth/Services/Saver.swift -->
Has a marker already.

## Stray

A paragraph first.
<!-- id: stray-one; keys: ; src: -->

## Saving

Same title as the second heading.

## Saving

And once more.
"""

TREE = {
    "TextMouth/Services/Saver.swift": "class Saver {}\n",
    "TextMouth/Views/Library/A.swift": "struct A {}\n",
    "TextMouth/ViewModels/ReaderViewModel.swift": "final class ReaderViewModel {}\n",
    # Another page's markers already hold the ids "reading" and "saving".
    "docs/other.md": "# Other\n\n<!-- id: reading; keys: ; src: -->\n\n## Other saving\n\n<!-- id: saving; keys: ; src: -->\n",
}

# The four headings of PAGE that get a marker, as (line in the new text, heading, marker line).
ADDED = [
    (4, "Reading", "<!-- id: reading-reading; keys: ; src: -->"),
    (9, "Saving",
     "<!-- id: reading-saving; keys: ; src: TextMouth/Services/Saver.swift, TextMouth/Views/Library/, "
     "TextMouth/ViewModels/ReaderViewModel.swift -->"),
    (25, "Saving", "<!-- id: reading-saving-2; keys: ; src: -->"),
    (30, "Saving", "<!-- id: reading-saving-3; keys: ; src: -->"),
]


class MarkCommandTests(DocLibCase):
    """mark on pages written in the temporary folder."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree(TREE)
        self.write_tree({"docs/reading.md": PAGE})

    def page(self, name: str = "docs/reading.md") -> str:
        """The text of a page of the temporary repository."""
        return (self.root / name).read_bytes().decode("utf-8")

    def mark(self, *args: str):
        """Run ``mark``; return (status, hit lines, standard error)."""
        status, out, err = self.run_cli("mark", *args)
        return status, out.splitlines(), err

    def test_markers_go_straight_under_the_headings_that_lack_one(self) -> None:
        status, hits, err = self.mark("reading")
        self.assertEqual((status, err), (0, "mark: docs/reading.md: 4 markers added\n"))
        self.assertEqual(hits, [f"docs/reading.md:{n}-{n}  {heading}  {line}" for n, heading, line in ADDED])
        lines = self.page().split("\n")
        for number, _heading, line in ADDED:
            self.assertEqual(lines[number - 1], line)
            self.assertTrue(lines[number - 2].startswith("#"))

    def test_ids_avoid_other_pages_and_repeated_titles(self) -> None:
        # reading and saving are other.md's; the second and third Saving take -2 and -3.
        self.mark("reading")
        page = docmodel.parse("docs/reading.md", self.page())
        ids = [marker.id for section in page.sections
               for marker in ([section.marker] if section.marker else []) + section.stray_markers]
        self.assertEqual(ids, ["reading-reading", "reading-saving", "loading-done", "stray-one",
                               "reading-saving-2", "reading-saving-3"])

    def test_a_title_free_of_collisions_gives_the_bare_id(self) -> None:
        self.write_tree({"docs/fresh.md": "# The Shape of Things\n"})
        self.mark("fresh")
        self.assertEqual(self.page("docs/fresh.md"), "# The Shape of Things\n<!-- id: shape-things; keys: ; src: -->\n")

    def test_src_from_a_files_line_and_an_unbackticked_type(self) -> None:
        self.mark("reading")
        self.assertIn(ADDED[1][2] + "\n", self.page())

    def test_a_section_with_a_marker_and_one_with_a_stray_marker_are_untouched(self) -> None:
        self.mark("reading")
        text = self.page()
        self.assertIn("## Loading\n\n<!-- id: loading-done; keys: load; src: TextMouth/Services/Saver.swift -->\n"
                      "Has a marker already.\n", text)
        self.assertIn("## Stray\n\nA paragraph first.\n<!-- id: stray-one; keys: ; src: -->\n\n", text)
        self.assertEqual(text.count("id: stray-one"), 1)

    def test_text_before_the_first_heading_is_untouched(self) -> None:
        self.mark("reading")
        self.assertTrue(self.page().startswith("Text before any heading stays as it is.\n\n# Reading\n"))

    def test_the_page_is_the_old_one_with_lines_added(self) -> None:
        self.mark("reading")
        new = self.page().split("\n")
        added = {number for number, _heading, _line in ADDED}
        self.assertEqual([line for number, line in enumerate(new, 1) if number not in added], PAGE.split("\n"))
        self.assertTrue(self.page().endswith("\n"))

    def test_a_page_without_a_last_line_end_stays_without_one(self) -> None:
        self.write_tree({"docs/bare.md": "# Bare\n\nText\n\n## Last"})
        status, hits, _err = self.mark("bare")
        self.assertEqual(status, 0)
        self.assertEqual(self.page("docs/bare.md"),
                         "# Bare\n<!-- id: bare; keys: ; src: -->\n\nText\n\n## Last\n<!-- id: last; keys: ; src: -->")
        self.assertTrue(hits[1].startswith("docs/bare.md:7-7  "))

    def test_a_second_run_adds_nothing(self) -> None:
        self.mark("reading")
        first = self.page()
        status, hits, err = self.mark("reading")
        self.assertEqual((status, hits), (0, []))
        self.assertEqual(err, "mark: docs/reading.md: every section has a marker\n")
        self.assertEqual(self.page(), first)

    def test_dry_run_prints_the_same_and_writes_nothing(self) -> None:
        status, hits, err = self.mark("reading", "--dry-run")
        self.assertEqual(
            (status, len(hits), err),
            (0, 4, "mark: docs/reading.md: 4 markers would be added (--dry-run: nothing written)\n"))
        self.assertEqual(self.page(), PAGE)
        # The real run then prints the very same hits.
        self.assertEqual(self.mark("reading")[1], hits)

    def test_every_added_line_parses_back_to_its_fields(self) -> None:
        self.mark("reading")
        lines = self.page().split("\n")
        for number, _heading, line in ADDED:
            marker = docmodel.parse_marker(number, lines[number - 1])
            expected = docmodel.parse_marker(number, line)
            self.assertEqual((marker.id, marker.keys, marker.src, marker.errors),
                             (expected.id, [], expected.src, []))
            self.assertTrue(docmodel.ID_SHAPE.match(marker.id))

    def test_a_page_with_carriage_returns_is_refused(self) -> None:
        data = b"# Crlf\r\n\r\ntext\r\n"
        (self.root / "docs/crlf.md").write_bytes(data)
        status, _out, err = self.run_cli("mark", "crlf")
        self.assertEqual(status, 2)
        self.assertIn("carriage returns", err)
        self.assertEqual((self.root / "docs/crlf.md").read_bytes(), data)

    def test_a_page_with_no_heading_needs_nothing(self) -> None:
        self.write_tree({"docs/plain.md": "Just text.\n"})
        status, hits, _err = self.mark("plain")
        self.assertEqual((status, hits), (0, []))
        self.assertEqual(self.page("docs/plain.md"), "Just text.\n")

    def test_a_failed_check_writes_nothing(self) -> None:
        # A plan that puts no marker where it said it would: the read-back check must refuse it.
        broken = lambda text, additions: text.replace("# Reading\n", "# Reading\n\n", 1)  # noqa: E731
        with mock.patch.object(cmd_mark, "apply_additions", broken):
            status, out, _err = self.run_cli("mark", "reading")
        self.assertEqual(status, 1)
        self.assertIn("refused, nothing written", out)
        self.assertEqual(self.page(), PAGE)


if __name__ == "__main__":
    unittest.main()
