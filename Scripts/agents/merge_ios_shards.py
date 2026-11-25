"""merge_ios_shards.py: joins the results of the iPhone jobs, when the iPhone build and tests are split over several.

The workflow's `ios` job can be a matrix (the plan's `ios_shards`): each job builds the iPhone app and runs its slice of the
iPhone test classes (run-ios-ui-tests.py --shard I --of N), and uploads the five files of one job (ios-summary.txt,
ios-errors.txt, ios.log, ios-ui-summary.txt, ios-ui.log) as the artifact `ios-results-I`. This joins them into the five files a single
job would have written, so that merge_shards.py's reading of them (and build-train.py's, on the Mac) never needs to know
there were several:

- ios-summary.txt: "iOS build: PASSED" only if every job's build passed; FAILED if one failed; NOT RUN when one reported nothing
  (and none failed).
  The errors are every job's, once each (ios-errors.txt), counted again; the minutes are the longest job's; each job's reasons
  are kept, with the job named. A job that reported nothing is named, and fails the join.
  The size lines (run-ios-build.py writes them when the request asks for the app's size, "ios_size") are the first job's
  that has any: every job builds the same app, so they are the same measurement. When the workflow runs the device build in
  a job of its own (run-ios-build.py --size-only), the jobs have none, and join_size adds the size job's to the joined summary.
- ios-ui-summary.txt: the verdict is FAILED if any job's was (or a job reported nothing), else NOT RUN if any was, else PASSED
  if any job ran tests, else NOT ASKED. The Executed line and each bundle's count are the jobs' added up (a bundle no job
  was asked for stays "not asked"); each FAILED, Skipped and Reason line is kept, in job order, with the job named in a Reason.
- ios.log and ios-ui.log: the jobs' logs one after another, each under a heading.

Python 3 standard library only, and importing it leaves no __pycache__ folder.
"""
import re
import sys
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The folder name a job's artifact is downloaded into: ios-results-3.
FOLDER_PREFIX = "ios-results-"
# Lines of the two summaries that this module reads.
EXECUTED = re.compile(r"^Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures? \(\d+ unexpected\) in ([\d.]+) \(")
BUNDLE_COUNT = re.compile(r"^(Unit tests|Interface tests) \((\w+)\): (?:(\d+) ran, (\d+) skipped, (\d+) failed|not asked)$")
BUILD_ERRORS = re.compile(r"^Errors in the app: (\d+) in (\d+) files$")
MINUTES = re.compile(r"^Minutes: ([\d.]+)")


# What the size lines of an ios-summary.txt start with (Scripts/ios/app-size.py writes them): the headlines (the app, the
# IPA, the App Store download), then the details (the biggest files, the libraries).
SIZE_PREFIX = "Size: "
SIZE_DETAIL_PREFIX = "Size detail: "


def size_lines(lines):
    """The size lines of a summary's `lines`, in their order: the headlines and the details. Empty when the run was not
    asked for the size (or its device build could not measure it, which a "Size: not measured" line says)."""
    return [line for line in lines or [] if line.startswith((SIZE_PREFIX, SIZE_DETAIL_PREFIX))]


# The file the size job uploads its lines in (run-ios-build.py --size-only writes it), and the log tail beside it.
SIZE_SUMMARY_FILE = "ios-size-summary.txt"
SIZE_LOG_FILE = "ios.log"


def size_not_measured(why):
    """The one line a train reads as "no size", with the reason `why`."""
    return f"{SIZE_PREFIX}not measured: {why}."


def join_size(size_dir, out_dir):
    """Adds the size job's result to the joined files in `out_dir`: its size lines at the end of ios-summary.txt, and the
    last lines of its device build's log at the end of ios.log under a heading. A job that uploaded no summary (it failed
    before the build, or was cancelled) gives one "Size: not measured" line saying so, as the train reads a failed
    measurement; a summary with no line in it (the request did not ask for the size) adds nothing. Returns the lines added."""
    size_dir, out_dir = Path(size_dir), Path(out_dir)
    found = read_lines(size_dir / SIZE_SUMMARY_FILE)
    if found is None:
        lines = [size_not_measured("the size job reported nothing (it failed before the device build, or was cancelled)")]
    else:
        lines = size_lines(found)
    if not lines:
        return []
    # An iPhone build that reported nothing has its NOT RUN summary written by the caller; the lines go after whatever it holds.
    summary = out_dir / "ios-summary.txt"
    before = summary.read_text(encoding="utf-8") if summary.exists() else ""
    before += "" if before.endswith("\n") or not before else "\n"
    summary.write_text(before + "".join(line + "\n" for line in lines), encoding="utf-8")
    log = size_dir / SIZE_LOG_FILE
    if log.exists():
        with open(out_dir / "ios.log", "a", encoding="utf-8") as joined:
            joined.write(f"\n===== size job: device build =====\n{log.read_text(encoding='utf-8', errors='replace')}\n")
    return lines


def shard_number(folder):
    """The job number a folder `ios-results-N` stands for, or None for any other name."""
    name = Path(folder).name
    return int(name[len(FOLDER_PREFIX):]) if name.startswith(FOLDER_PREFIX) and name[len(FOLDER_PREFIX):].isdigit() else None


def shard_folders(ios_dir, expected=1):
    """{job number: folder} of the `ios-results-N` folders inside `ios_dir`; empty when it has none and one job is expected (one
    job's files in the folder itself, as the download leaves them when a single artifact matched). With several jobs expected,
    files directly in `ios_dir` are one job's that came alone (the others uploaded nothing): they are filed under the number
    its ios-ui-summary.txt gives ("Shard: I of N"), else 1."""
    ios_dir = Path(ios_dir)
    if not ios_dir.is_dir():
        return {}
    found = {shard_number(path): path for path in sorted(ios_dir.iterdir()) if path.is_dir() and shard_number(path) is not None}
    if found or expected <= 1 or not ((ios_dir / "ios-summary.txt").exists() or (ios_dir / "ios-ui-summary.txt").exists()):
        return found
    lines = read_lines(ios_dir / "ios-ui-summary.txt") or []
    number = next((int(m.group(1)) for line in lines if (m := re.match(r"^Shard: (\d+) of \d+$", line))), 1)
    return {number: ios_dir}


def read_lines(path):
    """The stripped, non-empty lines of a text file, or None when it is missing."""
    try:
        return [line.strip() for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    except OSError:
        return None


def verdict_of(lines, prefix):
    """The word after `prefix` on a summary's first line ("PASSED", "FAILED", ...), or "NOT RUN" with no summary."""
    return lines[0].removeprefix(prefix).strip() if lines else "NOT RUN"


def join_build(summaries, errors_by_shard, expected):
    """The text of the joined ios-summary.txt and the joined errors. `summaries` is {job: lines or None}."""
    errors = list(dict.fromkeys(error for number in sorted(errors_by_shard) for error in errors_by_shard[number]))
    files = sorted({error.split(":", 1)[0] for error in errors if re.match(r"^[^ ]+:\d+:\d+: error: ", error)})
    verdicts = {number: verdict_of(summaries.get(number), "iOS build: ") for number in range(1, expected + 1)}
    words = set(verdicts.values())
    if "FAILED" in words:
        verdict = "FAILED"
    elif "NOT RUN" in words:
        verdict = "NOT RUN"
    else:
        verdict = "PASSED"
    minutes = max([float(m.group(1)) for lines in summaries.values() for line in (lines or []) if (m := MINUTES.match(line))] or [0.0])
    built = next((line for lines in summaries.values() for line in (lines or []) if line.startswith("Built: ")), None)
    out = [f"iOS build: {verdict}", f"Errors in the app: {len(errors)} in {len(files)} files"]
    out += [built] if built else []
    out += [f"Minutes: {minutes:.1f} (the longest of {expected} jobs)"]
    out += next((sizes for sizes in (size_lines(lines) for _, lines in sorted(summaries.items())) if sizes), [])
    for number in range(1, expected + 1):
        lines = summaries.get(number)
        if lines is None:
            out.append(f"Reason: iPhone job {number} of {expected} reported nothing (it failed before the build, or was cancelled)")
            continue
        out += [f"Reason: job {number} of {expected}: {line.removeprefix('Reason: ')}" for line in lines if line.startswith("Reason: ")]
    return out, errors


def join_tests(summaries, expected):
    """The lines of the joined ios-ui-summary.txt. `summaries` is {job: lines or None}."""
    verdicts = {number: verdict_of(summaries.get(number), "iOS UI tests: ") for number in range(1, expected + 1)}
    words = set(verdicts.values())
    if "FAILED" in words:
        verdict = "FAILED"
    elif "NOT RUN" in words:
        verdict = "NOT RUN"
    elif "PASSED" in words:
        verdict = "PASSED"
    else:
        verdict = "NOT ASKED"
    tests = skipped = failed = 0
    seconds = minutes = 0.0
    bundles = {}
    for lines in summaries.values():
        for line in lines or []:
            found = EXECUTED.match(line)
            if found:
                tests, skipped, failed = tests + int(found.group(1)), skipped + int(found.group(2)), failed + int(found.group(3))
                seconds = max(seconds, float(found.group(4)))
            counted = BUNDLE_COUNT.match(line)
            if counted:
                key = (counted.group(1), counted.group(2))
                if counted.group(3) is None:
                    bundles.setdefault(key, None)
                else:
                    ran, skip, fail = (int(counted.group(n)) for n in (3, 4, 5))
                    before = bundles.get(key) or (0, 0, 0)
                    bundles[key] = (before[0] + ran, before[1] + skip, before[2] + fail)
            minute = re.match(r"^Minutes: ([\d.]+)", line)
            if minute:
                minutes = max(minutes, float(minute.group(1)))
    out = [f"iOS UI tests: {verdict}"]
    if verdict not in ("NOT ASKED", "NOT RUN") or tests:
        out.append(f"Executed {tests} tests, with {skipped} tests skipped and {failed} failures (0 unexpected) in {seconds:.3f} ({seconds:.3f}) seconds")
        for (kind, bundle), counts in bundles.items():
            head = f"{kind} ({bundle}): "
            out.append(head + (f"{counts[0]} ran, {counts[1]} skipped, {counts[2]} failed" if counts else "not asked"))
        out.append(f"Minutes: {minutes:.1f} (the longest of {expected} jobs)")
    for number in range(1, expected + 1):
        lines = summaries.get(number)
        if lines is None:
            out.append(f"Reason: iPhone job {number} of {expected} reported nothing (it failed before the tests, or was cancelled)")
            continue
        out += [line for line in lines if line.startswith(("FAILED ", "Skipped "))]
        out += [f"Reason: job {number} of {expected}: {line.removeprefix('Reason: ')}" for line in lines if line.startswith("Reason: ")]
    return out


def heading(kind, number, expected, text):
    """One job's log under its heading, for the joined log."""
    return f"===== iPhone job {number} of {expected}: {kind} =====\n{text}\n"


def join(ios_dir, out_dir, expected):
    """Writes the five joined files into `out_dir` from the `ios-results-N` folders of `ios_dir`, for `expected` jobs (a job
    whose folder is missing, or empty, counts as one that reported nothing). Returns the number of jobs that reported."""
    ios_dir, out_dir = Path(ios_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    folders = shard_folders(ios_dir, expected)
    builds = {n: read_lines(folders[n] / "ios-summary.txt") for n in range(1, expected + 1) if n in folders}
    tests = {n: read_lines(folders[n] / "ios-ui-summary.txt") for n in range(1, expected + 1) if n in folders}
    errors = {n: (read_lines(folders[n] / "ios-errors.txt") or []) for n in builds}
    build_lines, joined_errors = join_build(builds, errors, expected)
    (out_dir / "ios-summary.txt").write_text("\n".join(build_lines) + "\n", encoding="utf-8")
    (out_dir / "ios-errors.txt").write_text("".join(error + "\n" for error in joined_errors), encoding="utf-8")
    (out_dir / "ios-ui-summary.txt").write_text("\n".join(join_tests(tests, expected)) + "\n", encoding="utf-8")
    for kind, name in (("build log", "ios.log"), ("test log", "ios-ui.log")):
        parts = []
        for number in range(1, expected + 1):
            path = folders[number] / name if number in folders else None
            text = path.read_text(encoding="utf-8", errors="replace") if path and path.exists() else "(no log)"
            parts.append(heading(kind, number, expected, text))
        (out_dir / name).write_text("".join(parts), encoding="utf-8")
    return len([n for n in builds if builds[n] is not None])
