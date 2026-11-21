"""Tests of ids.py (FR39 phase 3): how an ID is formed from the Swift declaration that holds a string, how keys that
collide tell themselves apart, and what `check` refuses. Every test builds a small tree of its own in a temporary
folder (a catalog, some Swift sources, an ids.json); none reads the real sources or the user's library."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from scan_case import L10N  # noqa: F401  (puts the tools' folder on sys.path)

import catalog  # noqa: E402
import ids  # noqa: E402

# A path for a fixture source; its name matters only to the scanner's wording-file rule.
MODELS = "TextMouth/Models"


def make_tree(root: Path, sources: Dict[str, str], keys: List[str], table: Optional[dict] = None,
              retired: Optional[List[str]] = None) -> None:
    """Writes a catalog with `keys`, the Swift `sources` ({path under TextMouth/Models: text}), and optionally ids.json
    and retired-ids.txt, under `root`."""
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
    if table is not None:
        path = root / ids.IDS_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(ids.dump_table(table), encoding="utf-8")
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

    def proposed(self, sources: Dict[str, str], keys: List[str]) -> Dict[str, str]:
        """The IDs `propose` forms for `keys` held by `sources`."""
        make_tree(self.root, sources, keys)
        table, _forms = ids.propose(self.root, None, True)
        return table["ids"]


class FormTests(TreeCase):
    """The form of an ID by the declaration that holds the string."""

    def test_enum_of_statics_gives_owner_and_member(self) -> None:
        found = self.proposed({"SleepTimerWording.swift": '''
enum SleepTimerWording {
    // Translators: the timer's title.
    static var title: String { String(localized: "Sleep Timer") }
    // Translators: the timer's hint.
    static var hint: String { String(localized: "Stops playback later") }
}
'''}, ["Sleep Timer", "Stops playback later"])
        self.assertEqual(found, {"Sleep Timer": "sleepTimer.title", "Stops playback later": "sleepTimer.hint"})

    def test_switch_arm_adds_the_case(self) -> None:
        found = self.proposed({"ModeWording.swift": '''
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
'''}, ["Fast", "Slow", "Other"])
        self.assertEqual(found, {"Fast": "mode.title.fast", "Slow": "mode.title.slow", "Other": "mode.title.other"})

    def test_error_description_gives_way_to_the_case(self) -> None:
        found = self.proposed({"FooError.swift": '''
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
'''}, ["The file is gone.", "The file is locked."])
        self.assertEqual(found, {"The file is gone.": "fooError.gone", "The file is locked.": "fooError.locked"})

    def test_an_error_without_a_case_keeps_its_member(self) -> None:
        found = self.proposed({"BarError.swift": '''
struct BarError: LocalizedError {
    var errorDescription: String? { String(localized: "Bar failed.") }
}
'''}, ["Bar failed."])
        self.assertEqual(found, {"Bar failed.": "barError.errorDescription"})

    def test_a_key_that_several_types_use_is_common(self) -> None:
        found = self.proposed({
            "AWording.swift": 'enum AWording { static var cancel: String { String(localized: "Cancel") } }\n',
            "BWording.swift": 'enum BWording { static var stop: String { String(localized: "Cancel") } }\n'}, ["Cancel"])
        self.assertEqual(found, {"Cancel": "common.cancel"})

    def test_common_ids_read_as_their_english(self) -> None:
        found = self.proposed({
            "AWording.swift": 'enum AWording { static var a: String { String(localized: "Sleep Timer") } }\n',
            "BWording.swift": 'enum BWording { static var b: String { String(localized: "Sleep Timer") } }\n',
            "CWording.swift": 'enum CWording { static var c: String { String(localized: "Go to the %@ Book") } }\n',
            "DWording.swift": 'enum DWording { static var d: String { String(localized: "Go to the %@ Book") } }\n'},
            ["Sleep Timer", "Go to the %@ Book"])
        self.assertEqual(found["Sleep Timer"], "common.sleepTimer")
        # A common ID keeps the small words and names its placeholder: it reads as the English.
        self.assertEqual(found["Go to the %@ Book"], "common.goToTheValueBook")

    def test_a_member_holding_several_strings_takes_words_of_the_english(self) -> None:
        found = self.proposed({"CountWording.swift": '''
enum CountWording {
    static func saved(books: Bool) -> String {
        if books { return String(localized: "Saved books") }
        return String(localized: "Saved feeds")
    }
}
'''}, ["Saved books", "Saved feeds"])
        self.assertEqual(found, {"Saved books": "count.saved.books", "Saved feeds": "count.saved.feeds"})

    def test_a_key_in_several_members_of_one_type_takes_the_type_and_its_words(self) -> None:
        found = self.proposed({"OneWording.swift": '''
enum OneWording {
    static var first: String { String(localized: "Open the folder") }
    static var second: String { String(localized: "Open the folder") }
}
'''}, ["Open the folder"])
        self.assertEqual(found, {"Open the folder": "one.openFolder"})

    def test_nested_types_name_the_innermost(self) -> None:
        found = self.proposed({"Outer.swift": '''
struct Outer {
    enum InnerWording {
        static var label: String { String(localized: "Inner label") }
    }
    enum Wording {
        static var note: String { String(localized: "Plain note") }
    }
}
'''}, ["Inner label", "Plain note"])
        # An inner type that is only the word Wording is named by the type around it.
        self.assertEqual(found, {"Inner label": "inner.label", "Plain note": "outer.note"})

    def test_extension_of_a_dotted_type(self) -> None:
        found = self.proposed({"Ext.swift": '''
extension Book.Wording {
    static var shelf: String { String(localized: "On the shelf") }
}
'''}, ["On the shelf"])
        self.assertEqual(found, {"On the shelf": "book.shelf"})

    def test_a_local_constant_is_not_the_member(self) -> None:
        found = self.proposed({"LocalWording.swift": '''
enum LocalWording {
    static func summary(count: Int) -> String {
        let head = String(localized: "Summary head")
        return head
    }
}
'''}, ["Summary head"])
        self.assertEqual(found, {"Summary head": "local.summary"})

    def test_an_initializer_gives_way_to_the_words(self) -> None:
        found = self.proposed({"Row.swift": '''
struct Row {
    init() {
        title = String(localized: "Row title")
    }
}
'''}, ["Row title"])
        self.assertEqual(found, {"Row title": "row.title"})

    def test_percent_and_integer_placeholders_match_the_catalog_key(self) -> None:
        found = self.proposed({"VolWording.swift": '''
enum VolWording {
    // Translators: The volume. %lld is the percent.
    static func level(_ n: Int) -> String { String(localized: "Volume: \\(n)%") }
}
'''}, ["Volume: %lld%%"])
        self.assertEqual(found, {"Volume: %lld%%": "vol.level"})

    def test_the_note_tells_an_integer_key_from_a_text_key(self) -> None:
        found = self.proposed({"SecWording.swift": '''
enum SecWording {
    // Translators: Whole seconds. %lld is the number of seconds.
    static func whole(_ n: Int) -> String { String(localized: "\\(n) seconds") }
    // Translators: Seconds with a decimal. %@ is the already formatted number.
    static func decimal(_ s: String) -> String { String(localized: "\\(s) seconds") }
}
'''}, ["%lld seconds", "%@ seconds"])
        self.assertEqual(found, {"%lld seconds": "sec.whole", "%@ seconds": "sec.decimal"})


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
        frequency = ids.word_frequency(["Download the book", "Download the feed", "Download the index"])
        self.assertEqual(ids.slug("Download the feed", 1, frequency=frequency), "feed")

    def test_lighten_member_drops_filler_words(self) -> None:
        self.assertEqual(ids.lighten_member(["x", "titleForKind"]), ["x", "titleKind"])
        self.assertEqual(ids.lighten_member(["x", "notReadSentence"], ids.MEMBER_ENDINGS), ["x", "notRead"])

    def test_case_pattern_ignores_tuple_patterns(self) -> None:
        self.assertIsNone(ids._CASE.match("        case let (a, b):"))
        self.assertEqual(ids._CASE.match("        case let .failed(reason):").group(1), "failed")


class LengthTests(TreeCase):
    """IDs stay within the limit and keep to the pattern."""

    def test_a_long_member_is_shortened_by_its_filler_and_stays_in_the_pattern(self) -> None:
        member = "titleForTheVeryLongDescriptionOfTheThing"
        found = self.proposed({"LongWording.swift": f'''
enum LongWording {{
    static var {member}: String {{ String(localized: "Long one") }}
}}
'''}, ["Long one"])
        ident = found["Long one"]
        self.assertTrue(ids.ID_PATTERN.fullmatch(ident), ident)
        self.assertLessEqual(len(ident), ids.MAX_ID_LENGTH)

    def test_no_id_ends_in_a_number_the_english_does_not_hold(self) -> None:
        found = self.proposed({"NumWording.swift": '''
enum NumWording {
    static func f(_ a: Bool) -> String {
        if a { return String(localized: "Same words here") }
        return String(localized: "Same words here too")
    }
}
'''}, ["Same words here", "Same words here too"])
        for ident in found.values():
            self.assertFalse(ident[-1].isdecimal(), ident)
        self.assertEqual(len(set(found.values())), 2)


class SuggestTests(TreeCase):
    """`suggest FILE:LINE`."""

    SOURCE = '''
enum SugWording {
    // Translators: a title.
    static var title: String { String(localized: "A new title") }
}
'''

    def test_suggests_by_the_same_rules(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, ["A new title"], table={"version": 1, "ids": {}, "splits": {}})
        self.assertEqual(ids.suggest(self.root, f"{MODELS}/SugWording.swift:4"), "sug.title")

    def test_never_suggests_an_id_in_use_or_retired(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, ["A new title"],
                  table={"version": 1, "ids": {"Another": "sug.title"}, "splits": {}}, retired=["sug.title.newTitle"])
        ident = ids.suggest(self.root, f"{MODELS}/SugWording.swift:4")
        self.assertNotIn(ident, ("sug.title", "sug.title.newTitle"))
        self.assertTrue(ids.ID_PATTERN.fullmatch(ident))

    def test_refuses_a_line_with_no_call(self) -> None:
        make_tree(self.root, {"SugWording.swift": self.SOURCE}, ["A new title"])
        with self.assertRaises(SystemExit):
            ids.suggest(self.root, f"{MODELS}/SugWording.swift:2")


class CheckTests(TreeCase):
    """`check` refuses a table that breaks a rule."""

    SOURCE = '''
enum PairWording {
    static var one: String { String(localized: "One") }
    static var two: String { String(localized: "Two") }
}
enum OtherWording {
    static var three: String { String(localized: "One") }
}
'''

    def table(self, mapping: Dict[str, str], splits: Optional[dict] = None) -> dict:
        """A table of `mapping` and `splits`."""
        return {"version": 1, "ids": mapping, "splits": splits or {}}

    def problems(self, table: dict, keys: Optional[List[str]] = None, sources: Optional[Dict[str, str]] = None,
                 retired: Optional[List[str]] = None) -> List[str]:
        """What `check` reports for `table`."""
        make_tree(self.root, sources if sources is not None else {}, keys if keys is not None else ["One", "Two"],
                  table=table, retired=retired)
        return ids.check(self.root)

    def test_a_clean_table_passes(self) -> None:
        self.assertEqual(self.problems(self.table({"One": "common.one", "Two": "pair.two"})), [])

    def test_a_key_without_an_id(self) -> None:
        self.assertTrue(any("key without an ID: 'Two'" in p for p in self.problems(self.table({"One": "a.one"}))))

    def test_an_id_without_a_key(self) -> None:
        found = self.problems(self.table({"One": "a.one", "Two": "a.two", "Gone": "a.gone"}))
        self.assertTrue(any("ID without a key" in p and "a.gone" in p for p in found), found)

    def test_an_id_given_to_two_keys(self) -> None:
        found = self.problems(self.table({"One": "a.same", "Two": "a.same"}))
        self.assertTrue(any("given to 2 keys" in p for p in found), found)

    def test_an_id_outside_the_pattern(self) -> None:
        for bad in ("single", "Upper.case", "a.1b", "a..b", "a.b.c.d.e", "a.b-c", "a. b"):
            found = self.problems(self.table({"One": bad, "Two": "a.two"}))
            self.assertTrue(any("outside the pattern" in p for p in found), (bad, found))

    def test_an_id_over_the_length_limit(self) -> None:
        long = "a." + "b" * ids.MAX_ID_LENGTH
        found = self.problems(self.table({"One": long, "Two": "a.two"}))
        self.assertTrue(any("over 48" in p for p in found), found)
        edge = "a." + "b" * (ids.MAX_ID_LENGTH - 2)
        self.assertEqual(self.problems(self.table({"One": edge, "Two": "a.two"})), [])

    def test_a_retired_id(self) -> None:
        found = self.problems(self.table({"One": "a.old", "Two": "a.two"}), retired=["# the file's own line", "", "a.old"])
        self.assertTrue(any("retired ID given again" in p for p in found), found)

    def test_the_retired_files_comment_line_retires_nothing(self) -> None:
        self.assertEqual(self.problems(self.table({"One": "a.one", "Two": "a.two"}), retired=["# a.one"]), [])

    def test_a_split_must_cover_every_site_once(self) -> None:
        sources = {"PairWording.swift": self.SOURCE}
        path = f"{MODELS}/PairWording.swift"
        ok = {"One": [{"id": "common.one", "sites": [f"{path}:PairWording.one"]},
                      {"id": "other.three", "sites": [f"{path}:OtherWording.three"]}]}
        mapping = {"One": "common.one", "Two": "pair.two"}
        self.assertEqual(self.problems(self.table(mapping, ok), sources=sources), [])
        # A site no use covers.
        missing = {"One": [{"id": "common.one", "sites": [f"{path}:PairWording.one"]},
                           {"id": "other.three", "sites": []}]}
        found = self.problems(self.table(mapping, missing), sources=sources)
        self.assertTrue(any("no use covers" in p for p in found), found)
        # A site two uses cover.
        overlap = {"One": [{"id": "common.one", "sites": [f"{path}:PairWording.one", f"{path}:OtherWording.three"]},
                           {"id": "other.three", "sites": [f"{path}:OtherWording.three"]}]}
        found = self.problems(self.table(mapping, overlap), sources=sources)
        self.assertTrue(any("covered by 2 uses" in p for p in found), found)

    def test_a_split_naming_no_site_of_the_key(self) -> None:
        sources = {"PairWording.swift": self.SOURCE}
        path = f"{MODELS}/PairWording.swift"
        bad = {"One": [{"id": "common.one", "sites": [f"{path}:PairWording.one", f"{path}:OtherWording.three"]},
                       {"id": "other.three", "sites": [f"{path}:PairWording.nothing"]}]}
        found = self.problems(self.table({"One": "common.one", "Two": "pair.two"}, bad), sources=sources)
        self.assertTrue(any("holds no site of the key" in p for p in found), found)

    def test_a_split_key_id_must_be_one_of_its_split_ids(self) -> None:
        sources = {"PairWording.swift": self.SOURCE}
        path = f"{MODELS}/PairWording.swift"
        split = {"One": [{"id": "common.one", "sites": [f"{path}:PairWording.one"]},
                         {"id": "other.three", "sites": [f"{path}:OtherWording.three"]}]}
        found = self.problems(self.table({"One": "elsewhere.one", "Two": "pair.two"}, split), sources=sources)
        self.assertTrue(any("is not one of its split IDs" in p for p in found), found)

    def test_a_split_id_given_to_another_key(self) -> None:
        sources = {"PairWording.swift": self.SOURCE}
        path = f"{MODELS}/PairWording.swift"
        split = {"One": [{"id": "pair.two", "sites": [f"{path}:PairWording.one"]},
                         {"id": "other.three", "sites": [f"{path}:OtherWording.three"]}]}
        found = self.problems(self.table({"One": "pair.two", "Two": "pair.two"}, split), sources=sources)
        self.assertTrue(any("given to" in p for p in found), found)


class TableFileTests(TreeCase):
    """ids.json's text, and `propose` keeping what is frozen."""

    def test_the_table_round_trips(self) -> None:
        table = {"version": 1, "ids": {"B key": "x.b", "A “key”": "x.a"},
                 "splits": {"A “key”": [{"id": "x.a", "sites": ["f.swift:T.m"]}, {"id": "x.c", "sites": ["f.swift:T.n"]}]}}
        text = ids.dump_table(table)
        self.assertEqual(json.loads(text), table)
        # Sorted by key, one key to a line, so a diff reads.
        self.assertLess(text.index('"A “key”": "x.a"'), text.index('"B key": "x.b"'))

    def test_propose_keeps_the_existing_ids_and_adds_the_new(self) -> None:
        sources = {"KeepWording.swift": '''
enum KeepWording {
    static var old: String { String(localized: "Old one") }
    static var fresh: String { String(localized: "Fresh one") }
}
'''}
        make_tree(self.root, sources, ["Old one", "Fresh one"], table={"version": 1, "ids": {"Old one": "frozen.name"}, "splits": {}})
        table, _forms = ids.propose(self.root, None, False)
        self.assertEqual(table["ids"], {"Old one": "frozen.name", "Fresh one": "keep.fresh"})

    def test_propose_never_gives_a_retired_or_taken_id(self) -> None:
        sources = {"KeepWording.swift": 'enum KeepWording { static var fresh: String { String(localized: "Fresh one") } }\n'}
        make_tree(self.root, sources, ["Fresh one"], table={"version": 1, "ids": {"Other": "keep.fresh"}, "splits": {}},
                  retired=["keep.fresh.freshOne"])
        table, _forms = ids.propose(self.root, None, False)
        ident = table["ids"]["Fresh one"]
        self.assertNotIn(ident, ("keep.fresh", "keep.fresh.freshOne"))


if __name__ == "__main__":
    unittest.main()
