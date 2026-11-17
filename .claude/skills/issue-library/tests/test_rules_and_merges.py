"""Tests of who may change what on which branch, and of the IDs git's history holds.

Each test makes a git repository in its own temporary folder (issuelib_case's
RepositoryCase: a TODO, an issue assigned to the agent ``floatrender``, the real
``.gitattributes``, and the merge driver), then works on ``main`` and on a branch
as the orchestrator and an agent would. The merges themselves are in
test_merge_driver.py.
"""

from __future__ import annotations

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
