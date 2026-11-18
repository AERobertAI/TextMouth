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

    def test_spanish_has_the_first_terms_and_each_term_has_a_spanish_text(self):
        self.assertGreaterEqual(len(self.glossary.terms), MINIMUM_TERMS)
        for term in self.glossary.terms:
            self.assertIn("es", term["translations"], term["term"])

    def test_a_translation_of_a_term_uses_the_term(self):
        """A term's own Spanish text must pass the check that warns about translations not using it (a typo in `match`)."""
        for term in self.glossary.terms:
            entry = term["translations"]["es"]
            self.assertEqual(self.glossary.unused_terms(term["term"], entry["text"], "es"), [], term["term"])

    def test_the_terms_a_native_speaker_should_look_at_are_marked(self):
        marked = [term["term"] for term in self.glossary.terms if term["translations"]["es"].get("check")]
        self.assertTrue(marked, "the seed holds words that are not certain")
        self.assertLess(len(marked), len(self.glossary.terms), "not every term is in doubt")

    def test_the_word_a_term_is_for_is_found_in_a_sentence_that_uses_it(self):
        found = self.glossary.terms_in("Add a bookmark to the Reading List", "es")
        self.assertEqual({item["term"] for item in found}, {"Add", "Bookmark", "Reading List", "Reading"})


if __name__ == "__main__":
    unittest.main()
