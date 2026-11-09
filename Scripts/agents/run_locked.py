#!/usr/bin/env python3
"""run_locked.py NAME COMMAND...: runs one command under the Mac's heavy lock.

The Mac has 8 GB of memory, so a full test run or a throwaway `swiftc` harness
takes the same lock the build train takes (heavy_lock.py, beside this file).

Never wrap `make typecheck-*` in this: those take the same lock themselves, and
wait on it until they give up. Run it with `python3 -I`, which leaves this
folder out of sys.path, so this folder is added by its own location below.

Exit status: the command's own; 2 for a bad command line; 3 when the lock was
not got in time (the command is then not run).
"""
import subprocess
import sys
from pathlib import Path

# Importing heavy_lock must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# heavy_lock.py is imported by path, from the folder this file is in, so the
# script works from any checkout or worktree.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import heavy_lock  # noqa: E402

# How long to wait for the lock before giving up: longer than a train's build.
WAIT_SECONDS = 3 * 60 * 60


def main():
    """Takes the lock, runs the command, and exits with the command's status."""
    if len(sys.argv) < 3:
        print("usage: run_locked.py NAME COMMAND...", file=sys.stderr)
        return 2
    name, command = sys.argv[1], sys.argv[2:]
    with heavy_lock.held(name, WAIT_SECONDS) as taken:
        if not taken:
            # Never run a heavy job beside another one: the Mac froze that way.
            print(f"run_locked: {name} did not get the lock in time", file=sys.stderr)
            return 3
        return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
