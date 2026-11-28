"""Tests that the translators' tools read a string's English from its `en` localization, never from its key (FR39 phase 7).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every catalog here is keyed by IDs whose text is nothing like the English, so a tool that still read the key as text would
fail. Each test works on a catalog it makes in a temporary folder and builds nothing.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import glossary as glossarylib  # noqa: E402
import l10n  # noqa: E402
import pack  # noqa: E402
import translate  # noqa: E402
import test_l10n as base  # noqa: E402  (its helpers: TemporaryCase, entry, unit, plural, make_catalog)

unit, plural, entry = base.unit, base.plural, base.entry

# The IDs of the fixtures: none of them is, or contains, an English text.
BOOKS, TITLE, TIMES = "library.bookCount", "library.title", "player.timesSeen"


def fixture():
    """A catalog keyed by ID: a plural with English forms and a Spanish translation, a plain string, and a string whose only
    English unit is Xcode's positional `new` one (nothing ships from it)."""
    return base.make_catalog({
        BOOKS: entry(en=plural(one=unit("%lld book"), other=unit("%lld books")),
                     es=plural(one=unit("%lld libro"), other=unit("%lld libros"))),
        TITLE: entry(en=unit("Library"), es=unit("Biblioteca")),
        TIMES: entry(en=unit("%1$@ %2$@", state="new")),
    })


class EnglishUnitsTests(unittest.TestCase):
    """`Catalog.english_units` and `english_forms`: what counts as the English of an entry."""

    def test_the_english_is_the_en_text_not_the_id(self):
        self.assertEqual(fixture().english_forms(TITLE), ["Library"])

    def test_plural_english_is_each_form(self):
        self.assertEqual(sorted(fixture().english_forms(BOOKS)), ["%lld book", "%lld books"])

    def test_a_unit_in_state_new_is_no_english(self):
        cat = fixture()
        self.assertEqual(cat.english_units(TIMES), [])
        # The same rule the pack follows: the unit compiles to nothing.
        problems = []
        self.assertIsNone(pack.compile_localization(cat.strings[TIMES]["localizations"]["en"], "en", "x", problems))
        self.assertEqual(problems, [])

    def test_the_key_is_never_the_english(self):
        cat = fixture()
        self.assertEqual(cat.english_forms(TIMES), [])
        self.assertEqual(translate.english_shape(cat, TIMES)[0], "other")

    def test_english_bytes_count_en_texts(self):
        cat = base.make_catalog({TITLE: entry(en=unit("Library"))})
        self.assertEqual(cat.english_bytes(), len("Library"))


class TranslateReadsEnTests(unittest.TestCase):
    """translate.py's helpers read `en`."""

    def test_english_shape_plain_and_plural(self):
        cat = fixture()
        self.assertEqual(translate.english_shape(cat, TITLE), ("plain", "Library"))
        self.assertEqual(translate.english_shape(cat, BOOKS), ("plural", {"one": "%lld book", "other": "%lld books"}))

    def test_english_form_falls_back_to_other(self):
        cat = fixture()
        self.assertEqual(translate.english_form(cat, BOOKS, "one"), "%lld book")
        self.assertEqual(translate.english_form(cat, BOOKS, "many"), "%lld books")

    def test_reference_of_is_other_for_a_plural(self):
        self.assertEqual(translate.reference_of(translate.english_values(fixture(), BOOKS)), "%lld books")

    def test_unit_placeholder_problems_compare_with_the_english(self):
        cat = fixture()
        english = translate.english_values(cat, BOOKS)
        reference = translate.reference_of(english)
        good = catalog.Unit("plural.other", "other", "translated", "%lld libros")
        bad = catalog.Unit("plural.other", "other", "translated", "libros")
        self.assertEqual(translate.unit_placeholder_problems(english, reference, good, "es"), [])
        self.assertTrue(translate.unit_placeholder_problems(english, reference, bad, "es"))

    def test_a_plural_needs_a_number_in_the_english(self):
        cat = base.make_catalog({"a.b": entry(en=unit("Library"))})
        problems = translate.plural_problems(cat, "a.b", "en", {"one": "Library", "other": "Libraries"})
        self.assertTrue(any("number placeholder" in sentence for sentence in problems))


class CommandsReadEnTests(base.TemporaryCase):
    """The commands on a catalog keyed by ID."""

    def test_check_compares_placeholders_with_the_english(self):
        cat = fixture()
        # A Spanish form that lost the number: a problem measured against the English, not against the ID.
        cat.strings[BOOKS]["localizations"]["es"] = plural(one=unit("un libro"), other=unit("libros"))
        problems, _note = l10n.check_catalog(cat, {"languages": ["es"], "budgetBytes": 1000, "budgetFails": False})
        self.assertTrue(any(BOOKS in sentence and "placeholder" in sentence for sentence in problems), problems)

    def test_todo_batch_item_has_the_id_beside_its_english(self):
        cat = base.make_catalog({TITLE: entry(en=unit("Library"))})
        batch = translate.build_batch(cat, "es", glossarylib.Glossary(), {}, self.folder)
        item = batch["items"][0]
        self.assertEqual((item["key"], item["english"]), (TITLE, "Library"))

    def test_todo_finds_the_glossary_terms_in_the_english(self):
        cat = base.make_catalog({TITLE: entry(en=unit("Library"))})
        glossary = glossarylib.Glossary(terms=[{"term": "Library", "translations": {"es": {"text": "Biblioteca"}}}])
        batch = translate.build_batch(cat, "es", glossary, {}, self.folder)
        self.assertEqual([term["term"] for term in batch["items"][0]["glossary"]], ["Library"])

    def test_apply_takes_a_batch_keyed_by_id(self):
        cat = base.make_catalog({TITLE: entry(en=unit("Library"))})
        batch = {"language": "es", "items": [{"key": TITLE, "english": "Library", "translation": "Biblioteca"}]}
        result = translate.apply_batch(cat, batch, glossarylib.Glossary())
        self.assertEqual(result.written, [TITLE])
        self.assertEqual([u.value for u in cat.units(TITLE, "es")], ["Biblioteca"])

    def test_apply_refuses_a_batch_whose_english_is_old(self):
        cat = base.make_catalog({TITLE: entry(en=unit("Library"))})
        batch = {"language": "es", "items": [{"key": TITLE, "english": "The library", "translation": "Biblioteca"}]}
        result = translate.apply_batch(cat, batch, glossarylib.Glossary())
        self.assertEqual(result.written, [])
        self.assertIn("English changed", result.rejected[0]["problems"][0])

    def test_plural_takes_an_id(self):
        cat = base.make_catalog({BOOKS: entry(en=unit("%lld books"))})
        translate.write_plural(cat, BOOKS, "en", {"one": "%lld book", "other": "%lld books"})
        self.assertEqual(sorted(cat.english_forms(BOOKS)), ["%lld book", "%lld books"])

    def test_plural_refuses_forms_that_differ_from_the_english_placeholders(self):
        cat = base.make_catalog({BOOKS: entry(en=unit("%lld books"))})
        with self.assertRaises(translate.Problems):
            translate.write_plural(cat, BOOKS, "en", {"one": "a book", "other": "%@ books"})

    def test_the_similar_stale_string_is_found_by_its_english(self):
        cat = base.make_catalog({
            "old.title": entry(en=unit("Open the library"), es=unit("Abrir la biblioteca")),
            "new.title": entry(en=unit("Open the libraries")),
        })
        cat.strings["old.title"]["extractionState"] = "stale"
        batch = translate.build_batch(cat, "es", glossarylib.Glossary(), {}, self.folder)
        previous = batch["items"][0].get("previous")
        self.assertEqual(previous["key"], "old.title")
        self.assertEqual(previous["english"], "Open the library")


if __name__ == "__main__":
    unittest.main()
