"""The area table: every Swift file of the app belongs to one feature."""

from __future__ import annotations

import unittest

from scan_case import REPO

from swiftscan import areas, scanner


class AreaTableTests(unittest.TestCase):
    """The table's own rules."""

    def test_the_table_has_about_twenty_areas_with_unique_names_and_patterns(self) -> None:
        names = areas.area_names()
        self.assertEqual(len(names), len(set(names)))
        self.assertGreaterEqual(len(names), 18)
        self.assertLessEqual(len(names), 24)
        for name, what, patterns in areas.AREAS:
            self.assertTrue(what and patterns, name)
        self.assertNotIn(areas.UNMAPPED, names)

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

    def test_a_file_no_pattern_covers_is_unmapped_and_reported_so(self) -> None:
        self.assertEqual(areas.area_of("Models/ZzzNoSuchFeature.swift"), areas.UNMAPPED)
        self.assertEqual(areas.unmapped(["Models/ZzzNoSuchFeature.swift", "Models/FeedItem.swift"]),
                         ["Models/ZzzNoSuchFeature.swift"])


class AppCompletenessTests(unittest.TestCase):
    """The table against the app's real files: a new file nobody gave an area fails here."""

    @classmethod
    def setUpClass(cls) -> None:
        if not (REPO / "TextMouth").is_dir():
            raise unittest.SkipTest("no TextMouth/ folder beside the scripts")
        cls.files = [p.as_posix() for p in scanner.swift_files(REPO)]

    def test_every_swift_file_of_the_app_is_in_an_area(self) -> None:
        missing = areas.unmapped(self.files)
        self.assertEqual(missing, [], "add these files to an area in Scripts/l10n/swiftscan/areas.py")

    def test_every_area_owns_at_least_one_file(self) -> None:
        owned = {areas.area_of(f) for f in self.files}
        self.assertEqual([n for n in areas.area_names() if n not in owned], [])


if __name__ == "__main__":
    unittest.main()
