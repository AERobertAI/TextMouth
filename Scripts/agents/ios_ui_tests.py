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
  classes alone;
- a name may also be `Class/testMethod`, one test method of such a class, and then only that method runs (a method whose
  class is named whole runs with the class).

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
# Scripts/test, for the lints' Swift masker (difflint.mask_swift), appended so a module of this folder always wins.
sys.path.append(str(Path(__file__).resolve().parents[1] / "test"))
import difflint  # noqa: E402

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


# What would make sound or use a microphone, in three groups, so a unit test of either bundle may name none of them:
# - the audio frameworks and the speech recognizer (`import Speech` uses the microphone's permission);
# - the app's own ways in, which `@testable import TextMouth` exposes: its players, its recorder, and its audio session;
# - calls that start sound: `togglePlay()`, `playOrResume()`, `playSelection()`, `playAudioChapter()`,
#   `startPunchIn()` and `.play(at:)` (any arguments), and any call beginning with play or speak, and `resume(` (a Swift continuation's is not one; `resumeIndexWrites(` is a library helper).
#   A call on a `…Wording` type (`PhoneReaderWording.playHint(movingBy:)`) only returns the text a control says, so it is
#   not one either; the same name called on anything else still counts.
# A bare `record(...)` is not read: in these tests it is the feed store, the log, or a test's own list recording a value, and the
# recorder types and `startRecording` are named above.
# A false red is the safe side. The check of the unit bundle's files (test_run_ios_ui_tests.py) and the tests census
# (Scripts/ios/typecheck.py) both read this one pattern.
SOUND_PATTERN = re.compile(
    r"AVFoundation|AVAudio|AVSpeech|AVPlayer|AVQueuePlayer|AudioToolbox|AudioUnit|CoreAudio|MediaPlayer|import Speech|"
    r"SpeechEngine|AudioEngine|PhoneAudioSession|PhoneAppModel|ReaderViewModel|"
    r"Recorder|RecordingService|togglePlay|playOrResume|playSelection|playAudioChapter|startPunchIn|startRecording|"
    r"\.(?:play|speak)\(|(?<!Wording\.)\b(?:play|speak)\w*\(|(?<!continuation\.)\bresume\("
)


# The one allowance in the rule above: a test may name `ReaderViewModel` inside one helper, `func makeReader() -> ReaderViewModel`,
# so that the sheets that take a reader (Go To, Search in Book, Sleep Timer) are hosted as the user meets them. The helper
# builds a stopped reader, services off and content set directly. `sound_in_source` finds its head and cuts it out by its
# braces, and the rule still reads the helper (without that one type name) and everything outside it (with it): the helper
# may call nothing that plays, speaks, or resumes, and nothing else in the file may name the type, not even a second helper.
_READER_HELPER_HEAD = re.compile(r"^[ \t]*(?:private\s+|fileprivate\s+)?func\s+makeReader\s*\(\s*\)\s*->\s*ReaderViewModel\s*\{", re.M)
# A string literal, blanked before braces are counted so that a brace inside a string cannot move the helper's end.
_STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\\n])*"')


def _cut_reader_helper(code):
    """`code` (comment lines already removed) as (the helper, the rest). The helper is the first `makeReader() -> ReaderViewModel`
    function, from its head to the brace that closes it; the rest is everything else, so it is read with the whole rule. When
    there is no helper, or its braces do not close, the helper is "" and the rest is all of `code`: no allowance is made."""
    head = _READER_HELPER_HEAD.search(code)
    if not head:
        return "", code
    # Count braces on a copy whose string literals are blanked out, same length so that its indexes are the code's.
    bare = _STRING_LITERAL.sub(lambda found: " " * len(found.group(0)), code)
    depth = 0
    for index in range(head.end() - 1, len(bare)):
        depth += {"{": 1, "}": -1}.get(bare[index], 0)
        if depth == 0:
            # The closing brace itself ends the helper: anything after it on its line is read as the rest.
            return code[head.start():index + 1], code[:head.start()] + code[index + 1:]
    return "", code


def sound_in_source(text):
    """The first thing in the Swift source `text` that would make sound (see SOUND_PATTERN), or "" when there is none.
    Comments say "plays" in prose, so only code counts: a line that starts with `//` is not read. The one allowance is the
    `makeReader() -> ReaderViewModel` helper (see _READER_HELPER_HEAD): its body is read with the type's name removed."""
    code = "\n".join(line for line in text.splitlines() if not line.strip().startswith("//"))
    helper, rest = _cut_reader_helper(code)
    # Outside the helper every name counts, ReaderViewModel included; inside it only that one name is let through.
    for part in (rest, re.sub(r"\bReaderViewModel\b", "Reader", helper)):
        match = SOUND_PATTERN.search(part)
        if match:
            return match.group(0)
    return ""


def sound_in_files(files):
    """The files (paths) that name something that makes sound, as {file name: first match}."""
    found = {}
    for path in files:
        match = sound_in_source(Path(path).read_text(encoding="utf-8", errors="replace"))
        if match:
            found[Path(path).name] = match
    return found


def swift_files(folder):
    """The Swift files under `folder`, subfolders included, in path order; none when the folder is absent (a tree from
    before the tests)."""
    folder = Path(folder)
    return sorted(folder.rglob("*.swift")) if folder.is_dir() else []


def unit_source_files(root=ROOT):
    """Every Swift file the unit bundle compiles, in path order: its own folder's, and the Mac tests' files that
    project.yml lists for it by path (so that one file serves the Mac's bundle and the iPhone's; see `shared_files`).
    A file listed but absent from the tree is left out."""
    root = Path(root)
    return sorted(set(swift_files(root / UNIT_FOLDER)) | set(shared_files(root)))


def shared_files(root=ROOT):
    """The Mac tests' Swift files that project.yml lists among the sources of TextMouthiOSTests, as absolute paths in
    the order listed: the files the two bundles share. None when project.yml is absent or lists none."""
    root = Path(root)
    project = root / "project.yml"
    if not project.is_file():
        return []
    block = re.search(rf"^  {UNIT_BUNDLE}:\n(.*?)^    settings:", project.read_text(encoding="utf-8"), re.M | re.S)
    if not block:
        return []
    listed = re.findall(r"^      - (\S+\.swift)\s*$", block.group(1), re.M)
    return [root / path for path in listed if (root / path).is_file()]


def without_mac_only(text):
    """`text` without the lines the iPhone does not compile: those between `#if os(macOS)` and its `#else` or `#endif` (the
    tests a shared Mac file fences off because they need the Mac). Nested `#if`s are followed; `#if !os(macOS)` and
    other conditions are kept, as the iPhone compiles them."""
    kept, depth_in_mac = [], 0
    for line in text.split("\n"):
        stripped = line.strip()
        if depth_in_mac:
            if stripped.startswith("#if"):
                depth_in_mac += 1
            elif stripped.startswith("#endif"):
                depth_in_mac -= 1
            elif stripped.startswith(("#else", "#elseif")) and depth_in_mac == 1:
                depth_in_mac = 0
                # What follows an #else of a Mac-only block is the iPhone's; its #endif is then dropped below.
                kept.append("#if true")
            continue
        if re.match(r"#if\s+os\(macOS\)\s*$", stripped):
            depth_in_mac = 1
            continue
        kept.append(line)
    return "\n".join(kept)


# A brace of the masked code (see _scope_runs).
_BRACE = re.compile(r"[{}]")


def _masked(text):
    """`text` with its comments and string literals blanked (difflint.mask_swift's code view), every offset kept, so a
    brace or a declaration inside them counts for nothing."""
    return "\n".join(difflint.mask_swift(text).code)


def _scope_runs(code):
    """The stretches of the masked `code` (`_masked`) each class or extension holds itself, as [(start, end, name)] in
    file order, `name` None outside them all. A scope's stretch runs from its declaration to its closing brace. A scope
    declared inside another (a helper class inside a test class) holds only its own braces, and the outer one's stretch
    resumes after them, so the tests after a nested helper still count for the class they are in. A scope whose closing
    brace never comes runs to the end. The offsets index the unmasked text too."""
    # Each opening brace's end: the offset just after its closing brace. A closing brace with none open is passed over.
    ends, opened = {}, []
    for brace in _BRACE.finditer(code):
        if brace.group() == "{":
            opened.append(brace.start())
        elif opened:
            ends[opened.pop()] = brace.end()
    runs, inside, cursor = [], [], 0  # inside: (name, end) of the scopes open at the cursor, the innermost last

    def leave_before(position):
        """Closes every open scope that ends at or before `position`, each with the last stretch it holds."""
        nonlocal cursor
        while inside and inside[-1][1] <= position:
            name, end = inside.pop()
            runs.append((cursor, end, name))
            cursor = end

    for match in _SCOPE.finditer(code):
        start = match.start()
        leave_before(start)
        runs.append((cursor, start, inside[-1][0] if inside else None))
        brace = code.find("{", match.end())
        inside.append((match.group("class") or match.group("ext").split(".")[-1],
                       ends.get(brace, len(code)) if brace >= 0 else len(code)))
        cursor = start
    leave_before(len(code))
    runs.append((cursor, len(code), None))
    return [run for run in runs if run[0] < run[1]]


def _counts_of(files, base):
    """How many test methods each test class declared in `files` (paths) holds, as {class: count}: a test class is one
    that inherits `base`, or inherits a class of these files that is one (so a shared helper base such as the Mac tests'
    `CloudMaintenanceTestCase` counts). A method counts for the class or extension it follows, wherever that is in the
    files: an extension of a test class adds to its count, an extension of any other type (or a class that inherits
    something else) adds to none, and a class nested in a test class holds only its own braces (`_scope_runs`). The
    runner checks that at least this many results came back (a run that returns fewer
    has lost tests)."""
    texts = [without_mac_only(path.read_text(encoding="utf-8", errors="replace")) for path in files]
    codes = [_masked(text) for text in texts]
    # First every test class of the files, so an extension may come before its class or in another file. A class that
    # inherits one found already is found in a later pass, so the order of the files does not matter.
    declared = [(match.group("class"), match.group("base").split(".")[-1])
                for code in codes for match in _SCOPE.finditer(code) if match.group("class")]
    bases, counts = {base}, {}
    grown = True
    while grown:
        grown = False
        for name, parent in declared:
            if parent in bases and name not in counts:
                counts[name] = 0
                bases.add(name)
                grown = True
    for text, code in zip(texts, codes):
        for start, end, name in _scope_runs(code):
            if name in counts:
                # pos and endpos, not a slice: `^` still matches only where a line of the file begins.
                counts[name] += len(TEST_METHOD.findall(text, start, end))
    return counts


def _counts_in(folder, base):
    """`_counts_of` the Swift files under `folder`."""
    return _counts_of(swift_files(folder), base)


def _classes_in(folder, base):
    """The test classes of `folder` (those that inherit `base`), sorted; none when the folder is absent."""
    return sorted(_counts_in(folder, base))


def ui_classes(root=ROOT):
    """The interface test classes in `root`'s TextMouthiOSUITests folder, sorted: every class that inherits
    `TextMouthUITestCase`. An absent folder (a tree from before the interface tests) has none."""
    return _classes_in(Path(root) / UI_FOLDER, UI_BASE)


def unit_classes(root=ROOT):
    """The unit test classes of `root`, sorted: every class that inherits `XCTestCase` in the TextMouthiOSTests folder or
    in a Mac test file that project.yml lists for the bundle."""
    return sorted(unit_counts(root))


def shared_classes(root=ROOT):
    """The unit test classes that are also Mac test classes, sorted: those declared in the files the two bundles share.
    Their names stay in a request's `"classes"` for the Mac, and are added to the iPhone's."""
    return sorted(_counts_of(shared_files(root), UNIT_BASE))


def all_classes(root=ROOT):
    """Every iPhone test class, the unit tests' first (the scheme lists that bundle first), each bundle's sorted."""
    return unit_classes(root) + ui_classes(root)


def bundle_of(name, root=ROOT):
    """The bundle the class `name` (or the method `Class/testMethod`) is in (UNIT_BUNDLE or UI_BUNDLE), or "" when
    neither holds it."""
    name = shard.class_of(name)
    if name in unit_classes(root):
        return UNIT_BUNDLE
    return UI_BUNDLE if name in ui_classes(root) else ""


def methods_of(name, root=ROOT):
    """The test methods the iPhone class `name` holds, in file order, from its class and its extensions in the bundle's
    sources (as `_counts_of` counts them); none for a name neither bundle holds."""
    bundle = bundle_of(name, root)
    files = unit_source_files(root) if bundle == UNIT_BUNDLE else swift_files(Path(root) / UI_FOLDER) if bundle else []
    methods = []
    for path in files:
        text = without_mac_only(path.read_text(encoding="utf-8", errors="replace"))
        for start, end, scope in _scope_runs(_masked(text)):
            if scope == name:
                methods += TEST_METHOD.findall(text, start, end)
    return methods


def test_counts(root=ROOT):
    """How many test methods each interface test class holds, as {class: count}."""
    return _counts_in(Path(root) / UI_FOLDER, UI_BASE)


def unit_counts(root=ROOT):
    """How many test methods each unit test class holds, as {class: count}, the shared Mac test files' included."""
    return _counts_of(unit_source_files(root), UNIT_BASE)


def counts_by_bundle(names, root=ROOT):
    """How many tests the classes `names` hold, as {bundle: count}, for the bundles they are in (a name in neither bundle
    counts nowhere; a `Class/testMethod` counts one). The runner expects at least this many results back from each bundle."""
    held = {UNIT_BUNDLE: unit_counts(root), UI_BUNDLE: test_counts(root)}
    totals = {}
    whole = {name for name in names if "/" not in name}
    for name in names:
        # A `Class/testMethod` is one test; it adds nothing when its whole class is there too.
        cls = shard.class_of(name)
        if name != cls and cls in whole:
            continue
        for bundle, counts in held.items():
            if cls in counts:
                totals[bundle] = totals.get(bundle, 0) + (counts[cls] if name == cls else 1)
    return totals


def split_classes(request, root=ROOT):
    """A copy of `request` with the iPhone test classes (of either bundle) named in its "classes" added to
    "ios_ui_classes" (joined with any already there, once each, in order). An iPhone-only class is moved out of "classes",
    so that "classes" holds only Mac test classes for run-area.py; a class the two bundles share stays in "classes" as
    well, because the Mac still runs it. A `Class/testMethod` follows its class."""
    known = set(all_classes(root))
    shared = set(shared_classes(root))
    classes = list(request.get("classes", []))
    moved = [name for name in classes if shard.class_of(name) in known]
    kept = [name for name in classes if shard.class_of(name) not in known or shard.class_of(name) in shared]
    already = [name for name in request.get("ios_ui_classes", []) if isinstance(name, str)]
    joined = list(dict.fromkeys(already + moved))
    split = {**request, "classes": kept}
    # The key is there only when it holds a name, so a request without any stays as it was.
    if joined:
        split["ios_ui_classes"] = joined
    else:
        split.pop("ios_ui_classes", None)
    return split


def _named_in_order(every, names):
    """The `names` that name a class or a method of a class in `every`, in the order of `every`: a class named whole stands
    for itself (a method of it in `names` is dropped), and a class's methods follow in the order they were named."""
    asked = [name for name in names if isinstance(name, str)]
    whole = {name for name in asked if "/" not in name}
    ordered = []
    for cls in every:
        if cls in whole:
            ordered.append(cls)
        else:
            ordered += [name for name in dict.fromkeys(asked) if "/" in name and shard.class_of(name) == cls]
    return ordered


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
    named = _named_in_order(every, request.get("ios_ui_classes", []))
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
# a unit test is far quicker: 1,979 of them, most shared with the Mac, took 70.9 seconds of test time in run 43690096205,
# about 0.04 seconds each, so 0.05 is counted. So a class a later change adds is dealt out by its size and not as one second,
# and the unit bundle's 1,960 tests do not pass for half an hour of work (they took the Mac tests' third shard when counted
# at a second each).
SECONDS_PER_TEST = {UI_BUNDLE: 25.0, UNIT_BUNDLE: 0.05}
# One iPhone job's share of tests, in seconds, past which another job is worth its own set-up (the platform's download, the
# build, the simulator's boot: about 12 minutes on the runner, since the build names one architecture). A third job saves
# only part of the tests' time but takes a macOS slot from the Mac tests' shards (5 at once, plan_shards.py), whose third
# shard then ends 5 or more minutes later (run 43716590818). So the full suite is two jobs as long as two jobs' tests end
# before the Mac's three shards do. Measured on the runs of November 23, 2026 (ios-class-times.json): about 1,350 seconds
# of tests (1,259 of interface tests in 10 classes, the Arabic and Spanish switch alone 296), so a third job comes only
# past 1,600 seconds.
TARGET_SHARD_SECONDS = 800
# The most iPhone jobs: a free account runs 5 macOS jobs at once, and the Mac tests' shards share them.
MAX_SHARDS = 3
# The most iPhone jobs when nothing else wants the slots: a request for one Mac shard leaves 4 of the 5 to the iPhone
# (plan_shards.py). A job's set-up, 14 minutes in the median (the platform's download 3.8, the Simulator build 4.9, the
# simulator's set-up 5.7; the 39 jobs of the 22 trains of November 23 to 25), is the same however few tests it holds, so a
# fourth job takes the tests' share from about 15 minutes (unit tests 3.6, interface tests 11.3) down to about 11.
MAX_SHARDS_WITH_ROOM = 4
# One iPhone job's share of tests, in seconds, past which another job is taken when slots stand idle (the same room): an
# idle macOS slot costs the Mac tests nothing, so the plan splits finer than TARGET_SHARD_SECONDS, which weighs a job against
# the Mac shards it would displace. At 600 seconds a split saves about 5 minutes of the slowest job's tests.
TARGET_SHARD_SECONDS_WITH_ROOM = 600


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
        # A `Class/testMethod` is one test of its class.
        cls = shard.class_of(name)
        counts = [(bundle, counted[cls] if name == cls else 1) for bundle, counted in held.items() if cls in counted]
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
