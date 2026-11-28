"""The scanner names the SwiftUI literals that are extracted without a comment (TL13), and the lint refuses them (FR39 phase 8).

The compiler extracts `Text("...")`, `Button("...")`, and the others as localized keys, but only `Text` can take a comment.
`scan.py show` lists them in a section of their own. Since no app ships a table of Apple's, each is an `apple-lookup` that would
show its key: it is counted neither localized nor unlocalized (the baseline does not change), and `lint` fails on it, naming
InterfaceText.line. (The file keeps the name of the section it first tested.)
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

from scan_case import REPO, TreeCase, run_main, scan_snippet
from swiftscan.classify import NEEDS_COMMENT_HELP


def bare(code: str) -> list:
    """The (call, text) of each literal of a snippet that needs a comment."""
    return [(lit.call, lit.text) for lit in scan_snippet(code) if lit.needs_comment]


class NeedsCommentTests(unittest.TestCase):
    """Which literals are listed."""

    def test_each_call_form_with_a_literal_is_listed(self) -> None:
        cases = {
            'Text("Sleep Timer")': "Text",
            'Button("Cancel") { stop() }': "Button",
            'Label("Add Book", systemImage: "plus")': "Label",
            'Toggle("Play sound", isOn: $on)': "Toggle",
            'Image(x).accessibilityLabel("Cover of the book")': "accessibilityLabel",
            'Image(x).accessibilityHint("Opens the book")': "accessibilityHint",
            'Image(x).accessibilityValue("3 of 5")': "accessibilityValue",
            'Image(x).help("Shows the book")': "help",
            'List {}.navigationTitle("Library")': "navigationTitle",
        }
        for code, call in cases.items():
            with self.subTest(call=call):
                found = bare(code)
                self.assertEqual([c for c, _t in found], [call], code)

    def test_text_with_a_comment_is_not_listed(self) -> None:
        self.assertEqual(bare('Text("Sleep Timer", comment: "The title of the sleep timer sheet")'), [])

    def test_text_with_a_comment_after_other_arguments_or_a_long_comment_is_not_listed(self) -> None:
        self.assertEqual(bare('Text("Sleep Timer", tableName: nil, bundle: .main, comment: "The title (a heading)")'), [])
        self.assertEqual(bare('Text("Time left: \\(minutes) minutes", comment: "Shows (and speaks) the time")'), [])

    def test_a_word_comment_inside_the_text_or_another_call_does_not_count_as_the_label(self) -> None:
        # The key's own text and a later call both hold the word, but no `comment:` argument belongs to this Text.
        self.assertEqual(bare('Text("Leave a comment: please")'), [("Text", "Leave a comment: please")])
        self.assertEqual(bare('VStack { Text("Hello there") }.padding(comment: 1)'), [("Text", "Hello there")])

    def test_a_literal_marked_l10n_no_is_not_listed(self) -> None:
        self.assertEqual(bare('Text("Debug panel") // l10n: no (a developer tool)'), [])
        self.assertEqual(bare('Button("Cancel") { stop() } // l10n: no'), [])

    def test_a_string_with_a_comment_and_other_localized_forms_are_not_listed(self) -> None:
        self.assertEqual(bare('let a = String(localized: "Sleep Timer", comment: "A title")'), [])
        self.assertEqual(bare('Text(verbatim: "Sleep Timer")'), [])
        self.assertEqual(bare('Text(name)'), [])

    def test_a_ternary_of_two_literals_lists_both(self) -> None:
        self.assertEqual(bare('Button(isNew ? "Add" : "Save") { go() }'), [("Button", "Add"), ("Button", "Save")])

    def test_a_listed_literal_is_an_apple_lookup_and_not_unlocalized(self) -> None:
        lit = scan_snippet('Text("Sleep Timer")')[0]
        self.assertEqual((lit.status, lit.needs_comment), ("apple-lookup", True))

    def test_a_label_on_the_literal_other_than_the_key_is_not_listed(self) -> None:
        self.assertEqual(bare('Button(action: go, label: "Go there")'), [])


class ShowTests(TreeCase):
    """`scan.py show` and the lint's counts."""

    CODE = ('import SwiftUI\n'
            'struct SleepPanel: View {\n'
            '    var body: some View {\n'
            '        Text("Sleep Timer")\n'
            '        // Translators: Shown when the timer is stored\n'
            '        Text("Saved")\n'
            '        Button("Cancel") { stop() }\n'
            '        Label("Debug", systemImage: "ladybug") // l10n: no\n'
            '    }\n'
            '}\n')
    # The same panel with a note above every key, as the lint needs it (TL15).
    NOTED = ('import SwiftUI\n'
             'struct SleepPanel: View {\n'
             '    var body: some View {\n'
             '        // Translators: The panel\'s title\n'
             '        Text("Sleep Timer")\n'
             '        // Translators: Shown when the timer is stored\n'
             '        Text("Saved")\n'
             '        // Translators: The button that stops the timer\n'
             '        Button("Cancel") { stop() }\n'
             '        // Translators: A debugging label\n'
             '        Label("Debug", systemImage: "ladybug") // l10n: no\n'
             '    }\n'
             '}\n')

    def test_show_lists_the_section_with_its_lines_and_the_call(self) -> None:
        self.write("Views/SleepPanel.swift", self.CODE)
        status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Views/SleepPanel.swift")
        self.assertEqual(status, 0)
        self.assertIn(f"{NEEDS_COMMENT_HELP} (2):", out)
        self.assertIn("InterfaceText.line", NEEDS_COMMENT_HELP)
        self.assertIn('line 4 [Text] "Sleep Timer"', out)
        self.assertIn('line 7 [Button] "Cancel"', out)
        extracted = out.split("translator's notes missing")[0]
        self.assertNotIn("Saved", extracted, "a key with a note above it is not listed")
        self.assertNotIn("Debug", extracted)

    def test_show_has_no_section_for_a_file_without_such_literals(self) -> None:
        self.write("Views/Plain.swift", 'import SwiftUI\nstruct A: View { var body: some View { Text("Hi", comment: "c") } }\n')
        _status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Views/Plain.swift")
        self.assertNotIn(NEEDS_COMMENT_HELP, out)

    def test_show_json_names_them(self) -> None:
        self.write("Views/SleepPanel.swift", self.CODE)
        _status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Views/SleepPanel.swift", "--json")
        data = json.loads(out)
        self.assertEqual([(item["line"], item["call"], item["text"]) for item in data["extractedWithoutComment"]],
                         [(4, "Text", "Sleep Timer"), (7, "Button", "Cancel")])

    def test_the_lints_counts_do_not_change_and_the_lint_refuses_each_literal(self) -> None:
        """The literals are counted neither localized nor unlocalized, so the counts name no file; the lint fails on each,
        naming the line and InterfaceText.line."""
        self.write("Views/SleepPanel.swift", self.NOTED)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8"))["files"], {}, "no file has unlocalized text")
        status, out, _err = self.lint()
        self.assertEqual(status, 1, out)
        for line, call in ((5, 'Text("...")'), (7, 'Text("...")'), (9, 'Button("...")'), (11, 'Label("...")')):
            self.assertIn(f"TextMouth/Views/SleepPanel.swift:{line}: {call} reads Apple's tables", out)
        self.assertIn('InterfaceText.line("<ID>", "<English>")', out)

    def test_the_repositorys_lint_still_passes_against_its_baseline(self) -> None:
        done = subprocess.run([sys.executable, "-I", "-B", str(Path(REPO) / "Scripts/l10n/scan.py"), "lint", "--base", "HEAD"],
                              capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
