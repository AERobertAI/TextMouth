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

    def test_a_name_with_a_japanese_chinese_or_korean_particle_against_it_is_kept(self):
        """Those scripts write the next word or particle straight against a name; a Latin or Cyrillic letter still joins."""
        glossary_ = make()
        english = "TextMouth reads EPUB with VoiceOver"
        for translation in ("TextMouthはVoiceOverでEPUBを読みます", "TextMouth가 VoiceOver로 EPUB를 읽습니다",
                            "TextMouth通过VoiceOver读取EPUB", "ｔ：TextMouthは、VoiceOverとEPUB。"):
            self.assertEqual(glossary_.missing_names(english, translation), [], translation)
        self.assertEqual(glossary_.missing_names(english, "TextMouthy читает EPUBа с VoiceOver"), ["TextMouth", "EPUB"])
        self.assertEqual(glossary_.names_in("この TextMouthの本とEPUBファイル"), ["TextMouth", "EPUB"])
        self.assertEqual(glossary_.names_in("MyTextMouth와 EPUBs"), ["EPUB"], "a Latin letter before a name still joins")

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

    def test_a_match_list_and_slash_alternatives_say_what_counts_as_using_a_term(self):
        glossary_ = glossary.Glossary([], [
            {"term": "Play", "translations": {"es": {"text": "Reproducir", "match": ["reproduc"]}}},
            {"term": "Export", "translations": {"es": {"text": "Exportar / exportación"}}}])
        self.assertEqual(glossary_.unused_terms("Plays the book", "Reproduce el libro", "es"), [])
        self.assertEqual(glossary_.unused_terms("Plays the book", "Lee el libro", "es"), ["Reproducir"])
        self.assertEqual(glossary_.unused_terms("Export", "La exportación", "es"), [])
        self.assertEqual(glossary_.unused_terms("Export", "Sacar", "es"), ["Exportar / exportación"])


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
            "a match that is not a list of text": {"terms": [{"term": "A", "translations": {"es": {"text": "B", "match": "b"}}}]},
            "translations that are not an object": {"terms": [{"term": "A", "translations": ["es"]}]},
        }
        for label, data in cases.items():
            with self.subTest(label):
                with self.assertRaises(glossary.GlossaryError):
                    glossary.Glossary.load(self.write(data))


class OrdinaryWordTests(unittest.TestCase):
    """A term that is also an everyday word is found only as a whole label or a title-case phrase; a name hides what is in it."""

    def terms(self, text):
        """The terms found in `text`, with Close and Open ordinary and Window and Library not."""
        glossary_ = glossary.Glossary(["Windows", "TextMouth"], [
            {"term": "Close", "ordinary": True, "translations": {"es": {"text": "Cerrar"}}},
            {"term": "Open", "ordinary": True, "translations": {"es": {"text": "Abrir"}}},
            {"term": "Done", "ordinary": True, "translations": {"es": {"text": "Hecho"}}},
            {"term": "Window", "translations": {"es": {"text": "Ventana"}}},
            {"term": "Library", "translations": {"es": {"text": "Biblioteca"}}}])
        return [item["term"] for item in glossary_.terms_in(text, "es")]

    def test_close_to_the_end_is_not_a_use_of_close(self):
        for text in ("close to the end", "Close to the end", "Open the book", "I am done", "Almost done reading"):
            self.assertEqual(self.terms(text), [], text)

    def test_a_whole_label_is_a_use_in_any_case_with_an_ellipsis_or_a_colon(self):
        for text in ("Close", "close", "Open...", "Open\u2026", "Done:", "Open?"):
            self.assertEqual(len(self.terms(text)), 1, text)

    def test_a_title_case_phrase_is_a_use(self):
        self.assertEqual(self.terms("Close Window"), ["Close", "Window"])
        self.assertEqual(self.terms("Open %@ in TextMouth"), ["Open"])
        self.assertEqual(self.terms("Open Without the Library"), ["Open", "Library"], "small words stay in lower case")

    def test_a_noun_is_found_in_a_sentence(self):
        self.assertEqual(self.terms("Your library has a window"), ["Window", "Library"])

    def test_a_term_is_never_found_inside_a_do_not_translate_name(self):
        self.assertEqual(self.terms("Windows-1252 (Western)"), [], "the name Windows, not the term Window")
        self.assertEqual(self.terms("Close Windows-1252"), ["Close"])
        self.assertEqual(self.terms("Window"), ["Window"], "the term alone is still the term")

    def test_masking_is_the_same_as_masking_each_name_in_turn_and_is_kept(self):
        """mask_names passes over a name the text lacks and remembers each answer (`check` masks one English once for each
        term it looks for); the text it gives is the one masking every name in turn gives."""
        glossary_ = glossary.Glossary(["TextMouth", "Windows", "EPUBs", "EPUB"], [])
        for text in ("Open EPUBs in TextMouth", "Windows-1252 (Western) EPUB", "textmouth", "", "EPUBEPUB TextMouths"):
            expected = text
            for name in glossary_.names:
                expected = glossary._word_pattern(name).sub(" ", expected)
            self.assertEqual(glossary_.mask_names(text), expected, text)
            self.assertIs(glossary_.mask_names(text), glossary_.mask_names(text), "the answer is kept")

    def test_title_case_and_whole_labels(self):
        self.assertTrue(glossary.is_title_case("Open Recent"))
        self.assertTrue(glossary.is_title_case("Open %lld in TextMouth"))
        self.assertFalse(glossary.is_title_case("Open the book"))
        self.assertFalse(glossary.is_title_case("%lld"), "nothing to judge")
        self.assertTrue(glossary.is_whole_label(" Close... ", "Close"))
        self.assertFalse(glossary.is_whole_label("Close it", "Close"))

    def test_ordinary_must_be_true_or_false(self):
        bad = glossary.Glossary([], [{"term": "A", "ordinary": "yes", "translations": {"es": {"text": "B"}}}])
        self.assertEqual(bad.problems(), ["the term 'A': `ordinary` must be true or false"])


class SharedTranslationTests(unittest.TestCase):
    """Two terms with one translation are a warning of the glossary."""

    def test_two_terms_that_share_a_translation_are_a_warning(self):
        warnings = make(Index="Índice", **{"Table of Contents": "indice"}).warnings()
        self.assertEqual(warnings, ["in es the terms 'Index' and 'Table of Contents' share the translation 'Índice'"])

    def test_distinct_translations_have_no_warning_and_a_malformed_glossary_is_not_made_valid_by_it(self):
        self.assertEqual(make(Index="Índice de búsqueda", **{"Table of Contents": "Índice"}).warnings(), [])
        self.assertEqual(make(Index="Índice", **{"Table of Contents": "Índice"}).problems(), [], "a warning, not a problem")


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
        self.assertIn("1 warning (the glossary's terms and the number formats; not failures)", out)

    def test_a_number_printed_with_other_digits_is_a_warning_beside_the_packs_own_refusal_of_the_specifier(self):
        # `%.1f` is no specifier the pack allows (FR39), so check also fails; the precision warning is still given.
        cat = self.load()
        cat.strings["%.1f seconds"] = base.entry("A duration", en=base.unit("%.1f seconds"), es=base.unit("%.3f segundos"))
        cat.strings["%.2f minutes"] = base.entry("A duration", en=base.unit("%.2f minutes"), es=base.unit("%.2f minutos"))
        cat.save()
        status, out = self.check()
        self.assertEqual(status, 1, out)
        self.assertIn('check: en "%.1f seconds": the specifier %.1f is not one the pack allows', out)
        self.assertIn("check: warning: es \"%.1f seconds\": placeholder 1 prints 3 digits where the English's prints 1", out)
        self.assertNotIn('"%.2f minutes": placeholder', out)

    def test_an_unfinished_translation_is_not_warned_about(self):
        self.assertNotIn("Pending Library", self.check()[1])

    def test_a_malformed_glossary_is_a_problem(self):
        self.glossary.write_text("{", encoding="utf-8")
        status, out = self.check()
        self.assertEqual(status, 1)
        self.assertIn("glossary.json", out)

    def test_a_translation_that_drops_a_name_is_a_warning(self):
        """`apply` refuses a lost name; a hand edit can still drop one, and `check` says so."""
        cat = self.load()
        cat.strings["Open in TextMouth"] = base.entry("A menu item", en=base.unit("Open in TextMouth"), es=base.unit("Abrir en la aplicación"))
        cat.save()
        self.glossary.write_text(json.dumps({"doNotTranslate": ["TextMouth"], "terms": []}), encoding="utf-8")
        status, out = self.check()
        self.assertEqual(status, 0, out)
        self.assertIn('check: warning: es "Open in TextMouth": drops the name TextMouth, which is never translated', out)

    def test_two_terms_with_one_translation_are_a_warning_of_check(self):
        self.glossary.write_text(json.dumps({"terms": [
            {"term": "Index", "translations": {"es": {"text": "Índice"}}},
            {"term": "Table of Contents", "translations": {"es": {"text": "Índice"}}}]}), encoding="utf-8")
        status, out = self.check()
        self.assertEqual(status, 0, out)
        self.assertIn("share the translation 'Índice'", out)

    def test_the_warnings_are_in_the_json(self):
        _, out = self.check("--json")
        self.assertEqual(len(json.loads(out)["warnings"]), 1)


if __name__ == "__main__":
    unittest.main()
