"""The lint's rules for `InterfaceText.line` calls (FR39 phase 5): the English of a call counts as localized, its note is held to
the rule of `String(localized:)`, its ID must be a literal in the pattern and not retired (nothing reads ids.json any more), and
a tree with no converted file counts what it counted before. Every test builds a tree of its own."""

from __future__ import annotations

import unittest

from scan_case import TreeCase, VIEW, WORDING, scan_snippet

import ids  # noqa: E402

# A wording file whose one call is right.
GOOD = '''enum PauseWording {
    // Translators: The title of the pause panel.
    static var title: String { InterfaceText.line("pause.title", "Pause the speech") }
}
'''
FILE = "TextMouth/Models/PauseWording.swift"


class CountingTests(unittest.TestCase):
    """The English of a call is localized, its ID and language are not text to translate."""

    def test_the_english_of_a_call_is_localized(self) -> None:
        found = scan_snippet(GOOD, WORDING)
        english = [lit for lit in found if lit.text == "Pause the speech"][0]
        self.assertEqual((english.rule, english.status, english.note_problem), ("localized-key", "localized", ""))

    def test_the_id_and_the_language_are_not_counted(self) -> None:
        found = scan_snippet('''enum PauseWording {
    // Translators: The title.
    static func title(_ language: String) -> String { InterfaceText.line("pause.title", "Pause the speech", language: "es") }
}
''', WORDING)
        counted = [lit.text for lit in found if lit.status in ("localized", "unlocalized")]
        self.assertEqual(counted, ["Pause the speech"])

    def test_a_call_with_no_note_has_a_note_problem(self) -> None:
        found = scan_snippet(GOOD.replace("    // Translators: The title of the pause panel.\n", ""), WORDING)
        self.assertEqual([lit.note_problem for lit in found if lit.text == "Pause the speech"], ["missing-note"])

    def test_another_calls_second_argument_called_line_is_not_a_converted_call(self) -> None:
        found = scan_snippet('func f() { Other.line("a.b", "Pause the speech again") }\n', VIEW)
        self.assertNotEqual([lit.rule for lit in found if lit.text == "Pause the speech again"], ["localized-key"])


class LintTests(TreeCase):
    """The lint on trees with converted files."""

    def setUp(self) -> None:
        super().setUp()
        # No file has unlocalized text, so the baseline is empty and any gain fails.
        self.write("Models/PauseWording.swift", GOOD)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)

    def write_retired(self, retired: list) -> None:
        """Writes retired-ids.txt under the tree's root."""
        target = self.root / ids.RETIRED_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("".join(f"{r}\n" for r in retired), encoding="utf-8")

    def test_a_right_call_passes_and_counts_nothing_unlocalized(self) -> None:
        status, out, _err = self.lint()
        self.assertEqual(status, 0, out)
        self.assertIn("l10n lint: ok, 0 unlocalized literals", out)

    def test_any_english_passes_it_is_not_looked_up_in_a_table(self) -> None:
        self.write("Models/PauseWording.swift", GOOD.replace("Pause the speech", "Something else entirely"))
        status, out, _err = self.lint()
        self.assertEqual(status, 0, out)

    def test_an_id_that_is_not_a_literal_fails(self) -> None:
        self.write("Models/PauseWording.swift", GOOD.replace('"pause.title"', "pauseID"))
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("the ID is not one plain string literal", out)

    def test_an_id_outside_the_pattern_fails(self) -> None:
        self.write("Models/PauseWording.swift", GOOD.replace("pause.title", "Pause-Title"))
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("outside the pattern", out)

    def test_a_retired_id_fails(self) -> None:
        self.write_retired(["pause.title"])
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("retired", out)
        self.assertIn(f"{FILE}:3:", out)

    def test_a_missing_note_fails_once_through_the_scanners_rule(self) -> None:
        self.write("Models/PauseWording.swift", GOOD.replace("    // Translators: The title of the pause panel.\n", ""))
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertEqual(out.count(":2: missing-note"), 1, out)
        self.assertEqual(out.count("InterfaceText"), 0, "the call's own checks add no second sentence about the note")

    def test_a_tree_with_no_converted_file_counts_what_it_counted_before(self) -> None:
        self.write("Models/PauseWording.swift", 'enum PauseWording {\n    static var one: String { "First sentence of text" }\n}\n')
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 0)
        self.assertIn("1 unlocalized literals in 1 files", out)


if __name__ == "__main__":
    unittest.main()
