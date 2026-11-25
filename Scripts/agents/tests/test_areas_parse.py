"""Tests of testkit.parse_areas: how Scripts/test/areas.conf is read.

areas.conf merges as a union (.gitattributes), so two branches that each add the same class to one area leave it listed
twice there; such a repeat must count once rather than make every train and run-area.py refuse the file (November 25,
2026: a merged sync branch listed SyncFormatTests twice in [sync]).
"""
import tempfile
import unittest
from pathlib import Path

import testkit_path  # noqa: F401  (puts Scripts/test on the path)
import testkit


class ParseAreasTests(unittest.TestCase):
    """The repeats a union merge leaves count once; real mistakes still refuse the file."""

    def parse(self, text):
        """The areas of an areas.conf holding `text`, written into a temporary folder the test removes."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "areas.conf"
        path.write_text(text, encoding="utf-8")
        return testkit.parse_areas(path)

    def test_a_class_listed_twice_in_one_area_counts_once(self):
        areas = self.parse("[sync] Syncing\nSyncFormatTests\nSyncStampTests\nSyncFormatTests\n")
        self.assertEqual(areas[0].classes, ("SyncFormatTests", "SyncStampTests"), "the first place is kept, the repeat dropped")

    def test_a_class_may_still_be_in_two_areas(self):
        areas = self.parse("[sync] Syncing\nSyncFormatTests\n[storage] Storage\nSyncFormatTests\n")
        self.assertEqual([area.classes for area in areas], [("SyncFormatTests",), ("SyncFormatTests",)])

    def test_an_area_listed_twice_is_still_refused(self):
        with self.assertRaises(testkit.AreasError):
            self.parse("[sync] Syncing\nSyncFormatTests\n[sync] Syncing again\nSyncStampTests\n")

    def test_a_line_that_is_no_class_is_still_refused(self):
        with self.assertRaises(testkit.AreasError):
            self.parse("[sync] Syncing\nnot a class\n")

    def test_the_repositorys_own_file_reads(self):
        root = Path(__file__).resolve().parents[3]
        self.assertTrue(testkit.parse_areas(root / "Scripts" / "test" / "areas.conf"))


if __name__ == "__main__":
    unittest.main()
