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

    def fake_report(self, train_id, base, merged, conflicts, output, train_dir, census=None, broken=()):
        self.steps.append("report")
        self.reported = SimpleNamespace(train_id=train_id, merged=merged, output=output)

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


class MergeTests(unittest.TestCase):
    """A train merges the commit an agent asked for, in a real throwaway repository."""

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, name):
        (self.repo / name).write_text(name + "\n")
        self.git("add", name)
        self.git("commit", "-q", "-m", f"Add {name}")
        return self.git("rev-parse", "HEAD")

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Path(folder.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "train@example.invalid")
        self.git("config", "user.name", "Train Test")
        self.git("config", "commit.gpgsign", "false")
        self.commit("base.txt")
        self.git("checkout", "-q", "-b", "feature")
        self.asked = self.commit("asked.txt")
        self.commit("newer.txt")  # Committed after the request, so not asked for.
        self.git("checkout", "-q", "-b", "train/run", "main")
        # The train's worktree, and the checkout its git() runs in by default, are the throwaway one.
        for name in ("WORKTREE", "ROOT"):
            self.addCleanup(setattr, train, name, getattr(train, name))
            setattr(train, name, self.repo)

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
