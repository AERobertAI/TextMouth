"""Tests of `verify_packs.py`: the proof that compact language files change no lookup (TL16).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The real catalog is compiled by Apple's `xcstringstool` and read by the Swift probe, so these
tests run on a Mac with Xcode only (about five seconds). They show that the proof is not
vacuous: a table changed after compacting is reported, and one left alone passes.
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


class VerifyPacksCase(unittest.TestCase):
    """Compiled and compacted copies of the real catalog, in a temporary folder."""

    @classmethod
    def setUpClass(cls):
        folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(folder.cleanup)
        root = Path(folder.name)
        cls.xcode = root / "xcode"
        cls.compact = root / "compact"
        cls.xcode.mkdir()
        subprocess.run(
            ["xcrun", "xcstringstool", "compile", "--output-directory", str(cls.xcode), str(verify_packs.CATALOG)],
            check=True, capture_output=True,
        )
        shutil.copytree(cls.xcode, cls.compact)
        _, errors = compact_packs.compact_folder(cls.compact)
        assert not errors, errors
        verify_packs.WORK.mkdir(parents=True, exist_ok=True)
        cls.probe = verify_packs.build_probe()
        cls.languages = verify_packs.catalog_languages()

    def run_probe(self, compact):
        """Run the probe on the compiled folder and `compact`; returns (exit status, its output)."""
        done = subprocess.run(
            [str(self.probe), str(self.xcode), str(compact), str(verify_packs.CATALOG), *self.languages],
            capture_output=True, text=True, check=False,
        )
        return done.returncode, done.stdout + done.stderr

    def test_compacted_files_read_back_identically(self):
        """Every key of every language, plurals at every count: no difference, and many lookups found."""
        status, output = self.run_probe(self.compact)
        self.assertEqual(status, 0, output)
        self.assertIn("0 different", output)
        self.assertIn("es", output)

    def test_a_changed_string_is_reported(self):
        """One Spanish word changed after compacting: the probe names the key, and exits 1."""
        changed = Path(tempfile.mkdtemp(dir=self.compact.parent))
        shutil.copytree(self.compact, changed / "pack")
        path = changed / "pack" / "es.lproj" / "Localizable.strings"
        text = path.read_bytes().decode("utf-8")
        self.assertIn('"Bookmarks"="Marcadores";', text)
        path.write_bytes(text.replace('"Bookmarks"="Marcadores";', '"Bookmarks"="Marcador";').encode("utf-8"))
        status, output = self.run_probe(changed / "pack")
        self.assertEqual(status, 1)
        self.assertIn('DIFFERENT: es "Bookmarks"', output)

    def test_a_changed_plural_form_is_reported_at_its_count(self):
        """A Spanish `many` form changed: only the count that reaches it (1,000,000) differs."""
        changed = Path(tempfile.mkdtemp(dir=self.compact.parent))
        shutil.copytree(self.compact, changed / "pack")
        path = changed / "pack" / "es.lproj" / "Localizable.stringsdict"
        table = plistlib.loads(path.read_bytes())
        table["%lld minutes"]["value"]["many"] += "!"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY))
        status, output = self.run_probe(changed / "pack")
        self.assertEqual(status, 1)
        self.assertIn('es "%lld minutes" at 1000000', output)
        self.assertNotIn('"%lld minutes" at 21', output)

    def test_a_missing_language_folder_stops_the_probe(self):
        """A compact folder without a language is a usage error, not a pass."""
        empty = Path(tempfile.mkdtemp(dir=self.compact.parent))
        status, output = self.run_probe(empty)
        self.assertEqual(status, 2)
        self.assertIn("lacks", output)

    def test_the_catalog_names_the_languages_that_are_compared(self):
        """At least English, the source language, and Spanish."""
        self.assertTrue({"en", "es"} <= set(self.languages), self.languages)


if __name__ == "__main__":
    unittest.main()
