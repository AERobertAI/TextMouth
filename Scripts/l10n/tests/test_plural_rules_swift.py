"""Keeps the plural categories of `LanguagePackTests.swift` equal to the catalog tool's table (TL18).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The Swift test checks Apple's plural rule against `LanguagePackPluralRules.categories`; this test checks that
table against `catalog.PLURAL_CATEGORIES`, so the two cannot drift apart.
"""
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)

SWIFT = HERE.parent.parent.parent / "TextMouthProductionTests" / "LanguagePackTests.swift"
# One language to a line: `"pt-BR": ["one", "many", "other"],`.
LINE = re.compile(r'^\s*"([A-Za-z-]+)": \[((?:"[a-z]+"(?:, )?)+)\],$')


class PluralRulesSwiftTests(unittest.TestCase):
    """The Swift table of plural categories."""

    def swift_table(self):
        """{language: [categories]} from the lines of the `categories` literal in the Swift file."""
        text = SWIFT.read_text(encoding="utf-8")
        start = text.index("static let categories: [String: [String]] = [")
        end = text.index("\n    ]\n", start)
        table = {}
        for line in text[start:end].splitlines()[1:]:
            match = LINE.match(line)
            self.assertIsNotNone(match, f"not a language line: {line!r}")
            table[match.group(1)] = re.findall(r'"([a-z]+)"', match.group(2))
        return table

    def test_the_swift_table_equals_the_catalog_tools(self):
        table = self.swift_table()
        for language, categories in table.items():
            self.assertEqual(categories, list(catalog.plural_categories(language)), language)

    def test_the_table_names_the_eleven_languages(self):
        self.assertEqual(
            sorted(self.swift_table()),
            sorted(["en", "es", "it", "fr", "pt-BR", "de", "ru", "uk", "zh-Hans", "ja", "ko"]),
        )


if __name__ == "__main__":
    unittest.main()
