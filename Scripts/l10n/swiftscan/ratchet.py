"""The lint's ratchet: how many unlocalized interface literals each file may still hold.

``Scripts/l10n/scan-baseline.json`` records, for each file, how many unlocalized interface
literals it had when the baseline was last lowered. The lint fails when a file has more than
its baseline (a file the baseline does not list has a baseline of zero) and prints the
literals; a file with fewer passes, and ``--update-baseline`` then lowers its record, so a file
can only ever get cleaner. A file that reaches zero leaves the baseline.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

from .classify import NOTE_PROBLEM_HELP
from .lexer import Literal

# The version of the baseline file's format.
BASELINE_VERSION = 1
# The rule about the baseline, in the lint's failure text and its --help: the lint passes while
# each file's count is at most its baseline, so a baseline left high fails nothing, and a branch
# that edited it would only conflict with the others (the merge lowers it).
BASELINE_RULE = ("Never edit scan-baseline.json to make the lint pass: localize the text. The merge chain "
                 "lowers it after every merge, and a baseline left high fails nothing.")


@dataclass
class Problem:
    """A file whose count rose above its baseline."""

    file: str
    baseline: int
    count: int
    literals: List[Literal]   # the literals to show: those on lines the branch added, or all


def unlocalized_by_file(literals: Iterable[Literal]) -> Dict[str, List[Literal]]:
    """The unlocalized interface literals, grouped by file (a file with none is absent)."""
    out: Dict[str, List[Literal]] = {}
    for lit in literals:
        if lit.status == "unlocalized":
            out.setdefault(lit.file, []).append(lit)
    return out


def counts_by_file(literals: Iterable[Literal]) -> Dict[str, int]:
    """Each file's count of unlocalized interface literals, omitting the files with none."""
    return {file: len(items) for file, items in unlocalized_by_file(literals).items()}


def read_baseline(path: Path) -> Dict[str, int]:
    """Reads the baseline's counts, or raises ValueError when the file is not a baseline."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValueError(f"{path.name} does not exist; the orchestrator makes it with --rebuild-baseline")
    except json.JSONDecodeError as error:
        raise ValueError(f"{path.name} is not valid JSON: {error}")
    files = data.get("files") if isinstance(data, dict) else None
    if not isinstance(files, dict) or data.get("version") != BASELINE_VERSION or \
            not all(isinstance(v, int) and v > 0 for v in files.values()):
        raise ValueError(f"{path.name} is not a version {BASELINE_VERSION} baseline: "
                         '{"version": 1, "files": {"path": count, ...}} with counts above zero')
    return dict(files)


def write_baseline(path: Path, counts: Mapping[str, int]) -> None:
    """Writes the baseline with one file per line and the paths sorted, so that two branches
    that lower different files merge cleanly."""
    data = {"version": BASELINE_VERSION, "files": {f: n for f, n in sorted(counts.items()) if n > 0}}
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def find_problems(baseline: Mapping[str, int], literals: Iterable[Literal],
                  added_lines: Optional[Mapping[str, Set[int]]] = None) -> List[Problem]:
    """The files whose unlocalized count is above their baseline, in path order.

    With ``added_lines`` (file -> line numbers the branch added), a problem lists the literals
    on those lines; when none of the file's literals is on an added line, or the file is not in
    the mapping, it lists them all, since a count cannot say which literal is the new one.
    """
    problems = []
    for file, items in sorted(unlocalized_by_file(literals).items()):
        allowed = baseline.get(file, 0)
        if len(items) <= allowed:
            continue
        lines = (added_lines or {}).get(file)
        shown = [lit for lit in items if lines and lit.line in lines] or items
        problems.append(Problem(file, allowed, len(items), shown))
    return problems


def note_problems(literals: Iterable[Literal]) -> List[Literal]:
    """The literals whose translator's note is wrong (see classify.note_problem), in path and line order. The baseline holds
    these at zero for every file: it has no record of them, and the lint fails on any."""
    return sorted((lit for lit in literals if lit.note_problem), key=lambda lit: (lit.file, lit.line, lit.start))


def format_note_problems(problems: Sequence[Literal], limit: int = 40, width: int = 100) -> List[str]:
    """The lint's failure text for the notes: each literal's file and line, what is wrong, and what the code should say."""
    lines = [f"l10n lint: {len(problems)} localized call{'s' if len(problems) != 1 else ''} with a translator's note that is "
             "missing or in the wrong place (every file's allowance is zero):"]
    for lit in problems[:limit]:
        text = json.dumps(lit.text, ensure_ascii=False)
        room = max(20, width - 40)
        lines.append(f"{lit.file}:{lit.line}: {lit.note_problem} {text if len(text) <= room else text[:room - 1] + '…'}")
    if len(problems) > limit:
        lines.append(f"... and {len(problems) - limit} more")
    for kind in sorted({lit.note_problem for lit in problems}):
        lines.append(f"{kind}: {NOTE_PROBLEM_HELP[kind]}")
    return lines


def lowered_baseline(baseline: Mapping[str, int], counts: Mapping[str, int],
                     renames: Sequence[Tuple[str, str]] = ()) -> Dict[str, int]:
    """The baseline with every count lowered to the current one, files at zero dropped, and
    never a count raised or a file added (a rename moves a file's record to its new path first)."""
    moved = dict(baseline)
    for old, new in renames:
        if old in moved and new not in moved:
            moved[new] = moved.pop(old)
    lowered = {file: min(n, counts.get(file, 0)) for file, n in moved.items()}
    return {file: n for file, n in lowered.items() if n > 0}


def describe_changes(before: Mapping[str, int], after: Mapping[str, int]) -> List[str]:
    """One line for each file the update lowered or dropped."""
    lines = []
    for file in sorted(set(before) | set(after)):
        old, new = before.get(file, 0), after.get(file, 0)
        if new < old:
            lines.append(f"  {file}: {old} -> {new}" if new else f"  {file}: {old} -> 0 (left the baseline)")
    return lines


_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def parse_added_lines(diff: str) -> Dict[str, Set[int]]:
    """The lines a ``git diff --unified=0`` adds, as {path: {line numbers in the new file}}."""
    added: Dict[str, Set[int]] = {}
    current: Optional[str] = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
        else:
            m = _HUNK.match(line)
            if m and current:
                first, count = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
                added.setdefault(current, set()).update(range(first, first + count))
    return added


def format_problems(problems: Sequence[Problem], width: int = 100) -> List[str]:
    """The lint's failure text: each file, its counts, and the literals to look at."""
    lines = [f"l10n lint: {len(problems)} file{'s' if len(problems) != 1 else ''} gained unlocalized interface text:"]
    for p in problems:
        gained = p.count - p.baseline
        lines.append(f"{p.file}: {p.count} unlocalized literals, baseline {p.baseline} (+{gained})")
        if len(p.literals) < p.count:
            lines.append(f"  the {len(p.literals)} on the lines this branch added:")
        for lit in p.literals:
            text = json.dumps(lit.text, ensure_ascii=False)
            room = max(20, width - 24)
            lines.append(f"  line {lit.line} [{lit.bucket}] {text if len(text) <= room else text[:room - 1] + '…'}")
    lines += [
        "Make each one localized with InterfaceText.line(\"<ID>\", \"<English>\") and a `// Translators: ...` line above it;",
        "or, for an identifier, a name the system gives, or a test hook, end its line with `// l10n: no`.",
        "`scan.py show FILE` lists a file's unlocalized literals.",
        BASELINE_RULE,
    ]
    return lines
