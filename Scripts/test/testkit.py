"""testkit.py: the shared module of the test kit's scripts.

A script in this folder does `import testkit`. It holds what every area script
needs, and nothing that builds:

  * the inventory of the hosted test classes (hosted_test_classes);
  * the area list (parse_areas, Area) and the resolution of names to classes
    (resolve_names);
  * the xcodebuild command (build_command);
  * the reading of an xcodebuild log (summarize_log, format_summary).

Python 3 standard library only. Output is plain words, one fact per line, for
a reader on VoiceOver and a braille display: no box drawing, no emoji, no
colors, no progress bars.
"""

import difflib
import os
import re
import shlex
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

# The folder of hosted test sources, the project and scheme, and the wrapper
# that holds one of the machine's three build slots (all relative to the root).
TESTS_FOLDER = "TextMouthProductionTests"
TEST_TARGET = "TextMouthProductionTests"
PROJECT = "TextMouth.xcodeproj"
SCHEME = "TextMouth"
SLOT_WRAPPER = ".claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh"
AREAS_CONF = "Scripts/test/areas.conf"

# The prefix that carries an environment variable into the test host.
ENV_PREFIX = "TEST_RUNNER_"

# The built-in area that holds every runnable hosted test class: the classes
# the areas list, in their order, then the ones no area lists yet.
ALL_AREA = "all"

# How many compile errors the summary lists before "and N more".
MAX_ERRORS_SHOWN = 20


def repo_root() -> Path:
    """The repository root: the folder above Scripts/, found from this file."""
    return Path(__file__).resolve().parent.parent.parent


# ---------------------------------------------------------------------------
# The inventory of hosted test classes
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class HostedClass:
    """One class of the hosted test target.

    path is the file (relative to the root) and line the 1-based line of the
    class's own declaration. test_count is the number of tests the class runs:
    its own `func test...()` members, those of its `extension` blocks anywhere
    in the folder, and those it inherits from a base class declared there.
    A class with test_count == 0 is a helper and is not runnable.
    """
    name: str
    path: str
    line: int
    test_count: int

    @property
    def runnable(self) -> bool:
        return self.test_count > 0


# A top-level declaration starts in column 0, with any modifiers before the
# keyword: `final class X: Y {`, `private final class X {`, `extension X {`.
# The name may be dotted (`extension LogWriter.Environment`). The text after
# the name up to `{` is kept so a class's superclass can be read.
_DECLARATION = re.compile(
    r"^(?:(?:private|fileprivate|internal|public|open|final)\s+)*"
    r"(class|extension|struct|enum|actor|protocol)\s+([A-Za-z_][\w.]*)(.*)$")
# A test: a method indented exactly one level (4 spaces) with no parameters.
_TEST_METHOD = re.compile(
    r"^    (?:@\w+\s+)*(?:(?:private|fileprivate|override)\s+)*"
    r"func\s+test\w*\s*\(\s*\)")


def hosted_test_classes(root: Path) -> Dict[str, HostedClass]:
    """Scans TextMouthProductionTests/*.swift and returns {class name: HostedClass}.

    This is a line scanner, not a Swift parser, and it has limits:
      * a scope opens at a column-0 `class`/`extension` line and closes at the
        next column-0 declaration or column-0 `}`; test methods must be
        indented exactly 4 spaces (as everywhere in this repository);
      * a test is `func test...()` with no parameters, as XCTest requires;
        a method hidden in a `#if` is counted as if it were compiled;
      * the superclass is the first word after the colon on the declaration
        line, and only a base class declared in the folder passes tests down;
      * a class of the same name in two files (a private helper twice) keeps
        its first declaration and adds up the tests of all.
    Tests added by `extension XCTestCase` are not attributed to any class.
    """
    declared: Dict[str, Tuple[str, int, Optional[str]]] = {}  # name -> path, line, superclass
    own_tests: Dict[str, int] = {}
    folder = root / TESTS_FOLDER
    for source in sorted(folder.glob("*.swift")):
        relative = str(source.relative_to(root))
        current: Optional[str] = None
        for number, text in enumerate(source.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if text.startswith("}"):
                current = None
                continue
            # Blank, indented, comment, attribute and compiler-directive lines
            # never start or end a scope; any other column-0 line does.
            if text[:1] not in ("", " ", "\t", "/", "@", "#"):
                match = _DECLARATION.match(text)
                if match:
                    kind, name, rest = match.groups()
                    # Only classes and extensions can hold tests; a struct or
                    # enum closes the scope of the declaration before it.
                    current = name if kind in ("class", "extension") else None
                    if kind == "class" and name not in declared:
                        superclass = re.match(r"\s*:\s*([A-Za-z_][\w.]*)", rest)
                        declared[name] = (relative, number, superclass.group(1) if superclass else None)
                else:
                    current = None
                continue
            if current and _TEST_METHOD.match(text):
                own_tests[current] = own_tests.get(current, 0) + 1

    def total(name: str, seen: Tuple[str, ...] = ()) -> int:
        """Own tests plus those inherited from a base class declared here."""
        count = own_tests.get(name, 0)
        parent = declared[name][2] if name in declared else None
        if parent and parent in declared and parent not in seen + (name,):
            count += total(parent, seen + (name,))
        return count

    return {name: HostedClass(name, path, line, total(name))
            for name, (path, line, _super) in declared.items()}


# ---------------------------------------------------------------------------
# The area list
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Area:
    """A named group of test classes, in the order areas.conf lists them."""
    name: str
    description: str
    classes: Tuple[str, ...]


class AreasError(ValueError):
    """A problem in areas.conf; the message names the file and line."""


_AREA_NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_AREA_HEADER = re.compile(r"^\[([^\]]*)\]\s*(.*)$")
_CLASS_NAME = re.compile(r"^[A-Za-z_]\w*$")


def parse_areas(path) -> List[Area]:
    """Reads areas.conf into an ordered list of Area.

    Format: `#` starts a comment (a whole line, or after a name); `[name] one-line
    description` starts an area (name: lowercase letters, digits and hyphens);
    every other non-blank line is one test class name belonging to the last
    area. A class may be listed in two areas, but not twice in one. A malformed
    line raises AreasError naming the line number.
    """
    areas: List[Tuple[str, str, List[str]]] = []
    for number, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        where = f"{path}:{number}"
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        header = _AREA_HEADER.match(text)
        if header:
            name, description = header.group(1), header.group(2).strip()
            if not _AREA_NAME.match(name):
                raise AreasError(f"{where}: bad area name '{name}' (lowercase letters, digits and hyphens)")
            if name == ALL_AREA:
                raise AreasError(f"{where}: 'all' is built in and cannot be an area")
            if any(existing[0] == name for existing in areas):
                raise AreasError(f"{where}: area '{name}' is listed twice")
            if not description:
                raise AreasError(f"{where}: area '{name}' has no description")
            areas.append((name, description, []))
            continue
        # A class line: a name, optionally followed by a # comment.
        name = text.split("#", 1)[0].strip()
        if not _CLASS_NAME.match(name):
            raise AreasError(f"{where}: not a class name or an area header: '{text}'")
        if not areas:
            raise AreasError(f"{where}: class '{name}' comes before any [area] line")
        if name in areas[-1][2]:
            raise AreasError(f"{where}: class '{name}' is listed twice in area '{areas[-1][0]}'")
        areas[-1][2].append(name)
    return [Area(name, description, tuple(classes)) for name, description, classes in areas]


class UnknownName(LookupError):
    """A NAME that is neither an area nor a runnable class; carries a ready message."""


def _dedupe(items: Sequence[str]) -> List[str]:
    """Drops repeats and keeps the first occurrence's order."""
    return list(dict.fromkeys(items))


def area_classes(areas: Sequence[Area], name: str) -> Optional[List[str]]:
    """The classes of the area `name` (the built-in `all` included), or None."""
    if name == ALL_AREA:
        return _dedupe([c for area in areas for c in area.classes])
    for area in areas:
        if area.name == name:
            return list(area.classes)
    return None


def resolve_names(names: Sequence[str], areas: Sequence[Area],
                  classes: Dict[str, HostedClass], classes_only: bool = False) -> List[str]:
    """Turns area and class NAMEs into one ordered list of class names without repeats.

    classes_only is for --classes, where an area name is refused. An unknown
    name raises UnknownName with the closest matches in its message.
    """
    result: List[str] = []
    for name in names:
        members = None if classes_only else area_classes(areas, name)
        if members is not None and name == ALL_AREA:
            # `all` must really be all: a class no area lists yet (a new one)
            # is still run, after the listed ones, never skipped silently.
            members = members + sorted(n for n, c in classes.items() if c.runnable)
        if members is not None:
            result.extend(members)
        elif name in classes and classes[name].runnable:
            result.append(name)
        elif name in classes:
            raise UnknownName(f"'{name}' is a helper class with no tests")
        else:
            pool = list(classes) if classes_only else [ALL_AREA] + [a.name for a in areas] + list(classes)
            close = difflib.get_close_matches(name, pool, n=5, cutoff=0.6)
            kind = "class" if classes_only else "area or class"
            hint = f"; closest: {', '.join(close)}" if close else ""
            raise UnknownName(f"no {kind} named '{name}'{hint}")
    return _dedupe(result)


# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------

def build_command(root: Path, classes: Sequence[str], derived_data: str, jobs: int = 4,
                  use_slot: bool = True, action: str = "test", extra: Sequence[str] = ()) -> List[str]:
    """The argv of one xcodebuild run of all `classes`, behind the slot wrapper.

    `action` is xcodebuild's own: "test" (the default), or "build-for-testing"
    and "test-without-building" for a build followed by several test runs.

    One invocation carries every class as its own -only-testing: argument, so
    several areas launch the test host once (each launch leaves about 23 MB in
    a system cache). Run it from the repository root. The wrapper is left out
    when use_slot is false. `extra` is more xcodebuild arguments, put before the
    classes (the GitHub runner passes its test time limits this way).
    """
    command = [str(root / SLOT_WRAPPER)] if use_slot else []
    command += [
        "xcodebuild", action,
        "-project", PROJECT,
        "-scheme", SCHEME,
        "-destination", "platform=macOS",
        "-parallel-testing-enabled", "NO",
        "-jobs", str(jobs),
        "CODE_SIGNING_ALLOWED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "-derivedDataPath", derived_data,
    ]
    command += list(extra)
    command += [f"-only-testing:{TEST_TARGET}/{name}" for name in classes]
    return command


def shell_line(command: Sequence[str], env: Dict[str, str] = None) -> str:
    """The command as one shell-quoted line, with `TEST_RUNNER_X=value` words first."""
    words = [shlex.quote(f"{ENV_PREFIX}{key}={value}") for key, value in (env or {}).items()]
    return " ".join(words + [shlex.join(command)])


# ---------------------------------------------------------------------------
# Reading a log
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Summary:
    """The facts of one xcodebuild log, in the order the summary prints them."""
    executed_line: Optional[str] = None        # the last "Executed N tests, ..." line, as printed
    executed: int = 0                          # N of that line
    failures: int = 0                          # its failure count
    failed_tests: Tuple[Tuple[str, str, str, str], ...] = ()  # (Class.test, file, line, message)
    errors: Tuple[Tuple[str, str, str], ...] = ()   # (file, line, message); file may be ""
    warnings: Tuple[Tuple[str, str, str], ...] = ()
    crash: Optional[str] = None
    succeeded: bool = False                    # "** TEST SUCCEEDED **" (or "TEST EXECUTE SUCCEEDED") seen
    tail: Tuple[str, ...] = ()                 # last log lines, shown when nothing else explains a failure
    log_path: Optional[str] = None             # set by the caller
    elapsed: Optional[float] = None            # seconds, set by the caller

    @property
    def passed(self) -> bool:
        """PASSED needs TEST SUCCEEDED, an Executed line with tests and no failures."""
        return (self.succeeded and self.executed_line is not None and self.executed > 0
                and self.failures == 0 and not self.failed_tests and not self.errors)


_EXECUTED = re.compile(r"^\s*(Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?.*)$")
# "/path/File.swift:123: error: -[TextMouthProductionTests.FooTests testBar] : message"
_TEST_ERROR = re.compile(r"^(.+?\.swift):(\d+): error: -\[(?:[\w.]+\.)?(\w+) (\w+)\] : (.*)$")
_TEST_FAILED = re.compile(r"^Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' failed")
_COMPILE_ERROR = re.compile(r"^(/.+?\.swift):(\d+):\d+: error: (.*)$")
# A printed NSError ("error: Error Domain=...") is not one: interleaved output from two processes can leave such a
# line starting at "error:".
_BARE_ERROR = re.compile(r"^(?:[\w+.-]+: )?(?:fatal )?error: (?!Error Domain=)(.*)$")
_WARNING = re.compile(r"^(/.+?\.swift):(\d+):\d+: warning: (.*)$")
_CRASH = re.compile(r"crashed|Restarting after unexpected exit, crash, or test timeout")
# The build wrapper copies the agent's unread board messages into the log
# (bbs.py's describe_message): a header "#2491 finding from a to b, 10:02:11
# 17 Oct: topic", then the reply, files, and body lines, each indented two
# spaces, a blank line between messages. Their words are no xcodebuild output,
# and a message about a crash ("Test host crashed 9x") must not read as one.
_BOARD_HEADER = re.compile(r"^#\d+(?: \(unread\))? \S+ from \S+ to \S+, ")
# A line the build wrapper prints itself.
_WRAPPER_PREFIX = "[build-slot]"
# Path pieces that mark a warning as not the repository's own.
_FOREIGN_PATH = ("/DerivedData", "/SourcePackages/", "/.build/", "/checkouts/", "/TextMouth-DerivedData")


def _in_repository(path: str, root: Path) -> bool:
    """True for a source file of this repository (not a package or DerivedData)."""
    roots = {str(root), os.path.realpath(root)}
    return any(path.startswith(r + "/") for r in roots) and not any(p in path for p in _FOREIGN_PATH)


def summarize_log(text: str, root: Path) -> Summary:
    """Reads an xcodebuild log into a Summary.

    The last "Executed" line wins (several print, one per suite, the total
    last). A failed test is named by its "Test Case ... failed" line and gets
    the file, line and message of its first error line. Compile errors and
    warnings are de-duplicated (xcodebuild prints errors twice).
    """
    executed_line, executed, failures = None, 0, 0
    test_errors: Dict[str, Tuple[str, str, str]] = {}   # "Class.test" -> first (file, line, message)
    failed_order: List[str] = []
    errors: Dict[Tuple[str, str, str], None] = {}
    warnings: Dict[Tuple[str, str, str], None] = {}
    crash = None
    succeeded = False
    lines = text.splitlines()
    in_board_message = False   # inside a board message the wrapper copied into the log
    for line in lines:
        if _BOARD_HEADER.match(line):
            in_board_message = True
            continue
        if in_board_message:
            # The message goes on through its indented lines and the blank
            # line after it; the first other line is xcodebuild's again.
            if line.startswith("  ") or not line.strip():
                continue
            in_board_message = False
        match = _EXECUTED.match(line)
        if match:
            executed_line, executed, failures = match.group(1).strip(), int(match.group(2)), int(match.group(3))
            continue
        # `test` prints TEST SUCCEEDED; `test-without-building` (the --repeat runs) TEST EXECUTE SUCCEEDED.
        if "** TEST SUCCEEDED **" in line or "** TEST EXECUTE SUCCEEDED **" in line:
            succeeded = True
            continue
        match = _TEST_ERROR.match(line)
        if match:
            path, number, cls, test, message = match.groups()
            key = f"{cls}.{test}"
            test_errors.setdefault(key, (os.path.basename(path), number, message))
            if key not in failed_order:
                failed_order.append(key)
            continue
        match = _TEST_FAILED.match(line)
        if match:
            key = f"{match.group(1)}.{match.group(2)}"
            if key not in failed_order:
                failed_order.append(key)
            continue
        match = _COMPILE_ERROR.match(line)
        if match:
            errors.setdefault((os.path.basename(match.group(1)), match.group(2), match.group(3)))
            continue
        match = _WARNING.match(line)
        if match:
            if _in_repository(match.group(1), root):
                warnings.setdefault((os.path.basename(match.group(1)), match.group(2), match.group(3)))
            continue
        match = _BARE_ERROR.match(line)
        if match and not line.startswith("/"):
            errors.setdefault(("", "", match.group(1)))
            continue
        # A crash line is not a test's name or an assertion message.
        if crash is None and _CRASH.search(line) \
                and not line.startswith(("Test Case ", "Test Suite ", _WRAPPER_PREFIX)) \
                and ".swift:" not in line:
            crash = line.strip()[:240]
    failed_tests = tuple((key,) + test_errors.get(key, ("", "", "")) for key in failed_order)
    return Summary(
        executed_line=executed_line, executed=executed, failures=failures,
        failed_tests=failed_tests, errors=tuple(errors), warnings=tuple(warnings),
        crash=crash, succeeded=succeeded,
        tail=tuple(l.strip() for l in lines if l.strip())[-3:])


def format_elapsed(seconds: float) -> str:
    """Plain words: '45 seconds', '5 minutes 12 seconds'."""
    seconds = int(round(seconds))
    minutes, rest = divmod(seconds, 60)
    return f"{minutes} minutes {rest} seconds" if minutes else f"{rest} seconds"


def format_summary(summary: Summary) -> List[str]:
    """The lines to print: Executed line, failed tests, errors, warnings, crash, log, verdict."""
    out = [summary.executed_line or "no tests ran"]
    for test, file, number, message in summary.failed_tests:
        where = f" at {file}:{number}: {message}" if file else ""
        out.append(f"FAILED {test}{where}")
    for file, number, message in summary.errors[:MAX_ERRORS_SHOWN]:
        out.append(f"ERROR {file}:{number}: {message}" if file else f"ERROR {message}")
    if len(summary.errors) > MAX_ERRORS_SHOWN:
        out.append(f"and {len(summary.errors) - MAX_ERRORS_SHOWN} more")
    for file, number, message in summary.warnings:
        out.append(f"WARNING {file}:{number}: {message}")
    if summary.crash:
        out.append(f"CRASH the test host crashed or restarted: {summary.crash}")
    # A failure nothing above explains: show where the log ends.
    if not summary.passed and not (summary.failed_tests or summary.errors or summary.crash) \
            and summary.executed_line is None:
        out.extend(f"LOG {line}" for line in summary.tail)
    if summary.log_path:
        out.append(f"log: {summary.log_path}")
    verdict = "PASSED" if summary.passed else "FAILED"
    if summary.elapsed is not None:
        verdict += f" in {format_elapsed(summary.elapsed)}"
    out.append(verdict)
    return out
