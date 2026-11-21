"""Tests of citations.py: what a section's prose cites."""

from __future__ import annotations

from typing import List

from doclib_case import DocLibCase

from citations import (
    FILES_LINE, IDENTIFIER, Citation, citations, code_spans, files_block_paths, identifier_positions, identifier_spans,
    line_of, path_tokens,
)
from repofiles import RepoFiles

# The files of a small repository the citations resolve against.
FILES = [
    "project.yml",
    "Scripts/agents/run_locked.py",
    "Vendor/lame/lame.c",
    "TextMouth/Models/AudioEdit.swift",
    "TextMouth/Services/X.swift",
    "TextMouth/Services/BookExportService.swift",
    "TextMouth/Services/SpeechExport/Job.swift",
    "TextMouth/ViewModels/LibraryViewModel.swift",
    "TextMouth/Parsers/DOCXParser+Numbering.swift",
]


class PathTokenTests(DocLibCase):
    """path_tokens(): split at white space and commas, wrappers stripped."""

    def tokens(self, text: str) -> List[str]:
        """Just the tokens of ``text``."""
        return [token for _, token in path_tokens(text)]

    def test_split_at_white_space_and_commas(self) -> None:
        self.assertEqual(self.tokens("a/b.swift, c/d.swift  e/f.swift,g/h.swift"),
                         ["a/b.swift", "c/d.swift", "e/f.swift", "g/h.swift"])

    def test_wrappers_are_stripped(self) -> None:
        self.assertEqual(self.tokens('("a/b.swift"), [c/d.swift]; (e/f.swift).'),
                         ["a/b.swift", "c/d.swift", "e/f.swift"])

    def test_a_trailing_slash_stays(self) -> None:
        self.assertEqual(self.tokens("Vendor/lame/, Services/SpeechExport/."), ["Vendor/lame/", "Services/SpeechExport/"])

    def test_offsets_point_at_the_token(self) -> None:
        text = "  (a/b.swift), c/d.swift."
        for offset, token in path_tokens(text):
            self.assertEqual(text[offset: offset + len(token)], token)

    def test_a_piece_that_is_only_wrappers_gives_nothing(self) -> None:
        self.assertEqual(self.tokens("( ) , ."), [])


class FilesBlockTests(DocLibCase):
    """FILES_LINE and files_block_paths()."""

    def test_files_line_matches_the_forms_the_pages_use(self) -> None:
        for text in ("Files: a.swift", "- Files: a.swift", "  - Files: a.swift", "* Files: a", "+ Files: a",
                     "**Files:** a", "- **Files:** a", "**Files**: a"):
            with self.subTest(text=text):
                self.assertIsNotNone(FILES_LINE.match(text))

    def test_files_line_does_not_match_other_blocks(self) -> None:
        for text in ("Owner: Files: a.swift", "The Files: a", "- Filesystem: a", "- Notes\n  Files: a"):
            with self.subTest(text=text):
                self.assertIsNone(FILES_LINE.match(text))

    def test_not_a_files_block_gives_none(self) -> None:
        self.assertIsNone(files_block_paths("- Owner: Models/AudioEdit.swift"))

    def test_notes_and_a_continuation_line(self) -> None:
        text = (
            "  - Files: Models/AudioEdit.swift, Services/BookExportService.swift (BookExportConversion),\n"
            "    ViewModels/LibraryViewModel.swift and its extensions, Vendor/lame, project.yml."
        )
        listed = files_block_paths(text)
        assert listed is not None
        tokens = [token for _, token in listed]
        self.assertEqual(tokens[:2], ["Models/AudioEdit.swift", "Services/BookExportService.swift"])
        # A note's words are tokens too; is_repo_path, not path_tokens, rejects them.
        self.assertIn("BookExportConversion", tokens)
        self.assertEqual(tokens[-2:], ["Vendor/lame", "project.yml"])
        self.assertIn("ViewModels/LibraryViewModel.swift", tokens)
        # Offsets are into the whole block, not the text after "Files:".
        for offset, token in listed:
            self.assertEqual(text[offset: offset + len(token)], token)

    def test_nothing_after_files_gives_an_empty_list(self) -> None:
        self.assertEqual(files_block_paths("- Files:"), [])


class CodeSpanTests(DocLibCase):
    """code_spans() is the sentence splitter's, re-exported."""

    def test_content_and_offsets(self) -> None:
        self.assertEqual(code_spans("a `b` c"), [(2, 5, "b")])

    def test_span_across_a_line_break(self) -> None:
        self.assertEqual(code_spans("a `b\nc` d"), [(2, 7, "b c")])


class CitationTests(DocLibCase):
    """citations(): the three kinds, in order, once each."""

    def setUp(self) -> None:
        """A RepoFiles over FILES."""
        super().setUp()
        self.repo = RepoFiles(self.root, FILES)

    def test_the_three_kinds_in_order(self) -> None:
        blocks = [
            (11, "Prose citing `Scripts/agents/run_locked.py` here."),
            (12, "- Files: Models/AudioEdit.swift, Vendor/lame, Services/Gone.swift."),
        ]
        found = citations(blocks, ["TextMouth/Services/X.swift", "Nope/x.swift"], 10, self.repo)
        self.assertEqual(
            found,
            [
                Citation("TextMouth/Services/X.swift", "src", 10, ("TextMouth/Services/X.swift",)),
                Citation("Nope/x.swift", "src", 10, ()),
                Citation("Models/AudioEdit.swift", "files", 12, ("TextMouth/Models/AudioEdit.swift",)),
                Citation("Vendor/lame", "files", 12, ("Vendor/lame/",)),
                Citation("Services/Gone.swift", "files", 12, ()),
                Citation("Scripts/agents/run_locked.py", "text", 11, ("Scripts/agents/run_locked.py",)),
            ],
        )

    def test_every_src_entry_is_cited_even_when_not_a_repo_path(self) -> None:
        found = citations([], ["/abs/path.swift", "x y", "~/z"], 3, self.repo)
        self.assertEqual([c.token for c in found], ["/abs/path.swift", "x y", "~/z"])
        self.assertTrue(all(c.paths == () and c.line == 3 and c.kind == "src" for c in found))

    def test_a_missing_marker_line_is_line_zero(self) -> None:
        self.assertEqual(citations([], ["a"], None, self.repo)[0].line, 0)

    def test_a_token_cited_twice_in_the_text_is_listed_once_at_its_first_place(self) -> None:
        blocks = [
            (5, "See `Models/AudioEdit.swift` first."),
            (6, "And `Models/AudioEdit.swift` again."),
        ]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([(c.token, c.line) for c in found], [("Models/AudioEdit.swift", 5)])

    def test_the_same_token_in_different_kinds_is_listed_for_each(self) -> None:
        blocks = [(5, "- Files: Models/AudioEdit.swift"), (6, "Uses `Models/AudioEdit.swift`.")]
        found = citations(blocks, ["Models/AudioEdit.swift"], 4, self.repo)
        self.assertEqual([c.kind for c in found], ["src", "files", "text"])

    def test_a_data_directory_path_in_backticks_is_not_cited(self) -> None:
        blocks = [(1, "The log is `Logs/textmouth.log`.")]
        self.assertEqual(citations(blocks, [], None, self.repo), [])

    def test_the_data_directory_itself_is_not_cited(self) -> None:
        blocks = [(1, "Data is in `~/.TextMouth` and `~/.TextMouth/library.json` and `/Library/Caches/x`.")]
        self.assertEqual(citations(blocks, [], None, self.repo), [])

    def test_a_path_in_prose_outside_backticks_is_not_cited(self) -> None:
        blocks = [(1, "See Models/AudioEdit.swift for it.")]
        self.assertEqual(citations(blocks, [], None, self.repo), [])

    def test_a_path_inside_a_command_span(self) -> None:
        blocks = [(1, "Run `python3 -I Scripts/agents/run_locked.py NAME` first.")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([c.token for c in found], ["Scripts/agents/run_locked.py"])

    def test_a_code_span_across_a_line_break_gives_each_token_its_line(self) -> None:
        blocks = [(20, "- Uses `Models/AudioEdit.swift\n  Services/X.swift` together.")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([(c.token, c.line) for c in found],
                         [("Models/AudioEdit.swift", 20), ("Services/X.swift", 21)])

    def test_a_padded_code_span_keeps_the_right_line(self) -> None:
        blocks = [(7, "text\nmore `` Models/AudioEdit.swift `` end")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([(c.token, c.line) for c in found], [("Models/AudioEdit.swift", 8)])

    def test_files_block_lines_follow_continuations(self) -> None:
        blocks = [(30, "- Files: Models/AudioEdit.swift,\n  Services/X.swift,\n  Vendor/lame.")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([(c.token, c.line) for c in found],
                         [("Models/AudioEdit.swift", 30), ("Services/X.swift", 31), ("Vendor/lame", 32)])

    def test_a_files_block_ignores_notes_that_are_not_paths(self) -> None:
        blocks = [(1, "- Files: Services/BookExportService.swift (BookExportConversion), "
                      "ViewModels/LibraryViewModel.swift and its extensions.")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([c.token for c in found],
                         ["Services/BookExportService.swift", "ViewModels/LibraryViewModel.swift"])

    def test_backticks_inside_a_files_block_are_not_a_second_citation(self) -> None:
        blocks = [(1, "- Files: Models/AudioEdit.swift (`Services/X.swift` too)")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual([(c.token, c.kind) for c in found], [("Models/AudioEdit.swift", "files")])

    def test_a_bare_file_name_resolves_by_name(self) -> None:
        blocks = [(1, "See `DOCXParser+Numbering.swift`.")]
        found = citations(blocks, [], None, self.repo)
        self.assertEqual(found[0].paths, ("TextMouth/Parsers/DOCXParser+Numbering.swift",))


class IdentifierTests(DocLibCase):
    """IDENTIFIER and identifier_spans()."""

    def test_names_that_match(self) -> None:
        for name in ("Book", "Book.Storage", "startLibrary()", "NSHostingController.sizeThatFits(in:)",
                     ".terminateCancel", "_private", "a.b.c(x:y:)"):
            with self.subTest(name=name):
                self.assertIsNotNone(IDENTIFIER.match(name))

    def test_shapes_that_do_not_match(self) -> None:
        for name in ("", "Book Storage", "f(a b)", "f(g(x))", "1Book", "Book.", "..x", "a/b.swift", "make check",
                     "Book\n", "-I"):
            with self.subTest(name=name):
                self.assertIsNone(IDENTIFIER.match(name))

    def test_identifiers_in_and_out_of_code_spans(self) -> None:
        blocks = [
            (3, "Book is not cited, but `Book` and `startLibrary()` are."),
            (4, "Also `make check`, `Services/X.swift`, and `.terminateCancel`."),
        ]
        self.assertEqual(identifier_spans(blocks), [(3, "Book"), (3, "startLibrary()"), (4, ".terminateCancel")])

    def test_files_blocks_are_skipped(self) -> None:
        blocks = [(1, "- Files: `Book`, Models/A.swift"), (2, "Uses `Book`.")]
        self.assertEqual(identifier_spans(blocks), [(2, "Book")])

    def test_positions_give_the_block_the_offset_and_the_line(self) -> None:
        # The Files: block is block 0 and gives none; in block 1 (starting on line 4) each backtick opens at its offset.
        blocks = [(1, "- Files: `Book`"), (4, "one\nab `Book` `x y` `run()`")]
        self.assertEqual(identifier_positions(blocks), [(1, 7, 5, "Book"), (1, 20, 5, "run()")])
        self.assertEqual(blocks[1][1][7], "`")
        self.assertEqual(blocks[1][1][20], "`")

    def test_line_of_counts_the_line_breaks_before_the_offset(self) -> None:
        self.assertEqual(line_of(10, "a\nb\ncd", 5), 12)
        self.assertEqual(line_of(10, "a\nb\ncd", 0), 10)

    def test_a_span_across_a_line_break_is_on_its_first_line(self) -> None:
        blocks = [(9, "a\nb `Book` c")]
        self.assertEqual(identifier_spans(blocks), [(10, "Book")])

    def test_a_padded_span_is_matched_by_its_content(self) -> None:
        self.assertEqual(identifier_spans([(1, "x `` Book `` y")]), [(1, "Book")])
