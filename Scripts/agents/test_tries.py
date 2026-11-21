"""test_tries.py: a test's tries, read from an xcodebuild log run with `-retry-tests-on-failure`.

With retries, xcodebuild runs a failing test again (up to the -test-iterations count) and the run
passes when a later try passes. A log from a real run (November 15, 2026) holds:

- each try as `Test Case '-[Module.Class test]' started (Iteration 2 of 3).` and then its own
  `passed|failed|skipped (0.001 seconds).` line, a failed try with its `error:` line before it;
- Suite lines `Test Suite 'Selected tests' failed at ...` even when every test finally passed,
  though the run's verdict, `** TEST SUCCEEDED **` (or `TEST EXECUTE SUCCEEDED`), is right;
- an `Executed N tests, with F failures (0 unexpected)` line that counts every try (a test that
  failed once and passed on try 2 adds one test and one failure) and so cannot be believed;
- a crashed test is not tried again: the host restarts and goes on with the next test.

So the Test Case lines are the count to trust: a test's last result is its outcome. Python 3
standard library only, and importing it leaves no __pycache__ folder.
"""
import re
import sys
from collections import namedtuple

sys.dont_write_bytecode = True

# One result line, wherever it starts on its line (the app's own log lines can land before it).
RESULT = re.compile(r"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (passed|failed|skipped) \(")
# The line that starts a try, with the try's number and the most tries a retrying run allows.
STARTED = re.compile(r"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' started \(Iteration (\d+) of (\d+)\)")

# A test's outcome: its name as Class.test, its last result, how many tries it had, and the most
# tries allowed (0 when the log never said).
Outcome = namedtuple("Outcome", "name result tries allowed")


def outcomes(text):
    """{Class.test: Outcome} from a log's text, in the order each test first appeared. The last
    result of a test is its outcome; its tries are the results the log holds for it."""
    results, allowed = {}, {}
    for line in text.splitlines():
        started = STARTED.search(line)
        if started:
            allowed[f"{started.group(1)}.{started.group(2)}"] = int(started.group(4))
            continue
        found = RESULT.search(line)
        if found:
            results.setdefault(f"{found.group(1)}.{found.group(2)}", []).append(found.group(3))
    return {name: Outcome(name, tries[-1], len(tries), allowed.get(name, 0)) for name, tries in results.items()}


def retried(found):
    """The Outcomes (from `outcomes`) of tests that passed on a later try, in order."""
    return [o for o in found.values() if o.result == "passed" and o.tries > 1]


def retried_line(outcome):
    """The line a summary gives a test that passed on a later try."""
    of = f" of {outcome.allowed}" if outcome.allowed else ""
    return f"RETRIED {outcome.name} passed on try {outcome.tries}{of}"


def counts(found):
    """(tests, skipped, failures) of the final outcomes, or None when the log has no results."""
    if not found:
        return None
    results = [o.result for o in found.values()]
    return len(results), results.count("skipped"), results.count("failed")


def has_retries(text):
    """Whether the log was made by a run that retries (its tests start with an Iteration)."""
    return STARTED.search(text) is not None


def last_suite_verdict(text):
    """'passed' or 'failed' from the last `Test Suite 'Selected tests'|'All tests'` line, or None."""
    verdicts = re.findall(r"Test Suite '(?:Selected tests|All tests)' (passed|failed) at", text)
    return verdicts[-1] if verdicts else None
