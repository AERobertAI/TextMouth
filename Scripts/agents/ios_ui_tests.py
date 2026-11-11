"""ios_ui_tests.py: which of the iPhone app's interface tests (TextMouthiOSUITests) a test request asks for.

The iPhone job of the GitHub workflow builds the iPhone app and its UI-test bundle, then runs the bundle in the iOS
Simulator (run-ios-ui-tests.py). Whether it runs, and which classes, is decided here, in one place, for every caller:
the runner's scripts, the build train, and their tests.

A request asks for the interface tests in these ways, strongest first:

- `"ios": false` leaves the whole iPhone job out, so nothing runs;
- `"ios_ui": false` runs none, and `"ios_ui": true` runs the classes named, or every class when none is named (a request
  sent by hand);
- the full suite (`"full": true`) runs every class, and so does a request for the area "all" or the area "phone";
- a request that names an interface test class, in `"classes"` or in `"ios_ui_classes"`, runs those classes alone.

The interface test classes are not Mac test classes, so Scripts/test/run-area.py does not know them: `split_classes`
moves their names out of a request's `"classes"` into `"ios_ui_classes"` (the key is there only when it holds a name)
before the Mac tests are planned, so a name given in either place works. Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The repository's root, and the folder holding the interface tests.
ROOT = Path(__file__).resolve().parents[2]
UI_FOLDER = "TextMouthiOSUITests"
# The areas of Scripts/test/areas.conf whose request also runs every interface test: the iPhone's own, and everything.
AREAS_THAT_RUN_THEM = ("phone", "all")
# A test class of the folder: it inherits the shared base class, `TextMouthUITestCase`, which is not itself a test class.
CLASS_LINE = re.compile(r"^\s*(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*TextMouthUITestCase\b", re.M)


def ui_classes(root=ROOT):
    """The interface test classes in `root`'s TextMouthiOSUITests folder, sorted: every class that inherits
    `TextMouthUITestCase`. An absent folder (a tree from before the interface tests) has none."""
    folder = Path(root) / UI_FOLDER
    if not folder.is_dir():
        return []
    found = set()
    for path in folder.glob("*.swift"):
        found.update(CLASS_LINE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return sorted(found)


# One test method of a class: `func testSomething(`.
TEST_METHOD = re.compile(r"^\s*func (test[A-Za-z0-9_]*)\(", re.M)


def test_counts(root=ROOT):
    """How many test methods each interface test class holds, as {class: count}: the `func test...(` lines between a
    class's declaration and the next one's. The runner checks that at least this many results came back (a run
    that returns fewer has lost tests)."""
    folder = Path(root) / UI_FOLDER
    counts = {}
    if not folder.is_dir():
        return counts
    for path in sorted(folder.glob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        starts = [(match.start(), match.group(1)) for match in CLASS_LINE.finditer(text)]
        for index, (start, name) in enumerate(starts):
            end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
            counts[name] = counts.get(name, 0) + len(TEST_METHOD.findall(text[start:end]))
    return counts


def split_classes(request, root=ROOT):
    """A copy of `request` with the interface test classes named in its "classes" moved to "ios_ui_classes" (joined
    with any already there, once each, in order), so that "classes" holds only Mac test classes for run-area.py."""
    known = set(ui_classes(root))
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
    """The interface test classes `request` asks to run, in the order of `ui_classes`: none when the iPhone job is left
    out or the request does not ask for them (see the module's comment). Names the folder does not hold are ignored."""
    if request.get("ios") is False:
        return []
    every = ui_classes(root)
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
