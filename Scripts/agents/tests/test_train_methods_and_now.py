"""Tests of the build train's two retry helpers (November 22, 2026): a request may name one test method
(`Class/testMethod`), and `request --now` makes the train leave at once.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

They use the throwaway repository and the fake GitHub of test_remote_train.py, so nothing here touches the real queue,
the real checkout, or GitHub.
"""
import io
import json
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace

from test_remote_train import (FakeClock, PASSING_LOG, PASSING_SUMMARY, RemoteTrainCase, results,
                               train)  # noqa: F401  (train is the module under test)


class OneTestMethodTests(RemoteTrainCase):
    """A request may name one test method, as `Class/testMethod`, of a Mac class or an iPhone class."""

    FILES = {
        "TextMouthProductionTests/FooTests.swift":
            "final class FooTests: XCTestCase {\n    func testAlpha() {}\n    func testBeta() {}\n}\n",
        "TextMouthiOSUITests/SearchUITests.swift":
            "final class SearchUITests: TextMouthUITestCase {\n    func testFind() {}\n}\n",
    }

    def setUp(self):
        super().setUp()
        self.patch(train, known_names=lambda cwd: ({"all", "stats"}, {"FooTests", "BarTests", "SearchUITests"}))

    def pushed(self):
        """The request file the train pushed to TestBuild."""
        return self.pushed_request(self.pushed_refs()["refs/heads/TestBuild"])

    def asks(self, **warnings_args):
        """Calls `request` for a branch and returns (what it printed to stderr, the queued request)."""
        self.git("checkout", "-q", "-b", "alpha", "main")
        self.git("checkout", "-q", "main")
        fields = dict(agent="alpha", branch="alpha", classes="", areas="", note="", ios_size=False, now=False)
        fields.update(warnings_args)
        errors = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(errors):
            self.assertEqual(train.command_request(SimpleNamespace(**fields)), 0)
        return errors.getvalue(), json.loads(sorted(train.QUEUE.glob("*.json"))[-1].read_text())

    def test_a_mac_method_reaches_the_request_by_its_full_name_and_an_iphone_method_goes_to_the_iphone_job(self):
        self.branch("alpha", self.FILES, areas=[], classes=["FooTests/testAlpha", "SearchUITests/testFind"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.assertEqual(self.run_train(), "ran")
        request = self.pushed()
        self.assertEqual((request["classes"], request["ios_ui_classes"]),
                         (["FooTests/testAlpha"], ["SearchUITests/testFind"]))
        self.assertIn("Names left out, unknown to run-area.py on the merged tree: none", self.result_of("alpha"))

    def test_a_method_typo_is_left_out_and_told_and_a_known_one_beside_it_still_runs(self):
        self.branch("alpha", self.FILES, areas=[], classes=["FooTests/testAlpa", "FooTests/testBeta"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        self.assertEqual(self.pushed()["classes"], ["FooTests/testBeta"])
        self.assertIn("unknown to run-area.py on the merged tree: FooTests/testAlpa", self.result_of("alpha"))

    def test_an_iphone_method_typo_is_left_out_too(self):
        self.branch("alpha", self.FILES, areas=["stats"], classes=["SearchUITests/testFnd"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        self.assertNotIn("ios_ui_classes", self.pushed())
        self.assertIn("SearchUITests/testFnd", self.result_of("alpha"))

    def test_a_method_of_an_unknown_class_is_left_out(self):
        self.branch("alpha", self.FILES, areas=["stats"], classes=["NoSuchTests/testX"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        self.assertEqual(self.pushed()["classes"], [])
        self.assertIn("NoSuchTests/testX", self.result_of("alpha"))

    def test_a_method_beside_its_whole_class_runs_with_the_class_even_when_another_agent_names_the_class(self):
        self.branch("alpha", self.FILES, areas=[], classes=["FooTests/testAlpha"])
        self.branch("beta", {"b.txt": "b"}, areas=[], classes=["FooTests"])
        self.gh_runs(results(PASSING_SUMMARY, PASSING_LOG))
        self.run_train()
        self.assertEqual(self.pushed()["classes"], ["FooTests"])

    def test_an_agent_is_told_the_failures_of_its_method_and_not_of_the_rest_of_the_class(self):
        failed = ("Executed 2 tests, with 0 tests skipped and 2 failures (0 unexpected) in 1.0 (1.0) seconds\n"
                  "FAILED FooTests.testAlpha at FooTests.swift:3: one\nFAILED FooTests.testBeta at FooTests.swift:4: two\n"
                  "FAILED in 9 seconds\n")
        self.branch("alpha", self.FILES, areas=[], classes=["FooTests/testAlpha"])
        self.gh_runs(results(failed, PASSING_LOG))
        self.run_train()
        mine = self.result_of("alpha").split("Failures in the classes you asked for")[1].split("Compile errors")[0]
        self.assertTrue(mine.startswith(": 1"), mine)
        self.assertIn("FooTests.testAlpha", mine)
        self.assertNotIn("FooTests.testBeta", mine)

    def test_failed_in_matches_a_whole_class_or_the_named_method_only(self):
        line = "FAILED FooTests.testAlpha at F.swift:1: x"
        self.assertTrue(train.failed_in(line, ["FooTests"]))
        self.assertTrue(train.failed_in(line, ["FooTests/testAlpha"]))
        self.assertFalse(train.failed_in(line, ["FooTests/testBeta", "BarTests"]))
        self.assertFalse(train.failed_in("CRASH somewhere", ["FooTests"]))

    def test_the_request_command_warns_of_a_method_typo_with_the_closest_names_and_still_queues_it(self):
        self.commit("TextMouthProductionTests/FooTests.swift", "final class FooTests: XCTestCase {\n    func testAlpha() {}\n}\n")
        errors, queued = self.asks(classes="FooTests/testAlpa")
        self.assertIn("main has no test method FooTests/testAlpa; closest: FooTests/testAlpha", errors)
        self.assertEqual(queued["classes"], ["FooTests/testAlpa"])

    def test_a_known_method_gives_no_warning(self):
        self.commit("TextMouthProductionTests/FooTests.swift", "final class FooTests: XCTestCase {\n    func testAlpha() {}\n}\n")
        errors, queued = self.asks(classes="FooTests/testAlpha")
        self.assertEqual(errors, "")
        self.assertEqual(queued["classes"], ["FooTests/testAlpha"])


class NowRequestTests(RemoteTrainCase):
    """`request --now`: a train that leaves at once, for the retry of one class or method."""

    def make_request(self, **more):
        """Queues a request through `command_request`; returns what it printed to stdout and to stderr, and its file."""
        self.git("checkout", "-q", "-b", "alpha", "main")
        self.git("checkout", "-q", "main")
        fields = dict(agent="alpha", branch="alpha", classes="FooTests", areas="", note="", ios_size=False, now=False)
        fields.update(more)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(train.command_request(SimpleNamespace(**fields)), 0)
        return out.getvalue(), err.getvalue(), json.loads(sorted(train.QUEUE.glob("*.json"))[-1].read_text())

    def test_now_is_recorded_only_when_asked_and_the_answer_says_the_train_leaves_at_once(self):
        out, _err, queued = self.make_request(now=True)
        self.assertIs(queued["now"], True)
        self.assertIn("the next train leaves at once", out)

    def test_a_request_without_now_is_as_it_was(self):
        out, _err, queued = self.make_request()
        self.assertNotIn("now", queued)
        self.assertNotIn("at once", out)

    def test_now_with_areas_prints_one_line_about_the_skipped_batching_and_goes_ahead(self):
        _out, err, queued = self.make_request(now=True, areas="stats")
        self.assertEqual(len([line for line in err.splitlines() if "--now skips the batching" in line]), 1)
        self.assertIs(queued["now"], True)
        self.assertEqual(queued["areas"], ["stats"])

    def test_now_with_no_areas_prints_no_such_line(self):
        _out, err, _queued = self.make_request(now=True)
        self.assertNotIn("batching", err)

    def test_a_request_command_without_the_now_field_still_works(self):
        # Callers older than the option build their arguments without it.
        self.git("checkout", "-q", "-b", "alpha", "main")
        self.git("checkout", "-q", "main")
        args = SimpleNamespace(agent="alpha", branch="alpha", classes="FooTests", areas="", note="", ios_size=False)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(train.command_request(args), 0)
        self.assertNotIn("now", json.loads(sorted(train.QUEUE.glob("*.json"))[-1].read_text()))

    def test_the_option_reaches_the_command_and_its_help_names_the_retry(self):
        seen = {}
        self.patch(train, command_request=lambda args: seen.update(vars(args)) or 0)
        train.main(["request", "--agent", "a", "--branch", "b", "--now"])
        self.assertIs(seen["now"], True)
        seen.clear()
        train.main(["request", "--agent", "a", "--branch", "b"])
        self.assertIs(seen["now"], False)
        with redirect_stdout(io.StringIO()) as shown, self.assertRaises(SystemExit):
            train.main(["request", "--help"])
        self.assertRegex(" ".join(shown.getvalue().split()), r"--now .*retry of ONE failing class or method with no --areas")

    def test_status_marks_a_now_request(self):
        self.make_request(now=True)
        shown = io.StringIO()
        with redirect_stdout(shown):
            train.command_status(SimpleNamespace())
        self.assertIn("areas=- now", shown.getvalue())


class NowDepartureTimeTests(unittest.TestCase):
    """When the loop's next train leaves, with and without `--now`."""

    HOUR = 3600
    SOON = SimpleNamespace(every=60, soon=5, remote=True)

    def test_with_soon_a_now_request_leaves_at_once_though_the_wait_is_not_over(self):
        self.assertEqual(train.next_train_time(self.SOON, 1000, [990, 995], now_times=[995]), 1000)

    def test_with_soon_a_now_request_still_waits_for_the_retry_time_of_a_failed_train(self):
        self.assertEqual(train.next_train_time(self.SOON, 1000, [995], not_before=4000, now_times=[995]), 4000)

    def test_with_soon_and_no_now_request_the_wait_is_as_before(self):
        self.assertEqual(train.next_train_time(self.SOON, 1000, [995], now_times=[]), 995 + 300)
        self.assertEqual(train.next_train_time(self.SOON, 1000, [995]), 995 + 300)

    def test_without_soon_a_now_request_does_not_change_the_hourly_clock(self):
        now = 5 * self.HOUR + 20 * 60
        args = SimpleNamespace(every=60, soon=0, remote=False)
        self.assertEqual(train.next_train_time(args, now, [now - 60], now_times=[now - 60]), 6 * self.HOUR)

    def test_with_soon_and_nothing_waiting_there_is_no_train(self):
        self.assertIsNone(train.next_train_time(self.SOON, 1000, [], now_times=[]))


class NowLoopTests(RemoteTrainCase):
    """The loop, on a fake clock, with a `--now` request: with no train running and with one."""

    def finish(self, calls, clock):
        """A fake train: records when it left and takes (renames) every waiting request."""
        calls.append(clock.now)
        for path in train.QUEUE.glob("*.json"):
            path.rename(path.with_suffix(".done"))
        return "ran"

    def run_loop(self):
        """Runs a one-hour loop with --soon 5, quietly."""
        with redirect_stdout(io.StringIO()):
            train.command_loop(SimpleNamespace(every=60, soon=5, remote=True, hours=1, base="main"))

    def leaves_after(self, **more):
        """Seconds the loop waits, with no train running, before it sends the one request it was given."""
        clock = FakeClock()
        self.patch(train, time=clock)
        self.branch("alpha", {"a.txt": "a"}, **more)
        calls = []
        self.patch(train, run_one_train=lambda args: self.finish(calls, clock))
        started = clock.now
        self.run_loop()
        self.assertEqual(len(calls), 1)
        return calls[0] - started

    def test_with_no_train_running_a_now_request_leaves_at_once(self):
        self.assertLess(self.leaves_after(now=True), 1)

    def test_a_request_without_now_waits_the_soon_minutes_as_before(self):
        self.assertAlmostEqual(self.leaves_after(), 5 * 60, delta=train.SOON_POLL_SECONDS)

    def test_a_now_request_that_comes_during_the_wait_ends_it_within_a_poll_and_takes_the_one_waiting(self):
        clock = FakeClock()
        self.patch(train, time=clock)
        self.branch("alpha", {"a.txt": "a"})
        calls, taken = [], []
        real_sleep = clock.sleep

        def sleep(seconds):
            """The second poll's sleep ends with a retry's request arriving."""
            real_sleep(seconds)
            if len(clock.sleeps) == 2:
                self.branch("beta", {"b.txt": "b"}, now=True)

        clock.sleep = sleep

        def fake_train(args):
            taken.extend(json.loads(path.read_text())["agent"] for path in sorted(train.QUEUE.glob("*.json")))
            return self.finish(calls, clock)

        self.patch(train, run_one_train=fake_train)
        started = clock.now
        self.run_loop()
        self.assertEqual(len(calls), 1, "one train takes both requests")
        self.assertEqual(sorted(taken), ["alpha", "beta"], "the request already waiting rides along")
        self.assertLess(calls[0] - started, 3 * train.SOON_POLL_SECONDS)

    def test_with_a_train_running_a_now_request_leaves_the_moment_it_ends_and_takes_the_ones_waiting(self):
        clock = FakeClock()
        self.patch(train, time=clock)
        self.branch("alpha", {"a.txt": "a"}, now=True)
        calls, taken = [], []

        def fake_train(args):
            if not calls:
                calls.append(clock.now)
                # This first train takes the first request. While it runs for ten minutes, a retry arrives
                # beside a plain request that has not waited its five minutes.
                for path in train.QUEUE.glob("*.json"):
                    path.rename(path.with_suffix(".done"))
                clock.now += 600
                self.branch("beta", {"b.txt": "b"}, now=True)
                self.branch("gamma", {"c.txt": "c"})
                return "ran"
            taken.extend(json.loads(path.read_text())["agent"] for path in sorted(train.QUEUE.glob("*.json")))
            return self.finish(calls, clock)

        self.patch(train, run_one_train=fake_train)
        self.run_loop()
        self.assertEqual(len(calls), 2)
        self.assertLess(calls[1] - (calls[0] + 600), 1, "the next train left as soon as the running one ended")
        self.assertEqual(sorted(taken), ["beta", "gamma"], "the request waiting at that moment rides along")

    def test_a_now_request_does_not_beat_the_hold_after_a_failed_train(self):
        clock = FakeClock()
        self.patch(train, time=clock)
        self.branch("alpha", {"a.txt": "a"}, now=True)
        calls = []

        def fake_train(args):
            if not calls:
                calls.append(clock.now)
                return "failed"  # The request stays queued, as after a real failed train.
            return self.finish(calls, clock)

        self.patch(train, run_one_train=fake_train)
        self.run_loop()
        self.assertAlmostEqual(calls[1] - calls[0], train.REMOTE_RETRY_MINUTES * 60, delta=1)


if __name__ == "__main__":
    unittest.main()
