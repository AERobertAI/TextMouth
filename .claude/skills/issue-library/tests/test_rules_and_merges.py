"""Tests of who may change what on which branch, and of real git merges of issue files.

Each test makes a git repository in its own temporary folder, with a TODO, an issue
assigned to the agent ``floatrender``, and the real ``.gitattributes`` line that gives
issue files git's union merge, then works on ``main`` and on a branch as the
orchestrator and an agent would.
"""

from __future__ import annotations

import json
from pathlib import Path

from issuelib_case import B16, SKILL, TODO, IssueCase

# The repository's own .gitattributes, two folders above the skill's.
ATTRIBUTES = (SKILL.parents[2] / ".gitattributes").read_text(encoding="utf-8")
# B16, given to the agent that works on it.
ASSIGNED = B16.replace("assignee:\n", "assignee: floatrender\n").replace("branch:\n", "branch: fix/float64-render\n")


class RepositoryCase(IssueCase):
    """A repository on main holding the TODO, B16 assigned to floatrender, and (unless told not to) the union merge."""

    def make_repository(self, union: bool = True) -> None:
        """Commit the starting files on main."""
        files = {"TODO-2026-09-04.md": TODO, "Issues/README.md": "# Issues\n", "Issues/B16.md": ASSIGNED}
        if union:
            files[".gitattributes"] = ATTRIBUTES
        self.git_repo(files)

    def as_agent(self, *argv: str):
        """Run a command as the agent floatrender."""
        return self.run_cli(*argv, "--as", "floatrender")

    def as_orchestrator(self, *argv: str):
        """Run a command as the orchestrator."""
        return self.run_cli(*argv, "--as", "orchestrator")


class RuleTests(RepositoryCase):
    """The orchestrator's changes belong on main; an agent's, on its branch, to its own issue."""

    def setUp(self) -> None:
        super().setUp()
        self.make_repository()

    def test_the_real_attributes_give_issue_files_the_union_merge(self) -> None:
        self.assertEqual(self.git("check-attr", "merge", "Issues/B16.md").stdout.strip(), "Issues/B16.md: merge: union")
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
        self.assertTrue(text.endswith("### 2026-11-16, floatrender\n\nWaiting for the reader's fix.\n"))

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


class MergeTests(RepositoryCase):
    """Real merges: two branches' comments on one issue, and a header line both change."""

    def comment_on_both_sides(self) -> None:
        """The agent comments on its branch, and the orchestrator on main, after the branch began."""
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.assertEqual(self.as_agent("comment", "B16", "From the branch.")[0], 0)
        self.commit_all("floatrender: a comment")
        self.git("switch", "-q", "main")
        self.assertEqual(self.as_orchestrator("comment", "B16", "From main: the user answered.")[0], 0)
        self.commit_all("orchestrator: a comment")

    def test_two_branches_comments_on_one_issue_merge_without_a_conflict(self) -> None:
        self.make_repository()
        self.comment_on_both_sides()
        merge = self.git("merge", "--no-ff", "-m", "Merge the branch", "fix/float64-render", check=False)
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        # Main's comment, then the branch's. git shares the blank line both sides began with,
        # so the second heading follows the first comment's text directly, as Markdown allows.
        self.assertEqual(self.read("Issues/B16.md"), ASSIGNED
                         + "\n### 2026-11-16, orchestrator\n\nFrom main: the user answered.\n"
                         + "### 2026-11-16, floatrender\n\nFrom the branch.\n")
        status, out, _err = self.run_cli("show", "B16", "--json")
        self.assertEqual([(c["author"], c["text"]) for c in json.loads(out)["comment_list"]],
                         [("orchestrator", "From main: the user answered."), ("floatrender", "From the branch.")])
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_a_rebase_onto_main_keeps_both_comments_too(self) -> None:
        self.make_repository()
        self.comment_on_both_sides()
        self.git("switch", "-q", "fix/float64-render")
        rebase = self.git("rebase", "main", check=False)
        self.assertEqual(rebase.returncode, 0, rebase.stdout + rebase.stderr)
        comments = self.read("Issues/B16.md").split("## Comments\n")[1]
        self.assertIn("From main: the user answered.", comments)
        self.assertIn("From the branch.", comments)
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_a_header_line_both_branches_change_is_kept_twice_and_check_fails(self) -> None:
        self.make_repository()
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.as_agent("set", "B16", "status", "in-progress")
        self.commit_all("floatrender: in progress")
        self.git("switch", "-q", "main")
        self.as_orchestrator("set", "B16", "status", "blocked")
        self.commit_all("orchestrator: blocked")
        merge = self.git("merge", "--no-ff", "-m", "Merge the branch", "fix/float64-render", check=False)
        # The union merge does not stop; the check is what catches the doubled line.
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        status, out, _err = self.run_cli("check")
        self.assertEqual(status, 1)
        self.assertIn("Issues/B16.md:6: field status given twice, here and on line 5", out)

    def test_without_the_union_merge_keeping_both_sides_settles_the_conflict(self) -> None:
        self.make_repository(union=False)
        self.comment_on_both_sides()
        merge = self.git("merge", "--no-ff", "-m", "Merge the branch", "fix/float64-render", check=False)
        self.assertNotEqual(merge.returncode, 0)
        self.assertIn("CONFLICT (content): Merge conflict in Issues/B16.md", merge.stdout)
        # Keeping both sides is dropping git's three marker lines.
        path = self.root / "Issues" / "B16.md"
        kept = [line for line in path.read_text(encoding="utf-8").split("\n")
                if not line.startswith(("<<<<<<< ", "=======", ">>>>>>> "))]
        path.write_text("\n".join(kept), encoding="utf-8")
        status, out, _err = self.run_cli("check")
        self.assertEqual((status, out), (0, ""))
        comments = path.read_text(encoding="utf-8").split("## Comments\n")[1]
        self.assertIn("From main: the user answered.", comments)
        self.assertIn("From the branch.", comments)


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
