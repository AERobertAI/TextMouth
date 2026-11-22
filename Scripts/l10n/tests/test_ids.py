"""Tests of ids.py (FR39 phase 3, as phase 7 left it): the words an ID is made of, and `suggest`, which proposes an ID clear
of every one in use. (`propose` and `check`, which made and checked ids.json, left in phase 7, with their tests.) Every test
builds a small tree of its own in a temporary folder (a catalog, some Swift sources); none reads the real sources or the
user's library."""

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
