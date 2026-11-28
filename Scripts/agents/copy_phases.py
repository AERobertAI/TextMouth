#!/usr/bin/env python3
"""copy_phases.py PBXPROJ [PBXPROJ]: prints each copy phase of a project by meaning.

Each copy phase is written as its destination and the sorted names of the files
it copies, so two generated projects can be compared whatever order xcodegen
wrote the phases and whatever identifiers it gave them. With two projects it
prints what is in only one of them, then "same by meaning" (exit 0) or
"DIFFERENT" (exit 1).
"""
import re
import sys

# Importing nothing from the repository, so there is nothing to leave behind.
sys.dont_write_bytecode = True


def phases(text):
    """Returns the set of (dstSubfolderSpec, dstPath, name, files) of a project."""
    found = set()
    for match in re.finditer(r"/\* ([^\n]*?) \*/ = \{\s*isa = PBXCopyFilesBuildPhase;(.*?)\n\t\t\};", text, re.S):
        name, body = match.groups()
        destination = re.search(r"dstPath = (.*?);", body)
        spec = re.search(r"dstSubfolderSpec = (.*?);", body)
        files = sorted(re.findall(r"/\* (.*?) in ", body))
        found.add((spec.group(1) if spec else "", (destination.group(1) if destination else "").strip('"'), name, tuple(files)))
    return found


def main():
    """Prints the phases of the first project, and any difference from the second."""
    if len(sys.argv) not in (2, 3):
        print("usage: copy_phases.py PBXPROJ [PBXPROJ]", file=sys.stderr)
        return 2
    first = phases(open(sys.argv[1], encoding="utf-8").read())
    if len(sys.argv) == 2:
        for phase in sorted(first):
            print(phase)
        return 0
    second = phases(open(sys.argv[2], encoding="utf-8").read())
    for phase in sorted(first - second):
        print("only in first: ", phase)
    for phase in sorted(second - first):
        print("only in second:", phase)
    print("same by meaning" if first == second else "DIFFERENT")
    return 0 if first == second else 1


if __name__ == "__main__":
    sys.exit(main())
