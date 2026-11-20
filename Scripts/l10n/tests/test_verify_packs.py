"""Tests of `verify_packs.py`: the proof that compact language files change no lookup (TL16, TL18).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The catalogs are compiled by Apple's `xcstringstool` and read by the Swift probe, so these
tests run on a Mac with Xcode only (a few seconds each). They show that the proof is not
vacuous: a table changed after compacting is reported, and one left alone passes.

Two catalogs are used: the repository's own, and a small synthetic one
(fixtures/squeeze/Localizable.xcstrings) that holds what the real one does not yet: Japanese
(only `other`), Russian (`one`, `few`, `many`, `other`), and French (`one` covering 0), plus the
awkward cases of the squeeze (an entry equal to its key, a plural string whose forms are one text).
"""
import plistlib
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

# The synthetic catalog of the squeeze, in a folder of its own because the table is named for the file.
SQUEEZE_CATALOG = HERE / "fixtures" / "squeeze" / "Localizable.xcstrings"


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
        # The probe is built into a folder of the test's own, so a run never touches build/.
        cls.probe = verify_packs.build_probe(root / "probe-build")

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
        self.assertIn('"Bookmarks"="Marcadores";', text)
        path.write_bytes(text.replace('"Bookmarks"="Marcadores";', '"Bookmarks"="Marcador";').encode("utf-8"))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('DIFFERENT: es "Bookmarks"', output)

    def test_a_changed_plural_form_is_reported_at_its_count(self):
        """A Spanish `many` form changed: only the count that reaches it (1,000,000) differs."""
        pack = self.changed_copy()
        path = pack / "es.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        table["%lld minutes"]["value"]["many"] += "!"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        status, output = self.run_probe(pack)
        self.assertEqual(status, 1)
        self.assertIn('es "%lld minutes" at 1000000', output)
        self.assertNotIn('"%lld minutes" at 21', output)

    def test_spanish_is_in_the_catalog(self):
        self.assertIn("es", self.languages)


class SqueezeCatalogTests(VerifyPacksCase):
    """The synthetic catalog: Japanese, Russian, and French beside English, and the squeeze's awkward cases."""

    catalog = SQUEEZE_CATALOG

    def test_the_catalog_holds_the_four_languages(self):
        self.assertEqual(self.languages, ["en", "fr", "ja", "ru"])

    def test_a_changed_japanese_string_is_reported(self):
        """The probe reads Japanese through its own language, so a changed kana string is named."""
        pack = self.changed_copy()
        path = pack / "ja.lproj" / "Localizable.strings"
        text = path.read_bytes().decode("utf-8")
        self.assertIn('"Bookmarks"="ブックマーク";', text)
        path.write_bytes(text.replace("ブックマーク", "しおり").encode("utf-8"))
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


if __name__ == "__main__":
    unittest.main()
