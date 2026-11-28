"""Dates as the TODO writes them ("November 16, 2026", or "October 3" in the TODO's own year)
and as issue files do (2026-11-16): one home for the months and their parsing.

The import reads an item's date from its text with ``DATE_IN_WORDS`` and
``iso_of``; ``record-merge.py --date`` takes a whole date with ``parse_date``.
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Optional

# The months, January first.
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December")

# A date in words inside text: the month, the day (not the start of a longer number), and perhaps ", YYYY".
DATE_IN_WORDS = re.compile(r"\b(" + "|".join(MONTHS) + r") (\d{1,2})(?!\d)(?:, (\d{4}))?")
# A whole date written YYYY-MM-DD.
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def iso_of(match: "re.Match[str]", year: int) -> str:
    """A ``DATE_IN_WORDS`` match as YYYY-MM-DD, in ``year`` when it names none; "" for an impossible date."""
    try:
        return dt.date(int(match.group(3) or year), MONTHS.index(match.group(1)) + 1, int(match.group(2))).isoformat()
    except ValueError:
        return ""


def parse_date(text: str, today: dt.date) -> Optional[str]:
    """A whole date, "2026-11-16", "November 16, 2026", or "November 16", as YYYY-MM-DD; None when it is none.

    A date without a year is in ``today``'s year, or the year before when that
    would put it ahead of today (a merge recorded on January 1 for December 31).
    """
    text = text.strip()
    if _ISO.match(text):
        try:
            return dt.date.fromisoformat(text).isoformat()
        except ValueError:
            return None
    match = DATE_IN_WORDS.fullmatch(text)
    if match is None:
        return None
    iso = iso_of(match, today.year)
    if iso and not match.group(3) and iso > today.isoformat():
        iso = iso_of(match, today.year - 1)
    return iso or None
