"""Tests of Scripts/l10n/catalog.py: the layout, the placeholders, the plural categories, the English text, and the states.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Nothing here builds anything. The layout tests read catalogs that `xcstringstool` itself wrote (committed under
fixtures/), and one live test runs the real `xcstringstool sync` when it is installed.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The module under test is in the folder above this one (python3 -I leaves both out of sys.path).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import catalog  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
# The repository's own catalog, which must stay in the layout.
REPOSITORY_CATALOG = Path(__file__).resolve().parents[3] / "TextMouth" / "Localization" / "Localizable.xcstrings"


def read_exact(path):
    """A file's text with its line endings and its end untouched."""
    return catalog.read_text(path)


def string_unit(value, state="translated"):
    """A stringUnit node, as a catalog holds it."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    """A localization with plural variations: plural(one="a", other="b")."""
    return {"variations": {"plural": {name: string_unit(value) for name, value in forms.items()}}}


class LayoutTests(unittest.TestCase):
    """`dumps` writes what xcstringstool writes, byte for byte."""

    def test_every_catalog_xcstringstool_wrote_comes_back_unchanged(self):
        fixtures = sorted(FIXTURES.glob("*-by-xcstringstool.xcstrings"))
        self.assertGreaterEqual(len(fixtures), 3)
        for path in fixtures:
            text = read_exact(path)
            self.assertEqual(catalog.dumps(catalog.loads(text)), text, path.name)

    def test_the_repositorys_catalog_is_in_the_layout(self):
        text = read_exact(REPOSITORY_CATALOG)
        self.assertEqual(catalog.dumps(catalog.loads(text)), text)

    def test_an_empty_catalog_is_what_xcstringstool_writes(self):
        self.assertEqual(catalog.Catalog.empty().dumps(),
                         '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}')

    def test_a_catalog_in_another_layout_is_rewritten_in_this_one_with_the_same_values(self):
        data = {"version": "1.0", "strings": {"b": {"comment": "c"}, "A": {}}, "sourceLanguage": "en"}
        foreign = json.dumps(data, indent=4)
        self.assertEqual(catalog.loads(foreign), data)
        self.assertEqual(catalog.dumps(catalog.loads(foreign)),
                         '{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "A" : {\n\n    },\n    "b" : {\n'
                         '      "comment" : "c"\n    }\n  },\n  "version" : "1.0"\n}')

    def test_keys_are_sorted_by_code_point_at_every_level(self):
        data = {"strings": {"apple": {}, "Zed": {}, "\U0001F600": {}, "～": {}, "10": {}, "9": {}}}
        self.assertEqual([line.strip().split('"')[1] for line in catalog.dumps(data).splitlines() if line.startswith('    "')],
                         ["10", "9", "Zed", "apple", "～", "\U0001F600"])

    def test_strings_are_escaped_as_json_requires_and_no_more(self):
        text = catalog.dumps({"k": 'q"\\\n\t\r\b\f\x01\x1f/\x7f é\U0001F600'})
        self.assertEqual(text, '{\n  "k" : "q\\"\\\\\\n\\t\\r\\b\\f\\u0001\\u001f/\x7f é\U0001F600"\n}')

    def test_booleans_numbers_and_empty_lists_are_written_as_foundation_writes_them(self):
        self.assertEqual(catalog.dumps({"a": True, "b": False, "c": 3, "d": []}),
                         '{\n  "a" : true,\n  "b" : false,\n  "c" : 3,\n  "d" : [\n\n  ]\n}')

    def test_the_text_has_no_newline_at_its_end(self):
        self.assertFalse(catalog.dumps({"a": 1}).endswith("\n"))


class SaveTests(unittest.TestCase):
    """Saving, canonicalizing, and leaving a canonical file alone."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def test_save_writes_the_layout_and_reports_a_change_once(self):
        path = self.folder / "Localizable.xcstrings"
        shutil.copy(FIXTURES / "translated-by-xcstringstool.xcstrings", path)
        loaded = catalog.Catalog.load(path)
        loaded.strings["New"] = {}
        self.assertTrue(loaded.save())
        self.assertFalse(loaded.save(), "a second save has nothing to write")
        self.assertEqual(read_exact(path), catalog.dumps(catalog.loads(read_exact(path))))
        self.assertIn("New", catalog.loads(read_exact(path))["strings"])

    def test_canonicalize_changes_the_layout_and_no_value(self):
        path = self.folder / "Localizable.xcstrings"
        original = catalog.loads(read_exact(FIXTURES / "translated-by-xcstringstool.xcstrings"))
        path.write_text(json.dumps(original, indent=4, ensure_ascii=False), encoding="utf-8")
        self.assertTrue(catalog.canonicalize(path))
        self.assertEqual(catalog.loads(read_exact(path)), original)
        self.assertEqual(read_exact(path), read_exact(FIXTURES / "translated-by-xcstringstool.xcstrings"))
        self.assertFalse(catalog.canonicalize(path), "a file already in the layout is not rewritten")

    @unittest.skipUnless(shutil.which("xcrun") and subprocess.run(["xcrun", "--find", "xcstringstool"], capture_output=True).returncode == 0,
                         "xcstringstool is not installed")
    def test_what_xcstringstool_writes_after_a_sync_is_what_dumps_writes(self):
        # The live proof: our text goes in, the tool adds a string and rewrites the file, and its text is ours again.
        path = self.folder / "Localizable.xcstrings"
        catalog.write_text(path, catalog.dumps(catalog.loads(read_exact(FIXTURES / "translated-by-xcstringstool.xcstrings"))))
        data = self.folder / "found.stringsdata"
        data.write_text(json.dumps({"source": "X.swift", "version": 1, "tables": {"Localizable": [
            {"comment": "from the sync", "key": "Found é by sync", "location": {"startingColumn": 1, "startingLine": 1}}]}}))
        done = subprocess.run(["xcrun", "xcstringstool", "sync", str(path), "--stringsdata", str(data), "--skip-marking-strings-stale"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        text = read_exact(path)
        self.assertIn("Found é by sync", catalog.loads(text)["strings"])
        self.assertEqual(catalog.dumps(catalog.loads(text)), text)


class PlaceholderTests(unittest.TestCase):
    """Format specifiers as Foundation reads them."""

    def types(self, text):
        """The type tokens of a text's placeholders, in order."""
        return [p.type for p in catalog.placeholders(text)]

    def test_the_specifiers_of_the_brief_are_found_with_their_types(self):
        cases = {
            "%@": ["object"], "%d": ["int32"], "%ld": ["int64"], "%lld": ["int64"], "%u": ["uint32"], "%lu": ["uint64"],
            "%f": ["double"], "%lf": ["double"], "%.1f": ["double"], "%x": ["uint32 hex"], "%1$@": ["object"], "%2$lld": ["int64"],
            "%s": ["cstring"], "%c": ["char"], "%hd": ["int16"], "%hhd": ["int8"], "%hu": ["uint16"], "%zd": ["int64"],
            "%D": ["int64"], "%Lf": ["long double"], "%5.2f%%": ["double"], "%-8s|": ["cstring"], "%#x": ["uint32 hex"],
            "%o": ["uint32 octal"], "%X": ["uint32 HEX"], "%e": ["double exponent"], "%G": ["double general"],
            "%a": ["double hex"], "%F": ["double"], "%C": ["unichar"], "%S": ["unistring"], "%p": ["pointer"],
        }
        for text, expected in cases.items():
            self.assertEqual(self.types(text), expected, text)

    def test_a_double_percent_is_a_literal_and_not_a_placeholder(self):
        self.assertEqual(catalog.placeholders("100%% done"), [])
        self.assertEqual(self.types("%lld%% of %@"), ["int64", "object"])
        # A literal percent sign directly before a specifier does not swallow it.
        self.assertEqual(self.types("%%%@"), ["object"])

    def test_a_percent_that_starts_no_specifier_is_text(self):
        self.assertEqual(catalog.placeholders("50%. Then 100%"), [])

    def test_a_substitution_is_a_placeholder_named_by_its_variable(self):
        found = catalog.placeholders("%#@books@ and %#@pages@")
        self.assertEqual([(p.name, p.type) for p in found], [("books", "substitution"), ("pages", "substitution")])

    def test_xcode_26s_named_form_is_a_placeholder_named_by_its_name(self):
        found = catalog.placeholders("%(count)lld books")
        self.assertEqual([(p.name, p.type, p.position) for p in found], [("count", "int64", None)])

    def test_the_argument_of_a_substitutions_own_forms_is_not_a_slot(self):
        self.assertEqual(catalog.slots("%arg book")[0], {})
        self.assertEqual([p.type for p in catalog.placeholders("%arg book")], ["substitution argument"])

    def test_unnumbered_placeholders_take_positions_in_order(self):
        self.assertEqual(catalog.slots("%@ of %lld")[0], {1: "object", 2: "int64"})
        self.assertEqual(catalog.slots("%2$lld of %1$@")[0], {1: "object", 2: "int64"})

    def test_the_same_placeholders_agree_whatever_their_formatting(self):
        self.assertEqual(catalog.compare_placeholders("%lld books", "%lld libros"), [])
        self.assertEqual(catalog.compare_placeholders("%f seconds", "%.1f segundos"), [])
        self.assertEqual(catalog.compare_placeholders("%ld", "%lld"), [], "both 64 bits on Apple's platforms")
        self.assertEqual(catalog.compare_placeholders("100%% sure", "100%% seguro"), [])
        self.assertEqual(catalog.compare_placeholders("No placeholder", "Sin marcador"), [])

    def test_a_translation_may_reorder_placeholders_only_with_positions(self):
        self.assertEqual(catalog.compare_placeholders("%@ has %lld pages", "%2$lld páginas tiene %1$@"), [])
        problems = catalog.compare_placeholders("%@ has %lld pages", "%lld páginas tiene %@")
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("placeholder 1 is a int64" in p for p in problems), problems)

    def test_a_missing_an_extra_and_a_changed_placeholder_are_each_reported(self):
        self.assertEqual(catalog.compare_placeholders("%@ and %lld", "%@ y"), ["missing placeholder number 2 (int64)"])
        self.assertEqual(catalog.compare_placeholders("%@", "%@ y %lld"), ["extra placeholder number 2 (int64)"])
        self.assertEqual(catalog.compare_placeholders("%lld", "%@"), ["placeholder 1 is a object, the English's is a int64"])
        self.assertEqual(catalog.compare_placeholders("%d", "%lld"), ["placeholder 1 is a int64, the English's is a int32"])

    def test_numbered_and_unnumbered_placeholders_mixed_are_a_problem_of_the_text(self):
        self.assertIn("mixed", catalog.placeholder_problems("%1$@ and %lld")[0])
        self.assertEqual(catalog.placeholder_problems("%1$@ and %2$lld"), [])

    def test_one_position_with_two_types_is_a_problem_but_one_type_twice_is_not(self):
        self.assertEqual(catalog.placeholder_problems("%1$@ then %1$@"), [])
        self.assertEqual(len(catalog.placeholder_problems("%1$@ then %1$lld")), 1)

    def test_named_placeholders_are_compared_by_name(self):
        self.assertEqual(catalog.compare_placeholders("%(count)lld of %(total)lld", "%(total)lld de %(count)lld"), [])
        self.assertEqual(catalog.compare_placeholders("%#@books@", "%#@libros@"),
                         ["missing placeholder books (substitution)", "extra placeholder libros (substitution)"])


class FoundationReadingTests(unittest.TestCase):
    """What Foundation does with a specifier, which decides when two placeholders agree (the review of l10n/core, findings 2
    to 4): a space is not a flag, the conversion class and `h` length are part of the type, and `*` and an empty precision
    are read."""

    def test_a_percent_and_a_space_is_text_in_the_languages_that_space_a_percent_sign(self):
        # Spanish, French, and German put a space before the sign: "50 % de descuento" holds no `% d`.
        for translation in ("50 % de descuento", "10 % de réduction", "Remise de 10 %", "50 % off", "5 % x", "7 % e"):
            self.assertEqual(catalog.placeholders(translation), [], translation)
            self.assertEqual(catalog.compare_placeholders("50% off", translation), [], translation)
        self.assertEqual(catalog.compare_placeholders("10% discount", "Remise de 10 %"), [])

    def test_a_space_does_not_start_a_flag_even_in_a_format_string(self):
        # With an argument the compiler writes `%%`, and a lone `%` is reported by percent_problems, not read as `% d`.
        self.assertEqual([p.raw for p in catalog.placeholders("50%% de %lld")], ["%lld"])
        self.assertEqual([p.raw for p in catalog.placeholders("% d")], [])

    def test_the_conversion_classes_that_print_differently_do_not_agree(self):
        for english, translation in (("%u", "%x"), ("%x", "%X"), ("%o", "%u"), ("%x", "%o"), ("%f", "%e"), ("%e", "%g"),
                                     ("%g", "%a"), ("%f", "%g"), ("%d", "%u"), ("%lld", "%llu"), ("%c", "%C"), ("%s", "%S"),
                                     ("%p", "%@")):
            self.assertEqual(len(catalog.compare_placeholders(english, translation)), 1, (english, translation))

    def test_the_conversions_that_print_alike_agree(self):
        # `d` and `i`, `f` and `F`, `e` and `E`, `g` and `G`, `a` and `A` differ only in case or not at all.
        for english, translation in (("%d", "%i"), ("%f", "%F"), ("%e", "%E"), ("%g", "%G"), ("%a", "%A"), ("%ld", "%lld"),
                                     ("%lu", "%llu"), ("%zd", "%lld"), ("%@", "%@")):
            self.assertEqual(catalog.compare_placeholders(english, translation), [], (english, translation))

    def test_a_short_integer_is_not_an_int(self):
        self.assertEqual(catalog.compare_placeholders("%d", "%hd"), ["placeholder 1 is a int16, the English's is a int32"])
        self.assertEqual(catalog.compare_placeholders("%d", "%hhd"), ["placeholder 1 is a int8, the English's is a int32"])
        self.assertEqual(catalog.compare_placeholders("%hd", "%hhd"), ["placeholder 1 is a int8, the English's is a int16"])
        self.assertEqual(catalog.compare_placeholders("%hd", "%hd"), [])

    def test_the_wide_lengths_stay_one_type_and_an_int_stays_apart_from_them(self):
        self.assertEqual(catalog.compare_placeholders("%ld", "%lld"), [], "both 64 bits")
        self.assertEqual(catalog.compare_placeholders("%d", "%lld"), ["placeholder 1 is a int64, the English's is a int32"])

    def test_every_number_type_a_plural_can_vary_on_is_one(self):
        for text in ("%d", "%lld", "%hd", "%u", "%x", "%o", "%f", "%e", "%g", "%a", "%Lf", "%lu"):
            self.assertTrue(catalog.has_number(text), text)
        for text in ("%@", "%s", "%c", "%p", "plain"):
            self.assertFalse(catalog.has_number(text), text)

    def test_an_empty_precision_is_read(self):
        self.assertEqual([(p.raw, p.type) for p in catalog.placeholders("%.f")], [("%.f", "double")])
        self.assertEqual([(p.raw, p.type) for p in catalog.placeholders("%.d items")], [("%.d", "int32")])
        # The English `%.f` is a double, so a translation that keeps it agrees and one that drops it is missing it.
        self.assertEqual(catalog.compare_placeholders("%.f seconds", "%.f segundos"), [])
        self.assertEqual(catalog.compare_placeholders("%.f seconds", "%f segundos"), [])
        self.assertEqual(catalog.compare_placeholders("%.f seconds", "segundos"), ["missing placeholder number 1 (double)"])
        self.assertEqual(catalog.compare_placeholders("%.d", "%.f"), ["placeholder 1 is a double, the English's is a int32"])

    def test_a_star_width_takes_an_int_argument_before_the_value(self):
        self.assertEqual(catalog.slots("%*d")[0], {1: "int32", 2: "int32"})
        self.assertEqual(catalog.slots("%@ %*lld")[0], {1: "object", 2: "int32", 3: "int64"})
        self.assertEqual(catalog.compare_placeholders("%*d", "%*d"), [])
        self.assertEqual(catalog.compare_placeholders("%.*f", "%.*f"), [])
        self.assertEqual(catalog.compare_placeholders("%*.*f", "%*.*f"), [])

    def test_a_star_precision_and_both_stars_each_take_an_int_argument(self):
        self.assertEqual(catalog.slots("%.*f")[0], {1: "int32", 2: "double"})
        self.assertEqual(catalog.slots("%*.*f")[0], {1: "int32", 2: "int32", 3: "double"})
        self.assertEqual(catalog.compare_placeholders("%.*f", "%.*f"), [])

    def test_a_numbered_star_names_the_argument_it_takes(self):
        self.assertEqual(catalog.slots("%1$*2$d")[0], {1: "int32", 2: "int32"})
        self.assertEqual(catalog.slots("%2$*1$d")[0], {1: "int32", 2: "int32"})
        self.assertEqual(catalog.slots("%1$@ %2$*3$.*4$f")[0], {1: "object", 2: "double", 3: "int32", 4: "int32"})
        self.assertEqual(catalog.placeholder_problems("%1$*2$d"), [])
        self.assertEqual(catalog.compare_placeholders("%1$*2$d", "%1$*2$d"), [])

    def test_a_numbered_value_with_an_unnumbered_star_is_a_mix(self):
        self.assertIn("mixed", catalog.placeholder_problems("%1$*d")[0])

    def test_a_star_a_translation_loses_is_reported(self):
        # The English `%*d` has two arguments (width, value); `%d` has one.
        problems = catalog.compare_placeholders("%*d", "%d")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("missing placeholder number 2", problems[0])
        problems = catalog.compare_placeholders("%.*f", "%f")
        self.assertEqual(len(problems), 2, problems)

    def test_a_different_precision_is_a_warning_and_never_a_problem(self):
        self.assertEqual(catalog.compare_placeholders("%.1f s", "%.3f s"), [], "agrees: only the type counts")
        self.assertEqual(catalog.precision_warnings("%.1f s", "%.3f s"),
                         ["placeholder 1 prints 3 digits where the English's prints 1"])
        self.assertEqual(catalog.precision_warnings("%.1f s", "%.1f s"), [])
        # A missing precision is the conversion's default (six digits for a float): `%f` against `%.1f` differs.
        self.assertEqual(catalog.precision_warnings("%f s", "%.1f s"),
                         ["placeholder 1 prints 1 digits where the English's prints 6"])
        self.assertEqual(catalog.precision_warnings("%f", "%.6f"), [])
        self.assertEqual(catalog.precision_warnings("%.f", "%.0f"), [])
        # Positions line up the slots; a star's precision is an argument, not a number of digits.
        self.assertEqual(catalog.precision_warnings("%1$.1f %2$.2f", "%2$.2f %1$.1f"), [])
        self.assertEqual(catalog.precision_warnings("%.*f", "%.2f"), [])
        self.assertEqual(catalog.precision_warnings("%@", "%@"), [])
        # Different types are a refusal's business, not a warning's.
        self.assertEqual(catalog.precision_warnings("%.1f", "%.1d"), [])


class PercentTests(unittest.TestCase):
    """`%%` and the lone `%`: counted, and compared between the English and a translation."""

    def test_percent_signs_are_counted_by_kind(self):
        self.assertEqual(catalog.percent_signs("Rate: %lld%%"), (1, 0, 1))
        self.assertEqual(catalog.percent_signs("100%% sure"), (1, 0, 0))
        self.assertEqual(catalog.percent_signs("Tasa: %lld %"), (0, 1, 1))
        self.assertEqual(catalog.percent_signs("50% of the book"), (0, 1, 0), "a space is no flag: `% o` is text")
        self.assertEqual(catalog.percent_signs("Save 5%")[1], 1)

    def test_a_different_number_of_literal_percent_signs_is_a_problem(self):
        self.assertEqual(catalog.compare_placeholders("Rate: %lld%%", "Tasa: %lld"),
                         ["0 literal percent signs (%%) where the English has 1"])
        self.assertEqual(catalog.compare_placeholders("Rate: %lld", "Tasa: %lld%%"),
                         ["1 literal percent sign (%%) where the English has 0"])
        self.assertEqual(catalog.compare_placeholders("Rate: %lld%%", "Tasa: %lld%%"), [])

    def test_a_lone_percent_is_a_problem_in_a_format_string_and_not_in_plain_text(self):
        self.assertIn("a lone % that is no placeholder: write %% for a percent sign",
                      catalog.compare_placeholders("Rate: %lld%%", "Tasa: %lld %"))
        self.assertIn("a lone %", catalog.compare_placeholders("Done %lld", "Hecho %lld 5%")[0])
        self.assertEqual(catalog.compare_placeholders("Save 5%.", "Ahorra el 5%."), [], "plain text is not a format string")


class PluralCategoryTests(unittest.TestCase):
    """CLDR's plural categories, one test for each family of languages."""

    def test_the_germanic_languages_and_turkish_have_one_and_other(self):
        for language in ("en", "de", "nl", "tr"):
            self.assertEqual(catalog.plural_categories(language), ("one", "other"), language)

    def test_the_romance_languages_have_one_many_and_other(self):
        for language in ("es", "fr", "it", "pt", "pt-BR", "pt-PT", "es-419"):
            self.assertEqual(catalog.plural_categories(language), ("one", "many", "other"), language)

    def test_chinese_japanese_and_korean_have_other_alone(self):
        for language in ("ja", "zh-Hans", "zh-Hant", "ko"):
            self.assertEqual(catalog.plural_categories(language), ("other",), language)

    def test_russian_and_polish_have_one_few_many_and_other(self):
        for language in ("ru", "pl"):
            self.assertEqual(catalog.plural_categories(language), ("one", "few", "many", "other"), language)

    def test_arabic_has_all_six(self):
        self.assertEqual(catalog.plural_categories("ar"), ("zero", "one", "two", "few", "many", "other"))

    def test_hebrew_has_one_two_and_other_since_cldr_42(self):
        self.assertEqual(catalog.plural_categories("he"), ("one", "two", "other"))

    def test_a_region_uses_its_languages_rule_and_an_underscore_is_read_as_a_hyphen(self):
        self.assertEqual(catalog.plural_categories("zh_Hans"), ("other",))
        self.assertEqual(catalog.plural_categories("ru-UA"), ("one", "few", "many", "other"))

    def test_a_language_with_no_recorded_rule_is_refused(self):
        with self.assertRaises(KeyError):
            catalog.plural_categories("xx")


class PluralTableTests(unittest.TestCase):
    """The table of plural categories against CLDR release 49 (common/supplemental/plurals.xml at the tag `release-49`),
    language by language, written out here as an independent copy so that a change to the table must change this too."""

    CLDR_49 = {
        "af": "one other", "ar": "zero one two few many other", "ca": "one many other", "cs": "one few many other",
        "da": "one other", "de": "one other", "el": "one other", "en": "one other", "es": "one many other",
        "et": "one other", "fa": "one other", "fi": "one other", "fr": "one many other",
        # Galician shares Catalan's and Italian's rule, `many` included (a reviewer believed it had only one and other).
        "bn": "one other", "gl": "one many other", "he": "one two other", "hi": "one other", "hu": "one other", "id": "other",
        "it": "one many other", "ja": "other", "ko": "other", "ms": "other", "nb": "one other", "nl": "one other",
        "nn": "one other", "no": "one other", "pl": "one few many other", "pt": "one many other",
        "pt-PT": "one many other", "ro": "one few other", "ru": "one few many other", "sk": "one few many other",
        "sv": "one other", "th": "other", "tr": "one other", "uk": "one few many other", "ur": "one other",
        # Vietnamese has `one` (0 and 1) in release 49, but the table keeps `other` alone, as Apple's Foundation does
        # (catalog.py says why): the one language where the table follows Apple rather than this release.
        "vi": "other", "zh": "other", "zh-Hans": "other", "zh-Hant": "other",
    }

    def test_every_language_of_the_table_has_cldrs_categories(self):
        for language, categories in self.CLDR_49.items():
            self.assertEqual(catalog.plural_categories(language), tuple(categories.split()), language)

    def test_the_table_has_no_language_this_check_does_not_know(self):
        self.assertEqual(sorted(catalog.PLURAL_CATEGORIES), sorted(self.CLDR_49))

    def test_every_language_with_a_one_category_has_a_one_rule_and_no_other_does(self):
        with_one = {language for language, categories in catalog.PLURAL_CATEGORIES.items() if "one" in categories}
        self.assertEqual(with_one, set(catalog.ONE_RULES))

    def test_one_means_exactly_the_number_1_in_the_languages_whose_rule_says_so(self):
        for language in ("en", "es", "de", "it", "nl", "pt-PT", "ca", "gl", "pl", "cs", "ar", "he", "da", "tr", "sv", "ro",
                         "ur"):
            self.assertTrue(catalog.one_is_exactly_one(language), language)

    def test_one_covers_more_than_the_number_1_in_french_portuguese_russian_and_hindi(self):
        for language in ("fr", "pt", "pt-BR", "ru", "uk", "hi", "bn", "fa"):
            self.assertFalse(catalog.one_is_exactly_one(language), language)
        self.assertTrue(catalog.one_selects("fr", 0), "French's one covers 0")
        self.assertTrue(catalog.one_selects("ru", 21), "Russian's one covers 21")
        self.assertFalse(catalog.one_selects("ru", 11))

    def test_a_language_with_no_one_category_or_no_rule_is_not_exactly_one(self):
        self.assertFalse(catalog.one_is_exactly_one("ja"))
        self.assertFalse(catalog.one_is_exactly_one("xx"))

    def test_a_region_uses_its_languages_one_rule_unless_it_has_its_own(self):
        self.assertTrue(catalog.one_is_exactly_one("es-419"))
        self.assertFalse(catalog.one_is_exactly_one("pt-BR"), "Brazil's Portuguese is `pt`, whose one covers 0")
        self.assertTrue(catalog.one_is_exactly_one("pt-PT"), "Portugal's has its own rule")

    def test_a_number_placeholder_may_be_dropped_only_when_asked(self):
        self.assertEqual(catalog.compare_placeholders("%lld book", "Un libro"), ["missing placeholder number 1 (int64)"])
        self.assertEqual(catalog.compare_placeholders("%lld book", "Un libro", may_drop_numbers=True), [])
        self.assertEqual(catalog.compare_placeholders("%lld in %@", "Uno", may_drop_numbers=True), ["missing placeholder number 2 (object)"])
        self.assertEqual(catalog.compare_placeholders("One", "%lld uno", may_drop_numbers=True), ["extra placeholder number 1 (int64)"])

    def test_has_number_finds_integers_and_floats_but_not_objects(self):
        self.assertTrue(catalog.has_number("%lld books"))
        self.assertTrue(catalog.has_number("%.1f hours"))
        self.assertFalse(catalog.has_number("Open %@"))
        self.assertFalse(catalog.has_number("100%% done"))


class EnglishTextTests(unittest.TestCase):
    """The English text of a catalog, in UTF-8 bytes, each text once."""

    def make(self, strings):
        """A catalog holding `strings`."""
        return catalog.Catalog({"sourceLanguage": "en", "strings": strings, "version": "1.0"})

    def test_the_english_is_the_en_text(self):
        cat = self.make({"player.play": {"localizations": {"en": string_unit("Play")}},
                         "player.cafe": {"localizations": {"en": string_unit("Café")}}})
        self.assertEqual(cat.english_texts(), {"Play", "Café"})
        self.assertEqual(cat.english_bytes(), len("Play") + len("Café".encode("utf-8")))

    def test_a_string_with_no_english_localization_has_no_english_not_its_key(self):
        cat = self.make({"player.play": {}})
        self.assertEqual(cat.english_forms("player.play"), [])
        self.assertEqual(cat.english_bytes(), 0)

    def test_plural_and_device_forms_count_instead_of_the_key(self):
        cat = catalog.Catalog.load(FIXTURES / "plural-and-device-by-xcstringstool.xcstrings")
        self.assertEqual(cat.english_texts(), {"%lld book", "%lld books", "Tap to play", "Click to play"})

    def test_a_text_two_strings_share_counts_once(self):
        cat = self.make({"a.done": {"localizations": {"en": string_unit("Done")}},
                         "a.doneAgain": {"localizations": {"en": string_unit("Done")}}})
        self.assertEqual(cat.english_texts(), {"Done"})
        self.assertEqual(cat.english_bytes(), 4)

    def test_stale_strings_and_strings_that_opt_out_do_not_count(self):
        cat = self.make({"a.live": {"localizations": {"en": string_unit("Live")}},
                         "a.old": {"extractionState": "stale", "localizations": {"en": string_unit("Old")}},
                         "a.never": {"shouldTranslate": False, "localizations": {"en": string_unit("Never")}}})
        self.assertEqual(cat.english_texts(), {"Live"})
        self.assertEqual(cat.translatable(), ["a.live"])

    def test_the_translations_do_not_count(self):
        cat = self.make({"player.play": {"localizations": {"en": string_unit("Play"), "es": string_unit("Reproducir")}}})
        self.assertEqual(cat.english_bytes(), 4)

    def test_substitution_forms_are_walked_with_their_paths(self):
        cat = self.make({"%lld and %lld": {"localizations": {"en": {
            **string_unit("%#@books@ and %#@pages@"),
            "substitutions": {"books": {"argNum": 1, "formatSpecifier": "lld", **plural(one="%arg book", other="%arg books")}}}}}})
        paths = [unit.path for unit in cat.units("%lld and %lld", "en")]
        self.assertEqual(paths, ["", "substitutions.books.plural.one", "substitutions.books.plural.other"])
        self.assertIn("%arg book", cat.english_texts())


class StateTests(unittest.TestCase):
    """What counts as a finished translation, and a string's status."""

    def make(self, localization):
        """A one-string catalog with Spanish `localization`."""
        data = {"sourceLanguage": "en", "version": "1.0", "strings": {"K": {"localizations": {"es": localization}} if localization else {}}}
        return catalog.Catalog(data)

    def test_translated_and_machine_translated_with_a_value_are_done(self):
        for state in ("translated", "machine_translated"):
            self.assertTrue(catalog.unit_done(catalog.Unit("", None, state, "Hola")), state)

    def test_the_other_states_and_an_empty_value_are_not_done(self):
        for state in ("new", "needs_review", "stale", "unknown"):
            self.assertFalse(catalog.unit_done(catalog.Unit("", None, state, "Hola")), state)
        self.assertFalse(catalog.unit_done(catalog.Unit("", None, "translated", "")))
        self.assertFalse(catalog.unit_done(catalog.Unit("", None, "translated", "  ")))

    def test_status_of_each_state(self):
        for state in ("translated", "machine_translated", "new", "needs_review", "stale"):
            self.assertEqual(self.make(string_unit("Hola", state)).status("K", "es"), state)

    def test_a_string_with_no_localization_is_missing(self):
        self.assertEqual(self.make(None).status("K", "es"), "missing")
        self.assertEqual(self.make(string_unit("Hola")).status("K", "fr"), "missing")

    def test_a_translated_state_with_an_empty_value_is_new(self):
        self.assertEqual(self.make(string_unit("", "translated")).status("K", "es"), "new")

    def test_a_plural_string_has_the_status_of_its_worst_form(self):
        cat = self.make({"variations": {"plural": {"one": string_unit("uno", "machine_translated"),
                                                   "other": string_unit("otros", "translated")}}})
        self.assertEqual(cat.status("K", "es"), "machine_translated")
        self.assertTrue(cat.done("K", "es"))
        cat = self.make({"variations": {"plural": {"one": string_unit("uno"), "other": string_unit("otros", "needs_review")}}})
        self.assertEqual(cat.status("K", "es"), "needs_review")
        self.assertFalse(cat.done("K", "es"))

    def test_the_languages_of_a_catalog_leave_out_its_source_language(self):
        cat = catalog.Catalog.load(FIXTURES / "plural-and-device-by-xcstringstool.xcstrings")
        self.assertEqual(cat.languages(), ["es"])


if __name__ == "__main__":
    unittest.main()
