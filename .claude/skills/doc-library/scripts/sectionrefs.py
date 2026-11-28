"""What one section cites: its prose blocks and the paths they and its marker name.

Shared by the commands that follow a section to its code (``code``, ``stale``,
``suggest-src``), so each reads a section the same way.
"""

from __future__ import annotations

from typing import List, Tuple

import citations
import docmodel
from citations import Citation
from docmodel import Page, Section
from repofiles import RepoFiles


def section_blocks(page: Page, section: Section) -> List[Tuple[int, str]]:
    """The section's prose as ``(first line, text)`` pairs (``docmodel.prose_blocks``)."""
    return docmodel.prose_blocks(page, section)


def section_citations(page: Page, section: Section, repo: RepoFiles) -> List[Citation]:
    """The paths the section cites: its marker's ``src``, its ``Files:`` lists, and its backticked paths."""
    marker = section.marker
    return citations.citations(
        section_blocks(page, section),
        marker.src if marker else [],
        marker.line if marker else None,
        repo,
    )
