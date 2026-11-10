"""shard.py: splits test classes among parallel GitHub jobs so that the jobs take about as long as each other.

A public repository runs several macOS jobs at once, and every job builds the app (a few minutes,
less with cached build products), so a long run is faster as a few shards than as one job. The Mac
decides how many shards a request needs (`shard_count`), writing it into the request file; each
shard job then takes its own slice (`split`) of the same list of classes, so the shards agree
without talking to each other. The slices are balanced by each class's time on the runner
(class-times.json, written by class_times.py from a run's log); a class not in the file counts
as DEFAULT_SECONDS. The split is deterministic: the same classes and times always give the same slices.

Python 3 standard library only.
"""
import json
import math
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The times file, beside this script: {class name: seconds on the runner}.
TIMES_FILE = Path(__file__).resolve().parent / "class-times.json"
# What a class that the file does not list is counted as.
DEFAULT_SECONDS = 5.0
# One shard's share, in seconds, past which another shard is worth its build.
TARGET_SECONDS = 600
# The most shards: a free account runs a few macOS jobs at once, and the rest would only queue.
MAX_SHARDS = 4


def load_times(path=TIMES_FILE):
    """{class name: seconds} from the times file; empty when it is missing or unreadable."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {name: float(seconds) for name, seconds in data.items()} if isinstance(data, dict) else {}


def seconds_of(name, times):
    """A class's time on the runner, or DEFAULT_SECONDS when the file doesn't know it."""
    return times.get(name, DEFAULT_SECONDS)


def shard_count(classes, times, target=TARGET_SECONDS, most=MAX_SHARDS):
    """How many shards `classes` need: one per `target` seconds of tests, at least one, at most `most`."""
    total = sum(seconds_of(name, times) for name in classes)
    return max(1, min(most, math.ceil(total / target)))


def split(classes, times, count):
    """`classes` dealt into `count` lists of about equal total time: the longest class first,
    each to the shard with least so far (ties to the lower shard). Every class lands in exactly
    one list; each list is sorted by name. Deterministic."""
    shards = [[] for _ in range(count)]
    loads = [0.0] * count
    for name in sorted(classes, key=lambda n: (-seconds_of(n, times), n)):
        lightest = min(range(count), key=lambda i: (loads[i], i))
        shards[lightest].append(name)
        loads[lightest] += seconds_of(name, times)
    return [sorted(shard) for shard in shards]
