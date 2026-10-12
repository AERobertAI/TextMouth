#!/usr/bin/env python3
"""What an agent's run cost, measured from its transcript.

Usage: agent-cost.py [label=]<agent ID or transcript path> ...

Each argument names one agent: the path of its transcript (a .jsonl file),
or its agent ID, which is looked up as agent-<ID>.jsonl in every session of
this project under ~/.claude/projects. A label before "=" names its row.

It counts tokens the way humanReports/TOKEN-USAGE-2026-10-10.md did, so its
figures compare with that report's: each API call once (one response is
often split across several records sharing a message ID), and tokens of
different kinds added up in units, one unit being one plain input token's
worth at Opus 5.5's published prices. That report found that about 6.2
million units make one point of the weekly limit; the points printed here
rest on that estimate. It prints counts only, never transcript text.
"""
import collections
import glob
import json
import os
import sys

# Price ratios relative to a plain input token (Opus 5.5).
WEIGHTS = {"inp": 1.0, "cw5": 1.25, "cw1h": 2.0, "cr": 0.05, "out": 5.0}
# Units in one point of the weekly limit (the October 10 report's fit).
UNITS_PER_WEEKLY_POINT = 6.2e6
# Where Claude Code keeps this project's sessions.
PROJECT = os.path.expanduser("~/.claude/projects/-Users-roberteggleston-programming-ai-claude-swift-TextMouth")


def transcript_path(ref):
    """The transcript a reference names: the path itself, or the agent's file."""
    if ref.endswith(".jsonl") or os.path.sep in ref:
        return ref
    matches = glob.glob(os.path.join(PROJECT, "*", "subagents", "agent-%s.jsonl" % ref))
    if not matches:
        sys.exit("no transcript found for agent %s" % ref)
    return matches[0]


def calls_of(path):
    """Each API call's token counts, once per call, and the efforts recorded.

    Records sharing a message ID are one call; their counts are merged by
    taking each field's largest value, as the October 10 audit did.
    """
    calls = {}
    efforts = collections.Counter()
    with open(path, errors="replace") as transcript:
        for line in transcript:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("type") != "assistant":
                continue
            message = record.get("message") or {}
            # Skip records the client made up rather than the API returned.
            if message.get("model") == "<synthetic>" or record.get("isApiErrorMessage"):
                continue
            usage = message.get("usage") or {}
            creation = usage.get("cache_creation") or {}
            counts = {
                "inp": usage.get("input_tokens") or 0,
                "cw5": creation.get("ephemeral_5m_input_tokens") or 0,
                "cw1h": creation.get("ephemeral_1h_input_tokens") or 0,
                "cc": usage.get("cache_creation_input_tokens") or 0,
                "cr": usage.get("cache_read_input_tokens") or 0,
                "out": usage.get("output_tokens") or 0,
                "think": (usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0,
            }
            key = message.get("id") or record.get("requestId")
            if key in calls:
                merged = calls[key]
                for field, value in counts.items():
                    merged[field] = max(merged[field], value)
            else:
                calls[key] = counts
                efforts[record.get("effort") or "unrecorded"] += 1
    return list(calls.values()), efforts


def summary(calls, efforts):
    """One agent's totals, its cost in units and weekly points, and per-call averages."""
    total = {field: sum(call[field] for call in calls) for field in ("inp", "cw5", "cw1h", "cc", "cr", "out", "think")}
    units = sum(total[field] * weight for field, weight in WEIGHTS.items())
    count = max(len(calls), 1)
    return {
        "effort": ", ".join("%s %d" % item for item in efforts.most_common()),
        "calls": len(calls),
        # A call's prompt is everything it sent: new input, cache writes, and cache reads.
        "largest_prompt": max((call["inp"] + call["cc"] + call["cr"] for call in calls), default=0),
        "cache_writes": total["cc"],
        "cache_reads": total["cr"],
        "output": total["out"],
        "thinking": total["think"],
        "thinking_share": total["think"] / total["out"] if total["out"] else 0.0,
        "units": units,
        "points": units / UNITS_PER_WEEKLY_POINT,
        "thinking_per_call": total["think"] / count,
        "output_per_call": total["out"] / count,
        "units_per_call": units / count,
    }


# The printed columns: heading, summary field, and format.
COLUMNS = [
    ("agent", None, "%-14s"),
    ("calls", "calls", "%6d"),
    ("max prompt k", "largest_prompt", "%13.0f"),
    ("writes M", "cache_writes", "%9.1f"),
    ("reads M", "cache_reads", "%8.0f"),
    ("output k", "output", "%9.0f"),
    ("thinking k", "thinking", "%11.0f"),
    ("think %", "thinking_share", "%8.0f"),
    ("units M", "units", "%8.1f"),
    ("points", "points", "%7.2f"),
    ("think/call", "thinking_per_call", "%11.0f"),
    ("out/call", "output_per_call", "%9.0f"),
    ("units/call k", "units_per_call", "%13.1f"),
]
# Each column's divisor, so large counts print in thousands or millions.
SCALE = {"largest_prompt": 1e3, "cache_writes": 1e6, "cache_reads": 1e6, "output": 1e3,
         "thinking": 1e3, "thinking_share": 0.01, "units": 1e6, "units_per_call": 1e3}


def main():
    """Prints one row per agent named on the command line, then each one's efforts."""
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = []
    for argument in sys.argv[1:]:
        label, _, ref = argument.rpartition("=")
        path = transcript_path(ref)
        rows.append((label or os.path.basename(path), summary(*calls_of(path))))
    print("  ".join(heading.rjust(len(fmt % 0)) if field else heading.ljust(14) for heading, field, fmt in COLUMNS))
    for label, row in rows:
        cells = [COLUMNS[0][2] % label[:14]]
        for _, field, fmt in COLUMNS[1:]:
            cells.append(fmt % (row[field] / SCALE.get(field, 1)))
        print("  ".join(cells))
    for label, row in rows:
        print("%s: effort recorded on its calls: %s" % (label, row["effort"]))


main()
