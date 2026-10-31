#!/usr/bin/env python3
"""build-train.py: one build at a time, on a schedule, pooling every agent's work.

On October 31, 2026 the Mac (8 GB of memory) froze under the agents' builds
and had to be restarted. The user asked for "1 build at a time maybe on a
schedule or something every 30 minutes and have the agents pool there work
into each build". So agents no longer build on their own:

- An agent commits its work on its branch and asks the train to test it
  (`request`), naming the test classes and areas it needs.
- Every 30 minutes (`loop`), the train takes every waiting request, merges
  each requested branch onto a shared base in a worktree of its own, builds
  once in one build folder of its own (kept between trains, so each build is
  incremental, and with half of xcodebuild's usual jobs, so it needs about
  half the memory), runs the union of the classes and areas asked for, and
  posts each agent its result on the message board.
- A branch that conflicts with the base or with a branch merged before it is
  left out of that train, and its agent is told which files conflicted.

Usage:
  build-train.py request --agent SLUG --branch BRANCH [--classes A,B] [--areas x,y] [--note TEXT]
  build-train.py status
  build-train.py run [--base REF]
  build-train.py loop [--every MINUTES] [--hours HOURS] [--base REF]

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
import time
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth")
TRAIN_DIR = ROOT / "build" / "orchestrator" / "train"
QUEUE = TRAIN_DIR / "queue"
TRAINS = TRAIN_DIR / "trains"
RESULTS = TRAIN_DIR / "results"
LOCK = TRAIN_DIR / "lock"
NEXT = TRAIN_DIR / "next.txt"
WORKTREE = ROOT / ".claude" / "worktrees" / "train"
DERIVED = Path("/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-train")
BBS = ROOT / ".claude" / "skills" / "agent-bbs" / "scripts" / "bbs.py"
XCODEGEN = "/opt/homebrew/bin/xcodegen"
DEFAULT_BASE = "train/base"
# The fewest gigabytes free on the data volume for a train to start.
MIN_FREE_GB = 3
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


# MARK: - Requests

def command_request(args):
    """Queues a request to test `--branch` with the classes and areas named."""
    head = git("rev-parse", "--verify", "--quiet", args.branch, check=False).stdout.strip()
    if not head:
        print(f"build-train: no branch named {args.branch}", file=sys.stderr)
        return 2
    QUEUE.mkdir(parents=True, exist_ok=True)
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
    """Prints the waiting requests, the next train's time, and whether one is running."""
    waiting = sorted(QUEUE.glob("*.json")) if QUEUE.exists() else []
    print(f"next train: {NEXT.read_text().strip() if NEXT.exists() else 'not scheduled'}")
    print(f"running now: {'yes' if LOCK.exists() else 'no'}")
    print(f"waiting requests: {len(waiting)}")
    for path in waiting:
        request = json.loads(path.read_text())
        print(f"  {request['agent']}: {request['branch']} ({request['head'][:8]}) "
              f"classes={','.join(request['classes']) or '-'} areas={','.join(request['areas']) or '-'}")
    return 0


# MARK: - A Train

def take_lock():
    """Takes the train's lock, or returns False when a live train holds it."""
    TRAIN_DIR.mkdir(parents=True, exist_ok=True)
    try:
        LOCK.mkdir()
    except FileExistsError:
        pid_file = LOCK / "pid"
        try:
            pid = int(pid_file.read_text())
            os.kill(pid, 0)
            return False
        except (OSError, ValueError):
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
    """Merges each request's branch into the train; returns (merged, conflicts by agent)."""
    merged, conflicts = [], {}
    for request in requests:
        result = git("merge", "--no-ff", "--no-edit", "-q", request["branch"], cwd=WORKTREE, check=False)
        log.write(f"merge {request['branch']}: exit {result.returncode}\n{result.stdout}{result.stderr}\n")
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


def changed_files(base, branch):
    """The files `branch` changes since it left `base`."""
    return set(git("diff", "--name-only", f"{base}...{branch}", check=False).stdout.split())


def run_tests(merged, train_dir):
    """Runs the union of the merged requests' areas and classes; returns run-area's output."""
    areas, classes = [], []
    for request in merged:
        areas += [a for a in request["areas"] if a not in areas]
        classes += [c for c in request["classes"] if c not in classes]
    names = ["all"] if "all" in areas else areas
    command = ["python3", "-I", "Scripts/test/run-area.py", *names]
    if classes and names != ["all"]:
        command += ["--classes", ",".join(classes)]
    # The orchestrator holds all three build slots while trains run, so no
    # agent can start a build of its own; the train itself runs outside them.
    command += ["--jobs", "2", "--no-slot", "--derived-data", str(DERIVED), "--log", str(train_dir / "run.log")]
    (train_dir / "command.txt").write_text(" ".join(command) + "\n")
    result = subprocess.run(command, cwd=WORKTREE, capture_output=True, text=True,
                            env={**os.environ, "BBS_AGENT": "build-train"})
    output = result.stdout + result.stderr
    (train_dir / "run-summary.txt").write_text(output)
    return output


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


def report(train_id, base, merged, conflicts, output, train_dir):
    """Writes each agent's result and posts it to them on the board."""
    verdict, executed, failures, errors, crashed = summarize(output) if merged else ("NOT RUN", "", [], [], False)
    RESULTS.mkdir(parents=True, exist_ok=True)
    summary = [f"# Train {train_id}", "", f"- Base: {base}",
               f"- Merged: {', '.join(r['branch'] + ' (' + r['agent'] + ')' for r in merged) or 'none'}",
               f"- Verdict: {verdict}", f"- {executed}", f"- Crash: {'yes' if crashed else 'no'}",
               f"- Log: {train_dir / 'run.log'}", ""]
    if errors:
        summary += ["## Compile errors", *[f"- {e}" for e in errors], ""]
    if failures:
        summary += ["## Failures", *[f"- {f}" for f in failures], ""]
    for agent, (request, files) in conflicts.items():
        summary += [f"## Left out: {request['branch']} ({agent}) conflicts in", *[f"- {f}" for f in files], ""]
    (train_dir / "summary.md").write_text("\n".join(summary))

    for request in merged:
        agent = request["agent"]
        mine = [f for f in failures if failure_class(f) in request["classes"]]
        touched = changed_files(base, request["branch"])
        my_errors = [e for e in errors if any(path in e for path in {Path(t).name for t in touched})]
        lines = [f"# {agent}: train {train_id}", "", f"- Your branch: {request['branch']} at {request['head'][:8]}",
                 f"- Verdict of the whole train: {verdict}", f"- {executed}",
                 f"- Failures in the classes you asked for: {len(mine)}", *[f"  - {f}" for f in mine],
                 f"- Compile errors in files your branch changes: {len(my_errors)}", *[f"  - {e}" for e in my_errors],
                 f"- Every failure and error in the train: {train_dir / 'summary.md'}", ""]
        (RESULTS / f"{agent}.md").write_text("\n".join(lines))
        post(agent, f"train {train_id}: {verdict}; yours: {len(mine)} failures, {len(my_errors)} compile errors; "
                    f"see {short_path(RESULTS / (agent + '.md'))}; {executed}")
    for agent, (request, files) in conflicts.items():
        (RESULTS / f"{agent}.md").write_text(
            f"# {agent}: train {train_id}\n\n- {request['branch']} was left out: it conflicts with the base "
            f"or a branch merged before it, in:\n" + "".join(f"  - {f}\n" for f in files) +
            "- Rebase it onto the base, or ask the orchestrator, then request again.\n")
        post(agent, f"train {train_id}: {request['branch']} LEFT OUT; see {short_path(RESULTS / (agent + '.md'))}; "
                    f"conflicts in {', '.join(Path(f).name for f in files)}")
    print("\n".join(summary))


def command_run(args):
    """Runs one train now, if anything waits; returns 0 when it ran or had nothing to do."""
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
        train_id = datetime.now().strftime("%m%d-%H%M")
        train_dir = TRAINS / train_id
        train_dir.mkdir(parents=True, exist_ok=True)
        requests = take_requests(train_dir)
        prepare_worktree(args.base, train_id)
        with open(train_dir / "merge.log", "w") as log:
            merged, conflicts = merge_requests(requests, log)
        if merged and regenerate_project():
            git("add", "TextMouth.xcodeproj", cwd=WORKTREE)
            git("commit", "-q", "-m", f"Regenerate the project for train {train_id}", cwd=WORKTREE)
        output = run_tests(merged, train_dir) if merged else ""
        report(train_id, args.base, merged, conflicts, output, train_dir)
    finally:
        release_lock()
    return 0


def command_loop(args):
    """Runs a train every `--every` minutes, on the half hour, for `--hours` hours."""
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
    loop.add_argument("--every", type=int, default=30)
    loop.add_argument("--hours", type=float, default=12)
    loop.add_argument("--base", default=DEFAULT_BASE)
    args = parser.parse_args(argv)
    return {"request": command_request, "status": command_status,
            "run": command_run, "loop": command_loop}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
