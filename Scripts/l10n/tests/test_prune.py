"""Tests of `l10n.py prune`: deleting the stale strings a cut leaves behind (TL13).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works on a catalog in a temporary folder.
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402


def unit(value, state="machine_translated"):
    """A localization holding one text."""
    return {"stringUnit": {"state": state, "value": value}}


def stale(**localizations):
    """A stale entry (the code no longer has it) with `localizations` by language."""
    result = {"comment": "Gone", "extractionState": "stale"}
    if localizations:
        result["localizations"] = localizations
    return result


class PruneCase(unittest.TestCase):
    """A catalog with every kind of string, in a temporary folder."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name) / "Localizable.xcstrings"
        # `prune` retires the IDs it deletes in this checkout's retired-ids.txt: a made-up checkout, never the repository's.
        patch = mock.patch.object(l10n, "ROOT", Path(folder.name) / "checkout")
        patch.start()
        self.addCleanup(patch.stop)
        strings = {
            "Live": {"comment": "Still in the code", "localizations": {"en": unit("Live"), "es": unit("Vivo")}},
            "Stale bare": stale(),
            "Stale english only": stale(en=unit("Stale english only", "translated")),
            "%lld stale books": stale(en={"variations": {"plural": {"one": unit("%lld book", "translated"),
                                                                    "other": unit("%lld books", "translated")}}}),
            "Stale untranslated spanish": stale(es=unit("", "new")),
            "Stale translated": stale(es=unit("Viejo")),
        }
        catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings}).save(self.path)

    def run_prune(self, *options):
        """Runs `prune` on the catalog; returns (exit status, standard output)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = l10n.main(["prune", "--catalog", str(self.path), *options])
        return status, out.getvalue()

    def keys(self):
        """The keys the catalog holds."""
        return sorted(catalog.Catalog.load(self.path).strings)


class PruneTests(PruneCase):
    """What goes, and what stays."""

    def test_only_stale_strings_without_a_translation_go(self):
        status, out = self.run_prune()
        self.assertEqual(status, 0)
        self.assertEqual(self.keys(), ["Live", "Stale translated"])
        self.assertIn('deleted stale "Stale bare"', out)

    def test_an_english_plural_or_a_value_less_localization_is_no_translation(self):
        _status, out = self.run_prune()
        for key in ("Stale english only", "%lld stale books", "Stale untranslated spanish"):
            self.assertIn(f'deleted stale "{key}"', out)

    def test_each_deleted_key_is_printed_and_the_rest_counted(self):
        _status, out = self.run_prune()
        self.assertEqual(out.count("deleted stale"), 4)
        self.assertNotIn("Live", out.replace("stale with a translation kept", ""))
        self.assertIn("prune: 4 stale strings deleted; 1 stale with a translation kept (--all deletes them too)", out)

    def test_all_deletes_the_translated_stale_string_too(self):
        _status, out = self.run_prune("--all")
        self.assertEqual(self.keys(), ["Live"])
        self.assertIn('deleted stale "Stale translated"', out)
        self.assertIn("prune: 5 stale strings deleted", out)
        self.assertNotIn("kept", out)

    def test_a_live_string_is_never_deleted_even_with_all(self):
        self.run_prune("--all")
        self.assertEqual(catalog.Catalog.load(self.path).strings["Live"]["localizations"]["es"], unit("Vivo"))

    def test_dry_run_lists_what_would_go_and_writes_nothing(self):
        before = self.path.read_bytes()
        stamp = self.path.stat().st_mtime_ns
        status, out = self.run_prune("--dry-run")
        self.assertEqual(status, 0)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.path.stat().st_mtime_ns, stamp)
        self.assertIn('would delete stale "Stale bare"', out)
        self.assertIn("4 stale strings would be deleted", out)
        self.assertNotIn("deleted stale", out)

    def test_dry_run_with_all_lists_the_translated_one_too(self):
        _status, out = self.run_prune("--dry-run", "--all")
        self.assertIn('would delete stale "Stale translated"', out)
        self.assertEqual(len(self.keys()), 6)

    def test_a_second_run_changes_nothing(self):
        self.run_prune()
        after_first = self.path.read_bytes()
        status, out = self.run_prune()
        self.assertEqual(status, 0)
        self.assertEqual(self.path.read_bytes(), after_first)
        self.assertNotIn("deleted stale", out)
        self.assertIn("prune: 0 stale strings deleted", out)

    def test_json_names_the_deleted_keys(self):
        _status, out = self.run_prune("--json", "--dry-run")
        data = json.loads(out)
        self.assertEqual(data["deleted"], sorted(["%lld stale books", "Stale bare", "Stale english only", "Stale untranslated spanish"]))
        self.assertIs(data["dryRun"], True)
        self.assertEqual(data["keptWithTranslation"], 1)

    def test_the_catalog_is_saved_in_the_tools_layout(self):
        self.run_prune()
        text = catalog.read_text(self.path)
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))

    def test_a_catalog_with_nothing_stale_is_left_alone(self):
        self.run_prune("--all")
        before = self.path.read_bytes()
        self.run_prune("--all")
        self.assertEqual(self.path.read_bytes(), before)


class CheckPointsToPruneTests(PruneCase):
    """`check`'s sentence for a stale string names the command that deletes it."""

    def test_the_stale_problem_names_prune(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = l10n.main(["check", "--catalog", str(self.path)])
        self.assertEqual(status, 1)
        self.assertIn("`prune`", out.getvalue())
        self.assertIn("stale", out.getvalue())

    def test_check_passes_once_every_stale_string_is_pruned(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.main(["prune", "--all", "--catalog", str(self.path)])
            status = l10n.main(["check", "--catalog", str(self.path)])
        self.assertEqual(status, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
