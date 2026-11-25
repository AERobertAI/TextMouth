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
   to the branch TestBuild, and to no other ref. It holds one exclusive lock, shared by every worktree of
   this repository on this Mac, from before its idle check until GitHub shows the run of its own push (matched
   by the commit's SHA): GitHub takes a few seconds to register a run, and a second sender whose idle check ran
   in that gap found nothing queued, pushed, and cancelled the first (November 11, 2026: run 43000459553, 3
   seconds after it began).
4. `find_run` and `wait_for_run` find the run that push started, by the
   commit's SHA, and wait for it, up to a limit.
5. `download` brings the run's artifacts to a folder.
6. A run watched through a lost connection: a poll that fails is a missed poll (`wait_for_run`), and a run whose
   results were not collected stays recorded with the tree it tested (`record_run`), so that the next send of the
   same tree collects that run's results instead of running it again (`recorded_run`).

Every wait has a limit. A step that cannot finish raises RemoteFailure with a
sentence for the agents and the orchestrator; callers then leave nothing half
done. Python 3 standard library only.
"""
import contextlib
import fcntl
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
# Origin's main, whose workflow files a pushed tree must not change, since origin's main holds test-build.yml
# (see check_workflows).
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
# The lock every push holds (see `push`): its file's name, in the repository's common git folder, which all worktrees share.
PUSH_LOCK_NAME = "textmouth-testbuild-push.lock"
# How long a push waits, after pushing, for GitHub to show its run before it lets go of the lock and says so, and how often
# it looks. About 90 seconds: the run showed within seconds in every run so far.
REGISTER_SECONDS = 90
REGISTER_POLL_SECONDS = 5
# How often a push waiting for the lock looks again.
LOCK_POLL_SECONDS = 2
# How many times in all a failed `gh` call that asks GitHub about runs is made, and the pause between them.
GH_ATTEMPTS = 4
GH_RETRY_SECONDS = 15
# How long one `gh` or `git` call may take before it counts as failed.
CALL_SECONDS = 120
# The conclusions of a run that ended without a verdict on its tests (a cancelled run's results are partial, and none is
# collected later). build-train.py and run_suite.py judge a finished run by this list too.
UNFINISHED_RUNS = ("cancelled", "timed_out", "startup_failure", "skipped", "stale", "action_required")
# The words with which `gh run download` says the run has no such artifact (a run that was cancelled or broke before its
# upload), which no retry will change; any other failure of the download is a lost connection, and is retried.
NO_ARTIFACT_WORDS = ("no artifact", "no valid artifact")
# The words of a failed `gh run view` that say the run is not there at all (a record of a run that has since gone).
NO_SUCH_RUN_WORDS = ("404", "not found", "could not find")
# The parts of a request that do not say what is tested, and so are left out when a recorded run is matched with a new
# request: the train's own name, which is new at every train.
REQUEST_KEYS_NOT_TESTED = ("train",)
# How many times in all a record may be used to collect a run before it is ignored: a record whose run keeps failing to
# be collected must not keep a train from ever pushing.
MAX_COLLECT_TRIES = 3
# What GitHub's annotation on a job says when no runner took it ("The job was not acquired by Runner of type hosted even
# after multiple attempts", run 45667831635 and 45639853419, November 25, 2026, when macOS runners were scarce): a job lost
# to the runner pool, not one whose steps failed. Compared in lower case.
LOST_RUNNER_WORDS = ("was not acquired by runner",)
# The run's attempt that may be re-run: only the first. A run is re-run once at most.
RERUN_ONLY_ATTEMPT = 1
# The step of the workflow's last job that must say `overwrite: true` for a re-run to be safe (see rerun_supported).
RERUN_UPLOAD_STEP = "name: Upload the results"
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
    """Raises RemoteFailure when `commit`'s .github/workflows or .github/actions differ from origin's main, but only once
    origin's main holds .github/workflows/test-build.yml. GitHub runs the workflow files (and the local actions they use)
    of the pushed tree, so a branch that widened `permissions:` or added a step would run it on the public repository;
    once the guard is on, only a change that is already on origin's main may run.

    The guard is on: origin's main has held test-build.yml since the push of main at 0.4.10 (a1214dc0). So a change to
    a workflow or an action runs on TestBuild only once it has been pushed to main, and a change the orchestrator merged
    into the local main is refused until origin's main has it, the safe way round. A main without test-build.yml (a
    fork, or a history before it) turns the guard off, and this returns at once."""
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


def push_lock_path(cwd):
    """The lock file's path: in the git common folder of the repository at `cwd`, which every worktree of the repository
    shares (`git rev-parse --git-common-dir` is relative to `cwd` in the main checkout, absolute in a worktree)."""
    common = Path(git(cwd, "rev-parse", "--git-common-dir"))
    return (common if common.is_absolute() else Path(cwd) / common) / PUSH_LOCK_NAME


@contextlib.contextmanager
def push_lock(cwd, limit_seconds, progress=None):
    """Holds the push lock (an exclusive `flock` on push_lock_path) for the `with` block. Waits for another holder, looking
    again every LOCK_POLL_SECONDS, and raises RemoteFailure after `limit_seconds`. `progress`, when given, is told once
    that it is waiting. The lock goes when the block ends, and when the process does, whatever happens."""
    with open(push_lock_path(cwd), "a") as handle:
        started = CLOCK()
        told = False
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not told and progress:
                    progress("waiting for another push from this Mac to be seen by GitHub before pushing")
                    told = True
                if CLOCK() - started > limit_seconds:
                    raise RemoteFailure(f"not pushed: another push from this Mac held the push lock for {limit_seconds // 60} minutes")
                SLEEP(LOCK_POLL_SECONDS)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def wait_for_registration(commit, progress=None):
    """Waits, up to REGISTER_SECONDS, until GitHub lists a run of this workflow on TestBuild for `commit`: the push has
    then started a run that a later push's idle check will see. Returns whether it did. It never raises: a `gh` that fails,
    or a run that does not show in time, is told plainly through `progress` and the caller goes on (the lock is let go)."""
    started = CLOCK()
    while True:
        try:
            runs = gh_json("run", "list", "-R", REPO, "--branch", BRANCH, "--commit", commit,
                           "--json", "databaseId,headSha,workflowName", "--limit", "10")
        except RemoteFailure as failure:
            if progress:
                progress(f"could not ask GitHub whether {commit[:8]} started a run ({failure}); the push lock is let go")
            return False
        if any(run.get("headSha") == commit and run.get("workflowName") == WORKFLOW_NAME for run in runs):
            return True
        if CLOCK() - started > REGISTER_SECONDS:
            if progress:
                progress(f"GitHub showed no run of {commit[:8]} in {REGISTER_SECONDS} seconds; the push lock is let go, "
                         f"so another push may cancel it")
            return False
        SLEEP(REGISTER_POLL_SECONDS)


def push(cwd, commit, idle_minutes=IDLE_WAIT_MINUTES, progress=None):
    """Pushes `commit` to the branch TestBuild with --force, and to nothing else, once no other run is on it
    (wait_until_idle). Returns the clock's reading as the push began, which a caller measures its run from. The
    refspec is built here, from the constant, and from no caller's text; --no-follow-tags keeps a user's
    push.followTags from sending tags too. The checks come first, so a push that would be refused anyway never waits.

    From before the idle check until GitHub shows the run of this push (wait_for_registration), one exclusive lock is
    held, so that no other push from this Mac (of any worktree) can check for an idle branch in the gap between this push
    and its run being listed, find it idle, and cancel this run."""
    check_public_tree(cwd, commit)
    check_workflows(cwd, commit)
    check_remote(cwd)
    with push_lock(cwd, idle_minutes * 60 + REGISTER_SECONDS + 60, progress):
        wait_until_idle(idle_minutes, progress)
        began = CLOCK()
        result = call(["git", "push", "--force", "--no-follow-tags", PUSH_REMOTE, f"{commit}:refs/heads/{BRANCH}"], cwd=cwd)
        if result.returncode != 0:
            raise RemoteFailure(f"git push to {BRANCH} failed: {(result.stderr or result.stdout).strip()[:300]}")
        wait_for_registration(commit, progress)
    return began


def gh_call(args, final=lambda result: False):
    """Runs `gh` with `args`; returns the finished process of the first call that succeeded or that `final` says no retry
    will change. A call that fails is tried again up to GH_ATTEMPTS times in all, GH_RETRY_SECONDS apart, since a
    connection to api.github.com drops now and then (it ended a wait for a pushed run on November 10, 2026, which was
    going well), and so does one that hangs or cannot start (call() raises RemoteFailure for it): only the last failure
    counts, as the last process, or as the RemoteFailure raised when the last call itself failed."""
    for attempt in range(1, GH_ATTEMPTS + 1):
        try:
            result = call([GH, *args])
        except RemoteFailure:
            if attempt == GH_ATTEMPTS:
                raise
        else:
            if result.returncode == 0 or final(result) or attempt == GH_ATTEMPTS:
                return result
        SLEEP(GH_RETRY_SECONDS)


def gh_json(*args):
    """Runs `gh` with `args` (see gh_call for its tries) and returns its output parsed as JSON; a failure to run, or an
    answer that is not JSON, is a RemoteFailure."""
    result = gh_call(args)
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


def wait_for_run(run, limit_minutes=RUN_LIMIT_MINUTES, progress=None, attempt=1):
    """Waits for `run` (as find_run returns it) to complete; returns its final state: {"status", "conclusion", "url",
    "attempt"}, plus "lost_minutes" (how long, in all, GitHub could not be asked) when any poll was missed. `attempt` is the
    attempt of the run to wait for: a re-run run shows its first attempt's completed state for a moment, which is not the end.

    A poll that fails (gh_json has already tried it GH_ATTEMPTS times) is a missed poll, not the end: the run goes on, on
    GitHub, whatever the Mac can see (the lid closed on battery cut the connection for 35 and 90 minutes on November 17,
    2026, and a passed run's results were never collected). So the wait goes on until `limit_minutes` on CLOCK, which
    does not count the Mac's sleep, and `progress` (when given) is told when the connection is lost and when it is back,
    with how long it was out. Past the limit is a RemoteFailure, which says so when the connection was still lost."""
    started = CLOCK()
    state = run
    lost_since = None
    lost_seconds = 0.0
    last_failure = ""
    while state.get("status") != "completed" or state.get("attempt", attempt) < attempt:
        if CLOCK() - started > limit_minutes * 60:
            still_lost = (f"; GitHub could not be asked for the last {(CLOCK() - lost_since) / 60:.0f} minutes "
                          f"({last_failure})") if lost_since is not None else ""
            raise RemoteFailure(f"run {run['url']} had not ended after {limit_minutes} minutes{still_lost}")
        SLEEP(POLL_SECONDS)
        # Read before the poll, which itself takes GH_ATTEMPTS tries and their pauses: a connection lost during it was
        # lost from its start.
        polled = CLOCK()
        try:
            state = gh_json("run", "view", str(run["databaseId"]), "-R", REPO, "--json", "status,conclusion,url,attempt")
        except RemoteFailure as failure:
            # A missed poll: the last known state stands, and the watch goes on.
            last_failure = str(failure)
            if lost_since is None:
                lost_since = polled
                if progress:
                    progress(f"lost GitHub while watching {run['url']} ({last_failure}); still watching")
            continue
        if lost_since is not None:
            lost_seconds += CLOCK() - lost_since
            lost_since = None
            if progress:
                progress(f"GitHub is back; it could not be asked for {lost_seconds / 60:.0f} minutes in all")
        state.setdefault("url", run["url"])
    if lost_seconds:
        state["lost_minutes"] = round(lost_seconds / 60, 1)
    return state


def is_lost_job(job, annotations, run_conclusion):
    """Whether `job` (a job of `gh api .../runs/ID/jobs`) never had a runner: its annotations (`annotations`, the messages of
    `gh api .../check-runs/ID/annotations`) say no runner acquired it (LOST_RUNNER_WORDS), or it was cancelled before its
    first step (no steps at all) in a run that was not itself cancelled (a newer push cancels the queued jobs of a run, which
    have no steps either). A job that began its steps and failed, or was cancelled in the middle of them (the train's own
    limit), is not lost."""
    if any(words in message.lower() for message in annotations for words in LOST_RUNNER_WORDS):
        return True
    return job.get("conclusion") == "cancelled" and not job.get("steps") and run_conclusion != "cancelled"


def failed_jobs(run_id, run_conclusion):
    """({the names of the jobs of the run's latest attempt that never had a runner}, [the names of the other jobs that
    ended without success]): the jobs are read with `gh api` (see is_lost_job). A job's annotations that cannot be read
    count as none (the job is then lost only by having no steps)."""
    jobs = gh_json("api", f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
    lost, others = [], []
    for job in jobs:
        if job.get("status") != "completed" or job.get("conclusion") in (None, "success", "skipped", "neutral"):
            continue
        try:
            notes = gh_json("api", f"repos/{REPO}/check-runs/{job['id']}/annotations")
            messages = [str(note.get("message", "")) for note in notes if isinstance(note, dict)]
        except RemoteFailure:
            messages = []
        (lost if is_lost_job(job, messages, run_conclusion) else others).append(job.get("name", str(job.get("id"))))
    return lost, others


def rerun_supported(cwd, commit):
    """Whether the workflow of the pushed `commit` can take a re-run: its join job's "Upload the results" step says
    `overwrite: true`. A re-run runs the join again, which uploads the artifact of the same name the first attempt's join
    uploaded, and without `overwrite` that upload fails and the results of the first attempt (a lost job reported as nothing)
    would be downloaded as the new ones."""
    shown = call(["git", "show", f"{commit}:.github/workflows/tests.yml"], cwd=cwd)
    if shown.returncode != 0 or RERUN_UPLOAD_STEP not in shown.stdout:
        return False
    step = shown.stdout[shown.stdout.index(RERUN_UPLOAD_STEP):]
    return "overwrite: true" in step.split("\n      - name:")[0]


def rerun_lost_jobs(cwd, commit, run, state, limit_minutes, progress):
    """After a run ended, re-runs it once if a job never had a runner. Returns (the state to judge, a note or None): the
    note is {"lost": [job names], "rerun": [job names GitHub re-ran besides the join], "lost_again": [job names]} for the
    train's summary, and the state is the new attempt's when it was re-run and waited for.

    Only a job that no runner took triggers it (is_lost_job), only once (the run's first attempt), only for a run whose
    workflow can take it (rerun_supported) and that did not succeed. It runs `gh run rerun ID --failed`, which re-runs every
    failed job and the jobs after them (a single job's re-run cannot be asked for again while the run goes on); a job that
    began and failed is then re-run too, and the note names it. The jobs that passed keep their results (their artifacts
    belong to the run, which is where the join looks)."""
    if state.get("conclusion") == "success" or state.get("attempt", RERUN_ONLY_ATTEMPT) != RERUN_ONLY_ATTEMPT:
        return state, None
    lost, others = failed_jobs(run["databaseId"], state.get("conclusion"))
    if not lost or not rerun_supported(cwd, commit):
        return state, None
    progress(f"{len(lost)} job(s) never had a runner ({'; '.join(lost)}); re-running the failed jobs once")
    result = gh_call(["run", "rerun", str(run["databaseId"]), "-R", REPO, "--failed"])
    if result.returncode != 0:
        said = (result.stderr or result.stdout).strip()[:200]
        progress(f"the re-run was refused: {said}")
        return state, {"lost": lost, "rerun": [], "lost_again": [], "refused": said}
    again = wait_for_run({"databaseId": run["databaseId"], "url": run["url"], "status": "queued"}, limit_minutes, progress,
                         attempt=RERUN_ONLY_ATTEMPT + 1)
    lost_again, _ = failed_jobs(run["databaseId"], again.get("conclusion")) if again.get("conclusion") != "success" else ([], [])
    return again, {"lost": lost, "rerun": others, "lost_again": lost_again}


def has_no_artifact(result):
    """Whether the finished `gh run download` process says the run has no such artifact (NO_ARTIFACT_WORDS)."""
    said = (result.stderr or result.stdout).lower()
    return any(words in said for words in NO_ARTIFACT_WORDS)


def download(run_id, destination):
    """Downloads the run's results artifact into the folder `destination`, made if need be. Returns True when the artifact
    was there to download, and False when the run has none (NO_ARTIFACT_WORDS). Any other failure is a lost connection:
    it is tried again as gh_call does (a call that hangs counts as a failed try), and a download that
    still fails is a RemoteFailure (never a False, which would read as a run with no results)."""
    Path(destination).mkdir(parents=True, exist_ok=True)
    result = gh_call(["run", "download", str(run_id), "-R", REPO, "-n", ARTIFACT, "-D", str(destination)],
                     final=has_no_artifact)
    if result.returncode == 0:
        return True
    if has_no_artifact(result):
        return False
    raise RemoteFailure(f"gh run download failed: {(result.stderr or result.stdout).strip()[:300]}")


def request_key(cwd, parent, request):
    """What a run tested, as a dictionary that two sends share exactly when they test the same thing: the tree of
    `parent` (the tree, not the commit's id, since a merge made twice differs in id and time only) and the request
    without the keys that do not say what is tested (REQUEST_KEYS_NOT_TESTED)."""
    return {"tree": git(cwd, "rev-parse", f"{parent}^{{tree}}"),
            "request": {name: value for name, value in request.items() if name not in REQUEST_KEYS_NOT_TESTED}}


def read_record(path):
    """The run recorded in the file `path`, or None when there is none, it cannot be read, or it is not a record."""
    try:
        record = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return record if isinstance(record, dict) and record.get("run_id") else None


def write_record(path, record):
    """Writes `record` (a dictionary, or None for no record) to the file `path`. A record is never deleted, only replaced
    by an empty one, so that nothing here removes a file. A file that cannot be written is left: the record is a help."""
    try:
        Path(path).write_text(json.dumps(record or {}, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def record_run(path, key, run, commit):
    """Records, in `path`, the run that `commit` started and what it tests (`key`), so that a train that cannot collect
    the results leaves the next send of the same tree a run to collect (see recorded_run). `tries` counts the uses."""
    write_record(path, {**key, "run_id": run["databaseId"], "url": run["url"], "commit": commit, "tries": 0})


def recorded_run(path, key, progress=None):
    """The run to collect instead of pushing again, or None. The file `path` must hold a record whose tree and request
    equal `key` exactly, that has been used fewer than MAX_COLLECT_TRIES times, and whose run GitHub still has, built
    from the recorded commit, and not ended without a verdict (a cancelled run has no results). The run comes back as
    find_run's does, with its current status and conclusion, and the record's commit. A record that does not match is
    ignored, and left for the next push to replace.

    Asking GitHub about the run can fail by a lost connection; that is a RemoteFailure (the record stays, and the train
    waits its turn, rather than pushing a run that would only repeat the first). A run that is not there
    (NO_SUCH_RUN_WORDS) is ignored."""
    record = read_record(path)
    if record is None or record.get("tree") != key["tree"] or record.get("request") != key["request"] \
            or record.get("tries", 0) >= MAX_COLLECT_TRIES:
        return None
    try:
        state = gh_json("run", "view", str(record["run_id"]), "-R", REPO, "--json", "status,conclusion,url,headSha")
    except RemoteFailure as failure:
        if any(words in str(failure).lower() for words in NO_SUCH_RUN_WORDS):
            return None
        raise
    if state.get("headSha") != record.get("commit") or state.get("conclusion") in UNFINISHED_RUNS:
        return None
    write_record(path, {**record, "tries": record.get("tries", 0) + 1})
    if progress:
        progress(f"collecting run {record['url']} of the same tree, which an earlier send left, instead of pushing again")
    return {"databaseId": record["run_id"], "url": state.get("url") or record["url"], "status": state.get("status"),
            "conclusion": state.get("conclusion"), "commit": record["commit"]}


def run_remotely(cwd, parent, request, destination, message, limit_minutes=None, progress=print, pending=None):
    """Pushes `parent` plus `request` to TestBuild, waits for its run, and
    downloads the results into `destination`. Returns a dictionary with the
    pushed "commit", the run's "url", its "conclusion", the "minutes" from the
    push to the end, "downloaded" (whether the results artifact came), and
    "lost_minutes" when GitHub could not be asked for a while (see wait_for_run), and "collected": True
    when the run was an earlier send's, collected rather than pushed (see `pending`).
    A run that ends without results (cancelled, timed out, or broken before the
    tests) comes back with downloaded False, and the caller decides what that
    means; a step that could not finish raises RemoteFailure.

    `pending`, when given, is the path of the file that keeps the run of the last send until its results are in hand:
    the run is recorded once GitHub shows it, and the record is emptied once the results came (or the run has none). A
    send that finds a record of the same tree and request collects that run's results instead of pushing again
    (recorded_run); one that ends in a RemoteFailure leaves the record for the next. `limit_minutes` is the run's own
    limit (RUN_LIMIT_MINUTES, read when this is called, when not given)."""
    limit_minutes = RUN_LIMIT_MINUTES if limit_minutes is None else limit_minutes
    key = request_key(cwd, parent, request) if pending else None
    run = recorded_run(pending, key, progress) if pending else None
    collected = run is not None
    if collected:
        commit, started = run["commit"], CLOCK()
    else:
        commit = commit_with_request(cwd, parent, request, message)
        # The minutes count from the push itself, not from the wait for the run in front of it.
        started = push(cwd, commit, progress=progress)
        progress(f"pushed {commit[:8]} to {BRANCH}; waiting for its run")
        run = find_run(commit)
        if pending:
            record_run(pending, key, run, commit)
    progress(f"run {run['url']}")
    state = wait_for_run(run, limit_minutes, progress)
    # Jobs no runner took lose the whole run's results: re-run them once (see rerun_lost_jobs).
    state, rerun = rerun_lost_jobs(cwd, commit, run, state, limit_minutes, progress)
    downloaded = download(run["databaseId"], destination)
    if pending:
        # The run is over and its results are in hand, or it has none to collect: nothing is left to collect later.
        write_record(pending, None)
    # From the push to the results in hand, which is what the Mac waits for.
    minutes = round((CLOCK() - started) / 60, 1)
    result = {"commit": commit, "url": state["url"], "conclusion": state.get("conclusion") or "unknown",
              "minutes": minutes, "downloaded": downloaded}
    if state.get("lost_minutes"):
        result["lost_minutes"] = state["lost_minutes"]
    if rerun:
        result["rerun"] = rerun
    if collected:
        # The run was an earlier send's: its minutes count from this send's start, not from a push.
        result["collected"] = True
    return result
