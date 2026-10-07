#!/usr/bin/env python3
"""Watch the usage windows that Opus work counts against, and exit when one runs low.

The claude-usage-left script's own --watch treats every window alike, and on
October 7, 2026 its "Weekly (Fable)" window (a cap on the Fable model only)
sat at a few percent left, so a stock watch would fire at once although this
session and its agents run on Opus. This watcher reads the script's JSON and
considers only windows that are not scoped to one model: the 5-hour session
and the weekly all-models window.

Usage: usage-watch-unscoped.py <threshold-left-percent> [poll-minutes]
Run it as a background task; its exit re-invokes the orchestrator.
Exits 0, printing an alert, once any counted window has at most that much left.
"""
import json
import subprocess
import sys
import time

SCRIPT = "/Users/roberteggleston/.claude/skills/claude-usage-left/scripts/claude_usage.py"


def counted_windows():
    """Return the windows that are not scoped to a single model."""
    out = subprocess.run(["python3", SCRIPT, "--json"], capture_output=True, text=True, timeout=120)
    data = json.loads(out.stdout)
    return [w for w in data["windows"] if not (w.get("scope") or {}).get("model")]


def main():
    threshold = float(sys.argv[1]) if len(sys.argv) > 1 else 25.0
    minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
    print(f"[usage-watch-unscoped] alert when a counted window has <= {threshold:.0f}% LEFT; polling every {minutes:g} min", flush=True)
    while True:
        try:
            windows = counted_windows()
        except Exception as error:  # a transient network or parse problem: try again later
            print(f"[usage-watch-unscoped] transient: {error}", flush=True)
            time.sleep(minutes * 60)
            continue
        low = [w for w in windows if w.get("left_pct") is not None and w["left_pct"] <= threshold]
        if low:
            for w in low:
                print(f"USAGE ALERT: {w['summary']}", flush=True)
            for w in windows:
                print(f"  {w['name']}: {w['left_pct']:.0f}% LEFT, resets in {w['reset_in_human']}", flush=True)
            return 0
        time.sleep(minutes * 60)


if __name__ == "__main__":
    sys.exit(main())
