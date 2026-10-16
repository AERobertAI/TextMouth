#!/usr/bin/env python3
"""run-area.py: runs the hosted tests of one or more areas, and prints a short result.

Usage: Scripts/test/run-area.py [options] NAME [NAME ...]

A NAME is an area (listed in Scripts/test/areas.conf) or a test class. `all`
is a built-in area: every class any area lists. Order is kept, repeats are
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
                      description); with NAMEs: their classes, one per line
  --classes A,B       more classes, comma separated (repeatable)
  --dry-run           print the command (one shell-quoted line) and exit 0
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
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path

# Importing testkit must not leave a __pycache__ folder in the repository
# (git does not ignore it), so write no bytecode, as trap-lint.py does.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import testkit  # noqa: E402  (the path above must be set first)

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
    parser.add_argument("--no-slot", action="store_true")
    parser.add_argument("--clean", action="store_true")
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
        everything = testkit.area_classes(areas, testkit.ALL_AREA)
        lines = [f"{a.name}: {len(a.classes)} classes. {a.description}" for a in areas]
        lines.append(f"{testkit.ALL_AREA}: {len(everything)} classes. Every class any area lists")
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
    check("all is every listed class", testkit.resolve_names(["all"], sample, fake) == ["A", "B", "C"])
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

    warned = testkit.format_summary(summary(_LOG_WARNING))
    check("a repository warning is listed once, a package's not",
          warned.count("WARNING Thing.swift:7: variable 'y' was never mutated") == 1
          and not any("not ours" in l for l in warned), warned)
    check("a warning does not fail the run", warned[-1] == "PASSED", warned)

    crashed = testkit.format_summary(summary(_LOG_CRASH))
    check("a crash with no Executed line says so", crashed[0] == "no tests ran"
          and any(l.startswith("CRASH ") for l in crashed) and crashed[-1] == "FAILED", crashed)

    stamped = testkit.format_summary(replace(passed, log_path="/tmp/x.log", elapsed=312.4))
    check("the log path and elapsed time print", stamped[-2:] == ["log: /tmp/x.log", "PASSED in 5 minutes 12 seconds"], stamped)
    check("zero tests do not pass", not summary("Executed 0 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **").passed)

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
    try:
        if args.list:
            print_lines(list_lines(names, areas, classes))
            return 0
        if not names and not extra:
            return usage_error("no area or class named; try --list, or -h for help")
        selected = testkit.resolve_names(names, areas, classes)
        selected = list(dict.fromkeys(selected + testkit.resolve_names(extra, areas, classes, classes_only=True)))
    except testkit.UnknownName as error:
        return usage_error(str(error))

    env_vars, problem = parse_env(args.env)
    if problem:
        return usage_error(problem)
    command = testkit.build_command(root, selected, derived_data, jobs=args.jobs, use_slot=not args.no_slot)

    if args.dry_run:
        print(testkit.shell_line(command, env_vars))
        return 0
    if shutil.which("xcodebuild") is None:
        return usage_error("xcodebuild was not found; install Xcode's command line tools")
    if not args.no_slot and not os.access(command[0], os.X_OK):
        return usage_error(f"the build-slot wrapper is missing or not executable: {command[0]}")

    area_count = len([n for n in names if testkit.area_classes(areas, n) is not None])
    what = f"{area_count} area{'s' if area_count != 1 else ''}, " if area_count else ""
    print(f"running {what}{len(selected)} class{'es' if len(selected) != 1 else ''}; "
          f"build folder {derived_data}; log {log_path}")
    sys.stdout.flush()

    # The test host sees each --env variable with the TEST_RUNNER_ prefix.
    child_env = dict(os.environ)
    child_env.update({f"{testkit.ENV_PREFIX}{k}": v for k, v in env_vars.items()})
    started = time.monotonic()
    try:
        status = run_child(command, child_env, root, log_path)
    except KeyboardInterrupt:
        print(f"interrupted; the log so far is at {log_path}")
        return 130
    except OSError as error:
        return usage_error(f"could not start the build: {error}")
    summary = summarize_file(log_path, root, elapsed=time.monotonic() - started, status=status)
    print_lines(testkit.format_summary(summary))
    return 0 if summary.passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
