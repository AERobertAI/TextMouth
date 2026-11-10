#!/usr/bin/env python3
"""plan_shards.py: tells the workflow how many parallel test jobs a request wants.

The workflow's first job runs this on the pushed request file and writes its two lines to
$GITHUB_OUTPUT: `shards=N` and `matrix={"shard":[1,...,N]}`, which the test job's matrix expands.
The Mac chose N when it made the request (the "shards" key, from shard.shard_count); this clamps
it to 1..shard.MAX_SHARDS so that a request cannot ask for more jobs than the workflow allows, and
treats a missing or odd value as 1.

Usage: python3 -I -B Scripts/agents/plan_shards.py REQUEST_FILE >> "$GITHUB_OUTPUT"
"""
import json
import sys
from pathlib import Path

# Importing these must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shard  # noqa: E402


def shard_total(request):
    """The request's shard count, clamped to 1..MAX_SHARDS; 1 when it is missing or not a whole number."""
    try:
        wanted = int(request.get("shards", 1))
    except (TypeError, ValueError):
        wanted = 1
    return max(1, min(shard.MAX_SHARDS, wanted))


def main(argv):
    """Prints the two output lines for the request file named."""
    if len(argv) != 1:
        print("usage: plan_shards.py REQUEST_FILE", file=sys.stderr)
        return 2
    try:
        request = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"plan_shards: cannot read the request {argv[0]}: {error}", file=sys.stderr)
        return 2
    count = shard_total(request if isinstance(request, dict) else {})
    print(f"shards={count}")
    print("matrix=" + json.dumps({"shard": list(range(1, count + 1))}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
