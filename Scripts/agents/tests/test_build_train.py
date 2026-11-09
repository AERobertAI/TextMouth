"""Tests of build-train.py: hourly trains that wait their turn for the heavy-work lock.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every test points the train and the lock at a temporary folder, and replaces
the steps that build, post, or touch the main checkout, before it calls
anything, so the real queue, trains, lock, and board are never read or changed.
"""
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace

AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)

# build-train.py has a hyphen in its name, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("build_train", AGENTS / "build-train.py")
train = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(train)


class TrainTestCase(unittest.TestCase):
    """Points the train and the lock at a temporary folder for each test."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        records = self.folder / "train"
        self.patch(train, TRAIN_DIR=records, QUEUE=records / "queue", TRAINS=records / "trains",
                   RESULTS=records / "results", LOCK=records / "lock", STATE=records / "lock" / "state.txt",
                   NEXT=records / "next.txt")
        self.patch(heavy_lock, LOCK=self.folder / "heavy-lock", FIRST=self.folder / "heavy-lock-first.json",
                   POLL_SECONDS=0.02)
        # A train gives up on the lock after 3 seconds here, not 50 minutes, so no test can hang.
        self.patch(train, LOCK_WAIT_MINUTES=0.05)
        # Never let a test reach the real records or lock, whatever it does: the
        # train must use the very module patched here, and every path must be temporary.
        self.assertIs(train.heavy_lock, heavy_lock)
        for path in (train.TRAIN_DIR, train.QUEUE, train.TRAINS, train.RESULTS, train.LOCK, train.STATE,
                     train.NEXT, heavy_lock.LOCK, heavy_lock.FIRST):
            self.assertTrue(str(path).startswith(str(self.folder)), path)
        self.posts = []
        self.steps = []
        self.patch(train, post=lambda to, topic, tag="build": self.posts.append((to, topic, tag)),
                   free_gigabytes=lambda: 100,
                   prepare_worktree=lambda base, train_id: self.steps.append("prepare"),
                   regenerate_project=lambda: False,
                   ios_census=lambda train_dir: None,
                   report=self.fake_report,
                   merge_requests=self.fake_merge,
                   run_tests=self.fake_run_tests)
        self.reported = None

    def patch(self, module, **values):
        """Sets each of `values` on `module` for this test only."""
        for name, value in values.items():
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, value)

    # The steps a train takes, stood in for, each noting that it ran.

    def fake_merge(self, requests, log):
        self.steps.append("merge")
        self.merged_requests = list(requests)
        return list(requests), {}

    def fake_run_tests(self, merged, train_dir):
        holder = heavy_lock.owner() or {}
        self.steps.append(f"tests under {holder.get('name')}")
        return "Executed 1 test, with 0 failures\nPASSED"

    def fake_report(self, train_id, base, merged, conflicts, output, train_dir, census=None, broken=(),
                    taken_back=()):
        self.steps.append("report")
        self.reported = SimpleNamespace(train_id=train_id, merged=merged, output=output, taken_back=taken_back)

    # Helpers.

    def queue(self, agent, branch="some/branch", head="0123456789abcdef"):
        """Queues a request as `build-train.py request` writes one."""
        train.QUEUE.mkdir(parents=True, exist_ok=True)
        request = {"agent": agent, "branch": branch, "head": head, "classes": ["FooTests"], "areas": [],
                   "note": "", "time": "2026-11-08T08:00:00"}
        path = train.QUEUE / f"{time.monotonic_ns()}-{agent}.json"
        path.write_text(json.dumps(request))
        return path

    def live_pid(self):
        """The process ID of another process that runs until the test ends."""
        process = subprocess.Popen(["sleep", "60"])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid

    def hold_heavy_lock(self, name="a full suite"):
        """Makes the heavy-work lock as another job holding it would."""
        heavy_lock.LOCK.mkdir()
        (heavy_lock.LOCK / "owner.json").write_text(
            json.dumps({"pid": self.live_pid(), "name": name, "since": "2026-11-08 07:58:00"}))

    def free_heavy_lock(self):
        """Frees the heavy-work lock in one step, as its job would on ending."""
        heavy_lock.LOCK.rename(self.folder / f"freed-{time.monotonic_ns()}")

    def later(self, seconds, action):
        """Runs `action` on a thread of its own after `seconds`, unless the test has ended."""
        timer = threading.Timer(seconds, action)
        self.addCleanup(timer.cancel)
        timer.start()

    def run_train(self):
        """Runs one train as the loop does, quietly; returns its exit status."""
        with redirect_stdout(io.StringIO()):
            return train.command_run(SimpleNamespace(base="train/base"))


class WaitingForTheLockTests(TrainTestCase):
    """A train never runs beside another heavy job."""

    def test_a_train_builds_and_tests_only_under_the_heavy_lock_and_then_frees_both_locks(self):
        self.queue("azw3")
        self.assertEqual(self.run_train(), 0)
        self.assertEqual(self.steps, ["prepare", "merge", "tests under build-train", "report"])
        self.assertFalse(heavy_lock.LOCK.exists(), "the train should release the heavy-work lock")
        self.assertFalse(heavy_lock.FIRST.exists(), "the train should leave no first-in-line mark")
        self.assertFalse(train.LOCK.exists(), "the train should release its own lock")

    def test_a_train_waits_for_the_job_holding_the_lock_and_says_whom_it_waits_for(self):
        self.queue("azw3")
        self.hold_heavy_lock("typecheck ioslead ios")
        self.later(0.2, self.free_heavy_lock)
        self.assertEqual(self.run_train(), 0)
        self.assertEqual(self.steps, ["prepare", "merge", "tests under build-train", "report"])
        notices = [topic for to, topic, tag in self.posts if tag == "notice"]
        self.assertEqual(len(notices), 1, self.posts)
        self.assertIn("held by typecheck ioslead ios since 2026-11-08 07:58:00", notices[0])

    def test_requests_made_while_the_train_waits_go_with_it(self):
        self.queue("azw3")
        self.hold_heavy_lock()
        self.later(0.1, lambda: self.queue("ioslead", branch="ios/lead-1108"))
        self.later(0.25, self.free_heavy_lock)
        self.run_train()
        self.assertEqual(sorted(r["agent"] for r in self.merged_requests), ["azw3", "ioslead"])
        self.assertEqual(list(train.QUEUE.glob("*.json")), [], "every request should have been taken")

    def test_a_train_that_never_gets_the_lock_runs_nothing_and_leaves_its_requests_queued(self):
        train.LOCK_WAIT_MINUTES = 0.005  # 0.3 seconds; setUp's cleanup restores the real value.
        waiting = self.queue("azw3")
        self.hold_heavy_lock("a full suite")
        self.assertEqual(self.run_train(), 0)
        self.assertEqual(self.steps, [], "nothing should run without the heavy-work lock")
        self.assertTrue(waiting.exists(), "the request should wait for the next train")
        self.assertEqual(heavy_lock.owner()["name"], "a full suite", "the holder's lock should be left alone")
        self.assertFalse(heavy_lock.FIRST.exists(), "a train that gave up should hold no one back")
        self.assertFalse(train.LOCK.exists(), "the train should release its own lock")
        gave_up = [topic for to, topic, tag in self.posts if "stayed busy" in topic]
        self.assertEqual(len(gave_up), 1, self.posts)
        self.assertEqual(self.posts[-1][0], "orchestrator")
        self.assertIn("held by a full suite since 2026-11-08 07:58:00", gave_up[0])

    def test_no_other_job_takes_the_lock_while_a_train_waits(self):
        self.queue("azw3")
        self.hold_heavy_lock()
        seen = {}

        def look():
            # A job of another process would be held off by the mark; the mark is what it reads.
            try:
                seen["mark"] = json.loads(heavy_lock.FIRST.read_text())
            except OSError:
                seen["mark"] = None
            self.free_heavy_lock()

        self.later(0.15, look)
        self.run_train()
        self.assertIsNotNone(seen["mark"], "a waiting train should mark itself first in line")
        self.assertEqual(seen["mark"]["name"], "build-train")
        self.assertIn("until", seen["mark"])

    def test_nothing_waits_means_no_lock_is_taken(self):
        self.hold_heavy_lock()
        self.assertEqual(self.run_train(), 0)
        self.assertEqual(self.steps, [])
        self.assertFalse(heavy_lock.FIRST.exists(), "a train with nothing to do should not get in line")


class StatusTests(TrainTestCase):
    """`status` says what a running train is doing."""

    def status(self):
        output = io.StringIO()
        with redirect_stdout(output):
            train.command_status(SimpleNamespace())
        return output.getvalue()

    def test_a_running_train_says_what_it_is_doing(self):
        train.LOCK.mkdir(parents=True)
        (train.LOCK / "pid").write_text(str(self.live_pid()))
        train.set_state("waiting for the heavy-work lock, held by a full suite")
        self.assertIn("running now: yes, waiting for the heavy-work lock, held by a full suite", self.status())

    def test_a_lock_left_by_a_train_that_ended_is_not_a_running_train(self):
        train.LOCK.mkdir(parents=True)
        ended = subprocess.Popen(["true"])
        ended.wait()
        (train.LOCK / "pid").write_text(str(ended.pid))
        self.assertIn("running now: no", self.status())
        self.assertTrue(train.take_lock(), "the next train should take a dead train's lock over")


class ThrowawayRepoTestCase(unittest.TestCase):
    """A real throwaway repository in a temporary folder, standing for both the main
    checkout and the train's worktree, so merges happen for real and nothing else is touched."""

    def git(self, *args):
        """Runs git in the throwaway repository; returns its output."""
        return subprocess.run(["git", *args], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, name, text=None):
        """Commits a file `name` holding `text` (by default its name); returns the commit."""
        (self.repo / name).write_text((text or name) + "\n")
        self.git("add", name)
        self.git("commit", "-q", "-m", f"Add {name}")
        return self.git("rev-parse", "HEAD")

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "train@example.invalid")
        self.git("config", "user.name", "Train Test")
        self.git("config", "commit.gpgsign", "false")
        self.commit("base.txt")
        # The train's worktree, and the checkout its git() runs in by default, are the throwaway one.
        for name in ("WORKTREE", "ROOT"):
            self.addCleanup(setattr, train, name, getattr(train, name))
            setattr(train, name, self.repo)
        self.assertTrue(str(train.WORKTREE).startswith(str(self.folder)))


class MergeTests(ThrowawayRepoTestCase):
    """A train merges the commit an agent asked for, in a real throwaway repository."""

    def setUp(self):
        super().setUp()
        self.git("checkout", "-q", "-b", "feature")
        self.asked = self.commit("asked.txt")
        self.commit("newer.txt")  # Committed after the request, so not asked for.
        self.git("checkout", "-q", "-b", "train/run", "main")

    def test_the_train_merges_the_commit_asked_for_not_the_branch_s_newest(self):
        log = io.StringIO()
        merged, conflicts = train.merge_requests(
            [{"agent": "azw3", "branch": "feature", "head": self.asked}], log)
        self.assertEqual((len(merged), conflicts), (1, {}), log.getvalue())
        self.assertTrue((self.repo / "asked.txt").exists(), "the commit asked for should be merged")
        self.assertFalse((self.repo / "newer.txt").exists(), "a commit made after the request should wait")
        self.assertEqual(self.git("log", "-1", "--format=%s"), f"Merge feature at {self.asked[:8]}")

    def test_files_and_errors_are_those_of_the_commit_asked_for(self):
        self.assertEqual(train.changed_files("main", self.asked), {"asked.txt"})
        self.assertEqual(train.errors_in_branch(["ERROR newer.txt:1: oops", "ERROR asked.txt:2: no"],
                                                "main", self.asked), ["ERROR asked.txt:2: no"])


class RebuildTests(ThrowawayRepoTestCase):
    """When a train builds again without the branches that broke the build, it merges
    again the branches it left out for a conflict, in a real throwaway repository."""

    def setUp(self):
        super().setUp()
        # Every branch starts at main. `shared.txt` is where branches clash.
        self.commit("shared.txt", "original")
        self.git("branch", "base-with-shared")
        self.train_dir = self.folder / "train-1"
        self.train_dir.mkdir()
        # Files the retry sets aside (keep_aside renames them), as a first run leaves them.
        (self.train_dir / "run.log").write_text("first run\n")
        (self.train_dir / "run-summary.txt").write_text("first summary\n")
        # The retry's steps that need Xcode, stood in for. Its worktree is the throwaway repository.
        self.tested = []
        for name, value in (("regenerate_project", lambda: False),
                            ("run_tests", self.fake_run_tests),
                            ("RESULTS", self.repo / "results"),
                            ("post", lambda *args, **more: None)):
            self.addCleanup(setattr, train, name, getattr(train, name))
            setattr(train, name, value)
        self.requests = [
            self.request("broken", {"shared.txt": "broken", "Broken.swift": "does not compile"}),
            self.request("rival", {"shared.txt": "rival"}),
            self.request("stay", {"stay.txt": "a"}),
            self.request("stay-rival", {"stay.txt": "b"}),
        ]
        self.merged, self.conflicts = self.first_merge()

    def request(self, name, files):
        """A request for a branch `name` off main that writes `files` (a dict of name to text)."""
        self.git("checkout", "-q", "-b", name, "main")
        head = ""
        for filename, text in files.items():
            head = self.commit(filename, text)
        return {"agent": f"agent-{name}", "branch": name, "head": head, "classes": ["FooTests"], "areas": []}

    def first_merge(self):
        """The train's first merge of all four requests, as command_run does it; leaves the
        throwaway repository on the train's branch with `broken` and `stay` merged."""
        self.git("checkout", "-q", "-b", "train/run-1", "main")
        with open(self.train_dir / "merge.log", "w") as log:
            return train.merge_requests(self.requests, log)

    def fake_run_tests(self, merged, train_dir):
        """The rebuilt train's tests: they pass, and note which branches were in the build."""
        self.tested.append([request["branch"] for request in merged])
        return "Executed 3 tests, with 0 failures\nPASSED"

    def rebuild(self, requests="in order"):
        """Runs without_broken_branches on a first build that failed to compile in Broken.swift."""
        output = "ERROR Broken.swift:1:1: error: does not compile\nFAILED\n"
        return train.without_broken_branches(
            "main", "1", self.train_dir, self.merged, self.conflicts, output,
            self.requests if requests == "in order" else requests)

    def branches(self, requests):
        """The branch names of `requests`."""
        return [request["branch"] for request in requests]

    def test_the_first_merge_leaves_out_the_two_that_conflict(self):
        self.assertEqual(self.branches(self.merged), ["broken", "stay"])
        self.assertEqual(sorted(request["branch"] for request, _ in self.conflicts.values()), ["rival", "stay-rival"])

    def test_a_branch_that_conflicted_only_with_the_branch_that_broke_the_build_is_taken_back(self):
        merged, conflicts, _, broken, taken_back = self.rebuild()
        self.assertEqual(self.branches(taken_back), ["rival"])
        self.assertIn("rival", self.branches(merged), "the branch was not taken back into the build")
        self.assertEqual(self.tested, [["rival", "stay"]], "the rebuild did not test the taken-back branch")
        self.assertEqual([request["branch"] for request, _ in broken], ["broken"])
        self.assertEqual((self.repo / "shared.txt").read_text(), "rival\n")

    def test_a_branch_that_conflicts_with_one_that_stays_is_not_taken_back(self):
        merged, conflicts, _, _, taken_back = self.rebuild()
        self.assertNotIn("stay-rival", self.branches(merged))
        self.assertNotIn("stay-rival", self.branches(taken_back))
        self.assertEqual([request["branch"] for request, _ in conflicts.values()], ["stay-rival"])
        self.assertEqual(list(conflicts.values())[0][1], ["stay.txt"], "the conflict should name the file")

    def test_the_branches_are_merged_again_in_the_order_they_were_requested(self):
        self.rebuild()
        subjects = self.git("log", "--merges", "--reverse", "--format=%s").splitlines()
        # The merges since the train's own first merges: the rebuild's, "rival" before "stay".
        self.assertEqual([subject.split()[1] for subject in subjects[-2:]], ["rival", "stay"])

    def test_given_the_requests_in_another_order_they_are_merged_in_that_order(self):
        # "stay-rival" now comes before "stay", so it wins their clash and "stay" is left out.
        merged, conflicts, *_ = self.rebuild(list(reversed(self.requests)))
        self.assertEqual(self.branches(merged), ["stay-rival", "rival"])
        self.assertEqual([request["branch"] for request, _ in conflicts.values()], ["stay"])

    def test_without_the_requests_the_merged_branches_come_first(self):
        _, _, _, _, taken_back = self.rebuild(requests=None)
        self.assertEqual(self.branches(taken_back), ["rival"])

    def test_nothing_is_taken_back_when_no_branch_broke_the_build(self):
        # A build that compiled leaves everything as it was, and merges nothing again.
        result = train.without_broken_branches("main", "1", self.train_dir, self.merged, self.conflicts,
                                               "Executed 3 tests, with 0 failures\nPASSED", self.requests)
        self.assertEqual(result, (self.merged, self.conflicts, "Executed 3 tests, with 0 failures\nPASSED", [], []))
        self.assertEqual(self.tested, [])

    def test_the_summary_says_which_were_taken_back(self):
        merged, conflicts, output, broken, taken_back = self.rebuild()
        with redirect_stdout(io.StringIO()):
            train.report("1", "main", merged, conflicts, output, self.train_dir, None, broken, taken_back)
        summary = (self.train_dir / "summary.md").read_text()
        self.assertIn("## Taken back: rival (agent-rival)", summary)
        self.assertNotIn("Taken back: stay-rival", summary)
        self.assertIn("## Left out: stay-rival (agent-stay-rival) conflicts in", summary)
        self.assertIn("was left out; the train then built again without that branch",
                      (train.RESULTS / "agent-rival.md").read_text())


class RebuildIsGivenTheRequestsTests(TrainTestCase):
    """command_run hands the retry the requests in the order they were queued."""

    def test_the_retry_gets_every_request_in_queue_order_and_the_report_gets_those_taken_back(self):
        calls = []

        def fake_retry(base, train_id, train_dir, merged, conflicts, output, requests=None):
            calls.append([request["agent"] for request in requests])
            return merged, conflicts, output, [], []

        self.patch(train, without_broken_branches=fake_retry)
        self.queue("first", branch="a")
        self.queue("second", branch="b")
        self.run_train()
        self.assertEqual(calls, [["first", "second"]])
        self.assertEqual(list(self.reported.taken_back), [])

    def test_a_branch_taken_back_that_then_breaks_the_build_is_not_reported_as_taken_back(self):
        script = iter([
            # Pass 1: the retry takes "second" back, and drops "first".
            lambda merged, requests: (merged[1:], {}, "o", [({"agent": "first"}, ["e"])], [merged[1]]),
            # Pass 2: "second" breaks the build and is dropped in turn (nothing is left to run, so none merged).
            lambda merged, requests: ([], {}, "o", [({"agent": "second"}, ["e"])], []),
            # Pass 3: nothing more to drop, so the loop ends.
            lambda merged, requests: (merged, {}, "o", [], []),
        ])

        def fake_retry(base, train_id, train_dir, merged, conflicts, output, requests=None):
            return next(script)(merged, requests)

        self.patch(train, without_broken_branches=fake_retry)
        self.queue("first", branch="a")
        self.queue("second", branch="b")
        self.run_train()
        self.assertEqual(list(self.reported.taken_back), [], "a branch that was dropped again was listed as taken back")


class LoopTests(unittest.TestCase):
    """The loop's schedule."""

    def test_trains_leave_every_hour_by_default(self):
        seen = {}
        original = train.command_loop
        self.addCleanup(setattr, train, "command_loop", original)
        train.command_loop = lambda args: seen.setdefault("every", args.every) and 0
        train.main(["loop"])
        self.assertEqual(seen["every"], 60)


if __name__ == "__main__":
    unittest.main()
