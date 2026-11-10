"""runner_skips.py: the tests the GitHub runner does not run, and what an agent is told about them.

`Scripts/agents/runner-skips.conf` lists what the runner leaves out: a line is `Class.testName  # reason` for one
test or `Class  # reason` for a whole class (a blank line or a line starting with # is a comment). The runner
(run-on-runner.py) turns the entries into xcodebuild's -skip-testing arguments, and the build train tells each agent
which of the classes and tests it asked for were among them, since a result from GitHub says nothing about those.

Python 3 standard library only.
"""
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The skips file, beside this script.
SKIPS_FILE = Path(__file__).resolve().parent / "runner-skips.conf"
# A name on a line: Class or Class.testName, each a Swift identifier.
NAME = re.compile(r"^([A-Za-z_]\w*)(?:\.([A-Za-z_]\w*))?$")
# How many left-out items a result names before it says "and N more".
MOST_NAMED = 20


class BadSkipLine(ValueError):
    """A line of the skips file that is not a comment and not `Class` or `Class.testName` with its reason."""


def read_skips(path=SKIPS_FILE):
    """What the runner leaves out, as [(class, test or None, reason)], from the skips file. A line that is not a
    comment must be a name and a `# reason`; anything else (a stray comma, a name with a space, a missing reason)
    raises BadSkipLine naming the line, since a line dropped without a word would run a test that must not run.
    A missing file is no skips."""
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    skips = []
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, hash_mark, reason = line.partition("#")
        match = NAME.match(name.strip())
        if not match or not hash_mark or not reason.strip():
            raise BadSkipLine(f"{path}:{number}: not `Class.testName  # reason` or `Class  # reason`: {line[:80]!r}")
        skips.append((match.group(1), match.group(2), reason.strip()))
    return skips


def skip_arguments(skips):
    """The xcodebuild arguments that leave `skips` out: -skip-testing for each test or class."""
    return [f"-skip-testing:TextMouthProductionTests/{owner}" + (f"/{test}" if test else "") for owner, test, _ in skips]


def selected_skips(request, skips):
    """The skips that apply to a runner job: all of them for a full-suite run or a run of areas (which could hold
    any class), and only those of its own classes for a run of named classes (a shard's command stays short)."""
    if request["full"] or request["areas"]:
        return list(skips)
    return [skip for skip in skips if skip[0] in set(request["classes"])]


def not_run_by(classes, skips):
    """The entries of `skips` that cover some of `classes`, each as a sentence part for a result: "Class (reason)" for a
    class left out whole, "Class.test (reason)" for a test. In the order of the file."""
    wanted = set(classes)
    return [f"{owner}.{test} ({reason})" if test else f"{owner} ({reason})"
            for owner, test, reason in skips if owner in wanted]


def not_run_lines(left_out):
    """The lines a result gives an agent for what the runner left out of its request ([] when nothing): one line
    for each, "Not run on GitHub, no verdict: X (reason)", MOST_NAMED at most, then how many more."""
    lines = [f"- Not run on GitHub, no verdict: {item}" for item in left_out[:MOST_NAMED]]
    if len(left_out) > MOST_NAMED:
        lines += [f"- Not run on GitHub, no verdict: and {len(left_out) - MOST_NAMED} more, in Scripts/agents/runner-skips.conf"]
    return lines
