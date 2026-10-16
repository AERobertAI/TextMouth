#!/usr/bin/env python3
"""test-logs.py: read xcodebuild test logs and say which tests are slowest,
what changed between two runs, and which tests are flaky across several runs.

    python3 Scripts/test/test-logs.py slowest LOG [-n N] [--classes]
    python3 Scripts/test/test-logs.py --selftest

Output is plain words, one fact per line: no tables, no color, no emoji, no box
drawing, so VoiceOver and a braille display read it cleanly.

Exit status: 0 for a report; 1 from `compare` when a test is now failing, is new
and failing, or is gone (so a merge script can gate on it); 2 for a usage
problem (a missing file, or a file with no test lines in it).

Standard library only. Logs may be large, so they are read line by line.
"""

import argparse
import re
import sys
from collections import defaultdict, namedtuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# The outcome words XCTest prints, as this tool names them.
PASSED, FAILED, SKIPPED = "passed", "failed", "skipped"

# One test case's last result in a log. `runs` counts how many times the log
# ran it; `history` holds every outcome in order (a retry shows as failed, passed).
Result = namedtuple("Result", "outcome seconds runs history")

# What parse_log returns: the results by "Class.test", plus the log's last
# "Executed N tests, ..." line (None when the run stopped before printing one).
ParsedLog = namedtuple("ParsedLog", "results executed")

# `Test Case '-[TextMouthProductionTests.FooTests testBar]' passed (0.123 seconds).`
# Group 1 is "Module.Class" (the class may contain digits and underscores),
# group 2 the test method, group 3 the outcome, group 4 the seconds.
TEST_CASE_RE = re.compile(
    r"Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)"
)

# `Executed 12 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.2 (1.3) seconds`
EXECUTED_RE = re.compile(r"Executed \d+ tests?, with .*seconds")

# The tests the team's pattern calls load-sensitive (teams-common.md, "Load-sensitive
# tests"). Each entry is (label, regex matched against "Class.test"). Kept in ONE place.
LOAD_SENSITIVE = [
    ("IntegrationSleepTimerTests", r"^IntegrationSleepTimerTests\."),
    ("BookmarkKeyboardAccessTests", r"^BookmarkKeyboardAccessTests\."),
    ("StorageGenerationMoveTests", r"^StorageGenerationMoveTests\."),
    ("BookSearchModelTests.testCancelledSearchPublishesNothing",
     r"^BookSearchModelTests\.testCancelledSearchPublishesNothing$"),
    ("DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies",
     r"^DataDirectoryMoveTests\.testAMoveShowsItsProgressWhileItCopies$"),
    ("ViewsAndWindowsReaderSheetTests", r"^ViewsAndWindowsReaderSheetTests\."),
    ("FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped",
     r"^FeedDownloadTests\.testADownloadThatStopsPartwayGoesOnFromWhereItStopped$"),
    ("PerformanceBaselineTests", r"^PerformanceBaselineTests\."),
    ("the benchmarks (test methods with Benchmark in the name)", r"\.test\w*Benchmark"),
]
LOAD_SENSITIVE_RES = [(label, re.compile(rx)) for label, rx in LOAD_SENSITIVE]
LOAD_SENSITIVE_MARK = " (known load-sensitive)"

# Thresholds the brief fixes for `flaky`: a time "varies" when the slowest run is
# more than 3 times the fastest and above 2 seconds.
VARIES_RATIO = 3.0
VARIES_FLOOR = 2.0

# The refusal for a file with no test lines.
NOT_A_LOG = "this does not look like an xcodebuild test log"


class UsageProblem(Exception):
    """A missing file or a file that is not a test log: the caller exits 2."""


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_lines(lines):
    """Parse an iterable of log lines into a ParsedLog.

    A test that appears more than once keeps its LAST result; `runs` counts the
    appearances and `history` lists every outcome in order. Raises UsageProblem
    when no `Test Case ... passed/failed/skipped` line is found.
    """
    results = {}
    executed = None
    for line in lines:
        # Cheap substring checks first: a 50 MB log is mostly other output.
        if "Test Case '" in line:
            m = TEST_CASE_RE.search(line)
            if m is None:
                continue
            qualified, method, outcome, seconds = m.groups()
            # Drop the module ("TextMouthProductionTests.") and keep Class.method.
            cls = qualified.split(".", 1)[1] if "." in qualified else qualified
            name = cls + "." + method
            old = results.get(name)
            history = (old.history if old else ()) + (outcome,)
            results[name] = Result(outcome, float(seconds), len(history), history)
        elif "Executed " in line:
            m = EXECUTED_RE.search(line)
            if m is not None:
                executed = m.group(0)
    if not results:
        raise UsageProblem(NOT_A_LOG)
    return ParsedLog(results, executed)


def parse_log(path):
    """Read the log at `path` line by line and return its ParsedLog.

    Raises UsageProblem for a file that cannot be read or holds no test lines.
    """
    try:
        # errors="replace": a log can hold stray bytes; never die on them.
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return parse_lines(handle)
    except OSError as error:
        raise UsageProblem("cannot read %s: %s" % (path, error.strerror or error))
    except UsageProblem as problem:
        raise UsageProblem("%s: %s" % (path, problem))


# ---------------------------------------------------------------------------
# Small formatting helpers
# ---------------------------------------------------------------------------

def fmt_seconds(value):
    """Format seconds with enough digits to tell fast tests apart: 0.003, 1.25, 12.4."""
    if value < 1:
        return "%.3f" % value
    if value < 10:
        return "%.2f" % value
    return "%.1f" % value


def seconds_text(value):
    """`12.4 seconds`: the unit goes with the number, for a screen reader."""
    return fmt_seconds(value) + " seconds"


def plural(count, noun):
    """`1 test`, `2 tests`."""
    return "%d %s%s" % (count, noun, "" if count == 1 else "s")


def class_of(name):
    """The class part of a "Class.test" key (a nested class keeps its dots)."""
    return name.rsplit(".", 1)[0]


def load_sensitive_label(name):
    """The load-sensitive label a "Class.test" name falls under, or None."""
    for label, rx in LOAD_SENSITIVE_RES:
        if rx.search(name):
            return label
    return None


def count_outcomes(results):
    """Return (passed, failed, skipped) counts over a results dict."""
    counts = defaultdict(int)
    for result in results.values():
        counts[result.outcome] += 1
    return counts[PASSED], counts[FAILED], counts[SKIPPED]


def name_section(title, names, lines):
    """Append `title (N):` and then one name per line, when `names` is not empty."""
    if names:
        lines.append("%s (%d):" % (title, len(names)))
        lines.extend(names)


# ---------------------------------------------------------------------------
# slowest
# ---------------------------------------------------------------------------

def report_slowest(parsed, top=20, classes=False):
    """Return the lines of the `slowest` report for one parsed log."""
    results = parsed.results
    lines = []
    # Slowest first; the name breaks ties so the output is stable.
    ranked = sorted(results.items(), key=lambda item: (-item[1].seconds, item[0]))
    for name, result in ranked[:max(top, 0)]:
        lines.append("%s  %s" % (seconds_text(result.seconds), name))
    total = sum(r.seconds for r in results.values())
    lines.append("%s, total %s" % (plural(len(results), "test"), seconds_text(total)))
    passed, failed, skipped = count_outcomes(results)
    lines.append("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
    if parsed.executed:
        lines.append(parsed.executed)
    if classes:
        # Sum the time and count the tests of each class.
        per_class = defaultdict(lambda: [0.0, 0])
        for name, result in results.items():
            entry = per_class[class_of(name)]
            entry[0] += result.seconds
            entry[1] += 1
        lines.append("slowest classes:")
        for cls, (secs, count) in sorted(per_class.items(), key=lambda i: (-i[1][0], i[0]))[:10]:
            lines.append("%s: %s in %s" % (cls, seconds_text(secs), plural(count, "test")))
    return lines, 0


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

# Canned log text: a pass, a fail, a skip, a repeated test, a class name with digits
# and underscores, and the Executed lines. The first three Test Case lines are real.
CANNED_OLD = """\
Test Suite 'Selected tests' started at 2026-10-16 18:32:48.663.
Test Case '-[TextMouthProductionTests.FeedRecordTests testAChangeWaitsWhileTheDataDirectoryIsUnavailable]' started.
Test Case '-[TextMouthProductionTests.FeedRecordTests testAChangeWaitsWhileTheDataDirectoryIsUnavailable]' passed (0.131 seconds).
Test Case '-[TextMouthProductionTests.FeedRecordTests testAFeedsSizeRoundTripsAndAnOlderRecordLoadsWithoutIt]' passed (0.002 seconds).
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testRenderedRowsExposeGoToEditNoteAndDeleteToAccessibility]' skipped (0.034 seconds).
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne]' failed (3.582 seconds).
Test Case '-[TextMouthProductionTests.Class2_With_Digits testOne]' passed (1.000 seconds).
Test Case '-[TextMouthProductionTests.Retried testTwice]' failed (0.500 seconds).
Test Case '-[TextMouthProductionTests.Retried testTwice]' passed (0.250 seconds).
Test Case '-[TextMouthProductionTests.Removed testGoesAway]' passed (0.010 seconds).
Test Case '-[TextMouthProductionTests.Steady testSlows]' passed (1.000 seconds).
Test Case '-[TextMouthProductionTests.Steady testBecomesPassing]' failed (0.100 seconds).
Test Case '-[TextMouthProductionTests.Steady testBecomesSkipped]' passed (0.100 seconds).
Test Case '-[TextMouthProductionTests.Steady testStopsBeingSkipped]' skipped (0.001 seconds).
Test Case '-[TextMouthProductionTests.Steady testBreaks]' passed (0.100 seconds).
	 Executed 12 tests, with 2 tests skipped and 2 failures (2 unexpected) in 6.3 (6.4) seconds
Test Suite 'Selected tests' failed at 2026-10-16 18:33:00.000.
	 Executed 12 tests, with 2 tests skipped and 2 failures (2 unexpected) in 6.3 (6.4) seconds
"""


def selftest():
    """Run the checks on canned text; print the verdict; return the exit status."""
    failures = []
    checks = [0]

    def check(label, actual, expected):
        """Record one check; an unequal pair becomes a failure line."""
        checks[0] += 1
        if actual != expected:
            failures.append("FAIL %s: expected %r, got %r" % (label, expected, actual))

    def contains(label, lines, wanted):
        """Check that `wanted` is one of the output lines."""
        checks[0] += 1
        if wanted not in lines:
            failures.append("FAIL %s: missing line %r in %r" % (label, wanted, lines))

    old = parse_lines(CANNED_OLD.splitlines())

    # parse_log's pieces.
    check("parse count", len(old.results), 12)
    check("parse executed is the last Executed line",
          old.executed, "Executed 12 tests, with 2 tests skipped and 2 failures (2 unexpected) in 6.3 (6.4) seconds")
    check("parse outcome pass", old.results["FeedRecordTests.testAChangeWaitsWhileTheDataDirectoryIsUnavailable"].outcome, PASSED)
    check("parse outcome fail", old.results["BookmarkKeyboardAccessTests.testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne"].outcome, FAILED)
    check("parse outcome skip", old.results["BookmarkKeyboardAccessTests.testRenderedRowsExposeGoToEditNoteAndDeleteToAccessibility"].seconds, 0.034)
    check("parse digits and underscores", "Class2_With_Digits.testOne" in old.results, True)
    check("repeat keeps the last result", old.results["Retried.testTwice"].outcome, PASSED)
    check("repeat keeps the last time", old.results["Retried.testTwice"].seconds, 0.25)
    check("repeat counts runs", old.results["Retried.testTwice"].runs, 2)
    check("repeat keeps history", old.results["Retried.testTwice"].history, (FAILED, PASSED))
    check("a started line alone is no result", parse_lines(
        ["Test Case '-[M.C t]' started.", "Test Case '-[M.C t]' passed (1 seconds)."]).results["C.t"].runs, 1)
    check("no Executed line", parse_lines(["Test Case '-[M.C t]' passed (1.5 seconds)."]).executed, None)

    # The refusal for a file that is not a test log.
    try:
        parse_lines(["just some build output", "** BUILD SUCCEEDED **"])
        failures.append("FAIL not-a-log: no refusal")
        checks[0] += 1
    except UsageProblem as problem:
        check("not-a-log text", str(problem), NOT_A_LOG)

    # slowest.
    lines, status = report_slowest(old, top=3, classes=True)
    check("slowest status", status, 0)
    check("slowest first line", lines[0], "3.58 seconds  BookmarkKeyboardAccessTests.testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne")
    check("slowest second line", lines[1], "1.00 seconds  Class2_With_Digits.testOne")
    check("slowest third line (tie broken by name)", lines[2], "1.00 seconds  Steady.testSlows")
    contains("slowest total", lines, "12 tests, total 6.31 seconds")
    contains("slowest counts", lines, "8 passed, 2 failed, 2 skipped")
    contains("slowest classes header", lines, "slowest classes:")
    contains("slowest top class", lines, "BookmarkKeyboardAccessTests: 3.62 seconds in 2 tests")
    check("slowest -n limits", len(report_slowest(old, top=1)[0]), 1 + 3)  # 1 test + total + counts + Executed
    check("slowest -n 0 shows no test lines", report_slowest(old, top=0)[0][0], "12 tests, total 6.31 seconds")

    if failures:
        print("\n".join(failures))
        print("selftest: %d checks, %d failed" % (checks[0], len(failures)))
        return 1
    print("selftest: %d checks, all passed" % checks[0])
    return 0


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def build_parser():
    """The argument parser: three subcommands plus --selftest."""
    parser = argparse.ArgumentParser(
        description="Read xcodebuild test logs: slowest tests, changes between runs, flaky tests.",
        epilog="Exit status: 0 for a report; compare exits 1 when a test is now failing, "
               "is new and failing, or is gone; 2 for a usage problem.")
    parser.add_argument("--selftest", action="store_true", help="check this tool on canned log text and exit")
    sub = parser.add_subparsers(dest="command")
    slowest = sub.add_parser("slowest", help="the N slowest tests of one log")
    slowest.add_argument("log")
    slowest.add_argument("-n", type=int, default=20, help="how many tests to list (default 20)")
    slowest.add_argument("--classes", action="store_true", help="also list the 10 slowest classes")
    return parser


def run(args, parser):
    """Run the chosen command; return (lines, status). Raises UsageProblem."""
    if args.command == "slowest":
        return report_slowest(parse_log(args.log), top=args.n, classes=args.classes)
    parser.print_usage(sys.stderr)
    raise UsageProblem("give a command: slowest, compare, flaky, or --selftest")


def main(argv=None):
    """Entry point; returns the process exit status."""
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    try:
        lines, status = run(args, parser)
    except UsageProblem as problem:
        print(problem, file=sys.stderr)
        return 2
    print("\n".join(lines))
    return status


if __name__ == "__main__":
    sys.exit(main())
