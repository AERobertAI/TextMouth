"""Tests of the ``lint`` command, run through ``doclib.main`` on repositories the tests write."""

from __future__ import annotations

import json
from typing import Dict, Tuple

from doclib_case import DocLibCase

import baseline  # noqa: E402  (imported after doclib_case has set sys.path)
import lintrules  # noqa: E402

# Two dates in one page, one in another: three ``date`` violations in all.
TWO_DATES = "# A\n\nOn October 12 it began.\nIt ended on October 13.\n"
ONE_DATE = "# B\n\nSince October 14 it holds.\n"
NO_DATE = "# C\n\nNothing dated here.\n"


class LintCase(DocLibCase):
    """A case with a small docs repository and helpers to run ``lint`` on it."""

    def docs(self, **pages: str) -> Dict[str, str]:
        """The files of a repository whose pages are ``docs/user/NAME.md`` for each keyword."""
        return {f"docs/user/{name}.md": text for name, text in pages.items()}

    def lint(self, *arguments: str) -> Tuple[int, str, str]:
        """Run ``lint`` on the date rule alone (unless the arguments choose rules) in ``self.root``."""
        extra = [] if any(a in ("--rule", "--skip") for a in arguments) else ["--rule", "date"]
        return self.run_cli("lint", *extra, *arguments)

    def counts(self) -> Dict[str, Dict[str, int]]:
        """The baseline file's counts."""
        loaded = baseline.load_baseline(self.root)
        self.assertIsNotNone(loaded)
        return loaded or {}


class RegressionTests(LintCase):
    """lint: what fails, and what it prints."""

    def test_no_baseline_makes_every_violation_a_regression(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=NO_DATE))
        status, out, err = self.lint()
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines()[0], "docs/user/a.md:1-1  -  date: 2 now, baseline 0")
        self.assertIn("doclib lint: no .claude/skills/doc-library/lint-baseline.json; every violation counts", err)
        self.assertIn("doclib lint: 1 regressions on 1 pages", err)

    def test_a_regression_prints_its_violations_as_hits(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES))
        _, out, _ = self.lint()
        self.assertEqual(out.splitlines(), [
            "docs/user/a.md:1-1  -  date: 2 now, baseline 0",
            "docs/user/a.md:3-3  A  date: date October 12",
            "docs/user/a.md:4-4  A  date: date October 13",
        ])

    def test_within_the_baseline_passes(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 2}, "docs/user/b.md": {"date": 1}})
        status, out, err = self.lint()
        self.assertEqual((status, out), (0, ""))
        self.assertEqual(err, "doclib lint: no page got worse (3 violations, all within the baseline)\n")

    def test_a_page_getting_worse_fails_and_names_the_page_and_rule(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}, "docs/user/b.md": {"date": 1}})
        status, out, err = self.lint()
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines()[0], "docs/user/a.md:1-1  -  date: 2 now, baseline 1")
        self.assertEqual(len(out.splitlines()), 3)  # b is within its baseline and not listed
        self.assertIn("doclib lint: 1 regressions on 1 pages", err)

    def test_a_rule_the_baseline_lacks_for_a_page_counts_zero(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"emoji": 5}})
        self.assertEqual(self.lint()[0], 1)

    def test_lower_counts_than_the_baseline_pass(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 4}})
        self.assertEqual(self.lint()[0], 0)

    def test_max_caps_the_hits_in_all(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        status, out, err = self.lint("--max", "2")
        self.assertEqual((status, len(out.splitlines())), (1, 2))
        self.assertIn("2 of 5 hits shown", err)

    def test_the_default_cap_is_twenty_hits(self) -> None:
        self.write_tree(self.docs(a="# A\n\n" + "On October 12 it began.\n" * 30))
        _, out, _ = self.lint()
        self.assertEqual(len(out.splitlines()), 20)

    def test_json_hits(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE))
        _, out, _ = self.lint("--json")
        first, second = (json.loads(line) for line in out.splitlines())
        self.assertEqual((first["path"], first["regression"], first["rule"], first["now"], first["baseline"]),
                         ("docs/user/a.md", True, "date", 1, 0))
        self.assertEqual((second["rule"], second["detail"], second["start"]), ("date", "date October 14", 3))

    def test_nothing_to_report_in_a_clean_repository(self) -> None:
        self.write_tree(self.docs(a=NO_DATE))
        status, out, err = self.lint()
        self.assertEqual((status, out), (0, ""))
        self.assertIn("no page got worse (0 violations", err)

    def test_the_other_rules_run_when_none_is_chosen(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n\nOne. Two.\n"})
        status, out, _ = self.run_cli("lint")
        self.assertEqual(status, 1)
        self.assertIn("marker-missing: 1 now, baseline 0", out)
        self.assertIn("sentences-per-line: 1 now, baseline 0", out)


class UpdateBaselineTests(LintCase):
    """--update-baseline and --rebuild-baseline."""

    def test_makes_the_file_when_there_is_none(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        status, out, err = self.lint("--update-baseline")
        self.assertEqual((status, out), (0, ""))
        self.assertIn("made .claude/skills/doc-library/lint-baseline.json from today's counts", err)
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 2}, "docs/user/b.md": {"date": 1}})
        self.assertEqual(self.lint()[0], 0)

    def test_lowers_and_prints_each_change(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE, b=NO_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 3}, "docs/user/b.md": {"date": 2}})
        status, out, err = self.lint("--update-baseline")
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), ["lowered docs/user/a.md date 3 -> 1", "lowered docs/user/b.md date 2 -> 0"])
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1}})
        self.assertIn("no page got worse", err)

    def test_never_raises_a_count_and_then_fails_on_the_regression(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}})
        status, out, _ = self.lint("--update-baseline")
        self.assertEqual(status, 1)
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1}})
        self.assertIn("docs/user/a.md:1-1  -  date: 2 now, baseline 1", out)

    def test_never_adds_a_page_the_baseline_lacks(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE, b=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}})
        status, _, _ = self.lint("--update-baseline")
        self.assertEqual(status, 1)
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1}})

    def test_drops_pages_that_no_longer_exist(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}, "docs/user/gone.md": {"date": 4}})
        status, out, _ = self.lint("--update-baseline")
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), ["lowered docs/user/gone.md date 4 -> 0"])
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1}})

    def test_leaves_the_file_alone_when_nothing_changes(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}})
        path = self.root / baseline.BASELINE
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")  # a mark that a rewrite would remove
        self.lint("--update-baseline")
        self.assertTrue(path.read_text(encoding="utf-8").endswith("}\n\n"))

    def test_with_a_rule_chosen_only_that_rule_is_lowered(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n\nOn October 12.\n"})
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 4, "line-length": 9, "emoji": 2}, "docs/user/gone.md": {"emoji": 1}})
        status, out, _ = self.run_cli("lint", "--rule", "date", "--update-baseline")
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), ["lowered docs/user/a.md date 4 -> 1", "lowered docs/user/gone.md emoji 1 -> 0"])
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1, "line-length": 9, "emoji": 2}})

    def test_with_a_page_chosen_only_that_page_is_lowered(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE, b=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 5}, "docs/user/b.md": {"date": 5}})
        self.lint("--page", "docs/user/a.md", "--update-baseline")
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 1}, "docs/user/b.md": {"date": 5}})

    def test_rebuild_raises_where_the_counts_rose(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=NO_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}, "docs/user/b.md": {"date": 3}})
        status, out, err = self.lint("--rebuild-baseline")
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), ["raised docs/user/a.md date 1 -> 2", "lowered docs/user/b.md date 3 -> 0"])
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 2}})
        self.assertIn("no page got worse", err)

    def test_rebuild_with_a_rule_chosen_keeps_the_other_rules(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"emoji": 7}})
        self.lint("--rebuild-baseline")
        self.assertEqual(self.counts(), {"docs/user/a.md": {"date": 2, "emoji": 7}})

    def test_the_help_says_rebuild_is_for_the_orchestrator(self) -> None:
        _, out, _ = self.run_cli("lint", "--help")
        self.assertIn("orchestrator", out)

    def test_the_modes_exclude_each_other(self) -> None:
        self.write_tree(self.docs(a=NO_DATE))
        self.assertEqual(self.lint("--report", "--update-baseline")[0], 2)
        self.assertEqual(self.lint("--update-baseline", "--rebuild-baseline")[0], 2)


class ReportTests(LintCase):
    """--report: every violation, then the totals."""

    def test_hits_then_totals_and_exit_zero(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        status, out, _ = self.lint("--report")
        self.assertEqual(status, 0)
        self.assertEqual(out.splitlines(), [
            "docs/user/a.md:3-3  A  date: date October 12",
            "docs/user/a.md:4-4  A  date: date October 13",
            "docs/user/b.md:3-3  B  date: date October 14",
            "total date: 3 on 2 pages",
            "total: 3 violations on 2 pages",
        ])

    def test_every_rule_has_a_totals_line_in_order(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES))
        status, out, _ = self.run_cli("lint", "--report", "--max", "0")
        self.assertEqual(status, 0)
        totals = [line.split(":")[0] for line in out.splitlines() if line.startswith("total")]
        self.assertEqual(totals[-1], "total")
        self.assertEqual(totals[:-1], ["total " + name for name in lintrules.rule_names()])
        self.assertIn("total date: 2 on 1 pages", out)
        self.assertIn("total sales-word: 0 on 0 pages", out)

    def test_report_ignores_the_baseline(self) -> None:
        self.write_tree(self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 9}})
        status, out, _ = self.lint("--report")
        self.assertEqual(status, 0)
        self.assertIn("total: 1 violations on 1 pages", out)

    def test_max_caps_the_hits_but_not_the_totals(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        _, out, err = self.lint("--report", "--max", "1")
        self.assertEqual(len(out.splitlines()), 3)
        self.assertIn("total: 3 violations on 2 pages", out)
        self.assertIn("1 of 3 violations shown", err)

    def test_json_hits_and_a_last_object_of_totals(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        _, out, _ = self.lint("--report", "--json")
        rows = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["rule"], "date")
        self.assertEqual(rows[-1], {"totals": {"date": {"violations": 3, "pages": 2}}, "violations": 3, "pages": 2})


class OptionTests(LintCase):
    """--rule, --skip, and --page."""

    def test_rule_keeps_only_those_rules(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n\nOn October 12. Two.\n"})
        _, out, _ = self.run_cli("lint", "--rule", "date,sentences-per-line", "--report", "--max", "0")
        self.assertIn("total date: 1", out)
        self.assertIn("total sentences-per-line: 1", out)
        self.assertNotIn("marker-missing", out)

    def test_skip_leaves_rules_out(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n\nOn October 12. Two.\n"})
        _, out, _ = self.run_cli("lint", "--skip", "date,marker-missing", "--report", "--max", "0")
        self.assertNotIn("total date", out)
        self.assertNotIn("total marker-missing", out)
        self.assertIn("total sentences-per-line: 1", out)

    def test_rule_and_skip_together(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n\nOn October 12. Two.\n"})
        _, out, _ = self.run_cli("lint", "--rule", "date,emoji", "--skip", "emoji", "--report")
        self.assertEqual([line for line in out.splitlines() if line.startswith("total")], ["total date: 1 on 1 pages", "total: 1 violations on 1 pages"])

    def test_an_unknown_rule_is_a_usage_error_naming_the_rules(self) -> None:
        self.write_tree(self.docs(a=NO_DATE))
        for option in ("--rule", "--skip"):
            with self.subTest(option=option):
                status, out, err = self.run_cli("lint", option, "date,nonsense")
                self.assertEqual((status, out), (2, ""))
                self.assertIn("unknown rule 'nonsense'", err)
                self.assertIn("line-length", err)

    def test_page_keeps_one_page_by_its_tail(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        _, out, _ = self.lint("--page", "b", "--report")
        self.assertEqual(out.splitlines(), ["docs/user/b.md:3-3  B  date: date October 14", "total date: 1 on 1 pages", "total: 1 violations on 1 pages"])

    def test_the_baseline_comparison_covers_only_the_chosen_page_and_rule(self) -> None:
        self.write_tree(self.docs(a=TWO_DATES, b=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 0}, "docs/user/b.md": {"date": 1}})
        self.assertEqual(self.lint("--page", "b")[0], 0)
        self.assertEqual(self.lint("--page", "a")[0], 1)
        self.assertEqual(self.run_cli("lint", "--rule", "emoji")[0], 0)

    def test_a_page_the_lint_does_not_cover_is_a_usage_error(self) -> None:
        self.write_tree({"docs/user/a.md": "# A\n", "research/R.md": "# R\n"})
        status, _, err = self.run_cli("lint", "--page", "research/R.md")
        self.assertEqual(status, 2)
        self.assertIn("not a page the lint covers", err)
        self.assertEqual(self.run_cli("lint", "--page", "nonesuch")[0], 2)


class AgainstTests(LintCase):
    """--against REF: no rule's baseline total may rise above the merge base's."""

    def start(self, counts: Dict[str, Dict[str, int]], pages: Dict[str, str]) -> None:
        """Make a repository on ``main`` holding ``pages`` and a baseline of ``counts``, then a branch."""
        baseline.write_baseline(self.root, counts)
        self.git_repo(pages)
        self.git("switch", "-q", "-c", "feature")

    def test_a_total_raised_by_hand_fails(self) -> None:
        pages = self.docs(a=TWO_DATES, b=ONE_DATE)
        self.start({"docs/user/a.md": {"date": 2}, "docs/user/b.md": {"date": 1}}, pages)
        base = self.git("rev-parse", "HEAD").strip()
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 3}, "docs/user/b.md": {"date": 1}})
        self.commit_all("raised by hand")
        status, out, err = self.lint("--against", "main")
        self.assertEqual((status, out), (1, ""))
        self.assertIn(f"baseline raised: date total 4, 3 at {base[:9]}", err)

    def test_counts_moved_between_pages_pass(self) -> None:
        pages = self.docs(a=TWO_DATES, b=ONE_DATE)
        self.start({"docs/user/a.md": {"date": 2}, "docs/user/b.md": {"date": 1}}, pages)
        # A split: a's counts move to a page of its own, the total stays 3.
        self.write_tree({"docs/user/a.md": ONE_DATE, "docs/user/a-two.md": ONE_DATE, "docs/user/b.md": ONE_DATE})
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}, "docs/user/a-two.md": {"date": 1}, "docs/user/b.md": {"date": 1}})
        self.commit_all("split")
        status, _, err = self.lint("--against", "main")
        self.assertEqual(status, 0)
        self.assertIn("no page got worse", err)

    def test_a_lowered_baseline_passes(self) -> None:
        self.start({"docs/user/a.md": {"date": 2}}, self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}})
        self.commit_all("lowered")
        self.assertEqual(self.lint("--against", "main")[0], 0)

    def test_no_baseline_at_the_base_skips_the_check(self) -> None:
        self.git_repo(self.docs(a=ONE_DATE))
        self.git("switch", "-q", "-c", "feature")
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1}})
        self.commit_all("first baseline")
        self.assertEqual(self.lint("--against", "main")[0], 0)

    def test_no_baseline_file_now_skips_the_check_but_every_violation_counts(self) -> None:
        self.git_repo(self.docs(a=ONE_DATE))
        status, _, err = self.lint("--against", "main")
        self.assertEqual(status, 1)
        self.assertNotIn("baseline raised", err)

    def test_the_merge_hook_form_compares_the_working_file_with_head(self) -> None:
        self.start({"docs/user/a.md": {"date": 1}}, self.docs(a=ONE_DATE))
        self.assertEqual(self.lint("--against", "HEAD")[0], 0)
        # An uncommitted hand edit that raises the total.
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 2}})
        status, _, err = self.lint("--against", "HEAD")
        self.assertEqual(status, 1)
        self.assertIn("baseline raised: date total 2, 1 at", err)

    def test_the_check_covers_only_the_chosen_rules(self) -> None:
        self.start({"docs/user/a.md": {"date": 1, "emoji": 1}}, self.docs(a=ONE_DATE))
        baseline.write_baseline(self.root, {"docs/user/a.md": {"date": 1, "emoji": 5}})
        self.commit_all("raised emoji")
        self.assertEqual(self.lint("--against", "main")[0], 0)
        status, _, err = self.run_cli("lint", "--rule", "emoji", "--against", "main")
        self.assertEqual(status, 1)
        self.assertIn("baseline raised: emoji total 5, 1 at", err)

    def test_an_unknown_ref_is_a_usage_error(self) -> None:
        self.start({"docs/user/a.md": {"date": 1}}, self.docs(a=ONE_DATE))
        status, _, err = self.lint("--against", "no-such-ref")
        self.assertEqual(status, 2)
        self.assertIn("no merge base of no-such-ref and HEAD", err)

    def test_update_baseline_then_checks_the_new_file(self) -> None:
        self.start({"docs/user/a.md": {"date": 3}}, self.docs(a=ONE_DATE))
        status, out, _ = self.lint("--update-baseline", "--against", "main")
        self.assertEqual(status, 0)
        self.assertIn("lowered docs/user/a.md date 3 -> 1", out)
