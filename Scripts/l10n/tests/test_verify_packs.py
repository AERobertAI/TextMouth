"""Tests of `verify_packs.py`: the proof that the engine, reading the pack, says what Apple's lookup of the catalog's tables
says, and that the system's choice of language is the one measured (TL16, TL18, FR39).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The catalogs are compiled by Apple's `xcstringstool` and read by the Swift probe, so these tests run on a Mac with Xcode only
(a few seconds each). They show that the proof is not vacuous: a pack that says something else is reported, and one built from
the same catalog passes. Since the switch (FR39 phase 8) there are no compact tables to compare: Apple's tables exist only
inside this proof.

The catalog is a small synthetic one keyed by ID (fixtures/squeeze-ids/Localizable.xcstrings, built from the awkward cases of
the old squeeze): Japanese (only `other`), Russian (`one`, `few`, `many`, `other`), and French (`one` covering 0), each entry
with its `en`. The repository's own catalog is read by `make l10n-check`, after the hosted test of the shipped pack has passed
on GitHub.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import verify_packs  # noqa: E402  (imported by path, after sys.path is set)

# The synthetic catalog keyed by ID (probe.key0, ... in the code-point order of the English keys), each entry with its `en`.
SQUEEZE_IDS_CATALOG = HERE / "fixtures" / "squeeze-ids" / "Localizable.xcstrings"


class VerifyPacksCase(unittest.TestCase):
    """Apple's tables compiled from a catalog, and the pack built from it, in a temporary folder."""

    catalog = SQUEEZE_IDS_CATALOG

    @classmethod
    def setUpClass(cls):
        folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(folder.cleanup)
        cls.root = Path(folder.name)
        cls.apple = cls.root / "apple"
        cls.apple.mkdir()
        subprocess.run(["xcrun", "xcstringstool", "compile", "--output-directory", str(cls.apple), str(cls.catalog)],
                       check=True, capture_output=True)
        cls.languages = verify_packs.catalog_languages(cls.catalog)
        verify_packs.write_app_info(cls.apple, cls.languages)
        # One compiled probe serves every class (it is rebuilt only when a source is newer); it copies itself into each folder
        # it reads, so no two tests share a copy.
        cls.probe = verify_packs.build_probe()

    def pack_arguments(self, catalog=None):
        """Builds the interface-text pack of `catalog` (the case's own by default) and returns the probe's arguments that
        name it."""
        pack = verify_packs.build_engine_pack(Path(catalog or self.catalog), self.root)
        return ["--pack", str(pack)]

    def run_probe(self, catalog=None, folder=None):
        """Run the probe on Apple's compiled folder (or `folder`), the pack built from `catalog` (the case's own by default);
        returns (status, output)."""
        done = subprocess.run(
            [str(self.probe), str(folder or self.apple), str(self.catalog), *self.pack_arguments(catalog), *self.languages],
            capture_output=True, text=True, check=False,
        )
        return done.returncode, done.stdout + done.stderr


class EngineReadingTests(VerifyPacksCase):
    """The engine's text from the interface-text pack equals Apple's table's for the same ID."""

    def test_the_catalog_holds_the_four_languages(self):
        self.assertEqual(self.languages, ["en", "fr", "ja", "ru"])

    def test_the_engine_reads_every_id_as_apple_does(self):
        """The engine's text equals Apple's table's for every ID, in every language, at every count."""
        status, output = self.run_probe()
        self.assertEqual(status, 0, output)
        self.assertRegex(output, r"probe: engine compared [1-9][0-9]* lookups in %d languages" % len(self.languages))
        self.assertIn(": 0 different, 0 IDs the lookups cannot feed, 0 problems reported", output)
        self.assertRegex(output, r"probe: engine timing \(-O\): ID list decode [0-9.]+ ms .* median lookup [0-9.]+ us")

    def test_each_language_reports_its_lookups_and_locale(self):
        """One line a language: its lookups, its time, and the locale both sides wrote with."""
        _, output = self.run_probe()
        for language in self.languages:
            self.assertRegex(output, r"probe: engine %s: [1-9][0-9]* lookups in [0-9.]+ s with [A-Za-z_@=-]+: 0 different; decode of the ID list [0-9.]+ ms, of this language [0-9.]+ ms, median lookup [0-9.]+ us" % language)

    def test_a_pack_that_says_something_else_is_reported(self):
        """The reading is not vacuous: a pack built from a catalog with one Russian text changed differs from Apple's tables,
        and the probe names the language and the ID."""
        strings = json.loads(Path(self.catalog).read_text(encoding="utf-8"))
        changed = None
        for key, entry in sorted(strings["strings"].items()):
            unit = entry.get("localizations", {}).get("ru", {}).get("stringUnit")
            english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")
            if unit and unit.get("state") != "new" and "%" not in english:
                unit["value"] += " (changed)"
                changed = key
                break
        self.assertIsNotNone(changed, "the catalog has no plain Russian string to change")
        altered = self.root / "altered.xcstrings"
        altered.write_text(json.dumps(strings), encoding="utf-8")
        status, output = self.run_probe(altered)
        self.assertEqual(status, 1, output)
        self.assertIn("ENGINE DIFFERENT: ru ", output)
        self.assertIn(f"ru {changed} (", output)
        self.assertNotIn("ENGINE DIFFERENT: ja ", output)

    def test_a_pack_that_is_not_there_is_a_usage_error(self):
        """--pack naming no file stops the probe with status 2 rather than comparing nothing."""
        done = subprocess.run(
            [str(self.probe), str(self.apple), str(self.catalog), "--pack", "no-such.pack", *self.languages],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(done.returncode, 2)
        self.assertIn("cannot open the pack", done.stdout + done.stderr)

    def test_a_folder_without_a_language_stops_the_probe(self):
        """An Apple folder without a language is a usage error, not a pass."""
        empty = Path(tempfile.mkdtemp(dir=self.root))
        status, output = self.run_probe(folder=empty)
        self.assertEqual(status, 2)
        self.assertIn("lacks", output)


class PreferenceTests(VerifyPacksCase):
    """The system's choice of language in a bundle laid out as the apps' are: Info.plist and .lproj folders, no table."""

    def app_folder(self):
        """The folder the pack's build writes, with the Info.plist that makes it an app's resources."""
        pack = verify_packs.build_engine_pack(self.catalog, self.root)
        verify_packs.write_app_info(pack.parent, self.languages)
        return pack.parent

    def test_the_apps_layout_holds_an_infoplist_strings_for_each_language_and_no_table(self):
        folder = self.app_folder()
        for language in self.languages:
            self.assertTrue((folder / f"{language}.lproj" / "InfoPlist.strings").is_file(), language)
        self.assertEqual(sorted(path.name for path in folder.glob("*.lproj/Localizable.*")), [])

    def test_each_preference_list_chooses_what_the_design_measured(self):
        """The measured matches (zh-Hant-TW gives zh-Hant, ...) hold for the languages this catalog has, in the app's layout
        and in the folder with the tables, and the two agree."""
        problems = verify_packs.check_preferences(self.probe, self.app_folder(), self.apple, self.languages)
        self.assertEqual(problems, [])

    def test_a_language_the_bundle_lacks_gives_the_development_region(self):
        found = verify_packs.preferred_languages(self.probe, self.app_folder(), ["xx", "ja", "ja,ru", "de,ru"])
        self.assertEqual(found, {"xx": "en", "ja": "ja", "ja,ru": "ja", "de,ru": "ru"})

    def test_the_measured_table_covers_the_designs_lists(self):
        """The design's measured matches are all in the table, and each language of a catalog chooses itself."""
        wanted = verify_packs.expected_preferences(["en", "es", "he", "pt-BR", "sv", "zh-Hans", "zh-Hant"])
        self.assertEqual(wanted["zh-Hant-TW"], "zh-Hant")
        self.assertEqual(wanted["zh-CN"], "zh-Hans")
        self.assertEqual(wanted["pt-PT"], "pt-BR")
        self.assertEqual(wanted["es-MX"], "es")
        self.assertEqual(wanted["iw"], "he")
        self.assertEqual(wanted["nb"], "en")
        self.assertEqual(wanted["nb,sv"], "sv")
        self.assertEqual(wanted["ca,es"], "es")
        self.assertEqual(wanted["hi-Latn"], "en")
        self.assertEqual(wanted["sv"], "sv")
        # A catalog without Hebrew has no measured answer for iw.
        self.assertNotIn("iw", verify_packs.expected_preferences(["en", "es"]))


if __name__ == "__main__":
    unittest.main()
