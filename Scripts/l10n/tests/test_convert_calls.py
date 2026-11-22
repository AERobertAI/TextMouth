"""Tests of convert_calls.py (FR39 phase 5): the before and after of each pattern the design lists, every other byte of a
file staying as it was, and what the converter refuses. Each test builds a small tree of its own in a temporary folder
(Swift sources and an ids.json); none reads the real sources or the user's library."""

from __future__ import annotations

import io
import contextlib
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from scan_case import L10N  # noqa: F401  (puts the tools' folder on sys.path)

import convert_calls  # noqa: E402
import ids  # noqa: E402

# Where a fixture source lives, and the file it is by default.
MODELS = "TextMouth/Models"
FILE = f"{MODELS}/SampleWording.swift"


class ConvertCase(unittest.TestCase):
    """A temporary repository with Swift sources and an ids.json, and helpers to convert them."""

    def setUp(self) -> None:
        self._folder = tempfile.TemporaryDirectory()
        self.addCleanup(self._folder.cleanup)
        self.root = Path(self._folder.name)

    def make(self, sources: Dict[str, str], table: Dict[str, str], splits: Optional[dict] = None) -> None:
        """Writes the sources (by file name under TextMouth/Models/) and an ids.json of `table` ({key: ID}) and `splits`."""
        for name, text in sources.items():
            path = self.root / MODELS / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        target = ids.table_path(self.root)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(ids.dump_table({"version": 1, "ids": table, "splits": splits or {}}), encoding="utf-8")

    def convert(self, source: str, table: Dict[str, str], splits: Optional[dict] = None, name: str = "SampleWording.swift",
                write: bool = False) -> convert_calls.Result:
        """Converts the one file `source` and returns the result (writing the file only when `write`)."""
        self.make({name: source}, table, splits)
        return convert_calls.convert_tree(self.root, [f"{MODELS}/{name}"], None, write)

    def converted_text(self, source: str, table: Dict[str, str], splits: Optional[dict] = None) -> str:
        """The new text of the one file, which must have converted without a refusal."""
        result = self.convert(source, table, splits)
        self.assertEqual([str(r) for r in result.refused], [])
        return result.texts[FILE]


class PatternTests(ConvertCase):
    """Each pattern of the design, before and after."""

    def test_a_wording_property(self) -> None:
        text = self.converted_text('''enum SampleWording {
    // Translators: The sleep timer's title.
    static var title: String { String(localized: "Sleep Timer") }
}
''', {"Sleep Timer": "common.sleepTimer"})
        self.assertEqual(text, '''enum SampleWording {
    // Translators: The sleep timer's title.
    static var title: String { InterfaceText.line("common.sleepTimer", "Sleep Timer") }
}
''')

    def test_a_text_with_a_value_keeps_its_interpolation(self) -> None:
        text = self.converted_text('''enum FeedWording {
    // Translators: Shown when a feed's folder is gone. %@ is the feed's name.
    static func folderMissing(_ name: String) -> String {
        String(localized: "The folder of \\(name) is no longer in the library.")
    }
}
''', {"The folder of %@ is no longer in the library.": "feed.folderMissing"})
        self.assertIn('InterfaceText.line("feed.folderMissing", "The folder of \\(name) is no longer in the library.")', text)
        self.assertNotIn("number:", text)

    def test_a_count_becomes_a_number(self) -> None:
        text = self.converted_text('''enum CountWording {
    // Translators: A count of books. %lld is the count.
    static func books(_ count: Int) -> String { String(localized: "\\(count) books") }
}
''', {"%lld books": "common.books"})
        self.assertIn('InterfaceText.line("common.books", "\\(number: count) books")', text)

    def test_two_numbers_and_a_percent_sign(self) -> None:
        text = self.converted_text('''enum ProgressWording {
    // Translators: Progress. %1$lld of %2$@, %3$lld percent.
    static func value(done: Int, name: String, percent: Int) -> String {
        String(localized: "\\(done) of \\(name), \\(percent)%")
    }
}
''', {"%lld of %@, %lld%%": "readerCloud.progressValue.of"})
        self.assertIn('InterfaceText.line("readerCloud.progressValue.of", "\\(number: done) of \\(name), \\(number: percent)%")', text)

    def test_a_switch_arm(self) -> None:
        text = self.converted_text('''enum KeyWording {
    static func words(for key: Key) -> String {
        switch key {
        // Translators: The End key's name.
        case .end: return String(localized: "End")
        // Translators: The Home key's name.
        case .home: return String(localized: "Home")
        }
    }
}
''', {"End": "keyWording.words.end", "Home": "keyWording.words.home"})
        self.assertIn('case .end: return InterfaceText.line("keyWording.words.end", "End")', text)
        self.assertIn('case .home: return InterfaceText.line("keyWording.words.home", "Home")', text)

    def test_a_literal_with_no_interpolation_and_a_percent_sign_stays_as_written(self) -> None:
        text = self.converted_text('''enum SampleWording {
    // Translators: Said at the end of a download.
    static var done: String { String(localized: "100% done") }
}
''', {"100% done": "sample.done"})
        self.assertIn('InterfaceText.line("sample.done", "100% done")', text)

    def test_the_note_and_every_other_byte_stay(self) -> None:
        source = '''import Foundation

// A header comment, with   odd   spacing.
enum SampleWording {
\t/// Documentation stays.
\t// Translators: A title.
\tstatic var title: String {   String(localized: "Title")   }  // trailing
    static var other = "not interface text"
}
'''
        text = self.converted_text(source, {"Title": "sample.title"})
        self.assertEqual(text, source.replace('String(localized: "Title")', 'InterfaceText.line("sample.title", "Title")'))

    def test_a_note_between_string_and_its_label_stays_above_the_english(self) -> None:
        text = self.converted_text('''enum SampleWording {
    static func heading(title: String, author: String) -> String {
        String(
            // Translators: A search result's heading. %1$@ is the title and %2$@ the author.
            localized: "\\(title), by \\(author)")
    }
}
''', {"%@, by %@": "sample.heading"})
        self.assertEqual(text, '''enum SampleWording {
    static func heading(title: String, author: String) -> String {
        InterfaceText.line(
            // Translators: A search result's heading. %1$@ is the title and %2$@ the author.
            "sample.heading", "\\(title), by \\(author)")
    }
}
''')

    def test_two_calls_on_one_file_convert_from_the_end_without_shifting_each_other(self) -> None:
        text = self.converted_text('''enum SampleWording {
    // Translators: First.
    static var a: String { String(localized: "Alpha") }
    // Translators: Second.
    static var b: String { String(localized: "Beta \\(1)") }
}
''', {"Alpha": "sample.a", "Beta %@": "sample.b"})
        self.assertIn('InterfaceText.line("sample.a", "Alpha")', text)
        self.assertIn('InterfaceText.line("sample.b", "Beta \\(1)")', text)

    def test_a_converted_file_is_read_back_as_calls_holding_the_key_and_the_id(self) -> None:
        text = self.converted_text('''enum SampleWording {
    // Translators: A count.
    static func books(_ count: Int) -> String { String(localized: "\\(count) of \\(count)%") }
}
''', {"%lld of %lld%%": "sample.books"})
        import interface_calls
        found = interface_calls.find_calls(text, FILE)
        self.assertEqual([(c.id, c.english) for c in found], [("sample.books", "%lld of %lld%%")])


class SplitTests(ConvertCase):
    """A key that is split takes the ID of the use that names each site."""

    SOURCE = '''enum BookWording {
    // Translators: An author that is not known.
    static var author: String { String(localized: "Unknown") }
}
enum TimeFormatting {
    // Translators: A length that is not known.
    static var totalSeconds: String { String(localized: "Unknown") }
}
'''
    SPLITS = {"Unknown": [
        {"id": "book.author", "sites": [f"{FILE}:BookWording.author"]},
        {"id": "timeFormatting.totalSeconds", "sites": [f"{FILE}:TimeFormatting.totalSeconds"]},
    ]}

    def test_each_site_takes_its_own_id(self) -> None:
        text = self.converted_text(self.SOURCE, {"Unknown": "book.author"}, self.SPLITS)
        self.assertIn('InterfaceText.line("book.author", "Unknown")', text)
        self.assertIn('InterfaceText.line("timeFormatting.totalSeconds", "Unknown")', text)

    def test_a_site_no_use_names_is_refused_and_the_others_still_convert(self) -> None:
        source = self.SOURCE + '''enum ThirdWording {
    // Translators: A third.
    static var third: String { String(localized: "Unknown") }
}
'''
        result = self.convert(source, {"Unknown": "book.author"}, self.SPLITS)
        self.assertEqual(len(result.converted), 2)
        self.assertEqual(len(result.refused), 1)
        self.assertIn("has no ID at this site", result.refused[0].reason)
        self.assertEqual(result.refused[0].line, 11)


class RefusalTests(ConvertCase):
    """A call that cannot be tied to one key and one ID is named with its file and line, and left as it was."""

    def refusals(self, source: str, table: Dict[str, str]) -> List[str]:
        """The refusals, as `file:line: reason`, of converting `source`."""
        return [str(r) for r in self.convert(source, table).refused]

    def test_a_text_with_no_key_is_refused_with_its_file_and_line(self) -> None:
        found = self.refusals('''enum SampleWording {
    // Translators: Nobody knows it.
    static var a: String { String(localized: "Not in the table") }
}
''', {"Something else": "sample.else"})
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith(f"{FILE}:3: the text 'Not in the table' ties to no key"), found[0])

    def test_two_keys_that_read_alike_are_settled_by_the_note(self) -> None:
        source = '''enum SampleWording {
    // Translators: Seconds spent. %lld is a whole number.
    static func a(_ n: Int) -> String { String(localized: "\\(n) seconds") }
    // Translators: A label. %@ is already formatted text.
    static func b(_ s: String) -> String { String(localized: "\\(s) seconds") }
}
'''
        result = self.convert(source, {"%lld seconds": "sample.a", "%@ seconds": "sample.b"})
        self.assertEqual(result.refused, [])
        self.assertIn('InterfaceText.line("sample.a", "\\(number: n) seconds")', result.texts[FILE])
        self.assertIn('InterfaceText.line("sample.b", "\\(s) seconds")', result.texts[FILE])

    def test_two_keys_that_read_alike_and_a_note_that_settles_nothing_are_refused(self) -> None:
        found = self.refusals('''enum SampleWording {
    // Translators: Seconds spent.
    static func a(_ n: Int) -> String { String(localized: "\\(n) seconds") }
}
''', {"%lld seconds": "sample.a", "%@ seconds": "sample.b"})
        self.assertEqual(len(found), 1)
        self.assertIn("ties to no key", found[0])

    def test_a_comment_argument_or_any_other_argument_is_refused(self) -> None:
        found = self.refusals('''enum SampleWording {
    // Translators: A title.
    static var a: String { String(localized: "Title", comment: "A title") }
}
''', {"Title": "sample.title"})
        self.assertEqual(len(found), 1)
        self.assertIn("an argument besides the literal", found[0])

    def test_another_localized_form_is_refused(self) -> None:
        found = self.refusals('''enum SampleWording {
    // Translators: A title.
    static var a: LocalizedStringResource { LocalizedStringResource("Title") }
}
''', {"Title": "sample.title"})
        self.assertEqual(len(found), 1)
        self.assertIn("a form this tool does not convert", found[0])

    def test_a_multi_line_literal_is_refused(self) -> None:
        found = self.refusals('''enum SampleWording {
    // Translators: Two lines.
    static var a: String { String(localized: """
        Hello
        there
        """) }
}
''', {"Hello\nthere": "sample.hello"})
        self.assertEqual(len(found), 1)
        self.assertIn("multi-line or raw", found[0])

    def test_a_key_whose_placeholders_do_not_match_the_interpolations_is_refused(self) -> None:
        # The key reads `%@ items` once `%%` folds, but the literal holds two interpolations in the same text.
        found = self.refusals('''enum SampleWording {
    // Translators: Items.
    static func a(_ n: Int) -> String { String(localized: "\\(n) items") }
}
''', {"%lld items": "sample.items", "%@ items": "sample.items2"})
        self.assertEqual(len(found), 1)

    def test_nothing_is_written_for_a_refused_call(self) -> None:
        source = '''enum SampleWording {
    // Translators: Nobody knows it.
    static var a: String { String(localized: "Not in the table") }
}
'''
        result = self.convert(source, {"Other": "sample.other"}, write=True)
        self.assertEqual(result.texts, {})
        self.assertEqual((self.root / FILE).read_text(), source)


class CommandTests(ConvertCase):
    """The command line: --check writes nothing and reports; a plain run writes."""

    SOURCE = '''enum SampleWording {
    // Translators: A title.
    static var a: String { String(localized: "Title") }
}
'''

    def run_main(self, *argv: str) -> "tuple[int, str]":
        """(exit status, printed text) of the command on this test's tree, made on the first call."""
        if not (self.root / FILE).exists():
            self.make({"SampleWording.swift": self.SOURCE}, {"Title": "sample.title"})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = convert_calls.main(["--root", str(self.root), "--locations", str(self.root / "none.json"), *argv])
        return status, out.getvalue()

    def test_check_reports_and_writes_nothing(self) -> None:
        status, text = self.run_main("--check")
        self.assertEqual(status, 0)
        self.assertIn("would convert 1 calls in 1 files; refused 0", text)
        self.assertEqual((self.root / FILE).read_text(), self.SOURCE)

    def test_a_run_writes_the_file(self) -> None:
        status, text = self.run_main()
        self.assertEqual(status, 0)
        self.assertIn("converted 1 calls in 1 files; refused 0", text)
        self.assertIn('InterfaceText.line("sample.title", "Title")', (self.root / FILE).read_text())

    def test_a_refusal_gives_exit_status_one_and_names_the_line(self) -> None:
        self.make({"SampleWording.swift": self.SOURCE}, {"Other": "sample.other"})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = convert_calls.main(["--root", str(self.root), "--check", "--locations", str(self.root / "none.json")])
        self.assertEqual(status, 1)
        self.assertIn(f"{FILE}:3:", out.getvalue())

    def test_a_file_that_does_not_exist_is_a_usage_error(self) -> None:
        self.make({"SampleWording.swift": self.SOURCE}, {"Title": "sample.title"})
        with contextlib.redirect_stderr(io.StringIO()):
            status = convert_calls.main(["--root", str(self.root), "TextMouth/Models/Nope.swift"])
        self.assertEqual(status, 2)

    def test_converting_twice_converts_nothing_more(self) -> None:
        self.run_main()
        status, text = self.run_main()
        self.assertEqual(status, 0)
        self.assertIn("converted 0 calls", text)


if __name__ == "__main__":
    unittest.main()
