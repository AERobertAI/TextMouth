"""The lint's ratchet: how many violations of each rule each page may still have.

``lint-baseline.json`` records, for each page, the count of each rule's violations on
the day it was written. The lint fails only when a page has *more* violations of a rule
than the file records (a page or rule missing from it counts 0), so the lint can gate
merges while the docs are still being fixed: a page may not get worse.

The file holds one page for each line, with pages and rules sorted, so two branches
that lower different pages merge without a conflict:

    {
      "version": 1,
      "pages": {
        "AGENTS.md": {"date": 61, "line-length": 69},
        "README.md": {"index-line": 20}
      }
    }

Everything here is pure except ``load_baseline``, ``baseline_at``, ``merge_base`` and
``write_baseline``, which read or write the file inside the repository folder they are
given (or ask git about it).
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

import output
from lintrules import Violation

# Where the baseline lives, from the repository's root.
BASELINE = ".claude/skills/doc-library/lint-baseline.json"
# The only form of the file this code reads and writes.
VERSION = 1
# The suffix of the file a write goes through before it replaces the baseline.
TEMPORARY_SUFFIX = ".tmp"

# Each page's count of each rule's violations; zero counts are left out.
Counts = Dict[str, Dict[str, int]]
# One difference between two baselines: (page, rule, before, after).
Change = Tuple[str, str, int, int]


def normalized(data: Counts) -> Counts:
    """A copy of ``data`` without zero counts and without pages that hold none."""
    result: Counts = {}
    for page, rules in data.items():
        kept = {rule: count for rule, count in rules.items() if count > 0}
        if kept:
            result[page] = kept
    return result


def counts(violations: Iterable[Violation]) -> Counts:
    """The count of each rule's violations on each page."""
    result: Counts = {}
    for found in violations:
        rules = result.setdefault(found.page, {})
        rules[found.rule] = rules.get(found.rule, 0) + 1
    return result


def read_baseline(text: str) -> Counts:
    """The counts in the baseline file's ``text``; a UsageError when it is not a baseline."""
    try:
        data = json.loads(text)
    except ValueError as error:
        raise output.UsageError(f"{BASELINE} is not JSON: {error}") from None
    if not isinstance(data, dict) or data.get("version") != VERSION or not isinstance(data.get("pages"), dict):
        raise output.UsageError(f'{BASELINE} is not a version {VERSION} baseline: {{"version": {VERSION}, "pages": {{...}}}}')
    result: Counts = {}
    for page, rules in data["pages"].items():
        ok = isinstance(rules, dict) and all(isinstance(n, int) and not isinstance(n, bool) and n >= 0 for n in rules.values())
        if not ok:
            raise output.UsageError(f"{BASELINE}: the counts of {page} are not whole numbers by rule")
        result[page] = dict(rules)
    return normalized(result)


def load_baseline(root: Path) -> Optional[Counts]:
    """The baseline file of the repository at ``root``; None when the file is not there."""
    path = root / BASELINE
    if not path.is_file():
        return None
    return read_baseline(path.read_text(encoding="utf-8"))


def _git(root: Path, *arguments: str) -> "subprocess.CompletedProcess[str]":
    """Run one git command in the repository at ``root`` and return its result."""
    try:
        return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    except OSError as error:
        raise output.UsageError(f"cannot run git: {error}") from None


def _refuse_option(ref: str) -> None:
    """Refuse a ``ref`` that git would read as an option."""
    if not ref or ref.startswith("-"):
        raise output.UsageError(f"{ref!r} is not a commit name")


def merge_base(root: Path, ref: str) -> str:
    """The commit where ``ref`` and ``HEAD`` last agree (``git merge-base``); a UsageError when there is none."""
    _refuse_option(ref)
    result = _git(root, "merge-base", ref, "HEAD")
    commit = result.stdout.strip()
    if result.returncode != 0 or not commit:
        raise output.UsageError(f"no merge base of {ref} and HEAD (is {ref} a branch or commit?)")
    return commit


def baseline_at(root: Path, ref: str) -> Optional[Counts]:
    """The baseline file as committed at ``ref``; None when that commit has no such file."""
    _refuse_option(ref)
    result = _git(root, "show", f"{ref}:{BASELINE}")
    if result.returncode != 0:
        return None
    return read_baseline(result.stdout)


def format_baseline(data: Counts) -> str:
    """The text of the baseline file for ``data``: one page for each line, everything sorted."""
    data = normalized(data)
    lines = ["{", f'  "version": {VERSION},']
    if not data:
        lines.append('  "pages": {}')
    else:
        lines.append('  "pages": {')
        pages = sorted(data)
        for index, page in enumerate(pages):
            cells = ", ".join(f"{json.dumps(rule)}: {count}" for rule, count in sorted(data[page].items()))
            comma = "," if index < len(pages) - 1 else ""
            lines.append(f"    {json.dumps(page, ensure_ascii=False)}: {{{cells}}}{comma}")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_baseline(root: Path, data: Counts) -> None:
    """Write ``data`` as the baseline file, so that a failed write never leaves half a file.

    The text goes to a temporary file in the same folder and replaces the baseline in
    one step (``os.replace``). The temporary file has one fixed name, so a write that
    fails leaves at most that one file, which the next write overwrites.
    """
    path = root / BASELINE
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + TEMPORARY_SUFFIX)
    temporary.write_text(format_baseline(data), encoding="utf-8")
    os.replace(temporary, path)


def lowered(old: Counts, now: Counts, pages_present: Set[str]) -> Counts:
    """``old`` with each count made the smaller of itself and today's, and gone pages dropped.

    Never raises a count and never adds a page or rule: a violation ``old`` does not
    record stays a regression. A page not in ``pages_present`` no longer exists, so
    its counts are dropped.
    """
    result: Counts = {}
    for page, rules in old.items():
        if page not in pages_present:
            continue
        for rule, count in rules.items():
            smaller = min(count, now.get(page, {}).get(rule, 0))
            if smaller > 0:
                result.setdefault(page, {})[rule] = smaller
    return result


def regressions(base: Counts, now: Counts) -> List[Tuple[str, str, int, int]]:
    """Every ``(page, rule, now, base)`` where today's count is above the baseline's, by page then rule."""
    found = []
    for page in sorted(now):
        for rule in sorted(now[page]):
            recorded = base.get(page, {}).get(rule, 0)
            if now[page][rule] > recorded:
                found.append((page, rule, now[page][rule], recorded))
    return found


def totals(data: Counts) -> Dict[str, int]:
    """The count of each rule over all pages."""
    result: Dict[str, int] = {}
    for rules in data.values():
        for rule, count in rules.items():
            result[rule] = result.get(rule, 0) + count
    return result


def _selected(page: str, rule: str, rules: Optional[Set[str]], pages: Optional[Set[str]]) -> bool:
    """Whether ``(page, rule)`` is among the chosen rules and pages (None chooses all)."""
    return (rules is None or rule in rules) and (pages is None or page in pages)


def restrict(data: Counts, rules: Optional[Set[str]] = None, pages: Optional[Set[str]] = None) -> Counts:
    """The counts of ``data`` for the chosen rules and pages only (None chooses all)."""
    return normalized({page: {rule: count for rule, count in kinds.items() if _selected(page, rule, rules, pages)}
                       for page, kinds in data.items()})


def without(data: Counts, rules: Optional[Set[str]] = None, pages: Optional[Set[str]] = None) -> Counts:
    """The counts of ``data`` that ``restrict`` with the same choice leaves out."""
    return normalized({page: {rule: count for rule, count in kinds.items() if not _selected(page, rule, rules, pages)}
                       for page, kinds in data.items()})


def present_only(data: Counts, pages_present: Set[str]) -> Counts:
    """The counts of ``data`` for the pages in ``pages_present``."""
    return {page: dict(kinds) for page, kinds in data.items() if page in pages_present}


def merged(first: Counts, second: Counts) -> Counts:
    """Both sets of counts in one; where both have a page's rule, ``second``'s count stands."""
    result: Counts = {page: dict(kinds) for page, kinds in first.items()}
    for page, kinds in second.items():
        result.setdefault(page, {}).update(kinds)
    return normalized(result)


def changes(before: Counts, after: Counts) -> List[Change]:
    """Each ``(page, rule, before, after)`` where the counts differ, by page then rule."""
    found: List[Change] = []
    for page in sorted(set(before) | set(after)):
        old, new = before.get(page, {}), after.get(page, {})
        for rule in sorted(set(old) | set(new)):
            if old.get(rule, 0) != new.get(rule, 0):
                found.append((page, rule, old.get(rule, 0), new.get(rule, 0)))
    return found
