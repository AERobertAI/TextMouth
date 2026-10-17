#!/usr/bin/env python3
"""test-diff: what did this branch do to the tests that ALREADY existed?

The rule for every worker: a failing existing test means stop and ask; never
edit, weaken or work around an existing test to make a change pass. Checking
that used to mean reading the whole diff. This script lists, in a page,
exactly what a branch did to existing tests: tests removed, renamed or moved;
assertions removed or changed (before and after side by side); skips,
expected failures and conditional compilation added; timeouts raised; test
code commented out; and changes to fixtures (setUp, tearDown and friends).

It complements `trap-lint.py`, which looks at lines a branch ADDS; this looks
at what the branch CHANGED OR REMOVED. New files get only their test count
(their content is for `trap-lint` and for review).

Usage (from anywhere inside the repository):
    python3 Scripts/test/test-diff.py                         # since main
    python3 Scripts/test/test-diff.py --base team/testkit --paths TextMouthTests
    python3 Scripts/test/test-diff.py --strict                # exit 1 on any finding
    python3 Scripts/test/test-diff.py --selftest

The "before" state is the merge-base of --base and HEAD; the "after" state is
the working tree (staged and unstaged edits count, and so do untracked files).
The repository is the one containing the current directory.

Reading the output (plain words: no color, no emoji):
  * One line per changed file: `modified path: 3 added, 5 removed`,
    `added path: 12 tests`, `deleted path: 7 tests`, `renamed a to b`.
  * Then one finding per problem, as `path:line: KIND: text`, with indented
    `before:` and `after:` lines. For findings about REMOVED lines the line
    number is in the OLD file; for all others it is in the NEW file.
  * The last line counts them. MOVED-TEST (a test that moved to another file)
    is listed but is not counted as a finding.

Exit status: 0 normally; with --strict, 1 when there is any finding; 2 for a
usage or git problem. Python 3 standard library only; the git engine is
Scripts/test/difflint.py.
"""

import argparse
import bisect
import os
import re
import sys
from collections import Counter, defaultdict, namedtuple
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

# The engine lives beside this script (and importing it must not leave a
# __pycache__ folder in the repository).
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import difflint  # noqa: E402
from difflint import FileDiff, GitError  # noqa: E402

DEFAULT_PATHS = ["TextMouthProductionTests"]

# How findings are counted in the last line. A kind that is missing here
# (MOVED-TEST) is informational and is not counted.
CATEGORY = {
    "REMOVED-TEST": "removed", "REMOVED-ASSERTION": "removed",
    "RENAMED-TEST": "changed", "CHANGED-ASSERTION": "changed", "SETUP-CHANGED": "changed",
    "SKIP-ADDED": "skips", "TIMEOUT-RAISED": "timeouts", "COMMENTED-OUT": "commented out",
}

# ---------------------------------------------------------------------------
# Patterns (all searched in the comment- and string-masked "code" view)
# ---------------------------------------------------------------------------

# A test method, and any function (for renames), capturing the name.
TEST_FUNC = re.compile(r"\bfunc\s+(test\w*)\s*[(<]")
ANY_FUNC = re.compile(r"\bfunc\s+(\w+)\s*[(<]")
# A name a person gives a test to switch it off (XCTest only runs test*).
DISABLED_NAME = re.compile(r"^(?:disabled_|xtest|x_test)")

# A line that asserts, waits for, or sets up the expectation of something.
ASSERTION = re.compile(r"XCTAssert|XCTFail|XCTUnwrap|XCTExpect|\bfulfill\(|\bexpectation\(|\bfulfillment\b")

# Added lines that skip, soften or conditionally compile a test.
SKIP = re.compile(
    r"\bXCTSkip\w*|\bXCTExpectFailure\b|\bXCTExpectedFailure\b|\bcontinueAfterFailure\b"
    r"|#(?:if|else|elseif)\b")

# Commented-out test code. `try` counts only when followed by a call, so a
# prose comment ("try again") is not flagged.
COMMENTED_CODE = re.compile(r"XCTAssert|XCTFail|func\s+test|\btry[?!]?\s+(?:await\s+)?[\w.]+\s*\(")

# The functions (and the closure form) whose changes can hide a failure.
FIXTURES = {"setUp", "tearDown", "setUpWithError", "tearDownWithError", "addTeardownBlock"}

# A number that is a deadline: after `timeout:`, `within:`, `seconds:`, or
# after `+ ` on a line that is clearly about a time (`.now() + 5`).
DEADLINE = re.compile(r"(?:\b(?:timeout|within|seconds)\s*:\s*|\+\s+)(\d+(?:\.\d+)?)")
DEADLINE_CONTEXT = re.compile(r"now\(|deadline|Date\(|DispatchTime|Timeout|interval", re.I)

# How many value arguments each XCTAssert function takes; later arguments are
# the optional message.
VALUE_ARGS = {
    "XCTAssertEqual": 2, "XCTAssertNotEqual": 2, "XCTAssertIdentical": 2,
    "XCTAssertNotIdentical": 2, "XCTAssertGreaterThan": 2,
    "XCTAssertGreaterThanOrEqual": 2, "XCTAssertLessThan": 2,
    "XCTAssertLessThanOrEqual": 2, "XCTAssertTrue": 1, "XCTAssertFalse": 1,
    "XCTAssertNil": 1, "XCTAssertNotNil": 1, "XCTAssertNoThrow": 1,
    "XCTAssertThrowsError": 1,
}
# Arguments that are neither values nor the message.
LABELED_EXTRA = re.compile(r"^(?:accuracy|file|line)\s*:")
# A literal expected value: number, string, true, false or nil.
LITERAL = re.compile(r'^(?:-?\d[\d_]*(?:\.\d+)?|"(?:[^"\\]|\\.)*"|true|false|nil)$')

# How many hunk lines a SETUP-CHANGED finding prints before it stops.
SETUP_LINE_CAP = 12


# ---------------------------------------------------------------------------
# One version of a file: its text, masked views, and function extents
# ---------------------------------------------------------------------------

# A function (or a teardown closure) and the lines it spans, 1-based inclusive.
Span = namedtuple("Span", "name start end is_func")

# `func name` or `addTeardownBlock {` (the closure form must open a brace).
_SPAN_START = re.compile(
    r"\bfunc\s+(?P<func>\w+)|\b(?P<block>addTeardownBlock)\s*\(?\s*(?=\{)")
_BRACE_OR_FUNC = re.compile(r"[{}]|\bfunc\s")
_BRACE = re.compile(r"[{}]")


def find_spans(code_lines: List[str]) -> List[Span]:
    """Find every function and teardown closure in a file's masked code.

    The braces are matched in the masked view, so a brace inside a string or
    comment never confuses the count.
    """
    text = "\n".join(code_lines)
    starts = [0]                       # starts[i] = offset of line i + 1
    for line in code_lines[:-1]:
        starts.append(starts[-1] + len(line) + 1)

    def line_of(offset: int) -> int:
        return bisect.bisect_right(starts, offset)

    spans: List[Span] = []
    for m in _SPAN_START.finditer(text):
        if m.group("block"):
            open_at = m.end()          # the lookahead guarantees a "{" here
        else:
            # The body's brace is the next "{"; a "}" or another `func` first
            # means this was a declaration without a body.
            nxt = _BRACE_OR_FUNC.search(text, m.end())
            if not nxt or nxt.group() != "{":
                continue
            open_at = nxt.start()
        depth, close_at = 0, len(text) - 1
        for brace in _BRACE.finditer(text, open_at):
            depth += 1 if brace.group() == "{" else -1
            if depth == 0:
                close_at = brace.start()
                break
        spans.append(Span(m.group("func") or m.group("block"), line_of(m.start()),
                          line_of(close_at), bool(m.group("func"))))
    return spans


class Source:
    """One version (old or new) of a file."""

    def __init__(self, text: str):
        self.lines = text.split("\n")
        masked = difflint.mask_swift(text)
        self.code = masked.code                    # strings and comments blanked
        self.kept = masked.code_with_strings       # comments blanked
        self._spans: Optional[List[Span]] = None

    def code_at(self, n: int) -> str:
        """The masked code of 1-based line `n` ('' when out of range)."""
        return self.code[n - 1] if 1 <= n <= len(self.code) else ""

    def is_comment(self, n: int) -> bool:
        """True when line `n` is a comment line (text, but no code at all)."""
        if not 1 <= n <= len(self.lines):
            return False
        return bool(self.lines[n - 1].strip()) and not self.kept[n - 1].strip()

    @property
    def spans(self) -> List[Span]:
        """All functions and teardown closures (computed once)."""
        if self._spans is None:
            self._spans = find_spans(self.code)
        return self._spans

    def innermost(self, n: int, funcs_only: bool = False) -> Optional[Span]:
        """The smallest span containing line `n` (None when there is none)."""
        inside = [s for s in self.spans
                  if s.start <= n <= s.end and (s.is_func or not funcs_only)]
        return min(inside, key=lambda s: s.end - s.start) if inside else None

    def count_tests(self) -> int:
        """How many `func test…(` declarations the file has."""
        return sum(1 for line in self.code if TEST_FUNC.search(line))


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

@dataclass
class Finding:
    """One finding: `path:line: KIND: text` plus indented detail lines."""
    path: str
    line: int
    kind: str
    text: str
    details: List[str] = field(default_factory=list)

    def render(self) -> List[str]:
        """The finding as output lines (details indented by 4 spaces)."""
        return [f"{self.path}:{self.line}: {self.kind}: {self.text}"] + \
               ["    " + d for d in self.details]


def squash(text: str) -> str:
    """Whitespace-normalized text (so re-indenting is not a change)."""
    return " ".join(text.split())


# ---------------------------------------------------------------------------
# The whole diff, indexed once
# ---------------------------------------------------------------------------

class Context:
    """Everything the rules need to know about the whole diff.

    read_old / read_new are functions path -> text for the file before and
    after the change (the selftest passes dictionaries' `get`). The indexes
    let a rule ask "was this test name added somewhere else?" (a move) and
    "is an identical line added in this file?" (a reformat or a move).
    """

    def __init__(self, diffs: List[FileDiff], read_old: Callable[[str], str],
                 read_new: Callable[[str], str]):
        self.diffs = diffs
        self._read_old, self._read_new = read_old, read_new
        self._sources: Dict[Tuple[str, str], Source] = {}
        self.added_tests: Dict[str, set] = defaultdict(set)    # name -> paths
        self.removed_tests: Dict[str, set] = defaultdict(set)  # name -> paths
        # Per file, a multiset of the normalized text of every added line. A
        # rule that excuses a removed line CONSUMES one entry, so one added
        # line excuses only one removed line.
        self.added_counts: Dict[str, Counter] = defaultdict(Counter)
        for fd in diffs:
            old, new = self.old(fd), self.new(fd)
            for hunk in fd.hunks:
                for n, text in hunk.added:
                    self.added_counts[fd.path][squash(text)] += 1
                    m = new and TEST_FUNC.search(new.code_at(n))
                    if m:
                        self.added_tests[m.group(1)].add(fd.path)
                for n, _text in hunk.removed:
                    m = old and TEST_FUNC.search(old.code_at(n))
                    if m:
                        self.removed_tests[m.group(1)].add(fd.path)

    def old(self, fd: FileDiff) -> Optional[Source]:
        """The file before the change (None for a new file)."""
        if fd.status == "added":
            return None
        path = fd.old_path or fd.path
        return self._source(("old", path), self._read_old)

    def new(self, fd: FileDiff) -> Optional[Source]:
        """The file after the change (None for a deleted file)."""
        if fd.status == "deleted":
            return None
        return self._source(("new", fd.path), self._read_new)

    def _source(self, key: Tuple[str, str], reader: Callable[[str], str]) -> Source:
        if key not in self._sources:
            self._sources[key] = Source(reader(key[1]) or "")
        return self._sources[key]


# ---------------------------------------------------------------------------
# Rule: tests removed, renamed, moved (and renamed to switch them off)
# ---------------------------------------------------------------------------

def _span_of_function(source: Source, line: int, name: str) -> Tuple[int, int]:
    """The (start, end) lines of the function declared on `line` (or just it)."""
    for span in source.spans:
        if span.is_func and span.start == line and span.name == name:
            return span.start, span.end
    return line, line


def _functions(source: Optional[Source], side: List[Tuple[int, str]], pattern) -> List[Tuple[int, str]]:
    """(line, function name) for each line of a hunk side declaring a function."""
    found = []
    for n, _text in side:
        m = source and pattern.search(source.code_at(n))
        if m:
            found.append((n, m.group(1)))
    return found


def check_test_functions(fd, ctx, old, new):
    """REMOVED-TEST, MOVED-TEST, RENAMED-TEST, and disabling renames.

    Returns (findings, gone) where `gone` lists (start, end, destination) for
    every old test that disappeared, so the assertion rule can leave its
    assertions to this finding. destination is the path the test moved to, or
    None when it was removed.
    """
    findings: List[Finding] = []
    gone: List[Tuple[int, int, Optional[str]]] = []
    for hunk in fd.hunks:
        removed = _functions(old, hunk.removed, TEST_FUNC)
        added = _functions(new, hunk.added, ANY_FUNC)
        pending = []                                  # removed, name added nowhere
        for n, name in removed:
            destinations = ctx.added_tests.get(name, set())
            if fd.path in destinations:
                continue                              # still in this file
            if destinations:                          # moved to another file
                target = sorted(destinations)[0]
                findings.append(Finding(fd.path, n, "MOVED-TEST",
                                        f"{name}, {fd.path} to {target}"))
                gone.append((*_span_of_function(old, n, name), target))
                continue
            pending.append((n, name))
        # An added test (or a name that switches a test off) in the same hunk
        # whose name was not removed elsewhere is what a removed test became.
        fresh = [(n, name) for n, name in added
                 if (name.startswith("test") and name not in ctx.removed_tests)
                 or DISABLED_NAME.match(name)]
        pairs = list(zip(pending, fresh))
        for (old_n, old_name), (new_n, new_name) in pairs:
            details = [f"before: {old.lines[old_n - 1].strip()}",
                       f"after: {new.lines[new_n - 1].strip()}"]
            if DISABLED_NAME.match(new_name):
                findings.append(Finding(fd.path, new_n, "SKIP-ADDED",
                                        f"{old_name} renamed to {new_name}, so it no longer runs",
                                        details))
            else:
                findings.append(Finding(fd.path, new_n, "RENAMED-TEST",
                                        f"{old_name} renamed to {new_name}", details))
        for n, name in pending[len(pairs):]:
            findings.append(Finding(fd.path, n, "REMOVED-TEST", name,
                                    [f"before: {old.lines[n - 1].strip()}"]))
            gone.append((*_span_of_function(old, n, name), None))
    return findings, gone


# ---------------------------------------------------------------------------
# Rule: assertions removed or changed
# ---------------------------------------------------------------------------

def call_args(line: str) -> Optional[Tuple[str, List[str]]]:
    """The first XCT call on a line as (name, top-level arguments), or None.

    Tolerates a call that continues on the next line (the arguments seen so
    far are returned). Commas inside brackets or strings do not split.
    """
    m = re.search(r"\b(XCT\w+)\s*\(", line)
    if not m:
        return None
    args: List[str] = []
    current: List[str] = []
    depth, in_string, i = 0, False, m.end()
    while i < len(line):
        c = line[i]
        if in_string:
            current.append(c)
            if c == "\\" and i + 1 < len(line):
                i += 1
                current.append(line[i])
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            current.append(c)
        elif c in "([{":
            depth += 1
            current.append(c)
        elif c in ")]}":
            if depth == 0:
                break                                  # the call's own ")"
            depth -= 1
            current.append(c)
        elif c == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
        else:
            current.append(c)
        i += 1
    tail = "".join(current).strip()
    if tail or args:
        args.append(tail)
    return m.group(1), args


def _value_and_message_args(call):
    """Split a parsed call into (value args, message args); None if unknown."""
    name, args = call
    arity = VALUE_ARGS.get(name)
    if arity is None:
        return None
    return args[:arity], [a for a in args[arity:] if not LABELED_EXTRA.match(a)]


def weaker_reasons(before: str, after: str, after_is_comment: bool) -> List[str]:
    """Why the replacement of an assertion is PLAINLY weaker (maybe none).

    Only the cases the brief names are judged; anything else is a plain
    change. The reasons, in order: replaced by a comment; Equal replaced by
    NotNil/True/False on the same expression; a literal expected value
    removed; `==` replaced by `>=` or `!=`; a message argument removed.
    """
    if after_is_comment:
        return ["replaced by a comment"]
    reasons: List[str] = []
    old_call, new_call = call_args(before), call_args(after)
    if old_call and new_call:
        if (old_call[0] == "XCTAssertEqual" and old_call[1]
                and new_call[0] in ("XCTAssertNotNil", "XCTAssertTrue", "XCTAssertFalse")
                and "".join(old_call[1][0].split()) in "".join(after.split())):
            reasons.append(f"XCTAssertEqual replaced by {new_call[0]} on the same expression")
        old_split, new_split = _value_and_message_args(old_call), _value_and_message_args(new_call)
        if old_split and new_split:
            if (sum(1 for a in old_split[0] if LITERAL.match(a))
                    > sum(1 for a in new_split[0] if LITERAL.match(a))):
                reasons.append("a literal expected value was removed")
            if old_split[1] and not new_split[1]:
                reasons.append("the message argument was removed")
    if "==" in before and "==" not in after:
        for operator in (">=", "!="):
            if operator in after and operator not in before:
                reasons.append(f"== replaced by {operator}")
    return reasons


def differs_only_in_deadline(before: str, after: str) -> bool:
    """True when two lines differ only in a deadline number (a changed wait).

    A wait such as `await fulfillment(of: [e], timeout: 10)` is an assertion
    line, but changing its timeout is the timeout rule's business, not a
    changed assertion.
    """
    number = re.compile(r"\d+(?:\.\d+)?")
    return (deadline_numbers(before) != deadline_numbers(after)
            and bool(deadline_numbers(before)) and bool(deadline_numbers(after))
            and squash(number.sub("#", before)) == squash(number.sub("#", after)))


def check_assertions(fd, ctx, old, new, gone):
    """REMOVED-ASSERTION and CHANGED-ASSERTION for every hunk of a file."""
    findings: List[Finding] = []
    same_file = ctx.added_counts[fd.path]
    for hunk in fd.hunks:
        removed = [(n, t) for n, t in hunk.removed if ASSERTION.search(old.code_at(n))]
        added = [(n, t) for n, t in hunk.added if new and ASSERTION.search(new.code_at(n))]
        kept: List[Tuple[int, str]] = []
        for n, text in removed:
            key = squash(text)
            span = next((g for g in gone if g[0] <= n <= g[1]), None)
            if span and span[2] is None:
                continue          # the whole test is reported as removed
            # Excuse a line that reappears: in the destination of a moved
            # test, or anywhere in this file (a reformat or a move).
            pool = ctx.added_counts[span[2]] if span else same_file
            if pool[key] > 0:
                pool[key] -= 1
                # The identical added line must not also serve as a partner.
                twin = next((a for a in added if squash(a[1]) == key), None)
                if twin:
                    added.remove(twin)
                continue
            kept.append((n, text))
        # Partners for the rest: added assertions, or else added comments.
        partners, as_comment = added, False
        if not partners:
            partners = [(n, t) for n, t in hunk.added if new and new.is_comment(n)]
            as_comment = True
        for i, (n, text) in enumerate(kept):
            if i >= len(partners):
                findings.append(Finding(fd.path, n, "REMOVED-ASSERTION", "assertion removed",
                                        [f"before: {text.strip()}"]))
                continue
            pn, ptext = partners[i]
            if differs_only_in_deadline(text, ptext):
                continue          # reported (or fine, if lowered) by the timeout rule
            reasons = weaker_reasons(text, ptext, as_comment)
            label = ("WEAKER? " + "; ".join(reasons)) if reasons else "assertion changed"
            findings.append(Finding(fd.path, pn, "CHANGED-ASSERTION", label,
                                    [f"before: {text.strip()}", f"after: {ptext.strip()}"]))
    return findings


# ---------------------------------------------------------------------------
# Rule: skips and expected failures added
# ---------------------------------------------------------------------------

def check_skips(fd, new, already_reported):
    """SKIP-ADDED for added skip-like lines (not already reported as renames)."""
    findings: List[Finding] = []
    for hunk in fd.hunks:
        for n, text in hunk.added:
            code = new.code_at(n)
            what = None
            m = SKIP.search(code)
            if m:
                what = m.group().strip()
            else:
                f = ANY_FUNC.search(code)
                if f and DISABLED_NAME.match(f.group(1)):
                    what = f"func {f.group(1)} (a name XCTest does not run)"
            if what is None or (fd.path, n) in already_reported:
                continue
            span = new.innermost(n, funcs_only=True)
            where = span.name if span else "outside any function"
            findings.append(Finding(fd.path, n, "SKIP-ADDED", f"{what} in {where}",
                                    [f"after: {text.strip()}"]))
    return findings


# ---------------------------------------------------------------------------
# Rule: timeouts raised
# ---------------------------------------------------------------------------

def deadline_numbers(code: str) -> List[float]:
    """The deadline numbers on one masked line, in order."""
    numbers = []
    for m in DEADLINE.finditer(code):
        # A bare `+ 3` is a deadline only on a line that is about time.
        if m.group().lstrip().startswith("+") and not DEADLINE_CONTEXT.search(code):
            continue
        numbers.append(float(m.group(1)))
    return numbers


def _number(value: float) -> str:
    """5.0 prints as 5, 2.5 as 2.5."""
    return f"{value:g}"


def check_timeouts(fd, old, new):
    """TIMEOUT-RAISED when a changed line's deadline got larger."""
    findings: List[Finding] = []
    for hunk in fd.hunks:
        before = [(n, t, deadline_numbers(old.code_at(n))) for n, t in hunk.removed]
        after = [(n, t, deadline_numbers(new.code_at(n))) for n, t in hunk.added]
        before = [b for b in before if b[2]]
        after = [a for a in after if a[2]]
        for (_bn, btext, bnums), (an, atext, anums) in zip(before, after):
            raised = [(b, a) for b, a in zip(bnums, anums) if a > b]
            if raised:
                findings.append(Finding(fd.path, an, "TIMEOUT-RAISED",
                                        f"{_number(raised[0][0])} to {_number(raised[0][1])}",
                                        [f"before: {btext.strip()}", f"after: {atext.strip()}"]))
    return findings


# ---------------------------------------------------------------------------
# Rule: test code commented out
# ---------------------------------------------------------------------------

def check_commented_out(fd, new):
    """COMMENTED-OUT for added whole-line comments that hold test code."""
    findings: List[Finding] = []
    for hunk in fd.hunks:
        for n, text in hunk.added:
            if new.is_comment(n) and COMMENTED_CODE.search(text):
                findings.append(Finding(fd.path, n, "COMMENTED-OUT", "test code in a comment",
                                        [f"after: {text.strip()}"]))
    return findings


# ---------------------------------------------------------------------------
# Rule: fixtures (setUp, tearDown, ...) changed
# ---------------------------------------------------------------------------

def _fixtures_touched(source: Optional[Source], numbers: List[int]) -> List[str]:
    """The fixture names whose extent holds any of the given lines."""
    names: List[str] = []
    for n in numbers:
        for span in (source.spans if source else []):
            if span.name in FIXTURES and span.start <= n <= span.end and span.name not in names:
                names.append(span.name)
    return names


def check_fixtures(fd, old, new):
    """SETUP-CHANGED for a hunk that touches a fixture; prints its lines."""
    findings: List[Finding] = []
    for hunk in fd.hunks:
        names = _fixtures_touched(old, [n for n, _ in hunk.removed])
        for name in _fixtures_touched(new, [n for n, _ in hunk.added]):
            if name not in names:
                names.append(name)
        if not names:
            continue
        details = [f"- {t.strip()}" for _, t in hunk.removed] + \
                  [f"+ {t.strip()}" for _, t in hunk.added]
        if len(details) > SETUP_LINE_CAP:
            hidden = len(details) - SETUP_LINE_CAP
            details = details[:SETUP_LINE_CAP] + [f"... {hidden} more lines"]
        line = hunk.added[0][0] if hunk.added else hunk.removed[0][0]
        findings.append(Finding(fd.path, line, "SETUP-CHANGED", ", ".join(names), details))
    return findings


# ---------------------------------------------------------------------------
# Putting it together
# ---------------------------------------------------------------------------

def file_line(fd: FileDiff, ctx: Context) -> str:
    """The one-line description of what happened to a file."""
    added = sum(len(h.added) for h in fd.hunks)
    removed = sum(len(h.removed) for h in fd.hunks)
    if fd.status == "added":
        return f"added {fd.path}: {ctx.new(fd).count_tests()} tests"
    if fd.status == "deleted":
        return f"deleted {fd.path}: {ctx.old(fd).count_tests()} tests"
    if fd.status == "renamed":
        suffix = f": {added} added, {removed} removed" if fd.hunks else ""
        return f"renamed {fd.old_path} to {fd.path}{suffix}"
    return f"modified {fd.path}: {added} added, {removed} removed"


def analyze(diffs: List[FileDiff], read_old: Callable[[str], str],
            read_new: Callable[[str], str]) -> Tuple[List[str], int]:
    """Run every rule over the diff; return (output lines, finding count)."""
    ctx = Context(diffs, read_old, read_new)
    ordered = sorted(diffs, key=lambda fd: fd.path)
    # A file with no hunks and no status change (a mode change) says nothing.
    ordered = [fd for fd in ordered if fd.hunks or fd.status != "modified"]
    lines = [file_line(fd, ctx) for fd in ordered]

    findings: List[Finding] = []
    for fd in ordered:
        if fd.status == "added":
            continue              # a new file: only its test count
        old, new = ctx.old(fd), ctx.new(fd)
        found, gone = check_test_functions(fd, ctx, old, new)
        found += check_assertions(fd, ctx, old, new, gone)
        if new:                   # nothing to look at in a deleted file
            reported = {(f.path, f.line) for f in found if f.kind == "SKIP-ADDED"}
            found += check_skips(fd, new, reported)
            found += check_timeouts(fd, old, new)
            found += check_commented_out(fd, new)
            found += check_fixtures(fd, old, new)
        found.sort(key=lambda f: f.line)
        findings += found

    for finding in findings:
        lines += finding.render()
    counts = Counter(CATEGORY[f.kind] for f in findings if f.kind in CATEGORY)
    total = sum(counts.values())
    if not total:
        lines.append("no existing test was weakened or removed")
    lines.append(
        f"{len(ordered)} files changed, {total} findings: {counts['removed']} removed, "
        f"{counts['changed']} changed, {counts['skips']} skips, {counts['timeouts']} timeouts, "
        f"{counts['commented out']} commented out")
    return lines, total


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    """Parse the command line, run git, print the report; return the status."""
    parser = argparse.ArgumentParser(
        description="List what this branch did to the tests that already existed: "
                    "tests removed, renamed or moved; assertions removed or changed; "
                    "skips added; timeouts raised; test code commented out; fixtures "
                    "changed. For findings about removed lines the line number is in "
                    "the old file; for the others it is in the new file.")
    parser.add_argument("--base", default="main",
                        help="the before state is the merge-base of this ref and HEAD (default: main)")
    parser.add_argument("--paths", nargs="+", default=list(DEFAULT_PATHS), metavar="P",
                        help="folders or files to compare, relative to the repository root "
                             f"(default: {' '.join(DEFAULT_PATHS)})")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when there is any finding")
    parser.add_argument("--selftest", action="store_true",
                        help="check the rules against canned diffs and exit")
    args = parser.parse_args(argv)  # argparse exits 2 on a usage error

    if args.selftest:
        return 0 if selftest() else 1
    try:
        root = difflint.repo_root()
        merge_base, diffs = difflint.diff_files(args.base, args.paths, root)
    except GitError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    def read_old(path: str) -> str:
        """A file as it was at the merge-base ('' when it did not exist)."""
        try:
            return difflint.run_git(["show", f"{merge_base}:{path}"], cwd=root)
        except GitError:
            return ""

    def read_new(path: str) -> str:
        """A file as it is in the working tree ('' when unreadable)."""
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError:
            return ""

    # Only Swift sources are tests; other files under the paths are ignored.
    diffs = [fd for fd in diffs if fd.path.endswith(".swift")]
    lines, total = analyze(diffs, read_old, read_new)
    print("\n".join(lines))
    return 1 if args.strict and total else 0


# ---------------------------------------------------------------------------
# Self-test: canned before/after files, one case per kind of finding
# ---------------------------------------------------------------------------

# A test class several cases start from. Line numbers matter to the expected
# output: setUp is lines 4-7, testAlpha 9-12, testBeta 14-17, testGamma 19-21,
# helper 23-25.
BASE = """import XCTest

final class FooTests: XCTestCase {
    override func setUp() {
        super.setUp()
        value = 1
    }

    func testAlpha() {
        XCTAssertEqual(value, 1)
        XCTAssertNotNil(thing)
    }

    func testBeta() throws {
        let item = try XCTUnwrap(maker())
        XCTAssertTrue(item.ok, "item should be ok")
    }

    func testGamma() {
        wait(for: [exp], timeout: 5)
    }

    func helper() {
        let a = 1
    }
}
"""

# Seven assertions, each separated from the next so every change is its own
# hunk. Lines 3, 5, 7, 9, 11, 13 and 15 hold the assertions.
ASSERTS = """final class AssertTests: XCTestCase {
    func testOne() {
        XCTAssertEqual(count, 3)
        step()
        XCTAssertEqual(name, other)
        step()
        XCTAssertTrue(items.count == 4)
        step()
        XCTAssertTrue(ok, "ok must hold")
        step()
        XCTAssertEqual(total, 10)
        step()
        XCTAssertNil(failure)
        step()
        XCTAssertEqual(width, 8)
    }
}
"""

TIMES = """final class TimeTests: XCTestCase {
    func testA() {
        let d = DispatchTime.now() + 2
        let n = count + 1
    }
}
"""

TEARDOWN = """final class TidyTests: XCTestCase {
    func testT() {
        addTeardownBlock {
            cleanup()
        }
    }
}
"""

WAITS = """final class WaitTests: XCTestCase {
    func testW() async {
        await fulfillment(of: [done], timeout: 10)
    }
}
"""

OTHER = """final class BarTests: XCTestCase {
    func testOne() {
        XCTAssertTrue(true)
    }
}
"""


def _edit(text: str, before: str, after: str) -> str:
    """Replace the one occurrence of `before` (a typo in a case fails loudly)."""
    assert text.count(before) == 1, before
    return text.replace(before, after)


def _file_diff_text(path, old, new, old_path=None) -> List[str]:
    """A git-style diff for one canned file (old None = new file, new None = deleted)."""
    import difflib
    if old_path:
        head = [f"diff --git a/{old_path} b/{path}", "similarity index 90%",
                f"rename from {old_path}", f"rename to {path}"]
    else:
        head = [f"diff --git a/{path} b/{path}"]
        if old is None:
            head.append("new file mode 100644")
        elif new is None:
            head.append("deleted file mode 100644")
    body = list(difflib.unified_diff((old or "").splitlines(), (new or "").splitlines(),
                                     n=0, lineterm=""))[2:]      # drop ---/+++
    if body:
        head += [f"--- {'/dev/null' if old is None else 'a/' + (old_path or path)}",
                 f"+++ {'/dev/null' if new is None else 'b/' + path}"]
    return head + body


def _run_case(files) -> List[str]:
    """Analyze canned files: (path, old, new[, old_path]) tuples."""
    diff, olds, news = [], {}, {}
    for path, old, new, *rest in files:
        old_path = rest[0] if rest else None
        diff += _file_diff_text(path, old, new, old_path)
        if old is not None:
            olds[old_path or path] = old
        if new is not None:
            news[path] = new
    lines, _total = analyze(difflint.parse_hunks("\n".join(diff) + "\n"),
                            lambda p: olds.get(p, ""), lambda p: news.get(p, ""))
    return lines


T = "Tests/FooTests.swift"

# (name, files, expected output lines)
CASES = [
    ("clean change and a pure addition", [
        (T, BASE, _edit(BASE, "        let a = 1\n    }\n",
                        "        let a = 2\n    }\n\n    func testDelta() {\n"
                        "        XCTAssertTrue(true)\n    }\n"))], [
        f"modified {T}: 5 added, 1 removed",
        "no existing test was weakened or removed",
        "1 files changed, 0 findings: 0 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a new file reports only its test count", [
        ("Tests/NewTests.swift", None, OTHER + OTHER.replace("testOne", "testTwo"))], [
        "added Tests/NewTests.swift: 2 tests",
        "no existing test was weakened or removed",
        "1 files changed, 0 findings: 0 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a deleted file is a finding for every test", [(T, BASE, None)], [
        f"deleted {T}: 3 tests",
        f"{T}:9: REMOVED-TEST: testAlpha",
        "    before: func testAlpha() {",
        f"{T}:14: REMOVED-TEST: testBeta",
        "    before: func testBeta() throws {",
        f"{T}:19: REMOVED-TEST: testGamma",
        "    before: func testGamma() {",
        "1 files changed, 3 findings: 3 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a removed test (its assertions are not listed again)", [
        (T, BASE, _edit(BASE, "    func testBeta() throws {\n        let item = try XCTUnwrap(maker())\n"
                              "        XCTAssertTrue(item.ok, \"item should be ok\")\n    }\n\n", ""))], [
        f"modified {T}: 0 added, 5 removed",
        f"{T}:14: REMOVED-TEST: testBeta",
        "    before: func testBeta() throws {",
        "1 files changed, 1 findings: 1 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a moved test is listed once and its assertions follow it", [
        (T, BASE, _edit(BASE, "    func testBeta() throws {\n        let item = try XCTUnwrap(maker())\n"
                              "        XCTAssertTrue(item.ok, \"item should be ok\")\n    }\n\n", "")),
        ("Tests/BarTests.swift", OTHER, _edit(OTHER, "    }\n}\n",
            "    }\n    func testBeta() throws {\n        let item = try XCTUnwrap(maker())\n"
            "        XCTAssertTrue(item.ok, \"item should be ok\")\n    }\n}\n"))], [
        "modified Tests/BarTests.swift: 4 added, 0 removed",
        f"modified {T}: 0 added, 5 removed",
        f"{T}:14: MOVED-TEST: testBeta, {T} to Tests/BarTests.swift",
        "no existing test was weakened or removed",
        "2 files changed, 0 findings: 0 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a renamed test", [(T, BASE, _edit(BASE, "testAlpha", "testAlphaValue"))], [
        f"modified {T}: 1 added, 1 removed",
        f"{T}:9: RENAMED-TEST: testAlpha renamed to testAlphaValue",
        "    before: func testAlpha() {",
        "    after: func testAlphaValue() {",
        "1 files changed, 1 findings: 0 removed, 1 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a removed assertion, and one replaced by something that is not an assertion", [
        (T, BASE, _edit(BASE, "        XCTAssertNotNil(thing)\n", "")),
        ("Tests/Other.swift", ASSERTS, _edit(ASSERTS, "        XCTAssertNil(failure)\n",
                                             "        _ = failure\n"))], [
        f"modified {T}: 0 added, 1 removed",
        "modified Tests/Other.swift: 1 added, 1 removed",
        f"{T}:11: REMOVED-ASSERTION: assertion removed",
        "    before: XCTAssertNotNil(thing)",
        "Tests/Other.swift:13: REMOVED-ASSERTION: assertion removed",
        "    before: XCTAssertNil(failure)",
        "2 files changed, 2 findings: 2 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("changed assertions: the plainly weaker ones are marked", [
        ("Tests/AssertTests.swift", ASSERTS, (
            _edit(_edit(_edit(_edit(_edit(_edit(ASSERTS,
                "XCTAssertEqual(count, 3)", "XCTAssertEqual(count, expected)"),
                "XCTAssertEqual(name, other)", "XCTAssertNotNil(name)"),
                "items.count == 4", "items.count >= 4"),
                "XCTAssertTrue(ok, \"ok must hold\")", "XCTAssertTrue(ok)"),
                "XCTAssertEqual(total, 10)", "XCTAssertEqual(total, 11)"),
                "XCTAssertNil(failure)", "XCTAssertNil(failure, \"none\")")))], [
        "modified Tests/AssertTests.swift: 6 added, 6 removed",
        "Tests/AssertTests.swift:3: CHANGED-ASSERTION: WEAKER? a literal expected value was removed",
        "    before: XCTAssertEqual(count, 3)",
        "    after: XCTAssertEqual(count, expected)",
        "Tests/AssertTests.swift:5: CHANGED-ASSERTION: WEAKER? XCTAssertEqual replaced by "
        "XCTAssertNotNil on the same expression",
        "    before: XCTAssertEqual(name, other)",
        "    after: XCTAssertNotNil(name)",
        "Tests/AssertTests.swift:7: CHANGED-ASSERTION: WEAKER? == replaced by >=",
        "    before: XCTAssertTrue(items.count == 4)",
        "    after: XCTAssertTrue(items.count >= 4)",
        "Tests/AssertTests.swift:9: CHANGED-ASSERTION: WEAKER? the message argument was removed",
        "    before: XCTAssertTrue(ok, \"ok must hold\")",
        "    after: XCTAssertTrue(ok)",
        "Tests/AssertTests.swift:11: CHANGED-ASSERTION: assertion changed",
        "    before: XCTAssertEqual(total, 10)",
        "    after: XCTAssertEqual(total, 11)",
        "Tests/AssertTests.swift:13: CHANGED-ASSERTION: assertion changed",
        "    before: XCTAssertNil(failure)",
        "    after: XCTAssertNil(failure, \"none\")",
        "1 files changed, 6 findings: 0 removed, 6 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("an assertion only re-indented is not a change", [
        (T, BASE, _edit(BASE, "        XCTAssertEqual(value, 1)\n", "            XCTAssertEqual(value, 1)\n"))], [
        f"modified {T}: 1 added, 1 removed",
        "no existing test was weakened or removed",
        "1 files changed, 0 findings: 0 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("skips, conditional compilation and continueAfterFailure added", [
        (T, BASE, _edit(_edit(_edit(BASE,
            "        super.setUp()\n", "        super.setUp()\n        continueAfterFailure = false\n"),
            "    func testAlpha() {\n", "    func testAlpha() {\n        try XCTSkipIf(flag)\n"),
            "        wait(for: [exp], timeout: 5)\n",
            "        #if DEBUG\n        wait(for: [exp], timeout: 5)\n        #endif\n"))], [
        f"modified {T}: 4 added, 0 removed",
        f"{T}:6: SKIP-ADDED: continueAfterFailure in setUp",
        "    after: continueAfterFailure = false",
        f"{T}:6: SETUP-CHANGED: setUp",
        "    + continueAfterFailure = false",
        f"{T}:11: SKIP-ADDED: XCTSkipIf in testAlpha",
        "    after: try XCTSkipIf(flag)",
        f"{T}:22: SKIP-ADDED: #if in testGamma",
        "    after: #if DEBUG",
        "1 files changed, 4 findings: 0 removed, 1 changed, 3 skips, 0 timeouts, 0 commented out"]),

    ("a test renamed so that it no longer runs", [
        (T, BASE, _edit(BASE, "testBeta", "disabled_testBeta"))], [
        f"modified {T}: 1 added, 1 removed",
        f"{T}:14: SKIP-ADDED: testBeta renamed to disabled_testBeta, so it no longer runs",
        "    before: func testBeta() throws {",
        "    after: func disabled_testBeta() throws {",
        "1 files changed, 1 findings: 0 removed, 0 changed, 1 skips, 0 timeouts, 0 commented out"]),

    ("a raised timeout (a lowered one is fine)", [
        (T, BASE, _edit(BASE, "timeout: 5", "timeout: 30")),
        ("Tests/Lower.swift", BASE, _edit(BASE, "timeout: 5", "timeout: 2"))], [
        f"modified {T}: 1 added, 1 removed",
        "modified Tests/Lower.swift: 1 added, 1 removed",
        f"{T}:20: TIMEOUT-RAISED: 5 to 30",
        "    before: wait(for: [exp], timeout: 5)",
        "    after: wait(for: [exp], timeout: 30)",
        "2 files changed, 1 findings: 0 removed, 0 changed, 0 skips, 1 timeouts, 0 commented out"]),

    ("a raised fulfillment timeout is one finding, not two", [
        ("Tests/WaitTests.swift", WAITS, _edit(WAITS, "timeout: 10", "timeout: 60"))], [
        "modified Tests/WaitTests.swift: 1 added, 1 removed",
        "Tests/WaitTests.swift:3: TIMEOUT-RAISED: 10 to 60",
        "    before: await fulfillment(of: [done], timeout: 10)",
        "    after: await fulfillment(of: [done], timeout: 60)",
        "1 files changed, 1 findings: 0 removed, 0 changed, 0 skips, 1 timeouts, 0 commented out"]),

    ("a raised deadline after + counts only on a line about time", [
        ("Tests/TimeTests.swift", TIMES, _edit(_edit(TIMES, "now() + 2", "now() + 20"),
                                                "count + 1", "count + 9"))], [
        "modified Tests/TimeTests.swift: 2 added, 2 removed",
        "Tests/TimeTests.swift:3: TIMEOUT-RAISED: 2 to 20",
        "    before: let d = DispatchTime.now() + 2",
        "    after: let d = DispatchTime.now() + 20",
        "1 files changed, 1 findings: 0 removed, 0 changed, 0 skips, 1 timeouts, 0 commented out"]),

    ("test code commented out (prose comments are fine)", [
        (T, BASE, _edit(_edit(BASE, "        let item = try XCTUnwrap(maker())\n",
                              "        // let item = try XCTUnwrap(maker())\n"),
                        "        let a = 1\n", "        // try again when ready\n        let a = 1\n"))], [
        f"modified {T}: 2 added, 1 removed",
        f"{T}:15: CHANGED-ASSERTION: WEAKER? replaced by a comment",
        "    before: let item = try XCTUnwrap(maker())",
        "    after: // let item = try XCTUnwrap(maker())",
        f"{T}:15: COMMENTED-OUT: test code in a comment",
        "    after: // let item = try XCTUnwrap(maker())",
        "1 files changed, 2 findings: 0 removed, 1 changed, 0 skips, 0 timeouts, 1 commented out"]),

    ("fixtures: setUp and addTeardownBlock", [
        (T, BASE, _edit(BASE, "        value = 1\n", "        value = 2\n")),
        ("Tests/TidyTests.swift", TEARDOWN, _edit(TEARDOWN, "cleanup()", "other()"))], [
        f"modified {T}: 1 added, 1 removed",
        "modified Tests/TidyTests.swift: 1 added, 1 removed",
        f"{T}:6: SETUP-CHANGED: setUp",
        "    - value = 1",
        "    + value = 2",
        "Tests/TidyTests.swift:4: SETUP-CHANGED: addTeardownBlock",
        "    - cleanup()",
        "    + other()",
        "2 files changed, 2 findings: 0 removed, 2 changed, 0 skips, 0 timeouts, 0 commented out"]),

    ("a renamed file: edits count against the new name, a pure rename says nothing", [
        ("Tests/New.swift", BASE, _edit(BASE, "        XCTAssertNotNil(thing)\n", ""), "Tests/Old.swift"),
        ("Tests/Same.swift", OTHER, OTHER, "Tests/Was.swift")], [
        "renamed Tests/Old.swift to Tests/New.swift: 0 added, 1 removed",
        "renamed Tests/Was.swift to Tests/Same.swift",
        "Tests/New.swift:11: REMOVED-ASSERTION: assertion removed",
        "    before: XCTAssertNotNil(thing)",
        "2 files changed, 1 findings: 1 removed, 0 changed, 0 skips, 0 timeouts, 0 commented out"]),
]


def selftest() -> bool:
    """Run every canned case and the helper checks; True when all pass."""
    failures: List[str] = []

    def check(name: str, condition: bool):
        if not condition:
            failures.append(name)

    for name, files, expected in CASES:
        actual = _run_case(files)
        if actual != expected:
            failures.append(name)
            print(f"--- case: {name}\n  expected:")
            print("\n".join("    " + line for line in expected))
            print("  actual:")
            print("\n".join("    " + line for line in actual))

    # --- helpers ------------------------------------------------------------
    check("call_args splits top-level commas",
          call_args('XCTAssertEqual(f(a, b), [1, 2], "x, y")') ==
          ("XCTAssertEqual", ["f(a, b)", "[1, 2]", '"x, y"']))
    check("call_args tolerates a call that continues",
          call_args("XCTAssertEqual(first,") == ("XCTAssertEqual", ["first", ""]))
    check("no call, no args", call_args("let x = 1") is None)
    check("deadline numbers", deadline_numbers("wait(for: [e], timeout: 2.5)") == [2.5]
          and deadline_numbers("let n = a + 1") == [] and deadline_numbers("x.now() + 3") == [3.0])
    spans = find_spans(difflint.mask_swift("func a() {\n  let s = \"}\"\n  func b() {\n  }\n}\n").code)
    check("spans ignore braces in strings and nest",
          [(s.name, s.start, s.end) for s in spans] == [("a", 1, 5), ("b", 3, 4)])
    check("a declaration without a body has no span",
          find_spans(difflint.mask_swift("protocol P {\n  func a()\n  func b() {\n  }\n}\n").code)[0].name == "b")

    for name in failures:
        print(f"selftest FAILED: {name}")
    if not failures:
        print(f"test-diff selftest: all {len(CASES)} cases and the helper checks passed")
    return not failures


if __name__ == "__main__":
    sys.exit(main())
