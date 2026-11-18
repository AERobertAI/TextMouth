"""Tests of Scripts/l10n/merge.py and `l10n.py merge-driver`: the three-way merge of String Catalogs by key, language, and
plural form, run directly and through real `git merge`s in a scratch repository.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every git test works in a temporary repository whose configuration is its own (the user's and the system's are not read),
so the repository's config and the working tree are never touched.
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402
import merge  # noqa: E402
from git_case import HAS_GIT, GitCase  # noqa: E402

L10N = HERE.parent / "l10n.py"
CATALOG_FILE = "Localizable.xcstrings"


def unit(value, state="machine_translated"):
    """A localization holding one text."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    """A localization holding plural forms: plural(one="a", other="b")."""
    return {"variations": {"plural": {category: {"stringUnit": {"state": "machine_translated", "value": text}}
                                      for category, text in forms.items()}}}


def entry(comment="Context", **localizations):
    """A catalog entry with a comment and localizations by language."""
    return {"comment": comment, "localizations": localizations} if localizations else {"comment": comment}


def make(strings):
    """A catalog's JSON object holding `strings`."""
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def merged(base, ours, theirs):
    """(the merged catalog, the conflicts) of three catalogs given as objects."""
    return merge.merge_catalogs(base, ours, theirs)


class MergeTests(unittest.TestCase):
    """merge.py on loaded catalogs."""

    BASE = make({"Play": entry("The play button"), "Stop": entry("The stop button")})

    def edit(self, **changes):
        """A copy of BASE with `changes` (key to entry, or None to delete) made to its strings."""
        copy = json.loads(json.dumps(self.BASE))
        for key, value in changes.items():
            if value is None:
                del copy["strings"][key]
            else:
                copy["strings"][key] = value
        return copy

    def test_keys_added_on_each_side_are_both_taken(self):
        result, conflicts = merged(self.BASE, self.edit(Pause=entry("A")), self.edit(Next=entry("B")))
        self.assertEqual(conflicts, [])
        self.assertEqual(sorted(result["strings"]), ["Next", "Pause", "Play", "Stop"])

    def test_a_key_deleted_on_one_side_goes_when_the_other_left_it_alone(self):
        result, conflicts = merged(self.BASE, self.edit(Stop=None), self.BASE)
        self.assertEqual((conflicts, sorted(result["strings"])), ([], ["Play"]))
        result, conflicts = merged(self.BASE, self.BASE, self.edit(Stop=None))
        self.assertEqual((conflicts, sorted(result["strings"])), ([], ["Play"]))

    def test_different_languages_of_one_key_are_both_taken(self):
        result, conflicts = merged(self.BASE, self.edit(Play=entry("The play button", es=unit("Reproducir"))),
                                   self.edit(Play=entry("The play button", fr=unit("Lire"))))
        self.assertEqual(conflicts, [])
        self.assertEqual(sorted(result["strings"]["Play"]["localizations"]), ["es", "fr"])

    def test_different_plural_forms_of_one_language_are_both_taken(self):
        base = make({"%lld books": entry("Books", es=plural(one="%lld libro"))})
        ours = make({"%lld books": entry("Books", es=plural(one="%lld libro", many="%lld de libros"))})
        theirs = make({"%lld books": entry("Books", es=plural(one="%lld libro", other="%lld libros"))})
        result, conflicts = merged(base, ours, theirs)
        self.assertEqual(conflicts, [])
        forms = result["strings"]["%lld books"]["localizations"]["es"]["variations"]["plural"]
        self.assertEqual(sorted(forms), ["many", "one", "other"])

    def test_a_comment_changed_on_one_side_and_a_translation_on_the_other_are_both_taken(self):
        result, conflicts = merged(self.BASE, self.edit(Play=entry("A better comment")),
                                   self.edit(Play=entry("The play button", es=unit("Reproducir"))))
        self.assertEqual(conflicts, [])
        self.assertEqual(result["strings"]["Play"]["comment"], "A better comment")
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))

    def test_the_same_change_on_both_sides_is_taken_once(self):
        same = self.edit(Play=entry("The play button", es=unit("Reproducir")))
        result, conflicts = merged(self.BASE, same, json.loads(json.dumps(same)))
        self.assertEqual(conflicts, [])
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))

    def test_the_same_unit_changed_differently_is_a_conflict_and_ours_is_kept(self):
        result, conflicts = merged(self.BASE, self.edit(Play=entry("The play button", es=unit("Reproducir"))),
                                   self.edit(Play=entry("The play button", es=unit("Tocar"))))
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))
        text = conflicts[0].describe()
        self.assertIn('"Play" localizations.es.stringUnit', text)
        self.assertIn("Reproducir", text)
        self.assertIn("Tocar", text)
        self.assertIn("the base has (absent)", text)

    def test_a_translations_state_and_value_are_not_mixed_from_two_sides(self):
        base = make({"Play": entry("c", es=unit("Reproducir"))})
        ours = make({"Play": entry("c", es=unit("Reproducir", "translated"))})
        theirs = make({"Play": entry("c", es=unit("Tocar"))})
        result, conflicts = merged(base, ours, theirs)
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir", "translated"))

    def test_a_key_deleted_on_one_side_and_translated_on_the_other_is_a_conflict(self):
        theirs = self.edit(Play=entry("The play button", es=unit("Reproducir")))
        result, conflicts = merged(self.BASE, self.edit(Play=None), theirs)
        self.assertTrue(conflicts)
        self.assertNotIn("Play", result["strings"], "ours is kept: the key stays deleted")
        result, conflicts = merged(self.BASE, theirs, self.edit(Play=None))
        self.assertTrue(conflicts)
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))

    def test_a_language_written_one_way_by_one_side_and_the_other_way_by_the_other_is_a_conflict_with_ours_kept(self):
        result, conflicts = merged(self.BASE, self.edit(Play=entry("The play button", es=unit("Reproducir"))),
                                   self.edit(Play=entry("The play button", es=plural(one="Reproducir", other="Reproducir"))))
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))
        # And the other way round, ours has plural forms: those are kept whole.
        result, _ = merged(self.BASE, self.edit(Play=entry("The play button", es=plural(one="a", other="b"))),
                           self.edit(Play=entry("The play button", es=unit("Reproducir"))))
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], plural(one="a", other="b"))

    def test_both_sides_adding_one_key_with_different_languages_merge_from_an_empty_base(self):
        result, conflicts = merged({}, make({"New": entry("c", es=unit("Nuevo"))}), make({"New": entry("c", fr=unit("Nouveau"))}))
        self.assertEqual(conflicts, [])
        self.assertEqual(sorted(result["strings"]["New"]["localizations"]), ["es", "fr"])

    def test_an_empty_localizations_object_survives_and_gives_way_to_a_translation(self):
        base = make({"Play": {"comment": "c", "localizations": {}}})
        result, conflicts = merged(base, base, make({"Play": entry("c", es=unit("Reproducir"))}))
        self.assertEqual(conflicts, [])
        self.assertEqual(result["strings"]["Play"]["localizations"], {"es": unit("Reproducir")})
        result, _ = merged(base, base, base)
        self.assertEqual(result["strings"]["Play"]["localizations"], {})

    def test_the_input_is_not_changed(self):
        ours = self.edit(Pause=entry("A"))
        before = json.dumps(ours, sort_keys=True)
        merged(self.BASE, ours, self.edit(Next=entry("B")))
        self.assertEqual(json.dumps(ours, sort_keys=True), before)

    def test_the_text_is_written_in_the_tools_layout(self):
        text, conflicts = merge.merge_texts(catalog.dumps(self.BASE), catalog.dumps(self.edit(Pause=entry("A"))), catalog.dumps(self.BASE))
        self.assertEqual(conflicts, [])
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))

    def test_an_empty_text_is_an_empty_catalog(self):
        text, conflicts = merge.merge_texts("", catalog.dumps(self.BASE), "")
        self.assertEqual((conflicts, catalog.loads(text)["strings"].keys()), ([], self.BASE["strings"].keys()))


class DriverCommandTests(unittest.TestCase):
    """`l10n.py merge-driver BASE OURS THEIRS PATH`, called as git calls it."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def drive(self, base, ours, theirs):
        """Writes the three catalogs (objects) as files, runs the driver on them, and returns (exit status, standard error,
        the catalog now in OURS as an object)."""
        paths = {}
        for name, data in (("base", base), ("ours", ours), ("theirs", theirs)):
            paths[name] = self.folder / name
            catalog.write_text(paths[name], catalog.dumps(data))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = l10n.main(["merge-driver", str(paths["base"]), str(paths["ours"]), str(paths["theirs"]),
                                "TextMouth/Localization/Localizable.xcstrings"])
        return status, err.getvalue(), catalog.loads(catalog.read_text(paths["ours"]))

    def test_a_clean_merge_writes_the_result_over_ours_and_exits_0(self):
        base = make({"Play": entry("c")})
        status, err, result = self.drive(base, make({"Play": entry("c"), "A": entry("c")}), make({"Play": entry("c"), "B": entry("c")}))
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(sorted(result["strings"]), ["A", "B", "Play"])

    def test_a_conflict_exits_1_prints_the_key_and_both_values_and_keeps_ours(self):
        base = make({"Play": entry("c")})
        status, err, result = self.drive(base, make({"Play": entry("c", es=unit("Reproducir"))}),
                                         make({"Play": entry("c", es=unit("Tocar"))}))
        self.assertEqual(status, 1)
        self.assertIn("Localizable.xcstrings", err)
        self.assertIn('"Play" localizations.es.stringUnit', err)
        self.assertIn("Reproducir", err)
        self.assertIn("Tocar", err)
        self.assertEqual(result["strings"]["Play"]["localizations"]["es"], unit("Reproducir"))

    def test_a_file_that_is_not_a_catalog_is_refused_and_ours_is_left_alone(self):
        ours = self.folder / "ours"
        for name in ("base", "theirs"):
            catalog.write_text(self.folder / name, catalog.dumps(make({})))
        catalog.write_text(ours, "{ not json")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = l10n.main(["merge-driver", str(self.folder / "base"), str(ours), str(self.folder / "theirs")])
        self.assertEqual(status, 2)
        self.assertEqual(catalog.read_text(ours), "{ not json")
        self.assertIn("cannot merge", err.getvalue())


class DriverRefusalTests(unittest.TestCase):
    """The driver refuses what is not a catalog (exit 2, ours untouched) instead of merging it silently (review finding 1)."""

    GOOD = make({"Play": entry("c")})

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def drive_texts(self, base, ours, theirs):
        """Runs the driver on three texts; returns (exit status, standard error, the text now in OURS)."""
        paths = {}
        for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
            paths[name] = self.folder / name
            catalog.write_text(paths[name], text)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = l10n.main(["merge-driver", str(paths["base"]), str(paths["ours"]), str(paths["theirs"]), "X.xcstrings"])
        return status, err.getvalue(), catalog.read_text(paths["ours"])

    def assert_refused(self, base, ours, theirs, words=""):
        """Asserts that the driver exits 2, names `words`, and leaves OURS byte for byte as it was."""
        status, err, now = self.drive_texts(base, ours, theirs)
        self.assertEqual(status, 2, err)
        self.assertEqual(now, ours)
        self.assertIn(words, err)

    def test_an_empty_object_as_theirs_is_refused_and_ours_keeps_its_added_key(self):
        """The review's case: ours added a key, theirs is `{}`; the key used to vanish with exit 0."""
        base = catalog.dumps(self.GOOD)
        ours = catalog.dumps(make({"Play": entry("c"), "C": entry("c")}))
        self.assert_refused(base, ours, "{}", "theirs has no `strings`")

    def test_a_json_object_with_no_strings_is_refused_on_either_side(self):
        good = catalog.dumps(self.GOOD)
        self.assert_refused(good, good, '{"hello": 1}', "theirs has no `strings`")
        self.assert_refused(good, '{"hello": 1}', good, "ours has no `strings`")
        self.assert_refused('{"hello": 1}', good, good, "the base has no `strings`")

    def test_strings_that_are_not_an_object_of_objects_are_refused(self):
        good = catalog.dumps(self.GOOD)
        for bad in ('{"strings": [1]}', '{"strings": null}', '{"strings": "x"}', '{"strings": {"A": 1}}',
                    '{"strings": {"A": null}}', '{"strings": {"A": []}}'):
            with self.subTest(bad=bad):
                self.assert_refused(good, good, bad, "theirs")

    def test_a_top_level_that_is_not_an_object_is_refused(self):
        good = catalog.dumps(self.GOOD)
        for bad in ("[]", '"text"', "7", "null"):
            with self.subTest(bad=bad):
                self.assert_refused(good, good, bad, "not a JSON object")

    def test_a_result_without_a_required_key_is_refused(self):
        """Three inputs that have `strings` but no `version`: the merged catalog would lack it."""
        for dropped in ("sourceLanguage", "version"):
            bare = {key: value for key, value in self.GOOD.items() if key != dropped}
            text = catalog.dumps(bare)
            with self.subTest(dropped=dropped):
                self.assert_refused(text, text, text, f"would lack `{dropped}`")

    def test_an_empty_file_is_still_an_empty_catalog(self):
        """Git gives an empty file for a version that does not exist (both branches added the file)."""
        status, _, now = self.drive_texts("", catalog.dumps(self.GOOD), catalog.dumps(make({"B": entry("c")})))
        self.assertEqual(status, 0)
        self.assertEqual(sorted(catalog.loads(now)["strings"]), ["B", "Play"])

    def test_a_merge_with_an_empty_catalog_object_inside_still_keeps_every_piece(self):
        """`unflatten` returned at the empty path and dropped the other pieces; an empty base object no longer does so."""
        self.assertEqual(merge.unflatten({(): {}, ("a",): 1}), {"a": 1})
        base = make({})
        status, _, now = self.drive_texts(catalog.dumps(base), catalog.dumps(make({"A": entry("c")})), catalog.dumps(base))
        self.assertEqual((status, list(catalog.loads(now)["strings"])), (0, ["A"]))

    def test_the_result_is_written_through_a_rename_so_a_failed_write_leaves_ours_whole(self):
        """The write goes to a temporary file in the same folder, then os.replace; if the rename fails, OURS is intact."""
        ours = catalog.dumps(make({"Play": entry("c"), "A": entry("c")}))
        base, theirs = catalog.dumps(self.GOOD), catalog.dumps(make({"Play": entry("c"), "B": entry("c")}))
        for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
            catalog.write_text(self.folder / name, text)
        args = ["merge-driver", *(str(self.folder / name) for name in ("base", "ours", "theirs"))]
        err = io.StringIO()
        with mock.patch("os.replace", side_effect=OSError("disk full")), contextlib.redirect_stderr(err):
            status = l10n.main(args)
        self.assertEqual(status, 2)
        self.assertEqual(catalog.read_text(self.folder / "ours"), ours)
        # Without the failure the same merge succeeds and leaves no temporary behind.
        self.assertEqual(l10n.main(args), 0)
        self.assertEqual(sorted(catalog.loads(catalog.read_text(self.folder / "ours"))["strings"]), ["A", "B", "Play"])
        self.assertEqual([path.name for path in self.folder.iterdir() if path.name.startswith(".")], [])


@unittest.skipUnless(HAS_GIT, "git is not installed")
class GitMergeTests(GitCase):
    """Real merges in a scratch repository that has the driver defined, as `make l10n-merge-driver` defines it."""

    def setUp(self):
        super().setUp()
        self.put(".gitattributes", "*.xcstrings merge=xcstrings\n")
        self.define_driver()
        self.write(make({"Play": entry("The play button"), "Rewind": entry("The rewind button")}))
        self.commit_all("base")

    def define_driver(self):
        """Defines the driver the way the Makefile's target does, with this checkout's script."""
        self.git("config", "merge.xcstrings.name", "a String Catalog")
        self.git("config", "merge.xcstrings.driver", f"{sys.executable} -I -B {L10N} merge-driver %O %A %B %P")

    def write(self, data):
        """Writes the catalog `data` in the repository's working tree."""
        catalog.write_text(self.repo / CATALOG_FILE, catalog.dumps(data))

    def read(self):
        """The catalog in the repository's working tree, as an object."""
        return catalog.loads(catalog.read_text(self.repo / CATALOG_FILE))

    def branch(self, name, strings):
        """Makes the branch `name` from main with `strings` added to (or replaced in) the catalog, and commits it."""
        self.git("switch", "-q", "main")
        self.git("switch", "-q", "-c", name)
        data = self.read()
        data["strings"].update(strings)
        self.write(data)
        self.git("commit", "-q", "-am", name)

    def merge_into(self, ours, theirs, check=True):
        """Switches to the branch `ours` and merges `theirs` into it; returns the completed process."""
        self.git("switch", "-q", ours)
        return self.git("merge", "--no-edit", theirs, check=check)

    def test_without_the_driver_neighbouring_keys_conflict_as_text(self):
        """The control: it is the driver, and not luck, that merges the next tests."""
        self.git("config", "--unset", "merge.xcstrings.driver")
        self.branch("a", {"Playback": entry("A")})
        self.branch("b", {"Playlist": entry("B")})
        self.assertNotEqual(self.merge_into("a", "b", check=False).returncode, 0)

    def test_two_branches_adding_neighbouring_keys_merge_cleanly(self):
        self.branch("a", {"Playback": entry("A")})
        self.branch("b", {"Playlist": entry("B")})
        done = self.merge_into("a", "b")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(sorted(self.read()["strings"]), ["Play", "Playback", "Playlist", "Rewind"])
        text = catalog.read_text(self.repo / CATALOG_FILE)
        self.assertEqual(text, catalog.dumps(catalog.loads(text)), "the merged file is in the tools' layout")

    def test_one_branch_adding_a_key_while_the_other_translates_another_merge_cleanly(self):
        self.branch("a", {"Playback": entry("A")})
        self.branch("b", {"Play": entry("The play button", es=unit("Reproducir"))})
        self.assertEqual(self.merge_into("a", "b").returncode, 0)
        result = self.read()["strings"]
        self.assertIn("Playback", result)
        self.assertEqual(result["Play"]["localizations"]["es"], unit("Reproducir"))

    def test_two_branches_translating_one_key_the_same_way_merge_cleanly(self):
        self.branch("a", {"Play": entry("The play button", es=unit("Reproducir"))})
        self.branch("b", {"Play": entry("The play button", es=unit("Reproducir"))})
        self.assertEqual(self.merge_into("a", "b").returncode, 0)

    def test_two_branches_translating_one_key_differently_conflict_and_the_file_is_marked_conflicted(self):
        self.branch("a", {"Play": entry("The play button", es=unit("Reproducir"))})
        self.branch("b", {"Play": entry("The play button", es=unit("Tocar"))})
        done = self.merge_into("a", "b", check=False)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("CONFLICT", done.stdout)
        self.assertIn("Tocar", done.stderr + done.stdout, "git shows the driver's message with both values")
        self.assertIn("Reproducir", done.stderr + done.stdout)
        unmerged = self.git("ls-files", "-u").stdout
        self.assertIn(CATALOG_FILE, unmerged, "the file is reported conflicted, with its three stages")
        self.assertEqual(self.read()["strings"]["Play"]["localizations"]["es"], unit("Reproducir"), "ours is kept in the file")
        self.assertNotIn("<<<<<<<", catalog.read_text(self.repo / CATALOG_FILE), "no conflict markers are written into the JSON")

    def test_a_conflict_in_one_key_does_not_lose_the_other_keys_changes(self):
        self.branch("a", {"Play": entry("The play button", es=unit("Reproducir")), "Playback": entry("A")})
        self.branch("b", {"Play": entry("The play button", es=unit("Tocar")), "Playlist": entry("B")})
        self.merge_into("a", "b", check=False)
        self.assertEqual(sorted(self.read()["strings"]), ["Play", "Playback", "Playlist", "Rewind"])

    def test_plural_forms_written_by_two_branches_merge_by_form(self):
        self.branch("a", {"%lld books": entry("Books", es=plural(one="%lld libro", many="%lld de libros"))})
        self.branch("b", {"%lld books": entry("Books", es=plural(one="%lld libro", other="%lld libros"))})
        self.assertEqual(self.merge_into("a", "b").returncode, 0)
        forms = self.read()["strings"]["%lld books"]["localizations"]["es"]["variations"]["plural"]
        self.assertEqual(sorted(forms), ["many", "one", "other"])


if __name__ == "__main__":
    unittest.main()
