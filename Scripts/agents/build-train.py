#!/usr/bin/env python3
"""build-train.py: one build at a time, on a schedule, pooling every agent's work.

On October 31, 2026 the Mac (8 GB of memory) froze under the agents' builds
and had to be restarted. The user asked for "1 build at a time maybe on a
schedule or something every 30 minutes and have the agents pool there work
into each build". So agents no longer build on their own:

- An agent commits its work on its branch and asks the train to test it
  (`request`), naming the test classes and areas it needs. The train tests the
  commit the branch was at when the agent asked; an agent that commits more
  before the train leaves asks again, and the newest request for a branch wins.
- Every hour, on the hour (`loop`), the train waits for the Mac's heavy-work
  lock, first in line, then takes every waiting request, merges each requested
  commit onto a shared base in a worktree of its own, builds once in one build
  folder of its own (kept between trains, so each build is incremental, and
  with half of xcodebuild's usual jobs, so it needs about half the memory),
  runs the union of the classes and areas asked for, and posts each agent its
  result on the message board. It left every 30 minutes until November 8,
  2026, when the user, finding the builds took a lot of CPU, asked for "the
  builds every hour and putting them one after the other".
- A branch that conflicts with the base or with a branch merged before it is
  left out of that train, and its agent is told which files conflicted.
- When the build fails to compile and every compile error is in a file that
  some of the merged branches change, the train builds again without those
  branches, so the others still get their tests, and the branches left out
  are told their errors (November 4, 2026, after two trains in one evening
  were lost to one branch's test files). Every branch left out only for a
  conflict is then merged again, in the order the requests came, with the
  branches that stay; one that now merges cleanly is taken back, and the
  summary says so. A branch that conflicts with one that stays is not.
- The build and tests run under the Mac's heavy-work lock (heavy_lock.py),
  which Scripts/ios/typecheck.py takes too, so no type-check runs beside a
  train's build. When the merged tree has that script, the train then counts
  the iOS errors left in it (a census, under the same lock) and tells each
  agent the ones in the files its branch changes (November 3, 2026).
- The train never runs without that lock. While it waits, no other job takes
  the lock before it; a train that waits LOCK_WAIT_MINUTES leaves its requests
  queued for the next train and tells the orchestrator who held the lock.

Usage:
  build-train.py request --agent SLUG --branch BRANCH [--classes A,B] [--areas x,y] [--note TEXT]
  build-train.py status
  build-train.py run [--base REF]
  build-train.py loop [--every MINUTES (default 60)] [--hours HOURS] [--base REF]

Paths are absolute, so any worktree's agent can call it. Requests, trains,
and results live in the main checkout's gitignored build/orchestrator/train/.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True

# The heavy-work lock, beside this script (python3 -I leaves its folder out of sys.path).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)

ROOT = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth")
TRAIN_DIR = ROOT / "build" / "orchestrator" / "train"
QUEUE = TRAIN_DIR / "queue"
TRAINS = TRAIN_DIR / "trains"
RESULTS = TRAIN_DIR / "results"
LOCK = TRAIN_DIR / "lock"
NEXT = TRAIN_DIR / "next.txt"
WORKTREE = ROOT / ".claude" / "worktrees" / "train"
# The train's build cache. It is kept beside the train's records, not in the user's temporary folder
# under /var/folders, because macOS sweeps that folder of files unused for three days: on 2026-11-04
# the sweep took the cache's precompiled modules (.pcm) between loops, and the next train failed
# before testing. The ".noindex" ending keeps Spotlight from indexing a gigabyte of build products.
DERIVED = TRAIN_DIR / "DerivedData.noindex"
# How long a run may write nothing to its log before its test host counts as
# hung and is killed: longer than any one test has ever taken.
HUNG_RUN_MINUTES = 15
# How long xcodebuild may stay silent after its last test ends. It normally ends
# within half a minute, so this is ample.
HUNG_AFTER_TESTS_MINUTES = 3
BBS = ROOT / ".claude" / "skills" / "agent-bbs" / "scripts" / "bbs.py"
XCODEGEN = "/opt/homebrew/bin/xcodegen"
DEFAULT_BASE = "train/base"
# The fewest gigabytes free on the data volume for a train to start.
MIN_FREE_GB = 3
# How long a train waits for the heavy-work lock before it gives up until the
# next train: less than the hour between trains, so the next leaves on time.
LOCK_WAIT_MINUTES = 50
# Where a running train says what it is doing, for `status`.
STATE = LOCK / "state.txt"
# The board's limit on a post's topic.
TOPIC_LIMIT = 200


def git(*args, cwd=None, check=True):
    """Runs git in `cwd` (the main checkout by default) and returns the result."""
    return subprocess.run(["git", *args], cwd=cwd or ROOT, capture_output=True, text=True, check=check)


def post(to, topic, tag="build"):
    """Posts `topic` to `to` on the message board as the orchestrator, cut to the board's limit."""
    if len(topic) > TOPIC_LIMIT:
        topic = topic[:TOPIC_LIMIT - 1] + "…"
    subprocess.run(["python3", "-I", str(BBS), "post", "orchestrator", "--to", to, "--tag", tag, "--topic", topic],
                   cwd=ROOT, capture_output=True, text=True)


def short_path(path):
    """`path` relative to the main checkout, short enough for a board post."""
    return str(Path(path).relative_to(ROOT))


def free_gigabytes():
    """The gigabytes free on the data volume, as `df -g` reports them."""
    out = subprocess.run(["df", "-g", "/System/Volumes/Data"], capture_output=True, text=True).stdout
    return int(out.splitlines()[1].split()[3])


def split_list(text):
    """A comma-separated option as a list, without empty names."""
    return [name.strip() for name in (text or "").split(",") if name.strip()]


# MARK: - Names

def known_names(cwd):
    """The areas and test classes run-area.py knows in the checkout at `cwd`:
    an unknown name makes run-area.py refuse the whole run, so every name is
    checked against these first."""
    def listed(*args):
        out = subprocess.run(["python3", "-I", "Scripts/test/run-area.py", "--list", *args],
                             cwd=cwd, capture_output=True, text=True).stdout
        return out.splitlines()
    areas = {line.split(":", 1)[0].strip() for line in listed() if ":" in line}
    classes = {line.strip() for line in listed("all") if line.strip()}
    return areas | {"all"}, classes


def unknown_names(request, areas, classes):
    """The names in `request` that are neither a known area nor a known class."""
    return ([a for a in request["areas"] if a not in areas]
            + [c for c in request["classes"] if c not in classes])


# MARK: - Requests

def command_request(args):
    """Queues a request to test `--branch` with the classes and areas named."""
    head = git("rev-parse", "--verify", "--quiet", args.branch, check=False).stdout.strip()
    if not head:
        print(f"build-train: no branch named {args.branch}", file=sys.stderr)
        return 2
    QUEUE.mkdir(parents=True, exist_ok=True)
    # Names are checked for certain against the merged tree at train time, where
    # a class new on the branch exists; main may lack it, so this is a warning.
    areas, classes = known_names(ROOT)
    bad = unknown_names({"areas": split_list(args.areas), "classes": split_list(args.classes)}, areas, classes)
    if bad:
        print(f"build-train: warning: main has no area or class named {', '.join(bad)}. A class is the name "
              f"after `class`, not its file's name (`Scripts/test/run-area.py --list all` lists them). If your "
              f"branch adds them, they run; a name still unknown on the merged tree is left out and you are told.",
              file=sys.stderr)
    request = {
        "agent": args.agent,
        "branch": args.branch,
        "head": head,
        "classes": split_list(args.classes),
        "areas": split_list(args.areas),
        "note": args.note or "",
        "time": datetime.now().isoformat(timespec="seconds"),
    }
    path = QUEUE / f"{int(time.time() * 1000)}-{re.sub(r'[^A-Za-z0-9_-]', '_', args.agent)}.json"
    path.write_text(json.dumps(request, indent=2))
    when = NEXT.read_text().strip() if NEXT.exists() else "when the orchestrator next runs one"
    print(f"queued {args.branch} at {head[:8]} for {args.agent}; the next train leaves {when}. "
          f"Your result will be posted to you on the board and written to {RESULTS / (args.agent + '.md')}.")
    return 0


def command_status(_args):
    """Prints the waiting requests, the next train's time, and what a running train is doing."""
    waiting = sorted(QUEUE.glob("*.json")) if QUEUE.exists() else []
    print(f"next train: {NEXT.read_text().strip() if NEXT.exists() else 'not scheduled'}")
    state = running_train()
    print(f"running now: {'yes, ' + state if state else 'no'}")
    print(f"waiting requests: {len(waiting)}")
    for path in waiting:
        request = json.loads(path.read_text())
        print(f"  {request['agent']}: {request['branch']} ({request['head'][:8]}) "
              f"classes={','.join(request['classes']) or '-'} areas={','.join(request['areas']) or '-'}")
    return 0


# MARK: - A Train

def train_alive():
    """Whether the process named in the train's lock is running."""
    try:
        os.kill(int((LOCK / "pid").read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


def running_train():
    """What the running train says it is doing, or None when no live train holds
    the lock (a train killed mid-run leaves its lock behind, and the next takes it over)."""
    if not train_alive():
        return None
    try:
        return STATE.read_text().strip() or "starting"
    except OSError:
        return "starting"


def set_state(text):
    """Records what the running train is doing, for `status` to print."""
    try:
        STATE.write_text(text + "\n")
    except OSError:
        pass  # Only `status` reads it, so a train never stops over it.


def take_lock():
    """Takes the train's lock, or returns False when a live train holds it."""
    TRAIN_DIR.mkdir(parents=True, exist_ok=True)
    try:
        LOCK.mkdir()
    except FileExistsError:
        if train_alive():
            return False
        # Its owner is gone: take the lock over.
        shutil.rmtree(LOCK, ignore_errors=True)
        LOCK.mkdir()
    (LOCK / "pid").write_text(str(os.getpid()))
    return True


def release_lock():
    """Releases the train's lock."""
    shutil.rmtree(LOCK, ignore_errors=True)


def take_requests(train_dir):
    """Moves every waiting request into the train's folder and returns them,
    keeping only the latest request for each agent and branch."""
    taken = []
    (train_dir / "requests").mkdir(parents=True, exist_ok=True)
    for path in sorted(QUEUE.glob("*.json")):
        target = train_dir / "requests" / path.name
        path.rename(target)
        taken.append(json.loads(target.read_text()))
    latest = {}
    for request in taken:
        latest[(request["agent"], request["branch"])] = request
    return list(latest.values())


def prepare_worktree(base, train_id):
    """Puts the train's worktree on a fresh branch at `base`, with nothing left over."""
    if not WORKTREE.exists():
        git("worktree", "add", "--detach", str(WORKTREE), base)
    git("merge", "--abort", cwd=WORKTREE, check=False)
    git("reset", "-q", "--hard", cwd=WORKTREE)
    git("clean", "-fdq", cwd=WORKTREE)
    git("checkout", "-q", "-B", f"train/run-{train_id}", base, cwd=WORKTREE)


def regenerate_project():
    """Regenerates the Xcode project in the train's worktree; True when it changed."""
    subprocess.run([XCODEGEN, "generate", "-q"], cwd=WORKTREE, capture_output=True, text=True)
    changed = git("status", "--porcelain", "TextMouth.xcodeproj", cwd=WORKTREE).stdout.strip()
    return bool(changed)


def merge_requests(requests, log):
    """Merges the commit each request asked for into the train, not its branch's
    newest, so the train tests what its agent asked for even when the agent has
    committed since; returns (merged, conflicts by agent)."""
    merged, conflicts = [], {}
    for request in requests:
        title = f"{request['branch']} at {request['head'][:8]}"
        result = git("merge", "--no-ff", "-q", "-m", f"Merge {title}", request["head"], cwd=WORKTREE, check=False)
        log.write(f"merge {title}: exit {result.returncode}\n{result.stdout}{result.stderr}\n")
        if result.returncode == 0:
            merged.append(request)
            continue
        unmerged = git("diff", "--name-only", "--diff-filter=U", cwd=WORKTREE).stdout.split()
        if unmerged == ["TextMouth.xcodeproj/project.pbxproj"]:
            # The project file alone conflicts: a fresh generation settles it.
            regenerate_project()
            git("add", "TextMouth.xcodeproj/project.pbxproj", cwd=WORKTREE)
            git("commit", "-q", "--no-edit", cwd=WORKTREE)
            merged.append(request)
        else:
            git("merge", "--abort", cwd=WORKTREE, check=False)
            conflicts[request["agent"]] = (request, unmerged)
    return merged, conflicts


def changed_files(base, commit):
    """The files `commit` changes since its branch left `base`."""
    return set(git("diff", "--name-only", f"{base}...{commit}", check=False).stdout.split())


def errors_in_branch(errors, base, commit):
    """The compile errors (summarize's "ERROR …" lines) that name a file `commit`
    changes since its branch left `base`. The lines give a file by its name
    alone, so a name is matched wherever the branch's file is."""
    names = {Path(path).name for path in changed_files(base, commit)}
    return [error for error in errors if any(name in error for name in names)]


def tests_have_ended(log):
    """Whether a run's log ends with its last test suite's summary, so that all
    its results are already written and only xcodebuild's own wrapping up is left."""
    with open(log, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - 4096))
        tail = handle.read().decode("utf-8", "replace")
    return re.search(r"Test Suite '(Selected tests|All tests)' (passed|failed) at", tail) is not None


def tests_all_passed(log):
    """Whether a run's log says its last test suite passed, for a run whose
    xcodebuild was stopped before it could print its own verdict.

    A host that crashed or quit is restarted by xcodebuild, and the suite after
    the restart can pass though the test that ended the host failed: on
    November 7, 2026 one run's last suite passed and xcodebuild still said
    TEST FAILED. So a restart anywhere in the log means not passed."""
    text = Path(log).read_text(encoding="utf-8", errors="replace")
    if "Restarting after unexpected exit, crash, or test timeout" in text:
        return False
    return re.search(r"Test Suite '(Selected tests|All tests)' passed at", text[-4096:]) is not None


def watch_for_a_hung_run(log, finished, stopped):
    """Ends a run whose log has stopped growing, until `finished` is set, and sets
    `stopped` if it ended xcodebuild itself. Runs on a thread of its own. There are
    two ways a run hangs, and neither ends by itself:

    - A test that waits forever never fails, so xcodebuild waits with it, and every
      agent's request waits behind the heavy-work lock: on November 6, 2026 one
      unbounded `await` held a train for 90 minutes. Killing the host fails that test
      as a crash, and xcodebuild goes on with the tests after it. The pattern is the
      host under the train's own derived data, so it never matches the user's
      installed app.
    - xcodebuild can outlive its tests: the same evening one sat silent for 14 minutes
      after its last test had ended. Its results are in the log by then, so stopping
      it loses nothing. The pattern names the train's derived data, so it never
      matches an xcodebuild of anyone else's.

    A quiet compile has no host and no finished tests, so it is left alone."""
    host = str(DERIVED / "Build" / "Products" / "Debug" / "TextMouth.app" / "Contents" / "MacOS" / "TextMouth")
    runner = f"xcodebuild test .*{re.escape(str(DERIVED))}"
    while not finished.wait(60):
        try:
            idle = time.time() - log.stat().st_mtime
            ended = tests_have_ended(log)
        except OSError:
            continue  # The run has not written its log yet.
        if ended and idle >= HUNG_AFTER_TESTS_MINUTES * 60:
            # SIGTERM, as xcodebuild then says so in the log and exits by itself.
            if subprocess.run(["pkill", "-f", runner], check=False).returncode == 0:
                stopped.set()
                post("orchestrator", f"build-train: xcodebuild was silent for {HUNG_AFTER_TESTS_MINUTES} minutes "
                                     f"after its last test ended, so it was stopped; its results stand: {log}",
                     tag="notice")
        elif idle >= HUNG_RUN_MINUTES * 60 and subprocess.run(["pkill", "-9", "-f", host], check=False).returncode == 0:
            post("orchestrator", f"build-train: a test wrote nothing for {HUNG_RUN_MINUTES} minutes, "
                                 f"so its test host was killed; see the end of {log}", tag="notice")


def run_tests(merged, train_dir):
    """Runs the union of the merged requests' areas and classes; returns run-area's
    output. Names the merged tree does not know are left out, and each request
    keeps a list of its own, so its agent is told."""
    known_areas, known_classes = known_names(WORKTREE)
    areas, classes = [], []
    for request in merged:
        request["dropped"] = unknown_names(request, known_areas, known_classes)
        areas += [a for a in request["areas"] if a in known_areas and a not in areas]
        classes += [c for c in request["classes"] if c in known_classes and c not in classes]
    names = ["all"] if "all" in areas else areas
    if not names and not classes:
        return "no tests ran: every name asked for was unknown\nFAILED"
    command = ["python3", "-I", "Scripts/test/run-area.py", *names]
    if classes and names != ["all"]:
        command += ["--classes", ",".join(classes)]
    # The orchestrator holds all three build slots while trains run, so no
    # agent can start a build of its own; the train itself runs outside them.
    command += ["--jobs", "2", "--no-slot", "--derived-data", str(DERIVED), "--log", str(train_dir / "run.log")]
    (train_dir / "command.txt").write_text(" ".join(command) + "\n")
    # A test that hangs must not hold the train, and every agent behind it, for ever.
    finished, stopped = threading.Event(), threading.Event()
    threading.Thread(target=watch_for_a_hung_run, args=(train_dir / "run.log", finished, stopped), daemon=True).start()
    try:
        result = subprocess.run(command, cwd=WORKTREE, capture_output=True, text=True,
                                env={**os.environ, "BBS_AGENT": "build-train"})
    finally:
        finished.set()
    output = result.stdout + result.stderr
    # xcodebuild stopped by the watchdog says BUILD INTERRUPTED, which would read as
    # a failure of tests that passed: the verdict follows the tests instead.
    if stopped.is_set() and tests_all_passed(train_dir / "run.log"):
        output += "\nPASSED, though xcodebuild had to be stopped after its tests ended\n"
    (train_dir / "run-summary.txt").write_text(output)
    return output


def keep_aside(path, stem, suffix):
    """Renames a run's file to `stem` plus `suffix`, or to `stem-2` and on when an
    earlier retry of the same train already took that name, so every run's log is kept."""
    target = path.with_name(stem + suffix)
    number = 2
    while target.exists():
        target = path.with_name(f"{stem}-{number}{suffix}")
        number += 1
    path.rename(target)


def without_broken_branches(base, train_id, train_dir, merged, conflicts, output, requests=None):
    """Builds the train again without the branches that broke its build.

    When the run compiled nothing and every compile error lies in a file that
    a merged branch changes, the branches whose files hold errors are taken
    out, and the rest are merged and run again, once. A branch that merged
    another one, as a reader branch may merge its neighbour to settle a
    conflict, changes that branch's files too, so it goes with it. Nothing is
    retried when every branch would go, or when an error lies in a file no
    branch changes, which the remaining branches might still break.

    A branch left out of the first merge only for a conflict may have conflicted
    with a branch that has now gone, so every such branch is merged again, in
    the order the requests came, with the branches that stay. Those that merge
    cleanly are kept (taken back); those that still conflict stay left out.
    `requests` is the train's requests in that order; without it, the merged
    branches come before the conflicting ones.

    The first run's log and summary are kept beside the new ones, as
    run-with-all.log and run-summary-with-all.txt.

    Returns (merged, conflicts, output, broken, taken_back): the branches the
    final run holds, the branches still left out for a conflict (with the files
    that conflict), the final run's output, the branches left out for breaking
    the build, each as (request, its errors), and the requests taken back."""
    _, executed, _, errors, _ = summarize(output)
    if not errors or executed != "no tests ran":
        return merged, conflicts, output, [], []
    blamed = [(request, errors_in_branch(errors, base, request["head"])) for request in merged]
    broken = [(request, mine) for request, mine in blamed if mine]
    kept = [request for request, mine in blamed if not mine]
    explained = {error for _, mine in broken for error in mine}
    if not broken or not kept or explained != set(errors):
        return merged, conflicts, output, [], []
    # Every request that can be tried again, in its original order: the branches
    # that stay, and those left out only for a conflict (by identity, since a
    # request is a dict).
    left_for_conflict = [request for request, _ in conflicts.values()]
    candidates = [request for request in (requests if requests is not None else merged + left_for_conflict)
                  if any(request is other for other in kept + left_for_conflict)]
    keep_aside(train_dir / "run.log", "run-with-all", ".log")
    keep_aside(train_dir / "run-summary.txt", "run-summary-with-all", ".txt")
    prepare_worktree(base, train_id)
    with open(train_dir / "merge.log", "a") as log:
        log.write("\n# The build failed to compile in the files of "
                  + ", ".join(request["branch"] for request, _ in broken)
                  + "; merging again without them\n")
        kept, conflicts = merge_requests(candidates, log)
        taken_back = [request for request in kept if any(request is other for other in left_for_conflict)]
        if taken_back:
            log.write("# Taken back, no longer in conflict: "
                      + ", ".join(request["branch"] for request in taken_back) + "\n")
    if kept and regenerate_project():
        git("add", "TextMouth.xcodeproj", cwd=WORKTREE)
        git("commit", "-q", "-m", f"Regenerate the project for train {train_id}", cwd=WORKTREE)
    output = run_tests(kept, train_dir) if kept else ""
    return kept, conflicts, output, broken, taken_back


def ios_census(train_dir):
    """Counts the iOS errors left in the merged tree with Scripts/ios/typecheck.py
    (a census, which reads AppKit imports as UIKit so every use is counted).
    Returns (the summary's count line, the errors as "path:line:col: error: …"
    lines), or None when the merged tree has no such script. The caller holds
    the heavy-work lock, so the check runs with --no-lock."""
    script = WORKTREE / "Scripts" / "ios" / "typecheck.py"
    if not script.exists():
        return None
    result = subprocess.run(["python3", "-I", str(script), "--platform", "ios", "--census", "--no-lock",
                             "--agent", "build-train", "--quiet"],
                            cwd=WORKTREE, capture_output=True, text=True)
    output = result.stdout + result.stderr
    (train_dir / "ios-census.txt").write_text(output)
    count = next((l.strip("- ").strip() for l in output.splitlines() if l.startswith("- Errors in the app:")),
                 "the census did not finish; see ios-census.txt")
    written = next((l for l in output.splitlines() if l.startswith("Written: ")), "")
    errors = []
    if written:
        errors_file = Path(written.split("Written: ", 1)[1].split("/summary.md", 1)[0]) / "errors.txt"
        if errors_file.exists():
            errors = errors_file.read_text().splitlines()
    return count.replace("**", ""), errors


def summarize(output):
    """The run's verdict, its Executed line, its failures, and its compile errors."""
    lines = output.splitlines()
    executed = next((l.strip() for l in reversed(lines) if "Executed" in l), "no tests ran")
    failures = [l.strip() for l in lines if l.strip().startswith("FAILED ") and " at " in l]
    errors = [l.strip() for l in lines if l.strip().startswith("ERROR ")]
    crashed = any(l.strip().startswith("CRASH") for l in lines)
    verdict = "PASSED" if lines and lines[-1].strip().startswith("PASSED") else "FAILED"
    return verdict, executed, failures, errors, crashed


def failure_class(line):
    """The test class a FAILED line names ("FAILED FooTests.testBar at …")."""
    match = re.match(r"FAILED\s+([A-Za-z0-9_]+)\.", line)
    return match.group(1) if match else ""


def report(train_id, base, merged, conflicts, output, train_dir, census=None, broken=(), taken_back=()):
    """Writes each agent's result and posts it to them on the board. `broken`
    holds the branches without_broken_branches left out, each as (request,
    the compile errors in its files), and `taken_back` the requests it merged
    after all, having left them out for a conflict with a branch that broke
    the build."""
    verdict, executed, failures, errors, crashed = summarize(output) if merged else ("NOT RUN", "", [], [], False)
    RESULTS.mkdir(parents=True, exist_ok=True)
    summary = [f"# Train {train_id}", "", f"- Base: {base}",
               f"- Merged: {', '.join(r['branch'] + ' (' + r['agent'] + ')' for r in merged) or 'none'}",
               f"- Verdict: {verdict}", f"- {executed}", f"- Crash: {'yes' if crashed else 'no'}",
               f"- Log: {train_dir / 'run.log'}"]
    if census:
        summary += [f"- iOS census of the merged tree: {census[0]} ({train_dir / 'ios-census.txt'})"]
    summary += [""]
    if errors:
        summary += ["## Compile errors", *[f"- {e}" for e in errors], ""]
    if failures:
        summary += ["## Failures", *[f"- {f}" for f in failures], ""]
    for agent, (request, files) in conflicts.items():
        summary += [f"## Left out: {request['branch']} ({agent}) conflicts in", *[f"- {f}" for f in files], ""]
    for request, mine in broken:
        summary += [f"## Left out: {request['branch']} ({request['agent']}) broke the first build, which then "
                    f"ran again without it (log: {train_dir / 'run-with-all.log'})",
                    *[f"- {e}" for e in mine], ""]
    for request in taken_back:
        summary += [f"## Taken back: {request['branch']} ({request['agent']}) first conflicted with a branch that "
                    f"broke the build, and merged cleanly without it", ""]
    (train_dir / "summary.md").write_text("\n".join(summary))

    for request in merged:
        agent = request["agent"]
        mine = [f for f in failures if failure_class(f) in request["classes"]]
        touched = changed_files(base, request["head"])
        my_errors = errors_in_branch(errors, base, request["head"])
        lines = [f"# {agent}: train {train_id}", "", f"- Your branch: {request['branch']} at {request['head'][:8]}",
                 f"- Verdict of the whole train: {verdict}", f"- {executed}",
                 f"- Failures in the classes you asked for: {len(mine)}", *[f"  - {f}" for f in mine],
                 f"- Compile errors in files your branch changes: {len(my_errors)}", *[f"  - {e}" for e in my_errors]]
        if any(request is other for other in taken_back):
            lines[2:2] = ["- Your branch first conflicted with a branch that broke the build, so it was left out; "
                          "the train then built again without that branch and your branch merged cleanly.", ""]
        ios_note = ""
        if census:
            # The census's paths are repository-relative, as `touched` is.
            my_ios = [e for e in census[1] if e.split(":", 1)[0] in touched]
            lines += [f"- iOS census of the merged tree: {census[0]}",
                      f"- iOS errors in files your branch changes: {len(my_ios)}", *[f"  - {e}" for e in my_ios[:30]]]
            if len(my_ios) > 30:
                lines += [f"  - … and {len(my_ios) - 30} more, in {train_dir / 'ios-census.txt'}"]
            ios_note = f"; iOS errors in your files: {len(my_ios)}"
        lines += [f"- Names left out, unknown to run-area.py on the merged tree: "
                  f"{', '.join(request.get('dropped', [])) or 'none'}",
                  f"- Every failure and error in the train: {train_dir / 'summary.md'}", ""]
        (RESULTS / f"{agent}.md").write_text("\n".join(lines))
        post(agent, f"train {train_id}: {verdict}; yours: {len(mine)} failures, {len(my_errors)} compile errors"
                    f"{ios_note}; see {short_path(RESULTS / (agent + '.md'))}; {executed}")
    for agent, (request, files) in conflicts.items():
        (RESULTS / f"{agent}.md").write_text(
            f"# {agent}: train {train_id}\n\n- {request['branch']} was left out: it conflicts with the base "
            f"or a branch merged before it, in:\n" + "".join(f"  - {f}\n" for f in files) +
            "- Rebase it onto the base, or ask the orchestrator, then request again.\n")
        post(agent, f"train {train_id}: {request['branch']} LEFT OUT; see {short_path(RESULTS / (agent + '.md'))}; "
                    f"conflicts in {', '.join(Path(f).name for f in files)}")
    for request, mine in broken:
        agent = request["agent"]
        (RESULTS / f"{agent}.md").write_text(
            f"# {agent}: train {train_id}\n\n- Your branch: {request['branch']} at {request['head'][:8]}\n"
            f"- The train's first build failed to compile, with errors in files your branch changes, so it was "
            f"built and tested again without your branch:\n" + "".join(f"  - {e}\n" for e in mine) +
            f"- The first build's log: {train_dir / 'run-with-all.log'}\n"
            "- Fix the errors, then request again.\n")
        post(agent, f"train {train_id}: {request['branch']} LEFT OUT, {len(mine)} compile errors in your files; "
                    f"see {short_path(RESULTS / (agent + '.md'))}")
    print("\n".join(summary))


def command_run(args):
    """Runs one train now, if anything waits; returns 0 when it ran, had nothing
    to do, or gave up waiting for the heavy-work lock (its requests then wait)."""
    waiting = list(QUEUE.glob("*.json")) if QUEUE.exists() else []
    if not waiting:
        print("build-train: nothing waits")
        return 0
    if free_gigabytes() < MIN_FREE_GB:
        print(f"build-train: only {free_gigabytes()} GB free; this train waits for the next")
        post("orchestrator", f"build-train: skipped a train, only {free_gigabytes()} GB free", tag="notice")
        return 0
    if not take_lock():
        print("build-train: a train is running")
        return 0
    try:
        def on_wait(holder):
            holder = holder or {}
            set_state(f"waiting for the heavy-work lock, held by {holder.get('name', '?')}")
            post("orchestrator", f"build-train: a train waits for the heavy-work lock, held by "
                                 f"{holder.get('name', '?')} since {holder.get('since', '?')}", tag="notice")
        set_state("waiting for the heavy-work lock")
        # One heavy job at a time, as the user asked: the train waits its turn,
        # first in line, and never runs beside another heavy job.
        with heavy_lock.held("build-train", LOCK_WAIT_MINUTES * 60, on_wait, first=True) as taken:
            if not taken:
                holder = heavy_lock.owner() or {}
                message = (f"build-train: the heavy-work lock stayed busy for {LOCK_WAIT_MINUTES} minutes, held by "
                           f"{holder.get('name', '?')} since {holder.get('since', '?')}; "
                           f"its requests wait for the next train")
                print(message)
                post("orchestrator", message, tag="notice")
                return 0
            # The requests are taken only now, so those made while the train
            # waited for the lock go with it.
            train_id = datetime.now().strftime("%m%d-%H%M")
            train_dir = TRAINS / train_id
            train_dir.mkdir(parents=True, exist_ok=True)
            set_state(f"train {train_id}: merging")
            requests = take_requests(train_dir)
            prepare_worktree(args.base, train_id)
            with open(train_dir / "merge.log", "w") as log:
                merged, conflicts = merge_requests(requests, log)
            if merged and regenerate_project():
                git("add", "TextMouth.xcodeproj", cwd=WORKTREE)
                git("commit", "-q", "-m", f"Regenerate the project for train {train_id}", cwd=WORKTREE)
            output, census, broken, taken_back = "", None, [], []
            if merged:
                set_state(f"train {train_id}: building and testing "
                          + ", ".join(f"{r['branch']} ({r['agent']})" for r in merged))
                output = run_tests(merged, train_dir)
                # The compiler stops at the first files it can't build, so a second
                # broken branch shows only once the first is out: on November 7 one
                # such branch kept every agent's tests from running. So retry, up
                # to three times, while each pass finds branches to leave out.
                for _ in range(3):
                    merged, conflicts, output, more, back = without_broken_branches(
                        args.base, train_id, train_dir, merged, conflicts, output, requests)
                    if not more:
                        break
                    broken += more
                    taken_back += back
                # A branch taken back may itself have broken a later build.
                taken_back = [request for request in taken_back if any(request is other for other in merged)]
                census = ios_census(train_dir)
        report(train_id, args.base, merged, conflicts, output, train_dir, census, broken, taken_back)
    finally:
        release_lock()
    return 0


def command_loop(args):
    """Runs a train every `--every` minutes, at whole multiples of that period (on
    the hour for the default 60, on the hour and the half hour for 30), for
    `--hours` hours. A train still running at its successor's time makes that
    one wait for the next multiple, so trains never overlap."""
    deadline = time.time() + args.hours * 3600
    while time.time() < deadline:
        now = time.time()
        period = args.every * 60
        next_time = (int(now // period) + 1) * period
        NEXT.parent.mkdir(parents=True, exist_ok=True)
        NEXT.write_text(datetime.fromtimestamp(next_time).strftime("%H:%M") + "\n")
        time.sleep(max(0, next_time - time.time()))
        command_run(args)
        sys.stdout.flush()
    NEXT.unlink(missing_ok=True)
    print("build-train: the loop ended")
    return 0


def main(argv):
    """Parses the command line and runs the command."""
    parser = argparse.ArgumentParser(prog="build-train.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    request = sub.add_parser("request", help="queue a branch to test")
    request.add_argument("--agent", required=True)
    request.add_argument("--branch", required=True)
    request.add_argument("--classes", default="")
    request.add_argument("--areas", default="")
    request.add_argument("--note", default="")
    sub.add_parser("status", help="show waiting requests and the next train")
    run = sub.add_parser("run", help="run one train now")
    run.add_argument("--base", default=DEFAULT_BASE)
    loop = sub.add_parser("loop", help="run a train on a schedule")
    loop.add_argument("--every", type=int, default=60)
    loop.add_argument("--hours", type=float, default=12)
    loop.add_argument("--base", default=DEFAULT_BASE)
    args = parser.parse_args(argv)
    return {"request": command_request, "status": command_status,
            "run": command_run, "loop": command_loop}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
