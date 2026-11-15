"""Tests of the Swift index (``swiftindex``): what it finds, and which names a section mentions."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from doclib_case import DocLibCase

import swiftindex
from repofiles import RepoFiles
from swiftindex import Declaration, Mention, SwiftIndex

BOOK = """\
import Foundation

/// The class Book is a comment and counts too.
final class Book: ObservableObject {
    struct Storage {
        func load() {}
    }

    class func make() -> Book { Book() }
    class var shared: Book { Book() }
    static func startLibrary() {}
}

public protocol Reading {}
actor Fetcher {}
typealias Pair = (Int, Int)
enum Format { case epub }
"""

EXTENSIONS = """\
extension Book {
    func open() {}
}
extension Book.Storage: Equatable {
    func startLibrary() {}
}
extension String where Self: Sendable {}
"""


class SwiftIndexTests(DocLibCase):
    """SwiftIndex.load and its lookups."""

    def setUp(self) -> None:
        super().setUp()
        self.write_tree({
            "TextMouth/Models/Book.swift": BOOK,
            "TextMouth/Models/Book+Extras.swift": EXTENSIONS,
            "Vendor/Lib/Hidden.swift": "class Hidden {}\n",
            "TextMouth/Notes.txt": "class NotSwift {}\n",
        })
        self.repo = RepoFiles.load(self.root)
        self.index = SwiftIndex.load(self.repo)

    def test_each_declaring_keyword_is_found_with_its_line_and_text(self) -> None:
        cases = {
            "Book": ("class", 4, "final class Book: ObservableObject {"),
            "Storage": ("struct", 5, "struct Storage {"),
            "Reading": ("protocol", 14, "public protocol Reading {}"),
            "Fetcher": ("actor", 15, "actor Fetcher {}"),
            "Pair": ("typealias", 16, "typealias Pair = (Int, Int)"),
            "Format": ("enum", 17, "enum Format { case epub }"),
            "load": ("func", 6, "func load() {}"),
        }
        for name, (kind, line, text) in cases.items():
            found = [d for d in self.index.declarations(name)
                     if d.path == "TextMouth/Models/Book.swift" and d.line == line]
            self.assertEqual(found, [Declaration(name, kind, "TextMouth/Models/Book.swift", line, text)], name)

    def test_a_comment_is_scanned_too(self) -> None:
        # "The class Book" in the comment on line 3 is a declaration, as the brief accepts.
        lines = [d.line for d in self.index.declarations("Book") if d.kind == "class"]
        self.assertEqual(lines, [3, 4])

    def test_class_func_and_class_var_keep_the_function_and_drop_the_keyword(self) -> None:
        self.assertEqual([d.line for d in self.index.declarations("make")], [9])
        self.assertTrue(self.index.is_func("make"))
        # ``class var shared`` declares nothing the index keeps, and "var" is no name.
        self.assertEqual(self.index.declarations("var"), [])
        self.assertEqual(self.index.declarations("func"), [])
        self.assertEqual(self.index.declarations("shared"), [])

    def test_an_extension_is_a_declaration_of_the_extended_name(self) -> None:
        kinds = [d.kind for d in self.index.declarations("String")]
        self.assertEqual(kinds, ["extension"])
        self.assertTrue(self.index.is_type("String"))
        # ``extension Book.Storage`` extends Storage, the last part.
        # (Book+Extras.swift sorts before Book.swift: "+" comes before ".".)
        self.assertEqual([d.kind for d in self.index.declarations("Storage")], ["extension", "struct"])

    def test_is_type_and_is_func(self) -> None:
        for name in ("Book", "Storage", "Reading", "Fetcher", "Pair", "Format", "String"):
            self.assertTrue(self.index.is_type(name), name)
        for name in ("load", "open", "startLibrary", "nothing"):
            self.assertFalse(self.index.is_type(name), name)
        for name in ("load", "open", "startLibrary", "make"):
            self.assertTrue(self.index.is_func(name), name)
        for name in ("Book", "String", "nothing"):
            self.assertFalse(self.index.is_func(name), name)

    def test_type_files_leave_extensions_out_and_list_each_file_once(self) -> None:
        self.assertEqual(self.index.type_files("Book"), ["TextMouth/Models/Book.swift"])
        self.assertEqual(self.index.type_files("Storage"), ["TextMouth/Models/Book.swift"])
        # String is only extended, so no file has a type declaration of it.
        self.assertEqual(self.index.type_files("String"), [])
        self.assertEqual(self.index.func_files("startLibrary"),
                         ["TextMouth/Models/Book+Extras.swift", "TextMouth/Models/Book.swift"])

    def test_vendor_and_non_swift_files_are_not_read(self) -> None:
        self.assertEqual(self.index.declarations("Hidden"), [])
        self.assertEqual(self.index.declarations("NotSwift"), [])

    def test_declarations_come_in_file_and_line_order(self) -> None:
        found = self.index.declarations("startLibrary")
        self.assertEqual([(d.path, d.line) for d in found],
                         [("TextMouth/Models/Book+Extras.swift", 5), ("TextMouth/Models/Book.swift", 11)])

    def test_lookup_puts_types_then_extensions_then_functions(self) -> None:
        self.write_tree({"TextMouth/Other.swift": "func Book() {}\nextension Book {}\n"})
        index = SwiftIndex.load(RepoFiles.load(self.root))
        kinds = [d.kind for d in index.lookup("Book")]
        self.assertEqual(kinds, ["class", "class", "extension", "extension", "func"])

    def test_lookup_of_written_names(self) -> None:
        # A call is looked up by the name before its parenthesis.
        self.assertEqual([d.kind for d in self.index.lookup("startLibrary()")], ["func", "func"])
        # A dotted name by its last part, and by its first when the last has no declaration.
        self.assertEqual({d.name for d in self.index.lookup("Book.Storage")}, {"Storage"})
        self.assertEqual({d.name for d in self.index.lookup("Book.nothing")}, {"Book"})
        self.assertEqual(self.index.lookup(".shared"), [])
        self.assertEqual(self.index.lookup("Nothing"), [])

    def test_defining_declarations_by_file(self) -> None:
        found = self.index.defining_declarations("Book")
        self.assertEqual([(d.path, d.line) for d in found], [("TextMouth/Models/Book.swift", 3)])
        found = self.index.defining_declarations("startLibrary()")
        self.assertEqual([d.path for d in found], ["TextMouth/Models/Book+Extras.swift", "TextMouth/Models/Book.swift"])
        self.assertEqual(self.index.defining_declarations("String"), [])

    def test_a_symbolic_link_is_not_followed_out_of_the_repository(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doclib-outside-") as outside:
            target = Path(outside).resolve() / "Secret.swift"
            target.write_text("class Outside {}\n", encoding="utf-8")
            link = self.root / "TextMouth" / "Link.swift"
            os.symlink(target, link)
            repo = RepoFiles.load(self.root)
            self.assertIn("TextMouth/Link.swift", repo.files)
            index = SwiftIndex.load(repo)
        self.assertEqual(index.declarations("Outside"), [])
        self.assertTrue(index.is_type("Book"))

    def test_a_missing_or_unreadable_file_is_skipped(self) -> None:
        repo = RepoFiles(self.root, ["TextMouth/Models/Book.swift", "TextMouth/Gone.swift"])
        index = SwiftIndex.load(repo)
        self.assertTrue(index.is_type("Book"))

    def test_a_keyword_at_the_very_start_of_a_file_and_with_no_final_newline(self) -> None:
        self.write_tree({"A.swift": "struct First {}", "B.swift": "\nfunc last()"})
        index = SwiftIndex.load(RepoFiles.load(self.root))
        self.assertEqual([(d.line, d.text) for d in index.declarations("First")], [(1, "struct First {}")])
        self.assertEqual([(d.line, d.text) for d in index.declarations("last")], [(2, "func last()")])

    def test_a_keyword_inside_a_longer_word_is_not_a_declaration(self) -> None:
        self.write_tree({"C.swift": "let subclass Thing = 1\nlet myfunc Other = 2\nsubstruct Third\n"})
        index = SwiftIndex.load(RepoFiles.load(self.root))
        for name in ("Thing", "Other", "Third"):
            self.assertEqual(index.declarations(name), [], name)

    def test_modifiers_are_no_names_but_a_function_may_be_called_open(self) -> None:
        self.write_tree({"D.swift": "class final func a() {}\nclass override var b = 1\nfunc open() {}\n"})
        index = SwiftIndex.load(RepoFiles.load(self.root))
        self.assertEqual(index.declarations("final"), [])
        self.assertEqual(index.declarations("override"), [])
        self.assertTrue(index.is_func("a"))
        self.assertTrue(index.is_func("open"))

    def test_enum_cases_are_declarations_that_a_call_may_name(self) -> None:
        # MarkupRefusal's nestedTooDeeply(limit:) is named in shared-helpers.md as a call.
        source = (
            "enum MarkupRefusal: Error {\n"
            "    case nestedTooDeeply(limit: Int)\n"
            "    case tooMuchMarkup, tooManyAttributes(limit: Int), tooMuchWork\n"
            "    case raw = \"r\", cooked = \"c\"\n"
            "}\n"
            "func f(x: Int) { switch x { case .a, .b: break; case let y: print(y) } }\n"
        )
        self.write_tree({"E.swift": source})
        index = SwiftIndex.load(RepoFiles.load(self.root))
        for name in ("nestedTooDeeply", "tooMuchMarkup", "tooManyAttributes", "tooMuchWork", "raw", "cooked"):
            with self.subTest(name=name):
                self.assertTrue(index.is_callable(name))
                self.assertFalse(index.is_func(name))
        self.assertEqual([(d.kind, d.line) for d in index.declarations("tooManyAttributes")], [("case", 3)])
        # A switch's patterns and case let declare nothing.
        for name in ("a", "b", "let", "y"):
            with self.subTest(name=name):
                self.assertEqual(index.declarations(name), [])


class NameHelperTests(DocLibCase):
    """The small pure helpers."""

    def test_name_keys(self) -> None:
        cases = {
            "Book": ["Book"],
            "Book.Storage": ["Storage", "Book"],
            "startLibrary()": ["startLibrary"],
            "NSHostingController.sizeThatFits(in:)": ["sizeThatFits", "NSHostingController"],
            ".terminateCancel": ["terminateCancel"],
            "a.b.c": ["c", "a"],
        }
        for written, keys in cases.items():
            self.assertEqual(swiftindex.name_keys(written), keys, written)

    def test_type_shape(self) -> None:
        for word in ("ReaderViewModel", "KF8Layout", "MOBIBook", "PersistenceFailureCenter", "FooBar"):
            self.assertTrue(swiftindex.is_type_shaped(word), word)
        for word in ("VoiceOver", "Reader", "EPUB", "lowerCase", "A", "_Thing", "Aa"):
            self.assertEqual(swiftindex.is_type_shaped(word), word == "VoiceOver", word)

    def test_capitalised_word(self) -> None:
        self.assertTrue(swiftindex.is_capitalised_word("Book"))
        self.assertFalse(swiftindex.is_capitalised_word("EPUB"))
        self.assertFalse(swiftindex.is_capitalised_word("book"))
        self.assertFalse(swiftindex.is_capitalised_word(""))

    def test_is_file_name(self) -> None:
        for written in ("Info.plist", "content.md", "library.json", "EPUBParser.swift", "Settings.PLIST"):
            self.assertTrue(swiftindex.is_file_name(written), written)
        for written in ("Book.Storage", "Book", "run.swift()", ".shared", ".plist", "a.b.cx"):
            self.assertFalse(swiftindex.is_file_name(written), written)

    def test_is_call(self) -> None:
        self.assertTrue(swiftindex.is_call("startLibrary()"))
        self.assertFalse(swiftindex.is_call("Book.Storage"))


def declared(*names: str) -> SwiftIndex:
    """An index that declares each of ``names`` as a struct in one file."""
    return SwiftIndex(Declaration(name, "struct", "A.swift", 1, f"struct {name} {{}}") for name in names)


class MentionsTests(DocLibCase):
    """mentions: backticked names, and bare type names the index declares."""

    def test_backticked_names_are_mentions_in_order_with_their_lines(self) -> None:
        blocks = [(10, "Uses `Book.Storage` and `startLibrary()`.\nThen `Reader`."), (12, "Last `.shared`.")]
        self.assertEqual(swiftindex.mentions(blocks), [
            Mention("Book.Storage", 10, True), Mention("startLibrary()", 10, True),
            Mention("Reader", 11, True), Mention(".shared", 12, True),
        ])

    def test_an_unbackticked_declared_type_is_a_mention_merged_in_written_order(self) -> None:
        blocks = [(5, "Owner: ReaderViewModel.shared, with `Book` and KF8Layout.")]
        found = swiftindex.mentions(blocks, declared("ReaderViewModel", "KF8Layout"))
        self.assertEqual([(m.name, m.backticked) for m in found],
                         [("ReaderViewModel", False), ("Book", True), ("KF8Layout", False)])
        self.assertEqual({m.line for m in found}, {5})

    def test_a_type_shaped_word_the_index_does_not_declare_is_no_mention(self) -> None:
        found = swiftindex.mentions([(1, "VoiceOver reads MOBIBook and ReaderViewModel.")],
                                    declared("MOBIBook", "ReaderViewModel"))
        self.assertEqual([m.name for m in found], ["MOBIBook", "ReaderViewModel"])
        # VoiceOver counts once the index declares it.
        found = swiftindex.mentions([(1, "VoiceOver reads.")], declared("VoiceOver"))
        self.assertEqual([m.name for m in found], ["VoiceOver"])

    def test_words_that_are_not_type_shaped_are_never_bare_mentions(self) -> None:
        found = swiftindex.mentions([(1, "Reader, EPUB, Book and reader.")], declared("Reader", "EPUB", "Book"))
        self.assertEqual(found, [])

    def test_words_inside_code_spans_and_link_destinations_are_not_prose(self) -> None:
        text = "See [the page](docs/ReaderViewModel.md) and `x ReaderViewModel y` and `ReaderViewModel`."
        found = swiftindex.mentions([(1, text)], declared("ReaderViewModel"))
        # Only the backticked identifier is a mention; the link and the span with spaces are not prose.
        self.assertEqual([(m.name, m.backticked) for m in found], [("ReaderViewModel", True)])

    def test_the_link_text_is_prose_and_a_bare_url_is_not(self) -> None:
        text = "[ReaderViewModel](docs/x.md) and https://example.com/ReaderViewModel."
        found = swiftindex.mentions([(1, text)], declared("ReaderViewModel"))
        self.assertEqual(len(found), 1)

    def test_files_blocks_are_skipped(self) -> None:
        blocks = [(1, "- Files: Parsers/ReaderViewModel.swift, `Other`"), (2, "Prose ReaderViewModel.")]
        found = swiftindex.mentions(blocks, declared("ReaderViewModel"))
        self.assertEqual([(m.name, m.line) for m in found], [("ReaderViewModel", 2)])

    def test_a_repeated_name_is_listed_each_time(self) -> None:
        found = swiftindex.mentions([(1, "ReaderViewModel, ReaderViewModel and `ReaderViewModel`.")],
                                    declared("ReaderViewModel"))
        self.assertEqual(len(found), 3)

    def test_the_line_of_a_bare_word_in_a_multiline_block(self) -> None:
        found = swiftindex.mentions([(7, "one\ntwo\nthree ReaderViewModel")], declared("ReaderViewModel"))
        self.assertEqual([m.line for m in found], [9])
