import XCTest
@testable import TextMouth

/// The braille file characters a braille book is read in, from its import to
/// every later reading (braillecodes, BRAILLE-CODES-RESEARCH-2026-10-25.md,
/// sections 8.3 to 8.5).
///
/// An import records, by an explicit id, the code it read a BRF or BRL file
/// in: Unicode braille patterns when the file's bytes say so for certain, and
/// the Braille setting's code otherwise, since no byte tells the seven-bit
/// codes apart; a PEF records none. Every later reading of the book's file
/// uses the code that stands between its row and its package record, and a
/// code this TextMouth does not know is refused by name, never read as
/// another.
///
/// The format samples are North American Braille ASCII files, so a sample in
/// another code is the grade 1 sample's cells written in that code
/// (`copyOfBrailleSample(_:writtenIn:)`). Every import binds the table and
/// the code it names, never the user's settings.
final class BrailleFileCodeImportTests: XCTestCase {
    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// record one.
    private static let unknownCode = "ascii-braillo-no-047-01"

    // MARK: - The Setting

    /// The setting reads North American Braille ASCII until a code of the
    /// catalog is stored, and again for an empty value, an id this TextMouth
    /// does not know, or a value that is not a string; a stored code reads as
    /// itself.
    func testTheSettingReadsAKnownCodeElseNorthAmerican() {
        let defaults = makeSandboxedPreferences("BrailleFileCode")
        XCTAssertEqual(BraillePreferences.fileCode.key, "brailleFileCode")
        XCTAssertEqual(BraillePreferences.fileCode.read(from: defaults), "ascii-na")

        for code in BrailleFileCode.all {
            BraillePreferences.fileCode.write(code.id, to: defaults)
            XCTAssertEqual(defaults.string(forKey: "brailleFileCode"), code.id)
            XCTAssertEqual(BraillePreferences.fileCode.read(from: defaults), code.id)
        }
        let unreadable: [Any] = ["", Self.unknownCode, 42]
        for stored in unreadable {
            defaults.set(stored, forKey: "brailleFileCode")
            XCTAssertEqual(BraillePreferences.fileCode.read(from: defaults), "ascii-na", "stored: \(stored)")
        }
    }

    /// A test chooses an import's code without writing any store; with none
    /// bound, an import reads the setting from the runtime's store, which
    /// hosted tests sandbox, never the user's real preferences: North
    /// American Braille ASCII while it holds none, and the stored code once
    /// one is written there (put back when the test ends).
    func testTheImportCodeIsTheBoundOneElseTheRuntimesSetting() {
        let store = TextMouthRuntime.current.preferences
        preservePreferences([BraillePreferences.fileCode.key], in: store)
        store.removeObject(forKey: BraillePreferences.fileCode.key)
        XCTAssertNil(BraillePreferences.fileCodeForImports)
        XCTAssertEqual(BraillePreferences.importFileCode(), "ascii-na")

        BraillePreferences.fileCode.write("ascii-eurobraille", to: store)
        XCTAssertEqual(BraillePreferences.importFileCode(), "ascii-eurobraille")

        // A bound code wins over the store, and only while it is bound.
        BraillePreferences.$fileCodeForImports.withValue("unicode") {
            XCTAssertEqual(BraillePreferences.importFileCode(), "unicode")
        }
        XCTAssertNil(BraillePreferences.fileCodeForImports)
        XCTAssertEqual(BraillePreferences.importFileCode(), "ascii-eurobraille")
    }
}
