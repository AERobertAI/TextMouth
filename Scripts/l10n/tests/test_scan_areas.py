"""The area table: each Swift file of the app belongs to one feature, or to the last area, other."""

from __future__ import annotations

import unittest

import scan_case  # noqa: F401  (puts the scanner on sys.path)

from swiftscan import areas


class AreaTableTests(unittest.TestCase):
    """The table's own rules."""

    def test_the_table_has_about_twenty_areas_with_unique_names_and_patterns(self) -> None:
        names = areas.area_names()
        self.assertEqual(len(names), len(set(names)))
        self.assertGreaterEqual(len(names), 18)
        self.assertLessEqual(len(names), 24)
        for name, what, patterns in areas.AREAS:
            self.assertTrue(what and patterns, name)
        # The last area is the catch-all, and only the last.
        self.assertEqual(names[-1], areas.OTHER)
        self.assertEqual(names.count(areas.OTHER), 1)

    def test_a_path_may_start_with_the_source_folder_or_not(self) -> None:
        self.assertEqual(areas.area_of("Models/FeedItem.swift"), "feeds")
        self.assertEqual(areas.area_of("TextMouth/Models/FeedItem.swift"), "feeds")

    def test_the_first_matching_area_owns_the_file(self) -> None:
        # The iPhone's folders come first: a sleep timer file there is the iPhone's.
        self.assertEqual(areas.area_of("Phone/PhoneSleepTimerModel.swift"), "iphone")
        self.assertEqual(areas.area_of("Services/SleepTimerService.swift"), "sleep-timer")
        # A parser of a feed is a parser first only when no earlier area claims it.
        self.assertEqual(areas.area_of("Parsers/PodcastTranscriptReader.swift"), "transcription")
        self.assertEqual(areas.area_of("Parsers/EPUBParser.swift"), "formats")

    def test_a_file_no_pattern_covers_lands_in_other(self) -> None:
        # A new file nobody has given a feature must not fail a check: it lands in the last area.
        self.assertEqual(areas.area_of("Models/ZzzNoSuchFeature.swift"), areas.OTHER)
        self.assertEqual(areas.area_of("TextMouth/Zzz/Deep/Path.swift"), areas.OTHER)
        self.assertEqual(areas.files_in(areas.OTHER, ["Models/ZzzNoSuchFeature.swift", "Models/FeedItem.swift"]),
                         ["Models/ZzzNoSuchFeature.swift"])


if __name__ == "__main__":
    unittest.main()
