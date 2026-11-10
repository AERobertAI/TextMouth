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
3. `push` waits, up to a limit, while another run is queued or going on TestBuild (a newer push
   cancels the older run, so a sender must not cut off a run it did not start), then pushes that commit
   to the branch TestBuild, and to no other ref.
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
# The remote `git push` goes to. Tests replace it with a throwaway repository. While it is the name
# "origin", the push first checks that origin's push URL is this repository's (ORIGIN_URLS).
PUSH_REMOTE = "origin"
ORIGIN_URLS = ("git@github.com:AERobertAI/TextMouth.git", "ssh://git@github.com/AERobertAI/TextMouth.git",
               "https://github.com/AERobertAI/TextMouth.git", "https://github.com/AERobertAI/TextMouth")
# Origin's main, whose workflow files a pushed tree must not change once the workflow is on it.
MAIN_REF = "origin/main"
WORKFLOW_FOLDER = ".github/workflows"
# What a pushed tree may not change either: the repository's own actions, which the workflows run (setup-xcode).
GUARDED_FOLDERS = (WORKFLOW_FOLDER, ".github/actions")
WORKFLOW_FILE = ".github/workflows/test-build.yml"
# The program that talks to GitHub. Tests replace it with a stand-in.
GH = "gh"
# Folders of the checkout the user keeps private; none may be in a pushed tree.
PRIVATE_PREFIXES = ("build/", "humanQuestions/", "humanReports/")
# How long a push waits for the runs already on TestBuild to end before it gives up, in minutes: as long
# as one run may take, since the run in front may be a full suite.
IDLE_WAIT_MINUTES = 125
# How often a push waiting its turn asks GitHub whether TestBuild is idle.
IDLE_POLL_SECONDS = 30
# How long to wait for GitHub to start the run a push caused.
RUN_APPEARS_SECONDS = 5 * 60
# How long a run may take from the push to its end. Its jobs have limits of 5 (plan), 100 (each test job) and 10
# (collect) minutes, 115 in all if every one ran to its limit; the runner script stops the tests at 80 minutes,
# so a run really ends within about 100. This is a little over the 115 and adds a wait for a runner.
RUN_LIMIT_MINUTES = 125
# How often to ask GitHub how the run is going.
POLL_SECONDS = 30
# How many times in all a failed `gh` call that asks GitHub about runs is made, and the pause between them.
GH_ATTEMPTS = 4
GH_RETRY_SECONDS = 15
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


def nul_split(text):
    """The non-empty NUL-separated parts of `text`."""
    return [part for part in text.split("\0") if part]


def is_private(path):
    """Whether `path` is, or is inside, a folder the user keeps private."""
    return any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in PRIVATE_PREFIXES)


def tree_paths(cwd, commit):
    """Every path in `commit`'s tree, exactly as git has it: NUL-separated, so a name with a quote, a
    newline, or a non-ASCII letter is not wrapped in quotes and escapes."""
    result = call(["git", "ls-tree", "-r", "-z", "--name-only", commit], cwd=cwd)
    if result.returncode != 0:
        raise RemoteFailure(f"git ls-tree failed: {(result.stderr or result.stdout).strip()[:300]}")
    return nul_split(result.stdout)


def pushed_paths(cwd, commit):
    """The path of every object the push would send: all that `commit` reaches and no ref of origin does, so the
    commits behind the tip count, and a private file committed and later removed is still found. With
    `-z`, git prints each object's id, then `path=<path>` for those that have one."""
    result = call(["git", "rev-list", "--objects", "-z", commit, "--not", "--remotes=origin"], cwd=cwd)
    if result.returncode != 0:
        raise RemoteFailure(f"git rev-list failed: {(result.stderr or result.stdout).strip()[:300]}")
    return [part[len("path="):] for part in nul_split(result.stdout) if part.startswith("path=")]


def check_public_tree(cwd, commit):
    """Raises RemoteFailure when anything the push would publish is in a private folder: a path of the tip's tree,
    or of any object in the history behind it that origin does not have. The repository is public."""
    for paths in (tree_paths(cwd, commit), pushed_paths(cwd, commit)):
        private = [path for path in paths if is_private(path)]
        if private:
            raise RemoteFailure(f"refusing to push {commit[:8]}: it would publish private paths, such as {private[0]!r}")


def workflow_listing(cwd, ref):
    """The set of `mode type blob<TAB>path` entries under the guarded folders (.github/workflows and .github/actions)
    in `ref`'s tree, or None when `ref` is not a commit here."""
    if call(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], cwd=cwd).returncode != 0:
        return None
    result = call(["git", "ls-tree", "-r", "-z", ref, "--", *GUARDED_FOLDERS], cwd=cwd)
    if result.returncode != 0:
        raise RemoteFailure(f"git ls-tree failed: {(result.stderr or result.stdout).strip()[:300]}")
    return set(nul_split(result.stdout))


def check_workflows(cwd, commit):
    """Once this workflow is on origin's main, raises RemoteFailure when `commit`'s .github/workflows or .github/actions
    differ from main's. GitHub runs the workflow files (and the local actions they use) of the pushed tree, so a merged
    branch that widened `permissions:` or added a step would run it on the public repository; only a change that is
    already on main may run. (A change the
    orchestrator merged into the local main is refused until origin's main has it: the safe way round.) Before the
    workflow is on main there is nothing to compare with, and the check passes."""
    main = workflow_listing(cwd, MAIN_REF)
    if main is None or not any(entry.endswith("\t" + WORKFLOW_FILE) for entry in main):
        return
    ours = workflow_listing(cwd, commit)
    if ours != main:
        changed = sorted({entry.split("\t", 1)[1] for entry in ours ^ main})
        raise RemoteFailure(f"refusing to push {commit[:8]}: its {' and '.join(GUARDED_FOLDERS)} differ from "
                            f"{MAIN_REF}'s in {', '.join(changed)}; only workflow changes already on main may run")


def check_remote(cwd):
    """Raises RemoteFailure when the push would go to something other than this repository: while PUSH_REMOTE is
    the name "origin", its push URL must be one of ORIGIN_URLS."""
    if PUSH_REMOTE != "origin":
        return
    result = call(["git", "remote", "get-url", "--push", "origin"], cwd=cwd)
    url = result.stdout.strip()
    if result.returncode != 0 or url not in ORIGIN_URLS:
        raise RemoteFailure(f"refusing to push: origin's push URL is {url or 'unknown'}, not {ORIGIN_URLS[0]}")


def active_runs():
    """The runs of the workflow on TestBuild that have not completed (queued, waiting, or in progress), as
    {"databaseId", "status", "url"} dictionaries; empty when TestBuild is idle. A push cancels the run before it
    (the workflow's concurrency group), so these are the runs a push now would cut off."""
    runs = gh_json("run", "list", "-R", REPO, "--branch", BRANCH, "--json", "databaseId,status,url,workflowName",
                   "--limit", "10")
    return [run for run in runs if run.get("workflowName") == WORKFLOW_NAME and run.get("status") != "completed"]


def wait_until_idle(limit_minutes=IDLE_WAIT_MINUTES, progress=None):
    """Waits until no run is queued or going on TestBuild, so that a push after it cuts off nobody's run. Asks
    every IDLE_POLL_SECONDS; past `limit_minutes` it raises RemoteFailure that names the run still going, and the
    caller pushes nothing. `progress`, when given, is told once which run it is waiting for."""
    started = CLOCK()
    told = False
    while True:
        busy = active_runs()
        if not busy:
            return
        if not told and progress:
            progress(f"waiting for {busy[0].get('url')} to end before pushing")
            told = True
        if CLOCK() - started > limit_minutes * 60:
            raise RemoteFailure(f"not pushed: {busy[0].get('url')} was still {busy[0].get('status')} on {BRANCH} "
                                f"after {limit_minutes} minutes, and a push would cancel it")
        SLEEP(IDLE_POLL_SECONDS)


def push(cwd, commit, idle_minutes=IDLE_WAIT_MINUTES, progress=None):
    """Pushes `commit` to the branch TestBuild with --force, and to nothing else, once no other run is on it
    (wait_until_idle). Returns the clock's reading as the push began, which a caller measures its run from. The
    refspec is built here, from the constant, and from no caller's text; --no-follow-tags keeps a user's
    push.followTags from sending tags too. The checks come first, so a push that would be refused anyway never waits."""
    check_public_tree(cwd, commit)
    check_workflows(cwd, commit)
    check_remote(cwd)
    wait_until_idle(idle_minutes, progress)
    began = CLOCK()
    result = call(["git", "push", "--force", "--no-follow-tags", PUSH_REMOTE, f"{commit}:refs/heads/{BRANCH}"], cwd=cwd)
    if result.returncode != 0:
        raise RemoteFailure(f"git push to {BRANCH} failed: {(result.stderr or result.stdout).strip()[:300]}")
    return began


def gh_json(*args):
    """Runs `gh` with `args` and returns its output parsed as JSON; a failure
    to run, or an answer that is not JSON, is a RemoteFailure. A call that fails is tried again up to GH_ATTEMPTS
    times in all, GH_RETRY_SECONDS apart, since a connection to api.github.com drops now and then (it ended a wait
    for a pushed run on November 10, 2026, which was going well): only the last failure counts."""
    for attempt in range(1, GH_ATTEMPTS + 1):
        result = call([GH, *args])
        if result.returncode == 0 or attempt == GH_ATTEMPTS:
            break
        SLEEP(GH_RETRY_SECONDS)
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
    # The minutes count from the push itself, not from the wait for the run in front of it.
    started = push(cwd, commit, progress=progress)
    progress(f"pushed {commit[:8]} to {BRANCH}; waiting for its run")
    run = find_run(commit)
    progress(f"run {run['url']}")
    state = wait_for_run(run, limit_minutes)
    downloaded = download(run["databaseId"], destination)
    # From the push to the results in hand, which is what the Mac waits for.
    minutes = round((CLOCK() - started) / 60, 1)
    return {"commit": commit, "url": state["url"], "conclusion": state.get("conclusion") or "unknown",
            "minutes": minutes, "downloaded": downloaded}
