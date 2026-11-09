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
catcher), so a clean run means the app compiles and links.

With `--tests` (macOS only) the package also holds the Mac's hosted test target,
TextMouthProductionTests, built with `swift build --build-tests`, so a test file
that does not compile is found without xcodebuild. The target's sources are the
folder of that name plus the files of TextMouthTests/Sources/Tests that
project.yml lists for it (read from project.yml at the commit, so the two cannot
drift apart); errors in those files are reported under their repository paths.
It compiles the tests and the app, and links the test bundle, but runs nothing.
Do this before asking the build train for a build.

The census (`--census`, iOS only) reads `import AppKit` as `import UIKit` in
the copy, so that every AppKit name a file uses is reported, instead of the
file stopping at one "no such module" error. It is for counting what is left;
the strict run (the default) is what the iOS app must pass.

Every run takes the Mac's heavy-work lock first (Scripts/agents/heavy_lock.py),
which the build train takes too, so no two heavy jobs ever run at once. A run
takes about two minutes. Its results go to the main checkout's gitignored
build/typecheck/results/, one folder per run: summary.md and errors.txt.

Usage:
  typecheck.py [--platform ios|macos] [--census | --tests] [--ref REF] [--agent SLUG]
               [--wait MINUTES] [--jobs N] [--no-lock] [--quiet]
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

# The main checkout, which holds the package checkouts, the lock, and the
# results, whichever worktree runs the script.
MAIN = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth")
WORK_ROOT = MAIN / "build" / "typecheck"
RESULTS = WORK_ROOT / "results"
CHECKOUTS = MAIN / "build" / "DerivedData" / "SourcePackages" / "checkouts"
RESOLVED = Path("TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

# The heavy-work lock, shared with the build train: Scripts/agents/heavy_lock.py
# beside this script's own folder (python3 -I leaves both out of sys.path).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agents"))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)

# The hosted test target of project.yml, and the folder of the copy that holds the
# files project.yml lists for it from TextMouthTests/Sources/Tests (one SwiftPM
# target takes one folder). Diagnostics in that folder are shown under the
# files' repository paths.
TEST_TARGET = "TextMouthProductionTests"
LISTED_TESTS_FOLDER = f"{TEST_TARGET}/_ListedInProjectYml"
LISTED_TESTS_ORIGIN = "TextMouthTests/Sources/Tests"

# Each package: its identity in Package.resolved, its checkout's folder name,
# and the folder name the probe gives it. swift-markdown finds cmark at
# ../cmark when SWIFTCI_USE_LOCAL_DEPS is set, which keeps the build off the
# network.
PACKAGES = [
    ("zipfoundation", "ZIPFoundation", "ZIPFoundation"),
    ("swiftsoup", "SwiftSoup", "SwiftSoup"),
    ("swift-markdown", "swift-markdown", "swift-markdown"),
    ("swift-cmark", "swift-cmark", "cmark"),
]

# One compiler diagnostic: an absolute path to a source file, its line and
# column, the kind, and the message.
DIAGNOSTIC = re.compile(r"^(/\S+\.(?:swift|c|h|m)):(\d+):(\d+): (error|warning): (.*)$")
# The linker's own failures, which name no source line.
LINK_FAILURE = re.compile(r"(^ld: |Undefined symbols|linker command failed|error: link command failed)")
# A quoted name inside a message, folded to 'X' to group messages by kind.
QUOTED = re.compile(r"'[^']*'")
# An AppKit import, which the census reads as UIKit.
APPKIT_IMPORT = re.compile(r"^(\s*(?:@preconcurrency\s+)?)import AppKit\s*$", re.MULTILINE)


def run(command, cwd=None, env=None, check=True):
    """Runs `command`, returning its completed process (output captured as text)."""
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, check=check)


def checkout_root():
    """The worktree (or main checkout) the script was started in."""
    return Path(run(["git", "rev-parse", "--show-toplevel"]).stdout.strip())


def pinned_packages(repo, commit):
    """Each package's (location, revision), read from Package.resolved at `commit`."""
    resolved = json.loads(run(["git", "-C", str(repo), "show", f"{commit}:{RESOLVED}"]).stdout)
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


def listed_test_files(repo, commit):
    """The files of TextMouthTests/Sources/Tests that project.yml at `commit` lists
    as sources of the hosted test target, in its order."""
    text = run(["git", "-C", str(repo), "show", f"{commit}:project.yml"]).stdout
    block = re.search(rf"^  {TEST_TARGET}:\n(.*?)^    settings:", text, re.MULTILINE | re.DOTALL)
    if not block:
        raise RuntimeError(f"project.yml at {commit} has no {TEST_TARGET} target")
    return re.findall(rf"^      - ({re.escape(LISTED_TESTS_ORIGIN)}/\S+\.swift)\s*$", block.group(1), re.MULTILINE)


def extract(repo, commit, paths, src):
    """Extracts `paths` (git pathspecs) of `commit` into the folder `src`."""
    archive = subprocess.Popen(["git", "-C", str(repo), "archive", commit, *paths], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", str(src)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait() != 0:
        raise RuntimeError(f"git archive {commit} failed")


def prepare_sources(repo, commit, src, census, tests=False):
    """Replaces `src` with the committed TextMouth/, Vendor/, and
    TextMouthBraille/ folders at `commit`; with `tests`, also the hosted test
    target's Swift sources, gathered into one folder; in a census, reads AppKit
    imports as UIKit there. Returns how many imports the census rewrote."""
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    extract(repo, commit, ["TextMouth", "Vendor", "TextMouthBraille"], src)
    if tests:
        listed = listed_test_files(repo, commit)
        extract(repo, commit, [f":(glob){TEST_TARGET}/**/*.swift", *listed], src)
        # SwiftPM takes one folder per target, so the listed files are copied beside the rest.
        folder = src / LISTED_TESTS_FOLDER
        folder.mkdir(parents=True)
        for path in listed:
            shutil.copy2(src / path, folder / Path(path).name)
    rewritten = 0
    if census:
        for path in (src / "TextMouth").rglob("*.swift"):
            text = path.read_text()
            new, count = APPKIT_IMPORT.subn(r"\1import UIKit", text)
            if count:
                path.write_text(new)
                rewritten += count
    return rewritten


def excluded_folders(src, platform):
    """The folders of TextMouth/ the platform does not compile, as the target's
    exclude list (only those that exist, so SwiftPM does not warn)."""
    other = "macOS" if platform == "ios" else "iOS"
    candidates = ["Resources", f"Platform/{other}"]
    return [c for c in candidates if (src / "TextMouth" / c).exists()]


def write_package(src, pkgs, platform, ios_target, tests=False):
    """Writes the probe's Package.swift into `src`; with `tests`, it also
    holds the hosted test target."""
    excludes = ", ".join(f'"{e}"' for e in excluded_folders(src, platform))
    # The braille helper's protocol is a header-only module, found by its map.
    include_flags = f'"-I", "{src / "TextMouthBraille" / "include"}"'
    test_target = f"""
        // The Mac's hosted tests: compiled and linked, never run.
        .testTarget(
            name: "{TEST_TARGET}",
            dependencies: [
                "TextMouth",
                "LAME",
                "ObjCExceptionCatcher",
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "{TEST_TARGET}",
            swiftSettings: [.unsafeFlags([{include_flags}, "-continue-building-after-errors"])]
        ),""" if tests else ""
    (src / "Package.swift").write_text(f"""// swift-tools-version: 6.0
// Written by Scripts/ios/typecheck.py: builds a copy of TextMouth's app sources
// for {platform}. Never run.
import PackageDescription

let package = Package(
    name: "TextMouthTypecheck",
    platforms: [.iOS("{ios_target}"), .macOS(.v14)],
    dependencies: [
        .package(path: "{pkgs / 'ZIPFoundation'}"),
        .package(path: "{pkgs / 'SwiftSoup'}"),
        .package(path: "{pkgs / 'swift-markdown'}"),
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
        // The Objective-C exception catcher.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Vendor/ObjCExceptionCatcher",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // The app's sources, as one executable target so that its @main
        // compiles; the braille protocol's header module is found by its map.
        .executableTarget(
            name: "TextMouth",
            dependencies: [
                "LAME",
                "ObjCExceptionCatcher",
                "ZIPFoundation",
                "SwiftSoup",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "TextMouth",
            exclude: [{excludes}],
            swiftSettings: [.unsafeFlags([{include_flags}, "-continue-building-after-errors"])]
        ),{test_target}
    ],
    swiftLanguageModes: [.v6]
)
""")


def summarize(log_text, src, header, out, tests=False):
    """Writes errors.txt and summary.md into `out` from the build's log, and
    returns (summary text, error count, link failed, build succeeded)."""
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
        if relative.startswith(LISTED_TESTS_FOLDER + "/"):
            relative = f"{LISTED_TESTS_ORIGIN}/{relative[len(LISTED_TESTS_FOLDER) + 1:]}"
        if not relative.startswith(("TextMouth/", TEST_TARGET + "/", LISTED_TESTS_ORIGIN + "/")):
            # The vendored C code builds with its warnings hidden; only its
            # errors would matter, and they count as the app's.
            if match.group(4) == "warning":
                continue
        entry = (relative, int(match.group(2)), int(match.group(3)), match.group(5))
        (errors if match.group(4) == "error" else warnings).add(entry)
    link_lines = [l for l in log_text.splitlines() if LINK_FAILURE.search(l)]
    succeeded = "Build complete!" in log_text and not errors
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
             f"- Link: {'failed' if link_lines and not ordered else 'not reached' if ordered else 'ok' if succeeded else 'unknown'}",
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


def main(argv):
    """Parses the command line, then copies, builds, and summarizes."""
    parser = argparse.ArgumentParser(prog="typecheck.py", description=__doc__.splitlines()[0])
    parser.add_argument("--platform", choices=["ios", "macos"], default="ios")
    parser.add_argument("--census", action="store_true", help="read import AppKit as import UIKit (iOS only)")
    parser.add_argument("--tests", action="store_true",
                        help="also compile and link the Mac's hosted test target, TextMouthProductionTests (macOS only)")
    parser.add_argument("--ref", default="HEAD", help="the commit to check (committed work only)")
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
    if args.tests and (args.platform != "macos" or args.census):
        parser.error("--tests is for --platform macos, without --census")

    def say(text):
        if not args.quiet:
            print(f"typecheck: {text}", flush=True)

    repo = checkout_root()
    try:
        commit = run(["git", "-C", str(repo), "rev-parse", "--short", args.ref]).stdout.strip()
        pins = pinned_packages(repo, commit)
    except subprocess.CalledProcessError as error:
        print(f"typecheck: cannot read {args.ref}: {error.stderr.strip()}", file=sys.stderr)
        return 2
    mode = "census" if args.census else "tests" if args.tests else "strict"
    # The packages are shared by every mode of a platform; each mode builds in a folder of its own.
    pkgs = WORK_ROOT / args.platform / "pkgs"
    work = WORK_ROOT / (f"{args.platform}-tests" if args.tests else args.platform)
    stamp = datetime.datetime.now().strftime("%m%d-%H%M%S")
    out = RESULTS / f"{re.sub(r'[^A-Za-z0-9_-]', '_', args.agent)}-{args.platform}-{mode}-{commit}-{stamp}"

    def waiting(owner):
        say(f"waiting for the heavy-work lock, held by {owner.get('name', '?') if owner else '?'} "
            f"since {owner.get('since', '?') if owner else '?'}")

    taken = True
    if not args.no_lock:
        taken = heavy_lock.acquire(f"typecheck {args.agent} {args.platform}", args.wait * 60, waiting)
        if not taken:
            print(f"typecheck: the heavy-work lock stayed busy for {args.wait:g} minutes; try again later", file=sys.stderr)
            return 3
    try:
        say(f"{args.platform} {mode} check of {commit} from {repo}")
        prepare_packages(pkgs, pins, say)
        rewritten = prepare_sources(repo, commit, work / "src", args.census, args.tests)
        write_package(work / "src", pkgs, args.platform, args.ios_target, args.tests)
        sdk = run(["xcrun", "--sdk", "iphoneos" if args.platform == "ios" else "macosx", "--show-sdk-path"]).stdout.strip()
        command = ["swift", "build", "--sdk", sdk, "-j", str(args.jobs), "--scratch-path", str(work / "spm")]
        if args.platform == "ios":
            command += ["--triple", f"arm64-apple-ios{args.ios_target}"]
        if args.tests:
            command += ["--build-tests"]
        say("building (about two minutes for the app alone)")
        result = subprocess.run(command, cwd=work / "src", capture_output=True, text=True,
                                env={**os.environ, "SWIFTCI_USE_LOCAL_DEPS": "1"})
        log_text = result.stdout + result.stderr
        out.mkdir(parents=True, exist_ok=True)
        (out / "build.log").write_text(log_text)
        header = (f"# {args.platform} {mode} check of {commit} ({args.agent}, {stamp})"
                  + (f"\n\nThe census read {rewritten} AppKit imports as UIKit." if args.census else ""))
        summary, count, _link_failed, succeeded = summarize(log_text, work / "src", header, out, args.tests)
    finally:
        if taken and not args.no_lock:
            heavy_lock.release()
    print(summary)
    print(f"\nWritten: {out}/summary.md, errors.txt, warnings.txt, build.log")
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
