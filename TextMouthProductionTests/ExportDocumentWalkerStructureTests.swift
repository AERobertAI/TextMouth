import XCTest
@testable import TextMouth

/// What the walk of a book's content.md keeps besides its words when a
/// writer asks for the book's structure (FMT28): where the chapters begin
/// and every page marker, read where the reader reads it; and that a walk
/// that does not ask keeps none of it.
final class ExportDocumentWalkerStructureTests: XCTestCase {
    // MARK: - Helpers

    /// The document of `markdown`, with a blank title so no title heading
    /// is added to what a test pins.
    private func walk(_ markdown: String, _ options: ExportWalkOptions = .bookStructure) throws -> ExportDocument {
        try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""), options: options)
    }

    /// The start of a page with `label` and `id`.
    private func page(_ label: String, _ id: String) -> ExportPageBreak {
        ExportPageBreak(label: label, id: id)
    }

    /// A paragraph of one plain run.
    private func paragraph(_ words: String) -> ExportBlock {
        .paragraph([ExportRun(words)])
    }

    // MARK: - A Walk of the Words Alone

    /// Without the structure asked for, markers are the comments they always
    /// were: no page, no chapter start, the words of the book unchanged.
    func testAPlainWalkKeepsNoPageAndNoChapterStart() throws {
        let document = try walk(
            "<!-- chapter: One -->\nAlpha <!-- page: 2 --> beta.\n\n<!-- page: 3 -->\nGamma.", .plain
        )
        XCTAssertEqual(document.chapterStarts, [])
        XCTAssertEqual(document.blocks, [
            .heading(ExportHeading(level: 1, runs: [ExportRun("One")], id: "one")),
            .paragraph([ExportRun("Alpha  beta.")]),
            paragraph("Gamma."),
        ])
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks), [])
    }

    /// The default options are the plain ones: a caller that says nothing
    /// gets what every writer always got.
    func testTheDefaultWalkIsThePlainOne() throws {
        let markdown = "Alpha <!-- page: 2 --> beta."
        XCTAssertEqual(
            try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: "")),
            try walk(markdown, .plain)
        )
    }

    // MARK: - Pages

    /// A page marker between blocks is a page break between them, with an
    /// id of its number.
    func testAMarkerBetweenBlocksIsAPageBreakBetweenThem() throws {
        let document = try walk("Alpha.\n\n<!-- page: 3 -->\nBeta.")
        XCTAssertEqual(document.blocks, [paragraph("Alpha."), .pageBreak(page("3", "page_1")), paragraph("Beta.")])
    }

    /// A marker inside a paragraph is a run of its own at its place, with
    /// no text, and the words around it are untouched.
    func testAMarkerInsideAParagraphIsARunAtItsPlace() throws {
        let document = try walk("Words <!-- page: 4 --> more.")
        XCTAssertEqual(document.blocks, [
            .paragraph([ExportRun("Words "), ExportRun("", pageBreak: page("4", "page_1")), ExportRun(" more.")]),
        ])
    }

    /// A marker at the start or the end of a paragraph keeps its place at
    /// that end, and the paragraph's white space is still trimmed.
    func testAMarkerAtTheEndsOfAParagraphStaysThere() throws {
        let document = try walk("**<!-- page: 1 -->** Words here.<!-- page: 2 -->")
        guard case .paragraph(let runs)? = document.blocks.first else { return XCTFail("\(document.blocks)") }
        XCTAssertEqual(runs.map(\.pageBreak?.label), ["1", nil, "2"])
        XCTAssertEqual(runs[1].text, "Words here.")
    }

    /// A paragraph that is only the start of a page is that and no paragraph.
    func testAParagraphThatIsOnlyAMarkerIsAPageBreak() throws {
        XCTAssertEqual(try walk("**<!-- page: 5 -->**").blocks, [.pageBreak(page("5", "page_1"))])
    }

    /// A marker in a heading starts its page where the heading does: a break
    /// before the heading, which holds none of it.
    func testAMarkerInAHeadingIsABreakBeforeIt() throws {
        let document = try walk("## <!-- page: 7 -->Title <!-- page: 8 -->here")
        XCTAssertEqual(document.blocks, [
            .pageBreak(page("7", "page_1")),
            .pageBreak(page("8", "page_2")),
            .heading(ExportHeading(level: 2, runs: [ExportRun("Title here")], id: "title-here")),
        ])
    }

    /// A heading that is only a marker is no heading: its page remains.
    func testAHeadingThatIsOnlyAMarkerIsOnlyAPage() throws {
        XCTAssertEqual(try walk("## <!-- page: 7 -->").blocks, [.pageBreak(page("7", "page_1"))])
    }

    /// A marker in a table's cell starts its page before the table, which
    /// keeps its cells' words.
    func testAMarkerInATableCellIsABreakBeforeTheTable() throws {
        let document = try walk("| A | B |\n|---|---|\n| x <!-- page: 8 --> | y |")
        XCTAssertEqual(document.blocks, [
            .pageBreak(page("8", "page_1")),
            .table(ExportTable(rows: [["A", "B"], ["x", "y"]], hasHeaderRow: true)),
        ])
    }

    /// A marker in a list item or a quote is found where it stands, and
    /// pages are numbered in reading order across them.
    func testPagesInListsAndQuotesAreFoundInReadingOrder() throws {
        let document = try walk("- one <!-- page: 3 --> two\n\n> quoted\n>\n> <!-- page: 4 -->\n> more\n\n<!-- page: 5 -->\nend")
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks), [
            page("3", "page_1"), page("4", "page_2"), page("5", "page_3"),
        ])
    }

    /// A marker's text in code is code, not a page.
    func testAMarkerInCodeIsNotAPage() throws {
        let document = try walk("```\n<!-- page: 3 -->\n```")
        XCTAssertEqual(document.blocks, [.codeBlock("<!-- page: 3 -->")])
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks), [])
    }

    /// Two pages in a row are two, even with one label; the page's id is its
    /// number among the book's pages.
    func testTwoPagesInARowAreTwoWithIdsInOrder() throws {
        let document = try walk("<!-- page: 5 -->\n\n<!-- page: 5 -->\n\nWords <!-- page: 5 --><!-- page: 5 --> end.")
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks).map(\.id), ["page_1", "page_2", "page_3", "page_4"])
    }

    /// A page label is read as the reader reads it: a leading "Page" is
    /// taken off, and a comment that is no marker of ours is no page.
    func testLabelsAreNormalizedAndOtherCommentsAreNoPages() throws {
        let document = try walk("<!-- page: Page 12 -->\n\n<!-- a plain comment -->\n\n<!-- page: -->\n\nWords.")
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks), [page("12", "page_1")])
    }

    /// Ids of pages never take a heading's: a heading named "page_1" can't be
    /// made (ids are of letters, digits, and hyphens), so the two never meet.
    func testPageIdsAreNotHeadingIds() throws {
        let document = try walk("# Page 1\n\n<!-- page: 1 -->\nWords.")
        XCTAssertEqual(ExportBlock.headings(in: document.blocks).map(\.id), ["page-1"])
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks).map(\.id), ["page_1"])
    }

    // MARK: - Words after a Line's Markers (ST05)

    /// Words that follow a marker on its line are the book's words, as the
    /// reader reads them: kept by a walk that keeps pages (after the page
    /// break), and by one that does not.
    func testWordsAfterAMarkerOnItsLineAreKept() throws {
        let markdown = "<!-- page: 2 --> Words after.\n\nNext."
        XCTAssertEqual(try walk(markdown).blocks, [
            .pageBreak(page("2", "page_1")), paragraph("Words after."), paragraph("Next."),
        ])
        XCTAssertEqual(try walk(markdown, .plain).blocks, [paragraph("Words after."), paragraph("Next.")])
    }

    /// Several markers before the words, a heading annotation among them:
    /// the pages are kept, the annotation is not, and the words are read.
    func testSeveralMarkersBeforeWordsAreAllRead() throws {
        let annotation = MarkdownHeadingAnnotation(level: 2, text: "Somewhere").markdown
        let document = try walk("<!-- page: 1 -->\(annotation)<!-- page: 2 -->Words.")
        XCTAssertEqual(document.blocks, [
            .pageBreak(page("1", "page_1")), .pageBreak(page("2", "page_2")), paragraph("Words."),
        ])
        XCTAssertFalse(document.blocks.map(\.plainText).joined().contains("Somewhere"))
    }

    /// A long line of markers is read in a loop, in a moment, and every
    /// marker is a page.
    func testALongLineOfMarkersIsReadInALoop() throws {
        let line = String(repeating: "<!-- page: 1 -->", count: 3_000) + "Words."
        let document = try walk(line)
        XCTAssertEqual(ExportBlock.pageBreaks(in: document.blocks).count, 3_000)
        XCTAssertEqual(document.blocks.last, paragraph("Words."))
    }

    // MARK: - Chapters

    /// The document says where each chapter begins in its blocks and what it
    /// is called, and adds no heading to a chapter that has none: the words
    /// are the book's. (A walk of the words alone gives such a chapter its
    /// title as a heading, as the reader does.)
    func testChapterStartsAreTheIndexOfEachChaptersFirstBlock() throws {
        let markdown = "<!-- chapter: A -->\nOne.\n\n<!-- chapter: B -->\n# Bee\n\nTwo.\n\n<!-- chapter: C -->\nThree."
        let document = try walk(markdown)
        XCTAssertEqual(document.chapterStarts, [
            ExportChapterStart(blockIndex: 0, title: "A"),
            ExportChapterStart(blockIndex: 1, title: "B"),
            ExportChapterStart(blockIndex: 3, title: "C"),
        ])
        XCTAssertEqual(document.blocks, [
            paragraph("One."),
            .heading(ExportHeading(level: 1, runs: [ExportRun("Bee")], id: "bee")),
            paragraph("Two."),
            paragraph("Three."),
        ])
        let plain = try walk(markdown, .plain)
        XCTAssertEqual(ExportBlock.headings(in: plain.blocks).map(\.plainText), ["A", "Bee", "C"])
    }

    /// A book with no chapter marker is one chapter with no title.
    func testABookWithNoChapterMarkerIsOneUntitledChapter() throws {
        XCTAssertEqual(try walk("Words.").chapterStarts, [ExportChapterStart(blockIndex: 0, title: "")])
    }

    /// The book's identity is in the details a book's walk is given.
    func testTheDetailsOfABookCarryItsIdentity() {
        let id = UUID()
        XCTAssertEqual(ExportBookDetails(title: "T", identifier: id).identifier, id)
        XCTAssertNil(ExportBookDetails(title: "T").identifier)
    }
}
