"""github_run.py: sends a commit to GitHub Actions to be built and tested, and brings the result back.

The Mac's side of the TestBuild workflow (.github/workflows/test-build.yml).
Both the remote build train (build-train.py --remote) and the remote full
suite (run_suite.py --remote) go through here:

1. `commit_with_request` makes a commit on top of the tree to test, holding
   one more file, the test request the workflow reads. It is made with git's
   plumbing, in a temporary index, so it needs no checkout and touches no
   working tree.
2. `check_public_tree` refuses a tree that holds a path the user keeps
   private, since the repository is public and everything pushed is published.
3. `push` pushes that commit to the branch TestBuild, and to no other ref.
4. `find_run` and `wait_for_run` find the run that push started, by the
   commit's SHA, and wait for it, up to a limit.
5. `download` brings the run's artifacts to a folder.

Every wait has a limit. A step that cannot finish raises RemoteFailure with a
sentence for the agents and the orchestrator; callers then leave nothing half
done. Python 3 standard library only.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The public repository, and the one branch anything is ever pushed to.
REPO = "AERobertAI/TextMouth"
BRANCH = "TestBuild"
# The workflow's name (the `name:` of .github/workflows/test-build.yml), and where
# in the pushed tree it finds its request. A run is found by this name and not by
# `gh run list --workflow FILE`, which looks the file up on the default branch
# and fails until the workflow has been merged into main.
WORKFLOW_NAME = "Test build"
REQUEST_PATH = ".github/test-request.json"
# The artifact the workflow always uploads: the log, the summary, and the verdict.
ARTIFACT = "test-build-results"
# The remote `git push` goes to. Tests replace it with a throwaway repository.
PUSH_REMOTE = "origin"
# The program that talks to GitHub. Tests replace it with a stand-in.
GH = "gh"
# Folders of the checkout the user keeps private; none may be in a pushed tree.
PRIVATE_PREFIXES = ("build/", "humanQuestions/", "humanReports/")
# How long to wait for GitHub to start the run a push caused.
RUN_APPEARS_SECONDS = 5 * 60
# How long a run may take from the push to its end: the workflow's own job
# limit (90 minutes) and the wait for a runner.
RUN_LIMIT_MINUTES = 110
# How often to ask GitHub how the run is going.
POLL_SECONDS = 30
# How long one `gh` or `git` call may take before it counts as failed.
CALL_SECONDS = 120
# The clock and the pause, which tests replace so that no test really waits.
CLOCK = time.monotonic
SLEEP = time.sleep


class RemoteFailure(Exception):
    """A step of the remote run could not finish; the message says which and why."""


def call(command, cwd=None, env=None, input_text=None):
    """Runs `command` with a time limit and returns the finished process, text
    mode. A program that is missing, hangs, or cannot start is a RemoteFailure."""
    try:
        return subprocess.run(command, cwd=cwd, env=env, input=input_text, capture_output=True, text=True,
                              timeout=CALL_SECONDS)
    except subprocess.TimeoutExpired:
        raise RemoteFailure(f"`{' '.join(command[:3])}` did not finish in {CALL_SECONDS} seconds")
    except OSError as error:
        raise RemoteFailure(f"could not start `{command[0]}`: {error}")


def git(cwd, *args, env=None, input_text=None):
    """Runs git in `cwd`; returns its stdout, stripped. A failure is a RemoteFailure."""
    result = call(["git", *args], cwd=cwd, env=env, input_text=input_text)
    if result.returncode != 0:
        raise RemoteFailure(f"git {args[0]} failed: {(result.stderr or result.stdout).strip()[:300]}")
    return result.stdout.strip()


def commit_with_request(cwd, parent, request, message):
    """Makes a commit whose tree is `parent`'s plus the request file, with
    `parent` as its only parent, and returns its SHA. Nothing in `cwd`'s
    working tree or index changes, and the commit holds only what git tracks:
    the tree is `parent`'s, so an untracked file can't be in it."""
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git(cwd, "read-tree", parent, env=env)
        blob = git(cwd, "hash-object", "-w", "--stdin", input_text=json.dumps(request, indent=2) + "\n")
        git(cwd, "update-index", "--add", "--cacheinfo", f"100644,{blob},{REQUEST_PATH}", env=env)
        tree = git(cwd, "write-tree", env=env)
    return git(cwd, "commit-tree", tree, "-p", parent, "-m", message)


def check_public_tree(cwd, commit):
    """Raises RemoteFailure when `commit`'s tree holds a path in a private
    folder. The repository is public, and a push publishes the whole tree."""
    paths = git(cwd, "ls-tree", "-r", "--name-only", commit).splitlines()
    private = [path for path in paths if path.startswith(PRIVATE_PREFIXES)]
    if private:
        raise RemoteFailure(f"refusing to push {commit[:8]}: its tree holds private paths, such as {private[0]}")


def push(cwd, commit):
    """Pushes `commit` to the branch TestBuild with --force, and to nothing else.
    The refspec is built here, from the constant, and from no caller's text."""
    check_public_tree(cwd, commit)
    result = call(["git", "push", "--force", PUSH_REMOTE, f"{commit}:refs/heads/{BRANCH}"], cwd=cwd)
    if result.returncode != 0:
        raise RemoteFailure(f"git push to {BRANCH} failed: {(result.stderr or result.stdout).strip()[:300]}")


def gh_json(*args):
    """Runs `gh` with `args` and returns its output parsed as JSON; a failure
    to run, or an answer that is not JSON, is a RemoteFailure."""
    result = call([GH, *args])
    if result.returncode != 0:
        raise RemoteFailure(f"gh {args[0]} {args[1]} failed: {(result.stderr or result.stdout).strip()[:300]}")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise RemoteFailure(f"gh {args[0]} {args[1]} printed something other than JSON: {result.stdout[:200]!r}")


def find_run(sha):
    """The run of the workflow that `sha`'s push started: its id, url, and
    status. Waits up to RUN_APPEARS_SECONDS for GitHub to start it."""
    started = CLOCK()
    while True:
        runs = gh_json("run", "list", "-R", REPO, "--branch", BRANCH, "--commit", sha,
                       "--json", "databaseId,status,conclusion,headSha,url,workflowName", "--limit", "10")
        # The newest run of this exact commit by this workflow (a rerun has the same SHA).
        ours = [run for run in runs if run.get("headSha") == sha and run.get("workflowName") == WORKFLOW_NAME]
        if ours:
            return max(ours, key=lambda run: run["databaseId"])
        if CLOCK() - started > RUN_APPEARS_SECONDS:
            raise RemoteFailure(f"GitHub started no run for {sha[:8]} in {RUN_APPEARS_SECONDS // 60} minutes; "
                                f"is the workflow on TestBuild, and are Actions on?")
        SLEEP(min(POLL_SECONDS, 10))


def wait_for_run(run, limit_minutes=RUN_LIMIT_MINUTES):
    """Waits for `run` (as find_run returns it) to complete; returns its final
    state: {"status", "conclusion", "url"}. Past `limit_minutes` is a RemoteFailure."""
    started = CLOCK()
    state = run
    while state.get("status") != "completed":
        if CLOCK() - started > limit_minutes * 60:
            raise RemoteFailure(f"run {run['url']} had not ended after {limit_minutes} minutes")
        SLEEP(POLL_SECONDS)
        state = gh_json("run", "view", str(run["databaseId"]), "-R", REPO, "--json", "status,conclusion,url")
        state.setdefault("url", run["url"])
    return state


def download(run_id, destination):
    """Downloads the run's results artifact into the folder `destination`,
    made if need be. Returns True when the artifact was there to download."""
    Path(destination).mkdir(parents=True, exist_ok=True)
    result = call([GH, "run", "download", str(run_id), "-R", REPO, "-n", ARTIFACT, "-D", str(destination)])
    return result.returncode == 0


def run_remotely(cwd, parent, request, destination, message, limit_minutes=RUN_LIMIT_MINUTES, progress=print):
    """Pushes `parent` plus `request` to TestBuild, waits for its run, and
    downloads the results into `destination`. Returns a dictionary with the
    pushed "commit", the run's "url", its "conclusion", the "minutes" from the
    push to the end, and "downloaded" (whether the results artifact came).
    A run that ends without results (cancelled, timed out, or broken before the
    tests) comes back with downloaded False, and the caller decides what that
    means; a step that could not finish raises RemoteFailure."""
    commit = commit_with_request(cwd, parent, request, message)
    started = CLOCK()
    push(cwd, commit)
    progress(f"pushed {commit[:8]} to {BRANCH}; waiting for its run")
    run = find_run(commit)
    progress(f"run {run['url']}")
    state = wait_for_run(run, limit_minutes)
    downloaded = download(run["databaseId"], destination)
    # From the push to the results in hand, which is what the Mac waits for.
    minutes = round((CLOCK() - started) / 60, 1)
    return {"commit": commit, "url": state["url"], "conclusion": state.get("conclusion") or "unknown",
            "minutes": minutes, "downloaded": downloaded}
