#!/usr/bin/env python3
"""typecheck.py: compile TextMouth's app sources for iOS or for macOS with SwiftPM.

Xcode refuses every iOS build until its iOS platform (about 10 GB) is
downloaded, but SwiftPM needs only the iOS SDK that Xcode already includes. So
this script copies the committed sources of a commit into a work folder of its
own, writes a Swift package around them, and builds that package for the
platform asked for, two jobs at a time to spare the Mac's 8 GB. It never
changes the repository.

What each platform compiles (the same rule as the two app targets in
project.yml):
- iOS: TextMouth/, less TextMouth/Platform/macOS/ and TextMouth/Resources/;
- macOS: TextMouth/, less TextMouth/Platform/iOS/ and TextMouth/Resources/.
Both link the C libraries the apps link (LAME and the Objective-C exception
catcher, and on iOS liblouis and the braille library, which the Mac's braille
helper links instead), so a clean run means the app compiles and links. The
iPhone's FFmpeg session (FMT54) needs FFmpeg's own build, which only Xcode
makes, so its package links a stand-in of the session's functions
(FFMPEG_SESSION_STUB), compiled against the session's real header; the real
session is built by every iPhone build on GitHub.

With `--tests` (macOS only) the package also holds the Mac's hosted test target,
TextMouthProductionTests, built with `swift build --target`, so a test file
that does not compile is found without xcodebuild. The target's sources are the
folder of that name plus the files of TextMouthTests/Sources/Tests that
project.yml lists for it (read from project.yml at the commit, so the two cannot
drift apart); errors in those files are reported under their repository paths.
It compiles the tests and the app, but links no test bundle and runs nothing.
On iOS, `--tests` also compiles the iPhone's interface-test bundle,
TextMouthiOSUITests (XCUITest code that drives the app from outside, so it needs
XCTest and nothing of the app), in a second build of the same package: a compile
error in an interface test is then found here, not first on GitHub, where it fails
a whole train. The one command covers both iPhone bundles, so no train request
can skip the interface tests' check. Do this before asking the build train for a build.

The census (`--census`, iOS only) reads `import AppKit` as `import UIKit` in
the copy, so that every AppKit name a file uses is reported, instead of the
file stopping at one "no such module" error. It is for counting what is left;
the strict run (the default) is what the iOS app must pass.

With `--worktree` the copy is made from the working tree's tracked and new files (the ones git would add, less what
.gitignore hides) instead of a commit, so that one commit can hold code and the catalog it needs, and a change can be
checked before it is committed; `--ref` still checks a commit.

Every run takes the Mac's heavy-work lock first (Scripts/agents/heavy_lock.py),
which the build train takes too, so no two heavy jobs ever run at once. A run
takes about two minutes. Its results go to the main checkout's gitignored
build/typecheck/results/, one folder per run: summary.md and errors.txt.

Usage:
  typecheck.py [--platform ios|macos] [--census | --tests | --tests-census] [--ref REF | --worktree]
               [--agent SLUG] [--wait MINUTES] [--jobs N] [--no-lock] [--quiet]
Exit status: 0 when the build succeeded, 1 when it found errors, 2 for a
problem setting it up, 3 when the lock stayed busy for the whole wait.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# The heavy-work lock, shared with the build train, and the main checkout's finder:
# Scripts/agents/heavy_lock.py and repo_paths.py beside this script's own folder
# (python3 -I leaves both out of sys.path).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agents"))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)
import ios_ui_tests  # noqa: E402  (the iPhone test classes, and what a unit test may not name)
import repo_paths  # noqa: E402

# The main checkout, which holds the package checkouts, the lock, and the
# results, whichever worktree runs the script.
MAIN = repo_paths.main_checkout()
WORK_ROOT = MAIN / "build" / "typecheck"
RESULTS = WORK_ROOT / "results"
CHECKOUTS = MAIN / "build" / "DerivedData" / "SourcePackages" / "checkouts"
RESOLVED = Path("TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

# The test kit's inventory of the Mac's test classes and its areas, which the tests census reports by.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "test"))
import testkit  # noqa: E402

# The hosted test target of project.yml, and the folder of the copy that holds the
# files project.yml lists for it from TextMouthTests/Sources/Tests (one SwiftPM
# target takes one folder). Diagnostics in that folder are shown under the
# files' repository paths.
TEST_TARGET = "TextMouthProductionTests"
LISTED_TESTS_FOLDER = f"{TEST_TARGET}/_ListedInProjectYml"
LISTED_TESTS_ORIGIN = "TextMouthTests/Sources/Tests"
# The iPhone app's unit-test target: its own folder, and the Mac tests' files that project.yml lists for it by path (so
# one file serves both bundles). SwiftPM takes one folder per target, so those files are copied into a folder of their own.
IOS_TEST_TARGET = "TextMouthiOSTests"
SHARED_TESTS_FOLDER = f"{IOS_TEST_TARGET}/_SharedWithTheMac"
# The iPhone app's interface-test target (XCUITest): its own folder, built with the unit target by `--tests` on iOS.
IOS_UI_TEST_TARGET = "TextMouthiOSUITests"

# Each package: its identity in Package.resolved, its checkout's folder name,
# and the folder name the probe gives it.
PACKAGES = [
    ("zipfoundation", "ZIPFoundation", "ZIPFoundation"),
    ("swift-cmark", "swift-cmark", "cmark"),
]

# One compiler diagnostic: an absolute path to a source file, its line and
# column, the kind, and the message.
DIAGNOSTIC = re.compile(r"^(/\S+\.(?:swift|c|h|m)):(\d+):(\d+): (error|warning): (.*)$")
# The terminal escapes in a compiler's colored output: color codes, and OSC 8 links. Xcode 27's
# compiler writes them even into a log file, inside each diagnostic line, and links each
# diagnostic to its documentation.
TERMINAL_ESCAPE = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;[^\x07\x1b]*(?:\x07|\x1b\\)")


def without_terminal_escapes(text):
    """`text` without color codes or links, so a colored diagnostic reads as the plain line DIAGNOSTIC matches."""
    return TERMINAL_ESCAPE.sub("", text)


# The linker's own failures, which name no source line.
LINK_FAILURE = re.compile(r"(^ld: |Undefined symbols|linker command failed|error: link command failed)")
# A quoted name inside a message, folded to 'X' to group messages by kind.
QUOTED = re.compile(r"'[^']*'")
# Where a tests census lists the test files that import AppKit (inside the copy, beside the target's folder).
APPKIT_IMPORTERS = "appkit-importers.txt"
# An AppKit import, which the census reads as UIKit.
APPKIT_IMPORT = re.compile(r"^(\s*(?:@preconcurrency\s+)?)import AppKit\s*$", re.MULTILINE)


def run(command, cwd=None, env=None, check=True):
    """Runs `command`, returning its completed process (output captured as text)."""
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, check=check)


def checkout_root():
    """The worktree (or main checkout) the script was started in."""
    return Path(run(["git", "rev-parse", "--show-toplevel"]).stdout.strip())


# What stands for the working tree where a commit is expected (see `--worktree`): the tracked and new files as they
# are on disk, whatever has been committed.
WORKTREE = ":worktree"


def file_at(repo, commit, path):
    """The text of `path` in `commit`, or in the working tree of `repo` when `commit` is WORKTREE."""
    if commit == WORKTREE:
        return (Path(repo) / path).read_text(encoding="utf-8")
    return run(["git", "-C", str(repo), "show", f"{commit}:{path}"]).stdout


def pinned_packages(repo, commit):
    """Each package's (location, revision), read from Package.resolved at `commit`."""
    resolved = json.loads(file_at(repo, commit, str(RESOLVED)))
    return {pin["identity"]: (pin["location"], pin["state"]["revision"]) for pin in resolved["pins"]}


def revision_of(folder):
    """The commit a package folder is checked out at, or None."""
    result = run(["git", "-C", str(folder), "rev-parse", "HEAD"], check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def prepare_packages(pkgs, pins, say):
    """Makes `pkgs` hold every package at its pinned revision: kept from an
    earlier run, copied from the checkouts `make build` keeps, or cloned."""
    pkgs.mkdir(parents=True, exist_ok=True)
    for identity, folder, name in PACKAGES:
        location, revision = pins[identity]
        target = pkgs / name
        if target.exists() and revision_of(target) == revision:
            continue
        if target.exists():
            shutil.rmtree(target)
        source = CHECKOUTS / folder
        if source.exists() and revision_of(source) == revision:
            shutil.copytree(source, target, symlinks=True)
        else:
            say(f"cloning {location} at {revision[:8]}")
            run(["git", "clone", "--quiet", location, str(target)])
            run(["git", "-C", str(target), "checkout", "--quiet", revision])


def listed_test_files(repo, commit, target=TEST_TARGET):
    """The Swift files that project.yml at `commit` lists, by path, among the sources of the test target `target`, in its
    order (the target's own folder is not a file and is not listed). For the Mac's hosted target they are the files of
    TextMouthTests/Sources/Tests; for the iPhone's unit target, the Mac tests' files it shares."""
    text = file_at(repo, commit, "project.yml")
    block = re.search(rf"^  {target}:\n(.*?)^    settings:", text, re.MULTILINE | re.DOTALL)
    if not block:
        raise RuntimeError(f"project.yml at {commit} has no {target} target")
    return re.findall(r"^      - (\S+\.swift)\s*$", block.group(1), re.MULTILINE)


def extract_worktree(repo, paths, src):
    """Copies the files of `repo`'s working tree that match `paths` (git pathspecs) into the folder `src`: the tracked
    files, and the new ones that .gitignore does not hide. A file that is tracked but was deleted on disk is left
    out, since it is no longer there."""
    listing = run(["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *paths])
    for name in sorted(set(filter(None, listing.stdout.split("\0")))):
        source = Path(repo) / name
        if source.is_file():
            target = src / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


def extract(repo, commit, paths, src):
    """Extracts `paths` (git pathspecs) of `commit` into the folder `src`; of the working tree when `commit` is WORKTREE."""
    if commit == WORKTREE:
        extract_worktree(repo, paths, src)
        return
    archive = subprocess.Popen(["git", "-C", str(repo), "archive", commit, *paths], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", str(src)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError(f"git archive {commit} failed")


def test_kind(tests):
    """The kind of test set a `tests` argument names: False for none, "mac" (True) for the Mac's hosted target compiled for
    the Mac, "ios" for the iPhone's unit target compiled for the iPhone, and "census" for every one of the Mac's test files
    compiled for the iPhone (to count which of them could run there)."""
    return "mac" if tests is True else tests


def test_names(kind):
    """(the SwiftPM test target's name and folder, the folder in it that holds the files listed by path, and the project.yml
    target that lists them) for a kind of test set (see test_kind)."""
    if kind == "ios":
        return IOS_TEST_TARGET, SHARED_TESTS_FOLDER, IOS_TEST_TARGET
    return TEST_TARGET, LISTED_TESTS_FOLDER, TEST_TARGET


def test_targets(kind):
    """The SwiftPM test targets a kind of test set builds, in order: the iPhone's unit target and then its interface-test
    target for "ios", and the one hosted target for the others. Each is its own `swift build --target`, so that an error in
    one does not hide the other's."""
    return [IOS_TEST_TARGET, IOS_UI_TEST_TARGET] if kind == "ios" else [test_names(kind)[0]]


def prepare_sources(repo, commit, src, census, tests=False):
    """Replaces `src` with the committed TextMouth/, Vendor/, TextMouthBraille/, and
    TextMouthFFmpeg/ folders at `commit` (or, when `commit` is WORKTREE, the working tree's tracked and new files); with `tests` (see test_kind), also the
    test target's Swift sources, gathered into one folder; in a census, reads AppKit
    imports as UIKit there. Returns how many imports the census rewrote."""
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    extract(repo, commit, ["TextMouth", "Vendor", "TextMouthBraille", "TextMouthFFmpeg"], src)
    kind = test_kind(tests)
    if kind:
        target, listed_folder, project_target = test_names(kind)
        listed = listed_test_files(repo, commit, project_target)
        # The target's own Swift files (the Mac's folder for a Mac or a census; the iPhone's for the iPhone's unit target).
        extract(repo, commit, [f":(glob){target}/**/*.swift", *listed], src)
        if kind == "census":
            # The census reports by area.
            extract(repo, commit, [testkit.AREAS_CONF], src)
        if kind == "ios":
            # The interface tests: Swift files only (the bundle's book and sample are resources, which a compile does not read).
            extract(repo, commit, [f":(glob){IOS_UI_TEST_TARGET}/**/*.swift"], src)
        # SwiftPM takes one folder per target, so the listed files are copied beside the rest.
        folder = src / listed_folder
        folder.mkdir(parents=True)
        for path in listed:
            shutil.copy2(src / path, folder / Path(path).name)
    rewritten = 0
    if kind == "census":
        # A test file that imports AppKit stops the compiler at "no such module", before it type-checks the other files, so
        # the census reads the import as UIKit and lists the files it changed: each needs an edit to run on the iPhone,
        # and what is left of its errors shows how much.
        importers = []
        for path in sorted((src / TEST_TARGET).rglob("*.swift")):
            new, count = APPKIT_IMPORT.subn(r"\1import UIKit", path.read_text(encoding="utf-8", errors="replace"))
            if count:
                path.write_text(new)
                importers.append(str(path.relative_to(src / TEST_TARGET)))
        (src / APPKIT_IMPORTERS).write_text("\n".join(importers) + "\n")
    if census:
        for path in (src / "TextMouth").rglob("*.swift"):
            text = path.read_text()
            new, count = APPKIT_IMPORT.subn(r"\1import UIKit", text)
            if count:
                path.write_text(new)
                rewritten += count
    return rewritten


# The String Catalog (FR34) in TextMouth/: the pack's source, no resource of either app since FR39 phase 8, which a Swift
# package would report as an unhandled file ("found 1 file(s) which are unhandled"). Only the file is left out, not its
# folder, since TextMouth/Localization/InterfaceText/ holds Swift sources (FR39).
LOCALIZATION_FOLDER = "Localization/Localizable.xcstrings"


def excluded_folders(src, platform):
    """The folders of TextMouth/ the platform does not compile, as the target's
    exclude list (only those that exist, so SwiftPM does not warn): the Mac's
    Resources, the other platform's folder, and the String Catalog's."""
    other = "macOS" if platform == "ios" else "iOS"
    candidates = ["Resources", LOCALIZATION_FOLDER, f"Platform/{other}"]
    return [c for c in candidates if (src / "TextMouth" / c).exists()]


def platform_test_flags(platform):
    """The compiler flags that let a test target find XCTest on `platform`: the platform's own Developer folder holds
    XCTest, which SwiftPM adds by itself only for the host's platform. Empty for the Mac."""
    if platform != "ios":
        return []
    folder = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-platform-path"]).stdout.strip()
    return ["-F", f"{folder}/Developer/Library/Frameworks", "-I", f"{folder}/Developer/usr/lib"]


# The empty folder each of the iPhone's braille C targets names as its public headers (see write_package).
NO_PUBLIC_HEADERS = "no-public-headers"
# The name of the iPhone package's C target that builds the braille library (see write_package): any name but the
# library's own module's, TextMouthBrailleLibrary, which SwiftPM's module of the target's name would clash with.
BRAILLE_LIBRARY_TARGET = "TextMouthBrailleC"

# The iPhone app links TextMouth's FFmpeg session (FMT54; project.yml's FFmpeg_iOS), whose C needs FFmpeg's own
# build, which only Xcode's FFmpeg_iOS target makes (Scripts/vendor/ffmpeg/build.py). So the iPhone's package links a
# stand-in for it instead: this C file, written into the copy, which includes the session's real header, so that
# each function is compiled against its declaration, and defines each one to fail at once. Nothing ever runs it:
# the type-check links an executable and runs nothing. test_typecheck.py checks that every function the header
# declares is here, so a new one is caught here rather than as a link error; the real session is compiled and
# linked by every iPhone build on GitHub.
FFMPEG_SESSION_STUB_TARGET = "TextMouthFFmpegSessionStub"
FFMPEG_SESSION_STUB_FOLDER = "TextMouthFFmpeg/typecheck-stub"
FFMPEG_SESSION_STUB = """\
/* Written by Scripts/ios/typecheck.py into its copy of the sources: a stand-in for TextMouth's FFmpeg session
   (TextMouthFFmpeg/Session/session.c), so that the iPhone's type-check links without FFmpeg's build. Every
   function fails at once, and nothing ever calls them: the type-check runs nothing. */
#include <stddef.h>
#include "TextMouthFFmpegProtocol.h"
#include "TextMouthFFmpegSession.h"

int tmff_session_prepare(void) { return 0; }

int tmff_session_cpu_features(void) { return 0; }

void tmff_set_allocation_cap(size_t bytes) { (void)bytes; }

int tmff_open_regular_file(const char *path) {
    (void)path;
    return -1;
}

tmff_session *tmff_session_open(int descriptor, const char *demuxer, tmff_session_mode mode, int *status) {
    return tmff_session_open_checked(descriptor, demuxer, mode, NULL, NULL, status);
}

tmff_session *tmff_session_open_checked(int descriptor, const char *demuxer, tmff_session_mode mode,
                                        tmff_stop_check check, void *context, int *status) {
    (void)descriptor;
    (void)demuxer;
    (void)mode;
    (void)check;
    (void)context;
    *status = TMFF_EXIT_USAGE;
    return NULL;
}

void tmff_session_set_stop_check(tmff_session *session, tmff_stop_check check, void *context) {
    (void)session;
    (void)check;
    (void)context;
}

int tmff_session_next(tmff_session *session, const unsigned char **bytes, size_t *length) {
    (void)session;
    *bytes = NULL;
    *length = 0;
    return TMFF_EXIT_USAGE;
}

void tmff_session_stop(tmff_session *session) { (void)session; }

void tmff_session_close(tmff_session *session) { (void)session; }

#ifdef DEBUG
int tmff_session_formcheck(char *out, size_t capacity) {
    if (capacity > 0) {
        out[0] = '\\0';
    }
    return TMFF_EXIT_USAGE;
}
#endif
"""


def write_package(src, pkgs, platform, ios_target, tests=False, skipped_tests=()):
    """Writes the probe's Package.swift into `src`; with `tests` (see test_kind), it also
    holds the test target. `skipped_tests` are files of the test target's folder (paths inside it) that the
    package leaves out: the census builds again without the files that did not compile."""
    kind = test_kind(tests)
    target, _listed_folder, _project_target = test_names(kind or "mac")
    # Non-Swift files the Mac's folder holds are left out (only those that exist, so SwiftPM does not warn), with the skipped files.
    left_out = [name for name in ("Info.plist", "performance-baselines.json", "performance-substitutions.json")
                if (src / target / name).exists()] + list(skipped_tests)
    skipped = ", ".join(f'"{name}"' for name in left_out)
    extra_flags = platform_test_flags(platform) if kind else []
    if kind == "census":
        # One compiler job for the whole test module reports the errors of every file at once: in the default batches a
        # failing batch stopped the others, so a build named one file in a hundred.
        extra_flags += ["-whole-module-optimization"]
    flags = "".join(f', "{flag}"' for flag in extra_flags)
    excludes = ", ".join(f'"{e}"' for e in excluded_folders(src, platform))
    # The braille helper's protocol and the FFmpeg helper's stream are header-only modules, found by their maps,
    # and so is the braille library's interface, whose map is in the folder named after its module there
    # (TextMouthBraille/include/TextMouthBrailleLibrary).
    # The system bzip2's module (Vendor/CBZip2/include), which the interface-text pack's reader imports, is found by its
    # map too.
    include_flags = (f'"-I", "{src / "Vendor" / "CBZip2" / "include"}", '
                     f'"-I", "{src / "TextMouthBraille" / "include"}", '
                     f'"-I", "{src / "TextMouthFFmpeg" / "include"}"')
    # The iPhone app links liblouis and TextMouth's braille translation, which its BrailleTranslator calls in its own
    # process (DR34; project.yml's liblouis_iOS and TextMouthBrailleLibrary_iOS); the Mac app links neither, since
    # its braille helper runs them. Neither target has public headers: each names an empty folder of the copy as
    # its public headers, since SwiftPM refuses a folder that is not there. SwiftPM still makes each a module of the
    # target's name, so the library's target is named BRAILLE_LIBRARY_TARGET, never TextMouthBrailleLibrary, the module
    # the app finds the library's interface by.
    # The FFmpeg session's stand-in (FFMPEG_SESSION_STUB) is the iPhone's too, with the same empty public headers.
    braille_dependencies = (f'\n                "liblouis",\n                "{BRAILLE_LIBRARY_TARGET}",'
                            f'\n                "{FFMPEG_SESSION_STUB_TARGET}",') if platform == "ios" else ""
    if platform == "ios":
        for target_folder in ("Vendor/liblouis", "TextMouthBraille", FFMPEG_SESSION_STUB_FOLDER):
            (src / target_folder / NO_PUBLIC_HEADERS).mkdir(parents=True, exist_ok=True)
        (src / FFMPEG_SESSION_STUB_FOLDER / "session_stub.c").write_text(FFMPEG_SESSION_STUB)
    braille_targets = f"""
        // liblouis, as project.yml's LiblouisLibrary template builds it.
        .target(
            name: "liblouis",
            path: "Vendor/liblouis",
            exclude: ["liblouis/liblouis.h.in", "tables"],
            sources: ["liblouis"],
            publicHeadersPath: "{NO_PUBLIC_HEADERS}",
            cSettings: [
                .define("LIBLOUIS_FOR_TEXTMOUTH", to: "1"),
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("liblouis"),
                .unsafeFlags(["-w", "-Os"]),
            ]
        ),
        // TextMouth's braille translation, as project.yml's TextMouthBrailleLibrary_iOS target builds it.
        .target(
            name: "{BRAILLE_LIBRARY_TARGET}",
            dependencies: ["liblouis"],
            path: "TextMouthBraille",
            exclude: ["main.c", "include"],
            sources: ["TextMouthBrailleLibrary.c"],
            publicHeadersPath: "{NO_PUBLIC_HEADERS}",
            cSettings: [.unsafeFlags(["-isystem", "{src / "Vendor" / "liblouis" / "include"}", "-Os"])]
        ),
        // A stand-in for TextMouth's FFmpeg session (FMT54), which project.yml's FFmpeg_iOS builds with FFmpeg:
        // each function of its real header, failing at once (typecheck.py's FFMPEG_SESSION_STUB).
        .target(
            name: "{FFMPEG_SESSION_STUB_TARGET}",
            path: "{FFMPEG_SESSION_STUB_FOLDER}",
            sources: ["session_stub.c"],
            publicHeadersPath: "{NO_PUBLIC_HEADERS}",
            cSettings: [.unsafeFlags(["-I", "{src / "TextMouthFFmpeg" / "include"}", "-Os"])]
        ),""" if platform == "ios" else ""
    test_target = f"""
        // The tests of the platform: compiled, never run.
        .testTarget(
            name: "{target}",
            dependencies: [
                "TextMouth",
                "LAME",
                "ObjCExceptionCatcher",
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "cmark-gfm", package: "cmark"),
                .product(name: "cmark-gfm-extensions", package: "cmark"),
            ],
            path: "{target}",
            exclude: [{skipped}],
            swiftSettings: [.unsafeFlags([{include_flags}, "-continue-building-after-errors"{flags}])]
        ),""" if kind else ""
    # The iPhone's interface tests drive the app from another process, so they link nothing of it: XCTest alone, found as the
    # unit tests find it. Only the iPhone's test kind holds them.
    ui_test_target = f"""
        // The iPhone's interface tests (XCUITest): compiled, never run.
        .testTarget(
            name: "{IOS_UI_TEST_TARGET}",
            path: "{IOS_UI_TEST_TARGET}",
            swiftSettings: [.unsafeFlags(["-continue-building-after-errors"{flags}])]
        ),""" if kind == "ios" else ""
    (src / "Package.swift").write_text(f"""// swift-tools-version: 6.0
// Written by Scripts/ios/typecheck.py: builds a copy of TextMouth's app sources
// for {platform}. Never run.
import PackageDescription

let package = Package(
    name: "TextMouthTypecheck",
    platforms: [.iOS("{ios_target}"), .macOS(.v14)],
    dependencies: [
        .package(path: "{pkgs / 'ZIPFoundation'}"),
        .package(path: "{pkgs / 'cmark'}"),
    ],
    targets: [
        // LAME's encoder, as project.yml's LAME target builds it.
        .target(
            name: "LAME",
            path: "Vendor/lame",
            sources: ["libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H", to: "1"),
                .headerSearchPath("."),
                .headerSearchPath("libmp3lame"),
                .unsafeFlags(["-w", "-Os"]),
            ]
        ),
        // SwiftSoup, vendored (Vendor/SwiftSoup), as project.yml's SwiftSoup
        // target builds it: one module, its warnings hidden.
        .target(
            name: "SwiftSoup",
            path: "Vendor/SwiftSoup/Sources",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        // The Objective-C exception catcher.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Vendor/ObjCExceptionCatcher",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),{braille_targets}
        // The app's sources, as one executable target so that its @main
        // compiles; the braille protocol's header module is found by its map.
        .executableTarget(
            name: "TextMouth",
            dependencies: [
                "LAME",
                "ObjCExceptionCatcher",{braille_dependencies}
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "cmark-gfm", package: "cmark"),
                .product(name: "cmark-gfm-extensions", package: "cmark"),
            ],
            path: "TextMouth",
            exclude: [{excludes}],
            swiftSettings: [.unsafeFlags([{include_flags}, "-continue-building-after-errors"])]
        ),{test_target}{ui_test_target}
    ],
    swiftLanguageModes: [.v6]
)
""")


def summarize(log_text, src, header, out, tests=False, origins=None, builds=1):
    """Writes errors.txt and summary.md into `out` from the build's log, and
    returns (summary text, error count, link failed, build succeeded). `origins`
    maps a listed test file's place in the copy (inside the test target's folder)
    to its repository path, which the diagnostics are shown under. `builds` is how many builds the log holds (one per test
    target): each must have finished for the run to succeed."""
    origins = origins or {}
    log_text = without_terminal_escapes(log_text)
    errors, warnings, package_problems = set(), set(), 0
    for line in log_text.splitlines():
        match = DIAGNOSTIC.match(line)
        if not match:
            continue
        path = Path(match.group(1))
        try:
            relative = str(path.resolve().relative_to(src.resolve()))
        except ValueError:
            # Outside the copy: one of the packages.
            if match.group(4) == "error":
                package_problems += 1
            continue
        if relative in origins:
            relative = origins[relative]
        elif relative.startswith(LISTED_TESTS_FOLDER + "/"):
            relative = f"{LISTED_TESTS_ORIGIN}/{relative[len(LISTED_TESTS_FOLDER) + 1:]}"
        if not relative.startswith(("TextMouth/", TEST_TARGET + "/", IOS_TEST_TARGET + "/", IOS_UI_TEST_TARGET + "/", LISTED_TESTS_ORIGIN + "/")):
            # The vendored C code builds with its warnings hidden; only its
            # errors would matter, and they count as the app's.
            if match.group(4) == "warning":
                continue
        entry = (relative, int(match.group(2)), int(match.group(3)), match.group(5))
        (errors if match.group(4) == "error" else warnings).add(entry)
    link_lines = [l for l in log_text.splitlines() if LINK_FAILURE.search(l)]
    # "Build complete!" ends a whole-package build; a build of one target (--tests) ends "Build of target: 'X' complete!".
    finished = "Build complete!" in log_text or len(re.findall(r"Build of target: '[^']*' complete!", log_text)) >= builds
    succeeded = bool(finished) and not errors
    ordered = sorted(errors)
    per_file = {}
    for entry in ordered:
        per_file[entry[0]] = per_file.get(entry[0], 0) + 1
    kinds = {}
    for entry in ordered:
        kind = QUOTED.sub("'X'", entry[3])
        kinds[kind] = kinds.get(kind, 0) + 1

    out.mkdir(parents=True, exist_ok=True)
    (out / "errors.txt").write_text("".join(f"{f}:{l}:{c}: error: {m}\n" for f, l, c, m in ordered))
    (out / "warnings.txt").write_text("".join(f"{f}:{l}:{c}: warning: {m}\n" for f, l, c, m in sorted(warnings)))
    lines = [header, "",
             f"- Result: {'BUILD SUCCEEDED' if succeeded else 'FAILED'}",
             f"- Errors in the app{' and its tests' if tests else ''}: **{len(ordered)}** in **{len(per_file)}** files",
             f"- Warnings in the app{' and its tests' if tests else ''}: {len(warnings)}",
             f"- Errors inside the Swift packages: {package_problems}",
             f"- Link: {'not attempted (the tests are compiled, not linked)' if tests else 'failed' if link_lines and not ordered else 'not reached' if ordered else 'ok' if succeeded else 'unknown'}",
             ""]
    if link_lines and not ordered:
        lines += ["## Linker", "", *[f"    {l}" for l in link_lines[:20]], ""]
    if per_file:
        lines += ["## Errors by file", "", *[f"- {f}: {n}" for f, n in sorted(per_file.items(), key=lambda i: (-i[1], i[0]))], ""]
        lines += ["## Kinds of error", "", *[f"- {n}: {k}" for k, n in sorted(kinds.items(), key=lambda i: -i[1])[:25]], ""]
    if warnings:
        lines += ["## Warnings", "", *[f"- {f}:{l}: {m}" for f, l, c, m in sorted(warnings)[:40]], ""]
    if not succeeded and not ordered and not link_lines:
        tail = log_text.splitlines()[-30:]
        lines += ["## The build's last lines (no error was recognized)", "", *[f"    {l}" for l in tail], ""]
    summary = "\n".join(lines)
    (out / "summary.md").write_text(summary + "\n")
    return summary, len(ordered), bool(link_lines), succeeded


# The most builds a tests census makes: each leaves out the files that did not compile in the one before, until a build is clean.
MAX_CENSUS_ROUNDS = 12
# How many distinct messages a census keeps for a file that does not compile.
MESSAGES_KEPT = 6
# A file that fails by more messages than this of its own counts as one that cannot run on the iPhone (fewer: could, with work).
FEW_MESSAGES = 5
# A name the compiler could not find, in a message.
CANNOT_FIND = re.compile(r"cannot find (?:type )?'([^']+)' in scope")
# A declaration, to learn which names a folder of the app declares.
DECLARATION = re.compile(r"\b(?:class|struct|enum|protocol|actor|typealias|func|var|let|case)\s+([A-Za-z_]\w*)")


def errors_by_test_file(log_text, src, target):
    """The build's errors that are in the test target's files, as {path inside the target's folder: [messages]}, each file's
    messages in order and without repeats; and how many errors there are in other files (the app's own, which make a
    census meaningless). A listed file is named by its copied name, in the folder of the files listed by path."""
    found, elsewhere = {}, 0
    for line in without_terminal_escapes(log_text).splitlines():
        match = DIAGNOSTIC.match(line)
        if not match or match.group(4) != "error":
            continue
        try:
            relative = str(Path(match.group(1)).resolve().relative_to((src / target).resolve()))
        except ValueError:
            elsewhere += 1
            continue
        messages = found.setdefault(relative, [])
        if match.group(5) not in messages:
            messages.append(match.group(5))
    return found, elsewhere


def names_declared_in_file(path):
    """The names declared (types, functions, variables, cases) in one Swift file, as a set."""
    return set(DECLARATION.findall(Path(path).read_text(encoding="utf-8", errors="replace")))


def names_declared_in(folder):
    """The names declared in the Swift files under `folder`, as a set."""
    names = set()
    for path in sorted(Path(folder).rglob("*.swift")):
        names |= names_declared_in_file(path)
    return names


def reason_for(round_number, messages, mac_names, skipped_names):
    """Why a test file did not compile for the iPhone, in a few words, from its messages and the round it first failed in:
    a file of round 1 fails by itself (AppKit, a type only the Mac's app has, or something else); a file of a later round
    fails because a file left out before it declared what it uses. `mac_names` are the names declared under
    TextMouth/Platform/macOS, `skipped_names` {a name: the file that declares it} for the files left out earlier."""
    missing = [CANNOT_FIND.search(m).group(1) for m in messages if CANNOT_FIND.search(m)]
    if messages and messages[0].startswith("no such module"):
        return "imports a module iOS lacks: " + ", ".join(re.findall(r"'([^']+)'", " ".join(messages))[:3])
    mac_only = [name for name in missing if name in mac_names or (name.startswith("NS") and name not in ("NSObject", "NSString"))]
    if mac_only:
        return "a Mac-only type (" + ", ".join(sorted(set(mac_only))[:3]) + ")"
    helpers = sorted({skipped_names[name] for name in missing if name in skipped_names})
    if helpers:
        return "needs " + ", ".join(helpers[:3]) + (", ..." if len(helpers) > 3 else "") + ", which does not compile"
    if round_number > 1:
        return "depends on a file left out earlier: " + messages[0][:80]
    return "other: " + messages[0][:100]


# An import line of a Swift file: its attributes, an optional kind (`import struct Foo.Bar`), and the module's dotted name.
IMPORT = re.compile(r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|func|typealias|protocol|var|let)\s+)?([A-Za-z_][\w.]*)", re.M)
# Modules every test file may import that are not the SDK's: the compiler is not asked about these.
KNOWN_MODULES = {"XCTest", "Testing", "TextMouth", "ZIPFoundation", "SwiftSoup", "cmark_gfm", "cmark_gfm_extensions", "LAME", "ObjCExceptionCatcher", "UIKit"}


def unavailable_imports(src, sdk, ios_target, say):
    """The test files that import a module the iPhone SDK lacks, as {file inside the target's folder: [modules]}. One
    missing module stops the compiler before it type-checks any other file, so the census finds them first, by asking the
    compiler about each distinct module once (a one-line file, `import Module`, type-checked for the iPhone)."""
    by_file = {}
    for path in sorted((src / TEST_TARGET).rglob("*.swift")):
        modules = {m for m in IMPORT.findall(path.read_text(encoding="utf-8", errors="replace")) if m.split(".")[0] not in KNOWN_MODULES}
        if modules:
            by_file[str(path.relative_to(src / TEST_TARGET))] = modules
    missing = set()
    probe = src.parent / "import-probe.swift"
    for module in sorted(set().union(*by_file.values()) if by_file else ()):
        probe.write_text(f"import {module}\n")
        answer = subprocess.run(["swiftc", "-typecheck", "-sdk", sdk, "-target", f"arm64-apple-ios{ios_target}", str(probe)],
                                capture_output=True, text=True, timeout=120)
        if answer.returncode != 0:
            missing.add(module)
    say(f"modules the iPhone SDK lacks: {', '.join(sorted(missing)) or 'none'}")
    return {name: sorted(modules & missing) for name, modules in by_file.items() if modules & missing}


def census_rows(result, src):
    """One row for each runnable class of the Mac's hosted tests: (name, its testkit record, status, reason), where status is
    "runs" (its file compiles for the iPhone and names nothing that makes sound), "could" (with more work: its file fails by
    FEW_MESSAGES or fewer of its own, depends on a file that does not compile, or names something that makes sound) or
    "cannot" (its file fails by more messages of its own), and reason says why for the last two."""
    classes = testkit.hosted_test_classes(src)
    skipped = result["skipped"]
    mac_names = names_declared_in(src / "TextMouth" / "Platform" / "macOS")
    declared_in_skipped = {}
    for relative in skipped:
        for name in names_declared_in_file(src / TEST_TARGET / relative):
            declared_in_skipped.setdefault(name, relative)
    importers = set((src / APPKIT_IMPORTERS).read_text().split())
    rows = []
    for name, info in sorted(classes.items()):
        if not info.runnable:
            continue
        relative = info.path.split("/", 1)[1]
        if relative in importers and relative not in skipped:
            # It compiles once AppKit is read as UIKit: only its import needs a guard.
            rows.append((name, info, "could", "imports AppKit, and nothing else of it fails (guard the import)"))
            continue
        if relative in skipped:
            record = skipped[relative]
            reason = reason_for(record["round"], record["messages"], mac_names, declared_in_skipped)
            if relative in importers:
                reason = "imports AppKit; " + reason
            few = record["round"] > 1 or len(record["messages"]) <= FEW_MESSAGES
            rows.append((name, info, "could" if few else "cannot", reason))
            continue
        found = ios_ui_tests.sound_in_source((src / TEST_TARGET / relative).read_text(encoding="utf-8", errors="replace"))
        rows.append((name, info, "could" if found else "runs", f"names something that makes sound: {found}" if found else ""))
    return rows


def census_report(result, src):
    """The tests census as Markdown, from `result` (see run_census) and the copy `src` of the sources it compiled: which of the
    Mac's hosted test classes compile for the iPhone and name nothing that makes sound, which could with more work, and which
    cannot, counted by area of Scripts/test/areas.conf, with each class's reason."""
    classes = testkit.hosted_test_classes(src)
    areas = testkit.parse_areas(src / testkit.AREAS_CONF)
    areas_of = {}
    for area in areas:
        for name in area.classes:
            areas_of.setdefault(name, []).append(area.name)
    rows = census_rows(result, src)
    totals = {key: [0, 0] for key in ("runs", "could", "cannot")}
    by_area = {}
    for name, info, status, _reason in rows:
        totals[status][0] += 1
        totals[status][1] += info.test_count
        for area in areas_of.get(name, ["(no area)"]):
            cell = by_area.setdefault(area, {key: [0, 0] for key in totals})
            cell[status][0] += 1
            cell[status][1] += info.test_count
    lines = [f"# The tests census: the Mac's hosted tests, compiled for the iPhone ({result['commit']})", "",
             f"{len(rows)} runnable classes with {sum(info.test_count for _, info, _, _ in rows)} tests, of {len(classes)} classes in "
             f"TextMouthProductionTests. {len(result['listed'])} more files, listed by path in project.yml (the legacy "
             f"scenario files), are compiled with them and not counted here.", "",
             "A class **runs** when its file compiles for the iPhone and names nothing that makes sound. It **could** with more "
             f"work when its file fails by {FEW_MESSAGES} messages or fewer of its own (fence a test, fake a service), depends on a "
             "file that does not compile, or names something that makes sound (a reviewed exception may be possible). It "
             f"**cannot** when its file fails by more than {FEW_MESSAGES} messages of its own.", "",
             f"Builds: {len(result['rounds'])} (each leaves out the files that failed in the one before); "
             f"the last one {'succeeded' if result['ok'] else 'FAILED'}.", "",
             "| Status | Classes | Tests |", "| --- | ---: | ---: |"]
    for key, label in (("runs", "Runs on the iPhone"), ("could", "Could, with more work"), ("cannot", "Cannot")):
        lines.append(f"| {label} | {totals[key][0]} | {totals[key][1]} |")
    lines += ["", "## By area (classes / tests)", "", "| Area | Runs | Could | Cannot |", "| --- | ---: | ---: | ---: |"]
    for area in [a.name for a in areas] + ["(no area)"]:
        if area in by_area:
            cell = by_area[area]
            lines.append(f"| {area} | {cell['runs'][0]} / {cell['runs'][1]} | {cell['could'][0]} / {cell['could'][1]} | "
                         f"{cell['cannot'][0]} / {cell['cannot'][1]} |")
    lines += ["", "## Reasons", ""]
    reasons = {}
    for name, info, status, reason in rows:
        if reason:
            # The reason without its detail in parentheses or after a colon, so that like reasons are counted together.
            key = re.split(r" \(|: ", reason)[0] if reason.startswith(("a Mac-only", "depends", "other", "names something", "imports AppKit", "imports a module")) else "needs a file that does not compile"
            cell = reasons.setdefault(key, [0, 0])
            cell[0] += 1
            cell[1] += info.test_count
    for key, (count, tests) in sorted(reasons.items(), key=lambda item: -item[1][0]):
        lines.append(f"- {key}: {count} classes, {tests} tests")
    lines += ["", "## Every class that does not run", "", "| Class | Tests | Status | Why | File |", "| --- | ---: | --- | --- | --- |"]
    for name, info, status, reason in rows:
        if status != "runs":
            lines.append(f"| {name} | {info.test_count} | {status} | {reason.replace('|', '/')} | {info.path.split('/', 1)[1]} |")
    return "\n".join(lines) + "\n"


def run_census(build, src, say, out=None, unavailable=None):
    """Builds the Mac's whole test target for the iPhone again and again, each time without the files that failed in the
    build before, until one build is clean (at most MAX_CENSUS_ROUNDS). `build(skipped)` writes the package without the
    `skipped` files of the target's folder, builds, and returns the build's log. Returns {"rounds": [{file: messages}],
    "skipped": {file: {"round": n, "messages": [...]}}, "compiles": [files], "listed": [files listed by path], "ok":
    whether the last build was clean, "log": the last log}."""
    everything = sorted(str(path.relative_to(src / TEST_TARGET)) for path in (src / TEST_TARGET).rglob("*.swift"))
    # Files that import a module the iPhone lacks are left out before the first build, which would stop at the first of them.
    skipped = {name: {"round": 1, "messages": [f"no such module '{m}' on iOS" for m in modules]}
               for name, modules in (unavailable or {}).items()}
    rounds, log_text, ok = [], "", False
    for number in range(1, MAX_CENSUS_ROUNDS + 1):
        say(f"census build {number}: {len(everything) - len(skipped)} of {len(everything)} test files")
        log_text = build(sorted(skipped))
        if out is not None:
            (out / f"build-round-{number}.log").write_text(log_text)
        found, elsewhere = errors_by_test_file(log_text, src, TEST_TARGET)
        rounds.append({name: messages[:MESSAGES_KEPT] for name, messages in found.items()})
        if elsewhere or not found:
            # Errors in the app itself make the counts meaningless; no error at all means the build is clean (or stopped
            # for a reason the log shows).
            ok = not elsewhere and bool(re.search(r"Build of target: '[^']*' complete!|Build complete!", log_text))
            break
        for name, messages in found.items():
            skipped[name] = {"round": number, "messages": messages[:MESSAGES_KEPT]}
    listed = sorted(name for name in everything if name.startswith("_ListedInProjectYml/"))
    compiles = [name for name in everything if name not in skipped]
    return {"rounds": rounds, "skipped": skipped, "compiles": compiles, "listed": listed, "ok": ok, "log": log_text}


def main(argv):
    """Parses the command line, then copies, builds, and summarizes."""
    parser = argparse.ArgumentParser(prog="typecheck.py", description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=["ios", "macos"], default="ios")
    parser.add_argument("--census", action="store_true", help="read import AppKit as import UIKit (iOS only)")
    parser.add_argument("--tests", action="store_true",
                        help="also compile the test target of the platform: the Mac's hosted tests (macOS), or the iPhone's unit "
                             "tests with the Mac test files they share (iOS)")
    parser.add_argument("--tests-census", action="store_true",
                        help="compile every file of the Mac's hosted tests for the iPhone, leaving out those that fail until a build "
                             "is clean, and write census.md (iOS only)")
    # The tree to check: a commit (the default, HEAD) or the working tree, never both.
    tree_choice = parser.add_mutually_exclusive_group()
    tree_choice.add_argument("--ref", default="HEAD", help="the commit to check (committed work only)")
    tree_choice.add_argument("--worktree", action="store_true",
                             help="check the working tree's tracked and new files instead of a commit (uncommitted work too)")
    parser.add_argument("--agent", default=os.environ.get("BBS_AGENT", "someone"), help="who runs it, for the lock and the results' folder")
    # Three hours, as run_locked.py waits: since November 8, 2026 heavy jobs run strictly one
    # after the other, with an hourly train first in line, so a wait of an hour could run out.
    parser.add_argument("--wait", type=float, default=180, help="minutes to wait for the heavy-work lock")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--ios-target", default="26.0")
    parser.add_argument("--no-lock", action="store_true", help="for a caller that already holds the lock (the build train)")
    parser.add_argument("--quiet", action="store_true", help="print only the summary")
    args = parser.parse_args(argv)
    if args.census and args.platform != "ios":
        parser.error("--census is for --platform ios")
    if args.tests_census and (args.platform != "ios" or args.census or args.tests):
        parser.error("--tests-census is for --platform ios, without --census or --tests")
    if args.tests and args.census:
        parser.error("--tests cannot be combined with --census")
    # What the test set is: the Mac's hosted target on the Mac, the iPhone's unit target on the iPhone, or the Mac's whole
    # target on the iPhone (the census).
    tests = "census" if args.tests_census else (("ios" if args.platform == "ios" else True) if args.tests else False)

    def say(text):
        if not args.quiet:
            print(f"typecheck: {text}", flush=True)

    repo = checkout_root()
    # `tree` says where the files come from (a commit's short name, or WORKTREE); `commit` names the run: the commit's
    # short name, or HEAD's with "-wt" for the working tree (whose files may differ from it).
    tree = WORKTREE
    try:
        commit = run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD" if args.worktree else args.ref]).stdout.strip()
        if args.worktree:
            commit += "-wt"
        else:
            tree = commit
        pins = pinned_packages(repo, tree)
    except (subprocess.CalledProcessError, OSError) as error:
        print(f"typecheck: cannot read {'the working tree' if args.worktree else args.ref}: "
              f"{getattr(error, 'stderr', None) or error}", file=sys.stderr)
        return 2
    mode = ("census" if args.census else "tests-census" if args.tests_census else "tests" if args.tests
            else "strict")
    # The packages are shared by every mode of a platform; each mode builds in a folder of its own (the strict check keeps
    # the plain one, so that a test run, which recompiles more, never undoes its incremental build).
    pkgs = WORK_ROOT / args.platform / "pkgs"
    work = WORK_ROOT / (f"{args.platform}-{mode}" if tests else args.platform)
    stamp = datetime.datetime.now().strftime("%m%d-%H%M%S")
    out = RESULTS / f"{re.sub(r'[^A-Za-z0-9_-]', '_', args.agent)}-{args.platform}-{mode}-{commit}-{stamp}"

    def waiting(owner):
        say(f"waiting for the heavy-work lock, held by {owner.get('name', '?') if owner else '?'} "
            f"since {owner.get('since', '?') if owner else '?'}; "
            f"{heavy_lock.describe_wait(owner) if owner else 'next in line'}")

    taken = True
    if not args.no_lock:
        taken = heavy_lock.acquire(f"typecheck {args.agent} {args.platform}", args.wait * 60, waiting)
        if not taken:
            print(f"typecheck: the heavy-work lock stayed busy for {args.wait:g} minutes; try again later", file=sys.stderr)
            return 3
    try:
        say(f"{args.platform} {mode} check of {commit} from {repo}")
        prepare_packages(pkgs, pins, say)
        src = work / "src"
        rewritten = prepare_sources(repo, tree, src, args.census, tests)
        sdk = run(["xcrun", "--sdk", "iphoneos" if args.platform == "ios" else "macosx", "--show-sdk-path"]).stdout.strip()
        command = ["swift", "build", "--sdk", sdk, "-j", str(args.jobs), "--scratch-path", str(work / "spm")]
        if args.platform == "ios":
            command += ["--triple", f"arm64-apple-ios{args.ios_target}"]
        # One build command for each test target (see test_targets), or the one plain build.
        commands = [command]
        if tests:
            # Only a test target's module (and the app it needs) is built: SwiftPM's last step for
            # --build-tests (which cannot be combined with --target), the synthesized test-runner module, stops on "unexpected input file:
            # .../plugins/testing" with this Xcode's toolchain after every file has compiled, so
            # nothing is linked. The iPhone's two bundles are two builds, one after the other, so that an error in the
            # first does not hide the second's.
            # A census adds --disable-index-store: indexing fails with one whole-module job ("index output filenames do not
            # match input source files").
            extra = ["--disable-index-store"] if tests == "census" else []
            commands = [command + ["--target", name, *extra] for name in test_targets(test_kind(tests))]

        def build(skipped=()):
            """Writes the package (without the `skipped` test files), builds each target, and returns the logs' text, joined."""
            write_package(src, pkgs, args.platform, args.ios_target, tests, skipped)
            say("building (about two minutes for the app alone)")
            logs = []
            for one in commands:
                built = subprocess.run(one, cwd=src, capture_output=True, text=True,
                                       env={**os.environ, "SWIFTCI_USE_LOCAL_DEPS": "1"})
                logs.append(built.stdout + built.stderr)
            return "\n".join(logs)

        out.mkdir(parents=True, exist_ok=True)
        if args.tests_census:
            unavailable = unavailable_imports(src, sdk, args.ios_target, say)
            result = run_census(build, src, say, out, unavailable)
            log_text = result.pop("log")
            result["commit"] = commit
            (out / "census.json").write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
            (out / "census.md").write_text(census_report(result, src))
            say(f"the census is in {out}/census.md")
        else:
            log_text = build()
        (out / "build.log").write_text(log_text)
        header = (f"# {args.platform} {mode} check of {commit} ({args.agent}, {stamp})"
                  + (f"\n\nThe census read {rewritten} AppKit imports as UIKit." if args.census else ""))
        origins = {}
        if tests:
            _target, listed_folder, project_target = test_names(test_kind(tests))
            origins = {f"{listed_folder}/{Path(path).name}": path for path in listed_test_files(repo, tree, project_target)}
        summary, count, _link_failed, succeeded = summarize(log_text, src, header, out, bool(tests), origins, len(commands))
    finally:
        if taken and not args.no_lock:
            heavy_lock.release()
    print(summary)
    print(f"\nWritten: {out}/summary.md, errors.txt, warnings.txt, build.log")
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
