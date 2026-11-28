"""Tests of the merge driver for issue files (issuemerge.py), on texts and in real git merges and rebases.

The git tests make a repository in a temporary folder whose config defines the driver
as `make issues-merge-driver` does, but with this checkout's script by its full path.
"""

from __future__ import annotations

import json
import subprocess
from unittest import mock

from issuelib_case import ASSIGNED, B16, RepositoryCase
import issuemerge

# Lines that two comments share, as a pasted train result does: git's own merge pulls
# such a run of four or more lines out of a conflict, which once mixed two comments.
SHARED = ("Train 1116-1739: PASSED.\nExecuted 1305 tests, with 15 tests skipped and 0 failures.\n"
          "iOS errors in your files: 0.\nThe run is on GitHub.\nSee the result file.")


def comment(date: str, author: str, text: str) -> str:
    """A comment block as issuelib appends one."""
    count = len(text.split("\n"))
    return f"\n### {date}, {author}, {count} {'line' if count == 1 else 'lines'}\n\n{text}\n"


class TextTests(RepositoryCase):
    """merge_texts on three versions of one file."""

    def test_a_change_on_one_side_alone_keeps_that_side_byte_for_byte(self) -> None:
        odd = B16.replace("title: A test bug", "title: A test bug  ")
        self.assertEqual(issuemerge.merge_texts(B16, odd, B16), (odd, 0))
        self.assertEqual(issuemerge.merge_texts(B16, B16, odd), (odd, 0))

    def test_different_fields_both_win_and_updated_takes_the_later_date(self) -> None:
        mine = B16.replace("status: open", "status: in-progress").replace("updated: 2026-11-16", "updated: 2026-11-18")
        theirs = B16.replace("priority: P2", "priority: P1").replace("updated: 2026-11-16", "updated: 2026-11-17")
        text, conflicts = issuemerge.merge_texts(B16, mine, theirs)
        self.assertEqual(conflicts, 0)
        self.assertEqual(text, B16.replace("status: open", "status: in-progress").replace("priority: P2", "priority: P1")
                         .replace("updated: 2026-11-16", "updated: 2026-11-18"))

    def test_one_field_changed_both_ways_is_a_conflict_inside_the_header(self) -> None:
        mine = B16.replace("status: open", "status: in-progress")
        theirs = B16.replace("status: open", "status: blocked")
        text, conflicts = issuemerge.merge_texts(B16, mine, theirs)
        self.assertEqual(conflicts, 1)
        self.assertIn("kind: bug\n<<<<<<< current\nstatus: in-progress\n=======\nstatus: blocked\n>>>>>>> other\n"
                      "priority: P2\n", text)

    def test_two_added_comments_stay_whole_in_date_order_whatever_lines_they_share(self) -> None:
        mine = B16 + comment("2026-11-17", "orchestrator", SHARED + "\nMain's conclusion.")
        theirs = B16 + comment("2026-11-16", "floatrender", SHARED + "\nThe branch's conclusion.")
        text, conflicts = issuemerge.merge_texts(B16, mine, theirs)
        self.assertEqual(conflicts, 0)
        self.assertEqual(text, B16 + comment("2026-11-16", "floatrender", SHARED + "\nThe branch's conclusion.")
                         + comment("2026-11-17", "orchestrator", SHARED + "\nMain's conclusion."))

    def test_on_one_date_the_current_sides_comment_comes_first_and_one_added_alike_is_kept_once(self) -> None:
        same = comment("2026-11-16", "orchestrator", "Seen on both.")
        mine = B16 + same + comment("2026-11-16", "orchestrator", "Main's.")
        theirs = B16 + same + comment("2026-11-16", "floatrender", "The branch's.")
        text, _conflicts = issuemerge.merge_texts(B16, mine, theirs)
        self.assertEqual(text, B16 + same + comment("2026-11-16", "orchestrator", "Main's.")
                         + comment("2026-11-16", "floatrender", "The branch's."))

    def test_an_old_comment_edited_on_one_side_takes_the_edit_and_on_both_meets_in_markers(self) -> None:
        base = B16 + comment("2026-11-16", "orchestrator", "First line.\nSecond line.")
        mine = base.replace("Second line.", "Second line, edited.")
        theirs = base + comment("2026-11-17", "floatrender", "New.")
        text, conflicts = issuemerge.merge_texts(base, mine, theirs)
        self.assertEqual((text, conflicts), (mine + comment("2026-11-17", "floatrender", "New."), 0))
        both = base.replace("Second line.", "Second line, theirs.")
        text, conflicts = issuemerge.merge_texts(base, mine, both)
        self.assertEqual(conflicts, 1)
        self.assertIn("<<<<<<< current\nSecond line, edited.\n=======\nSecond line, theirs.\n>>>>>>> other", text)

    def test_a_side_that_drops_a_comment_or_reads_as_no_issue_gets_gits_merge_of_the_whole_file(self) -> None:
        base = B16 + comment("2026-11-16", "orchestrator", "Kept?")
        text, conflicts = issuemerge.merge_texts(base, B16, base + comment("2026-11-17", "x", "More."))
        self.assertEqual(conflicts, 1)
        self.assertIn("<<<<<<< current", text)
        text, conflicts = issuemerge.merge_texts(B16, "not an issue\n", B16.replace("P2", "P1"))
        self.assertEqual(conflicts, 1)
        self.assertIn(">>>>>>> other", text)

    def test_without_git_the_two_sides_go_whole_between_markers(self) -> None:
        with mock.patch.object(issuemerge.subprocess, "run", side_effect=OSError("no git")):
            text, conflicts = issuemerge.merge_lines("a\n", "b\n", "c\n", 7)
        self.assertEqual((text, conflicts), ("<<<<<<< current\nb\n=======\nc\n>>>>>>> other\n", 1))


class GitTests(RepositoryCase):
    """Real merges and rebases with the driver defined in the repository's config."""

    def comment_on_both_sides(self, branch_text: str = "From the branch.", main_text: str = "From main.") -> None:
        """The agent comments on its branch on 2026-11-17, and the orchestrator on main on 2026-11-16."""
        self.git("switch", "-q", "-c", "fix/float64-render")
        with self.on("2026-11-17"):
            self.assertEqual(self.as_agent("comment", "B16", branch_text)[0], 0)
        self.commit_all("floatrender: a comment")
        self.git("switch", "-q", "main")
        self.assertEqual(self.as_orchestrator("comment", "B16", main_text)[0], 0)
        self.commit_all("orchestrator: a comment")

    def comments(self) -> list:
        """B16's comments as (date, author, text), read the way issuelib show reads them."""
        data = json.loads(self.run_cli("show", "B16", "--json")[1])
        return [(c["date"], c["author"], c["text"]) for c in data["comment_list"]]

    def test_two_comments_sharing_lines_merge_whole_and_check_passes(self) -> None:
        self.make_repository()
        self.comment_on_both_sides(SHARED + "\nThe branch's conclusion.", SHARED + "\nMain's conclusion.")
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        self.assertEqual(self.read("Issues/B16.md"), ASSIGNED
                         + comment("2026-11-16", "orchestrator", SHARED + "\nMain's conclusion.")
                         + comment("2026-11-17", "floatrender", SHARED + "\nThe branch's conclusion."))
        self.assertEqual(self.run_cli("check")[:2], (0, ""))

    def test_a_rebase_onto_main_keeps_both_comments_whole(self) -> None:
        self.make_repository()
        self.comment_on_both_sides(SHARED + "\nThe branch's conclusion.", SHARED + "\nMain's conclusion.")
        self.git("switch", "-q", "fix/float64-render")
        rebase = self.git("rebase", "main", check=False)
        self.assertEqual(rebase.returncode, 0, rebase.stdout + rebase.stderr)
        self.assertEqual(self.comments(), [("2026-11-16", "orchestrator", SHARED + "\nMain's conclusion."),
                                           ("2026-11-17", "floatrender", SHARED + "\nThe branch's conclusion.")])
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_header_edits_on_both_sides_merge_field_by_field(self) -> None:
        self.make_repository()
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.as_agent("set", "B16", "status", "in-progress")
        self.commit_all("floatrender: in progress")
        self.git("switch", "-q", "main")
        self.as_orchestrator("set", "B16", "title", "A float book's render fails")
        self.commit_all("orchestrator: a clearer title")
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        text = self.read("Issues/B16.md")
        self.assertEqual(text, ASSIGNED.replace("status: open", "status: in-progress")
                         .replace("title: A test bug", "title: A float book's render fails"))
        self.assertEqual(self.run_cli("check")[0], 0)

    def triage_while_the_branch_is_out(self) -> None:
        """The agent sets in-progress and comments on its branch; main re-triages the issue meanwhile."""
        self.git("switch", "-q", "-c", "fix/float64-render")
        with self.on("2026-11-17"):
            self.assertEqual(self.as_agent("set", "B16", "status", "in-progress")[0], 0)
            self.assertEqual(self.as_agent("comment", "B16", "Started.")[0], 0)
        self.commit_all("floatrender: started")
        self.git("switch", "-q", "main")
        with self.on("2026-11-18"):
            self.assertEqual(self.as_orchestrator("set", "B16", "priority", "P1")[0], 0)
            self.assertEqual(self.as_orchestrator("set", "B16", "labels", "audio, editor")[0], 0)
            self.assertEqual(self.as_orchestrator("assign", "B16", "floatrender", "--branch", "fix/float64-render-2")[0], 0)
        self.commit_all("orchestrator: triage")

    def assert_triaged_and_started(self) -> None:
        """Both sides' header changes are in one header, the comment is whole, and check passes."""
        text = self.read("Issues/B16.md")
        expected = (ASSIGNED.replace("status: open", "status: in-progress").replace("priority: P2", "priority: P1")
                    .replace("labels: audio", "labels: audio, editor").replace("branch: fix/float64-render", "branch: fix/float64-render-2")
                    .replace("updated: 2026-11-16", "updated: 2026-11-18")) + comment("2026-11-17", "floatrender", "Started.")
        self.assertEqual(text, expected)
        self.assertEqual(self.run_cli("check")[:2], (0, ""))

    def test_triage_on_main_while_the_branch_is_out_merges_into_one_header(self) -> None:
        self.make_repository()
        self.triage_while_the_branch_is_out()
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        self.assert_triaged_and_started()

    def test_triage_on_main_while_the_branch_is_out_rebases_into_one_header(self) -> None:
        self.make_repository()
        self.triage_while_the_branch_is_out()
        self.git("switch", "-q", "fix/float64-render")
        rebase = self.git("rebase", "main", check=False)
        self.assertEqual(rebase.returncode, 0, rebase.stdout + rebase.stderr)
        self.assert_triaged_and_started()

    def test_one_field_changed_both_ways_stops_the_merge_with_markers_in_the_header(self) -> None:
        self.make_repository()
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.as_agent("set", "B16", "status", "blocked")
        self.as_agent("comment", "B16", "Blocked on the reader.")
        self.commit_all("floatrender: blocked")
        self.git("switch", "-q", "main")
        self.as_orchestrator("set", "B16", "status", "in-progress")
        self.commit_all("orchestrator: in progress")
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 1)
        self.assertIn("CONFLICT (content): Merge conflict in Issues/B16.md", merge.stdout)
        text = self.read("Issues/B16.md")
        self.assertIn("<<<<<<< current\nstatus: in-progress\n=======\nstatus: blocked\n>>>>>>> other\n", text)
        # Everything else merged: the branch's comment is there once, whole.
        self.assertTrue(text.endswith(comment("2026-11-16", "floatrender", "Blocked on the reader.")))
        status, out, _err = self.run_cli("check")
        self.assertEqual(status, 1)
        self.assertIn("a header line must read 'name: value'", out)
        # Keeping one side's line settles it.
        resolved = text.replace("<<<<<<< current\nstatus: in-progress\n=======\n", "").replace(">>>>>>> other\n", "")
        (self.root / "Issues" / "B16.md").write_text(resolved, encoding="utf-8")
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_a_description_edited_on_both_sides_merges_as_git_would(self) -> None:
        long = ASSIGNED.replace("What is wrong.", "What is wrong.\n\nWhere it shows.\n\nWhat would fix it.")
        self.make_repository(files={"Issues/B16.md": long})
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.write_tree({"Issues/B16.md": long.replace("What is wrong.", "What is wrong, said better.")})
        self.commit_all("the branch: the first paragraph")
        self.git("switch", "-q", "main")
        self.write_tree({"Issues/B16.md": long.replace("What would fix it.", "What would fix it: the reader.")})
        self.commit_all("main: the last paragraph")
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 0, merge.stdout + merge.stderr)
        self.assertEqual(self.read("Issues/B16.md"), long.replace("What is wrong.", "What is wrong, said better.")
                         .replace("What would fix it.", "What would fix it: the reader."))

    def test_one_description_line_edited_both_ways_meets_in_markers(self) -> None:
        self.make_repository()
        self.git("switch", "-q", "-c", "fix/float64-render")
        self.write_tree({"Issues/B16.md": ASSIGNED.replace("What is wrong.", "The branch's words.")})
        self.commit_all("the branch's description")
        self.git("switch", "-q", "main")
        self.write_tree({"Issues/B16.md": ASSIGNED.replace("What is wrong.", "Main's words.")})
        self.commit_all("main's description")
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 1)
        self.assertIn("## Description\n\n<<<<<<< current\nMain's words.\n=======\nThe branch's words.\n>>>>>>> other\n"
                      "\n## Comments\n", self.read("Issues/B16.md"))

    def test_the_trains_branches_merge_one_after_another_into_one_tree(self) -> None:
        self.make_repository()
        # Three branches of the issue's agent, each with a comment (one also sets the status),
        # and a label set on main meanwhile; the train merges all three into one tree.
        work = [("fix/a", "2026-11-18", "A's result."), ("fix/b", "2026-11-17", "B's result."),
                ("fix/c", "2026-11-19", "C's result.")]
        for branch, date, text in work:
            self.git("switch", "-q", "-c", branch, "main")
            with self.on(date):
                self.assertEqual(self.as_agent("comment", "B16", text)[0], 0)
                if branch == "fix/b":
                    self.assertEqual(self.as_agent("set", "B16", "status", "in-progress")[0], 0)
            self.commit_all(f"{branch}: its result")
        self.git("switch", "-q", "main")
        self.assertEqual(self.as_orchestrator("set", "B16", "labels", "audio")[0], 0)
        self.commit_all("main: a label")
        self.git("switch", "-q", "-c", "integrate", "main")
        for branch, _date, _text in work:
            merge = self.merge(branch)
            self.assertEqual(merge.returncode, 0, f"{branch}: {merge.stdout}{merge.stderr}")
        self.assertEqual(self.comments(), [("2026-11-17", "floatrender", "B's result."),
                                           ("2026-11-18", "floatrender", "A's result."),
                                           ("2026-11-19", "floatrender", "C's result.")])
        text = self.read("Issues/B16.md")
        self.assertIn("status: in-progress\n", text)
        self.assertIn("labels: audio\n", text)
        self.assertIn("updated: 2026-11-17\n", text)
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_the_readme_is_left_to_gits_own_merge(self) -> None:
        self.make_repository()
        self.assertEqual(self.git("check-attr", "merge", "Issues/README.md").stdout.strip(), "Issues/README.md: merge: set")
        self.git("switch", "-q", "-c", "docs/readme")
        self.write_tree({"Issues/README.md": "# Issues, the branch's\n"})
        self.commit_all("the branch's README")
        self.git("switch", "-q", "main")
        self.write_tree({"Issues/README.md": "# Issues, main's\n"})
        self.commit_all("main's README")
        merge = self.merge("docs/readme")
        self.assertEqual(merge.returncode, 1)
        # git's own labels: the driver's would say "current" and "other".
        self.assertEqual(self.read("Issues/README.md"),
                         "<<<<<<< HEAD\n# Issues, main's\n=======\n# Issues, the branch's\n>>>>>>> docs/readme\n")

    def test_where_the_driver_is_not_defined_git_merges_as_text_with_markers(self) -> None:
        self.make_repository(driver=False)
        self.comment_on_both_sides()
        merge = self.merge("fix/float64-render")
        self.assertEqual(merge.returncode, 1)
        self.assertIn("CONFLICT (content): Merge conflict in Issues/B16.md", merge.stdout)
        self.assertIn("<<<<<<< HEAD", self.read("Issues/B16.md"))
        self.assertEqual(self.run_cli("check")[0], 1)

    def test_the_make_target_defines_the_driver_in_the_repositorys_config(self) -> None:
        makefile = (issuemerge.Path(__file__).resolve().parents[4] / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("\nissues-merge-driver:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(target.strip().split("\n")[1].strip(),
                         'git config merge.issuefile.driver "python3 -I -B .claude/skills/issue-library/scripts/'
                         'issuelib.py merge-driver %O %A %B %L %P"')
        self.make_repository(driver=False)
        result = subprocess.run(["make", "-f", str(issuemerge.Path(__file__).resolve().parents[4] / "Makefile"),
                                 "issues-merge-driver"], cwd=self.root, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("config", "merge.issuefile.driver").stdout.strip(),
                         "python3 -I -B .claude/skills/issue-library/scripts/issuelib.py merge-driver %O %A %B %L %P")
