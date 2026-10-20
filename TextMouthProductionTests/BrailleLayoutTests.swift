import XCTest
@testable import TextMouth

// MARK: - Helpers

extension XCTestCase {
    /// `ascii` (North American Braille ASCII, a space for the blank cell) as
    /// Unicode cells, so that a test can write braille as readable letters.
    func brailleCells(_ ascii: String) -> String {
        String(String.UnicodeScalarView(ascii.utf8.compactMap { BrailleCells.cell(forASCII: $0) }))
    }

    /// `cells` as braille ASCII, a space for the blank cell and "?" for a
    /// cell that has no character (an eight-dot cell), for comparisons that
    /// read well in a failure message.
    func brailleASCII(_ cells: String) -> String {
        String(cells.unicodeScalars.map { scalar -> Character in
            guard let byte = BrailleCells.ascii(for: scalar) else { return "?" }
            return Character(Unicode.Scalar(byte))
        })
    }

    /// Row `row` of page `page` of `pages`, or nil when the layout gave no
    /// such row, so that a test reading a row never traps the test host on
    /// a page shorter than it expects.
    func rowAt(_ pages: [[String]], _ page: Int, _ row: Int) -> String? {
        guard pages.indices.contains(page), pages[page].indices.contains(row) else { return nil }
        return pages[page][row]
    }

    /// The pages of a BRF file's bytes as rows of Unicode cells: split at the
    /// form feeds, then at the line ends (CR LF or LF), each byte converted
    /// with `BrailleCells.cell(forASCII:)`. A page's last line end is not a
    /// row.
    func brfPages(_ data: Data) -> [[String]] {
        data.split(separator: 0x0C, omittingEmptySubsequences: false).map { pageBytes in
            var lines = pageBytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
                // A CR before the LF belongs to the line end.
                line.last == 0x0D ? line.dropLast() : line
            }
            // The text after the page's last line end is empty.
            if lines.last?.isEmpty == true { lines.removeLast() }
            return lines.map { line in
                String(String.UnicodeScalarView(line.compactMap { BrailleCells.cell(forASCII: $0) }))
            }
        }
    }

    /// The pages of the BRF sample "pride-and-prejudice-ch1-grade1.brf", read
    /// from a copy of the sample.
    func brfSamplePages() throws -> [[String]] {
        let copy = try copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf")
        return brfPages(try Data(contentsOf: copy))
    }
}

// MARK: - Tests

/// Tests for `BrailleLayout` (FMT22, Phase A): braille blocks laid out in
/// pages as BANA's Braille Formats (2016) says. Most tests write their
/// braille in North American Braille ASCII ("AB" is ⠁⠃, a space the blank
/// cell) and compare rows in that form, so that a failure reads as the
/// page; the sample test compares the real cells.
final class BrailleLayoutTests: XCTestCase {
    // MARK: Helpers

    /// `blocks` laid out in braille ASCII rows, one array of rows per page.
    private func pages(
        _ blocks: [BrailleBlock], cells: Int = 40, lines: Int = 25, numbers: Bool = true
    ) -> [[String]] {
        let format = BraillePageFormat(cellsPerLine: cells, linesPerPage: lines, numbersPages: numbers)
        return BrailleLayout.pages(of: blocks, format: format).map { $0.map(brailleASCII) }
    }

    /// A paragraph block of braille ASCII text.
    private func paragraph(_ ascii: String) -> BrailleBlock { .paragraph(text: brailleCells(ascii)) }

    /// A heading block of braille ASCII text.
    private func heading(_ level: Int, _ ascii: String) -> BrailleBlock {
        .heading(level: level, text: brailleCells(ascii))
    }

    /// A list item block of braille ASCII text.
    private func item(_ depth: Int, _ ascii: String) -> BrailleBlock {
        .listItem(depth: depth, text: brailleCells(ascii))
    }

    /// `count` blanks, for a row's expected margin.
    private func blanks(_ count: Int) -> String { String(repeating: " ", count: count) }

    // MARK: The samples

    /// The BRL sample's 14 lines (title, heading, 12 paragraphs), laid out at
    /// 40 by 25 with page numbers, are the BRF sample's two pages, row for row.
    func testTheSampleBookLaysOutAsTheBRFSampleDoes() throws {
        let brl = try copyOfFormatSample("brl/pride-and-prejudice-ch1-grade1.brl")
        let text = try XCTUnwrap(String(data: Data(contentsOf: brl), encoding: .ascii))
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.count, 14)
        guard lines.count == 14 else { return }

        // Line 1 is the title, line 2 the heading, the rest paragraphs.
        var blocks: [BrailleBlock] = [heading(1, lines[0]), heading(2, lines[1])]
        blocks += lines[2...].map { paragraph($0) }

        let expected = try brfSamplePages()
        XCTAssertEqual(expected.count, 2)
        let actual = BrailleLayout.pages(of: blocks, format: BraillePageFormat())
        XCTAssertEqual(actual.count, expected.count)
        guard actual.count == expected.count else { return }
        for (number, (laidOut, wanted)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(laidOut.count, 25, "page \(number + 1) has 25 rows")
            XCTAssertEqual(laidOut.map(brailleASCII), wanted.map(brailleASCII), "page \(number + 1)")
            // The strings themselves, cell for cell, not just their ASCII.
            XCTAssertEqual(laidOut, wanted, "page \(number + 1)")
        }
    }

    // MARK: Words and wrapping

    /// A line takes as many whole words as fit, one blank cell between them;
    /// the first line of a paragraph starts in cell 3.
    func testLinesTakeWholeWordsWithOneBlankBetween() throws {
        let result = pages([paragraph("AB CD EF GH IJ KL MN")], cells: 18)
        XCTAssertEqual(result.count, 1)
        guard let page = result.first else { return }
        // Cells 3 to 18 hold 16 cells: five words and their blanks take 14,
        // and a sixth would take 3 more.
        XCTAssertEqual(rowAt([page], 0, 0), "  AB CD EF GH IJ")
        XCTAssertEqual(rowAt([page], 0, 1), "KL MN")
    }

    /// Whatever the widths, no word is ever divided: every row's words are
    /// whole words of the text, in order, and no row is longer than a line.
    func testNoWordIsEverDividedAtAnyWidth() throws {
        let words = ["A", "BC", "DEF", "GHIJ", "KLMNO", "PQRSTU", "VWXYZ12", "34567890", "ABCDEFGHI"]
        // A text of 120 words, cycling through the lengths.
        let text = (0..<120).map { words[$0 % words.count] }
        for width in [18, 19, 23, 40, 64, 80] {
            let result = pages([paragraph(text.joined(separator: " "))], cells: width, lines: 50)
            let rows = result.flatMap { $0.dropLast() }
            var found: [String] = []
            for row in rows {
                XCTAssertLessThanOrEqual(row.count, width, "width \(width): \(row)")
                found += row.split(separator: " ").map(String.init)
            }
            XCTAssertEqual(found, text, "width \(width)")
        }
    }

    /// A word longer than a whole line is cut at the line's end and goes on at
    /// the next line's indent; one exactly a line long fits whole.
    func testAWordLongerThanALineIsCutAtTheLineEnd() throws {
        // 20 cells at an 18-cell line: 16 after the first-line indent, then 4.
        var result = pages([paragraph("ABCDEFGHIJKLMNOPQRST")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  ABCDEFGHIJKLMNOP")
        XCTAssertEqual(rowAt(result, 0, 1), "QRST")

        // A word that follows another one begins a new line, fills it to its
        // last cell (from the runover indent, cell 1), and goes on.
        result = pages([paragraph("AB ABCDEFGHIJKLMNOPQRST")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  AB")
        XCTAssertEqual(rowAt(result, 0, 1), "ABCDEFGHIJKLMNOPQR")
        XCTAssertEqual(rowAt(result, 0, 2), "ST")

        // Later words follow the cut word's last piece on its line.
        result = pages([paragraph("ABCDEFGHIJKLMNOPQRST UV")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 1), "QRST UV")

        // A word of 40 cells at 18 needs three lines: 16, 18, and 6.
        result = pages([paragraph(String(repeating: "A", count: 40))], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  " + String(repeating: "A", count: 16))
        XCTAssertEqual(rowAt(result, 0, 1), String(repeating: "A", count: 18))
        XCTAssertEqual(rowAt(result, 0, 2), String(repeating: "A", count: 6))
    }

    /// A word exactly as long as the line from its indent fits, uncut.
    func testAWordExactlyALineLongFits() throws {
        let sixteen = String(repeating: "B", count: 16)
        let eighteen = String(repeating: "C", count: 18)
        // 16 cells after the 2-cell first indent fill an 18-cell line, and an
        // 18-cell word after it fills the next line whole.
        let result = pages([paragraph("\(sixteen) \(eighteen)")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  " + sixteen)
        XCTAssertEqual(rowAt(result, 0, 1), eighteen)
        XCTAssertEqual(rowAt(result, 0, 2), "")
    }

    /// A cut never parts a number sign from the cells after it (second review
    /// round, E7): a word of ten letter cells joined to a number sign and
    /// twelve digit cells (23 cells) at 18 is cut just before its sign, as the
    /// line's last cell would have been a digit of the number.
    func testAWordIsCutBeforeANumberNotInsideIt() throws {
        let word = "PQRSTUVWXY#ABCDEABCDEAB"
        let result = pages([paragraph(word)], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  PQRSTUVWXY")
        XCTAssertEqual(rowAt(result, 0, 1), "#ABCDEABCDEAB")

        // A word whose line would end on the sign itself moves it too.
        let signLast = pages([paragraph("PQRSTUVWXYZPQRS#ABCDEABCDEABCD")], cells: 18)
        XCTAssertEqual(rowAt(signLast, 0, 0), "  PQRSTUVWXYZPQRS")
        XCTAssertEqual(rowAt(signLast, 0, 1), "#ABCDEABCDEABCD")
    }

    /// A number sign and 30 digit cells alone have nothing before the sign, so
    /// moving the cut would leave the line empty: the cut stays at the line's
    /// end (a number sign and 15 digits, then the other 15).
    func testANumberAloneIsCutAtTheLineEnd() throws {
        let result = pages([paragraph("#" + String(repeating: "A", count: 30))], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  #" + String(repeating: "A", count: 15))
        XCTAssertEqual(rowAt(result, 0, 1), String(repeating: "A", count: 15))
    }

    /// A long address is cut just after a slash, the last the line has room
    /// for, at 18 and at 20 cells. At 18 the second line would end between the
    /// slash's two cells, so it ends before the slash, and no row ends on the
    /// number sign. Every cell of the address is still there, in order.
    func testALongAddressIsCutAfterASlash() throws {
        // https://www.gutenberg.org/ebooks/1342 in braille ASCII, with ":" as
        // "3" and "." as "4"; a slash is the two cells "_/".
        let address = "HTTPS3_/_/WWW4GUTENBERG4ORG_/EBOOKS_/#ACDB"
        let narrow = pages([paragraph(address)], cells: 18)
        XCTAssertEqual(rowAt(narrow, 0, 0), "  HTTPS3_/_/")
        XCTAssertEqual(rowAt(narrow, 0, 1), "WWW4GUTENBERG4ORG")
        XCTAssertEqual(rowAt(narrow, 0, 2), "_/EBOOKS_/#ACDB")

        let wide = pages([paragraph(address)], cells: 20)
        XCTAssertEqual(rowAt(wide, 0, 0), "  HTTPS3_/_/")
        XCTAssertEqual(rowAt(wide, 0, 1), "WWW4GUTENBERG4ORG_/")
        XCTAssertEqual(rowAt(wide, 0, 2), "EBOOKS_/#ACDB")

        for result in [narrow, wide] {
            let rows = (result.first ?? []).prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(rows.joined(), address)
        }
    }

    /// A long word with a hyphen inside the line's room is cut after the last
    /// such hyphen; without a hyphen in reach it is cut at the line's end.
    func testALongWordIsCutAfterAHyphen() throws {
        // Two hyphens inside the first line's 16 cells: the cut is after the last.
        var result = pages([paragraph("ABCD-EF-GHIJKLMNOPQRSTUV")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  ABCD-EF-")
        XCTAssertEqual(rowAt(result, 0, 1), "GHIJKLMNOPQRSTUV")

        // A hyphen beyond the room does not count: the cut is at the line's end.
        result = pages([paragraph("ABCDEFGHIJKLMNOPQR-STUVWXYZ")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "  ABCDEFGHIJKLMNOP")
        XCTAssertEqual(rowAt(result, 0, 1), "QR-STUVWXYZ")
    }

    /// Doubled blank cells, and white space other than the blank cell, make
    /// no empty words or odd gaps.
    func testExtraBlanksBetweenWordsAreSingle() throws {
        let result = pages([.paragraph(text: brailleCells("AB   CD") + "\n" + brailleCells("EF "))])
        XCTAssertEqual(rowAt(result, 0, 0), "  AB CD EF")
    }

    // MARK: Margins

    /// A paragraph starts in cell 3, and its runover lines in cell 1.
    func testParagraphStartsInCellThreeAndRunsOverInCellOne() throws {
        let result = pages([paragraph("AAAAAA BBBBBB CCCCCC DDDDDD EEEEEE")], cells: 20)
        // The first line has 18 cells for text, which two words take (13) and
        // a third would overrun; the runover has all 20, which three fill.
        XCTAssertEqual(rowAt(result, 0, 0), "  AAAAAA BBBBBB")
        XCTAssertEqual(rowAt(result, 0, 1), "CCCCCC DDDDDD EEEEEE")
        XCTAssertEqual(rowAt(result, 0, 2), "")
    }

    /// A list item at depth 1 starts in cell 1 and runs over in cell 3.
    func testListItemAtDepthOneStartsInCellOneAndRunsOverInCellThree() throws {
        let result = pages([item(1, "AAAAAA BBBBBB CCCCCC DDDDDD EEEEEE")], cells: 20)
        XCTAssertEqual(rowAt(result, 0, 0), "AAAAAA BBBBBB CCCCCC")
        XCTAssertEqual(rowAt(result, 0, 1), "  DDDDDD EEEEEE")
    }

    /// At depth 2 the first line starts in cell 3 and the runovers in cell 5.
    func testListItemAtDepthTwoStartsInCellThreeAndRunsOverInCellFive() throws {
        let result = pages([item(2, "AAAAAA BBBBBB CCCCCC DDDDDD EEEEEE FFFFFF")], cells: 24)
        XCTAssertEqual(rowAt(result, 0, 0), "  AAAAAA BBBBBB CCCCCC")
        XCTAssertEqual(rowAt(result, 0, 1), "    DDDDDD EEEEEE FFFFFF")
    }

    /// The depth is held so that the runover indent is at most a third of the
    /// line: at 18 cells, 6 cells (depth 3) is the most, so depth 9 is 3.
    func testListDepthIsHeldToAThirdOfTheLine() throws {
        let result = pages([item(9, "AAAA BBBB CCCC DDDD EEEE FFFF")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), "    AAAA BBBB CCCC")
        XCTAssertEqual(rowAt(result, 0, 1), "      DDDD EEEE")
        XCTAssertEqual(rowAt(result, 0, 2), "      FFFF")
        // A depth below 1 is read as 1.
        let low = pages([item(0, "AAAA")], cells: 18)
        XCTAssertEqual(rowAt(low, 0, 0), "AAAA")
    }

    /// A level-3 heading starts in cell 5 and a level-5 heading in cell 7,
    /// each with a blank line before and none after.
    func testLowerHeadingsHaveTheirMarginsAndABlankOnlyBefore() throws {
        let result = pages([
            paragraph("AAA"), heading(3, "BBB"), paragraph("CCC"), heading(5, "DDD"), paragraph("EEE"),
        ])
        XCTAssertEqual(result.count, 1)
        guard let page = result.first else { return }
        XCTAssertEqual(Array(page.prefix(7)), [
            "  AAA", "", "    BBB", "  CCC", "", "      DDD", "  EEE",
        ])
    }

    /// A heading of level 4 or 6 starts in cell 7 as level 5 does, and its
    /// runover lines start at the same cell.
    func testHeadingRunoversStayAtTheHeadingsCell() throws {
        let result = pages([heading(3, "AAAAAA BBBBBB CCCCCC DDDDDD")], cells: 24)
        XCTAssertEqual(rowAt(result, 0, 0), "    AAAAAA BBBBBB CCCCCC")
        XCTAssertEqual(rowAt(result, 0, 1), "    DDDDDD")
        let deeper = pages([heading(6, "AAAAAA BBBBBB CCCCCC")], cells: 24)
        XCTAssertEqual(rowAt(deeper, 0, 0), "      AAAAAA BBBBBB")
        XCTAssertEqual(rowAt(deeper, 0, 1), "      CCCCCC")
    }

    // MARK: Centered headings

    /// Centering: (cells - length) / 2 blanks before, rounded down, so an odd
    /// difference leaves the extra cell on the right; a blank line follows.
    func testCenteredHeadingsOfEvenAndOddLength() throws {
        // 40 - 4 = 36, 18 blanks; 40 - 5 = 35, 17 blanks.
        var result = pages([heading(1, "ABCD"), paragraph("X")])
        XCTAssertEqual(rowAt(result, 0, 0), blanks(18) + "ABCD")
        XCTAssertEqual(rowAt(result, 0, 1), "")
        XCTAssertEqual(rowAt(result, 0, 2), "  X")
        result = pages([heading(2, "ABCDE"), paragraph("X")])
        XCTAssertEqual(rowAt(result, 0, 0), blanks(17) + "ABCDE")
        XCTAssertEqual(rowAt(result, 0, 1), "")
    }

    /// A heading too long for one centered line (at most width - 6 cells) is
    /// wrapped, and each line is centered with 3 or more blanks on each side.
    func testALongCenteredHeadingIsWrappedAndEachLineCentered() throws {
        let result = pages([heading(1, "ABCDE FGHIJ KLMNO"), paragraph("X")], cells: 18)
        // "KLMNO" would stand in cell 7 (a margin of 6), which reads back as a
        // cell-7 heading, so the heading is wrapped again, narrower, and its
        // lines (a margin of 6 moved to 7 by a cell) are all clear of cells 5 and 7.
        XCTAssertEqual(rowAt(result, 0, 0), blanks(7) + "ABCDE")
        XCTAssertEqual(rowAt(result, 0, 1), blanks(7) + "FGHIJ")
        XCTAssertEqual(rowAt(result, 0, 2), blanks(7) + "KLMNO")
        XCTAssertEqual(rowAt(result, 0, 3), "")
        XCTAssertEqual(rowAt(result, 0, 4), "  X")
        // A line as long as the most allowed has exactly 3 blanks each side,
        // so a word of 12 cells fills a centered line.
        let full = pages([heading(1, String(repeating: "A", count: 12))], cells: 18)
        XCTAssertEqual(rowAt(full, 0, 0), blanks(3) + String(repeating: "A", count: 12))
        // A word of 13 is cut at 12.
        let cut = pages([heading(1, String(repeating: "A", count: 13))], cells: 18)
        XCTAssertEqual(rowAt(cut, 0, 0), blanks(3) + String(repeating: "A", count: 12))
        XCTAssertEqual(rowAt(cut, 0, 1), blanks(8) + "A")
    }

    /// The blocks the analyzer reads from `blocks` laid out at `cells` by 25 lines.
    private func readBack(_ blocks: [BrailleBlock], cells: Int = 40) -> [BrailleBlock] {
        let format = BraillePageFormat(cellsPerLine: cells, linesPerPage: 25, numbersPages: true)
        return BraillePageAnalyzer.structure(of: BrailleLayout.pages(of: blocks, format: format), formatted: true).blocks
    }

    /// A centered line of 31, 32, 27, or 28 cells at 40 would stand with a
    /// margin of 4 or 6 cells, which the reader takes for a heading of cell 5
    /// or 7; the heading is wrapped again at 26 cells (a margin of 7 or
    /// more) and reads back as the level-1 heading it is.
    func testCenteredHeadingLinesWithMarginFourOrSixAreWrappedAt26() throws {
        // Two words that make a first line of 31, 32, 27, or 28 cells.
        for (first, second) in [(15, 15), (15, 16), (13, 13), (13, 14)] {
            let a = String(repeating: "A", count: first), b = String(repeating: "B", count: second)
            let result = pages([heading(1, a + " " + b), paragraph("X")])
            XCTAssertEqual(rowAt(result, 0, 0), blanks((40 - first) / 2) + a, "\(first + 1 + second) cells")
            XCTAssertEqual(rowAt(result, 0, 1), blanks((40 - second) / 2) + b, "\(first + 1 + second) cells")
            XCTAssertEqual(rowAt(result, 0, 2), "")
            XCTAssertEqual(readBack([heading(1, a + " " + b), paragraph("X")]).first,
                           .heading(level: 1, text: brailleCells(a + " " + b)), "\(first + 1 + second) cells")
        }
    }

    /// Lines of 30, 29, 33, 34, and 26 cells have margins 5, 5, 3, 3, and 7:
    /// no heading is wrapped again for them.
    func testCenteredHeadingLinesWithOtherMarginsKeepTheirWrapping() throws {
        for (first, second, margin) in [(15, 14, 5), (14, 14, 5), (16, 16, 3), (17, 16, 3), (13, 12, 7)] {
            let a = String(repeating: "A", count: first), b = String(repeating: "B", count: second)
            let result = pages([heading(2, a + " " + b), paragraph("X")])
            // One line, centered at BANA's margin.
            XCTAssertEqual(rowAt(result, 0, 0), blanks(margin) + a + " " + b, "\(first + 1 + second) cells")
            XCTAssertEqual(rowAt(result, 0, 1), "")
            XCTAssertEqual(readBack([heading(2, a + " " + b), paragraph("X")]).first?.text,
                           brailleCells(a + " " + b), "\(first + 1 + second) cells")
        }
    }

    /// The narrow page's heading keeps its words whole, and a line whose
    /// margin would be 6 (an odd difference) stands a cell further right, so
    /// the reader still takes it for a centered heading.
    func testANarrowHeadingKeepsItsWordsAndMovesAnAmbiguousLine() throws {
        // At 18 cells a 5-cell line has a margin of 6 (13 / 2).
        let result = pages([heading(1, "ABCDE"), paragraph("X")], cells: 18)
        XCTAssertEqual(rowAt(result, 0, 0), blanks(7) + "ABCDE")
        XCTAssertEqual(readBack([heading(1, "ABCDE"), paragraph("X")], cells: 18).first,
                       .heading(level: 1, text: brailleCells("ABCDE")))
        // A word of 8 cells at 20 stands in cell 7 whatever is done (a margin
        // of 6, the difference being even): the text is still whole.
        let stuck = readBack([heading(1, "ABCDEFGH"), paragraph("X")], cells: 20)
        XCTAssertEqual(stuck.first, .heading(level: 3, text: brailleCells("ABCDEFGH")))
    }

    /// Laid out and read back, the BRL sample's blocks are the sample's: two
    /// level-1 headings and twelve paragraphs.
    func testTheSampleBlocksReadBackFromTheirLayout() throws {
        let brl = try copyOfFormatSample("brl/pride-and-prejudice-ch1-grade1.brl")
        let text = try XCTUnwrap(String(data: Data(contentsOf: brl), encoding: .ascii))
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.count, 14)
        guard lines.count == 14 else { return }
        var blocks: [BrailleBlock] = [heading(1, lines[0]), heading(2, lines[1])]
        blocks += lines[2...].map { paragraph($0) }
        let expected = blocks.map { block -> BrailleBlock in
            if case let .heading(_, text) = block { return .heading(level: 1, text: text) }
            return block
        }
        XCTAssertEqual(readBack(blocks), expected)
    }

    // MARK: Blank lines

    /// A heading that opens a page has no blank line before it, and a
    /// heading right after a heading never makes two blank lines.
    func testNoBlankLineAtThePageTopAndNeverTwoInARow() throws {
        let result = pages([
            heading(3, "ONE"), heading(1, "TWO"), heading(2, "THREE"), paragraph("A"), heading(3, "FOUR"),
            heading(3, "FIVE"),
        ])
        XCTAssertEqual(result.count, 1)
        guard let page = result.first else { return }
        XCTAssertEqual(page.first, "    ONE")
        // A level-1 heading after a level-3 one gets one blank before it.
        XCTAssertEqual(Array(page.prefix(8)), [
            "    ONE", "", blanks(18) + "TWO", "", blanks(17) + "THREE", "", "  A", "",
        ])
        XCTAssertEqual(Array(page.dropFirst(8).prefix(3)), ["    FOUR", "", "    FIVE"])
        // No two blank rows in a row between the first row and the last row
        // of text (blank rows after the text only pad the page, and the last
        // row is the page number).
        let body = page.dropLast()
        guard let lastText = body.lastIndex(where: { !$0.isEmpty }) else { return }
        let text = body[...lastText]
        XCTAssertFalse(zip(text, text.dropFirst()).contains { $0.isEmpty && $1.isEmpty }, "never two blanks in a row")
    }

    /// A blank line that would fall at the top of a page is dropped, and
    /// paragraphs have no blank line between them.
    func testNoBlankLineBetweenParagraphsOrAtTheTopOfANewPage() throws {
        // At 18 by 5 (4 text lines): two 3-row paragraphs follow on at once.
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        let result = pages([threeRows, threeRows], cells: 18, lines: 5)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(Array(result[0].prefix(4)), ["  " + sixteen, sixteen, sixteen, "  " + sixteen])
        // The second paragraph's rows follow without a blank line, and the
        // second page starts with text, not a blank.
        XCTAssertEqual(result[1].first, sixteen)

        // A heading that falls first on a page (it is the book's last block,
        // so it is not moved) has the blank line before it dropped.
        let moved = pages([threeRows, paragraph("X"), self.heading(3, "BB")], cells: 18, lines: 5)
        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(moved.last?.first, "    BB")
    }

    /// A list has a blank line before its first item and after its last, and
    /// none between its items, whatever their depth (BANA 8.3.2a). A list is
    /// a run of items with nothing else between them, so a paragraph between
    /// two runs makes two lists.
    func testAListHasABlankLineBeforeAndAfterIt() throws {
        let result = pages([
            paragraph("AAA"), item(1, "BBB"), item(2, "CCC"), item(1, "DDD"), paragraph("EEE"), item(1, "FFF"),
            paragraph("GGG"),
        ])
        XCTAssertEqual(result.count, 1)
        guard let page = result.first else { return }
        XCTAssertEqual(Array(page.prefix(11)), [
            "  AAA", "", "BBB", "  CCC", "DDD", "", "  EEE", "", "FFF", "", "  GGG",
        ])
    }

    /// A list right after a heading in cell 5 or cell 7 has no blank line
    /// before it (BANA 8.3.3a), and one right after a centered heading has
    /// only the heading's own; the blank line after each list stays.
    func testAListAfterAHeadingHasNoBlankLineOfItsOwnBeforeIt() throws {
        let result = pages([
            heading(3, "ONE"), item(1, "AAA"), paragraph("BBB"), heading(5, "TWO"), item(1, "CCC"), item(2, "DDD"),
            heading(1, "THREE"), item(1, "EEE"), paragraph("FFF"),
        ])
        XCTAssertEqual(result.count, 1)
        guard let page = result.first else { return }
        XCTAssertEqual(Array(page.prefix(15)), [
            "    ONE", "AAA", "", "  BBB", "", "      TWO", "CCC", "  DDD", "", blanks(17) + "THREE", "", "EEE", "",
            "  FFF", "",
        ])
    }

    /// A list that begins a page has no blank line above it, and one that
    /// ends a page leaves no blank line at the top of the next.
    func testAListAtAPagesTopOrFootHasNoBlankLineThere() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        // At 18 by 5 (4 text lines) the paragraph's three rows and the
        // list's blank line fill page 1, and the list begins page 2.
        let begins = pages([threeRows, item(1, "BBB"), item(1, "CCC"), paragraph("DDD")], cells: 18, lines: 5)
        XCTAssertEqual(begins.count, 2)
        guard begins.count == 2 else { return }
        XCTAssertEqual(Array(begins[0].prefix(4)), ["  " + sixteen, sixteen, sixteen, ""])
        XCTAssertEqual(Array(begins[1].prefix(4)), ["BBB", "CCC", "", "  DDD"])

        // Four items fill page 1, and the paragraph after them begins page 2.
        let ends = pages([item(1, "AAA"), item(1, "BBB"), item(1, "CCC"), item(1, "DDD"), paragraph("EEE")],
                         cells: 18, lines: 5)
        XCTAssertEqual(ends.count, 2)
        guard ends.count == 2 else { return }
        XCTAssertEqual(Array(ends[0].prefix(4)), ["AAA", "BBB", "CCC", "DDD"])
        XCTAssertEqual(ends[1].first, "  EEE")
    }

    // MARK: Headings and the page's end

    /// A heading that would be the last text on a page moves to the next
    /// page, leaving its page's remaining text lines blank (BANA 4.3.9).
    func testAHeadingNeverEndsAPage() throws {
        let sixteen = String(repeating: "A", count: 16)
        // Three rows of text; 5 text lines leave 2, and the heading needs a
        // blank line, itself, and a line of the next block.
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        let result = pages([threeRows, heading(3, "BB"), paragraph("CC")], cells: 18, lines: 6)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(result[0].count, 6)
        XCTAssertEqual(result[0].prefix(5).map { $0 }, ["  " + sixteen, sixteen, sixteen, "", ""])
        XCTAssertEqual(rowAt(result, 0, 5), blanks(16) + "#A")
        XCTAssertEqual(Array(result[1].prefix(2)), ["    BB", "  CC"])
        XCTAssertEqual(rowAt(result, 1, 5), blanks(16) + "#B")

        // With one line more the heading, its blank line, and a line fit.
        let fits = pages([threeRows, heading(3, "BB"), paragraph("CC")], cells: 18, lines: 7)
        XCTAssertEqual(fits.count, 1)
        XCTAssertEqual(Array(fits.first?.prefix(6) ?? []), ["  " + sixteen, sixteen, sixteen, "", "    BB", "  CC"])
    }

    /// A heading counts the headings directly after it: none of a run of
    /// headings may be the page's last text.
    func testARunOfHeadingsMovesTogether() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        // 6 text lines (7 lines), 3 used: a level-3 heading (blank, heading)
        // and a second one (blank, heading) take 4, with a line after, 5.
        let result = pages([threeRows, heading(3, "BB"), heading(3, "CC"), paragraph("DD")], cells: 18, lines: 7)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(Array(result[0].prefix(4)), ["  " + sixteen, sixteen, sixteen, ""])
        XCTAssertEqual(Array(result[1].prefix(4)), ["    BB", "", "    CC", "  DD"])
    }

    /// A heading keeps with it the first two lines of a list item that runs
    /// over, as it keeps one line of a paragraph: where the heading and one
    /// line would fit at the page's foot but not two, the heading begins the
    /// next page, and is never the page's last text.
    func testAHeadingKeepsTheFirstTwoLinesOfAListItemAfterIt() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        // At 18 by 7 (6 text lines) three rows leave three: room for a blank
        // line, the heading, and one line (testAHeadingNeverEndsAPage).
        let result = pages([threeRows, heading(3, "BB"), item(1, "DDDDDD EEEEEE FFFFFF")], cells: 18, lines: 7)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(Array(result[0].prefix(6)), ["  " + sixteen, sixteen, sixteen, "", "", ""])
        XCTAssertEqual(Array(result[1].prefix(3)), ["    BB", "DDDDDD EEEEEE", "  FFFFFF"])
    }

    // MARK: List items and the page's end

    /// A list item that runs over begins on a page with room for its first
    /// two lines, at either depth: alone at a page's foot, its first line
    /// would leave its runover at the next page's top, where a reader cannot
    /// tell it from a new block, or, in cell 5, from a heading. An item of
    /// one line may still end a page.
    func testAListItemThatRunsOverNeverLeavesItsFirstLineAloneAtAPagesFoot() throws {
        for depth in [1, 2] {
            let indent = blanks(2 * depth - 2)
            // At 18 by 5 (4 text lines) three items of one line leave one.
            let result = pages([item(1, "AAA"), item(1, "BBB"), item(1, "CCC"), item(depth, "DDDDDD EEEEEE FFFFFF")],
                               cells: 18, lines: 5)
            XCTAssertEqual(result.count, 2, "depth \(depth)")
            guard result.count == 2 else { continue }
            XCTAssertEqual(Array(result[0].prefix(4)), ["AAA", "BBB", "CCC", ""], "depth \(depth)")
            XCTAssertEqual(Array(result[1].prefix(2)), [indent + "DDDDDD EEEEEE", indent + "  FFFFFF"], "depth \(depth)")
        }
        let fits = pages([item(1, "AAA"), item(1, "BBB"), item(1, "CCC"), item(2, "DDD")], cells: 18, lines: 5)
        XCTAssertEqual(fits.count, 1)
        XCTAssertEqual(Array(fits.first?.prefix(4) ?? []), ["AAA", "BBB", "CCC", "  DDD"])
    }

    /// A heading that is the book's last block is never moved for this.
    func testALastHeadingStaysWhereItFalls() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        let result = pages([threeRows, heading(1, "BB")], cells: 18, lines: 6)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Array(result.first?.prefix(5) ?? []), ["  " + sixteen, sixteen, sixteen, "", blanks(8) + "BB"])
    }

    // MARK: Page numbers

    /// The braille page number is the number sign and the digit cells, at the
    /// right margin of the last line: ⠼⠁ on page 1 and ⠼⠁⠃ on page 12.
    func testPageNumbersAreRightAlignedOnTheLastLine() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        let result = BrailleLayout.pages(of: Array(repeating: threeRows, count: 12), format: BraillePageFormat(
            cellsPerLine: 18, linesPerPage: 4, numbersPages: true
        ))
        XCTAssertEqual(result.count, 12)
        guard result.count == 12 else { return }
        XCTAssertEqual(rowAt(result, 0, 3), String(repeating: "\u{2800}", count: 16) + "\u{283C}\u{2801}")
        XCTAssertEqual(rowAt(result, 11, 3), String(repeating: "\u{2800}", count: 15) + "\u{283C}\u{2801}\u{2803}")
        // Every page has its four rows and its number on the fourth.
        for (index, page) in result.enumerated() {
            XCTAssertEqual(page.count, 4)
            XCTAssertEqual(page.last?.unicodeScalars.count, 18, "page \(index + 1) number line reaches the margin")
        }
    }

    /// The digit cells: 1 to 9 are the cells a to i and 0 is j.
    func testPageNumberDigits() {
        XCTAssertEqual(BrailleLayout.pageNumberCells(1), "\u{283C}\u{2801}")
        XCTAssertEqual(BrailleLayout.pageNumberCells(12), "\u{283C}\u{2801}\u{2803}")
        XCTAssertEqual(brailleASCII(BrailleLayout.pageNumberCells(1234567890)), "#ABCDEFGHIJ")
    }

    /// With page numbers off every line holds text and no number appears.
    func testWithoutPageNumbersTheLastLineHoldsText() throws {
        let sixteen = String(repeating: "A", count: 16)
        let threeRows = paragraph([sixteen, sixteen, sixteen].joined(separator: " "))
        let result = pages([threeRows, threeRows], cells: 18, lines: 4, numbers: false)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(result[0], ["  " + sixteen, sixteen, sixteen, "  " + sixteen])
        XCTAssertEqual(result[1], [sixteen, sixteen, "", ""])
        XCTAssertFalse(result.joined().contains { $0.contains("#") })
    }

    // MARK: Formats

    /// The smallest page, 18 cells by 4 lines, works: 3 text lines and a
    /// number line.
    func testTheSmallestFormatWorks() throws {
        let format = BraillePageFormat(cellsPerLine: 18, linesPerPage: 4, numbersPages: true)
        let result = BrailleLayout.pages(of: [paragraph("AB CD EF GH IJ KL MN OP QR ST")], format: format)
        XCTAssertFalse(result.isEmpty)
        for page in result {
            XCTAssertEqual(page.count, 4)
            XCTAssertTrue(page.allSatisfy { $0.unicodeScalars.count <= 18 })
        }
    }

    /// Cells per line are held to 18 to 80 and lines per page to 4 to 50.
    func testTheFormatIsHeldToItsRanges() throws {
        let low = BraillePageFormat(cellsPerLine: 10, linesPerPage: 2, numbersPages: false).clamped
        XCTAssertEqual(low, BraillePageFormat(cellsPerLine: 18, linesPerPage: 4, numbersPages: false))
        let high = BraillePageFormat(cellsPerLine: 100, linesPerPage: 99, numbersPages: true).clamped
        XCTAssertEqual(high, BraillePageFormat(cellsPerLine: 80, linesPerPage: 50, numbersPages: true))
        // The default is BANA's 40 by 25 with page numbers.
        XCTAssertEqual(BraillePageFormat(), BraillePageFormat(cellsPerLine: 40, linesPerPage: 25, numbersPages: true))
        XCTAssertEqual(BraillePageFormat().clamped, BraillePageFormat())

        // The layout uses the held format.
        let text = (0..<400).map { _ in "AAAA" }.joined(separator: " ")
        let tooSmall = BrailleLayout.pages(
            of: [paragraph(text)], format: BraillePageFormat(cellsPerLine: 10, linesPerPage: 2)
        )
        XCTAssertTrue(tooSmall.allSatisfy { $0.count == 4 })
        XCTAssertEqual(tooSmall.first?.last?.unicodeScalars.count, 18)
        let tooBig = BrailleLayout.pages(
            of: [paragraph(text)], format: BraillePageFormat(cellsPerLine: 100, linesPerPage: 99)
        )
        XCTAssertTrue(tooBig.allSatisfy { $0.count == 50 })
        XCTAssertEqual(tooBig.first?.last?.unicodeScalars.count, 80)
        XCTAssertTrue(tooBig.joined().allSatisfy { $0.unicodeScalars.count <= 80 })
    }

    // MARK: Nothing to lay out

    /// No blocks give no pages, and a block with no words is skipped.
    func testNoBlocksGiveNoPagesAndBlankBlocksAreSkipped() throws {
        XCTAssertEqual(BrailleLayout.pages(of: [], format: BraillePageFormat()), [])
        let blankCells = String(repeating: "\u{2800}", count: 5)
        XCTAssertEqual(BrailleLayout.pages(of: [
            .paragraph(text: ""), .heading(level: 1, text: blankCells), .listItem(depth: 1, text: " \n")
        ], format: BraillePageFormat()), [])

        // Skipped blocks leave no trace, not even the blank line of a heading.
        let with = pages([heading(1, "ONE"), .heading(level: 2, text: blankCells), paragraph(""), paragraph("TWO")])
        let without = pages([heading(1, "ONE"), paragraph("TWO")])
        XCTAssertEqual(with, without)
    }
}
