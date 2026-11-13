import XCTest
@testable import TextMouth

/// The guard on Markdown's nesting (`MarkdownNesting`, and the two layers in
/// `MarkdownDocParser.parseChapter`): block quotes and lists nested far deeper
/// than any book are refused with a sentence, as HTML is (`MarkupGuard`), and
/// anything nested as books nest reads exactly as it did. Every deep input here
/// is plainly deep (thousands of `>` marks or list markers) and none is built
/// to pass the count. Hermetic: no helper, no library, no file.
final class MarkdownNestingTests: XCTestCase {

    // MARK: - Helpers

    /// `levels` block quotes around `words`, written `> > > words`.
    private func quotes(_ levels: Int, around words: String = "Quoted words") -> String {
        String(repeating: "> ", count: levels) + words
    }

    /// `levels` nested lists around `words`, one two-column indent deeper each.
    private func nestedList(_ levels: Int, around words: String = "Listed words") -> String {
        (0..<levels).map { String(repeating: " ", count: 2 * $0) + "- " + ($0 == levels - 1 ? words : "item") }
            .joined(separator: "\n")
    }

    /// The deepest count of `markdown` with a limit above anything it holds.
    private func depth(_ markdown: String) -> Int {
        MarkdownNesting.deepest(in: markdown, stopAbove: .max)
    }

    private let standardLimit = MarkupGuard.Limits.standard.deepestNesting

    /// Runs `body` with the walk's limit on trees lifted, so that only the count of
    /// containers (the first layer) can refuse a text: a refusal seen inside `body` is
    /// the count's, not the walk's answering first for a tree that was parsed anyway.
    private func whereOnlyTheCountRefuses(_ body: () throws -> Void) rethrows {
        var limits = MarkupGuard.Limits.standard
        limits.deepestTree = .max
        try MarkupGuard.$limits.withValue(limits) { try body() }
    }

    // MARK: - The count

    /// Quotes count one each, with or without the space after the mark.
    func testBlockQuotesCountOneEach() {
        XCTAssertEqual(depth("Plain words."), 0)
        XCTAssertEqual(depth("> One"), 1)
        XCTAssertEqual(depth("> > > Three"), 3)
        XCTAssertEqual(depth(">>>Three"), 3)
        XCTAssertEqual(depth("Text\n> > Two\nText"), 2)
    }

    /// A list marker counts one, and one after another on its line is a list inside it.
    func testListMarkersCountOneEach() {
        for marker in ["-", "+", "*", "1.", "23)"] {
            XCTAssertEqual(depth("\(marker) Item"), 1, marker)
        }
        XCTAssertEqual(depth("- - - Three"), 3)
        XCTAssertEqual(depth("> - Quoted item"), 2)
        // A marker needs white space (or the line's end) after it, and at most nine digits.
        XCTAssertEqual(depth("-dash\n*emphasis*\n1.5 apples\n1234567890. Number"), 0)
        XCTAssertEqual(depth("-"), 1)
    }

    /// Lists nested by indentation count by the indentation: two columns a level, as the least a
    /// nested list may be indented, so a book's lists are counted exactly.
    func testNestedListsCountByTheirIndentation() {
        XCTAssertEqual(depth(nestedList(1)), 1)
        XCTAssertEqual(depth(nestedList(3)), 3)
        XCTAssertEqual(depth(nestedList(6)), 6)
        // Four columns a level counts more (two for the indent and one for the marker), never less.
        let wide = "- a\n    - b\n        - c"
        XCTAssertGreaterThanOrEqual(depth(wide), 3)
    }

    /// A line of one repeated `-` or `*` marker is a thematic break, which opens no list, even
    /// when it is long; the same markers followed by words are nested lists.
    func testAThematicBreakOpensNothing() {
        XCTAssertEqual(depth("* * *"), 0)
        XCTAssertEqual(depth("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"), 0)
        XCTAssertEqual(depth("Before\n* * *\nAfter"), 0)
        XCTAssertEqual(depth("* * * words"), 3)
        XCTAssertEqual(depth("- * -"), 3, "different markers are not a thematic break")
        XCTAssertEqual(depth("> * * *"), 1, "the quote counts, the break does not")
    }

    /// Carriage returns and CR LF pairs end lines, and the count stops at the limit given.
    func testLineEndingsAndTheStop() {
        XCTAssertEqual(depth("> One\r\n> > Two\r\nText\r\n"), 2)
        XCTAssertEqual(depth("> One\r> > Two\rText"), 2)
        let deep = String(repeating: ">", count: 5_000)
        let stopped = MarkdownNesting.deepest(in: deep, stopAbove: 10)
        XCTAssertGreaterThan(stopped, 10)
        XCTAssertLessThanOrEqual(stopped, 5_000)
    }

    // MARK: - The refusal

    /// Thousands of nested quotes are refused with the sentence HTML's refusal gives, and do not
    /// crash. The walk's limit is lifted, so only the count of quotes before the parse can refuse.
    func testThousandsOfNestedQuotesAreRefused() throws {
        let markdown = String(repeating: ">", count: 5_000) + " words"
        try whereOnlyTheCountRefuses {
            XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: markdown)) {
                XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
                XCTAssertTrue(($0 as? MarkupRefusal)?.errorDescription?.contains("128") == true)
            }
        }
    }

    /// So are thousands of nested lists, by marker and by indentation, by the count alone.
    func testThousandsOfNestedListsAreRefused() throws {
        try whereOnlyTheCountRefuses {
            for markdown in [String(repeating: "- ", count: 5_000) + "words", nestedList(2_000)] {
                XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: markdown)) {
                    XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
                }
            }
        }
    }

    /// The limit is the one `MarkupGuard` has: 128 levels read, 129 are refused.
    func testTheLimitIsMarkupGuards() throws {
        XCTAssertEqual(MarkupGuard.Limits.standard.deepestNesting, 128)
        let chapter = try MarkdownDocParser.parseChapter(markdown: quotes(128))
        XCTAssertEqual(chapter.text, "Quoted words")
        XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: quotes(129))) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: 128))
        }
    }

    /// A limit bound for a reading is the limit of its Markdown too, on any thread.
    func testALimitBoundForTheReadingIsKept() throws {
        var limits = MarkupGuard.Limits.standard
        limits.deepestNesting = 10
        try MarkupGuard.$limits.withValue(limits) {
            XCTAssertNoThrow(try MarkdownDocParser.parseChapter(markdown: quotes(10)))
            XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: quotes(11))) {
                XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: 10))
            }
        }
    }

    /// The second layer: a tree deeper than its own limit is refused after the parse, though the
    /// count let it through, and the text read before the limit is not passed on as the chapter.
    func testATreeDeeperThanItsLimitIsRefusedAfterTheParse() throws {
        var limits = MarkupGuard.Limits.standard
        limits.deepestNesting = .max
        limits.deepestTree = 20
        try MarkupGuard.$limits.withValue(limits) {
            XCTAssertNoThrow(try MarkdownDocParser.parseChapter(markdown: quotes(10)))
            XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: quotes(30))) {
                XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: .max))
            }
        }
    }

    /// The rest of a line that begins with a page marker is parsed again as a text of its own
    /// (ST05), and is counted like one, so nested quotes there are refused too. The rest holds
    /// 200 quotes: past the count's limit of 128, yet a tree of about 204 levels, under the walk's
    /// own limit of 272, so only the count of the rest can refuse it.
    func testTheRestOfAMarkerLineIsCountedLikeAnyText() throws {
        let markdown = "<!-- page: 3 --> " + String(repeating: ">", count: 200) + " words"
        XCTAssertThrowsError(try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
        }
        // A shallow rest reads as it did.
        let shallow = try MarkdownDocParser.parseChapter(markdown: "<!-- page: 3 --> > Quoted words", includeNavigationHeadings: true)
        XCTAssertTrue(shallow.text.contains("Quoted words"))
    }

    // MARK: - Text as books nest it

    /// Quotes and lists as books nest them read as they did: their words, in order.
    func testBooksAsTheyNestStillRead() throws {
        XCTAssertEqual(try MarkdownDocParser.parseChapter(markdown: quotes(5)).text, "Quoted words")
        // Six nested lists: five items before the last, whose words end the text.
        let listed = try MarkdownDocParser.parseChapter(markdown: nestedList(6)).text
        XCTAssertEqual(listed.components(separatedBy: "item").count - 1, 5)
        XCTAssertTrue(listed.hasSuffix("Listed words"))
        let book = "# Title\n\nA paragraph.\n\n> A quote\n>\n> > A quote in a quote\n\n1. First\n2. Second\n   - Inner\n\n* * *\n\nEnd."
        let chapter = try MarkdownDocParser.parseChapter(markdown: book)
        XCTAssertTrue(chapter.text.contains("A quote in a quote"))
        XCTAssertTrue(chapter.text.contains("Inner"))
        XCTAssertTrue(chapter.text.hasSuffix("End."))
    }

    /// A text file whose lines are centered with spaces, or bulleted, is not near the limit.
    func testPlainTextWithIndentedLinesIsNotRefused() throws {
        let centered = String(repeating: " ", count: 40) + "CHAPTER ONE\n\n" + String(repeating: " ", count: 30) + "* * *\n\n- a dash list\n- another\n"
        XCTAssertNoThrow(try MarkdownDocParser.parseChapter(markdown: centered))
        XCTAssertLessThan(depth(centered), 40)
    }
}
