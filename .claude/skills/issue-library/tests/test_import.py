"""Tests of import-todo: every open item of a TODO in the real one's shapes becomes an issue file."""

from __future__ import annotations

from issuelib_case import IssueCase  # first: it puts the scripts folder on sys.path
import issuefile
import issuetodo

# A TODO with each shape the real one has: the audit's items and its matrix of rows
# without IDs, a title broken over two lines, an aside before the dash, sub-bullets
# nested two deep, findings by an agent and by a train, review items that name their
# docs three ways, done items that stay, and an ID given twice with an alias.
TODO = """\
# TextMouth code audit and polish TODO

Audit date: September 4, 2026. Local branch: `audit/2026-09-04-polish`.

## Completed fixes

- [x] **B12 — the float merge.** Merged 6b09b2ee2.

## P — Playback, navigation, and lifecycle

- [ ] **P09 — Validate speech transitions.** P1 · Impact 4 · Difficulty 5 · Manual / Risk. Acceptance: the cursor stays.

- [x] **P10 — Refresh open readers.** P1 · Impact 4 · Difficulty 4 · Confirmed. Done.

## A — Accessibility and interface consistency

- [ ] **A01 — Run the acceptance matrix below.** P1 · Impact 4 · Difficulty 4 · Manual. Workarounds stay.

## Manual acceptance matrix for A01/P09/Q05

These checks have **not** been performed. Record the OS version.

- [ ] VoiceOver and braille: Library to reader and back.
- [ ] Keyboard only: every action is reachable.

## Verification record

- Baseline: **774 XCTest tests**.

## Feature requests (October 3)

- [ ] **FR02 — Keep the data directory in a cloud drive with on-demand
  download.** Requested October 3. Research first; the user answered on October 3: free this Mac's disk first.

## Feature requests and bugs (October 7)

- [ ] **FR16 (low priority) — Pauses between headings.**
  Requested October 13 with FR15: "maybe customizable pauses".
- [x] **FR15 — Pauses in ZIP books.** Merged abc1234.
- [ ] **B14 — A save's temporary file can make a move fail.** Found November 16, 2026 by `review-rulesmove` (finding 7). Fix: leave them out.
- [ ] **A11Y-GOTO — The iPhone Go To sheet's text fields don't follow Dynamic Type.** Found November 15, 2026: train 1115-1800's audit failed.
- [ ] **FU-FORMATS — Smaller leftovers of the November 15 format branches.** `pageimages`: big pictures are refused; the iPhone refuses TTA.
- [ ] **Q-HANG — `SomeTests.testSomething` never finished in one iPhone run.** Train 1115-2347 (November 15, 2026), outside that branch's files.
- [x] **B12 — A 64-bit float book crashes a render.** Found November 15, 2026 by `mp3render`. Merged 6b09b2ee2.

## Pages across formats (researched October 21)

- [x] **PG02 — Pages in EPUB books.** Merged 77e798a0.
- [x] **B12 (alias B12-OCT) — An update replaces edited text.** Merged 77e798a0, October 21.
- [ ] **PG14 — Pages in DAISY audiobooks.** Difficulty M · Impact 2 · After PG02.
  - **What:** page spans become pages.
  - **Files:** `Parsers/DAISYParser+Audio.swift`.

## Before the official 0.2.0 install (planned October 23)

- [ ] **V06 — Escape only what Markdown needs.** Difficulty M · Impact 3 · The first update.
  - **Migration:**
    - edits are kept (B12).

## From the ChatGPT docs review (November 16)

- [ ] **DR01 — Search Library on the iPhone.** From the ChatGPT docs review of November 16, 2026 (suggested priority P1; list items 1 and 2). Docs: `docs/user/search-library.md`, "What Search Library does not do": "there is no Search Library screen." Platform: iPhone (a parity gap; the Mac has it). Related: DR02.
- [ ] **DR02 — Search one folder.** From the ChatGPT docs review of November 16, 2026 (suggested priority P2; list item 3). Docs: as DR01. Platform: Mac, then the iPhone with DR01. Related: DR01.
- [ ] **DR03 — A quoted sentence.** From the ChatGPT docs review of November 16, 2026 (suggested priority P3). Docs: `docs/user/search-library.md`: "… a feed's articles are not searched." Platform: Mac (the iPhone has no search).
"""

# The docs page the review items name.
PAGE = """\
# Search Library
<!-- id: search-library -->

## What is searched
<!-- id: library-search-what-searched -->

A feed's **articles** are not searched, as the lists leave them out.

## What Search Library does not do
<!-- id: library-search-limits -->

On the iPhone, there is no Search Library screen.
"""

# The TODO after the import: one pointer line for each entry, and every other line as it was.
MOVED = """\
# TextMouth code audit and polish TODO

Audit date: September 4, 2026. Local branch: `audit/2026-09-04-polish`.

## Completed fixes

- [x] **B12 — the float merge.** Merged 6b09b2ee2.

## P — Playback, navigation, and lifecycle

- [ ] **P09** moved to Issues/P09.md

- [x] **P10 — Refresh open readers.** P1 · Impact 4 · Difficulty 4 · Confirmed. Done.

## A — Accessibility and interface consistency

- [ ] **A01** moved to Issues/A01.md

## Manual acceptance matrix for A01/P09/Q05

These checks have **not** been performed. Record the OS version.

- [ ] **A01** moved to Issues/A01.md

## Verification record

- Baseline: **774 XCTest tests**.

## Feature requests (October 3)

- [ ] **FR02** moved to Issues/FR02.md

## Feature requests and bugs (October 7)

- [ ] **FR16** moved to Issues/FR16.md
- [x] **FR15 — Pauses in ZIP books.** Merged abc1234.
- [ ] **B14** moved to Issues/B14.md
- [ ] **A11Y-GOTO** moved to Issues/A11Y-GOTO.md
- [ ] **FU-FORMATS** moved to Issues/FU-FORMATS.md
- [ ] **Q-HANG** moved to Issues/Q-HANG.md
- [x] **B12 — A 64-bit float book crashes a render.** Found November 15, 2026 by `mp3render`. Merged 6b09b2ee2.

## Pages across formats (researched October 21)

- [x] **PG02 — Pages in EPUB books.** Merged 77e798a0.
- [x] **B12 (alias B12-OCT) — An update replaces edited text.** Merged 77e798a0, October 21.
- [ ] **PG14** moved to Issues/PG14.md

## Before the official 0.2.0 install (planned October 23)

- [ ] **V06** moved to Issues/V06.md

## From the ChatGPT docs review (November 16)

- [ ] **DR01** moved to Issues/DR01.md
- [ ] **DR02** moved to Issues/DR02.md
- [ ] **DR03** moved to Issues/DR03.md
"""


class ImportCase(IssueCase):
    """A folder with the TODO above and the docs page its review items name."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"TODO-2026-09-04.md": TODO, "docs/user/search-library.md": PAGE, "Issues/README.md": "# Issues\n"})

    def run_import(self, *extra: str):
        """Run import-todo as the agent that moves the items."""
        return self.run_cli("import-todo", "--as", "issuelib", *extra)

    def issue(self, issue_id: str) -> issuefile.Issue:
        """The issue file the import wrote for ``issue_id``, read."""
        return issuefile.parse(f"Issues/{issue_id}.md", self.read(f"Issues/{issue_id}.md"))


class ImportTests(ImportCase):
    """What the import writes."""

    def test_every_open_item_gets_a_file_with_the_facts_its_text_gives(self) -> None:
        status, out, err = self.run_import()
        self.assertEqual(status, 0, err)
        # id: kind, priority, platform, found-by, created, related, docs, labels.
        expected = {
            "P09": ("test", "P1", "mac", "the code audit of 2026-09-04", "2026-09-04", "A01", "", "manual"),
            "A01": ("test", "P1", "mac", "the code audit of 2026-09-04", "2026-09-04", "P09", "", "manual"),
            "FR02": ("feature", "P2", "mac", "the user", "2026-10-03", "", "", ""),
            "FR16": ("feature", "P3", "mac", "the user", "2026-10-13", "FR15", "", ""),
            "B14": ("bug", "P2", "mac", "review-rulesmove", "2026-11-16", "", "", ""),
            "A11Y-GOTO": ("bug", "P2", "iphone", "train 1115-1800", "2026-11-15", "", "", ""),
            "FU-FORMATS": ("follow-up", "P2", "both", "orchestrator", "2026-11-15", "", "", ""),
            "Q-HANG": ("test", "P2", "iphone", "train 1115-2347", "2026-11-15", "", "", ""),
            "PG14": ("feature", "P2", "mac", "the research of 2026-10-21", "2026-10-21", "PG02", "", ""),
            "V06": ("feature", "P2", "mac", "the plan of 2026-10-23", "2026-10-23", "B12-OCT", "", ""),
            "DR01": ("feature", "P1", "iphone", "the ChatGPT docs review", "2026-11-16", "DR02", "library-search-limits", ""),
            "DR02": ("feature", "P2", "mac", "the ChatGPT docs review", "2026-11-16", "DR01", "library-search-limits", ""),
            "DR03": ("feature", "P3", "mac", "the ChatGPT docs review", "2026-11-16", "", "library-search-what-searched", ""),
        }
        names = ("kind", "priority", "platform", "found-by", "created", "related", "docs", "labels")
        wrong = []
        for issue_id, wanted in expected.items():
            issue = self.issue(issue_id)
            got = tuple(issue.value(name) for name in names)
            if got != wanted:
                wrong.append(f"{issue_id}: expected {wanted}, got {got}")
            if issue.problems or issuefile.check_values(issue):
                wrong.append(f"{issue_id}: {issue.problems + issuefile.check_values(issue)}")
            if (issue.value("status"), issue.value("updated"), issue.value("assignee")) != ("open", "2026-11-16", ""):
                wrong.append(f"{issue_id}: status, updated, assignee {issue.value('status')}, {issue.value('updated')}")
        self.assertEqual(wrong, [])
        self.assertEqual(sorted(path.stem for path in (self.root / "Issues").glob("*.md")),
                         sorted(list(expected) + ["README"]))
        self.assertTrue(out.endswith("issuelib: TODO-2026-09-04.md: 14 open entries, 21 lines, made 14 pointer lines; "
                                     "13 issue files\n"), out)

    def test_titles_come_whole_from_the_bold_opening(self) -> None:
        self.run_import()
        self.assertEqual(self.issue("FR02").value("title"), "Keep the data directory in a cloud drive with on-demand download")
        self.assertEqual(self.issue("FR16").value("title"), "Pauses between headings")
        self.assertEqual(self.issue("Q-HANG").value("title"), "`SomeTests.testSomething` never finished in one iPhone run")

    def test_the_description_is_the_items_text_as_it_was(self) -> None:
        self.run_import()
        self.assertEqual(self.issue("FR02").description,
                         "**FR02 — Keep the data directory in a cloud drive with on-demand\n"
                         "download.** Requested October 3. Research first; the user answered on October 3: free this Mac's disk first.")
        self.assertEqual(self.issue("V06").description,
                         "**V06 — Escape only what Markdown needs.** Difficulty M · Impact 3 · The first update.\n"
                         "- **Migration:**\n  - edits are kept (B12).")
        comment = self.issue("PG14").comments[0]
        self.assertEqual((comment.date, comment.author), ("2026-11-16", "issuelib"))
        self.assertEqual(comment.text, "Moved from TODO-2026-09-04.md, lines 50 to 52 of the version this import read, "
                                       "where it was an open item; the description is its text as it was.")

    def test_rows_without_an_id_go_into_the_item_their_section_names(self) -> None:
        self.run_import()
        a01 = self.issue("A01")
        self.assertEqual(a01.description,
                         "**A01 — Run the acceptance matrix below.** P1 · Impact 4 · Difficulty 4 · Manual. Workarounds stay.\n\n"
                         "### Manual acceptance matrix for A01/P09/Q05\n\n"
                         "These checks have **not** been performed. Record the OS version.\n\n"
                         "- [ ] VoiceOver and braille: Library to reader and back.\n"
                         "- [ ] Keyboard only: every action is reachable.")
        self.assertIn("line 17 and lines 23 to 24 of the version", a01.comments[0].text)

    def test_the_todo_keeps_every_line_but_the_moved_ones_and_check_passes(self) -> None:
        self.run_import()
        self.assertEqual(self.read("TODO-2026-09-04.md"), MOVED)
        status, out, err = self.run_cli("check")
        self.assertEqual((status, out), (0, ""), err)

    def test_every_items_words_reach_its_file_in_order(self) -> None:
        entries = issuetodo.find_entries(TODO)
        issuetodo.assign_rows(entries)
        self.run_import()
        for entry in entries:
            wanted = issuetodo.item_text(entry.lines).split()
            held = self.issue(entry.owner).description.split()
            self.assertTrue(issuetodo.holds_in_order(held, wanted), entry.owner)

    def test_a_second_import_finds_nothing_more_to_move(self) -> None:
        self.run_import()
        status, out, _err = self.run_import()
        self.assertEqual(status, 0)
        self.assertIn("0 open entries", out)
        self.assertEqual(self.read("TODO-2026-09-04.md"), MOVED)


class RefusalTests(ImportCase):
    """When the import refuses, it writes nothing at all."""

    def assert_untouched(self) -> None:
        """The TODO is as it was, and Issues/ holds only its README (and a file the test put there)."""
        self.assertEqual(self.read("TODO-2026-09-04.md"), TODO)
        self.assertLessEqual({path.name for path in (self.root / "Issues").iterdir()}, {"README.md", "B14.md"})

    def test_a_dry_run_writes_nothing(self) -> None:
        status, out, _err = self.run_import("--dry-run")
        self.assertEqual(status, 0)
        self.assertIn("(dry run: nothing written)", out)
        self.assertIn("issuelib: Issues/DR01.md: DR01, feature, P1, iphone, found by the ChatGPT docs review on "
                      "2026-11-16; related DR02; docs library-search-limits; TODO line 62", out)
        self.assert_untouched()

    def test_an_issue_file_already_there_stops_it(self) -> None:
        self.write_tree({"Issues/B14.md": "taken"})
        status, _out, err = self.run_import()
        self.assertEqual(status, 1)
        self.assertIn("B14 (line 40) has an issue file already", err)
        self.assert_untouched()

    def test_rows_whose_section_names_no_open_item_stop_it(self) -> None:
        self.write_tree({"TODO-2026-09-04.md": TODO.replace("for A01/P09/Q05", "for later")})
        status, _out, err = self.run_import()
        self.assertEqual(status, 1)
        self.assertIn("the open item on line 23 has no ID", err)

    def test_an_item_with_two_ids_stops_it(self) -> None:
        self.write_tree({"TODO-2026-09-04.md": TODO.replace("**B14 — ", "**B14 and B15 — ")})
        status, _out, err = self.run_import()
        self.assertEqual(status, 1)
        self.assertIn("opens with 2 IDs (B14, B15)", err)


class DocsTests(ImportCase):
    """docs_of: a review item's sections, by title and by every sentence it quotes from the page."""

    def test_every_section_holding_a_quoted_sentence_is_named_with_the_titled_one(self) -> None:
        self.write_tree({"docs/user/export.md": (
            "# Export\n<!-- id: export -->\n\n## Convert to\n<!-- id: export-convert -->\n\n"
            "EPUB: An e-book with the book's headings. It holds no pictures.\n\n"
            "## What every format leaves out\n<!-- id: export-leaves-out -->\n\nA picture becomes its alternative text.\n\n"
            "## Where the files go\n<!-- id: export-where -->\n\nThe Downloads folder.\n")})
        store = issuetodo.issuestore.Store(self.root)
        text = ('Docs: `docs/user/export.md`, "Convert to": "EPUB: An e-book with the book\'s headings... '
                'It holds no pictures." and "a picture becomes its alternative text". Code: none.')
        self.assertEqual(issuetodo.docs_of(text, store, {}), ["export-convert", "export-leaves-out"])
        # The title alone, and a quote alone, each find their section; "as" takes another item's.
        self.assertEqual(issuetodo.docs_of('Docs: `docs/user/export.md`, "Where the files go". Code: x.', store, {}),
                         ["export-where"])
        self.assertEqual(issuetodo.docs_of('Docs: `docs/user/export.md`: "… becomes its alternative text."', store, {}),
                         ["export-leaves-out"])
        self.assertEqual(issuetodo.docs_of("Docs: as DR04. Code: x.", store, {"DR04": {"docs": "export-where"}}),
                         ["export-where"])


class PlatformTests(ImportCase):
    """platform_of: a Platform sentence's first word, then the iPhone named in the title or the text."""

    def test_the_first_word_of_the_platform_sentence_decides(self) -> None:
        cases = {
            "Platform: Mac (the iPhone has no export).": "mac",
            "Platform: Mac (the audio editor is not on the iPhone).": "mac",
            "Platform: iPhone (a parity gap; the Mac reads them).": "iphone",
            "Platform: both (the MOBI reader is shared).": "both",
            "Platform: Mac, then the iPhone with DR01.": "mac",
            "Nothing said; the iPhone refuses it.": "both",
            "Nothing said of either.": "mac",
        }
        for text, expected in cases.items():
            self.assertEqual(issuetodo.platform_of("A title", text), expected, text)
        self.assertEqual(issuetodo.platform_of("The iPhone Go To sheet", "Its fields."), "iphone")


class ExtentTests(ImportCase):
    """Where an item ends: indented lines, a paragraph after a blank line, and lazy continuation lines."""

    def test_an_item_goes_on_over_its_paragraphs_and_stops_at_the_next_block(self) -> None:
        text = ("- [ ] **B30 — one.** First line\n"
                "lazily continued\n"
                "  indented\n"
                "\n"
                "  a second paragraph\n"
                "\n"
                "A paragraph of its own.\n"
                "- [ ] **B31 — two.**\n"
                "## Heading\n")
        entries = issuetodo.find_entries(text)
        self.assertEqual([(entry.owner, entry.start, entry.end) for entry in entries], [("B30", 1, 5), ("B31", 8, 8)])


if __name__ == "__main__":
    import unittest
    unittest.main()
