"""Tests of ``where``, on repositories the tests write."""

from __future__ import annotations

import json
from typing import Dict, List

from doclib_case import DocLibCase

import citations
import cmd_where
from repofiles import RepoFiles

# The source files of the test repository; the docs cite them in different ways.
SOURCES: Dict[str, str] = {
    "TextMouth/Models/Book.swift": "struct Book {}\n",
    "TextMouth/Models/BookBox.swift": "final class BookBox {}\n",
    "TextMouth/Parsers/EPUBParser.swift": "struct EPUBParser {}\n",
    "TextMouth/Parsers/DOCXParser.swift": "struct DOCXParser {}\n",
    "TextMouth/Services/Other.swift": "struct Other {}\n",
    "project.yml": "name: TextMouth\n",
    "Scripts/build.sh": "echo build\n",
}

# One page of sections, each citing in another way.
ARCHITECTURE = """\
# Architecture

## Models

<!-- id: models-book; keys: Book; src: TextMouth/Models/Book.swift -->
The `Book` type holds a title. Then `Book.Storage` holds the fields.
The `Book` is cited again here, and once more as `Book`.

## Boxes

<!-- id: boxes; keys: box; src: TextMouth/Models/BookBox.swift -->
The `BookBox` class is a box and is not a Book in itself.

## Parsers

<!-- id: parsers; keys: parse; src: TextMouth/Services/Other.swift -->
Parsing is split by format.

- Files: Parsers/EPUBParser.swift, Parsers/DOCXParser.swift

## Whole folder

Everything is in `Parsers/`.

## Removed

The old code lived in `TextMouth/Removed.swift` and in `Scripts/Old.swift`.

## Nothing

No paths here, only words.
"""

# A second page, to test the order of pages and --scope.
OTHER_PAGE = """\
# Notes

## One

Files: Models/Book.swift
"""

# A memory page, found only with --scope memory.
AGENTS = """\
# Agents

## Rules

Read `TextMouth/Models/Book.swift` first.
"""


class WhereCase(DocLibCase):
    """A test case with the source files and docs of the repository written."""

    def setUp(self) -> None:
        """Write the repository."""
        super().setUp()
        files = dict(SOURCES)
        files["docs/architecture/models.md"] = ARCHITECTURE
        files["docs/developer/notes.md"] = OTHER_PAGE
        files["AGENTS.md"] = AGENTS
        self.write_tree(files)
        self.last_status = -1

    def where(self, *argv: str) -> List[Dict]:
        """Run ``where ARGV --json``, remember its exit status, and return its hits."""
        status, out, _ = self.run_cli("where", *argv, "--json")
        self.last_status = status
        return [json.loads(line) for line in out.splitlines()]

    def sections(self, hits: List[Dict]) -> List[str]:
        """The marker ids (or headings) of the hits' sections, in order."""
        return [hit["id"] or hit["heading"] for hit in hits]


class ClassifyTests(WhereCase):
    """classify(): the three kinds of NAME, in order."""

    def kind(self, name: str) -> str:
        """The kind of ``name`` in the test repository."""
        return cmd_where.classify(name, RepoFiles.load(self.root))

    def test_a_name_with_a_slash_is_a_path(self) -> None:
        self.assertEqual(self.kind("TextMouth/Models/Book.swift"), "path")
        self.assertEqual(self.kind("TextMouth/Parsers/"), "path")

    def test_a_name_with_an_extension_is_a_file_name(self) -> None:
        self.assertEqual(self.kind("EPUBParser.swift"), "file")
        self.assertEqual(self.kind("Removed.swift"), "file")
        self.assertEqual(self.kind("project.yml"), "file")

    def test_a_dotted_swift_name_is_not_a_file_name(self) -> None:
        self.assertEqual(self.kind("Book.Storage"), "swift")
        self.assertEqual(self.kind("AppState.shared"), "swift")

    def test_a_plain_word_is_a_swift_name(self) -> None:
        self.assertEqual(self.kind("Book"), "swift")
        self.assertEqual(self.kind("start(in:)"), "swift")


class PathTests(WhereCase):
    """A path or a file name finds the sections that cite it."""

    def test_a_file_path_finds_the_marker_citation(self) -> None:
        hits = self.where("TextMouth/Models/Book.swift")
        self.assertEqual(self.last_status, 0)
        self.assertEqual(
            [(hit["path"], hit["id"], hit["kind"]) for hit in hits],
            [("docs/architecture/models.md", "models-book", "src"),
             ("docs/developer/notes.md", None, "files")])

    def test_a_path_written_without_text_mouth_finds_the_same(self) -> None:
        self.assertEqual(self.where("Models/Book.swift"), self.where("TextMouth/Models/Book.swift"))

    def test_one_hit_for_each_section_at_the_marker(self) -> None:
        # The Models section cites Book.swift in the marker only, but names `Book` three times.
        hits = self.where("TextMouth/Models/Book.swift")
        self.assertEqual(len([hit for hit in hits if hit["id"] == "models-book"]), 1)
        first = hits[0]
        self.assertEqual((first["start"], first["end"]), (5, 5))
        self.assertEqual(first["token"], "TextMouth/Models/Book.swift")

    def test_a_folder_finds_a_section_citing_a_file_inside_it_through_a_files_line(self) -> None:
        hits = self.where("TextMouth/Parsers/")
        self.assertEqual(self.last_status, 0)
        parsers = [hit for hit in hits if hit["id"] == "parsers"]
        self.assertEqual(len(parsers), 1)
        self.assertEqual(parsers[0]["kind"], "files")
        self.assertEqual(parsers[0]["token"], "Parsers/EPUBParser.swift")
        # The section that cites the folder itself is found too.
        self.assertIn("Whole folder", [hit["heading"] for hit in hits])

    def test_a_folder_citation_is_found_by_a_file_inside_it(self) -> None:
        hits = self.where("TextMouth/Parsers/EPUBParser.swift")
        folder = [hit for hit in hits if hit["heading"] == "Whole folder"]
        self.assertEqual(len(folder), 1)
        self.assertEqual((folder[0]["kind"], folder[0]["token"]), ("text", "Parsers/"))

    def test_a_removed_file_is_still_found(self) -> None:
        hits = self.where("TextMouth/Removed.swift")
        self.assertEqual(self.last_status, 0)
        self.assertEqual(self.sections(hits), ["Removed"])
        self.assertEqual(hits[0]["token"], "TextMouth/Removed.swift")

    def test_a_removed_path_is_found_by_the_spelling_the_doc_uses(self) -> None:
        self.assertEqual(self.sections(self.where("Scripts/Old.swift")), ["Removed"])

    def test_a_file_name_finds_a_files_line_written_relative_to_text_mouth(self) -> None:
        hits = self.where("EPUBParser.swift")
        # The section citing the folder `Parsers/` holds the file too.
        self.assertEqual(self.sections(hits), ["parsers", "Whole folder"])
        self.assertEqual(hits[0]["kind"], "files")
        self.assertEqual(hits[0]["token"], "Parsers/EPUBParser.swift")

    def test_a_removed_file_name_finds_the_citation_whose_last_component_it_is(self) -> None:
        hits = self.where("Old.swift")
        self.assertEqual(self.sections(hits), ["Removed"])
        self.assertEqual(hits[0]["token"], "Scripts/Old.swift")

    def test_a_root_file_name(self) -> None:
        self.write_tree({
            "docs/developer/build.md":
                "# Build\n\n## Spec\n\n<!-- id: spec; keys: x; src: project.yml -->\nThe spec.\n"})
        self.assertEqual(self.sections(self.where("project.yml")), ["spec"])

    def test_nothing_found_exits_1_with_no_output(self) -> None:
        status, out, _ = self.run_cli("where", "TextMouth/Services/Missing.swift")
        self.assertEqual((status, out), (1, ""))

    def test_the_text_form_names_the_line_and_the_heading(self) -> None:
        status, out, _ = self.run_cli("where", "TextMouth/Models/Book.swift")
        self.assertEqual(status, 0)
        first = out.splitlines()[0]
        self.assertTrue(first.startswith("docs/architecture/models.md:5-5  Models  "), first)
        self.assertIn("src: TextMouth/Models/Book.swift", first)


class NameTests(WhereCase):
    """A Swift name finds the units that hold it as a whole name."""

    def test_book_is_found_as_a_whole_name(self) -> None:
        hits = self.where("Book")
        self.assertEqual(self.last_status, 0)
        self.assertEqual((hits[0]["kind"], hits[0]["token"]), ("name", "Book"))

    def test_book_box_alone_does_not_match_book(self) -> None:
        # BookBox appears in the marker and the text, but never Book by itself.
        self.write_tree({"docs/user/box.md": "# Box\n\n## Only\n\nThe `BookBox` and BookBoxes only.\n"})
        paths = [hit["path"] for hit in self.where("Book")]
        self.assertNotIn("docs/user/box.md", paths)

    def test_the_boxes_section_matches_only_through_its_own_whole_book(self) -> None:
        # Its marker's src names BookBox.swift and its keys say box; only the prose has a whole Book.
        hits = [hit for hit in self.where("Book") if hit["id"] == "boxes"]
        self.assertEqual(len(hits), 1)
        self.assertIn("not a Book in itself", hits[0]["text"])

    def test_a_dotted_name_matches_book_storage_and_book_matches_inside_it(self) -> None:
        self.assertEqual(self.sections(self.where("Book.Storage")), ["models-book"])
        self.assertIn("models-book", self.sections(self.where("Book")))

    def test_book_matches_inside_a_path(self) -> None:
        self.write_tree({"docs/user/p.md": "# P\n\n## S\n\nSee Models/Book.swift now.\n"})
        paths = [hit["path"] for hit in self.where("Book")]
        self.assertIn("docs/user/p.md", paths)

    def test_one_hit_for_each_section_at_the_first_unit(self) -> None:
        models = [hit for hit in self.where("Book") if hit["id"] == "models-book"]
        self.assertEqual(len(models), 1)
        # The marker line holds `keys: Book`, so it comes first.
        self.assertEqual((models[0]["start"], models[0]["end"]), (5, 5))

    def test_the_match_is_case_sensitive(self) -> None:
        self.assertEqual(self.where("BOOK"), [])
        self.assertEqual(self.last_status, 1)


class OptionTests(WhereCase):
    """Scope, the usage error, and the JSON fields."""

    def test_scope_memory_reads_the_memory_pages_only(self) -> None:
        hits = self.where("TextMouth/Models/Book.swift", "--scope", "memory")
        self.assertEqual([hit["path"] for hit in hits], ["AGENTS.md"])
        hits = self.where("TextMouth/Models/Book.swift", "--scope", "all")
        self.assertEqual(len(hits), 3)

    def test_pages_come_in_scope_order(self) -> None:
        hits = self.where("TextMouth/Models/Book.swift")
        self.assertEqual([hit["path"] for hit in hits], sorted(hit["path"] for hit in hits))

    def test_a_name_that_is_none_of_the_three_is_a_usage_error(self) -> None:
        for name in ("two words", "a+b", "x(", "9lives"):
            with self.subTest(name=name):
                status, _, err = self.run_cli("where", name)
                self.assertEqual(status, 2)
                self.assertIn("where takes a path, a file name, or a Swift name; find searches words", err)

    def test_an_empty_name_is_a_usage_error(self) -> None:
        status, _, err = self.run_cli("where", " ")
        self.assertEqual(status, 2)
        self.assertIn("find searches words", err)

    def test_json_fields(self) -> None:
        hits = self.where("TextMouth/Models/Book.swift")
        self.assertEqual(
            sorted(hits[0]),
            ["end", "heading", "id", "kind", "path", "section_end", "section_start", "start", "text", "token"])
        self.assertEqual((hits[0]["section_start"], hits[0]["section_end"]), (3, 7))

    def test_max_caps_the_hits_and_says_so(self) -> None:
        status, out, err = self.run_cli("where", "TextMouth/Models/Book.swift", "--max", "1")
        self.assertEqual((status, len(out.splitlines())), (0, 1))
        self.assertIn("1 of 2 sections shown", err)


class NamesPathTests(WhereCase):
    """citations.names_path(): the rule where and affected share."""

    def cites(self, token: str, *paths: str) -> citations.Citation:
        """A citation of token that resolves to paths."""
        return citations.Citation(token, "text", 1, tuple(paths))

    def test_the_target_is_among_the_paths(self) -> None:
        cited = self.cites("Book.swift", "A/Book.swift", "B/Book.swift")
        self.assertTrue(citations.names_path(cited, "B/Book.swift", "x"))
        self.assertFalse(citations.names_path(cited, "C/Book.swift", "x"))

    def test_a_folder_holding_the_target_and_a_folder_the_target_holds(self) -> None:
        self.assertTrue(citations.names_path(self.cites("A/B/", "A/B/"), "A/B/C.swift", "x"))
        self.assertTrue(citations.names_path(self.cites("A/B.swift", "A/B.swift"), "A/", "x"))
        self.assertFalse(citations.names_path(self.cites("A/B/", "A/B/"), "A/BC/D.swift", "x"))

    def test_a_top_folder_names_itself_and_not_each_file_in_it(self) -> None:
        # testing.md names TextMouth/, which must not make it cite every app file.
        top = self.cites("TextMouth/", "TextMouth/")
        self.assertFalse(citations.names_path(top, "TextMouth/Models/Book.swift", "TextMouth/Models/Book.swift"))
        self.assertTrue(citations.names_path(top, "TextMouth/", "TextMouth/"))
        self.assertTrue(citations.is_top_folder("docs/"))
        self.assertFalse(citations.is_top_folder("docs/user/"))
        self.assertFalse(citations.is_top_folder("README.md"))

    def test_a_citation_naming_nothing_matches_by_its_spelling(self) -> None:
        gone = self.cites("Models/Gone.swift")
        self.assertTrue(citations.names_path(gone, "Models/Gone.swift", "other"))
        self.assertTrue(citations.names_path(gone, "TextMouth/Models/Gone.swift", "other"))
        self.assertTrue(citations.names_path(gone, "elsewhere", "TextMouth/Models/Gone.swift"))
        self.assertFalse(citations.names_path(gone, "Models/Other.swift", "Models/Other.swift"))

    def test_a_citation_that_resolves_ignores_its_spelling(self) -> None:
        cited = self.cites("Models/Book.swift", "TextMouth/Models/Book.swift")
        self.assertFalse(citations.names_path(cited, "Models/Book.swift", "Models/Book.swift"))


class OrderTests(WhereCase):
    """Where in a section the hit is."""

    def doc_hits(self) -> List[Dict]:
        """The hits for Book.swift in the page these tests write."""
        return [hit for hit in self.where("TextMouth/Models/Book.swift") if hit["path"] == "docs/user/o.md"]

    def test_the_marker_comes_before_a_files_line_and_the_text(self) -> None:
        self.write_tree({"docs/user/o.md": (
            "# O\n\n## S\n\n<!-- id: o-s; keys: x; src: TextMouth/Models/Book.swift -->\n"
            "The `Models/Book.swift` file is in the prose.\n\n- Files: Models/Book.swift\n")})
        self.assertEqual([(hit["kind"], hit["start"]) for hit in self.doc_hits()], [("src", 5)])

    def test_a_files_line_comes_before_the_prose_written_above_it(self) -> None:
        self.write_tree({"docs/user/o.md": (
            "# O\n\n## S\n\nThe `Models/Book.swift` file is in the prose.\n\n- Files: Models/Book.swift\n")})
        self.assertEqual([(hit["kind"], hit["start"]) for hit in self.doc_hits()], [("files", 7)])

