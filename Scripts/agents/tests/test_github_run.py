"""Tests of github_run.py: pushing a request to TestBuild, finding its run, and bringing the results back.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Nothing reaches GitHub (see remote_case.py): the push goes to a bare repository in a
temporary folder, `gh` is a stand-in, and the clock is pretend, so no test waits.
"""
import json
import subprocess
import unittest
from pathlib import Path

# remote_case puts the scripts' folder on the path, so it is imported first.
from remote_case import (FAILING_LOG, FAILING_SUMMARY, PASSING_LOG, PASSING_SUMMARY, STARTED, RemoteTestCase,
                         results)
import github_run  # noqa: E402

REQUEST = {"areas": ["stats"], "classes": ["FooTests"], "full": False}


class CommitWithRequestTests(RemoteTestCase):
    """The commit that is pushed holds the parent's tree plus the request, and nothing else."""

    def test_the_commit_adds_only_the_request_file_on_top_of_the_parent(self):
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        self.assertEqual(self.git("rev-parse", f"{commit}^"), self.head, "the parent should be the only parent")
        changed = self.git("diff", "--name-status", self.head, commit).splitlines()
        self.assertEqual(changed, [f"A\t{github_run.REQUEST_PATH}"])
        self.assertEqual(json.loads(self.git("show", f"{commit}:{github_run.REQUEST_PATH}")), REQUEST)

    def test_making_the_commit_changes_neither_the_working_tree_nor_the_index_nor_the_branch(self):
        (self.repo / "untracked.txt").write_text("not tracked\n")
        before = (self.git("status", "--porcelain"), self.git("rev-parse", "HEAD"), self.git("ls-files"))
        github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        self.assertEqual((self.git("status", "--porcelain"), self.git("rev-parse", "HEAD"), self.git("ls-files")),
                         before)
        self.assertFalse((self.repo / github_run.REQUEST_PATH).exists())

    def test_an_untracked_file_is_not_in_the_commit(self):
        (self.repo / "untracked.txt").write_text("secret\n")
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        self.assertNotIn("untracked.txt", self.git("ls-tree", "-r", "--name-only", commit))


class PushTests(RemoteTestCase):
    """The push goes to TestBuild, forced, and to nothing else."""

    def test_the_push_makes_only_the_branch_testbuild_at_the_commit(self):
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        github_run.push(self.repo, commit)
        self.assertEqual(self.pushed_refs(), {"refs/heads/TestBuild": commit})
        self.assertEqual(self.pushed_request(commit), REQUEST)

    def test_a_second_push_replaces_the_first_even_when_it_is_not_a_descendant(self):
        first = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: first")
        github_run.push(self.repo, first)
        later = self.commit("later.txt")
        self.git("reset", "-q", "--hard", self.head)  # The next train starts again from the base.
        second = github_run.commit_with_request(self.repo, self.head, {**REQUEST, "areas": ["logs"]}, "second")
        self.assertNotEqual(first, second)
        github_run.push(self.repo, second)
        self.assertEqual(self.pushed_refs(), {"refs/heads/TestBuild": second})
        self.assertNotEqual(later, second)

    def test_a_tree_holding_a_private_path_is_refused_and_nothing_is_pushed(self):
        for private in ("build/orchestrator/train/queue/x.json", "humanQuestions/2026-11-09.md",
                        "humanReports/tokens.md"):
            with self.subTest(private=private):
                parent = self.commit(private)
                commit = github_run.commit_with_request(self.repo, parent, REQUEST, "Test build: x")
                with self.assertRaises(github_run.RemoteFailure) as caught:
                    github_run.push(self.repo, commit)
                self.assertIn("private", str(caught.exception))
                self.assertEqual(self.pushed_refs(), {}, "a refused tree must not reach the remote at all")
                self.git("reset", "-q", "--hard", self.head)

    def test_a_push_that_the_remote_refuses_is_a_remote_failure(self):
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.push(self.repo, commit)
        self.assertIn("push to TestBuild failed", str(caught.exception))

    def test_the_branch_and_the_repository_are_fixed(self):
        self.assertEqual(github_run.BRANCH, "TestBuild")
        self.assertEqual(github_run.REPO, "AERobertAI/TextMouth")


class PrivatePathTests(RemoteTestCase):
    """The review's three cases for the privacy guard, and its neighbours."""

    def refused(self, parent):
        """Pushes a request commit on `parent`; asserts it is refused as private and that nothing reached the remote."""
        commit = github_run.commit_with_request(self.repo, parent, REQUEST, "Test build: x")
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.push(self.repo, commit)
        self.assertIn("private", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {}, "a refused tree must not reach the remote at all")

    def test_names_git_would_quote_are_still_checked(self):
        # git quotes non-ASCII letters and quote marks in `ls-tree --name-only` unless told to use NUL separators.
        for private in ("build/kfx-private/Caf\u00e9.kfx", 'humanReports/a "b".txt', "humanQuestions/line\nbreak.md"):
            with self.subTest(private=private):
                parent = self.commit(private)
                self.refused(parent)
                self.git("reset", "-q", "--hard", self.head)

    def test_a_private_file_in_history_behind_the_tip_is_refused_though_the_tip_no_longer_has_it(self):
        self.commit("build/kfx-private/old.kfx")
        self.git("rm", "-q", "build/kfx-private/old.kfx")
        self.git("commit", "-q", "-m", "remove it again")
        tip = self.git("rev-parse", "HEAD")
        self.assertNotIn("build/kfx-private/old.kfx", self.git("ls-tree", "-r", "--name-only", tip))
        self.refused(tip)

    def test_history_that_origin_already_has_is_not_checked_again(self):
        # The same old commit, once origin's refs hold it, is not something this push would send.
        self.commit("build/kfx-private/old.kfx")
        self.git("rm", "-q", "build/kfx-private/old.kfx")
        self.git("commit", "-q", "-m", "remove it again")
        tip = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", tip)
        commit = github_run.commit_with_request(self.repo, tip, REQUEST, "Test build: x")
        github_run.push(self.repo, commit)
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"])

    def test_a_file_named_like_a_private_folder_is_refused_too(self):
        parent = self.commit("build")
        self.refused(parent)

    def test_a_folder_that_only_starts_like_a_private_one_is_fine(self):
        parent = self.commit("builder/notes.txt")
        commit = github_run.commit_with_request(self.repo, parent, REQUEST, "Test build: x")
        github_run.push(self.repo, commit)
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"])

    def test_humanreports_is_ignored_by_version_control_as_a_folder(self):
        ignored = subprocess.run(["git", "check-ignore", "-q", "humanReports/anything.csv"],
                                 cwd=Path(github_run.__file__).resolve().parents[2]).returncode
        self.assertEqual(ignored, 0, "/humanReports/ must be in .gitignore, not only its .md and .txt files")


class WorkflowGuardTests(RemoteTestCase):
    """Once the workflow is on main, no pushed tree may change .github/workflows."""

    WORKFLOW = "name: Test build\non:\n  push:\n    branches: [TestBuild]\npermissions:\n  contents: read\n"

    def main_has_the_workflow(self):
        """Commits the workflow, and makes it origin's main."""
        main = self.commit(github_run.WORKFLOW_FILE, self.WORKFLOW)
        self.git("update-ref", "refs/remotes/origin/main", main)
        return main

    def push_of(self, parent):
        """A request commit on `parent`, pushed; returns nothing or raises."""
        commit = github_run.commit_with_request(self.repo, parent, REQUEST, "Test build: x")
        github_run.push(self.repo, commit)

    def test_a_tree_with_main_s_workflow_may_be_pushed(self):
        self.push_of(self.main_has_the_workflow())
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"])

    def test_a_branch_that_widens_the_workflow_s_permissions_is_refused(self):
        self.main_has_the_workflow()
        widened = self.commit(github_run.WORKFLOW_FILE, self.WORKFLOW.replace("read", "write"))
        with self.assertRaises(github_run.RemoteFailure) as caught:
            self.push_of(widened)
        self.assertIn(".github/workflows and .github/actions differ", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {})

    def test_a_branch_that_changes_a_local_action_the_workflows_run_is_refused(self):
        # The workflows run .github/actions/setup-xcode, so changing it changes what runs on the public repository.
        self.main_has_the_workflow()
        self.commit(".github/actions/setup-xcode/action.yml", "name: a\n")
        self.git("update-ref", "refs/remotes/origin/main", self.git("rev-parse", "HEAD"))
        changed = self.commit(".github/actions/setup-xcode/action.yml", "name: b\n")
        with self.assertRaises(github_run.RemoteFailure) as caught:
            self.push_of(changed)
        self.assertIn(".github/actions/setup-xcode/action.yml", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {})

    def test_a_branch_that_adds_a_local_action_is_refused(self):
        self.main_has_the_workflow()
        added = self.commit(".github/actions/extra/action.yml", "name: x\n")
        with self.assertRaises(github_run.RemoteFailure):
            self.push_of(added)

    def test_a_branch_that_adds_another_workflow_is_refused(self):
        self.main_has_the_workflow()
        added = self.commit(".github/workflows/extra.yml", "on: push\n")
        with self.assertRaises(github_run.RemoteFailure) as caught:
            self.push_of(added)
        self.assertIn("extra.yml", str(caught.exception))

    def test_a_branch_that_removes_the_workflow_is_refused(self):
        self.main_has_the_workflow()
        self.git("rm", "-q", github_run.WORKFLOW_FILE)
        self.git("commit", "-q", "-m", "remove it")
        with self.assertRaises(github_run.RemoteFailure):
            self.push_of(self.git("rev-parse", "HEAD"))

    def test_before_the_workflow_is_on_main_nothing_is_compared(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)  # main has no workflow yet
        self.push_of(self.commit(github_run.WORKFLOW_FILE, self.WORKFLOW))
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"])

    def test_with_no_origin_main_at_all_nothing_is_compared(self):
        self.push_of(self.commit(github_run.WORKFLOW_FILE, self.WORKFLOW))
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"])

    def test_the_request_file_beside_the_workflows_is_not_a_workflow_change(self):
        self.push_of(self.main_has_the_workflow())  # the commit adds .github/test-request.json
        names = self.git("ls-tree", "-r", "--name-only", self.pushed_refs()["refs/heads/TestBuild"], cwd=self.remote)
        self.assertIn(github_run.REQUEST_PATH, names)


class PushSafetyTests(RemoteTestCase):
    """What keeps a push to one branch of one repository."""

    def test_tags_are_not_pushed_even_when_the_user_asked_git_to_follow_them(self):
        self.git("config", "push.followTags", "true")
        self.git("tag", "-a", "-m", "a release", "v9.9.9", self.head)
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        github_run.push(self.repo, commit)
        self.assertEqual(list(self.pushed_refs()), ["refs/heads/TestBuild"], "an annotated tag reachable from the commit went too")

    def test_origin_must_be_this_repository(self):
        self.patch_github(PUSH_REMOTE="origin")
        self.git("remote", "add", "origin", str(self.remote))
        commit = github_run.commit_with_request(self.repo, self.head, REQUEST, "Test build: x")
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.push(self.repo, commit)
        self.assertIn("push URL", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {}, "nothing is pushed to a remote that is not this repository")

    def test_the_urls_of_this_repository_pass_the_check(self):
        self.patch_github(PUSH_REMOTE="origin")
        for url in github_run.ORIGIN_URLS:
            with self.subTest(url=url):
                self.git("remote", "remove", "origin") if "origin" in self.git("remote").split() else None
                self.git("remote", "add", "origin", url)
                github_run.check_remote(self.repo)

    def test_a_push_url_that_differs_from_the_fetch_url_is_the_one_checked(self):
        self.patch_github(PUSH_REMOTE="origin")
        self.git("remote", "add", "origin", github_run.ORIGIN_URLS[0])
        self.git("remote", "set-url", "--push", "origin", str(self.remote))
        with self.assertRaises(github_run.RemoteFailure):
            github_run.check_remote(self.repo)


class FindingTheRunTests(RemoteTestCase):
    """The run is found by its commit's SHA and its workflow's name, with a limit."""

    def test_the_run_is_found_once_github_has_started_it(self):
        self.gh_state({"list": [[], [], [STARTED]]})
        run = github_run.find_run("a" * 40)
        self.assertEqual(run["databaseId"], 7001)
        self.assertEqual(len(self.pauses), 2, "it should have waited twice for the run to appear")

    def test_the_list_is_asked_for_the_commit_on_the_testbuild_branch_of_the_public_repository(self):
        self.gh_state({"list": [[STARTED]]})
        github_run.find_run("b" * 40)
        call = self.gh_calls()[0]
        self.assertEqual(call[:2], ["run", "list"])
        for flag, value in (("-R", "AERobertAI/TextMouth"), ("--branch", "TestBuild"), ("--commit", "b" * 40)):
            self.assertEqual(call[call.index(flag) + 1], value)

    def test_runs_of_another_commit_or_another_workflow_are_not_ours(self):
        other_sha = {**STARTED, "databaseId": 1, "headSha": "c" * 40}
        other_workflow = {**STARTED, "databaseId": 2, "workflowName": "Check"}
        self.gh_state({"list": [[other_sha, other_workflow, {**STARTED, "databaseId": 3}]]})
        self.assertEqual(github_run.find_run("d" * 40)["databaseId"], 3)

    def test_the_newest_run_of_the_commit_wins(self):
        self.gh_state({"list": [[{**STARTED, "databaseId": 5}, {**STARTED, "databaseId": 9}]]})
        self.assertEqual(github_run.find_run("e" * 40)["databaseId"], 9)

    def test_a_run_that_never_starts_is_a_remote_failure_after_the_limit(self):
        self.gh_state({"list": [[]]})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.find_run("f" * 40)
        self.assertIn("started no run", str(caught.exception))
        self.assertLessEqual(self.now, github_run.RUN_APPEARS_SECONDS + github_run.POLL_SECONDS)

    def test_gh_failing_is_a_remote_failure_after_a_few_tries(self):
        self.gh_state({"fail": "list"})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.find_run("a" * 40)
        self.assertIn("gh run list failed", str(caught.exception))
        self.assertEqual(len(self.gh_calls()), github_run.GH_ATTEMPTS, "it should try the whole number of times and no more")
        self.assertEqual(self.pauses, [github_run.GH_RETRY_SECONDS] * (github_run.GH_ATTEMPTS - 1))

    def test_a_dropped_connection_is_tried_again_and_the_run_is_found(self):
        # The wait for a pushed run on November 10, 2026 ended at one "error connecting to api.github.com".
        self.gh_state({"list": [[STARTED]], "fail_first": {"list": 2}})
        self.assertEqual(github_run.find_run("a" * 40)["databaseId"], 7001)
        self.assertEqual(self.pauses, [github_run.GH_RETRY_SECONDS] * 2)

    def test_a_watch_for_a_run_goes_on_after_a_dropped_connection(self):
        done = {"status": "completed", "conclusion": "success", "url": "https://github.example/runs/7001"}
        self.gh_state({"view": [done], "fail_first": {"view": 2}})
        self.assertEqual(github_run.wait_for_run(STARTED)["conclusion"], "success")

    def test_gh_missing_is_a_remote_failure(self):
        self.patch_github(GH=str(self.folder / "no-gh"))
        with self.assertRaises(github_run.RemoteFailure):
            github_run.find_run("a" * 40)


class WaitingForTheRunTests(RemoteTestCase):
    """A run is waited for until it completes, and no longer than the limit."""

    def test_it_returns_the_final_state_once_the_run_completes(self):
        done = {"status": "completed", "conclusion": "success", "url": "https://github.example/runs/7001"}
        self.gh_state({"view": [{"status": "in_progress", "conclusion": ""}, done]})
        state = github_run.wait_for_run(STARTED)
        self.assertEqual((state["status"], state["conclusion"]), ("completed", "success"))
        self.assertEqual(len(self.pauses), 2)

    def test_a_run_already_completed_is_not_waited_for(self):
        state = github_run.wait_for_run({**STARTED, "status": "completed", "conclusion": "failure"})
        self.assertEqual(state["conclusion"], "failure")
        self.assertEqual(self.pauses, [])

    def test_a_run_that_does_not_end_in_time_is_a_remote_failure(self):
        self.gh_state({"view": [{"status": "in_progress", "conclusion": ""}]})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.wait_for_run(STARTED, limit_minutes=10)
        self.assertIn("had not ended after 10 minutes", str(caught.exception))
        self.assertLess(self.now, 10 * 60 + 2 * github_run.POLL_SECONDS, "it should stop soon after the limit")


class WaitingForAnIdleBranchTests(RemoteTestCase):
    """A push waits while another run is on TestBuild, since a newer push cancels the run before it."""

    # A run that is going on TestBuild, and one that is waiting for a machine.
    GOING = {"databaseId": 6001, "status": "in_progress", "url": "https://github.example/runs/6001",
             "workflowName": "Test build"}
    QUEUED = {**GOING, "databaseId": 6002, "status": "queued", "url": "https://github.example/runs/6002"}
    DONE = {**GOING, "databaseId": 6003, "status": "completed", "url": "https://github.example/runs/6003"}

    def push_it(self, **options):
        """Pushes a request commit of the throwaway repository; returns the commit."""
        commit = github_run.commit_with_request(self.repo, self.head, {"areas": [], "classes": ["A"]}, "m")
        self.commit_pushed = commit
        github_run.push(self.repo, commit, **options)
        return commit

    def test_an_idle_branch_is_pushed_to_at_once(self):
        self.gh_state({"active": [[]], "list": [[STARTED]]})
        commit = self.push_it()
        self.assertEqual(self.pushed_refs(), {"refs/heads/TestBuild": commit})
        self.assertEqual(self.pauses, [])
        self.assertEqual(self.idle_checks(), 1)

    def test_the_idle_check_asks_for_the_runs_on_the_testbuild_branch_of_the_public_repository(self):
        self.gh_state({"active": [[]], "list": [[STARTED]]})
        self.push_it()
        call = self.gh_calls()[0]
        self.assertEqual(call[:2], ["run", "list"])
        for flag, value in (("-R", "AERobertAI/TextMouth"), ("--branch", "TestBuild")):
            self.assertEqual(call[call.index(flag) + 1], value)
        self.assertNotIn("--commit", call)

    def test_a_push_waits_for_a_run_going_and_a_run_queued_and_pushes_only_after_both_are_gone(self):
        self.gh_state({"active": [[self.GOING], [self.QUEUED], [self.QUEUED, self.GOING], []], "list": [[STARTED]]})
        # Nothing may be on the remote while the push is still waiting.
        seen = []
        original = self.pause
        self.patch_github(SLEEP=lambda seconds: (seen.append(dict(self.pushed_refs())), original(seconds)))
        commit = self.push_it()
        self.assertEqual(self.pauses, [github_run.IDLE_POLL_SECONDS] * 3)
        self.assertEqual(seen, [{}, {}, {}], "the push must not happen while a run is on the branch")
        self.assertEqual(self.pushed_refs(), {"refs/heads/TestBuild": commit})

    def test_a_completed_run_and_a_run_of_another_workflow_do_not_hold_a_push_back(self):
        other_workflow = {**self.GOING, "databaseId": 6004, "workflowName": "Check"}
        self.gh_state({"active": [[self.DONE, other_workflow]], "list": [[STARTED]]})
        self.push_it()
        self.assertEqual(self.pauses, [])

    def test_a_branch_that_never_goes_idle_is_a_remote_failure_that_names_the_run_and_pushes_nothing(self):
        self.gh_state({"active": [[self.GOING]]})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            self.push_it(idle_minutes=10)
        message = str(caught.exception)
        self.assertIn("https://github.example/runs/6001", message)
        self.assertIn("after 10 minutes", message)
        self.assertIn("would cancel it", message)
        self.assertEqual(self.pushed_refs(), {}, "a push that gave up must have sent nothing")
        self.assertLess(self.now, 10 * 60 + 2 * github_run.IDLE_POLL_SECONDS, "it should stop soon after the limit")

    def test_the_default_wait_is_as_long_as_a_run_may_take(self):
        self.assertGreaterEqual(github_run.IDLE_WAIT_MINUTES, github_run.RUN_LIMIT_MINUTES)

    def test_gh_failing_while_it_looks_is_a_remote_failure_and_nothing_is_pushed(self):
        self.gh_state({"fail": "list"})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            self.push_it()
        self.assertIn("gh run list failed", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {})

    def test_a_push_that_would_be_refused_anyway_does_not_wait(self):
        self.commit("build/secret.txt")
        self.gh_state({"active": [[self.GOING]]})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.push(self.repo, self.git("rev-parse", "HEAD"))
        self.assertIn("private", str(caught.exception))
        self.assertEqual(self.gh_calls(), [])
        self.assertEqual(self.pauses, [])

    def test_the_wait_is_told_once_which_run_it_is_waiting_for(self):
        self.gh_state({"active": [[self.GOING], [self.GOING], []], "list": [[STARTED]]})
        messages = []
        self.push_it(progress=messages.append)
        self.assertEqual(messages, ["waiting for https://github.example/runs/6001 to end before pushing"])


class PushLockTests(RemoteTestCase):
    """Every push holds one lock from before its idle check until GitHub shows the run of its own push, so that a second
    push cannot check for an idle branch in the gap and cancel the first (November 11, 2026: run 43000459553 was cancelled
    3 seconds after it began by another agent's push). Nothing real runs: gh, the push, and the checks are stand-ins."""

    def setUp(self):
        super().setUp()
        import threading
        import time
        self.events = []
        self.shown = set()      # the commits whose run GitHub lists
        self.lock = threading.Lock()
        # Real time and real threads for the lock; the pause is tiny.
        self.patch_github(CLOCK=time.monotonic, SLEEP=lambda seconds: time.sleep(0.005), LOCK_POLL_SECONDS=0.005,
                          REGISTER_POLL_SECONDS=0.005)
        self.patch_github(check_public_tree=lambda cwd, commit: None, check_workflows=lambda cwd, commit: None,
                          check_remote=lambda cwd: None)
        self.patch_github(wait_until_idle=lambda minutes, progress=None: self.note("idle"))
        self.real_call = github_run.call
        self.patch_github(call=self.fake_call, gh_json=self.fake_gh_json)

    def note(self, what):
        """Records an event with the name of the thread it happened in."""
        import threading
        with self.lock:
            self.events.append((what, threading.current_thread().name))

    def fake_call(self, command, cwd=None, env=None, input_text=None):
        """A git push that succeeds and is noted; any other call (the git that finds the lock's folder) really runs."""
        if command[:2] != ["git", "push"]:
            self.assertEqual(command[:2], ["git", "rev-parse"], command)
            return self.real_call(command, cwd=cwd, env=env, input_text=input_text)
        self.note("push")
        return subprocess.CompletedProcess(command, 0, "", "")

    def fake_gh_json(self, *args):
        """`gh run list --commit SHA` lists the run of a commit once the test has said GitHub shows it."""
        commit = args[args.index("--commit") + 1]
        if commit in self.shown:
            self.note("seen")
            return [{"databaseId": 1, "headSha": commit, "workflowName": github_run.WORKFLOW_NAME}]
        return []

    def start(self, name, commit, **options):
        """Starts a push of `commit` in a thread called `name`; returns the thread."""
        import threading
        thread = threading.Thread(name=name, target=lambda: github_run.push(self.repo, commit, **options))
        thread.start()
        self.addCleanup(thread.join, 30)
        return thread

    def wait_for(self, condition, what):
        """Waits (really, up to 10 seconds) until `condition()` holds."""
        import time
        deadline = time.monotonic() + 10
        while not condition():
            self.assertLess(time.monotonic(), deadline, f"never happened: {what}")
            time.sleep(0.005)

    def test_a_second_push_waits_until_the_first_ones_run_is_seen(self):
        first = self.start("first", "a" * 40)
        self.wait_for(lambda: ("push", "first") in self.events, "the first push")
        second = self.start("second", "b" * 40)
        # The first run is not yet shown: the second must not even check for an idle branch, let alone push.
        import time
        time.sleep(0.3)
        self.assertNotIn(("idle", "second"), self.events, "the second push checked the branch before the first run was seen")
        self.assertNotIn(("push", "second"), self.events)
        self.shown.add("a" * 40)
        first.join(10)
        self.shown.add("b" * 40)
        second.join(10)
        order = [event for event in self.events if event[0] in ("idle", "push", "seen")]
        self.assertEqual(order, [("idle", "first"), ("push", "first"), ("seen", "first"), ("idle", "second"),
                                 ("push", "second"), ("seen", "second")])

    def test_the_lock_is_let_go_when_the_run_is_seen_and_a_later_push_takes_it_at_once(self):
        self.shown.update({"a" * 40, "b" * 40})
        github_run.push(self.repo, "a" * 40)
        github_run.push(self.repo, "b" * 40)
        self.assertEqual([event[0] for event in self.events], ["idle", "push", "seen", "idle", "push", "seen"])

    def test_a_run_that_never_shows_is_given_about_ninety_seconds_then_said_plainly_and_the_lock_is_let_go(self):
        # Pretend time for this test: each pause moves the clock on.
        self.patch_github(CLOCK=lambda: self.now, SLEEP=self.pause, REGISTER_POLL_SECONDS=5)
        messages = []
        github_run.push(self.repo, "a" * 40, progress=messages.append)
        self.assertEqual(len(messages), 1)
        self.assertIn("GitHub showed no run of aaaaaaaa in 90 seconds", messages[0])
        self.assertIn("the push lock is let go", messages[0])
        self.assertGreater(self.now, github_run.REGISTER_SECONDS)
        self.assertLess(self.now, github_run.REGISTER_SECONDS + 10)
        # The lock was let go: the next push takes it without waiting.
        before = self.now
        self.shown.add("b" * 40)
        github_run.push(self.repo, "b" * 40)
        self.assertEqual(self.now, before)

    def test_gh_failing_while_the_run_is_looked_for_is_told_not_raised_and_the_lock_is_let_go(self):
        def failing(*args):
            raise github_run.RemoteFailure("gh run list failed: no network")

        self.patch_github(gh_json=failing)
        messages = []
        github_run.push(self.repo, "a" * 40, progress=messages.append)
        self.assertEqual(len(messages), 1)
        self.assertIn("could not ask GitHub whether aaaaaaaa started a run", messages[0])
        self.assertIn("gh run list failed: no network", messages[0])
        self.patch_github(gh_json=self.fake_gh_json)
        self.shown.add("b" * 40)
        github_run.push(self.repo, "b" * 40)

    def test_a_push_that_fails_lets_the_lock_go(self):
        def refusing(command, cwd=None, env=None, input_text=None):
            return subprocess.CompletedProcess(command, 1, "", "remote: refused")

        self.patch_github(call=refusing)
        with self.assertRaises(github_run.RemoteFailure):
            github_run.push(self.repo, "a" * 40)
        self.patch_github(call=self.fake_call)
        self.shown.add("b" * 40)
        github_run.push(self.repo, "b" * 40)

    def test_a_push_that_cannot_get_the_lock_in_time_is_a_remote_failure_that_pushes_nothing(self):
        import fcntl
        self.patch_github(CLOCK=lambda: self.now, SLEEP=self.pause)
        with open(github_run.push_lock_path(self.repo), "a") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            with self.assertRaises(github_run.RemoteFailure) as caught:
                github_run.push(self.repo, "a" * 40, idle_minutes=1)
        self.assertIn("held the push lock", str(caught.exception))
        self.assertEqual(self.events, [], "nothing was checked or pushed")

    def test_a_push_waiting_for_the_lock_says_so_once(self):
        import fcntl
        messages = []
        ticks = []
        original = github_run.SLEEP

        def release_after_a_few(seconds):
            ticks.append(seconds)
            if len(ticks) == 3:
                fcntl.flock(holder, fcntl.LOCK_UN)
            original(seconds)

        self.patch_github(SLEEP=release_after_a_few)
        self.shown.add("a" * 40)
        with open(github_run.push_lock_path(self.repo), "a") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            github_run.push(self.repo, "a" * 40, progress=messages.append)
        self.assertEqual(messages, ["waiting for another push from this Mac to be seen by GitHub before pushing"])

    def test_the_lock_file_is_in_the_git_common_folder_so_every_worktree_shares_it(self):
        worktree = self.folder / "other-worktree"
        self.git("worktree", "add", "-q", "-b", "other", str(worktree))
        self.assertEqual(github_run.push_lock_path(worktree).resolve(), github_run.push_lock_path(self.repo).resolve())
        self.assertEqual(github_run.push_lock_path(self.repo).name, github_run.PUSH_LOCK_NAME)
        self.assertEqual(github_run.push_lock_path(self.repo).resolve().parent, (self.repo / ".git").resolve())

    def test_a_registration_wait_asks_for_the_pushed_commit_on_testbuild_and_this_workflow_only(self):
        asked = []

        def recording(*args):
            asked.append(args)
            other = {"databaseId": 2, "headSha": "a" * 40, "workflowName": "Check"}
            return [other]

        self.patch_github(gh_json=recording, CLOCK=lambda: self.now, SLEEP=self.pause, REGISTER_POLL_SECONDS=30)
        self.assertFalse(github_run.wait_for_registration("a" * 40))
        first = asked[0]
        self.assertEqual(first[:2], ("run", "list"))
        self.assertEqual(first[first.index("--commit") + 1], "a" * 40)
        self.assertEqual(first[first.index("--branch") + 1], "TestBuild")
        self.assertEqual(first[first.index("-R") + 1], "AERobertAI/TextMouth")


class RunRemotelyTests(RemoteTestCase):
    """The whole round trip: push, find, wait, download."""

    def run_it(self, request=REQUEST):
        """Runs run_remotely from the throwaway repository into a results folder."""
        self.destination = self.folder / "results"
        messages = []
        result = github_run.run_remotely(self.repo, self.head, request, self.destination, "Test build: t",
                                         progress=messages.append)
        return result, messages

    def test_a_passing_run_comes_back_with_its_results_and_its_minutes(self):
        done = {"status": "completed", "conclusion": "success", "url": "https://github.example/runs/7001"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [results(PASSING_SUMMARY, PASSING_LOG)]})
        result, messages = self.run_it()
        self.assertEqual((result["conclusion"], result["downloaded"], result["url"]),
                         ("success", True, "https://github.example/runs/7001"))
        self.assertEqual(self.pushed_refs(), {"refs/heads/TestBuild": result["commit"]})
        self.assertEqual((self.destination / "run-summary.txt").read_text(), PASSING_SUMMARY)
        self.assertEqual((self.destination / "run.log").read_text(), PASSING_LOG)
        self.assertEqual(result["minutes"], round(github_run.POLL_SECONDS / 60, 1))
        self.assertTrue(any("pushed" in m for m in messages))

    def test_a_run_that_waited_its_turn_counts_its_minutes_from_the_push_and_tells_why_it_waited(self):
        done = {"status": "completed", "conclusion": "success", "url": "u"}
        going = {"databaseId": 6001, "status": "in_progress", "url": "https://github.example/runs/6001",
                 "workflowName": "Test build"}
        self.gh_state({"active": [[going], [going], []], "list": [[STARTED]], "view": [done],
                       "download": [results(PASSING_SUMMARY, PASSING_LOG)]})
        result, messages = self.run_it()
        self.assertGreaterEqual(self.now, 2 * github_run.IDLE_POLL_SECONDS)
        self.assertEqual(result["minutes"], round(github_run.POLL_SECONDS / 60, 1), "the wait must not be counted")
        self.assertTrue(any("waiting for https://github.example/runs/6001" in m for m in messages))

    def test_a_run_whose_tests_failed_is_a_result_not_a_remote_failure(self):
        done = {"status": "completed", "conclusion": "failure", "url": "https://github.example/runs/7001"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [results(FAILING_SUMMARY, FAILING_LOG)]})
        result, _ = self.run_it()
        self.assertEqual((result["conclusion"], result["downloaded"]), ("failure", True))

    def test_a_run_with_no_results_comes_back_as_not_downloaded(self):
        done = {"status": "completed", "conclusion": "cancelled", "url": "https://github.example/runs/7001"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [{"fail": True}]})
        result, _ = self.run_it()
        self.assertEqual((result["conclusion"], result["downloaded"]), ("cancelled", False))

    def test_the_results_are_asked_for_by_run_and_artifact_name(self):
        done = {"status": "completed", "conclusion": "success", "url": "u"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [results(PASSING_SUMMARY, PASSING_LOG)]})
        self.run_it()
        call = next(c for c in self.gh_calls() if c[:2] == ["run", "download"])
        self.assertEqual(call[2], "7001")
        self.assertEqual(call[call.index("-n") + 1], github_run.ARTIFACT)

    def test_a_push_that_fails_never_asks_github_about_a_run(self):
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        with self.assertRaises(github_run.RemoteFailure):
            self.run_it()
        self.assertEqual(self.gh_calls_about_the_run(), [])

    def test_the_pushed_commit_is_made_of_tracked_files_only(self):
        (self.repo / "scratch.txt").write_text("untracked\n")
        done = {"status": "completed", "conclusion": "success", "url": "u"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [results(PASSING_SUMMARY, PASSING_LOG)]})
        result, _ = self.run_it()
        names = self.git("ls-tree", "-r", "--name-only", result["commit"], cwd=self.remote).split()
        self.assertEqual(sorted(names), sorted(["base.txt", github_run.REQUEST_PATH]))


if __name__ == "__main__":
    unittest.main()
