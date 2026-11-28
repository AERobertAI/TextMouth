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


# Xcode's own retry: a failing test is run again, up to three tries in all, and the run passes when
# one try passes. A test that is slow on a busy Mac or runner then no longer fails a whole run (each
# failed run emails the user). The tests that needed a second try are listed in every result
# (test_tries.py reads them from the log), so one that fails now and then stays visible.
RETRY_ARGUMENTS = ["-retry-tests-on-failure", "-test-iterations", "3"]


def retry_arguments(extra):
    """Xcode's retry on failure, unless `extra` already says how many times to run each test
    (`-test-iterations N`, a request's "test_iterations"): a run hunting a flaky test repeats every
    test and counts each failure, where the retry would hide it behind a second try, and xcodebuild
    refuses an option given twice."""
    return [] if "-test-iterations" in extra else list(RETRY_ARGUMENTS)


def full_suite_command(derived_data, result_bundle=None, extra=()):
    """The argv of the full suite, built in `derived_data`. With `result_bundle`
    (a path), xcodebuild also writes its result bundle there; `extra` is more
    xcodebuild arguments, put before it. A failing test is tried again (RETRY_ARGUMENTS)."""
    base = list(FULL_SUITE_BASE)
    if "-parallel-testing-enabled" in extra:
        # xcodebuild refuses an option given twice: an extra one takes the place of the base's `NO`.
        at = base.index("-parallel-testing-enabled")
        del base[at:at + 2]
    command = [*base, "-derivedDataPath", str(derived_data), *retry_arguments(extra), *extra]
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
    xcodebuild's -jobs; `extra` is more xcodebuild arguments. A failing test is tried again
    (RETRY_ARGUMENTS), as in the full suite."""
    names = area_names(areas)
    command = ["python3", "-I", "Scripts/test/run-area.py", *names]
    if classes and names != ["all"]:
        command += ["--classes", ",".join(classes)]
    command += ["--jobs", str(jobs)]
    if not slot:
        command += ["--no-slot"]
    command += ["--derived-data", str(derived_data), "--log", str(log)]
    # run-area.py takes each as --xcodebuild-arg=ARG (the equals sign, since ARG starts with a hyphen).
    command += [f"--xcodebuild-arg={argument}" for argument in [*retry_arguments(extra), *extra]]
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
