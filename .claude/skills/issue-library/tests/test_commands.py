"""Tests of issuelib.py's commands, run in-process on a folder outside git, where no branch rule applies."""

from __future__ import annotations

import json

from issuelib_case import B16, TODO, IssueCase


class FilingTests(IssueCase):
    """new: the next free ID of the kind's family, from the template."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"TODO-2026-09-04.md": TODO, "Issues/README.md": "# Issues\n"})

    def test_a_new_bug_takes_the_next_b_and_reads_as_the_template_says(self) -> None:
        status, out, err = self.new_issue("A test bug", "bug", "mac", "--related", "B12", "--labels", "audio")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(out, "issuelib: filed Issues/B16.md: B16, bug, P2, mac: A test bug\n")
        self.assertEqual(self.read("Issues/B16.md"), B16)
        # The next one goes on from there.
        self.assertEqual(self.new_issue("Another")[1], "issuelib: filed Issues/B17.md: B17, bug, P2, mac: Another\n")

    def test_each_kind_starts_its_own_family_and_mentions_count(self) -> None:
        self.assertIn("FR01", self.new_issue("A wish", "feature")[1])
        self.assertIn("TL01", self.new_issue("A tool", "tooling")[1])
        # The TODO's prose names C18 (another list's item), so C goes on from C19.
        self.assertIn("C19", self.new_issue("A setting", "bug", "mac", "--family", "C")[1])
        self.assertIn("PG01", self.new_issue("A page", "feature", "both", "--family", "PG")[1])

    def test_a_typo_in_a_related_field_does_not_move_the_next_number(self) -> None:
        self.write_tree({"Issues/B16.md": B16.replace("related: B12", "related: B99")})
        self.assertIn("filed Issues/B17.md", self.new_issue("Next")[1])

    def test_a_given_id_must_be_unused(self) -> None:
        for taken in ("B12", "B12-OCT", "B14"):
            status, _out, err = self.new_issue("Again", "bug", "mac", "--id", taken)
            self.assertEqual(status, 1, err)
            self.assertIn("is used already", err)
        # B13 opens no item, but its number is below the highest B, so it may have been used elsewhere.
        status, _out, err = self.new_issue("Again", "bug", "mac", "--id", "B03")
        self.assertEqual((status, "next free one is B16" in err), (0, False), err)
        status, out, _err = self.new_issue("Named", "follow-up", "both", "--id", "FU-AUDIO")
        self.assertEqual((status, out), (0, "issuelib: filed Issues/FU-AUDIO.md: FU-AUDIO, follow-up, P2, both: Named\n"))

    def test_bad_values_are_usage_errors(self) -> None:
        self.assertEqual(self.run_cli("new", "--kind", "bug", "--title", "T", "--platform", "mac",
                                      "--as", "orchestrator")[0], 2)
        self.assertEqual(self.new_issue("T", "crash")[0], 2)
        self.assertEqual(self.new_issue("T", "bug", "ipad")[0], 2)
        self.assertEqual(self.new_issue("T", "bug", "mac", "--family", "b")[0], 2)
        self.assertEqual(self.new_issue("T", "bug", "mac", "--id", "b16")[0], 2)
        self.assertEqual(self.new_issue("T", "bug", "mac", "--labels", "Bad Label")[0], 1)
        self.assertFalse((self.root / "Issues/B16.md").exists())

    def test_a_reference_that_names_nothing_is_refused(self) -> None:
        status, _out, err = self.new_issue("T", "bug", "mac", "--related", "B12, B99")
        self.assertEqual((status, err), (1, "issuelib: refused: related B99 names no issue file, TODO item, or alias\n"))
        status, _out, err = self.new_issue("T", "bug", "mac", "--docs", "no-such-section")
        self.assertEqual(status, 1)
        self.assertIn("docs no-such-section names no doc section", err)
        self.assertFalse((self.root / "Issues/B16.md").exists())
        # An alias and a real section are fine.
        self.write_tree({"docs/user/x.md": "# X\n<!-- id: x-top -->\n\nText.\n"})
        self.assertEqual(self.new_issue("T", "bug", "mac", "--related", "B12-OCT", "--docs", "x-top")[0], 0)

    def test_the_description_may_come_from_a_file(self) -> None:
        self.write_tree({"desc.txt": "First paragraph.\n\n- a point\n"})
        status, _out, err = self.run_cli("new", "--kind", "bug", "--title", "T", "--platform", "mac",
                                         "--file", str(self.root / "desc.txt"), "--as", "orchestrator")
        self.assertEqual(status, 0, err)
        self.assertIn("## Description\n\nFirst paragraph.\n\n- a point\n\n## Comments\n", self.read("Issues/B16.md"))


class ChangeTests(IssueCase):
    """set, assign, comment, close, and reopen: one file each, one line saying what changed."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"TODO-2026-09-04.md": TODO, "Issues/B16.md": B16})

    def as_orchestrator(self, *argv: str):
        """Run a command as the orchestrator."""
        return self.run_cli(*argv, "--as", "orchestrator")

    def test_set_changes_one_line_and_updated(self) -> None:
        import os
        os.environ["ISSUELIB_TODAY"] = "2026-11-18"
        status, out, err = self.as_orchestrator("set", "B16", "priority", "P1")
        self.assertEqual((status, out, err), (0, "issuelib: Issues/B16.md: priority P2 -> P1\n", ""))
        self.assertEqual(self.read("Issues/B16.md"),
                         B16.replace("priority: P2", "priority: P1").replace("updated: 2026-11-16", "updated: 2026-11-18"))

    def test_set_normalizes_lists_and_keeps_colons_in_text(self) -> None:
        self.as_orchestrator("set", "B16", "related", "B12", "B14,B15")
        self.as_orchestrator("set", "B16", "title", "Speak", "Info:", "the selection")
        text = self.read("Issues/B16.md")
        self.assertIn("related: B12, B14, B15\n", text)
        self.assertIn("title: Speak Info: the selection\n", text)
        # No value clears a field.
        self.as_orchestrator("set", "B16", "labels")
        self.assertIn("labels:\n", self.read("Issues/B16.md"))

    def test_set_refuses_what_belongs_to_another_command(self) -> None:
        cases = {
            ("status", "done"): (1, "close closes an issue"),
            ("merged", "abc1234"): (1, "merged belongs to a closed issue"),
            ("id", "B17"): (2, "id is not set by hand"),
            ("updated", "2026-11-17"): (2, "updated is not set by hand"),
            ("colour", "red"): (2, "'colour' is not a field"),
            ("priority", "P4"): (2, "priority 'P4' is not one of"),
        }
        for (name, value), (expected_status, expected) in cases.items():
            with self.subTest(name):
                status, _out, err = self.as_orchestrator("set", "B16", name, value)
                self.assertEqual(status, expected_status, err)
                self.assertIn(expected, err)
        self.assertEqual(self.read("Issues/B16.md"), B16)

    def test_set_refuses_a_related_or_docs_entry_that_names_nothing(self) -> None:
        for name, value, expected in (("related", "B12 B99", "related B99 names no issue file"),
                                      ("docs", "no-such-section", "docs no-such-section names no doc section")):
            with self.subTest(name):
                status, _out, err = self.as_orchestrator("set", "B16", name, value)
                self.assertEqual(status, 1)
                self.assertIn(expected, err)
        self.assertEqual(self.read("Issues/B16.md"), B16)
        self.write_tree({"docs/user/x.md": "# X\n<!-- id: x-top -->\n\nText.\n"})
        self.assertEqual(self.as_orchestrator("set", "B16", "docs", "x-top")[0], 0)
        self.assertIn("docs: x-top\n", self.read("Issues/B16.md"))

    def test_set_to_the_same_value_writes_nothing(self) -> None:
        status, out, _err = self.as_orchestrator("set", "B16", "priority", "P2")
        self.assertEqual((status, out), (0, "issuelib: Issues/B16.md: priority is P2 already\n"))
        self.assertEqual(self.read("Issues/B16.md"), B16)

    def test_assign_names_the_agent_and_its_branch(self) -> None:
        status, out, _err = self.as_orchestrator("assign", "B16", "floatrender", "--branch", "fix/float64-render")
        self.assertEqual(out, "issuelib: Issues/B16.md: assignee none -> floatrender; branch none -> fix/float64-render\n")
        text = self.read("Issues/B16.md")
        self.assertIn("assignee: floatrender\n", text)
        self.assertIn("branch: fix/float64-render\n", text)
        self.as_orchestrator("assign", "B16", "none")
        self.assertIn("assignee:\n", self.read("Issues/B16.md"))

    def test_a_comment_goes_at_the_end_and_leaves_the_header(self) -> None:
        status, out, _err = self.run_cli("comment", "B16", "Found the cause.\n\nIt is the reader.", "--as", "floatrender")
        self.assertEqual(out, "issuelib: Issues/B16.md: comment by floatrender on 2026-11-16 added (3 lines)\n")
        self.assertEqual(self.read("Issues/B16.md"),
                         B16 + "\n### 2026-11-16, floatrender, 3 lines\n\nFound the cause.\n\nIt is the reader.\n")

    def test_a_comment_that_would_break_the_file_is_refused(self) -> None:
        for text in ("", "## Next"):
            status, _out, err = self.run_cli("comment", "B16", text, "--as", "floatrender")
            self.assertEqual(status, 1, err)
        self.assertEqual(self.run_cli("comment", "B16", "--as", "floatrender")[0], 2)
        self.assertEqual(self.read("Issues/B16.md"), B16)

    def test_close_at_a_merge_and_reopen(self) -> None:
        status, out, _err = self.as_orchestrator("close", "B16", "--merged", "6b09b2ee2", "--date", "2026-11-17")
        self.assertEqual(out, "issuelib: Issues/B16.md: closed as done, merged 6b09b2ee2, on 2026-11-17\n")
        closed = self.read("Issues/B16.md")
        self.assertIn("status: done\n", closed)
        self.assertIn("merged: 6b09b2ee2\n", closed)
        self.assertIn("updated: 2026-11-17\n", closed)
        self.assertTrue(closed.endswith("\n### 2026-11-17, orchestrator, 1 line\n\nClosed as done: merged in 6b09b2ee2.\n"))
        self.assertEqual(self.as_orchestrator("close", "B16", "--merged", "6b09b2ee2")[0], 1)
        status, out, _err = self.as_orchestrator("reopen", "B16", "--reason", "It crashes again on WAVE.")
        self.assertEqual(out, "issuelib: Issues/B16.md: reopened (it was done, merged in 6b09b2ee2)\n")
        reopened = self.read("Issues/B16.md")
        self.assertIn("status: open\n", reopened)
        self.assertIn("merged:\n", reopened)
        self.assertTrue(reopened.endswith(
            "\n### 2026-11-16, orchestrator, 1 line\n\nReopened: It crashes again on WAVE. It was done, merged in 6b09b2ee2.\n"))

    def test_close_ticks_the_pointer_line_and_reopen_unticks_it(self) -> None:
        self.write_tree({"TODO-2026-09-04.md": TODO + "- [ ] **B16** moved to Issues/B16.md\n"})
        out = self.as_orchestrator("close", "B16", "--status", "wontfix", "--reason", "The user withdrew it.")[1]
        self.assertEqual(out.splitlines()[1], "issuelib: TODO-2026-09-04.md: B16's pointer line ticked")
        self.assertTrue(self.read("TODO-2026-09-04.md").endswith("- [x] **B16** moved to Issues/B16.md\n"))
        out = self.as_orchestrator("reopen", "B16", "--reason", "The user wants it after all.")[1]
        self.assertEqual(out.splitlines()[1], "issuelib: TODO-2026-09-04.md: B16's pointer line unticked")
        self.assertTrue(self.read("TODO-2026-09-04.md").endswith("- [ ] **B16** moved to Issues/B16.md\n"))
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_closing_needs_a_merge_or_a_reason(self) -> None:
        cases = [
            ((), 2, "needs --merged HASH or --reason TEXT"),
            (("--status", "wontfix"), 2, "closing as wontfix needs --reason"),
            (("--merged", "ABC"), 2, "is not a commit"),
            (("--status", "open", "--reason", "x"), 2, "invalid choice"),
        ]
        for extra, expected_status, expected in cases:
            with self.subTest(extra):
                status, _out, err = self.as_orchestrator("close", "B16", *extra)
                self.assertEqual(status, expected_status, err)
                self.assertIn(expected, err)
        status, _out, _err = self.as_orchestrator("close", "B16", "--status", "duplicate", "--reason", "B15 again.")
        self.assertEqual(status, 0)
        text = self.read("Issues/B16.md")
        self.assertIn("reason: B15 again.\n", text)
        self.assertTrue(text.endswith("Closed as duplicate: B15 again.\n"))

    def test_an_id_with_no_file_is_a_usage_error_that_says_where_it_is(self) -> None:
        status, _out, err = self.as_orchestrator("set", "B14", "priority", "P1")
        self.assertEqual(status, 2)
        self.assertIn("B14 has no file in Issues/; TODO-2026-09-04.md names it on line 10", err)

    def test_check_fails_an_empty_comment_and_a_wrong_line_count(self) -> None:
        self.write_tree({"Issues/B16.md": B16 + "\n### 2026-11-16, floatrender, 2 lines\n\nOne line only.\n"
                                               "\n### 2026-11-17, orchestrator, 1 line\n\n"
                                               "\n### 2026-11-18, orchestrator\n\nNo count.\n"})
        status, out, _err = self.run_cli("check")
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines(), [
            "Issues/B16.md:26: the heading says 2 lines, and the comment has 1 (lines of two comments mixed in a merge, "
            "or an edit that left the count)",
            "Issues/B16.md:30: the comment of 2026-11-17 by orchestrator has no text",
            "Issues/B16.md:33: the heading gives no line count: '### 2026-11-18, orchestrator, 1 line'",
        ])

    def test_a_broken_file_is_refused_until_fixed_by_hand(self) -> None:
        self.write_tree({"Issues/B16.md": B16.replace("status: open\n", "status: open\nstatus: blocked\n")})
        status, _out, err = self.run_cli("comment", "B16", "Text.", "--as", "orchestrator")
        self.assertEqual(status, 1)
        self.assertIn("Issues/B16.md:6: field status given twice", err)


class ReadingTests(IssueCase):
    """list, show, search, and summary."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"TODO-2026-09-04.md": TODO})
        self.new_issue("Plain bug", "bug", "mac")
        self.new_issue("Urgent bug", "bug", "both", "--priority", "P1", "--labels", "audio")
        self.new_issue("A wish", "feature", "iphone", "--priority", "P3")
        self.run_cli("assign", "B17", "floatrender", "--as", "orchestrator")
        self.run_cli("set", "B17", "status", "in-progress", "--as", "orchestrator")
        self.run_cli("close", "B16", "--reason", "fixed by hand", "--as", "orchestrator")

    def test_list_shows_what_is_not_closed_by_priority_one_line_each(self) -> None:
        status, out, err = self.run_cli("list")
        self.assertEqual(status, 0)
        self.assertEqual(out, "B17 P1 in-progress both floatrender: Urgent bug\nFR01 P3 open iphone: A wish\n")
        self.assertEqual(err, "issuelib: 2 of 3 issues\n")

    def test_list_filters(self) -> None:
        cases = {
            ("--status", "all"): ["B17", "B16", "FR01"],
            ("--status", "done"): ["B16"],
            ("--priority", "P3"): ["FR01"],
            ("--kind", "bug"): ["B17"],
            ("--platform", "iphone"): ["B17", "FR01"],
            ("--platform", "mac"): ["B17"],
            ("--platform", "both"): ["B17"],
            ("--assignee", "floatrender"): ["B17"],
            ("--assignee", "none"): ["FR01"],
            ("--label", "audio"): ["B17"],
        }
        for argv, expected in cases.items():
            with self.subTest(argv):
                out = self.run_cli("list", *argv)[1]
                self.assertEqual([line.split()[0] for line in out.splitlines()], expected)
        self.assertEqual(self.run_cli("list", "--status", "closed")[0], 2)

    def test_list_cuts_lines_for_a_braille_display_and_prints_json(self) -> None:
        self.run_cli("set", "FR01", "title", "A wish " + "that goes on " * 10, "--as", "orchestrator")
        line = self.run_cli("list", "--width", "40", "--priority", "P3")[1].strip()
        self.assertEqual(len(line), 40)
        self.assertTrue(line.endswith("…"))
        objects = [json.loads(line) for line in self.run_cli("list", "--json")[1].splitlines()]
        self.assertEqual([(o["id"], o["labels"]) for o in objects], [("B17", ["audio"]), ("FR01", [])])

    def test_show_prints_the_file_and_the_sections_that_cite_it(self) -> None:
        status, out, _err = self.run_cli("show", "FR01")
        self.assertEqual(status, 0)
        self.assertTrue(out.startswith("Issues/FR01.md\n---\nid: FR01\n"))
        self.assertTrue(out.endswith("\n## Comments\n\nNo doc section cites FR01.\n"))

    def test_show_and_close_name_the_doc_sections_that_cite_the_issue(self) -> None:
        self.write_tree({"docs/user/wishes.md": "# Wishes\n<!-- id: wishes -->\n\n## Not yet\n"
                                                "<!-- id: wishes-not-yet; status: planned; issues: B17, FR01 -->\n\nA wish.\n"})
        out = self.run_cli("show", "FR01")[1]
        self.assertTrue(out.endswith("Doc sections that cite FR01: 1\n"
                                     "docs/user/wishes.md:4-7  Not yet  wishes-not-yet, status planned\n"), out)
        data = json.loads(self.run_cli("show", "FR01", "--json")[1])
        self.assertEqual(data["cited_by"], [{"path": "docs/user/wishes.md", "start": 4, "end": 7, "heading": "Not yet",
                                             "id": "wishes-not-yet", "status": "planned"}])
        out = self.run_cli("close", "FR01", "--reason", "the user withdrew it", "--status", "wontfix", "--as", "orchestrator")[1]
        self.assertEqual(out.splitlines()[1], "issuelib: docs/user/wishes.md:4 (wishes-not-yet, status planned) cites FR01: "
                                              "the next docs pass updates that section (doclib check lists it)")

    def test_show_finds_an_id_or_an_alias_that_only_the_todo_has(self) -> None:
        out = self.run_cli("show", "B12")[1]
        self.assertTrue(out.startswith("B12 has no file in Issues/; TODO-2026-09-04.md names it:\n"))
        self.assertEqual(len(out.splitlines()), 4)
        out = self.run_cli("show", "B12-OCT")[1]
        self.assertEqual(out.splitlines()[0], "B12-OCT is an alias of B12, given in TODO-2026-09-04.md:")
        self.assertIn(":12: - [x] **B12 (alias B12-OCT)", out)
        self.assertEqual(self.run_cli("show", "XYZ9")[0], 2)
        # A name that is no ID never becomes a path, so it cannot lead out of Issues/.
        status, _out, err = self.run_cli("show", "../B16")
        self.assertEqual((status, err), (2, "issuelib: '../B16' is not an ID: capitals, digits, and hyphens, with a digit or a hyphen\n"))

    def test_search_prints_each_matching_line_with_its_id(self) -> None:
        status, out, _err = self.run_cli("search", "urgent")
        self.assertEqual((status, out), (0, "B17:3: title: Urgent bug\n"))
        self.assertEqual(self.run_cli("search", "fixed by hand", "--status", "open")[0], 1)
        self.assertEqual(self.run_cli("search", "(")[0], 2)

    def test_summary_counts_each_status_by_priority(self) -> None:
        status, out, _err = self.run_cli("summary")
        self.assertEqual(out, "3 issues: 2 not closed (P1 1, P3 1), 1 closed.\n"
                              "in-progress 1: P1 1\nopen 1: P3 1\ndone 1: P2 1\n")


class CheckTests(IssueCase):
    """check: every file's layout and values, its references, and the TODO's IDs."""

    def test_a_sound_folder_passes(self) -> None:
        self.write_tree({"TODO-2026-09-04.md": TODO, "Issues/B16.md": B16, "Issues/README.md": "# Issues\n"})
        status, out, err = self.run_cli("check")
        self.assertEqual((status, out, err), (0, "", "issuelib check: 1 issue file, no problems\n"))

    def test_a_pointers_box_must_agree_with_its_issue_and_no_open_item_is_left_in_the_todo(self) -> None:
        done = B16.replace("id: B16", "id: B17").replace("status: open", "status: done").replace("merged:", "merged: abc1234")
        todo = TODO + ("- [x] **B16** moved to Issues/B16.md\n- [ ] **B17** moved to Issues/B17.md\n"
                       "- [ ] **B18 — added by hand.**\n- [ ] A row with no ID.\n")
        self.write_tree({"TODO-2026-09-04.md": todo, "Issues/B16.md": B16, "Issues/B17.md": done})
        out = self.run_cli("check")[1]
        self.assertEqual(out.splitlines(), [
            "TODO-2026-09-04.md:13: B16's pointer is ticked, but B16 is open (issuelib close and reopen tick and untick it)",
            "TODO-2026-09-04.md:14: B17's pointer is not ticked, but B17 is done (issuelib close and reopen tick and untick it)",
            "TODO-2026-09-04.md:15: an open item left in TODO-2026-09-04.md: open work is an issue (issuelib new on main, or import-todo)",
            "TODO-2026-09-04.md:16: an open item left in TODO-2026-09-04.md: open work is an issue (issuelib new on main, or import-todo)",
        ])

    def test_each_kind_of_problem_is_reported(self) -> None:
        todo = TODO + "- [ ] **B16 — the same ID again.**\n- [ ] **B17** moved to Issues/B17.md\n" \
                      "- [x] **B13 — once.**\n- [x] **B13 — twice.**\n"
        self.write_tree({
            "TODO-2026-09-04.md": todo,
            "Issues/B16.md": B16.replace("related: B12", "related: B12, B99").replace("docs:", "docs: no-such-section"),
            "Issues/B18.md": B16.replace("id: B16", "id: B19"),
            "Issues/notes.md": B16.replace("id: B16", "id: B20"),
            "Issues/B12-OCT.md": B16.replace("id: B16", "id: B12-OCT"),
        })
        status, out, err = self.run_cli("check")
        self.assertEqual(status, 1)
        expected = [
            "Issues/B12-OCT.md: B12-OCT is also an alias of B12 in TODO-2026-09-04.md",
            "Issues/B16.md:15: related B99 names no issue file, TODO item, or alias",
            "Issues/B16.md:16: docs no-such-section names no doc section",
            "Issues/B16.md: B16 also opens an item of TODO-2026-09-04.md (line 13)",
            "Issues/B18.md:2: id B19 differs from the file's name, B18",
            "Issues/notes.md: notes.md is not named for an ID",
            "TODO-2026-09-04.md:14: B17 moved to Issues/B17.md, which does not exist",
            "TODO-2026-09-04.md:15: B13 opens 2 items (lines 15 and 16)",
        ]
        for message in expected:
            self.assertTrue(any(line.startswith(message) for line in out.splitlines()), f"{message}\n---\n{out}")
        self.assertIn("problems in", err)


class ArgumentOrderTests(IssueCase):
    """TL04: options and positionals come in any order, for every command with an optional positional."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"TODO-2026-09-04.md": TODO, "Issues/B16.md": B16})

    def test_comment_takes_its_text_before_or_after_as(self) -> None:
        # The order that always worked, the one TL04 found failing, and the text last of all.
        orders = {
            "text first": ("comment", "B16", "Text one.", "--as", "floatrender"),
            "as first": ("comment", "B16", "--as", "floatrender", "Text two."),
            "json between": ("comment", "B16", "--json", "Text three.", "--as", "floatrender"),
        }
        for name, argv in orders.items():
            with self.subTest(name):
                status, _out, err = self.run_cli(*argv)
                self.assertEqual(status, 0, err)
        text = self.read("Issues/B16.md")
        for wanted in ("Text one.", "Text two.", "Text three."):
            self.assertIn(f"\n{wanted}\n", text)

    def test_the_same_comment_is_written_whatever_the_order(self) -> None:
        results = []
        for argv in (("comment", "B16", "Same text.", "--as", "floatrender"),
                     ("comment", "B16", "--as", "floatrender", "Same text.")):
            self.write_tree({"Issues/B16.md": B16})
            self.assertEqual(self.run_cli(*argv)[0], 0)
            results.append(self.read("Issues/B16.md"))
        self.assertEqual(results[0], results[1])

    def test_a_comment_with_no_text_is_still_refused_in_both_orders(self) -> None:
        for argv in (("comment", "B16", "--as", "floatrender"), ("comment", "--as", "floatrender", "B16")):
            self.assertEqual(self.run_cli(*argv)[0], 2, argv)
        self.assertEqual(self.read("Issues/B16.md"), B16)

    def test_set_takes_its_value_words_on_either_side_of_as(self) -> None:
        for argv in (("set", "B16", "title", "Speak", "Info", "--as", "orchestrator"),
                     ("set", "B16", "title", "--as", "orchestrator", "Speak", "Info"),
                     ("set", "B16", "title", "Speak", "--as", "orchestrator", "Info")):
            with self.subTest(argv):
                self.write_tree({"Issues/B16.md": B16})
                status, _out, err = self.run_cli(*argv)
                self.assertEqual(status, 0, err)
                self.assertIn("title: Speak Info\n", self.read("Issues/B16.md"))

    def test_set_with_no_value_still_clears_in_both_orders(self) -> None:
        for argv in (("set", "B16", "labels", "--as", "orchestrator"), ("set", "--as", "orchestrator", "B16", "labels")):
            self.assertEqual(self.run_cli(*argv)[0], 0)
            self.assertIn("labels:\n", self.read("Issues/B16.md"))

    def test_commands_with_only_required_positionals_take_options_anywhere(self) -> None:
        self.assertEqual(self.run_cli("show", "--json", "B16")[0], 0)
        self.assertEqual(self.run_cli("show", "B16", "--json")[0], 0)
        self.assertEqual(self.run_cli("search", "--status", "all", "Description")[0], 0)
        self.assertEqual(self.run_cli("assign", "--as", "orchestrator", "B16", "floatrender")[0], 0)
        self.assertEqual(self.run_cli("assign", "B16", "none", "--as", "orchestrator")[0], 0)
        self.assertEqual(self.run_cli("close", "--as", "orchestrator", "B16", "--merged", "6b09b2ee2")[0], 0)
        self.assertEqual(self.run_cli("reopen", "B16", "--as", "orchestrator", "--reason", "Again.")[0], 0)

    def test_the_merge_driver_keeps_its_optional_size_and_path(self) -> None:
        import issuelib
        parsed = issuelib.build_parser().parse_args(["merge-driver", "base", "cur", "other", "9", "a/B1.md"])
        self.assertEqual((parsed.base, parsed.current, parsed.other, parsed.marker_size, parsed.path), ("base", "cur", "other", 9, "a/B1.md"))
        short = issuelib.build_parser().parse_args(["merge-driver", "base", "cur", "other"])
        self.assertEqual((short.marker_size, short.path), (issuelib.issuemerge.MARKER_SIZE, ""))

    def run_dashed(self, *argv: str):
        """Run the command ``argv[0]`` with --root given right after its name: run_cli appends it otherwise, and after a
        ``--`` it would be read as a positional."""
        return self.run_cli(argv[0], "--root", str(self.root), *argv[1:])

    def test_a_double_dash_ends_the_options_even_before_the_first_positional(self) -> None:
        # Python before 3.12.8 lost such a "--" in the intermixed parse: the words after it were read as options, so
        # `set` wrote an emptied labels field and `search -- -x` and `comment --as N -- ID -x` were refused.
        status, _out, err = self.run_dashed("set", "--as", "orchestrator", "--", "B16", "labels", "--json")
        self.assertEqual(status, 1, err)
        self.assertIn("--json", err)
        self.assertEqual(self.read("Issues/B16.md"), B16, "a refused value must write nothing")
        self.assertEqual(self.run_dashed("search", "--", "-x")[0], 1, "no match is status 1, not a usage error")
        self.assertEqual(self.run_dashed("search", "--status", "all", "--", "-x")[0], 1)
        status, _out, err = self.run_dashed("comment", "--as", "floatrender", "--", "B16", "-x")
        self.assertEqual(status, 0, err)
        self.assertTrue(self.read("Issues/B16.md").endswith("\n-x\n"))
        status, _out, err = self.run_dashed("set", "--as", "orchestrator", "--", "B16", "title", "-x", "y")
        self.assertEqual(status, 0, err)
        self.assertIn("title: -x y\n", self.read("Issues/B16.md"))

    def test_dash_leading_text_after_the_id_still_works(self) -> None:
        for text in ("- item", "-5", "-", "--dash"):
            with self.subTest(text):
                self.write_tree({"Issues/B16.md": B16})
                status, _out, err = self.run_dashed("comment", "B16", "--as", "floatrender", "--", text)
                self.assertEqual(status, 0, err)
                self.assertTrue(self.read("Issues/B16.md").endswith(f"\n{text}\n"))

    def test_a_stray_argument_is_still_an_error(self) -> None:
        status, _out, err = self.run_cli("comment", "B16", "one", "two", "--as", "floatrender")
        self.assertEqual(status, 2)
        self.assertIn("unrecognized arguments: two", err)


if __name__ == "__main__":
    import unittest
    unittest.main()
