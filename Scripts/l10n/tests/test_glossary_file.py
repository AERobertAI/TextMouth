"""Tests of the glossary the repository ships (Scripts/l10n/glossary.json): that it is well formed, that every name in it
is one the app's code holds, and that its Spanish terms are consistent.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

These read the glossary file and the app's Swift sources in this checkout; nothing else.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import glossary  # noqa: E402  (imported by path, after sys.path is set)

ROOT = HERE.parents[2]
# The fewest Spanish terms the first seed holds (the brief's "about 60").
MINIMUM_TERMS = 60


class ShippedGlossaryTests(unittest.TestCase):
    """The glossary file the tools read by default."""

    @classmethod
    def setUpClass(cls):
        cls.glossary = glossary.Glossary.load(glossary.GLOSSARY_PATH)
        cls.sources = "\n".join(path.read_text(encoding="utf-8", errors="replace")
                                for path in sorted((ROOT / "TextMouth").rglob("*.swift")))

    def test_the_file_is_well_formed(self):
        self.assertEqual(self.glossary.problems(), [])
        self.assertTrue(self.glossary.names and self.glossary.terms)

    def test_every_name_is_one_the_apps_code_holds(self):
        absent = [name for name in self.glossary.names if name not in self.sources]
        self.assertEqual(absent, [], "a name nobody uses has no place in the list")

    def test_a_name_is_listed_once_and_is_not_also_a_term(self):
        self.assertEqual(len(self.glossary.names), len(set(self.glossary.names)))
        terms = {term["term"] for term in self.glossary.terms}
        self.assertEqual(sorted(terms & set(self.glossary.names)), [])

    def test_spanish_has_the_first_terms_and_each_term_has_a_translation(self):
        """The seed terms (the first MINIMUM_TERMS) each have Spanish; a term a later language's pass added (FR36) may cover
        only the languages that needed it, but never none."""
        self.assertGreaterEqual(len(self.glossary.terms), MINIMUM_TERMS)
        for term in self.glossary.terms[:MINIMUM_TERMS]:
            self.assertIn("es", term["translations"], term["term"])
        for term in self.glossary.terms:
            self.assertTrue(term["translations"], term["term"])

    def test_a_translation_of_a_term_uses_the_term(self):
        """A term's own text, in each language it has, must pass the check that warns about translations not using it (a
        typo in `match`)."""
        for term in self.glossary.terms:
            for language, entry in term["translations"].items():
                with self.subTest(term=term["term"], language=language):
                    self.assertEqual(self.glossary.unused_terms(term["term"], entry["text"], language), [])

    def test_the_terms_a_native_speaker_should_look_at_are_marked(self):
        marked = [term["term"] for term in self.glossary.terms if term["translations"].get("es", {}).get("check")]
        self.assertTrue(marked, "the seed holds words that are not certain")
        self.assertLess(len(marked), len(self.glossary.terms), "not every term is in doubt")

    def test_the_word_a_term_is_for_is_found_in_a_sentence_that_uses_it(self):
        found = self.glossary.terms_in("Your bookmark in the Reading List", "es")
        self.assertEqual({item["term"] for item in found}, {"Bookmark", "Reading List", "Reading"})

    def test_an_everyday_command_word_is_found_as_a_label_and_not_in_a_sentence(self):
        for text in ("Close", "Open...", "Done", "Play", "Close Window"):
            self.assertTrue(any(item["term"] in ("Close", "Open", "Done", "Play") for item in self.glossary.terms_in(text, "es")), text)
        for text in ("close to the end", "Open the book", "I am done", "Play it again"):
            found = [item["term"] for item in self.glossary.terms_in(text, "es")]
            self.assertEqual([term for term in found if term in ("Close", "Open", "Done", "Play")], [], text)
        # A noun in the same sentence is still found: only the everyday command words are held back.
        self.assertEqual([item["term"] for item in self.glossary.terms_in("Open the book", "es")], ["Book"])

    def test_the_encodings_windows_name_does_not_find_window(self):
        for name in ("Windows-1252 (Western)", "Windows-1250 (Central European)", "Windows-1251"):
            self.assertNotIn("Window", [item["term"] for item in self.glossary.terms_in(name, "es")], name)

    def test_index_is_the_search_index_and_no_two_terms_share_a_translation(self):
        index = next(term for term in self.glossary.terms if term["term"] == "Index")["translations"]["es"]
        self.assertEqual(index["text"], "Índice de búsqueda")
        self.assertTrue(index.get("check"))
        self.assertEqual(self.glossary.warnings(), [])

    def test_the_terms_whose_apple_spanish_is_not_confirmed_stay_marked_with_what_the_review_believes(self):
        entries = {term["term"]: term["translations"]["es"] for term in self.glossary.terms if "es" in term["translations"]}
        self.assertTrue(entries["Settings"]["check"])
        self.assertIn("Configuración del Sistema", entries["Settings"]["note"])
        self.assertTrue(entries["Keyboard Shortcut"]["check"])
        self.assertIn("Funciones rápidas de teclado", entries["Keyboard Shortcut"]["note"])
        self.assertEqual((entries["Settings"]["text"], entries["Keyboard Shortcut"]["text"]), ("Ajustes", "Atajo de teclado"),
                         "no Apple term that cannot be confirmed is decided")


if __name__ == "__main__":
    unittest.main()
