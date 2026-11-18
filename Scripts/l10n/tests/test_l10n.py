"""Tests of Scripts/l10n/l10n.py: sync, status, size, and check.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The sync tests read recorded .stringsdata files (fixtures/stringsdata/, in the compiler's own layout, with made-up
paths), so they build nothing and take no lock; one test also runs the real `xcstringstool` when it is installed.
Every test works in a temporary folder and never touches the repository's own catalog or build folders.
"""
import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402

FIXTURES = HERE / "fixtures" / "stringsdata"
HAS_TOOL = bool(shutil.which("xcrun")) and subprocess.run(["xcrun", "--find", "xcstringstool"], capture_output=True).returncode == 0


def unit(value, state="translated"):
    """A stringUnit node."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    """Plural variations: plural(one=unit("a"), other=unit("b")) is a localization."""
    return {"variations": {"plural": forms}}


def make_catalog(strings):
    """A Catalog holding `strings` (key to entry), in English."""
    return catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings})


def entry(comment="Context", **localizations):
    """A catalog entry with a comment and localizations by language."""
    return {"comment": comment, "localizations": localizations} if localizations else {"comment": comment}


def args_for(command, catalog_file=None, **extra):
    """The parsed arguments of `command` as the command line would give them."""
    argv = [command]
    if catalog_file:
        argv += ["--catalog", str(catalog_file)]
    for name, value in extra.items():
        option = "--" + name.replace("_", "-")
        if value is True:
            argv.append(option)
        elif value is not False:
            argv += [option, str(value)]
    return l10n.build_parser().parse_args(argv)


class TemporaryCase(unittest.TestCase):
    """A temporary folder for each test."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def write_catalog(self, strings, name="Localizable.xcstrings"):
        """Writes `strings` as a catalog file in the temporary folder and returns its path."""
        path = self.folder / name
        make_catalog(strings).save(path)
        return path


class SyncCase(TemporaryCase):
    """A copy of the recorded runs and an empty catalog to sync them into."""

    def setUp(self):
        super().setUp()
        self.runs = {}
        for platform in l10n.PLATFORMS:
            self.runs[platform] = self.folder / "runs" / platform
            shutil.copytree(FIXTURES / platform, self.runs[platform])
        self.catalog = self.write_catalog({})
        self.locations = self.folder / "out" / "locations.json"
        self.lines = []
        self.config = self.folder / "sync-config.json"
        self.set_sync_paths("TextMouth/**")

    def set_sync_paths(self, *globs):
        """Writes the sync's configuration with these `syncPaths`."""
        self.config.write_text(json.dumps({"syncPaths": list(globs)}))

    def manifests(self):
        """The two runs' manifests, as the sync reads them."""
        return [l10n.read_manifest(self.runs[platform]) for platform in l10n.PLATFORMS]

    def sync(self):
        """Runs the sync on the copies; returns its exit status (its lines are in `self.lines`)."""
        args = args_for("sync", self.catalog, verbose=False, config=self.config)
        return l10n.sync_manifests(args, self.manifests(), self.lines.append, self.locations)

    def edit_manifest(self, which, **changes):
        """Changes fields of the manifest of the run of platform `which` on disk."""
        path = self.runs[which] / l10n.STRINGS_MANIFEST
        data = json.loads(path.read_text())
        data.update(changes)
        path.write_text(json.dumps(data))


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class SyncTests(SyncCase):
    """`sync`: merging both apps' strings."""

    def test_the_strings_of_both_apps_are_added_and_none_is_stale(self):
        self.assertEqual(self.sync(), 1, "the Menus table has no catalog, so the sync reports a problem")
        strings = catalog.Catalog.load(self.catalog).strings
        self.assertEqual(sorted(strings), ["%lld books", "Play", "Reveal in Finder", "Share"])
        self.assertTrue(all("extractionState" not in value for value in strings.values()), "a string found in code is not marked")
        self.assertEqual(strings["Play"]["comment"], "The button that plays the book")

    def test_a_string_only_one_app_has_stays_when_both_are_given(self):
        # The Mac-only and the iPhone-only strings are each absent from the other app's files; given both, neither is stale.
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertFalse(any(cat.is_stale(entry) for entry in cat.strings.values()))

    def test_the_counts_and_the_english_bytes_are_printed(self):
        self.sync()
        text = "\n".join(self.lines)
        self.assertIn("Localizable: 4 added, 0 became stale, 0 no longer stale, 0 removed", text)
        self.assertIn("the English text went from 0 to 35 bytes", text)
        self.assertIn("kept 5 strings of 6 converted files (Mac 4, iPhone 3", text)

    def test_the_catalog_is_left_in_the_tools_layout(self):
        self.sync()
        text = catalog.read_text(self.catalog)
        self.assertEqual(catalog.dumps(catalog.loads(text)), text)

    def test_a_second_sync_of_the_same_runs_changes_nothing(self):
        self.sync()
        first = catalog.read_text(self.catalog)
        self.lines.clear()
        self.sync()
        self.assertEqual(catalog.read_text(self.catalog), first)
        self.assertIn("Localizable: 0 added, 0 became stale", "\n".join(self.lines))

    def test_a_string_that_left_the_code_becomes_stale_and_keeps_its_translation(self):
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        cat.strings["Share"]["localizations"] = {"es": unit("Compartir")}
        cat.save()
        # The iPhone's PhoneOnly file no longer holds Share.
        (self.runs["ios"] / "PhoneOnly.stringsdata").write_text(json.dumps(
            {"source": "/work/typecheck/ios-strings/src/TextMouth/Platform/iOS/PhoneOnly.swift", "tables": {}, "version": 1}))
        self.lines.clear()
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertTrue(cat.is_stale(cat.strings["Share"]))
        self.assertEqual(cat.units("Share", "es")[0].value, "Compartir")
        self.assertIn("1 became stale", "\n".join(self.lines))
        self.assertIn('became stale: "Share"', "\n".join(self.lines))

    def test_the_locations_map_each_key_to_its_repository_files_and_lines_without_repeats(self):
        self.sync()
        places = json.loads(self.locations.read_text())["Localizable"]
        self.assertEqual(places["Play"], [{"file": "TextMouth/Views/LibraryView.swift", "line": 12}], "found by both apps, listed once")
        self.assertEqual(places["Share"], [{"file": "TextMouth/Platform/iOS/PhoneOnly.swift", "line": 22}])
        self.assertEqual(places["Reveal in Finder"], [{"file": "TextMouth/Platform/macOS/MacOnly.swift", "line": 8}])
        self.assertNotIn("/work/", self.locations.read_text(), "a path of the type-check's copy leaked into the locations")

    def test_the_locations_carry_the_commit_and_sources_they_were_made_from(self):
        """`todo` reads this stamp to tell when the lines it shows come from other code (TL12)."""
        self.sync()
        stamp = json.loads(self.locations.read_text())[l10n.EXTRACTED_KEY]
        self.assertEqual(stamp, {"commit": "abc1234", "treeId": "0000000000000000000000000000000000000000"})
        self.assertNotIn(l10n.EXTRACTED_KEY, json.loads(self.locations.read_text())["Localizable"], "it is beside the tables")

    def test_a_table_with_no_catalog_is_reported_and_the_others_are_still_synced(self):
        status = self.sync()
        self.assertEqual(status, l10n.EXIT_PROBLEMS)
        self.assertIn("no catalog for the table 'Menus'", "\n".join(self.lines))
        self.assertTrue(catalog.Catalog.load(self.catalog).strings, "the main table was not synced")

    def test_a_table_with_a_catalog_of_its_name_is_synced_there(self):
        menus = self.write_catalog({}, "Menus.xcstrings")
        self.catalog = self.folder / "Localizable.xcstrings"
        args = args_for("sync", self.catalog, config=self.config)
        with mock.patch.object(l10n, "catalog_path", lambda _args, table=l10n.TABLE: self.folder / f"{table}.xcstrings"):
            status = l10n.sync_manifests(args, self.manifests(), self.lines.append, self.locations)
        self.assertEqual(status, 0)
        self.assertEqual(sorted(catalog.Catalog.load(menus).strings), ["Shortcut"])
        self.assertNotIn("Shortcut", catalog.Catalog.load(self.catalog).strings)


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class SyncPathsTests(SyncCase):
    """`syncPaths`: the catalog holds the strings of the converted files only."""

    def keys(self):
        """The keys the catalog holds."""
        return sorted(catalog.Catalog.load(self.catalog).strings)

    def add_entry(self, platform, name, key):
        """Adds `key` to the entries of a file of a run."""
        path = self.runs[platform] / name
        data = json.loads(path.read_text())
        data["tables"].setdefault("Localizable", []).append(
            {"comment": "also here", "key": key, "location": {"startingColumn": 1, "startingLine": 99}})
        path.write_text(json.dumps(data))

    def test_a_key_in_a_converted_file_is_kept_and_one_only_in_unconverted_files_is_left_out(self):
        self.set_sync_paths("TextMouth/Views/**")
        self.sync()
        self.assertEqual(self.keys(), ["%lld books", "Play"])
        self.assertIn("left out by syncPaths (TextMouth/Views/**): 3 strings", "\n".join(self.lines))

    def test_the_other_files_strings_are_kept_when_the_other_glob_is_given(self):
        self.set_sync_paths("TextMouth/Platform/**")
        self.sync()
        self.assertEqual(self.keys(), ["Reveal in Finder", "Share"])

    def test_a_key_in_a_converted_and_an_unconverted_file_is_kept(self):
        # Play is in LibraryView.swift (not converted here) and also in MacOnly.swift (converted).
        self.add_entry("macos", "MacOnly.stringsdata", "Play")
        self.set_sync_paths("TextMouth/Platform/macOS/**")
        self.sync()
        self.assertIn("Play", self.keys())
        places = json.loads(self.locations.read_text())["Localizable"]["Play"]
        self.assertEqual(places, [{"file": "TextMouth/Platform/macOS/MacOnly.swift", "line": 99}],
                         "the locations list the converted files' places only")

    def test_an_empty_sync_paths_gives_an_empty_catalog(self):
        self.set_sync_paths()
        self.sync()
        self.assertEqual(self.keys(), [])
        self.assertIn("left out by syncPaths (none): 5 strings", "\n".join(self.lines))

    def test_an_empty_sync_paths_removes_the_strings_a_catalog_held_without_translations(self):
        self.set_sync_paths("TextMouth/**")
        self.sync()
        self.assertEqual(len(self.keys()), 4)
        self.set_sync_paths()
        self.sync()
        self.assertEqual(self.keys(), [])

    def test_a_key_that_leaves_every_converted_file_goes_stale_and_keeps_its_translation(self):
        self.set_sync_paths("TextMouth/**")
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        cat.strings["Share"]["localizations"] = {"es": unit("Compartir")}
        cat.save()
        self.set_sync_paths("TextMouth/Views/**", "TextMouth/Platform/macOS/**")
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertTrue(cat.is_stale(cat.strings["Share"]))
        self.assertEqual(cat.units("Share", "es")[0].value, "Compartir")

    def test_both_platforms_are_still_read_so_the_other_apps_converted_strings_are_not_stale(self):
        self.set_sync_paths("TextMouth/Platform/**")
        self.sync()
        cat = catalog.Catalog.load(self.catalog)
        self.assertEqual(sorted(cat.strings), ["Reveal in Finder", "Share"])
        self.assertFalse(any(cat.is_stale(entry) for entry in cat.strings.values()))

    def test_the_record_of_what_was_left_out_is_written_and_status_and_size_say_it(self):
        self.set_sync_paths("TextMouth/Views/**")
        self.sync()
        record = l10n.read_left_out(self.locations.parent)
        self.assertEqual((record["kept"], record["leftOut"]), (2, 3))
        self.assertEqual(record["leftOutKeys"], {"Localizable": ["Reveal in Finder", "Share"], "Menus": ["Shortcut"]})
        for command, function in (("status", l10n.cmd_status), ("size", l10n.cmd_size)):
            out = io.StringIO()
            with mock.patch.object(l10n, "OUTPUT", self.locations.parent), contextlib.redirect_stdout(out):
                function(args_for(command, self.catalog, config=self.config))
            self.assertIn("Strings left out by syncPaths: 3 found by the compiler in files not yet converted (the last sync kept 2",
                          out.getvalue(), command)


class GlobTests(unittest.TestCase):
    """The globs of `syncPaths`."""

    def matches(self, glob, path):
        """Whether `glob` matches `path`."""
        return l10n.path_matcher([glob])(path)

    def test_double_star_matches_any_depth_and_the_whole_tree(self):
        self.assertTrue(self.matches("TextMouth/**", "TextMouth/Views/Library/LibraryView.swift"))
        self.assertTrue(self.matches("TextMouth/Views/**", "TextMouth/Views/A.swift"))
        self.assertFalse(self.matches("TextMouth/Views/**", "TextMouth/Models/A.swift"))
        self.assertFalse(self.matches("TextMouth/**", "Vendor/A.swift"))

    def test_a_single_star_stays_within_one_folder(self):
        self.assertTrue(self.matches("TextMouth/Views/*.swift", "TextMouth/Views/A.swift"))
        self.assertFalse(self.matches("TextMouth/Views/*.swift", "TextMouth/Views/Library/A.swift"))
        self.assertTrue(self.matches("TextMouth/Models/*Wording.swift", "TextMouth/Models/BookWording.swift"))

    def test_double_star_slash_matches_no_folder_at_all(self):
        self.assertTrue(self.matches("TextMouth/**/*.swift", "TextMouth/A.swift"))
        self.assertTrue(self.matches("TextMouth/**/*.swift", "TextMouth/Views/Library/A.swift"))
        self.assertFalse(self.matches("TextMouth/**/*.swift", "TextMouth/Views/A.txt"))

    def test_a_question_mark_is_one_character_and_a_dot_is_a_dot(self):
        self.assertTrue(self.matches("TextMouth/A?.swift", "TextMouth/Ab.swift"))
        self.assertFalse(self.matches("TextMouth/A?.swift", "TextMouth/A/.swift"))
        self.assertFalse(self.matches("TextMouth/A.swift", "TextMouth/AXswift"))

    def test_no_globs_match_nothing(self):
        self.assertFalse(l10n.path_matcher([])("TextMouth/A.swift"))

    def test_a_path_must_match_whole(self):
        self.assertFalse(self.matches("TextMouth/A", "TextMouth/A.swift"))


class RefusalTests(SyncCase):
    """A sync that must not run: nothing is changed."""

    def refused(self, fragment):
        """Asserts that the sync is refused with a message holding `fragment` and the catalog is untouched."""
        before = catalog.read_text(self.catalog)
        with self.assertRaises(l10n.Refused) as refusal:
            self.sync()
        self.assertIn(fragment, str(refusal.exception))
        self.assertEqual(catalog.read_text(self.catalog), before)
        self.assertFalse(self.locations.exists())

    def test_one_app_alone_is_refused(self):
        with self.assertRaises(l10n.Refused) as refusal:
            l10n.check_manifests([self.manifests()[0]])
        self.assertIn("needs the strings of both apps", str(refusal.exception))

    def test_two_runs_of_the_same_app_are_refused(self):
        self.edit_manifest("ios", platform="macos")
        self.refused("needs the strings of both apps")

    def test_runs_of_different_trees_are_refused(self):
        self.edit_manifest("ios", treeId="1" * 40)
        self.refused("not of the same tree")

    def test_a_commit_run_and_a_working_tree_run_are_refused(self):
        self.edit_manifest("ios", tree="worktree")
        self.refused("not of the same tree")

    def test_a_manifest_without_a_tree_id_is_refused(self):
        for platform in l10n.PLATFORMS:
            self.edit_manifest(platform, treeId="")
        self.refused("not of the same tree")

    def test_a_run_with_fewer_files_than_swift_files_is_refused(self):
        self.edit_manifest("macos", swiftFiles=4)
        self.refused("wrote 3 .stringsdata files for 4 Swift files")

    def test_the_folders_of_one_app_alone_are_refused_by_the_command_line(self):
        with self.assertRaises(l10n.Refused) as refusal:
            l10n.cmd_sync(args_for("sync", self.catalog, mac_strings=self.runs["macos"]))
        self.assertEqual(refusal.exception.status, l10n.EXIT_USAGE)


class TypeCheckRunTests(TemporaryCase):
    """Running typecheck.py --emit-strings."""

    def done(self, code=0, out="", err=""):
        """A finished process, as subprocess.run returns it."""
        return SimpleNamespace(returncode=code, stdout=out, stderr=err)

    def test_the_command_asks_for_the_strings_of_one_platform_and_names_the_tree(self):
        seen = []

        def runner(command, **options):
            """Records the command; names a strings folder."""
            seen.append(command)
            return self.done(out=f"summary\n{l10n.STRINGS_FOLDER_LINE}/work/strings/{command[command.index('--platform') + 1]}\n")
        folder = l10n.run_type_check("ios", ["--worktree"], lambda _text: None, runner)
        self.assertEqual(folder, Path("/work/strings/ios"))
        command = seen[0]
        self.assertEqual(command[command.index("--platform") + 1], "ios")
        for flag in ("--emit-strings", "--worktree"):
            self.assertIn(flag, command)
        self.assertEqual(Path(command[3]).name, "typecheck.py")
        self.assertNotIn("run_locked.py", " ".join(command), "typecheck.py takes the lock itself")

    def test_a_failed_type_check_refuses_the_sync(self):
        runner = lambda command, **options: self.done(1, "# summary\n- Result: FAILED\n", "boom")  # noqa: E731
        with self.assertRaises(l10n.Refused) as refusal:
            l10n.run_type_check("macos", ["--ref", "HEAD"], lambda _text: None, runner)
        self.assertIn("did not succeed", str(refusal.exception))
        self.assertIn("FAILED", str(refusal.exception))

    def test_a_run_that_names_no_strings_folder_refuses_the_sync(self):
        with self.assertRaises(l10n.Refused):
            l10n.run_type_check("macos", ["--ref", "HEAD"], lambda _text: None, lambda command, **options: self.done(0, "all well\n"))

    def test_the_sync_runs_both_platforms_over_the_one_tree(self):
        seen = []

        def runner(command, **options):
            """Records the platform and the tree options; the folders are the fixtures'."""
            seen.append((command[command.index("--platform") + 1], command[command.index("--ref") + 1:command.index("--ref") + 2]))
            return self.done(out=f"{l10n.STRINGS_FOLDER_LINE}{FIXTURES / seen[-1][0]}\n")
        with mock.patch.object(l10n.subprocess, "run", runner), contextlib.redirect_stdout(io.StringIO()) as printed:
            cat = self.write_catalog({})
            with mock.patch.object(l10n, "sync_manifests", lambda *a, **k: 0):
                self.assertEqual(l10n.cmd_sync(args_for("sync", cat, ref="abc1234")), 0)
        self.assertEqual(seen, [("macos", ["abc1234"]), ("ios", ["abc1234"])])
        self.assertIn("type-checking the Mac app", printed.getvalue())


class StatusTests(TemporaryCase):
    """`status`: the counts of each language."""

    def catalog_file(self):
        """A catalog with one string in each state in Spanish, a missing one, and a stale one with a translation."""
        return self.write_catalog({
            "done": entry(es=unit("hecho")),
            "machine": entry(es=unit("máquina", "machine_translated")),
            "fresh": entry(es=unit("nuevo", "new")),
            "review": entry(es=unit("revisar", "needs_review")),
            "empty": entry(es=unit("", "translated")),
            "absent": entry(),
            "plural": entry(es=plural(one=unit("uno"), other=unit("otros", "needs_review"))),
            "old": {"extractionState": "stale", "localizations": {"es": unit("viejo")}},
        })

    def test_each_status_is_counted_once_and_stale_strings_apart(self):
        counts = l10n.language_counts(catalog.Catalog.load(self.catalog_file()), "es")
        self.assertEqual(counts, {"translated": 1, "machine_translated": 1, "new": 2, "needs_review": 2, "stale": 1, "missing": 1})

    def test_the_command_prints_a_line_for_each_language_and_the_english_bytes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), config=self.folder / "none.json"))
        lines = out.getvalue().splitlines()
        self.assertEqual(lines[0], "7 strings to translate, 1 stale. English text: 39 bytes of 150,000 (0%).")
        self.assertEqual(lines[1], "es: 1 translated, 1 machine translated, 2 new, 2 need review, 1 stale, 1 missing")

    def test_a_language_asked_for_that_the_catalog_lacks_is_all_missing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), lang="fr", config=self.folder / "none.json"))
        self.assertIn("fr: 0 translated, 0 machine translated, 0 new, 0 need review, 0 stale, 7 missing", out.getvalue())

    def test_the_shipped_languages_are_listed_though_the_catalog_has_none_of_them(self):
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["fr"]}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), config=config))
        self.assertIn("fr: 0 translated", out.getvalue())

    def test_json_output_has_the_same_numbers(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), json=True, config=self.folder / "none.json"))
        self.assertEqual(json.loads(out.getvalue())["languages"]["es"]["missing"], 1)


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class SizeTests(TemporaryCase):
    """`size`: the budget and the compiled files."""

    def run_size(self, path, config=None):
        """Runs `size` with its output folder in the temporary folder; returns what it printed."""
        out = io.StringIO()
        with mock.patch.object(l10n, "OUTPUT", self.folder / "build" / "l10n"), contextlib.redirect_stdout(out):
            l10n.cmd_size(args_for("size", path, config=config or self.folder / "none.json"))
        return out.getvalue()

    def test_an_empty_catalog_has_nothing_to_compile(self):
        printed = self.run_size(self.write_catalog({}))
        self.assertIn("English text: 0 bytes of 150,000 (0%); 150,000 under the budget.", printed)
        self.assertIn("nothing is compiled", printed)

    def test_each_language_is_compiled_in_both_formats_and_plurals_add_their_file(self):
        path = self.write_catalog({"Play": entry(es=unit("Reproducir")), "%lld books": entry(es=plural(
            one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("%lld libros")))})
        printed = self.run_size(path)
        self.assertRegex(printed, r"es: text [\d,]+ bytes, binary [\d,]+ bytes")
        text = (self.folder / "build/l10n/size/text/es.lproj")
        self.assertTrue((text / "Localizable.strings").exists())
        self.assertTrue((text / "Localizable.stringsdict").exists(), "a catalog with a plural also compiles a stringsdict")
        self.assertIn("catalog file", printed)

    def test_over_the_budget_is_said(self):
        path = self.write_catalog({"x" * 200: entry()})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"budgetBytes": 100}))
        self.assertIn("100 over the budget", self.run_size(path, config))


class CheckTests(TemporaryCase):
    """`check`: one test for each rule, with a catalog that breaks it."""

    CONFIG = {"languages": ["es"], "budgetBytes": 150000, "budgetFails": False}

    def problems(self, strings, **config):
        """The problems `check` finds in a catalog of `strings` under the configuration, with `config` changed."""
        problems, _note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, **config})
        return problems

    def good(self):
        """A catalog every rule passes."""
        return {"Play": entry(es=unit("Reproducir")),
                "%lld books": entry(es=plural(one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("%lld libros")))}

    def test_a_clean_catalog_has_no_problem(self):
        self.assertEqual(self.problems(self.good()), [])

    def test_the_empty_catalog_passes_with_no_language_shipped(self):
        self.assertEqual(self.problems({}, languages=[]), [])
        self.assertEqual(self.problems({}), [])

    def test_the_repositorys_catalog_and_configuration_pass(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(l10n.main(["check"]), 0)
        self.assertIn("0 problems", out.getvalue())

    def test_a_string_with_no_translation_in_a_shipped_language_is_a_problem(self):
        self.assertEqual(self.problems({"Play": entry()}), ['es "Play": missing translation'])

    def test_a_language_that_is_not_shipped_needs_no_translation(self):
        self.assertEqual(self.problems({"Play": entry()}, languages=[]), [])

    def test_an_unfinished_state_is_a_problem(self):
        for state in ("new", "needs_review", "stale"):
            self.assertEqual(self.problems({"Play": entry(es=unit("Reproducir", state))}),
                             [f'es "Play": not translated (state {state})'], state)

    def test_machine_translated_counts_as_done(self):
        self.assertEqual(self.problems({"Play": entry(es=unit("Reproducir", "machine_translated"))}), [])

    def test_an_empty_value_is_a_problem_whatever_its_state(self):
        for state in ("translated", "new"):
            self.assertIn('es "Play": empty value', self.problems({"Play": entry(es=unit("", state))}), state)

    def test_a_placeholder_the_translation_lacks_or_adds_or_changes_is_a_problem(self):
        problems = self.problems({"%lld of %@": entry(es=unit("%lld de")), "Hi %@": entry(es=unit("Hola %lld")),
                                  "Plain": entry(es=unit("Simple %@"))})
        self.assertEqual(len(problems), 3, problems)
        self.assertTrue(any("missing placeholder number 2 (object)" in p for p in problems), problems)
        self.assertTrue(any("extra placeholder number 1 (int64)" in p or "placeholder 1 is a int64" in p for p in problems), problems)

    def test_a_reordering_with_positions_is_fine_and_without_them_is_not(self):
        self.assertEqual(self.problems({"%@ has %lld": entry(es=unit("%2$lld tiene %1$@"))}), [])
        self.assertNotEqual(self.problems({"%@ has %lld": entry(es=unit("%lld tiene %@"))}), [])

    def test_placeholders_are_compared_plural_form_by_plural_form(self):
        # The `many` form forgets its number; the English is the key, which holds one.
        problems = self.problems({"%lld books": entry(es=plural(one=unit("%lld libro"), many=unit("de libros"), other=unit("%lld libros")))})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("(plural.many)", problems[0])
        self.assertIn("missing placeholder number 1", problems[0])

    def test_the_one_form_may_say_one_in_words_only_where_one_means_exactly_1(self):
        forms = {"%lld books": entry(es=plural(one=unit("un libro"), many=unit("%lld de libros"), other=unit("%lld libros")),
                                     fr=plural(one=unit("un livre"), many=unit("%lld de livres"), other=unit("%lld livres")))}
        self.assertEqual(self.problems(forms), [], "Spanish: one means 1")
        problems = self.problems(forms, languages=["fr"])
        self.assertEqual(len(problems), 1, "French: one covers 0, so the number stays")
        self.assertIn("(plural.one)", problems[0])

    def test_a_plural_form_the_english_has_is_the_one_compared(self):
        strings = {"%lld books": entry(en=plural(one=unit("%lld book"), other=unit("%lld books")),
                                       es=plural(one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("libros")))}
        problems = self.problems(strings)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("(plural.other)", problems[0])

    def test_a_plural_category_of_the_language_that_is_missing_is_a_problem(self):
        problems = self.problems({"%lld books": entry(es=plural(one=unit("%lld libro"), other=unit("%lld libros")))})
        self.assertEqual(problems, ['es "%lld books": plural form missing: many'])

    def test_each_languages_own_categories_are_required(self):
        one_other = {"%lld books": entry(ru=plural(one=unit("%lld книга"), other=unit("%lld книг")), ja=plural(other=unit("%lld 冊")))}
        problems = self.problems(one_other, languages=["ru", "ja"])
        self.assertEqual(problems, ['ru "%lld books": plural forms missing: few, many'])

    def test_a_translation_with_no_plural_where_the_english_has_one_is_a_problem(self):
        strings = {"%lld books": entry(en=plural(one=unit("%lld book"), other=unit("%lld books")), es=unit("%lld libros"))}
        self.assertEqual(self.problems(strings), ['es "%lld books": the English has plural forms and the translation has none'])

    def test_a_language_with_no_recorded_plural_rule_is_a_problem(self):
        problems = self.problems({"Play": entry(xx=unit("Play"))}, languages=["xx"])
        self.assertEqual(len(problems), 1)
        self.assertIn("no plural rule", problems[0])

    def test_a_substitution_the_translation_lacks_or_changes_is_a_problem(self):
        english = {**unit("%#@books@"), "substitutions": {"books": {"argNum": 1, "formatSpecifier": "lld",
                                                                  **plural(one=unit("%arg book"), other=unit("%arg books"))}}}
        good = {**unit("%#@books@"), "substitutions": {"books": {"argNum": 1, "formatSpecifier": "lld",
                                                                "variations": {"plural": {"one": unit("%arg libro"), "many": unit("%arg de libros"), "other": unit("%arg libros")}}}}}
        self.assertEqual(self.problems({"%lld books": entry(en=english, es=good)}), [])
        changed = json.loads(json.dumps(good))
        changed["substitutions"]["books"]["formatSpecifier"] = "@"
        self.assertIn("another argument or format", self.problems({"%lld books": entry(en=english, es=changed)})[0])
        missing = {**unit("%#@books@")}
        self.assertTrue(any("missing substitution books" in p for p in self.problems({"%lld books": entry(en=english, es=missing)})))

    def test_a_string_without_a_comment_is_a_problem(self):
        self.assertEqual(self.problems({"Play": {"localizations": {"es": unit("Reproducir")}}}), ['"Play": no comment for the translators'])
        self.assertEqual(self.problems({"Play": {"comment": "  ", "localizations": {"es": unit("Reproducir")}}}),
                         ['"Play": no comment for the translators'])

    def test_a_string_that_is_not_translated_needs_no_comment(self):
        self.assertEqual(self.problems({"Pop": {"shouldTranslate": False}}), [])

    def test_a_stale_string_is_a_problem(self):
        problems = self.problems({"Old": {"extractionState": "stale", "comment": "c", "localizations": {"es": unit("Viejo")}}})
        self.assertEqual(len(problems), 1)
        self.assertIn('"Old": stale', problems[0])

    def test_the_budget_only_reports_unless_the_configuration_makes_it_fail(self):
        strings = {"x" * 200: entry(es=unit("y"))}
        problems, note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, "budgetBytes": 100})
        self.assertEqual(problems, [])
        self.assertIn("100 over the budget (reported only", note)
        problems, _note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, "budgetBytes": 100, "budgetFails": True})
        self.assertEqual(len(problems), 1)
        self.assertIn("100 bytes over the 100-byte budget", problems[0])

    def test_a_key_whose_own_placeholders_cannot_be_read_is_a_problem(self):
        problems = self.problems({"%1$@ and %lld": entry(es=unit("%1$@ y %2$lld"))})
        self.assertTrue(any("cannot be read" in p for p in problems), problems)

    def test_long_keys_are_cut_in_the_lines(self):
        self.assertLessEqual(len(l10n.quote("k" * 500)), l10n.KEY_WIDTH + 1)
        self.assertEqual(l10n.quote("a\nb"), '"a\\nb"')


class CommandTests(TemporaryCase):
    """The command line: output, limits, exit statuses."""

    def run_main(self, *argv):
        """Runs main(); returns (status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = l10n.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def test_check_exits_1_with_the_problems_and_0_without(self):
        bad = self.write_catalog({"Play": entry()})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["es"]}))
        status, out, _err = self.run_main("check", "--catalog", str(bad), "--config", str(config))
        self.assertEqual(status, 1)
        self.assertIn('check: es "Play": missing translation', out)
        self.assertIn("check: 1 problem; shipped languages: es", out)
        status, out, _err = self.run_main("check", "--catalog", str(self.write_catalog({})), "--config", str(config))
        self.assertEqual(status, 0)

    def test_the_limit_cuts_the_list_and_says_how_many_are_left(self):
        many = self.write_catalog({f"k{n:02d}": entry() for n in range(5)})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["es"]}))
        _status, out, _err = self.run_main("check", "--catalog", str(many), "--config", str(config), "--limit", "2")
        self.assertEqual(out.count("missing translation"), 2)
        self.assertIn("and 3 more", out)
        _status, out, _err = self.run_main("check", "--catalog", str(many), "--config", str(config), "--limit", "0")
        self.assertEqual(out.count("missing translation"), 5)

    def test_a_bad_configuration_exits_2_and_says_which_file(self):
        config = self.folder / "config.json"
        for text in ('{"languages": "es"}', '{"budgetBytes": 0}', '{"budgetFails": "yes"}', '{"syncPaths": "TextMouth/**"}',
                     '{"syncPaths": [""]}', "not json"):
            config.write_text(text)
            status, _out, err = self.run_main("check", "--config", str(config))
            self.assertEqual(status, 2, text)
            self.assertIn(str(config), err)

    def test_a_missing_catalog_exits_2(self):
        status, _out, err = self.run_main("check", "--catalog", str(self.folder / "nothing.xcstrings"))
        self.assertEqual(status, 2)
        self.assertIn("cannot read the catalog", err)

    def test_a_command_line_that_names_nothing_exits_2_and_every_command_has_help(self):
        with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            l10n.main([])
        self.assertEqual(stopped.exception.code, 2)
        for command in ("sync", "status", "size", "check"):
            with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stdout(io.StringIO()) as printed:
                l10n.main([command, "--help"])
            self.assertEqual(stopped.exception.code, 0)
            self.assertIn(command, printed.getvalue())

    def test_the_repositorys_configuration_ships_no_language_and_reports_the_budget(self):
        config = l10n.load_config()
        self.assertEqual(config, {"languages": [], "budgetBytes": 150000, "budgetFails": False, "syncPaths": []})


if __name__ == "__main__":
    unittest.main()
