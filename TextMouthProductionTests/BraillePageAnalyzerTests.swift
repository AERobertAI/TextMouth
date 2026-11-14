import XCTest
@testable import TextMouth

/// `BraillePageAnalyzer` (FMT20): the headings, paragraphs, and page numbers
/// a braille book's pages hold. The pages are built here from strings in
/// North American Braille ASCII, which `cells(_:)` turns into the Unicode
/// cells the analyzer reads, so a test row reads like a BRF's line.
final class BraillePageAnalyzerTests: XCTestCase {
    // MARK: Helpers

    /// `ascii` as Unicode braille cells, a space becoming the blank cell.
    private func cells(_ ascii: String) -> String {
        String(String.UnicodeScalarView(ascii.utf8.compactMap { byte in
            byte == 0x20 ? BrailleCells.blank : BrailleCells.cell(forASCII: byte)
        }))
    }

    /// A row of `ascii` with `indent` blank cells before it.
    private func row(_ indent: Int, _ ascii: String) -> String {
        cells(String(repeating: " ", count: indent) + ascii)
    }

    /// A row of `ascii` centered in `width` cells (the extra cell, if any, on the right).
    private func centered(_ ascii: String, width: Int = 40) -> String {
        row((width - ascii.count) / 2, ascii)
    }

    /// A row of `width` cells that ends with `number`, with `text` at its left
    /// and blank cells between them.
    private func rightAligned(_ number: String, text: String = "", width: Int = 40) -> String {
        let gap = max(width - text.count - number.count, 0)
        return cells(text + String(repeating: " ", count: gap) + number)
    }

    /// The structure of one formatted page of `rows`.
    private func formattedStructure(_ rows: [String]) -> BrailleStructure {
        BraillePageAnalyzer.structure(of: [rows], formatted: true)
    }

    /// The paragraph block for `ascii`.
    private func paragraph(_ ascii: String) -> BrailleBlock { .paragraph(text: cells(ascii)) }

    /// A sample's bytes, from a copy of the sample in a folder of the test's own.
    private func sampleBytes(_ relativePath: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: copyOfFormatSample(relativePath)))
    }

    /// A BRF sample read into pages of Unicode rows: pages split at form feeds,
    /// rows at CR LF, each byte turned into its cell (a stand-in for the real reader).
    private func sampleBRFPages(_ relativePath: String) throws -> [[String]] {
        let bytes = try sampleBytes(relativePath)
        return bytes.split(separator: 0x0C, omittingEmptySubsequences: false).map { page in
            page.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
                String(String.UnicodeScalarView(line.compactMap { BrailleCells.cell(forASCII: $0) }))
            }
        }
    }

    // MARK: Samples

    func testPrideAndPrejudiceBRFHasTwoHeadingsAndTwelveParagraphs() throws {
        let pages = try sampleBRFPages("brf/pride-and-prejudice-ch1-grade1.brf")
        let brl = try String(decoding: sampleBytes("brl/pride-and-prejudice-ch1-grade1.brl"), as: UTF8.self)
            .components(separatedBy: "\r\n").filter { !$0.isEmpty }.map(cells)
        XCTAssertEqual(brl.count, 14)
        guard brl.count == 14 else { return }

        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)

        XCTAssertEqual(structure.blocks.count, 14)
        guard structure.blocks.count == 14 else { return }
        XCTAssertEqual(structure.blocks[0], .heading(level: 1, text: brl[0]))
        XCTAssertEqual(structure.blocks[1], .heading(level: 1, text: brl[1]))
        for index in 2..<14 {
            XCTAssertEqual(structure.blocks[index], .paragraph(text: brl[index]), "block \(index)")
        }
        XCTAssertEqual(structure.pages.count, 2)
        guard structure.pages.count == 2 else { return }
        XCTAssertEqual(structure.pages[0].braillePageNumber, "⠼⠁")
        XCTAssertEqual(structure.pages[1].braillePageNumber, "⠼⠃")
        XCTAssertNil(structure.pages[0].printPageNumber)
        XCTAssertNil(structure.pages[1].printPageNumber)
        XCTAssertEqual(structure.pages[0].printPageChanges, [])
        XCTAssertEqual(structure.pages[1].printPageChanges, [])
        // The 7th paragraph (block 8) starts on page 1 and goes on at the top of page 2.
        XCTAssertEqual(structure.pages[0].firstBlockIndex, 0)
        XCTAssertEqual(structure.pages[1].firstBlockIndex, 8)
    }

    /// The analyzer reads the compact pages a reader gives; the pages as text
    /// are only a way to make them, so both give the same structure.
    func testTheCompactPagesAndThePagesAsTextGiveOneStructure() throws {
        for (path, kind) in [("brf/pride-and-prejudice-ch1-grade1.brf", BrailleFileKind.brf),
                             ("brl/pride-and-prejudice-ch1-grade1.brl", .brl),
                             ("brf/grade2-short.brf", .brf)] {
            let file = try BrailleFileReader.read(copyOfFormatSample(path), as: kind)
            let fromCompact = BraillePageAnalyzer.structure(of: file)
            XCTAssertEqual(fromCompact, BraillePageAnalyzer.structure(of: file.pages, formatted: kind != .brl), path)
            XCTAssertFalse(fromCompact.blocks.isEmpty, path)
        }
        // The sample, read as a PEF, gives the BRF's blocks and page numbers.
        let brf = try BrailleFileReader.read(
            copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf"), as: .brf)
        let pef = try BrailleFileReader.read(
            copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"), as: .pef)
        XCTAssertEqual(BraillePageAnalyzer.structure(of: pef), BraillePageAnalyzer.structure(of: brf))
    }

    func testGrade2SampleIsOneParagraphOfThreeLines() throws {
        let pages = try sampleBRFPages("brf/grade2-short.brf")
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)

        XCTAssertEqual(structure.blocks.count, 1)
        guard case let .paragraph(text) = structure.blocks.first else {
            return XCTFail("expected one paragraph, got \(structure.blocks)")
        }
        // Words are single-spaced, and nothing is left at either end.
        XCTAssertFalse(text.hasPrefix(String(BrailleCells.blank)))
        XCTAssertFalse(text.hasSuffix(String(BrailleCells.blank)))
        XCTAssertFalse(text.contains(String(repeating: String(BrailleCells.blank), count: 2)))
        XCTAssertEqual(structure.pages.count, 1)
        XCTAssertEqual(structure.pages.first?.braillePageNumber, "⠼⠁")
    }

    func testGrade2SampleParagraphJoinsItsLinesWithBlankCells() throws {
        let pages = try sampleBRFPages("brf/grade2-short.brf")
        // The first three rows of the page are the paragraph's lines.
        guard let page = pages.first, page.count >= 3 else { return XCTFail("the sample has no rows") }
        let lines = Array(page[0..<3])
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [.paragraph(text: lines.joined(separator: String(BrailleCells.blank)))])
    }

    // MARK: Page numbers

    func testBraillePageNumberAfterThreeBlanksIsTakenAndTheTextKept() {
        // The last row is 19 cells: 14 of text, 3 blanks, ⠼⠁. It is the longest, so the width is 19.
        let structure = formattedStructure([row(2, "THIS IS TEXT"), rightAligned("#A", text: "SOME TEXT HERE", width: 19)])
        XCTAssertEqual(structure.pages.count, 1)
        XCTAssertEqual(structure.pages.first?.braillePageNumber, "⠼⠁")
        // The text left of the number stays a block (a row of indent 0 after a paragraph is a runover).
        XCTAssertEqual(structure.blocks, [paragraph("THIS IS TEXT SOME TEXT HERE")])
    }

    func testTwoBlanksBeforeTheNumberTakeNothing() {
        // 15 cells of text + 2 blanks + 2 of number = 19; the gap is only 2.
        let last = rightAligned("#A", text: "SOME TEXT HERES", width: 19)
        let structure = formattedStructure([row(2, "TEXT"), last])
        XCTAssertNil(structure.pages.first?.braillePageNumber)
        XCTAssertEqual(structure.blocks, [paragraph("TEXT SOME TEXT HERES #A")])
    }

    func testANumberThatDoesNotEndAtTheLineWidthIsNotTaken() {
        // Two pages are numbered at cell 24, which is the width; the third page's
        // footer ends at 20, so it is a row of text and not a number.
        let text = row(2, String(repeating: "X", count: 22))
        let pages = [[text, rightAligned("#A", width: 24)], [text, rightAligned("#B", width: 24)],
                     [text, rightAligned("#C", width: 20)]]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", "⠼⠃", nil])
    }

    func testOneOverlongRowDoesNotMoveThePageNumberColumn() {
        // Pages numbered at cell 40, and one row of 41 cells: the width is the
        // column the numbers stand in, so neither number is left in the text.
        let text = row(2, "A PARAGRAPH")
        let overlong = row(0, String(repeating: "X", count: 41))
        let pages = [[text, overlong, rightAligned("#A")], [row(0, "GOES ON"), rightAligned("#B")]]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", "⠼⠃"])
        XCTAssertEqual(structure.blocks, [paragraph("A PARAGRAPH " + String(repeating: "X", count: 41) + " GOES ON")])
    }

    func testTheWidthIsTheMostCommonNumberedLastRowAndTiesTakeTheLonger() {
        let text = row(2, "TEXT")
        // Two pages numbered at 30 and one at 40: the width is 30, so a row of
        // 40 cells is no footer, and the page numbered at 40 keeps its number in the text.
        let common = [[text, rightAligned("#A", width: 30)], [text, rightAligned("#B", width: 30)],
                      [text, rightAligned("#C", width: 40)]]
        XCTAssertEqual(BraillePageAnalyzer.structure(of: common, formatted: true).pages.map(\.braillePageNumber),
                       ["⠼⠁", "⠼⠃", nil])
        // One page each at 30 and 40: the tie goes to the longer, 40.
        let tie = [[text, rightAligned("#A", width: 30)], [text, rightAligned("#B", width: 40)]]
        XCTAssertEqual(BraillePageAnalyzer.structure(of: tie, formatted: true).pages.map(\.braillePageNumber),
                       [nil, "⠼⠃"])
    }

    func testPreliminaryAndContinuationPageNumbersAreTaken() {
        for (ascii, expected) in [("P#A", "⠏⠼⠁"), ("A#A", "⠁⠼⠁")] {
            let structure = formattedStructure([row(2, String(repeating: "X", count: 22)), rightAligned(ascii, width: 24)])
            XCTAssertEqual(structure.pages.first?.braillePageNumber, expected, ascii)
            XCTAssertEqual(structure.blocks.count, 1)
        }
    }

    func testANumberWordOfNineCellsIsNotTaken() {
        // "ABCDEFG#A" is 9 cells.
        let structure = formattedStructure([row(2, "TEXT"), rightAligned("ABCDEFG#A", width: 24)])
        XCTAssertNil(structure.pages.first?.braillePageNumber)
    }

    func testAnEightCellNumberWordIsTaken() {
        let structure = formattedStructure([row(2, "TEXT"), rightAligned("ABCDEF#A", width: 24)])
        XCTAssertEqual(structure.pages.first?.braillePageNumber, cells("ABCDEF#A"))
    }

    func testAPageWhoseLastRowIsTextIsLeftWhole() {
        let structure = formattedStructure([row(2, "FIRST LINE"), "", row(2, "LAST LINE OF THE PAGE")])
        XCTAssertNil(structure.pages.first?.braillePageNumber)
        XCTAssertNil(structure.pages.first?.printPageNumber)
        XCTAssertEqual(structure.blocks, [paragraph("FIRST LINE"), paragraph("LAST LINE OF THE PAGE")])
    }

    func testAFooterAloneOnItsRowDoesNotEndAParagraphThatContinuesOverThePage() {
        let page1 = [row(2, "A PARAGRAPH THAT"), rightAligned("#A")]
        let page2 = [row(0, "GOES ON"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("A PARAGRAPH THAT GOES ON")])
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", "⠼⠃"])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 0])
    }

    func testEmptyRowsAfterTheBraillePageNumberDoNotEndAParagraph() {
        // A reader that splits a file at its line breaks leaves an empty piece after the last one.
        let page1 = [row(2, "A PARAGRAPH THAT"), rightAligned("#A"), "", cells("  ")]
        let page2 = [row(0, "GOES ON"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("A PARAGRAPH THAT GOES ON")])
    }

    /// The sample's bytes with every form feed replaced by `replacement`, read
    /// by the real reader and analyzed.
    private func structureOfSample(replacingFormFeedWith replacement: [UInt8]) throws -> BrailleStructure {
        var bytes: [UInt8] = []
        for byte in try sampleBytes("brf/pride-and-prejudice-ch1-grade1.brf") {
            if byte == 0x0C { bytes += replacement } else { bytes.append(byte) }
        }
        let pages = try BrailleFileReader.pages(fromASCII: Data(bytes), kind: .brf).pages
        return BraillePageAnalyzer.structure(of: pages, formatted: true)
    }

    func testABlankRowAtAPagesTopDoesNotEndAParagraphOverThePage() throws {
        // The sample ends page 1 with a line end; a form feed that is followed
        // by a line end, or sits on a line of its own, starts page 2 with a blank row.
        let original = try structureOfSample(replacingFormFeedWith: [0x0C])
        XCTAssertEqual(original.blocks.count, 14)
        for (label, replacement) in [("FF CR LF", [0x0C, 0x0D, 0x0A] as [UInt8]),
                                     ("FF LF", [0x0C, 0x0A]),
                                     ("FF CR", [0x0C, 0x0D]),
                                     ("FF on its own line", [0x0D, 0x0A, 0x0C, 0x0D, 0x0A])] {
            let structure = try structureOfSample(replacingFormFeedWith: replacement)
            XCTAssertEqual(structure.blocks, original.blocks, label)
            XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", "⠼⠃"], label)
            XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 8], label)
        }
    }

    func testBlankRowsAtAPagesTopAreDroppedBeforeItsFirstRowWithText() {
        // Two blank rows and a print page number alone on a row, then text.
        let page1 = [row(2, "A PARAGRAPH THAT"), rightAligned("#A")]
        let page2 = ["", cells("   "), rightAligned("#C"), "", row(0, "GOES ON"), "", row(2, "NEW"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("A PARAGRAPH THAT GOES ON"), paragraph("NEW")])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 0])
        // The print page number was taken, and the blank row in the middle of the page still ends a paragraph.
        XCTAssertEqual(structure.pages.last?.printPageNumber, "⠼⠉")
    }

    // MARK: Block-style paragraphs

    /// A book of block-style paragraphs (the reviewer's `block-style.brf`):
    /// each begins in cell 1 after a blank row, on two numbered pages. The
    /// fourth begins page 2, after the empty row that a form feed followed
    /// by a line end leaves at its top.
    private func blockStylePages() -> [[String]] {
        let blankRows = [String](repeating: "", count: 17)
        let page1 = [
            row(0, "FIRST BLOCK PARAGRAPH ENDS HERE4"), "", row(0, "SECOND BLOCK PARAGRAPH4"),
        ] + blankRows + [
            row(0, "THIRD BLOCK PARAGRAPH ENDS AT THE PAGE4"), row(0, "LAST LINE OF PAGE ONE4"), rightAligned("#A"),
        ]
        let page2 = ["", row(0, "FOURTH BLOCK PARAGRAPH4")] + [String](repeating: "", count: 22) + [rightAligned("#B")]
        return [page1, page2]
    }

    /// A blank row at the top of a page ends the paragraph before it when
    /// the book's paragraphs are set apart by blank rows, as the blank row
    /// before the second paragraph shows. Dropped, it joined the fourth to
    /// the third.
    func testABlankRowAtAPagesTopEndsABlockStyleParagraph() {
        let structure = BraillePageAnalyzer.structure(of: blockStylePages(), formatted: true)
        XCTAssertEqual(structure.blocks, [
            paragraph("FIRST BLOCK PARAGRAPH ENDS HERE4"),
            paragraph("SECOND BLOCK PARAGRAPH4"),
            paragraph("THIRD BLOCK PARAGRAPH ENDS AT THE PAGE4 LAST LINE OF PAGE ONE4"),
            paragraph("FOURTH BLOCK PARAGRAPH4"),
        ])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 3])
    }

    /// Without that blank row at the top of page 2, the fourth paragraph's
    /// first row would go on the third: the style changes nothing else.
    func testABlockStyleParagraphThatGoesOnOverThePageStaysOne() {
        var pages = blockStylePages()
        XCTAssertEqual(pages.count, 2)
        guard pages.count == 2, pages[1].first == "" else { return XCTFail("page 2 should begin with a blank row") }
        pages[1].removeFirst()
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks.count, 3)
        XCTAssertEqual(structure.blocks.last,
                       paragraph("THIRD BLOCK PARAGRAPH ENDS AT THE PAGE4 LAST LINE OF PAGE ONE4 FOURTH BLOCK PARAGRAPH4"))
    }

    /// BANA's paragraphs outnumber the blocks, so their pages' blank top rows
    /// go: a book of paragraphs in cell 3, one of them (a runover that
    /// follows a blank row, as after a print page change) in cell 1.
    func testBlankRowsAtAPagesTopStillGoInABookOfParagraphsInCellThree() {
        let page1 = [row(2, "ONE"), "", row(2, "TWO"), "", row(0, "RUNOVER"), row(2, "A PARAGRAPH THAT"), rightAligned("#A")]
        let page2 = ["", row(0, "GOES ON"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [
            paragraph("ONE"), paragraph("TWO"), paragraph("RUNOVER"), paragraph("A PARAGRAPH THAT GOES ON"),
        ])
    }

    // MARK: Print page numbers and change lines

    func testPrintPageNumberAtTheRightOfTheFirstRowIsTakenAndTheTextKept() {
        let first = rightAligned("#C", text: "  FIRST LINE", width: 40)
        let structure = formattedStructure([first, row(0, "SECOND"), rightAligned("#A")])
        XCTAssertEqual(structure.pages.first?.printPageNumber, "⠼⠉")
        XCTAssertEqual(structure.pages.first?.braillePageNumber, "⠼⠁")
        XCTAssertEqual(structure.blocks, [paragraph("FIRST LINE SECOND")])
    }

    func testASingleRowPageTakesOnlyTheBraillePageNumber() {
        let structure = formattedStructure([rightAligned("#A")])
        XCTAssertEqual(structure.pages.first?.braillePageNumber, "⠼⠁")
        XCTAssertNil(structure.pages.first?.printPageNumber)
        XCTAssertEqual(structure.blocks, [])
    }

    func testAPrintPageChangeLineInTheMiddleOfAParagraphIsTakenOut() {
        let structure = formattedStructure([
            row(2, "ONE TWO"), row(0, "THREE"), row(0, "------#CB"), row(0, "FOUR"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [paragraph("ONE TWO THREE FOUR")])
        XCTAssertFalse(structure.blocks.first?.text.contains("⠤") ?? true)
        XCTAssertEqual(structure.pages.first?.printPageChanges, ["⠼⠉⠃"])
    }

    func testChangeLinesNeedThreeDashesAndNothingElse() {
        // Two dashes, or text after the number, make an ordinary row.
        let structure = formattedStructure([row(2, "ONE"), row(0, "--#C"), row(0, "---#C TEXT"), rightAligned("#A")])
        XCTAssertEqual(structure.pages.first?.printPageChanges, [])
        XCTAssertEqual(structure.blocks.count, 1)
    }

    func testAChangeLineAfterABlankRowDoesNotSeparateAnything() {
        let structure = formattedStructure([row(2, "ONE"), "", row(2, "TWO"), row(8, "---#E"), row(0, "TWO MORE"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("ONE"), paragraph("TWO TWO MORE")])
        XCTAssertEqual(structure.pages.first?.printPageChanges, [cells("#E")])
    }

    // MARK: Headings

    func testCellFiveAndCellSevenHeadingsFollowBlankRows() {
        let structure = formattedStructure([
            row(2, "ONE"), "", row(4, "HEAD TWO"), row(2, "UNDER TWO"), "", row(6, "HEAD THREE"), row(2, "UNDER THREE"),
            rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [
            paragraph("ONE"),
            .heading(level: 2, text: cells("HEAD TWO")),
            paragraph("UNDER TWO"),
            .heading(level: 3, text: cells("HEAD THREE")),
            paragraph("UNDER THREE"),
        ])
    }

    func testCellFiveAndSevenHeadingsMayFollowEachOtherAndTakeSameIndentRows() {
        let structure = formattedStructure([
            row(4, "LONG HEADING"), row(4, "CONTINUED"), row(6, "SUB"), row(2, "TEXT"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [
            .heading(level: 2, text: cells("LONG HEADING CONTINUED")),
            .heading(level: 3, text: cells("SUB")),
            paragraph("TEXT"),
        ])
    }

    func testACellFiveRowInTheMiddleOfAParagraphIsAParagraphNotAHeading() {
        let structure = formattedStructure([row(2, "PARA"), row(0, "RUNOVER"), row(4, "FIVE ROW"), row(0, "REST"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("PARA RUNOVER"), paragraph("FIVE ROW REST")])
    }

    func testTwoCenteredRowsBetweenBlankRowsAreOneLevelOneHeading() {
        let structure = formattedStructure([centered("BOOK"), centered("ONE"), "", row(2, "TEXT"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [.heading(level: 1, text: cells("BOOK ONE")), paragraph("TEXT")])
    }

    func testACenteredRowWithTextRightAfterItIsAParagraph() {
        let structure = formattedStructure([centered("TITLE"), row(0, "TEXT"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("TITLE TEXT")])
    }

    func testACenteredRowAfterTextWithoutABlankRowIsNotAHeading() {
        let structure = formattedStructure([row(2, "TEXT"), centered("TITLE"), "", rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("TEXT"), paragraph("TITLE")])
    }

    func testACenteredHeadingAtThePageEndsWithThePage() {
        let page1 = [row(2, "TEXT"), "", centered("HEAD"), rightAligned("#A")]
        let page2 = [row(2, "NEXT"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("TEXT"), .heading(level: 1, text: cells("HEAD")), paragraph("NEXT")])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 2])
    }

    // MARK: Long cell-5 and cell-7 headings

    /// A numbered 40-cell page: a paragraph, a blank row, `headingRows`, a
    /// blank row, a paragraph, and the page number at cell 40.
    private func pageWithHeading(_ headingRows: [String]) -> BrailleStructure {
        formattedStructure([row(2, "BEFORE"), ""] + headingRows + ["", row(2, "AFTER"), rightAligned("#A")])
    }

    /// The block after the first paragraph, of the page `pageWithHeading` makes
    /// (nil if the page has fewer blocks, so a test never indexes past the end).
    private func headingBlock(_ headingRows: [String]) -> BrailleBlock? {
        pageWithHeading(headingRows).blocks.dropFirst().first
    }

    /// `length` cells of one word.
    private func word(_ length: Int) -> String { String(repeating: "H", count: length) }

    /// A cell-5 heading of 1 to 36 cells is level 2, and a cell-7 heading of
    /// 1 to 34 is level 3, at 40 cells: the right margin does not matter.
    /// The lengths from 30 to 34 (cell 5) and 26 to 30 (cell 7) measured as
    /// centered, since their right margin is within a cell of the indent.
    func testCellFiveAndSevenHeadingsOfEveryLengthAreHeadings() {
        for (indent, level) in [(4, 2), (6, 3)] {
            for length in 1...(40 - indent) {
                let structure = pageWithHeading([row(indent, word(length))])
                XCTAssertEqual(structure.blocks, [
                    paragraph("BEFORE"), .heading(level: level, text: cells(word(length))), paragraph("AFTER"),
                ], "indent \(indent), \(length) cells")
            }
        }
    }

    /// The boundary lengths named, so a failure says where it breaks.
    func testTheLengthsThatMeasuredAsCenteredAreHeadings() {
        for length in 30...34 {
            XCTAssertEqual(headingBlock([row(4, word(length))]),
                           .heading(level: 2, text: cells(word(length))), "cell 5, \(length) cells")
        }
        for length in 26...30 {
            XCTAssertEqual(headingBlock([row(6, word(length))]),
                           .heading(level: 3, text: cells(word(length))), "cell 7, \(length) cells")
        }
    }

    /// A cell-5 heading wrapped to two rows is one heading, whether its first
    /// row reaches the right margin or measures as centered.
    func testAWrappedLongHeadingIsOneHeading() {
        for firstLength in [20, 31, 32, 33] {
            let structure = pageWithHeading([row(4, word(firstLength)), row(4, "SECOND")])
            XCTAssertEqual(structure.blocks, [
                paragraph("BEFORE"),
                .heading(level: 2, text: cells(word(firstLength) + " SECOND")),
                paragraph("AFTER"),
            ], "first row \(firstLength) cells")
        }
        let seven = pageWithHeading([row(6, word(28)), row(6, "SECOND")])
        XCTAssertEqual(seven.blocks.dropFirst().first, .heading(level: 3, text: cells(word(28) + " SECOND")))
    }

    /// A centered heading whose left margin is 4 or 6 cells is read as level
    /// 2 or 3: still a heading, its text whole. Centered rows of every other
    /// margin are still a level-1 heading.
    func testACenteredHeadingWithMarginFourOrSixIsALowerHeadingWithItsTextWhole() {
        // 40 - 31 = 9 and 40 - 32 = 8 give a margin of 4; 27 and 28, 6.
        XCTAssertEqual(headingBlock([centered(word(32))]), .heading(level: 2, text: cells(word(32))))
        XCTAssertEqual(headingBlock([centered(word(28))]), .heading(level: 3, text: cells(word(28))))
        // Margins 3, 5, 7: level 1.
        for length in [34, 30, 26] {
            XCTAssertEqual(headingBlock([centered(word(length))]),
                           .heading(level: 1, text: cells(word(length))), "\(length) cells")
        }
    }

    // MARK: Centered headings of several lines

    /// Every title of the sample `wrapped-titles.brf` (the chapter titles of
    /// Pride and Prejudice, wrapped at 34 cells, as BANA's margins of three
    /// cells allow) is one level-1 heading. A title's row may begin after 4 or 6
    /// blank cells, where a cell-5 or cell-7 heading begins, and Phase A read
    /// all of them whole; a reading that cut such a row off made 98 of the
    /// 233 titles headings of a lower level or paragraphs.
    func testEveryTitleOfTheWrappedTitlesSampleIsOneLevelOneHeading() throws {
        let file = try BrailleFileReader.read(copyOfFormatSample("brf/wrapped-titles.brf"), as: .brf)
        XCTAssertEqual(file.pageCount, 233)
        let blocks = BraillePageAnalyzer.structure(of: file).blocks
        // Each page: a paragraph, the title, a paragraph.
        XCTAssertEqual(blocks.count, 3 * 233)
        guard blocks.count == 3 * 233 else { return }
        let misread = (0..<233).filter { page in
            guard case .heading(level: 1, _) = blocks[3 * page + 1] else { return true }
            guard case .paragraph = blocks[3 * page], case .paragraph = blocks[3 * page + 2] else { return true }
            return false
        }
        XCTAssertEqual(misread, [], "pages (from 0) whose title did not read as one level-1 heading")
    }

    /// A title of two rows, the first with a left margin of 4 cells (the
    /// reviewer's `twoline-title.brf`), is one level-1 heading.
    func testATwoRowTitleWhoseFirstRowHasMarginFourIsOneLevelOneHeading() {
        let first = "PPPPPPP QQQQQQQQ RRRRRRRR SSSSSS"
        let second = "TTTTTTTTT UUUUUUUUUU"
        let structure = formattedStructure([
            row(2, "BEFORE"), "", row(4, first), row(10, second), "", row(2, "AFTER"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [
            paragraph("BEFORE"), .heading(level: 1, text: cells(first + " " + second)), paragraph("AFTER"),
        ])
    }

    /// Centered rows of several margins, 4 and 6 among them, are one level-1
    /// heading, in whatever order the margins come.
    func testCenteredRowsOfMixedMarginsAreOneLevelOneHeading() {
        let rows = [(4, word(32)), (12, word(16)), (6, word(28)), (3, word(34)), (5, word(30))]
        let structure = formattedStructure(
            [row(2, "BEFORE"), ""] + rows.map { row($0.0, $0.1) } + ["", row(2, "AFTER"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [
            paragraph("BEFORE"), .heading(level: 1, text: cells(rows.map(\.1).joined(separator: " "))), paragraph("AFTER"),
        ])
    }

    /// The lengths that M2 made level 2 at cell 5 (31 to 33 cells at 40) and
    /// level 3 at cell 7 (27 to 29) still read so, alone or wrapped to the
    /// same margin on a second row.
    func testRowsAllAtMarginFourOrSixStayACellFiveOrCellSevenHeading() {
        for (indent, level, lengths) in [(4, 2, 31...33), (6, 3, 27...29)] {
            for length in lengths {
                XCTAssertEqual(headingBlock([row(indent, word(length))]),
                               .heading(level: level, text: cells(word(length))), "margin \(indent), \(length) cells")
                XCTAssertEqual(headingBlock([row(indent, word(length)), row(indent, word(length))]),
                               .heading(level: level, text: cells(word(length) + " " + word(length))),
                               "margin \(indent), two rows of \(length) cells")
            }
        }
    }

    /// A run of centered rows that goes straight on into a row that is neither
    /// blank nor centered is no heading: its rows are paragraphs, as before.
    func testCenteredRowsThatGoOnIntoTextWithoutABlankRowAreNotAHeading() {
        let structure = formattedStructure([
            row(2, "BEFORE"), "", centered("AAAA"), centered("BBBBBB"), row(0, "RUNS ON"), "", rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [paragraph("BEFORE"), paragraph("AAAA"), paragraph("BBBBBB RUNS ON")])
    }

    /// A long stretch of rows that all look centered (margins 4 and 6 in turn)
    /// and end in a row that does not is scanned once, not once for each row.
    func testALongStretchOfCenteredRowsWithoutAnEndIsReadInAReasonableTime() {
        let stretch = (0..<40_000).map { row($0 % 2 == 0 ? 4 : 6, word($0 % 2 == 0 ? 32 : 28)) }
        let page = [row(2, "BEFORE"), ""] + stretch + [row(2, "NOT CENTERED"), rightAligned("#A")]
        let structure = BraillePageAnalyzer.structure(of: [page], formatted: true)
        XCTAssertEqual(structure.blocks.first, paragraph("BEFORE"))
        // No heading run: each row is a cell-5 or cell-7 heading, and the last row a paragraph.
        XCTAssertEqual(structure.blocks.count, 1 + 40_000 + 1)
    }

    /// A word of `length` random cells from `generator`, none of them the
    /// number sign, so that no row can pass for a page number.
    private func randomWord(_ length: Int, using generator: inout SplitMix64) -> String {
        String(String.UnicodeScalarView((0..<length).map { _ -> Unicode.Scalar in
            var value: UInt32
            repeat { value = UInt32.random(in: 0x2801...0x283F, using: &generator) } while value == 0x283C
            return Unicode.Scalar(value) ?? "\u{2801}"
        }))
    }

    /// TextMouth's own centered headings read back whole at 18 to 23 cells,
    /// where a line of a heading may have a margin of 4 or 6 cells: as one
    /// level-1 heading, or as one of a lower level when every line has such
    /// a margin, but always with all their text, between paragraphs that
    /// read back as written. A reading that cut such a line off lost 60 to
    /// 74 of 400 random headings per width at 18 to 21 cells.
    func testCenteredHeadingsAtNarrowWidthsReadBackWithTheirWholeText() {
        var generator = SplitMix64(seed: 7)
        let blank = String(BrailleCells.blank)
        let paragraph = BrailleBlock.paragraph(
            text: (0..<30).map { _ in randomWord(5, using: &generator) }.joined(separator: blank))
        var misread: [String] = []
        for width in 18...23 {
            let format = BraillePageFormat(cellsPerLine: width, linesPerPage: 25, numbersPages: true)
            for index in 0..<200 {
                let heading = (0..<Int.random(in: 1...4, using: &generator)).map { _ in
                    randomWord(Int.random(in: 1...9, using: &generator), using: &generator)
                }.joined(separator: blank)
                let pages = BrailleLayout.pages(of: [paragraph, .heading(level: 1, text: heading), paragraph], format: format)
                let blocks = BraillePageAnalyzer.structure(of: pages, formatted: true).blocks
                if blocks.count == 3, blocks[0] == paragraph, blocks[2] == paragraph,
                   case let .heading(_, text) = blocks[1], text == heading { continue }
                misread.append("width \(width), heading \(index)")
            }
        }
        XCTAssertEqual(misread, [], "headings that did not read back whole between their paragraphs")
    }

    // MARK: Width

    func testTheWidthIsTheLongestRowOfTheFile() {
        // A row of 30 cells makes the width 30, so a row with 11 blanks each side is centered.
        let rows = [centered("EIGHTCHR", width: 30), "", row(2, String(repeating: "X", count: 28))]
        XCTAssertEqual(formattedStructure(rows).blocks.first, .heading(level: 1, text: cells("EIGHTCHR")))
        // Against a width of 40 the same row (11 left, 21 right) is no heading.
        let wider = rows + [row(0, String(repeating: "Y", count: 40))]
        XCTAssertEqual(formattedStructure(wider).blocks.first, paragraph("EIGHTCHR"))
    }

    func testAFileOfShortRowsIsMeasuredAsEighteenCells() {
        // At 10 cells the row "    AB" would be centered (4 each side); held to 18 it is a cell-5 heading.
        let structure = formattedStructure([row(2, "ABCDEFGH"), "", row(4, "AB"), row(2, "TEXT")])
        XCTAssertEqual(structure.blocks, [paragraph("ABCDEFGH"), .heading(level: 2, text: cells("AB")), paragraph("TEXT")])
    }

    func testAFileOfVeryLongRowsIsMeasuredAsEightyCells() {
        // Held to 80, a row of 10 blanks and 60 cells is centered; at 90 it would not be.
        let structure = formattedStructure([
            centered(String(repeating: "H", count: 60), width: 80), "", row(2, String(repeating: "X", count: 88)),
        ])
        XCTAssertEqual(structure.blocks.first, .heading(level: 1, text: cells(String(repeating: "H", count: 60))))
        XCTAssertEqual(structure.blocks.count, 2)
    }

    // MARK: List items

    /// Text of exactly `length` cells (a length of 4, 9, 14, ... and so on,
    /// one less than a multiple of 5): words of four cells and single blanks.
    private func filler(_ length: Int) -> String {
        String(repeating: "WWWW ", count: (length + 1) / 5).dropLast().description
    }

    /// The row of a list item in `ascii` words, of `length` cells with
    /// `indent` blank cells before it.
    private func fillerRow(_ indent: Int, _ length: Int) -> String { row(indent, filler(length)) }

    /// A row of 39 cells followed by a word of four cannot be a line a layout
    /// filled: the word could not have fitted on it (39 + 1 + 4 > 40). So a
    /// row of cell 3 under a first row of cell 1 is its runover.
    func testARowThatCouldNotHaveFittedOnTheRowAboveIsAListItemsRunover() {
        let structure = formattedStructure([fillerRow(0, 39), row(2, "WWWW"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph(filler(39) + " WWWW")])
    }

    /// One that could have fitted is the first row of another block.
    func testARowThatCouldHaveFittedOnTheRowAboveBeginsAnotherBlock() {
        let structure = formattedStructure([row(0, "ITEM ONE"), row(2, "ITEM TWO"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("ITEM ONE"), paragraph("ITEM TWO")])
    }

    /// After a row that ends in a hyphen a word may be divided, so the row
    /// below goes on whatever its length.
    func testARowAfterAHyphenGoesOn() {
        let structure = formattedStructure([row(0, "ITEM-"), row(2, "TWO"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("ITEM- TWO")])
    }

    /// Items in cell 1 that run over in cell 3 are one paragraph each: a row
    /// in cell 1 after an item's runover is the next item, not a runover.
    func testItemsInCellOneThatRunOverInCellThreeAreOneParagraphEach() {
        let structure = formattedStructure([
            fillerRow(0, 39), row(2, "FIRST END"), fillerRow(0, 39), row(2, "SECOND END"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [
            paragraph(filler(39) + " FIRST END"), paragraph(filler(39) + " SECOND END"),
        ])
    }

    /// BANA's paragraph still runs over in cell 1, whatever the length of the rows.
    func testRowsInCellOneStillGoOnAParagraph() {
        let structure = formattedStructure([row(2, "A PARAGRAPH"), row(0, "WITH SHORT"), row(0, "ROWS"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("A PARAGRAPH WITH SHORT ROWS")])
    }

    /// The layout's list items, in cells 1 and 3 and in 3 and 5, read back
    /// one paragraph for each, after a heading (the blank row after it
    /// starts a new block). The last row of each item is short, so the
    /// first word of the item below could have fitted on it.
    func testTextMouthsOwnListItemsInTwoDepthsReadBackOneParagraphEach() {
        let items: [BrailleBlock] = [
            .listItem(depth: 1, text: cells(filler(64))),
            .listItem(depth: 2, text: cells(filler(79))),
            .listItem(depth: 2, text: cells(filler(54))),
            .listItem(depth: 1, text: cells(filler(64))),
            .paragraph(text: cells(filler(64))),
        ]
        let blocks: [BrailleBlock] = [.heading(level: 1, text: cells("LISTS"))] + items
        let pages = BrailleLayout.pages(of: blocks, format: BraillePageFormat())
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [.heading(level: 1, text: cells("LISTS"))] + items.map { .paragraph(text: $0.text) })
    }

    /// A list between two paragraphs reads back one paragraph for each item,
    /// as the layout sets the list apart with a blank row before and after
    /// it. Without the row before, the first item, in cell 1, went on the
    /// paragraph above as its runovers do; without the row after, the
    /// paragraph below, in cell 3 under the last item's runover of 36 cells
    /// that its first word could not have joined, went on the item.
    func testAListBetweenParagraphsFromTheLayoutReadsBackOneParagraphForEachItem() {
        let blocks: [BrailleBlock] = [
            .paragraph(text: cells(filler(64))),
            .listItem(depth: 1, text: cells(filler(64))),
            .listItem(depth: 2, text: cells(filler(79))),
            .listItem(depth: 1, text: cells(filler(74))),
            .paragraph(text: cells(filler(64))),
        ]
        let pages = BrailleLayout.pages(of: blocks, format: BraillePageFormat())
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, blocks.map { .paragraph(text: $0.text) })
    }

    /// The layout's list items read back one paragraph each wherever a page
    /// break falls in the list: after 0 to 23 paragraphs of one row, a
    /// heading, items of three rows at depths 1 and 2, and a paragraph, so
    /// that the break falls after each of the list's rows in turn. An item's
    /// first row alone at a page's foot left its runover at the next page's
    /// top, where it began a paragraph (and each runover after it another),
    /// or, in cell 5, a heading.
    func testListItemsReadBackOneParagraphEachWhereverAPageBreakFalls() {
        let list: [BrailleBlock] = [
            .listItem(depth: 1, text: cells(filler(99))),
            .listItem(depth: 2, text: cells(filler(99))),
            .listItem(depth: 2, text: cells(filler(99))),
            .listItem(depth: 1, text: cells(filler(99))),
        ]
        for lead in 0..<24 {
            let blocks = [BrailleBlock](repeating: .paragraph(text: cells(filler(29))), count: lead)
                + [.heading(level: 1, text: cells("LISTS"))] + list + [.paragraph(text: cells(filler(64)))]
            let expected = blocks.map { block -> BrailleBlock in
                if case .listItem = block { return .paragraph(text: block.text) }
                return block
            }
            let pages = BrailleLayout.pages(of: blocks, format: BraillePageFormat())
            XCTAssertEqual(BraillePageAnalyzer.structure(of: pages, formatted: true).blocks, expected,
                           "after \(lead) paragraphs")
        }
    }

    /// A nested item's runover at a page's top is not a heading (it begins
    /// in cell 5, where a heading of level 2 does): the item goes on over
    /// the page break as one paragraph.
    func testANestedItemsRunoverAtAPagesTopIsNotAHeading() {
        let page1 = [fillerRow(2, 34), fillerRow(4, 34), rightAligned("#A")]
        let page2 = [row(4, "WWWW"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph(filler(34) + " " + filler(34) + " WWWW")])
    }

    /// The same through the layout: a depth-2 item that runs over a page.
    func testANestedItemOverAPageBreakFromTheLayoutIsOneParagraph() {
        let item = BrailleBlock.listItem(depth: 2, text: cells(filler(199)))
        let blocks: [BrailleBlock] = [.heading(level: 1, text: cells("LISTS")), item, .paragraph(text: cells(filler(49)))]
        let pages = BrailleLayout.pages(of: blocks, format: BraillePageFormat(cellsPerLine: 40, linesPerPage: 6, numbersPages: true))
        XCTAssertGreaterThan(pages.count, 1)
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [
            .heading(level: 1, text: cells("LISTS")), .paragraph(text: item.text), .paragraph(text: cells(filler(49))),
        ])
    }

    /// A heading in cell 5 at a page's top, under a paragraph of one row that
    /// fills the line, is a heading: it could be the runover of a list item
    /// as well, and the page break leaves no blank row to tell which.
    func testAHeadingAtAPagesTopUnderAOneRowParagraphStaysAHeading() {
        let page1 = [fillerRow(2, 34), rightAligned("#A")]
        let page2 = [row(4, "WWWW"), "", row(2, "TEXT"), rightAligned("#B")]
        let structure = BraillePageAnalyzer.structure(of: [page1, page2], formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph(filler(34)), .heading(level: 2, text: cells("WWWW")), paragraph("TEXT")])
    }

    // MARK: Width without page numbers

    /// A short book 40 cells wide with no page numbers: a title centered in
    /// 40 cells (15 blank cells before it, 16 after) and a sentence whose row
    /// is 30 cells, the longest. Against a width of 30 the title is off center.
    private func shortBook() -> [String] {
        [centered("THE TITLE"), "", row(2, "A SENTENCE OF ABOUT THIRTY C")]
    }

    /// A centered title in a short book with no page numbers is a heading,
    /// as the export writes it (decision 15's Grade 2 book at 40 by 25).
    func testACenteredTitleOfAShortBookWithoutPageNumbersIsAHeading() {
        let structure = formattedStructure(shortBook())
        XCTAssertEqual(structure.blocks, [.heading(level: 1, text: cells("THE TITLE")), paragraph("A SENTENCE OF ABOUT THIRTY C")])
    }

    /// The title may be several rows, each centered, and the width they imply
    /// is the same.
    func testAWrappedTitleOfAShortBookWithoutPageNumbersIsOneHeading() {
        let structure = formattedStructure([
            centered("THE LONG TITLE OF"), centered("A SHORT BOOK"), "", row(2, "A SENTENCE OF ABOUT THIRTY C"),
        ])
        XCTAssertEqual(structure.blocks, [
            .heading(level: 1, text: cells("THE LONG TITLE OF A SHORT BOOK")), paragraph("A SENTENCE OF ABOUT THIRTY C"),
        ])
    }

    /// With page numbers to measure, they are the width, and a lone row that
    /// implies a wider one does not move it.
    func testAPageNumberColumnIsTheWidthWhateverALoneRowImplies() {
        let page = [centered("THE TITLE"), "", row(2, "TEXT"), "", row(20, "WIDE"), rightAligned("#A")]
        XCTAssertEqual(formattedStructure(page).blocks.first, .heading(level: 1, text: cells("THE TITLE")))
    }

    /// Two headings centered in 40 cells outvote a lone row that implies 45.
    func testTheWidthTheMostHeadingsImplyWins() {
        let structure = formattedStructure([
            centered("FIRST TITLE"), "", row(2, "A SENTENCE OF ABOUT THIRTY C"), "", centered("SECOND ONE"), "",
            row(20, "WIDE"),
        ])
        XCTAssertEqual(structure.blocks, [
            .heading(level: 1, text: cells("FIRST TITLE")), paragraph("A SENTENCE OF ABOUT THIRTY C"),
            .heading(level: 1, text: cells("SECOND ONE")), paragraph("WIDE"),
        ])
    }

    /// A long heading in cell 5 stands alone too, but it is no vote: its row
    /// implies 44 cells, and the title, centered in 40, keeps the width.
    func testACellFiveHeadingDoesNotMoveTheImpliedWidth() {
        let structure = formattedStructure([
            centered("THE TITLE"), "", row(2, "A SENTENCE OF ABOUT THIRTY C"), "", row(4, word(36)), "", row(2, "TEXT"),
        ])
        XCTAssertEqual(structure.blocks, [
            .heading(level: 1, text: cells("THE TITLE")), paragraph("A SENTENCE OF ABOUT THIRTY C"),
            .heading(level: 2, text: cells(word(36))), paragraph("TEXT"),
        ])
    }

    /// A print page change line stands alone with its dashes at the left, and
    /// is no vote either.
    func testAPrintPageChangeLineIsNoVote() {
        let structure = formattedStructure([
            centered("THE TITLE"), "", row(2, "A SENTENCE OF ABOUT THIRTY C"), "",
            row(5, String(repeating: "-", count: 30) + "#E"),
        ])
        XCTAssertEqual(structure.blocks.first, .heading(level: 1, text: cells("THE TITLE")))
    }

    // MARK: A PEF's declared width

    /// The pages of `rows` as a PEF that declares `width`.
    private func pef(declaring width: Int?, _ rows: [String]) -> BrailleFilePages {
        var pages = BrailleFilePages(kind: .pef, pages: [rows])
        pages.lineWidth = width
        return pages
    }

    /// A declared width is the line width before any other rule: a last row
    /// of 30 cells that ends in a page number is a numbered page when nothing
    /// is declared, and plain text when 40 is.
    func testADeclaredWidthComesBeforeTheRowsThatMeasureOne() {
        let rows = [centered("THE TITLE"), "", row(2, "TEXT"), rightAligned("#A", width: 30)]
        XCTAssertEqual(BraillePageAnalyzer.structure(of: pef(declaring: nil, rows)).pages.first?.braillePageNumber, "⠼⠁")
        let declared = BraillePageAnalyzer.structure(of: pef(declaring: 40, rows))
        XCTAssertNil(declared.pages.first?.braillePageNumber)
        XCTAssertEqual(declared.blocks.first, .heading(level: 1, text: cells("THE TITLE")))
    }

    /// A width outside 18 to 80 is ignored, so the rows measure it.
    func testADeclaredWidthOutsideTheRangeIsIgnored() {
        let rows = [centered("THE TITLE"), "", row(2, "TEXT"), rightAligned("#A")]
        let measured = BraillePageAnalyzer.structure(of: pef(declaring: nil, rows))
        for width in [0, 17, 81, 1000, -40] {
            XCTAssertEqual(BraillePageAnalyzer.structure(of: pef(declaring: width, rows)), measured, "\(width)")
        }
        XCTAssertEqual(measured.pages.first?.braillePageNumber, "⠼⠁")
    }

    // MARK: Unformatted files

    func testUnformattedRowsEachBecomeATrimmedParagraph() {
        let rows = [cells("  ONE   TWO  "), "", cells("THREE"), cells("   "), cells(" FOUR  FIVE")]
        let structure = BraillePageAnalyzer.structure(of: [rows], formatted: false)
        XCTAssertEqual(structure.blocks, [paragraph("ONE TWO"), paragraph("THREE"), paragraph("FOUR FIVE")])
        XCTAssertEqual(structure.pages, [BraillePageNumbers(firstBlockIndex: 0, hasText: true)])
    }

    func testUnformattedRowsMakeNoHeadingsOrPageNumbers() {
        let structure = BraillePageAnalyzer.structure(of: [[centered("TITLE"), rightAligned("#A")]], formatted: false)
        XCTAssertEqual(structure.blocks.count, 2)
        XCTAssertEqual(structure.blocks.first, paragraph("TITLE"))
        XCTAssertEqual(structure.pages, [BraillePageNumbers(firstBlockIndex: 0, hasText: true)])
    }

    func testAnUnformattedFileWithNoRowsStillHasOnePage() {
        XCTAssertEqual(BraillePageAnalyzer.structure(of: [], formatted: false),
                       BrailleStructure(blocks: [], pages: [BraillePageNumbers(firstBlockIndex: 0)]))
        XCTAssertEqual(BraillePageAnalyzer.structure(of: [["", ""]], formatted: false).blocks, [])
    }

    // MARK: Empty input

    func testNoPagesGiveNothing() {
        XCTAssertEqual(BraillePageAnalyzer.structure(of: [], formatted: true), BrailleStructure(blocks: [], pages: []))
    }

    func testPagesOfBlankRowsGiveNoBlocksAndAnEntryForEachPage() {
        let blankRow = cells("     ")
        let structure = BraillePageAnalyzer.structure(of: [[blankRow, "", blankRow], [], [""]], formatted: true)
        XCTAssertEqual(structure.blocks, [])
        XCTAssertEqual(structure.pages, Array(repeating: BraillePageNumbers(firstBlockIndex: 0), count: 3))
    }

    func testAPageWithNoTextHasTheIndexOfTheNextBlock() {
        let pages = [[row(2, "ONE"), rightAligned("#A")], ["", ""], [row(2, "TWO"), rightAligned("#C")], [""]]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("ONE"), paragraph("TWO")])
        // The empty page points at "TWO", and the last page, past the end, at the count.
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 1, 1, 2])
    }

    // MARK: Where each page begins (PG12)

    /// Where the word `word` begins in `ascii`, counted in cells: each
    /// character of a row written in braille ASCII is one cell (`cells(_:)`),
    /// so a block's text and its ASCII count alike.
    private func offset(of word: String, in ascii: String) -> Int {
        guard let range = ascii.range(of: word) else {
            XCTFail("\"\(word)\" is not in \"\(ascii)\"")
            return -1
        }
        return ascii.distance(from: ascii.startIndex, to: range.lowerBound)
    }

    /// The sample's second page begins inside the paragraph it goes on (the
    /// 7th, block 8), at "taken": the cell after the first page's last word
    /// and the blank cell that joins the paragraph's rows.
    func testTheSamplesSecondPageBeginsInsideTheParagraphItGoesOn() throws {
        let structure = BraillePageAnalyzer.structure(
            of: try sampleBRFPages("brf/pride-and-prejudice-ch1-grade1.brf"), formatted: true)
        let lastRowOfPageOne = "8,DO NOT YOU WANT TO KNOW WHO HAS"
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 8])
        XCTAssertEqual(structure.pages.map(\.firstCellOffset), [0, lastRowOfPageOne.count + 1])
        guard structure.blocks.count > 8 else { return XCTFail("the sample has \(structure.blocks.count) blocks") }
        let text = Array(structure.blocks[8].text.unicodeScalars)
        guard text.count > lastRowOfPageOne.count + 5 else { return XCTFail("block 8 has \(text.count) cells") }
        XCTAssertEqual(text[lastRowOfPageOne.count], BrailleCells.blank)
        XCTAssertEqual(String(String.UnicodeScalarView(text[(lastRowOfPageOne.count + 1)...].prefix(5))), cells("TAKEN"))
    }

    /// A paragraph over three pages: the second and third pages each begin
    /// at the first word of their first row, inside it.
    func testAParagraphOverThreePagesNamesWhereEachPageBeginsInIt() {
        let pages = [
            [row(2, "ONE"), "", row(2, "A LONG PARAGRAPH"), rightAligned("#A")],
            [row(0, "GOES ON HERE"), rightAligned("#B")],
            [row(0, "AND ENDS"), "", row(2, "NEXT"), rightAligned("#C")],
        ]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        let long = "A LONG PARAGRAPH GOES ON HERE AND ENDS"
        XCTAssertEqual(structure.blocks, [paragraph("ONE"), paragraph(long), paragraph("NEXT")])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 1, 1])
        XCTAssertEqual(structure.pages.map(\.firstCellOffset), [0, offset(of: "GOES", in: long), offset(of: "AND", in: long)])
    }

    /// A cell-5 heading that goes on at the top of the next page: that page
    /// begins inside the heading, at its row's first word.
    func testAHeadingThatGoesOnOverAPageNamesWhereThePageBeginsInIt() {
        let pages = [
            [row(2, "TEXT"), "", row(4, "A HEADING IN CELL FIVE"), rightAligned("#A")],
            [row(4, "THAT GOES ON"), "", row(2, "MORE"), rightAligned("#B")],
        ]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        let heading = "A HEADING IN CELL FIVE THAT GOES ON"
        XCTAssertEqual(structure.blocks, [paragraph("TEXT"), .heading(level: 2, text: cells(heading)), paragraph("MORE")])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 1])
        XCTAssertEqual(structure.pages.map(\.firstCellOffset), [0, offset(of: "THAT", in: heading)])
    }

    /// A page with nothing but its number, in the middle of a paragraph,
    /// begins where the next page does, inside the paragraph.
    func testAPageWithNoTextInsideAParagraphBeginsWhereTheNextPageDoes() {
        let pages = [
            [row(2, "A PARAGRAPH THAT"), rightAligned("#A")],
            [rightAligned("#B")],
            [row(0, "GOES ON"), rightAligned("#C")],
        ]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        let paragraphText = "A PARAGRAPH THAT GOES ON"
        XCTAssertEqual(structure.blocks, [paragraph(paragraphText)])
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", "⠼⠃", "⠼⠉"])
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 0, 0])
        let goesOn = offset(of: "GOES", in: paragraphText)
        XCTAssertEqual(structure.pages.map(\.firstCellOffset), [0, goesOn, goesOn])
    }

    /// Pages that begin a block begin at its first cell, and a page after the
    /// last block (past the end) at 0 too.
    func testAPageThatBeginsABlockOrComesAfterTheLastBeginsAtItsFirstCell() {
        let pages = [[row(2, "ONE"), rightAligned("#A")], ["", ""], [row(2, "TWO"), rightAligned("#C")], [""]]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.pages.map(\.firstBlockIndex), [0, 1, 1, 2])
        XCTAssertEqual(structure.pages.map(\.firstCellOffset), [0, 0, 0, 0])
        // The block-style book's fourth paragraph begins page 2.
        XCTAssertEqual(BraillePageAnalyzer.structure(of: blockStylePages(), formatted: true).pages.map(\.firstCellOffset), [0, 0])
    }

    /// Each page says whether it holds text: a page of nothing but blank rows,
    /// or of nothing but its number, holds none, though it begins where the
    /// next page with text does (review of October 24).
    func testEachPageSaysWhetherItHoldsText() {
        let pages = [[row(2, "ONE"), rightAligned("#A")], ["", ""], [rightAligned("#C")], [row(0, "TWO"), rightAligned("#D")]]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("ONE TWO")])
        XCTAssertEqual(structure.pages.map(\.hasText), [true, false, false, true])
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), ["⠼⠁", nil, "⠼⠉", "⠼⠙"])
    }

    // MARK: Large input

    func testALargeBookIsReadInAReasonableTime() {
        // 20,000 pages of 25 rows: a quadratic reader would not finish.
        let page = (0..<24).map { index in index % 6 == 0 ? row(2, "WORD WORD WORD") : row(0, "WORD WORD") } + [rightAligned("#A")]
        let pages = Array(repeating: page, count: 20_000)
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.pages.count, 20_000)
        XCTAssertEqual(structure.blocks.count, 4 * 20_000)
    }

    // MARK: Page labels (PG12)

    /// A braille page number reads as the print it writes: digits after the
    /// number sign, letters before it or after it, a capital sign's capital.
    func testABraillePageNumberReadsAsPrint() {
        let expectations: [(ascii: String, label: String)] = [
            ("#A", "1"), ("#AB", "12"), ("#AJJ", "100"), ("#J", "0"),
            ("P#A", "p1"), ("T#C", "t3"), ("A#A", "a1"), (",P#A", "P1"),
            ("#A;A", "1a"), ("#AK", "1k"), ("#A,B", "1B"), ("#AB;CD", "12cd"),
        ]
        for (ascii, label) in expectations {
            XCTAssertEqual(BraillePageNumbers.printLabel(of: cells(ascii)), label, ascii)
        }
    }

    /// A word this reading does not know has no label: no number, a second
    /// number, a sign with nothing after it, a cell no page number uses, a
    /// blank cell, an eight-dot cell, or text that is no braille.
    func testAWordThisReadingDoesNotKnowHasNoLabel() {
        let unknown = ["", "#", "P", "P#", "#A#B", "##A", "#,A", "#;A", "#A;", "#A,", ",#A", "#-A", "#A-B", "A1", "#A B", "#K"]
        for ascii in unknown {
            XCTAssertNil(BraillePageNumbers.printLabel(of: cells(ascii)), ascii)
        }
        XCTAssertNil(BraillePageNumbers.printLabel(of: "⠼⣁"))
        XCTAssertNil(BraillePageNumbers.printLabel(of: "#A"))
    }

    /// A page's label is its braille page number read as print, and a page
    /// without one has none; the sample's pages are 1 and 2.
    func testAPagesLabelIsItsBraillePageNumberReadAsPrint() throws {
        XCTAssertNil(BraillePageNumbers(firstBlockIndex: 0).braillePageLabel)
        XCTAssertEqual(BraillePageNumbers(braillePageNumber: cells("#AB"), firstBlockIndex: 0).braillePageLabel, "12")
        let structure = BraillePageAnalyzer.structure(
            of: try sampleBRFPages("brf/pride-and-prejudice-ch1-grade1.brf"), formatted: true)
        XCTAssertEqual(structure.pages.map(\.braillePageLabel), ["1", "2"])
    }
}

// MARK: - Running heads (Life of Pi, November 13)

extension BraillePageAnalyzerTests {
    /// The first row of a page the way an old transcription writes it: a
    /// braille page number at the left, the running head, a print page
    /// number at the right end of a 40-cell line.
    private func headRow(left: String, head: String, right: String) -> String {
        rightAligned(right, text: left + " " + head)
    }

    /// A page of an old-style book: its head row, then a paragraph's rows.
    private func headedPage(left: String, right: String, head: String = ",LIFE ( ,PI4 ,\"P#A", body: [String]) -> [String] {
        [headRow(left: left, head: head, right: right)] + body
    }

    /// A head with a braille page number at its left and a print page number
    /// at its right, repeated on three pages, is taken out whole: the book's
    /// text has none of it, and both numbers are the page's.
    func testARunningHeadThatRepeatsOnThreePagesIsDropped() {
        let pages = [
            headedPage(left: "A#AJ", right: "#CA", body: [row(2, "FIRST PAGE TEXT")]),
            headedPage(left: "A#AA", right: "#CB", body: [row(0, "SECOND PAGE TEXT")]),
            headedPage(left: "A#AB", right: "#CC", body: [row(0, "THIRD PAGE TEXT")]),
        ]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.blocks, [paragraph("FIRST PAGE TEXT SECOND PAGE TEXT THIRD PAGE TEXT")])
        // The left word is the braille page number, the right word the print page's.
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), [cells("A#AJ"), cells("A#AA"), cells("A#AB")])
        XCTAssertEqual(structure.pages.map(\.printPageNumber), [cells("#CA"), cells("#CB"), cells("#CC")])
    }

    /// A head on only two pages could be text: it stays, as it did.
    func testAHeadThatRepeatsOnTwoPagesIsKept() {
        let pages = [
            headedPage(left: "A#AJ", right: "#CA", body: [row(2, "ONE")]),
            headedPage(left: "A#AA", right: "#CB", body: [row(0, "TWO")]),
        ]
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        // Each page's head row is text, as before: it stands before the page's paragraph.
        XCTAssertEqual(structure.blocks.count, 2)
        XCTAssertTrue(structure.blocks.first?.text.contains(cells(",LIFE")) ?? false)
        // With no right-hand braille page number the left word is not read as one either.
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), [nil, nil])
    }

    /// A head that alternates between two texts (title, chapter) is dropped
    /// when each text repeats on three pages.
    func testAlternatingHeadsAreBothDropped() {
        /// A letter A to F by index, to make each page's numbers differ.
        func letter(_ index: Int) -> String { String(UnicodeScalar(UInt8(65 + index))) }
        var pages: [[String]] = []
        for index in 0..<6 {
            let head = index % 2 == 0 ? ",TITLE" : ",CHAPTER"
            pages.append(headedPage(left: "#" + letter(index), right: "#A" + letter(index), head: head,
                                    body: [row(index == 0 ? 2 : 0, "TEXT" + letter(index))]))
        }
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertFalse(structure.blocks.contains { $0.text.contains(cells(",TITLE")) || $0.text.contains(cells(",CHAPTER")) })
        XCTAssertEqual(structure.pages.count, 6)
    }

    /// A page whose last row already holds the braille page number keeps it,
    /// and the head's left word is not read as another.
    func testABraillePageNumberAtTheBottomWinsOverTheHeadsLeftWord() {
        func page(_ left: String, _ right: String, _ bottom: String) -> [String] {
            [headRow(left: left, head: ",HEAD", right: right), row(2, "BODY TEXT"), rightAligned(bottom)]
        }
        let structure = BraillePageAnalyzer.structure(
            of: [page("#A", "#CA", "#AA"), page("#B", "#CB", "#AB"), page("#C", "#CC", "#AC")], formatted: true)
        XCTAssertEqual(structure.pages.map(\.braillePageNumber), [cells("#AA"), cells("#AB"), cells("#AC")])
        XCTAssertEqual(structure.pages.map(\.printPageNumber), [cells("#CA"), cells("#CB"), cells("#CC")])
        XCTAssertFalse(structure.blocks.contains { $0.text.contains(cells(",HEAD")) })
    }

    /// A first row of real text that has no number word is never a head,
    /// however often it repeats.
    func testARepeatedFirstRowWithNoNumberWordIsKept() {
        let pages = (0..<4).map { _ in [row(2, "REPEATED OPENING")] }
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        // Four pages, four paragraphs: none is taken for a head.
        XCTAssertEqual(structure.blocks.count, 4)
        XCTAssertTrue(structure.blocks.allSatisfy { $0.text.contains(cells("REPEATED")) })
    }
}

// MARK: - Roman numeral change lines (Life of Pi, November 13)

extension BraillePageAnalyzerTests {
    /// A front matter page's change line (`------;IX`) is taken out like a
    /// numbered one, and its numeral is kept as the page's change.
    func testARomanNumeralChangeLineIsTakenOutOfTheText() {
        let structure = formattedStructure([row(2, "ONE TWO"), row(0, "THREE"), row(0, "------;IX"), row(0, "FOUR"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("ONE TWO THREE FOUR")])
        XCTAssertEqual(structure.pages.first?.printPageChanges, [cells(";IX")])
    }

    /// A capital sign and every Roman numeral letter are accepted; a numeral
    /// of more than seven letters, or a word with another letter, is no change line.
    func testRomanNumeralChangeLinesTakeCapitalsAndNoOtherLetters() {
        let accepted = formattedStructure([row(2, "ONE"), row(0, "---,XLVIII"), row(0, "TWO"), rightAligned("#A")])
        XCTAssertEqual(accepted.pages.first?.printPageChanges, [cells(",XLVIII")])
        XCTAssertEqual(accepted.blocks, [paragraph("ONE TWO")])
        for ascii in ["---;IXA", "---;", "---;IIIIIIII", "--;IX"] {
            let kept = formattedStructure([row(2, "ONE"), row(0, ascii), row(0, "TWO"), rightAligned("#A")])
            XCTAssertEqual(kept.pages.first?.printPageChanges, [], ascii)
            XCTAssertEqual(kept.blocks.count, 1, ascii)
            XCTAssertTrue(kept.blocks.first?.text.contains(cells(ascii)) ?? false, ascii)
        }
    }
}

// MARK: - Chapter rows that run straight into text (Life of Pi, November 13)

extension BraillePageAnalyzerTests {
    /// "Chapter 1" centered under a rule and followed directly by the
    /// paragraph's indented first row, with no blank row between, is a
    /// heading; the rule is no part of its text.
    func testACenteredChapterRowRunningIntoAnIndentedRowIsAHeadingWithoutItsRule() {
        let structure = formattedStructure([
            row(2, "BEFORE"), "", centered("333333333333"), centered(",*APT] #A"),
            row(2, "THE FIRST ROW"), row(0, "RUNS ON"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [
            paragraph("BEFORE"), .heading(level: 1, text: cells(",*APT] #A")), paragraph("THE FIRST ROW RUNS ON"),
        ])
    }

    /// A part title above the rule is part of the same heading, rule left out.
    func testAPartTitleAndAChapterRowAreOneHeading() {
        let structure = formattedStructure([
            centered(",PART ONE"), centered("333333333333"), centered(",*APT] #A"), row(2, "TEXT"), rightAligned("#A"),
        ])
        XCTAssertEqual(structure.blocks, [.heading(level: 1, text: cells(",PART ONE ,*APT] #A")), paragraph("TEXT")])
    }

    /// A rule row alone, between blank rows, is no heading and no text.
    func testARuleRowAloneMakesNoHeading() {
        let structure = formattedStructure([row(2, "BEFORE"), "", centered("333333333333"), "", row(2, "AFTER"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("BEFORE"), paragraph("AFTER")])
    }

    /// Letters repeated are not a rule: a centered row of them stays text.
    func testARowOfLettersIsNotARule() {
        let structure = formattedStructure([row(2, "BEFORE"), "", centered("AAAA"), "", rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("BEFORE"), .heading(level: 1, text: cells("AAAA"))])
    }

    /// More than three centered rows of text running into an indented row
    /// are not a heading: they are as likely to be a centered verse.
    func testFourCenteredRowsRunningIntoTextAreNotAHeading() {
        let structure = formattedStructure([
            row(2, "BEFORE"), "", centered("ONE"), centered("TWO"), centered("THREE"), centered("FOUR"),
            row(2, "TEXT"), rightAligned("#A"),
        ])
        XCTAssertFalse(structure.blocks.contains { if case .heading(level: 1, text: _) = $0 { return true } else { return false } })
    }

    /// A centered row that runs into a row at cell 1, not cell 3, is not a heading, as before.
    func testACenteredRowRunningIntoACellOneRowIsStillNotAHeading() {
        let structure = formattedStructure([row(2, "BEFORE"), "", centered("AAAA"), row(0, "RUNS ON"), rightAligned("#A")])
        XCTAssertEqual(structure.blocks, [paragraph("BEFORE"), paragraph("AAAA RUNS ON")])
    }
}

// MARK: - The title page (Life of Pi, November 13)

extension BraillePageAnalyzerTests {
    /// The cells of `ascii`, as one braille text with its blanks.
    private func braille(_ ascii: String) -> String { cells(ascii) }

    /// The centered rows of the first page come back one by one, a rule or a
    /// row of another kind parting two stretches with an empty string.
    func testTheCenteredRowsOfTheFirstPageAreGivenRowByRow() {
        let page = [
            rightAligned("#A"), centered(",LIFE ( ,PI"), centered("0,YANN ,M>TEL"), centered("333333333333"),
            centered(",9 #D ,VOLUMES"), "", row(2, "A PARAGRAPH OF TEXT"),
        ]
        let rows = BraillePageAnalyzer.centeredRowsOfFirstPage(of: BrailleFilePages(kind: .brf, pages: [page]))
        XCTAssertEqual(rows, [braille(",LIFE ( ,PI"), braille("0,YANN ,M>TEL"), "", braille(",9 #D ,VOLUMES")])
    }

    /// A page with no text before the title page (a form feed at the file's
    /// start) is passed over, and a BRL has no title page.
    func testAnEmptyFirstPageIsPassedOverAndABRLHasNoTitlePage() {
        let pages = [[""], [centered(",TITLE"), centered(",ONE"), centered(",TWO")]]
        XCTAssertEqual(BraillePageAnalyzer.centeredRowsOfFirstPage(of: BrailleFilePages(kind: .brf, pages: pages)).count, 3)
        XCTAssertEqual(BraillePageAnalyzer.centeredRowsOfFirstPage(of: BrailleFilePages(kind: .brl, pages: pages)), [])
    }

    /// English Braille's "by" sign written against the author's capital,
    /// "Title / by Author", the title is the first row and the author the
    /// words after the sign.
    func testTheEnglishBrailleBySignNamesTheAuthor() {
        let names = BrailleTitlePage.names(inRows: [braille(",LIFE ( ,PI"), braille("0,YANN ,M>TEL"), "", braille(",9 #D ,VOLUMES")])
        XCTAssertEqual(names, BrailleTitlePage.Names(title: braille(",LIFE ( ,PI"), author: braille(",YANN ,M>TEL")))
    }

    /// "by" spelled, on a row of its own with the author on the next, or
    /// with the author after it, or inside the title's row, names the author.
    func testASpelledByNamesTheAuthorOnItsOwnRowOrInTheTitlesRow() {
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",A ,TITLE"), braille("BY"), braille(",SOME ,ONE")]),
            BrailleTitlePage.Names(title: braille(",A ,TITLE"), author: braille(",SOME ,ONE")))
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",A ,TITLE"), braille("BY ,SOME ,ONE")]),
            BrailleTitlePage.Names(title: braille(",A ,TITLE"), author: braille(",SOME ,ONE")))
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",A ,TITLE BY ,SOME ,ONE")]),
            BrailleTitlePage.Names(title: braille(",A ,TITLE"), author: braille(",SOME ,ONE")))
        // A "by" inside the title is the title's when the next row begins with "by".
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",STAND BY ,ME"), braille("BY ,SOME ,ONE")]),
            BrailleTitlePage.Names(title: braille(",STAND BY ,ME"), author: braille(",SOME ,ONE")))
    }

    /// A title of two rows before the author's is one title, and a
    /// "Published by" row of a later stretch is no author's.
    func testATwoRowTitleIsOneTitleAndALaterPublishedByNamesNoAuthor() {
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",ONE"), braille(",TWO"), braille("BY ,A ,B")]),
            BrailleTitlePage.Names(title: braille(",ONE ,TWO"), author: braille(",A ,B")))
        XCTAssertEqual(
            BrailleTitlePage.names(inRows: [braille(",TITLE"), "", braille(",PUBLISHED BY ,X"), braille(",ISBN")]),
            BrailleTitlePage.Names(title: braille(",TITLE"), author: nil))
    }

    /// A page of one or two rows with no "by" is no title page (a chapter
    /// opening with the book's title and its heading is not): nothing is
    /// named, and the file's name stands.
    func testAPageWithNoByAndFewerThanThreeRowsNamesNothing() {
        XCTAssertNil(BrailleTitlePage.names(inRows: []))
        XCTAssertNil(BrailleTitlePage.names(inRows: [braille(",PRIDE"), "", braille(",CHAPTER ,I")]))
    }
}

/// A BRF's title page, read into the title and author a new book is listed
/// under.
final class BrailleTitlePageImportTests: XCTestCase {
    /// A file named `name` holding `rows` as BRF text (CR LF between rows),
    /// in a folder of this test's own.
    private func brf(named name: String, rows: [String]) throws -> URL {
        let url = try makeSandboxDirectory("BrailleTitlePage").appendingPathComponent(name)
        try Data(rows.joined(separator: "\r\n").utf8).write(to: url)
        return url
    }

    /// `ascii` centered in a 40-cell line.
    private func centered(_ ascii: String) -> String {
        String(repeating: " ", count: (40 - ascii.count) / 2) + ascii
    }

    /// An invented title page: the title, "by" and the author, a rule, a
    /// publisher's line, and a first page of text after it.
    private var titlePageRows: [String] {
        [centered(",A ,QUIET ,HARBOUR"), centered("0,JOHN ,SMITH"), centered("333333333333"),
         centered(",PUBLI%$ BY ,ACME"), centered(",SEATTLE"), "", "\u{0C}" + "  ,THE ,FIRST ,CHAPTER"]
    }

    /// The Braille setting's table, Grade 2 UEB, reads the title page, and
    /// the book is listed under its title and author, not its file's name.
    func testANewBRFIsListedUnderItsTitlePagesTitleAndAuthor() throws {
        let url = try brf(named: "000012345.brf", rows: titlePageRows)
        let metadata = ImportedFileMetadata.read(
            from: url, format: .braille, brailleReading: (table: "en-ueb-g2.ctb", fileCode: nil))
        XCTAssertEqual(metadata.title, "A Quiet Harbour")
        XCTAssertEqual(metadata.author, "John Smith")
    }

    /// A BRF with no title page, such as the sample that opens with a chapter, keeps its file's name.
    func testABRFWithoutATitlePageKeepsItsFileNameAndAnUnknownAuthor() throws {
        let url = try brf(named: "just-a-chapter.brf", rows: [centered(",CHAPTER ,ONE"), "", "  ,SOME ,TEXT"])
        let metadata = ImportedFileMetadata.read(
            from: url, format: .braille, brailleReading: (table: "en-ueb-g2.ctb", fileCode: nil))
        XCTAssertEqual(metadata.title, "just-a-chapter")
        XCTAssertEqual(metadata.author, Book.unknownAuthor)
    }

    /// A table the book cannot be read with leaves the file's name, never a refusal.
    func testAnUnknownTableLeavesTheFileNameAndNeverFails() throws {
        let url = try brf(named: "named.brf", rows: titlePageRows)
        let metadata = ImportedFileMetadata.read(
            from: url, format: .braille, brailleReading: (table: "no-such-table.ctb", fileCode: nil))
        XCTAssertEqual(metadata.title, "named")
        XCTAssertEqual(metadata.author, Book.unknownAuthor)
    }
}

// MARK: - Telling English Braille, American Edition from UEB (Life of Pi, November 13)

extension BraillePageAnalyzerTests {
    /// The detector's count of pages made of `rows` (North American Braille ASCII).
    private func detectorCount(_ rows: [String]) -> BrailleCodeDetector.Count {
        BrailleCodeDetector.count(of: BrailleFilePages(kind: .brf, pages: [rows.map { cells($0) }]))
    }

    /// "to" and "by" joined to the next word, and "ation" and "ally" inside a
    /// word, are the old code's signs; a book full of them looks like it.
    func testWordsWithTheOldCodesSignsAreCountedAndTheBookLooksOld() {
        // Two words with a joined "to" and "by", then "populN" and "reY" (a capital N or Y after a letter).
        let count = detectorCount(["6GO 0,JOHN POPUL,N RE,Y PLAIN"])
        XCTAssertEqual(count.words, 5)
        XCTAssertEqual(count.hits, 4)
        let book = detectorCount(Array(repeating: "6GO 6BE 0THE 6SEE 6DO 6SAY", count: 3))
        XCTAssertEqual(book.hits, 18)
        XCTAssertTrue(book.looksLikeEBAE)
    }

    /// UEB writes none of those signs: its "!" and closing quote stand alone or end a word,
    /// and its capital sign begins a word.
    func testUEBTextDoesNotLookOld() {
        let count = detectorCount(["THE CAT SAT ON THE MAT6 ,HE SAID0 ,MC,NEIL", "6 0 ,NAME ,YES"])
        XCTAssertEqual(count.hits, 1, "only a capital N after a letter, as in a name, shows a sign")
        XCTAssertFalse(count.looksLikeEBAE)
    }

    /// A few such words in a long book are not enough, nor are several
    /// words too few of the book's: the book needs at least ten and one in a hundred.
    func testAFewOrAFractionOfAPercentOfOldSignsDoesNotLookOld() {
        var rows = Array(repeating: "6GO", count: 9)
        XCTAssertFalse(detectorCount(rows).looksLikeEBAE, "nine words are too few")
        rows.append("6GO")
        XCTAssertTrue(detectorCount(rows).looksLikeEBAE, "ten of ten words")
        rows += Array(repeating: "THE CAT SAT ON THE MAT", count: 300)
        XCTAssertFalse(detectorCount(rows).looksLikeEBAE, "ten of 1,810 words is under one in a hundred")
    }
}
