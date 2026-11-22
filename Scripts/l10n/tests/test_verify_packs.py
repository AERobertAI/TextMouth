"""Tests of `verify_packs.py`: the proof that compact language files change no lookup (TL16, TL18).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The catalogs are compiled by Apple's `xcstringstool` and read by the Swift probe, so these
tests run on a Mac with Xcode only (a few seconds each). They show that the proof is not
vacuous: a table changed after compacting is reported, and one left alone passes.

Three catalogs are used: the repository's own (keyed by ID), a small synthetic one
(fixtures/squeeze/Localizable.xcstrings, keyed by English) that holds what the real one does not yet: Japanese
(only `other`), Russian (`one`, `few`, `many`, `other`), and French (`one` covering 0), plus the
awkward cases of the squeeze (an entry equal to its key, a plural string whose forms are one text), and the same
catalog keyed by ID with an `en` for each entry (fixtures/squeeze-ids/), which the engine reading needs.
"""
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import compact_packs  # noqa: E402  (imported by path, after sys.path is set)
import verify_packs  # noqa: E402

# The synthetic catalog of the squeeze, in a folder of its own because the table is named for the file, and the same
# catalog keyed by ID (probe.key0, ... in the code-point order of the English keys), each entry with its `en`.
SQUEEZE_CATALOG = HERE / "fixtures" / "squeeze" / "Localizable.xcstrings"
SQUEEZE_IDS_CATALOG = HERE / "fixtures" / "squeeze-ids" / "Localizable.xcstrings"


class VerifyPacksCase(unittest.TestCase):
    """Compiled and compacted copies of a catalog, in a temporary folder. Subclasses name the catalog."""

    # The catalog compiled and compared; a base class with none is not run.
    catalog = None

    @classmethod
    def setUpClass(cls):
        if cls.catalog is None:
            raise unittest.SkipTest("the base class names no catalog")
        folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(folder.cleanup)
        root = Path(folder.name)
        cls.root = root
        cls.xcode = root / "xcode"
        cls.compact = root / "compact"
        cls.xcode.mkdir()
        subprocess.run(
            ["xcrun", "xcstringstool", "compile", "--output-directory", str(cls.xcode), str(cls.catalog)],
            check=True, capture_output=True,
        )
        shutil.copytree(cls.xcode, cls.compact)
        _, errors = compact_packs.compact_folder(cls.compact)
        assert not errors, errors
        cls.languages = verify_packs.catalog_languages(cls.catalog)
        for pack in (cls.xcode, cls.compact):
            verify_packs.write_app_info(pack, cls.languages)
        # One compiled probe serves every class (it is rebuilt only when a source is newer); it copies itself
        # into each folder it reads, so no two tests share a copy.
        cls.probe = verify_packs.build_probe()

    def run_probe(self, compact):
        """Run the probe on the compiled folder and `compact`; returns (exit status, its output)."""
        done = subprocess.run(
            [str(self.probe), str(self.xcode), str(compact), str(self.catalog), *self.languages],
            capture_output=True, text=True, check=False,
        )
        return done.returncode, done.stdout + done.stderr

    def changed_copy(self):
        """A copy of the compact folder, with its Info.plist, that a test may alter; returns its path."""
        changed = Path(tempfile.mkdtemp(dir=self.root)) / "pack"
        shutil.copytree(self.compact, changed)
        return changed

    def test_compacted_files_read_back_identically(self):
        """Every key of every language, plurals at every count: no difference, and many lookups found."""
        status, output = self.run_probe(self.compact)
        self.assertEqual(status, 0, output)
        self.assertIn("0 different", output)
        self.assertIn("en", output)

    def test_a_missing_language_folder_stops_the_probe(self):
        """A compact folder without a language is a usage error, not a pass."""
        empty = Path(tempfile.mkdtemp(dir=self.root))
        status, output = self.run_probe(empty)
        self.assertEqual(status, 2)
        self.assertIn("lacks", output)

    def test_the_catalog_names_the_languages_that_are_compared(self):
        """At least English, the source language."""
        self.assertIn("en", self.languages)


class RealCatalogTests(VerifyPacksCase):
    """The repository's own catalog."""

    catalog = verify_packs.CATALOG

    def test_a_changed_string_is_reported(self):
        """One Spanish word changed after compacting: the probe names the key, and exits 1."""
        pack = self.changed_copy()
        path = pack / "es.lproj" / "Localizable.strings"
        text = path.read_bytes().decode("utf-8")
        self.assertIn('"common.bookmarks"="Marcadores";', text)
        path.write_bytes(text.replace('"common.bookmarks"="Marcadores";', '"common.bookmarks"="Marcador";').encode("utf-8"))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('DIFFERENT: es "common.bookmarks"', output)

    def test_a_changed_plural_form_is_reported_at_its_count(self):
        """A Spanish `many` form changed: only the count that reaches it (1,000,000) differs."""
        pack = self.changed_copy()
        path = pack / "es.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        table["common.countMinutes"]["value"]["many"] += "!"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('es "common.countMinutes" at 1000000', output)
        self.assertNotIn('"common.countMinutes" at 21', output)

    def test_spanish_is_in_the_catalog(self):
        self.assertIn("es", self.languages)


class SqueezeCatalogTests(VerifyPacksCase):
    """The synthetic catalog: Japanese, Russian, and French beside English, and the squeeze's awkward cases."""

    catalog = SQUEEZE_CATALOG

    def test_the_catalog_holds_the_four_languages(self):
        self.assertEqual(self.languages, ["en", "fr", "ja", "ru"])

    def test_a_binary_strings_file_reads_back_identically_through_the_bundle(self):
        """Item 1: the same Japanese, French, and Russian tables as binary property lists give every lookup unchanged."""
        pack = self.changed_copy()
        for language in ("fr", "ja", "ru"):
            path = pack / f"{language}.lproj" / "Localizable.strings"
            table = compact_packs.apple_parse(path.read_bytes())
            path.write_bytes(compact_packs.render_strings_binary(table))
            self.assertTrue(path.read_bytes().startswith(b"bplist00"))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 0, output)
        self.assertIn("0 different", output)

    def parsed(self, pack, language, kind):
        """What a language's `Localizable.<kind>` in `pack` holds, read through Apple's parser."""
        return compact_packs.apple_parse((pack / f"{language}.lproj" / f"Localizable.{kind}").read_bytes())

    def test_the_squeeze_left_out_what_it_should_and_kept_the_rest(self):
        """Items 2 and 3 in the compiled fixture: what is plain, what is left out, and what stays a plural entry."""
        ja = self.parsed(self.compact, "ja", "strings")
        # Item 2: equal to the key in every language, or only in Japanese with English's tables silent about it.
        self.assertNotIn("TextMouth", ja)
        self.assertNotIn("Open", ja)
        # ... but kept where English holds the key as a plural entry (the fallback would format it as English).
        self.assertEqual(ja["%lld minutes"], "%lld minutes")
        self.assertEqual(self.parsed(self.compact, "fr", "strings")["%lld minutes"], "%lld minutes")
        # Item 3: Japanese's one-form plurals are plain entries, and its plural table is empty.
        self.assertEqual(ja["%lld books"], "%lld 冊")
        self.assertEqual(ja["%@ holds %lld pages"], "%1$@ は %2$lld ページです")
        self.assertEqual(self.parsed(self.compact, "ja", "stringsdict"), {})
        # Russian's four forms of one text merge too; its real plurals stay.
        self.assertEqual(self.parsed(self.compact, "ru", "strings")["%lld items"], "%lld шт.")
        self.assertIn("%lld books", self.parsed(self.compact, "ru", "stringsdict"))
        self.assertNotIn("%lld items", self.parsed(self.compact, "ru", "stringsdict"))
        # English's forms that were one text are gone from its plurals (and, equal to the key, from its strings).
        self.assertNotIn("%lld%% done", self.parsed(self.compact, "en", "stringsdict"))

    def test_the_squeeze_is_smaller_than_the_xcode_files(self):
        """The compact folder holds fewer bytes than Xcode's, language file by language file in total."""
        def total(folder):
            return sum(path.stat().st_size for path in folder.glob("*.lproj/Localizable.*"))
        self.assertLess(total(self.compact), total(self.xcode))

    def test_a_merged_plain_entry_that_formats_differently_is_reported_at_every_count(self):
        """Item 3's proof is not vacuous: a plain entry with another text differs at all seven counts."""
        pack = self.changed_copy()
        path = pack / "ja.lproj" / "Localizable.strings"
        table = compact_packs.apple_parse(path.read_bytes())
        table["%lld books"] = "%lld 巻"
        path.write_bytes(compact_packs.render_strings(table))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        for count in (0, 1, 2, 5, 21, 100, 1000000):
            self.assertIn(f'ja "%lld books" at {count}:', output)

    def test_a_changed_japanese_string_is_reported(self):
        """The probe reads Japanese through its own language, so a changed kana string is named."""
        pack = self.changed_copy()
        path = pack / "ja.lproj" / "Localizable.strings"
        # The file may be either compact form, so it is read and written back through the tool's own helpers.
        table = compact_packs.apple_parse(path.read_bytes())
        self.assertEqual(table["Bookmarks"], "ブックマーク")
        table["Bookmarks"] = "しおり"
        path.write_bytes(compact_packs.render_strings(table))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('DIFFERENT: ja "Bookmarks"', output)

    def test_a_changed_russian_plural_form_is_reported_at_the_counts_that_reach_it(self):
        """Russian's `few` form (2 and, by the rule, 22) changes: 2 differs, and 1 and 5 do not."""
        pack = self.changed_copy()
        path = pack / "ru.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        table["%lld books"]["value"]["few"] += "!"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('ru "%lld books" at 2', output)
        self.assertNotIn('ru "%lld books" at 1:', output)
        self.assertNotIn('ru "%lld books" at 5:', output)

    def test_a_changed_french_form_is_reported_at_zero(self):
        """French's `one` covers 0: changing it differs at 0 and at 1, and not at 2."""
        pack = self.changed_copy()
        path = pack / "fr.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        table["%lld books"]["value"]["one"] += "!"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('fr "%lld books" at 0', output)
        self.assertIn('fr "%lld books" at 1:', output)
        self.assertNotIn('fr "%lld books" at 2:', output)


class EngineReadingTests(VerifyPacksCase):
    """The third reading (FR39): the engine's text from the interface-text pack equals Apple's table for the same ID.

    Only the synthetic catalog keyed by ID runs here, so no unit test of the tools runs the repository's real pack through
    the engine: that is `make l10n-check`'s, after the hosted test of the shipped pack has passed on GitHub.
    """

    catalog = SQUEEZE_IDS_CATALOG

    def engine_arguments(self, catalog=None):
        """Builds the interface-text pack of `catalog` (the case's own by default) and returns the probe's arguments that
        name it."""
        pack = verify_packs.build_engine_pack(Path(catalog or self.catalog), self.root)
        return ["--pack", str(pack)]

    def run_engine_probe(self, catalog=None):
        """Run the probe with the engine's reading on the compiled and compact folders, the pack built from `catalog`
        (the case's own by default); returns (status, output)."""
        done = subprocess.run(
            [str(self.probe), str(self.xcode), str(self.compact), str(self.catalog), *self.engine_arguments(catalog),
             *self.languages],
            capture_output=True, text=True, check=False,
        )
        return done.returncode, done.stdout + done.stderr

    def test_the_engine_reads_every_id_as_xcode_does(self):
        """The engine's text equals Apple's table's for every ID, in every language, at every count."""
        status, output = self.run_engine_probe()
        self.assertEqual(status, 0, output)
        self.assertRegex(output, r"probe: engine compared [1-9][0-9]* lookups in %d languages" % len(self.languages))
        self.assertIn(": 0 different, 0 IDs the lookups cannot feed, 0 problems reported", output)
        self.assertRegex(output, r"probe: engine timing \(-O\): ID list decode [0-9.]+ ms .* median lookup [0-9.]+ us")

    def test_each_language_reports_its_lookups_and_locale(self):
        """One line a language: its lookups, its time, and the locale both sides wrote with."""
        _, output = self.run_engine_probe()
        for language in self.languages:
            self.assertRegex(output, r"probe: engine %s: [1-9][0-9]* lookups in [0-9.]+ s with [A-Za-z_@=-]+: 0 different; decode of the ID list [0-9.]+ ms, of this language [0-9.]+ ms, median lookup [0-9.]+ us" % language)

    def test_a_pack_that_says_something_else_is_reported(self):
        """The engine reading is not vacuous: a pack built from a catalog with one Russian text changed differs from
        what Xcode ships, and the probe names the language and the ID."""
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
        status, output = self.run_engine_probe(altered)
        self.assertEqual(status, 1, output)
        self.assertIn("ENGINE DIFFERENT: ru ", output)
        self.assertIn(f"ru {changed} (", output)
        self.assertNotIn("ENGINE DIFFERENT: ja ", output)

    def test_a_pack_that_is_not_there_is_a_usage_error(self):
        """--pack naming no file stops the probe with status 2 rather than comparing nothing."""
        done = subprocess.run(
            [str(self.probe), str(self.xcode), str(self.compact), str(self.catalog), "--pack", "no-such.pack", *self.languages],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(done.returncode, 2)
        self.assertIn("cannot open the pack", done.stdout + done.stderr)


class FallbackCatalogTests(VerifyPacksCase):
    """A catalog whose French has no plural string, so no `.stringsdict` file: the case item 2 must not break."""

    catalog = HERE / "fixtures" / "squeeze-fallback" / "Localizable.xcstrings"

    def test_french_has_no_plurals_file_and_foundation_answers_from_english(self):
        """Without French's entry the lookup is English's plural, which reads differently at 0 and 1.

        Foundation takes a plural entry from the first language whose `.stringsdict` exists, so a language with
        no such file answers a key its `.strings` lacks from English's plurals: French's `one` form reads
        `1 minute` at 0 and 1 where the entry reads `1 minutes`. The probe holds English in the same bundle,
        so it must say so.
        """
        self.assertFalse((self.xcode / "fr.lproj" / "Localizable.stringsdict").exists())
        pack = self.changed_copy()
        path = pack / "fr.lproj" / "Localizable.strings"
        table = compact_packs.apple_parse(path.read_bytes())
        del table["%lld minutes"]
        path.write_bytes(compact_packs.render_strings(table))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('DIFFERENT: fr "%lld minutes" at 0:', output)
        self.assertIn('DIFFERENT: fr "%lld minutes" at 1:', output)
        self.assertNotIn('fr "%lld minutes" at 2:', output)

    def test_the_squeeze_keeps_that_entry_and_drops_the_one_nothing_answers(self):
        """`%lld minutes` stays in French (English holds it as a plural); `Open` goes (no English table holds it)."""
        french = compact_packs.apple_parse((self.compact / "fr.lproj" / "Localizable.strings").read_bytes())
        self.assertEqual(french, {"%lld minutes": "%lld minutes", "Close": "Fermer"})


if __name__ == "__main__":
    unittest.main()
