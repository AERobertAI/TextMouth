"""Tests of interface_calls.py (FR39 phase 5): reading the `InterfaceText.line` calls of Swift sources (ID, English as the
catalog's key, note, place), what makes a call unreadable, the check of each call against ids.json, and the
`.stringsdata` written for the sync. Every test works on a snippet or a small tree of its own."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from scan_case import L10N  # noqa: F401  (puts the tools' folder on sys.path)

import ids  # noqa: E402
import interface_calls  # noqa: E402
from swiftscan import lexer  # noqa: E402

FILE = "TextMouth/Models/SampleWording.swift"


def calls_of(code: str) -> List[interface_calls.Call]:
    """The calls of a snippet, read as the file FILE."""
    return interface_calls.find_calls(code, FILE)


class EnglishTests(unittest.TestCase):
    """The English of a call, as the key Xcode extracts from `String(localized:)`."""

    def english(self, literal: str) -> Optional[str]:
        """The English of the one call `InterfaceText.line("a.b", <literal>)`."""
        found = calls_of(f'InterfaceText.line("a.b", {literal})')
        self.assertEqual(len(found), 1)
        return found[0].english

    def test_a_plain_literal_is_kept_as_written_with_its_percent_sign(self) -> None:
        self.assertEqual(self.english('"100% done"'), "100% done")

    def test_an_interpolation_is_a_text_placeholder(self) -> None:
        self.assertEqual(self.english(r'"Starting: \(title)"'), "Starting: %@")

    def test_a_number_interpolation_is_a_lld_placeholder(self) -> None:
        self.assertEqual(self.english(r'"\(number: count) books"'), "%lld books")

    def test_a_percent_sign_is_doubled_where_the_literal_has_interpolations(self) -> None:
        self.assertEqual(self.english(r'"\(number: done) of \(name), \(number: percent)%"'), "%lld of %@, %lld%%")

    def test_the_code_of_an_interpolation_may_hold_strings_and_calls(self) -> None:
        self.assertEqual(self.english(r'"\(names.joined(separator: ", ")): \(number: items.count)"'), "%@: %lld")

    def test_a_number_label_is_read_whatever_the_spacing(self) -> None:
        self.assertEqual(self.english(r'"\( number : n )"'), "%lld")

    def test_a_literal_percent_at_in_a_plain_literal_is_not_mistaken_for_a_placeholder(self) -> None:
        self.assertEqual(self.english('"Use %@ here"'), "Use %@ here")

    def test_escapes_are_resolved(self) -> None:
        self.assertEqual(self.english(r'"Say \"hi\"\tnow"'), 'Say "hi"\tnow')

    def test_a_multi_line_literal_is_refused(self) -> None:
        found = calls_of('InterfaceText.line("a.b", """\n    one\n    two\n    """)')
        self.assertIsNone(found[0].english)
        self.assertTrue(found[0].problems)


class ReadingTests(unittest.TestCase):
    """What a call holds: its ID, note, line, and column; and what is not a call."""

    def test_the_id_note_line_and_column(self) -> None:
        found = calls_of('''enum SampleWording {
    // Translators: The title.
    static var title: String { InterfaceText.line("sample.title", "Title") }
}
''')
        self.assertEqual(len(found), 1)
        call = found[0]
        self.assertEqual((call.id, call.english, call.note, call.line), ("sample.title", "Title", "The title.", 3))
        # The column is the English literal's opening quote, counted from 1 in UTF-8 bytes.
        line = '    static var title: String { InterfaceText.line("sample.title", "Title") }'
        self.assertEqual(call.column, line.index('"Title"') + 1)
        self.assertEqual(call.problems, [])

    def test_the_column_counts_utf8_bytes(self) -> None:
        found = calls_of('let é = InterfaceText.line("a.b", "Café")')
        self.assertEqual(found[0].column, len('let é = InterfaceText.line("a.b", '.encode("utf-8")) + 1)

    def test_a_call_with_a_language_argument_is_read(self) -> None:
        found = calls_of('InterfaceText.line("a.b", "Title", language: "es")')
        self.assertEqual((found[0].id, found[0].english, found[0].problems), ("a.b", "Title", []))

    def test_a_wrapped_call_with_its_note_between_the_parenthesis_and_the_id(self) -> None:
        found = calls_of('''InterfaceText.line(
    // Translators: A heading.
    "a.b", "Heading \\(x)")
''')
        self.assertEqual((found[0].id, found[0].english, found[0].note, found[0].line), ("a.b", "Heading %@", "A heading.", 3))

    def test_prose_and_strings_that_mention_the_call_are_not_calls(self) -> None:
        self.assertEqual(calls_of('''/// Use `InterfaceText.line("a.b", "x")` for text.
// InterfaceText.line("a.b", "y")
let doc = "InterfaceText.line(\\"a.b\\", \\"z\\")"
'''), [])

    def test_a_call_inside_an_interpolation_is_a_call(self) -> None:
        found = calls_of('let s = "\\(InterfaceText.line("a.b", "Inner"))"')
        self.assertEqual([c.english for c in found], ["Inner"])

    def test_a_file_without_the_word_has_no_calls(self) -> None:
        self.assertEqual(calls_of('let s = String(localized: "x")'), [])

    def test_an_id_that_is_not_a_literal_is_refused(self) -> None:
        found = calls_of('InterfaceText.line(someID, "Title")')
        self.assertIsNone(found[0].id)
        self.assertTrue(any("ID" in p for p in found[0].problems))

    def test_an_id_with_an_interpolation_is_refused(self) -> None:
        found = calls_of('InterfaceText.line("a.\\(x)", "Title")')
        self.assertIsNone(found[0].id)

    def test_an_english_that_is_not_a_literal_is_refused(self) -> None:
        found = calls_of('InterfaceText.line("a.b", format)')
        self.assertIsNone(found[0].english)
        self.assertTrue(found[0].problems)

    def test_an_english_joined_to_another_literal_is_refused(self) -> None:
        found = calls_of('InterfaceText.line("a.b", "One " + "two")')
        self.assertIsNone(found[0].english)
        self.assertTrue(any("joined" in p for p in found[0].problems))

    def test_the_lexer_records_the_pieces_and_the_interpolations_of_a_literal(self) -> None:
        text = 'x("a %\\(n) of \\(f("q"))")'
        found = [lit for lit in lexer.lex(text, FILE) if lit.has_interp][0]
        self.assertEqual(found.pieces, ("a %", None, " of ", None, ""))
        self.assertEqual([text[begin:end] for begin, end in found.interps], ['\\(n)', '\\(f("q"))'])


class CheckCase(unittest.TestCase):
    """A temporary repository with one source file and an ids.json."""

    def setUp(self) -> None:
        self._folder = tempfile.TemporaryDirectory()
        self.addCleanup(self._folder.cleanup)
        self.root = Path(self._folder.name)

    def problems(self, source: str, table: Dict[str, str], splits: Optional[dict] = None, retired: Optional[set] = None,
                 notes: bool = True) -> List[str]:
        """The problems of the calls in `source` against an ids.json of `table` and `splits`."""
        target = self.root / FILE
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source, encoding="utf-8")
        calls = interface_calls.calls_in_tree(self.root)
        return interface_calls.problems_of(self.root, calls, {"version": 1, "ids": table, "splits": splits or {}},
                                           retired or set(), notes=notes)


class ProblemTests(CheckCase):
    """The check of each call against ids.json."""

    GOOD = '''enum SampleWording {
    // Translators: The title.
    static var title: String { InterfaceText.line("sample.title", "Title") }
}
'''

    def test_a_right_call_has_no_problem(self) -> None:
        self.assertEqual(self.problems(self.GOOD, {"Title": "sample.title"}), [])

    def test_an_id_that_is_not_the_keys_is_named_with_both(self) -> None:
        found = self.problems(self.GOOD, {"Title": "sample.heading"})
        self.assertEqual(len(found), 1)
        self.assertIn(f"{FILE}:3:", found[0])
        self.assertIn("'sample.title'", found[0])
        self.assertIn("'sample.heading'", found[0])

    def test_an_english_that_differs_from_the_key_by_one_character_is_refused(self) -> None:
        found = self.problems(self.GOOD.replace('"Title"', '"Title."'), {"Title": "sample.title"})
        self.assertEqual(len(found), 1)
        self.assertIn("not a key in ids.json", found[0])

    def test_an_id_outside_the_pattern_is_refused(self) -> None:
        found = self.problems(self.GOOD.replace("sample.title", "Sample_title"), {"Title": "Sample_title"})
        self.assertTrue(any("outside the pattern" in p for p in found))

    def test_an_id_over_the_length_limit_is_refused(self) -> None:
        long_id = "sample." + "a" * 60
        found = self.problems(self.GOOD.replace("sample.title", long_id), {"Title": long_id})
        self.assertTrue(any("outside the pattern" in p for p in found))

    def test_a_retired_id_is_refused(self) -> None:
        found = self.problems(self.GOOD, {"Title": "sample.title"}, retired={"sample.title"})
        self.assertEqual(len(found), 1)
        self.assertIn("retired", found[0])

    def test_a_missing_note_is_refused_but_not_when_the_notes_are_left_to_the_scanner(self) -> None:
        source = self.GOOD.replace("    // Translators: The title.\n", "")
        self.assertTrue(any("no `// Translators:" in p for p in self.problems(source, {"Title": "sample.title"})))
        self.assertEqual(self.problems(source, {"Title": "sample.title"}, notes=False), [])

    def test_two_calls_on_one_line_are_refused(self) -> None:
        source = '''enum SampleWording {
    // Translators: Two.
    static var both: String { InterfaceText.line("sample.a", "A") + InterfaceText.line("sample.b", "B") }
}
'''
        found = self.problems(source, {"A": "sample.a", "B": "sample.b"})
        self.assertEqual(len(found), 2)
        self.assertTrue(all("another call is on this line" in p for p in found))

    def test_a_split_key_takes_the_id_of_the_use_that_names_the_site(self) -> None:
        source = '''enum BookWording {
    // Translators: An author that is not known.
    static var author: String { InterfaceText.line("book.author", "Unknown") }
}
enum TimeFormatting {
    // Translators: A length that is not known.
    static var totalSeconds: String { InterfaceText.line("book.author", "Unknown") }
}
'''
        splits = {"Unknown": [{"id": "book.author", "sites": [f"{FILE}:BookWording.author"]},
                              {"id": "timeFormatting.total", "sites": [f"{FILE}:TimeFormatting.totalSeconds"]}]}
        found = self.problems(source, {"Unknown": "book.author"}, splits)
        self.assertEqual(len(found), 1)
        self.assertIn(f"{FILE}:7:", found[0])
        self.assertIn("'timeFormatting.total'", found[0])

    def test_a_call_that_cannot_be_read_is_named_with_its_place(self) -> None:
        found = self.problems(self.GOOD.replace('"sample.title"', "someID"), {"Title": "sample.title"})
        self.assertTrue(found and all(p.startswith(f"{FILE}:") for p in found))


class StringsdataTests(unittest.TestCase):
    """The `.stringsdata` of a file's calls, in the shape Xcode writes."""

    def test_the_shape_and_the_entries(self) -> None:
        calls = calls_of('''enum SampleWording {
    // Translators: Count of books.
    static func books(_ n: Int) -> String { InterfaceText.line("common.books", "\\(number: n) books") }
}
''')
        data = interface_calls.stringsdata("/work/src/" + FILE, calls)
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["source"], "/work/src/" + FILE)
        self.assertEqual(data["tables"], {"Localizable": [{
            "comment": "Count of books.", "key": "%lld books",
            "location": {"startingColumn": calls[0].column, "startingLine": 3}}]})

    def test_a_file_with_no_readable_call_has_no_table(self) -> None:
        data = interface_calls.stringsdata("/work/src/" + FILE, calls_of('InterfaceText.line(someID, "Title")'))
        self.assertEqual(data["tables"], {})


if __name__ == "__main__":
    unittest.main()
