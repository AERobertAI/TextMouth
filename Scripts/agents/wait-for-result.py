#!/usr/bin/env python3
"""wait-for-result.py: wait for an agent's build-train result, then print it.

An agent that asks the build train to test its branch must not end its turn
to wait: nothing wakes it again (on November 1, 2026 two results sat unread
for two hours). So, right after `build-train.py request`, it starts this
script with the Bash tool's background mode. The script exits as soon as the
agent's result file, build/orchestrator/train/results/<SLUG>.md, is written
after the moment the script started, printing the result, and the agent is
woken by that exit.

Usage: wait-for-result.py --agent SLUG [--timeout MINUTES]
Exit status: 0 with the result printed, 1 when the timeout passed first.
"""
import argparse
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

RESULTS = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/train/results")
# How often the file is looked at, in seconds.
POLL_SECONDS = 20


def main(argv):
    """Waits for the result file to be written, then prints it."""
    parser = argparse.ArgumentParser(prog="wait-for-result.py", description=__doc__.splitlines()[0])
    parser.add_argument("--agent", required=True)
    parser.add_argument("--timeout", type=float, default=150, help="minutes to wait (default 150)")
    args = parser.parse_args(argv)
    path = RESULTS / f"{args.agent}.md"
    started = time.time()
    deadline = started + args.timeout * 60
    while time.time() < deadline:
        try:
            if path.stat().st_mtime > started:
                # Give the train a moment to finish writing the file.
                time.sleep(2)
                print(path.read_text())
                return 0
        except FileNotFoundError:
            pass
        time.sleep(POLL_SECONDS)
    print(f"wait-for-result: no result for {args.agent} in {args.timeout:g} minutes; "
          f"check `python3 -I Scripts/agents/build-train.py status`")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
