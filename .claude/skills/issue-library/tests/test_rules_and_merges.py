"""Tests of who may change what on which branch, and of the IDs git's history holds.

Each test makes a git repository in its own temporary folder (issuelib_case's
RepositoryCase: a TODO, an issue assigned to the agent ``floatrender``, the real
``.gitattributes``, and the merge driver), then works on ``main`` and on a branch
as the orchestrator and an agent would. The merges themselves are in
test_merge_driver.py.
"""

from __future__ import annotations

import json
from pathlib import Path

from issuelib_case import ASSIGNED, B16, TODO, RepositoryCase


class RuleTests(RepositoryCase):
    """The orchestrator's changes belong on main; an agent's, on its branch, to its own issue."""

    def setUp(self) -> None:
        super().setUp()
        self.make_repository()

    def test_the_real_attributes_give_issue_files_the_driver(self) -> None:
        self.assertEqual(self.git("check-attr", "merge", "Issues/B16.md").stdout.strip(), "Issues/B16.md: merge: issuefile")
        self.assertEqual(self.git("check-attr", "merge", "TODO-2026-09-04.md").stdout.strip(),
                         "TODO-2026-09-04.md: merge: unspecified")

    def test_on_main_the_orchestrator_files_assigns_and_closes(self) -> None:
        self.assertEqual(self.new_issue("Another bug")[0], 0)
        self.assertEqual(self.as_orchestrator("assign", "B17", "rulesmove")[0], 0)
        self.assertEqual(self.as_orchestrator("set", "B17", "priority", "P1")[0], 0)
        self.assertEqual(self.as_orchestrator("close", "B17", "--merged", "a557ee2b4")[0], 0)

    def test_on_a_branch_filing_assigning_and_closing_are_refused(self) -> None:
        self.git("switch", "-q", "-c", "fix/float64-render")
        status, _out, err = self.new_issue("A bug found on a branch")
        self.assertEqual(status, 1)
        self.assertIn("filing an issue is the orchestrator's, on main, and this is fix/float64-render", err)
        for argv in (("assign", "B16", "other"), ("close", "B16", "--merged", "abc1234"),
                     ("set", "B16", "priority", "P1"), ("set", "B16", "status", "open")):
            with self.subTest(argv):
                status, _out, err = self.as_agent(*argv)
                self.assertEqual(status, 1, err)
                self.assertIn("is the orchestrator's, on main", err)
        self.assertEqual(self.read("Issues/B16.md"), ASSIGNED)
        self.assertEqual(sorted(path.name for path in (self.root / "Issues").iterdir()), ["B16.md", "README.md"])

    def test_filing_on_a_branch_needs_on_branch(self) -> None:
        self.git("switch", "-q", "-c", "tools/x")
        self.assertEqual(self.new_issue("Left out of a review", "tooling")[0], 1)
        status, out, err = self.new_issue("Left out of a review", "tooling", "both", "--on-branch")
        self.assertEqual((status, out), (0, "issuelib: filed Issues/TL01.md: TL01, tooling, P2, both: Left out of a review\n"), err)

    def test_on_a_branch_the_assignee_comments_and_sets_in_progress_or_blocked(self) -> None:
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.assertEqual(self.as_agent("set", "B16", "status", "in-progress")[0], 0)
        self.assertEqual(self.as_agent("comment", "B16", "Waiting for the reader's fix.")[0], 0)
        self.assertEqual(self.as_agent("set", "B16", "status", "blocked")[0], 0)
        text = self.read("Issues/B16.md")
        self.assertIn("status: blocked\n", text)
        self.assertTrue(text.endswith("### 2026-11-16, floatrender, 1 line\n\nWaiting for the reader's fix.\n"))

    def test_on_a_branch_another_agent_may_not_touch_the_issue(self) -> None:
        self.git("switch", "-q", "-c", "fix/rules-save-during-move")
        status, _out, err = self.run_cli("comment", "B16", "Looks related.", "--as", "rulesmove")
        self.assertEqual(status, 1)
        self.assertIn("B16 is assigned to floatrender, not rulesmove", err)
        self.assertIn("post anything else on the board", err)

    def test_a_branch_made_before_the_assignment_may_touch_the_issue_only_after_a_rebase(self) -> None:
        self.write_tree({"Issues/B17.md": B16.replace("id: B16", "id: B17")})
        self.commit_all("B17, not yet assigned")
        self.git("switch", "-q", "-c", "fix/early")
        status, _out, err = self.as_agent("comment", "B17", "Started.")
        self.assertEqual(status, 1)
        self.assertIn("B17 is assigned to no one, not floatrender", err)
        self.git("switch", "-q", "main")
        self.assertEqual(self.as_orchestrator("assign", "B17", "floatrender", "--branch", "fix/early")[0], 0)
        self.commit_all("orchestrator: B17 to floatrender")
        self.git("switch", "-q", "fix/early")
        self.git("rebase", "-q", "main")
        self.assertEqual(self.as_agent("comment", "B17", "Started.")[0], 0)

    def test_a_detached_head_is_no_branch_and_so_not_main(self) -> None:
        self.git("switch", "-q", "--detach")
        status, _out, err = self.new_issue("A bug")
        self.assertEqual(status, 1)
        self.assertIn("this is (no branch)", err)

    def test_a_folder_inside_a_repository_is_not_its_top_so_no_rule_applies(self) -> None:
        copy = self.root / "build" / "copy"
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.write_tree({"TODO-2026-09-04.md": TODO, "Issues/B16.md": ASSIGNED}, root=copy)
        self.assertEqual(self.new_issue("A bug in a copy", root=copy)[0], 0)


class NewSinceTests(RepositoryCase):
    """check --new-since: the problems a merge brings, against an earlier check --json, in the files it changed."""

    def test_only_new_problems_in_changed_files_count(self) -> None:
        broken = ASSIGNED.replace("related: B12", "related: B99")
        self.make_repository(files={"Issues/B16.md": broken, "Issues/B18.md": broken.replace("id: B16", "id: B18")})
        # main's problems: B18's only, as if B16's were not there yet (so B16's counts as new).
        snapshot = self.root / "before.json"
        snapshot.write_text(json.dumps({"path": "Issues/B18.md", "line": 15,
                                        "message": "related B99 names no issue file, TODO item, or alias"}) + "\n")
        # The merge changes B16 (a comment) and adds a broken B17; B18 is left alone.
        self.as_orchestrator("comment", "B16", "From the merge.")
        self.write_tree({"Issues/B17.md": broken.replace("id: B16", "id: B17").replace("found-by: orchestrator\n", "")})
        status, out, err = self.run_cli("check", "--new-since", str(snapshot))
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines(), [
            "Issues/B16.md:15: related B99 names no issue file, TODO item, or alias",
            "Issues/B17.md:1: missing field found-by",
            "Issues/B17.md:14: related B99 names no issue file, TODO item, or alias",
        ])
        self.assertIn("3 new problems in the files changed against HEAD (1 others left out", err)

    def test_a_problem_in_a_file_the_merge_left_alone_is_not_its(self) -> None:
        # B18 cites a doc section that is gone, which no snapshot lists; the merge changes B16 only.
        self.make_repository(files={"Issues/B18.md": ASSIGNED.replace("id: B16", "id: B18").replace("docs:", "docs: gone")})
        snapshot = self.root / "before.json"
        snapshot.write_text("")
        self.as_orchestrator("comment", "B16", "From the merge.")
        status, out, err = self.run_cli("check", "--new-since", str(snapshot))
        self.assertEqual((status, out), (0, ""), err)
        self.assertIn("(1 others left out", err)
        # The same problem in a file the merge changes is the merge's.
        self.write_tree({"Issues/B16.md": self.read("Issues/B16.md").replace("docs:", "docs: gone")})
        status, out, _err = self.run_cli("check", "--new-since", str(snapshot))
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines(), ["Issues/B16.md:16: docs gone names no doc section (doclib find gone finds none)"])

    def test_a_problem_main_had_is_the_same_one_after_its_lines_moved(self) -> None:
        twice = TODO + "- [x] **B13 — once.**\n- [x] **B13 — twice.**\n"
        self.make_repository(files={"TODO-2026-09-04.md": twice})
        snapshot = self.root / "before.json"
        snapshot.write_text(self.run_cli("check", "--json")[1])
        self.assertIn("B13 opens 2 items (lines 13 and 14)", snapshot.read_text())
        # The merge adds an entry above the two, so their line numbers change.
        self.write_tree({"TODO-2026-09-04.md": twice.replace("## Bugs\n", "## Bugs\n\n- [x] **B11 — new.**\n")})
        status, out, err = self.run_cli("check", "--new-since", str(snapshot))
        self.assertEqual((status, out), (0, ""), err)
        self.assertIn("no new problems in the files changed against HEAD (2 others left out", err)


class HistoryTests(RepositoryCase):
    """In git, numbers in the TODO's old versions, and old issue files, count as used."""

    def test_a_number_only_an_old_version_of_the_todo_held_is_not_given_again(self) -> None:
        self.make_repository()
        self.write_tree({"TODO-2026-09-04.md": TODO.replace("## Bugs\n", "## Bugs\n\n- [ ] **B40 — a bug.**\n")})
        self.commit_all("an item that is later taken out")
        self.write_tree({"TODO-2026-09-04.md": TODO})
        self.commit_all("taken out")
        status, out, _err = self.new_issue("A new bug")
        self.assertEqual((status, out.split(":")[1].strip()), (0, "filed Issues/B41.md"))

    def test_the_id_of_an_issue_file_that_was_moved_away_is_not_given_again(self) -> None:
        self.make_repository()
        self.write_tree({"Issues/B30.md": B16.replace("id: B16", "id: B30")})
        self.commit_all("B30")
        self.git("mv", "Issues/B30.md", "B30-elsewhere.md")
        self.commit_all("B30 moved out of Issues/")
        self.assertIn("filed Issues/B31.md", self.new_issue("A new bug")[1])
        self.assertTrue(Path(self.root / "B30-elsewhere.md").is_file())
