"""Tests of plan_shards.py: how the workflow learns how many parallel jobs a request wants.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
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
        self.assertEqual(lines, ["shards=3", 'matrix={"shard":[1,2,3]}'])

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

    def test_the_most_shards_is_what_the_workflow_runs_at_once(self):
        # A free account runs a few macOS jobs at once; more shards would only queue.
        self.assertLessEqual(shard.MAX_SHARDS, 5)


if __name__ == "__main__":
    unittest.main()
