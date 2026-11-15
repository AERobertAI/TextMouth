"""Tests of ``suggest-src --strings`` and ``wordingsearch``: from a section's interface words to the Swift files that hold them."""

from __future__ import annotations

import json
from typing import List

from doclib_case import DocLibCase

import wordingsearch
from wordingsearch import EQUAL, INSIDE

# A user page: a heading, a menu path, quoted and bold names, a curly-quoted one, and a name no code holds.
PAGE = """\
# Search

## The window

- Edit > Find > Search Library… (Option-Command-F) opens it.
- Press "Close" or check **Match Case**; "Nowhere Phrase" is in no code.
- The field is “Search the library”.
"""

# The wording enum: the words, and a comment that quotes a phrase the code does not hold.
WORDING = """\
import Foundation

/// The window's words. A comment may quote "Commented Phrase" without it counting.
enum SearchWording {
    /// The title: "Search Library" again, in a comment.
    static let windowTitle = "Search Library"
    static let closeButton = "Close"
    static let matchCase = "MATCH CASE"
    static let fieldLabel = "Search the library"
    static let menuTitle = "Search Library (Option-Command-F)"
}
"""


def literal_file(*literals: str) -> str:
    """A Swift file holding each of ``literals`` in a one-line string."""
    return "".join(f'let x{n} = "{text}"\n' for n, text in enumerate(literals))


class SuggestStringsTests(DocLibCase):
    """suggest-src --strings in a small repository: a page, a wording enum, its users, and files that must not count."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "docs/user/search.md": PAGE,
            "TextMouth/Models/SearchWording.swift": WORDING,
            # Names the title and the close button: the best user.
            "TextMouth/Views/SearchView.swift":
                "struct SearchView {\n  let a = SearchWording.windowTitle\n  let b = SearchWording.closeButton\n}\n",
            # Names the type once, and no matched member: a lesser user.
            "TextMouth/Views/OtherView.swift": "struct OtherView {\n  let a = SearchWording.menuTitle\n}\n",
            # Holds one phrase itself, in no wording type.
            "TextMouth/Views/PlainView.swift": literal_file("Close"),
            # None of these folders is the app's.
            "TextMouthTests/SearchTests.swift": literal_file("Search Library", "Close", "Match Case"),
            "TextMouthProductionTests/MoreTests.swift": literal_file("Search Library", "Close", "Match Case"),
            "Vendor/Lib/V.swift": literal_file("Search Library", "Close", "Match Case"),
            "Scripts/tool.swift": literal_file("Search Library", "Close", "Match Case"),
            "build/Generated.swift": literal_file("Search Library", "Close", "Match Case"),
        })

    def strings(self, *args: str):
        """Run ``suggest-src docs/user/search.md#The window --strings``; return (status, stdout lines, stderr)."""
        status, out, err = self.run_cli("suggest-src", "search#The window", "--strings", *args)
        return status, out.splitlines(), err

    def test_the_wording_file_comes_first_then_its_users(self) -> None:
        status, lines, err = self.strings()
        self.assertEqual((status, err), (0, ""))
        # The wording file matches the most phrases; under it come each phrase's first match, then its users.
        self.assertEqual(lines[:5], [
            "TextMouth/Models/SearchWording.swift:6-6  The window  4 phrases, wording",
            '  "Search Library…" (equal) line 6: static let windowTitle = "Search Library"',
            '  "Close" (equal) line 7: static let closeButton = "Close"',
            '  "Match Case" (equal) line 8: static let matchCase = "MATCH CASE"',
            '  "Search the library" (equal) line 9: static let fieldLabel = "Search the library"',
        ])
        self.assertTrue(lines[5].startswith("  used by TextMouth/Views/SearchView.swift"))

    def test_the_users_follow_the_wording_file_best_first(self) -> None:
        _status, lines, _err = self.strings()
        users = [line for line in lines if line.startswith("  used by")]
        self.assertEqual(users, [
            "  used by TextMouth/Views/SearchView.swift (2 references)",
            "  used by TextMouth/Views/OtherView.swift (1 reference)",
        ])

    def test_a_file_with_one_literal_of_its_own_follows_the_wording_file(self) -> None:
        _status, lines, _err = self.strings()
        heads = [line for line in lines if not line.startswith("  ")]
        self.assertEqual([head.split(":")[0] for head in heads], [
            "TextMouth/Models/SearchWording.swift", "TextMouth/Views/PlainView.swift"])
        self.assertTrue(heads[1].endswith("1 phrase"))

    def test_tests_vendored_code_tooling_and_build_output_are_not_searched(self) -> None:
        _status, lines, _err = self.strings("--max", "0")
        text = "\n".join(lines)
        for folder in ("Tests/", "Vendor/", "Scripts/", "build/"):
            self.assertNotIn(folder, text)

    def test_a_phrase_found_nowhere_yields_no_file(self) -> None:
        self.write_tree({"docs/user/none.md": '# None\n\n- Press "Nowhere Phrase" or **Another Missing One**.\n'})
        status, out, err = self.run_cli("suggest-src", "none#None", "--strings")
        self.assertEqual((status, out, err), (1, "", ""))

    def test_a_comment_is_not_a_literal(self) -> None:
        self.write_tree({"docs/user/c.md": '# C\n\n- See "Commented Phrase".\n',
                         "TextMouth/Views/Commented.swift": '// "Commented Phrase"\n/* "Commented Phrase" */\n'})
        status, out, _err = self.run_cli("suggest-src", "c#C", "--strings")
        self.assertEqual((status, out), (1, ""))

    def test_the_cap_counts_files_and_says_so(self) -> None:
        status, lines, err = self.strings("--max", "1")
        self.assertEqual(status, 0)
        self.assertEqual(len([line for line in lines if not line.startswith("  ")]), 1)
        self.assertIn("1 of 2 files shown", err)

    def test_json_is_one_object_per_file_with_its_phrases_and_users(self) -> None:
        status, out, _err = self.strings("--json")
        objects = [json.loads(line) for line in out]
        self.assertEqual((status, len(objects)), (0, 2))
        first = objects[0]
        self.assertEqual(first["path"], "TextMouth/Models/SearchWording.swift")
        self.assertEqual(first["wording"], ["SearchWording"])
        self.assertEqual([p["phrase"] for p in first["phrases"]],
                         ["Search Library…", "Close", "Match Case", "Search the library"])
        self.assertEqual(first["users"][0], {"path": "TextMouth/Views/SearchView.swift", "references": 2})
        self.assertEqual(objects[1]["users"], [])

    def test_only_three_users_are_listed(self) -> None:
        for n in range(5):
            self.write_tree({f"TextMouth/Views/Extra{n}.swift": "let e = SearchWording.closeButton\n"})
        _status, out, _err = self.strings("--json")
        self.assertEqual(len(json.loads(out[0])["users"]), 3)

    def test_the_other_option_still_works(self) -> None:
        # Without --strings the same page names no code, so there is nothing to suggest.
        status, out, _err = self.run_cli("suggest-src", "search#The window")
        self.assertEqual((status, out), (1, ""))

    def test_a_bad_target_is_a_usage_error(self) -> None:
        status, out, err = self.run_cli("suggest-src", "nope", "--strings")
        self.assertEqual((status, out), (2, ""))
        self.assertIn("no section has the id", err)


class PhraseTests(DocLibCase):
    """interface_phrases: what a section's words are."""

    def phrases(self, title: str, text: str) -> List[str]:
        """The phrase texts of a section titled ``title`` whose one block is ``text``."""
        return [phrase.text for phrase in wordingsearch.interface_phrases(title, [(1, text)])]

    def test_quoted_curly_and_bold_names_and_the_heading(self) -> None:
        self.assertEqual(self.phrases("Keep This Code", 'Press "Close", “Open Book…” or **Stop**.'),
                         ["Keep This Code", "Close", "Open Book…", "Stop"])

    def test_a_menu_path_is_split_and_its_trailing_words_are_left_out(self) -> None:
        self.assertEqual(self.phrases("Top", "Edit > Find > Search Library… (Option-Command-F) opens it."),
                         ["Top", "Edit", "Find", "Search Library…"])

    def test_a_quoted_menu_path_is_split_too_and_a_name_comes_once(self) -> None:
        self.assertEqual(self.phrases("Find", 'Use "Edit > Find" and Edit > Find again.'), ["Find", "Edit"])

    def test_the_first_word_of_a_sentence_does_not_hide_the_menu(self) -> None:
        self.assertEqual(self.phrases("Top", "Open Settings > Library > Titles to set it."),
                         ["Top", "Open Settings", "Library", "Titles", "Settings"])

    def test_small_words_join_capitalised_ones_in_a_menu_name(self) -> None:
        self.assertEqual(self.phrases("Top", "File > Add to Library… works."), ["Top", "File", "Add to Library…"])

    def test_a_heading_joining_two_names_gives_each_as_well(self) -> None:
        self.assertEqual(self.phrases("Match Case and Regular Expression", "Nothing."),
                         ["Match Case and Regular Expression", "Match Case", "Regular Expression"])

    def test_one_character_and_letterless_phrases_are_left_out(self) -> None:
        self.assertEqual(self.phrases("Heading", 'Say "a", "750", "…" and "Ok".'), ["Heading", "Ok"])

    def test_a_files_line_is_not_read_for_words(self) -> None:
        self.assertEqual(self.phrases("Head", 'Files: "Quoted/Path.swift"'), ["Head"])


class LiteralTests(DocLibCase):
    """swift_literals and normalise: what a Swift file's strings say."""

    def literals(self, text: str) -> List[str]:
        """The texts of the literals of ``text``."""
        return [literal for _offset, literal in wordingsearch.swift_literals(text)]

    def test_escapes_and_interpolations_are_resolved(self) -> None:
        self.assertEqual(self.literals(r'let a = "Say \"hi\"\u{2026} \(count) books"'),
                         ['Say "hi"… ￼ books'])

    def test_comments_hide_their_quotes_and_strings_hide_their_slashes(self) -> None:
        text = 'let a = "http://x.y" // "gone"\n/* "gone too" */ let b = "kept"\n'
        self.assertEqual(self.literals(text), ["http://x.y", "kept"])

    def test_a_multi_line_literal_gives_each_nonblank_line_at_its_own_offset(self) -> None:
        text = 'let a = """\n  First line\n\n  Second line\n  """\n'
        found = list(wordingsearch.swift_literals(text))
        self.assertEqual([literal.strip() for _o, literal in found], ["First line", "Second line"])
        self.assertEqual([text[offset:].split("\n")[0].strip() for offset, _l in found], ["First line", "Second line"])

    def test_normalise_drops_the_ellipsis_folds_case_and_straightens_apostrophes(self) -> None:
        self.assertEqual(wordingsearch.normalise("  Search   Library… "), "search library")
        self.assertEqual(wordingsearch.normalise("Open Book..."), "open book")
        self.assertEqual(wordingsearch.normalise("Don’t STOP"), "don't stop")

    def test_whole_words_only_for_a_phrase_inside_a_literal(self) -> None:
        self.assertTrue(wordingsearch._holds_whole("search library (option-command-f)", "search library"))
        self.assertTrue(wordingsearch._holds_whole("open the book", "book"))
        self.assertFalse(wordingsearch._holds_whole("bookmarks", "book"))
        self.assertFalse(wordingsearch._holds_whole("a closet", "close"))

    def test_a_phrase_is_equal_or_inside(self) -> None:
        self.write_tree({"TextMouth/A.swift": literal_file("Close", "Close the window")})
        phrases = [wordingsearch.Phrase("Close", "close"), wordingsearch.Phrase("window", "window")]
        result, _refs = wordingsearch._scan_file((self.root / "TextMouth/A.swift").read_text(), "TextMouth/A.swift", phrases)
        self.assertEqual({key: match.kind for key, match in result.matches.items()}, {"close": EQUAL, "window": INSIDE})

    def test_a_short_phrase_is_not_looked_for_inside_longer_literals(self) -> None:
        # "the" and "View" are in every sentence; only an equal literal counts for them.
        self.write_tree({"TextMouth/B.swift": literal_file("the", "Open the View now", "Show Library now")})
        phrases = [wordingsearch.Phrase("the", "the"), wordingsearch.Phrase("View", "view"),
                   wordingsearch.Phrase("Library", "library")]
        result, _refs = wordingsearch._scan_file((self.root / "TextMouth/B.swift").read_text(), "TextMouth/B.swift", phrases)
        self.assertEqual({key: match.kind for key, match in result.matches.items()}, {"the": EQUAL, "library": INSIDE})
