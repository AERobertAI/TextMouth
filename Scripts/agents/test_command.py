"""test_command.py: the one place that says how the hosted tests are run.

Three callers run the tests, and none keeps a copy of the command:

- the build train (build-train.py), on this Mac or, with --remote, on GitHub;
- the orchestrator's full suite (run_suite.py), on this Mac or, with
  --remote, on GitHub;
- the GitHub Actions workflow (.github/workflows/test-build.yml), through
  run-on-runner.py, which reads the request file a train or a suite pushed.

A test request is a small dictionary, the same on this Mac and on GitHub:

    {"areas": ["feeds"], "classes": ["FooTests"], "full": false}

`areas` and `classes` name what Scripts/test/run-area.py runs (an area, a
test class, or "all"). `full` asks instead for the orchestrator's full suite
as run_suite.py runs it on this Mac, the scheme's whole test action. On the
GitHub runner a request with more than one shard is run by classes, however
it is flagged: the remote full suite always is, since run_suite.py --remote
asks for the most shards, and run-on-runner.py deals the classes of "all" out.
Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import importlib.util
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The folder this file is in, so any checkout or worktree finds its siblings.
AGENTS = Path(__file__).resolve().parent

# The full suite's command, as the merge method in AGENTS.md gives it. The
# derived-data folder is the caller's, since it differs from one place to the
# next: build/DerivedData for the orchestrator, the runner's own on GitHub.
FULL_SUITE_BASE = ["xcodebuild", "test", "-project", "TextMouth.xcodeproj", "-scheme", "TextMouth",
                   "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                   "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete"]


def full_suite_command(derived_data, result_bundle=None, extra=()):
    """The argv of the full suite, built in `derived_data`. With `result_bundle`
    (a path), xcodebuild also writes its result bundle there; `extra` is more
    xcodebuild arguments, put before it."""
    command = [*FULL_SUITE_BASE, "-derivedDataPath", str(derived_data), *extra]
    if result_bundle:
        command += ["-resultBundlePath", str(result_bundle)]
    return command


def area_names(areas):
    """The names run-area.py gets for a request's `areas`: just "all" when the
    whole suite is asked for, since every other area is then part of it."""
    return ["all"] if "all" in areas else list(areas)


def area_command(areas, classes, derived_data, log, jobs=2, slot=False, extra=()):
    """The argv of one run-area.py run of `areas` and `classes` (a list, may be
    empty), built in `derived_data` and logged to `log`. A class named beside
    "all" is already part of it, so it is left out. `slot` False leaves out the
    build-slot wrapper, as the train and the runner both want; `jobs` is
    xcodebuild's -jobs; `extra` is more xcodebuild arguments."""
    names = area_names(areas)
    command = ["python3", "-I", "Scripts/test/run-area.py", *names]
    if classes and names != ["all"]:
        command += ["--classes", ",".join(classes)]
    command += ["--jobs", str(jobs)]
    if not slot:
        command += ["--no-slot"]
    command += ["--derived-data", str(derived_data), "--log", str(log)]
    # run-area.py takes each as --xcodebuild-arg=ARG (the equals sign, since ARG starts with a hyphen).
    command += [f"--xcodebuild-arg={argument}" for argument in extra]
    return command


def load_build_train():
    """The build-train.py module, loaded by path (its name has a hyphen), with
    its command line out of the way. It holds the train's reading of a log
    (summarize, tests_have_ended, tests_all_passed), which every caller shares
    so that none can disagree with another."""
    spec = importlib.util.spec_from_file_location("build_train", AGENTS / "build-train.py")
    module = importlib.util.module_from_spec(spec)
    # build-train.py imports heavy_lock from beside it, so its folder must be on the path.
    sys.path.insert(0, str(AGENTS))
    arguments, sys.argv = sys.argv, ["build-train.py"]
    try:
        spec.loader.exec_module(module)
    finally:
        sys.argv = arguments
    return module
