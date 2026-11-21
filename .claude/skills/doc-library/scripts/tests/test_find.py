"""Tests of ``find`` and of ``docmodel.units``, on pages the tests write."""

from __future__ import annotations

import json
from typing import List

from doclib_case import DocLibCase

import docmodel
from docmodel import Unit, parse

# A page with a long line of two sentences, a phrase broken over two lines, a marker,
# a code block, a table, a quote, and a list.
EPUB = """\
# EPUB import

## Headings

<!-- id: epub-headings; keys: NCX, nav document; src: TextMouth/Parsers/EPUBParser.swift -->
The parser reads the nav document first. Then it falls back to the NCX file when the nav is missing.
A phrase that is broken
over two lines is still found.

- A list item about seamless playback. It has a second sentence.
- Another item.

> A quoted remark about
> chapters. A second quoted sentence.

```swift
let spine = book.spine
```

| Name | Value |
| ---- | ----- |
| flag (x) | on |

## Other (parts)

Nothing here but "a.b" and f(x).
"""


def unit_summary(units: List[Unit]) -> list:
    """Units as ``(kind, start, end, text)`` tuples for compact comparisons."""
    return [(u.kind, u.start, u.end, u.text) for u in units]


class UnitsTests(DocLibCase):
    """docmodel.units: what a section is cut into."""

    def test_units_of_a_section_in_line_order(self) -> None:
        page = parse("p.md", EPUB)
        found = unit_summary(docmodel.units(page, page.sections[1]))
        self.assertEqual(found[0], ("heading", 3, 3, "Headings"))
        self.assertEqual(found[1][:3], ("marker", 5, 5))
        self.assertIn("id: epub-headings", found[1][3])
        self.assertEqual(found[2], ("sentence", 6, 6, "The parser reads the nav document first."))
        self.assertEqual(found[3], ("sentence", 6, 6, "Then it falls back to the NCX file when the nav is missing."))
        # A sentence that spans two lines has both lines, and a final period ends it.
        self.assertEqual(found[4], ("sentence", 7, 8, "A phrase that is broken\nover two lines is still found."))

    def test_list_markers_and_quote_marks_are_not_part_of_a_sentence(self) -> None:
        page = parse("p.md", EPUB)
        found = unit_summary(docmodel.units(page, page.sections[1]))
        texts = [text for kind, _s, _e, text in found if kind == "sentence"]
        self.assertIn("A list item about seamless playback.", texts)
        self.assertIn("It has a second sentence.", texts)
        self.assertIn("Another item.", texts)
        self.assertIn("A quoted remark about\nchapters.", texts)
        self.assertIn("A second quoted sentence.", texts)
        quote = next(u for u in docmodel.units(page, page.sections[1]) if u.text.startswith("A quoted"))
        self.assertEqual((quote.start, quote.end), (13, 14))

    def test_code_table_html_and_stray_marker_are_one_unit_a_line(self) -> None:
        text = "# T\n<!-- id: t -->\n```\ncode 1\n\ncode 2\n```\n| a | b |\n| - | - |\n<!--\nnote\n-->\ntext\n<!-- id: stray -->\n"
        page = parse("p.md", text)
        found = unit_summary(docmodel.units(page, page.sections[0]))
        kinds = [(kind, start) for kind, start, _e, _t in found]
        self.assertEqual(kinds, [
            ("heading", 1), ("marker", 2), ("code", 3), ("code", 4), ("code", 6), ("code", 7),
            ("table", 8), ("table", 9), ("html", 10), ("html", 11), ("html", 12),
            ("sentence", 13), ("marker", 14)])

    def test_rules_and_front_matter_give_no_units(self) -> None:
        page = parse("p.md", "---\na: b\n---\n# T\n\n---\n\ntext\n")
        found = unit_summary(docmodel.units(page, page.sections[0]))
        self.assertEqual([k for k, *_ in found], ["heading", "sentence"])

    def test_a_level_zero_section_has_no_heading_unit(self) -> None:
        page = parse("p.md", "intro here\n\n# T\n")
        self.assertEqual(unit_summary(docmodel.units(page, page.sections[0])),
                         [("sentence", 1, 1, "intro here")])


class FindTests(DocLibCase):
    """find: matching units, the options, the hit fields, and the exit statuses."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "docs/architecture/epub.md": EPUB,
            "docs/user/reading.md": "# Reading\n\nPlay the book. Seamless playback needs no setup.\n",
            "AGENTS.md": "# Agents\n\nSeamless rules for agents.\n",
        })

    def find(self, *args: str):
        """Run ``find`` with ``args``; return (status, standard output lines, standard error)."""
        status, out, err = self.run_cli("find", *args)
        return status, out.splitlines(), err

    def test_one_sentence_of_two_on_a_long_line_is_found_and_printed_alone(self) -> None:
        status, lines, _err = self.find("falls back")
        self.assertEqual(status, 0)
        self.assertEqual(lines, ["docs/architecture/epub.md:6-6  Headings  "
                                 "Then it falls back to the NCX file when the nav is missing."])

    def test_a_phrase_broken_over_a_line_end_matches(self) -> None:
        status, lines, _err = self.find("broken over two")
        self.assertEqual(status, 0)
        self.assertEqual(lines, ["docs/architecture/epub.md:7-8  Headings  A phrase that is broken over two lines is still found."])

    def test_fixed_treats_dots_and_parentheses_as_text(self) -> None:
        # As a pattern "f(x)." is the letter f, a group x, and any character: no match.
        self.assertEqual(self.find("f(x).")[0], 1)
        status, lines, _err = self.find("--fixed", "f(x).")
        self.assertEqual((status, len(lines)), (0, 1))
        self.assertIn("docs/architecture/epub.md:26-26", lines[0])
        # A dot is any character as a pattern, and only a dot when fixed.
        self.assertEqual(self.find("nav.document")[0], 0)
        self.assertEqual(self.find("--fixed", "nav.document")[0], 1)
        self.assertEqual(self.find("--fixed", "a.b")[0], 0)

    def test_matching_ignores_case(self) -> None:
        self.assertEqual(self.find("THE PARSER")[0], 0)

    def test_area_keeps_the_pages_under_one_docs_folder(self) -> None:
        _status, lines, _err = self.find("seamless")
        self.assertEqual(sorted(line.split(":")[0] for line in lines),
                         ["docs/architecture/epub.md", "docs/user/reading.md"])
        _status, lines, _err = self.find("seamless", "--area", "user")
        self.assertEqual([line.split(":")[0] for line in lines], ["docs/user/reading.md"])
        self.assertEqual(self.find("seamless", "--area", "agents")[0], 1)

    def test_area_with_memory_scope_is_a_usage_error(self) -> None:
        status, lines, err = self.find("seamless", "--area", "user", "--scope", "memory")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("--scope memory", err)

    def test_scope_memory_and_all(self) -> None:
        self.assertEqual([line.split(":")[0] for line in self.find("seamless", "--scope", "memory")[1]], ["AGENTS.md"])
        self.assertEqual(len(self.find("seamless", "--scope", "all")[1]), 3)

    def test_a_match_in_marker_keys_and_source_paths(self) -> None:
        _status, lines, _err = self.find("--fixed", "NCX, nav document")
        self.assertEqual(len(lines), 1)
        self.assertIn(":5-5  Headings  <!-- id: epub-headings; keys: NCX, nav document;", lines[0])
        _status, lines, _err = self.find("EPUBParser.swift")
        self.assertIn(":5-5", lines[0])

    def test_a_match_in_a_code_line_and_a_table_line(self) -> None:
        _status, lines, _err = self.find("book.spine")
        self.assertEqual(lines, ["docs/architecture/epub.md:17-17  Headings  let spine = book.spine"])
        data = json.loads(self.run_cli("find", "flag", "--json")[1].splitlines()[0])
        self.assertEqual((data["kind"], data["start"]), ("table", 22))

    def test_a_heading_match(self) -> None:
        _status, lines, _err = self.find("other \\(parts\\)")
        self.assertEqual(lines, ["docs/architecture/epub.md:24-24  Other (parts)  Other (parts)"])

    def test_max_caps_the_hits_and_standard_error_gives_the_count(self) -> None:
        status, lines, err = self.find("seamless", "--max", "1")
        self.assertEqual((status, len(lines)), (0, 1))
        self.assertIn("1 of 2 hits shown", err)

    def test_the_default_cap_is_twenty(self) -> None:
        self.write_tree({"docs/many.md": "# Many\n\n" + "".join(f"Line {n} says zebra.\n\n" for n in range(30))})
        status, lines, err = self.find("zebra")
        self.assertEqual((status, len(lines)), (0, 20))
        self.assertIn("20 of 30 hits shown", err)
        self.assertEqual(len(self.find("zebra", "--max", "0")[1]), 30)

    def test_no_match_exits_one_with_no_output(self) -> None:
        self.assertEqual(self.find("no such phrase anywhere"), (1, [], ""))

    def test_a_bad_pattern_is_a_usage_error_but_fixed_makes_it_text(self) -> None:
        status, lines, err = self.find("f(x")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("bad pattern 'f(x'", err)
        self.assertEqual(self.find("--fixed", "f(y")[0], 1)
        self.assertEqual(self.find("--fixed", "f(x")[0], 0)
        self.assertEqual(self.find("")[0], 2)

    def test_json_fields(self) -> None:
        _status, out, _err = self.run_cli("find", "falls back", "--json")
        data = json.loads(out)
        self.assertEqual(data, {
            "path": "docs/architecture/epub.md", "start": 6, "end": 6, "heading": "Headings",
            "text": "Then it falls back to the NCX file when the nav is missing.",
            "kind": "sentence", "id": "epub-headings", "section_start": 3, "section_end": 22,
        })

    def test_a_section_without_a_marker_has_a_null_id(self) -> None:
        data = json.loads(self.run_cli("find", "nothing here", "--json")[1])
        self.assertIsNone(data["id"])
        self.assertEqual(data["kind"], "sentence")

    def test_a_long_sentence_is_cut_around_the_match(self) -> None:
        self.write_tree({"docs/long.md": "# Long\n\n" + "word " * 100 + "needle " + "word " * 100 + "\n"})
        _status, lines, _err = self.find("needle")
        self.assertIn("needle", lines[0])
        self.assertLess(len(lines[0].split("  ", 2)[2]), 201)

    def test_hits_come_in_page_then_line_order(self) -> None:
        _status, lines, _err = self.find("the|nav", "--max", "0")
        keys = [(line.split(":")[0], int(line.split(":")[1].split("-")[0])) for line in lines]
        self.assertEqual(keys, sorted(keys))
