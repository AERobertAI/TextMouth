"""Tests of `compact_packs.py`: the build step that ships each language's files compact (TL16).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests
(and again with /usr/bin/python3, the interpreter the Xcode build phase uses).

Every test works on made-up language folders in a temporary folder. The step reads
its own output back with Apple's `plutil`, so these tests run on a Mac only.
"""
import contextlib
import io
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import compact_packs  # noqa: E402  (imported by path, after sys.path is set)

# The plural categories of a Spanish count, as a compiled catalog writes them.
PLURAL_FORMS = {"zero": "ningún libro", "one": "%d libro", "many": "%d de libros", "other": "%d libros"}


def plural_entry(forms=None, variable="count"):
    """One `.stringsdict` entry the way Xcode compiles a plural string: the format, then the variable's rules."""
    return {
        "NSStringLocalizedFormatKey": f"%#@{variable}@",
        variable: {
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "d",
            **(forms or PLURAL_FORMS),
        },
    }


class PackCase(unittest.TestCase):
    """A resources folder in a temporary folder, with helpers to fill it and read it back."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def folder(self, name="Resources"):
        """A resources folder named `name` under the temporary root."""
        path = self.root / name
        path.mkdir(exist_ok=True)
        return path

    def write_xml(self, resources, language, kind, table):
        """Write `table` as the XML property list Xcode writes, at `<language>.lproj/Localizable.<kind>`."""
        lproj = resources / f"{language}.lproj"
        lproj.mkdir(exist_ok=True)
        path = lproj / f"Localizable.{kind}"
        path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_XML))
        return path

    def run_main(self, *args):
        """Run the command line; returns (exit status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = compact_packs.main([str(a) for a in args])
        return status, out.getvalue(), err.getvalue()


class StringsFormTests(PackCase):
    """The `.strings` text form: exact bytes, every character Apple's parser must read back unchanged."""

    def test_exact_bytes_sorted_utf8_without_whitespace(self):
        """Keys in code-point order, `"k"="v";`, nothing between entries, accents as UTF-8."""
        table = {"b": 'say "hi"', "a": "one\ntwo", "é": "café", "C": "back\\slash"}
        path = self.write_xml(self.folder(), "es", "strings", table)
        self.assertEqual(compact_packs.compact_folder(path.parent.parent), (1, []))
        # Code-point order: "C" (0x43) before "a" (0x61), "b", and "é" (0xE9).
        want = '"C"="back\\\\slash";"a"="one\\ntwo";"b"="say \\"hi\\"";"é"="café";'
        self.assertEqual(path.read_bytes(), want.encode("utf-8"))

    def test_placeholders_empty_value_tab_and_emoji_survive(self):
        """`%@`, `%1$@`, `%%`, an empty value, a tab, and a character outside the BMP read back exactly."""
        table = {
            "Open %@": "Abrir %@",
            "%1$@ of %2$@": "%2$@ de %1$@",
            "100%% done": "100%% hecho",
            "empty": "",
            "tab\there": "tab\taqui",
            "Party \U0001F389": "Fiesta \U0001F389 \U0001D11E",
        }
        path = self.write_xml(self.folder(), "es", "strings", table)
        self.assertEqual(compact_packs.compact_folder(path.parent.parent)[1], [])
        self.assertEqual(compact_packs.apple_parse(path.read_bytes()), table)
        # A tab is escaped, so the file holds no raw control character.
        self.assertNotIn(b"\t", path.read_bytes())
        self.assertIn("\U0001F389".encode("utf-8"), path.read_bytes())

    def test_every_control_character_reads_back_exactly(self):
        """The C0 range, DEL, and the C1 range, in keys and values, through Apple's own parser."""
        controls = [*range(0x00, 0x20), 0x7F, *range(0x80, 0xA0)]
        table = {f"k{code:02X}-" + chr(code): "a" + chr(code) + "beefz" for code in controls}
        # NUL cannot be in a property list's text, and an XML list cannot hold the others, so the
        # table goes through the renderer and Apple's parser directly.
        table.pop("k00-" + chr(0))
        data = compact_packs.render_strings(table)
        self.assertEqual(compact_packs.apple_parse(data), table)
        # Nothing in the file but printable text: every control character was escaped.
        self.assertFalse([b for b in data if b < 0x20 or b == 0x7F])

    def test_an_old_style_file_with_control_characters_is_compacted(self):
        """A text-form original that plistlib cannot read (a control character) is read by Apple's parser."""
        folder = self.folder()
        lproj = folder / "es.lproj"
        lproj.mkdir()
        path = lproj / "Localizable.strings"
        path.write_bytes(b'/* a comment */\n"k" = "a\\U001bz";\n"j" = "b";\n')
        self.assertEqual(compact_packs.compact_folder(folder), (1, []))
        self.assertEqual(path.read_bytes(), b'"j"="b";"k"="a\\U001Bz";')
        self.assertEqual(compact_packs.apple_parse(path.read_bytes()), {"k": "a\x1bz", "j": "b"})


class StringsdictFormTests(PackCase):
    """The `.stringsdict`: a binary property list holding the same plural rules."""

    def test_plurals_with_zero_one_many_other_become_binary(self):
        """Every category survives, and the file is binary."""
        table = {"%lld books": plural_entry()}
        path = self.write_xml(self.folder(), "es", "stringsdict", table)
        self.assertEqual(compact_packs.compact_folder(path.parent.parent), (1, []))
        data = path.read_bytes()
        self.assertTrue(data.startswith(b"bplist00"))
        self.assertEqual(plistlib.loads(data), table)
        self.assertEqual(compact_packs.apple_parse(data), table)

    def test_an_entry_with_two_plural_variables(self):
        """One format that holds two plural variables keeps both rule sets."""
        entry = plural_entry(variable="books")
        entry["NSStringLocalizedFormatKey"] = "%#@books@ in %#@shelves@"
        entry["shelves"] = {
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "d",
            "one": "%d estante",
            "other": "%d estantes",
        }
        table = {"%lld books on %lld shelves": entry, "%lld minutes": plural_entry()}
        path = self.write_xml(self.folder(), "es", "stringsdict", table)
        self.assertEqual(compact_packs.compact_folder(path.parent.parent)[1], [])
        self.assertEqual(plistlib.loads(path.read_bytes()), table)

    def test_binary_is_smaller_than_the_xml_for_plurals(self):
        """The reason for the binary form."""
        table = {f"%lld thing {n}": plural_entry() for n in range(20)}
        path = self.write_xml(self.folder(), "en", "stringsdict", table)
        before = path.stat().st_size
        compact_packs.compact_folder(path.parent.parent)
        self.assertLess(path.stat().st_size, before // 2)


class RepeatabilityTests(PackCase):
    """The same input gives the same bytes, and a compact file is left alone."""

    def table(self):
        return {"b": "B é", "a": 'A "q"', "c": "C\nline"}

    def test_running_twice_changes_nothing_the_second_time(self):
        """The second run changes no file and does not even touch its modification time."""
        resources = self.folder()
        strings = self.write_xml(resources, "es", "strings", self.table())
        plurals = self.write_xml(resources, "es", "stringsdict", {"%lld books": plural_entry()})
        self.assertEqual(compact_packs.compact_folder(resources), (2, []))
        first = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (strings, plurals)}
        self.assertEqual(compact_packs.compact_folder(resources), (0, []))
        self.assertEqual({p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (strings, plurals)}, first)

    def test_same_content_in_any_order_gives_the_same_bytes(self):
        """Two builds of one catalog are byte for byte equal, whatever order the dictionary came in."""
        forward = self.table()
        backward = dict(reversed(list(forward.items())))
        outputs = []
        for name, table in (("one", forward), ("two", backward)):
            resources = self.folder(name)
            strings = self.write_xml(resources, "es", "strings", table)
            plurals = self.write_xml(resources, "es", "stringsdict", {"%lld a": plural_entry(), "%lld b": plural_entry()})
            compact_packs.compact_folder(resources)
            outputs.append((strings.read_bytes(), plurals.read_bytes()))
        self.assertEqual(outputs[0], outputs[1])

    def test_the_command_line_says_what_it_did(self):
        """Exit 0 and a line counting the files, then the same on the second run."""
        resources = self.folder()
        self.write_xml(resources, "es", "strings", self.table())
        status, out, err = self.run_main(resources)
        self.assertEqual((status, err), (0, ""))
        self.assertIn("1 language file(s) compacted, 0 already compact", out)
        status, out, _ = self.run_main(resources)
        self.assertEqual(status, 0)
        self.assertIn("0 language file(s) compacted, 1 already compact", out)

    def test_an_empty_table_is_left_alone(self):
        """Apple's parser reads no empty text form, and an empty table has nothing to save."""
        resources = self.folder()
        path = self.write_xml(resources, "fr", "strings", {})
        before = path.read_bytes()
        self.assertEqual(compact_packs.compact_folder(resources), (0, []))
        self.assertEqual(path.read_bytes(), before)


class SafetyTests(PackCase):
    """A change that Apple's parser would read differently stops the build and leaves the file as it was."""

    def test_a_failing_self_check_leaves_the_file_and_names_the_key(self):
        """A parser that reads one value differently: exit 1, the file named with the first differing key, bytes unchanged."""
        resources = self.folder()
        path = self.write_xml(resources, "es", "strings", {"alpha": "uno", "beta": "dos", "gamma": "tres"})
        before = path.read_bytes()

        def wrong_parse(_data):
            return {"alpha": "uno", "beta": "DOS", "gamma": "tres"}

        with mock.patch.object(compact_packs, "apple_parse", wrong_parse):
            status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("es.lproj/Localizable.strings", err)
        self.assertIn("beta", err)
        self.assertNotIn("alpha:", err)
        self.assertEqual(path.read_bytes(), before)

    def test_a_missing_key_is_a_difference_too(self):
        """A key that the check does not read back fails it, in a plural table as well."""
        resources = self.folder()
        path = self.write_xml(resources, "es", "stringsdict", {"%lld books": plural_entry()})
        before = path.read_bytes()
        with mock.patch.object(compact_packs, "apple_parse", lambda _data: {}):
            status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("%lld books", err)
        self.assertEqual(path.read_bytes(), before)

    def test_a_parser_that_refuses_the_bytes_fails_the_build(self):
        """An error from Apple's parser is a failure, not a pass."""
        resources = self.folder()
        path = self.write_xml(resources, "es", "strings", {"a": "b"})
        before = path.read_bytes()
        with mock.patch.object(compact_packs, "PLUTIL", "/usr/bin/false"):
            status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("refuses", err)
        self.assertEqual(path.read_bytes(), before)

    def test_a_value_that_is_not_text_is_refused(self):
        """A `.strings` entry that is a number is not a plain table: nothing is written."""
        resources = self.folder()
        path = self.write_xml(resources, "es", "strings", {"a": 5})
        before = path.read_bytes()
        status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("not a string pair", err)
        self.assertEqual(path.read_bytes(), before)

    def test_one_bad_file_does_not_stop_the_others(self):
        """Every file is tried, the bad one is named, the good one is compacted, and the exit is 1."""
        resources = self.folder()
        bad = self.write_xml(resources, "de", "strings", {"a": 5})
        good = self.write_xml(resources, "es", "strings", {"a": "b"})
        status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("de.lproj", err)
        self.assertEqual(good.read_bytes(), b'"a"="b";')
        self.assertTrue(bad.read_bytes().startswith(b"<?xml"))

    def test_garbage_is_an_error_not_a_crash(self):
        """A file Apple's parser cannot read is named, and left."""
        resources = self.folder()
        lproj = resources / "es.lproj"
        lproj.mkdir()
        path = lproj / "Localizable.strings"
        path.write_bytes(b"this is not a property list")
        status, _, err = self.run_main(resources)
        self.assertEqual(status, 1)
        self.assertIn("es.lproj/Localizable.strings", err)
        self.assertEqual(path.read_bytes(), b"this is not a property list")


class ScopeTests(PackCase):
    """Only the language files directly inside a `*.lproj` folder are touched."""

    def test_other_files_are_left_alone(self):
        """A property list, a text file, a loose strings file, a nested bundle's languages, a non-lproj folder."""
        resources = self.folder()
        target = self.write_xml(resources, "es", "strings", {"a": "b"})
        untouched = {
            resources / "Info.plist": plistlib.dumps({"CFBundleName": "X"}),
            resources / "notes.txt": b"hello",
            resources / "Loose.strings": plistlib.dumps({"a": "b"}),
            resources / "es.lproj" / "readme.txt": b"not a language file",
            resources / "es.lproj" / "Localizable.strings.bak": plistlib.dumps({"a": "b"}),
        }
        nested = resources / "Frameworks" / "X.framework" / "Resources" / "fr.lproj"
        nested.mkdir(parents=True)
        untouched[nested / "Localizable.strings"] = plistlib.dumps({"a": "b"})
        elsewhere = resources / "Assets"
        elsewhere.mkdir()
        untouched[elsewhere / "Localizable.strings"] = plistlib.dumps({"a": "b"})
        for path, data in untouched.items():
            path.write_bytes(data)
        self.assertEqual(compact_packs.compact_folder(resources), (1, []))
        self.assertEqual(target.read_bytes(), b'"a"="b";')
        for path, data in untouched.items():
            self.assertEqual(path.read_bytes(), data, path)

    def test_a_missing_folder_is_a_usage_error(self):
        """Exit 2, and a message."""
        status, _, err = self.run_main(self.root / "nowhere")
        self.assertEqual(status, 2)
        self.assertIn("not a folder", err)

    def test_several_folders_cannot_be_compacted_at_once(self):
        """Compacting takes one folder; only --verify takes several."""
        status, _, err = self.run_main(self.folder("a"), self.folder("b"))
        self.assertEqual(status, 2)
        self.assertIn("one folder", err)


class VerifyTests(PackCase):
    """`--verify`: the sizes `make check` reports, and the files it refuses."""

    def test_a_compact_folder_passes_and_reports_sizes(self):
        """Each file is listed with its size and form, for both folders; the exit is 0."""
        resources = self.folder()
        self.write_xml(resources, "es", "strings", {"a": "b"})
        self.write_xml(resources, "es", "stringsdict", {"%lld books": plural_entry()})
        compact_packs.compact_folder(resources)
        other = self.folder("Second")
        self.write_xml(other, "en", "stringsdict", {"%lld books": plural_entry()})
        compact_packs.compact_folder(other)
        status, out, err = self.run_main("--verify", resources, other)
        self.assertEqual((status, err), (0, ""))
        self.assertIn("text   es.lproj/Localizable.strings", out)
        self.assertIn("binary es.lproj/Localizable.stringsdict", out)
        self.assertIn("binary en.lproj/Localizable.stringsdict", out)
        self.assertIn("8 bytes", out)  # `"a"="b";`

    def test_a_strings_file_left_in_xml_fails(self):
        """The build phase did not run: the name and the form are reported."""
        resources = self.folder()
        self.write_xml(resources, "es", "strings", {"a": "b"})
        status, _, err = self.run_main("--verify", resources)
        self.assertEqual(status, 1)
        self.assertIn("es.lproj/Localizable.strings is xml, not text", err)

    def test_a_stringsdict_left_in_xml_fails(self):
        """The same for a plural table."""
        resources = self.folder()
        self.write_xml(resources, "es", "stringsdict", {"%lld books": plural_entry()})
        status, _, err = self.run_main("--verify", resources)
        self.assertEqual(status, 1)
        self.assertIn("es.lproj/Localizable.stringsdict is xml, not binary", err)

    def test_a_binary_strings_file_fails(self):
        """A `.strings` as a binary list is bigger for accents, so it is not accepted either."""
        resources = self.folder()
        lproj = resources / "es.lproj"
        lproj.mkdir()
        (lproj / "Localizable.strings").write_bytes(plistlib.dumps({"a": "é"}, fmt=plistlib.FMT_BINARY))
        status, _, err = self.run_main("--verify", resources)
        self.assertEqual(status, 1)
        self.assertIn("is binary, not text", err)

    def test_no_language_files_fails(self):
        """A folder with none cannot be told from a build that lost them."""
        status, _, err = self.run_main("--verify", self.folder())
        self.assertEqual(status, 1)
        self.assertIn("no language files found", err)


if __name__ == "__main__":
    unittest.main()
