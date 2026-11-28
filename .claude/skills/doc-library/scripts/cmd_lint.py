"""``lint``: check the docs against docs/agents/writing-docs.md, with a ratchet.

    python3 -I .claude/skills/doc-library/scripts/doclib.py lint
    python3 -I .claude/skills/doc-library/scripts/doclib.py lint --report
    python3 -I .claude/skills/doc-library/scripts/doclib.py lint --update-baseline

``lint`` fails (exit 1) only where a page has more violations of a rule than
``lint-baseline.json`` records (see ``baseline.py``), and prints each such page and rule
with its violations as hits. ``--report`` lists every violation with totals by rule.
``--update-baseline`` lowers the baseline to today's counts and never raises one.
``--against REF`` also fails when a rule's total in the baseline is above its total in
the baseline at the merge base of REF and HEAD, which stops a count being raised by
hand while allowing a page split to move counts between pages.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Iterator, List, Optional, Set, Tuple

import baseline
import docmodel
import lintrules
import output
import targets
from baseline import Counts
from lintrules import Violation
from output import Hit

# How much of a commit's name a message shows.
SHORT_COMMIT = 9


def rule_list(text: str) -> List[str]:
    """argparse type for ``--rule`` and ``--skip``: rule names separated by commas."""
    return [name.strip() for name in text.split(",") if name.strip()]


def chosen_rules(args: Any) -> List[str]:
    """The rules to run, in report order: ``--rule``'s (all by default) less ``--skip``'s."""
    names = lintrules.rule_names()
    kept = lintrules.check_rule_names(args.rule) if args.rule else names
    skipped = lintrules.check_rule_names(args.skip) if args.skip else []
    return [name for name in names if name in kept and name not in skipped]


def chosen_page(args: Any) -> Optional[str]:
    """The one page ``--page`` names, which must be a page the lint covers; None without the option."""
    if not args.page:
        return None
    page = targets.resolve_page(args.root, args.page)
    if page not in docmodel.lint_pages(args.root):
        raise output.UsageError(f"{page} is not a page the lint covers (the docs, AGENTS.md, and CLAUDE.md)")
    return page


def violation_hit(found: Violation) -> Hit:
    """The hit that shows one violation: its place, section, and ``rule: detail``."""
    return Hit(found.page, found.start, found.end, found.heading, f"{found.rule}: {found.detail}",
               extra={"rule": found.rule, "detail": found.detail})


def regression_hits(violations: List[Violation], regressed: List[Tuple[str, str, int, int]]) -> Iterator[Hit]:
    """For each regression its heading line, then that page's violations of that rule."""
    for page, rule, now, recorded in regressed:
        yield Hit(page, 1, 1, "", f"{rule}: {now} now, baseline {recorded}",
                  extra={"regression": True, "rule": rule, "now": now, "baseline": recorded})
        for found in violations:
            if found.page == page and found.rule == rule:
                yield violation_hit(found)


def print_changes(before: Counts, after: Counts) -> None:
    """Print one line for each count that differs: ``lowered PAGE RULE B -> N`` (or ``raised``)."""
    for page, rule, old, new in baseline.changes(before, after):
        print(f"{'lowered' if new < old else 'raised'} {page} {rule} {old} -> {new}")


def settle_baseline(args: Any, now: Counts, rules: Set[str], pages: Optional[Set[str]]) -> Counts:
    """Apply ``--update-baseline`` or ``--rebuild-baseline`` (when given) and return the baseline in force.

    Only the chosen rules and pages are touched; the rest of the file stays, less the
    pages that no longer exist. With no file yet, ``--update-baseline`` makes one from
    today's counts. The file is written only when its counts change.
    """
    existing = baseline.load_baseline(args.root)
    old = existing or {}
    if not (args.update_baseline or args.rebuild_baseline):
        return old
    present = set(docmodel.lint_pages(args.root))
    chosen_old = baseline.restrict(old, rules, pages)
    if args.update_baseline and existing is not None:
        replaced = baseline.lowered(chosen_old, now, present)
    else:
        replaced = now
    new = baseline.merged(baseline.present_only(baseline.without(old, rules, pages), present), replaced)
    if existing is None:
        print(f"doclib lint: made {baseline.BASELINE} from today's counts", file=sys.stderr)
    else:
        print_changes(old, new)
    if existing is None or new != old:
        baseline.write_baseline(args.root, new)
    return new


def against_failures(args: Any, rules: List[str]) -> List[str]:
    """The ``baseline raised`` messages: rules whose baseline total is above the one at the merge base.

    Nothing to say without a baseline file now or at the merge base. Pages are not
    compared one by one, so a split page may move counts without failing.
    """
    current = baseline.load_baseline(args.root)
    if current is None:
        return []
    commit = baseline.merge_base(args.root, args.against)
    earlier = baseline.baseline_at(args.root, commit)
    if earlier is None:
        return []
    now_totals, then_totals = baseline.totals(current), baseline.totals(earlier)
    return [f"baseline raised: {rule} total {now_totals.get(rule, 0)}, {then_totals.get(rule, 0)} at {commit[:SHORT_COMMIT]}"
            for rule in rules if now_totals.get(rule, 0) > then_totals.get(rule, 0)]


def report(args: Any, violations: List[Violation], rules: List[str]) -> int:
    """``--report``: every violation as a hit, then the totals by rule and in all; exit status 0."""
    output.emit((violation_hit(found) for found in violations), args, noun="violations")
    summary = {}
    for rule in rules:
        of_rule = [found for found in violations if found.rule == rule]
        summary[rule] = {"violations": len(of_rule), "pages": len({found.page for found in of_rule})}
    pages = len({found.page for found in violations})
    if args.json:
        print(json.dumps({"totals": summary, "violations": len(violations), "pages": pages}, ensure_ascii=False))
        return output.EXIT_OK
    for rule in rules:
        print(f"total {rule}: {summary[rule]['violations']} on {summary[rule]['pages']} pages")
    print(f"total: {len(violations)} violations on {pages} pages")
    return output.EXIT_OK


def run(args: Any) -> int:
    """Run the lint: report, update or rebuild the baseline, and fail on a regression."""
    rules = chosen_rules(args)
    page = chosen_page(args)
    violations = lintrules.lint(args.root, rules)
    if page:
        violations = [found for found in violations if found.page == page]
    if args.report:
        return report(args, violations, rules)
    now = baseline.counts(violations)
    base = settle_baseline(args, now, set(rules), {page} if page else None)
    if not (args.root / baseline.BASELINE).is_file():
        print(f"doclib lint: no {baseline.BASELINE}; every violation counts", file=sys.stderr)
    regressed = baseline.regressions(base, now)
    output.emit(regression_hits(violations, regressed), args, noun="hits")
    raised = against_failures(args, rules) if args.against else []
    for message in raised:
        print(f"doclib lint: {message}", file=sys.stderr)
    if regressed:
        print(f"doclib lint: {len(regressed)} regressions on {len({entry[0] for entry in regressed})} pages", file=sys.stderr)
    elif raised:
        print(f"doclib lint: baseline raised on {len(raised)} rules", file=sys.stderr)
    else:
        print(f"doclib lint: no page got worse ({len(violations)} violations, all within the baseline)", file=sys.stderr)
    return output.EXIT_NONE if regressed or raised else output.EXIT_OK


def register(subparsers: Any, common: Any) -> None:
    """Add the ``lint`` subcommand."""
    parser = subparsers.add_parser(
        "lint", parents=[common], help="check the docs against writing-docs.md; fail where a page got worse",
        description="Check the docs against docs/agents/writing-docs.md. Fails only where a page has more "
                    "violations of a rule than lint-baseline.json records. --scope does not apply: the lint "
                    "covers the docs, AGENTS.md, and CLAUDE.md.")
    parser.add_argument("--rule", type=rule_list, metavar="R[,R]", help="run only these rules: " + ", ".join(lintrules.rule_names()))
    parser.add_argument("--skip", type=rule_list, metavar="R[,R]", help="leave these rules out")
    parser.add_argument("--page", metavar="PAGE", help="check one page (a path, or its tail)")
    parser.add_argument("--against", metavar="REF",
                        help="also fail when a rule's total in the baseline is above its total at the merge base of REF and HEAD")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--report", action="store_true", help="list every violation and the totals by rule; exit 0")
    modes.add_argument("--update-baseline", action="store_true",
                       help="lower the baseline to today's counts (never raising one), or make it; then lint")
    modes.add_argument("--rebuild-baseline", action="store_true",
                       help="for the orchestrator alone, after it accepts a regression: write today's counts, raising where they rose")
    parser.set_defaults(func=run, default_max=output.DEFAULT_MAX)
