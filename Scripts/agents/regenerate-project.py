#!/usr/bin/env python3
"""regenerate-project.py: regenerate TextMouth.xcodeproj with xcodegen,
leaving out only the noise of its copy-phase order.

xcodegen deals the project's copy-files phases out in an order that changes
from one run to the next: the same phase IDs trade their destinations and
their files, and the app's target lists them in another order, so even a
regeneration that changes nothing shows hunks. This script runs
`xcodegen generate`, then compares the copy-files phases of the project as
it was (the index's copy) and as xcodegen wrote it, by meaning: each phase's
destination and the names of the files it copies.

- When they mean the same, the copy-files section and the targets' lists of
  their copy phases are put back as they were, so only the real changes stay
  (files added, moved, or removed).
- When they differ, as when project.yml gains a bundled resource, xcodegen's
  project is kept whole. Putting back only part of it can pair one phase's
  destination with another phase's files, which is what an earlier version of
  this script did on November 4, 2026: it put back the hunks it took for a
  mere reordering one by one, and readers/mobi's project stopped copying
  liblouis's braille tables into the app. Only a fresh generation showed it,
  since the build train generates every project afresh.

Before writing anything, the script checks that the project it leaves copies
the same files to the same places as xcodegen's own, and keeps xcodegen's
otherwise.

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

# The project's copy-files section, from its Begin line through its End line.
SECTION = re.compile(
    r"/\* Begin PBXCopyFilesBuildPhase section \*/\n.*?/\* End PBXCopyFilesBuildPhase section \*/\n", re.S
)
# One copy-files phase's body, from its isa line to its closing brace.
PHASE = re.compile(r"isa = PBXCopyFilesBuildPhase;(.*?)\n\t\t\};", re.S)
# A target's reference to one of its copy phases, a line of its buildPhases
# list. (A phase's own definition, in the section, ends "= {" instead.)
PHASE_REFERENCE = re.compile(r"^\t\t\t\t[0-9A-F]{24} /\* CopyFiles \*/,$", re.M)


def run(arguments, **options):
    """Run a command and return its output, stopping the script with that
    output when the command fails."""
    result = subprocess.run(arguments, capture_output=True, text=True, **options)
    if result.returncode != 0:
        sys.exit(f"{' '.join(arguments)} failed:\n{result.stdout}{result.stderr}")
    return result.stdout


def copy_phases(project):
    """The copy-files phases of `project`, a pbxproj's text, by meaning: each
    phase as its destination and the sorted names of its files, the phases
    sorted too, so that two projects compare equal whatever order xcodegen
    dealt their phases out in."""
    phases = []
    for match in PHASE.finditer(project):
        body = match.group(1)
        destination = re.search(r"dstPath = (.*?);", body)
        files = sorted(re.findall(r"/\* (.*?) in CopyFiles \*/", body))
        phases.append((destination.group(1) if destination else "", files))
    return sorted(phases)


def with_old_copy_order(fresh, old):
    """`fresh` with its copy-files section, and its targets' references to
    their copy phases, put back as they are in `old`; None when the two
    cannot be matched up, as when either has no copy-files section or they
    refer to different phases."""
    fresh_section, old_section = SECTION.search(fresh), SECTION.search(old)
    if not fresh_section or not old_section:
        return None
    result = fresh[:fresh_section.start()] + old_section.group(0) + fresh[fresh_section.end():]
    fresh_references = PHASE_REFERENCE.findall(result)
    old_references = PHASE_REFERENCE.findall(old)
    if sorted(fresh_references) != sorted(old_references):
        return None
    # Each reference line, in turn, becomes the old project's line at the same
    # place in the lists, so the phases are listed in their old order.
    replacements = iter(old_references)
    return PHASE_REFERENCE.sub(lambda _: next(replacements), result)


def main():
    """Regenerate the project, then leave out the noise of its copy-phase
    order when, and only when, that changes nothing it copies."""
    root = Path(run(["git", "rev-parse", "--show-toplevel"]).strip())
    project_path = root / PROJECT
    # The project as it was: the index's copy, the one `git diff` compares with.
    old = run(["git", "show", f":{PROJECT}"], cwd=root)
    run([XCODEGEN, "generate"], cwd=root)
    fresh = project_path.read_text()
    if copy_phases(old) != copy_phases(fresh):
        print("regenerate-project: the copy-files phases changed in meaning, so xcodegen's project is kept whole")
        return
    result = with_old_copy_order(fresh, old)
    if result is None or copy_phases(result) != copy_phases(fresh):
        print("regenerate-project: the copy-files phases could not be put back in their old order, "
              "so xcodegen's project is kept whole")
        return
    project_path.write_text(result)
    if result == old:
        print("regenerate-project: the project is unchanged")
    else:
        print("regenerate-project: the project changed, with its copy-files phases as they were")


if __name__ == "__main__":
    main()
