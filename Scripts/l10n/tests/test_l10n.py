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


# What `check` says of "Play" when it has no comment: it names the line that gives one.
NO_COMMENT_PLAY = '"Play": no comment for the translators (write a "// Translators: ..." line above its literal in the code, then sync)'
# The indentation of a note line in the generated sources: a note takes its literal's line's indentation, but the
# generated lines start at the literal's column, so the tests only need a margin.
NOTE_INDENT = "    "


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
        # The checkout whose TextMouth/Localization/ the sync lists is a made-up one, never the repository's own.
        self.checkout = self.folder / "checkout"
        patch = mock.patch.object(l10n, "ROOT", self.checkout)
        patch.start()
        self.addCleanup(patch.stop)
        self.locations = self.folder / "out" / "locations.json"
        self.lines = []
        self.config = self.folder / "sync-config.json"
        self.set_sync_paths("TextMouth/**")
        # The recorded runs name made-up folders for the compiler's copy of the sources; point each at a folder of this test,
        # where `write_sources` writes the sources the entries describe (the sync reads the translators' notes from them).
        self.source_roots = {}
        for platform in l10n.PLATFORMS:
            self.relocate_sources(platform)

    def relocate_sources(self, platform):
        """Makes the run of `platform` say its sources are under a folder of this test's own, in its manifest and in each
        .stringsdata file's `source` path."""
        manifest_path = self.runs[platform] / l10n.STRINGS_MANIFEST
        manifest = json.loads(manifest_path.read_text())
        old_root = manifest["sourceRoot"]
        self.source_roots[platform] = self.folder / "src" / platform
        manifest["sourceRoot"] = str(self.source_roots[platform])
        manifest_path.write_text(json.dumps(manifest))
        for name in manifest["files"]:
            path = self.runs[platform] / name
            data = json.loads(path.read_text())
            data["source"] = data["source"].replace(old_root, str(self.source_roots[platform]))
            path.write_text(json.dumps(data))

    def write_sources(self, notes=None):
        """Writes, for each run, the source file of each .stringsdata file: empty lines, with a quote at the byte column of
        each entry's line (the opening quote of its literal), and, for each (repository path, line) of `notes`, the line
        above that line made `// Translators: <text>`. Files that `notes` or the entries do not need are not written."""
        notes = notes or {}
        self.custom_sources = getattr(self, "custom_sources", {})
        for platform in l10n.PLATFORMS:
            for name in l10n.read_manifest(self.runs[platform])["files"]:
                data = json.loads((self.runs[platform] / name).read_text())
                relative = l10n.relative_source(data, self.source_roots[platform])
                lines = {}
                for entries in data["tables"].values():
                    for found in entries:
                        where = found["location"]
                        lines[where["startingLine"]] = " " * (where["startingColumn"] - 1) + '"' + found["key"] + '"'
                for (path, line), text in notes.items():
                    if path == relative:
                        lines[line - 1] = f"{NOTE_INDENT}{l10n.NOTE_MARKER} {text}"
                if not lines:
                    continue
                target = self.source_roots[platform] / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                # A test may give a file's whole text (`custom_sources`, by repository path) when it needs a layout of its own.
                text = self.custom_sources.get(relative) or "\n".join(lines.get(number, "") for number in range(1, max(lines) + 1)) + "\n"
                target.write_text(text, encoding="utf-8")

    def set_sync_paths(self, *globs):
        """Writes the sync's configuration (without `syncPaths`, which the file beside it holds) and that file with these
        globs, one per line."""
        self.config.write_text("{}")
        (self.folder / l10n.SYNC_PATHS_FILE).write_text("".join(glob + "\n" for glob in globs))

    def manifests(self):
        """The two runs' manifests, as the sync reads them."""
        return [l10n.read_manifest(self.runs[platform]) for platform in l10n.PLATFORMS]

    def sync(self, notes=None):
        """Runs the sync on the copies, with the sources written (see write_sources); returns its exit status (its lines are
        in `self.lines`)."""
        self.write_sources(notes)
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
        self.write_sources()
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


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class NoteTests(SyncCase):
    """The translators' notes written in the code as `// Translators:` lines (TL15): `sync` reads each, from the line
    directly above the key's literal, and writes it into the catalog as the key's comment."""

    VIEW = "TextMouth/Views/LibraryView.swift"       # holds "Play" at line 12 and "%lld books" at line 31
    MAC = "TextMouth/Platform/macOS/MacOnly.swift"   # holds "Reveal in Finder" at line 8

    def setUp(self):
        super().setUp()
        # The recorded entries carry the compiler's `comment:`, the old form: these tests start from the new form.
        for platform in l10n.PLATFORMS:
            for name in l10n.read_manifest(self.runs[platform])["files"]:
                self.rewrite_entries(platform, name, lambda entry: entry.pop("comment", None))

    def rewrite_entries(self, platform, name, change):
        """Applies `change(entry)` to each entry of a .stringsdata file of a run, and saves the file."""
        path = self.runs[platform] / name
        data = json.loads(path.read_text())
        for entries in data["tables"].values():
            for found in entries:
                change(found)
        path.write_text(json.dumps(data))

    def add_site(self, platform, name, key, line, column=5, comment=None):
        """Adds another place (an entry) for `key` to a .stringsdata file of a run."""
        path = self.runs[platform] / name
        data = json.loads(path.read_text())
        found = {"key": key, "location": {"startingColumn": column, "startingLine": line}}
        if comment is not None:
            found["comment"] = comment
        data["tables"].setdefault("Localizable", []).append(found)
        path.write_text(json.dumps(data))

    def comment_of(self, key):
        """The comment the catalog holds for `key` after the sync."""
        return catalog.Catalog.load(self.catalog).strings[key].get("comment")

    def test_a_note_above_the_literal_becomes_the_keys_comment(self):
        self.sync({(self.VIEW, 12): "The button that plays the book"})
        self.assertEqual(self.comment_of("Play"), "The button that plays the book")
        self.assertIn("comments written from the code's \"// Translators:\" lines", "\n".join(self.lines))

    def test_a_key_with_no_note_and_no_catalog_comment_gets_none(self):
        self.sync({(self.VIEW, 12): "The button that plays the book"})
        self.assertIsNone(self.comment_of("%lld books"))
        self.assertIn('"%lld books": no comment for the translators', "\n".join(
            l10n.check_catalog(catalog.Catalog.load(self.catalog), {"languages": [], "budgetBytes": 10**6, "budgetFails": False})[0]))

    def test_a_key_with_no_note_at_any_site_keeps_the_comment_the_catalog_has(self):
        self.write_catalog({"Play": entry("Kept for the translators")})
        self.sync()
        self.assertEqual(self.comment_of("Play"), "Kept for the translators")

    def test_a_note_replaces_the_comment_the_catalog_has(self):
        self.write_catalog({"Play": entry("Old comment")})
        self.sync({(self.VIEW, 12): "New note"})
        self.assertEqual(self.comment_of("Play"), "New note")

    def test_sites_with_the_same_note_give_it_once(self):
        self.add_site("macos", "MacOnly.stringsdata", "Play", 30)
        self.sync({(self.VIEW, 12): "The play button", (self.MAC, 30): "The play button"})
        self.assertEqual(self.comment_of("Play"), "The play button")

    def test_sites_with_different_notes_give_them_in_code_point_order_one_to_a_line(self):
        self.add_site("macos", "MacOnly.stringsdata", "Play", 30)
        self.add_site("ios", "PhoneOnly.stringsdata", "Play", 40)
        self.sync({(self.VIEW, 12): "b: the button", (self.MAC, 30): "a: the menu item",
                   ("TextMouth/Platform/iOS/PhoneOnly.swift", 40): "B: the phone's button"})
        self.assertEqual(self.comment_of("Play"), "B: the phone's button\na: the menu item\nb: the button",
                         "capitals sort before lowercase letters, as `xcstringstool sync` sorts")

    def test_a_site_without_a_note_adds_nothing_beside_the_sites_that_have_one(self):
        self.add_site("macos", "MacOnly.stringsdata", "Play", 30)
        self.sync({(self.VIEW, 12): "The play button"})
        self.assertEqual(self.comment_of("Play"), "The play button")

    def test_the_note_is_above_the_literals_line_not_the_calls_first_line(self):
        # The call starts on line 10 and its literal is on line 12: the note sits directly above line 12.
        self.custom_sources = {self.VIEW: "\n".join([
            "", "", "", "", "", "", "", "", "",
            "        return String(",                               # line 10
            "            // Translators: Plays the book",           # line 11
            '            localized: "Play")',                       # line 12
            "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
            '                   "%lld books"',                       # line 31
        ]) + "\n"}
        self.edit_columns("Play", 24)
        self.edit_columns("%lld books", 20)
        self.sync()
        self.assertEqual(self.comment_of("Play"), "Plays the book")
        self.assertIsNone(self.comment_of("%lld books"))

    def edit_columns(self, key, column):
        """Sets the column of every entry of `key` in both runs."""
        for platform in l10n.PLATFORMS:
            for name in l10n.read_manifest(self.runs[platform])["files"]:
                self.rewrite_entries(platform, name, lambda found: found["location"].update(startingColumn=column) if found["key"] == key else None)

    def test_a_note_keeps_its_quotes_backslashes_and_accents_as_written(self):
        note = 'Says "Undo" before a \\ path: la acción, 3 × 4 \u2026 %1$@ and %2$lld'
        self.sync({(self.VIEW, 12): note})
        self.assertEqual(self.comment_of("Play"), note)

    def test_the_column_counts_utf8_bytes_so_a_literal_after_accents_is_found(self):
        # "é…" is two characters and five bytes, so the literal's quote is at a byte column that is three past its character column.
        lines = [""] * 11 + ["// Translators: After accents", 'let é… = String(localized: "Play")']
        self.custom_sources = {self.VIEW: "\n".join(lines) + "\n"}
        self.edit_columns("Play", len('let é… = String(localized: '.encode("utf-8")) + 1)
        for platform in l10n.PLATFORMS:
            for name in l10n.read_manifest(self.runs[platform])["files"]:
                self.rewrite_entries(platform, name, lambda found: found["location"].update(startingLine=13) if found["key"] == "Play" else None)
        self.sync()
        self.assertEqual(self.comment_of("Play"), "After accents")

    def test_a_source_that_is_not_the_one_the_compiler_read_gives_a_problem_and_no_note(self):
        # The literal's quote is not at the entry's column: another run wrote the copy since.
        self.custom_sources = {self.VIEW: "\n".join(["// Translators: Wrong"] * 40) + "\n"}
        status = self.sync()
        self.assertEqual(status, l10n.EXIT_PROBLEMS)
        self.assertIn("does not match the compiler's place", "\n".join(self.lines))
        self.assertIsNone(self.comment_of("Play"))

    def test_a_source_that_cannot_be_read_gives_a_problem_and_the_catalogs_comment_stays(self):
        self.write_catalog({"Play": entry("Kept")})
        self.write_sources()
        shutil.rmtree(self.source_roots["macos"] / "TextMouth" / "Views")
        shutil.rmtree(self.source_roots["ios"] / "TextMouth" / "Views")
        args = args_for("sync", self.catalog, verbose=False, config=self.config)
        status = l10n.sync_manifests(args, self.manifests(), self.lines.append, self.locations)
        self.assertEqual(status, l10n.EXIT_PROBLEMS)
        self.assertIn("cannot be read", "\n".join(self.lines))
        self.assertEqual(self.comment_of("Play"), "Kept")

    def test_a_wrong_copy_of_the_sources_prints_a_few_sentences_and_the_count_of_the_rest(self):
        # 40 more entries, each with no quote at its column, besides the file's own two: the sync says 20 and counts the other 22.
        for number in range(40):
            self.add_site("macos", "MacOnly.stringsdata", f"Key {number}", 100 + number, column=3)
        self.custom_sources = {self.MAC: "\n".join(["no quotes here"] * 150) + "\n"}
        self.assertEqual(self.sync(), l10n.EXIT_PROBLEMS)
        said = [line for line in self.lines if line.startswith("notes:")]
        self.assertEqual(len(said), l10n.NOTE_PROBLEMS_SHOWN + 1)
        self.assertIn("and 22 more", said[-1])

    def test_the_old_form_comment_of_the_compiler_still_gives_the_comment(self):
        self.rewrite_entries("macos", "LibraryView.stringsdata", lambda found: found.update(comment="From comment:"))
        self.rewrite_entries("ios", "LibraryView.stringsdata", lambda found: found.update(comment="From comment:"))
        self.sync()
        self.assertEqual(self.comment_of("Play"), "From comment:")

    def test_both_forms_in_one_tree_give_both_notes(self):
        self.add_site("macos", "MacOnly.stringsdata", "Play", 30, comment="From comment:")
        self.sync({(self.VIEW, 12): "From the line"})
        self.assertEqual(self.comment_of("Play"), "From comment:\nFrom the line")

    def test_two_keys_on_one_line_get_no_note_and_a_problem(self):
        # "Play" and "Share" both have their literal on line 12 of one file: one note cannot be for both.
        self.add_site("macos", "LibraryView.stringsdata", "Share", 12, column=40)
        status = self.sync({(self.VIEW, 12): "For one of them"})
        self.assertEqual(status, l10n.EXIT_PROBLEMS)
        self.assertIn("more than one key are on this line", "\n".join(self.lines))
        self.assertIsNone(self.comment_of("Play"))

    def test_a_second_sync_changes_nothing(self):
        self.sync({(self.VIEW, 12): "The play button"})
        first = catalog.read_text(self.catalog)
        self.sync({(self.VIEW, 12): "The play button"})
        self.assertEqual(catalog.read_text(self.catalog), first)

    def test_a_marker_with_no_text_gives_no_note_and_only_the_line_directly_above_counts(self):
        lines = ["", "", "", "// Translators:", "// Translators: Too far above", "", 'let a = "Play"']
        self.assertIsNone(l10n.note_above(lines, 7), "the line above is empty")
        self.assertIsNone(l10n.note_above(lines, 5), "a marker with no text")
        self.assertEqual(l10n.note_above(lines, 6), "Too far above")
        self.assertEqual(l10n.note_above(["    //   Translators:  spaced   ", "x"], 2), None, "the marker is written once, in one form")
        self.assertEqual(l10n.note_above(["        // Translators:  spaced   ", "x"], 2), "spaced", "indentation and spaces are not the note")
        self.assertIsNone(l10n.note_above(["let x = 1 // Translators: not a line of its own", "y"], 2))
        self.assertIsNone(l10n.note_above(["// Translators: first line"], 1), "nothing is above line 1")


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


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class EveryCatalogTests(SyncCase):
    """The sync reaches every catalog in the checkout's TextMouth/Localization/, not only the tables the code still uses
    (the review of l10n/core, finding 8)."""

    def put_catalog(self, table, strings):
        """Writes a catalog of `table` in the made-up checkout's Localization folder; returns its path."""
        folder = self.checkout / l10n.CATALOG_FOLDER
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{table}.xcstrings"
        make_catalog(strings).save(path)
        return path

    def test_the_strings_of_a_table_that_left_the_code_go_stale(self):
        """No file of the runs has the table `Other` any more: its strings are marked, where before nothing was."""
        other = self.put_catalog("Other", {"Gone": entry("A string no code uses", es=unit("Se fue"))})
        self.sync()
        cat = catalog.Catalog.load(other)
        self.assertTrue(cat.is_stale(cat.strings["Gone"]))
        self.assertIn("Other: 0 added, 1 became stale", "\n".join(self.lines))

    def test_a_table_the_code_still_uses_is_synced_once(self):
        menus = self.put_catalog("Menus", {})
        self.sync()
        self.assertEqual(sorted(catalog.Catalog.load(menus).strings), ["Shortcut"])
        self.assertEqual(sum(1 for line in self.lines if line.startswith("Menus: 1 added")), 1)

    def test_a_folder_catalog_of_the_main_tables_name_is_not_synced_in_place_of_the_one_named_on_the_command_line(self):
        folder_one = self.put_catalog(l10n.TABLE, {"Left alone": entry("Not the catalog the command line named")})
        self.sync()
        self.assertEqual(sorted(catalog.Catalog.load(folder_one).strings), ["Left alone"])
        self.assertIn("Play", catalog.Catalog.load(self.catalog).strings)


class HelpTests(unittest.TestCase):
    """`--help` of the tool and of each command prints and exits 0 (a `%O` in a help text once crashed it)."""

    def exits_with(self, argv):
        """The exit status of parsing `argv`, and what it printed."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            l10n.build_parser().parse_args(argv)
        return raised.exception.code, out.getvalue()

    def test_the_tools_help_exits_0_and_names_the_merge_drivers_arguments(self):
        status, text = self.exits_with(["--help"])
        self.assertEqual(status, 0)
        # The merge driver's placeholders are shown literally, as git writes them.
        self.assertIn("%O %A %B %P", text)

    def test_every_commands_help_exits_0(self):
        # Every command the parser has, so a command added later is covered without a change here.
        subparsers = next(action for action in l10n.build_parser()._actions if getattr(action, "choices", None))
        for command in subparsers.choices:
            with self.subTest(command=command):
                self.assertEqual(self.exits_with([command, "--help"])[0], 0)


class RefusalTests(SyncCase):
    """A sync that must not run: nothing is changed."""

    def test_a_catalog_whose_file_is_not_named_for_its_table_is_refused_with_a_sentence(self):
        """xcstringstool writes nothing to such a file and exits 0, which the sync would print as `0 added` (finding 5)."""
        self.catalog = self.write_catalog({}, "Foo.xcstrings")
        self.refused("named 'Foo' but holds the table 'Localizable'")

    def test_a_misnamed_catalog_is_refused_before_any_catalog_is_written(self):
        """Alpha sorts before Localizable: without the check up front it would be synced (and its string marked) first."""
        folder = self.checkout / l10n.CATALOG_FOLDER
        folder.mkdir(parents=True)
        alpha = folder / "Alpha.xcstrings"
        make_catalog({"Gone": entry("c", es=unit("Se fue"))}).save(alpha)
        self.catalog = self.write_catalog({}, "Foo.xcstrings")
        self.refused("named 'Foo'")
        self.assertFalse(catalog.Catalog.load(alpha).is_stale(catalog.Catalog.load(alpha).strings["Gone"]),
                         "a catalog was written before the refusal")

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

    def test_the_type_check_runs_in_the_tools_own_checkout_whatever_folder_the_sync_started_in(self):
        """typecheck.py takes the repository from its working folder: another checkout's strings must not reach this catalog."""
        seen = []

        def runner(command, **options):
            """Records where the command runs."""
            seen.append(options.get("cwd"))
            return self.done(out=f"{l10n.STRINGS_FOLDER_LINE}/work/strings/macos\n")
        l10n.run_type_check("macos", ["--worktree"], lambda _text: None, runner)
        self.assertEqual(seen, [l10n.ROOT])

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

    def broken(self, entry_value, sentence, key="Play"):
        """The catalog with `entry_value` for a string `key` and a good one beside it: `check` gives exactly one problem, which
        names the key and says `sentence`, and the good string is still checked (and passes)."""
        problems = self.problems({"Open": entry(es=unit("Abrir")), key: entry_value})
        self.assertEqual(problems, [f'{l10n.quote(key)}: {sentence}'], entry_value)

    def test_a_value_that_is_not_text_is_a_problem_and_not_a_crash_or_a_pass(self):
        """The review's finding 7: `"value": 5` and `"value": null` ended in an AttributeError traceback."""
        for value, kind in ((5, "a number"), (None, "null"), (["x"], "a list"), (True, "true or false")):
            self.broken({"comment": "c", "localizations": {"es": {"stringUnit": {"state": "translated", "value": value}}}},
                        f"es value is {kind}, not text")

    def test_a_state_that_is_not_text_is_a_problem(self):
        self.broken({"comment": "c", "localizations": {"es": {"stringUnit": {"state": 3, "value": "Reproducir"}}}},
                    "es state is a number, not text")

    def test_a_comment_that_is_not_text_is_a_problem_and_not_a_pass(self):
        """`"comment": null` and `"comment": 5` passed the comment rule, since `str(None)` is "None"."""
        for value, kind in ((None, "null"), (5, "a number"), (["a"], "a list")):
            self.broken({"comment": value, "localizations": {"es": unit("Reproducir")}}, f"the comment is {kind}, not text")

    def test_localizations_that_are_not_an_object_are_a_problem(self):
        for value, kind in ((None, "null"), (5, "a number"), ([], "a list")):
            self.broken({"comment": "c", "localizations": value}, f"localizations is {kind}, not an object")

    def test_a_localization_that_is_not_an_object_is_a_problem(self):
        self.broken({"comment": "c", "localizations": {"es": None}}, "es is null, not an object")

    def test_an_entry_that_is_not_an_object_is_a_problem(self):
        for value, kind in ((None, "null"), (7, "a number"), ("text", "text")):
            self.broken(value, f"the entry is {kind}, not an object")

    def test_a_string_unit_variations_and_substitutions_that_are_not_of_their_type_are_found_where_they_are(self):
        self.broken({"comment": "c", "localizations": {"es": {"stringUnit": ["x"]}}}, "es stringUnit is a list, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": None}}}, "es variations is null, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": {"plural": 5}}}},
                    "es plural variations are a number, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": {"plural": {"one": {"stringUnit": {"value": None}}}}}}},
                    "es plural.one value is null, not text")
        self.broken({"comment": "c", "localizations": {"es": {"substitutions": {"n": 3}}}}, "es substitution n is a number, not an object")

    def test_every_broken_part_of_a_string_is_listed_and_the_other_checks_go_on_without_it(self):
        problems = self.problems({"Open": entry(), "Play": {"comment": None, "localizations": {"es": {"stringUnit": {"value": 5}}}}})
        self.assertEqual(problems, ['"Play": the comment is null, not text', '"Play": es value is a number, not text',
                                    'es "Open": missing translation'])

    def test_a_broken_catalog_makes_the_command_exit_with_problems_and_no_traceback(self):
        """What the review ran: the command ended in a traceback, whose exit status 1 looks like a check that found problems."""
        path = self.write_catalog({"Play": {"comment": "c", "localizations": {"es": {"stringUnit": {"state": "translated", "value": 5}}}},
                                   "Open": {"comment": None}})
        config = self.folder / "config.json"
        config.write_text(json.dumps(self.CONFIG))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = l10n.main(["check", "--catalog", str(path), "--config", str(config)])
        self.assertEqual(status, 1, err.getvalue())
        self.assertEqual(err.getvalue(), "")
        self.assertIn('check: "Play": es value is a number, not text', out.getvalue())
        self.assertIn('check: "Open": the comment is null, not text', out.getvalue())
        self.assertIn("check: 2 problems", out.getvalue())

    def test_a_file_that_is_not_a_catalog_is_refused_with_a_sentence(self):
        for text in ("[]", "5", "null", '{"strings": []}'):
            path = self.folder / "Bad.xcstrings"
            path.write_text(text, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = l10n.main(["check", "--catalog", str(path)])
            self.assertEqual(status, l10n.EXIT_USAGE, text)
            self.assertIn("cannot read the catalog", err.getvalue())

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
        self.assertEqual(self.problems({"Play": {"localizations": {"es": unit("Reproducir")}}}), [NO_COMMENT_PLAY])
        self.assertEqual(self.problems({"Play": {"comment": "  ", "localizations": {"es": unit("Reproducir")}}}), [NO_COMMENT_PLAY])
        self.assertIn("// Translators:", NO_COMMENT_PLAY, "the problem says how to fix it")

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
        for text in ('{"languages": "es"}', '{"budgetBytes": 0}', '{"budgetFails": "yes"}', "not json"):
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
        """Only what must hold is pinned: no language ships until the orchestrator ships one (change `languages` here then),
        the budget, and that it only reports. `syncPaths` grows with every branch that converts files, so it is checked for its
        type and not its value (l10npilot's finding, #6564). Its globs are read from sync-paths.txt, each of which must match
        a file of this checkout."""
        config = l10n.load_config(root=l10n.ROOT)
        self.assertEqual(config["languages"], [])
        self.assertEqual(config["budgetBytes"], 150000)
        self.assertIs(config["budgetFails"], False)
        self.assertIsInstance(config["syncPaths"], list)
        self.assertTrue(all(isinstance(glob, str) for glob in config["syncPaths"]), config["syncPaths"])


if __name__ == "__main__":
    unittest.main()
