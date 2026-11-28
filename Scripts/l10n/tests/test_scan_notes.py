"""The scanner's rules for a translator's note (TL15).

A note is a `// Translators: <note>` line directly above the line that holds a localized key's literal. The scanner
refuses a `comment:` argument on a localized call (Foundation compiles it into the app), a key with no such line above it,
and a line that holds two keys, and the lint holds all three at zero in every file.
"""

from __future__ import annotations

import json
import unittest
from typing import List

from scan_case import TreeCase, WORDING, lex, run_main, scan_snippet

from swiftscan import classify, ratchet
from swiftscan.lexer import Literal


def problems(code: str, path: str = WORDING) -> List[tuple]:
    """(line, problem) of each literal of a snippet whose note is wrong."""
    return [(lit.line, lit.note_problem) for lit in scan_snippet(code, path) if lit.note_problem]


class CommentArgumentTests(unittest.TestCase):
    """A `comment:` argument of a localized call is an error."""

    def test_the_comment_of_string_localized_is_refused(self) -> None:
        code = 'enum W {\n    // Translators: A title\n    static var a: String { String(localized: "Title", comment: "A title") }\n}\n'
        self.assertEqual(problems(code), [(3, "comment-argument")])

    def test_the_comment_of_each_localized_call_is_refused(self) -> None:
        for call in ('Text("x", comment: "c")', 'AttributedString(localized: "x", comment: "c")',
                     'LocalizedStringResource("x", comment: "c")', 'String(localized: "x", table: "T", comment: "c")'):
            code = f"// Translators: n\nlet a = {call}\n"
            self.assertIn((2, "comment-argument"), problems(code), call)

    def test_a_comment_label_of_another_call_is_not_a_localized_comment(self) -> None:
        # `post(comment:)` is not a call the compiler extracts.
        self.assertEqual(problems('let a = Review(comment: "Good book")\n'), [])
        self.assertEqual(problems('let a = Review(title: "x", comment: "Good book")\n'), [])

    def test_a_note_line_and_no_argument_passes(self) -> None:
        code = 'enum W {\n    // Translators: A title\n    static var a: String { String(localized: "Title") }\n}\n'
        self.assertEqual(problems(code), [])


class MissingNoteTests(unittest.TestCase):
    """A localized key needs a `// Translators:` line directly above its line."""

    def test_a_key_with_a_note_directly_above_passes(self) -> None:
        self.assertEqual(problems('// Translators: A title\nlet a = String(localized: "Title")\n'), [])

    def test_a_key_with_no_note_is_refused_and_the_text_is_named(self) -> None:
        found = [(lit.line, lit.note_problem, lit.text) for lit in scan_snippet('let a = String(localized: "Title")\n') if lit.note_problem]
        self.assertEqual(found, [(1, "missing-note", "Title")])

    def test_the_line_above_is_what_counts_not_a_comment_further_up(self) -> None:
        code = '// Translators: A title\n\nlet a = String(localized: "Title")\n'
        self.assertEqual(problems(code), [(3, "missing-note")])
        code = '// Translators: A title\n// Another comment\nlet a = String(localized: "Title")\n'
        self.assertEqual(problems(code), [(3, "missing-note")])

    def test_a_marker_with_no_text_is_no_note(self) -> None:
        self.assertEqual(problems('// Translators:\nlet a = String(localized: "Title")\n'), [(2, "missing-note")])
        self.assertEqual(problems('// Translators:   \nlet a = String(localized: "Title")\n'), [(2, "missing-note")])

    def test_another_comment_is_no_note(self) -> None:
        self.assertEqual(problems('// A title\nlet a = String(localized: "Title")\n'), [(2, "missing-note")])
        self.assertEqual(problems('/// Translators: A title\nlet a = String(localized: "Title")\n'), [(2, "missing-note")])

    def test_the_note_takes_any_indentation(self) -> None:
        code = 'enum W {\n    static var a: String {\n        // Translators: A title\n        String(localized: "Title")\n    }\n}\n'
        self.assertEqual(problems(code), [])

    def test_a_note_above_a_key_that_is_not_on_the_calls_first_line_passes(self) -> None:
        # The call starts a line earlier than its key: the note sits above the key's own line, and the lexer still sees the
        # label past the comment (it once took `// ... author.` for the code before `localized:`).
        code = ('enum W {\n    static func a(_ n: String) -> String {\n        let byline = cond ? n : String(\n'
                '            // Translators: A title and author. %1$@ is the title.\n'
                '            localized: "\\(n), by author")\n        return byline\n    }\n}\n')
        keys = [lit for lit in scan_snippet(code) if lit.rule == "localized-key"]
        self.assertEqual([(lit.line, lit.text) for lit in keys], [(5, "%@, by author")])
        self.assertEqual(problems(code), [])

    def test_each_branch_of_a_ternary_needs_its_own_note(self) -> None:
        code = ('let a = cond\n    // Translators: One\n    ? String(localized: "A")\n    : String(localized: "B")\n')
        self.assertEqual(problems(code), [(4, "missing-note")])

    def test_a_swiftui_literal_is_a_key_too_and_a_note_above_it_passes(self) -> None:
        code = 'struct V: View {\n    var body: some View {\n        Text("Hello there")\n    }\n}\n'
        self.assertEqual(problems(code, "TextMouth/Views/V.swift"), [(3, "missing-note")])
        code = code.replace("        Text", "        // Translators: A greeting\n        Text")
        self.assertEqual(problems(code, "TextMouth/Views/V.swift"), [])

    def test_a_literal_that_is_not_a_key_needs_no_note(self) -> None:
        self.assertEqual(problems('let key = "pause.button"\nlet text = Text(verbatim: "Shown as is")\n'), [])

    def test_a_note_held_in_a_string_is_no_note(self) -> None:
        code = 'let hint = "// Translators: not a comment"\nlet a = String(localized: "Title")\n'
        self.assertEqual(problems(code), [(2, "missing-note")])


class SharedLineTests(unittest.TestCase):
    """A line that holds two different keys cannot carry a note for each."""

    def test_two_keys_on_one_line_are_refused(self) -> None:
        code = '// Translators: Both\nlet a = cond ? String(localized: "One") : String(localized: "Two")\n'
        self.assertEqual(problems(code), [(2, "shared-line"), (2, "shared-line")])

    def test_the_same_key_twice_on_a_line_has_one_note(self) -> None:
        code = '// Translators: Both\nlet a = cond ? String(localized: "One") : String(localized: "One")\n'
        self.assertEqual(problems(code), [])

    def test_a_missing_note_is_still_named_first_when_the_line_is_shared(self) -> None:
        code = 'let a = cond ? String(localized: "One") : String(localized: "Two")\n'
        self.assertEqual(problems(code), [(1, "missing-note"), (1, "missing-note")])


class LexerCommentTests(unittest.TestCase):
    """The lexer steps over a comment between a call's parenthesis and its argument's label."""

    def test_a_line_comment_before_a_label_keeps_the_label(self) -> None:
        lits = lex('String(\n    // Translators: A note: with a colon.\n    localized: "Title")\n')
        self.assertEqual([(lit.label, lit.call) for lit in lits if lit.text == "Title"], [("localized", "String")])

    def test_a_block_comment_before_a_label_keeps_the_label(self) -> None:
        lits = lex('String(\n    /* a note: here */\n    localized: "Title")\n')
        self.assertEqual([(lit.label, lit.call) for lit in lits if lit.text == "Title"], [("localized", "String")])

    def test_a_comment_does_not_make_a_label_of_a_ternarys_colon(self) -> None:
        # A colon after a value on the line above the comment is not an argument label.
        lits = lex('foo(a ? b\n    // Translators: note\n    : "Text")\n')
        self.assertEqual([lit.label for lit in lits if lit.text == "Text"], [None])


class LintTests(TreeCase):
    """`scan.py lint` and `scan.py show` hold the notes at zero in every file."""

    OLD = 'enum PauseWording {\n    static var one: String { String(localized: "Pause", comment: "A button") }\n}\n'
    NEW = 'enum PauseWording {\n    // Translators: A button\n    static var one: String { InterfaceText.line("pause.one", "Pause") }\n}\n'

    def test_a_tree_with_a_comment_argument_fails_the_lint_with_its_line(self) -> None:
        self.write("Models/PauseWording.swift", self.OLD)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("TextMouth/Models/PauseWording.swift:2: comment-argument", out)
        self.assertIn("TextMouth/Models/PauseWording.swift:2: missing-note", out)
        self.assertIn("every file's allowance is zero", out)

    def test_a_tree_in_the_new_form_passes(self) -> None:
        self.write("Models/PauseWording.swift", self.NEW)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 0, out)

    def test_update_baseline_never_hides_a_note_problem(self) -> None:
        self.write("Models/PauseWording.swift", self.OLD)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, _out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8"))["files"], {}, "the baseline holds no note problem")

    def test_the_baseline_cannot_allow_a_note_problem(self) -> None:
        self.write("Models/PauseWording.swift", self.OLD)
        self.baseline.write_text(json.dumps({"version": 1, "files": {"TextMouth/Models/PauseWording.swift": 5}}), encoding="utf-8")
        self.assertEqual(self.lint()[0], 1)

    def test_a_long_list_is_cut_and_counted(self) -> None:
        body = "".join(f'    static var n{i}: String {{ String(localized: "Word {i}") }}\n' for i in range(45))
        self.write("Models/ManyWording.swift", f"enum ManyWording {{\n{body}}}\n")
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("45 localized calls with a translator's note", out)
        self.assertIn("... and 5 more", out)

    def test_show_lists_a_files_note_problems_and_what_each_asks(self) -> None:
        self.write("Models/PauseWording.swift", self.OLD)
        status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Models/PauseWording.swift")
        self.assertEqual(status, 0)
        self.assertIn("translator's notes missing or misplaced (2):", out)
        self.assertIn('line 2 [comment-argument] "A button"', out)
        self.assertIn('line 2 [missing-note] "Pause"', out)
        _status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Models/PauseWording.swift", "--json")
        self.assertEqual(sorted(item["problem"] for item in json.loads(out)["noteProblems"]), ["comment-argument", "missing-note"])

    def test_show_names_nothing_for_a_clean_file(self) -> None:
        self.write("Models/PauseWording.swift", self.NEW)
        _status, out, _err = run_main("--root", str(self.root), "show", "TextMouth/Models/PauseWording.swift")
        self.assertNotIn("translator's notes missing", out)


class RuleTests(unittest.TestCase):
    """The helpers the rules stand on."""

    def test_has_note_reads_only_the_line_directly_above(self) -> None:
        lines = ["", "// Translators: A", "x", "    // Translators: B", "", "y"]
        self.assertTrue(classify.has_note(lines, 3))
        self.assertFalse(classify.has_note(lines, 2))
        self.assertFalse(classify.has_note(lines, 6))
        self.assertFalse(classify.has_note(lines, 1))
        self.assertFalse(classify.has_note(lines, 99))

    def test_note_problems_come_in_path_and_line_order(self) -> None:
        literals = scan_snippet('let b = String(localized: "B")\nlet a = String(localized: "A")\n')
        self.assertEqual([lit.line for lit in ratchet.note_problems(literals)], [1, 2])

    def test_every_problem_kind_has_its_help(self) -> None:
        kinds = {"comment-argument", "missing-note", "shared-line"}
        self.assertEqual(set(classify.NOTE_PROBLEM_HELP), kinds)


if __name__ == "__main__":
    unittest.main()
