"""Tests of `l10n.py sync` and Scripts/l10n/sync.py, which read the code's `InterfaceText.line` calls without the compiler
(FR39 phase 7), and of `prune` retiring the IDs it deletes.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test builds a made-up checkout in a temporary folder (Swift files under TextMouth/, a catalog, a retired-IDs file) and
points the tool at it; nothing reads or writes the repository's own catalog, and nothing builds or takes the heavy-work lock.
"""
import contextlib
import copy
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import ids  # noqa: E402
import l10n  # noqa: E402
import sync  # noqa: E402
import test_l10n as base  # noqa: E402  (its helpers: TemporaryCase, entry, unit, plural, args_for)

unit, plural, entry = base.unit, base.plural, base.entry

# A source file of calls: a plain line, an interpolation, a number, and a `%` in a literal that has an interpolation.
SOURCE = '''enum LibraryWording {
    // Translators: The library's title.
    static let title = InterfaceText.line("library.title", "Library")
    // Translators: Says how many books. %lld is the count.
    static func count(_ n: Int) -> String { InterfaceText.line("library.count", "\\(number: n) books") }
    // Translators: Says a share. %@ is the book's title.
    static func share(_ t: String) -> String { InterfaceText.line("library.share", "100% of \\(t)") }
}
'''


class SyncCase(base.TemporaryCase):
    """A made-up checkout with one Swift file and a catalog, and the tool pointed at it."""

    def setUp(self):
        super().setUp()
        self.checkout = self.folder / "checkout"
        (self.checkout / "TextMouth" / "Models").mkdir(parents=True)
        (self.checkout / "Scripts" / "l10n").mkdir(parents=True)
        self.source = self.checkout / "TextMouth" / "Models" / "LibraryWording.swift"
        self.source.write_text(SOURCE, encoding="utf-8")
        self.catalog = self.checkout / "TextMouth" / "Localization" / "Localizable.xcstrings"
        self.catalog.parent.mkdir()
        self.write_strings({})
        self.locations = self.folder / "out" / "locations.json"
        patch = mock.patch.object(l10n, "ROOT", self.checkout)
        patch.start()
        self.addCleanup(patch.stop)

    def write_strings(self, strings):
        """Writes `strings` (ID to entry, as given) as the checkout's catalog."""
        catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings}).save(self.catalog)

    def load(self):
        """The checkout's catalog as it is on disk now."""
        return catalog.Catalog.load(self.catalog)

    def write_source(self, text):
        """Replaces the Swift file."""
        self.source.write_text(text, encoding="utf-8")

    def run_sync(self, *extra):
        """Runs the sync command on the checkout; returns (exit status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = l10n.main(["sync", "--catalog", str(self.catalog), "--locations", str(self.locations), *extra])
        return status, out.getvalue(), err.getvalue()


class ReadCodeTests(SyncCase):
    """What `read_code` finds in the sources, and what it refuses."""

    def test_the_ids_english_notes_and_places_are_read(self):
        found, calls, problems = sync.read_code(self.checkout)
        self.assertEqual(problems, [])
        self.assertEqual(len(calls), 3)
        self.assertEqual(sorted(found), ["library.count", "library.share", "library.title"])
        self.assertEqual(found["library.title"].english, "Library")
        self.assertEqual(found["library.title"].notes, {"The library's title."})
        self.assertEqual(found["library.title"].places, [{"file": "TextMouth/Models/LibraryWording.swift", "line": 3}])

    def test_a_number_is_lld_another_interpolation_is_at_and_a_percent_is_doubled_beside_one(self):
        found, _, _ = sync.read_code(self.checkout)
        self.assertEqual(found["library.count"].english, "%lld books")
        self.assertEqual(found["library.share"].english, "100%% of %@")

    def refused(self, text, *words):
        """The sentences `read_code` gives for source `text`; each of `words` must be in one of them."""
        self.write_source(text)
        _, _, problems = sync.read_code(self.checkout)
        self.assertTrue(problems, "nothing was refused")
        for word in words:
            self.assertTrue(any(word in sentence for sentence in problems), (word, problems))
        return problems

    def test_an_id_outside_the_pattern_is_refused(self):
        self.refused('// Translators: x\nlet a = InterfaceText.line("Library", "Library")\n', "outside the pattern", ":2:")

    def test_an_id_over_48_characters_is_refused(self):
        long_id = "library." + "a" * 45
        self.refused(f'// Translators: x\nlet a = InterfaceText.line("{long_id}", "Library")\n', "outside the pattern")

    def test_a_retired_id_is_refused(self):
        (self.checkout / ids.RETIRED_PATH).write_text("# retired\nlibrary.title\n", encoding="utf-8")
        found, _, problems = sync.read_code(self.checkout)
        self.assertTrue(any("retired" in sentence and "library.title" in sentence for sentence in problems), problems)

    def test_a_call_without_a_note_is_refused(self):
        self.refused('let a = InterfaceText.line("library.title", "Library")\n', "Translators")

    def test_two_calls_on_one_line_are_refused(self):
        self.refused('// Translators: x\nlet a = [InterfaceText.line("a.one", "One"), InterfaceText.line("a.two", "Two")]\n',
                     "another call is on this line")

    def test_an_id_that_is_not_a_literal_is_refused(self):
        self.refused('// Translators: x\nlet a = InterfaceText.line(name, "Library")\n', "the ID is not one plain string literal")

    def test_an_english_that_is_not_a_literal_is_refused(self):
        self.refused('// Translators: x\nlet a = InterfaceText.line("library.title", english)\n', "English")

    def test_one_id_with_two_english_texts_is_refused_naming_both_places(self):
        problems = self.refused('// Translators: x\nlet a = InterfaceText.line("library.title", "Library")\n'
                                '// Translators: x\nlet b = InterfaceText.line("library.title", "The library")\n',
                                "library.title", "Library", "The library")
        self.assertIn(":4:", " ".join(problems))
        self.assertIn(":2", " ".join(problems))

    def test_one_id_used_twice_with_the_same_english_is_fine_and_gives_both_places_and_both_notes(self):
        self.write_source('// Translators: one\nlet a = InterfaceText.line("library.title", "Library")\n'
                          '// Translators: two\nlet b = InterfaceText.line("library.title", "Library")\n')
        found, _, problems = sync.read_code(self.checkout)
        self.assertEqual(problems, [])
        self.assertEqual(found["library.title"].notes, {"one", "two"})
        self.assertEqual([place["line"] for place in found["library.title"].places], [2, 4])

    def test_the_engines_own_declaration_and_prose_are_not_calls(self):
        self.write_source('/// Call `InterfaceText.line("a.b", "x")` like this.\nstatic func line(_ id: String, _ english: String) {}\n')
        found, calls, problems = sync.read_code(self.checkout)
        self.assertEqual((found, calls, problems), ({}, [], []))


class SyncCatalogTests(unittest.TestCase):
    """`sync_catalog`: what each kind of difference does to the catalog."""

    def found(self, **english):
        """{ID: Found} for IDs (written with `_` for `.`) and their English."""
        return {name.replace("_", "."): sync.Found(text, {"A note."}) for name, text in english.items()}

    def cat(self, strings):
        """A catalog of `strings`."""
        return catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings})

    def test_a_new_id_gets_its_english_its_note_and_manual_extraction(self):
        cat = self.cat({})
        report = sync.sync_catalog(cat, self.found(a_b="Hello"))
        self.assertEqual(report.added, ["a.b"])
        self.assertEqual(cat.strings["a.b"], {"comment": "A note.", "extractionState": "manual",
                                              "localizations": {"en": unit("Hello")}})

    def test_the_notes_of_an_id_are_its_comment_one_to_a_line_in_code_point_order(self):
        cat = self.cat({})
        sync.sync_catalog(cat, {"a.b": sync.Found("Hello", {"Zed.", "Alpha."})})
        self.assertEqual(cat.strings["a.b"]["comment"], "Alpha.\nZed.")

    def test_an_id_the_code_lost_becomes_stale_and_keeps_its_translations(self):
        cat = self.cat({"a.b": entry("Old.", extractionState="manual", en=unit("Hello"), es=unit("Hola"))})
        report = sync.sync_catalog(cat, {})
        self.assertEqual(report.stale, ["a.b"])
        self.assertEqual(cat.strings["a.b"]["extractionState"], "stale")
        self.assertEqual(cat.strings["a.b"]["localizations"]["es"], unit("Hola"))

    def test_an_id_that_comes_back_is_no_longer_stale(self):
        cat = self.cat({"a.b": {**entry("A note.", en=unit("Hello")), "extractionState": "stale"}})
        report = sync.sync_catalog(cat, self.found(a_b="Hello"))
        self.assertEqual((report.revived, report.stale, report.english_changed), (["a.b"], [], []))
        self.assertEqual(cat.strings["a.b"]["extractionState"], "manual")

    def test_a_changed_english_is_written_and_every_other_language_needs_review(self):
        cat = self.cat({"a.b": {**entry("A note.", en=unit("Hello"), es=unit("Hola", "machine_translated"),
                                        fr=unit("Salut", "translated"), de=unit("Hallo", "new")), "extractionState": "manual"}})
        report = sync.sync_catalog(cat, self.found(a_b="Hello there"))
        self.assertEqual(report.english_changed, ["a.b"])
        localizations = cat.strings["a.b"]["localizations"]
        self.assertEqual(localizations["en"], unit("Hello there"))
        self.assertEqual(localizations["es"], unit("Hola", "needs_review"))
        self.assertEqual(localizations["fr"], unit("Salut", "needs_review"))
        # A unit that was not finished stays as it was; every translation keeps its text, so it keeps shipping.
        self.assertEqual(localizations["de"], unit("Hallo", "new"))

    def test_a_changed_english_drops_the_english_plural_forms_and_reviews_the_plural_translations(self):
        cat = self.cat({"a.b": {**entry("A note.", en=plural(one=unit("%lld book"), other=unit("%lld books")),
                                        es=plural(one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("%lld libros"))),
                                "extractionState": "manual"}})
        sync.sync_catalog(cat, self.found(a_b="%lld shelved books"))
        localizations = cat.strings["a.b"]["localizations"]
        self.assertEqual(localizations["en"], unit("%lld shelved books"))
        states = {form["stringUnit"]["state"] for form in localizations["es"]["variations"]["plural"].values()}
        self.assertEqual(states, {"needs_review"})
        # The forms keep their text.
        self.assertEqual(localizations["es"]["variations"]["plural"]["one"]["stringUnit"]["value"], "%lld libro")

    def test_an_english_plural_whose_other_form_is_the_codes_english_is_unchanged(self):
        cat = self.cat({"a.b": {**entry("A note.", en=plural(one=unit("%lld book"), other=unit("%lld books"))),
                                "extractionState": "manual"}})
        before = copy.deepcopy(cat.data)
        report = sync.sync_catalog(cat, self.found(a_b="%lld books"))
        self.assertFalse(report.changed())
        self.assertEqual(cat.data, before)

    def test_an_entry_with_no_english_gets_it_from_the_code(self):
        cat = self.cat({"a.b": {**entry("A note."), "extractionState": "manual"}})
        report = sync.sync_catalog(cat, self.found(a_b="Hello"))
        self.assertEqual(report.english_changed, ["a.b"])
        self.assertEqual(cat.strings["a.b"]["localizations"]["en"], unit("Hello"))

    def test_a_changed_note_changes_the_comment(self):
        cat = self.cat({"a.b": {**entry("Old note.", en=unit("Hello")), "extractionState": "manual"}})
        report = sync.sync_catalog(cat, self.found(a_b="Hello"))
        self.assertEqual((report.comments, cat.strings["a.b"]["comment"]), (["a.b"], "A note."))

    def test_the_english_bytes_before_and_after_are_reported(self):
        cat = self.cat({"a.b": {**entry("A note.", en=unit("Hi")), "extractionState": "manual"}})
        report = sync.sync_catalog(cat, self.found(a_b="Hello"))
        self.assertEqual((report.bytes_before, report.bytes_after), (2, 5))


class SyncCommandTests(SyncCase):
    """`l10n.py sync` on the made-up checkout."""

    def test_the_catalog_and_the_locations_are_written_and_the_counts_printed(self):
        status, out, _ = self.run_sync()
        self.assertEqual(status, 0)
        self.assertIn("read 3 InterfaceText.line calls with 3 IDs", out)
        self.assertIn("3 added, 0 became stale", out)
        cat = self.load()
        self.assertEqual(sorted(cat.strings), ["library.count", "library.share", "library.title"])
        self.assertEqual(cat.strings["library.share"]["localizations"]["en"], unit("100%% of %@"))
        data = json.loads(self.locations.read_text(encoding="utf-8"))
        self.assertEqual(data["Localizable"]["library.count"], [{"file": "TextMouth/Models/LibraryWording.swift", "line": 5}])
        self.assertIn("_extracted", data)

    def test_a_second_sync_changes_nothing(self):
        self.run_sync()
        text = self.catalog.read_text(encoding="utf-8")
        status, out, _ = self.run_sync()
        self.assertEqual(status, 0)
        self.assertIn("0 added, 0 became stale, 0 no longer stale, 0 changed their English", out)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), text)

    def test_a_second_sync_leaves_the_catalogs_bytes_and_modification_time_alone(self):
        self.run_sync()
        before = (self.catalog.read_bytes(), self.catalog.stat().st_mtime_ns)
        status, _, _ = self.run_sync()
        self.assertEqual(status, 0)
        self.assertEqual((self.catalog.read_bytes(), self.catalog.stat().st_mtime_ns), before)

    def test_a_sync_with_nothing_to_do_does_not_even_rewrite_a_catalog_in_another_layout(self):
        self.run_sync()
        # Valid JSON in a layout of its own: only a change in the strings may make the sync write the file.
        self.catalog.write_text(json.dumps(json.loads(self.catalog.read_text(encoding="utf-8"))), encoding="utf-8")
        before = self.catalog.read_bytes()
        self.run_sync()
        self.assertEqual(self.catalog.read_bytes(), before)

    def test_the_locations_are_written_every_time(self):
        self.run_sync()
        self.locations.write_text("{}", encoding="utf-8")
        self.run_sync()
        self.assertIn("library.title", self.locations.read_text(encoding="utf-8"))

    def test_the_catalog_is_written_in_the_tools_layout(self):
        self.run_sync()
        text = self.catalog.read_text(encoding="utf-8")
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))

    def test_a_refusal_writes_neither_the_catalog_nor_the_locations(self):
        self.write_source(SOURCE + '// Translators: x\nlet a = InterfaceText.line("Bad", "Library")\n')
        before = self.catalog.read_text(encoding="utf-8")
        status, _, err = self.run_sync()
        self.assertEqual(status, 1)
        self.assertIn("1 problems", err)
        self.assertIn("outside the pattern", err)
        self.assertEqual(self.catalog.read_text(encoding="utf-8"), before)
        self.assertFalse(self.locations.exists())

    def test_a_long_list_of_refusals_is_cut_and_counted(self):
        self.write_source("".join(f'// Translators: x\nlet a{n} = InterfaceText.line("Bad{n}", "T")\n' for n in range(20)))
        _, _, err = self.run_sync()
        self.assertIn("20 problems", err)
        self.assertIn("and 5 more", err)

    def test_an_id_the_code_lost_is_marked_stale_and_one_that_changed_its_english_is_reviewed(self):
        self.run_sync()
        cat = self.load()
        cat.strings["library.title"]["localizations"]["es"] = unit("Biblioteca")
        cat.strings["library.gone"] = {"comment": "x", "extractionState": "manual", "localizations": {"en": unit("Gone")}}
        cat.save()
        self.write_source(SOURCE.replace('"Library"', '"The library"'))
        status, out, _ = self.run_sync("--verbose")
        self.assertEqual(status, 0)
        self.assertIn("1 became stale", out)
        self.assertIn("1 changed their English", out)
        cat = self.load()
        self.assertEqual(cat.strings["library.gone"]["extractionState"], "stale")
        self.assertEqual(cat.strings["library.title"]["localizations"]["es"], unit("Biblioteca", "needs_review"))

    def test_the_sync_takes_seconds_and_needs_no_compiler_or_lock(self):
        # No subprocess is started: a sync that ran the type-check or xcstringstool would call subprocess.run.
        with mock.patch("subprocess.run", side_effect=AssertionError("a process was started")):
            with mock.patch.object(l10n, "head_ids", return_value=(None, None)):
                status, _, _ = self.run_sync()
        self.assertEqual(status, 0)


class PruneRetiresTests(SyncCase):
    """`prune` retires the IDs it deletes, and `sync` then refuses them."""

    def setUp(self):
        super().setUp()
        self.run_sync()
        cat = self.load()
        cat.strings["library.gone"] = {"comment": "x", "extractionState": "stale", "localizations": {"en": unit("Gone")}}
        cat.save()
        self.retired = self.checkout / ids.RETIRED_PATH

    def prune(self, *extra):
        """Runs prune on the checkout's catalog; returns (status, standard output)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = l10n.main(["prune", "--catalog", str(self.catalog), *extra])
        return status, out.getvalue()

    def test_a_pruned_id_goes_to_the_retired_file(self):
        status, out = self.prune()
        self.assertEqual(status, 0)
        self.assertIn("1 IDs added to retired-ids.txt", out)
        self.assertIn("library.gone", self.retired.read_text(encoding="utf-8").split("\n"))
        self.assertNotIn("library.gone", self.load().strings)

    def test_a_dry_run_retires_nothing(self):
        self.prune("--dry-run")
        self.assertFalse(self.retired.exists())

    def test_a_retired_id_is_refused_when_the_code_uses_it_again(self):
        self.prune()
        self.write_source(SOURCE + '// Translators: x\nlet a = InterfaceText.line("library.gone", "Gone")\n')
        status, _, err = self.run_sync()
        self.assertEqual(status, 1)
        self.assertIn("retired", err)

    def test_an_id_is_retired_once(self):
        sync.retire(self.checkout, ["b.b", "a.a"])
        sync.retire(self.checkout, ["a.a", "c.c"])
        self.assertEqual(self.retired.read_text(encoding="utf-8").split("\n")[-4:], ["a.a", "b.b", "c.c", ""])


class RepositoryTests(unittest.TestCase):
    """The repository's own catalog against its own code."""

    def test_the_catalog_is_in_step_with_the_code(self):
        root = l10n.HERE.parents[1]
        found, _calls, problems = sync.read_code(root)
        self.assertEqual(problems, [])
        cat = catalog.Catalog.load(root / l10n.CATALOG_FOLDER / "Localizable.xcstrings")
        before = copy.deepcopy(cat.data)
        report = sync.sync_catalog(cat, found)
        # A sync of the committed catalog changes nothing: the second run of a sync is a no-op.
        self.assertEqual((report.added, report.stale, report.revived, report.english_changed, report.comments), ([], [], [], [], []))
        self.assertEqual(cat.data, before)


if __name__ == "__main__":
    unittest.main()
