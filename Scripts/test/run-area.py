#!/usr/bin/env python3
"""run-area.py: runs the hosted tests of one or more areas, and prints a short result.

Usage: Scripts/test/run-area.py [options] NAME [NAME ...]

A NAME is an area (listed in Scripts/test/areas.conf) or a test class. `all`
is a built-in area: every runnable hosted test class (those no area lists
yet come last). Order is kept, repeats are
dropped, and ONE xcodebuild run covers them all (each launch of the test host
leaves about 23 MB in a system cache only the user can purge, so never run the
areas one after another).

While it runs nothing is printed: xcodebuild's whole output goes to a log
file. Afterwards it prints one fact per line, in plain words:
  1. the last "Executed N tests, ..." line, or "no tests ran";
  2. each failed test:    FAILED FooTests.testBar at File.swift:123: message
  3. each compile error:  ERROR File.swift:12: message (20 at most, then "and N more");
  4. each Swift warning inside the repository: WARNING File.swift:12: message;
  5. a CRASH line when the log shows the test host crashed or restarted;
  6. the log's path;
  7. the last line: PASSED or FAILED, then the elapsed time.

Options:
  --list              with no NAME: one line per area (name, class count,
                      description); with NAMEs: their classes, one per line;
                      with --changed: only the --changed report, no run
  --classes A,B       more classes, comma separated (repeatable)
  --changed           pick the classes whose file mentions a type declared in a file
                      changed since the merge-base of --base and HEAD (staged,
                      unstaged, committed and untracked, under TextMouth/,
                      TextMouthProductionTests/ and TestData/); a class declared in a
                      changed test file always comes first. Prints "score  Class"
                      lines (the number of changed type names the class's file
                      mentions), a count line with the areas, and then RUNS them
                      with any NAMEs given, like any NAMEs. It is a heuristic: a test
                      that mentions no changed type is missed, so run the area or
                      "all" before a merge. A name that over 150 test files mention
                      is dropped from the scoring (the report says how many).
  --base REF          the comparison point of --changed (default main)
  --explain           with --changed: the matching type names under each class
  --limit N           with --changed: keep the first N classes
  --repeat N          (2 to 20) build ONCE for testing, then run the chosen classes N
                      times with test-without-building, each run to its own log
                      (<log>.1, <log>.2, ...), all while holding one build slot.
                      Prints each run's lines, then the "test-logs.py flaky" report
                      over the N logs ("no test changed outcome in N runs" when
                      nothing varied), then "PASSED in all N runs" or "FAILED in K
                      of N runs"; exit 0 only when every run passed. Each run
                      launches the test host, which leaves about 23 MB in a system
                      cache only the user can purge, so use it for a suspected
                      flaky test, not as a habit. --env reaches the runs only.
  --dry-run           print the command (one shell-quoted line; with --repeat, the build
                      step and each run step, labeled) and exit 0
  --unassigned        print the test classes no area lists, then a count line
  --selftest          check the script against canned logs and areas.conf; no build
  --summarize LOG     print the summary of an existing xcodebuild log and exit
                      with its verdict (0 PASSED, 1 FAILED)
  --env NAME=VALUE    pass TEST_RUNNER_NAME=VALUE to the test host (repeatable);
                      a value is printed only by --dry-run
  --derived-data DIR  build folder; default <tempdir>/TextMouth-DerivedData-<suffix>
  --log FILE          log file;     default <tempdir>/TextMouth-area-<suffix>.log
                      (<suffix> is $BBS_AGENT when set, else "area")
  --jobs N            xcodebuild -jobs (default 4)
  --xcodebuild-arg=ARG  one more argument for xcodebuild (repeatable; give it with an equals sign,
                      as --xcodebuild-arg=-test-timeouts-enabled, since it starts with a hyphen);
                      not used by --repeat
  --no-slot           do not hold a build slot (for a Mac with no agents running)
  --clean             unregister the build folder's app and delete the folder
  -h, --help          this text

Build slots: the command runs through
.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, so a user needs no
registration; an agent sets BBS_AGENT=<name> to report to the board. The
wrapper's own messages go to the log.

Exit status: 0 PASSED, 1 FAILED, 2 a usage or setup error (an unknown name, no
xcodebuild, areas.conf unreadable), 130 interrupted with Ctrl-C (the log is kept).
"""

import argparse
import contextlib
import io
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import replace
from pathlib import Path

# Importing testkit must not leave a __pycache__ folder in the repository
# (git does not ignore it), so write no bytecode, as trap-lint.py does.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import difflint  # noqa: E402  (the path above must be set first)
import testkit  # noqa: E402

# Where macOS keeps the tool that unregisters an app from Launch Services.
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
# A folder --clean deletes must have this in its name.
DERIVED_DATA_MARK = "TextMouth-DerivedData"


def usage_error(message: str) -> int:
    """Prints a usage or setup error to stderr and returns the exit status 2."""
    print(f"run-area.py: {message}", file=sys.stderr)
    return 2


def parse_args(argv):
    """Parses the command line (help is the header comment, not argparse's)."""
    parser = argparse.ArgumentParser(add_help=False, prog="run-area.py")
    parser.add_argument("names", nargs="*")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--classes", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--unassigned", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--summarize", metavar="LOG")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--derived-data")
    parser.add_argument("--log")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--xcodebuild-arg", action="append", default=[])
    parser.add_argument("--no-slot", action="store_true")
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--changed", action="store_true")
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--explain", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--repeat", type=int)
    return parser.parse_args(argv)


def default_paths(args):
    """The build folder and log: explicit options, else <tempdir>/...-<suffix>."""
    suffix = os.environ.get("BBS_AGENT") or "area"
    tmp = tempfile.gettempdir()
    derived = args.derived_data or os.path.join(tmp, f"{DERIVED_DATA_MARK}-{suffix}")
    log = args.log or os.path.join(tmp, f"TextMouth-area-{suffix}.log")
    return derived, log


def parse_env(pairs):
    """Turns NAME=VALUE words into a dict; returns (dict, error message or None)."""
    env = {}
    for pair in pairs:
        name, equals, value = pair.partition("=")
        if not equals or not name or not (name[0].isalpha() or name[0] == "_") \
                or not all(c.isalnum() or c == "_" for c in name):
            return {}, f"--env wants NAME=VALUE with a name of letters, digits and underscores, not '{pair}'"
        env[name] = value
    return env, None


def split_classes(values):
    """Splits repeated comma-separated --classes values into class names."""
    return [name.strip() for value in values for name in value.split(",") if name.strip()]


# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------

def list_lines(names, areas, classes):
    """Lines for --list: every area when no NAME, else each NAME's classes."""
    if not names:
        everything = testkit.resolve_names([testkit.ALL_AREA], areas, classes)
        lines = [f"{a.name}: {len(a.classes)} classes. {a.description}" for a in areas]
        lines.append(f"{testkit.ALL_AREA}: {len(everything)} classes. Every runnable test class, those no area lists yet last")
        return lines
    return testkit.resolve_names(names, areas, classes)


def unassigned_lines(areas, classes):
    """Lines for --unassigned: runnable classes no area lists, then a count."""
    listed = set(testkit.area_classes(areas, testkit.ALL_AREA))
    missing = sorted(n for n, c in classes.items() if c.runnable and n not in listed)
    return missing + [f"{len(missing)} unassigned classes"]


# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

def clean(folder: str) -> int:
    """Unregisters the build's app from Launch Services, then deletes the folder."""
    path = Path(folder)
    if DERIVED_DATA_MARK not in path.name:
        return usage_error(f"refusing to delete '{folder}': its name lacks '{DERIVED_DATA_MARK}'")
    if not path.exists():
        print(f"nothing to clean: {folder} does not exist")
        return 0
    app = path / "Build" / "Products" / "Debug" / "TextMouth.app"
    if app.exists() and os.path.exists(LSREGISTER):
        # A failure here only leaves a stale registration; the folder still goes.
        subprocess.run([LSREGISTER, "-u", str(app)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        return usage_error(f"could not delete {folder}")
    print(f"cleaned {folder}")
    return 0


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def run_child(command, env, root, log_path):
    """Runs the command with all its output in the log. Returns its exit status.

    The child gets its own process group, so a Ctrl-C reaches this script (not
    the child directly); this script then forwards an interrupt to the group
    and gives it time to release its build slot. Raises KeyboardInterrupt
    after the child has stopped.
    """
    with open(log_path, "wb") as log:
        child = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait()
        except KeyboardInterrupt:
            for sig, patience in ((signal.SIGINT, 20), (signal.SIGTERM, 10), (signal.SIGKILL, 5)):
                try:
                    os.killpg(child.pid, sig)
                    child.wait(timeout=patience)
                    break
                except (subprocess.TimeoutExpired, ProcessLookupError):
                    continue
            raise


def summarize_file(log_path, root, elapsed=None, status=None):
    """Reads a log into a Summary (with path and elapsed set); a nonzero child status never passes."""
    text = Path(log_path).read_text(encoding="utf-8", errors="replace")
    summary = testkit.summarize_log(text, root)
    if status:
        summary = replace(summary, succeeded=False)
    return replace(summary, log_path=str(log_path), elapsed=elapsed)


def print_lines(lines):
    """Prints each line on its own, flushing at the end."""
    for line in lines:
        print(line)
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# --changed: which hosted tests mention the code a branch changed?
# ---------------------------------------------------------------------------

# The folders whose changes count, and the default comparison point.
CHANGED_APP = "TextMouth/"
CHANGED_TESTS = "TextMouthProductionTests/"
CHANGED_DATA = "TestData/"
DEFAULT_BASE = "main"

# A class declared in a changed test file always outranks any mention score.
CHANGED_TEST_SCORE = 1000
# A name that more test files than this mention says nothing about any one of
# them, so it is dropped from the scoring.
COMMON_NAME_LIMIT = 150
# --explain shows at most this many matching names under a class.
MAX_EXPLAINED = 5

# Types an `extension` may add to without that saying anything about the app's
# own code: the standard library, Foundation, AppKit, SwiftUI, AVFoundation, the
# JSON coders, CoreGraphics, and the test framework's base class.
IGNORED_EXTENSIONS = frozenset("""
    String Substring Character Array ArraySlice Dictionary Set Optional Result Range ClosedRange
    Int Int64 UInt UInt32 UInt64 Double Float CGFloat Bool Collection Sequence RandomAccessCollection
    BidirectionalCollection MutableCollection RangeReplaceableCollection Comparable Equatable
    Hashable Identifiable Codable Encodable Decodable Error LocalizedError Task
    Data URL Date Calendar TimeInterval Notification NotificationCenter UUID Locale Bundle
    FileManager UserDefaults ProcessInfo Process Pipe Thread DispatchQueue OperationQueue
    NSObject NSString NSAttributedString NSRange NSURL NSNumber NSError NSRegularExpression
    NSView NSWindow NSApplication NSTextView NSTableView NSControl NSMenu NSMenuItem NSImage NSColor
    NSFont NSSound NSPasteboard NSAlert NSOpenPanel NSSavePanel NSWorkspace NSSplitView NSToolbar
    CGRect CGPoint CGSize NSRect NSPoint NSSize
    View Scene Text Button Image Color Font Binding State FocusedValues FocusedValue EnvironmentValues
    Commands Toggle Picker Slider List Form Section Menu Label Alert Animation Edge Axis
    AVAudioPCMBuffer AVAudioFile AVAudioFormat AVAudioEngine AVAudioTime AVAudioPlayerNode
    AVAsset AVURLAsset AVPlayer AVPlayerItem AVSpeechSynthesizer AVSpeechSynthesisVoice
    AVSpeechUtterance AVMetadataItem CMTime
    JSONDecoder JSONEncoder PropertyListDecoder PropertyListEncoder XCTestCase XCTest
    Archive
""".split())

# A Swift keyword that can follow `class` without declaring a type
# (`class func`, `class var`, ...): such a line names no type.
_NOT_A_TYPE_NAME = frozenset("func var let init subscript override final static private "
                             "fileprivate internal public open".split())
# A type declaration at column 0 or nested one level (4 spaces), after any
# attributes and modifiers: `@MainActor final class Foo: Bar {`, `extension A.B {`.
_TYPE_DECLARATION = re.compile(
    r"^(?: {4})?(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|fileprivate|internal|public|open|final|indirect|nonisolated)\s+)*"
    r"(class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)")
_WORD = re.compile(r"\w+")


def declared_type_names(source: str, file_name: str):
    """The names a Swift file offers for matching tests against, sorted.

    Top-level and one-level-nested `class`, `struct`, `enum`, `protocol` and
    `actor` declarations, and the type an `extension` extends (a dotted
    `A.B` gives both `A` and `B`), read from the source with comments and
    strings masked. An extension of a standard or system type (see
    IGNORED_EXTENSIONS) says nothing and is left out. The file's base name
    (`ReaderViewModel+WhereAmI.swift`, split at `+`) is added as well.
    """
    names = set()
    for line in difflint.mask_swift(source).code:
        match = _TYPE_DECLARATION.match(line)
        if not match:
            continue
        keyword, dotted = match.groups()
        parts = dotted.split(".")
        if parts[0] in _NOT_A_TYPE_NAME or (keyword == "extension" and parts[0] in IGNORED_EXTENSIONS):
            continue
        names.update((parts[0], parts[-1]))
    stem = file_name.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    names.update(part for part in stem.split("+")
                 if _WORD.fullmatch(part) and part not in IGNORED_EXTENSIONS)
    return sorted(names)


def file_words(text: str):
    """How often each identifier-like word occurs in a text (what `\\bName\\b` can match)."""
    return Counter(_WORD.findall(text))


def score_test_classes(changed_names, changed_test_paths, classes, words_by_path):
    """Scores each runnable hosted class by how many changed type names its file mentions.

    changed_names:      set of declared type names of all changed app files.
    changed_test_paths: paths (relative to the root) of changed test files.
    classes:            {name: HostedClass}.
    words_by_path:      {test file path: Counter of its words}, for every test file.
    Returns (ranked, dropped, matches): ranked is [(score, class name)] with
    the highest score first. Equal scores are told apart, since one file often
    holds several classes: a class whose own name contains a matched type name
    comes first (`SleepTimerServiceTests` for `SleepTimerService`), then the
    file with more mentions, then the name. Dropped is the sorted list of names
    left out because more than COMMON_NAME_LIMIT test files mention them;
    matches maps a class name to the sorted names it matched.
    """
    mention_counts = {name: sum(name in words for words in words_by_path.values())
                      for name in changed_names}
    dropped = sorted(name for name, count in mention_counts.items() if count > COMMON_NAME_LIMIT)
    useful = set(changed_names) - set(dropped)
    keyed, matches = [], {}
    for name, hosted in classes.items():
        if not hosted.runnable:
            continue
        words = words_by_path.get(hosted.path, Counter())
        found = sorted(useful.intersection(words))
        matches[name] = found
        if hosted.path in changed_test_paths:
            keyed.append((CHANGED_TEST_SCORE, 0, 0, name))
        elif found:
            named = any(match in name for match in found)
            keyed.append((len(found), int(named), sum(words[match] for match in found), name))
    keyed.sort(key=lambda key: (-key[0], -key[1], -key[2], key[3]))
    return [(key[0], key[3]) for key in keyed], dropped, matches


def changed_files(base: str, root: Path):
    """The files changed since the merge-base of `base` and HEAD, as {path: text or None}.

    Tracked changes (staged, unstaged and committed) and untracked files under
    TextMouth/, TextMouthProductionTests/ and TestData/. A deleted file is read
    from the merge-base, so the types it declared still count; a file that
    cannot be read as text maps to None. Raises difflint.GitError.
    """
    scopes = ["--", CHANGED_APP, CHANGED_TESTS, CHANGED_DATA]
    merge_base = difflint.run_git(["merge-base", base, "HEAD"], cwd=str(root)).strip()
    tracked = difflint.run_git(["diff", "--name-only", "--no-color", merge_base] + scopes, cwd=str(root))
    untracked = difflint.run_git(["ls-files", "--others", "--exclude-standard"] + scopes, cwd=str(root))
    paths = sorted(set(filter(None, tracked.split("\n"))) | set(filter(None, untracked.split("\n"))))
    result = {}
    for path in paths:
        try:
            result[path] = (root / path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            # Gone from the working tree: take the merge-base's copy if it had one.
            try:
                result[path] = difflint.run_git(["show", f"{merge_base}:{path}"], cwd=str(root))
            except difflint.GitError:
                result[path] = None
    return result


def names_of_changes(changes):
    """Splits {path: text} into (the names to look for, the changed test file paths).

    An app file contributes its declared type names. A TestData file
    contributes its base name (`Sample.epub` gives `Sample`), which a test that
    loads it usually spells out.
    """
    names, test_paths = set(), set()
    for path, text in changes.items():
        if path.startswith(CHANGED_TESTS) and path.endswith(".swift"):
            test_paths.add(path)
        elif path.startswith(CHANGED_APP) and path.endswith(".swift") and text is not None:
            names.update(declared_type_names(text, path))
        elif path.startswith(CHANGED_DATA):
            stem = path.rsplit("/", 1)[-1].split(".", 1)[0]
            if _WORD.fullmatch(stem):
                names.add(stem)
    return names, test_paths


def test_file_words(root: Path):
    """{path: words} for every Swift file of the hosted test folder."""
    return {str(source.relative_to(root)): file_words(source.read_text(encoding="utf-8", errors="replace"))
            for source in sorted((root / testkit.TESTS_FOLDER).glob("*.swift"))}


def changed_report(ranked, dropped, matches, areas, explain=False, limit=None):
    """The lines --changed prints, and the class names it selected.

    `ranked` is from score_test_classes. With `limit`, only the first N classes
    are kept. Areas come from areas.conf; a class in no area counts as
    `unassigned`.
    """
    if limit is not None:
        ranked = ranked[:limit]
    if not ranked:
        return ["no hosted test class mentions the changed code"], []
    areas_of = {}
    for area in areas:
        for cls in area.classes:
            areas_of.setdefault(cls, []).append(area.name)
    lines, seen_areas = [], []
    for score, name in ranked:
        lines.append(f"{score}  {name}")
        if explain:
            lines.append("    declared in a changed test file" if score == CHANGED_TEST_SCORE
                         else "    mentions " + ", ".join(matches[name][:MAX_EXPLAINED]))
        for area in areas_of.get(name, ["unassigned"]):
            if area not in seen_areas:
                seen_areas.append(area)
    count = len(ranked)
    lines.append(f"{count} class{'es' if count != 1 else ''}; areas: {', '.join(seen_areas)}")
    if dropped:
        lines.append(f"dropped {len(dropped)} name{'s' if len(dropped) != 1 else ''} "
                     f"mentioned by more than {COMMON_NAME_LIMIT} test files")
    lines.append('Heuristic: a test that mentions no changed type is not listed; '
                 'run the area or "all" before a merge.')
    return lines, [name for _score, name in ranked]


def select_changed(root: Path, base, areas, classes, explain=False, limit=None):
    """Runs the whole --changed analysis on the repository: (report lines, class names)."""
    changes = changed_files(base, root)
    if not changes:
        return [f"no changed files under {CHANGED_APP}, {CHANGED_TESTS} or {CHANGED_DATA} "
                f"since {base}", "no hosted test class mentions the changed code"], []
    names, test_paths = names_of_changes(changes)
    ranked, dropped, matches = score_test_classes(names, test_paths, classes, test_file_words(root))
    return changed_report(ranked, dropped, matches, areas, explain, limit)


# ---------------------------------------------------------------------------
# --repeat: one build, N test runs, and what differed between them
# ---------------------------------------------------------------------------

# The least and most runs --repeat accepts: one run answers nothing about
# flakiness, and more than twenty only costs test-host launches.
REPEAT_MIN, REPEAT_MAX = 2, 20
# Where the flaky report comes from (called as a program, not copied).
TEST_LOGS_SCRIPT = Path(__file__).resolve().parent / "test-logs.py"


def run_log_path(log_path: str, number: int) -> str:
    """The log of run `number` (1-based): the main log's path plus `.<number>`."""
    return f"{log_path}.{number}"


def repeat_plan(root: Path, classes, derived_data: str, jobs: int, count: int, log_path: str,
                env_vars, use_slot: bool = True):
    """The command of a --repeat run, and its steps as shell-quoted lines.

    One build-for-testing, then `count` test-without-building runs, each to
    its own log, all inside ONE `/bin/sh -c` so the build slot (taken by the
    wrapper around that one command) is held from the build to the last run
    and no other agent's build is starved in between. A failing test run does
    not stop the next one; a failing build stops everything. The TEST_RUNNER_
    variables go to the test runs only. Returns (argv, [(label, line)]).
    """
    def argv(action):
        return testkit.build_command(root, classes, derived_data, jobs=jobs, use_slot=False, action=action)

    steps = [("build", testkit.shell_line(argv("build-for-testing"), {}))]
    for number in range(1, count + 1):
        line = testkit.shell_line(argv("test-without-building"), env_vars)
        steps.append((f"run {number}", f"{line} > {shlex.quote(run_log_path(log_path, number))} 2>&1"))
    script = f"{steps[0][1]} && {{ {'; '.join(line for _label, line in steps[1:])}; }}"
    command = ([str(root / testkit.SLOT_WRAPPER)] if use_slot else []) + ["/bin/sh", "-c", script]
    return command, steps


def flaky_lines(log_paths, count: int):
    """The `test-logs.py flaky` report over the run logs, as plain lines.

    When no test varied, the report's "no flaky test found" line becomes
    "no test changed outcome in N runs". Fewer than two readable logs cannot
    be compared. Returns a list of lines.
    """
    present = [path for path in log_paths if os.path.exists(path)]
    if len(present) < 2:
        return ["not enough run logs to compare"]
    done = subprocess.run([sys.executable, str(TEST_LOGS_SCRIPT), "flaky"] + present,
                          capture_output=True, text=True, errors="replace")
    if done.returncode != 0:
        return [f"could not compare the runs: {(done.stderr or done.stdout).strip()}"]
    return [f"no test changed outcome in {count} runs" if line == "no flaky test found" else line
            for line in done.stdout.splitlines()]


def repeat_report(root: Path, log_path: str, count: int, elapsed: float, status: int):
    """Reads the main log and the run logs. Returns (lines, exit status).

    Per run: the summary's lines, each starting `run N:`. Then the flaky
    report, the time, and `PASSED in all N runs` or `FAILED in K of N runs`.
    When no run log exists the build failed, and the main log's summary
    (compile errors and all) is printed instead.
    """
    run_logs = [run_log_path(log_path, number) for number in range(1, count + 1)]
    if not any(os.path.exists(path) for path in run_logs):
        lines = testkit.format_summary(summarize_file(log_path, root, elapsed=elapsed, status=status or 1))
        return ["the build did not finish, so no test ran"] + lines, 1
    lines, failed = [], 0
    for number, path in enumerate(run_logs, 1):
        if not os.path.exists(path):
            lines.append(f"run {number}: no log; the run did not start")
            failed += 1
            continue
        summary = summarize_file(path, root)
        failed += 0 if summary.passed else 1
        lines += [f"run {number}: {line}" for line in testkit.format_summary(summary)]
    lines += flaky_lines(run_logs, count)
    lines.append(f"build and runs took {testkit.format_elapsed(elapsed)}; main log {log_path}")
    lines.append(f"PASSED in all {count} runs" if not failed else f"FAILED in {failed} of {count} runs")
    return lines, 0 if not failed else 1


# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

_FAKE_ROOT = Path("/work/TextMouth")

# Canned xcodebuild logs for the self-test.
_LOG_PASS = """\
[build-slot] acquired slot1 at 10:00:00
Test Case '-[TextMouthProductionTests.CountWordingTests testOne]' passed (0.001 seconds).
Test Suite 'CountWordingTests' passed at 2026-10-16 10:00:01.000.
\t Executed 9 tests, with 0 failures (0 unexpected) in 0.020 (0.021) seconds
Test Suite 'Selected tests' passed at 2026-10-16 10:00:02.000.
\t Executed 13 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.5 (0.6) seconds

** TEST SUCCEEDED **
"""
_LOG_TWO_EXECUTED = _LOG_PASS
_LOG_TEST_FAILURE = """\
/work/TextMouth/TextMouthProductionTests/FooTests.swift:123: error: -[TextMouthProductionTests.FooTests testBar] : XCTAssertEqual failed: ("1") is not equal to ("2")
second line of the message
Test Case '-[TextMouthProductionTests.FooTests testBar]' failed (0.1 seconds).
Test Case '-[TextMouthProductionTests.FooTests testOk]' passed (0.1 seconds).
\t Executed 2 tests, with 1 failure (1 unexpected) in 0.2 (0.2) seconds

** TEST FAILED **
"""
_LOG_COMPILE_ERROR = """\
/work/TextMouth/TextMouth/Model/Thing.swift:12:5: error: cannot find 'x' in scope
/work/TextMouth/TextMouth/Model/Thing.swift:12:5: error: cannot find 'x' in scope

** TEST FAILED **
"""
_LOG_WARNING = _LOG_PASS + """\
/work/TextMouth/TextMouth/Model/Thing.swift:7:9: warning: variable 'y' was never mutated
/work/TextMouth/TextMouth/Model/Thing.swift:7:9: warning: variable 'y' was never mutated
/Users/x/Library/Developer/Xcode/DerivedData/TextMouth-abc/SourcePackages/checkouts/Pkg/P.swift:3:1: warning: not ours
"""
_LOG_CRASH = """\
Test Case '-[TextMouthProductionTests.BoomTests testBoom]' started.
Restarting after unexpected exit, crash, or test timeout in BoomTests/testBoom(); summary will include totals from previous launches.
** TEST FAILED **
"""
# The build wrapper's board messages (bbs.py's describe_message) in a log that
# crashed nowhere: one whose topic says the test host crashed, one whose body
# does, an error and an Executed line in a body, then a clean run.
_LOG_BOARD_CRASH_TALK = """\
[build-slot] unread board messages for worker (still unread; read them with bbs.py inbox worker --unread):
#2491 finding from oggtoaac to all, 10:02:11 17 Oct: Test host crashed 9x in the Ogg tests
  Files: TextMouth/Services/Foo.swift
  The test host crashed again; error: boom
  Executed 99 tests, with 99 failures (0 unexpected)

#2492 notice from lead to worker, 10:03:00 17 Oct: restart after a crash
  Restarting after unexpected exit, crash, or test timeout in X
[build-slot] acquired slot1 at 10:04:00
""" + _LOG_PASS


def selftest() -> int:
    """Checks areas.conf, the inventory, the command and the log reader. Builds nothing."""
    failures = []
    count = [0]

    def check(name, condition, detail=""):
        """Counts one check and records it when it fails."""
        count[0] += 1
        if not condition:
            failures.append(f"selftest FAILED: {name}{': ' + str(detail) if detail else ''}")

    root = testkit.repo_root()

    # areas.conf parses; every class exists and is runnable; no area is empty.
    classes = testkit.hosted_test_classes(root)
    check("the inventory finds hosted classes", len(classes) > 100, len(classes))
    try:
        areas = testkit.parse_areas(root / testkit.AREAS_CONF)
    except (OSError, testkit.AreasError) as error:
        areas = []
        check("areas.conf parses", False, error)
    check("areas.conf has areas", bool(areas))
    for area in areas:
        check(f"area {area.name} is not empty", bool(area.classes))
        for name in area.classes:
            check(f"{area.name}: {name} exists and has tests",
                  name in classes and classes[name].runnable)

    # A bad areas file names the line.
    with tempfile.TemporaryDirectory() as folder:
        bad = Path(folder) / "bad.conf"
        bad.write_text("[ok] fine\nAThing\nAThing\n")
        try:
            testkit.parse_areas(bad)
            check("a class twice in one area is an error", False)
        except testkit.AreasError as error:
            check("a duplicate class names its line", ":3:" in str(error), error)
        bad.write_text("[Bad_Name] x\n")
        try:
            testkit.parse_areas(bad)
            check("a bad area name is an error", False)
        except testkit.AreasError as error:
            check("a bad area name names its line", ":1:" in str(error), error)

    # Names resolve: areas, classes, order, repeats, unknowns.
    sample = [testkit.Area("one", "d", ("A", "B")), testkit.Area("two", "d", ("B", "C"))]
    fake = {n: testkit.HostedClass(n, "x.swift", 1, 1) for n in "ABCD"}
    check("areas resolve in order without repeats",
          testkit.resolve_names(["one", "two", "D", "A"], sample, fake) == ["A", "B", "C", "D"])
    check("all is every listed class, then every unlisted one",
          testkit.resolve_names(["all"], sample, fake) == ["A", "B", "C", "D"])
    try:
        testkit.resolve_names(["tw"], sample, fake)
        check("an unknown name raises", False)
    except testkit.UnknownName as error:
        check("an unknown name offers the closest", "no area or class named 'tw'; closest: two" in str(error), error)

    # The command.
    command = testkit.build_command(Path("/r"), ["A", "B"], "/tmp/D", jobs=3, use_slot=False)
    check("build_command is the documented argv", command == [
        "xcodebuild", "test", "-project", "TextMouth.xcodeproj", "-scheme", "TextMouth",
        "-destination", "platform=macOS", "-parallel-testing-enabled", "NO", "-jobs", "3",
        "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "-derivedDataPath", "/tmp/D",
        "-only-testing:TextMouthProductionTests/A", "-only-testing:TextMouthProductionTests/B"], command)
    extra = testkit.build_command(Path("/r"), ["A"], "/tmp/D", use_slot=False, extra=["-test-timeouts-enabled", "YES"])
    check("extra arguments go before the classes", extra[-3:] == ["-test-timeouts-enabled", "YES", "-only-testing:TextMouthProductionTests/A"],
          extra[-3:])
    slotted = testkit.build_command(Path("/r"), ["A"], "/tmp/D")
    check("the wrapper goes first", slotted[0] == "/r/" + testkit.SLOT_WRAPPER and slotted[1] == "xcodebuild", slotted[:2])

    # The log reader.
    def summary(text):
        return testkit.summarize_log(text, _FAKE_ROOT)

    passed = summary(_LOG_PASS)
    check("a pass is PASSED", passed.passed)
    check("a pass prints the last Executed line, as printed",
          testkit.format_summary(passed)[0] == "Executed 13 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.5 (0.6) seconds",
          testkit.format_summary(passed))
    check("a pass ends with PASSED", testkit.format_summary(passed)[-1] == "PASSED")
    check("two Executed lines: the last wins", summary(_LOG_TWO_EXECUTED).executed == 13)

    failed = testkit.format_summary(summary(_LOG_TEST_FAILURE))
    check("a test failure names the test, file, line and first message line",
          "FAILED FooTests.testBar at FooTests.swift:123: XCTAssertEqual failed: (\"1\") is not equal to (\"2\")" in failed, failed)
    check("a test failure ends with FAILED", failed[-1] == "FAILED", failed)
    check("a test failure prints its Executed line first",
          failed[0] == "Executed 2 tests, with 1 failure (1 unexpected) in 0.2 (0.2) seconds", failed)

    compiled = testkit.format_summary(summary(_LOG_COMPILE_ERROR))
    check("a compile error is listed once", compiled.count("ERROR Thing.swift:12: cannot find 'x' in scope") == 1, compiled)
    check("a compile error prints no tests ran", compiled[0] == "no tests ran" and compiled[-1] == "FAILED", compiled)
    many = "\n".join(f"/work/TextMouth/A.swift:{n}:1: error: e{n}" for n in range(1, 26))
    listed = testkit.format_summary(summary(many))
    check("errors are capped at 20 then 'and N more'",
          sum(l.startswith("ERROR ") for l in listed) == 20 and "and 5 more" in listed, listed)

    # A printed NSError that two processes' interleaved output cut at the front ("... proxy " lost, "error: Error
    # Domain=..." left at the start of a line) is no compile error: it failed a clean run of 11,849 tests (November 10).
    noise = summary(_LOG_PASS + "error: Error Domain=NSCocoaErrorDomain Code=4099 \"The connection ... was invalidated\"\n")
    check("an NSError cut at the front is no error", not noise.errors and noise.passed, noise.errors)
    real = summary(_LOG_PASS + "error: Unable to find a destination\n")
    check("a bare error line is still an error", bool(real.errors), real.errors)

    warned = testkit.format_summary(summary(_LOG_WARNING))
    check("a repository warning is listed once, a package's not",
          warned.count("WARNING Thing.swift:7: variable 'y' was never mutated") == 1
          and not any("not ours" in l for l in warned), warned)
    check("a warning does not fail the run", warned[-1] == "PASSED", warned)

    crashed = testkit.format_summary(summary(_LOG_CRASH))
    check("a crash with no Executed line says so", crashed[0] == "no tests ran"
          and any(l.startswith("CRASH ") for l in crashed) and crashed[-1] == "FAILED", crashed)

    # A board message the wrapper copied into the log, however it speaks of
    # crashes, errors, or results, is not xcodebuild's own output.
    talked = summary(_LOG_BOARD_CRASH_TALK)
    check("a board message about a crash is no CRASH", talked.crash is None, talked.crash)
    check("a board message's error and Executed lines are not read", not talked.errors and talked.executed == 13, talked)
    check("a log with board talk of crashes still passes", talked.passed
          and not any(l.startswith("CRASH ") for l in testkit.format_summary(talked)))
    after_board = summary(_LOG_BOARD_CRASH_TALK + _LOG_CRASH)
    check("a real crash after board messages is still found",
          after_board.crash is not None and after_board.crash.startswith("Restarting after unexpected exit"), after_board.crash)

    stamped = testkit.format_summary(replace(passed, log_path="/tmp/x.log", elapsed=312.4))
    check("the log path and elapsed time print", stamped[-2:] == ["log: /tmp/x.log", "PASSED in 5 minutes 12 seconds"], stamped)
    check("a test-without-building run passes on TEST EXECUTE SUCCEEDED",
          summary(_LOG_PASS.replace("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **")).passed)
    check("zero tests do not pass", not summary("Executed 0 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **").passed)

    # --clean refuses a folder not named for a build, ignores a missing one,
    # and deletes a real one.
    with tempfile.TemporaryDirectory() as folder:
        stray = Path(folder) / "stray"
        stray.mkdir()
        with open(os.devnull, "w") as quiet:
            real_stderr, real_stdout = sys.stderr, sys.stdout
            sys.stderr = sys.stdout = quiet
            try:
                refused = clean(str(stray))
                missing = clean(str(Path(folder) / f"{DERIVED_DATA_MARK}-none"))
                build = Path(folder) / f"{DERIVED_DATA_MARK}-x"
                (build / "Build").mkdir(parents=True)
                removed = clean(str(build))
            finally:
                sys.stderr, sys.stdout = real_stderr, real_stdout
        check("--clean refuses a folder not named for a build", refused == 2 and stray.exists())
        check("--clean treats a missing folder as fine", missing == 0)
        check("--clean deletes a build folder", removed == 0 and not build.exists())

    # --changed: type names are read from code, not from comments or strings.
    canned = '''\
// class InComment {}
/* struct InBlock {} */
import Foundation

let text = "enum InString {"

@MainActor final class Alpha: Base {
    struct Nested {}
    class func make() {}
    enum Deep {
        struct TooDeep {}
    }
}
private struct Beta {}
protocol Gamma {}
actor Delta {}
extension Alpha {}
extension String {}
extension Notification.Name {}
extension LogWriter.Environment {}
public indirect enum Epsilon {}
'''
    found = declared_type_names(canned, "TextMouth/Models/Alpha.swift")
    check("type names: classes, structs, enums, protocols, actors, extensions",
          {"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Nested", "Deep", "LogWriter", "Environment"} <= set(found), found)
    check("type names: comments and strings are ignored",
          not {"InComment", "InBlock", "InString"} & set(found), found)
    check("type names: a type nested two levels is not listed", "TooDeep" not in found, found)
    check("type names: `class func` is not a type", "make" not in found and "func" not in found, found)
    check("type names: an extension of a standard type is ignored",
          not {"String", "Notification", "Name"} & set(found), found)
    plus = declared_type_names("extension ReaderViewModel {}\n", "TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift")
    check("type names: a + file name adds its feature part", plus == ["ReaderViewModel", "WhereAmI"], plus)
    check("type names: a plain file name is added when undeclared",
          declared_type_names("let x = 1\n", "TextMouth/App/Helpers.swift") == ["Helpers"])
    check("type names: String+Extras does not add String",
          declared_type_names("extension String {}\n", "String+Extras.swift") == ["Extras"])

    # --changed: scoring, order, limits and the report.
    hosted = {name: testkit.HostedClass(name, f"T/{name}.swift", 1, 1)
              for name in ("OneTests", "TwoTests", "WidgetTests", "NoneTests")}
    hosted["Helper"] = testkit.HostedClass("Helper", "T/Helper.swift", 1, 0)
    words = {
        "T/OneTests.swift": file_words("Widget Gadget"),
        "T/TwoTests.swift": file_words("Widget"),
        "T/WidgetTests.swift": file_words("Widget"),
        "T/NoneTests.swift": file_words("Other"),
        "T/Helper.swift": file_words("Widget Gadget"),
    }
    ranked, dropped, matches = score_test_classes({"Widget", "Gadget"}, set(), hosted, words)
    check("scoring: distinct names, highest first, name match breaks ties, helpers and misses left out",
          ranked == [(2, "OneTests"), (1, "WidgetTests"), (1, "TwoTests")] and not dropped, ranked)
    check("scoring: matches list the names", matches["OneTests"] == ["Gadget", "Widget"], matches)
    ranked, _, _ = score_test_classes({"Gadget"}, {"T/NoneTests.swift"}, hosted, words)
    check("scoring: a class in a changed test file scores 1000 and comes first",
          ranked[0] == (1000, "NoneTests") and ranked[1] == (1, "OneTests"), ranked)
    crowd = {f"T/C{n}.swift": file_words("Common Rare") for n in range(COMMON_NAME_LIMIT + 1)}
    crowd.update(words)
    crowd["T/OneTests.swift"] = file_words("Common Rare")
    ranked, dropped, _ = score_test_classes({"Common", "Rare"}, set(), hosted, crowd)
    check("scoring: a name mentioned by more than the limit is dropped and counted",
          dropped == ["Common", "Rare"] and ranked == [], (dropped, ranked))
    crowd.update({f"T/C{n}.swift": file_words("Common") for n in range(COMMON_NAME_LIMIT + 1)})
    ranked, dropped, _ = score_test_classes({"Common", "Rare"}, set(), hosted, crowd)
    check("scoring: only the common name is dropped", dropped == ["Common"] and ranked == [(1, "OneTests")],
          (dropped, ranked))

    sample_areas = [testkit.Area("first", "d", ("OneTests",)), testkit.Area("second", "d", ("OneTests", "TwoTests"))]
    ranked, dropped, matches = score_test_classes({"Widget", "Gadget"}, set(), hosted, words)
    lines, picked = changed_report(ranked, ["Zed"], matches, sample_areas, explain=True)
    check("report: score and class, then the matched names under --explain",
          lines[:2] == ["2  OneTests", "    mentions Gadget, Widget"], lines)
    check("report: the count line lists areas in areas.conf order, unassigned for a class in none",
          "3 classes; areas: first, second, unassigned" in lines, lines)
    check("report: dropped names and the heuristic line close it",
          lines[-2].startswith("dropped 1 name mentioned by more than ") and lines[-1].startswith("Heuristic: "), lines)
    lines, picked = changed_report(ranked, [], matches, sample_areas, limit=1)
    check("report: --limit keeps the first N", picked == ["OneTests"] and "1 class; areas: first, second" in lines, lines)
    check("report: nothing selected says so",
          changed_report([], [], {}, sample_areas) == (["no hosted test class mentions the changed code"], []))

    # --changed on a real (scratch) git repository: edits, a new file, a deletion, TestData.
    with tempfile.TemporaryDirectory() as folder:
        repo = Path(folder)

        def git(*arguments):
            """Runs git in the scratch repository, quietly."""
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                            "-C", str(repo)] + list(arguments), check=True, capture_output=True)

        git("init", "-q", "-b", "main")
        for path, text in (("TextMouth/Models/Kept.swift", "struct Kept {}\n"),
                           ("TextMouth/Models/Gone.swift", "struct Gone {}\n"),
                           ("TextMouthProductionTests/KeptTests.swift", "// Kept\n"),
                           ("README.md", "x\n")):
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("checkout", "-q", "-b", "work")
        (repo / "TextMouth/Models/Kept.swift").write_text("struct Kept {}\nstruct Added {}\n")
        (repo / "TextMouth/Models/Gone.swift").unlink()
        (repo / "TextMouth/Models/Fresh.swift").write_text("enum Fresh {}\n")
        (repo / "TestData").mkdir()
        (repo / "TestData/Sample.epub").write_text("x")
        (repo / "README.md").write_text("changed\n")
        changes = changed_files("main", repo)
        check("changed files: edits, a deletion (read from the base), untracked and TestData; others left out",
              sorted(changes) == ["TestData/Sample.epub", "TextMouth/Models/Fresh.swift", "TextMouth/Models/Gone.swift",
                                  "TextMouth/Models/Kept.swift"] and changes["TextMouth/Models/Gone.swift"] == "struct Gone {}\n",
              sorted(changes))
        names, test_paths = names_of_changes(changes)
        check("changed names: types of every app file plus a TestData base name",
              {"Kept", "Added", "Gone", "Fresh", "Sample"} <= names and not test_paths, names)
        git("add", "-A")
        git("commit", "-q", "-m", "work")
        check("changed files: committed changes still count since the merge-base",
              len(changed_files("main", repo)) == 4)
        try:
            changed_files("no-such-ref", repo)
            check("changed files: an unknown base raises", False)
        except difflint.GitError:
            check("changed files: an unknown base raises", True)

    # --repeat: the argument check, the command line, the flaky report, the report.
    def run_main(*argv):
        """Runs main() quietly. Returns (exit status, stdout lines, stderr text)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = main(list(argv))
        return status, out.getvalue().splitlines(), err.getvalue()

    for bad in ("1", "0", "21", "-3"):
        status, _lines, problem = run_main("--repeat", bad, "CountWordingTests")
        check(f"--repeat {bad} is refused with status 2", status == 2 and "2 to 20" in problem, (status, problem))
    status, lines, _problem = run_main("--dry-run", "--repeat", "3", "--env", "X=1", "--log", "/tmp/my log", "CountWordingTests")
    check("--dry-run --repeat 3 prints the build step and three test steps",
          status == 0 and [l.split(":")[0] for l in lines] == ["build", "run 1", "run 2", "run 3"], lines)
    check("the build step builds for testing, without the environment",
          "xcodebuild build-for-testing" in lines[0] and "TEST_RUNNER_" not in lines[0], lines[0])
    check("each test step runs without building, with the environment and its own quoted log",
          all("TEST_RUNNER_X=1 xcodebuild test-without-building" in l and l.endswith(f"'/tmp/my log.{n}' 2>&1")
              for n, l in enumerate(lines[1:], 1)), lines)
    command, steps = repeat_plan(Path("/r"), ["A"], "/d", 4, 2, "/l", {}, use_slot=True)
    check("the whole sequence is one command behind the slot wrapper",
          command[0] == "/r/" + testkit.SLOT_WRAPPER and command[1:3] == ["/bin/sh", "-c"] and len(command) == 4, command)
    check("the script builds first, then runs both tests whatever the first gives",
          command[3].startswith("xcodebuild build-for-testing") and " && { xcodebuild test-without-building" in command[3]
          and command[3].count("test-without-building") == 2 and command[3].endswith("; }"), command[3])
    check("--no-slot leaves the wrapper out", repeat_plan(Path("/r"), ["A"], "/d", 4, 2, "/l", {}, use_slot=False)[0][0] == "/bin/sh")

    with tempfile.TemporaryDirectory() as folder:
        base = os.path.join(folder, "area.log")
        steady = _LOG_PASS.replace("[build-slot] acquired slot1 at 10:00:00\n", "")
        shaky = steady.replace("Test Case '-[TextMouthProductionTests.CountWordingTests testOne]' passed",
                               "Test Case '-[TextMouthProductionTests.CountWordingTests testOne]' failed") \
            .replace("with 1 test skipped and 0 failures (0 unexpected)", "with 1 test skipped and 1 failure (1 unexpected)")
        Path(base).write_text("[build-slot] acquired slot1 at 10:00:00\n")
        runs = [os.path.join(folder, f"area.log.{n}") for n in (1, 2, 3)]
        for path in runs:
            Path(path).write_text(steady)
        lines, verdict = repeat_report(_FAKE_ROOT, base, 3, 90, 0)
        check("three steady runs: every run's lines, no change, PASSED in all 3 runs",
              verdict == 0 and "run 1: PASSED" in lines and "run 3: PASSED" in lines
              and "no test changed outcome in 3 runs" in lines and lines[-1] == "PASSED in all 3 runs", lines)
        check("each run prints its Executed line",
              sum(l.startswith("run ") and "Executed 13 tests" in l for l in lines) == 3, lines)
        Path(runs[1]).write_text(shaky)
        lines, verdict = repeat_report(_FAKE_ROOT, base, 3, 90, 0)
        check("one failing run: FAILED in 1 of 3 runs and exit status 1",
              verdict == 1 and lines[-1] == "FAILED in 1 of 3 runs" and "run 2: PASSED" not in lines, lines)
        check("the flaky report names the test whose outcome changed",
              any("CountWordingTests.testOne" in l for l in lines)
              and "no test changed outcome in 3 runs" not in lines, lines)
        os.remove(runs[2])
        lines, verdict = repeat_report(_FAKE_ROOT, base, 3, 90, 0)
        check("a run that never started counts as failed",
              verdict == 1 and "run 3: no log; the run did not start" in lines and lines[-1] == "FAILED in 2 of 3 runs", lines)
        for path in runs:
            if os.path.exists(path):
                os.remove(path)
        Path(base).write_text(_LOG_COMPILE_ERROR)
        lines, verdict = repeat_report(_FAKE_ROOT, base, 3, 90, 65)
        check("with no run log the build failed: its errors and FAILED",
              verdict == 1 and lines[0] == "the build did not finish, so no test ran"
              and "ERROR Thing.swift:12: cannot find 'x' in scope" in lines and lines[-1].startswith("FAILED"), lines)

    if failures:
        print("\n".join(failures))
        return 1
    print(f"selftest: {count[0]} checks, all passed")
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv) -> int:
    """The command line. Returns the exit status."""
    args = parse_args(argv)
    if args.help:
        print(__doc__.strip())
        return 0
    root = testkit.repo_root()
    if args.selftest:
        return selftest()
    if args.summarize:
        try:
            summary = summarize_file(args.summarize, root)
        except OSError as error:
            return usage_error(f"cannot read the log: {error}")
        print_lines(testkit.format_summary(summary))
        return 0 if summary.passed else 1

    derived_data, log_path = default_paths(args)
    if args.clean:
        return clean(derived_data)

    # The area list and the class inventory.
    try:
        areas = testkit.parse_areas(root / testkit.AREAS_CONF)
    except (OSError, testkit.AreasError) as error:
        return usage_error(f"cannot use areas.conf: {error}")
    classes = testkit.hosted_test_classes(root)
    names = list(args.names)
    extra = split_classes(args.classes)

    if args.unassigned:
        print_lines(unassigned_lines(areas, classes))
        return 0
    if args.limit is not None and args.limit < 1:
        return usage_error("--limit wants a number of 1 or more")
    if args.repeat is not None and not REPEAT_MIN <= args.repeat <= REPEAT_MAX:
        return usage_error(f"--repeat wants a number from {REPEAT_MIN} to {REPEAT_MAX}, not {args.repeat}")
    # --changed picks classes from the code a branch changed; its report
    # prints first, and --list stops there.
    changed_picks = []
    if args.changed:
        try:
            report, changed_picks = select_changed(root, args.base, areas, classes, args.explain, args.limit)
        except difflint.GitError as error:
            return usage_error(f"cannot find the changed files: {error}")
        print_lines(report)
        if args.list:
            return 0
    try:
        if args.list:
            print_lines(list_lines(names, areas, classes))
            return 0
        if not names and not extra and not args.changed:
            return usage_error("no area or class named; try --list, or -h for help")
        selected = testkit.resolve_names(names, areas, classes)
        selected = list(dict.fromkeys(changed_picks + selected
                                      + testkit.resolve_names(extra, areas, classes, classes_only=True)))
    except testkit.UnknownName as error:
        return usage_error(str(error))
    if not selected:
        return 0

    env_vars, problem = parse_env(args.env)
    if problem:
        return usage_error(problem)
    if args.repeat:
        command, steps = repeat_plan(root, selected, derived_data, args.jobs, args.repeat, log_path,
                                     env_vars, use_slot=not args.no_slot)
    else:
        command = testkit.build_command(root, selected, derived_data, jobs=args.jobs, use_slot=not args.no_slot,
                                        extra=args.xcodebuild_arg)

    if args.dry_run:
        if args.repeat:
            print_lines(f"{label}: {line}" for label, line in steps)
        else:
            print(testkit.shell_line(command, env_vars))
        return 0
    if shutil.which("xcodebuild") is None:
        return usage_error("xcodebuild was not found; install Xcode's command line tools")
    if not args.no_slot and not os.access(command[0], os.X_OK):
        return usage_error(f"the build-slot wrapper is missing or not executable: {command[0]}")

    area_count = len([n for n in names if testkit.area_classes(areas, n) is not None])
    what = f"{area_count} area{'s' if area_count != 1 else ''}, " if area_count else ""
    times = f", {args.repeat} times" if args.repeat else ""
    print(f"running {what}{len(selected)} class{'es' if len(selected) != 1 else ''}{times}; "
          f"build folder {derived_data}; log {log_path}")
    sys.stdout.flush()

    # The test host sees each --env variable with the TEST_RUNNER_ prefix.
    # (A --repeat run carries them on its test steps only, so the build never sees them.)
    child_env = dict(os.environ)
    if not args.repeat:
        child_env.update({f"{testkit.ENV_PREFIX}{k}": v for k, v in env_vars.items()})
    started = time.monotonic()
    if args.repeat:
        # A run log left by an earlier --repeat must not pass for this one's.
        for number in range(1, args.repeat + 1):
            Path(run_log_path(log_path, number)).unlink(missing_ok=True)
    try:
        status = run_child(command, child_env, root, log_path)
    except KeyboardInterrupt:
        print(f"interrupted; the log so far is at {log_path}")
        return 130
    except OSError as error:
        return usage_error(f"could not start the build: {error}")
    if args.repeat:
        lines, verdict = repeat_report(root, log_path, args.repeat, time.monotonic() - started, status)
        print_lines(lines)
        return verdict
    summary = summarize_file(log_path, root, elapsed=time.monotonic() - started, status=status)
    print_lines(testkit.format_summary(summary))
    return 0 if summary.passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
