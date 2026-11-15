"""ios_ui_tests.py: which of the iPhone app's tests a test request asks for: its interface tests (TextMouthiOSUITests)
and its unit tests (TextMouthiOSTests).

The iPhone job of the GitHub workflow builds the iPhone app and both test bundles, then runs them in the iOS Simulator
(run-ios-ui-tests.py), in one xcodebuild run. Whether they run, and which classes, is decided here, in one place, for
every caller: the runner's scripts, the build train, and their tests. The two bundles are asked for together: a request
that asks for one asks for the other, except that a request naming classes runs those classes alone.

A request asks for the iPhone tests in these ways, strongest first:

- `"ios": false` leaves the whole iPhone job out, so nothing runs;
- `"ios_ui": false` runs none, and `"ios_ui": true` runs the classes named, or every class when none is named (a request
  sent by hand);
- the full suite (`"full": true`) runs every class of both bundles, and so does a request for the area "all" or the
  area "phone";
- a request that names an iPhone test class (of either bundle), in `"classes"` or in `"ios_ui_classes"`, runs those
  classes alone.

The iPhone test classes are not Mac test classes, so Scripts/test/run-area.py does not know them: `split_classes`
moves their names out of a request's `"classes"` into `"ios_ui_classes"` (the key is there only when it holds a name)
before the Mac tests are planned, so a name given in either place works. The key keeps its old name though it holds
unit test classes too. Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shard  # noqa: E402

# The repository's root, and the folders holding the two bundles' tests (each folder is named for its bundle).
ROOT = Path(__file__).resolve().parents[2]
UI_FOLDER = "TextMouthiOSUITests"
UNIT_FOLDER = "TextMouthiOSTests"
UI_BUNDLE = UI_FOLDER
UNIT_BUNDLE = UNIT_FOLDER
# What each bundle's tests are called in a summary.
BUNDLE_KIND = {UNIT_BUNDLE: "unit tests", UI_BUNDLE: "interface tests"}
# The areas of Scripts/test/areas.conf whose request also runs every iPhone test: the iPhone's own, and everything.
AREAS_THAT_RUN_THEM = ("phone", "all")
# What may stand before a declaration on its line (or on the lines before it): attributes, with or without arguments
# (`@MainActor`, `@available(iOS 26, *)`), and modifiers. `project.yml` compiles every Swift file under each test folder, so
# the sources are read the same way, subfolders and all.
_BEFORE = r"(?:(?:@\w+(?:\([^)]*\))?|public|internal|open|final|private|fileprivate|override|nonisolated)\s+)*"
# A place where tests are declared: a class, or an extension of a type (an extension in another file or after another class
# adds its tests to the type it names). `class` captures its name and its first base class; `extension` its type's name.
_SCOPE = re.compile(
    r"^[ \t]*" + _BEFORE + r"(?:class\s+(?P<class>[A-Za-z0-9_]+)\s*:\s*(?P<base>[A-Za-z0-9_.]+)|extension\s+(?P<ext>[A-Za-z0-9_.]+))",
    re.M,
)
# The base class a test class of each folder inherits. The interface folder's own base class, `TextMouthUITestCase`, is not
# a test class itself: it inherits XCTestCase, not itself.
UI_BASE = "TextMouthUITestCase"
UNIT_BASE = "XCTestCase"
# One test method of a class: `func testSomething(`, with any attributes or modifiers before `func`
# (`@MainActor func testA()`). A method inside `#if DEBUG` counts: the iPhone job builds Debug (the scheme's test action
# says so, and a test pins it), and the Debug build holds it. A helper struct's `func test...(` also counts (a false red,
# which is the safe side).
TEST_METHOD = re.compile(r"^[ \t]*" + _BEFORE + r"func\s+(test[A-Za-z0-9_]*)\s*\(", re.M)


def swift_files(folder):
    """The Swift files under `folder`, subfolders included, in path order; none when the folder is absent (a tree from
    before the tests)."""
    folder = Path(folder)
    return sorted(folder.rglob("*.swift")) if folder.is_dir() else []


def _counts_in(folder, base):
    """How many test methods each test class of `folder` holds, as {class: count}: a test class is one that inherits `base`.
    A method counts for the class or extension it follows, wherever that is in the folder: an extension of a test class
    adds to its count, an extension of any other type (or a class that inherits something else) adds to none. The runner
    checks that at least this many results came back (a run that returns fewer has lost tests)."""
    texts = [path.read_text(encoding="utf-8", errors="replace") for path in swift_files(folder)]
    # First every test class of the folder, so an extension may come before its class or in another file.
    counts = {}
    for text in texts:
        for match in _SCOPE.finditer(text):
            if match.group("class") and match.group("base").split(".")[-1] == base:
                counts.setdefault(match.group("class"), 0)
    for text in texts:
        scopes = [(match.start(), match.group("class") or match.group("ext").split(".")[-1])
                  for match in _SCOPE.finditer(text)]
        for index, (start, name) in enumerate(scopes):
            end = scopes[index + 1][0] if index + 1 < len(scopes) else len(text)
            if name in counts:
                counts[name] += len(TEST_METHOD.findall(text[start:end]))
    return counts


def _classes_in(folder, base):
    """The test classes of `folder` (those that inherit `base`), sorted; none when the folder is absent."""
    return sorted(_counts_in(folder, base))


def ui_classes(root=ROOT):
    """The interface test classes in `root`'s TextMouthiOSUITests folder, sorted: every class that inherits
    `TextMouthUITestCase`. An absent folder (a tree from before the interface tests) has none."""
    return _classes_in(Path(root) / UI_FOLDER, UI_BASE)


def unit_classes(root=ROOT):
    """The unit test classes in `root`'s TextMouthiOSTests folder, sorted: every class that inherits `XCTestCase`."""
    return _classes_in(Path(root) / UNIT_FOLDER, UNIT_BASE)


def all_classes(root=ROOT):
    """Every iPhone test class, the unit tests' first (the scheme lists that bundle first), each bundle's sorted."""
    return unit_classes(root) + ui_classes(root)


def bundle_of(name, root=ROOT):
    """The bundle the class `name` is in (UNIT_BUNDLE or UI_BUNDLE), or "" when neither holds it."""
    if name in unit_classes(root):
        return UNIT_BUNDLE
    return UI_BUNDLE if name in ui_classes(root) else ""


def test_counts(root=ROOT):
    """How many test methods each interface test class holds, as {class: count}."""
    return _counts_in(Path(root) / UI_FOLDER, UI_BASE)


def unit_counts(root=ROOT):
    """How many test methods each unit test class holds, as {class: count}."""
    return _counts_in(Path(root) / UNIT_FOLDER, UNIT_BASE)


def counts_by_bundle(names, root=ROOT):
    """How many tests the classes `names` hold, as {bundle: count}, for the bundles they are in (a name in neither bundle
    counts nowhere). The runner expects at least this many results back from each bundle."""
    held = {UNIT_BUNDLE: unit_counts(root), UI_BUNDLE: test_counts(root)}
    totals = {}
    for name in names:
        for bundle, counts in held.items():
            if name in counts:
                totals[bundle] = totals.get(bundle, 0) + counts[name]
    return totals


def split_classes(request, root=ROOT):
    """A copy of `request` with the iPhone test classes (of either bundle) named in its "classes" moved to
    "ios_ui_classes" (joined with any already there, once each, in order), so that "classes" holds only Mac test classes
    for run-area.py."""
    known = set(all_classes(root))
    classes = list(request.get("classes", []))
    moved = [name for name in classes if name in known]
    kept = [name for name in classes if name not in known]
    already = [name for name in request.get("ios_ui_classes", []) if isinstance(name, str)]
    joined = list(dict.fromkeys(already + moved))
    split = {**request, "classes": kept}
    # The key is there only when it holds a name, so a request without any stays as it was.
    if joined:
        split["ios_ui_classes"] = joined
    else:
        split.pop("ios_ui_classes", None)
    return split


def wanted(request, root=ROOT):
    """The iPhone test classes (unit and interface) `request` asks to run, in the order of `all_classes`: none when the
    iPhone job is left out or the request does not ask for them (see the module's comment). Names the folders do not
    hold are ignored."""
    if request.get("ios") is False:
        return []
    every = all_classes(root)
    explicit = request.get("ios_ui")
    if explicit is False:
        return []
    request = split_classes(request, root)
    named = [name for name in every if name in set(request.get("ios_ui_classes", []))]
    # "ios_ui": true with classes named runs those alone, as a request for classes does; with none it runs them all.
    if explicit is True:
        return named or every
    if request.get("full") or any(area in AREAS_THAT_RUN_THEM for area in request.get("areas", [])):
        return every
    return named


def executed_with_counts(lines):
    """The Executed line of an ios-ui-summary.txt (`lines`, its lines) with the per-bundle count lines joined on, so that a
    reader that shows one line shows how many unit tests and how many interface tests ran: "Executed 52 tests, ...;
    unit tests (TextMouthiOSTests): 19 ran, 0 skipped, 0 failed; interface tests (TextMouthiOSUITests): ...". An empty
    string when the summary has no Executed line. The count lines of the summary begin with the kind's name, capitalised
    ("Unit tests (TextMouthiOSTests): ...")."""
    executed = next((line.strip() for line in lines if line.startswith("Executed ")), "")
    if not executed:
        return ""
    kinds = tuple(kind[0].upper() + kind[1:] for kind in BUNDLE_KIND.values())
    counts = [line.strip()[0].lower() + line.strip()[1:] for line in lines if line.startswith(kinds)]
    return "; ".join([executed, *counts])


# ---------------------------------------------------------------------------
# Sharding: the iPhone job as several jobs (the workflow's `ios` matrix)
# ---------------------------------------------------------------------------

# The seconds each class took in a run on the runner, {class: seconds}, beside this script (class_times.py writes it from the
# `ios-ui.log` of a full suite).
TIMES_FILE = Path(__file__).resolve().parent / "ios-class-times.json"
# What a class that the times file does not know is counted as, for each test it holds: an interface test launches the app
# (10 to 15 seconds on the runner's three cores) and waits for screens, 25 to 35 seconds each in the runs of November 10 to 13;
# a unit test takes about a second. So a class a later change adds is dealt out by its size and not as one second.
SECONDS_PER_TEST = {UI_BUNDLE: 25.0, UNIT_BUNDLE: 1.0}
# One iPhone job's share of tests, in seconds, past which another job is worth its own set-up (the platform's download, the
# build, the simulator's boot: about 10 to 13 minutes on the runner).
TARGET_SHARD_SECONDS = 480
# The most iPhone jobs: a free account runs 5 macOS jobs at once, and the Mac tests' shards share them.
MAX_SHARDS = 3


def load_times(path=TIMES_FILE):
    """{class: seconds} from the times file; empty when it is missing or unreadable (see shard.load_times)."""
    return shard.load_times(path)


def estimated_seconds(classes, root=ROOT, times=None):
    """{class: seconds} for `classes`: the time the file holds, else the number of tests the class holds times the
    SECONDS_PER_TEST of its bundle (a class in neither bundle counts as shard.DEFAULT_SECONDS)."""
    times = load_times() if times is None else times
    held = {UNIT_BUNDLE: unit_counts(root), UI_BUNDLE: test_counts(root)}
    seconds = {}
    for name in classes:
        if name in times:
            seconds[name] = times[name]
            continue
        counts = [(bundle, counted[name]) for bundle, counted in held.items() if name in counted]
        seconds[name] = counts[0][1] * SECONDS_PER_TEST[counts[0][0]] if counts else shard.DEFAULT_SECONDS
    return seconds


def shard_count(classes, root=ROOT, times=None, target=TARGET_SHARD_SECONDS, most=MAX_SHARDS):
    """How many iPhone jobs `classes` need: one for each `target` seconds of tests, at least 1, at most `most`."""
    return shard.shard_count(list(classes), estimated_seconds(classes, root, times), target, most)


def slice_for(classes, number, count, root=ROOT, times=None):
    """The classes of shard `number` of `count` (1-based): the classes dealt out by their estimated seconds (shard.split),
    so every job computes the same slices from the same request. With a count of 1, all of them."""
    if count <= 1:
        return list(classes)
    return shard.split(list(classes), estimated_seconds(classes, root, times), count)[number - 1]
