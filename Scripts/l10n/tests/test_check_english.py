"""Tests of the rules `l10n.py check` keeps about a catalog keyed by ID and the code that holds its English (FR39 phase 7).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every catalog and every "code" here is made in memory; nothing reads the repository's own files.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402
import sync  # noqa: E402

CONFIG = {"languages": [], "budgetBytes": 150000, "budgetFails": False}


def unit(value, state="translated"):
    """A stringUnit localization."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    """Plural variations."""
    return {"variations": {"plural": {name: unit(text) for name, text in forms.items()}}}


def entry(**localizations):
    """A live entry (extractionState manual) with a comment and these localizations."""
    return {"comment": "A note.", "extractionState": "manual", "localizations": localizations}


def problems_of(strings, found=None):
    """The problems `check_catalog` finds in a catalog of `strings`, given the code's `found` ({ID: English})."""
    cat = catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings})
    code = None if found is None else {identifier: sync.Found(english, {"A note."}) for identifier, english in found.items()}
    return l10n.check_catalog(cat, CONFIG, code)[0]


class EnglishRuleTests(unittest.TestCase):
    """The rules about `en` that need no code."""

    def test_a_clean_catalog_has_no_problem(self):
        self.assertEqual(problems_of({"a.b": entry(en=unit("Hello %@."), es=unit("Hola %@."))}), [])

    def test_an_entry_with_no_english_is_a_problem(self):
        found = problems_of({"a.b": entry(es=unit("Hola"))})
        self.assertEqual(len(found), 1)
        self.assertIn("no English text", found[0])
        self.assertIn('"a.b"', found[0])

    def test_an_english_unit_in_state_new_is_no_english(self):
        self.assertTrue(any("no English" in p for p in problems_of({"a.b": entry(en=unit("Hello", "new"))})))

    def test_a_specifier_the_pack_does_not_allow_is_a_problem_in_english_and_in_a_translation(self):
        found = problems_of({"a.b": entry(en=unit("Hello %d"), es=unit("Hola %.1f"))})
        self.assertTrue(any(p.startswith('en "a.b"') and "not one the pack allows" in p for p in found), found)
        self.assertTrue(any(p.startswith('es "a.b"') and "%.1f" in p for p in found), found)

    def test_the_five_specifiers_are_allowed(self):
        for english in ("%@ and %lld and 100%%", "%2$@ then %1$lld"):
            self.assertEqual(problems_of({"a.b": entry(en=unit(english))}), [], english)

    def test_a_translation_with_plural_forms_where_the_english_has_none_is_a_problem(self):
        found = problems_of({"a.b": entry(en=unit("%lld books"), es=plural(one="%lld libro", many="%lld de libros", other="%lld libros"))})
        self.assertEqual(len(found), 1)
        self.assertIn("the translation has plural forms and the English has none", found[0])

    def test_english_plural_forms_with_translated_plural_forms_are_fine(self):
        found = problems_of({"a.b": entry(en=plural(one="%lld book", other="%lld books"),
                                          es=plural(one="%lld libro", many="%lld de libros", other="%lld libros"))})
        self.assertEqual(found, [])


class CodeRuleTests(unittest.TestCase):
    """The rules that compare the catalog with the code's calls."""

    def test_a_catalog_in_step_with_the_code_has_no_problem(self):
        strings = {"a.b": entry(en=unit("Hello")), "a.c": entry(en=plural(one="%lld book", other="%lld books"))}
        self.assertEqual(problems_of(strings, {"a.b": "Hello", "a.c": "%lld books"}), [])

    def test_an_en_that_differs_from_the_code_is_a_problem_naming_both(self):
        found = problems_of({"a.b": entry(en=unit("Hello"))}, {"a.b": "Hello there"})
        self.assertEqual(len(found), 1)
        self.assertIn('"Hello"', found[0])
        self.assertIn('"Hello there"', found[0])

    def test_a_difference_of_one_character_or_space_is_a_problem(self):
        self.assertTrue(problems_of({"a.b": entry(en=unit("Hello"))}, {"a.b": "Hello."}))
        self.assertTrue(problems_of({"a.b": entry(en=unit("Hello "))}, {"a.b": "Hello"}))

    def test_an_english_plurals_other_form_must_equal_the_codes_english(self):
        strings = {"a.b": entry(en=plural(one="%lld book", other="%lld books"))}
        self.assertEqual(problems_of(strings, {"a.b": "%lld books"}), [])
        self.assertTrue(problems_of(strings, {"a.b": "%lld book"}))

    def test_an_id_the_code_calls_that_the_catalog_lacks_is_a_problem(self):
        found = problems_of({}, {"a.b": "Hello"})
        self.assertEqual(len(found), 1)
        self.assertIn("the catalog does not hold it", found[0])

    def test_an_id_with_no_call_that_is_not_stale_is_a_problem_and_a_stale_one_only_the_stale_problem(self):
        live = problems_of({"a.b": entry(en=unit("Hello"))}, {})
        self.assertTrue(any("no call in the code has this ID" in p for p in live), live)
        stale = {"a.b": {**entry(en=unit("Hello")), "extractionState": "stale"}}
        problems = problems_of(stale, {})
        self.assertFalse(any("no call" in p for p in problems), problems)
        self.assertTrue(any("stale" in p for p in problems))

    def test_without_the_code_the_catalog_is_checked_on_its_own(self):
        self.assertEqual(problems_of({"a.b": entry(en=unit("Hello"))}), [])

    def test_a_sync_then_a_check_agree_after_the_english_changed(self):
        cat = catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": {
            "a.b": entry(en=plural(one="%lld book", other="%lld books"),
                         es=plural(one="%lld libro", many="%lld de libros", other="%lld libros"))}})
        found = {"a.b": sync.Found("%lld shelved books", {"A note."})}
        sync.sync_catalog(cat, found)
        problems = l10n.check_catalog(cat, CONFIG, found)[0]
        # Check fails until `plural` writes the English forms again: the Spanish forms have no English forms beside them.
        self.assertTrue(any("the translation has plural forms and the English has none" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
