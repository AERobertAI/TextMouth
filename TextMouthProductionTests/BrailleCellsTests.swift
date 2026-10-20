import XCTest
@testable import TextMouth

/// Tests for `BrailleCells` (FMT20, FMT22), the conversion between North
/// American Braille ASCII and Unicode braille, and for `BrailleBlock`. The
/// table is checked by its own facts and against the real samples: each line
/// of the BRF sample, converted cell by cell, is the PEF sample's row.
final class BrailleCellsTests: XCTestCase {
    // MARK: - The Table

    /// The table is the 64 characters 0x20 to 0x5F, each once, in the order
    /// of the cells' dots: the space is the blank cell and "=" all six dots.
    func testTheTableIsTheSixtyFourCharactersOfBrailleASCII() {
        XCTAssertEqual(BrailleCells.asciiByDots.count, 64)
        XCTAssertEqual(Set(BrailleCells.asciiByDots), Set(0x20...0x5F))
        XCTAssertEqual(BrailleCells.asciiByDots.first, UInt8(ascii: " "))
        XCTAssertEqual(BrailleCells.asciiByDots.last, UInt8(ascii: "="))
    }

    /// Known cells, from the research's table: A is dot 1, the capital sign
    /// "," is dot 6, the number sign "#" is dots 3-4-5-6, and "=" is every dot.
    func testKnownCharactersGiveTheirCells() {
        let expected: [(Character, UInt32)] = [
            (" ", 0x2800), ("A", 0x2801), ("B", 0x2803), (",", 0x2820), ("#", 0x283C), ("=", 0x283F), ("4", 0x2832),
        ]
        for (character, value) in expected {
            XCTAssertEqual(BrailleCells.cell(forASCII: character.asciiValue ?? 0)?.value, value, "\(character)")
        }
    }

    /// Every character of the table gives its cell, and the cell gives the
    /// character back.
    func testEveryCharacterRoundTrips() throws {
        for byte in UInt8(0x20)...UInt8(0x5F) {
            let cell = try XCTUnwrap(BrailleCells.cell(forASCII: byte), "byte \(byte)")
            XCTAssertTrue(BrailleCells.isPattern(cell))
            XCTAssertFalse(BrailleCells.usesEightDots(cell))
            XCTAssertEqual(BrailleCells.ascii(for: cell), byte, "byte \(byte)")
        }
    }

    /// Lowercase reads as uppercase: each of 0x60 to 0x7E is the cell of the
    /// character 0x20 below it, so "a" is "A" and "{" is "[".
    func testLowercaseCharactersAreReadAsTheirCapitals() {
        for byte in UInt8(0x60)...UInt8(0x7E) {
            XCTAssertEqual(BrailleCells.cell(forASCII: byte), BrailleCells.cell(forASCII: byte - 0x20), "byte \(byte)")
        }
        XCTAssertEqual(BrailleCells.cell(forASCII: UInt8(ascii: "a"))?.value, 0x2801)
    }

    /// Control characters, DEL, and bytes past ASCII are no cell at all.
    func testOtherBytesAreNoCell() {
        for byte in Array(UInt8(0x00)...UInt8(0x1F)) + [0x7F] + Array(UInt8(0x80)...UInt8(0xFF)) {
            XCTAssertNil(BrailleCells.cell(forASCII: byte), "byte \(byte)")
        }
    }

    /// Only six-dot patterns have a braille ASCII character: an eight-dot
    /// cell and a letter have none.
    func testOnlySixDotCellsHaveACharacter() throws {
        let dotSeven = try XCTUnwrap(Unicode.Scalar(0x2840))
        XCTAssertNil(BrailleCells.ascii(for: dotSeven))
        XCTAssertTrue(BrailleCells.usesEightDots(dotSeven))
        XCTAssertTrue(BrailleCells.usesEightDots(try XCTUnwrap(Unicode.Scalar(0x28FF))))
        XCTAssertNil(BrailleCells.ascii(for: "A"))
        XCTAssertFalse(BrailleCells.isPattern("A"))
        XCTAssertFalse(BrailleCells.isPattern(try XCTUnwrap(Unicode.Scalar(0x2900))))
    }

    /// `spaced` shows blank cells as spaces and leaves every other cell.
    func testSpacedShowsBlankCellsAsSpaces() {
        XCTAssertEqual(BrailleCells.spaced("⠠⠮\u{2800}⠃⠕⠽"), "⠠⠮ ⠃⠕⠽")
    }

    // MARK: - The Samples

    /// The BRF sample, converted line by line, is the PEF sample row by
    /// row, blank rows and trailing blank cells aside: the two were written
    /// from the same pages, and the PEF holds Unicode braille.
    func testTheBRFSampleConvertsToThePEFSampleRows() throws {
        let brf = try Data(contentsOf: copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf"))
        let lines = String(decoding: brf, as: UTF8.self)
            .replacingOccurrences(of: "\u{0C}", with: "")
            .components(separatedBy: "\r\n")
            .dropLast()
        let converted = try lines.map { line in
            String(String.UnicodeScalarView(try line.utf8.map { try XCTUnwrap(BrailleCells.cell(forASCII: $0)) }))
        }
        let pef = try String(contentsOf: copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"), encoding: .utf8)
        let rows = pef.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("<row") }
            .map { $0 == "<row/>" ? "" : String($0.dropFirst("<row>".count).dropLast("</row>".count)) }
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(converted, rows)
    }

    // MARK: - Blocks

    /// A block's text is its own, and a new text keeps its kind and level.
    func testABlockKeepsItsKindWhenItsTextChanges() {
        XCTAssertEqual(BrailleBlock.heading(level: 2, text: "⠁").withText("a"), .heading(level: 2, text: "a"))
        XCTAssertEqual(BrailleBlock.paragraph(text: "⠃").withText("b"), .paragraph(text: "b"))
        XCTAssertEqual(BrailleBlock.listItem(depth: 3, text: "⠉").withText("c"), .listItem(depth: 3, text: "c"))
        XCTAssertEqual(BrailleBlock.listItem(depth: 1, text: "⠙").text, "⠙")
    }
}
