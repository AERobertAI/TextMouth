"""Tests of plan_shards.py: how the workflow learns how many parallel jobs a request wants.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import ios_ui_tests  # noqa: E402
import plan_shards  # noqa: E402
import shard  # noqa: E402


class PlanShardsTests(unittest.TestCase):
    """The two output lines for a request file."""

    def plan(self, request):
        """Runs main() on a request file holding `request`; returns (status, the lines it printed)."""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "request.json"
            path.write_text(request if isinstance(request, str) else json.dumps(request))
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                status = plan_shards.main([str(path)])
        return status, out.getvalue().splitlines()

    def test_a_request_for_three_shards_gives_three_in_the_matrix(self):
        status, lines = self.plan({"areas": ["all"], "shards": 3})
        self.assertEqual(status, 0)
        self.assertEqual(lines[:2], ["shards=3", 'matrix={"shard":[1,2,3]}'])

    def test_the_matrix_line_is_json_the_workflow_can_expand(self):
        _, lines = self.plan({"shards": 2})
        self.assertEqual(json.loads(lines[1].split("=", 1)[1]), {"shard": [1, 2]})

    def test_no_shards_key_means_one_job(self):
        self.assertEqual(self.plan({"areas": ["stats"]})[1][0], "shards=1")

    def test_a_request_cannot_ask_for_more_than_the_most_or_fewer_than_one(self):
        self.assertEqual(self.plan({"shards": 99})[1][0], f"shards={shard.MAX_SHARDS}")
        self.assertEqual(self.plan({"shards": 0})[1][0], "shards=1")
        self.assertEqual(self.plan({"shards": -4})[1][0], "shards=1")

    def test_a_value_that_is_not_a_number_means_one_job(self):
        for odd in ("many", None, [3], {"n": 3}):
            with self.subTest(odd=odd):
                self.assertEqual(self.plan({"shards": odd})[1][0], "shards=1")

    def test_a_request_that_is_not_an_object_means_one_job(self):
        self.assertEqual(self.plan([1, 2, 3])[1][0], "shards=1")

    def test_a_request_that_cannot_be_read_is_an_error_and_prints_nothing_to_the_output_file(self):
        status, lines = self.plan("{not json")
        self.assertEqual((status, lines), (2, []))

    def test_a_missing_file_is_an_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(plan_shards.main(["/nonexistent/request.json"]), 2)

    def output(self, request):
        """The plan's lines as {name: value}."""
        return dict(line.split("=", 1) for line in self.plan(request)[1])

    def test_the_request_is_passed_on_as_one_line_that_reads_back_the_same(self):
        request = {"areas": ["all"], "classes": ["A\nB", "Café"], "shards": 2, "full": True}
        lines = self.plan(request)[1]
        self.assertEqual(len([l for l in lines if l.startswith("request=")]), 1)
        self.assertEqual(len(lines), 7, "one output line each: no raw newline may split the request")
        self.assertEqual(json.loads(self.output(request)["request"]), request)

    def test_the_iphone_build_is_on_unless_the_request_turns_it_off(self):
        self.assertEqual(self.output({})["ios"], "true")
        self.assertEqual(self.output({"ios": False})["ios"], "false")
        self.assertEqual(self.output({"ios": True})["ios"], "true")
        self.assertEqual(self.output({"ios": "no"})["ios"], "true", "only a real false turns it off")

    def test_the_build_is_cached_unless_the_request_asks_for_a_cold_one(self):
        self.assertEqual(self.output({})["cold"], "false")
        self.assertEqual(self.output({"cold": True})["cold"], "true")
        self.assertEqual(self.output({"cold": "yes"})["cold"], "false", "only a real true makes it cold")

    def test_a_full_suite_asks_for_several_iphone_jobs_and_a_request_without_iphone_tests_for_one(self):
        # Beside 2 Mac shards there are slots for several (beside 4, the Mac keeps its shards and leaves one).
        full = self.output({"areas": ["all"], "full": True, "shards": 2})
        self.assertGreater(int(full["ios_shards"]), 1, "the interface tests are the longest path of a full suite")
        self.assertEqual(json.loads(full["ios_matrix"]), {"shard": list(range(1, int(full["ios_shards"]) + 1))})
        self.assertEqual(self.output({"classes": ["ChatterTests"]})["ios_shards"], "1")
        self.assertEqual(self.output({"full": True, "ios": False})["ios_shards"], "1")

    def test_a_request_may_say_how_many_iphone_jobs_within_the_most(self):
        self.assertEqual(self.output({"ios_shards": 2})["ios_shards"], "2")
        # With one Mac shard there is room for a fourth; with more Mac shards the most is 3.
        self.assertEqual(self.output({"ios_shards": 99})["ios_shards"], str(ios_ui_tests.MAX_SHARDS_WITH_ROOM))
        self.assertEqual(self.output({"ios_shards": 99, "shards": 2})["ios_shards"], str(ios_ui_tests.MAX_SHARDS))
        self.assertEqual(self.output({"ios_shards": 0})["ios_shards"], "1")
        for odd in (True, "2", None, 1.5):
            with self.subTest(odd=odd):
                self.assertEqual(self.output({"full": True, "ios_shards": odd})["ios_shards"],
                                 self.output({"full": True})["ios_shards"], "an odd value is the planned count")

    def test_the_mac_shards_and_the_iphone_jobs_never_exceed_the_five_macos_jobs_a_free_account_runs_at_once(self):
        # A job past the limit waits for a free one and ends last, so the Mac shards take what the iPhone jobs leave.
        for request in ({"areas": ["all"], "full": True, "shards": 4}, {"full": True, "shards": 4, "ios_shards": 3},
                        {"shards": 4}, {"shards": 4, "ios": False}, {"full": True, "shards": 99, "ios_shards": 99},
                        {"shards": 1, "ios_shards": 99}, {"shards": 2, "ios_shards": 99}):
            with self.subTest(request=request):
                out = self.output(request)
                ios_jobs = int(out["ios_shards"]) if out["ios"] == "true" else 0
                self.assertLessEqual(int(out["shards"]) + ios_jobs, plan_shards.MACOS_JOBS_AT_ONCE)
                self.assertGreaterEqual(int(out["shards"]), 1)

    def test_the_mac_keeps_the_shards_it_asked_for_and_the_iphone_jobs_take_the_slots_left(self):
        out = self.output({"full": True, "shards": 4, "ios_shards": 3})
        self.assertEqual((out["shards"], out["ios_shards"]), ("4", "1"), "4 + 1 are the 5 macOS jobs")
        out = self.output({"full": True, "shards": 3, "ios_shards": 3})
        self.assertEqual((out["shards"], out["ios_shards"]), ("3", "2"))
        out = self.output({"full": True, "shards": 2, "ios_shards": 3})
        self.assertEqual((out["shards"], out["ios_shards"]), ("2", "3"))

    def estimate_of(self, seconds):
        """A patch that makes the iPhone tests' estimate `seconds` in all, as the real classes' shares of it."""
        real = ios_ui_tests.estimated_seconds

        def scaled(classes, *args, **kwargs):
            """The real estimate of `classes`, scaled to the total."""
            base = real(classes, *args, **kwargs)
            factor = seconds / (sum(base.values()) or 1)
            return {name: value * factor for name, value in base.items()}

        return mock.patch.object(ios_ui_tests, "estimated_seconds", scaled)

    def test_an_estimate_past_two_jobs_does_not_take_a_mac_shard_from_a_full_suite(self):
        # exportphone's ExportUITests (125 s), PhoneExportPeakMemoryTests (45.8) and PhoneExportMemoryCheckTests (6.6) bring the
        # estimate of the whole iPhone suite from 1,520 to 1,714 seconds, past the two-job line (2 x 800): 3 iPhone jobs.
        with self.estimate_of(1714.0):
            wanted = self.output({"shards": 2, "full": True})["ios_shards"]
            self.assertEqual(wanted, "3", "the estimate wants 3 iPhone jobs where there is room")
            for mac, expected_ios in ((4, "1"), (3, "2")):
                with self.subTest(mac_shards=mac):
                    out = self.output({"full": True, "areas": ["all"], "shards": mac})
                    self.assertEqual((out["shards"], out["ios_shards"]), (str(mac), expected_ios))

    def test_a_one_shard_train_keeps_the_iphone_jobs_its_estimate_wants(self):
        with self.estimate_of(1714.0):
            out = self.output({"shards": 1, "full": True})
            self.assertEqual((out["shards"], out["ios_shards"]), ("1", "3"))
        with self.estimate_of(2600.0):
            out = self.output({"shards": 1, "full": True})
            self.assertEqual((out["shards"], out["ios_shards"]), ("1", "4"), "room for 4 beside one Mac shard")

    def test_the_iphone_jobs_are_at_least_one_whatever_the_mac_asks(self):
        for mac in (1, 2, 3, 4, 99):
            with self.subTest(mac=mac), self.estimate_of(5000.0):
                out = self.output({"full": True, "shards": mac})
                self.assertGreaterEqual(int(out["ios_shards"]), 1)
                self.assertEqual(int(out["shards"]), min(mac, shard.MAX_SHARDS))

    def test_a_train_without_iphone_tests_keeps_all_the_mac_shards_beside_its_one_iphone_build(self):
        out = self.output({"classes": ["ChatterTests"], "shards": 4})
        self.assertEqual((out["shards"], out["ios_shards"]), ("4", "1"))

    def planned_ios_jobs(self, request, seconds_each):
        """The ios_shards the plan gives `request` when every iPhone class it asks for is counted as `seconds_each` seconds."""
        counted = lambda classes, *args, **kwargs: {name: seconds_each for name in classes}  # noqa: E731
        with mock.patch.object(ios_ui_tests, "estimated_seconds", counted):
            return int(self.output(request)["ios_shards"])

    def test_one_mac_shard_leaves_room_for_four_iphone_jobs(self):
        # With 214 classes at 20 seconds, the tests are 4,280 seconds: 6 jobs at the plain target, so the most decides.
        full = {"full": True, "shards": 1}
        self.assertEqual(self.planned_ios_jobs(full, 20.0), ios_ui_tests.MAX_SHARDS_WITH_ROOM)
        self.assertEqual(self.planned_ios_jobs({**full, "shards": 2}, 20.0), ios_ui_tests.MAX_SHARDS, "two Mac shards leave 3")
        out = self.output({**full, "ios_shards": 99})
        self.assertEqual((out["shards"], out["ios_shards"]), ("1", "4"))

    def test_with_room_the_tests_are_split_finer_than_without(self):
        # 214 classes at 4 seconds are 856 seconds: 2 jobs at either target (ceil 1.07 and 1.43).
        full = {"full": True, "shards": 1}
        self.assertEqual(self.planned_ios_jobs(full, 4.0), 2)
        self.assertEqual(self.planned_ios_jobs({**full, "shards": 2}, 4.0), 2)
        # 1,300 seconds: 2 jobs at the plain target (1.63), 3 at the finer one (2.17).
        self.assertEqual(self.planned_ios_jobs({**full, "shards": 2}, 1300 / 214), 2)
        self.assertEqual(self.planned_ios_jobs(full, 1300 / 214), 3)

    def test_a_request_with_no_iphone_tests_is_one_job_whatever_the_room(self):
        self.assertEqual(self.output({"classes": ["ChatterTests"], "shards": 1})["ios_shards"], "1")

    def test_the_most_shards_is_what_the_workflow_runs_at_once(self):
        # A free account runs a few macOS jobs at once; more shards would only queue.
        self.assertLessEqual(shard.MAX_SHARDS, 5)


if __name__ == "__main__":
    unittest.main()
