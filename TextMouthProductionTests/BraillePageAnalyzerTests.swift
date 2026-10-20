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

    // MARK: Unformatted files

    func testUnformattedRowsEachBecomeATrimmedParagraph() {
        let rows = [cells("  ONE   TWO  "), "", cells("THREE"), cells("   "), cells(" FOUR  FIVE")]
        let structure = BraillePageAnalyzer.structure(of: [rows], formatted: false)
        XCTAssertEqual(structure.blocks, [paragraph("ONE TWO"), paragraph("THREE"), paragraph("FOUR FIVE")])
        XCTAssertEqual(structure.pages, [BraillePageNumbers(firstBlockIndex: 0)])
    }

    func testUnformattedRowsMakeNoHeadingsOrPageNumbers() {
        let structure = BraillePageAnalyzer.structure(of: [[centered("TITLE"), rightAligned("#A")]], formatted: false)
        XCTAssertEqual(structure.blocks.count, 2)
        XCTAssertEqual(structure.blocks.first, paragraph("TITLE"))
        XCTAssertEqual(structure.pages, [BraillePageNumbers(firstBlockIndex: 0)])
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

    // MARK: Large input

    func testALargeBookIsReadInAReasonableTime() {
        // 20,000 pages of 25 rows: a quadratic reader would not finish.
        let page = (0..<24).map { index in index % 6 == 0 ? row(2, "WORD WORD WORD") : row(0, "WORD WORD") } + [rightAligned("#A")]
        let pages = Array(repeating: page, count: 20_000)
        let structure = BraillePageAnalyzer.structure(of: pages, formatted: true)
        XCTAssertEqual(structure.pages.count, 20_000)
        XCTAssertEqual(structure.blocks.count, 4 * 20_000)
    }
}
