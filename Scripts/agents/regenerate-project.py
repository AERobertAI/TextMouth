#!/usr/bin/env python3
"""regenerate-project.py: regenerate TextMouth.xcodeproj with xcodegen,
keeping only real changes.

xcodegen writes the project's copy-files phases in an order that changes
from one run to the next (the licence and table folders trade places), so
every regeneration shows hunks that change nothing. This script runs
`xcodegen generate`, then puts back every hunk of the project's diff whose
changed lines are only copy-phase lines (a `dstPath = …;` or an
`… in CopyFiles */,` entry), keeping the rest: the entries of files added,
moved, or removed.

A real change to a copy-files phase (a new bundled resource) is put back
too, so make one of those by hand.

Usage, from the repository's root or a worktree's:
    python3 -I Scripts/agents/regenerate-project.py
"""
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

PROJECT = "TextMouth.xcodeproj/project.pbxproj"
XCODEGEN = "/opt/homebrew/bin/xcodegen"

# A changed line that only reorders the copy-files phases.
COPY_PHASE_LINE = re.compile(r"^[+-]\s*(dstPath = .*;|\w+ /\* .* in CopyFiles \*/,)\s*$")


def run(arguments, **options):
    """Run a command, stopping the script with its output when it fails."""
    result = subprocess.run(arguments, capture_output=True, text=True, **options)
    if result.returncode != 0:
        sys.exit(f"{' '.join(arguments)} failed:\n{result.stdout}{result.stderr}")
    return result.stdout


def hunks_of(patch):
    """Split a unified diff into its header lines and its hunks."""
    header, hunks = [], []
    for line in patch.splitlines(keepends=True):
        if line.startswith("@@"):
            hunks.append([line])
        elif hunks:
            hunks[-1].append(line)
        else:
            header.append(line)
    return header, hunks


def is_reordering(hunk):
    """Whether every changed line of `hunk` is a copy-files phase line."""
    changed = [line.rstrip("\n") for line in hunk[1:] if line[:1] in "+-"]
    return bool(changed) and all(COPY_PHASE_LINE.match(line) for line in changed)


def main():
    """Regenerate the project, then keep only its real changes."""
    root = Path(run(["git", "rev-parse", "--show-toplevel"]).strip())
    run([XCODEGEN, "generate"], cwd=root)
    patch = run(["git", "diff", "-U0", "--", PROJECT], cwd=root)
    if not patch:
        print("regenerate-project: the project is unchanged")
        return
    header, hunks = hunks_of(patch)
    kept = [hunk for hunk in hunks if not is_reordering(hunk)]
    # Put the project back as committed, then apply the real changes alone.
    run(["git", "checkout", "--", PROJECT], cwd=root)
    if kept:
        filtered = "".join(header + [line for hunk in kept for line in hunk])
        subprocess.run(
            ["git", "apply", "--unidiff-zero", "-"], cwd=root, input=filtered, text=True, check=True
        )
    print(f"regenerate-project: kept {len(kept)} of {len(hunks)} hunks; "
          f"{len(hunks) - len(kept)} only reordered the copy-files phases")


if __name__ == "__main__":
    main()
