"""Tests of ``suggest-src`` and ``suggest_paths``: the paths a section's marker src should cite."""

from __future__ import annotations

import json
from typing import List

from doclib_case import DocLibCase

import docmodel
from cmd_suggest_src import Suggestion, suggest_paths
from repofiles import RepoFiles
from swiftindex import SwiftIndex

PAGE = """\
# Reader

<!-- id: reader; keys: read; src: TextMouth/Parsers/Covered.swift -->
- Owner: ReaderViewModel is named here, ReaderViewModel again, and ReaderViewModel a third time.
- `startLibrary()` runs, and `ReaderViewModel` is backticked once; `openEverything()` has four homes.
- `Pair()` is declared twice and `Triple` three times; `EPUBParser.swift` is a file name, `Covered.swift` is in src.
- Files: Services/Saver.swift, Views/Library/.
"""


class SuggestSrcTests(DocLibCase):
    """suggest-src on a section holding each kind of suggestion."""

    def setUp(self) -> None:
        super().setUp()
        files = {
            "docs/p.md": PAGE,
            "TextMouth/Services/Saver.swift": "class Saver {}\n",
            "TextMouth/Views/Library/A.swift": "struct A {}\n",
            "TextMouth/Parsers/Covered.swift": "struct Covered {}\n",
            "TextMouth/Parsers/EPUBParser.swift": "struct EPUBParser {}\n",
            "TextMouth/ViewModels/ReaderViewModel.swift": "// head\nfinal class ReaderViewModel {}\n",
            "TextMouth/ViewModels/ReaderViewModel+More.swift": "extension ReaderViewModel {}\n",
            "TextMouth/Models/Library.swift": "\n\nfunc startLibrary() {}\n",
            "TextMouth/Two/One.swift": "func Pair() {}\n",
            "TextMouth/Two/Two.swift": "\nfunc Pair() {}\n",
        }
        for n in range(4):
            files[f"TextMouth/Four/F{n}.swift"] = "func openEverything() {}\n"
        for n in range(3):
            files[f"TextMouth/Three/T{n}.swift"] = "struct Triple {}\n"
        self.write_tree(files)

    def suggest(self, *args: str):
        """Run ``suggest-src``; return (status, hit lines, standard error)."""
        status, out, err = self.run_cli("suggest-src", *args)
        return status, out.splitlines(), err

    def test_files_first_then_by_how_often_named_then_by_first_mention(self) -> None:
        status, lines, err = self.suggest("reader")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(lines, [
            "TextMouth/Services/Saver.swift:1-1  Reader  Files: line",
            "TextMouth/Views/Library/:1-1  Reader  Files: line",
            "TextMouth/ViewModels/ReaderViewModel.swift:2-2  Reader  declares ReaderViewModel (named 4 times)",
            "TextMouth/Models/Library.swift:3-3  Reader  declares startLibrary() (named 1 time)",
            "TextMouth/Two/One.swift:1-1  Reader  declares Pair() (named 1 time)",
            "TextMouth/Two/Two.swift:2-2  Reader  declares Pair() (named 1 time)",
            "TextMouth/Parsers/EPUBParser.swift:1-1  Reader  file name EPUBParser.swift",
        ])

    def test_what_the_marker_src_covers_is_left_out_and_a_folder_covers_its_files(self) -> None:
        # Covered.swift is in src and named in the text; Saver.swift is under a src folder.
        self.write_tree({"docs/q.md": PAGE.replace("src: TextMouth/Parsers/Covered.swift",
                                                    "src: TextMouth/Parsers/Covered.swift, TextMouth/Services/")})
        _status, lines, _err = self.suggest("docs/q.md#Reader")
        paths = [line.split(":")[0] for line in lines]
        self.assertNotIn("TextMouth/Services/Saver.swift", paths)
        self.assertNotIn("TextMouth/Parsers/Covered.swift", paths)
        self.assertEqual(paths[0], "TextMouth/Views/Library/")

    def test_a_name_with_more_than_two_homes_is_not_suggested(self) -> None:
        _status, lines, _err = self.suggest("reader", "--max", "0")
        text = "\n".join(lines)
        self.assertNotIn("openEverything", text)
        self.assertNotIn("Triple", text)
        self.assertNotIn("Four/", text)
        self.assertNotIn("Three/", text)

    def test_the_extension_file_of_a_type_is_not_suggested(self) -> None:
        _status, lines, _err = self.suggest("reader", "--max", "0")
        self.assertFalse(any("ReaderViewModel+More" in line for line in lines))

    def test_a_path_found_twice_keeps_its_first_reason_and_adds_its_count(self) -> None:
        # Saver is in the Files: line and named in prose: still one suggestion, "Files: line".
        self.write_tree({"docs/r.md": "# R\n\nSaver, Saver and `Saver`.\n\nFiles: Services/Saver.swift\n"})
        _status, lines, _err = self.suggest("docs/r.md#R")
        self.assertEqual(lines, ["TextMouth/Services/Saver.swift:1-1  R  Files: line"])

    def test_a_section_with_nothing_to_suggest_exits_1(self) -> None:
        self.write_tree({"docs/n.md": "# N\n\nNothing named, but `true` and Reader.\n"})
        status, lines, err = self.suggest("docs/n.md#N")
        self.assertEqual((status, lines, err), (1, [], ""))

    def test_a_target_that_names_nothing_is_a_usage_error(self) -> None:
        status, lines, err = self.suggest("nope")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("no section has the id", err)

    def test_json_fields_and_the_cap(self) -> None:
        status, out, err = self.run_cli("suggest-src", "reader", "--json", "--max", "3")
        hits = [json.loads(line) for line in out.splitlines()]
        self.assertEqual((status, len(hits)), (0, 3))
        self.assertEqual(hits[2], {
            "path": "TextMouth/ViewModels/ReaderViewModel.swift", "start": 2, "end": 2, "heading": "Reader",
            "text": "declares ReaderViewModel (named 4 times)", "reason": "declares ReaderViewModel (named 4 times)"})
        self.assertIn("3 of 7 suggestions shown", err)

    def test_the_api_returns_suggestions_in_order(self) -> None:
        repo = RepoFiles.load(self.root)
        page = docmodel.load_page(self.root, "docs/p.md")
        found: List[Suggestion] = suggest_paths(page, page.sections[0], repo, SwiftIndex.load(repo))
        self.assertEqual(found[0], Suggestion("TextMouth/Services/Saver.swift", 1, "Files: line"))
        self.assertEqual(found[2], Suggestion("TextMouth/ViewModels/ReaderViewModel.swift", 2,
                                              "declares ReaderViewModel (named 4 times)"))
        self.assertEqual(len(found), 7)

    def test_a_section_without_a_marker_suggests_everything_it_names(self) -> None:
        self.write_tree({"docs/m.md": "# M\n\nSee `Saver` and `Saver.swift`.\n"})
        repo = RepoFiles.load(self.root)
        page = docmodel.load_page(self.root, "docs/m.md")
        found = suggest_paths(page, page.sections[0], repo, SwiftIndex.load(repo))
        self.assertEqual([s.path for s in found], ["TextMouth/Services/Saver.swift"])
        self.assertEqual(found[0].reason, "declares Saver (named 1 time)")
