"""The doc sections that point at issues, for ``incomplete`` and ``check``.

A section that describes something missing, limited, or not built yet gives a
``status`` (incomplete or planned) and the ``issues`` that track it in its marker
(see docmodel). The issues are files in ``Issues/``, which the issue-library skill
reads; ``issue_library`` reaches that skill's own modules by path, so the format of
an issue file has one home.
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import ModuleType
from typing import Iterator, Tuple

import docmodel
from docmodel import Marker, Page, Section
from output import UsageError

# The issue-library skill's scripts, beside this skill's folder.
ISSUE_SCRIPTS = Path(__file__).resolve().parents[2] / "issue-library" / "scripts"


def marked_sections(root: Path) -> Iterator[Tuple[Page, Section, Marker]]:
    """Every section of the lint's pages whose marker gives a status or issues, in page and line order."""
    for path in docmodel.lint_pages(root):
        page = docmodel.load_page(root, path)
        for section in page.sections:
            marker = section.marker
            if marker is not None and (marker.status or marker.issues):
                yield page, section, marker


def issue_library() -> ModuleType:
    """The issue-library skill's ``issuestore`` module (with its ``issuefile`` and ``issueids``).

    UsageError when the skill is not in this checkout.
    """
    if not (ISSUE_SCRIPTS / "issuestore.py").is_file():
        raise UsageError(f"the issue-library skill is not in this checkout ({ISSUE_SCRIPTS.parent} is missing)")
    # No bytecode beside the other skill, as -B would keep none; set before its folder joins the path.
    sys.dont_write_bytecode = True
    if str(ISSUE_SCRIPTS) not in sys.path:
        sys.path.append(str(ISSUE_SCRIPTS))
    import issuestore  # noqa: E402  (the issue-library skill's own module, found by path)
    return issuestore
