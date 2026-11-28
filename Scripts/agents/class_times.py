#!/usr/bin/env python3
"""class_times.py: writes class-times.json from an xcodebuild log, for shard.py to balance the shards by.

Each test class's own suite line in a log ("Test Suite 'FooTests' passed at ...", then "Executed N tests ... in S
(T) seconds") gives its time. Pass the merged log of a run on the runner (the `run.log` of a `test-build-results`
artifact), since the shards should be balanced by what the runner takes, not what this Mac takes. A class under half
a second is left out of the file (shard.py counts a class it does not know as one second).

Usage: python3 -I -B Scripts/agents/class_times.py LOG [OUT_FILE]
Without OUT_FILE the times are printed as JSON. Python 3 standard library only.
"""
import json
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# A class's suite line, and the Executed line that follows it.
SUITE = re.compile(r"^Test Suite '([A-Za-z0-9_]+)' (?:passed|failed) at ")
EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? .* in ([\d.]+) \(([\d.]+)\) seconds")
# The suites of the run and of the test bundle are not classes.
NOT_CLASSES = {"All", "Selected", "TextMouthProductionTests"}
# A class faster than this is left out of the file.
MINIMUM_SECONDS = 0.5


def class_times(log_text):
    """{class name: seconds} from the text of a log: each class's suite line followed by its Executed line. A class
    that appears twice (the host restarted and ran it again) keeps its longest time."""
    times = {}
    pending = None
    for line in log_text.splitlines():
        match = SUITE.match(line)
        if match:
            pending = match.group(1)
            continue
        if pending:
            executed = EXECUTED.search(line)
            if executed and pending not in NOT_CLASSES:
                times[pending] = max(times.get(pending, 0.0), float(executed.group(5)))
            pending = None
    return times


def main(argv):
    """Reads the log, and writes or prints the times."""
    if not 1 <= len(argv) <= 2:
        print("usage: class_times.py LOG [OUT_FILE]", file=sys.stderr)
        return 2
    try:
        times = class_times(Path(argv[0]).read_text(encoding="utf-8", errors="replace"))
    except OSError as error:
        print(f"class_times: cannot read the log: {error}", file=sys.stderr)
        return 2
    kept = {name: round(seconds, 1) for name, seconds in sorted(times.items()) if seconds >= MINIMUM_SECONDS}
    text = json.dumps(kept, indent=0) + "\n"
    if len(argv) == 2:
        Path(argv[1]).write_text(text, encoding="utf-8")
        print(f"class_times: {len(kept)} classes of {len(times)} in the log, {sum(kept.values()):.0f} seconds, written to {argv[1]}")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
