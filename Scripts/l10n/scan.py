#!/usr/bin/env python3
"""scan: find the interface text of TextMouth's Swift code that is not localized yet.

Run from anywhere inside the repository or one of its worktrees:

    python3 -I -B Scripts/l10n/scan.py COMMAND [OPTIONS]

Commands:
    report [--by area|file] [--area NAME] [--top N] [--json]
        For each area (a feature) or file: the unlocalized and the localized interface
        strings with their bytes, and the findings the conversion must restructure.
    show FILE [--all] [--width N] [--json]
        Each unlocalized interface literal of one file, with its line and bucket, and the
        file's findings; --all adds the localized and the marked literals.
    lint [--base REF] [--update-baseline | --rebuild-baseline] [--renamed OLD NEW]
        The ratchet behind `make lint-l10n`: fails when a file has more unlocalized interface
        literals than Scripts/l10n/scan-baseline.json records for it (or a file the baseline
        does not list has any), and prints each literal. --update-baseline lowers the counts
        that fell and drops the files that reached zero (never raises one); --rebuild-baseline,
        which only the orchestrator runs, writes the baseline from scratch.

A literal is interface text when it is shown or spoken to the user (see swiftscan/classify.py
for the buckets). It is *localized* when it is the key of a call the compiler extracts
(String(localized:), LocalizedStringResource, Text("..."), .accessibilityLabel("..."), and the
others), *marked* when its line ends with the comment `// l10n: no` (an identifier, a name the
system gives, a test hook), and *unlocalized* otherwise.

Exit status: 0 when the command did its work (for lint: nothing got worse), 1 when lint found a
file that gained unlocalized text, 2 for a command line that names nothing or gives a bad
value. Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set

# No bytecode beside the script: it runs with -B, and this covers a run without it. The folder
# of the script joins the path before the package beside it is imported.
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from swiftscan import areas, ratchet, report  # noqa: E402
from swiftscan.classify import FINDING_HELP  # noqa: E402
from swiftscan.scanner import Scan, scan_tree  # noqa: E402

EXIT_OK = 0      # the command did its work
EXIT_FAIL = 1    # the lint found text that is not localized
EXIT_USAGE = 2   # a bad command line

# The repository root, from this script's place at Scripts/l10n/scan.py.
DEFAULT_ROOT = HERE.parent.parent
# The baseline's place, relative to the repository root.
BASELINE_PATH = Path("Scripts/l10n/scan-baseline.json")
# The longest line `show` prints unless --width says otherwise: two pans of a 40-cell braille display.
DEFAULT_WIDTH = 80


def run_git(root: Path, *args: str) -> Optional[str]:
    """Runs git in the repository and returns its output, or None when it fails."""
    try:
        done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def added_lines(root: Path, base: str) -> Optional[Dict[str, Set[int]]]:
    """The lines of the app's Swift files that the work tree adds since the merge-base of base
    and HEAD, or None when git cannot say (no such ref, no repository)."""
    merge_base = run_git(root, "merge-base", base, "HEAD")
    if merge_base is None:
        return None
    diff = run_git(root, "diff", "--unified=0", "--no-color", "--no-ext-diff", merge_base.strip(), "--", "TextMouth")
    return None if diff is None else ratchet.parse_added_lines(diff)


def quote(text: str, room: int) -> str:
    """A literal's text in quotes on one line, cut with an ellipsis to fit the room."""
    quoted = json.dumps(text, ensure_ascii=False)
    return quoted if len(quoted) <= room else quoted[:room - 1] + "…"


# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------

def cmd_report(args: argparse.Namespace, scan: Scan) -> int:
    """Prints the totals by area or by file."""
    if args.area and args.area not in areas.area_names() + [areas.UNMAPPED]:
        print(f"scan: no area named {args.area}; the areas are: {', '.join(areas.area_names())}", file=sys.stderr)
        return EXIT_USAGE
    if args.json:
        print(json.dumps(report.json_report(scan.literals, scan.files, scan.seconds, args.by, args.area),
                         indent=2, ensure_ascii=False))
    else:
        print(report.text_report(scan.literals, scan.files, scan.seconds, args.by, args.area, args.top))
    return EXIT_OK


def resolve_file(root: Path, name: str, files: Sequence[str]) -> Optional[str]:
    """The scanned file a user's name means: a path from the repository root or from
    TextMouth/, an absolute path, or one relative to the working folder."""
    candidates = [name, f"TextMouth/{name}"]
    for given in (Path(name), Path.cwd() / name):
        try:
            candidates.append(given.resolve().relative_to(root.resolve()).as_posix())
        except ValueError:
            pass
    return next((c for c in candidates if c in set(files)), None)


def cmd_show(args: argparse.Namespace, scan: Scan, root: Path) -> int:
    """Prints one file's unlocalized interface literals and its findings."""
    file = resolve_file(root, args.file, scan.files)
    if file is None:
        print(f"scan: {args.file} is not a Swift file under TextMouth/", file=sys.stderr)
        return EXIT_USAGE
    wanted = ("unlocalized", "localized", "marked") if args.all else ("unlocalized",)
    items = [lit for lit in scan.literals if lit.file == file and lit.status in wanted]
    counts = {s: sum(1 for lit in scan.literals if lit.file == file and lit.status == s)
              for s in ("unlocalized", "localized", "marked")}
    if args.json:
        print(json.dumps({
            "file": file, "area": areas.area_of(file), **{s: n for s, n in counts.items()},
            "literals": [{"line": lit.line, "bucket": lit.bucket, "rule": lit.rule, "status": lit.status,
                          "text": lit.text, "findings": list(lit.findings)} for lit in items],
        }, indent=2, ensure_ascii=False))
        return EXIT_OK
    print(f"{file} (area {areas.area_of(file)}): {counts['unlocalized']} unlocalized, "
          f"{counts['localized']} localized, {counts['marked']} marked.")
    for lit in items:
        label = f"line {lit.line} [{lit.bucket}]" + (f" {lit.status}" if args.all else "")
        print(f"  {label} {quote(lit.text, max(20, args.width - len(label) - 3))}")
    found = [(lit.line, kind) for lit in scan.literals if lit.file == file for kind in lit.findings]
    if found:
        print("findings:")
        seen = set()
        for line, kind in sorted(found):
            if (line, kind) not in seen:
                seen.add((line, kind))
                print(f"  line {line}: {kind}")
        # What each kind that occurs asks of the conversion.
        for kind in sorted({kind for _line, kind in found}):
            print(f"  {kind}: {FINDING_HELP[kind]}")
    return EXIT_OK


def cmd_lint(args: argparse.Namespace, scan: Scan, root: Path) -> int:
    """Checks the literals against the baseline, and updates or rebuilds the baseline on request."""
    path = Path(args.baseline) if args.baseline else root / BASELINE_PATH
    counts = ratchet.counts_by_file(scan.literals)
    if args.rebuild_baseline:
        ratchet.write_baseline(path, counts)
        print(f"l10n lint: wrote {path.name}: {sum(counts.values()):,} unlocalized literals in {len(counts)} files.")
        return EXIT_OK
    try:
        baseline = ratchet.read_baseline(path)
    except ValueError as error:
        print(f"scan: {error}", file=sys.stderr)
        return EXIT_USAGE
    if args.update_baseline:
        lowered = ratchet.lowered_baseline(baseline, counts, args.renamed or ())
        if lowered != baseline:
            ratchet.write_baseline(path, lowered)
            print(f"l10n lint: lowered the baseline for {len(ratchet.describe_changes(baseline, lowered))} files:")
            print("\n".join(ratchet.describe_changes(baseline, lowered)))
        else:
            print("l10n lint: the baseline is already as low as the code.")
        baseline = lowered
    elif args.renamed:
        print("scan: --renamed goes with --update-baseline", file=sys.stderr)
        return EXIT_USAGE
    problems = ratchet.find_problems(baseline, scan.literals, added_lines(root, args.base) if args.base else None)
    if problems:
        print("\n".join(ratchet.format_problems(problems)))
        vanished = sorted(f for f in baseline if f not in set(scan.files))
        if vanished:
            print("Baseline entries of files that are gone (a rename? --update-baseline --renamed OLD NEW): "
                  + ", ".join(vanished))
        return EXIT_FAIL
    lower = sum(1 for f, n in baseline.items() if counts.get(f, 0) < n)
    print(f"l10n lint: ok, {sum(counts.values()):,} unlocalized literals in {len(counts)} files, none above its baseline."
          + (f" {lower} files are below it: run --update-baseline to lock that in." if lower else ""))
    return EXIT_OK


# ---------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    """The command line's parser."""
    parser = argparse.ArgumentParser(prog="scan.py", description=__doc__.split("\n\n")[0],
                                     epilog="See the top of Scripts/l10n/scan.py for each command in full.")
    parser.add_argument("--root", help="the repository root (default: the one this script is in)")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True

    rep = sub.add_parser("report", help="totals by area or by file, with the findings")
    rep.add_argument("--by", choices=("area", "file"), default="area", help="what to total by (default: area)")
    rep.add_argument("--area", help="with --by file, only the files of this area")
    rep.add_argument("--top", type=int, default=0, metavar="N", help="show only the N rows with the most unlocalized bytes")
    rep.add_argument("--json", action="store_true", help="print JSON instead of text")

    show = sub.add_parser("show", help="the unlocalized interface literals of one file")
    show.add_argument("file", help="a Swift file, as a path from the repository root or from TextMouth/")
    show.add_argument("--all", action="store_true", help="also the localized and the marked literals")
    show.add_argument("--width", type=int, default=DEFAULT_WIDTH, help=f"line width (default {DEFAULT_WIDTH})")
    show.add_argument("--json", action="store_true", help="print JSON instead of text")

    lint = sub.add_parser("lint", help="fail when a file gains unlocalized interface text")
    lint.add_argument("--base", metavar="REF", help="show only the literals on lines added since the merge-base of REF and HEAD")
    lint.add_argument("--baseline", metavar="FILE", help="the baseline file (default Scripts/l10n/scan-baseline.json)")
    group = lint.add_mutually_exclusive_group()
    group.add_argument("--update-baseline", action="store_true", help="lower the counts that fell; never raise one")
    group.add_argument("--rebuild-baseline", action="store_true", help="write the baseline from scratch (orchestrator only)")
    lint.add_argument("--renamed", nargs=2, action="append", metavar=("OLD", "NEW"),
                      help="with --update-baseline: move a renamed file's record to its new path")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    """Runs one command and returns its exit status."""
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as stop:  # argparse exits with 2 for a bad command line, 0 for --help
        return int(stop.code or 0)
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    if not (root / "TextMouth").is_dir():
        print(f"scan: {root} has no TextMouth/ folder", file=sys.stderr)
        return EXIT_USAGE
    scan = scan_tree(root)
    if args.command == "report":
        return cmd_report(args, scan)
    if args.command == "show":
        return cmd_show(args, scan, root)
    return cmd_lint(args, scan, root)


if __name__ == "__main__":
    sys.exit(main())
