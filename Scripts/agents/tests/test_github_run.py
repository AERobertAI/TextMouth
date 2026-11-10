"""Tests of github_run.py: pushing a request to TestBuild, finding its run, and bringing the results back.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Nothing reaches GitHub (see remote_case.py): the push goes to a bare repository in a
temporary folder, `gh` is a stand-in, and the clock is pretend, so no test waits.
"""
import json
import unittest

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

    def test_gh_failing_is_a_remote_failure(self):
        self.gh_state({"fail": "list"})
        with self.assertRaises(github_run.RemoteFailure) as caught:
            github_run.find_run("a" * 40)
        self.assertIn("gh run list failed", str(caught.exception))

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

    def test_a_push_that_fails_never_asks_github_anything(self):
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        with self.assertRaises(github_run.RemoteFailure):
            self.run_it()
        self.assertEqual(self.gh_calls(), [])

    def test_the_pushed_commit_is_made_of_tracked_files_only(self):
        (self.repo / "scratch.txt").write_text("untracked\n")
        done = {"status": "completed", "conclusion": "success", "url": "u"}
        self.gh_state({"list": [[STARTED]], "view": [done], "download": [results(PASSING_SUMMARY, PASSING_LOG)]})
        result, _ = self.run_it()
        names = self.git("ls-tree", "-r", "--name-only", result["commit"], cwd=self.remote).split()
        self.assertEqual(sorted(names), sorted(["base.txt", github_run.REQUEST_PATH]))


if __name__ == "__main__":
    unittest.main()
