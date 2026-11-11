#!/usr/bin/env python3
"""run-ios-ui-tests.py: runs the iPhone app's interface tests (TextMouthiOSUITests) in the iOS Simulator, on a GitHub
Actions runner.

The workflow's `ios` job (.github/workflows/tests.yml) calls this after run-ios-build.py has built the app and its test
bundle (`build-for-testing`). It runs them with `xcodebuild test-without-building`, in an iPhone 17 simulator on the
iOS runtime the job downloaded. Which classes run is decided by ios_ui_tests.py from the request the commit carries
(.github/test-request.json): every full suite, a request for the phone area, and a request that names an interface test
class ask for them; any other request does not, and this writes "NOT ASKED" and stops.

**The sound rule.** These tests press Play and type, as a person does. That makes sound, so on the development Mac they
skip: TextMouthUITestCase runs such a test only when the environment variable TEXTMOUTH_UI_SOUND is 1. This script is the
one place that sets it (as TEST_RUNNER_TEXTMOUTH_UI_SOUND, which xcodebuild hands to the test runner without the prefix),
and it runs only on a GitHub runner, where nobody listens. Never set it anywhere else.

It writes three files into the output folder, which the workflow uploads and the Mac downloads:

  ios-ui-summary.txt   "iOS UI tests: PASSED", "FAILED", "NOT RUN" or "NOT ASKED", then the Executed line, the simulator,
                       the minutes, a "FAILED Class.test at file:line: message" line for each failed test (the form the
                       Mac's runs print), a "Skipped Class.test: why" line for each skipped one, and a "Reason:" line for
                       a run that did not finish
  ios-ui.log           the simulator set-up and xcodebuild's whole output
  ios-ui-result.xcresult  xcodebuild's result bundle, with the screenshots and trees the tests attached

It exits 0 when the tests passed or were not asked for or could not start for a reason that is not theirs (the build
did not pass), and 1 when an asked-for test failed or the run could not be finished, so that the job's verdict follows
the interface tests, and never the Mac's. Every wait has a limit.

Usage: python3 -I -B Scripts/agents/run-ios-ui-tests.py [--out DIR] [--derived-data DIR] [--request FILE]
                                                         [--limit-minutes N]
Run it from the repository root. Python 3 standard library only.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# Importing these must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
AGENTS = Path(__file__).resolve().parent
sys.path.insert(0, str(AGENTS))
import ios_ui_tests  # noqa: E402

# The repository's root, where the tests run.
ROOT = AGENTS.parents[1]
SCHEME = "TextMouthiOS"
BUNDLE = "TextMouthiOSUITests"
# The simulator: an iPhone 17, as on the development Mac, on the iOS runtime the job downloaded (the one of the SDK
# Xcode 26.0.1 builds with). A different iOS version is used only when the wanted one is not there, and the summary says so.
DEVICE_NAME = "iPhone 17"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME_VERSION = "26.0"
# The environment variable that lets a test make sound or type, and the name xcodebuild takes it by.
SOUND_VARIABLE = "TEXTMOUTH_UI_SOUND"
RUNNER_SOUND_VARIABLE = "TEST_RUNNER_" + SOUND_VARIABLE
# The longest the interface tests may take, in minutes. The slowest full run so far took 21.0 minutes of tests (run
# 42968173876), so 35 leaves room for a slower runner without a false "stopped at its time limit".
DEFAULT_LIMIT_MINUTES = 35
# The whole step, in minutes, as the workflow's step limit (`timeout-minutes: 45` of "Run the iPhone interface tests")
# less a minute of margin: the tests' limit is cut by what the simulator's set-up used, so that this script always has
# time to write its results before the runner stops the step.
STEP_BUDGET_MINUTES = 44
# The least time worth running the tests in, in minutes: with less left after a slow set-up, the run fails at once, saying so.
LEAST_TEST_MINUTES = 5
# How long the first boot of a device is waited for, in seconds: a boot took 1 to 3 minutes in the runs that finished, and four
# of the last seven on November 11, 2026 never finished ("Waiting on BackBoard", for 300 seconds). A boot not done by then
# is given up on, and the tests get a new device (see ready_simulator), which is waited for BOOT_SECONDS.
FIRST_BOOT_SECONDS = 180
# The longest the simulator may take to boot, in seconds, and one `simctl` call to answer.
BOOT_SECONDS = 300
SIMCTL_SECONDS = 60
# How many `simctl` calls the set-up makes besides the boots' waits, at the most: the listing, the runtimes, the devices, the
# device made when there is none, the shutdown of a device that did not boot, the new device made for the second try, and one
# `defaults write` for each keyboard setting (the workflow test adds their limits up, with FIRST_BOOT_SECONDS and BOOT_SECONDS).
SETUP_SIMCTL_CALLS = 6 + 4
# How long a run past its limit is given to end after being asked to, before it is killed, in seconds.
KILL_GRACE_SECONDS = 60
# The longest one test may take, in seconds: a test that waits for a minute at a time can take several.
TEST_SECONDS = 300
# How many clones of the simulator run the tests at once (1: a single simulator). Two clones were tried on GitHub (run
# 42952036750) and took no less time for the same 34 tests (17.1 minutes against 17.5), the runner having three slow cores,
# and xcodebuild then printed no failure message or location for a failed test. So one simulator.
PARALLEL_WORKERS = 1
# The keyboard's own settings in the simulator, written before the first test: the one-time "Speed up your typing by
# sliding your finger" page would otherwise cover the keyboard of the first test that types, and a correction or a
# prediction could change what a test typed.
KEYBOARD_DOMAIN = "com.apple.keyboard.preferences"
KEYBOARD_SETTINGS = (("DidShowContinuousPathIntroduction", True), ("KeyboardAutocorrection", False),
                     ("KeyboardPrediction", False), ("KeyboardShowPredictionBar", False))


class SimulatorFailure(Exception):
    """The simulator could not be made ready; the message says which step failed and why."""


class BootTimedOut(SimulatorFailure):
    """A boot did not finish in the time it was given; the message holds what `simctl bootstatus` had printed."""


def simctl(*args, timeout=SIMCTL_SECONDS):
    """Runs `xcrun simctl args`; returns the finished process (text). A call that hangs or cannot start is a
    SimulatorFailure, so that no wait is without limit."""
    try:
        return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        # What the call had printed before it was stopped is the only clue to why it hung (three phone-area runs on
        # November 11, 2026 lost their tests to "bootstatus did not finish in 300 seconds" with nothing else known).
        printed = "".join(part.decode("utf-8", "replace") if isinstance(part, bytes) else (part or "")
                          for part in (expired.stdout, expired.stderr)).strip()
        raise SimulatorFailure(f"simctl {args[0]} did not finish in {timeout} seconds"
                               + (f"; it had printed: {printed[-400:]}" if printed else "; it had printed nothing"))
    except OSError as error:
        raise SimulatorFailure(f"could not start simctl: {error}")


def simctl_json(*args):
    """The JSON `xcrun simctl list ... -j` prints, parsed; a failure or other output is a SimulatorFailure."""
    result = simctl("list", *args, "-j")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise SimulatorFailure(f"simctl list {' '.join(args)} gave no JSON: {(result.stderr or result.stdout)[:300]}")


def version_key(version):
    """A version string such as "26.0.1" as a tuple of numbers, to order versions; an odd part counts as 0."""
    return tuple(int(part) if part.isdigit() else 0 for part in str(version).split("."))


def choose_runtime(runtimes, wanted=RUNTIME_VERSION):
    """The iOS runtime to use from `simctl list runtimes -j`'s "runtimes": one that is available and whose version is
    `wanted` or begins with `wanted` and a dot (the newest of those), else the newest iOS runtime there is; None when
    there is no iOS runtime. Each is a dictionary with "identifier", "version" and "isAvailable"."""
    ios = [runtime for runtime in runtimes
           if "SimRuntime.iOS-" in runtime.get("identifier", "") and runtime.get("isAvailable", True)]
    if not ios:
        return None
    exact = [runtime for runtime in ios
             if runtime.get("version") == wanted or str(runtime.get("version", "")).startswith(wanted + ".")]
    return max(exact or ios, key=lambda runtime: version_key(runtime.get("version", "0")))


def choose_device(devices, runtime_id, name=DEVICE_NAME):
    """The UDID of an available device called `name` among `devices` (the "devices" of `simctl list devices -j`, a
    dictionary from runtime identifier to a list of devices) under `runtime_id`, or None when there is none."""
    for device in devices.get(runtime_id, []):
        if device.get("name") == name and device.get("isAvailable", True):
            return device["udid"]
    return None


def wait_for_boot(udid, seconds, log):
    """Boots the device `udid` if nothing has and waits up to `seconds` for it to finish (`simctl bootstatus -b`). Raises
    BootTimedOut, holding what bootstatus had printed, when the time passes, and SimulatorFailure when the call fails."""
    try:
        booted = simctl("bootstatus", udid, "-b", timeout=seconds)
    except SimulatorFailure as failure:
        if "did not finish in" in str(failure):
            raise BootTimedOut(str(failure))
        raise
    log.write(f"$ xcrun simctl bootstatus {udid} -b -> {booted.returncode}\n{booted.stdout[-2000:]}{booted.stderr[-2000:]}\n")
    if booted.returncode != 0:
        raise SimulatorFailure(f"the simulator {udid} did not boot: {(booted.stderr or booted.stdout).strip()[-300:]}")


def ready_simulator(log):
    """Finds or makes an iPhone 17 on the best iOS runtime, boots it, and sets the keyboard's settings. Returns
    (its UDID, a sentence naming it). Every `simctl` call is written to `log`. A step that cannot finish raises
    SimulatorFailure, naming it."""
    listing = simctl("list")
    log.write(f"$ xcrun simctl list\n{listing.stdout}\n")
    runtime = choose_runtime(simctl_json("runtimes").get("runtimes", []))
    if runtime is None:
        raise SimulatorFailure("the runner has no iOS simulator runtime (the platform download did not leave one)")
    udid = choose_device(simctl_json("devices").get("devices", {}), runtime["identifier"])
    if udid is None:
        made = simctl("create", f"TextMouth {DEVICE_NAME}", DEVICE_TYPE, runtime["identifier"])
        udid = made.stdout.strip()
        log.write(f"$ xcrun simctl create -> {made.returncode}: {made.stdout}{made.stderr}\n")
        if made.returncode != 0 or not udid:
            raise SimulatorFailure(f"could not make an {DEVICE_NAME} on {runtime['identifier']}: {made.stderr.strip()[:300]}")
    try:
        wait_for_boot(udid, FIRST_BOOT_SECONDS, log)
    except BootTimedOut as stuck:
        # The device is stuck (it prints "Waiting on BackBoard" and goes no further): shut it down and boot a new one.
        log.write(f"The boot of {udid} did not finish: {stuck}\n")
        shut = simctl("shutdown", udid)
        log.write(f"$ xcrun simctl shutdown {udid} -> {shut.returncode} {shut.stderr.strip()}\n")
        made = simctl("create", f"TextMouth {DEVICE_NAME} second try", DEVICE_TYPE, runtime["identifier"])
        udid = made.stdout.strip()
        log.write(f"$ xcrun simctl create (a new device) -> {made.returncode}: {made.stdout}{made.stderr}\n")
        if made.returncode != 0 or not udid:
            raise SimulatorFailure(f"the first boot did not finish ({stuck}) and a new device could not be made: {made.stderr.strip()[:300]}")
        wait_for_boot(udid, BOOT_SECONDS, log)
    for key, value in KEYBOARD_SETTINGS:
        written = simctl("spawn", udid, "defaults", "write", KEYBOARD_DOMAIN, key, "-bool", "true" if value else "false")
        log.write(f"$ defaults write {KEYBOARD_DOMAIN} {key} {value} -> {written.returncode} {written.stderr.strip()}\n")
    sentence = f"{DEVICE_NAME}, iOS {runtime.get('version', '?')} ({udid})"
    if not str(runtime.get("version", "")).startswith(RUNTIME_VERSION):
        sentence += f" (the wanted iOS {RUNTIME_VERSION} runtime was not there)"
    return udid, sentence


def parallel_arguments():
    """The xcodebuild arguments that run the tests in PARALLEL_WORKERS clones of the simulator at once, or none for one
    simulator. The first run on GitHub (42948545901, one simulator) took 17.5 minutes for 34 tests, about 25 seconds each,
    the runner being a slow virtual machine."""
    if PARALLEL_WORKERS < 2:
        return ["-parallel-testing-enabled", "NO"]
    return ["-parallel-testing-enabled", "YES", "-parallel-testing-worker-count", str(PARALLEL_WORKERS),
            "-maximum-parallel-testing-workers", str(PARALLEL_WORKERS)]


def test_command(udid, derived_data, result_bundle, classes):
    """The argv of the run: `test-without-building` of the scheme, in the simulator `udid`, on the interface test bundle
    (or only `classes` of it, each as -only-testing), with a time limit for any one test."""
    only = [f"-only-testing:{BUNDLE}/{name}" for name in classes] if classes else [f"-only-testing:{BUNDLE}"]
    return ["xcodebuild", "test-without-building", "-project", "TextMouth.xcodeproj", "-scheme", SCHEME,
            "-destination", f"id={udid}", "-derivedDataPath", str(derived_data), *only,
            "-resultBundlePath", str(result_bundle), *parallel_arguments(), "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", str(TEST_SECONDS),
            "-maximum-test-execution-time-allowance", str(TEST_SECONDS),
            "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]


def test_environment():
    """The environment of the run: this process's own, plus the variable that lets the tests make sound and type. It is
    set here and nowhere else (see the module's comment)."""
    return {**os.environ, RUNNER_SOUND_VARIABLE: "1"}


# One test's result in an xcodebuild log, in the two forms Xcode prints: the test process's own,
# "Test Case '-[TextMouthiOSUITests.ReaderUITests testX]' passed (3.4 seconds).", and xcodebuild's,
# "Test case 'ReaderUITests.testX()' passed on 'iPhone 17 - TextMouthiOS (4242)' (3.4 seconds)".
CASE_OBJC = re.compile(r"^Test Case '-\[(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(", re.M)
CASE_SWIFT = re.compile(r"^Test case '([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\(\)' (passed|failed|skipped) on ", re.M)
# A failure the test process printed: "<path>:<line>: error: -[Module.Class test] : <message>".
FAILURE_LINE = re.compile(r"^(\S.*?):(\d+): error: -\[(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\] : (.*)$", re.M)
# A skip: "<path>:<line>: -[Module.Class test] : Test skipped - <why>".
SKIP_LINE = re.compile(r"^(?:\S.*?):\d+: -\[(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\] : Test skipped - (.*)$", re.M)
# What xcodebuild prints last when the tests passed: "** TEST SUCCEEDED **" for `test`, and, found by the full suite of
# November 10, 2026 (run 42957244945, 34 tests with no failure judged FAILED), "** TEST EXECUTE SUCCEEDED **" for
# `test-without-building`.
SUCCESS_LINE = re.compile(r"\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*")
# The words every skip for sound has in its reason: TextMouthUITestCase.soundSkipMarker, the same text (a test pins that the
# two agree). This script sets the sound variable, so a test that skipped for sound means the variable did not reach the
# test runner, and the run proved nothing about those tests.
SOUND_SKIP_MARKER = "runs only on a GitHub runner"
# The longest a failure or skip message is kept, in characters: an assertion message can hold a screen's whole tree.
MESSAGE_LIMIT = 300


def relative(path, root=ROOT):
    """`path` with the repository root (and the slash after it) taken off, or unchanged when it is elsewhere."""
    prefix = str(root).rstrip("/") + "/"
    return path[len(prefix):] if path.startswith(prefix) else path


def parse_results(log_text, root=ROOT):
    """What an xcodebuild log says of the tests: a dictionary with
    "cases" (a dictionary from "Class.test" to "passed", "failed" or "skipped"; a test printed twice keeps the last),
    "failures" ("FAILED Class.test at path:line: message", for each failed case, the first message of the case),
    and "skips" ("Class.test: why", one for each skipped case, in the order met)."""
    cases = {}
    for regex in (CASE_OBJC, CASE_SWIFT):
        for owner, test, outcome in regex.findall(log_text):
            cases[f"{owner}.{test}"] = outcome
    first_error = {}
    for path, line, owner, test, message in FAILURE_LINE.findall(log_text):
        first_error.setdefault(f"{owner}.{test}", (relative(path, root), line, message.strip()[:MESSAGE_LIMIT]))
    failures = []
    for name, outcome in cases.items():
        if outcome != "failed":
            continue
        where, message = (f"{first_error[name][0]}:{first_error[name][1]}", first_error[name][2]) if name in first_error else ("(no location)", "failed")
        failures.append(f"FAILED {name} at {where}: {message}")
    why = {f"{owner}.{test}": reason.strip()[:MESSAGE_LIMIT] for owner, test, reason in SKIP_LINE.findall(log_text)}
    skips = [f"{name}: {why.get(name, 'no reason printed')}" for name, outcome in cases.items() if outcome == "skipped"]
    return {"cases": cases, "failures": failures, "skips": skips}


def judge(status, timed_out, log_text, parsed, expected=0):
    """(whether the run passed, the reasons it did not): xcodebuild exited 0 and printed TEST SUCCEEDED, the time limit
    did not stop it, no case failed, at least one test ran (a run of nothing is a mistake, not a pass), no test skipped
    because it makes sound (this script sets the variable that allows it, so such a skip means it never arrived), and,
    when `expected` is given, at least that many results came back (the tests the asked classes hold)."""
    reasons = []
    if timed_out:
        reasons.append("the run was stopped at its time limit")
    if parsed["failures"]:
        reasons.append(f"{len(parsed['failures'])} test(s) failed")
    elif not timed_out and (status != 0 or not SUCCESS_LINE.search(log_text)):
        reasons.append(f"xcodebuild ended with status {status} and did not print TEST SUCCEEDED or TEST EXECUTE SUCCEEDED")
    if not parsed["cases"]:
        reasons.append("no test result was found in the log")
    silenced = [line.split(":", 1)[0] for line in parsed["skips"] if SOUND_SKIP_MARKER in line]
    if silenced:
        reasons.append(f"{len(silenced)} test(s) skipped because they make sound, though this run allows sound: "
                       f"{SOUND_VARIABLE} did not reach the test runner ({', '.join(silenced[:3])}{', ...' if len(silenced) > 3 else ''})")
    if expected and len(parsed["cases"]) < expected:
        reasons.append(f"{len(parsed['cases'])} test results came back, and the classes asked for hold {expected}")
    return not reasons, reasons


def summary_lines(verdict, parsed, seconds, setup_seconds, simulator, classes, reasons):
    """The lines of ios-ui-summary.txt for a run that was made (see the module's comment for the form)."""
    counts = list(parsed["cases"].values())
    failed, skipped = counts.count("failed"), counts.count("skipped")
    shown = ", ".join(classes) if classes else "every class"
    return [f"iOS UI tests: {verdict}",
            f"Executed {len(counts)} tests, with {skipped} tests skipped and {failed} failures (0 unexpected) "
            f"in {seconds:.3f} ({seconds:.3f}) seconds",
            f"Classes: {shown}", f"Simulator: {simulator}",
            f"Sound: allowed ({SOUND_VARIABLE}=1, set by this script alone, so the tests press Play and type)",
            f"Minutes: {(seconds + setup_seconds) / 60:.1f} (the simulator's set-up took {setup_seconds / 60:.1f})",
            *parsed["failures"], *[f"Skipped {line}" for line in parsed["skips"]],
            *[f"Reason: {reason}" for reason in reasons]]


def not_run_lines(verdict, reason):
    """The lines of ios-ui-summary.txt for a run that did not happen: its verdict and the reason."""
    return [f"iOS UI tests: {verdict}", f"Reason: {reason}"]


def build_passed(out):
    """Whether run-ios-build.py's summary in `out` says the build passed (the tests need its products)."""
    try:
        first = (out / "ios-summary.txt").read_text(encoding="utf-8", errors="replace").splitlines()[0]
    except (OSError, IndexError):
        return False
    return first.strip() == "iOS build: PASSED"


def run_tests(command, log, limit_minutes):
    """Runs `command` with its whole output appended to `log`; returns (its exit status, whether the limit stopped it).
    A run past the limit is asked to end, then killed KILL_GRACE_SECONDS later."""
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=test_environment())
    try:
        return process.wait(timeout=limit_minutes * 60), False
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        return process.returncode, True


def main(argv):
    """Decides whether the tests are asked for, runs them, writes the results, and exits by their verdict."""
    parser = argparse.ArgumentParser(prog="run-ios-ui-tests.py", description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="build/remote-ios")
    parser.add_argument("--derived-data", default="build/remote-DerivedData-ios")
    parser.add_argument("--request", default=".github/test-request.json")
    parser.add_argument("--limit-minutes", type=float, default=DEFAULT_LIMIT_MINUTES)
    args = parser.parse_args(argv)
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    summary = out / "ios-ui-summary.txt"

    def finish(lines, code):
        """Writes the summary, prints it, and returns the exit status."""
        summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(summary.read_text(), end="")
        return code

    try:
        request = json.loads((ROOT / args.request).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        request = {}
    classes = ios_ui_tests.wanted(request if isinstance(request, dict) else {}, ROOT)
    if not classes:
        return finish(not_run_lines("NOT ASKED", "the request does not ask for the interface tests (a full suite, "
                                    "the phone area, or an interface test class does)"), 0)
    if not build_passed(out):
        return finish(not_run_lines("NOT RUN", "the iPhone build did not pass, so there is no test bundle to run"), 0)
    # All classes are one run of the whole bundle; a subset names each class.
    every = ios_ui_tests.ui_classes(ROOT)
    named = [] if classes == every else classes
    started = time.monotonic()
    # One fresh handle serves the set-up's notes and xcodebuild's output, which writes through the same file. It is opened
    # to write, not to append, so that a folder used before cannot lend this run an old run's results.
    with open(out / "ios-ui.log", "w", encoding="utf-8") as log:
        try:
            udid, simulator = ready_simulator(log)
        except SimulatorFailure as failure:
            log.write(f"simulator set-up failed: {failure}\n")
            # What the devices were doing when it failed.
            try:
                log.write(f"$ xcrun simctl list devices booted\n{simctl('list', 'devices', 'booted').stdout}\n")
            except SimulatorFailure as again:
                log.write(f"(and the devices could not be listed: {again})\n")
            return finish(not_run_lines("FAILED", f"the simulator could not be made ready: {failure}"), 1)
        log.flush()
        setup_seconds = time.monotonic() - started
        # The tests get what the step has left, never more than they were asked to take.
        left = STEP_BUDGET_MINUTES - (setup_seconds + KILL_GRACE_SECONDS) / 60
        if left < LEAST_TEST_MINUTES:
            return finish(not_run_lines("FAILED", f"the simulator's set-up took {setup_seconds / 60:.1f} minutes, leaving "
                                        f"{left:.1f} of the step's {STEP_BUDGET_MINUTES} for the tests"), 1)
        limit_minutes = min(args.limit_minutes, left)
        command = test_command(udid, ROOT / args.derived_data, out / "ios-ui-result.xcresult", named)
        print("command:", " ".join(command), flush=True)
        began = time.monotonic()
        status, timed_out = run_tests(command, log, limit_minutes)
        seconds = time.monotonic() - began
    log_text = (out / "ios-ui.log").read_text(encoding="utf-8", errors="replace")
    parsed = parse_results(log_text)
    counts = ios_ui_tests.test_counts(ROOT)
    passed, reasons = judge(status, timed_out, log_text, parsed, expected=sum(counts.get(name, 0) for name in classes))
    return finish(summary_lines("PASSED" if passed else "FAILED", parsed, seconds, setup_seconds, simulator, named,
                                reasons), 0 if passed else 1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
