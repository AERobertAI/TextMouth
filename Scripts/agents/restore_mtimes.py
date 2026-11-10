#!/usr/bin/env python3
"""restore_mtimes.py: makes a fresh checkout look, to the build system, like the one the cached build products came from.

A GitHub runner checks the repository out afresh on every run, so every file has the time of the
checkout, and Xcode's build system, which compares file times, would compile everything again
even with last run's build products restored from the cache. This script gives the files that did
not change since those products were built one fixed old time (FIXED_TIME), and leaves every file
that did change at the checkout's own newer time, so the build recompiles exactly those.

"Changed" is read from a manifest of the files' git blob hashes, saved beside the build products
and restored with them. Without a manifest (the first run, or an evicted cache) every file gets the
fixed time, so the build that follows is a complete one that the next run can rely on. The script
then writes the manifest of this checkout. Only tracked files are touched, and only their times.

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

# 2026-01-01 00:00:00 UTC, older than any checkout's own time.
FIXED_TIME = 1767225600


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
    """Sets the fixed time on every tracked file that the manifest says is unchanged (every
    one, with no manifest), saves the manifest of this checkout, and returns (files given the
    fixed time, files left at their checkout time)."""
    root = Path(root)
    current = tracked_hashes(root)
    old = read_manifest(manifest_path)
    kept = changed = 0
    for path, blob in current.items():
        if old is not None and old.get(path) != blob:
            changed += 1
            continue
        try:
            os.utime(root / path, (FIXED_TIME, FIXED_TIME), follow_symlinks=False)
            kept += 1
        except OSError:
            changed += 1  # A file that can't be touched is simply built again.
    Path(manifest_path).parent.mkdir(parents=True, exist_ok=True)
    Path(manifest_path).write_text(json.dumps(current), encoding="utf-8")
    return kept, changed


def main(argv):
    """Restores the times and says what it did."""
    if len(argv) != 1:
        print("usage: restore_mtimes.py MANIFEST", file=sys.stderr)
        return 2
    manifest = Path(argv[0])
    had = read_manifest(manifest) is not None
    kept, changed = restore(Path.cwd(), manifest)
    print(f"restore_mtimes: {'manifest found' if had else 'no manifest, so a complete build'}; "
          f"{kept} files unchanged (given the fixed time), {changed} changed or new (left as checked out)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
