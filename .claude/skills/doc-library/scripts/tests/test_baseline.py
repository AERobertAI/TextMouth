"""Tests of the lint's baseline file and the ratchet's arithmetic."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

import baseline  # noqa: E402  (imported after doclib_case has set sys.path)
import output  # noqa: E402
from lintrules import Violation  # noqa: E402


def violation(page: str, rule: str, line: int = 1) -> Violation:
    """A violation of ``rule`` on ``page`` at ``line``, with nothing else of note."""
    return Violation(page, rule, line, line, "", "detail")


class CountTests(DocLibCase):
    """counts, totals, and the other pure arithmetic on counts."""

    def test_counts_by_page_and_rule(self) -> None:
        found = [violation("a.md", "date"), violation("a.md", "date", 2), violation("a.md", "emoji"), violation("b.md", "date")]
        self.assertEqual(baseline.counts(found), {"a.md": {"date": 2, "emoji": 1}, "b.md": {"date": 1}})
        self.assertEqual(baseline.counts([]), {})

    def test_totals_by_rule_over_pages(self) -> None:
        data = {"a.md": {"date": 2, "emoji": 1}, "b.md": {"date": 3}}
        self.assertEqual(baseline.totals(data), {"date": 5, "emoji": 1})
        self.assertEqual(baseline.totals({}), {})

    def test_regressions_are_the_counts_above_the_baseline(self) -> None:
        base = {"a.md": {"date": 2, "emoji": 1}, "gone.md": {"date": 9}}
        now = {"a.md": {"date": 3, "emoji": 1}, "b.md": {"date": 1}, "c.md": {"emoji": 2}}
        self.assertEqual(baseline.regressions(base, now), [
            ("a.md", "date", 3, 2), ("b.md", "date", 1, 0), ("c.md", "emoji", 2, 0)])

    def test_equal_and_lower_counts_are_not_regressions(self) -> None:
        self.assertEqual(baseline.regressions({"a.md": {"date": 2}}, {"a.md": {"date": 2}}), [])
        self.assertEqual(baseline.regressions({"a.md": {"date": 2}}, {"a.md": {"date": 1}}), [])
        self.assertEqual(baseline.regressions({"a.md": {"date": 2}}, {}), [])

    def test_a_missing_baseline_counts_zero(self) -> None:
        self.assertEqual(baseline.regressions({}, {"a.md": {"date": 1}}), [("a.md", "date", 1, 0)])

    def test_lowered_takes_the_smaller_count(self) -> None:
        old = {"a.md": {"date": 5, "emoji": 2}, "b.md": {"date": 1}}
        now = {"a.md": {"date": 3, "emoji": 2}, "b.md": {"date": 4}}
        self.assertEqual(baseline.lowered(old, now, {"a.md", "b.md"}), {"a.md": {"date": 3, "emoji": 2}, "b.md": {"date": 1}})

    def test_lowered_never_raises_or_adds(self) -> None:
        old = {"a.md": {"date": 1}}
        now = {"a.md": {"date": 7, "emoji": 3}, "new.md": {"date": 2}}
        self.assertEqual(baseline.lowered(old, now, {"a.md", "new.md"}), {"a.md": {"date": 1}})

    def test_lowered_drops_zero_counts_vanished_pages_and_dead_rules(self) -> None:
        old = {"a.md": {"date": 2, "retired-rule": 5}, "gone.md": {"date": 4}, "fixed.md": {"emoji": 1}}
        now = {"a.md": {"date": 1}}
        self.assertEqual(baseline.lowered(old, now, {"a.md", "fixed.md"}), {"a.md": {"date": 1}})

    def test_lowered_does_not_change_its_arguments(self) -> None:
        old, now = {"a.md": {"date": 5}}, {"a.md": {"date": 2}}
        baseline.lowered(old, now, {"a.md"})
        self.assertEqual((old, now), ({"a.md": {"date": 5}}, {"a.md": {"date": 2}}))

    def test_restrict_without_and_merged(self) -> None:
        data = {"a.md": {"date": 1, "emoji": 2}, "b.md": {"date": 3}}
        self.assertEqual(baseline.restrict(data, {"date"}, None), {"a.md": {"date": 1}, "b.md": {"date": 3}})
        self.assertEqual(baseline.restrict(data, None, {"b.md"}), {"b.md": {"date": 3}})
        self.assertEqual(baseline.restrict(data, {"emoji"}, {"b.md"}), {})
        self.assertEqual(baseline.without(data, {"date"}, None), {"a.md": {"emoji": 2}})
        self.assertEqual(baseline.without(data, {"emoji"}, {"a.md"}), {"a.md": {"date": 1}, "b.md": {"date": 3}})
        self.assertEqual(baseline.merged({"a.md": {"emoji": 2}}, {"a.md": {"date": 1}, "b.md": {"date": 3}}),
                         {"a.md": {"emoji": 2, "date": 1}, "b.md": {"date": 3}})
        self.assertEqual(baseline.merged({"a.md": {"date": 9}}, {"a.md": {"date": 1}}), {"a.md": {"date": 1}})
        # Restricting and the rest together make the whole again.
        self.assertEqual(baseline.merged(baseline.without(data, {"date"}, None), baseline.restrict(data, {"date"}, None)), data)

    def test_present_only(self) -> None:
        self.assertEqual(baseline.present_only({"a.md": {"date": 1}, "b.md": {"date": 2}}, {"b.md"}), {"b.md": {"date": 2}})

    def test_changes(self) -> None:
        before = {"a.md": {"date": 3, "emoji": 1}, "gone.md": {"date": 2}}
        after = {"a.md": {"date": 2, "emoji": 1}, "new.md": {"date": 1}}
        self.assertEqual(baseline.changes(before, after), [
            ("a.md", "date", 3, 2), ("gone.md", "date", 2, 0), ("new.md", "date", 0, 1)])


class FormatTests(DocLibCase):
    """The file's text: its exact form, and reading it back."""

    def test_the_exact_format_is_one_page_to_a_line_everything_sorted(self) -> None:
        data = {"README.md": {"index-line": 20}, "AGENTS.md": {"line-length": 69, "date": 61}}
        self.assertEqual(baseline.format_baseline(data), (
            '{\n'
            '  "version": 1,\n'
            '  "pages": {\n'
            '    "AGENTS.md": {"date": 61, "line-length": 69},\n'
            '    "README.md": {"index-line": 20}\n'
            '  }\n'
            '}\n'))

    def test_an_empty_baseline(self) -> None:
        self.assertEqual(baseline.format_baseline({}), '{\n  "version": 1,\n  "pages": {}\n}\n')
        self.assertEqual(baseline.read_baseline(baseline.format_baseline({})), {})

    def test_zero_counts_and_empty_pages_are_left_out(self) -> None:
        text = baseline.format_baseline({"a.md": {"date": 0}, "b.md": {}, "c.md": {"date": 1, "emoji": 0}})
        self.assertEqual(json.loads(text), {"version": 1, "pages": {"c.md": {"date": 1}}})

    def test_round_trip_keeps_names_that_are_not_ascii(self) -> None:
        data = {"docs/user/café.md": {"date": 2}, "a \"quoted\".md": {"emoji": 1}}
        text = baseline.format_baseline(data)
        self.assertIn("café", text)
        self.assertEqual(baseline.read_baseline(text), data)

    def test_two_pages_lowered_on_two_branches_change_different_lines(self) -> None:
        both = {"a.md": {"date": 5}, "b.md": {"date": 5}, "c.md": {"date": 5}}
        one = baseline.format_baseline({**both, "a.md": {"date": 4}}).splitlines()
        two = baseline.format_baseline({**both, "c.md": {"date": 4}}).splitlines()
        base = baseline.format_baseline(both).splitlines()
        self.assertEqual(len(base), len(one))
        self.assertEqual([i for i in range(len(base)) if base[i] != one[i]], [3])
        self.assertEqual([i for i in range(len(base)) if base[i] != two[i]], [5])

    def test_reading_drops_zero_counts(self) -> None:
        self.assertEqual(baseline.read_baseline('{"version": 1, "pages": {"a.md": {"date": 0, "emoji": 2}, "b.md": {}}}'),
                         {"a.md": {"emoji": 2}})

    def test_reading_refuses_what_is_not_a_baseline(self) -> None:
        for text in ["not json", "[]", '{"pages": {}}', '{"version": 2, "pages": {}}', '{"version": 1}',
                     '{"version": 1, "pages": []}', '{"version": 1, "pages": {"a.md": 3}}',
                     '{"version": 1, "pages": {"a.md": {"date": -1}}}', '{"version": 1, "pages": {"a.md": {"date": "3"}}}',
                     '{"version": 1, "pages": {"a.md": {"date": true}}}']:
            with self.subTest(text=text):
                with self.assertRaises(output.UsageError):
                    baseline.read_baseline(text)


class FileTests(DocLibCase):
    """Reading and writing the file inside a repository folder."""

    def test_no_file_loads_as_none(self) -> None:
        self.assertIsNone(baseline.load_baseline(self.root))

    def test_write_then_load(self) -> None:
        data = {"a.md": {"date": 2}}
        baseline.write_baseline(self.root, data)
        self.assertTrue((self.root / baseline.BASELINE).is_file())
        self.assertEqual(baseline.load_baseline(self.root), data)
        self.assertEqual((self.root / baseline.BASELINE).read_text(encoding="utf-8"), baseline.format_baseline(data))

    def test_the_write_goes_through_a_temporary_file_and_replaces(self) -> None:
        baseline.write_baseline(self.root, {"a.md": {"date": 2}})
        baseline.write_baseline(self.root, {"a.md": {"date": 1}})
        folder = (self.root / baseline.BASELINE).parent
        self.assertEqual([path.name for path in folder.iterdir()], ["lint-baseline.json"])
        self.assertEqual(baseline.load_baseline(self.root), {"a.md": {"date": 1}})

    def test_a_failed_write_leaves_the_old_file_whole(self) -> None:
        baseline.write_baseline(self.root, {"a.md": {"date": 2}})
        path = self.root / baseline.BASELINE
        # A folder where the temporary file belongs makes the write fail before the replace.
        path.with_name(path.name + baseline.TEMPORARY_SUFFIX).mkdir()
        with self.assertRaises(OSError):
            baseline.write_baseline(self.root, {"a.md": {"date": 1}})
        self.assertEqual(baseline.load_baseline(self.root), {"a.md": {"date": 2}})

    def test_a_file_that_is_not_a_baseline_is_a_usage_error(self) -> None:
        self.write_tree({baseline.BASELINE: "{}"})
        with self.assertRaises(output.UsageError):
            baseline.load_baseline(self.root)


class GitTests(DocLibCase):
    """The baseline at a commit, and the merge base."""

    def test_baseline_at_a_commit(self) -> None:
        self.git_repo({baseline.BASELINE: baseline.format_baseline({"a.md": {"date": 2}}), "a.md": "x\n"})
        first = self.git("rev-parse", "HEAD").strip()
        baseline.write_baseline(self.root, {"a.md": {"date": 1}})
        self.commit_all("lowered")
        self.assertEqual(baseline.baseline_at(self.root, first), {"a.md": {"date": 2}})
        self.assertEqual(baseline.baseline_at(self.root, "HEAD"), {"a.md": {"date": 1}})
        self.assertEqual(baseline.baseline_at(self.root, "HEAD~1"), {"a.md": {"date": 2}})

    def test_no_baseline_at_a_commit_is_none(self) -> None:
        self.git_repo({"a.md": "x\n"})
        self.assertIsNone(baseline.baseline_at(self.root, "HEAD"))
        self.assertIsNone(baseline.baseline_at(self.root, "no-such-ref"))

    def test_the_merge_base_of_a_branch(self) -> None:
        self.git_repo({"a.md": "x\n"})
        base = self.git("rev-parse", "HEAD").strip()
        self.git("switch", "-q", "-c", "feature")
        self.write_tree({"b.md": "y\n"})
        self.commit_all("feature work")
        self.assertEqual(baseline.merge_base(self.root, "main"), base)
        self.assertEqual(baseline.merge_base(self.root, "HEAD"), self.git("rev-parse", "HEAD").strip())

    def test_an_unknown_ref_or_an_option_is_a_usage_error(self) -> None:
        self.git_repo({"a.md": "x\n"})
        for ref in ("no-such-branch", "--all", ""):
            with self.subTest(ref=ref):
                with self.assertRaises(output.UsageError):
                    baseline.merge_base(self.root, ref)
        with self.assertRaises(output.UsageError):
            baseline.baseline_at(self.root, "--all")
