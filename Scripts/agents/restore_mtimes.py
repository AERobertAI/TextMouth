#!/usr/bin/env python3
"""restore_mtimes.py: makes a fresh checkout look, to the build system, like the one the cached build products came from.

A GitHub runner checks the repository out afresh on every run, so every file has the time of the
checkout, and Xcode's build system, which compares each input's time with the one it recorded, would
compile everything again even with last run's build products restored from the cache. This script gives
every tracked file a time that depends only on the file's content: FIXED_TIME plus a few seconds taken
from its git blob hash (content_time). The same text therefore has the same time in every run, whichever
run built the products, and a file whose text changed gets a different time, so the build compiles
exactly the files whose text differs from what the products were built from, and nothing else.

(Until November 14, 2026 every file unchanged since the cached run's manifest got one fixed time and a
changed file kept its checkout time. The products of a run then recorded its changed files at that run's
checkout time, which no later run could give them again, so the next run compiled them again, with
everything that depends on them: 154 Swift files for a tree with nothing new, and the whole module, 1,562
files, after a day's changes.)

The manifest of blob hashes, saved beside the build products and restored with them, is now only for the
log: it says which files differ from the products' tree, so that a run's page names what the build had to
look at. Without one the files get their times all the same. The script then writes the manifest of this
checkout. Only tracked files are touched, and only their times.

Usage: python3 -I -B Scripts/agents/restore_mtimes.py MANIFEST
Run it from the repository root, after the checkout and the cache restore, before the build.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# 2026-01-01 00:00:00 UTC, older than any checkout's own time; every file's time is this plus up to TIME_SPREAD seconds.
FIXED_TIME = 1767225600
# The seconds a file's time may be later than FIXED_TIME: 100 days, so that every time is still in the past of any checkout
# (April 11, 2026 at the latest), and two texts of one file share a time only about once in 8.6 million.
TIME_SPREAD = 100 * 86400


def content_time(blob):
    """The modification time (whole seconds) that a file whose git blob hash is `blob` is given: FIXED_TIME plus the
    hash's first 8 hex digits modulo TIME_SPREAD. The same blob always gives the same time."""
    return FIXED_TIME + int(blob[:8], 16) % TIME_SPREAD


def tracked_hashes(root):
    """{path: blob hash} of every tracked file, as `git ls-files -s` lists them."""
    out = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=root, capture_output=True, text=True, check=True).stdout
    hashes = {}
    for entry in out.split("\0"):
        if not entry:
            continue
        # "<mode> <blob> <stage>\t<path>"
        head, path = entry.split("\t", 1)
        hashes[path] = head.split()[1]
    return hashes


def read_manifest(path):
    """The saved manifest ({path: blob hash}), or None when there is none or it can't be read."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def restore(root, manifest_path):
    """Gives every tracked file its content_time, saves the manifest of this checkout, and returns (files whose text
    is what the manifest says, files that differ from it or are new). With no manifest every file counts as the first.
    A file that can't be touched keeps its checkout time (and counts as differing): it is simply built again."""
    root = Path(root)
    current = tracked_hashes(root)
    old = read_manifest(manifest_path)
    kept = changed = 0
    for path, blob in current.items():
        try:
            stamp = content_time(blob)
            os.utime(root / path, (stamp, stamp), follow_symlinks=False)
            same = old is None or old.get(path) == blob
        except OSError:
            same = False
        if same:
            kept += 1
        else:
            changed += 1
    Path(manifest_path).parent.mkdir(parents=True, exist_ok=True)
    Path(manifest_path).write_text(json.dumps(current), encoding="utf-8")
    return kept, changed


# How many changed files main() names, so that a run's log shows what the build had to look at.
NAMED = 40


def changed_names(current, old):
    """The paths whose blob differs from the manifest `old` (or are new), sorted; empty with no manifest."""
    if old is None:
        return []
    return sorted(path for path, blob in current.items() if old.get(path) != blob)


def main(argv):
    """Restores the times and says what it did."""
    if len(argv) != 1:
        print("usage: restore_mtimes.py MANIFEST", file=sys.stderr)
        return 2
    manifest = Path(argv[0])
    old = read_manifest(manifest)
    had = old is not None
    names = changed_names(tracked_hashes(Path.cwd()), old)
    kept, changed = restore(Path.cwd(), manifest)
    print(f"restore_mtimes: {'manifest found' if had else 'no manifest, so a complete build'}; "
          f"{kept} files as the products were built, {changed} changed or new (every file is given its content's time)")
    for name in names[:NAMED]:
        print(f"restore_mtimes:   changed {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
