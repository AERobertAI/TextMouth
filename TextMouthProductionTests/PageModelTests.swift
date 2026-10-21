import XCTest
@testable import TextMouth

/// The page model and the parse that finds pages (PG01): where a marker in
/// content.md places a page, that a marker never changes the reading text or
/// the headings, and how a reading position is turned into "Page 12 of 300".
final class PageModelTests: XCTestCase {
    // MARK: - Helpers

    /// `markdown` parsed as generated content.md is, with page markers read.
    private func parse(_ markdown: String, navigation: Bool = true) throws -> Chapter {
        try MarkdownDocParser.parseChapter(
            markdown: markdown, title: "T", includeNavigationHeadings: navigation)
    }

    /// `markdown` with every page marker deleted.
    private func withoutMarkers(_ markdown: String) -> String {
        markdown.replacingOccurrences(
            of: "<!-- page: [^>]*-->", with: "", options: .regularExpression)
    }

    /// The pages of `chapter` as (label, offset) pairs, to compare in one line.
    private func pairs(_ chapter: Chapter) -> [String] {
        chapter.pages.map { "\($0.label)@\($0.characterOffset)" }
    }

    /// The headings of `chapter` as comparable strings (level, offset, text).
    private func headingSummary(_ chapter: Chapter) -> [String] {
        chapter.headings.map { "\($0.level):\($0.characterOffset):\($0.text)" }
    }

    /// Assert that `markdown` has exactly `expected` pages, and that deleting
    /// its markers changes neither the reading text nor the headings.
    private func assertPages(
        _ markdown: String, _ expected: [String], text: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let chapter = try parse(markdown)
        XCTAssertEqual(pairs(chapter), expected, file: file, line: line)
        let plain = try parse(withoutMarkers(markdown))
        XCTAssertEqual(chapter.text, plain.text, "markers must add no text", file: file, line: line)
        XCTAssertEqual(headingSummary(chapter), headingSummary(plain), file: file, line: line)
        if let text {
            XCTAssertEqual(chapter.text, text, file: file, line: line)
        }
    }

    /// A book of `pages` as break lists, for the lookup tests.
    private func book(_ breaks: (String, Int, Int)...) -> BookPages {
        BookPages(breaks: breaks.map { PageBreak(label: $0.0, chapterIndex: $0.1, characterOffset: $0.2) })
    }

    // MARK: - The parse

    func testAPageAtTheStartOfTheText() throws {
        try assertPages("<!-- page: 1 -->\n\nHello world.", ["1@0"], text: "Hello world.")
    }

    func testAPageBetweenParagraphsTakesTheNextParagraphsOffset() throws {
        try assertPages("One.\n\n<!-- page: 2 -->\n\nTwo.", ["2@6"], text: "One.\n\nTwo.")
    }

    func testAnInlinePageTakesItsExactPlace() throws {
        try assertPages("One two <!-- page: 3 -->three four.", ["3@8"])
    }

    func testAPageBeforeASpaceBeginsAtTheNextWord() throws {
        try assertPages("One <!-- page: 3 --> two", ["3@5"], text: "One  two")
    }

    func testAPageInsideAWordBeginsAtTheWordsStart() throws {
        try assertPages("tele<!-- page: 4 -->phone call", ["4@0"])
        try assertPages("a tele<!-- page: 4 -->phone", ["4@2"])
    }

    func testAPageAfterAHardBreakStaysInTheParagraph() throws {
        try assertPages("Line one  \n    <!-- page: 5 -->line two", ["5@9"], text: "Line one\nline two")
    }

    func testAPageBeforeAHeadingSharesTheHeadingsOffset() throws {
        let markdown = "Intro.\n\n<!-- page: 6 -->\n\n# Title\n\nBody."
        try assertPages(markdown, ["6@8"])
        let chapter = try parse(markdown)
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [8])
    }

    func testAPageTypedInsideAHeadingTakesTheHeadingsOffset() throws {
        let markdown = "Intro.\n\n# Ti<!-- page: 7 -->tle\n\nBody."
        try assertPages(markdown, ["7@8"])
        let chapter = try parse(markdown)
        XCTAssertEqual(chapter.headings.map(\.text), ["Title"])
    }

    func testAPageAtTheEndIsClampedToTheText() throws {
        try assertPages("Text.\n\n<!-- page: 8 -->", ["8@5"], text: "Text.")
    }

    func testPagesAtOnePlaceKeepTheirOrder() throws {
        try assertPages("<!-- page: 1 -->\n\n<!-- page: 2 -->\n\nText.", ["1@0", "2@0"], text: "Text.")
    }

    func testOffsetsCountUTF16UnitsNotCharacters() throws {
        // Each emoji is two UTF-16 units: "😀😀 one " is 9.
        try assertPages("😀😀 one <!-- page: 9 -->two", ["9@9"])
    }

    func testTrimmedLeadingWhitespaceShiftsAPagesOffset() throws {
        try assertPages("\u{00A0}\u{00A0}Hello <!-- page: 2 -->world", ["2@6"], text: "Hello world")
    }

    func testAPageInATableCellBeginsAtTheCellsWords() throws {
        let markdown = "| a | b |\n|---|---|\n| c | <!-- page: 3 -->d |"
        let chapter = try parse(markdown)
        try assertPages(markdown, pairs(chapter))
        XCTAssertEqual(chapter.pages.count, 1)
        guard let page = chapter.pages.first else { return }
        let offset = chapter.text.index(atUTF16Offset: page.characterOffset)
        XCTAssertEqual(String(chapter.text[offset...]), "d")
    }

    func testMarkersAreIgnoredWhereNavigationHeadingsAre() throws {
        let chapter = try parse("One two <!-- page: 3 -->three four.", navigation: false)
        XCTAssertTrue(chapter.pages.isEmpty)
        XCTAssertEqual(chapter.text, try parse("One two three four.").text)
    }

    func testMalformedMarkersAreOrdinaryComments() throws {
        XCTAssertTrue(try parse("Text <!-- page: a--b --> more").pages.isEmpty)
        XCTAssertTrue(try parse("<!--page: 1 -->\n\nText").pages.isEmpty)
    }

    func testAMultiChapterBookGivesEachPageItsChaptersIndex() {
        let content = MarkdownCacheService.parseMultiChapterMarkdown(
            "<!-- chapter: One -->\n<!-- page: 1 -->\n\nFirst.\n\n"
                + "<!-- chapter: Two -->\n<!-- page: 2 -->\n\nSecond <!-- page: 3 -->half.",
            bookTitle: "B", bookAuthor: "A")
        XCTAssertEqual(content.pages.breaks, [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "2", chapterIndex: 1, characterOffset: 0),
            PageBreak(label: "3", chapterIndex: 1, characterOffset: 7),
        ])
        XCTAssertEqual(content.chapters.count, 2)
        guard content.chapters.count == 2 else { return }
        // A chapter's own pages carry index 0, as its headings do.
        XCTAssertEqual(content.chapters[1].pages.map(\.label), ["2", "3"])
        XCTAssertEqual(content.chapters[1].pages.map(\.chapterIndex), [0, 0])
    }

    // MARK: - The page total

    func testTheTotalIsTheLargestWholeNumberLabel() {
        func total(_ labels: [String]) -> Int {
            BookPages(breaks: labels.map { PageBreak(label: $0, characterOffset: 0) }).total
        }
        XCTAssertEqual(total(["i", "ii", "xiv", "1", "2", "300"]), 300)
        XCTAssertEqual(total(["i", "ii"]), 2)
        XCTAssertEqual(total(["A-1", "B-2", "C"]), 3)
        XCTAssertEqual(total(["007", "12"]), 12)
        XCTAssertEqual(total([String(repeating: "9", count: 25), "5"]), 5)
        XCTAssertEqual(total(["+5", "-3", "٣"]), 3)
        XCTAssertEqual(total([]), 0)
    }

    func testBreaksAreSortedByPlaceAndThenByGivenOrder() {
        let pages = book(("x", 1, 5), ("y", 0, 3), ("z", 0, 3))
        XCTAssertEqual(pages.breaks.map(\.label), ["y", "z", "x"])
    }

    // MARK: - Positions

    func testAPositionIsInTheLastPageThatBeganAtOrBeforeIt() {
        let pages = book(("1", 0, 0), ("2", 0, 100), ("3", 1, 0))
        let places: [(chapter: Int, offset: Int, number: Int)] = [
            (0, 0, 1), (0, 99, 1), (0, 100, 2), (0, 5000, 2), (1, 0, 3), (2, 0, 3),
        ]
        for place in places {
            let position = pages.position(atChapter: place.chapter, offset: place.offset)
            XCTAssertEqual(position.number, place.number, "\(place)")
            XCTAssertEqual(position.page?.label, String(place.number), "\(place)")
            XCTAssertEqual(position.count, 3)
        }
    }

    func testAPositionBeforeTheFirstPageHasNoPage() {
        let pages = book(("i", 0, 50), ("1", 1, 0))
        let position = pages.position(atChapter: 0, offset: 10)
        XCTAssertNil(position.page)
        XCTAssertNil(position.number)
        XCTAssertEqual(position.label, "Before page i")
    }

    func testOfSeveralPagesAtOnePlaceTheLastHoldsIt() {
        let pages = book(("1", 0, 0), ("2", 0, 0), ("3", 0, 0), ("4", 0, 10))
        let position = pages.position(atChapter: 0, offset: 0)
        XCTAssertEqual(position.page?.label, "3")
        XCTAssertEqual(position.number, 3)
    }

    func testPageLabelsAreSpokenAsPageNOfTotal() {
        let numbered = book(("xii", 0, 0), ("12", 0, 10), ("300", 0, 20))
        XCTAssertEqual(numbered.position(atChapter: 0, offset: 10).label, "Page 12 of 300")
        XCTAssertEqual(numbered.position(atChapter: 0, offset: 0).label, "Page xii of 300")
        let lettered = book(("A", 0, 0), ("B", 0, 10))
        XCTAssertEqual(lettered.position(atChapter: 0, offset: 10).label, "Page B of 2")
        let none = BookPages.none.position(atChapter: 0, offset: 0)
        XCTAssertEqual(none.label, "")
        XCTAssertNil(none.page)
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(none.total, 0)
        XCTAssertNil(none.firstLabel)
    }

    func testBinarySearchAgreesWithALinearScan() {
        // A fixed linear congruential sequence, so the test is repeatable.
        var state: UInt64 = 12345
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var breaks: [PageBreak] = []
        for chapter in 0..<3 {
            var offset = 0
            for _ in 0..<167 {
                offset += next(40)
                breaks.append(PageBreak(label: "p", chapterIndex: chapter, characterOffset: offset))
            }
        }
        let pages = BookPages(breaks: breaks)
        XCTAssertEqual(pages.count, 501)
        for _ in 0..<2000 {
            let chapter = next(4)
            let offset = next(7000)
            let expected = pages.breaks.lastIndex {
                $0.startsAtOrBefore(chapterIndex: chapter, characterOffset: offset)
            }
            XCTAssertEqual(pages.index(ofPageAtChapter: chapter, offset: offset), expected)
        }
    }

    // MARK: - The first word of a page

    func testAPageBeginsAtItsFirstWholeWord() {
        let text = "end.  The next"
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: 4), 6)
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: 6), 6)
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: 8), 6)
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: 0), 0)
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: -3), 0)
        XCTAssertEqual(PageBreak.firstWordStart(in: text, at: 99), 14)
        XCTAssertEqual(PageBreak.firstWordStart(in: "", at: 5), 0)
    }
}
