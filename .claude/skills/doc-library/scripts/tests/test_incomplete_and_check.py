"""Tests of ``incomplete`` and ``check``: doc sections whose marker names the issues that track a gap."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

# A user page with a section of each kind: plain, incomplete, planned, and two broken ones.
PAGE = """\
# Search Library
<!-- id: search-library -->

The window.

## What is searched
<!-- id: library-search-what-searched; keys: feeds; status: incomplete; issues: DR03 -->

A feed's articles are not searched.

## What Search Library does not do
<!-- id: library-search-limits; status: planned; issues: DR01, DR02 -->

There is no Search Library screen on the iPhone.

## Broken one
<!-- id: broken-one; status: incomplete -->

Nothing named.

## Broken two
<!-- id: broken-two; issues: DR01, B12, B14, FR99, dr1 -->

No status, and issues that are done, only in the TODO, or nowhere.
"""

# A TODO that names B12 as a done item.
TODO = "# TODO\n\n## Bugs\n\n- [x] **B12 — A float book crashes.** Merged 6b09b2ee2.\n"


def issue(issue_id: str, status: str = "open") -> str:
    """A valid issue file for ``issue_id`` with ``status`` (a closed one names its merge)."""
    merged = "6b09b2ee2" if status == "done" else ""
    return (f"---\nid: {issue_id}\ntitle: A gap\nkind: feature\nstatus: {status}\npriority: P2\nplatform: mac\n"
            f"assignee:\ncreated: 2026-11-16\nupdated: 2026-11-16\nfound-by: docaudit\nbranch:\n"
            f"merged: {merged}\nreason:\nrelated:\ndocs:\nlabels:\n---\n\n## Description\n\nA gap.\n\n## Comments\n")


class IncompleteTests(DocLibCase):
    """incomplete: one hit for each section whose marker gives a status or issues."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"docs/user/search-library.md": PAGE})

    def test_each_marked_section_with_its_status_and_issues(self) -> None:
        status, out, err = self.run_cli("incomplete")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(out.splitlines(), [
            "docs/user/search-library.md:6-9  What is searched  incomplete: DR03",
            "docs/user/search-library.md:11-14  What Search Library does not do  planned: DR01, DR02",
            "docs/user/search-library.md:16-19  Broken one  incomplete: no issue",
            "docs/user/search-library.md:21-24  Broken two  no status: DR01, B12, B14, FR99, dr1",
        ])

    def test_filters_and_json(self) -> None:
        out = self.run_cli("incomplete", "--issue", "DR01")[1]
        self.assertEqual([line.split("  ")[1] for line in out.splitlines()],
                         ["What Search Library does not do", "Broken two"])
        out = self.run_cli("incomplete", "--status", "planned", "--json")[1]
        data = [json.loads(line) for line in out.splitlines()]
        self.assertEqual([(d["id"], d["status"], d["issues"]) for d in data],
                         [("library-search-limits", "planned", ["DR01", "DR02"])])
        self.assertEqual(self.run_cli("incomplete", "--issue", "XYZ1")[0], 1)

    def test_find_already_matches_a_marker_by_its_issue(self) -> None:
        out = self.run_cli("find", "DR03")[1]
        self.assertIn("library-search-what-searched; keys: feeds; status: incomplete; issues: DR03", out)


class CheckTests(DocLibCase):
    """check: a status needs issues, and each issue must be an open issue file."""

    def test_every_kind_of_problem_is_one_hit(self) -> None:
        self.write_tree({
            "docs/user/search-library.md": PAGE, "TODO-2026-09-04.md": TODO,
            "Issues/DR01.md": issue("DR01"), "Issues/DR02.md": issue("DR02", "in-progress"),
            "Issues/DR03.md": issue("DR03"), "Issues/B14.md": issue("B14", "done"),
        })
        status, out, err = self.run_cli("check")
        self.assertEqual(status, 1)
        prefix = "docs/user/search-library.md"
        self.assertEqual(out.splitlines(), [
            f"{prefix}:17-17  Broken one  status incomplete names no issue: add issues: ID for the work that would finish it",
            f"{prefix}:22-22  Broken two  issues without a status: give status: incomplete or planned",
            f"{prefix}:22-22  Broken two  B12 has no file in Issues/; TODO-2026-09-04.md names it on line 5",
            f"{prefix}:22-22  Broken two  B14 is done: update the section, and drop the issue (and the status, if no other is open)",
            f"{prefix}:22-22  Broken two  FR99 has no file in Issues/",
            f"{prefix}:22-22  Broken two  dr1 is not an ID",
        ])
        self.assertEqual(err, "doclib check: 6 problems in the 4 sections with a status or issues\n")

    def test_open_issues_pass(self) -> None:
        self.write_tree({
            "docs/user/search-library.md": PAGE.split("## Broken one")[0],
            "Issues/DR01.md": issue("DR01"), "Issues/DR02.md": issue("DR02", "blocked"), "Issues/DR03.md": issue("DR03"),
        })
        self.assertEqual(self.run_cli("check"), (0, "", "doclib check: 2 sections with a status or issues, no problems\n"))

    def test_a_marker_status_other_than_incomplete_or_planned_is_a_lint_error(self) -> None:
        self.write_tree({"docs/user/x.md": "# X\n<!-- id: x; status: done; issues: DR01 -->\n\nText.\n"})
        out = self.run_cli("lint", "--report", "--rule", "marker-invalid")[1]
        self.assertIn("marker-invalid: status not incomplete or planned: 'done'", out)
