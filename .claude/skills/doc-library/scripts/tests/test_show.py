"""Tests of the ``show`` command and of how it finds its section (``targets.resolve_target``)."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

import output
import targets

FEEDS = """\
# Feeds

<!-- id: feeds-top; keys: RSS -->
The top.

## Subscribing

<!-- id: feeds-subscribe; keys: Add Feed, subscribe; src: TextMouth/Feeds.swift, gone.swift -->
Text of subscribing.

## Subscribing again

No marker here.

## The `Reader` view

<!-- id: reader-view -->
Reader text.

## Reader settings

Settings text.
"""

# Section line numbers in FEEDS.
TOP, SUBSCRIBING, AGAIN, READER, SETTINGS = 1, 6, 11, 15, 20


class ShowTests(DocLibCase):
    """show: each target form, the first line, numbers, the cap, and JSON."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"docs/user/feeds.md": FEEDS, "docs/architecture/state/feeds.md": "# State\n\ntext\n",
                         "TextMouth/Feeds.swift": "// feeds\n"})

    def show(self, *args: str):
        """Run ``show`` with ``args`` and return (status, standard output lines, standard error)."""
        status, out, err = self.run_cli("show", *args)
        return status, out.splitlines(), err

    def test_a_heading_target_prints_the_hit_line_then_the_section_as_written(self) -> None:
        status, lines, err = self.show("docs/user/feeds.md#Subscribing")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(lines[0], "docs/user/feeds.md:6-9  Subscribing  id: feeds-subscribe")
        self.assertEqual(lines[1:5], FEEDS.splitlines()[5:9])
        # The marker's source paths end the output; one that names no file says so.
        self.assertEqual(lines[5:], ["src: TextMouth/Feeds.swift", "src: gone.swift (missing)"])

    def test_a_line_target_finds_the_section_holding_the_line(self) -> None:
        for line in (6, 7, 9, 10):
            status, lines, _err = self.show(f"docs/user/feeds.md:{line}")
            self.assertEqual(status, 0, line)
            self.assertIn("docs/user/feeds.md:6-9", lines[0])
        # The blank line between sections belongs to the section above.
        self.assertIn(":6-9", self.show("docs/user/feeds.md:10")[1][0])
        self.assertIn(":11-13", self.show("docs/user/feeds.md:11")[1][0])

    def test_an_id_target_finds_the_section_without_naming_the_page(self) -> None:
        status, lines, _err = self.show("reader-view")
        self.assertEqual(status, 0)
        self.assertEqual(lines[0], "docs/user/feeds.md:15-18  The `Reader` view  id: reader-view")
        self.assertEqual(lines[1], "## The `Reader` view")

    def test_a_section_without_a_marker_says_so(self) -> None:
        _status, lines, _err = self.show("docs/user/feeds.md#Subscribing again")
        self.assertEqual(lines[0], "docs/user/feeds.md:11-13  Subscribing again  no marker")

    def test_a_page_named_by_its_unique_end(self) -> None:
        self.write_tree({"docs/developer/build.md": "# Build\n\ntext\n"})
        status, lines, _err = self.show("build#Build")
        self.assertEqual(status, 0)
        self.assertEqual(lines[0], "docs/developer/build.md:1-3  Build  no marker")

    def test_a_page_name_without_a_slash_that_two_pages_share_is_ambiguous(self) -> None:
        status, _lines, err = self.show("feeds#Feeds")
        self.assertEqual(status, 2)
        self.assertIn("docs/user/feeds.md", err)
        self.assertIn("docs/architecture/state/feeds.md", err)
        self.assertEqual(self.show("state/feeds#State")[0], 0)

    def test_heading_matching_tiers(self) -> None:
        # Equal titles (case and markup ignored), then the GitHub anchor, then a unique prefix or part.
        for target, want in (("#subscribing", SUBSCRIBING), ("#the reader view", READER),
                             ("#the-reader-view", READER), ("#Reader sett", SETTINGS),
                             ("#settings", SETTINGS), ("#Feeds > Subscribing again", AGAIN),
                             ("#Feeds > The reader view", READER), ("#Feeds", TOP)):
            status, lines, err = self.show("docs/user/feeds.md" + target)
            self.assertEqual(status, 0, (target, err))
            self.assertIn(f"docs/user/feeds.md:{want}-", lines[0], target)

    def test_a_heading_that_several_sections_start_is_ambiguous(self) -> None:
        status, _lines, err = self.show("docs/user/feeds.md#Sub")
        self.assertEqual(status, 2)
        self.assertIn("fits 2 sections", err)
        self.assertIn("docs/user/feeds.md:6", err)
        self.assertIn("docs/user/feeds.md:11", err)
        # A part of a title that two titles hold is just as ambiguous.
        self.assertEqual(self.show("docs/user/feeds.md#again")[0], 0)
        self.assertEqual(self.show("docs/user/feeds.md#ing")[0], 2)

    def test_an_unknown_heading_lists_close_titles(self) -> None:
        status, _lines, err = self.show("docs/user/feeds.md#Subscribng")
        self.assertEqual(status, 2)
        self.assertIn("no section of docs/user/feeds.md is titled 'Subscribng'", err)
        self.assertIn("close: Subscribing", err)

    def test_an_unknown_id_names_the_close_ids(self) -> None:
        status, lines, err = self.show("feeds-subscibe")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("no section has the id 'feeds-subscibe'", err)
        self.assertIn("close: feeds-subscribe", err)

    def test_a_bare_page_name_gets_the_hint(self) -> None:
        status, lines, err = self.show("docs/user/feeds.md")
        self.assertEqual((status, lines), (2, []))
        self.assertIn("name a section: PAGE#HEADING, PAGE:LINE, or an id (outline PAGE lists them)", err)
        self.assertIn("docs/user/feeds.md", err)
        self.assertIn("name a section", self.show("user/feeds")[2])

    def test_a_line_outside_the_page_and_an_unknown_page(self) -> None:
        status, _lines, err = self.show("docs/user/feeds.md:999")
        self.assertEqual(status, 2)
        self.assertIn("has no line 999", err)
        self.assertEqual(self.show("docs/user/feeds.md:0")[0], 2)
        status, _lines, err = self.show("docs/user/nope.md#Feeds")
        self.assertEqual(status, 2)
        self.assertIn("no page named", err)

    def test_a_heading_holding_a_colon_with_digits_is_not_a_line_number(self) -> None:
        self.write_tree({"docs/odd.md": "# Odd\n\n## Step: 2\n\ntext\n"})
        status, lines, _err = self.show("docs/odd.md#Step: 2")
        self.assertEqual(status, 0)
        self.assertIn("docs/odd.md:3-5", lines[0])

    def test_numbers_start_each_line_with_its_number_and_a_tab(self) -> None:
        _status, lines, _err = self.show("docs/user/feeds.md#Subscribing", "--numbers")
        self.assertEqual(lines[0], "docs/user/feeds.md:6-9  Subscribing  id: feeds-subscribe")
        self.assertEqual(lines[1:5], [f"{n}\t{text}" for n, text in
                                      zip(range(6, 10), FEEDS.splitlines()[5:9])])

    def test_the_twelve_thousand_character_cap_and_all(self) -> None:
        body = "".join(f"{n:04d} " + "x" * 94 + "\n" for n in range(200))  # 100 characters a line
        self.write_tree({"docs/big.md": "# Big\n\n" + body})
        _status, lines, _err = self.show("docs/big.md#Big")
        shown = lines[1:-1]
        total = sum(len(line) + 1 for line in shown)
        # The cap holds, and the next line would have broken it.
        self.assertLessEqual(total, 12000)
        self.assertGreater(total + 100, 12000)
        self.assertEqual(lines[-1], f"{output.ELLIPSIS} lines {len(shown) + 1}-202 not shown; --all shows them")
        status, lines, _err = self.show("docs/big.md#Big", "--all")
        self.assertEqual(len(lines) - 1, 202)
        self.assertNotIn("not shown", lines[-1])

    def test_the_cap_counts_the_number_prefixes_too(self) -> None:
        body = "".join("y" * 98 + "\n" for _ in range(200))
        self.write_tree({"docs/big.md": "# Big\n\n" + body})
        plain = self.show("docs/big.md#Big")[1]
        numbered = self.show("docs/big.md#Big", "--numbers")[1]
        self.assertLess(len(numbered), len(plain))
        self.assertTrue(numbered[-1].startswith(output.ELLIPSIS + " lines "))

    def test_a_single_overlong_first_line_is_still_printed(self) -> None:
        self.write_tree({"docs/wide.md": "# " + "w" * 13000 + "\n\ntail\n"})
        _status, lines, _err = self.show("docs/wide.md:1")
        self.assertEqual(len(lines[1]), 13002)
        self.assertEqual(lines[-1], f"{output.ELLIPSIS} lines 2-3 not shown; --all shows them")

    def test_json_object(self) -> None:
        status, out, _err = self.run_cli("show", "docs/user/feeds.md#Subscribing", "--json")
        self.assertEqual(status, 0)
        data = json.loads(out)
        self.assertEqual(data, {
            "path": "docs/user/feeds.md", "start": 6, "end": 9, "span_end": 10,
            "heading": "Subscribing", "title": "Subscribing", "level": 2, "id": "feeds-subscribe",
            "keys": ["Add Feed", "subscribe"], "status": None, "issues": [],
            "src": [{"path": "TextMouth/Feeds.swift", "exists": True}, {"path": "gone.swift", "exists": False}],
            "lines": FEEDS.splitlines()[5:9], "truncated": False,
        })

    def test_json_gives_a_marked_sections_status_and_issues(self) -> None:
        self.write_tree({"docs/user/limits.md": "# Limits\n<!-- id: limits; status: planned; issues: DR04, DR05 -->\n\nNot yet.\n"})
        data = json.loads(self.run_cli("show", "limits", "--json")[1])
        self.assertEqual((data["status"], data["issues"]), ("planned", ["DR04", "DR05"]))

    def test_json_for_a_section_without_a_marker_and_for_a_truncated_one(self) -> None:
        data = json.loads(self.run_cli("show", "docs/user/feeds.md#Subscribing again", "--json")[1])
        self.assertEqual((data["id"], data["keys"], data["src"]), (None, [], []))
        self.write_tree({"docs/big.md": "# Big\n\n" + "z" * 12100 + "\n\nmore\n"})
        data = json.loads(self.run_cli("show", "docs/big.md#Big", "--json")[1])
        self.assertTrue(data["truncated"])
        self.assertEqual(data["lines"], ["# Big", ""])
        data = json.loads(self.run_cli("show", "docs/big.md#Big", "--json", "--all")[1])
        self.assertFalse(data["truncated"])


class TargetHelperTests(DocLibCase):
    """github_slug, page_slugs, and the markup stripping behind heading names."""

    def test_github_slug(self) -> None:
        cases = {
            "Section markers": "section-markers",
            "The `Reader` view": "the-reader-view",
            "What's *new*? (v2.0)": "whats-new-v20",
            "snake_case and _emphasis_": "snake_case-and-emphasis",
            "A  B": "a--b",
            "[link](http://x) text": "link-text",
            "Café au lait": "café-au-lait",
            "Q&A: 1/2": "qa-12",
        }
        for title, slug in cases.items():
            self.assertEqual(targets.github_slug(title), slug, title)

    def test_page_slugs_number_repeats_like_github(self) -> None:
        from docmodel import parse
        page = parse("p.md", "intro\n\n# A\n\n## Same\n\n## Same\n\n## Same\n\n## Same-1\n")
        slugs = targets.page_slugs(page)
        # A heading titled "Same-1" must not take the anchor GitHub already gave the second "Same".
        self.assertEqual(list(slugs), ["a", "same", "same-1", "same-2", "same-1-1"])
        self.assertEqual([s.start for s in slugs.values()], [3, 5, 7, 9, 11])

    def test_duplicate_headings_are_ambiguous_by_title_but_reachable_by_anchor_or_line(self) -> None:
        self.write_tree({"docs/dup.md": "# D\n\n## Same\n\none\n\n## Same\n\ntwo\n"})
        status, _out, err = self.run_cli("show", "docs/dup.md#Same")
        self.assertEqual(status, 2)
        self.assertIn("fits 2 sections", err)
        status, out, _err = self.run_cli("show", "docs/dup.md#same-1")
        self.assertEqual(status, 0)
        self.assertIn("docs/dup.md:7-9", out)
        self.assertIn("two", out)

    def test_an_id_on_two_sections_is_an_error(self) -> None:
        self.write_tree({"docs/a.md": "# A\n<!-- id: twin -->\n", "docs/b.md": "# B\n<!-- id: twin -->\n"})
        status, _out, err = self.run_cli("show", "twin")
        self.assertEqual(status, 2)
        self.assertIn("is on 2 sections", err)

    def test_an_id_is_looked_up_in_agents_and_claude_but_not_in_the_memory_logs(self) -> None:
        self.write_tree({"AGENTS.md": "# Agents\n\n## Rules\n<!-- id: agent-rules -->\ntext\n",
                         "TODO-2026.md": "# Todo\n\n## Item\n<!-- id: todo-item -->\ntext\n"})
        self.assertEqual(self.run_cli("show", "agent-rules")[0], 0)
        self.assertEqual(self.run_cli("show", "todo-item")[0], 2)
