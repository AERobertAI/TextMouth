"""runner_diagnose.py: where a GitHub runner job's minutes go, measured on the runner and printed to the job's log.

A request sent by hand (github_run.run_remotely) with "diagnose": true makes run-on-runner.py call `diagnose` before
its tests, so that one run says what the machine is, how long package resolution and the build take, which Swift files
the build compiled again (a build from restored products should compile only what changed), and what Xcode's own
build timing summary says. Nothing it prints is a verdict; the tests that follow run exactly as without it. The same
build then finds its products up to date, so the tests' timing is the tests' alone.

Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import collections
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# How many compiled files the report names.
FILES_NAMED = 40
# The task names (the first word of a line in xcodebuild's log) the report counts.
TASKS = ("SwiftCompile", "SwiftEmitModule", "SwiftDriver", "CompileC", "Ld", "CodeSign", "ProcessInfoPlistFile",
         "CompileAssetCatalog", "CopySwiftLibs", "GenerateDSYMFile", "PhaseScriptExecution", "WriteAuxiliaryFile",
         "Libtool", "SwiftMergeGeneratedHeaders", "ScanDependencies", "PackageGraph")


def shell_text(command):
    """The output of a short shell command, or the reason it failed; never raises."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        return (result.stdout + result.stderr).strip()
    except (OSError, subprocess.SubprocessError) as error:
        return f"({command[0]} failed: {error})"


def timed(label, command, cwd, log):
    """Runs `command` with its whole output appended to `log`, prints how long it took (`label`), and returns the
    elapsed seconds and the exit status."""
    started = time.monotonic()
    with open(log, "ab") as sink:
        status = subprocess.run(command, cwd=cwd, stdout=sink, stderr=subprocess.STDOUT).returncode
    seconds = time.monotonic() - started
    print(f"DIAGNOSE {label}: {seconds:.1f} s (status {status}) load {os.getloadavg()[0]:.2f}", flush=True)
    return seconds, status


def task_counts(text):
    """{task name: number of its lines} for the build log's task lines, and the distinct Swift files compiled, in the
    order first seen. A line such as `SwiftCompile normal arm64 /path/File.swift (in target ...)` is one compile."""
    counts = collections.Counter()
    files = {}
    for line in text.splitlines():
        word = line.split(" ", 1)[0]
        if word in TASKS:
            counts[word] += 1
        if word == "SwiftCompile":
            found = re.search(r"(/\S+\.swift)", line)
            if found:
                files.setdefault(found.group(1), None)
    return counts, list(files)


def timing_summary(text):
    """The part of the log from xcodebuild's `Build Timing Summary` to its end (empty when there is none)."""
    marker = text.find("Build Timing Summary")
    return text[marker:] if marker >= 0 else ""


# Two files the incremental probes touch: a file few others use, and the hub nearly every file uses.
LEAF_PROBE = "TextMouth/Models/TitleTyping.swift"
HUB_PROBE = "TextMouth/Models/Book.swift"


def build_and_report(label, root, command, log):
    """Builds with `command` (timed, logged to `log` afresh), then prints what the build did: its seconds, its task
    counts, how many Swift files it compiled and how many of them are the app's own, the test bundle's, or generated, and
    (for the first build only, `label` "first") the first FILES_NAMED of them and Xcode's timing summary."""
    log.write_bytes(b"")
    seconds, _ = timed(label, [*command, "-showBuildTimingSummary"], root, log)
    text = log.read_text(encoding="utf-8", errors="replace")
    counts, files = task_counts(text)
    prefix = str(root) + "/"
    names = [path.replace(prefix, "") for path in files]
    by_folder = collections.Counter(name.split("/", 1)[0] for name in names)
    print(f"DIAGNOSE [{label}] tasks: " + (", ".join(f"{k} {v}" for k, v in sorted(counts.items())) or "none"), flush=True)
    print(f"DIAGNOSE [{label}] Swift files compiled: {len(names)} " + str(dict(by_folder)), flush=True)
    if label == "first":
        for name in names[:FILES_NAMED]:
            print("DIAGNOSE   compiled", name, flush=True)
        print("DIAGNOSE timing summary:\n" + (timing_summary(text)[:6000] or "(none)"), flush=True)
    return seconds


def probe_edit(root, relative, label, command, log):
    """Appends a comment line to the tracked file `relative`, rebuilds (reporting as build_and_report), and puts the file
    back as git has it, so the tests that follow run on the tree they were sent."""
    path = Path(root) / relative
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n// diagnose probe\n")
    try:
        return build_and_report(label, root, command, log)
    finally:
        subprocess.run(["git", "checkout", "--", relative], cwd=root, capture_output=True)


def diagnose(root, derived, build_command, out):
    """Prints the machine, then times package resolution and the build (`build_command`, the argv of a
    build-for-testing; -showBuildTimingSummary is added here), a second build with nothing changed, and rebuilds after a
    comment is added to a leaf file and then to the hub (Book.swift), saying each time what was compiled. `derived` is
    the derived-data folder; `out` the folder the log goes into (diagnose-build.log, which is not uploaded: the report is in
    the job's log)."""
    print("DIAGNOSE machine:", shell_text(["sysctl", "-n", "hw.ncpu", "hw.memsize", "machdep.cpu.brand_string"]).replace("\n", " | "), flush=True)
    print("DIAGNOSE disk:", shell_text(["df", "-h", "/"]).splitlines()[-1], flush=True)
    print("DIAGNOSE derived data before:", shell_text(["du", "-sh", str(derived)]), flush=True)
    log = Path(out) / "diagnose-build.log"
    log.write_bytes(b"")
    base = ["-project", "TextMouth.xcodeproj", "-scheme", "TextMouth", "-derivedDataPath", str(derived)]
    timed("package resolution", ["xcodebuild", "-resolvePackageDependencies", *base], root, log)
    build_and_report("first", root, build_command, log)
    print("DIAGNOSE derived data after:", shell_text(["du", "-sh", str(derived)]), flush=True)
    build_and_report("nothing changed", root, build_command, log)
    probe_edit(root, LEAF_PROBE, "leaf edited", build_command, log)
    probe_edit(root, HUB_PROBE, "hub edited", build_command, log)
