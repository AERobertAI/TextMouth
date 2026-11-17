"""Tests of docmodel.py: blocks, markers, sections, pages, and the scopes' page lists.

Every test builds its own small page; none reads the real docs.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from typing import List, Tuple
from unittest import mock

from doclib_case import DocLibCase

import docmodel
from docmodel import Block, Page, parse, parse_marker
from output import UsageError


def kinds(page: Page) -> List[Tuple[str, int, int]]:
    """The page's blocks as ``(kind, start, end)`` triples, for compact comparisons."""
    return [(block.kind, block.start, block.end) for block in page.blocks]


def lines_of(*lines: str) -> str:
    """A page's text from its lines, with a final line end."""
    return "\n".join(lines) + "\n"


class HeadingAndTextBlockTests(unittest.TestCase):
    """Headings, paragraphs, rules, quotes, and tables."""

    def test_heading_shapes_precisely(self) -> None:
        page = parse("p.md", lines_of("# One #", "## Two ##  ", "###### Six"))
        self.assertEqual([(b.level, b.title) for b in page.blocks], [(1, "One"), (2, "Two"), (6, "Six")])
        page = parse("p.md", lines_of("####### seven", "#nospace", "    # indented"))
        self.assertEqual([b.kind for b in page.blocks], ["paragraph"])
        page = parse("p.md", lines_of("#", "# C#"))
        self.assertEqual([(b.level, b.title) for b in page.blocks], [(1, ""), (1, "C#")])

    def test_heading_interrupts_a_paragraph_and_a_paragraph_runs_over_lines(self) -> None:
        page = parse("p.md", lines_of("one", "two", "# H", "three", "", "four"))
        self.assertEqual(kinds(page), [("paragraph", 1, 2), ("heading", 3, 3),
                                       ("paragraph", 4, 4), ("paragraph", 6, 6)])

    def test_thematic_break_is_a_rule_before_a_list_item(self) -> None:
        page = parse("p.md", lines_of("text", "", "---", "* * *", "- - -", "___", "-"))
        self.assertEqual([b.kind for b in page.blocks],
                         ["paragraph", "rule", "rule", "rule", "rule", "list-item"])

    def test_tables_and_quotes_are_runs_of_lines(self) -> None:
        page = parse("p.md", lines_of("| a |", "| - |", "| b |", "after", "", "> q1", "> q2", "lazy", "", "  > q3"))
        self.assertEqual(kinds(page), [("table", 1, 3), ("paragraph", 4, 4), ("quote", 6, 8), ("quote", 10, 10)])

    def test_text_continuing_a_table_starts_a_paragraph(self) -> None:
        page = parse("p.md", lines_of("| a |", "plain"))
        self.assertEqual(kinds(page), [("table", 1, 1), ("paragraph", 2, 2)])


class CodeAndCommentTests(unittest.TestCase):
    """Fences, indented code, HTML comments, and front matter."""

    def test_hash_inside_a_fence_is_not_a_heading(self) -> None:
        page = parse("p.md", lines_of("# A", "```sh", "# comment", "## also", "```", "## B"))
        self.assertEqual(kinds(page), [("heading", 1, 1), ("code", 2, 5), ("heading", 6, 6)])
        self.assertEqual([s.title for s in page.sections], ["A", "B"])

    def test_fence_closes_only_on_a_fence_at_least_as_long_of_the_same_character(self) -> None:
        page = parse("p.md", lines_of("````", "```", "~~~~", "````", "after"))
        self.assertEqual(kinds(page), [("code", 1, 4), ("paragraph", 5, 5)])
        page = parse("p.md", lines_of("~~~", "```", "~~~~", "x"))
        self.assertEqual(kinds(page), [("code", 1, 3), ("paragraph", 4, 4)])

    def test_an_unclosed_fence_runs_to_the_last_line(self) -> None:
        page = parse("p.md", lines_of("# A", "```", "# not a heading", "", "text"))
        self.assertEqual(kinds(page), [("heading", 1, 1), ("code", 2, 5)])
        self.assertEqual(len(page.sections), 1)

    def test_inline_code_at_the_start_of_a_line_is_not_a_fence(self) -> None:
        page = parse("p.md", lines_of("```inline``` text"))
        self.assertEqual(kinds(page), [("paragraph", 1, 1)])

    def test_indented_code_after_a_blank_line_and_its_extent(self) -> None:
        page = parse("p.md", lines_of("text", "", "    code 1", "", "    code 2", "", "after"))
        self.assertEqual(kinds(page), [("paragraph", 1, 1), ("code", 3, 5), ("paragraph", 7, 7)])

    def test_indented_code_at_the_page_start_and_with_a_tab(self) -> None:
        page = parse("p.md", "\tcode\n    more\nend\n")
        self.assertEqual(kinds(page), [("code", 1, 2), ("paragraph", 3, 3)])

    def test_indented_line_straight_after_a_paragraph_is_not_code(self) -> None:
        page = parse("p.md", lines_of("text", "    still text"))
        self.assertEqual(kinds(page), [("paragraph", 1, 2)])

    def test_writing_docs_example_an_indented_marker_is_code_not_a_marker(self) -> None:
        text = lines_of(
            "## Section markers", "", "Each section starts with one marker line:", "",
            "    <!-- id: epub-headings; keys: EPUB; src: a.swift -->", "", "- `id`: unique")
        page = parse("p.md", text)
        self.assertEqual([b.kind for b in page.blocks], ["heading", "paragraph", "code", "list-item"])
        self.assertIsNone(page.sections[0].marker)
        self.assertEqual(page.sections[0].stray_markers, [])

    def test_html_comments_one_line_and_many(self) -> None:
        page = parse("p.md", lines_of("<!-- page: 12 -->", "  <!-- a", "b # not a heading", "c -->", "text"))
        self.assertEqual(kinds(page), [("html", 1, 1), ("html", 2, 4), ("paragraph", 5, 5)])

    def test_a_comment_inside_a_sentence_is_not_a_block(self) -> None:
        page = parse("p.md", lines_of("See the page <!-- page: 12 --> for more."))
        self.assertEqual(kinds(page), [("paragraph", 1, 1)])

    def test_a_comment_with_text_after_it_is_html_not_a_marker(self) -> None:
        page = parse("p.md", lines_of("<!-- id: a-b --> trailing"))
        self.assertEqual([b.kind for b in page.blocks], ["html"])

    def test_front_matter_holds_no_headings(self) -> None:
        page = parse("p.md", lines_of("---", "title: x", "# not a heading", "...", "# Real"))
        self.assertEqual(kinds(page), [("front-matter", 1, 4), ("heading", 5, 5)])
        self.assertEqual(len(page.sections), 1)

    def test_a_lone_leading_rule_is_not_front_matter(self) -> None:
        page = parse("p.md", lines_of("---", "text"))
        self.assertEqual(kinds(page), [("rule", 1, 1), ("paragraph", 2, 2)])

    def test_crlf_and_final_line_end(self) -> None:
        page = parse("p.md", "# A\r\n\r\ntext\r\n")
        self.assertEqual(page.lines, ["# A", "", "text"])
        self.assertEqual(kinds(page), [("heading", 1, 1), ("paragraph", 3, 3)])
        self.assertEqual(parse("p.md", "").lines, [])
        self.assertEqual(parse("p.md", "a").lines, ["a"])
        self.assertEqual(parse("p.md", "a\n\n").lines, ["a", ""])


class ListTests(unittest.TestCase):
    """List items, their continuation lines and paragraphs, nesting, and code inside items."""

    def test_item_content_column_and_marker_column(self) -> None:
        page = parse("p.md", lines_of("- a", "1. b", "  * c", "-   d", "-     e", "-"))
        self.assertEqual([(b.indent, b.content_col) for b in page.blocks],
                         [(0, 2), (0, 3), (2, 4), (0, 4), (0, 2), (0, 2)])

    def test_a_following_line_continues_the_item_at_any_indentation(self) -> None:
        page = parse("p.md", lines_of("- one", "two", "        three", "- next"))
        self.assertEqual(kinds(page), [("list-item", 1, 3), ("list-item", 4, 4)])

    def test_indented_paragraph_after_a_blank_line_is_a_list_para(self) -> None:
        page = parse("p.md", lines_of("- item", "", "  more of it", "", "outside"))
        self.assertEqual(kinds(page), [("list-item", 1, 1), ("list-para", 3, 3), ("paragraph", 5, 5)])
        self.assertEqual(page.blocks[1].indent, 2)

    def test_four_more_spaces_make_code_inside_the_item(self) -> None:
        page = parse("p.md", lines_of("- item", "", "      code", "", "  para"))
        self.assertEqual(kinds(page), [("list-item", 1, 1), ("code", 3, 3), ("list-para", 5, 5)])

    def test_nested_items_and_returning_to_the_outer_list(self) -> None:
        page = parse("p.md", lines_of("- a", "  - b", "    - c", "  - d", "- e", "", "    para"))
        self.assertEqual([(b.kind, b.indent) for b in page.blocks],
                         [("list-item", 0), ("list-item", 2), ("list-item", 4), ("list-item", 2),
                          ("list-item", 0), ("list-para", 2)])

    def test_a_list_para_belongs_to_the_deepest_item_it_is_indented_into(self) -> None:
        page = parse("p.md", lines_of("- a", "  - b", "", "    under b", "", "  under a"))
        paras = [b for b in page.blocks if b.kind == "list-para"]
        self.assertEqual([(b.start, b.indent) for b in paras], [(4, 4), (6, 2)])

    def test_a_blank_line_does_not_end_the_list_but_a_less_indented_line_does(self) -> None:
        page = parse("p.md", lines_of("- a", "", "- b", "", "text", "", "    code"))
        self.assertEqual([b.kind for b in page.blocks],
                         ["list-item", "list-item", "paragraph", "code"])

    def test_a_heading_ends_the_list(self) -> None:
        page = parse("p.md", lines_of("- a", "# H", "", "    code"))
        self.assertEqual([b.kind for b in page.blocks], ["list-item", "heading", "code"])

    def test_a_fence_inside_an_item_and_text_after_it(self) -> None:
        page = parse("p.md", lines_of("- a", "  ```", "  x", "  ```", "  after", "outside"))
        self.assertEqual([(b.kind, b.start, b.end) for b in page.blocks],
                         [("list-item", 1, 1), ("code", 2, 4), ("list-para", 5, 6)])

    def test_a_fence_at_column_zero_ends_the_list(self) -> None:
        page = parse("p.md", lines_of("- a", "```", "x", "```", "", "    code"))
        self.assertEqual([b.kind for b in page.blocks], ["list-item", "code", "code"])


class MarkerTests(unittest.TestCase):
    """parse_marker and where markers sit in sections."""

    def test_a_full_marker_is_parsed(self) -> None:
        marker = parse_marker(7, "<!-- id: epub-headings; keys: EPUB, nav document, NCX; src: A.swift, b/C.swift -->")
        assert marker is not None
        self.assertEqual((marker.line, marker.id), (7, "epub-headings"))
        self.assertEqual(marker.keys, ["EPUB", "nav document", "NCX"])
        self.assertEqual(marker.src, ["A.swift", "b/C.swift"])
        self.assertEqual(marker.errors, [])

    def test_empty_lists_and_missing_fields_are_fine(self) -> None:
        marker = parse_marker(1, "<!-- id: a; keys: ; src: ,, -->")
        assert marker is not None
        self.assertEqual((marker.keys, marker.src, marker.errors), ([], [], []))
        marker = parse_marker(1, "<!--id:a-->")
        assert marker is not None
        self.assertEqual(marker.id, "a")

    def test_not_markers(self) -> None:
        for text in ("<!-- page: 12 -->", "text <!-- id: a -->", "<!-- id: a --> x", "not a comment",
                     "<!-- id: a --> <!-- id: b -->", "<!-- keys: a -->", "<!-- id: a"):
            self.assertIsNone(parse_marker(1, text), text)

    def test_errors_name_each_problem(self) -> None:
        marker = parse_marker(1, "<!-- id: Bad_Id; keys: a; keys: b; color: red; oops -->")
        assert marker is not None
        self.assertEqual(len(marker.errors), 4, marker.errors)
        self.assertTrue(any("not lowercase" in e for e in marker.errors))
        self.assertTrue(any("twice" in e and "keys" in e for e in marker.errors))
        self.assertTrue(any("unknown field" in e and "color" in e for e in marker.errors))
        self.assertTrue(any("without a colon" in e and "oops" in e for e in marker.errors))
        self.assertEqual(marker.keys, ["a"])  # the first of a repeated field wins

    def test_a_status_and_the_issues_that_track_it(self) -> None:
        marker = parse_marker(3, "<!-- id: search-limits; keys: a; status: incomplete; issues: DR01, DR02 -->")
        assert marker is not None
        self.assertEqual((marker.status, marker.issues, marker.errors), ("incomplete", ["DR01", "DR02"], []))
        marker = parse_marker(3, "<!-- id: later; status: planned; issues: FR22 -->")
        assert marker is not None
        self.assertEqual((marker.status, marker.issues, marker.errors), ("planned", ["FR22"], []))
        # A marker without them has neither.
        marker = parse_marker(3, "<!-- id: plain -->")
        assert marker is not None
        self.assertEqual((marker.status, marker.issues), (None, []))

    def test_a_status_must_be_incomplete_or_planned(self) -> None:
        for value in ("done", "Incomplete", ""):
            marker = parse_marker(1, f"<!-- id: a; status: {value}; issues: B16 -->")
            assert marker is not None
            self.assertIsNone(marker.status, value)
            self.assertEqual(marker.errors, [f"status not incomplete or planned: {value!r}"], value)

    def test_an_empty_id_is_no_id(self) -> None:
        marker = parse_marker(1, "<!-- id: ; keys: a -->")
        assert marker is not None
        self.assertIsNone(marker.id)
        self.assertEqual(marker.errors, ["no id"])

    def test_id_shape(self) -> None:
        for good in ("a", "a-b", "x1-2y"):
            self.assertTrue(docmodel.ID_SHAPE.match(good), good)
        for bad in ("A", "a--b", "-a", "a-", "a b", "a_b", ""):
            self.assertFalse(docmodel.ID_SHAPE.match(bad), bad)

    def test_marker_straight_under_the_heading_and_after_a_blank_line(self) -> None:
        for between in ([], [""]):
            page = parse("p.md", lines_of("# T", *between, "<!-- id: t -->", "text"))
            section = page.sections[0]
            assert section.marker is not None
            self.assertEqual(section.marker.id, "t")
            self.assertEqual(section.stray_markers, [])

    def test_a_marker_after_text_is_stray_and_a_second_marker_too(self) -> None:
        page = parse("p.md", lines_of("# T", "text", "<!-- id: a -->", "", "<!-- id: b -->"))
        section = page.sections[0]
        self.assertIsNone(section.marker)
        self.assertEqual([m.id for m in section.stray_markers], ["a", "b"])
        page = parse("p.md", lines_of("# T", "<!-- id: a -->", "<!-- id: b -->"))
        section = page.sections[0]
        assert section.marker is not None
        self.assertEqual((section.marker.id, [m.id for m in section.stray_markers]), ("a", ["b"]))

    def test_a_marker_inside_a_fence_is_not_a_marker(self) -> None:
        page = parse("p.md", lines_of("# T", "```", "<!-- id: a -->", "```"))
        self.assertIsNone(page.sections[0].marker)
        self.assertEqual(page.sections[0].stray_markers, [])


class SectionTests(unittest.TestCase):
    """Section ranges, heading paths, and Page lookups."""

    def test_end_is_the_last_non_blank_line_and_span_end_reaches_the_next_heading(self) -> None:
        page = parse("p.md", lines_of("# A", "", "text", "", "", "## B", "more", "", ""))
        first, second = page.sections
        self.assertEqual((first.start, first.end, first.span_end), (1, 3, 5))
        self.assertEqual((second.start, second.end, second.span_end), (6, 7, 9))

    def test_a_section_with_no_body_ends_at_its_heading(self) -> None:
        page = parse("p.md", lines_of("# A", "", "# B"))
        self.assertEqual((page.sections[0].start, page.sections[0].end, page.sections[0].span_end), (1, 1, 2))

    def test_a_trailing_unclosed_fence_with_blank_lines_ends_at_its_last_text(self) -> None:
        page = parse("p.md", lines_of("# A", "```", "x", "", ""))
        self.assertEqual((page.sections[0].end, page.sections[0].span_end), (3, 5))

    def test_paths_and_headings_with_one_top_heading(self) -> None:
        page = parse("p.md", lines_of("# Top", "## A", "### A1", "## B", "### B1"))
        self.assertEqual([s.path for s in page.sections],
                         [("Top",), ("Top", "A"), ("Top", "A", "A1"), ("Top", "B"), ("Top", "B", "B1")])
        self.assertEqual([s.heading for s in page.sections], ["Top", "A", "A > A1", "B", "B > B1"])

    def test_headings_keep_the_top_heading_when_there_are_two(self) -> None:
        page = parse("p.md", lines_of("# One", "## A", "# Two", "## A"))
        self.assertEqual([s.heading for s in page.sections], ["One", "One > A", "Two", "Two > A"])

    def test_headings_when_the_page_starts_below_level_one(self) -> None:
        page = parse("p.md", lines_of("## A", "### B", "## C"))
        self.assertEqual([s.heading for s in page.sections], ["A", "A > B", "C"])

    def test_text_before_the_first_heading_is_a_level_zero_section(self) -> None:
        page = parse("p.md", lines_of("intro", "", "# T", "body"))
        zero = page.sections[0]
        self.assertEqual((zero.level, zero.title, zero.path, zero.heading), (0, "", (), ""))
        self.assertEqual((zero.start, zero.end, zero.span_end), (1, 1, 2))
        self.assertEqual([s.index for s in page.sections], [0, 1])
        self.assertEqual(page.sections[1].heading, "T")

    def test_front_matter_alone_makes_no_level_zero_section(self) -> None:
        page = parse("p.md", lines_of("---", "a: b", "---", "", "# T"))
        self.assertEqual([s.level for s in page.sections], [1])

    def test_an_empty_page_has_no_sections(self) -> None:
        page = parse("p.md", "")
        self.assertEqual(page.sections, [])
        with self.assertRaises(LookupError):
            page.section_at(1)

    def test_section_at_a_blank_line_between_sections_and_at_the_edges(self) -> None:
        page = parse("p.md", lines_of("# A", "x", "", "# B", "y"))
        self.assertEqual(page.section_at(1).title, "A")
        self.assertEqual(page.section_at(3).title, "A")  # the blank line before B
        self.assertEqual(page.section_at(4).title, "B")
        self.assertEqual(page.section_at(5).title, "B")
        self.assertEqual(page.section_at(99).title, "B")

    def test_section_at_before_the_first_heading_after_front_matter(self) -> None:
        page = parse("p.md", lines_of("---", "a: b", "---", "# T"))
        self.assertEqual(page.section_at(2).title, "T")

    def test_text_returns_the_lines_inclusive(self) -> None:
        page = parse("p.md", lines_of("a", "b", "c"))
        self.assertEqual(page.text(2, 3), "b\nc")

    def test_size_is_the_utf8_byte_count(self) -> None:
        self.assertEqual(parse("p.md", "é\n").size, 3)

    def test_the_marker_and_blocks_of_a_section_exclude_its_heading(self) -> None:
        page = parse("p.md", lines_of("# T", "<!-- id: t -->", "text", "## U", "more"))
        self.assertEqual([b.kind for b in page.sections[0].blocks], ["marker", "paragraph"])
        self.assertEqual([b.kind for b in page.sections[1].blocks], ["paragraph"])

    def test_prose_blocks_skip_code_markers_rules_html_and_front_matter(self) -> None:
        page = parse("p.md", lines_of(
            "# T", "<!-- id: t -->", "para one", "line two", "```", "code", "```", "---", "<!-- c -->",
            "- item", "", "  more", "> quote", "| a |"))
        pairs = docmodel.prose_blocks(page, page.sections[0])
        self.assertEqual(pairs, [(1, "# T"), (3, "para one\nline two"), (10, "- item"),
                                 (12, "  more"), (13, "> quote"), (14, "| a |")])

    def test_prose_blocks_of_a_level_zero_section_have_no_heading(self) -> None:
        page = parse("p.md", lines_of("intro", "# T"))
        self.assertEqual(docmodel.prose_blocks(page, page.sections[0]), [(1, "intro")])


class ScopeAndLoadTests(DocLibCase):
    """scope_pages, lint_pages, load_page, and load_pages on small trees."""

    def tree(self) -> None:
        """A tree with both scopes' kinds of files, and some that no scope names."""
        self.write_tree({
            "README.md": "# R\n", "ARCHITECTURE.md": "# A\n", "AGENTS.md": "# G\n", "CLAUDE.md": "# C\n",
            "docs/user/b.md": "# b\n", "docs/user/a.md": "# a\n", "docs/z.md": "# z\n",
            "docs/user/notes.txt": "not markdown", "docs/deep/er/x.md": "# x\n",
            "TODO-2026.md": "# t\n", "AGENT-NOTES-2026.md": "# n\n", "OTHER.md": "# o\n",
            "research/one.md": "# 1\n", "Scripts/agents/briefs/2026-11-14/t/m.md": "# m\n",
            "humanQuestions/q.md": "# q\n",
        })

    def test_docs_scope_in_entry_order_with_each_entrys_matches_sorted(self) -> None:
        self.tree()
        self.assertEqual(docmodel.scope_pages(self.root, "docs"), [
            "README.md", "ARCHITECTURE.md", "docs/deep/er/x.md", "docs/user/a.md", "docs/user/b.md", "docs/z.md"])

    def test_memory_scope_in_entry_order(self) -> None:
        self.tree()
        self.assertEqual(docmodel.scope_pages(self.root, "memory"), [
            "AGENTS.md", "CLAUDE.md", "TODO-2026.md", "AGENT-NOTES-2026.md", "research/one.md",
            "Scripts/agents/briefs/2026-11-14/t/m.md", "humanQuestions/q.md"])

    def test_all_is_docs_then_memory_without_repeats(self) -> None:
        self.tree()
        everything = docmodel.scope_pages(self.root, "all")
        self.assertEqual(everything, docmodel.scope_pages(self.root, "docs") + docmodel.scope_pages(self.root, "memory"))
        self.assertEqual(len(everything), len(set(everything)))

    def test_missing_entries_are_skipped(self) -> None:
        # A worktree has no humanQuestions/, and may lack most of the rest too.
        self.write_tree({"AGENTS.md": "# G\n", "docs/a.md": "# a\n"})
        self.assertEqual(docmodel.scope_pages(self.root, "memory"), ["AGENTS.md"])
        self.assertEqual(docmodel.scope_pages(self.root, "docs"), ["docs/a.md"])
        self.assertEqual(docmodel.scope_pages(self.root / "nowhere", "all"), [])

    def test_an_unknown_scope_is_a_usage_error(self) -> None:
        with self.assertRaises(UsageError):
            docmodel.scope_pages(self.root, "everything")

    def test_symlinks_out_of_the_root_are_left_out(self) -> None:
        self.tree()
        # A second temporary folder, outside the root, that the links point into.
        other = tempfile.TemporaryDirectory(prefix="doclib-outside-")
        self.addCleanup(other.cleanup)
        outside = self.write_tree({"secret.md": "# secret\n", "dir/inside.md": "# in\n"},
                                  root=Path(other.name).resolve())
        os.symlink(outside / "secret.md", self.root / "docs" / "link.md")
        os.symlink(outside / "dir", self.root / "docs" / "linked-dir")
        os.symlink(outside / "secret.md", self.root / "CLAUDE-LINK.md")
        os.symlink(outside / "secret.md", self.root / "TODO-link.md")
        (self.root / "research").rename(self.root / "research-real")
        os.symlink(self.root / "research-real", self.root / "research")
        found = docmodel.scope_pages(self.root, "all")
        for name in ("docs/link.md", "docs/linked-dir/inside.md", "TODO-link.md", "research/one.md"):
            self.assertNotIn(name, found)
        self.assertIn("docs/user/a.md", found)
        # The linked page is not readable through load_page either.
        with self.assertRaises(UsageError):
            docmodel.load_page(self.root, "docs/link.md")

    def test_a_symlinked_file_inside_the_root_is_also_left_out(self) -> None:
        self.write_tree({"docs/real.md": "# r\n"})
        os.symlink(self.root / "docs" / "real.md", self.root / "docs" / "alias.md")
        self.assertEqual(docmodel.scope_pages(self.root, "docs"), ["docs/real.md"])

    def test_lint_pages_are_docs_plus_agents_and_claude(self) -> None:
        self.tree()
        self.assertEqual(docmodel.lint_pages(self.root),
                         docmodel.scope_pages(self.root, "docs") + ["AGENTS.md", "CLAUDE.md"])

    def test_lint_pages_skip_a_missing_extra_page(self) -> None:
        self.write_tree({"README.md": "# R\n", "AGENTS.md": "# G\n"})
        self.assertEqual(docmodel.lint_pages(self.root), ["README.md", "AGENTS.md"])

    def test_load_page_reads_utf8_with_replacement_and_the_byte_size(self) -> None:
        self.write_tree({"docs/a.md": "# é\n"})
        (self.root / "docs" / "bad.md").write_bytes(b"# a\xffb\n")
        page = docmodel.load_page(self.root, "docs/a.md")
        self.assertEqual((page.path, page.sections[0].title, page.size), ("docs/a.md", "é", 5))
        bad = docmodel.load_page(self.root, "docs/bad.md")
        self.assertEqual(bad.sections[0].title, "a�b")
        self.assertEqual(bad.size, 6)

    def test_load_page_refuses_paths_outside_the_root_and_missing_files(self) -> None:
        self.write_tree({"docs/a.md": "# a\n"})
        for path in ("../outside.md", "/etc/hosts", "docs/missing.md", "docs"):
            with self.assertRaises(UsageError, msg=path):
                docmodel.load_page(self.root, path)

    def test_load_pages_keeps_the_order(self) -> None:
        self.write_tree({"docs/a.md": "# a\n", "docs/b.md": "# b\n"})
        pages = docmodel.load_pages(self.root, ["docs/b.md", "docs/a.md"])
        self.assertEqual([p.path for p in pages], ["docs/b.md", "docs/a.md"])

    def test_name_inside_judges_a_name_by_its_spelling(self) -> None:
        inside = str(self.root / "docs" / "a.md")
        cases = {
            "docs/a.md": "docs/a.md",
            inside: "docs/a.md",
            "/Users/nobody/.TextMouth/library.json": None,
            "~/.TextMouth/library.json": None,
            "../outside.md": None,
            "docs/../../outside.md": None,
            "": None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(docmodel.name_inside(self.root, name), expected)

    def test_a_name_outside_the_root_is_refused_before_any_file_system_call(self) -> None:
        # The user's live library must never be looked at, not even by realpath's lstat.
        self.write_tree({"docs/a.md": "# a\n"})
        real_realpath = os.path.realpath

        def guarded(path, *args, **kwargs):
            """os.path.realpath that fails the test when asked about the live library."""
            if ".TextMouth" in os.fspath(path):
                self.fail(f"realpath was asked about {path}")
            return real_realpath(path, *args, **kwargs)

        with mock.patch("os.path.realpath", guarded):
            for name in ("/Users/nobody/.TextMouth/x.md", "~/.TextMouth/x.md"):
                with self.subTest(name=name), self.assertRaises(UsageError):
                    docmodel.load_page(self.root, name)
            status, _, err = self.run_cli("show", "/Users/nobody/.TextMouth/x.md:1")
        self.assertEqual(status, 2, err)


if __name__ == "__main__":
    unittest.main()
