"""reach.py: the hosted test classes a branch's localization could break (`l10n.py reach`, TL13).

A conversion wave rewrites interface text as `String(localized: "...")` (or, since FR39, `InterfaceText.line("<ID>", "...")`) under a
`// Translators: ...` line. Tests that compare the English text,
or read a converted file's source, can then fail. This finds them for the train request (`build-train.py request --classes`),
from the branch's own diff, with no type name written in. It covers the Mac tests (TextMouthProductionTests) and the iPhone
unit tests (TextMouthiOSTests), each class under the bundle that runs it. A class is reached when its file:

- holds an English text the branch localized: each `String(localized: "...")` or `InterfaceText.line("<ID>", "...")` the branch adds, cut at its first
  interpolation, kept when MIN_PHRASE characters or more remain (so a short word such as "Done" does not reach everything);
- names a file the branch converted (one whose added lines hold a `String(localized:`), by its path or its file name, since
  tests read the source of such files;
- is one `run-area.py --changed` finds: it mentions a type declared in a changed file, or is declared in a changed test file.
  That code is `Scripts/test/run-area.py`'s (loaded from there, not copied), and the folders are the testkit's.

Standard library only. It reads the repository's files and git's diff, and writes nothing.
"""
import importlib.util
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TEST_TOOLS = HERE.parent / "test"

# The fewest characters of an English phrase (cut at its first interpolation) that count as a match: a shorter one says nothing.
MIN_PHRASE = 12
# What the bundles are called in the results: the key of each, its test folder's name in the testkit, and its heading.
MAC, PHONE = "mac", "phone"
HEADINGS = {MAC: "Mac tests (TextMouthProductionTests)", PHONE: "iPhone unit tests (TextMouthiOSTests; request the area `phone`)"}
# A localized text in Swift source, with escapes still in it: the literal after `String(localized:`, or the English (the
# literal after the ID) of an `InterfaceText.line("<ID>", "...")` call (FR39), which a converted file holds.
LOCALIZED = re.compile(r'(?:String\(localized: |InterfaceText\.line\(\s*"[^"\\]*",\s*)"((?:[^"\\]|\\.)*)"')
# How many matching type names a reason lists.
SHOWN_NAMES = 5


def load_run_area():
    """The module of `Scripts/test/run-area.py` (its file name has a hyphen, so it is loaded by path). It brings
    `difflint` and `testkit` with it, and its `--changed` code."""
    sys.path.insert(0, str(TEST_TOOLS))
    spec = importlib.util.spec_from_file_location("run_area", TEST_TOOLS / "run-area.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def phrases_of(line):
    """The English phrases a source line localizes: each `String(localized: "...")`, cut at its first interpolation,
    with escaped quotes undone, that is MIN_PHRASE characters or longer."""
    found = []
    for match in LOCALIZED.finditer(line):
        text = match.group(1).split("\\(")[0].replace('\\"', '"')
        if len(text) >= MIN_PHRASE:
            found.append(text)
    return found


def localizations(run_area, root, base, changes):
    """What the branch localized: ({phrase: sorted files that gained it}, sorted converted files). `changes` is
    run-area's {path: text} of the changed files; the added lines are git's (difflint), so an old
    `String(localized:` the branch did not touch counts for nothing."""
    added = run_area.difflint.added_lines(base, [run_area.CHANGED_APP], str(root))
    phrases, converted = {}, set()
    for path, numbers in added.items():
        text = changes.get(path)
        if not path.endswith(".swift") or text is None:
            continue
        lines = text.split("\n")
        for number in sorted(numbers):
            if not 1 <= number <= len(lines):
                continue
            for phrase in phrases_of(lines[number - 1]):
                phrases.setdefault(phrase, set()).add(path)
                converted.add(path)
    return {phrase: sorted(files) for phrase, files in phrases.items()}, sorted(converted)


def add_reason(reached, name, reason):
    """Records that class `name` is reached for `reason` (each reason once)."""
    reasons = reached.setdefault(name, [])
    if reason not in reasons:
        reasons.append(reason)


def reach_bundle(run_area, root, folder, classes, names, changed_tests, phrases, converted):
    """The classes of one test bundle that the branch reaches: {class name: [reasons]}.

    `folder` is the bundle's test folder, `classes` its {name: HostedClass}, `names` the type names the changed app files
    declare, `changed_tests` the paths of its changed test files, `phrases` and `converted` from `localizations`."""
    words = run_area.test_file_words(root, folder)
    by_path = {}
    for name, hosted in classes.items():
        if hosted.runnable:
            by_path.setdefault(hosted.path, []).append(name)
    reached = {}
    # The classes of a file that holds an English phrase the branch localized, or names a file it converted.
    for path, names_here in by_path.items():
        text = (Path(root) / path).read_text(encoding="utf-8", errors="replace")
        reasons = [f'compares the English text "{phrase}"' for phrase in sorted(phrases) if phrase in text]
        reasons += [f"reads the source of {source}" for source in converted if source in text or source.rsplit("/", 1)[-1] in text]
        for name in names_here:
            for reason in reasons:
                add_reason(reached, name, reason)
    # The classes run-area's `--changed` picks: a type of a changed file mentioned, or a changed test file.
    ranked, _dropped, matches = run_area.score_test_classes(names, changed_tests, classes, words)
    for score, name in ranked:
        if score == run_area.CHANGED_TEST_SCORE:
            add_reason(reached, name, "declared in a changed test file")
        else:
            add_reason(reached, name, "mentions " + ", ".join(matches[name][:SHOWN_NAMES]))
    return reached


def reach(root, base="main"):
    """What the branch (the working tree and HEAD, against the merge-base with `base`) reaches in `root`:
    {"mac": {class: [reasons]}, "phone": {class: [reasons]}}. Raises difflint.GitError when git cannot say."""
    run_area = load_run_area()
    testkit = run_area.testkit
    root = Path(root)
    # The changed files include the iPhone tests', so a changed iPhone test file is found too.
    scopes = [run_area.CHANGED_APP, run_area.CHANGED_TESTS, run_area.CHANGED_DATA, testkit.IOS_TESTS_FOLDER + "/"]
    changes = run_area.changed_files(base, root, scopes)
    names, mac_changed = run_area.names_of_changes(changes)
    phone_changed = {path for path in changes if path.startswith(testkit.IOS_TESTS_FOLDER + "/") and path.endswith(".swift")}
    phrases, converted = localizations(run_area, root, base, changes)
    result = {}
    for bundle, folder, changed_tests in ((MAC, testkit.TESTS_FOLDER, mac_changed), (PHONE, testkit.IOS_TESTS_FOLDER, phone_changed)):
        classes = testkit.hosted_test_classes(root, folder)
        result[bundle] = reach_bundle(run_area, root, folder, classes, names, changed_tests, phrases, converted)
    return result


def format_reach(reached, explain=False):
    """The lines `reach` prints. Without `explain`: the Mac classes as one comma-separated line (for
    `build-train.py request --classes`; empty when there are none), then, when the iPhone tests are reached, one line
    headed with the iPhone bundle's name. With `explain`: each bundle under its heading, then a line for each class and
    reason: `  Class: reason`."""
    if not explain:
        lines = [",".join(sorted(reached[MAC]))]
        if reached[PHONE]:
            lines.append(f"{HEADINGS[PHONE]}: " + ",".join(sorted(reached[PHONE])))
        return lines
    lines = []
    for bundle in (MAC, PHONE):
        lines.append(f"{HEADINGS[bundle]}: {len(reached[bundle])} classes")
        for name in sorted(reached[bundle]):
            lines.extend(f"  {name}: {reason}" for reason in reached[bundle][name])
    return lines
