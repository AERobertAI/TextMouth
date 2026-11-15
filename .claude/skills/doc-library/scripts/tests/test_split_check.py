"""Tests of ``split-check`` and of the word model it stands on (``splitcheck``)."""

from __future__ import annotations

import time

from doclib_case import DocLibCase

import splitcheck
from output import UsageError

OLD = """\
# Feeds

<!-- id: feeds-top; keys: RSS -->
A feed is a list of episodes. The app reads it
and lists each episode.

## Subscribing

Choose Add Feed and paste the address.
"""


class WordsTests(DocLibCase):
    """words(): what counts as a word, and what does not."""

    def texts(self, text: str, **options) -> list:
        """The words of ``text`` as plain strings."""
        return [word.text for word in splitcheck.words(text, "page.md", **options)]

    def test_front_matter_headings_markers_and_blank_lines_add_no_words(self) -> None:
        text = "---\ntitle: x\n---\n# Head\n\n<!-- id: a-b; keys: k -->\nOne two.\n"
        self.assertEqual(self.texts(text), ["One", "two."])

    def test_list_and_quote_markers_are_dropped(self) -> None:
        text = "- a\n* b\n+ c\n1. d\n2) e\n\n> f\n> - g\n"
        self.assertEqual(self.texts(text), list("abcdefg"))

    def test_a_marker_inside_a_code_block_or_table_stays(self) -> None:
        text = "```\n- x\n> y\n```\n\n| a | b |\n"
        self.assertEqual(self.texts(text), ["```", "-", "x", ">", "y", "```", "|", "a", "|", "b", "|"])

    def test_a_word_that_only_starts_like_a_marker_is_kept(self) -> None:
        self.assertEqual(self.texts("-5 degrees\n**bold** and 3.5\n"), ["-5", "degrees", "**bold**", "and", "3.5"])

    def test_words_carry_their_source_and_line(self) -> None:
        found = splitcheck.words("# H\n\nfirst\nsecond third\n", "a.md")
        self.assertEqual([(w.text, w.source, w.line) for w in found], [("first", "a.md", 3), ("second", "a.md", 4), ("third", "a.md", 4)])


class SplitCheckTests(DocLibCase):
    """The command: same words pass, any change in the words or their order fails."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({"old.md": OLD})

    def check(self, *argv: str):
        """Run ``split-check`` with ``argv``; return (status, standard output lines, standard error)."""
        status, out, err = self.run_cli("split-check", *argv)
        return status, out.splitlines(), err

    def test_the_same_text_reflowed_passes(self) -> None:
        reflowed = ("# Feeds\n\nA feed is a list of episodes.\nThe app reads it and lists each episode.\n\n"
                    "## Subscribing\n\nChoose Add Feed\nand paste the address.\n")
        self.write_tree({"new.md": reflowed})
        status, lines, err = self.check("old.md", "new.md")
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(lines, ["split-check: same words (22 words)"])

    def test_a_heading_added_and_a_marker_added_pass(self) -> None:
        text = OLD.replace("## Subscribing\n", "## Subscribing\n\n<!-- id: subscribing; src: x.swift -->\n") + "\n### A new heading\n"
        self.write_tree({"new.md": text})
        self.assertEqual(self.check("old.md", "new.md")[0], 0)

    def test_a_bullet_turned_into_a_paragraph_passes(self) -> None:
        self.write_tree({"old.md": "# P\n\n- Pick the file.\n- Press Play.\n", "new.md": "# P\n\nPick the file.\n\nPress Play.\n"})
        self.assertEqual(self.check("old.md", "new.md")[0], 0)

    def test_one_word_changed_fails_naming_both_lines_with_context(self) -> None:
        self.write_tree({"new.md": OLD.replace("paste the address", "type the address")})
        status, lines, _ = self.check("old.md", "new.md")
        self.assertEqual(status, 1)
        self.assertEqual(lines[1], "  OLD old.md:9: and lists each episode. Choose Add Feed and [paste] the address.")
        self.assertEqual(lines[2], "  NEW new.md:9: and lists each episode. Choose Add Feed and [type] the address.")
        self.assertEqual(lines[3], "  OLD has 22 words, NEW has 22")

    def test_a_word_moved_fails(self) -> None:
        self.write_tree({"new.md": OLD.replace("reads it\nand lists", "lists it\nand reads")})
        status, lines, _ = self.check("old.md", "new.md")
        self.assertEqual(status, 1)
        self.assertIn("[reads]", lines[1])
        self.assertIn("[lists]", lines[2])

    def test_a_word_dropped_at_the_end_names_where_the_new_text_ends(self) -> None:
        self.write_tree({"new.md": OLD.replace(" the address.", "")})
        status, lines, _ = self.check("old.md", "new.md")
        self.assertEqual(status, 1)
        self.assertIn("[the] address.", lines[1])
        self.assertEqual(lines[2], "  NEW new.md:9 (the end): lists each episode. Choose Add Feed and paste [end of text]")
        self.assertEqual(lines[3], "  OLD has 22 words, NEW has 20")

    def test_context_is_at_most_eight_words_a_side(self) -> None:
        self.write_tree({"old.md": "# H\n\n" + " ".join(f"w{i}" for i in range(40)) + "\n",
                         "new.md": "# H\n\n" + " ".join(f"w{i}" if i != 20 else "x" for i in range(40)) + "\n"})
        _, lines, _ = self.check("old.md", "new.md")
        self.assertEqual(lines[1], "  OLD old.md:3: w12 w13 w14 w15 w16 w17 w18 w19 [w20] w21 w22 w23 w24 w25 w26 w27 w28")

    def test_one_page_split_in_two_passes_in_order_and_fails_in_the_wrong_one(self) -> None:
        self.write_tree({"first.md": "# Feeds\n\nA feed is a list of episodes. The app reads it\nand lists each episode.\n",
                         "second.md": "# Subscribing\n\nChoose Add Feed and paste the address.\n"})
        status, lines, _ = self.check("old.md", "first.md", "second.md")
        self.assertEqual((status, lines), (0, ["split-check: same words (22 words)"]))
        status, lines, _ = self.check("old.md", "second.md", "first.md")
        self.assertEqual(status, 1)
        self.assertIn("NEW second.md:3", lines[2])

    def test_ref_and_path_reads_the_file_as_git_has_it(self) -> None:
        self.git_repo({"docs/a.md": OLD})
        self.write_tree({"docs/a.md": OLD.replace("address", "url"), "docs/b.md": OLD})
        self.assertEqual(self.check("HEAD:docs/a.md", "docs/b.md")[0], 0)
        status, lines, _ = self.check("HEAD:docs/a.md", "docs/a.md")
        self.assertEqual(status, 1)
        self.assertIn("OLD HEAD:docs/a.md:9", lines[1])

    def test_a_ref_git_does_not_know_and_a_missing_file_are_usage_errors(self) -> None:
        self.git_repo({"docs/a.md": OLD})
        for spec in ("nosuchref:docs/a.md", "HEAD:docs/none.md", "HEAD:docs"):
            status, out, err = self.run_cli("split-check", spec, "docs/a.md")
            self.assertEqual((status, out), (2, ""), spec)
            self.assertIn("git has no file", err)
        self.assertEqual(self.run_cli("split-check", "docs/none.md", "docs/a.md")[0], 2)

    def test_a_path_outside_the_root_is_refused(self) -> None:
        for spec in ("../old.md", "/etc/hosts", "~/old.md", "HEAD:../old.md", "HEAD:/etc/hosts"):
            status, out, err = self.run_cli("split-check", spec, "old.md")
            self.assertEqual((status, out), (2, ""), spec)
            self.assertTrue(err.startswith("doclib: "), spec)
        self.assertEqual(self.run_cli("split-check", "old.md", "../old.md")[0], 2)
        # A ref that looks like an option is never handed to git.
        with self.assertRaises(UsageError):
            splitcheck.read_version(self.root, "-x:old.md")

    def test_a_long_page_is_checked_in_well_under_a_second(self) -> None:
        text = "# Long\n\n" + "\n".join("word%d " % i * 10 for i in range(4000)) + "\n"
        self.write_tree({"old.md": text, "new.md": text.replace("\n", "\n\n")})
        started = time.monotonic()
        status, _, _ = self.check("old.md", "new.md")
        self.assertEqual(status, 0)
        self.assertLess(time.monotonic() - started, 1.0)


FILES_OLD = """\
# Imports

<!-- id: imports; keys: import -->
Imports read a file.

Files: TextMouth/Importer.swift, Parser.swift
and TextMouth/Parsers/

- Files: not/a/path.swift, project.yml
"""


class FilesToSrcTests(DocLibCase):
    """--files-to-src: Files: blocks are left out, and every path they name must reappear."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "TextMouth/Importer.swift": "", "TextMouth/Parsers/Parser.swift": "", "project.yml": "",
            "old.md": FILES_OLD,
        })

    def check(self, new_text: str):
        """Write ``new_text`` as new.md and run ``split-check --files-to-src old.md new.md``."""
        self.write_tree({"new.md": new_text})
        status, out, _ = self.run_cli("split-check", "old.md", "new.md", "--files-to-src")
        return status, out.splitlines()

    def test_the_paths_moved_into_a_marker_pass(self) -> None:
        status, lines = self.check(
            "# Imports\n\n<!-- id: imports; keys: import; src: TextMouth/Importer.swift, TextMouth/Parsers/Parser.swift, "
            "TextMouth/Parsers/, project.yml -->\nImports read a file.\n")
        self.assertEqual((status, lines), (0, ["split-check: same words (4 words)"]))

    def test_a_path_written_another_way_passes_when_both_resolve_to_the_same_file(self) -> None:
        # Parser.swift resolves to TextMouth/Parsers/Parser.swift; Importer.swift's marker spelling keeps it.
        status, _ = self.check(
            "# Imports\n\n<!-- id: imports; src: Importer.swift, Parser.swift, Parsers/, project.yml -->\nImports read a file.\n")
        self.assertEqual(status, 0)

    def test_a_path_may_be_named_by_a_files_block_of_the_new_page(self) -> None:
        status, _ = self.check(
            "# Imports\n\n<!-- id: imports; src: TextMouth/Importer.swift -->\nImports read a file.\n\n"
            "Files: Parser.swift TextMouth/Parsers/ project.yml\n")
        self.assertEqual(status, 0)

    def test_a_dropped_path_fails_naming_the_token(self) -> None:
        status, lines = self.check(
            "# Imports\n\n<!-- id: imports; src: TextMouth/Importer.swift, TextMouth/Parsers/ -->\nImports read a file.\n")
        self.assertEqual(status, 1)
        self.assertIn("  Parser.swift", lines)
        self.assertIn("  project.yml", lines)
        self.assertNotIn("  TextMouth/Importer.swift", lines)
        self.assertNotIn("  not/a/path.swift", lines)

    def test_without_the_flag_files_blocks_count_as_words(self) -> None:
        self.write_tree({"new.md": "# Imports\n\nImports read a file.\n"})
        status, _, _ = self.run_cli("split-check", "old.md", "new.md")
        self.assertEqual(status, 1)
