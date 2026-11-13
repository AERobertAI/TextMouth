#!/usr/bin/env python3
"""merge_shards.py: joins the results of the parallel shard jobs into the one result the Mac reads.

Each shard job of the workflow uploads an artifact `shard-results-N` holding run-on-runner.py's four
files. The workflow's last job downloads them all into one folder and runs this, which writes the same four
files a single job would have: run-summary.txt, run.log, summary.md, and request.json, so the Mac,
build-train.py and run_suite.py, never needs to know there were shards.

- run-summary.txt: one Executed line with the shards' counts added (and the longest shard's time),
  every FAILED, ERROR and CRASH line of every shard, and a last line of PASSED only if every expected
  shard reported and passed. A shard that reported nothing (its job failed before the tests, or was
  cancelled) fails the run and is named.
- run.log: the shard logs one after another, each under a heading, then a closing "Test Suite 'All tests'"
  verdict and TEST SUCCEEDED or TEST FAILED, so the reading of a log's tail (run_suite.py,
  tests_all_passed) judges the whole run and not only the last shard.

Usage: python3 -I -B Scripts/agents/merge_shards.py SHARDS_DIR OUT_DIR EXPECTED
  SHARDS_DIR holds one folder per shard; OUT_DIR is where the four files go; EXPECTED is the number of shards.
Python 3 standard library only.
"""
import json
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ios_ui_tests  # noqa: E402

EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
                      r"(?: \((\d+) unexpected\))?(?: in ([\d.]+) \(([\d.]+)\) seconds)?")


def is_kept(line):
    """Whether a summary line is a failed test (which names where, with " at "), a compile error, or a
    crash. A closing "FAILED in 41 seconds" or "FAILED: reason" line is not: the merge writes its own."""
    if line.startswith("FAILED "):
        return " at " in line
    return line.startswith(("ERROR ", "CRASH"))


# The count of entries a shard's summary.md says the runner left out of it.
LEFT_OUT = re.compile(r"Left out on the runner: (\d+)")
# One test's result in an xcodebuild log, wherever it starts on its line: the app's own log lines (os_log) sometimes land in
# the middle of a line, so a result can follow a time stamp ("2026-11-11 05Test Case '-[...]' passed"), and 3 to 10 of a
# shard's 3,000 results were lost to an anchored pattern (the review of ci/ios-ui-tests, finding 10). The name is the key.
TEST_CASE = re.compile(r"Test Case '(-\[[^'\]]*\])' (passed|failed|skipped) \(")


def case_counts(log):
    """(tests, skipped, failures) counted from the log's own Test Case result lines, or None when it has none.
    The log is the count to trust: after the test host restarts, xcodebuild's closing Executed line counts
    only the last launch (a shard that restarted 29 times said it ran 539 tests when its log held 562 results,
    and another said 967 of 2,882). Each test counts once, by its name, with its last result."""
    results = dict(TEST_CASE.findall(log))
    if not results:
        return None
    outcomes = list(results.values())
    return len(outcomes), outcomes.count("skipped"), outcomes.count("failed")


def read_shard(folder):
    """What one shard folder holds: {"summary": text or None, "log": text, "passed": bool,
    "counts": (tests, skipped, failures, seconds) or None}. A folder without a summary reported nothing."""
    folder = Path(folder)
    summary_path = folder / "run-summary.txt"
    summary = summary_path.read_text(encoding="utf-8", errors="replace") if summary_path.exists() else None
    log_path = folder / "run.log"
    log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    counts = None
    passed = False
    if summary is not None:
        lines = [line.strip() for line in summary.splitlines() if line.strip()]
        passed = bool(lines) and lines[-1].startswith("PASSED")
        for line in reversed(lines):
            match = EXECUTED.search(line)
            if match:
                counts = (int(match.group(1)), int(match.group(2) or 0), int(match.group(3)),
                          float(match.group(6) or 0))
                break
    by_log = case_counts(log)
    if by_log is not None:
        counts = (*by_log, counts[3] if counts else 0.0)
    summary_md = folder / "summary.md"
    left_out = 0
    if summary_md.exists():
        found = LEFT_OUT.search(summary_md.read_text(encoding="utf-8", errors="replace"))
        left_out = int(found.group(1)) if found else 0
    return {"summary": summary, "log": log, "passed": passed, "counts": counts, "left_out": left_out}


def shard_number(folder):
    """The number of the shard whose files are in `folder`: from the folder's name (shard-results-3), or, for
    files with no such folder, from the request.json inside ("shard": "3 of 4"), else 1."""
    named = re.search(r"(\d+)$", Path(folder).name)
    if named and Path(folder).name.startswith("shard-results-"):
        return int(named.group(1))
    try:
        request = json.loads((Path(folder) / "request.json").read_text(encoding="utf-8"))
        return int(str(request.get("shard", "1")).split()[0])
    except (OSError, ValueError, IndexError, AttributeError):
        return 1


# The files the iPhone job uploads (run-ios-build.py's three, then run-ios-ui-tests.py's two), which the join passes on
# beside the tests' own.
IOS_FILES = ("ios-summary.txt", "ios-errors.txt", "ios.log", "ios-ui-summary.txt", "ios-ui.log")
# How many failed iPhone tests (unit or interface) summary.md names.
IOS_UI_FAILURES_NAMED = 40


def merge_ios(ios_dir, out_dir):
    """Passes the iPhone build's results on into `out_dir`, and returns the line summary.md shows for them. With no
    summary in `ios_dir` (its job failed before the build, or was cancelled), writes one that says NOT RUN, so the Mac
    can tell a build that did not happen from one that passed. The iPhone build never decides whether the tests passed."""
    ios_dir, out_dir = Path(ios_dir), Path(out_dir)
    summary_path = ios_dir / "ios-summary.txt"
    if not summary_path.exists():
        (out_dir / "ios-summary.txt").write_text(
            "iOS build: NOT RUN\nReason: its job reported nothing (it failed before the build, or was cancelled)\n",
            encoding="utf-8")
        (out_dir / "ios-errors.txt").write_text("", encoding="utf-8")
        return "- iOS build: NOT RUN (its job reported nothing)"
    for name in IOS_FILES:
        if (ios_dir / name).exists():
            (out_dir / name).write_bytes((ios_dir / name).read_bytes())
    lines = summary_path.read_text(encoding="utf-8", errors="replace").splitlines()
    return f"- {lines[0]}; {lines[1].lower()}" if len(lines) > 1 else f"- {lines[0] if lines else 'iOS build: unknown'}"


def merge_ios_ui(ios_dir, out_dir):
    """Passes the iPhone tests' summary (the unit tests' and the interface tests') on into `out_dir` (merge_ios copies
    the files), and returns the lines summary.md shows for it: the verdict with the Executed line and the count of each
    bundle, then each failed test. With no summary in `ios_dir` (the step was cut off), writes one that says NOT RUN. The
    iPhone tests never decide whether the Mac tests passed: their verdict is shown beside it."""
    ios_dir, out_dir = Path(ios_dir), Path(out_dir)
    path = ios_dir / "ios-ui-summary.txt"
    if not path.exists():
        (out_dir / "ios-ui-summary.txt").write_text(
            "iOS UI tests: NOT RUN\nReason: the step reported nothing (it was cut off, or the job ended before it)\n",
            encoding="utf-8")
        return ["- iOS UI tests: NOT RUN (the step reported nothing)"]
    lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    verdict = lines[0] if lines else "iOS UI tests: unknown"
    # The Executed line with how many unit tests and how many interface tests ran.
    executed = ios_ui_tests.executed_with_counts(lines)
    failures = [line for line in lines if line.startswith("FAILED ")]
    reasons = [line for line in lines if line.startswith("Reason: ")]
    shown = f"- {verdict}" + (f"; {executed[0].lower()}{executed[1:]}" if executed else "")
    return [shown, *[f"- {reason}" for reason in reasons],
            f"- iOS UI test failures: {len(failures)}", *[f"  - {line}" for line in failures[:IOS_UI_FAILURES_NAMED]]]


def merge(shards_dir, out_dir, expected, ios_dir=None):
    """Writes the merged four files into `out_dir` (and, with `ios_dir`, the iPhone build's too, see merge_ios);
    returns True when the whole run passed.

    The shards' folders are `shard-results-N` inside `shards_dir`. When only one shard's artifact matched
    the download, actions/download-artifact puts its files straight into `shards_dir` with no folder of its own
    (found by the first proof run of a train, which had one shard), so files there are one shard's too."""
    shards_dir, out_dir = Path(shards_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    folders = sorted(path for path in shards_dir.iterdir() if path.is_dir()) if shards_dir.exists() else []
    if (shards_dir / "run-summary.txt").exists() or (shards_dir / "request.json").exists():
        folders.append(shards_dir)
    by_number = {}
    folder_of = {}
    for path in folders:
        number = shard_number(path)
        if path != shards_dir and not path.name.startswith("shard-results-"):
            continue
        by_number[number] = read_shard(path)
        folder_of[number] = path
    tests = skipped = failures = left_out = 0
    seconds = 0.0
    lines, problems, logs = [], [], []
    for number in range(1, expected + 1):
        shard = by_number.get(number)
        if shard is None or shard["summary"] is None:
            problems.append(f"shard {number} of {expected} reported nothing (its job failed before the tests, or was cancelled)")
            logs.append(f"===== shard {number} of {expected}: no results =====\n")
            continue
        left_out += shard["left_out"]
        if shard["counts"]:
            tests += shard["counts"][0]
            skipped += shard["counts"][1]
            failures += shard["counts"][2]
            seconds = max(seconds, shard["counts"][3])
        else:
            problems.append(f"shard {number} of {expected} ran no tests")
        lines += [line.strip() for line in shard["summary"].splitlines() if is_kept(line.strip())]
        if not shard["passed"]:
            reasons = [line.strip()[len("FAILED:"):].strip() for line in shard["summary"].splitlines()
                       if line.strip().startswith("FAILED:")]
            problems.append(f"shard {number} of {expected} did not pass" + (f" ({'; '.join(reasons)})" if reasons else ""))
        logs.append(f"===== shard {number} of {expected} =====\n{shard['log']}\n")
    passed = not problems and failures == 0
    executed = (f"Executed {tests} tests, with {skipped} tests skipped and {failures} failures "
                f"(0 unexpected) in {seconds:.3f} ({seconds:.3f}) seconds")
    summary = [f"{executed}", f"shards: {expected}", *lines]
    summary += [f"FAILED: {problem}" for problem in problems]
    summary += ["PASSED" if passed else "FAILED"]
    (out_dir / "run-summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    closing = [f"Test Suite 'All tests' {'passed' if passed else 'failed'} at (merged from {expected} shards).",
               f"\t {executed}", "** TEST SUCCEEDED **" if passed else "** TEST FAILED **"]
    (out_dir / "run.log").write_text("".join(logs) + "\n".join(closing) + "\n", encoding="utf-8")
    request = {}
    for number in sorted(by_number):
        request_path = folder_of[number] / "request.json"
        if request_path.exists():
            request = json.loads(request_path.read_text(encoding="utf-8"))
            break
    (out_dir / "request.json").write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
    ios_line = [merge_ios(ios_dir, out_dir), *merge_ios_ui(ios_dir, out_dir)] if ios_dir is not None else []
    (out_dir / "summary.md").write_text(
        "\n".join(["# Test build", "", f"- Verdict: {'PASSED' if passed else 'FAILED'}", f"- {executed}",
                   f"- Shards: {expected}", f"- Left out on the runner: {left_out} tests or classes (Scripts/agents/runner-skips.conf)",
                   *ios_line, f"- Failures and errors: {len(lines)}", *[f"  - {l}" for l in lines[:40]],
                   *[f"- Problem: {p}" for p in problems]]) + "\n", encoding="utf-8")
    return passed


def main(argv):
    """Merges and says the verdict; exits 0 when the whole run passed."""
    if len(argv) not in (3, 4):
        print("usage: merge_shards.py SHARDS_DIR OUT_DIR EXPECTED [IOS_DIR]", file=sys.stderr)
        return 2
    passed = merge(argv[0], argv[1], int(argv[2]), argv[3] if len(argv) == 4 else None)
    print("PASSED" if passed else "FAILED")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
