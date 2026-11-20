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


class StringsSmallerFormTests(PackCase):
    """A `.strings` is written in whichever of its two forms, text or binary, is smaller (TL18)."""

    # About 40 words of Japanese, so that a table of a few hundred of them is mostly CJK.
    JAPANESE = "ブックマークを追加して、あとで続きから読み上げを再開できます。"

    def table(self, value, count=300):
        """`count` entries with English keys, ASCII for the key and `value` for the text."""
        return {f"Key number {number} of the table": value for number in range(count)}

    def test_japanese_becomes_binary_because_utf16_is_smaller(self):
        """Three bytes a character in UTF-8, two in a binary list: a mostly Japanese table is binary."""
        resources = self.folder()
        path = self.write_xml(resources, "ja", "strings", self.table(self.JAPANESE))
        self.assertTrue(compact_packs.compact_file(path))
        self.assertTrue(path.read_bytes().startswith(b"bplist00"))
        text_size = len(compact_packs.render_strings(plistlib.loads(path.read_bytes())))
        self.assertLess(path.stat().st_size, text_size)

    def test_spanish_stays_text_because_utf8_is_smaller(self):
        """Accents cost two bytes in UTF-8 and the same in UTF-16, and the list adds its own overhead."""
        resources = self.folder()
        path = self.write_xml(resources, "es", "strings", {f"Key {n}": f"Texto número {n} con acentos: áéíóú" for n in range(300)})
        compact_packs.compact_file(path)
        self.assertEqual(path.read_bytes()[:1], b'"')

    def test_a_tie_goes_to_the_text_form(self):
        """When both forms have the same size the text form is written, since it is the one a person can read."""
        table = {"a": "b"}
        text = compact_packs.render_strings(table)
        with mock.patch.object(compact_packs, "render_strings_binary", return_value=b"x" * len(text)):
            self.assertEqual(compact_packs.render_smaller_strings(table), text)

    def test_the_binary_form_is_deterministic_and_sorted(self):
        """The same table in any order gives the same bytes (make check is a reproducibility gate)."""
        one = {"b": "ブ", "a": "ク", "c": "マ"}
        two = {"c": "マ", "a": "ク", "b": "ブ"}
        self.assertEqual(compact_packs.render_strings_binary(one), compact_packs.render_strings_binary(two))

    def test_the_binary_form_reads_back_through_apples_parser(self):
        """The self-check for a binary `.strings`: Apple's parser reads every character back, controls and astral ones too."""
        table = {"quote \" and \\": "「引用」\n改行\t\u0001 and 😀", "empty": ""}
        self.assertEqual(compact_packs.apple_parse(compact_packs.render_strings_binary(table)), table)

    def test_a_changed_lookup_in_the_binary_form_leaves_the_file_and_names_the_key(self):
        """The self-check holds for the binary form: a parser that disagrees fails the build with the file untouched."""
        resources = self.folder()
        table = self.table(self.JAPANESE)
        path = self.write_xml(resources, "ja", "strings", table)
        before = path.read_bytes()
        wrong = {**table, "Key number 7 of the table": "別の"}
        real_parse = compact_packs.apple_parse
        # The original is read by plistlib (an XML list), so only the read-back of the new bytes reaches here.
        with mock.patch.object(compact_packs, "apple_parse", side_effect=lambda data: wrong if data.startswith(b"bplist") else real_parse(data)):
            with self.assertRaises(compact_packs.CompactError) as raised:
                compact_packs.compact_file(path)
        self.assertIn("Key number 7 of the table", str(raised.exception))
        self.assertEqual(path.read_bytes(), before)

    def test_running_twice_changes_nothing_for_either_form(self):
        """A binary `.strings` already chosen is not rewritten (nor a text one)."""
        resources = self.folder()
        self.write_xml(resources, "ja", "strings", self.table(self.JAPANESE))
        self.write_xml(resources, "es", "strings", {"a": "ácido"})
        self.assertEqual(compact_packs.compact_folder(resources), (2, []))
        self.assertEqual(compact_packs.compact_folder(resources), (0, []))

    def test_a_binary_strings_with_a_smaller_text_form_is_rewritten_as_text(self):
        """A file left in the larger form is rewritten into the smaller, so the choice does not depend on history."""
        resources = self.folder()
        lproj = resources / "es.lproj"
        lproj.mkdir()
        path = lproj / "Localizable.strings"
        path.write_bytes(plistlib.dumps({"a": "b"}, fmt=plistlib.FMT_BINARY))
        self.assertTrue(compact_packs.compact_file(path))
        self.assertEqual(path.read_bytes(), b'"a"="b";')

    def test_a_non_string_entry_is_refused_in_either_form(self):
        """The binary form would hold a number, so the table is checked before either is rendered."""
        with self.assertRaises(compact_packs.CompactError):
            compact_packs.render_strings_binary({"a": 1})


class SqueezeTests(PackCase):
    """The squeeze across a folder's languages (TL18, items 2 and 3)."""

    def write_tables(self, resources, language, strings=None, plurals=None):
        """Write a language's `.strings` and `.stringsdict` as Xcode would (XML), for the tables given."""
        if strings is not None:
            self.write_xml(resources, language, "strings", strings)
        if plurals is not None:
            self.write_xml(resources, language, "stringsdict", plurals)

    def read(self, resources, language, kind):
        """What `<language>.lproj/Localizable.<kind>` holds, read back through Apple's parser; None when absent."""
        path = resources / f"{language}.lproj" / f"Localizable.{kind}"
        return compact_packs.apple_parse(path.read_bytes()) if path.exists() else None

    def one_text(self, text="%lld 冊"):
        """A plural entry whose every form is `text` (as a language with only `other` has it)."""
        return plural_entry({"other": text}, variable="value")

    def english_minutes(self):
        """English's plural entry for `%lld minutes`, with two forms."""
        return plural_entry({"one": "%lld minute", "other": "%lld minutes"}, variable="value")

    # -- item 3: one form, one plain entry ------------------------------------------------------------------

    def test_a_plural_entry_with_one_text_becomes_a_plain_entry(self):
        resources = self.folder()
        self.write_tables(resources, "ja", plurals={"%lld books": self.one_text()})
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual((result.errors, result.merged), ([], 1))
        self.assertEqual(self.read(resources, "ja", "strings"), {"%lld books": "%lld 冊"})
        # The emptied `.stringsdict` stays, as an empty binary list (nothing is deleted).
        self.assertEqual(self.read(resources, "ja", "stringsdict"), {})
        self.assertTrue((resources / "ja.lproj" / "Localizable.stringsdict").read_bytes().startswith(b"bplist00"))

    def test_forms_that_are_all_one_text_in_a_language_with_several_categories_merge_too(self):
        """Russian's four forms of one text: the same rule, whatever the language's categories."""
        entry = plural_entry({"one": "%d шт.", "few": "%d шт.", "many": "%d шт.", "other": "%d шт."}, variable="value")
        self.assertEqual(compact_packs.plain_text_of_plural(entry), "%d шт.")

    def test_an_entry_with_two_different_forms_stays(self):
        entry = plural_entry({"one": "%d libro", "other": "%d libros"}, variable="value")
        self.assertIsNone(compact_packs.plain_text_of_plural(entry))

    def test_an_entry_without_other_stays(self):
        """A count in a category with no form reads nothing as a plural; as a plain entry it would read text."""
        self.assertIsNone(compact_packs.plain_text_of_plural(plural_entry({"one": "%d x"}, variable="value")))

    def test_an_entry_with_two_variables_stays(self):
        entry = plural_entry({"other": "x"}, variable="a")
        entry["b"] = plural_entry({"other": "x"}, variable="b")["b"]
        self.assertIsNone(compact_packs.plain_text_of_plural(entry))

    def test_a_format_with_text_around_the_variable_stays(self):
        entry = plural_entry({"other": "%d x"}, variable="value")
        entry["NSStringLocalizedFormatKey"] = "Read %#@value@ today"
        self.assertIsNone(compact_packs.plain_text_of_plural(entry))

    def test_a_variable_that_is_not_a_plural_rule_stays(self):
        entry = plural_entry({"other": "x"}, variable="value")
        entry["value"]["NSStringFormatSpecTypeKey"] = "NSStringDeviceSpecificRuleType"
        self.assertIsNone(compact_packs.plain_text_of_plural(entry))

    def test_an_unknown_key_in_the_variable_stays(self):
        entry = plural_entry({"other": "x", "surprise": "x"}, variable="value")
        self.assertIsNone(compact_packs.plain_text_of_plural(entry))

    def test_a_non_text_form_stays(self):
        self.assertIsNone(compact_packs.plain_text_of_plural(plural_entry({"other": 5}, variable="value")))
        self.assertIsNone(compact_packs.plain_text_of_plural("not a dictionary"))

    def test_a_later_argument_needs_every_specifier_positioned(self):
        """`%2$#@value@` hands its form argument 2: a plain `%d` would read argument 1, so that form stays."""
        later = plural_entry({"other": "%d x"}, variable="value")
        later["NSStringLocalizedFormatKey"] = "%2$#@value@"
        self.assertIsNone(compact_packs.plain_text_of_plural(later))
        later = plural_entry({"other": "%1$@ and %2$lld, 100%%"}, variable="value")
        later["NSStringLocalizedFormatKey"] = "%2$#@value@"
        self.assertEqual(compact_packs.plain_text_of_plural(later), "%1$@ and %2$lld, 100%%")
        first = plural_entry({"other": "%d x"}, variable="value")
        first["NSStringLocalizedFormatKey"] = "%1$#@value@"
        self.assertEqual(compact_packs.plain_text_of_plural(first), "%d x")

    def test_an_entry_whose_key_is_already_plain_is_not_merged(self):
        """A key held both ways keeps its two entries, so neither is lost."""
        resources = self.folder()
        self.write_tables(resources, "ja", strings={"%lld books": "古い"}, plurals={"%lld books": self.one_text()})
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual(result.merged, 0)
        self.assertEqual(self.read(resources, "ja", "strings"), {"%lld books": "古い"})
        self.assertEqual(list(self.read(resources, "ja", "stringsdict")), ["%lld books"])

    def test_a_merge_creates_the_strings_file_a_language_lacked(self):
        resources = self.folder()
        self.write_tables(resources, "ja", plurals={"%lld books": self.one_text()})
        self.assertFalse((resources / "ja.lproj" / "Localizable.strings").exists())
        compact_packs.compact_folder(resources)
        self.assertTrue((resources / "ja.lproj" / "Localizable.strings").exists())

    # -- item 2: no entry that equals its key -----------------------------------------------------------------

    def test_an_entry_equal_to_its_key_is_left_out(self):
        resources = self.folder()
        self.write_tables(resources, "es", strings={"TextMouth": "TextMouth", "Open": "Abrir"})
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual(result.dropped, 1)
        self.assertEqual(self.read(resources, "es", "strings"), {"Open": "Abrir"})

    def test_a_table_left_with_no_entry_is_an_empty_binary_list(self):
        resources = self.folder()
        self.write_tables(resources, "es", strings={"TextMouth": "TextMouth"})
        compact_packs.compact_folder(resources)
        path = resources / "es.lproj" / "Localizable.strings"
        self.assertTrue(path.read_bytes().startswith(b"bplist00"))
        self.assertEqual(self.read(resources, "es", "strings"), {})

    def test_an_entry_stays_when_english_holds_the_key_as_a_plural_entry(self):
        """Without it a lookup falls back to English's plural, which formats differently."""
        resources = self.folder()
        self.write_tables(resources, "en", plurals={"%lld minutes": self.english_minutes()})
        self.write_tables(resources, "ja", strings={"%lld minutes": "%lld minutes"})
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual(result.dropped, 0)
        self.assertEqual(self.read(resources, "ja", "strings"), {"%lld minutes": "%lld minutes"})

    def test_an_entry_stays_when_english_holds_the_key_with_another_text(self):
        resources = self.folder()
        self.write_tables(resources, "en", strings={"Open": "Open file"})
        self.write_tables(resources, "ja", strings={"Open": "Open"})
        compact_packs.compact_folder(resources)
        self.assertEqual(self.read(resources, "ja", "strings"), {"Open": "Open"})

    def test_an_entry_goes_when_english_holds_the_key_as_the_key(self):
        resources = self.folder()
        self.write_tables(resources, "en", strings={"Open": "Open"})
        self.write_tables(resources, "ja", strings={"Open": "Open", "Close": "閉じる"})
        compact_packs.compact_folder(resources)
        self.assertEqual(self.read(resources, "ja", "strings"), {"Close": "閉じる"})
        self.assertEqual(self.read(resources, "en", "strings"), {})

    def test_an_entry_stays_when_its_own_language_holds_the_key_as_a_plural_entry(self):
        """A plain entry beside a plural one of the same key in its own language is not touched."""
        resources = self.folder()
        self.write_tables(
            resources, "es", strings={"%lld books": "%lld books"},
            plurals={"%lld books": plural_entry({"one": "%d libro", "other": "%d libros"}, "value")},
        )
        self.assertEqual(compact_packs.compact_folder_counting(resources).dropped, 0)

    def test_a_merged_entry_equal_to_its_key_goes_when_english_does_not_block_it(self):
        """The two items together: a one-text plural whose text is its key is merged, then left out."""
        resources = self.folder()
        self.write_tables(resources, "ja", plurals={"%lld%% done": plural_entry({"other": "%lld%% done"}, "value")})
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual((result.merged, result.dropped), (1, 1))

    def test_each_table_name_is_squeezed_on_its_own(self):
        """A table other than Localizable is separate: English's plural of `Open` in Localizable does not block it."""
        resources = self.folder()
        self.write_tables(resources, "en", plurals={"Open": plural_entry({"one": "a", "other": "b"}, "value")})
        other = resources / "ja.lproj"
        other.mkdir()
        (other / "Other.strings").write_bytes(plistlib.dumps({"Open": "Open"}, fmt=plistlib.FMT_XML))
        compact_packs.compact_folder(resources)
        self.assertEqual(compact_packs.apple_parse((other / "Other.strings").read_bytes()), {})

    def test_each_item_can_be_switched_off_for_measuring(self):
        """`merge` and `drop` stand for items 3 and 2: with both off nothing is squeezed."""
        resources = self.folder()
        self.write_tables(resources, "ja", strings={"TextMouth": "TextMouth"}, plurals={"%lld books": self.one_text()})
        tables = {path: compact_packs.read_table(path) for path in compact_packs.language_files(resources)}
        none = compact_packs.squeeze_tables(resources, tables, merge=False, drop=False)
        self.assertEqual((none.merged, none.dropped), (0, 0))
        merge_only = compact_packs.squeeze_tables(resources, tables, drop=False)
        self.assertEqual((merge_only.merged, merge_only.dropped), (1, 0))
        drop_only = compact_packs.squeeze_tables(resources, tables, merge=False)
        self.assertEqual((drop_only.merged, drop_only.dropped), (0, 1))

    def test_infoplist_strings_keep_an_entry_equal_to_its_key(self):
        """A missing key in InfoPlist.strings falls back to the Info.plist's value, not to the key."""
        resources = self.folder()
        lproj = resources / "ja.lproj"
        lproj.mkdir()
        (lproj / "InfoPlist.strings").write_bytes(plistlib.dumps({"CFBundleName": "CFBundleName"}, fmt=plistlib.FMT_XML))
        result = compact_packs.compact_folder_counting(resources)
        self.assertEqual(result.dropped, 0)
        self.assertEqual(compact_packs.apple_parse((lproj / "InfoPlist.strings").read_bytes()), {"CFBundleName": "CFBundleName"})

    def test_the_squeeze_does_not_change_its_input(self):
        tables = {Path("r/ja.lproj/Localizable.strings"): {"a": "a"}}
        compact_packs.squeeze_tables(Path("r"), tables)
        self.assertEqual(tables, {Path("r/ja.lproj/Localizable.strings"): {"a": "a"}})

    def test_a_folder_that_cannot_be_read_is_not_squeezed(self):
        """An unreadable table might hold what a drop relies on: the rest is compacted as it is, and the build fails."""
        resources = self.folder()
        self.write_tables(resources, "es", strings={"TextMouth": "TextMouth"})
        (resources / "en.lproj").mkdir()
        (resources / "en.lproj" / "Localizable.stringsdict").write_bytes(b"\x00 not a property list")
        result = compact_packs.compact_folder_counting(resources)
        self.assertTrue(result.errors)
        self.assertEqual(result.dropped, 0)
        self.assertEqual(self.read(resources, "es", "strings"), {"TextMouth": "TextMouth"})

    def test_running_twice_changes_nothing_the_second_time(self):
        resources = self.folder()
        self.write_tables(resources, "en", plurals={"%lld minutes": self.english_minutes()})
        self.write_tables(
            resources, "ja", strings={"TextMouth": "TextMouth", "%lld minutes": "%lld minutes"},
            plurals={"%lld books": self.one_text()},
        )
        first = compact_packs.compact_folder_counting(resources)
        self.assertGreater(first.changed, 0)
        second = compact_packs.compact_folder_counting(resources)
        self.assertEqual((second.changed, second.merged, second.dropped, second.errors), (0, 0, 0, []))

    def test_the_command_line_reports_the_squeeze(self):
        resources = self.folder()
        self.write_tables(resources, "ja", strings={"TextMouth": "TextMouth"}, plurals={"%lld books": self.one_text()})
        status, out, err = self.run_main(resources)
        self.assertEqual((status, err), (0, ""))
        self.assertIn("1 plural entr(ies) written plain, 1 entr(ies) equal to their key left out", out)


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
        self.assertIn("es.lproj/Localizable.strings is xml, not text or binary", err)

    def test_a_stringsdict_left_in_xml_fails(self):
        """The same for a plural table."""
        resources = self.folder()
        self.write_xml(resources, "es", "stringsdict", {"%lld books": plural_entry()})
        status, _, err = self.run_main("--verify", resources)
        self.assertEqual(status, 1)
        self.assertIn("es.lproj/Localizable.stringsdict is xml, not binary", err)

    def test_a_binary_strings_file_passes(self):
        """A `.strings` as a binary list is a compact form (TL18): accepted, and its form is reported."""
        resources = self.folder()
        lproj = resources / "ja.lproj"
        lproj.mkdir()
        (lproj / "Localizable.strings").write_bytes(plistlib.dumps({"a": "日本語"}, fmt=plistlib.FMT_BINARY))
        status, out, err = self.run_main("--verify", resources)
        self.assertEqual((status, err), (0, ""))
        self.assertIn("binary ja.lproj/Localizable.strings", out)

    def test_no_language_files_fails(self):
        """A folder with none cannot be told from a build that lost them."""
        status, _, err = self.run_main("--verify", self.folder())
        self.assertEqual(status, 1)
        self.assertIn("no language files found", err)


if __name__ == "__main__":
    unittest.main()
