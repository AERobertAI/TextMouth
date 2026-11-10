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

EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
                      r"(?: \((\d+) unexpected\))?(?: in ([\d.]+) \(([\d.]+)\) seconds)?")


def is_kept(line):
    """Whether a summary line is a failed test (which names where, with " at "), a compile error, or a
    crash. A closing "FAILED in 41 seconds" or "FAILED: reason" line is not: the merge writes its own."""
    if line.startswith("FAILED "):
        return " at " in line
    return line.startswith(("ERROR ", "CRASH"))


# One test's result line in an xcodebuild log.
TEST_CASE = re.compile(r"^Test Case '.*' (passed|failed|skipped) \(", re.M)


def case_counts(log):
    """(tests, skipped, failures) counted from the log's own Test Case result lines, or None when it has none.
    The log is the count to trust: after the test host restarts, xcodebuild's closing Executed line counts
    only the last launch (a shard that restarted 29 times said it ran 539 tests when its log held 562 results,
    and another said 967 of 2,882)."""
    results = TEST_CASE.findall(log)
    if not results:
        return None
    return len(results), results.count("skipped"), results.count("failed")


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
    return {"summary": summary, "log": log, "passed": passed, "counts": counts}


def merge(shards_dir, out_dir, expected):
    """Writes the merged four files into `out_dir`; returns True when the whole run passed."""
    shards_dir, out_dir = Path(shards_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    folders = sorted(path for path in shards_dir.iterdir() if path.is_dir()) if shards_dir.exists() else []
    by_number = {}
    for path in folders:
        number = re.search(r"(\d+)$", path.name)
        if number:
            by_number[int(number.group(1))] = read_shard(path)
    tests = skipped = failures = 0
    seconds = 0.0
    lines, problems, logs = [], [], []
    for number in range(1, expected + 1):
        shard = by_number.get(number)
        if shard is None or shard["summary"] is None:
            problems.append(f"shard {number} of {expected} reported nothing (its job failed before the tests, or was cancelled)")
            logs.append(f"===== shard {number} of {expected}: no results =====\n")
            continue
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
        request_path = shards_dir / f"shard-results-{number}" / "request.json"
        if request_path.exists():
            request = json.loads(request_path.read_text(encoding="utf-8"))
            break
    (out_dir / "request.json").write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
    (out_dir / "summary.md").write_text(
        "\n".join(["# Test build", "", f"- Verdict: {'PASSED' if passed else 'FAILED'}", f"- {executed}",
                   f"- Shards: {expected}", f"- Failures and errors: {len(lines)}", *[f"  - {l}" for l in lines[:40]],
                   *[f"- Problem: {p}" for p in problems]]) + "\n", encoding="utf-8")
    return passed


def main(argv):
    """Merges and says the verdict; exits 0 when the whole run passed."""
    if len(argv) != 3:
        print("usage: merge_shards.py SHARDS_DIR OUT_DIR EXPECTED", file=sys.stderr)
        return 2
    passed = merge(argv[0], argv[1], int(argv[2]))
    print("PASSED" if passed else "FAILED")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
