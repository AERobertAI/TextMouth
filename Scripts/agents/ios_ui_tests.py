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
# A test class of the interface folder: it inherits the shared base class, `TextMouthUITestCase`, which is not itself a
# test class.
CLASS_LINE = re.compile(r"^\s*(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*TextMouthUITestCase\b", re.M)
# A test class of the unit folder: it inherits XCTestCase itself.
UNIT_CLASS_LINE = re.compile(r"^\s*(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase\b", re.M)
# One test method of a class: `func testSomething(`. A method inside `#if DEBUG` counts: the iPhone job builds Debug (the
# scheme's test action says so, and a test pins it), and the Debug build holds it.
TEST_METHOD = re.compile(r"^\s*func (test[A-Za-z0-9_]*)\(", re.M)


def _classes_in(folder, class_line):
    """The classes the `class_line` pattern finds in the Swift files of `folder`, sorted; none when the folder is absent
    (a tree from before the tests)."""
    folder = Path(folder)
    if not folder.is_dir():
        return []
    found = set()
    for path in folder.glob("*.swift"):
        found.update(class_line.findall(path.read_text(encoding="utf-8", errors="replace")))
    return sorted(found)


def _counts_in(folder, class_line):
    """How many test methods each class of `folder` holds, as {class: count}: the `func test...(` lines between a class's
    declaration and the next one's. The runner checks that at least this many results came back (a run that returns
    fewer has lost tests)."""
    folder = Path(folder)
    counts = {}
    if not folder.is_dir():
        return counts
    for path in sorted(folder.glob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        starts = [(match.start(), match.group(1)) for match in class_line.finditer(text)]
        for index, (start, name) in enumerate(starts):
            end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
            counts[name] = counts.get(name, 0) + len(TEST_METHOD.findall(text[start:end]))
    return counts


def ui_classes(root=ROOT):
    """The interface test classes in `root`'s TextMouthiOSUITests folder, sorted: every class that inherits
    `TextMouthUITestCase`. An absent folder (a tree from before the interface tests) has none."""
    return _classes_in(Path(root) / UI_FOLDER, CLASS_LINE)


def unit_classes(root=ROOT):
    """The unit test classes in `root`'s TextMouthiOSTests folder, sorted: every class that inherits `XCTestCase`."""
    return _classes_in(Path(root) / UNIT_FOLDER, UNIT_CLASS_LINE)


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
    return _counts_in(Path(root) / UI_FOLDER, CLASS_LINE)


def unit_counts(root=ROOT):
    """How many test methods each unit test class holds, as {class: count}."""
    return _counts_in(Path(root) / UNIT_FOLDER, UNIT_CLASS_LINE)


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
