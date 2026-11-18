"""runner_module_cache.py: keeps a GitHub runner's restored module caches from outliving the toolchain that made them.

The workflow restores each build's derived-data folder from GitHub's cache, so that a build compiles only what changed.
That folder holds Clang's module caches: precompiled modules (.pcm files) that record the modification time of every
file they were built from, among them the toolchain's own `module.modulemap`. GitHub rolls a new macOS image out over
days, and the same job can land on the old image or the new one. A new image's toolchain files have new times, so a
cache made on the other image fails the build with, for example (train 1116-1349, November 16, 2026):

    error: Clang dependency scanner failure: fatal error: file '.../usr/lib/swift/clang/include/module.modulemap'
    has been modified since the module file '.../ModuleCache.noindex/.../_Builtin_stdbool-....pcm' was built:
    mtime changed (was 1793595417, now 1794497068)

That error names no file of the repository, and it comes back at every image change, in either direction.

This module is the cure, in two parts, which the scripts the workflow calls share (run-ios-build.py,
run-on-runner.py):

  prepare(...)               before a build: writes a stamp of the toolchain (the runner image's version, `xcodebuild
                             -version`, and the time of the toolchain's module.modulemap) into the derived-data
                             folder, and when the folder holds no stamp or a different one, empties the module caches
                             first. Everything else the build can reuse stays: the compiled objects, the build
                             database, the package checkouts. This is not a clean build.
  empty_module_caches(...)   what the retry does when a build still fails with the error above.

The stamp lives inside the derived-data folder, so it is saved and restored with the cache and describes the toolchain
that built what is in the folder.

Everything here deletes only inside the derived-data folder it is given, and only the folders named in CACHE_FOLDERS.
`prepare` does nothing anywhere but on a GitHub Actions runner (GITHUB_ACTIONS is "true" there and nowhere else),
as runner_settings.py does.

Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The stamp's file name, inside the derived-data folder.
STAMP_NAME = "toolchain-stamp.json"
# The folders of a derived-data folder that hold modules built against the toolchain, each relative to it:
#   ModuleCache.noindex                                  Clang's implicit module cache (the failing one of train 1116-1349)
#   SDKStatCaches.noindex                                the SDK's stat caches, which record file times too
#   Build/Intermediates.noindex/ExplicitPrecompiledModules   the modules Xcode 26 builds explicitly for each target
#   Build/Intermediates.noindex/PrecompiledHeaders       precompiled headers, which embed the modules they were built with
#   Build/Intermediates.noindex/SwiftExplicitPrecompiledModules   the .pcm files Xcode 26's Swift driver builds explicitly
#                                                        for each module a target imports: the SDK's and toolchain's (a new
#                                                        toolchain makes them stale) and the repository's own (TextMouthBraille's
#                                                        module.modulemap changing in size left train 1116-2122's iPhone build
#                                                        failing on both tries, since this folder was not emptied)
# Xcode makes each again when it is missing, and the build database re-runs a step whose output is gone.
CACHE_FOLDERS = ("ModuleCache.noindex", "SDKStatCaches.noindex",
                 "Build/Intermediates.noindex/ExplicitPrecompiledModules",
                 "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules",
                 "Build/Intermediates.noindex/PrecompiledHeaders")
# Where the toolchain's module.modulemap is, inside the developer directory (DEVELOPER_DIR, as the workflow selects Xcode).
MODULEMAP_IN_DEVELOPER_DIR = "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include/module.modulemap"
# The words of Clang's error for a module built before a file changed. A log holding it failed for the cache, not for the code.
STALE_MARKER = "has been modified since the module file"
# The other failure of a restored cache: a precompiled module the build database still claims is not on disk (hand runs
# 44025566537 and 44039539045, train 1117-1219, and a race in TextMouthBrailleLibrary.c in train 1117-0527), which Clang
# words "fatal error: module file '.../_Builtin_stddef-....pcm' not found". "No such module 'X'" (a real import error) and
# "module 'X' not found" do not match: the words "module file" or a ".pcm" must come before "not found".
MISSING_MODULE = re.compile(r"(?:module file|\.pcm)[^\n]*not found")
# What a retry's note and a summary call the missing-module failure, as STALE_MARKER names the stale one.
MISSING_MARKER = "module file ... not found"
# What a train's summary says when the iPhone build's only errors are a cache failure (either kind).
STALE_SENTENCE = ("the runner's module cache failed the build (it was stale, made on another runner image, or lacked a module "
                  "its build database claims), not this branch's code; nothing to fix in any file")
# How long a call to xcodebuild or xcode-select may take, in seconds.
CALL_SECONDS = 60


def on_github_runner(environment):
    """Whether `environment` is a step of a GitHub Actions run: GITHUB_ACTIONS is exactly "true" there."""
    return environment.get("GITHUB_ACTIONS") == "true"


def run_text(command, run=subprocess.run):
    """What `command` prints, with its lines and runs of spaces joined into single spaces, or None when it cannot run,
    fails, or prints nothing."""
    try:
        result = run(command, capture_output=True, text=True, timeout=CALL_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return None
    words = " ".join((result.stdout or "").split()) if result.returncode == 0 else ""
    return words or None


def xcodebuild_version(run=subprocess.run):
    """What `xcodebuild -version` prints, as one line ("Xcode 26.0.1 Build version 17A400"), or None."""
    return run_text(["xcodebuild", "-version"], run)


def developer_dir(environment, run=subprocess.run):
    """The developer directory the build uses: DEVELOPER_DIR (the workflow's Xcode step sets it), else what
    `xcode-select -p` prints, else None."""
    chosen = environment.get("DEVELOPER_DIR") or run_text(["xcode-select", "-p"], run)
    return Path(chosen) if chosen else None


def modulemap_mtime(environment, run=subprocess.run):
    """The modification time, in whole seconds, of the toolchain's module.modulemap, or None when it cannot be read.
    This is the very value Clang compares (the error's "now 1794497068")."""
    directory = developer_dir(environment, run)
    if directory is None:
        return None
    try:
        return int((directory / MODULEMAP_IN_DEVELOPER_DIR).stat().st_mtime)
    except OSError:
        return None


def current_stamp(environment, run=subprocess.run):
    """The toolchain this process builds with, as a dictionary of three facts, each None when it is not known: the runner
    image's version (GitHub sets ImageVersion), `xcodebuild -version`, and the time of the toolchain's module.modulemap."""
    return {"image_version": environment.get("ImageVersion") or None,
            "xcodebuild_version": xcodebuild_version(run),
            "modulemap_mtime": modulemap_mtime(environment, run)}


def read_stamp(derived):
    """The stamp in the derived-data folder `derived`, or None when there is none or it cannot be read."""
    try:
        stamp = json.loads((Path(derived) / STAMP_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return stamp if isinstance(stamp, dict) else None


def write_stamp(derived, stamp):
    """Writes `stamp` into the derived-data folder, making the folder if it is not there yet."""
    Path(derived).mkdir(parents=True, exist_ok=True)
    (Path(derived) / STAMP_NAME).write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def stamp_known(stamp):
    """Whether the stamp says anything: a stamp of three unknowns cannot vouch for a cache, so it never matches."""
    return any(value is not None for value in stamp.values())


def empty_module_caches(derived, say=print):
    """Deletes the CACHE_FOLDERS that exist inside the derived-data folder `derived`; returns the names it removed.
    A folder that cannot be removed is reported through `say` and left; nothing outside `derived` is touched (a link
    is removed as a link, never followed)."""
    removed = []
    for name in CACHE_FOLDERS:
        path = Path(derived) / name
        try:
            if path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            else:
                continue
        except OSError as error:
            say(f"module cache: could not empty {name}: {error}")
            continue
        removed.append(name)
    return removed


def describe(derived, modulemap_time):
    """One line saying what the module caches hold now: how many .pcm files the implicit module cache has and how many
    of them are older than the toolchain's module.modulemap (a module built before the file changed is the stale kind).
    Printed into the job's log, where the next reader finds out what a restored cache was like before it was judged."""
    cache = Path(derived) / "ModuleCache.noindex"
    if not cache.is_dir():
        return "module cache: no ModuleCache.noindex in the restored folder"
    total = older = 0
    for path in cache.rglob("*.pcm"):
        total += 1
        try:
            if modulemap_time is not None and int(path.stat().st_mtime) < modulemap_time:
                older += 1
        except OSError:
            continue
    return f"module cache: ModuleCache.noindex holds {total} .pcm files, {older} older than the toolchain's module.modulemap"


def prepare(derived, environment=None, run=subprocess.run, say=print):
    """Before a build into `derived`: stamps the toolchain, and empties the module caches when the folder's stamp is
    missing or differs (or says nothing). Returns what it did, one of "skipped" (not on a GitHub runner, nothing
    touched), "kept" (the stamp matches, the caches stay) or "emptied" (the caches were emptied, which includes a
    folder that had no stamp). Each decision is printed through `say`, so that a job's log tells the story."""
    environment = os.environ if environment is None else environment
    if not on_github_runner(environment):
        return "skipped"
    now = current_stamp(environment, run)
    before = read_stamp(derived)
    say(f"module cache: toolchain now {json.dumps(now, sort_keys=True)}")
    say(f"module cache: stamp in the restored folder {json.dumps(before, sort_keys=True) if before is not None else 'missing'}")
    say(describe(derived, now["modulemap_mtime"]))
    if before is not None and stamp_known(now) and before == now:
        say("module cache: the stamp matches; the caches are kept")
        return "kept"
    removed = empty_module_caches(derived, say)
    say(f"module cache: the stamp {'differs' if before is not None else 'is missing'}; emptied "
        f"{', '.join(removed) if removed else 'nothing (there was none)'}")
    write_stamp(derived, now)
    return "emptied"


def is_stale_module_error(text):
    """Whether a build's log holds Clang's error for a module built before a file changed."""
    return STALE_MARKER in text


def cache_failure(text):
    """The words naming how a restored module cache failed the build whose log (or error line) is `text`: STALE_MARKER for
    a module built before a file changed, MISSING_MARKER for a precompiled module that is not there, or None when the
    text holds neither (a real compile error). The one test of a log that the iPhone build's retry and summary share (run-on-runner.py still looks only for the stale kind)."""
    if is_stale_module_error(text):
        return STALE_MARKER
    return MISSING_MARKER if MISSING_MODULE.search(text) else None


def stale_cache_only(errors):
    """Whether `errors` (the lines of ios-errors.txt) are all a cache failure (see cache_failure) and there is at least
    one: a build whose only errors are these failed for the runner's cache, and no change to the repository can fix it."""
    return bool(errors) and all(cache_failure(error) for error in errors)
