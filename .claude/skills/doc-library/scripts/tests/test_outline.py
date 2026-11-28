"""Tests of the ``outline`` command, run through ``doclib.main`` on pages the tests write."""

from __future__ import annotations

import json

from doclib_case import DocLibCase

FEEDS = """\
Intro text before any heading.

# Feeds

<!-- id: feeds-top; keys: RSS; src: TextMouth/Feeds.swift -->
The top.

## Subscribing

<!-- id: feeds-subscribe -->
Text of é subscribing.

### Details

No marker here.
"""


FEEDS_LINES = FEEDS.splitlines()


def size(*lines: str) -> int:
    """The UTF-8 bytes of the lines, each with its line end."""
    return sum(len(line.encode("utf-8")) + 1 for line in lines)


class OutlineTests(DocLibCase):
    """outline: one hit for every section, with id, size, and level."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"docs/user/feeds.md": FEEDS, "docs/architecture/state/feeds.md": "# State\n"})

    def test_one_line_for_every_section_with_ids_and_sizes(self) -> None:
        status, out, err = self.run_cli("outline", "docs/user/feeds.md")
        self.assertEqual((status, err), (0, ""))
        lines = out.splitlines()
        self.assertEqual(len(lines), 4)
        # Commas separate the fields, so they survive the collapse of white space in a hit's text.
        self.assertEqual(lines[0], f"docs/user/feeds.md:1-1  (top)  no id, 1 lines, {size(FEEDS_LINES[0])} bytes, 0 paths")
        self.assertEqual(lines[1], f"docs/user/feeds.md:3-6  # Feeds  feeds-top, 4 lines, {size(*FEEDS_LINES[2:6])} bytes, 1 paths")
        self.assertEqual(lines[2], f"docs/user/feeds.md:8-11  ## Subscribing  feeds-subscribe, 4 lines, {size(*FEEDS_LINES[7:11])} bytes, 0 paths")
        self.assertEqual(lines[3], f"docs/user/feeds.md:13-15  ### Details  no id, 3 lines, {size(*FEEDS_LINES[12:15])} bytes, 0 paths")

    def test_sizes_count_utf8_bytes_of_the_lines_with_their_line_ends(self) -> None:
        _status, out, _err = self.run_cli("outline", "docs/user/feeds.md", "--json")
        sections = [json.loads(line) for line in out.splitlines()]
        file_bytes = len(FEEDS.encode("utf-8"))
        # The sections' sizes plus the blank lines between them make up the file.
        self.assertLessEqual(sum(s["bytes"] for s in sections), file_bytes)
        subscribing = sections[2]
        text = "## Subscribing\n\n<!-- id: feeds-subscribe -->\nText of é subscribing.\n"
        self.assertEqual(subscribing["bytes"], len(text.encode("utf-8")))
        self.assertEqual(subscribing["lines"], 4)

    def test_json_fields(self) -> None:
        _status, out, _err = self.run_cli("outline", "docs/user/feeds.md", "--json")
        sections = [json.loads(line) for line in out.splitlines()]
        top, feeds, sub, details = sections
        self.assertEqual((top["level"], top["title"], top["id"], top["path_titles"]), (0, "", None, []))
        self.assertEqual((feeds["level"], feeds["title"], feeds["id"], feeds["path_titles"]),
                         (1, "Feeds", "feeds-top", ["Feeds"]))
        self.assertEqual(sub["path_titles"], ["Feeds", "Subscribing"])
        self.assertEqual((details["level"], details["id"], details["path_titles"]),
                         (3, None, ["Feeds", "Subscribing", "Details"]))
        for item in sections:
            for key in ("path", "start", "end", "heading", "text", "id", "level", "title", "lines", "bytes", "paths", "path_titles"):
                self.assertIn(key, item)

    def test_paths_counts_distinct_tokens_from_src_and_prose_whether_or_not_they_exist(self) -> None:
        self.write_tree({
            "TextMouth/Feeds.swift": "// code\n",
            "docs/paths.md": (
                "# P\n\n<!-- id: p; src: TextMouth/Feeds.swift, TextMouth/Gone.swift -->\n"
                "See `TextMouth/Feeds.swift` and `TextMouth/Feeds.swift` again, and `docs/paths.md`.\n\n"
                "## Q\n\nNo paths: `Book` and `x`.\n"),
        })
        _status, out, _err = self.run_cli("outline", "docs/paths.md", "--json")
        first, second = [json.loads(line) for line in out.splitlines()]
        # The src entries (the second names no file) and one prose token not in src; the repeat counts once.
        self.assertEqual(first["paths"], 3)
        self.assertEqual(second["paths"], 0)
        self.assertTrue(first["text"].endswith(", 3 paths"))

    def test_a_page_named_by_its_unique_end(self) -> None:
        self.write_tree({"docs/user/only.md": "# Only\n"})
        status, out, _err = self.run_cli("outline", "only")
        self.assertEqual(status, 0)
        self.assertTrue(out.startswith("docs/user/only.md:1-1  # Only  no id, 1 lines,"))

    def test_an_ambiguous_page_name_lists_both_candidates(self) -> None:
        status, out, err = self.run_cli("outline", "feeds")
        self.assertEqual((status, out), (2, ""))
        self.assertIn("docs/user/feeds.md", err)
        self.assertIn("docs/architecture/state/feeds.md", err)
        self.assertEqual(self.run_cli("outline", "user/feeds")[0], 0)
        self.assertEqual(self.run_cli("outline", "state/feeds.md")[0], 0)

    def test_an_unknown_page_is_a_usage_error_with_close_names(self) -> None:
        status, _out, err = self.run_cli("outline", "feedz")
        self.assertEqual(status, 2)
        self.assertIn("no page named 'feedz'", err)
        self.assertIn("did you mean", err)

    def test_thirty_headings_are_all_printed_despite_the_default_cap(self) -> None:
        text = "".join(f"## Heading {n}\n\nBody {n}.\n\n" for n in range(30))
        self.write_tree({"docs/long.md": "# Long\n\n" + text})
        status, out, err = self.run_cli("outline", "docs/long.md")
        self.assertEqual((status, err), (0, ""))
        lines = out.splitlines()
        self.assertEqual(len(lines), 31)
        self.assertIn("## Heading 29", lines[-1])
        # --max still caps it when asked, and says so on standard error.
        _status, out, err = self.run_cli("outline", "docs/long.md", "--max", "5")
        self.assertEqual(len(out.splitlines()), 5)
        self.assertIn("5 of 31 sections shown", err)

    def test_an_empty_page_prints_nothing_and_exits_zero(self) -> None:
        self.write_tree({"docs/empty.md": ""})
        self.assertEqual(self.run_cli("outline", "docs/empty.md"), (0, "", ""))

    def test_a_path_outside_the_repository_is_not_read(self) -> None:
        status, _out, err = self.run_cli("outline", "../outside.md")
        self.assertEqual(status, 2)
        self.assertIn("no page named", err)
