"""Tests of ``code``: from a section to the files it cites and the declarations it names."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

PAGE = """\
# Saving

<!-- id: saving; keys: save; src: TextMouth/Services/Saver.swift, gone/Missing.swift -->
- Owner: ReaderViewModel.shared, which `startLibrary()` calls; also `Many` and `Book.Storage`.
- Files: Services/Saver.swift, Views/Library/, Gone.swift.

## Quiet

<!-- id: quiet -->
Nothing to see here, only `true` and `Info.plist`.
"""

SAVER = "// one\n// two\nclass Saver {}\n"

# A name declared in five files.
MANY = {f"TextMouth/Many/Many{n}.swift": "final class Many {}\n" for n in range(5)}


class CodeTests(DocLibCase):
    """code on a section with a Files: line, calls, bare and dotted names, a name with five declarations, and a miss."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "docs/architecture/saving.md": PAGE,
            "TextMouth/Services/Saver.swift": SAVER,
            "TextMouth/Views/Library/A.swift": "struct A {}\n",
            "TextMouth/Views/Library/B.swift": "struct B {}",
            "TextMouth/ViewModels/ReaderViewModel.swift": "// head\nfinal class ReaderViewModel {\n}\nextension ReaderViewModel {}\n",
            "TextMouth/Models/Book.swift": "struct Book {\n    struct Storage {}\n}\nfunc startLibrary() {}\n",
            **MANY,
        })

    def code(self, *args: str):
        """Run ``code`` with ``args``; return (status, output lines, standard error)."""
        status, out, err = self.run_cli("code", *args)
        return status, out.splitlines(), err

    def test_paths_first_in_citation_order_then_declarations_in_mention_order(self) -> None:
        status, lines, err = self.code("saving", "--max", "0")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(lines, [
            # src: a file with its line count, then a path that names nothing.
            "TextMouth/Services/Saver.swift:1-3  cited (src)  file",
            "gone/Missing.swift:0-0  cited (src)  missing",
            # Files: the same file is not repeated; a folder counts its files.
            "TextMouth/Views/Library/:1-1  cited (files)  folder of 2 files",
            # A bare source file name that resolves to nothing is missing too.
            "Gone.swift:0-0  cited (files)  missing",
            # Names, in order of first mention: ReaderViewModel (bare), startLibrary(), Many, Book.Storage.
            "TextMouth/ViewModels/ReaderViewModel.swift:2-2  ReaderViewModel  final class ReaderViewModel {",
            "TextMouth/ViewModels/ReaderViewModel.swift:4-4  ReaderViewModel  extension ReaderViewModel {}",
            "TextMouth/Models/Book.swift:4-4  startLibrary()  func startLibrary() {}",
            "TextMouth/Many/Many0.swift:1-1  Many  final class Many {}",
            "TextMouth/Many/Many1.swift:1-1  Many  final class Many {}",
            "TextMouth/Many/Many2.swift:1-1  Many  final class Many {} (+2 more)",
            "TextMouth/Models/Book.swift:2-2  Book.Storage  struct Storage {}",
        ])

    def test_a_file_without_a_final_line_end_still_counts_its_last_line(self) -> None:
        self.write_tree({"docs/p.md": "# P\n\n<!-- id: p; src: TextMouth/Views/Library/B.swift -->\n"})
        _status, lines, _err = self.code("p")
        self.assertEqual(lines, ["TextMouth/Views/Library/B.swift:1-1  cited (src)  file"])

    def test_a_citation_in_prose_is_cited_text(self) -> None:
        self.write_tree({"docs/p.md": "# P\n\nSee `Services/Saver.swift`.\n"})
        _status, lines, _err = self.code("docs/p.md#P")
        self.assertEqual(lines, ["TextMouth/Services/Saver.swift:1-3  cited (text)  file"])

    def test_a_backticked_file_name_is_a_path_and_not_a_code_name(self) -> None:
        # ``Saver.swift`` has the shape of a dotted name, but its declaration of Saver is not listed.
        self.write_tree({"docs/p.md": "# P\n\nSee `Saver.swift`.\n"})
        _status, lines, _err = self.code("docs/p.md#P")
        self.assertEqual(lines, ["TextMouth/Services/Saver.swift:1-3  cited (text)  file"])

    def test_a_missing_citation_is_listed_once(self) -> None:
        self.write_tree({"docs/p.md": "# P\n\n<!-- id: p; src: a/b.swift -->\nFiles: a/b.swift\n"})
        # a/b.swift is no repository path in a Files: line (its first folder is unknown), the src entry is.
        _status, lines, _err = self.code("p")
        self.assertEqual(lines, ["a/b.swift:0-0  cited (src)  missing"])

    def test_a_bare_file_name_that_names_two_files_lists_both(self) -> None:
        self.write_tree({"docs/p.md": "# P\n\nSee `Dup.swift`.\n", "TextMouth/A/Dup.swift": "x\n",
                         "TextMouth/B/Dup.swift": "y\n"})
        _status, lines, _err = self.code("docs/p.md#P")
        self.assertEqual(lines, ["TextMouth/A/Dup.swift:1-1  cited (text)  file",
                                 "TextMouth/B/Dup.swift:1-1  cited (text)  file"])

    def test_a_section_with_nothing_to_show_exits_1(self) -> None:
        status, lines, err = self.code("quiet")
        self.assertEqual((status, lines, err), (1, [], ""))

    def test_a_target_that_names_nothing_is_a_usage_error(self) -> None:
        status, lines, err = self.code("no-such-section")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("no section has the id", err)

    def test_the_cap_names_what_was_left_out(self) -> None:
        status, lines, err = self.code("saving", "--max", "2")
        self.assertEqual((status, len(lines)), (0, 2))
        self.assertIn("2 of 11 hits shown", err)

    def test_the_default_cap_is_twenty(self) -> None:
        names = " ".join(f"`F{n}`" for n in range(25))
        decls = "\n".join(f"func F{n}() {{}}" for n in range(25))
        self.write_tree({"docs/p.md": f"# P\n\n{names}\n", "TextMouth/F.swift": decls})
        _status, lines, err = self.code("docs/p.md#P")
        self.assertEqual(len(lines), 20)
        self.assertIn("20 of 25 hits shown", err)

    def test_json_fields(self) -> None:
        status, out, _err = self.run_cli("code", "saving", "--json", "--max", "0")
        self.assertEqual(status, 0)
        hits = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(hits[0], {
            "path": "TextMouth/Services/Saver.swift", "start": 1, "end": 3, "heading": "cited (src)",
            "text": "file", "kind": "path", "name": "TextMouth/Services/Saver.swift", "decl_kind": None})
        self.assertEqual(hits[1]["kind"], "path")
        self.assertEqual((hits[1]["path"], hits[1]["start"], hits[1]["end"]), ("gone/Missing.swift", 0, 0))
        self.assertEqual(hits[2]["name"], "Views/Library/")
        self.assertEqual((hits[3]["path"], hits[3]["text"]), ("Gone.swift", "missing"))
        self.assertEqual(hits[4], {
            "path": "TextMouth/ViewModels/ReaderViewModel.swift", "start": 2, "end": 2,
            "heading": "ReaderViewModel", "text": "final class ReaderViewModel {",
            "kind": "declaration", "name": "ReaderViewModel", "decl_kind": "class"})
        self.assertEqual(hits[5]["decl_kind"], "extension")
