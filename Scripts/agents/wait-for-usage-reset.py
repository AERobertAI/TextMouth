#!/usr/bin/env python3
"""Wait until a spent usage window comes back, then exit, re-invoking the orchestrator.

On a night the user lets agents run until the limit runs out (AGENTS.md: the
night before the weekly reset), the account can be refused by the API for a
while: the 5-hour window, or the weekly all-models window, reaches 0% left,
and every agent stops where it is. Nothing re-invokes the orchestrator when
the window resets, so this watcher runs as a background task and exits once
a counted window it saw spent has headroom again; its exit re-invokes the
orchestrator, which resumes the agents that were cut off (a message to each
agent's ID).

Only the windows not scoped to one model count (the 5-hour session and the
weekly all-models window), as in usage-watch-unscoped.py: a cap on the Fable
model does not count Opus work.

Usage: wait-for-usage-reset.py [poll-minutes] [spent-left-percent]
  poll-minutes: at least 1, 5 by default; spent-left-percent: 2 by default. On a day the
  normal usage rule applies, agents stop themselves at 10% left, so pass about 12 to be
  woken when a window they stopped at comes back.
Exits 0, printing every counted window, once a window it saw at or below
SPENT_LEFT percent left has at least BACK_LEFT percent left again.
"""
import json
import subprocess
import sys
import time

SCRIPT = "/Users/roberteggleston/.claude/skills/claude-usage-left/scripts/claude_usage.py"
# A window this low counts as spent: agents are being refused, or soon will be.
SPENT_LEFT = 2.0
# A spent window with this much left again has reset.
BACK_LEFT = 50.0


def counted_windows():
    """Return the windows that are not scoped to a single model."""
    out = subprocess.run(["python3", SCRIPT, "--json"], capture_output=True, text=True, timeout=120)
    data = json.loads(out.stdout)
    return [w for w in data["windows"] if not (w.get("scope") or {}).get("model")]


def main():
    # Never poll faster than once a minute: a tight loop would hammer the usage endpoint.
    minutes = max(1.0, float(sys.argv[1])) if len(sys.argv) > 1 else 5.0
    spent_left = float(sys.argv[2]) if len(sys.argv) > 2 else SPENT_LEFT
    print(f"[wait-for-usage-reset] exits once a window seen at <= {spent_left:.0f}% left has >= {BACK_LEFT:.0f}% left; polling every {minutes:g} min", flush=True)
    spent = set()
    while True:
        try:
            windows = counted_windows()
        except Exception as error:  # a transient network or parse problem: try again later
            print(f"[wait-for-usage-reset] transient: {error}", flush=True)
            time.sleep(minutes * 60)
            continue
        for window in windows:
            left = window.get("left_pct")
            if left is None:
                continue
            if left <= spent_left and window["name"] not in spent:
                spent.add(window["name"])
                print(f"[wait-for-usage-reset] spent: {window['summary']}", flush=True)
            elif window["name"] in spent and left >= BACK_LEFT:
                print(f"USAGE BACK: {window['summary']}", flush=True)
                for each in windows:
                    print(f"  {each['name']}: {each['left_pct']:.0f}% LEFT, resets in {each['reset_in_human']}", flush=True)
                return 0
        time.sleep(minutes * 60)


if __name__ == "__main__":
    sys.exit(main())
