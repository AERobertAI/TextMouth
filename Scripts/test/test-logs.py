#!/usr/bin/env python3
"""test-logs.py: read xcodebuild test logs and say which tests are slowest,
what changed between two runs, and which tests are flaky across several runs.

    python3 Scripts/test/test-logs.py slowest LOG [-n N] [--classes]
    python3 Scripts/test/test-logs.py compare OLD NEW [--slower SECONDS]
    python3 Scripts/test/test-logs.py flaky LOG LOG [LOG ...]
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
# compare
# ---------------------------------------------------------------------------

def report_compare(old, new, slower=2.0):
    """Return (lines, exit_status) for `compare` of two parsed logs."""
    lines = [
        "old log: " + (old.executed or "no Executed line (the run may have stopped early)"),
        "new log: " + (new.executed or "no Executed line (the run may have stopped early)"),
    ]
    both = sorted(set(old.results) & set(new.results))
    now_failing, now_passing, now_skipped, no_longer_skipped, slow = [], [], [], [], []
    for name in both:
        before, after = old.results[name], new.results[name]
        if before.outcome != after.outcome:
            if after.outcome == FAILED:
                now_failing.append(name)
            elif before.outcome == FAILED:  # failed, and now passed or skipped
                (now_passing if after.outcome == PASSED else now_skipped).append(name)
            elif after.outcome == SKIPPED:
                now_skipped.append(name)
            else:  # skipped before, passed now
                no_longer_skipped.append(name)
        # Slower: over the floor AND more than 1.5 times the old time.
        if after.outcome != SKIPPED and after.seconds > slower and after.seconds > 1.5 * before.seconds:
            slow.append((name, before.seconds, after.seconds))
    only_new = sorted(set(new.results) - set(old.results))
    gone = sorted(set(old.results) - set(new.results))
    new_failing = [n for n in only_new if new.results[n].outcome == FAILED]

    name_section("now failing", now_failing, lines)
    name_section("now passing", now_passing, lines)
    name_section("now skipped", now_skipped, lines)
    name_section("no longer skipped", no_longer_skipped, lines)
    name_section("new", [n + (" (failed)" if n in new_failing else "") for n in only_new], lines)
    name_section("gone", gone, lines)
    if gone:
        lines.append("a gone test means someone deleted or renamed a test: check that this was meant")
    if slow:
        slow.sort(key=lambda item: (-(item[2] - item[1]), item[0]))
        lines.append("slower (%d):" % len(slow))
        for name, before, after in slow:
            lines.append("%s: %s before, %s now" % (name, seconds_text(before), seconds_text(after)))

    changed = len(now_failing) + len(now_passing) + len(now_skipped) + len(no_longer_skipped)
    if changed == 0:
        lines.append("no test changed outcome")
    lines.append("compared %d tests: %d changed outcome, %d new, %d gone, %d slower"
                 % (len(both), changed, len(only_new), len(gone), len(slow)))
    # A failure, a failing new test, or a vanished test is what a merge script must stop on.
    return lines, 1 if (now_failing or new_failing or gone) else 0


# ---------------------------------------------------------------------------
# flaky
# ---------------------------------------------------------------------------

def outcome_summary(outcomes):
    """`passed in 2 of 3 logs, failed in 1`: the most common outcome first."""
    counts = defaultdict(int)
    for outcome in outcomes:
        counts[outcome] += 1
    order = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    parts = ["%s in %d of %d logs" % (order[0][0], order[0][1], len(outcomes))]
    parts += ["%s in %d" % (word, count) for word, count in order[1:]]
    return ", ".join(parts)


def report_flaky(parsed_logs):
    """Return (lines, 0) for `flaky` over two or more parsed logs."""
    names = sorted({n for parsed in parsed_logs for n in parsed.results})
    outcome_lines, retry_lines, time_lines = [], [], []
    seen_load = defaultdict(lambda: [set(), 0])  # label -> [test names, tests with a bad result]
    for name in names:
        present = [p.results[name] for p in parsed_logs if name in p.results]
        mark = LOAD_SENSITIVE_MARK if load_sensitive_label(name) else ""
        outcomes = [r.outcome for r in present]
        differs = len(set(outcomes)) > 1
        if differs:
            outcome_lines.append(name + " " + outcome_summary(outcomes) + mark)
        # A rerun inside one log (a retry) that changed the outcome is flakiness too.
        elif any(len(set(r.history)) > 1 for r in present):
            retry_lines.append("%s gave different results within one log (a retry): %s%s"
                               % (name, ", ".join(next(r.history for r in present if len(set(r.history)) > 1)), mark))
        # Time: ignore skipped runs, whose time is just the skip.
        times = [r.seconds for r in present if r.outcome != SKIPPED]
        if times and max(times) > VARIES_FLOOR and max(times) > VARIES_RATIO * min(times):
            time_lines.append("%s varies: %s to %s%s" % (name, seconds_text(min(times)), seconds_text(max(times)), mark))
        label = load_sensitive_label(name)
        if label:
            entry = seen_load[label]
            entry[0].add(name)
            if differs or FAILED in outcomes:
                entry[1] += 1

    lines = ["%d logs read" % len(parsed_logs)]
    name_section("outcome differs between logs", outcome_lines, lines)
    name_section("outcome differs within one log", retry_lines, lines)
    name_section("time varies", time_lines, lines)
    if seen_load:
        lines.append("known load-sensitive tests in these logs:")
        for label, (tests, bad) in sorted(seen_load.items()):
            verdict = "all passed or skipped in every log" if bad == 0 else \
                "%d with a failure or a changing outcome" % bad
            lines.append("%s: %s, %s" % (label, plural(len(tests), "test"), verdict))
    if not (outcome_lines or retry_lines or time_lines):
        lines.append("no flaky test found")
    lines.append("compared %s in %d logs: %d with a changing outcome, %d with a varying time"
                 % (plural(len(names), "test"), len(parsed_logs),
                    len(outcome_lines) + len(retry_lines), len(time_lines)))
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

CANNED_NEW = """\
Test Case '-[TextMouthProductionTests.FeedRecordTests testAChangeWaitsWhileTheDataDirectoryIsUnavailable]' passed (0.131 seconds).
Test Case '-[TextMouthProductionTests.FeedRecordTests testAFeedsSizeRoundTripsAndAnOlderRecordLoadsWithoutIt]' passed (0.002 seconds).
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testRenderedRowsExposeGoToEditNoteAndDeleteToAccessibility]' skipped (0.034 seconds).
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne]' passed (0.5 seconds).
Test Case '-[TextMouthProductionTests.Class2_With_Digits testOne]' passed (1.000 seconds).
Test Case '-[TextMouthProductionTests.Retried testTwice]' passed (0.250 seconds).
Test Case '-[TextMouthProductionTests.Brand testNew]' passed (0.010 seconds).
Test Case '-[TextMouthProductionTests.Brand testNewButBroken]' failed (0.010 seconds).
Test Case '-[TextMouthProductionTests.Steady testSlows]' passed (4.000 seconds).
Test Case '-[TextMouthProductionTests.Steady testBecomesPassing]' passed (0.100 seconds).
Test Case '-[TextMouthProductionTests.Steady testBecomesSkipped]' skipped (0.100 seconds).
Test Case '-[TextMouthProductionTests.Steady testStopsBeingSkipped]' passed (0.001 seconds).
Test Case '-[TextMouthProductionTests.Steady testBreaks]' failed (0.100 seconds).
	 Executed 13 tests, with 2 tests skipped and 2 failures (2 unexpected) in 7.0 (7.1) seconds
"""

# A third run for flaky: the bookmark test fails again, a benchmark swings in time.
CANNED_THIRD = """\
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne]' failed (7.165 seconds).
Test Case '-[TextMouthProductionTests.Steady testSlows]' passed (0.5 seconds).
Test Case '-[TextMouthProductionTests.Steady testBenchmarkSomething]' passed (0.2 seconds).
Test Case '-[TextMouthProductionTests.Class2_With_Digits testOne]' passed (1.000 seconds).
Test Case '-[TextMouthProductionTests.Steady testSwingsUnderTheFloor]' passed (0.100 seconds).
"""

CANNED_FOURTH = """\
Test Case '-[TextMouthProductionTests.BookmarkKeyboardAccessTests testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne]' passed (0.4 seconds).
Test Case '-[TextMouthProductionTests.Steady testSlows]' passed (0.5 seconds).
Test Case '-[TextMouthProductionTests.Steady testBenchmarkSomething]' passed (2.9 seconds).
Test Case '-[TextMouthProductionTests.Class2_With_Digits testOne]' passed (1.000 seconds).
Test Case '-[TextMouthProductionTests.Steady testSwingsUnderTheFloor]' passed (1.900 seconds).
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
    new = parse_lines(CANNED_NEW.splitlines())
    third = parse_lines(CANNED_THIRD.splitlines())
    fourth = parse_lines(CANNED_FOURTH.splitlines())

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

    # compare.
    lines, status = report_compare(old, new)
    check("compare status (a test now fails)", status, 1)
    contains("compare old Executed", lines, "old log: Executed 12 tests, with 2 tests skipped and 2 failures (2 unexpected) in 6.3 (6.4) seconds")
    contains("compare now failing header", lines, "now failing (1):")
    contains("compare now failing name", lines, "Steady.testBreaks")
    contains("compare now passing header", lines, "now passing (2):")
    contains("compare now passing name", lines, "Steady.testBecomesPassing")
    contains("compare a failed to passed name", lines, "BookmarkKeyboardAccessTests.testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne")
    contains("compare now skipped", lines, "Steady.testBecomesSkipped")
    contains("compare no longer skipped", lines, "Steady.testStopsBeingSkipped")
    contains("compare new header", lines, "new (2):")
    contains("compare new failing marked", lines, "Brand.testNewButBroken (failed)")
    contains("compare gone header", lines, "gone (1):")
    contains("compare gone name", lines, "Removed.testGoesAway")
    contains("compare gone explained", lines, "a gone test means someone deleted or renamed a test: check that this was meant")
    contains("compare slower", lines, "Steady.testSlows: 1.00 seconds before, 4.00 seconds now")
    check("compare slower excludes the 3.58 to 0.5 speedup", any("testAfterDeleting" in l and "before" in l for l in lines), False)
    check("compare last line", lines[-1], "compared 11 tests: 5 changed outcome, 2 new, 1 gone, 1 slower")
    same_lines, same_status = report_compare(new, new)
    check("compare identical status", same_status, 0)
    contains("compare identical says nothing changed", same_lines, "no test changed outcome")
    check("compare identical last line", same_lines[-1], "compared 13 tests: 0 changed outcome, 0 new, 0 gone, 0 slower")
    # A slowdown needs BOTH the floor and the ratio.
    fast_old = parse_lines(["Test Case '-[M.C t]' passed (0.1 seconds)."])
    fast_new = parse_lines(["Test Case '-[M.C t]' passed (1.9 seconds)."])
    check("compare under the floor is not slower", report_compare(fast_old, fast_new)[0][-1],
          "compared 1 tests: 0 changed outcome, 0 new, 0 gone, 0 slower")
    ratio_old = parse_lines(["Test Case '-[M.C t]' passed (2.5 seconds)."])
    ratio_new = parse_lines(["Test Case '-[M.C t]' passed (3.7 seconds)."])
    check("compare under 1.5 times is not slower", report_compare(ratio_old, ratio_new)[0][-1],
          "compared 1 tests: 0 changed outcome, 0 new, 0 gone, 0 slower")
    check("compare --slower is honored", report_compare(fast_old, fast_new, slower=1.0)[0][-1],
          "compared 1 tests: 0 changed outcome, 0 new, 0 gone, 1 slower")
    # A new test that only passes does not fail the gate.
    gate_new = parse_lines(["Test Case '-[M.C t]' passed (1 seconds).", "Test Case '-[M.D u]' passed (1 seconds)."])
    gate_old = parse_lines(["Test Case '-[M.C t]' passed (1 seconds)."])
    check("compare a new passing test exits 0", report_compare(gate_old, gate_new)[1], 0)

    # flaky.
    lines, status = report_flaky([old, new, third, fourth])
    check("flaky status", status, 0)
    contains("flaky logs read", lines, "4 logs read")
    contains("flaky outcome line with mark",
             lines, "BookmarkKeyboardAccessTests.testAfterDeletingTheMiddleBookmarkReturnGoesToTheNextOne"
                    " failed in 2 of 4 logs, passed in 2 (known load-sensitive)")
    contains("flaky retry within one log", lines,
             "Retried.testTwice gave different results within one log (a retry): failed, passed")
    check("flaky retry only where the outcome agrees across logs",
          any(l.startswith("Retried.testTwice failed") for l in lines), False)
    contains("flaky time varies", lines, "Steady.testSlows varies: 0.500 seconds to 4.00 seconds")
    contains("flaky time varies for a benchmark", lines,
             "Steady.testBenchmarkSomething varies: 0.200 seconds to 2.90 seconds (known load-sensitive)")
    check("flaky a swing under the floor is not varying",
          any("testSwingsUnderTheFloor varies" in l for l in lines), False)
    contains("flaky known load-sensitive summary", lines,
             "BookmarkKeyboardAccessTests: 2 tests, 1 with a failure or a changing outcome")
    contains("flaky benchmark label", lines,
             "the benchmarks (test methods with Benchmark in the name): 1 test, all passed or skipped in every log")
    check("flaky last line", lines[-1].startswith("compared 16 tests in 4 logs: "), True)
    quiet, _ = report_flaky([new, new])
    contains("flaky quiet", quiet, "no flaky test found")
    # Load-sensitive naming.
    check("load-sensitive class", load_sensitive_label("IntegrationSleepTimerTests.testAnything") is not None, True)
    check("load-sensitive exact test", load_sensitive_label(
        "DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies") is not None, True)
    check("another test in that class is not", load_sensitive_label("DataDirectoryMoveTests.testOther"), None)

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
    compare = sub.add_parser("compare", help="what changed between an old log and a new one")
    compare.add_argument("old")
    compare.add_argument("new")
    compare.add_argument("--slower", type=float, default=2.0,
                         help="a test is slower when it takes more than this many seconds now "
                              "AND more than 1.5 times its old time (default 2.0)")
    flaky = sub.add_parser("flaky", help="tests that differ in outcome or time across two or more logs")
    flaky.add_argument("logs", nargs="+")
    return parser


def run(args, parser):
    """Run the chosen command; return (lines, status). Raises UsageProblem."""
    if args.command == "slowest":
        return report_slowest(parse_log(args.log), top=args.n, classes=args.classes)
    if args.command == "compare":
        return report_compare(parse_log(args.old), parse_log(args.new), slower=args.slower)
    if args.command == "flaky":
        if len(args.logs) < 2:
            raise UsageProblem("flaky needs two or more logs")
        return report_flaky([parse_log(path) for path in args.logs])
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
