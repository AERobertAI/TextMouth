"""The ratchet: `scan.py lint` and the baseline it keeps, on trees of their own."""

from __future__ import annotations

import json
import unittest

from scan_case import REPO, TreeCase, run_main, scan_snippet

from swiftscan import ratchet

# A wording file with two unlocalized literals, and the same file with three and with one.
TWO = 'enum PauseWording {\n    static var one: String { "First sentence of text" }\n    static var two: String { "Second sentence of text" }\n}\n'
THREE = (
    'enum PauseWording {\n    static var one: String { "First sentence of text" }\n'
    '    static var two: String { "Second sentence of text" }\n'
    '    static var three: String { "Third sentence of text" }\n}\n')
ONE = 'enum PauseWording {\n    static var one: String { "First sentence of text" }\n}\n'


class LintTests(TreeCase):
    """The lint passes at its baseline, fails above it, and only ever lowers it."""

    def baseline_counts(self) -> dict:
        """The files and counts the baseline file holds."""
        return json.loads(self.baseline.read_text(encoding="utf-8"))["files"]

    def setUp(self) -> None:
        super().setUp()
        self.write("Models/PauseWording.swift", TWO)
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)

    def test_the_rebuilt_baseline_records_each_files_count_sorted_one_per_line(self) -> None:
        self.write("Models/AaaWording.swift", ONE)
        self.lint("--rebuild-baseline")
        text = self.baseline.read_text(encoding="utf-8")
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/AaaWording.swift": 1, "TextMouth/Models/PauseWording.swift": 2})
        self.assertEqual(text.splitlines()[:3], ["{", '  "version": 1,', '  "files": {'])
        self.assertLess(text.index("AaaWording"), text.index("PauseWording"))

    def test_a_tree_at_its_baseline_passes(self) -> None:
        status, out, _err = self.lint()
        self.assertEqual(status, 0)
        self.assertIn("l10n lint: ok, 2 unlocalized literals in 1 files", out)

    def test_a_file_that_gains_a_literal_fails_and_each_literal_is_shown_with_its_line(self) -> None:
        self.write("Models/PauseWording.swift", THREE)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("TextMouth/Models/PauseWording.swift: 3 unlocalized literals, baseline 2 (+1)", out)
        self.assertIn('line 4 [wording] "Third sentence of text"', out)
        self.assertIn('line 2 [wording] "First sentence of text"', out)
        self.assertIn("// l10n: no", out)

    def test_a_new_file_with_unlocalized_text_fails(self) -> None:
        self.write("Models/ResumeWording.swift", ONE)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("TextMouth/Models/ResumeWording.swift: 1 unlocalized literals, baseline 0 (+1)", out)

    def test_a_new_file_with_only_localized_marked_or_uncounted_text_passes(self) -> None:
        self.write("Views/NewView.swift", (
            'import SwiftUI\nstruct NewView: View {\n    var body: some View {\n'
            '        // Translators: A label on the pause panel\n        Text(verbatim: PauseWording.label)\n'
            '        // Translators: The button that resumes\n        Button(PauseWording.resume) { go() }\n    }\n    let hook = "A name the tests use" // l10n: no\n'
            '    let key = "pause.button"\n    func trace() { print("Tracing the pause button") }\n}\n'))
        self.assertEqual(self.lint()[0], 0)

    def test_a_file_that_loses_a_literal_passes_and_update_lowers_its_baseline(self) -> None:
        self.write("Models/PauseWording.swift", ONE)
        status, out, _err = self.lint()
        self.assertEqual(status, 0)
        self.assertIn("1 files are below it: run --update-baseline", out)
        status, out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 0)
        self.assertIn("TextMouth/Models/PauseWording.swift: 2 -> 1", out)
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/PauseWording.swift": 1})

    def test_a_file_that_reaches_zero_leaves_the_baseline(self) -> None:
        self.write("Models/PauseWording.swift", 'enum PauseWording {\n    // Translators: A title\n    static var one: String { InterfaceText.line("pause.one", "First sentence of text") }\n}\n')
        status, out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 0)
        self.assertIn("2 -> 0 (left the baseline)", out)
        self.assertEqual(self.baseline_counts(), {})

    def test_update_never_raises_a_count_nor_adds_a_file(self) -> None:
        self.write("Models/PauseWording.swift", THREE)
        self.write("Models/ResumeWording.swift", ONE)
        status, out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 1)
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/PauseWording.swift": 2})
        self.assertIn("baseline 2 (+1)", out)
        self.assertIn("ResumeWording.swift: 1 unlocalized literals, baseline 0", out)

    def test_update_lowers_one_file_while_another_still_fails(self) -> None:
        self.write("Models/ResumeWording.swift", ONE)
        self.lint("--rebuild-baseline")
        self.write("Models/PauseWording.swift", ONE)           # fell from 2 to 1
        self.write("Models/ResumeWording.swift", TWO)          # rose from 1 to 2
        status, _out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 1)
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/PauseWording.swift": 1, "TextMouth/Models/ResumeWording.swift": 1})

    def test_a_literal_marked_as_not_localized_on_purpose_is_skipped(self) -> None:
        self.write("Models/PauseWording.swift", THREE.replace('"Third sentence of text" }', '"Third sentence of text" } // l10n: no'))
        self.assertEqual(self.lint()[0], 0)

    def test_a_renamed_file_moves_its_record(self) -> None:
        # The baseline lists a file that is gone, and the tree has its text under a new name.
        self.baseline.write_text('{"version": 1, "files": {"TextMouth/Models/OldWording.swift": 2}}\n', encoding="utf-8")
        self.write("Models/PauseWording.swift", "// emptied\n")
        self.write("Models/HaltWording.swift", TWO)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("a rename?", out)
        self.assertIn("TextMouth/Models/OldWording.swift", out)
        status, _out, _err = self.lint("--update-baseline", "--renamed", "TextMouth/Models/OldWording.swift", "TextMouth/Models/HaltWording.swift")
        self.assertEqual(status, 0)
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/HaltWording.swift": 2})

    def test_a_deleted_files_entry_is_dropped_so_a_new_file_at_its_path_starts_from_zero(self) -> None:
        # The baseline lists a file the tree no longer has (deleted in a merged branch).
        self.baseline.write_text('{"version": 1, "files": {"TextMouth/Models/GoneWording.swift": 2, '
                                 '"TextMouth/Models/PauseWording.swift": 2}}\n', encoding="utf-8")
        status, out, _err = self.lint("--update-baseline")
        self.assertEqual(status, 0)
        self.assertIn("GoneWording.swift: 2 -> 0 (left the baseline)", out)
        self.assertEqual(self.baseline_counts(), {"TextMouth/Models/PauseWording.swift": 2})
        # A new file at the same path inherits nothing: one literal fails.
        self.write("Models/GoneWording.swift", ONE)
        status, out, _err = self.lint()
        self.assertEqual(status, 1)
        self.assertIn("GoneWording.swift: 1 unlocalized literals, baseline 0 (+1)", out)

    def test_the_failure_text_and_help_say_a_branch_never_edits_the_baseline(self) -> None:
        self.write("Models/PauseWording.swift", THREE)
        _status, out, _err = self.lint()
        self.assertIn("Never edit scan-baseline.json", out)
        self.assertIn("lowers it after every merge", out)
        _status, help_out, _err = run_main("lint", "--help")
        self.assertIn("Never edit scan-baseline.json", " ".join(help_out.split()))

    def test_renamed_without_update_is_a_usage_error(self) -> None:
        status, _out, err = self.lint("--renamed", "A", "B")
        self.assertEqual(status, 2)
        self.assertIn("--renamed goes with --update-baseline", err)


class BaselineFileTests(TreeCase):
    """A missing or damaged baseline is a usage error, not a pass."""

    def test_a_missing_baseline_is_a_usage_error(self) -> None:
        status, _out, err = self.lint()
        self.assertEqual(status, 2)
        self.assertIn("baseline.json does not exist", err)
        self.assertNotIn(str(self.root), err)

    def test_damaged_baselines_are_usage_errors(self) -> None:
        for content in ("not json", "[]", '{"version": 2, "files": {}}', '{"version": 1, "files": {"a": 0}}',
                        '{"version": 1, "files": {"a": "many"}}'):
            self.baseline.write_text(content, encoding="utf-8")
            status, _out, err = self.lint()
            self.assertEqual(status, 2, content)
            self.assertIn("baseline.json", err)

    def test_rebuild_and_update_cannot_be_combined(self) -> None:
        self.assertEqual(self.lint("--rebuild-baseline", "--update-baseline")[0], 2)

    def test_an_empty_app_has_an_empty_baseline(self) -> None:
        self.assertEqual(self.lint("--rebuild-baseline")[0], 0)
        self.assertEqual(json.loads(self.baseline.read_text(encoding="utf-8")), {"version": 1, "files": {}})
        self.assertEqual(self.lint()[0], 0)


class MakefileTests(unittest.TestCase):
    """`make lint-l10n` is defined, listed in `make help`, and runs the lint with the lint base."""

    def setUp(self) -> None:
        makefile = REPO / "Makefile"
        if not makefile.is_file():
            self.skipTest("no Makefile beside the scripts")
        self.text = makefile.read_text(encoding="utf-8")

    def test_the_target_is_defined_phony_and_in_the_help(self) -> None:
        self.assertIn("\nlint-l10n:\n\t@python3 -I -B Scripts/l10n/scan.py lint --base $(LINT_BASE) $(L10N_ARGS)\n", self.text)
        phony = next(line for line in self.text.splitlines() if line.startswith(".PHONY:"))
        self.assertIn(" lint-l10n ", phony)
        self.assertIn('@echo "  make lint-l10n  - ', self.text)


class RatchetFunctionTests(unittest.TestCase):
    """The pieces of the ratchet, without a tree."""

    def literals(self) -> list:
        return scan_snippet(TWO, "TextMouth/Models/PauseWording.swift")

    def test_added_lines_are_read_from_a_zero_context_diff(self) -> None:
        diff = ("diff --git a/TextMouth/Models/A.swift b/TextMouth/Models/A.swift\n--- a/TextMouth/Models/A.swift\n"
                "+++ b/TextMouth/Models/A.swift\n@@ -3,0 +4,2 @@ context\n+one\n+two\n@@ -10 +12 @@\n-old\n+new\n"
                "@@ -20,2 +21,0 @@\n-gone\n-gone\n"
                "diff --git a/TextMouth/Models/B.swift b/TextMouth/Models/B.swift\n--- /dev/null\n+++ b/TextMouth/Models/B.swift\n@@ -0,0 +1,3 @@\n+x\n+y\n+z\n"
                "diff --git a/TextMouth/Models/C.swift b/TextMouth/Models/C.swift\n--- a/TextMouth/Models/C.swift\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n")
        self.assertEqual(ratchet.parse_added_lines(diff),
                         {"TextMouth/Models/A.swift": {4, 5, 12}, "TextMouth/Models/B.swift": {1, 2, 3}})

    def test_the_problem_shows_only_the_literals_on_added_lines_when_there_are_some(self) -> None:
        problems = ratchet.find_problems({"TextMouth/Models/PauseWording.swift": 1}, self.literals(),
                                         {"TextMouth/Models/PauseWording.swift": {3}})
        self.assertEqual([(p.count, p.baseline, [l.line for l in p.literals]) for p in problems], [(2, 1, [3])])
        text = "\n".join(ratchet.format_problems(problems))
        self.assertIn("the 1 on the lines this branch added:", text)

    def test_the_problem_shows_every_literal_when_no_added_line_matches(self) -> None:
        problems = ratchet.find_problems({"TextMouth/Models/PauseWording.swift": 1}, self.literals(),
                                         {"TextMouth/Models/PauseWording.swift": {1}})
        self.assertEqual([l.line for l in problems[0].literals], [2, 3])
        problems = ratchet.find_problems({}, self.literals(), None)
        self.assertEqual([l.line for l in problems[0].literals], [2, 3])

    def test_lowering_never_raises_a_count(self) -> None:
        self.assertEqual(ratchet.lowered_baseline({"a": 3, "b": 2, "c": 5}, {"a": 4, "b": 1, "d": 9}), {"a": 3, "b": 1})

    def test_long_literals_are_cut_in_the_failure_text(self) -> None:
        lit = scan_snippet('static var a: String { "' + "word " * 60 + 'end" }', "TextMouth/Models/LongWording.swift")
        text = "\n".join(ratchet.format_problems(ratchet.find_problems({}, lit)))
        self.assertTrue(any(line.endswith("…") and len(line) < 100 for line in text.splitlines()))


if __name__ == "__main__":
    unittest.main()
