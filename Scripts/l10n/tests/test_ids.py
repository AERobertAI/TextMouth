"""Tests of ids.py (FR39 phase 3, as phase 7 left it): the words an ID is made of, and `suggest`, which proposes an ID clear
of every one in use. (`propose` and `check`, which made and checked ids.json, left in phase 7, with their tests.) Every test
builds a small tree of its own in a temporary folder (a catalog, some Swift sources); none reads the real sources or the
user's library."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from scan_case import L10N  # noqa: F401  (puts the tools' folder on sys.path)

import catalog  # noqa: E402
import ids  # noqa: E402

# A path for a fixture source; its name matters only to the scanner's wording-file rule.
MODELS = "TextMouth/Models"


def make_tree(root: Path, sources: Dict[str, str], keys: List[str], retired: Optional[List[str]] = None) -> None:
    """Writes a catalog with `keys`, the Swift `sources` ({path under TextMouth/Models: text}), and optionally
    retired-ids.txt, under `root`."""
    cat = catalog.Catalog.empty()
    for key in keys:
        cat.strings[key] = {}
    target = root / ids.CATALOG_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    cat.save(target)
    for name, text in sources.items():
        path = root / MODELS / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    if retired is not None:
        path = root / ids.RETIRED_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(retired) + "\n", encoding="utf-8")


class TreeCase(unittest.TestCase):
    """A test with a temporary repository folder."""

    def setUp(self) -> None:
        self._folder = tempfile.TemporaryDirectory()
        self.addCleanup(self._folder.cleanup)
        self.root = Path(self._folder.name)


class WordTests(unittest.TestCase):
    """The pieces an ID is made of."""

    def test_owner_names(self) -> None:
        self.assertEqual(ids.owner_segment("SleepTimerWording"), "sleepTimer")
        self.assertEqual(ids.owner_segment("EPUBExportWriter"), "epubExportWriter")
        self.assertEqual(ids.owner_segment("DAISYPackageError"), "daisyPackageError")
        self.assertEqual(ids.owner_segment("FFmpegImport"), "ffmpegImport")
        self.assertEqual(ids.owner_segment("AVSpeechSynthesisVoice"), "avSpeechSynthesisVoice")
        self.assertEqual(ids.owner_segment("Book"), "book")
        self.assertEqual(ids.owner_segment("Text"), "text")  # the suffix is kept when nothing else would be left

    def test_slug_skips_small_words_and_placeholders(self) -> None:
        self.assertEqual(ids.slug("Move Book to Trash?", 3), "moveBookTrash")
        self.assertEqual(ids.slug("The drive “%@” isn't connected.", 9), "driveIsntConnected")
        self.assertEqual(ids.slug("Save it as UTF-8, then import it again.", 6, keep_stopwords=True), "saveItAsUtf8ThenImport")

    def test_slug_of_a_text_with_no_word_names_its_punctuation(self) -> None:
        self.assertEqual(ids.slug("%@, %@", 9), "valueCommaValue")
        self.assertEqual(ids.slug("(%@)", 9), "openValueClose")

    def test_a_slug_never_starts_with_a_number(self) -> None:
        self.assertEqual(ids.slug("3 books", 3), "n3Books")

    def test_the_rarest_words_tell_keys_apart(self) -> None:
        # How many English texts hold each word: "download" is in all three, so the rarer "feed" tells this text apart.
        frequency = {"download": 3, "the": 3, "book": 1, "feed": 1, "index": 1}
        self.assertEqual(ids.slug("Download the feed", 1, frequency=frequency), "feed")

    def test_a_slug_never_repeats_a_word_the_id_already_holds(self) -> None:
        held = {"feed", "stays"}
        # Content words the earlier segments lack come first.
        self.assertEqual(ids.slug("Mark all played items", 3, avoid={"mark", "played"}), "allItems")
        # With too little left, the first words from the first one the ID lacks, small words too.
        self.assertEqual(ids.slug("%@ stays in its feed: %@", 3, avoid=held), "inItsFeed")
        self.assertEqual(ids.make_id(["feed", "stays"], "%@ stays in its feed: %@", 2), "feed.stays.inIts")

    def test_lighten_member_drops_filler_words(self) -> None:
        self.assertEqual(ids.lighten_member(["x", "titleForKind"]), ["x", "titleKind"])
        self.assertEqual(ids.lighten_member(["x", "notReadSentence"], ids.MEMBER_ENDINGS), ["x", "notRead"])

    def test_case_pattern_ignores_tuple_patterns(self) -> None:
        self.assertIsNone(ids._CASE.match("        case let (a, b):"))
        self.assertEqual(ids._CASE.match("        case let .failed(reason):").group(1), "failed")


class SuggestFormTests(TreeCase):
    """The form of an ID by the declaration that holds the string, asked of `suggest` for one call site (main's FormTests and
    LengthTests asked it of the retired `propose`; these keep their sources and their expected IDs).

    Not ported, because they are about several sites of one key or several keys of one member, which only `propose`'s
    collision resolution decided (`suggest` answers one site, with the bare declaration first): a key that several types use
    is `common`, common IDs reading as their English, a member holding several strings taking words of the English, and a key
    in several members of one type taking the type and its words."""

    def suggested(self, name: str, source: str, needle: str) -> str:
        """The ID `suggest` gives the call on the first line of `source` (written as `name`) that holds `needle`."""
        make_tree(self.root, {name: source}, [])
        line = next(number for number, row in enumerate(source.split("\n"), 1) if needle in row)
        return ids.suggest(self.root, f"{MODELS}/{name}:{line}")

    def test_enum_of_statics_gives_owner_and_member(self) -> None:
        source = '''
enum SleepTimerWording {
    // Translators: the timer's title.
    static var title: String { String(localized: "Sleep Timer") }
    // Translators: the timer's hint.
    static var hint: String { String(localized: "Stops playback later") }
}
'''
        self.assertEqual(self.suggested("SleepTimerWording.swift", source, '"Sleep Timer"'), "sleepTimer.title")
        self.assertEqual(self.suggested("SleepTimerWording.swift", source, '"Stops playback later"'), "sleepTimer.hint")

    def test_switch_arm_adds_the_case(self) -> None:
        source = '''
enum ModeWording {
    static func title(for mode: Mode) -> String {
        switch mode {
        case .fast:
            return String(localized: "Fast")
        case .slow(let by):
            return String(localized: "Slow")
        case .other: return String(localized: "Other")
        }
    }
}
'''
        for text, expected in (("Fast", "mode.title.fast"), ("Slow", "mode.title.slow"), ("Other", "mode.title.other")):
            self.assertEqual(self.suggested("ModeWording.swift", source, f'"{text}"'), expected)

    def test_error_description_gives_way_to_the_case(self) -> None:
        source = '''
enum FooError: LocalizedError {
    case gone
    case locked
    var errorDescription: String? {
        switch self {
        case .gone: return String(localized: "The file is gone.")
        case .locked:
            return String(localized: "The file is locked.")
        }
    }
}
'''
        self.assertEqual(self.suggested("FooError.swift", source, '"The file is gone."'), "fooError.gone")
        self.assertEqual(self.suggested("FooError.swift", source, '"The file is locked."'), "fooError.locked")

    def test_an_error_without_a_case_keeps_its_member(self) -> None:
        source = '''
struct BarError: LocalizedError {
    var errorDescription: String? { String(localized: "Bar failed.") }
}
'''
        self.assertEqual(self.suggested("BarError.swift", source, '"Bar failed."'), "barError.errorDescription")

    def test_nested_types_name_the_innermost(self) -> None:
        source = '''
struct Outer {
    enum InnerWording {
        static var label: String { String(localized: "Inner label") }
    }
    enum Wording {
        static var note: String { String(localized: "Plain note") }
    }
}
'''
        # An inner type that is only the word Wording is named by the type around it.
        self.assertEqual(self.suggested("Outer.swift", source, '"Inner label"'), "inner.label")
        self.assertEqual(self.suggested("Outer.swift", source, '"Plain note"'), "outer.note")

    def test_extension_of_a_dotted_type(self) -> None:
        source = '''
extension Book.Wording {
    static var shelf: String { String(localized: "On the shelf") }
}
'''
        self.assertEqual(self.suggested("Ext.swift", source, '"On the shelf"'), "book.shelf")

    def test_a_local_constant_is_not_the_member(self) -> None:
        source = '''
enum LocalWording {
    static func summary(count: Int) -> String {
        let head = String(localized: "Summary head")
        return head
    }
}
'''
        self.assertEqual(self.suggested("LocalWording.swift", source, '"Summary head"'), "local.summary")

    def test_an_initializer_gives_way_to_the_words(self) -> None:
        source = '''
struct Row {
    init() {
        title = String(localized: "Row title")
    }
}
'''
        self.assertEqual(self.suggested("Row.swift", source, '"Row title"'), "row.title")

    def test_percent_and_integer_placeholders_match_the_english(self) -> None:
        source = '''
enum VolWording {
    // Translators: The volume. %lld is the percent.
    static func level(_ n: Int) -> String { String(localized: "Volume: \\(n)%") }
}
'''
        self.assertEqual(self.suggested("VolWording.swift", source, "Volume"), "vol.level")

    def test_the_note_tells_an_integer_from_a_text(self) -> None:
        source = '''
enum SecWording {
    // Translators: Whole seconds. %lld is the number of seconds.
    static func whole(_ n: Int) -> String { String(localized: "\\(n) seconds") }
    // Translators: Seconds with a decimal. %@ is the already formatted number.
    static func decimal(_ s: String) -> String { String(localized: "\\(s) seconds") }
}
'''
        self.assertEqual(self.suggested("SecWording.swift", source, "func whole"), "sec.whole")
        self.assertEqual(self.suggested("SecWording.swift", source, "func decimal"), "sec.decimal")

    def test_a_long_member_is_shortened_by_its_filler_and_stays_in_the_pattern(self) -> None:
        member = "titleForTheVeryLongDescriptionOfTheThing"
        source = f'''
enum LongWording {{
    static var {member}: String {{ String(localized: "Long one") }}
}}
'''
        ident = self.suggested("LongWording.swift", source, '"Long one"')
        self.assertTrue(ids.ID_PATTERN.fullmatch(ident), ident)
        self.assertLessEqual(len(ident), ids.MAX_ID_LENGTH)

    def test_no_id_ends_in_a_number_the_english_does_not_hold(self) -> None:
        source = '''
enum NumWording {
    static func f(_ a: Bool) -> String {
        if a { return String(localized: "Same words here") }
        return String(localized: "Same words here too")
    }
}
'''
        for text in ('"Same words here"', '"Same words here too"'):
            self.assertFalse(self.suggested("NumWording.swift", source, text)[-1].isdecimal())


class SuggestTests(TreeCase):
    """`suggest FILE:LINE`."""

    SOURCE = '''
enum SugWording {
    // Translators: a title.
    static var title: String { String(localized: "A new title") }
}
'''

    def test_suggests_by_the_same_rules(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, [])
        self.assertEqual(ids.suggest(self.root, f"{MODELS}/SugWording.swift:4"), "sug.title")

    def test_never_suggests_an_id_in_the_catalog_or_retired(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, ["sug.title"], retired=["sug.title.newTitle"])
        ident = ids.suggest(self.root, f"{MODELS}/SugWording.swift:4")
        self.assertNotIn(ident, ("sug.title", "sug.title.newTitle"))
        self.assertTrue(ids.ID_PATTERN.fullmatch(ident))

    def test_never_suggests_an_id_a_call_of_the_code_already_uses(self) -> None:
        other = '''
enum OtherWording {
    // Translators: a heading.
    static var heading: String { InterfaceText.line("sug.title", "Heading") }
}
'''
        make_tree(self.root, {"SugWording.swift": self.SOURCE, "OtherWording.swift": other}, [])
        self.assertNotEqual(ids.suggest(self.root, f"{MODELS}/SugWording.swift:4"), "sug.title")

    def test_refuses_a_line_with_no_call(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, ["A new title"])
        with self.assertRaises(SystemExit):
            ids.suggest(self.root, f"{MODELS}/SugWording.swift:2")


if __name__ == "__main__":
    unittest.main()
