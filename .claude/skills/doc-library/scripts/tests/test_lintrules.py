"""Tests of the lint rules, run on repositories the tests write (never the real docs).

Each rule has cases where it fires, cases where it must not (a log page, an index
page, a page outside the reference areas, and the exceptions in the rule's table),
and the exact lines and details it reports.
"""

from __future__ import annotations

from typing import Dict, List, Tuple

from doclib_case import DocLibCase  # first: it puts the scripts folder on sys.path

import docmodel  # noqa: E402
import lintrules  # noqa: E402
import output  # noqa: E402
import pagewrite  # noqa: E402
from cmd_reflow import reflow_text  # noqa: E402
from lintrules import Violation  # noqa: E402

# A page that satisfies the marker rules, around the text a test cares about.
def marked(ident: str, body: str = "", title: str = "Title") -> str:
    """A reference page with one section: its heading, its marker, and ``body``."""
    return f"# {title}\n\n<!-- id: {ident} -->\n{body}\n"


class RuleCase(DocLibCase):
    """A case with helpers to write a repository and run some rules over it."""

    def found(self, files: Dict[str, str], *rules: str) -> List[Violation]:
        """Write ``files`` and return the violations of ``rules`` (all rules when none)."""
        self.write_tree(files)
        return lintrules.lint(self.root, list(rules) or None)

    def places(self, violations: List[Violation]) -> List[Tuple[str, int, int]]:
        """Each violation's ``(page, start, end)``."""
        return [(v.page, v.start, v.end) for v in violations]


class LineLengthTests(RuleCase):
    """line-length: over 300 characters, outside code, front matter, and markers."""

    def test_limit_is_300_characters(self) -> None:
        text = "a" * 300 + "\n" + "b" * 301 + "\n"
        found = self.found({"docs/user/a.md": text}, "line-length")
        self.assertEqual(self.places(found), [("docs/user/a.md", 2, 2)])
        self.assertEqual(found[0].detail, "301 characters, limit 300")

    def test_counts_characters_not_bytes(self) -> None:
        # 300 two-byte characters are still 300 characters.
        self.assertEqual(self.found({"docs/user/a.md": "é" * 300 + "\n"}, "line-length"), [])

    def test_code_front_matter_and_markers_are_exempt(self) -> None:
        long = "x" * 400
        text = f"---\ntitle: {long}\n---\n# T\n\n<!-- id: t; src: {long} -->\n\n```\n{long}\n```\n\n    {long}\n"
        self.assertEqual(self.found({"docs/user/a.md": text}, "line-length"), [])

    def test_a_plain_html_comment_and_a_heading_are_counted(self) -> None:
        long = "x" * 301
        text = f"# {long}\n\n<!-- {long} -->\n"
        found = self.found({"docs/user/a.md": text}, "line-length")
        self.assertEqual([v.start for v in found], [1, 3])

    def test_applies_to_log_and_index_pages_but_not_to_other_pages(self) -> None:
        long = "x" * 301 + "\n"
        files = {"docs/user/changelog.md": long, "README.md": long, "AGENTS.md": long, "research/R.md": long}
        found = self.found(files, "line-length")
        self.assertEqual(sorted(v.page for v in found), ["AGENTS.md", "README.md", "docs/user/changelog.md"])


def sentence(length: int, first: str = "S") -> str:
    """One sentence of exactly ``length`` characters: a capital, lowercase letters, and a full stop."""
    return first + "x" * (length - 2) + "."


def words_of(length: int) -> str:
    """A capitalised run of nine-letter words, ``length`` characters long, ending in a full stop."""
    text = " ".join(["Wwwwwwwww"] + ["wwwwwwwww"] * ((length - 9) // 10))
    # Pad the last word until the text (plus its full stop) is exactly ``length`` long.
    return text + "w" * (length - 1 - len(text)) + "."


def wrapped(long: str, indent: str = "") -> str:
    """``long`` cut at a space near its middle into two lines, each starting with ``indent``."""
    cut = long.rindex(" ", 0, len(long) // 2)
    return f"{indent}{long[:cut]}\n{indent}{long[cut + 1:]}\n"


class LineLengthReflowTests(RuleCase):
    """line-length: a prose block counts the larger of its long lines as written and as reflow writes them."""

    def lines_of(self, text: str) -> List[Tuple[int, str]]:
        """The ``(line, detail)`` of each line-length violation of ``text``, as a page of docs/user."""
        found = self.found({"docs/user/a.md": text}, "line-length")
        return [(v.start, v.detail) for v in found]

    @staticmethod
    def old_rule_count(text: str) -> int:
        """What the rule counted before it looked at reflow: the lines over the limit outside code and markers."""
        page = docmodel.parse("page.md", text)
        skipped = lintrules.unchecked_lines(page)
        return sum(1 for number, line in enumerate(page.lines, start=1)
                   if len(line) > lintrules.LINE_LIMIT and number not in skipped)

    def test_a_line_of_three_long_sentences_counts_three(self) -> None:
        text = " ".join([sentence(310), sentence(320), sentence(330)]) + "\n"
        # All three start on line 1, and each says that it shares the line.
        self.assertEqual(self.lines_of(text), [
            (1, "sentence of 310 characters on a line of 3 sentences, limit 300"),
            (1, "sentence of 320 characters on a line of 3 sentences, limit 300"),
            (1, "sentence of 330 characters on a line of 3 sentences, limit 300")])

    def test_a_long_line_of_short_sentences_counts_once(self) -> None:
        found = self.lines_of("Short one. " * 91 + "\n")
        self.assertEqual(len(found), 1)
        # The line as written is the larger count, so it keeps today's wording.
        self.assertTrue(found[0][1].endswith("characters, limit 300"))
        self.assertFalse(found[0][1].startswith("sentence"))

    def test_a_violation_is_at_the_line_its_sentence_starts(self) -> None:
        # Two lines are over the limit as written, three sentences are as reflow writes them.
        # The second and third start on line 2, a line of three sentences.
        text = f"{sentence(305)}\nTiny one. {sentence(306)} {sentence(307)}\n"
        self.assertEqual(self.lines_of(text), [
            (1, "sentence of 305 characters, limit 300"),
            (2, "sentence of 306 characters on a line of 3 sentences, limit 300"),
            (2, "sentence of 307 characters on a line of 3 sentences, limit 300")])

    def test_a_tie_keeps_the_line_as_written(self) -> None:
        # Two long lines as written, two long sentences reflowed: the counts tie, so today's report stands.
        text = f"{sentence(305)}\nTiny one. {sentence(306)}\n"
        self.assertEqual(self.lines_of(text), [(1, "305 characters, limit 300"), (2, "316 characters, limit 300")])

    def test_a_sentence_wrapped_over_lines_counts_at_its_first_line(self) -> None:
        # No line is over the limit as written, but the sentence on one line is.
        text = "Short one.\n" + wrapped(words_of(310))
        self.assertEqual(self.lines_of(text), [(2, "sentence of 310 characters, limit 300")])

    def test_a_list_items_later_sentences_have_the_items_indent(self) -> None:
        # A bullet's text starts at column 2, a numbered item's at column 3, and reflow
        # indents later sentences to it: 299 characters become 301, 298 become 301, 297 stay 300.
        for marker, length, counted in (("-", 299, 1), ("-", 298, 0), ("1.", 298, 1), ("1.", 297, 0)):
            with self.subTest(marker=marker, length=length):
                text = f"{marker} Short one.\n" + wrapped(words_of(length), "  ")
                self.assertEqual(len(self.lines_of(text)), counted)

    def test_a_paragraph_sentence_has_no_indent_to_add(self) -> None:
        text = "Short one.\n" + wrapped(words_of(300))
        self.assertEqual(self.lines_of(text), [])

    def test_a_list_paragraph_keeps_the_indent_of_its_first_line(self) -> None:
        # Each of the two sentences is 299 characters, and on its own line gets the two spaces: 301.
        text = f"- Item.\n\n  {sentence(299)} {sentence(299)}\n"
        self.assertEqual(len(self.lines_of(text)), 2)

    def test_a_block_reflow_leaves_alone_keeps_todays_rule(self) -> None:
        # A hard line break (two trailing spaces) keeps the block, so its one long line counts once.
        text = f"Short one.  \n{sentence(310)} {sentence(320)}\n"
        self.assertEqual(self.lines_of(text), [(2, "631 characters, limit 300")])

    def test_quotes_and_tables_keep_todays_rule(self) -> None:
        text = f"# T\n\n> {sentence(310)} {sentence(320)}\n\n| a | b |\n|---|---|\n| {sentence(310)} {sentence(320)} | x |\n"
        found = self.lines_of(text)
        self.assertEqual([line for line, _ in found], [3, 7])
        self.assertFalse(any(detail.startswith("sentence") for _, detail in found))

    def test_a_reflowed_page_counts_as_the_old_rule_did(self) -> None:
        text = (f"# T\n\n<!-- id: t; src: {'x' * 400} -->\n{sentence(310)}\n{sentence(250)}\n{sentence(301)}\n\n"
                f"- {sentence(300)}\n  {sentence(299)}\n\n```\n{'y' * 400}\n```\n")
        # Four lines are over 300 (the marker and the code are exempt), and reflow changes nothing.
        self.assertEqual(len(self.lines_of(text)), self.old_rule_count(text))
        self.assertEqual(reflow_text(text), text)

    def test_reflow_never_raises_the_count_of_any_page_of_the_repository(self) -> None:
        """For every page the lint covers (read only), the count after ``reflow_text`` is at most the page's own."""
        root = lintrules.SKILL_DIR.parents[2]
        if not (root / "docs").is_dir():
            self.skipTest("the repository's docs folder is not here")
        for path in docmodel.lint_pages(root):
            with self.subTest(page=path):
                text = pagewrite.read_page_text(root, path)
                before = len(lintrules.line_length_violations(docmodel.parse(path, text)))
                after_text = reflow_text(text)
                after = len(lintrules.line_length_violations(docmodel.parse(path, after_text)))
                self.assertLessEqual(after, before)
                # And a reflowed page counts as the old rule did: each long line once.
                self.assertEqual(after, self.old_rule_count(after_text))


class SectionLengthTests(RuleCase):
    """section-length: more than 40 lines from a heading to the section's last line."""

    def test_forty_lines_pass_and_forty_one_fail(self) -> None:
        forty = "# Forty\n" + "line\n" * 39
        forty_one = "# Over\n" + "line\n" * 40
        found = self.found({"docs/user/a.md": forty, "docs/user/b.md": forty_one}, "section-length")
        self.assertEqual(self.places(found), [("docs/user/b.md", 1, 41)])
        self.assertEqual(found[0].detail, "41 lines, limit 40")
        self.assertEqual(found[0].heading, "Over")

    def test_a_section_ends_at_its_last_nonblank_line(self) -> None:
        text = "# T\n\n## Long\n" + "line\n" * 38 + "\n\n\n## Next\n"
        self.assertEqual(self.found({"docs/user/a.md": text}, "section-length"), [])

    def test_log_pages_are_exempt(self) -> None:
        self.assertEqual(self.found({"docs/user/changelog.md": "# Log\n" + "line\n" * 60}, "section-length"), [])

    def test_heading_names_the_section(self) -> None:
        text = "# T\n\n## Big\n" + "line\n" * 45
        found = self.found({"docs/user/a.md": text}, "section-length")
        self.assertEqual(found[0].heading, "Big")


class PageSizeTests(RuleCase):
    """page-size: bytes over the page's limit, a kB being 1,000 bytes."""

    @staticmethod
    def of_bytes(count: int) -> str:
        """Text of exactly ``count`` bytes: short lines of ASCII."""
        text = ("x" * 99 + "\n") * (count // 100)
        return text + "y" * (count - len(text))

    def test_default_limit_is_40_kilobytes(self) -> None:
        found = self.found({"docs/user/a.md": self.of_bytes(40_000), "docs/user/b.md": self.of_bytes(40_001)}, "page-size")
        self.assertEqual(self.places(found), [("docs/user/b.md", 1, 1)])
        self.assertEqual(found[0].detail, "40,001 bytes, limit 40,000")

    def test_agents_and_claude_have_limits_of_their_own(self) -> None:
        files = {"AGENTS.md": self.of_bytes(12_001), "CLAUDE.md": self.of_bytes(3_001)}
        found = self.found(files, "page-size")
        self.assertEqual([(v.page, v.detail) for v in found], [
            ("AGENTS.md", "12,001 bytes, limit 12,000"), ("CLAUDE.md", "3,001 bytes, limit 3,000")])
        self.assertEqual(self.found({"AGENTS.md": self.of_bytes(12_000), "CLAUDE.md": self.of_bytes(3_000)}, "page-size"), [])

    def test_counts_bytes_not_characters(self) -> None:
        # 20,001 two-byte characters are 40,002 bytes.
        found = self.found({"docs/user/a.md": "é" * 20_001 + "\n"}, "page-size")
        self.assertEqual(len(found), 1)

    def test_log_pages_are_exempt(self) -> None:
        self.assertEqual(self.found({"docs/agents/history.md": self.of_bytes(50_000)}, "page-size"), [])


class DateTests(RuleCase):
    """date: dates in prose, outside logs, code, and file names."""

    def dates(self, text: str, path: str = "docs/user/a.md") -> List[str]:
        """The dates found in ``text`` placed on one page, as the detail's date text."""
        return [v.detail.removeprefix("date ") for v in self.found({path: text}, "date")]

    def test_iso_dates(self) -> None:
        self.assertEqual(self.dates("Made on 2026-10-12, then 2026-11-01.\n"), ["2026-10-12", "2026-11-01"])

    def test_month_name_dates(self) -> None:
        text = ("October 12 and Oct. 12, 2026 and 12 October 2026 and October 2026 and May 5th "
                "and Sept 3 and 3rd March.\n")
        self.assertEqual(self.dates(text), [
            "October 12", "Oct. 12, 2026", "12 October 2026", "October 2026", "May 5th", "Sept 3", "3rd March"])

    def test_the_date_is_one_violation_at_its_line(self) -> None:
        found = self.found({"docs/user/a.md": "# T\n\nfirst\non Oct. 12, 2026 it\n"}, "date")
        self.assertEqual(self.places(found), [("docs/user/a.md", 4, 4)])
        self.assertEqual(found[0].detail, "date Oct. 12, 2026")

    def test_not_dates(self) -> None:
        text = ("october 12 and may I ask, 12 ounces, March is a month, Dec alone, 2026-13-45, 1234-56-78, "
                "version 12 of 2026, Mayor 5, Marching 12.\n")
        self.assertEqual(self.dates(text), [])

    def test_a_date_in_a_path_like_name_is_not_counted(self) -> None:
        text = ("See TODO-2026-09-04.md and AGENT-NOTES-2026-10-04.md, the folder briefs/2026-11-14/, "
                "[the log](TODO-2026-09-04.md), and Scripts/agents/briefs/2026-11-14/doclib/lint.md.\n")
        self.assertEqual(self.dates(text), [])

    def test_a_date_beside_a_sentence_end_is_counted(self) -> None:
        self.assertEqual(self.dates("It was fixed on 2026-10-12.\nOr (2026-10-13) or 2026-10-14: fixed.\n"),
                         ["2026-10-12", "2026-10-13", "2026-10-14"])

    def test_code_blocks_code_spans_and_link_destinations_are_not_prose(self) -> None:
        text = ("`October 12` and [note](notes/October-12 2026-10-12.md)\n\n```\nOctober 12, 2026\n```\n\n"
                "<!-- October 12 -->\n")
        self.assertEqual(self.dates(text), [])

    def test_headings_lists_and_tables_are_prose(self) -> None:
        text = "# Since October 12\n\n- listed 2026-10-12\n\n| a | b |\n| - | - |\n| May 5 | x |\n"
        self.assertEqual(len(self.dates(text)), 3)

    def test_log_pages_are_exempt_and_other_lint_pages_are_not(self) -> None:
        files = {"docs/user/changelog.md": "October 12\n", "docs/agents/history.md": "2026-10-12\n",
                 "README.md": "October 12\n", "AGENTS.md": "October 12\n", "research/R.md": "October 12\n"}
        found = self.found(files, "date")
        self.assertEqual(sorted(v.page for v in found), ["AGENTS.md", "README.md"])


class UserQuoteTests(RuleCase):
    """user-quote: long double-quoted spans on a line that holds the word user."""

    def quotes(self, text: str, path: str = "docs/user/a.md") -> List[Violation]:
        """The user-quote violations of ``text`` on one page."""
        return self.found({path: text}, "user-quote")

    def test_six_words_beside_user(self) -> None:
        found = self.quotes('The user said "please add this to the list" today.\n')
        self.assertEqual(self.places(found), [("docs/user/a.md", 1, 1)])
        self.assertEqual(found[0].detail, "quotation of 6 words beside the word user")

    def test_five_words_pass(self) -> None:
        self.assertEqual(self.quotes('The user said "please add this one thing" today.\n'), [])

    def test_exactly_six_words_fail(self) -> None:
        self.assertEqual(len(self.quotes('The user said "please add this to the list" today.\n')), 1)

    def test_curly_quotes_and_any_case(self) -> None:
        self.assertEqual(len(self.quotes("USER asked: “one two three four five six”.\n")), 1)

    def test_no_user_on_the_line_passes(self) -> None:
        self.assertEqual(self.quotes('The screen says "one two three four five six seven".\n'), [])

    def test_the_word_must_stand_alone(self) -> None:
        self.assertEqual(self.quotes('A username said "one two three four five six seven".\n'), [])

    def test_each_long_span_counts_and_punctuation_is_not_a_word(self) -> None:
        text = 'The user said "a b c d e f" and "g h i j k l" and "- - - - - - -".\n'
        self.assertEqual(len(self.quotes(text)), 2)

    def test_a_quote_inside_code_is_ignored(self) -> None:
        self.assertEqual(self.quotes('The user ran `say "one two three four five six"`.\n'), [])

    def test_log_pages_are_exempt(self) -> None:
        self.assertEqual(self.quotes('The user said "one two three four five six".\n', "docs/user/changelog.md"), [])


class SalesWordTests(RuleCase):
    """sales-word: the words of sales-words.txt, in prose, ignoring case."""

    def test_the_word_list_file(self) -> None:
        words = lintrules.load_sales_words()
        self.assertEqual(len(words), 18)
        self.assertIn("state-of-the-art", words)
        self.assertFalse(any(word.startswith("#") for word in words))

    def test_words_are_found_ignoring_case(self) -> None:
        found = self.found({"docs/user/a.md": "A Seamless, POWERFUL tool; it works seamlessly.\n"}, "sales-word")
        self.assertEqual([v.detail for v in found], ["sales word seamless", "sales word powerful", "sales word seamlessly"])

    def test_hyphenated_words(self) -> None:
        found = self.found({"docs/user/a.md": "Cutting-edge and state-of-the-art.\n"}, "sales-word")
        self.assertEqual(len(found), 2)

    def test_only_whole_words_count(self) -> None:
        self.assertEqual(self.found({"docs/user/a.md": "Its robustness and a stunningly odd comprehensiveness.\n"}, "sales-word"), [])

    def test_code_and_link_destinations_are_not_prose(self) -> None:
        text = "`robust` and [x](robust.md) and https://example.com/stunning\n\n```\nrobust\n```\n"
        self.assertEqual(self.found({"docs/user/a.md": text, "robust.md": "x\n"}, "sales-word"), [])

    def test_applies_to_logs_and_not_to_pages_outside_the_lint(self) -> None:
        files = {"docs/user/changelog.md": "A delightful change.\n", "research/R.md": "A delightful change.\n"}
        self.assertEqual([v.page for v in self.found(files, "sales-word")], ["docs/user/changelog.md"])


class BrokenLinkTests(RuleCase):
    """broken-link: link, image, and reference destinations that resolve to nothing."""

    FILES = {
        "docs/user/a.md": "# A\n\n## Sub section\n",
        "docs/user/b.md": "# B\n\n## Other part\n",
        "docs/developer/c.md": "# C\n",
        "TextMouth/App.swift": "// code\n",
        "Scripts/x.sh": "echo\n",
    }

    def problems(self, body: str, path: str = "docs/user/a.md") -> List[Tuple[int, str]]:
        """The ``(line, detail)`` of each broken link in ``body`` placed in page ``path``."""
        files = dict(self.FILES)
        files[path] = body
        return [(v.start, v.detail) for v in self.found(files, "broken-link")]

    def test_good_links_pass(self) -> None:
        body = ("# A\n\n## Sub section\n\n"
                "[b](b.md) [c](../developer/c.md) [code](../../TextMouth/App.swift) [folder](../developer/) "
                "[folder2](../developer) [root](/Scripts/x.sh) [anchor](#sub-section) [upper](#Sub-Section) "
                "[other](b.md#other-part) [web](https://example.com/x.md) [mail](mailto:a@b.c) "
                "[titled](b.md \"The title\") [angle](<b.md>) ![img](../../Scripts/x.sh) [file anchor](../../Scripts/x.sh#L10)\n")
        self.assertEqual(self.problems(body), [])

    def test_a_missing_file(self) -> None:
        self.assertEqual(self.problems("# A\n\n[x](nope.md)\n"), [(3, "docs/user/nope.md does not exist")])

    def test_a_missing_image(self) -> None:
        self.assertEqual(self.problems("# A\n\nan ![alt](img/p.png) here\n"), [(3, "docs/user/img/p.png does not exist")])

    def test_a_missing_heading_on_the_page(self) -> None:
        self.assertEqual(self.problems("# A\n\n[x](#nowhere)\n"), [(3, "no heading for #nowhere")])

    def test_a_missing_heading_on_another_page(self) -> None:
        self.assertEqual(self.problems("# A\n\n[x](b.md#nowhere)\n"), [(3, "no heading for #nowhere in docs/user/b.md")])

    def test_a_link_out_of_the_repository(self) -> None:
        self.assertEqual(self.problems("# A\n\n[x](../../../etc/hosts)\n"), [(3, "../../../etc/hosts leaves the repository")])

    def test_a_home_path_is_just_a_missing_file_and_is_never_opened(self) -> None:
        self.assertEqual(self.problems("# A\n\n[x](~/.TextMouth/library.json)\n"),
                         [(3, "docs/user/~/.TextMouth/library.json does not exist")])

    def test_a_reference_definition(self) -> None:
        body = "# A\n\n[good]: b.md\n[bad]: gone.md \"Title\"\n[web]: https://example.com\n"
        self.assertEqual(self.problems(body), [(4, "docs/user/gone.md does not exist")])

    def test_percent_encoding_and_queries(self) -> None:
        files = dict(self.FILES, **{"docs/user/with space.md": "# S\n", "docs/user/a.md": "# A\n\n[x](with%20space.md) [y](b.md?plain=1)\n"})
        self.assertEqual(self.found(files, "broken-link"), [])

    def test_links_in_code_are_not_links(self) -> None:
        self.assertEqual(self.problems("# A\n\n`[x](gone.md)`\n\n```\n[x](gone.md)\n```\n"), [])

    def test_a_link_on_a_later_line_of_a_paragraph(self) -> None:
        self.assertEqual(self.problems("# A\n\nfirst line\nsecond [x](gone.md) line\n"), [(4, "docs/user/gone.md does not exist")])

    def test_checks_every_lint_page_including_logs_and_indexes(self) -> None:
        files = {"README.md": "[x](gone.md)\n", "docs/user/changelog.md": "[x](gone.md)\n", "research/R.md": "[x](gone.md)\n"}
        self.assertEqual(sorted(v.page for v in self.found(files, "broken-link")), ["README.md", "docs/user/changelog.md"])

    def test_an_anchor_in_a_page_that_is_not_a_lint_page(self) -> None:
        files = {"README.md": "[ok](research/R.md#part) [bad](research/R.md#gone)\n", "research/R.md": "# R\n\n## Part\n"}
        self.assertEqual([v.detail for v in self.found(files, "broken-link")], ["no heading for #gone in research/R.md"])

    def test_repeated_headings_get_github_numbers(self) -> None:
        files = {"docs/user/a.md": "# A\n\n## Same\n\n## Same\n\n[x](#same) [y](#same-1) [z](#same-2)\n"}
        self.assertEqual([v.detail for v in self.found(files, "broken-link")], ["no heading for #same-2"])


class IndexLinkTests(RuleCase):
    """index-link: each page under docs/ linked from the index pages exactly once."""

    def test_once_passes_and_other_counts_fail(self) -> None:
        files = {
            "README.md": "- [A](docs/user/a.md)\n- [B](docs/user/b.md)\n- [B again](docs/user/b.md#top)\n",
            "ARCHITECTURE.md": "- [C](docs/architecture/c.md)\n",
            "docs/user/a.md": "# A\n", "docs/user/b.md": "# B\n", "docs/user/d.md": "# D\n",
            "docs/architecture/c.md": "# C\n",
        }
        found = self.found(files, "index-link")
        self.assertEqual(self.places(found), [("docs/user/b.md", 1, 1), ("docs/user/d.md", 1, 1)])
        self.assertEqual(found[0].detail, "linked from the index pages 2 times, not once: README.md:2, README.md:3")
        self.assertEqual(found[1].detail, "linked from the index pages 0 times, not once")

    def test_the_two_index_pages_count_together(self) -> None:
        files = {"README.md": "- [A](docs/user/a.md)\n", "ARCHITECTURE.md": "- [A](docs/user/a.md)\n", "docs/user/a.md": "# A\n"}
        self.assertEqual(len(self.found(files, "index-link")), 1)

    def test_only_pages_under_docs_are_counted_and_links_from_other_pages_do_not_count(self) -> None:
        files = {"README.md": "- [Agents](AGENTS.md)\n", "AGENTS.md": "[A](docs/user/a.md)\n", "docs/user/a.md": "# A\n",
                 "research/R.md": "# R\n"}
        self.assertEqual(self.places(self.found(files, "index-link")), [("docs/user/a.md", 1, 1)])

    def test_log_pages_must_be_linked_too(self) -> None:
        files = {"README.md": "- [x](docs/user/a.md)\n", "docs/user/a.md": "# A\n", "docs/user/changelog.md": "# C\n"}
        self.assertEqual(self.places(self.found(files, "index-link")), [("docs/user/changelog.md", 1, 1)])

    def test_links_with_schemes_do_not_count(self) -> None:
        files = {"README.md": "- [a](https://example.com/docs/user/a.md)\n", "docs/user/a.md": "# A\n"}
        self.assertEqual(len(self.found(files, "index-link")), 1)


class IndexLineTests(RuleCase):
    """index-line: index list items start with a link and run at most 12 words."""

    def lines(self, text: str, path: str = "README.md") -> List[Violation]:
        """The index-line violations of ``text`` placed in page ``path``."""
        return self.found({path: text}, "index-line")

    def test_a_link_and_a_few_words_pass(self) -> None:
        self.assertEqual(self.lines("- [Title here](docs/a.md): what it holds.\n* [Other](docs/b.md)\n1. [Third](docs/c.md)\n"), [])

    def test_twelve_words_pass_and_thirteen_fail(self) -> None:
        twelve = "- [One two](docs/a.md): three four five six seven eight nine ten eleven twelve\n"
        thirteen = "- [One two](docs/a.md): three four five six seven eight nine ten eleven twelve thirteen\n"
        self.assertEqual(self.lines(twelve), [])
        found = self.lines(thirteen)
        self.assertEqual((found[0].start, found[0].detail), (1, "13 words, limit 12"))

    def test_syntax_is_not_a_word(self) -> None:
        # The destination, dashes, backticks, and stars are not words; the code's content is.
        text = "- [One](docs/a-very-long-destination.md) - **two** `three four` - five six seven eight nine ten eleven\n"
        self.assertEqual(self.lines(text), [])

    def test_a_link_inside_the_line_counts_its_text(self) -> None:
        text = "- [A](docs/a.md): see [the second page with many words in it](docs/b.md) and then more words\n"
        self.assertEqual(self.lines(text)[0].detail, "14 words, limit 12")

    def test_an_item_that_does_not_start_with_a_link(self) -> None:
        found = self.lines("- Plain text here\n- text [Late](docs/a.md)\n- [Good](docs/a.md)\n")
        self.assertEqual([(v.start, v.detail) for v in found], [(1, "does not start with a link"), (2, "does not start with a link")])

    def test_both_problems_are_one_violation(self) -> None:
        found = self.lines("- " + "word " * 14 + "\n")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].detail, "does not start with a link; 14 words, limit 12")

    def test_a_wrapped_item_is_one_item_with_its_lines(self) -> None:
        found = self.lines("- [A](docs/a.md): one two three four\n  five six seven eight\n  nine ten eleven twelve\n")
        self.assertEqual((found[0].start, found[0].end), (1, 3))

    def test_other_pages_and_paragraphs_are_not_checked(self) -> None:
        files = {"docs/user/a.md": "- plain item\n", "AGENTS.md": "- plain item\n"}
        self.assertEqual(self.found(files, "index-line"), [])
        self.assertEqual(self.lines("Intro paragraph that is not a list and runs on for many many many many words in a row.\n"), [])

    def test_architecture_md_is_an_index_page(self) -> None:
        self.assertEqual(len(self.lines("- plain item\n", "ARCHITECTURE.md")), 1)


class MarkerRuleTests(RuleCase):
    """marker-missing, marker-invalid, marker-duplicate-id, and marker-src."""

    def test_missing_on_every_section_of_a_reference_page(self) -> None:
        text = "# Top\n\ntext\n\n## One\n<!-- id: one -->\n\n### Deep\n\ntext\n"
        found = self.found({"docs/architecture/a.md": text}, "marker-missing")
        self.assertEqual([(v.start, v.heading, v.detail) for v in found], [
            (1, "Top", "no marker under the heading"), (8, "One > Deep", "no marker under the heading")])

    def test_each_reference_folder_is_checked_and_nothing_else(self) -> None:
        text = "# T\n\ntext\n"
        pages = ["docs/user/a.md", "docs/developer/a.md", "docs/architecture/a.md", "docs/architecture/state/a.md", "docs/agents/a.md"]
        exempt = ["docs/user/changelog.md", "docs/agents/history.md", "docs/other/a.md", "README.md", "ARCHITECTURE.md", "AGENTS.md", "CLAUDE.md"]
        found = self.found({path: text for path in pages + exempt}, "marker-missing")
        self.assertEqual(sorted(v.page for v in found), sorted(pages))

    def test_a_marker_after_text_is_stray_and_the_heading_still_lacks_one(self) -> None:
        text = "# T\n\ntext\n<!-- id: late -->\n"
        self.assertEqual(len(self.found({"docs/user/a.md": text}, "marker-missing")), 1)
        found = self.found({}, "marker-invalid")
        self.assertEqual([(v.start, v.detail) for v in found], [(4, "stray marker: not the first line under a heading")])

    def test_a_marker_above_the_first_heading_is_stray(self) -> None:
        found = self.found({"docs/user/a.md": "<!-- id: top -->\n# T\n"}, "marker-invalid")
        self.assertEqual([v.start for v in found], [1])

    def test_invalid_markers(self) -> None:
        text = ("# T\n\n<!-- id: Bad_Id; keys: a; colour: red -->\n\n## U\n\n<!-- id: ok; keys: 1, 2, 3, 4, 5, 6, 7, 8, 9 -->\n\n"
                "## V\n\n<!-- id: eight; keys: 1, 2, 3, 4, 5, 6, 7, 8 -->\n")
        found = self.found({"docs/user/a.md": text}, "marker-invalid")
        self.assertEqual([(v.start, v.detail) for v in found], [
            (3, "id not lowercase words joined by hyphens: 'Bad_Id'; unknown field: 'colour'"),
            (7, "9 keys, limit 8")])

    def test_invalid_markers_are_checked_on_every_lint_page(self) -> None:
        found = self.found({"AGENTS.md": "# T\n\n<!-- id: Bad -->\n", "docs/user/changelog.md": "# L\n\n<!-- id: Bad -->\n"}, "marker-invalid")
        self.assertEqual(sorted(v.page for v in found), ["AGENTS.md", "docs/user/changelog.md"])

    def test_duplicate_ids_across_pages(self) -> None:
        files = {"docs/user/a.md": marked("same"), "docs/user/b.md": marked("same") + "\n## More\n<!-- id: other -->\n",
                 "docs/user/c.md": marked("unique")}
        found = self.found(files, "marker-duplicate-id")
        self.assertEqual(self.places(found), [("docs/user/a.md", 3, 3), ("docs/user/b.md", 3, 3)])
        self.assertEqual(found[0].detail, "id same is also at docs/user/b.md:3")

    def test_duplicate_ids_within_a_page(self) -> None:
        text = "# T\n\n<!-- id: x -->\n\n## U\n\n<!-- id: x -->\n"
        self.assertEqual(len(self.found({"docs/user/a.md": text}, "marker-duplicate-id")), 2)

    def test_src_entries_that_exist_pass(self) -> None:
        files = {"docs/user/a.md": "# T\n\n<!-- id: a; src: TextMouth/Parsers/EPUBParser.swift, Parsers/Other.swift, Scripts/, Makefile -->\n",
                 "TextMouth/Parsers/EPUBParser.swift": "x\n", "TextMouth/Parsers/Other.swift": "x\n",
                 "Scripts/run.sh": "x\n", "Makefile": "x\n"}
        self.assertEqual(self.found(files, "marker-src"), [])

    def test_src_entries_that_name_nothing_fail(self) -> None:
        files = {"docs/user/a.md": "# T\n\n<!-- id: a; src: Gone.swift, Scripts/*.sh, /etc/hosts, ~/x, TextMouth/Real.swift -->\n",
                 "TextMouth/Real.swift": "x\n"}
        found = self.found(files, "marker-src")
        self.assertEqual([v.detail for v in found], [
            "src Gone.swift does not exist", "src Scripts/*.sh does not exist", "src /etc/hosts does not exist", "src ~/x does not exist"])
        self.assertEqual({v.start for v in found}, {3})


class StaleRuleTests(RuleCase):
    """stale: what stale_items finds, less marker src entries (marker-src's) and log pages."""

    # A repository with one Swift type, so a backticked name can be known or not.
    SWIFT = {"TextMouth/Models/Book.swift": "struct Book {}\n"}

    def test_a_missing_path_and_an_unknown_name_are_counted(self) -> None:
        body = "It reads `TextMouth/Models/Gone.swift` and `Book`, and `Vanished` too."
        files = dict(self.SWIFT, **{"docs/user/a.md": marked("a", body)})
        found = self.found(files, "stale")
        self.assertEqual([v.detail for v in found],
                         ["missing path: TextMouth/Models/Gone.swift", "unknown name: Vanished"])
        self.assertEqual({v.start for v in found}, {4})

    def test_a_missing_marker_src_is_marker_srcs_not_stales(self) -> None:
        page = "# Title\n\n<!-- id: a; src: TextMouth/Models/Gone.swift -->\nText.\n"
        files = dict(self.SWIFT, **{"docs/user/a.md": page})
        self.assertEqual(self.found(files, "stale"), [])
        self.assertEqual([v.rule for v in self.found(files, "marker-src")], ["marker-src"])

    def test_a_log_page_may_name_what_was_removed(self) -> None:
        files = dict(self.SWIFT, **{"docs/user/changelog.md": "# Changelog\n\nRemoved `TextMouth/Models/Gone.swift`.\n"})
        self.assertEqual(self.found(files, "stale"), [])


class DuplicateHeadingTests(RuleCase):
    """duplicate-heading: a title that repeats an earlier heading of the page."""

    def test_repeats_ignoring_case_markup_and_level(self) -> None:
        text = "# Top\n\n## Open `Book`\n\n## open book\n\n### **Open** [Book](x.md)\n\n## Different\n"
        found = self.found({"docs/user/a.md": text}, "duplicate-heading")
        self.assertEqual([(v.start, v.detail) for v in found], [(5, "same heading as line 3"), (7, "same heading as line 3")])

    def test_the_same_title_on_another_page_is_fine(self) -> None:
        files = {"docs/user/a.md": "# T\n\n## Same\n", "docs/user/b.md": "# T\n\n## Same\n"}
        self.assertEqual(self.found(files, "duplicate-heading"), [])

    def test_headings_in_code_are_not_headings(self) -> None:
        self.assertEqual(self.found({"docs/user/a.md": "# T\n\n```\n# T\n```\n"}, "duplicate-heading"), [])

    def test_log_pages_are_exempt(self) -> None:
        self.assertEqual(self.found({"docs/user/changelog.md": "# T\n\n## Same\n\n## Same\n"}, "duplicate-heading"), [])


class SentencesPerLineTests(RuleCase):
    """sentences-per-line: prose lines that hold more than one sentence."""

    def lines(self, text: str, path: str = "docs/user/a.md") -> List[Violation]:
        """The sentences-per-line violations of ``text`` placed in page ``path``."""
        return self.found({path: text}, "sentences-per-line")

    def test_two_sentences_on_a_line(self) -> None:
        found = self.lines("# T\n\nOne is here. Two is here.\nA single sentence.\n")
        self.assertEqual([(v.start, v.detail) for v in found], [(3, "2 sentences on one line")])

    def test_list_markers_and_quote_marks_are_not_text(self) -> None:
        text = "- One. Two.\n1. Three. Four.\n   - Nested. Pair.\n> Quoted. Twice.\n> - Listed. Quote.\n- Fine.\n"
        self.assertEqual([v.start for v in self.lines(text)], [1, 2, 3, 4, 5])

    def test_list_paragraphs_and_continuation_lines(self) -> None:
        text = "- Item one.\n  Item continues here. And again.\n\n  Para. Graph.\n"
        self.assertEqual([v.start for v in self.lines(text)], [2, 4])

    def test_one_sentence_over_two_lines_is_fine(self) -> None:
        self.assertEqual(self.lines("A sentence that goes on\nand finishes here.\n"), [])

    def test_abbreviations_code_links_and_urls_do_not_split(self) -> None:
        text = ("Use e.g. the tool, i.e. this one, etc. Then `a. B` and [x](a.b/c. D) here.\n"
                "Version 0.4.10 and Mr. Smith came.\n")
        self.assertEqual(self.lines(text), [])

    def test_code_tables_headings_and_comments_are_not_checked(self) -> None:
        text = "# One. Two.\n\n```\nOne. Two.\n```\n\n| One. Two. | x |\n| - | - |\n\n<!-- One. Two. -->\n\n    One. Two.\n"
        self.assertEqual(self.lines(text), [])

    def test_log_pages_are_exempt_and_index_pages_are_not(self) -> None:
        self.assertEqual(self.lines("One. Two.\n", "docs/user/changelog.md"), [])
        self.assertEqual(len(self.lines("One. Two.\n", "README.md")), 1)


class EmojiTests(RuleCase):
    """emoji: the listed ranges, outside code; braille and arrows are fine."""

    def emoji(self, text: str, path: str = "docs/user/a.md") -> List[Violation]:
        """The emoji violations of ``text`` placed in page ``path``."""
        return self.found({path: text}, "emoji")

    def test_each_range(self) -> None:
        characters = ["\U0001F600", "\U0001FA70", "✅", "❤", "➿", "⬅", "⬛", "⭐", "⭕", "️"]
        found = self.emoji("# T\n\n" + " ".join(characters) + "\n")
        self.assertEqual([v.detail for v in found], [f"emoji U+{ord(c):04X}" for c in characters])
        self.assertTrue(all(v.start == 3 for v in found))

    def test_braille_cells_and_arrows_are_not_emoji(self) -> None:
        self.assertEqual(self.emoji("Dots ⠀ ⠃ ⣿ and arrows → ← ⇒ and é — “ done.\n"), [])

    def test_code_is_exempt_but_other_blocks_are_not(self) -> None:
        text = "`✅` and\n\n```\n✅\n```\n\n    ✅\n\n<!-- ✅ -->\n\n> ✅\n\n| ✅ |\n"
        self.assertEqual([v.start for v in self.emoji(text)], [9, 11, 13])

    def test_logs_are_checked_and_pages_outside_the_lint_are_not(self) -> None:
        files = {"docs/user/changelog.md": "✅\n", "research/R.md": "✅\n"}
        self.assertEqual([v.page for v in self.found(files, "emoji")], ["docs/user/changelog.md"])


class LintRunTests(RuleCase):
    """lint(): the rule list, the choice of rules, and the order of the result."""

    def test_the_rules_in_order(self) -> None:
        self.assertEqual(lintrules.rule_names(), [
            "line-length", "section-length", "page-size", "date", "user-quote", "sales-word", "broken-link",
            "index-link", "index-line", "marker-missing", "marker-invalid", "marker-duplicate-id", "marker-src",
            "stale", "duplicate-heading", "sentences-per-line", "emoji"])

    def test_rules_can_be_chosen(self) -> None:
        self.write_tree({"docs/user/a.md": "# T\n\nOne. Two. On October 12.\n"})
        self.assertEqual({v.rule for v in lintrules.lint(self.root)} >= {"date", "sentences-per-line", "marker-missing"}, True)
        self.assertEqual({v.rule for v in lintrules.lint(self.root, ["date"])}, {"date"})
        self.assertEqual(lintrules.lint(self.root, []), [])

    def test_an_unknown_rule_is_a_usage_error_naming_the_rules(self) -> None:
        self.write_tree({"docs/user/a.md": "# T\n"})
        with self.assertRaises(output.UsageError) as caught:
            lintrules.lint(self.root, ["date", "nonsense"])
        self.assertIn("unknown rule 'nonsense'", str(caught.exception))
        self.assertIn("line-length", str(caught.exception))

    def test_results_come_in_rule_then_page_then_line_order(self) -> None:
        files = {"docs/user/b.md": "On October 12. And October 13.\n", "docs/user/a.md": "x\nOctober 14.\n" + "a" * 301 + "\n"}
        found = [(v.rule, v.page, v.start) for v in self.found(files, "date", "line-length")]
        self.assertEqual(found, [("line-length", "docs/user/a.md", 3), ("date", "docs/user/a.md", 2),
                                 ("date", "docs/user/b.md", 1), ("date", "docs/user/b.md", 1)])

    def test_a_violation_names_its_section(self) -> None:
        found = self.found({"docs/user/a.md": "# T\n\n## Part\n\nOn October 12.\n"}, "date")
        self.assertEqual(found[0].heading, "Part")

    def test_a_repository_with_no_docs_has_no_violations(self) -> None:
        self.assertEqual(self.found({"other/readme.txt": "x\n"}), [])
