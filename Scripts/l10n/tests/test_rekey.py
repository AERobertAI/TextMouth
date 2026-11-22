"""Tests of Scripts/l10n/rekey.py, the one-off that re-keys the String Catalog by ID (FR39 phase 7).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Each test works in a temporary folder, on a small catalog, ID table, and review record it writes, and never touches the
repository's own files.
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import pack  # noqa: E402
import rekey  # noqa: E402


def unit(value, state="translated"):
    """A stringUnit localization."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(one, other, many=None):
    """Plural variations; Spanish needs `many` as well."""
    forms = {"one": unit(one), "other": unit(other)}
    if many:
        forms["many"] = unit(many)
    return {"variations": {"plural": forms}}


# The catalog the tests re-key: a plain string, one with Xcode's positional `new` English, a plural, and a split key.
OLD = {
    "Play": {"comment": "Play button", "localizations": {"es": unit("Reproducir")}},
    "%@ of %@": {"comment": "Two titles", "localizations": {"en": unit("%1$@ of %2$@", "new"), "es": unit("%1$@ de %2$@")}},
    "%lld books": {"comment": "A count", "localizations": {"en": plural("%lld book", "%lld books"),
                                                           "es": plural("%lld libro", "%lld libros", "%lld de libros")}},
    "Delete": {"comment": "Both uses", "localizations": {"es": unit("Eliminar")}},
}
TABLE = {
    "version": 1,
    "ids": {"Play": "player.play", "%@ of %@": "player.position", "%lld books": "library.bookCount", "Delete": "common.delete"},
    "splits": {"Delete": [{"id": "common.delete", "sites": ["A.swift:A.x"]}, {"id": "feed.delete", "sites": ["B.swift:B.y"]}]},
}
REVIEW = {"language": "es", "reviews": [{"part": 1, "fixes": [
    {"key": "Play", "english": "Play", "before": "a", "after": "b"},
    {"key": "Delete", "english": "Delete", "before": "c", "after": "d"},
]}]}


class RekeyCase(unittest.TestCase):
    """A temporary folder holding the old catalog, the ID table, and a review record."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.catalog = self.folder / "Localizable.xcstrings"
        catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": OLD}).save(self.catalog)
        self.ids = self.folder / "ids.json"
        self.ids.write_text(json.dumps(TABLE), encoding="utf-8")
        self.reviews = self.folder / "reviews"
        self.reviews.mkdir()
        (self.reviews / "es.json").write_text(json.dumps(REVIEW, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")

    def run_rekey(self, *extra):
        """Runs rekey.main on the folder's files; returns (exit status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = rekey.main(["--catalog", str(self.catalog), "--ids", str(self.ids), "--reviews", str(self.reviews), *extra])
        return status, out.getvalue(), err.getvalue()

    def strings(self):
        """The catalog's strings as they are on disk now."""
        return catalog.Catalog.load(self.catalog).strings


class RekeyTests(RekeyCase):
    """What a re-key writes."""

    def test_entries_move_under_their_ids_and_a_split_key_is_copied(self):
        status, out, _ = self.run_rekey()
        self.assertEqual(status, 0)
        strings = self.strings()
        self.assertEqual(sorted(strings), ["common.delete", "feed.delete", "library.bookCount", "player.play", "player.position"])
        self.assertEqual(strings["common.delete"], strings["feed.delete"])
        # Every translation, its state, and the comment are copied.
        self.assertEqual(strings["feed.delete"]["comment"], "Both uses")
        self.assertEqual(strings["feed.delete"]["localizations"]["es"], unit("Eliminar"))
        self.assertIn("5 IDs", out)
        self.assertIn("1 copies", out)

    def test_every_entry_gets_its_english_and_manual_extraction(self):
        self.run_rekey()
        strings = self.strings()
        for identifier, entry in strings.items():
            self.assertEqual(entry["extractionState"], "manual", identifier)
        self.assertEqual(strings["player.play"]["localizations"]["en"], unit("Play"))
        self.assertEqual(strings["common.delete"]["localizations"]["en"], unit("Delete"))

    def test_xcodes_positional_new_unit_is_replaced_by_the_keys_text(self):
        self.run_rekey()
        self.assertEqual(self.strings()["player.position"]["localizations"]["en"], unit("%@ of %@"))

    def test_plural_english_forms_are_kept(self):
        self.run_rekey()
        self.assertEqual(self.strings()["library.bookCount"]["localizations"]["en"], plural("%lld book", "%lld books"))

    def test_other_languages_and_comments_do_not_change(self):
        self.run_rekey()
        strings = self.strings()
        self.assertEqual(strings["player.position"]["localizations"]["es"], unit("%1$@ de %2$@", "translated"))
        self.assertEqual(strings["player.play"]["comment"], "Play button")

    def test_the_english_the_pack_builds_is_the_same(self):
        old_plan = pack.build_plan(self.catalog, self.ids)
        self.run_rekey()
        new_plan = pack.build_plan(self.catalog)
        # The same entries for every ID in every language (the plans' blobs are what the pack holds).
        self.assertEqual(old_plan.ids, new_plan.ids)
        self.assertEqual(old_plan.blobs, new_plan.blobs)

    def test_the_catalog_is_written_in_xcodes_layout(self):
        self.run_rekey()
        text = self.catalog.read_text(encoding="utf-8")
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))

    def test_review_fixes_gain_an_id_or_ids_and_keep_key_and_english(self):
        self.run_rekey()
        fixes = json.loads((self.reviews / "es.json").read_text(encoding="utf-8"))["reviews"][0]["fixes"]
        self.assertEqual(list(fixes[0]), ["key", "id", "english", "before", "after"])
        self.assertEqual((fixes[0]["key"], fixes[0]["id"], fixes[0]["english"]), ("Play", "player.play", "Play"))
        self.assertEqual(fixes[1]["ids"], ["common.delete", "feed.delete"])
        self.assertNotIn("id", fixes[1])

    def test_a_dry_run_writes_nothing(self):
        before = self.catalog.read_text(encoding="utf-8")
        status, out, _ = self.run_rekey("--dry-run")
        self.assertEqual(status, 0)
        self.assertIn("would write", out)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), before)


class RekeyRefusalTests(RekeyCase):
    """What a re-key refuses, writing nothing."""

    def test_a_second_run_refuses(self):
        self.run_rekey()
        after_first = self.catalog.read_text(encoding="utf-8")
        reviews_after_first = (self.reviews / "es.json").read_text(encoding="utf-8")
        status, _, err = self.run_rekey()
        self.assertEqual(status, 1)
        self.assertIn("already keyed by ID", err)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), after_first)
        self.assertEqual((self.reviews / "es.json").read_text(encoding="utf-8"), reviews_after_first)

    def test_a_key_without_an_id_refuses(self):
        data = catalog.Catalog.load(self.catalog)
        data.strings["Stop"] = {"comment": "x"}
        data.save(self.catalog)
        before = self.catalog.read_text(encoding="utf-8")
        status, _, err = self.run_rekey()
        self.assertEqual(status, 1)
        self.assertIn("'Stop'", err)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), before)

    def test_a_review_fix_with_an_unknown_key_refuses_before_anything_is_written(self):
        bad = {"language": "es", "reviews": [{"fixes": [{"key": "Nothing", "english": "x"}]}]}
        (self.reviews / "es.json").write_text(json.dumps(bad), encoding="utf-8")
        before = self.catalog.read_text(encoding="utf-8")
        status, _, err = self.run_rekey()
        self.assertEqual(status, 1)
        self.assertIn("'Nothing'", err)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), before)


if __name__ == "__main__":
    unittest.main()
