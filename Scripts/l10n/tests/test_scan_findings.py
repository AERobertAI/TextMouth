"""The findings: what the conversion must restructure around a literal, reported and never failed on."""

from __future__ import annotations

import unittest

from scan_case import WORDING, ScanCase, scan_snippet


def findings(code: str, path: str = "TextMouth/Views/Snippet.swift") -> list:
    """The findings of every literal of a snippet, as (text, findings) pairs."""
    return [(lit.text, lit.findings) for lit in scan_snippet(code, path)]


class GluedSentenceTests(ScanCase):
    """Sentences built from pieces."""

    def test_a_literal_glued_to_a_variable_with_plus(self) -> None:
        # ViewModels/ReaderViewModel+CloudDownload.swift:219 builds a message from pieces like this.
        code = 'let message = "Downloading " + title + " from the cloud."'
        self.assertEqual(findings(code), [("Downloading ", ("glued",)), (" from the cloud.", ("glued",))])

    def test_pieces_over_several_lines(self) -> None:
        # ViewModels/LibraryViewModel+Migration.swift:250.
        code = 'let note = "Adopted \\(count) books, "\n    + "kept \\(kept) as they were."'
        self.assertEqual([f for _t, f in findings(code)], [("glued",), ("glued",)])

    def test_two_plain_literals_wrapped_over_two_lines_are_one_sentence(self) -> None:
        # Views/Library/LibraryIndexRecoveryViews.swift:38.
        code = 'static let a = "Closes these options so you can keep reading. "\n    + "The index is not changed."'
        self.assertEqual([f for _t, f in findings(code)], [("static-let",), ("static-let",)])

    def test_joined_literals_are_glued(self) -> None:
        # App/QuitFinisher.swift:33.
        code = 'let list = ["one thing", "another thing", other].joined(separator: ", ")'
        self.assertEqual(findings(code)[:2], [("one thing", ("glued",)), ("another thing", ("glued",))])

    def test_a_marked_line_has_no_findings(self) -> None:
        code = 'let message = "Downloading " + title // l10n: no'
        self.assertEqual(findings(code), [("Downloading ", ())])


class HandBuiltPluralTests(ScanCase):
    """A plural built from a singular and a plural word."""

    def test_count_wording_phrase(self) -> None:
        # Models/CountWording.swift:34: phrase(count, singular: "book", plural: "books").
        code = 'phrase(count, singular: "book", plural: "books")'
        self.assertEqual(findings(code), [("book", ("plural",)), ("books", ("plural",))])

    def test_a_noun_pair(self) -> None:
        # ViewModels/TextExtractionProgress.swift:16.
        code = 'static let itemNoun = CountWording.Noun(singular: "book extracted", plural: "books extracted")'
        self.assertEqual([f for _t, f in findings(code)], [("plural", "static-let")] * 2)

    def test_a_count_compared_with_one_in_a_ternary(self) -> None:
        # ViewModels/LibraryViewModel+OggConversion.swift:56.
        code = 'let subject = books.count == 1 ? "its Ogg audio" : "their Ogg audio"'
        self.assertEqual([f for _t, f in findings(code)], [("plural",), ("plural",)])

    def test_other_comparisons_with_one(self) -> None:
        # ViewModels/LibraryViewModel+BookOperations.swift:1239.
        for compare in ("movable > 1", "n != 1", "n >= 2", "n <= 1", "n < 2"):
            code = f'return {compare} ? "Move these books" : "Move this book"'
            self.assertEqual(findings(code)[0][1], ("plural",), compare)

    def test_a_comparison_with_zero_is_not_a_plural(self) -> None:
        # ViewModels/LibraryViewModel+SortAndOrder.swift:23 chooses above or below, not one or many.
        code = 'return "Moved \\(title) \\(direction < 0 ? "above" : "below") \\(other)"'
        self.assertEqual(findings(code)[0], ("Moved %@ %@ %@", ()))


class StaticLetTests(ScanCase):
    """Interface text kept in a static let is read once, in whatever language was current."""

    def test_a_static_let_in_a_wording_type(self) -> None:
        # Models/AddToLibraryWording.swift:9.
        code = 'enum AddToLibraryWording {\n    static let sheetTitle = "Add to Library"\n}'
        lit = scan_snippet(code, WORDING)[0]
        self.assertEqual((lit.status, lit.findings, lit.wording, lit.static_let), ("unlocalized", ("static-let",), True, 2))

    def test_a_static_var_that_computes_is_not_a_finding(self) -> None:
        code = 'enum AddToLibraryWording {\n    static var sheetTitle: String { "Add to Library" }\n}'
        self.assertEqual(scan_snippet(code, WORDING)[0].findings, ())

    def test_a_static_func_is_not_a_finding(self) -> None:
        # Models/LibraryCloudWording.swift:312.
        code = 'enum CloudWording {\n    static func note() -> String { "Downloaded and ready to read." }\n}'
        self.assertEqual(scan_snippet(code, WORDING)[0].findings, ())

    def test_a_localized_line_kept_in_a_static_let_is_a_finding_too(self) -> None:
        # Synthetic: an InterfaceText.line in a static let would be cached in the wrong language.
        code = 'enum W {\n    static let title = InterfaceText.line("sleep.title", "Sleep timer")\n}'
        found = scan_snippet(code)
        self.assertEqual([(l.text, l.status, l.findings) for l in found],
                         [("sleep.title", "", ()), ("Sleep timer", "localized", ("static-let",))])

    def test_a_static_let_that_is_a_key_or_a_number_is_not_text(self) -> None:
        code = 'enum Keys {\n    static let maximum = 10\n    static let cacheKey = "bookmarks.v2"\n}'
        self.assertEqual([l.findings for l in scan_snippet(code)], [()])


if __name__ == "__main__":
    unittest.main()
