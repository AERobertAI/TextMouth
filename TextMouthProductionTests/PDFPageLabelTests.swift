import CoreGraphics
import PDFKit
import XCTest
@testable import TextMouth

/// PG06: a PDF's pages become page markers in content.md. Every page gets a
/// block marker before its text (and before its outline headings), labelled
/// as PDFKit reads the PDF's `/PageLabels` ("i", "ii", "1", "A-1") or, with
/// none, by its number; a page without text keeps its marker; and the
/// reading text is exactly what it was without pages, so no saved place moves.
final class PDFPageLabelTests: XCTestCase {

    // MARK: - Helpers

    /// The Markdown of the PDF at `url`, read without OCR, with or without
    /// page markers.
    private func markdown(of url: URL, includesPages: Bool) throws -> String {
        try PDFTextParser.extract(from: url, recognizer: nil, includesPages: includesPages).markdown
    }

    /// `markdown` read as the reader reads content.md.
    private func parsed(_ markdown: String) -> DocumentContent {
        MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Pages", bookAuthor: "Test")
    }

    /// The first chapter's reading text, with a check that the book is one
    /// chapter (a PDF's outline headings are headings, not chapters).
    private func readingText(of content: DocumentContent) -> String {
        content.chapters.first?.text ?? ""
    }

    /// The UTF-16 offset in `text` at which `phrase` first begins, or nil.
    private func offset(of phrase: String, in text: String) -> Int? {
        let range = (text as NSString).range(of: phrase)
        return range.location == NSNotFound ? nil : range.location
    }

    /// Markdown with every page marker, and the line breaks after it, taken
    /// out, and trimmed of whitespace at its ends.
    private func withoutMarkers(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"<!-- page: [^\n]* -->\n{0,2}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A PDF of `pageCount` letter-size pages written to `Data` with Core
    /// Graphics, each page drawn by `draw` (given the context and the page's
    /// index), saved as `name` in a sandbox folder of this test's own.
    private func makePDF(pages pageCount: Int, named name: String, draw: (CGContext, Int) -> Void) throws -> URL {
        let data = NSMutableData()
        var box = PDFFixtures.letter
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            draw(context, index)
            context.endPDFPage()
        }
        context.closePDF()
        let url = try makeSandboxDirectory("PDFPages").appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    // MARK: - Labels

    /// The sample's five pages carry the labels i, ii, 1, 2, A-1, each at the
    /// start of its own line of text, and the page count says "of 2": the
    /// largest label that is a whole number.
    func testLabelledSampleGivesItsFiveLabelsEachAtItsText() throws {
        let url = try copyOfFormatSample("pdf/labelled-pages.pdf")

        let content = parsed(try markdown(of: url, includesPages: true))

        let text = readingText(of: content)
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertEqual(content.pages.count, 5)
        XCTAssertEqual(content.pages.total, 2)
        guard content.pages.breaks.count == 5 else { return }
        let expected = [
            ("i", "This is page one."), ("ii", "This is page two."), ("1", "This is page three."),
            ("2", "This is page four."), ("A-1", "This is page five."),
        ]
        for (page, (label, phrase)) in zip(content.pages.breaks, expected) {
            XCTAssertEqual(page.label, label)
            XCTAssertEqual(page.characterOffset, offset(of: phrase, in: text), "page \(label)")
        }
    }

    /// The Markdown of the sample is the five markers, each a block of its
    /// own before its line.
    func testLabelledSampleMarkersAreBlocksBeforeEachPage() throws {
        let url = try copyOfFormatSample("pdf/labelled-pages.pdf")

        let markdown = try markdown(of: url, includesPages: true)

        XCTAssertEqual(markdown, """
            <!-- page: i -->

            This is page one.

            <!-- page: ii -->

            This is page two.

            <!-- page: 1 -->

            This is page three.

            <!-- page: 2 -->

            This is page four.

            <!-- page: A-1 -->

            This is page five.
            """)
    }

    // MARK: - The TestData PDFs

    /// Both TestData PDFs give pages 1, 2, 3 in order, and what they read
    /// as (text, headings, chapters) is the same as without pages.
    func testTestDataPDFsGivePagesWithoutChangingTheReading() throws {
        for name in ["test_with_outline.pdf", "test_formatted.pdf"] {
            let url = try requireFile(name)

            let withPages = parsed(try markdown(of: url, includesPages: true))
            let without = parsed(try markdown(of: url, includesPages: false))

            XCTAssertEqual(withPages.pages.breaks.map(\.label), ["1", "2", "3"], name)
            XCTAssertTrue(without.pages.isEmpty, name)
            XCTAssertEqual(withPages.chapters.map(\.title), without.chapters.map(\.title), name)
            XCTAssertEqual(withPages.chapters.map(\.text), without.chapters.map(\.text), name)
            XCTAssertEqual(
                withPages.allHeadings.map { "\($0.level)|\($0.text)|\($0.chapterIndex)|\($0.characterOffset)" },
                without.allHeadings.map { "\($0.level)|\($0.text)|\($0.chapterIndex)|\($0.characterOffset)" },
                name
            )
            // The pages are in order along the text.
            let offsets = withPages.pages.breaks.map(\.characterOffset)
            XCTAssertEqual(offsets, offsets.sorted(), name)
        }
    }

    /// In the outline PDF, each outline entry's heading is on the page its
    /// outline destination names: the page's marker comes before the
    /// heading, so the page's offset is at or before the heading's.
    func testOutlineHeadingsAreOnTheirPagesAfterTheMarker() throws {
        let url = try requireFile("test_with_outline.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        var destinations: [String: String] = [:]
        collectOutline(document.outlineRoot, into: &destinations)
        XCTAssertFalse(destinations.isEmpty)

        let content = parsed(try markdown(of: url, includesPages: true))

        var matched = 0
        for heading in content.allHeadings {
            guard let expectedLabel = destinations[heading.text] else { continue }
            let index = content.pages.index(ofPageAtChapter: heading.chapterIndex, offset: heading.characterOffset)
            guard let index, content.pages.breaks.indices.contains(index) else {
                XCTFail("no page holds the heading \(heading.text)")
                continue
            }
            let page = content.pages.breaks[index]
            XCTAssertEqual(page.label, expectedLabel, heading.text)
            XCTAssertLessThanOrEqual(page.characterOffset, heading.characterOffset, heading.text)
            matched += 1
        }
        XCTAssertGreaterThan(matched, 0)
    }

    /// Fills `destinations` with each outline entry's title and the label of
    /// the page it points to, from `outline` and everything below it.
    private func collectOutline(_ outline: PDFOutline?, into destinations: inout [String: String]) {
        guard let outline else { return }
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if let title = child.label, let label = child.destination?.page?.label {
                destinations[title] = label
            }
            collectOutline(child, into: &destinations)
        }
    }

    // MARK: - Without pages

    /// With `includesPages: false` the Markdown holds no marker, and it is
    /// the pages' Markdown with every marker (and the blank line after it)
    /// taken out: the plain join, and the outline path, as they were.
    func testWithoutPagesTheMarkdownIsTheOtherWithoutItsMarkers() throws {
        let urls = [
            try requireFile("test_with_outline.pdf"),
            try requireFile("test_formatted.pdf"),
            try copyOfFormatSample("pdf/labelled-pages.pdf"),
        ]
        for url in urls {
            let name = url.lastPathComponent

            let withPages = try markdown(of: url, includesPages: true)
            let without = try markdown(of: url, includesPages: false)

            XCTAssertTrue(withPages.contains("<!-- page: "), name)
            XCTAssertFalse(without.contains("<!-- page:"), name)
            XCTAssertEqual(withoutMarkers(withPages), without, name)
        }
    }

    // MARK: - Pages without text

    /// Pages that hold no text keep their markers, in order, at the place
    /// the next text begins (or the text's end), and the reading text is
    /// just the two pages' words.
    func testBlankPagesKeepTheirMarkers() throws {
        let words = ["One", nil, "Three", nil]
        let url = try makePDF(pages: words.count, named: "blanks.pdf") { context, index in
            guard let word = words[index] else { return }
            PDFFixtures.drawText(word, size: 24, at: CGPoint(x: 72, y: 700), in: context)
        }

        let content = parsed(try markdown(of: url, includesPages: true))

        let text = readingText(of: content)
        XCTAssertEqual(text, "One\n\nThree")
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2", "3", "4"])
        let three = offset(of: "Three", in: text)
        XCTAssertEqual(content.pages.breaks.map(\.characterOffset), [0, three ?? -1, three ?? -1, (text as NSString).length])
        // The place of "Three" is on page 3, the last of the pages that
        // begin there.
        let position = content.pages.position(atChapter: 0, offset: three ?? 0)
        XCTAssertEqual(position.number, 3)
        XCTAssertEqual(position.label, "Page 3 of 4")
    }

    // MARK: - Number labels

    /// PDFKit writes the thousandth page of a PDF without labels as "1,000"
    /// (or "1.000", "1 000" in other locales): the marker says "1000", so it
    /// counts as a whole number in "of N". Roman numerals, prefixed labels,
    /// and numbers that are not one to three digits and groups of exactly
    /// three stay as PDFKit gave them.
    func testPlainNumberLabelRemovesOnlyANumbersGroupingSeparators() {
        for (given, expected) in [
            ("1,000", "1000"), ("12.345", "12345"), ("1 000", "1000"), ("123,456", "123456"),
            ("1\u{00A0}000", "1000"), ("1\u{202F}000", "1000"), ("1'000", "1000"), ("1\u{2019}000", "1000"),
            ("1,000,000", "1000000"), ("1.234,567", "1234567"),
            ("7", "7"), ("2000", "2000"), ("", ""), ("xiv", "xiv"), ("A-1", "A-1"),
            ("1,5", "1,5"), ("1,00", "1,00"), ("1,0000", "1,0000"), ("1234,567", "1234,567"),
            ("-1,000", "-1,000"), (",000", ",000"), ("1,", "1,"), ("1,,000", "1,,000"), ("A,000", "A,000"),
            ("1,000a", "1,000a"), ("\u{0661},000", "\u{0661},000"),
        ] {
            XCTAssertEqual(PDFTextParser.plainNumberLabel(given), expected, "label \(given)")
        }
    }

    // MARK: - A long PDF

    /// A 2,000-page PDF keeps every page, in order, labelled 1 to 2000. The
    /// time is logged, not asserted: the suite runs on a busy Mac.
    func testTwoThousandPagesKeepEveryMarker() throws {
        let count = 2000
        let url = try makePDF(pages: count, named: "long.pdf") { context, index in
            PDFFixtures.drawText("Line \(index + 1)", size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }

        let started = Date()
        let markdown = try markdown(of: url, includesPages: true)
        print("PDFPageLabelTests: extracting \(count) pages took \(Date().timeIntervalSince(started)) s")
        let content = parsed(markdown)

        XCTAssertEqual(content.pages.count, count)
        XCTAssertEqual(content.pages.total, count)
        XCTAssertEqual(content.pages.breaks.map(\.label), (1...count).map(String.init))
        let offsets = content.pages.breaks.map(\.characterOffset)
        XCTAssertEqual(offsets, offsets.sorted())
    }
}
