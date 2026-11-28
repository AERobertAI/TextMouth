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
import swiftindex  # noqa: E402


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


class CodeSpanFastPathTests(DocLibCase):
    """code_spans answers at once for a text with no backtick, as the full scan would."""

    @staticmethod
    def full_scan(text: str) -> list:
        """code_spans without its fast path, by clearing its cache and adding a backtick pair that is then dropped."""
        return [span for span in sentences.code_spans(text + "``") if span[1] <= len(text)]

    def test_texts_without_a_backtick_have_no_spans(self) -> None:
        for text in ("", "plain", "two\nlines. Here", "a 'quote' and \"another\""):
            self.assertEqual(sentences.code_spans(text), [], repr(text))
            self.assertEqual(self.full_scan(text), [], repr(text))

    def test_texts_with_one_are_scanned(self) -> None:
        self.assertEqual(sentences.code_spans("a `b` c"), [(2, 5, "b")])
        self.assertEqual(sentences.code_spans("a ` b"), [])


# The first version of the Swift scan: one pattern for each declaring keyword, tried at every position.
_OLD_PATTERNS = tuple(
    (keyword, re.compile(keyword.encode("ascii") + rb"\s+(?=([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*))"))
    for keyword in ("class", "struct", "enum", "protocol", "actor", "typealias", "func", "extension", "case")
)


def old_scan_keywords(data: bytes) -> list:
    """What ``scan_keywords`` returned when it ran a pattern for each keyword."""
    found = []
    for keyword, pattern in _OLD_PATTERNS:
        for match in pattern.finditer(data):
            start = match.start()
            if start == 0 or data[start - 1] not in swiftindex._WORD_BYTES:
                found.append((start, keyword, match.group(1)))
                if keyword == "case":
                    # A case list's later names (more_case_names has its own tests).
                    end = match.start(1) + len(match.group(1))
                    found.extend((offset, keyword, name) for offset, name in swiftindex.more_case_names(data, end))
    found.sort()
    return found


class SwiftScanTests(DocLibCase):
    """scan_keywords finds exactly what a pattern for each keyword found."""

    def test_fixed_cases(self) -> None:
        for text in (
            "", "class", "class A", "class\tA {}", "final class Foo: Bar {}", "subclass Foo", "_class Foo", "class _x",
            "class func make() {}", "extension Book.Storage {", "enum E { case func }", "func\n\nf()", "classclass A",
            "struct S\nstruct T", "actor protocol typealias X = Y", "x.func y", "class Café", "éclass A",
            "class 1", "class A.B.C {}", "class A. B", "extension    X",
        ):
            data = text.encode("utf-8")
            self.assertEqual(swiftindex.scan_keywords(data), old_scan_keywords(data), repr(text))

    def test_random_texts(self) -> None:
        pieces = ["class", "struct", "enum", "protocol", "actor", "typealias", "func", "extension", "case", ", ", " ", "\n", "\t",
                  "A", "foo", "_", ".", "1", "{", "(", "é", "x", "Foo.Bar", "sub", "class "]
        rng = random.Random(5)
        for _ in range(4000):
            data = "".join(rng.choice(pieces) for _ in range(rng.randint(0, 14))).encode("utf-8")
            self.assertEqual(swiftindex.scan_keywords(data), old_scan_keywords(data), repr(data))


class ReadWithoutFollowingLinksTests(DocLibCase):
    """read_without_following_links: the bytes of a plain file, and None for anything else."""

    def test_reads_a_file_whole(self) -> None:
        self.write_tree({"a.swift": "class A {}\n", "empty.swift": ""})
        self.assertEqual(swiftindex.read_without_following_links(str(self.root / "a.swift")), b"class A {}\n")
        self.assertEqual(swiftindex.read_without_following_links(str(self.root / "empty.swift")), b"")

    def test_reads_a_file_bigger_than_a_chunk(self) -> None:
        text = ("func f() {}\n" * 200_000).encode("ascii")
        (self.root / "big.swift").write_bytes(text)
        self.assertEqual(swiftindex.read_without_following_links(str(self.root / "big.swift")), text)

    def test_a_missing_file_a_folder_and_a_link_are_none(self) -> None:
        self.write_tree({"a.swift": "class A {}\n"})
        (self.root / "folder").mkdir()
        (self.root / "link.swift").symlink_to(self.root / "a.swift")
        for name in ("missing.swift", "folder", "link.swift"):
            self.assertIsNone(swiftindex.read_without_following_links(str(self.root / name)), name)
