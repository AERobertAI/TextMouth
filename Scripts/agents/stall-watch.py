#!/usr/bin/env python3
"""Watch a session's subagent transcripts for a tool call left waiting.

A Bash call ends within ten minutes (its longest timeout), so a tool call
with no result after fifteen minutes is almost always waiting on a
permission prompt the user has not seen. That happened on October 18, 2026:
a team lead's `rm` through a shell variable waited five hours for the user's
answer, and its team stood still all that time.

Usage: stall-watch.py --subagents DIR [--minutes 15] [--hours 12]
DIR is the session's subagents folder,
~/.claude/projects/<project folder>/<session id>/subagents.
Run it as a background task with `python3 -I`; its exit re-invokes the
orchestrator. Exits 0 with one line per stalled agent when it finds one;
otherwise polls every two minutes until --hours pass, then exits 4. It
reads only transcripts and touches nothing.
"""
import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime, timezone

# Tools that legitimately block for long: a foreground agent runs to its end.
LONG_TOOLS = {"Agent", "Task"}


def pending_call(path):
    """The (timestamp, tool name, short input, id) of the latest tool call in
    `path` that has no result yet, or None. Reads only the file's last 200 KB.
    Only the transcript's own assistant and user rows count: an
    `api-request-blob` row replays a whole request, and the tail can cut it
    from the result that answered one of its calls."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - 200_000))
        tail = f.read().decode("utf-8", "replace").splitlines()
    calls, answered = {}, set()
    # Some rows carry no timestamp; such a row takes the last one seen.
    last_stamp = ""
    for line in tail:
        try:
            obj = json.loads(line)
        except ValueError:
            continue  # the first line of the tail may be cut short
        if isinstance(obj, dict) and obj.get("timestamp"):
            last_stamp = obj["timestamp"]
        if not isinstance(obj, dict) or obj.get("type") not in ("assistant", "user"):
            continue
        msg = obj.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "tool_use":
                inp = part.get("input") or {}
                what = inp.get("description") or inp.get("command") or ""
                calls[part.get("id")] = (last_stamp, part.get("name"), str(what)[:160], part.get("id"))
            elif part.get("type") == "tool_result":
                answered.add(part.get("tool_use_id"))
    waiting = [c for i, c in calls.items() if i not in answered and c[1] not in LONG_TOOLS]
    return max(waiting) if waiting else None


def age_minutes(stamp):
    """Minutes since an ISO 8601 UTC timestamp such as 2026-10-18T17:34:16.861Z;
    0 when there is none, so an undated call never counts as stalled."""
    if not stamp:
        return 0
    when = datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - when).total_seconds() / 60


def stalled_calls(folder, minutes):
    """(path, call) for each transcript in `folder` of the last day that has
    been quiet for `minutes` and whose latest unanswered call is at least
    that old."""
    found = []
    for path in glob.glob(os.path.join(folder, "*.jsonl")):
        idle = (time.time() - os.path.getmtime(path)) / 60
        if idle < minutes or idle > 24 * 60:
            continue
        call = pending_call(path)
        if call and age_minutes(call[0]) >= minutes:
            found.append((path, call))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--subagents", required=True,
                        help="the session's subagents folder of transcripts")
    parser.add_argument("--minutes", type=float, default=15)
    parser.add_argument("--hours", type=float, default=12)
    args = parser.parse_args()
    if not os.path.isdir(args.subagents):
        print(f"stall-watch: no folder {args.subagents}", file=sys.stderr)
        return 2
    deadline = time.time() + args.hours * 3600
    # Calls already stalled at the start belong to agents that were stopped
    # long ago (a stop can leave its last call without a result); a call
    # still young at the start is watched like any other.
    baseline = {(path, call[3]) for path, call in stalled_calls(args.subagents, args.minutes)}
    while time.time() < deadline:
        stalled = [f"{os.path.basename(path)}: {call[1]} waiting since {call[0]} ({call[2]})"
                   for path, call in stalled_calls(args.subagents, args.minutes)
                   if (path, call[3]) not in baseline]
        if stalled:
            print("\n".join(stalled))
            return 0
        # Poll every two minutes, but never sleep past the deadline.
        time.sleep(max(0, min(120, deadline - time.time())))
    print("no stalled tool call found")
    return 4


if __name__ == "__main__":
    sys.exit(main())
