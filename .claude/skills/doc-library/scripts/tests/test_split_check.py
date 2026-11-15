"""Tests of ``split-check`` and of the word model it stands on (``splitcheck``)."""

from __future__ import annotations

import time

from doclib_case import DocLibCase

import baseline
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

    def test_several_old_versions_joined_by_commas_check_a_move_between_pages(self) -> None:
        self.git_repo({"a.md": "# A\n\nalpha one.\n\n## Moved\n\nmoved text here.\n", "b.md": "# B\n\nbeta two.\n"})
        # The section moves from the end of a.md to the top of b.md.
        self.write_tree({"a.md": "# A\n\nalpha one.\n", "b.md": "# B\n\n## Moved\n\nmoved text here.\n\nbeta two.\n"})
        status, lines, err = self.check("HEAD:a.md,HEAD:b.md", "a.md", "b.md")
        self.assertEqual((status, err, lines), (0, "", ["split-check: same words (7 words)"]))
        # In another order of the pages the words no longer follow one another.
        status, lines, _ = self.check("HEAD:a.md,HEAD:b.md", "b.md", "a.md")
        self.assertEqual(status, 1)
        self.assertIn("OLD HEAD:a.md:3", lines[1])
        self.assertIn("NEW b.md:", lines[2])
        # And the OLD versions are read in the order given too.
        self.assertEqual(self.check("HEAD:b.md,HEAD:a.md", "a.md", "b.md")[0], 1)

    def test_a_missing_old_version_in_the_list_is_a_usage_error(self) -> None:
        self.assertEqual(self.run_cli("split-check", "old.md,none.md", "old.md")[0], 2)

    def test_a_long_page_is_checked_in_well_under_a_second(self) -> None:
        text = "# Long\n\n" + "\n".join("word%d " % i * 10 for i in range(4000)) + "\n"
        self.write_tree({"old.md": text, "new.md": text.replace("\n", "\n\n")})
        started = time.monotonic()
        status, _, _ = self.check("old.md", "new.md")
        self.assertEqual(status, 0)
        self.assertLess(time.monotonic() - started, 1.0)


class LooseTests(DocLibCase):
    """--loose: a re-punctuation passes, any other change fails, and code stays exact."""

    def loose(self, old: str, new: str, *extra: str):
        """Write ``old`` and ``new`` as pages; return ((loose status, its lines), the exact check's status)."""
        self.write_tree({"old.md": "# P\n\n" + old, "new.md": "# P\n\n" + new})
        status, out, _ = self.run_cli("split-check", "old.md", "new.md", "--loose", *extra)
        exact, _, _ = self.run_cli("split-check", "old.md", "new.md", *extra)
        return (status, out.splitlines()), exact

    def assert_loose_only(self, old: str, new: str) -> None:
        """The loose check passes and the exact one fails."""
        (status, lines), exact = self.loose(old, new)
        self.assertEqual((status, exact), (0, 1), lines)

    def assert_both_fail(self, old: str, new: str) -> None:
        """The loose check and the exact one both fail."""
        (status, lines), exact = self.loose(old, new)
        self.assertEqual((status, exact), (1, 1), lines)

    def test_a_semicolon_made_a_full_stop_passes_loosely_only(self) -> None:
        self.assert_loose_only("Open the book; press Play.\n", "Open the book. Press Play.\n")

    def test_a_capital_after_a_new_full_stop_passes_loosely_only(self) -> None:
        self.assert_loose_only("The reader opens it, and then it plays.\n", "The reader opens it.\nAnd then it plays.\n")

    def test_a_clause_run_made_a_markdown_list_passes_loosely_only(self) -> None:
        self.assert_loose_only("It opens a book; it reads a page; it saves a place.\n",
                               "- It opens a book.\n- It reads a page.\n- It saves a place.\n")

    def test_a_parenthesis_made_a_sentence_passes_loosely_only(self) -> None:
        self.assert_loose_only("Press Play (the button is at the left) to start.\n",
                               "Press Play. The button is at the left. To start.\n")

    def test_quotes_and_a_lone_dash_are_ignored(self) -> None:
        self.assert_loose_only("He said “stop” - then \"left\".\n", "He said stop then left.\n")
        self.assert_loose_only("It is a word — well.\n", "It is a word well.\n")

    def test_inner_punctuation_keeps_a_word_whole(self) -> None:
        self.assert_both_fail("Open file.swift now.\n", "Open fileswift now.\n")
        self.assert_both_fail("It's here.\n", "Its here.\n")
        self.assert_both_fail("A well-known fact.\n", "A wellknown fact.\n")

    def test_an_added_or_removed_word_fails_both(self) -> None:
        self.assert_both_fail("Open the book; press Play.\n", "Open the book. Then press Play.\n")
        self.assert_both_fail("Open the book; press Play.\n", "Open the book. Play.\n")
        # Dropping the word "and" from a clause list is a removed word too.
        self.assert_both_fail("A one; a two; and a three.\n", "- A one.\n- A two.\n- A three.\n")

    def test_a_reordered_word_fails_both(self) -> None:
        self.assert_both_fail("Open the book.\n", "Open book the.\n")

    def test_a_changed_backticked_name_fails_both_even_in_case_or_punctuation(self) -> None:
        self.assert_both_fail("Call `foo(bar:)` now.\n", "Call `foo(baz:)` now.\n")
        self.assert_both_fail("Call `foo(bar:)` now.\n", "Call `Foo(bar:)` now.\n")
        self.assert_both_fail("Call `foo(bar:)` now.\n", "Call `foo(bar)` now.\n")
        # A span of several words is exact through its middle and at its two ends.
        self.assert_both_fail("Run `make Install now` here.\n", "Run `make install now` here.\n")
        self.assert_both_fail("Run `make install.` here.\n", "Run `make install` here.\n")
        self.assert_both_fail("Run `(make install` here.\n", "Run `make install` here.\n")

    def test_punctuation_around_a_backticked_name_may_change(self) -> None:
        self.assert_loose_only("See `foo(bar:)`; then stop.\n", "See `foo(bar:)`. Then stop.\n")
        self.assert_loose_only("See (`Foo.swift`), then stop.\n", "See `Foo.swift` then stop.\n")

    def test_a_changed_code_line_fails_both(self) -> None:
        self.assert_both_fail("```\nlet X = foo(1)\n```\n", "```\nlet x = foo(1)\n```\n")
        self.assert_both_fail("```\nlet x = foo(1);\n```\n", "```\nlet x = foo(1)\n```\n")
        # A lone dash in a code block is a word and counts.
        self.assert_both_fail("```\na\n-\nb\n```\n", "```\na\nb\n```\n")

    def test_a_table_stays_exact(self) -> None:
        table = "| Key | Does |\n| --- | --- |\n| Space | Plays. |\n"
        self.assert_both_fail(table, table.replace("Space", "space"))
        self.assert_both_fail(table, table.replace("Plays.", "Plays"))

    def test_the_output_names_the_loose_mode_and_the_exact_one_does_not(self) -> None:
        (status, lines), _ = self.loose("Open it; press Play.\n", "Open it. Press Play.\n")
        self.assertEqual((status, lines), (0, ["split-check: same words, loosely (4 words)"]))
        self.write_tree({"new.md": "# P\n\nOpen it; press Play.\n"})
        _, out, _ = self.run_cli("split-check", "old.md", "new.md")
        self.assertEqual(out.splitlines(), ["split-check: same words (4 words)"])

    def test_a_failure_shows_the_words_as_written(self) -> None:
        (status, lines), _ = self.loose("Open it; press Play.\n", "Open it. Then Press Play.\n")
        self.assertEqual(status, 1)
        self.assertIn("[Then]", lines[2])

    def test_loose_works_with_files_to_src(self) -> None:
        self.write_tree({"TextMouth/Importer.swift": ""})
        old = "Imports read a file; then stop.\n\nFiles: TextMouth/Importer.swift\n"
        new = "<!-- id: imports; src: TextMouth/Importer.swift -->\nImports read a file. Then stop.\n"
        (status, lines), exact = self.loose(old, new, "--files-to-src")
        self.assertEqual((status, lines), (0, ["split-check: same words, loosely (6 words)"]))
        self.assertEqual(exact, 1)

    def test_loose_works_with_update_baseline(self) -> None:
        self.git_repo({"README.md": "# Index\n\n- [Old](docs/old.md) old\n- [New](docs/new.md) new\n",
                       "docs/old.md": page("Old", "On March 3, 2026 it changed; go now."), "docs/new.md": page("New")})
        baseline.write_baseline(self.root, {"docs/old.md": {"date": 1}})
        self.write_tree({"docs/new.md": page("New", DATED, "Go now.")})
        (self.root / "docs/old.md").unlink()
        status, out, _ = self.run_cli("split-check", "HEAD:docs/old.md", "docs/new.md", "--loose", "--update-baseline")
        self.assertEqual(status, 0, out)
        self.assertIn("split-check: same words, loosely (8 words)", out)
        self.assertEqual(baseline.load_baseline(self.root), {"docs/new.md": {"date": 1}})

    def test_loose_words_of_a_page_carry_their_keys(self) -> None:
        found = splitcheck.words("# H\n\n- Hello, (`Foo`) — World.\n", "a.md", loose=True)
        self.assertEqual([(w.text, w.same_as) for w in found], [("Hello,", "hello"), ("(`Foo`)", "`Foo`"), ("World.", "world")])

    def test_a_long_page_is_checked_loosely_in_well_under_a_second(self) -> None:
        text = "# Long\n\n" + "\n".join("Word%d; " % i * 10 for i in range(4000)) + "\n"
        self.write_tree({"old.md": text, "new.md": text.replace(";", ".")})
        started = time.monotonic()
        status, _, _ = self.run_cli("split-check", "old.md", "new.md", "--loose")
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

    def test_files_blocks_of_every_old_version_must_be_named(self) -> None:
        self.write_tree({"other.md": "# Other\n\nOther text.\n\nFiles: project.yml\n"})
        self.write_tree({"new.md": "# Imports\n\n<!-- id: imports; src: TextMouth/Importer.swift, Parser.swift, Parsers/ -->\n"
                                   "Imports read a file.\n\nOther text.\n"})
        status, out, _ = self.run_cli("split-check", "old.md,other.md", "new.md", "--files-to-src")
        self.assertEqual(status, 1)
        self.assertEqual(out.splitlines()[-1], "  project.yml")


# One paragraph with a dated sentence (a ``date`` violation) and one with a 350-character line
# (a ``line-length`` violation): the lint counts each, and a split can move them between pages.
DATED = "On March 3, 2026 it changed."
LONG = "word " * 70
INDEX = "# Index\n\n- [Old](docs/old.md) the old page\n- [One](docs/new1.md) page one\n- [Two](docs/new2.md) page two\n"


def page(title: str, *paragraphs: str) -> str:
    """A docs page: a heading, then each paragraph."""
    return f"# {title}\n\n" + "\n\n".join(paragraphs) + "\n"


class UpdateBaselineTests(DocLibCase):
    """--update-baseline: the OLD pages' lint counts follow the words to the NEW pages."""

    def setUp(self) -> None:
        super().setUp()
        # The index links all three pages from the start, so the split adds no index-link violation.
        self.git_repo({"README.md": INDEX, "docs/old.md": page("Old", DATED, DATED, LONG, DATED),
                       "docs/new1.md": page("One"), "docs/new2.md": page("Two")})

    def set_baseline(self, data: dict) -> None:
        """Write ``data`` as the lint baseline."""
        baseline.write_baseline(self.root, data)

    def split(self, *argv: str):
        """Run ``split-check --update-baseline`` with ``argv``; return (status, standard output lines)."""
        status, out, _ = self.run_cli("split-check", *argv, "--update-baseline")
        return status, out.splitlines()

    def test_a_split_within_the_pool_hands_the_counts_to_the_new_pages_and_drops_the_old_entry(self) -> None:
        self.set_baseline({"docs/old.md": {"date": 3, "line-length": 1}, "docs/other.md": {"date": 5}})
        self.write_tree({"docs/new1.md": page("One", DATED, DATED, LONG), "docs/new2.md": page("Two", DATED)})
        (self.root / "docs/old.md").unlink()
        status, lines = self.split("HEAD:docs/old.md", "docs/new1.md", "docs/new2.md")
        self.assertEqual(status, 0, lines)
        self.assertEqual(baseline.load_baseline(self.root), {
            "docs/new1.md": {"date": 2, "line-length": 1}, "docs/new2.md": {"date": 1}, "docs/other.md": {"date": 5}})
        self.assertIn("lowered docs/old.md date 3 -> 0", lines)
        self.assertIn("raised docs/new1.md date 0 -> 2", lines)

    def test_a_split_that_raises_a_rule_is_refused_and_writes_nothing(self) -> None:
        # The baseline allows one date, but the page already has three: the split may not pass them on.
        self.set_baseline({"docs/old.md": {"date": 1, "line-length": 1}})
        before = (self.root / baseline.BASELINE).read_text()
        self.write_tree({"docs/new1.md": page("One", DATED, DATED, LONG), "docs/new2.md": page("Two", DATED)})
        (self.root / "docs/old.md").unlink()
        status, lines = self.split("HEAD:docs/old.md", "docs/new1.md", "docs/new2.md")
        self.assertEqual(status, 1)
        self.assertEqual(len(lines), 2, lines)
        self.assertIn("3 violations of date", lines[1])
        self.assertIn("allow 1", lines[1])
        self.assertEqual((self.root / baseline.BASELINE).read_text(), before)

    def test_a_split_that_keeps_the_old_page_as_one_of_the_new_ones_keeps_its_entry_with_its_new_counts(self) -> None:
        self.set_baseline({"docs/old.md": {"date": 3, "line-length": 1}})
        self.write_tree({"docs/old.md": page("Old", DATED, DATED, LONG), "docs/new1.md": page("One", DATED)})
        status, lines = self.split("HEAD:docs/old.md", "docs/old.md", "docs/new1.md")
        self.assertEqual(status, 0, lines)
        self.assertEqual(baseline.load_baseline(self.root), {
            "docs/old.md": {"date": 2, "line-length": 1}, "docs/new1.md": {"date": 1}})

    def test_the_pool_adds_up_every_old_page(self) -> None:
        # A move from old.md into new2.md, which had a date of its own: both are OLD, and both are NEW.
        self.write_tree({"docs/new2.md": page("Two", DATED)})
        self.commit_all("new2 has a date")
        self.set_baseline({"docs/old.md": {"date": 3, "line-length": 1}, "docs/new2.md": {"date": 1}})
        self.write_tree({"docs/old.md": page("Old", DATED, DATED), "docs/new2.md": page("Two", LONG, DATED, DATED)})
        status, lines = self.split("HEAD:docs/old.md,HEAD:docs/new2.md", "docs/old.md", "docs/new2.md")
        self.assertEqual(status, 0, lines)
        self.assertEqual(baseline.load_baseline(self.root), {
            "docs/old.md": {"date": 2}, "docs/new2.md": {"date": 2, "line-length": 1}})

    def test_a_count_over_the_sum_of_the_old_pages_is_refused(self) -> None:
        self.write_tree({"docs/new2.md": page("Two", DATED)})
        self.commit_all("new2 has a date")
        self.set_baseline({"docs/old.md": {"date": 2, "line-length": 1}, "docs/new2.md": {"date": 1}})
        self.write_tree({"docs/old.md": page("Old", DATED, DATED), "docs/new2.md": page("Two", LONG, DATED, DATED)})
        status, lines = self.split("HEAD:docs/old.md,HEAD:docs/new2.md", "docs/old.md", "docs/new2.md")
        self.assertEqual(status, 1, lines)
        self.assertIn("4 violations of date", lines[1])
        self.assertIn("allow 3", lines[1])

    def test_the_pool_adds_what_a_new_page_that_is_not_old_already_has(self) -> None:
        self.set_baseline({"docs/old.md": {"date": 2, "line-length": 1}, "docs/new1.md": {"date": 1}})
        self.write_tree({"docs/old.md": page("Old", DATED, DATED, LONG), "docs/new1.md": page("One", DATED)})
        status, lines = self.split("HEAD:docs/old.md", "docs/old.md", "docs/new1.md")
        self.assertEqual(status, 0, lines)
        self.assertEqual(baseline.load_baseline(self.root), {
            "docs/old.md": {"date": 2, "line-length": 1}, "docs/new1.md": {"date": 1}})

    def test_nothing_changes_when_the_words_do_not_match_or_the_baseline_has_no_entry_for_the_old_pages(self) -> None:
        self.set_baseline({"docs/other.md": {"date": 5}})
        self.write_tree({"docs/new1.md": page("One", DATED, DATED, LONG, DATED)})
        (self.root / "docs/old.md").unlink()
        status, lines = self.split("HEAD:docs/old.md", "docs/new1.md")
        self.assertEqual((status, lines[-1]), (0, "split-check: the baseline holds nothing for the OLD pages; left as it is"))
        self.assertEqual(baseline.load_baseline(self.root), {"docs/other.md": {"date": 5}})
        # Words that do not match: the baseline stays as it is.
        self.set_baseline({"docs/old.md": {"date": 3}})
        before = (self.root / baseline.BASELINE).read_text()
        self.write_tree({"docs/new1.md": page("One", DATED, DATED, LONG)})
        status, lines = self.split("HEAD:docs/old.md", "docs/new1.md")
        self.assertEqual(status, 1)
        self.assertEqual((self.root / baseline.BASELINE).read_text(), before)
