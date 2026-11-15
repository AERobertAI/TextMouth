"""Tests of the speed-ups: each quick test that gates a slow one must never turn away what the slow one finds.

The lint and the sentence splitter first ask a cheap question of a block of text (is a
date, a sales word, an emoji, or a sentence's end possible here?) and run the exact, slow
search only when the answer is yes. These tests compare each cheap question with the exact
search on fixed and random texts, so a gate that is too tight fails here and not only in the
real docs.
"""

from __future__ import annotations

import random
import re
from typing import List

from doclib_case import DocLibCase  # first: it puts the scripts folder on sys.path

import lintrules  # noqa: E402
import sentences  # noqa: E402


class SalesGateTests(DocLibCase):
    """sales_prefilter / folded / holds_any: a text the sales pattern matches always passes."""

    def gate(self, words: List[str], text: str) -> bool:
        """Whether the gate lets ``text`` through for ``words``."""
        return lintrules.holds_any(lintrules.folded(text), lintrules.sales_prefilter(words))

    def test_the_real_words_pass_in_any_case(self) -> None:
        words = lintrules.load_sales_words()
        pattern = lintrules.sales_pattern(words)
        for word in words:
            for text in (word, word.upper(), word.title(), f"A {word}.", f"x\n{word.capitalize()}\ny"):
                self.assertTrue(pattern.search(text), text)
                self.assertTrue(self.gate(words, text), text)

    def test_characters_ignore_case_folds_to_ascii_still_pass(self) -> None:
        # The long s, the dotless i, the dotted capital I, and the Kelvin sign match ASCII
        # letters under IGNORECASE; str.lower alone would miss them.
        words = ["seamless", "kind of", "icing"]
        pattern = lintrules.sales_pattern(words)
        for text in ("\u017feamle\u017f\u017f", "\u212aind of", "\u0130cing", "\u0131cing"):
            self.assertTrue(pattern.search(text), ascii(text))
            self.assertTrue(self.gate(words, text), ascii(text))

    def test_a_phrase_is_gated_by_its_first_word(self) -> None:
        words = ["state of the art"]
        text = "It is state   of\tthe art."
        self.assertTrue(lintrules.sales_pattern(words).search(text))
        self.assertTrue(self.gate(words, text))

    def test_text_with_no_sales_word_is_turned_away(self) -> None:
        self.assertFalse(self.gate(lintrules.load_sales_words(), "Plain prose about a reader and a library.\n"))

    def test_no_words_means_no_needles(self) -> None:
        self.assertEqual(lintrules.sales_prefilter([]), ())

    def test_random_texts(self) -> None:
        words = ["seamless", "cutting-edge", "state of the art", "kind", "icing"]
        pattern = lintrules.sales_pattern(words)
        pieces = ["seamless", "Seamless", "SEAMLESS", "cutting-edge", "state", "of", "the", "art", " ", "\n", "\t",
                  "kind", "KIND", "icing", "x", "-", "\u017f", "\u212a", "\u0130", "\u0131", "\u00e9", "`", "."]
        rng = random.Random(7)
        for _ in range(3000):
            text = "".join(rng.choice(pieces) for _ in range(rng.randint(1, 12)))
            if pattern.search(text):
                self.assertTrue(self.gate(words, text), ascii(text))

    def test_the_rule_finds_a_folded_spelling(self) -> None:
        # End to end: the lint reports the long-s spelling the exact pattern matches.
        self.write_tree({"docs/user/a.md": "# T\n\n<!-- id: t -->\nIt is \u017feamle\u017f\u017f.\n"})
        found = lintrules.lint(self.root, ["sales-word"])
        self.assertEqual([v.start for v in found], [4])


class DateGateTests(DocLibCase):
    """might_hold_date: a text either date pattern matches always passes."""

    def matches(self, text: str) -> bool:
        """Whether either exact date pattern matches ``text``."""
        return bool(lintrules._ISO_DATE.search(text) or lintrules._NAMED_DATE.search(text))

    def test_every_form_of_date_passes(self) -> None:
        for text in ("2026-10-12", "October 12", "Oct. 12, 2026", "October 2026", "12 October", "12th Oct 2026",
                     "Sept 3", "May 1", "3 May", "x\n2019-01-31\ny", "see Dec. 31st", "1 Jan.", "Mar\t5"):
            self.assertTrue(self.matches(text), text)
            self.assertTrue(lintrules.might_hold_date(text), text)

    def test_text_with_no_date_may_be_turned_away(self) -> None:
        self.assertFalse(lintrules.might_hold_date("Plain prose, a version 0.4.10, and 12 apples.\n"))

    def test_random_texts(self) -> None:
        pieces = ["2026", "-", "10", "12", "0", "1", "31", "Oct", "October", "Sept", "May", ".", ",", " ", "\t", "\n",
                  "st", "th", "x", "19", "20", "Dec", "Mar", "\u0663", "\u00e9"]
        rng = random.Random(11)
        for _ in range(5000):
            text = "".join(rng.choice(pieces) for _ in range(rng.randint(1, 12)))
            if self.matches(text):
                self.assertTrue(lintrules.might_hold_date(text), ascii(text))


class EmojiPageGateTests(DocLibCase):
    """The emoji rule skips a page with no emoji anywhere, and still finds one on any other."""

    def emoji(self, text: str) -> List[int]:
        """The lines of the emoji violations of a page with ``text``."""
        self.write_tree({"docs/user/a.md": text})
        return [v.start for v in lintrules.lint(self.root, ["emoji"])]

    def test_emoji_in_code_is_not_reported_but_one_in_prose_is(self) -> None:
        text = "# T\n\n```\n\U0001F600\n```\n\nA `\U0001F600` span.\n\nProse \U0001F600 here.\n"
        self.assertEqual(self.emoji(text), [9])

    def test_a_page_with_none(self) -> None:
        self.assertEqual(self.emoji("# T\n\nNothing to see.\n"), [])


class SentenceGateTests(DocLibCase):
    """split_sentences skips the protected-span search when no sentence can end; the result is unchanged."""

    @staticmethod
    def reference(text: str) -> List[sentences.Span]:
        """The splitter as it was before the gate: protected spans and every terminator, always."""
        protected = sentences.protected_spans(text)
        spans: List[sentences.Span] = []
        start = 0
        for match in re.finditer(r"[.!?]", text):
            index = match.start()
            if index < start:
                continue
            end = sentences._sentence_end_at(text, index, protected)
            if end == -1:
                continue
            spans.append((sentences._first_nonspace(text, start), end))
            start = end
        first = sentences._first_nonspace(text, start)
        last = len(text.rstrip())
        if first < last:
            spans.append((first, last))
        return spans

    def test_fixed_cases(self) -> None:
        for text in ("", " ", "No terminator", "One sentence.", "One sentence. ", "Two. Sentences", "a.b c", "end?)",
                     "Ends\u00a0Here. Next", "3.14 is pi", "(See X.) Next", "e.g. Foo", "x!\ty"):
            self.assertEqual(sentences.split_sentences(text), self.reference(text), repr(text))

    def test_random_texts(self) -> None:
        pieces = [".", "!", "?", " ", " ", "\t", "\n", ")", "]", "\"", "'", "*", "_", "`", "A", "b", "1", "Dr", "e.g",
                  "J", "http://x.y/z", "[l](d.md)", "\u00a0", "\u2019", "\u201d", "<!--", "-->"]
        rng = random.Random(3)
        for _ in range(5000):
            text = "".join(rng.choice(pieces) for _ in range(rng.randint(0, 14)))
            self.assertEqual(sentences.split_sentences(text), self.reference(text), repr(text))
