"""The lint's rule against lookups into Apple's tables (FR39 phase 8).

Neither app ships a table of Apple's, so `String(localized:)`, `AttributedString(localized:)`, `LocalizedStringResource`,
`String.LocalizationValue`, `LocalizedStringKey`, `NSLocalizedString`, and a SwiftUI literal key would find nothing and show their
key. `make lint-l10n` fails on each, in any file of TextMouth/, naming InterfaceText.line. Every test builds a tree of its own.
"""

from __future__ import annotations

import subprocess
import sys
import unittest

from scan_case import REPO, TreeCase

import apple_lookups  # noqa: E402

# One file's body for each form the rule refuses, with the 1-based line the lookup is on (line 1 is `enum W {`).
FORMS = {
    "String(localized:) with a literal": ('static var a: String { String(localized: "Pause") }', "String(\"...\")"),
    "String(localized:) with a value": ('static func a(_ v: String.LocalizationValue) -> String { String(localized: v) }',
                                        "String(localized:)"),
    "AttributedString(localized:)": ('static var a: AttributedString { AttributedString(localized: "Pause") }', None),
    "LocalizedStringResource": ('static var a = LocalizedStringResource("Pause")', None),
    "LocalizedStringResource as a type": ('static func a(_ r: LocalizedStringResource) {}', "LocalizedStringResource"),
    "String.LocalizationValue": ('static func a(_ v: String.LocalizationValue) {}', "String.LocalizationValue"),
    "LocalizedStringKey": ('static func a(_ k: LocalizedStringKey) {}', "LocalizedStringKey"),
    "NSLocalizedString": ('static var a: String { NSLocalizedString("Pause", comment: "") }', "NSLocalizedString"),
    "a SwiftUI Text literal": ('var body: some View { Text("Pause the speech") }', "Text(\"...\")"),
    "a SwiftUI Button literal": ('var body: some View { Button("Resume") { go() } }', "Button(\"...\")"),
    "a SwiftUI accessibilityLabel literal": ('var body: some View { Color.red.accessibilityLabel("Cover") }',
                                             "accessibilityLabel(\"...\")"),
}


def source(body: str) -> str:
    """A file whose line 2 holds `body`, with a translator's note above it so that only the lookup is wrong."""
    return f"import SwiftUI\n// Translators: A line.\n{body}\n"


class FormTests(TreeCase):
    """The lint refuses each form, once, naming the line and InterfaceText.line."""

    def test_each_form_fails_the_lint_with_its_line_and_the_remedy(self) -> None:
        for name, (body, _form) in FORMS.items():
            with self.subTest(form=name):
                self.write("Models/PauseWording.swift", source(body))
                self.assertEqual(self.lint("--rebuild-baseline")[0], 0, name)
                status, out, _err = self.lint()
                self.assertEqual(status, 1, f"{name}: {out}")
                self.assertIn("TextMouth/Models/PauseWording.swift:3: ", out, name)
                self.assertIn("reads Apple's tables", out, name)
                self.assertIn('InterfaceText.line("<ID>", "<English>")', out, name)
                self.assertEqual(out.count("PauseWording.swift:3:"), 1, f"{name}: a line is named once: {out}")

    def test_every_form_but_a_swiftui_literal_is_found_by_its_name_alone(self) -> None:
        """A use with no literal (a value, a type) is found by the name, in code; only a SwiftUI literal key needs the scanner."""
        for name, (body, _form) in FORMS.items():
            with self.subTest(form=name):
                found = apple_lookups.from_text(source(body), "TextMouth/Models/PauseWording.swift")
                self.assertEqual([lookup.line for lookup in found] != [], "SwiftUI" not in name, name)

    def test_a_tree_with_only_interface_text_calls_passes(self) -> None:
        self.write("Models/PauseWording.swift",
                   'enum PauseWording {\n    // Translators: A title.\n    static var a: String { InterfaceText.line("pause.title", "Pause the speech") }\n}\n')
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 0, out)

    def test_a_mention_in_a_comment_or_a_string_is_no_lookup(self) -> None:
        self.write("Models/PauseWording.swift", (
            "enum PauseWording {\n"
            "    /// Not `String(localized:)`, not NSLocalizedString, and no LocalizedStringKey either.\n"
            "    // A LocalizedStringResource would show its key.\n"
            '    // Translators: A title.\n    static var a: String { InterfaceText.line("pause.title", "Use NSLocalizedString never") }\n'
            "}\n"))
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 0, out)

    def test_a_marked_line_is_still_a_lookup(self) -> None:
        """`// l10n: no` leaves unlocalized text out of the count; a lookup into a missing table is no text to leave out."""
        self.write("Views/Panel.swift", source('var body: some View { Text("Debug panel") } // l10n: no'))
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 1, out)
        self.assertIn("Panel.swift:3: Text(\"...\") reads Apple's tables", out)

    def test_a_baseline_cannot_allow_a_lookup(self) -> None:
        """The lookups are held at zero in every file, whatever the baseline says."""
        self.write("Views/Panel.swift", source('var body: some View { Text("Debug panel") }'))
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        self.assertEqual(self.lint("--update-baseline")[0], 1)

    def test_text_verbatim_and_a_text_of_a_variable_are_no_lookup(self) -> None:
        self.write("Views/Panel.swift", source('var body: some View { Text(verbatim: name); Text(name) }'))
        status, out, _err = self.lint()
        self.assertNotIn("reads Apple's tables", out)

    def test_two_lookups_on_two_lines_are_two_problems_in_line_order(self) -> None:
        self.write("Views/Panel.swift", source('var a: String { NSLocalizedString("A", comment: "") }\nvar b: Text { Text("B") }'))
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        _status, out, _err = self.lint()
        lines = [line for line in out.splitlines() if "reads Apple's tables" in line]
        self.assertEqual(len(lines), 2, out)
        self.assertTrue(lines[0].startswith("TextMouth/Views/Panel.swift:3: ") and lines[1].startswith("TextMouth/Views/Panel.swift:4: "))


class RepositoryTests(unittest.TestCase):
    """The app's own code."""

    def test_the_apps_code_holds_no_lookup_into_apples_tables(self) -> None:
        done = subprocess.run([sys.executable, "-I", "-B", str(REPO / "Scripts/l10n/scan.py"), "lint"],
                              capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("reads Apple's tables", done.stdout)


if __name__ == "__main__":
    unittest.main()
