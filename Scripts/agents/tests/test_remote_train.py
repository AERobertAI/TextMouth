"""Tests of build-train.py --remote: a train whose tests run on GitHub Actions.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The train is real, and so are its merges and its push, but all in throwaway places
(see remote_case.py): a repository in a temporary folder is both the main checkout and
the train's worktree, the push goes to a bare repository beside it, `gh` is a stand-in,
and the clock is pretend. The train's records are in the temporary folder too. The
heavy-work lock is replaced by a trap that fails the test if a remote train asks for it.
"""
import io
import json
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest import mock

from remote_case import (FAILING_LOG, FAILING_SUMMARY, PASSING_LOG, PASSING_SUMMARY, STARTED, RemoteTestCase,
                         results)
import github_run  # noqa: E402
import heavy_lock  # noqa: E402
import test_command  # noqa: E402

train = test_command.load_build_train()

# A finished run, as `gh run view` shows one.
DONE = {"status": "completed", "conclusion": "success", "url": "https://github.example/runs/7001"}
DONE_FAILED = {**DONE, "conclusion": "failure"}
DONE_CANCELLED = {**DONE, "conclusion": "cancelled"}
# The summary of a build that did not compile, as run-area.py prints it.
BROKEN_SUMMARY = "no tests ran\nERROR Broken.swift:1:1: error: does not compile\nFAILED in 30 seconds\n"


class RemoteTrainCase(RemoteTestCase):
    """A remote train in a throwaway repository, with its records in a temporary folder."""

    def setUp(self):
        super().setUp()
        records = self.folder / "train"
        self.patch(train, TRAIN_DIR=records, QUEUE=records / "queue", TRAINS=records / "trains",
                   RESULTS=records / "results", LOCK=records / "lock", STATE=records / "lock" / "state.txt",
                   NEXT=records / "next.txt", ROOT=self.repo, WORKTREE=self.repo)
        # Never let a test reach the real records, checkout or lock: every path must be temporary.
        for path in (train.TRAIN_DIR, train.QUEUE, train.TRAINS, train.RESULTS, train.LOCK, train.ROOT,
                     train.WORKTREE):
            self.assertTrue(str(path).startswith(str(self.folder)), path)
        self.assertIs(train.github_run, github_run)
        self.posts = []
        self.patch(train, post=lambda to, topic, tag="build": self.posts.append((to, topic, tag)),
                   short_path=str, regenerate_project=lambda: False,
                   known_names=lambda cwd: ({"all", "stats", "logs"}, {"FooTests", "BarTests"}))

        def no_census(train_dir):
            raise AssertionError("a remote train must not run the iOS census on this Mac")

        def no_lock(*args, **more):
            raise AssertionError("a remote train must not take the heavy-work lock")

        self.patch(train, ios_census=no_census)
        patcher = mock.patch.object(heavy_lock, "held", no_lock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.counter = 0

    def patch(self, module, **values):
        """Sets each of `values` on `module` for this test only."""
        for name, value in values.items():
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, value)

    def branch(self, agent, files, areas=("stats",), classes=("FooTests",)):
        """Makes a branch for `agent` off main that adds `files` (a dict of name to text), queues
        a request for it as `build-train.py request` does, and returns the request."""
        self.git("checkout", "-q", "-b", agent, "main")
        head = ""
        for name, text in files.items():
            head = self.commit(name, text)
        self.git("checkout", "-q", "main")
        request = {"agent": agent, "branch": agent, "head": head, "classes": list(classes), "areas": list(areas),
                   "note": "", "time": "2026-11-09T09:00:00"}
        train.QUEUE.mkdir(parents=True, exist_ok=True)
        self.counter += 1
        (train.QUEUE / f"{self.counter:013d}-{agent}.json").write_text(json.dumps(request))
        return request

    def queued(self):
        """The names of the request files waiting in the queue."""
        return sorted(path.name for path in train.QUEUE.glob("*.json")) if train.QUEUE.exists() else []

    def gh_runs(self, *downloads, view=DONE):
        """Tells the fake gh a run starts, ends as `view` says, and uploads each of `downloads` in turn."""
        self.gh_state({"list": [[STARTED]], "view": [view], "download": list(downloads)})

    def run_train(self, remote=True):
        """Runs one train as the loop does, quietly; returns its outcome."""
        with redirect_stdout(io.StringIO()):
            return train.run_one_train(SimpleNamespace(base="main", remote=remote))

    def result_of(self, agent):
        """The text of an agent's result file."""
        return (train.RESULTS / f"{agent}.md").read_text()

    def posts_to(self, agent):
        """What the train posted to `agent` on the board."""
        return [topic for to, topic, _ in self.posts if to == agent]


class RemoteTrainRunTests(RemoteTrainCase):
    """A train that goes through: merged here, tested there, reported here."""

    def test_the_merged_tree_and_a_request_are_pushed_to_testbuild_and_nothing_else(self):
        self.branch("alpha", {"a.txt": "a"}, areas=["stats"], classes=["FooTests"])
        self.branch("beta", {"b.txt": "b"}, areas=["logs"], classes=["BarTests"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.assertEqual(self.run_train(), "ran")
        refs = self.pushed_refs()
        self.assertEqual(list(refs), ["refs/heads/TestBuild"], "nothing but TestBuild may be pushed")
        request = self.pushed_request(refs["refs/heads/TestBuild"])
        self.assertEqual((request["areas"], request["classes"], request["full"]),
                         (["stats", "logs"], ["FooTests", "BarTests"], False))
        self.assertEqual([r["agent"] for r in request["requests"]], ["alpha", "beta"])
        tree = self.git("ls-tree", "-r", "--name-only", refs["refs/heads/TestBuild"], cwd=self.remote).split()
        self.assertEqual(sorted(tree), sorted(["base.txt", "a.txt", "b.txt", github_run.REQUEST_PATH]),
                         "both branches should be merged into the pushed tree")

    def test_a_long_request_asks_for_more_shards_and_a_short_one_for_one(self):
        self.branch("alpha", {"a.txt": "a"}, areas=["stats"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        # 1500 seconds of tests, by the times file: three shards at 600 seconds each at most.
        self.patch(train, selected_classes=lambda areas, classes: ["BigTests"],
                   shard=SimpleNamespace(load_times=lambda path: {"BigTests": 1500}, shard_count=train.shard.shard_count))
        self.run_train()
        long_request = self.pushed_request(self.pushed_refs()["refs/heads/TestBuild"])
        self.assertEqual(long_request["shards"], 3)

    def test_a_short_request_is_one_shard(self):
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.patch(train, selected_classes=lambda areas, classes: ["SmallTests"])
        self.run_train()
        request = self.pushed_request(self.pushed_refs()["refs/heads/TestBuild"])
        self.assertEqual(request["shards"], 1)

    def test_each_agent_is_told_the_result_and_given_the_runs_link(self):
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        text = self.result_of("alpha")
        self.assertIn("Verdict of the whole train: PASSED", text)
        self.assertIn("Executed 12 tests, with 0 failures", text)
        self.assertIn("Run on GitHub: https://github.example/runs/7001", text)
        self.assertTrue(any("PASSED" in topic for topic in self.posts_to("alpha")), self.posts)
        train_dir = next(train.TRAINS.iterdir())
        self.assertEqual((train_dir / "run.log").read_text(), PASSING_LOG, "the log should be kept in the train's folder")
        self.assertEqual((train_dir / "run-summary.txt").read_text(), PASSING_SUMMARY)
        self.assertEqual(json.loads((train_dir / "remote.json").read_text())["url"], DONE["url"])
        self.assertIn("Run on GitHub", (train_dir / "summary.md").read_text())

    def test_failing_tests_are_a_result_and_the_requests_are_not_put_back(self):
        self.branch("alpha", {"a.txt": "a"}, classes=["FooTests"])
        self.gh_runs(results(FAILING_SUMMARY, FAILING_LOG), view=DONE_FAILED)
        self.assertEqual(self.run_train(), "ran")
        text = self.result_of("alpha")
        self.assertIn("Verdict of the whole train: FAILED", text)
        self.assertIn("Failures in the classes you asked for: 1", text)
        self.assertEqual(self.queued(), [], "a run with failing tests is a result, not a reason to ask again")

    def test_the_train_takes_its_own_lock_and_frees_it_and_never_the_heavy_one(self):
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()  # The heavy-work lock trap in setUp fails the test if the train asks for it.
        self.assertFalse(train.LOCK.exists(), "the train should release its own lock")
        self.assertEqual(self.queued(), [])

    def test_names_the_merged_tree_does_not_know_run_nothing_and_push_nothing(self):
        self.branch("alpha", {"a.txt": "a"}, areas=["nosucharea"], classes=["NoSuchTests"])
        self.assertEqual(self.run_train(), "ran")
        self.assertEqual(self.pushed_refs(), {}, "with nothing to run there is nothing to push")
        self.assertEqual(self.gh_calls(), [])
        self.assertIn("nosucharea", self.result_of("alpha"))

    def test_a_local_train_is_unchanged_by_the_option_existing(self):
        # The default asks for the heavy-work lock (here the trap, which fails the call).
        self.branch("alpha", {"a.txt": "a"})
        self.patch(train, free_gigabytes=lambda: 100)
        with self.assertRaises(AssertionError) as caught:
            self.run_train(remote=False)
        self.assertIn("heavy-work lock", str(caught.exception))
        self.assertEqual(self.pushed_refs(), {})


def with_iphone_build(download, summary, errors=""):
    """A `gh run download` answer that also holds the iPhone build's files, as the join uploads them."""
    return {"files": {**download["files"], "ios-summary.txt": summary, "ios-errors.txt": errors,
                      "ios.log": "xcodebuild output\n"}}


IOS_PASSED = "iOS build: PASSED\nErrors in the app: 0 in 0 files\nMinutes: 3.1\n"


class IPhoneBuildTests(RemoteTrainCase):
    """A remote train reports the iPhone build its run made, by file, as a Mac train's census is reported."""

    def test_a_passing_iphone_build_is_in_the_summary_and_in_each_agents_result_and_the_files_are_kept(self):
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(with_iphone_build(results(PASSING_SUMMARY, PASSING_LOG), IOS_PASSED))
        self.assertEqual(self.run_train(), "ran")
        text = self.result_of("alpha")
        self.assertIn(f"- {train.IOS_BUILD_LABEL}: PASSED, 0 errors in 0 files", text)
        self.assertIn("iOS errors in files your branch changes: 0", text)
        train_dir = next(train.TRAINS.iterdir())
        self.assertIn("iOS build of the merged tree on GitHub", (train_dir / "summary.md").read_text())
        self.assertEqual((train_dir / "ios-summary.txt").read_text(), IOS_PASSED)
        self.assertTrue((train_dir / "ios.log").exists())
        self.assertTrue(any("iOS errors in your files: 0" in topic for topic in self.posts_to("alpha")), self.posts)

    def test_the_errors_are_listed_by_the_files_each_branch_changes(self):
        self.branch("alpha", {"TextMouth/Phone/A.swift": "a"})
        self.branch("beta", {"TextMouth/Services/B.swift": "b"}, classes=["BarTests"])
        errors = ("TextMouth/Phone/A.swift:3:4: error: cannot find 'NSWorkspace' in scope\n"
                  "TextMouth/Services/B.swift:9:1: error: expected declaration\n"
                  "TextMouth/Elsewhere.swift:1:1: error: nobody here changed this\n")
        summary = "iOS build: FAILED\nErrors in the app: 3 in 3 files\nMinutes: 4.0\n"
        self.gh_runs(with_iphone_build(results(PASSING_SUMMARY, PASSING_LOG), summary, errors))
        self.run_train()
        alpha, beta = self.result_of("alpha"), self.result_of("beta")
        self.assertIn("iOS errors in files your branch changes: 1", alpha)
        self.assertIn("TextMouth/Phone/A.swift:3:4: error: cannot find 'NSWorkspace' in scope", alpha)
        self.assertNotIn("B.swift", alpha)
        self.assertIn("iOS errors in files your branch changes: 1", beta)
        self.assertIn("TextMouth/Services/B.swift:9:1: error: expected declaration", beta)
        self.assertNotIn("Elsewhere", alpha + beta)
        self.assertIn("FAILED, 3 errors in 3 files", alpha)

    def test_a_failed_iphone_build_does_not_change_the_trains_verdict_on_the_tests(self):
        self.branch("alpha", {"a.txt": "a"})
        summary = "iOS build: FAILED\nErrors in the app: 0 in 0 files\nReason: the runner image lacks the iOS Simulator platform or SDK that this build needs\n"
        self.gh_runs(with_iphone_build(results(PASSING_SUMMARY, PASSING_LOG), summary))
        self.assertEqual(self.run_train(), "ran")
        text = self.result_of("alpha")
        self.assertIn("Verdict of the whole train: PASSED", text)
        self.assertIn("FAILED, 0 errors in 0 files (the runner image lacks the iOS Simulator platform or SDK", text)
        self.assertEqual(self.queued(), [], "an iPhone build that failed is a result, not a reason to ask again")

    def test_a_run_with_no_iphone_build_has_no_iphone_line(self):
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        self.assertNotIn("iOS", self.result_of("alpha").replace("iOS errors", "").replace("Names left out", ""))
        self.assertNotIn("iOS build", (next(train.TRAINS.iterdir()) / "summary.md").read_text())

    def test_the_remote_train_never_runs_the_census_on_this_mac(self):
        # setUp replaces ios_census with a trap; a train with an iPhone build to report passes through it.
        self.branch("alpha", {"a.txt": "a"})
        self.gh_runs(with_iphone_build(results(PASSING_SUMMARY, PASSING_LOG), IOS_PASSED))
        self.assertEqual(self.run_train(), "ran")

    def test_an_unreadable_summary_is_read_as_what_it_is(self):
        folder = self.folder / "ios-dir"
        folder.mkdir()
        (folder / "ios-summary.txt").write_text("iOS build: NOT RUN\nReason: its job reported nothing\n")
        count, errors, label = train.remote_ios_result(folder)
        self.assertEqual((count, errors, label), ("NOT RUN (its job reported nothing)", [], train.IOS_BUILD_LABEL))
        self.assertIsNone(train.remote_ios_result(self.folder / "no-such-folder"))


class NotRunOnGitHubTests(RemoteTrainCase):
    """A remote result names what the runner left out of what an agent asked for (review finding 3)."""

    SKIPS = ("ReaderAudioFailureTests  # it plays audio; it still runs on the development Mac\n"
             "FooTests.testHangs  # it hangs there; it still runs on the development Mac")

    def branch_with_skips(self, agent, files=None, **more):
        """A branch whose tree carries a skips file."""
        return self.branch(agent, {"Scripts/agents/runner-skips.conf": self.SKIPS, **(files or {})}, **more)

    def test_an_agent_is_told_which_of_its_classes_the_runner_skipped_and_why(self):
        self.branch_with_skips("alpha", classes=["ReaderAudioFailureTests", "FooTests", "BarTests"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.patch(train, selected_classes=lambda areas, classes: ["ReaderAudioFailureTests", "FooTests", "BarTests"])
        self.assertEqual(self.run_train(), "ran")
        text = self.result_of("alpha")
        self.assertIn("- Not run on GitHub, no verdict: ReaderAudioFailureTests (it plays audio; it still runs on the development Mac)", text)
        self.assertIn("- Not run on GitHub, no verdict: FooTests.testHangs (it hangs there; it still runs on the development Mac)", text)
        self.assertIn("local `build-train.py run`", text, "the result says how to run them here")
        self.assertTrue(any("NOT RUN on GitHub" in topic for topic in self.posts_to("alpha")), self.posts)
        self.assertIn("Verdict of the whole train: PASSED", text, "a PASSED verdict is for what ran, and the lines say what did not")

    def test_an_agent_who_asked_for_nothing_the_runner_skips_hears_nothing_of_it(self):
        self.branch_with_skips("alpha", classes=["BarTests"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.patch(train, selected_classes=lambda areas, classes: ["BarTests"])
        self.run_train()
        self.assertNotIn("Not run on GitHub", self.result_of("alpha"))

    def test_each_agent_hears_only_about_its_own_request(self):
        self.branch_with_skips("alpha", classes=["ReaderAudioFailureTests"])
        self.branch("beta", {"b.txt": "b"}, classes=["BarTests"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.patch(train, selected_classes=lambda areas, classes: list(classes) or ["BarTests"])
        self.run_train()
        self.assertIn("Not run on GitHub", self.result_of("alpha"))
        self.assertNotIn("Not run on GitHub", self.result_of("beta"))

    def test_the_classes_of_an_area_count_as_asked_for(self):
        self.branch_with_skips("alpha", areas=["stats"], classes=[])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.patch(train, selected_classes=lambda areas, classes: ["ReaderAudioFailureTests", "BarTests"])
        self.run_train()
        self.assertIn("Not run on GitHub, no verdict: ReaderAudioFailureTests", self.result_of("alpha"))

    def test_a_request_of_only_skipped_classes_pushes_nothing_and_says_why_it_has_no_verdict(self):
        self.branch_with_skips("alpha", classes=["ReaderAudioFailureTests"])
        self.patch(train, selected_classes=lambda areas, classes: ["ReaderAudioFailureTests"])
        self.assertEqual(self.run_train(), "ran")
        self.assertEqual(self.pushed_refs(), {}, "with nothing to run there is nothing to push")
        text = self.result_of("alpha")
        self.assertIn("Not run on GitHub, no verdict: ReaderAudioFailureTests", text)
        self.assertIn("the GitHub runner does not run", next(train.TRAINS.iterdir()).joinpath("run-summary.txt").read_text())

    def test_a_malformed_skips_file_in_the_merged_tree_stops_the_train_and_puts_the_requests_back(self):
        self.branch("alpha", {"Scripts/agents/runner-skips.conf": "ReaderAudioFailureTests,  # a stray comma"})
        self.patch(train, selected_classes=lambda areas, classes: ["FooTests"])
        self.assertEqual(self.run_train(), "failed")
        self.assertEqual(len(self.queued()), 1)
        self.assertIn("malformed", next(train.TRAINS.iterdir()).joinpath("remote-failure.txt").read_text())


class RemoteTrainFailureTests(RemoteTrainCase):
    """A push or run that fails leaves nothing half done: the requests wait for the next train."""

    def assert_put_back(self, requests):
        """Checks that every request is queued again, and the agents were told."""
        self.assertEqual(len(self.queued()), len(requests), "every request should be back in the queue")
        self.assertFalse(train.LOCK.exists(), "the train should release its own lock")
        for request in requests:
            agent = request["agent"]
            self.assertTrue(any("waits for the next train" in topic for topic in self.posts_to(agent)), self.posts)
            self.assertIn("back in the queue", self.result_of(agent))
        self.assertTrue(any(to == "orchestrator" and tag == "notice" for to, _, tag in self.posts), self.posts)
        train_dir = next(train.TRAINS.iterdir())
        self.assertTrue((train_dir / "remote-failure.txt").exists())
        self.assertFalse((train_dir / "summary.md").exists(), "a failed train reports no result")

    def test_a_push_that_fails_puts_the_requests_back_and_tells_each_agent(self):
        requests = [self.branch("alpha", {"a.txt": "a"}), self.branch("beta", {"b.txt": "b"})]
        before = self.queued()
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)
        self.assertEqual(self.queued(), before, "the requests should keep their names, so their order")
        self.assertEqual(self.gh_calls_about_the_run(), [])

    def test_a_run_cancelled_by_a_newer_push_puts_the_requests_back(self):
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_runs({"fail": True}, view=DONE_CANCELLED)
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)
        self.assertIn("cancelled", next(train.TRAINS.iterdir()).joinpath("remote-failure.txt").read_text())

    def test_a_cancelled_run_is_no_verdict_even_when_it_uploaded_partial_results(self):
        # The workflow uploads whatever it has even when it is cancelled; a half-run is not a result.
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_runs(results(FAILING_SUMMARY, FAILING_LOG), view=DONE_CANCELLED)
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)

    def test_a_run_that_leaves_no_results_puts_the_requests_back(self):
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_runs({"fail": True}, view=DONE_FAILED)
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)

    def test_a_run_that_never_starts_puts_the_requests_back(self):
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_state({"list": [[]]})
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)

    def test_a_run_that_never_ends_puts_the_requests_back(self):
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_state({"list": [[STARTED]], "view": [{"status": "in_progress", "conclusion": ""}]})
        self.patch_github(RUN_LIMIT_MINUTES=5)
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)

    def test_gh_failing_puts_the_requests_back(self):
        requests = [self.branch("alpha", {"a.txt": "a"})]
        self.gh_state({"fail": "list"})
        self.assertEqual(self.run_train(), "failed")
        self.assert_put_back(requests)

    def test_the_requests_put_back_go_with_the_next_train_without_asking_again(self):
        self.branch("alpha", {"a.txt": "a"})
        good_remote = github_run.PUSH_REMOTE
        self.patch_github(PUSH_REMOTE=str(self.folder / "no-such-remote.git"))
        self.assertEqual(self.run_train(), "failed")
        # The next train, with the push working again.
        self.patch_github(PUSH_REMOTE=good_remote)
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.assertEqual(self.run_train(), "ran")
        self.assertEqual(self.queued(), [])
        self.assertIn("Verdict of the whole train: PASSED", self.result_of("alpha"))


class RemoteTrainRetryTests(RemoteTrainCase):
    """A build that fails to compile is retried without the branch that broke it, on GitHub again."""

    def test_the_branch_that_broke_the_build_is_left_out_and_the_rest_run_in_a_second_run(self):
        self.branch("broken", {"Broken.swift": "does not compile"})
        self.branch("fine", {"fine.txt": "fine"})
        self.gh_runs(results(BROKEN_SUMMARY, "compile error\n"), results(PASSING_SUMMARY, PASSING_LOG))
        self.assertEqual(self.run_train(), "ran")
        runs = [call for call in self.gh_calls() if call[:2] == ["run", "download"]]
        self.assertEqual(len(runs), 2, "a second run should have tested the rest")
        refs = self.pushed_refs()
        request = self.pushed_request(refs["refs/heads/TestBuild"])
        self.assertEqual([r["agent"] for r in request["requests"]], ["fine"], "the last push leaves the broken one out")
        self.assertIn("first build failed to compile", self.result_of("broken"))
        self.assertTrue(any("LEFT OUT" in topic for topic in self.posts_to("broken")), self.posts)
        self.assertIn("Verdict of the whole train: PASSED", self.result_of("fine"))
        train_dir = next(train.TRAINS.iterdir())
        self.assertTrue((train_dir / "run-with-all.log").exists(), "the first run's log should be kept")
        self.assertTrue((train_dir / "remote-1").is_dir() and (train_dir / "remote-2").is_dir())
        self.assertEqual(self.queued(), [])


class NextTrainTimeTests(unittest.TestCase):
    """When the loop's next train leaves."""

    HOUR = 3600

    def args(self, **more):
        """A loop's arguments: hourly, not remote, no early trains, unless `more` says otherwise."""
        return SimpleNamespace(every=60, soon=0, remote=False, **more)

    def test_by_default_a_train_leaves_on_the_next_hour(self):
        now = 5 * self.HOUR + 20 * 60
        self.assertEqual(train.next_train_time(self.args(), now, []), 6 * self.HOUR)

    def test_a_train_leaves_on_the_hour_whether_or_not_a_request_waits(self):
        now = 5 * self.HOUR + 20 * 60
        self.assertEqual(train.next_train_time(self.args(), now, [now - 60]), 6 * self.HOUR)

    def test_exactly_on_the_hour_the_next_train_is_an_hour_later(self):
        self.assertEqual(train.next_train_time(self.args(), 5 * self.HOUR, []), 6 * self.HOUR)

    def test_a_failed_train_s_retry_time_holds_back_the_next_one(self):
        now = 5 * self.HOUR
        self.assertEqual(train.next_train_time(self.args(), now, [], not_before=now + 2 * self.HOUR),
                         now + 2 * self.HOUR)

    def test_with_soon_no_request_means_no_train(self):
        self.assertIsNone(train.next_train_time(SimpleNamespace(every=60, soon=5, remote=True), 1000, []))

    def test_with_soon_a_train_leaves_that_many_minutes_after_the_oldest_request(self):
        args = SimpleNamespace(every=60, soon=5, remote=True)
        self.assertEqual(train.next_train_time(args, 1000, [2000, 1500]), 1500 + 300)

    def test_with_soon_a_request_that_has_waited_long_enough_leaves_at_once(self):
        args = SimpleNamespace(every=60, soon=5, remote=True)
        self.assertEqual(train.next_train_time(args, 5000, [1000]), 5000)

    def test_with_soon_the_retry_time_still_holds_a_train_back(self):
        args = SimpleNamespace(every=60, soon=5, remote=True)
        self.assertEqual(train.next_train_time(args, 5000, [1000], not_before=8000), 8000)


class FakeClock:
    """A stand-in for the time module: sleeping moves the clock, and nothing waits."""

    def __init__(self):
        self.now = time.time()
        self.sleeps = []

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class LoopTests(RemoteTrainCase):
    """The loop's options."""

    def test_soon_without_remote_is_refused(self):
        # A pretend clock, so that a loop which wrongly started would end at its deadline, not hang.
        self.patch(train, time=FakeClock(), run_one_train=lambda args: self.fail("a train must not run"))
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            status = train.command_loop(SimpleNamespace(every=60, soon=5, remote=False, hours=1, base="main"))
        self.assertEqual(status, 2)

    def test_the_options_reach_the_loop(self):
        seen = {}
        self.patch(train, command_loop=lambda args: seen.update(vars(args)) or 0)
        train.main(["loop", "--remote", "--soon", "3", "--every", "30"])
        self.assertEqual((seen["remote"], seen["soon"], seen["every"]), (True, 3, 30))
        seen.clear()
        train.main(["loop"])
        self.assertEqual((seen["remote"], seen["soon"], seen["every"]), (False, 0, 60), "the default stays hourly")
        seen.clear()
        self.patch(train, command_run=lambda args: seen.update(vars(args)) or 0)
        train.main(["run", "--remote"])
        self.assertTrue(seen["remote"])

    def test_a_loop_with_soon_sends_a_train_after_a_request_and_waits_after_a_failure(self):
        clock = FakeClock()
        self.patch(train, time=clock)
        request = self.branch("alpha", {"a.txt": "a"})
        # The queued file was just written, so its time is the real clock's, which the fake clock started from.
        calls = []

        def fake_train(args):
            calls.append(clock.now)
            if len(calls) == 1:
                return "failed"  # The request stays in the queue, as a failed train leaves it.
            for path in train.QUEUE.glob("*.json"):
                path.rename(path.with_suffix(".done"))
            return "ran"

        self.patch(train, run_one_train=fake_train)
        with redirect_stdout(io.StringIO()):
            train.command_loop(SimpleNamespace(every=60, soon=2, remote=True, hours=1, base="main"))
        self.assertEqual(len(calls), 2)
        self.assertAlmostEqual(calls[1] - calls[0], train.REMOTE_RETRY_MINUTES * 60, delta=1)
        self.assertEqual(request["agent"], "alpha")


if __name__ == "__main__":
    unittest.main()
