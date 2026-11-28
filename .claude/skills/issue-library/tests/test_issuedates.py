"""Tests of issuedates: dates in the TODO's words and in an issue file's digits."""

from __future__ import annotations

import datetime as dt
import unittest

import issuelib_case  # noqa: F401  (puts the scripts folder on sys.path)
import issuedates

TODAY = dt.date(2026, 11, 16)


class ParseDateTests(unittest.TestCase):
    """parse_date: a whole date, three ways, or None."""

    def test_the_three_ways_a_date_is_written(self) -> None:
        self.assertEqual(issuedates.parse_date("2026-11-15", TODAY), "2026-11-15")
        self.assertEqual(issuedates.parse_date("November 15, 2026", TODAY), "2026-11-15")
        self.assertEqual(issuedates.parse_date(" November 15 ", TODAY), "2026-11-15")

    def test_a_date_without_a_year_ahead_of_today_is_last_years(self) -> None:
        self.assertEqual(issuedates.parse_date("December 31", dt.date(2027, 1, 1)), "2026-12-31")
        self.assertEqual(issuedates.parse_date("December 31", TODAY), "2025-12-31")
        self.assertEqual(issuedates.parse_date("December 31, 2026", TODAY), "2026-12-31")

    def test_what_is_no_date(self) -> None:
        for text in ("16 November", "November", "2026-02-30", "February 30", "Nov 16", "November 16th", "", "2026-1-5"):
            self.assertIsNone(issuedates.parse_date(text, TODAY), text)


class DatesInTextTests(unittest.TestCase):
    """DATE_IN_WORDS and iso_of: a date inside an item's text."""

    def test_a_date_is_found_in_text_and_a_year_alone_is_not_a_day(self) -> None:
        match = issuedates.DATE_IN_WORDS.search("Found November 16, 2026 by `review-rulesmove`.")
        self.assertEqual(issuedates.iso_of(match, 2026), "2026-11-16")
        match = issuedates.DATE_IN_WORDS.search("Requested October 3. Research first.")
        self.assertEqual(issuedates.iso_of(match, 2026), "2026-10-03")
        self.assertIsNone(issuedates.DATE_IN_WORDS.search("eBraille 1.0 (August 2025)"))


if __name__ == "__main__":
    unittest.main()
