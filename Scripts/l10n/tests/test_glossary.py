"""Tests of Scripts/l10n/glossary.py: loading and checking the glossary, finding its names and terms in a text, and the
`check` command's warnings about a translation that does not use a term.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test uses glossaries it writes in a temporary folder; the repository's own glossary is tested in test_glossary_file.py.
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import glossary  # noqa: E402  (imported by path, after sys.path is set)
import test_l10n as base  # noqa: E402  (its helpers: entry, unit)
import test_translate as shared  # noqa: E402  (its CatalogCase and run)


def make(names=("TextMouth", "VoiceOver", "EPUB"), **terms):
    """A Glossary with `names` and the Spanish `terms` ({English term: Spanish text})."""
    return glossary.Glossary(names, [{"term": term, "translations": {"es": {"text": text}}} for term, text in terms.items()])


class MatchingTests(unittest.TestCase):
    """Finding the glossary's names and terms in a text."""

    def test_a_name_is_found_as_a_word_with_its_case_and_a_plural_s(self):
        glossary_ = make()
        self.assertEqual(glossary_.names_in("Open the EPUBs in TextMouth's library"), ["TextMouth", "EPUB"])
        self.assertEqual(glossary_.names_in("textmouth and VoiceOverX and MyEPUB"), [], "case counts, and so do word edges")

    def test_the_names_a_translation_lost_are_listed(self):
        glossary_ = make()
        self.assertEqual(glossary_.missing_names("Use VoiceOver in TextMouth", "Usa VoiceOver en la aplicación"), ["TextMouth"])
        self.assertEqual(glossary_.missing_names("Use VoiceOver", "Usa VoiceOver"), [])

    def test_a_text_of_names_numbers_and_placeholders_has_nothing_to_translate(self):
        glossary_ = make()
        for text in ("TextMouth", "%lld", "%1$@ %2$lld", "EPUB 3", "…", "TextMouth 2.0", "%@ / %@"):
            self.assertTrue(glossary_.nothing_to_translate(text), text)
        for text in ("Play", "Open TextMouth", "%lld books"):
            self.assertFalse(glossary_.nothing_to_translate(text), text)

    def test_a_term_is_found_in_any_case_with_a_plural_s_and_only_as_a_word(self):
        glossary_ = make(Bookmark="Marcador", Voice="Voz")
        self.assertEqual([item["term"] for item in glossary_.terms_in("Your BOOKMARKS and a Voice", "es")], ["Bookmark", "Voice"])
        self.assertEqual(glossary_.terms_in("VoiceOver, bookmarked, Audiobook", "es"), [], "a part of a longer word is not the term")

    def test_a_term_without_a_translation_in_the_language_is_left_out(self):
        self.assertEqual(make(Voice="Voz").terms_in("A voice", "fr"), [])

    def test_a_region_uses_the_terms_of_its_language(self):
        self.assertEqual(make(Voice="Voz").terms_in("A voice", "es-419")[0]["translation"], "Voz")

    def test_the_note_and_the_check_flag_come_with_the_term(self):
        glossary_ = glossary.Glossary([], [{"term": "Feed", "note": "A podcast feed", "translations": {
            "es": {"text": "Canal", "note": "Apple uses Canal", "check": True}}}])
        self.assertEqual(glossary_.terms_in("Feed", "es"), [{"term": "Feed", "translation": "Canal",
                                                             "note": "A podcast feed Apple uses Canal", "check": True}])

    def test_a_translation_uses_a_term_when_it_holds_the_text_ignoring_case_accents_and_inflection(self):
        glossary_ = make(Bookmark="Marcador", Index="Índice")
        self.assertEqual(glossary_.unused_terms("Bookmarks", "Mis marcadores", "es"), [])
        self.assertEqual(glossary_.unused_terms("Index", "indice general", "es"), [])
        self.assertEqual(glossary_.unused_terms("Bookmark and Index", "Favorito e Índice", "es"), ["Marcador"])


class LoadingTests(shared.CatalogCase):
    """Reading the glossary file."""

    def write(self, data, name="glossary.json"):
        """Writes `data` as a glossary file in the temporary folder; returns its path."""
        path = self.folder / name
        path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
        return path

    def test_a_missing_file_is_an_empty_glossary(self):
        loaded = glossary.Glossary.load(self.folder / "absent.json")
        self.assertEqual((loaded.names, loaded.terms), ([], []))

    def test_a_good_file_is_loaded(self):
        loaded = glossary.Glossary.load(self.write({"doNotTranslate": ["A"], "terms": [{"term": "B", "translations": {"es": {"text": "C"}}}]}))
        self.assertEqual(loaded.names, ["A"])
        self.assertEqual(loaded.terms[0]["term"], "B")

    def test_a_file_that_is_not_json_is_an_error_naming_the_file(self):
        with self.assertRaisesRegex(glossary.GlossaryError, "glossary.json"):
            glossary.Glossary.load(self.write("{"))

    def test_each_malformation_is_reported(self):
        cases = {
            "a name that is not text": {"doNotTranslate": [""]},
            "a term without text": {"terms": [{"translations": {}}]},
            "a term listed twice": {"terms": [{"term": "A"}, {"term": "A"}]},
            "a translation without its text": {"terms": [{"term": "A", "translations": {"es": {"check": True}}}]},
            "a check that is not true or false": {"terms": [{"term": "A", "translations": {"es": {"text": "B", "check": "yes"}}}]},
            "translations that are not an object": {"terms": [{"term": "A", "translations": ["es"]}]},
        }
        for label, data in cases.items():
            with self.subTest(label):
                with self.assertRaises(glossary.GlossaryError):
                    glossary.Glossary.load(self.write(data))


class CheckWarningTests(shared.CatalogCase):
    """`check` warns when a translation does not use the glossary's term, and fails on a malformed glossary."""

    def setUp(self):
        super().setUp()
        self.make({"Open the Library": base.entry("A menu item", es=base.unit("Abrir la lista")),
                   "Close the Library": base.entry("A menu item", es=base.unit("Cerrar la Biblioteca")),
                   "Pending Library": base.entry("A menu item", es=base.unit("Biblioteca pendiente", "new"))})
        self.glossary = self.folder / "glossary.json"
        self.glossary.write_text(json.dumps({"terms": [{"term": "Library", "translations": {"es": {"text": "Biblioteca"}}}]}),
                                 encoding="utf-8")
        self.config = self.folder / "config.json"
        self.config.write_text(json.dumps({"languages": []}), encoding="utf-8")

    def check(self, *extra):
        """Runs `check` on the fixtures; returns (status, standard output)."""
        status, out, _ = shared.run("check", "--catalog", str(self.path), "--config", str(self.config),
                                    "--glossary", str(self.glossary), *extra)
        return status, out

    def test_a_translation_that_does_not_use_the_term_is_a_warning_and_not_a_failure(self):
        status, out = self.check()
        self.assertEqual(status, 0, out)
        self.assertIn('check: warning: es "Open the Library": does not use the glossary\'s "Biblioteca"', out)
        self.assertNotIn("Close the Library\": does not use", out)
        self.assertIn("1 warning (the glossary's terms; not failures)", out)

    def test_an_unfinished_translation_is_not_warned_about(self):
        self.assertNotIn("Pending Library", self.check()[1])

    def test_a_malformed_glossary_is_a_problem(self):
        self.glossary.write_text("{", encoding="utf-8")
        status, out = self.check()
        self.assertEqual(status, 1)
        self.assertIn("glossary.json", out)

    def test_the_warnings_are_in_the_json(self):
        _, out = self.check("--json")
        self.assertEqual(len(json.loads(out)["warnings"]), 1)


if __name__ == "__main__":
    unittest.main()
