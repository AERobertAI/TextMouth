"""Tests of shard.py: balanced, deterministic slices of the test classes.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import json
import tempfile
import unittest
from pathlib import Path

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import shard  # noqa: E402


class SplitTests(unittest.TestCase):
    """Dealing classes into shards."""

    TIMES = {"Big": 100, "Medium": 60, "Small": 10, "Tiny": 1, "Other": 50, "More": 49}

    def test_every_class_lands_in_exactly_one_shard(self):
        classes = list(self.TIMES) + ["Unknown"]
        for count in (1, 2, 3, 4, 7):
            with self.subTest(count=count):
                shards = shard.split(classes, self.TIMES, count)
                self.assertEqual(len(shards), count)
                self.assertEqual(sorted(name for one in shards for name in one), sorted(classes))

    def test_the_shards_are_balanced_by_time(self):
        shards = shard.split(list(self.TIMES), self.TIMES, 2)
        loads = [sum(self.TIMES[name] for name in one) for one in shards]
        # Dealing the longest first is within 4/3 of the best possible split (which here is 135 and 135).
        self.assertLessEqual(max(loads), 135 * 4 / 3, (shards, loads))

    def test_the_longest_class_goes_alone_when_it_is_longer_than_the_rest_together(self):
        shards = shard.split(["Huge", "A", "B"], {"Huge": 500, "A": 5, "B": 5}, 2)
        self.assertEqual(shards, [["Huge"], ["A", "B"]])

    def test_the_split_does_not_depend_on_the_order_the_classes_come_in(self):
        names = list(self.TIMES)
        self.assertEqual(shard.split(names, self.TIMES, 3), shard.split(list(reversed(names)), self.TIMES, 3))

    def test_a_class_with_no_time_counts_as_the_default(self):
        shards = shard.split(["A", "B", "C"], {}, 3)
        self.assertEqual([len(one) for one in shards], [1, 1, 1])

    def test_more_shards_than_classes_leaves_some_empty(self):
        shards = shard.split(["A", "B"], {}, 4)
        self.assertEqual(sum(1 for one in shards if one), 2)
        self.assertEqual(len(shards), 4)

    def test_each_shard_is_sorted_by_name(self):
        for one in shard.split(list(self.TIMES), self.TIMES, 2):
            self.assertEqual(one, sorted(one))


class ShardCountTests(unittest.TestCase):
    """How many shards a request needs."""

    def test_a_short_request_is_one_shard(self):
        self.assertEqual(shard.shard_count(["A", "B"], {"A": 10, "B": 20}), 1)
        self.assertEqual(shard.shard_count([], {}), 1)

    def test_one_shard_for_each_target_of_time_up_to_the_most(self):
        times = {"A": shard.TARGET_SECONDS * 1.5}
        self.assertEqual(shard.shard_count(["A"], times), 2)
        self.assertEqual(shard.shard_count(["A"], {"A": shard.TARGET_SECONDS * 100}), shard.MAX_SHARDS)

    def test_unknown_classes_count_as_the_default_time(self):
        classes = [f"C{i}" for i in range(int(shard.TARGET_SECONDS / shard.DEFAULT_SECONDS) * 2 + 1)]
        self.assertEqual(shard.shard_count(classes, {}), 3)


class LoadTimesTests(unittest.TestCase):
    """The times file."""

    def test_a_file_is_read_as_numbers(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "times.json"
            path.write_text(json.dumps({"A": 3, "B": 4.5}))
            self.assertEqual(shard.load_times(path), {"A": 3.0, "B": 4.5})

    def test_a_missing_or_broken_file_is_no_times(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(shard.load_times(Path(folder) / "none.json"), {})
            broken = Path(folder) / "broken.json"
            broken.write_text("[1, 2")
            self.assertEqual(shard.load_times(broken), {})
            listy = Path(folder) / "list.json"
            listy.write_text("[1, 2]")
            self.assertEqual(shard.load_times(listy), {})


if __name__ == "__main__":
    unittest.main()
