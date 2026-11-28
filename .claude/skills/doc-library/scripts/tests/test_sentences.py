"""Tests of sentences.py: the sentence splitter, protected spans, and code spans."""

from __future__ import annotations

import random
from typing import List

from doclib_case import DocLibCase

from sentences import ABBREVIATIONS, code_spans, protected_spans, split_sentences


def sentences(text: str) -> List[str]:
    """The sentences of ``text`` as strings."""
    return [text[start:end] for start, end in split_sentences(text)]


class SplitTests(DocLibCase):
    """split_sentences() on the cases the brief names, then on edge cases."""

    def check(self, text: str, *expected: str) -> None:
        """``text`` splits into exactly ``expected``."""
        self.assertEqual(sentences(text), list(expected))

    def test_two_plain_sentences(self) -> None:
        self.check("One. Two.", "One.", "Two.")

    def test_question_and_exclamation_end_sentences(self) -> None:
        self.check("It works? Yes! Fine.", "It works?", "Yes!", "Fine.")

    def test_abbreviation_does_not_end_a_sentence(self) -> None:
        self.check("Use e.g. this one. Next.", "Use e.g. this one.", "Next.")

    def test_abbreviation_before_a_capital_does_not_end_a_sentence(self) -> None:
        self.check("At 8:00 a.m. Eastern it resets. Then.", "At 8:00 a.m. Eastern it resets.", "Then.")

    def test_abbreviations_are_case_insensitive(self) -> None:
        self.check("Ask Dr. Smith. Done.", "Ask Dr. Smith.", "Done.")
        self.check("Fruit, nuts, ETC. Next.", "Fruit, nuts, ETC. Next.")

    def test_every_listed_abbreviation_holds_a_sentence_together(self) -> None:
        for word in sorted(ABBREVIATIONS):
            with self.subTest(word=word):
                self.assertEqual(len(sentences(f"Word {word}. Then more.")), 1)

    def test_version_number_ends_a_sentence(self) -> None:
        self.check("Version 0.4.10. The next.", "Version 0.4.10.", "The next.")

    def test_file_name_ends_a_sentence(self) -> None:
        self.check("Edit imports.md. Then build.", "Edit imports.md.", "Then build.")

    def test_digit_starts_a_sentence(self) -> None:
        self.check("macOS 26. 12 books.", "macOS 26.", "12 books.")

    def test_closing_emphasis_belongs_to_its_sentence(self) -> None:
        self.check("**Bold one.** Plain two.", "**Bold one.**", "Plain two.")

    def test_closing_parenthesis_belongs_to_its_sentence(self) -> None:
        self.check("(See X.) Next.", "(See X.)", "Next.")

    def test_closing_quote_belongs_to_its_sentence(self) -> None:
        self.check('He said "go." Then left.', 'He said "go."', "Then left.")

    def test_curly_quotes_close_a_sentence(self) -> None:
        self.check("He said “go.” Then left.", "He said “go.”", "Then left.")

    def test_inline_code_protects_its_period(self) -> None:
        self.check("Run `make check. Now` first. Done.", "Run `make check. Now` first.", "Done.")

    def test_link_destination_is_protected_but_link_text_is_not(self) -> None:
        self.check("See [x](a. B.md) now. Next.", "See [x](a. B.md) now.", "Next.")
        self.check("See [one. Two](a.md) now.", "See [one.", "Two](a.md) now.")

    def test_link_destination_with_nested_parentheses(self) -> None:
        self.check("See [x](a_(b). C.md) now. Next.", "See [x](a_(b). C.md) now.", "Next.")

    def test_bare_url_ending_a_sentence_still_ends_it(self) -> None:
        self.check("See https://example.com/a.b. Next.", "See https://example.com/a.b.", "Next.")

    def test_bare_url_keeps_its_inner_periods(self) -> None:
        self.check("Go to https://example.com/a. B/c now. Next.", "Go to https://example.com/a.", "B/c now.", "Next.")

    def test_ellipsis_does_not_end_a_sentence(self) -> None:
        self.check("Wait... What now.", "Wait... What now.")

    def test_initials_do_not_end_a_sentence(self) -> None:
        self.check("J. R. Tolkien wrote it. Next.", "J. R. Tolkien wrote it.", "Next.")
        self.check("J.R. Tolkien wrote it. Next.", "J.R. Tolkien wrote it.", "Next.")

    def test_a_letter_after_a_hyphen_ends_a_sentence(self) -> None:
        self.check("Press Command-F. Type a word.", "Press Command-F.", "Type a word.")

    def test_lowercase_after_a_question_mark_does_not_split(self) -> None:
        self.check("Where Am I? opens it.", "Where Am I? opens it.")

    def test_no_space_after_the_period_does_not_split(self) -> None:
        self.check("Ends with no space.Next", "Ends with no space.Next")

    def test_a_newline_counts_as_white_space(self) -> None:
        self.check("One.\nTwo on a new line.", "One.", "Two on a new line.")

    def test_code_span_starts_a_sentence(self) -> None:
        self.check("One. `code` starts two.", "One.", "`code` starts two.")

    def test_html_comment_is_protected(self) -> None:
        self.check("<!-- a. B --> text. Next.", "<!-- a. B --> text.", "Next.")

    def test_autolink_is_protected(self) -> None:
        self.check("Mail <mailto:a.b@x.org> now. Next.", "Mail <mailto:a.b@x.org> now.", "Next.")

    def test_leading_and_trailing_space_is_dropped(self) -> None:
        self.check("  Leading and trailing.  ", "Leading and trailing.")

    def test_empty_and_blank_text_have_no_sentences(self) -> None:
        self.check("")
        self.check(" \n ")

    def test_unclosed_backticks_protect_nothing(self) -> None:
        self.check("A ` tick. Next one.", "A ` tick.", "Next one.")

    def test_text_without_a_terminator_is_one_sentence(self) -> None:
        self.check("no terminator at all", "no terminator at all")


class InvariantTests(DocLibCase):
    """Properties that hold for any text, checked on generated texts."""

    # Pieces that exercise every rule when glued together at random.
    PIECES = [
        "One", "two", "Three", "J.", "R.", "e.g.", "a.m.", "etc.", "...", ". ", "! ", "? ", ".", " ", "  ", "\n",
        "`", "``", "`code. Here`", "](", ")", "(", "[", "]", "<!--", "-->", "<", ">", "https://x.org/a.b.", "*", "_",
        '"', "'", "”", "1", "12", "Dr.", "U.S.", "-", "F.", " ",
    ]

    def generated(self, seed: int) -> str:
        """A random text glued from PIECES."""
        rng = random.Random(seed)
        return "".join(rng.choice(self.PIECES) for _ in range(rng.randint(0, 40)))

    def test_spans_cover_every_non_space_character_exactly_once(self) -> None:
        for seed in range(2000):
            text = self.generated(seed)
            spans = split_sentences(text)
            covered = [0] * len(text)
            previous_end = 0
            for start, end in spans:
                # Increasing, non-overlapping, and trimmed to non-space characters.
                self.assertLess(start, end, (seed, text))
                self.assertGreaterEqual(start, previous_end, (seed, text))
                self.assertFalse(text[start].isspace(), (seed, text))
                self.assertFalse(text[end - 1].isspace(), (seed, text))
                for position in range(start, end):
                    covered[position] += 1
                previous_end = end
            for position, char in enumerate(text):
                # Space is covered once inside a sentence or not at all between two.
                if not char.isspace():
                    self.assertEqual(covered[position], 1, (seed, text))

    def test_no_sentence_ends_inside_a_protected_span(self) -> None:
        for seed in range(2000):
            text = self.generated(seed)
            protected = protected_spans(text)
            for _, end in split_sentences(text)[:-1]:
                for start, stop in protected:
                    self.assertFalse(start < end < stop, (seed, text, end))


class ProtectedSpanTests(DocLibCase):
    """protected_spans() and code_spans() on their own."""

    def spans(self, text: str) -> List[str]:
        """The protected spans of ``text`` as strings."""
        return [text[start:end] for start, end in protected_spans(text)]

    def test_inline_code(self) -> None:
        self.assertEqual(self.spans("a `b. C` d"), ["`b. C`"])

    def test_double_backticks_hold_a_single_one(self) -> None:
        self.assertEqual(self.spans("a ``b ` c`` d"), ["``b ` c``"])

    def test_unclosed_run_protects_nothing(self) -> None:
        self.assertEqual(self.spans("a ``b ` c d"), [])

    def test_link_and_image_destinations(self) -> None:
        self.assertEqual(self.spans("[a](b.md) and ![i](p.png)"), ["](b.md)", "](p.png)"])

    def test_link_marker_inside_code_is_not_a_link(self) -> None:
        self.assertEqual(self.spans("`x](y` z) w"), ["`x](y`"])

    def test_unclosed_destination_protects_nothing(self) -> None:
        self.assertEqual(self.spans("[a](b.md"), [])

    def test_bare_url_gives_back_trailing_punctuation(self) -> None:
        self.assertEqual(self.spans("see https://a.org/x?y=1)."), ["https://a.org/x?y=1"])

    def test_autolink_and_comment(self) -> None:
        self.assertEqual(self.spans("<https://a.org/x> and <!-- c -->"), ["<https://a.org/x>", "<!-- c -->"])

    def test_overlapping_spans_are_merged(self) -> None:
        # The bare URL inside the link text runs into the destination: one span.
        self.assertEqual(self.spans("[https://a.org](https://a.org/b) end"), ["https://a.org](https://a.org/b)"])
        self.assertEqual(self.spans("`a` `b`"), ["`a`", "`b`"])

    def test_code_spans_content_and_offsets(self) -> None:
        text = "x `` a ` b `` y `z`"
        self.assertEqual(code_spans(text), [(2, 13, "a ` b"), (16, 19, "z")])

    def test_code_span_across_a_line_break(self) -> None:
        text = "x `a\nb` y"
        self.assertEqual(code_spans(text), [(2, 7, "a b")])

    def test_one_space_is_stripped_only_when_on_both_sides(self) -> None:
        self.assertEqual([c for _, _, c in code_spans("` a` `b ` ` c `")], [" a", "b ", "c"])
