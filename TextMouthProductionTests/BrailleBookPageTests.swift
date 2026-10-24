import XCTest
@testable import TextMouth

/// A braille book's pages (PG12): each braille page of a BRF or a PEF is a
/// page marker in the book's content.md where its first word is read,
/// labelled by its braille page number read as print, and the reading text
/// is the same, word for word, with pages and without. A marker stands
/// between block lines, never inside one: a page that begins inside a
/// paragraph splits the paragraph's Markdown into lines of one paragraph, and
/// one that begins inside a heading stands before it.
///
/// The Markdown is put together first from print made up here, with no
/// helper (`BrailleBookReader.PagedTranslation`), then read from the samples
/// and from long books laid out by TextMouth's own braille writer with every
/// bundled table, through liblouis in the helper.
final class BrailleBookPageTests: XCTestCase {

    /// The Grade 1 UEB table, which the samples are written in.
    private let grade1 = "en-ueb-g1.ctb"

    // MARK: - Helpers

    /// `ascii` as Unicode braille cells, a space becoming the blank cell.
    private func cells(_ ascii: String) -> String {
        String(String.UnicodeScalarView(ascii.utf8.compactMap { byte in
            byte == 0x20 ? BrailleCells.blank : BrailleCells.cell(forASCII: byte)
        }))
    }

    /// A page labelled `label` that begins at cell `cell` of block `block`.
    private func start(_ label: String, block: Int, cell: Int = 0) -> BrailleBookReader.PageStart {
        BrailleBookReader.PageStart(marker: MarkdownPageMarker(label: label, ordinal: 1), blockIndex: block, cellOffset: cell)
    }

    /// `texts` as print with no emphasis, as the helper would answer.
    private func printed(_ texts: [String]) -> [EmphasizedText] {
        texts.map { EmphasizedText($0) }
    }

    /// The UTF-16 offset in `text` where `words` first begin.
    private func offset(of words: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: words), "\"\(words)\" is not in the text")
        return text.utf16Offset(of: range.lowerBound)
    }

    /// The chapter `markdown` reads as, with its markers read, as the cache
    /// reads content.md.
    private func chapter(_ markdown: String) throws -> Chapter {
        try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true)
    }

    /// Asserts that `withPages` reads exactly as `withoutPages` does, in its
    /// text and its headings, and that no marker begins a line holding words
    /// (CommonMark would read such a line as raw HTML, its words lost).
    private func assertSameReading(
        _ withPages: String, _ withoutPages: String, _ context: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let paged = try chapter(withPages)
        let plain = try chapter(withoutPages)
        XCTAssertEqual(paged.text, plain.text, "reading text; \(context)", file: file, line: line)
        XCTAssertEqual(paged.headings, plain.headings, "headings; \(context)", file: file, line: line)
        for markdownLine in withPages.components(separatedBy: "\n") where markdownLine.contains("<!--") {
            let isMarkerAlone = MarkdownPageMarker.decode(markdownLine) != nil
            XCTAssertTrue(isMarkerAlone || !markdownLine.hasPrefix("<!--"), "a marker begins \"\(markdownLine)\"; \(context)",
                          file: file, line: line)
        }
    }

    // MARK: - Putting the Markdown Together

    /// A page that begins inside a paragraph splits its Markdown into two
    /// lines of one paragraph, the marker after the first line's words;
    /// pages that begin a block stand before it, and a page after the last
    /// block at the end. The helper is sent the blocks whole, then the
    /// paragraph's two pieces, and the reading text is as without pages.
    func testAPageInsideAParagraphSplitsItsLineAndChangesNoWord() throws {
        let blocks: [BrailleBlock] = [
            .heading(level: 1, text: cells("H")), .paragraph(text: cells("A B C D")), .paragraph(text: cells("E")),
        ]
        let translation = BrailleBookReader.PagedTranslation(
            blocks: blocks, starts: [start("1", block: 0), start("2", block: 1, cell: 4), start("3", block: 3)]
        )
        XCTAssertEqual(translation.texts.map(\.text), [cells("H"), cells("A B C D"), cells("E"), cells("A B"), cells("C D")])

        let print = printed(["Title", "one two three four", "five", "one two", "three four"])
        let markdown = try XCTUnwrap(translation.markdown(from: print))
        XCTAssertEqual(markdown, "<!-- page: 1 -->\n\n# Title\n\none two<!-- page: 2 -->\nthree four\n\nfive\n\n<!-- page: 3 -->\n\n")

        let plain = try XCTUnwrap(BrailleBookReader.PagedTranslation(blocks: blocks, starts: []).markdown(from: print))
        XCTAssertEqual(plain, "# Title\n\none two three four\n\nfive")
        try assertSameReading(markdown, plain)
        let paged = try chapter(markdown)
        XCTAssertEqual(paged.pages.map(\.label), ["1", "2", "3"])
        XCTAssertEqual(paged.pages.map(\.characterOffset),
                       [0, try offset(of: "three four", in: paged.text), paged.text.utf16.count])
    }

    /// Without pages the helper is sent the blocks alone, and the Markdown is
    /// the blocks' lines apart by blank lines, as the reader wrote it before
    /// pages: a block with no print is left out, and none is nil.
    func testWithoutPagesTheMarkdownIsTheBlocksAlone() throws {
        let blocks: [BrailleBlock] = [.paragraph(text: cells("A")), .paragraph(text: cells("B")), .heading(level: 2, text: cells("C"))]
        let translation = BrailleBookReader.PagedTranslation(blocks: blocks, starts: [])
        XCTAssertEqual(translation.texts.map(\.text), blocks.map(\.text))
        XCTAssertEqual(translation.markdown(from: printed(["one", "  ", "Three"])), "one\n\n## Three")
        XCTAssertNil(translation.markdown(from: printed(["", " ", "\n"])))
    }

    /// A paragraph over three pages is cut twice, into three lines, and
    /// pages at one place (a page with no text, then the next) are markers
    /// side by side, in order.
    func testAParagraphCutTwiceAndTwoPagesAtOnePlace() throws {
        let blocks: [BrailleBlock] = [.paragraph(text: cells("A B C D E"))]
        let starts = [start("1", block: 0), start("2", block: 0, cell: 4), start("3", block: 0, cell: 8), start("4", block: 0, cell: 8)]
        let translation = BrailleBookReader.PagedTranslation(blocks: blocks, starts: starts)
        XCTAssertEqual(translation.texts.map(\.text), [cells("A B C D E"), cells("A B"), cells("C D"), cells("E")])
        let print = printed(["a b c d e", "a b", "c d", "e"])
        let markdown = try XCTUnwrap(translation.markdown(from: print))
        XCTAssertEqual(markdown, "<!-- page: 1 -->\n\na b<!-- page: 2 -->\nc d<!-- page: 3 --><!-- page: 4 -->\ne")
        try assertSameReading(markdown, "a b c d e")
        XCTAssertEqual(try chapter(markdown).pages.map(\.characterOffset), [0, 4, 8, 8])
    }

    /// Each line of a split paragraph is its own literal with its own
    /// emphasis: an italic passage over the page is two italic stretches, so
    /// no delimiter is left unpaired, and nothing is read aloud.
    func testEmphasisOverAPageIsKeptOnBothLines() throws {
        let blocks: [BrailleBlock] = [.paragraph(text: cells("A B C D"))]
        let translation = BrailleBookReader.PagedTranslation(blocks: blocks, starts: [start("7", block: 0, cell: 4)])
        let whole = "one two three four"
        let italic = whole.unicodeScalars.indices.map { index -> BrailleEmphasis in
            let offset = whole.unicodeScalars.distance(from: whole.unicodeScalars.startIndex, to: index)
            return (4..<13).contains(offset) ? .italic : []
        }
        let print = [try XCTUnwrap(EmphasizedText(whole, emphasis: italic))] + printed(["one two", "three four"])
        let markdown = try XCTUnwrap(translation.markdown(from: print))
        XCTAssertEqual(markdown, "one *two*<!-- page: 7 -->\n*three* four")
        try assertSameReading(markdown, "one *two three* four")
    }

    /// A page that begins inside a heading stands before it, since a heading
    /// is one line; a block with no print keeps its pages' markers where its
    /// line would have stood.
    func testAPageInsideAHeadingOrABlockWithNoPrintStandsBeforeIt() throws {
        let blocks: [BrailleBlock] = [
            .heading(level: 2, text: cells("A B")), .paragraph(text: cells("C")), .paragraph(text: cells("D")),
        ]
        let starts = [start("1", block: 0), start("2", block: 0, cell: 2), start("3", block: 1)]
        let translation = BrailleBookReader.PagedTranslation(blocks: blocks, starts: starts)
        // A heading is never cut, so the helper is sent the blocks alone.
        XCTAssertEqual(translation.texts.count, 3)
        let markdown = try XCTUnwrap(translation.markdown(from: printed(["Part One", "", "after"])))
        XCTAssertEqual(markdown, "<!-- page: 1 -->\n\n<!-- page: 2 -->\n\n## Part One\n\n<!-- page: 3 -->\n\nafter")
        try assertSameReading(markdown, "## Part One\n\nafter")
    }

    /// Where a piece's print differs from the whole's, the cut is found from
    /// the end; found neither way, the page begins at the block's start,
    /// before its first word, rather than after it.
    func testAPageWhosePiecesReadOtherwiseBeginsNoLaterThanItShould() throws {
        let blocks: [BrailleBlock] = [.paragraph(text: cells("A B C D"))]
        let translation = BrailleBookReader.PagedTranslation(blocks: blocks, starts: [start("1", block: 0), start("2", block: 0, cell: 4)])
        // The first piece reads otherwise (its capitals lost), the second as
        // the whole's end: the cut is found from the end, and the lines are
        // the whole's print.
        let fromTheEnd = try XCTUnwrap(translation.markdown(from: printed(["ONE TWO three four", "one two", "three four"])))
        XCTAssertEqual(fromTheEnd, "<!-- page: 1 -->\n\nONE TWO<!-- page: 2 -->\nthree four")
        // Neither piece reads as the whole: page 2 begins with page 1.
        let neither = try XCTUnwrap(translation.markdown(from: printed(["one two three four", "uno dos", "tres cuatro"])))
        XCTAssertEqual(neither, "<!-- page: 1 -->\n\n<!-- page: 2 -->\n\none two three four")
        try assertSameReading(neither, "one two three four")
    }

    // MARK: - Finding a Page in the Print

    /// The scalars of `text`.
    private func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    /// Each cut is the one space after its piece's print, found from the
    /// start; a piece that reads otherwise is found from the end; a cut found
    /// neither way is nil; and the space must be one space between words.
    func testCutsAreFoundFromTheStartThenFromTheEnd() {
        let whole = scalars("a b c d e f")
        func places(_ pieces: [String]) -> [Int?] {
            BrailleBookReader.places(ofCutsIn: whole, pieces: pieces.map(scalars))
        }
        XCTAssertEqual(places(["a b", "c d", "e f"]), [3, 7])
        XCTAssertEqual(places(["a b c d e f"]), [])
        XCTAssertEqual(places([]), [])
        // The middle piece reads otherwise: the first cut from the start, the
        // second from the end.
        XCTAssertEqual(places(["a b", "C D", "e f"]), [3, 7])
        // The first reads otherwise: both from the end.
        XCTAssertEqual(places(["A B", "c d", "e f"]), [3, 7])
        // Two pieces in the middle read otherwise: the cut between them is
        // found neither way.
        XCTAssertEqual(places(["a", "B", "C", "d e f"]), [1, nil, 5])
        // Pieces that read as nothing, or as more than the whole.
        XCTAssertEqual(places(["", "a b c d e f"]), [nil])
        XCTAssertEqual(places(["a b c d e f g", "h"]), [nil])
        // Two spaces, or a no-break space, where the page begins.
        XCTAssertEqual(BrailleBookReader.places(ofCutsIn: scalars("a  b"), pieces: [scalars("a"), scalars("b")]), [nil])
        XCTAssertEqual(BrailleBookReader.places(ofCutsIn: scalars("a\u{00A0}b"), pieces: [scalars("a"), scalars("b")]), [nil])
    }

    // MARK: - The Samples

    /// The Grade 1 sample, BRF and PEF alike, has two pages: page 1 at the
    /// book's start and page 2 inside the paragraph it goes on, at "taken".
    /// Without pages its content.md is the one the reader wrote before them.
    func testTheGrade1SamplesPagesAreMarkedWhereTheyBegin() throws {
        for path in ["brf/pride-and-prejudice-ch1-grade1.brf", "pef/pride-and-prejudice-ch1-grade1.pef"] {
            let url = try copyOfFormatSample(path)
            let withoutPages = try BrailleBookReader.markdown(of: url, table: grade1)
            let withPages = try BrailleBookReader.markdown(of: url, table: grade1, includesPages: true)
            XCTAssertTrue(withoutPages.contains(" who has taken it"), path)
            XCTAssertFalse(withoutPages.contains("<!--"), path)
            XCTAssertEqual(
                withPages,
                "<!-- page: 1 -->\n\n"
                    + withoutPages.replacingOccurrences(of: " who has taken it", with: " who has<!-- page: 2 -->\ntaken it"),
                path
            )
            try assertSameReading(withPages, withoutPages, path)
            let paged = try chapter(withPages)
            XCTAssertEqual(paged.pages.map(\.label), ["1", "2"], path)
            XCTAssertEqual(paged.pages.map(\.characterOffset), [0, try offset(of: "taken it?", in: paged.text)], path)
        }
    }

    /// The Grade 2 sample's one page begins at its start; a BRL has no pages.
    func testAOnePageBookHasPageOneAndABRLHasNone() throws {
        let grade2 = try copyOfFormatSample("brf/grade2-short.brf")
        let plain = try BrailleBookReader.markdown(of: grade2, table: "en-ueb-g2.ctb")
        XCTAssertEqual(try BrailleBookReader.markdown(of: grade2, table: "en-ueb-g2.ctb", includesPages: true), "<!-- page: 1 -->\n\n" + plain)

        let brl = try copyOfFormatSample("brl/pride-and-prejudice-ch1-grade1.brl")
        XCTAssertEqual(
            try BrailleBookReader.markdown(of: brl, table: grade1, includesPages: true),
            try BrailleBookReader.markdown(of: brl, table: grade1)
        )
    }

    /// A row of braille ASCII `text` with `number` at the right margin of a
    /// 40-cell line, as a BRF writes a page number.
    private func numberedRow(_ text: String, _ number: String) -> String {
        text + String(repeating: " ", count: max(40 - text.count - number.count, 3)) + number
    }

    /// A page is a braille page, never a print page (question 2 of the
    /// October 21 questions): a Grade 1 BRF whose pages also carry print
    /// page numbers at the top right, and a print page change line in the
    /// middle of a paragraph, is labelled by its braille page numbers, 1 and
    /// 2, with page 2 at its first row's first word, inside the paragraph
    /// that goes on over it; no print page number is read as text.
    func testPagesAreBraillePagesWhatEverPrintPagesTheyHold() throws {
        let pageOne = [
            numberedRow("  ,THE FIRST BOAT LEAVES AT SIX1", "#C"),
            "AND THE SECOND WAITS FOR THE MAIL",
            String(repeating: "-", count: 36) + "#D",
            "TRAIN BEFORE IT CROSSES TO THE",
            numberedRow("", "#A"),
        ]
        let pageTwo = [
            numberedRow("ISLAND4", "#D"),
            "",
            "  ,IN WINTER THE EVENING CROSSING IS",
            "CANCELLED4",
            numberedRow("", "#B"),
        ]
        let url = try makeSandboxDirectory("BraillePrintPages").appendingPathComponent("print-pages.brf")
        let file = pageOne.joined(separator: "\r\n") + "\r\n\u{0C}" + pageTwo.joined(separator: "\r\n") + "\r\n"
        try Data(file.utf8).write(to: url)

        let withPages = try BrailleBookReader.markdown(of: url, table: grade1, includesPages: true)
        try assertSameReading(withPages, try BrailleBookReader.markdown(of: url, table: grade1))
        let paged = try chapter(withPages)
        XCTAssertEqual(
            paged.text,
            "The first boat leaves at six, and the second waits for the mail train before it crosses to the island."
                + "\n\nIn winter the evening crossing is cancelled."
        )
        XCTAssertEqual(paged.pages.map(\.label), ["1", "2"])
        XCTAssertEqual(paged.pages.map(\.characterOffset), [0, try offset(of: "island.", in: paged.text)])
    }

    // MARK: - Every Bundled Table

    /// A long book, the sample chapter's paragraphs joined three by three and
    /// read four times, under a heading: long enough that pages begin inside
    /// paragraphs with every table.
    private func longBook() throws -> [BrailleBlock] {
        let text = String(decoding: try Data(contentsOf: copyOfFormatSample("brf/pride-and-prejudice-ch1.txt")), as: UTF8.self)
        let paragraphs = text.replacingOccurrences(of: "_", with: "")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .dropFirst(2)  // the title and the chapter's heading
        let joined = stride(from: paragraphs.startIndex, to: paragraphs.endIndex, by: 3).map { first in
            paragraphs[first..<min(first + 3, paragraphs.endIndex)].joined(separator: " ")
        }
        return [.heading(level: 1, text: "Chapter One")] + Array(repeating: joined, count: 4).joined().map { .paragraph(text: $0) }
    }

    /// With every bundled table (EBAE and UEB, uncontracted and contracted),
    /// a long book written by TextMouth's own braille writer reads with its
    /// pages exactly as without them, has one page for each of its pages,
    /// numbered as the writer numbered them, and each page begins at the
    /// first word of its first row: the word that row's first braille word
    /// reads as alone. A translation cut at a page reads as the whole.
    func testEveryBundledTableFindsEachPageAtItsFirstRowsFirstWord() throws {
        let tables = BrailleTableCatalog.bundled.map(\.id)
        XCTAssertEqual(tables.count, 4)
        let blocks = try longBook()
        for table in tables {
            let folder = try makeSandboxDirectory("BrailleBookPages")
            let pages = try BrailleDocumentWriter.pages(of: blocks, options: BrailleExportOptions(table: table), workingIn: folder)
            let url = folder.appendingPathComponent("long.brf")
            try BrailleFileWriter.brf(pages: pages, lineEnd: .crlf).write(to: url)

            let withoutPages = try BrailleBookReader.markdown(of: url, table: table)
            let withPages = try BrailleBookReader.markdown(of: url, table: table, includesPages: true)
            try assertSameReading(withPages, withoutPages, table)
            let paged = try chapter(withPages)
            XCTAssertEqual(paged.pages.map(\.label), (1...pages.count).map(String.init), table)

            // Where the analyzer says each page begins, and the word its
            // first row's first braille word reads as, alone.
            let structure = BraillePageAnalyzer.structure(of: try BrailleFileReader.read(url, as: .brf))
            XCTAssertTrue(structure.pages.contains { $0.firstCellOffset > 0 }, "\(table): no page begins inside a paragraph")
            let firstWords = structure.pages.map { page -> String in
                guard structure.blocks.indices.contains(page.firstBlockIndex) else { return "" }
                let cells = structure.blocks[page.firstBlockIndex].text.unicodeScalars.dropFirst(page.firstCellOffset)
                return String(String.UnicodeScalarView(cells.prefix { $0 != BrailleCells.blank }))
            }
            let printedWords = try BrailleTranslator.translate(firstWords, table: table, direction: .brailleToPrint, workingIn: folder)
            XCTAssertEqual(printedWords.count, paged.pages.count, table)
            for (index, (page, word)) in zip(paged.pages, printedWords).enumerated() {
                let expected = word.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let at = paged.text[paged.text.index(atUTF16Offset: page.characterOffset)...]
                let found = at.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                XCTAssertEqual(found, expected, "\(table): page \(index + 1)")
            }
        }
    }
}
