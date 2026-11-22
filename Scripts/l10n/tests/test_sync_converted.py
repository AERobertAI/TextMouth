"""Tests of `l10n.py sync` in its transition mode (FR39 phase 5): the `InterfaceText.line` calls of the type-checked sources
are written as `.stringsdata` beside the compiler's, so that `xcstringstool sync` keeps their keys and notes, and each call
is checked against ids.json first, a mismatch refusing the sync with nothing written.

The tests run on the recorded runs of test_l10n's SyncCase (made-up paths, no build, no lock) with a converted source file
added to each run's sources and an ids.json in the made-up checkout; the ones that run the real `xcstringstool` skip when
it is not installed."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import catalog  # noqa: E402
import ids  # noqa: E402
import l10n  # noqa: E402
import test_l10n  # noqa: E402  (the module, not its classes, so that its tests are not run again here)

# The converted source file each run holds, and the calls in it.
CONVERTED = "TextMouth/Models/ConvertedWording.swift"
GOOD = '''enum ConvertedWording {
    // Translators: The title of the converted wording.
    static var title: String { InterfaceText.line("converted.title", "Converted title") }
    // Translators: How many books. %lld is the count.
    static func books(_ n: Int) -> String { InterfaceText.line("converted.books", "\\(number: n) converted books") }
}
'''
TABLE = {"Converted title": "converted.title", "%lld converted books": "converted.books"}


class ConvertedCase(test_l10n.SyncCase):
    """The recorded runs with a converted file in each, and an ids.json."""

    def setUp(self) -> None:
        super().setUp()
        self.write_ids(TABLE)

    def write_ids(self, table, splits=None) -> None:
        """Writes ids.json in the made-up checkout the sync reads it from."""
        target = ids.table_path(self.checkout)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(ids.dump_table({"version": 1, "ids": table, "splits": splits or {}}), encoding="utf-8")

    def write_converted(self, text: str) -> None:
        """Puts the source `text` under CONVERTED in both runs' copies of the sources."""
        for platform in l10n.PLATFORMS:
            target = self.source_roots[platform] / CONVERTED
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")


class AddConvertedCallsTests(ConvertedCase):
    """`add_converted_calls`: the check, and the files it writes."""

    def test_each_run_gets_a_stringsdata_file_in_the_shape_xcode_writes(self) -> None:
        self.write_converted(GOOD)
        manifests = self.manifests()
        self.assertEqual(l10n.add_converted_calls(manifests, self.checkout), 4, "two calls in each of the two runs")
        for manifest in manifests:
            added = [name for name in manifest["files"] if name.startswith(l10n.CONVERTED_FOLDER + "/")]
            self.assertEqual(len(added), 1)
            data = json.loads((manifest["folder"] / added[0]).read_text())
            self.assertEqual(data["source"], str(Path(manifest["sourceRoot"]) / CONVERTED))
            self.assertEqual([entry["key"] for entry in data["tables"]["Localizable"]], ["Converted title", "%lld converted books"])
            self.assertEqual(data["tables"]["Localizable"][0]["comment"], "The title of the converted wording.")
            self.assertEqual(data["tables"]["Localizable"][0]["location"]["startingLine"], 3)

    def test_no_file_is_written_when_nothing_is_converted(self) -> None:
        manifests = self.manifests()
        self.assertEqual(l10n.add_converted_calls(manifests, self.checkout), 0)
        self.assertFalse((manifests[0]["folder"] / l10n.CONVERTED_FOLDER).exists())

    def test_a_wrong_id_refuses_and_names_the_call_and_both_ids(self) -> None:
        self.write_converted(GOOD.replace("converted.title", "converted.heading"))
        with self.assertRaises(l10n.Refused) as caught:
            l10n.add_converted_calls(self.manifests(), self.checkout)
        message = str(caught.exception)
        self.assertIn(f"{CONVERTED}:3", message)
        self.assertIn("'converted.heading'", message)
        self.assertIn("'converted.title'", message)

    def test_an_english_that_is_not_the_key_refuses(self) -> None:
        self.write_converted(GOOD.replace('"Converted title"', '"Converted titles"'))
        with self.assertRaises(l10n.Refused) as caught:
            l10n.add_converted_calls(self.manifests(), self.checkout)
        self.assertIn("not a key in ids.json", str(caught.exception))

    def test_a_missing_note_refuses(self) -> None:
        self.write_converted(GOOD.replace("    // Translators: The title of the converted wording.\n", ""))
        with self.assertRaises(l10n.Refused) as caught:
            l10n.add_converted_calls(self.manifests(), self.checkout)
        self.assertIn("Translators", str(caught.exception))

    def test_a_retired_id_refuses(self) -> None:
        self.write_converted(GOOD)
        retired = self.checkout / ids.RETIRED_PATH
        retired.parent.mkdir(parents=True, exist_ok=True)
        retired.write_text("converted.title\n", encoding="utf-8")
        with self.assertRaises(l10n.Refused) as caught:
            l10n.add_converted_calls(self.manifests(), self.checkout)
        self.assertIn("retired", str(caught.exception))

    def test_a_call_that_is_not_two_plain_literals_refuses(self) -> None:
        self.write_converted(GOOD.replace('"converted.title"', "someID"))
        with self.assertRaises(l10n.Refused):
            l10n.add_converted_calls(self.manifests(), self.checkout)

    def test_a_split_key_is_checked_by_site(self) -> None:
        self.write_converted('''enum ConvertedWording {
    // Translators: An author.
    static var author: String { InterfaceText.line("converted.author", "Unknown") }
}
enum ConvertedTime {
    // Translators: A length.
    static var length: String { InterfaceText.line("converted.author", "Unknown") }
}
''')
        splits = {"Unknown": [{"id": "converted.author", "sites": [f"{CONVERTED}:ConvertedWording.author"]},
                              {"id": "converted.length", "sites": [f"{CONVERTED}:ConvertedTime.length"]}]}
        self.write_ids({"Unknown": "converted.author"}, splits)
        with self.assertRaises(l10n.Refused) as caught:
            l10n.add_converted_calls(self.manifests(), self.checkout)
        self.assertIn("'converted.length'", str(caught.exception))
        self.assertNotIn(f"{CONVERTED}:3", str(caught.exception), "the first site is right")


@unittest.skipUnless(test_l10n.HAS_TOOL, "xcstringstool is not installed")
class ConvertedSyncTests(ConvertedCase):
    """The whole sync with converted calls: nothing stale, notes and places kept, a mismatch writing nothing."""

    def seed_catalog(self) -> None:
        """A catalog that already holds the converted keys, as the real one does before their file converts."""
        self.catalog = self.write_catalog({
            "Converted title": test_l10n.entry("The title of the converted wording.", es=test_l10n.unit("Titulo convertido")),
            "%lld converted books": test_l10n.entry("How many books. %lld is the count."),
        })

    def test_the_keys_of_a_converted_file_are_kept_not_marked_stale(self) -> None:
        self.seed_catalog()
        self.write_converted(GOOD)
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertFalse(cat.is_stale(cat.strings["Converted title"]))
        self.assertFalse(cat.is_stale(cat.strings["%lld converted books"]))
        self.assertEqual(cat.units("Converted title", "es")[0].value, "Titulo convertido", "the translation is untouched")

    def test_without_the_converted_calls_the_same_keys_would_be_stale(self) -> None:
        """The control: the compiler no longer sees a converted file's keys, so the sync's own file is what keeps them."""
        self.seed_catalog()
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertTrue(cat.is_stale(cat.strings["Converted title"]))

    def test_the_note_and_the_place_of_a_converted_call_reach_the_catalog_and_the_locations(self) -> None:
        self.catalog = self.write_catalog({})
        self.write_converted(GOOD)
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertEqual(cat.strings["Converted title"]["comment"], "The title of the converted wording.")
        self.assertEqual(cat.strings["%lld converted books"]["comment"], "How many books. %lld is the count.")
        places = json.loads(self.locations.read_text())["Localizable"]
        self.assertEqual(places["Converted title"], [{"file": CONVERTED, "line": 3}])
        self.assertEqual(places["%lld converted books"], [{"file": CONVERTED, "line": 5}])

    def test_a_second_sync_changes_nothing(self) -> None:
        self.seed_catalog()
        self.write_converted(GOOD)
        self.sync()
        first = catalog.read_text(self.catalog)
        self.sync()
        self.assertEqual(catalog.read_text(self.catalog), first)

    def test_the_count_of_converted_files_is_the_compilers_not_the_added_ones(self) -> None:
        self.seed_catalog()
        self.write_converted(GOOD)
        self.sync()
        text = "\n".join(self.lines)
        self.assertIn("read 4 InterfaceText.line calls and checked each against ids.json", text)
        self.assertIn("strings of 6 converted files", text, "six files are the compiler's; the two added ones do not count")

    def test_a_mismatch_refuses_and_leaves_the_catalog_as_it_was(self) -> None:
        self.seed_catalog()
        before = catalog.read_text(self.catalog)
        self.write_converted(GOOD.replace("converted.books", "converted.bookCount"))
        with self.assertRaises(l10n.Refused):
            self.sync()
        self.assertEqual(catalog.read_text(self.catalog), before)
        self.assertFalse(self.locations.exists(), "no locations were written")


if __name__ == "__main__":
    unittest.main()
