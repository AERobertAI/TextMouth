import XCTest
@testable import TextMouth

/// Tests for `BrailleFileCode` and `SevenBitBrailleTable` (braillecodes): the
/// catalog of the ways a BRF or BRL file writes braille cells as characters.
/// Each seven-bit table is checked by its own facts and against liblouis's
/// display table for it, vendored unchanged from liblouis 3.39.0 and read
/// from the app's tables folder, so the test also proves the files ship.
final class BrailleFileCodeTests: XCTestCase {
    /// The two seven-bit tables, by name for the failure messages.
    private let tables: [(name: String, table: SevenBitBrailleTable)] = [
        ("North American Braille ASCII", .northAmerican),
        ("Eurobraille", .eurobraille),
    ]

    // MARK: - The Tables

    /// Each table is 64 distinct printable ASCII characters, the blank
    /// cell's the space.
    func testEachTableIsSixtyFourDistinctPrintableCharacters() {
        for (name, table) in tables {
            XCTAssertEqual(table.bytes.count, 64, name)
            XCTAssertEqual(Set(table.bytes).count, 64, name)
            XCTAssertTrue(table.bytes.allSatisfy { (0x20...0x7E).contains($0) }, name)
            XCTAssertEqual(table.bytes.first, UInt8(ascii: " "), name)
            XCTAssertEqual(table.dots(forByte: UInt8(ascii: " ")), 0, name)
        }
    }

    /// Every cell gives its byte and the byte its cell, both ways round.
    func testEveryCellRoundTrips() throws {
        for (name, table) in tables {
            for dots in UInt8(0)..<64 {
                XCTAssertEqual(table.dots(forByte: table.byte(forDots: dots)), dots, "\(name), dots \(dots)")
            }
            for byte in table.bytes {
                let dots = try XCTUnwrap(table.dots(forByte: byte), "\(name), byte \(byte)")
                XCTAssertEqual(table.byte(forDots: dots), byte, "\(name), byte \(byte)")
                let cell = try XCTUnwrap(table.cell(forByte: byte), "\(name), byte \(byte)")
                XCTAssertEqual(cell.value, 0x2800 + UInt32(dots))
                XCTAssertEqual(table.byte(forCell: cell), byte, "\(name), byte \(byte)")
            }
        }
    }

    /// North American Braille ASCII reads lowercase, 0x60 to 0x7E, as the
    /// character 0x20 below, so "a" is "A" and "{" is "[".
    func testNorthAmericanReadsLowercaseAsItsCapitals() {
        let table = SevenBitBrailleTable.northAmerican
        for byte in UInt8(0x60)...UInt8(0x7E) {
            XCTAssertNotNil(table.dots(forByte: byte), "byte \(byte)")
            XCTAssertEqual(table.dots(forByte: byte), table.dots(forByte: byte - 0x20), "byte \(byte)")
        }
        XCTAssertEqual(table.cell(forByte: UInt8(ascii: "a"))?.value, 0x2801)
    }

    /// Eurobraille reads its capitals form too: A to Z as a to z, @ [ \ ] ^
    /// as ` { | } ~, and DEL as _ (dots 4-5-6).
    func testEurobrailleReadsItsCapitalsFormAndDEL() {
        let table = SevenBitBrailleTable.eurobraille
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            XCTAssertEqual(table.dots(forByte: byte), table.dots(forByte: byte + 0x20), "byte \(byte)")
        }
        for (capital, lower) in zip("@[\\]^".utf8, "`{|}~".utf8) {
            XCTAssertNotNil(table.dots(forByte: lower), "byte \(lower)")
            XCTAssertEqual(table.dots(forByte: capital), table.dots(forByte: lower), "byte \(capital)")
        }
        XCTAssertEqual(table.dots(forByte: 0x7F), 0b111000, "DEL is dots 4-5-6")
        XCTAssertEqual(table.dots(forByte: UInt8(ascii: "_")), 0b111000)
        // The writer writes the lowercase form, and _ for dots 4-5-6.
        XCTAssertEqual(table.byte(forDots: 0b111000), UInt8(ascii: "_"))
        XCTAssertEqual(table.byte(forDots: 1), UInt8(ascii: "a"))
    }

    /// Control characters and bytes past ASCII are no cell in either table,
    /// and DEL is none in North American Braille ASCII.
    func testOtherBytesAreNoCell() throws {
        for (name, table) in tables {
            for byte in Array(UInt8(0x00)...UInt8(0x1F)) + Array(UInt8(0x80)...UInt8(0xFF)) {
                XCTAssertNil(table.dots(forByte: byte), "\(name), byte \(byte)")
                XCTAssertNil(table.cell(forByte: byte), "\(name), byte \(byte)")
            }
            XCTAssertNil(table.byte(forCell: try XCTUnwrap(Unicode.Scalar(0x2840))), name)
            XCTAssertNil(table.byte(forCell: try XCTUnwrap(Unicode.Scalar(0x28FF))), name)
            XCTAssertNil(table.byte(forCell: "A"), name)
        }
        XCTAssertNil(SevenBitBrailleTable.northAmerican.dots(forByte: 0x7F))
    }

    /// The two tables agree on 31 cells, letters compared without case (the
    /// blank, the 26 letters, #, &, -, and _), and differ on the other 33:
    /// a file in one read as the other gives plausible text with no error.
    func testTheTwoTablesAgreeOnThirtyOneCells() {
        let folded = { (byte: UInt8) -> UInt8 in (0x61...0x7A).contains(byte) ? byte - 0x20 : byte }
        let agreeing = (UInt8(0)..<64).filter { dots in
            folded(SevenBitBrailleTable.northAmerican.byte(forDots: dots))
                == folded(SevenBitBrailleTable.eurobraille.byte(forDots: dots))
        }
        XCTAssertEqual(agreeing.count, 31)
    }

    // MARK: - liblouis's Own Tables

    /// North American Braille ASCII is liblouis's `en-us-brf.dis`, 64 cells
    /// of 64.
    func testNorthAmericanIsLiblouisEnUsBRF() throws {
        let cells = try displayCells(of: "en-us-brf.dis")
        for (character, dots) in cells {
            XCTAssertEqual(SevenBitBrailleTable.northAmerican.byte(forDots: dots), character, "dots \(dots)")
        }
    }

    /// Eurobraille is liblouis's `de-eurobrl6.dis`, 64 cells of 64.
    func testEurobrailleIsLiblouisDeEurobrl6() throws {
        let cells = try displayCells(of: "de-eurobrl6.dis")
        for (character, dots) in cells {
            XCTAssertEqual(SevenBitBrailleTable.eurobraille.byte(forDots: dots), character, "dots \(dots)")
        }
    }

    /// Every character of liblouis's capitals form, `de-eurobrl6u.dis`,
    /// reads as its cell through Eurobraille's aliases, 64 cells of 64.
    func testEurobrailleReadsLiblouisDeEurobrl6u() throws {
        let cells = try displayCells(of: "de-eurobrl6u.dis")
        for (character, dots) in cells {
            XCTAssertEqual(SevenBitBrailleTable.eurobraille.dots(forByte: character), dots, "character \(character)")
        }
    }

    /// The six-dot cells of the liblouis display table `name` in the app's
    /// tables folder, as (character, dot value) pairs: exactly 64, one for
    /// each cell. A `display` line's second field is the character (`\s` the
    /// space, `\\` the backslash, `\xHHHH` a character by its code) and its
    /// third the dots (`0` the blank cell, else digits 1 to 6). A line whose
    /// dots hold anything else is no six-dot cell and is left out, as
    /// `de-eurobrl6.dis`'s `display \s a`, the German tables' virtual-dot
    /// cell for the non-breaking space.
    private func displayCells(of name: String) throws -> [(character: UInt8, dots: UInt8)] {
        let folder = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder)
        let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        var cells: [(character: UInt8, dots: UInt8)] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, fields[0] == "display", let dots = Self.sixDots(fields[2]) else { continue }
            cells.append((try Self.character(fields[1], in: name), dots))
        }
        XCTAssertEqual(cells.count, 64, name)
        XCTAssertEqual(Set(cells.map(\.dots)).count, 64, "\(name) lists each cell once")
        return cells
    }

    /// The dot value of a display line's dots field: 0 for "0", the sum of
    /// 2^(n-1) for digits n from 1 to 6, and nil for anything else.
    private static func sixDots(_ field: String) -> UInt8? {
        if field == "0" { return 0 }
        guard !field.isEmpty, field.allSatisfy({ ("1"..."6").contains($0) }) else { return nil }
        return field.utf8.reduce(UInt8(0)) { $0 | (1 << ($1 - UInt8(ascii: "1"))) }
    }

    /// The ASCII byte a display line's character field names.
    private static func character(_ field: String, in name: String) throws -> UInt8 {
        switch field {
        case "\\s": return UInt8(ascii: " ")
        case "\\\\": return UInt8(ascii: "\\")
        default:
            if field.hasPrefix("\\x") {
                let code = try XCTUnwrap(UInt32(field.dropFirst(2), radix: 16), "\(name): \(field)")
                return try XCTUnwrap(UInt8(exactly: code), "\(name): \(field) is past ASCII")
            }
            XCTAssertEqual(field.utf8.count, 1, "\(name): \(field)")
            return try XCTUnwrap(field.utf8.first, "\(name): an empty character field")
        }
    }

    // MARK: - The Catalog

    /// The catalog holds the three codes, in the pop-ups' order, with their
    /// permanent ids, names, and refusal words.
    func testTheCatalogHoldsTheThreeCodes() {
        XCTAssertEqual(BrailleFileCode.all.map(\.id), ["ascii-na", "ascii-eurobraille", "unicode"])
        XCTAssertEqual(
            BrailleFileCode.all.map(\.name),
            ["North American Braille ASCII", "Eurobraille, six-dot (German-speaking countries)", "Unicode braille patterns"]
        )
        XCTAssertEqual(
            BrailleFileCode.all.map(\.characterName),
            ["braille ASCII", "Eurobraille", "a Unicode braille pattern"]
        )
        XCTAssertEqual(BrailleFileCode.northAmerican.kind, .sevenBit(.northAmerican))
        XCTAssertEqual(BrailleFileCode.eurobraille.kind, .sevenBit(.eurobraille))
        XCTAssertEqual(BrailleFileCode.unicode.kind, .unicodePatterns)
        XCTAssertEqual(BrailleFileCode.northAmerican.sevenBitTable, .northAmerican)
        XCTAssertNil(BrailleFileCode.unicode.sevenBitTable)
        XCTAssertEqual(BrailleFileCode.defaultCode, .northAmerican)
    }

    /// A code is found by its exact id; a book's stored value of none reads
    /// as North American Braille ASCII, and an unknown id as no code, which
    /// is never read as another.
    func testCodesAreFoundByIDAndAStoredNoneIsTheDefault() {
        for code in BrailleFileCode.all {
            XCTAssertEqual(BrailleFileCode.code(withID: code.id), code)
            XCTAssertEqual(BrailleFileCode.code(forStored: code.id), code)
        }
        XCTAssertNil(BrailleFileCode.code(withID: "ASCII-NA"))
        XCTAssertNil(BrailleFileCode.code(withID: "ascii-braillo-no-047-01"))
        XCTAssertEqual(BrailleFileCode.code(forStored: nil), .northAmerican)
        XCTAssertEqual(BrailleFileCode.code(forStored: ""), .northAmerican)
        XCTAssertNil(BrailleFileCode.code(forStored: "ascii-braillo-no-047-01"))
    }

    /// An import may be set to the two seven-bit codes only: Unicode braille
    /// patterns are recognized by a file's bytes, never chosen (review of
    /// October 30, finding 4), and neither is an id the catalog lacks.
    func testTheImportsChoicesAreTheSevenBitCodes() {
        XCTAssertEqual(BrailleFileCode.importChoices.map(\.id), ["ascii-na", "ascii-eurobraille"])
        XCTAssertEqual(BrailleFileCode.importChoice(withID: "ascii-na"), .northAmerican)
        XCTAssertEqual(BrailleFileCode.importChoice(withID: "ascii-eurobraille"), .eurobraille)
        XCTAssertNil(BrailleFileCode.importChoice(withID: "unicode"))
        XCTAssertNil(BrailleFileCode.importChoice(withID: "ascii-braillo-no-047-01"))
    }

    /// Two codes are the same code exactly when their ids are.
    func testCodesAreEqualByTheirIDs() {
        XCTAssertNotEqual(BrailleFileCode.northAmerican, .eurobraille)
        let renamed = BrailleFileCode(id: "ascii-na", name: "Another name", characterName: "x", kind: .unicodePatterns)
        XCTAssertEqual(renamed, .northAmerican)
        XCTAssertEqual(Set([renamed, .northAmerican, .unicode]).count, 2)
    }
}
