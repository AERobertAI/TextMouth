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
worth at Opus 5.5's published prices. A call on another model counts at
that model's price as a share of Opus's (`MODEL_PRICES`), so a Sonnet 5.5
call's tokens count half. That report found that about 6.2 million units
make one point of the weekly limit; the points printed here rest on that
estimate, and assume the limit weighs each model by its price. It prints
counts only, never transcript text.
"""
import collections
import glob
import json
import os
import sys

# Price ratios relative to a plain input token (Opus 5.5).
WEIGHTS = {"inp": 1.0, "cw5": 1.25, "cw1h": 2.0, "cr": 0.05, "out": 5.0}
# Each model's prices as a share of Opus 5.5's, by the start of its model
# name (platform.claude.com/docs/en/about-claude/pricing, October 2026):
# Sonnet 5.5 costs $2 and $10 a million input and output tokens against
# Opus 5.5's $4 and $20, and its cache writes and reads half as much too
# (the pricing page's cache read is 5% of a model's input price; Anthropic's
# launch post gave Sonnet's as $0.20, Opus's price, which would make its
# cache reads count in full). A model not listed counts as Opus.
MODEL_PRICES = {"claude-opus": 1.0, "claude-sonnet": 0.5}
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


def price_of(model):
    """A model's prices as a share of Opus 5.5's (`MODEL_PRICES`); 1 when unknown."""
    for prefix, share in MODEL_PRICES.items():
        if (model or "").startswith(prefix):
            return share
    return 1.0


def calls_of(path):
    """Each API call's token counts and model, once per call, and the efforts recorded.

    Records sharing a message ID are one call; their counts are merged by
    taking each field's largest value, as the October 10 audit did.
    """
    calls = {}
    efforts = collections.Counter()
    models = collections.Counter()
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
                "price": price_of(message.get("model")),
            }
            key = message.get("id") or record.get("requestId")
            if key in calls:
                merged = calls[key]
                for field, value in counts.items():
                    merged[field] = max(merged[field], value)
            else:
                calls[key] = counts
                efforts[record.get("effort") or "unrecorded"] += 1
                models[message.get("model") or "unrecorded"] += 1
    return list(calls.values()), efforts, models


def summary(calls, efforts, models):
    """One agent's totals, its cost in units and weekly points, and per-call averages."""
    total = {field: sum(call[field] for call in calls) for field in ("inp", "cw5", "cw1h", "cc", "cr", "out", "think")}
    # Each call's tokens at its own model's prices.
    units = sum(call[field] * weight * call["price"] for call in calls for field, weight in WEIGHTS.items())
    count = max(len(calls), 1)
    return {
        "effort": ", ".join("%s %d" % item for item in efforts.most_common()),
        "models": ", ".join("%s %d" % item for item in models.most_common()),
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
        print("%s: effort recorded on its calls: %s; models: %s" % (label, row["effort"], row["models"]))


main()
