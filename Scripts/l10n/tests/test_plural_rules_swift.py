"""Keeps the plural categories of the app's `PluralRules.swift` equal to the catalog tool's table (TL18).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

The Swift test checks Apple's plural rule against `PluralRules.categories`; this test checks that
table against `catalog.PLURAL_CATEGORIES`, so the two cannot drift apart.
"""
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)

SWIFT = HERE.parent.parent.parent / "TextMouth" / "Localization" / "InterfaceText" / "PluralRules.swift"
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

    def test_the_table_names_every_language_the_catalog_holds(self):
        """Every language of the String Catalog, English included, has its rule in the Swift table; the table may run
        ahead of the catalog by the languages being translated (a wave's rules go in before its strings)."""
        import json
        path = HERE.parent.parent.parent / "TextMouth" / "Localization" / "Localizable.xcstrings"
        strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
        languages = {"en"} | {language for entry in strings.values() for language in entry.get("localizations", {})}
        self.assertEqual(sorted(languages - set(self.swift_table())), [])


if __name__ == "__main__":
    unittest.main()
