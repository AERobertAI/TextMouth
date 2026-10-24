import XCTest
@testable import TextMouth

/// Plain text's form feeds begin pages (PG13): page 1 at the book's start,
/// and each form feed between words the next, at the first line after it
/// that is read. A form feed still ends a line, so the reading text, its
/// paragraphs, and its headings are the same with pages and without them.
/// The markers are in content.md only; the direct parse reads none.
final class PlainTextFormFeedPageTests: XCTestCase {
    /// The hosted test root's library index, put back after each test, since
    /// one test imports a book.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
    }

    // MARK: - Helpers

    /// The sample: a heading, a paragraph a form feed cuts after its second
    /// line, an all-caps heading, two form feeds, and a paragraph; with a form
    /// feed before the first words and one after the last.
    private func sampleText() throws -> String {
        try TextFileDecoder.readText(at: copyOfFormatSample("txt-pages/form-feeds.txt"), format: .txt)
    }

    /// The chapter `markdown` reads as, with its markers read, as the cache
    /// reads content.md.
    private func chapter(_ markdown: String) throws -> Chapter {
        try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true)
    }

    /// The UTF-16 offset in `text` where `words` first begin.
    private func offset(of words: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: words), "\"\(words)\" is not in the text")
        return text.utf16Offset(of: range.lowerBound)
    }

    /// Asserts that `text`'s content.md reads the same with pages and
    /// without, in its text and headings, that no marker begins a line
    /// holding words, and returns the chapter it reads as with its pages.
    @discardableResult
    private func assertSameReading(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Chapter {
        let withPages = PlainTextParser.markdown(text: text)
        let withoutPages = PlainTextParser.markdown(text: text, includesPages: false)
        let paged = try chapter(withPages)
        let plain = try chapter(withoutPages)
        XCTAssertEqual(paged.text, plain.text, "reading text", file: file, line: line)
        XCTAssertEqual(paged.headings, plain.headings, "headings", file: file, line: line)
        XCTAssertEqual(paged.text, PlainTextParser.parse(text: text).chapters.first?.text, "the direct reading", file: file, line: line)
        for markdownLine in withPages.components(separatedBy: "\n") where markdownLine.contains("<!--") {
            XCTAssertTrue(MarkdownPageMarker.decode(markdownLine) != nil || !markdownLine.hasPrefix("<!--"),
                          "a marker begins \"\(markdownLine)\"", file: file, line: line)
        }
        return paged
    }

    // MARK: - The Sample

    /// The sample's form feeds begin three pages after page 1: one inside the
    /// first paragraph, at its third line, and two at the second paragraph's
    /// start, the first of them blank. The form feeds before the first words
    /// and after the last begin none. The blocks are those without pages.
    func testTheSamplesFormFeedsBeginPagesBetweenWords() throws {
        let text = try sampleText()
        let paged = PlainTextParser.pagedBlocks(in: text)
        XCTAssertEqual(paged.blocks, PlainTextParser.blocks(in: text))
        XCTAssertEqual(paged.blocks.count, 4)
        XCTAssertEqual(paged.pages, [
            PlainTextParser.FormFeedPage(block: 1, line: 2),
            PlainTextParser.FormFeedPage(block: 3, line: 0),
            PlainTextParser.FormFeedPage(block: 3, line: 0),
        ])
    }

    /// The sample's content.md: page 1 before the first heading, page 2 after
    /// the words of the line before its first line, inside the paragraph,
    /// and pages 3 and 4 before the second paragraph. Without pages it is
    /// what cache format 3.0.7 wrote: the same, less the markers.
    func testTheSamplesContentHasAMarkerWhereEachPageBegins() throws {
        let text = try sampleText()
        let expected = #"""
            <!-- page: 1 -->

            # Ferry Timetable Notes

            The first boat leaves the north pier at six\,
            and the second waits for the mail train<!-- page: 2 -->
            before it crosses to the island\.

            ## WINTER SERVICE

            <!-- page: 3 -->

            <!-- page: 4 -->

            In winter the evening crossing is cancelled
            when the wind is above force seven\.
            """#
        XCTAssertEqual(PlainTextParser.markdown(text: text), expected)
        XCTAssertEqual(PlainTextParser.markdown(text: text, includesPages: false), #"""
            # Ferry Timetable Notes

            The first boat leaves the north pier at six\,
            and the second waits for the mail train
            before it crosses to the island\.

            ## WINTER SERVICE

            In winter the evening crossing is cancelled
            when the wind is above force seven\.
            """#)
        // The direct parse reads no pages.
        XCTAssertEqual(PlainTextParser.parse(text: text).chapters.first?.pages, [])
    }

    /// Read back, the sample has four pages, numbered 1 to 4, at the words
    /// each begins at, and reads as it does without them.
    func testTheSamplesPagesAreReadAtTheirWords() throws {
        let paged = try assertSameReading(try sampleText())
        XCTAssertEqual(paged.pages.map(\.label), ["1", "2", "3", "4"])
        XCTAssertEqual(paged.pages.map(\.characterOffset), [
            0,
            try offset(of: "before it crosses", in: paged.text),
            try offset(of: "In winter", in: paged.text),
            try offset(of: "In winter", in: paged.text),
        ])
        XCTAssertEqual(BookPages(breaks: paged.pages).total, 4)
    }

    /// Imported, the sample's pages are the book's pages in the reader.
    func testAnImportedTextHasItsFormFeedPages() throws {
        let imported = try importedForTest(copyOfFormatSample("txt-pages/form-feeds.txt"))
        XCTAssertEqual(imported.book.format, .txt)
        let pages = try openedContent(of: imported.book).pages
        XCTAssertEqual(pages.breaks.map(\.label), ["1", "2", "3", "4"])
    }

    // MARK: - Where a Form Feed Begins a Page

    /// A text with no form feed between words has no pages: none at all, one
    /// before the first words, ones after the last, and a text of nothing
    /// but form feeds. Its content.md is the one without pages.
    func testATextWithNoFormFeedBetweenWordsHasNoPages() throws {
        for text in ["One line.\n\nTwo lines\nhere.", "\u{0C}First words.", "Last words.\u{0C}\u{0C}", "\u{0C}\n\u{0C}", ""] {
            XCTAssertEqual(PlainTextParser.pagedBlocks(in: text).pages, [], text.debugDescription)
            XCTAssertEqual(PlainTextParser.markdown(text: text), PlainTextParser.markdown(text: text, includesPages: false),
                           text.debugDescription)
        }
    }

    /// A form feed between two lines of a paragraph begins its page inside
    /// the paragraph; one at a blank line, before a heading, or after a CR
    /// LF begins its page at the block after it.
    func testAFormFeedBeginsItsPageAtTheFirstLineReadAfterIt() throws {
        let cases: [(text: String, pages: [PlainTextParser.FormFeedPage], markdown: String)] = [
            ("one\u{0C}two", [.init(block: 0, line: 1)], "<!-- page: 1 -->\n\none<!-- page: 2 -->\ntwo"),
            ("one\n\u{0C}two", [.init(block: 1, line: 0)], "<!-- page: 1 -->\n\none\n\n<!-- page: 2 -->\n\ntwo"),
            ("one\u{0C}\ntwo", [.init(block: 1, line: 0)], "<!-- page: 1 -->\n\none\n\n<!-- page: 2 -->\n\ntwo"),
            ("one\r\n\u{0C}two", [.init(block: 1, line: 0)], "<!-- page: 1 -->\n\none\n\n<!-- page: 2 -->\n\ntwo"),
            ("one\u{0C}# Two", [.init(block: 1, line: 0)], "<!-- page: 1 -->\n\none\n\n<!-- page: 2 -->\n\n# Two"),
        ]
        for (text, pages, markdown) in cases {
            XCTAssertEqual(PlainTextParser.pagedBlocks(in: text).pages, pages, text.debugDescription)
            XCTAssertEqual(PlainTextParser.markdown(text: text), markdown, text.debugDescription)
            let paged = try assertSameReading(text)
            XCTAssertEqual(paged.pages.map(\.label), ["1", "2"], text.debugDescription)
            // Page 2 begins at the word "two" (a heading's "Two").
            let second = try XCTUnwrap(paged.pages.last)
            let words = paged.text[paged.text.index(atUTF16Offset: second.characterOffset)...]
            XCTAssertTrue(words.lowercased().hasPrefix("two"), "\(text.debugDescription): page 2 begins at \"\(words)\"")
        }
    }

    /// The underline a setext heading takes is no line read: a form feed
    /// before it begins its page at the next line read, after the heading.
    func testAFormFeedBeforeASetextUnderlineBeginsItsPageAfterTheHeading() throws {
        let text = "Before\n\nTitle\u{0C}=====\nAfter the title."
        XCTAssertEqual(PlainTextParser.pagedBlocks(in: text).blocks, [
            .paragraph(lines: ["Before"]), .heading(level: 1, text: "Title"), .paragraph(lines: ["After the title."]),
        ])
        XCTAssertEqual(PlainTextParser.pagedBlocks(in: text).pages, [.init(block: 2, line: 0)])
        let paged = try assertSameReading(text)
        XCTAssertEqual(paged.pages.last?.characterOffset, try offset(of: "After the title", in: paged.text))
    }

    /// Every line ending counts as the line cut counts it, the rarer ones
    /// too (VT, NEL, LS, PS), so a form feed's page begins at its own line.
    func testEveryKindOfLineEndingCountsTowardTheFormFeedsLine() throws {
        for ending in ["\n", "\u{0B}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "one\(ending)two\(ending)three\u{0C}four\(ending)five"
            XCTAssertEqual(PlainTextParser.pagedBlocks(in: text).pages, [.init(block: 0, line: 3)], ending.debugDescription)
            let paged = try assertSameReading(text)
            XCTAssertEqual(paged.pages.last?.characterOffset, try offset(of: "four", in: paged.text), ending.debugDescription)
        }
    }

    // MARK: - Limits (review, October 24)

    /// A hostile text of form feeds gets at most the pages a book may have
    /// (`MarkdownPageMarker.maximumPagesPerBook`, which textutil's reader
    /// keeps too): past them, a form feed begins no page, and the text is
    /// unchanged. A hundred and fifty thousand form feeds between two words
    /// give a hundred thousand pages, written and read in a bounded time.
    func testFormFeedsPastTheMostPagesABookMayHaveBeginNoPage() throws {
        let text = "a" + String(repeating: "\u{0C}", count: 150_000) + "b"
        let began = Date()
        let paged = PlainTextParser.pagedBlocks(in: text)
        XCTAssertEqual(paged.pages.count, MarkdownPageMarker.maximumPagesPerBook - 1)
        XCTAssertEqual(paged.blocks, PlainTextParser.blocks(in: text))
        let chapter = try assertSameReading(text)
        XCTAssertLessThan(Date().timeIntervalSince(began), 60, "a hundred thousand pages took too long")
        XCTAssertEqual(chapter.text, "a\n\nb")
        XCTAssertEqual(chapter.pages.count, MarkdownPageMarker.maximumPagesPerBook)
        XCTAssertEqual(chapter.pages.last?.label, String(MarkdownPageMarker.maximumPagesPerBook))
    }

    /// The limit is the one textutil's reader keeps, not a copy of it.
    func testPlainTextAndTextutilShareOneLimitOfPages() {
        XCTAssertEqual(MarkdownPageMarker.maximumPagesPerBook, 100_000)
        XCTAssertEqual(TextutilPageBreaks.maximumPages, MarkdownPageMarker.maximumPagesPerBook)
    }

    /// A web archive whose page is plain text writes no pages, whatever form
    /// feeds it holds: the format has no page reader (V07), so a book of it
    /// is never read again for pages, and its text must not gain them by
    /// another path.
    func testAWebArchivesTextPageWritesNoPages() throws {
        let page = WebArchiveReader.MainPage(text: "one\u{0C}two", isHTML: false)
        XCTAssertFalse(try page.markdown().contains("<!--"))
        XCTAssertEqual(try page.markdown(), PlainTextParser.markdown(text: "one\u{0C}two", includesPages: false))
    }

    /// Text that looks like Markdown on the line before a page, or on the
    /// page's first line, stays literal: the marker never makes a line raw
    /// HTML, a list, or a heading.
    func testMarkdownLookingLinesAroundAPageStayLiteral() throws {
        for text in ["1. one\u{0C}- two", "> quoted\u{0C}+ item\u{0B}more", "a <b>\u{0C}<!-- page: 9 --> c", "x\\\u{0C}y", "* \u{0C}*", "1984\u{0C}2. two"] {
            try assertSameReading(text)
            XCTAssertEqual(try chapter(PlainTextParser.markdown(text: text)).pages.count, 2, text.debugDescription)
        }
    }
}
