import CoreGraphics
import XCTest
@testable import TextMouth

/// How a picture's recognized lines become its page's paragraphs, and a
/// book's pages its content.md (FMT34): a chapter for each page with text in
/// a book of several, a marker for every page, and each line read back
/// exactly as recognized.
final class PageImageTextTests: XCTestCase {
    /// The recognized lines these tests lay out.
    private typealias Script = PageImageFixtures

    // MARK: - Paragraphs

    /// Lines a usual line apart are one paragraph; a blank line's gap begins
    /// another, as a letter's address, date, and greeting stand apart.
    func testAGapBeginsAParagraph() {
        let lines = Script.paragraph(["Harbour Office", "12 Quay Road"], startingAt: 0.95)
            + [Script.line("15 March 2026", top: 0.80)]
            + Script.paragraph(["Dear Ms. Ferreira,"], startingAt: 0.70)
            + Script.paragraph(["The ferry timetable changes", "on Monday."], startingAt: 0.62)

        XCTAssertEqual(
            PageImageText.paragraphs(of: lines),
            [["Harbour Office", "12 Quay Road"], ["15 March 2026"], ["Dear Ms. Ferreira,"],
             ["The ferry timetable changes", "on Monday."]]
        )
    }

    /// An indented line after one that ends a sentence begins a paragraph,
    /// as a book page's paragraphs do; one after a line that runs on does
    /// not, and the indent is measured from the paragraph's left edge.
    func testAnIndentAfterASentenceBeginsAParagraph() {
        let lines = [
            Script.line("The tide was out when the boat", top: 0.90, left: 0.10),
            Script.line("came in.", top: 0.85, left: 0.10),
            Script.line("Nobody had expected it", top: 0.80, left: 0.15),
            Script.line("so early, and", top: 0.75, left: 0.10),
            Script.line("    nobody minded", top: 0.70, left: 0.15),
        ]

        XCTAssertEqual(
            PageImageText.paragraphs(of: lines),
            [["The tide was out when the boat", "came in."], ["Nobody had expected it", "so early, and", "nobody minded"]]
        )
    }

    /// A dish and its price on one row stay together, whatever the gap
    /// between them, and empty lines are left out.
    func testLinesOnOneRowStayTogether() {
        let lines = [
            RecognizedTextLine(text: "Soup of the day", normalizedBounds: CGRect(x: 0.1, y: 0.80, width: 0.4, height: 0.04)),
            RecognizedTextLine(text: "6.50", normalizedBounds: CGRect(x: 0.8, y: 0.805, width: 0.1, height: 0.04)),
            RecognizedTextLine(text: "  ", normalizedBounds: CGRect(x: 0.1, y: 0.77, width: 0.1, height: 0.04)),
            RecognizedTextLine(text: "Grilled sardines", normalizedBounds: CGRect(x: 0.1, y: 0.75, width: 0.4, height: 0.04)),
            RecognizedTextLine(text: "11.00", normalizedBounds: CGRect(x: 0.8, y: 0.75, width: 0.1, height: 0.04)),
        ]

        XCTAssertEqual(PageImageText.paragraphs(of: lines), [["Soup of the day", "6.50", "Grilled sardines", "11.00"]])
    }

    /// No lines, or only empty ones, make no paragraph.
    func testNoLinesMakeNoParagraphs() {
        XCTAssertEqual(PageImageText.paragraphs(of: []), [])
        XCTAssertEqual(PageImageText.paragraphs(of: [Script.line(" \t", top: 0.5)]), [])
    }

    // MARK: - Markdown

    /// A book of one page is one chapter titled by the book: its page's
    /// marker, then its paragraphs; without pages, the text alone.
    func testABookOfOnePage() {
        let page = PageImagePageText(title: "Page 1", paragraphs: [["Harbour Office", "12 Quay Road"], ["Dear Ms. Ferreira,"]])

        XCTAssertEqual(
            PageImageText.markdown(of: [page], includesPages: true),
            "<!-- page: 1 -->\n\nHarbour Office\n12 Quay Road\n\nDear Ms. Ferreira,"
        )
        XCTAssertEqual(
            PageImageText.markdown(of: [page], includesPages: false),
            "Harbour Office\n12 Quay Road\n\nDear Ms. Ferreira,"
        )
    }

    /// A book of several pages has a chapter for each page with text; a
    /// page without text keeps its marker after the page before it, or
    /// before the first page with text.
    func testABookOfSeveralPages() {
        let pages = [
            PageImagePageText(title: "Front Cover", paragraphs: []),
            PageImagePageText(title: "Page 2", paragraphs: [["Harbour Notices"]]),
            PageImagePageText(title: "Page 3", paragraphs: []),
            PageImagePageText(title: "Page 4", paragraphs: [["Sailings resume", "at dawn."]]),
        ]

        XCTAssertEqual(
            PageImageText.markdown(of: pages, includesPages: true),
            """
            <!-- chapter: Page 2 -->
            <!-- page: 1 -->

            <!-- page: 2 -->

            Harbour Notices

            <!-- page: 3 -->

            <!-- chapter: Page 4 -->
            <!-- page: 4 -->

            Sailings resume
            at dawn.
            """
        )
        XCTAssertEqual(
            PageImageText.markdown(of: pages, includesPages: false),
            "<!-- chapter: Page 2 -->\nHarbour Notices\n\n<!-- chapter: Page 4 -->\nSailings resume\nat dawn."
        )
    }

    /// The cache reads the book back as its chapters, pages, and words, each
    /// line exactly as recognized, Markdown's own characters and all.
    func testTheCacheReadsThePagesBackExactly() {
        let tricky = ["# 42 is the berth", "- 2 crates *fragile*", "1. Report to <office>", "Tickets: $5 & up_front"]
        let pages = [
            PageImagePageText(title: "Page 1", paragraphs: [tricky]),
            PageImagePageText(title: "Page 2", paragraphs: []),
            PageImagePageText(title: "Page 3", paragraphs: [["Last page \"quoted\" -- dashed..."]]),
        ]

        let markdown = PageImageText.markdown(of: pages, includesPages: true)
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Notices", bookAuthor: "Unknown")

        XCTAssertEqual(content.chapters.map(\.title), ["Page 1", "Page 3"])
        XCTAssertEqual(content.chapters.first?.text, tricky.joined(separator: " "), markdown)
        XCTAssertEqual(content.chapters.last?.text, "Last page \"quoted\" -- dashed...", markdown)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2", "3"], markdown)
    }
}
