#!/usr/bin/env python3
"""plan_shards.py: tells the workflow how many parallel test jobs a request wants, and what else it asks.

The workflow's first job runs this on the request file (pushed to TestBuild, or written from the input of a caller such
as check.yml) and writes its lines to $GITHUB_OUTPUT:
  shards=N                          and
  matrix={"shard":[1,...,N]}        which the test job's matrix expands;
  request=<the request, one line>   which every later job writes back to .github/test-request.json, so that a request
                                    given as an input reaches them as a pushed one does;
  ios=true|false                    whether the iPhone app is built too (a request says "ios": false to leave it out);
  cold=true|false                   whether the build starts from nothing, with no cached build products ("cold": true);
  ios_shards=N                      and
  ios_matrix={"shard":[1,...,N]}    how many jobs the iPhone app's build and tests are split into (ios_shard_total): the
                                    request's "ios_shards" when it has one, else one for each ios_ui_tests.TARGET_SHARD_SECONDS
                                    of the iPhone tests it asks for, at most ios_ui_tests.MAX_SHARDS (3); with one Mac shard (has_room) one for each
                                    TARGET_SHARD_SECONDS_WITH_ROOM, at most MAX_SHARDS_WITH_ROOM (4).
The Mac chose N when it made the request (the "shards" key, from shard.shard_count); this clamps
it to 1..shard.MAX_SHARDS so that a request cannot ask for more jobs than the workflow allows, to what the iPhone jobs leave of
the 5 macOS jobs a free account runs at once, and treats a missing or odd value as 1.

Usage: python3 -I -B Scripts/agents/plan_shards.py REQUEST_FILE >> "$GITHUB_OUTPUT"
"""
import json
import sys
from pathlib import Path

# Importing these must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ios_ui_tests  # noqa: E402
import shard  # noqa: E402


# How many macOS jobs a free account runs at once (GitHub's limit for a public repository). A job past it waits for a free one,
# so the Mac tests' shards and the iPhone jobs together stay within it: the jobs that wait start late and end last.
MACOS_JOBS_AT_ONCE = 5


def shard_total(request):
    """The request's shard count, clamped to 1..MAX_SHARDS; 1 when it is missing or not a whole number."""
    try:
        wanted = int(request.get("shards", 1))
    except (TypeError, ValueError):
        wanted = 1
    return max(1, min(shard.MAX_SHARDS, wanted))


def has_room(mac_wanted):
    """Whether macOS slots stand idle for the iPhone jobs: the Mac wants one shard (`mac_wanted`), so 4 iPhone jobs and the
    Mac's one make the 5 macOS jobs at once."""
    return mac_wanted == 1


def ios_shard_total(request, room=False):
    """How many jobs the iPhone work is split into, 1 to ios_ui_tests.MAX_SHARDS (MAX_SHARDS_WITH_ROOM when `room`, see
    has_room): the request's "ios_shards" when it holds a whole number (clamped), else what ios_ui_tests.shard_count says the
    iPhone tests it asks for need (1 when it asks for none, since the build alone is one job's work), at the finer
    TARGET_SHARD_SECONDS_WITH_ROOM when `room`."""
    most = ios_ui_tests.MAX_SHARDS_WITH_ROOM if room else ios_ui_tests.MAX_SHARDS
    wanted = request.get("ios_shards")
    if isinstance(wanted, int) and not isinstance(wanted, bool):
        return max(1, min(most, wanted))
    target = ios_ui_tests.TARGET_SHARD_SECONDS_WITH_ROOM if room else ios_ui_tests.TARGET_SHARD_SECONDS
    return ios_ui_tests.shard_count(ios_ui_tests.wanted(request), most=most, target=target)


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
    ios_count = ios_shard_total(request, has_room(shard_total(request)))
    # The iPhone jobs (when the request builds the iPhone app at all) take their share of the macOS jobs; the Mac tests' shards
    # take what is left, and at least one.
    taken = ios_count if flag(request, "ios", True) == "true" else 0
    count = max(1, min(shard_total(request), MACOS_JOBS_AT_ONCE - taken))
    print(f"shards={count}")
    print("matrix=" + json.dumps({"shard": list(range(1, count + 1))}, separators=(",", ":")))
    # One line, with no raw newline (ASCII escapes), since $GITHUB_OUTPUT reads a line as one value.
    print("request=" + json.dumps(request, separators=(",", ":")))
    print(f"ios={flag(request, 'ios', True)}")
    print(f"cold={flag(request, 'cold', False)}")
    print(f"ios_shards={ios_count}")
    print("ios_matrix=" + json.dumps({"shard": list(range(1, ios_count + 1))}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
