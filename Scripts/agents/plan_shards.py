#!/usr/bin/env python3
"""plan_shards.py: tells the workflow how many parallel test jobs a request wants, and what else it asks.

The workflow's first job runs this on the request file (pushed to TestBuild, or written from the input of a caller such
as check.yml) and writes its lines to $GITHUB_OUTPUT:
  shards=N                          and
  matrix={"shard":[1,...,N]}        which the test job's matrix expands;
  request=<the request, one line>   which every later job writes back to .github/test-request.json, so that a request
                                    given as an input reaches them as a pushed one does;
  ios=true|false                    whether the iPhone app is built too (a request says "ios": false to leave it out);
  cold=true|false                   whether the build starts from nothing, with no cached build products ("cold": true).
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


def flag(request, key, default):
    """The request's `key` as the word "true" or "false" that a workflow condition reads; `default` (a bool) when the
    key is missing. Only a real true or false counts: any other value (a string, a number) means `default`."""
    value = request.get(key, default)
    return "true" if (value if isinstance(value, bool) else default) else "false"


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
    request = request if isinstance(request, dict) else {}
    count = shard_total(request)
    print(f"shards={count}")
    print("matrix=" + json.dumps({"shard": list(range(1, count + 1))}, separators=(",", ":")))
    # One line, with no raw newline (ASCII escapes), since $GITHUB_OUTPUT reads a line as one value.
    print("request=" + json.dumps(request, separators=(",", ":")))
    print(f"ios={flag(request, 'ios', True)}")
    print(f"cold={flag(request, 'cold', False)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
