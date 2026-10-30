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
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The table both samples are written in: uncontracted UEB.
    private static let table = "en-ueb-g1.ctb"
    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// record one.
    private static let unknownCode = "ascii-braillo-no-047-01"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
    }

    // MARK: - Helpers

    /// The book the file at `url` imports as, with the samples' table, and
    /// with `code` as the Braille setting's file code.
    private func imported(_ url: URL, settingCode code: BrailleFileCode) throws -> Book {
        try BraillePreferences.$tableForImports.withValue(Self.table) {
            try BraillePreferences.$fileCodeForImports.withValue(code.id) {
                try importedForTest(url).book
            }
        }
    }

    /// The bytes of the content.md in `book`'s package.
    private func contentMD(of book: Book) throws -> Data {
        try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
    }

    /// The code the record in `book`'s package keeps.
    private func recordedCode(of book: Book) throws -> String? {
        try BookInfo.load(from: book.tmbDirectory).metadata.brailleFileCode
    }

    /// Writes `code` into the record in `book`'s package as the code it
    /// keeps, as a later TextMouth's record may hold one, and changes nothing
    /// else in the record.
    private func recordCode(_ code: String, inRecordOf book: Book) throws {
        let recordURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        metadata["brailleFileCode"] = code
        record["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    }

    // MARK: - Every Later Reading

    /// A code this TextMouth does not know, as a later TextMouth may record,
    /// is refused by name and changes nothing: the rebuild of a book whose
    /// row and record hold it fails with the reader's sentence, content.md
    /// keeps its bytes and the book its code, and the direct parse refuses it
    /// in the same words.
    func testAnUnknownCodeIsRefusedByNameAndChangesNothing() throws {
        var book = try imported(copyOfFormatSample(Self.sample), settingCode: .northAmerican)
        let before = try contentMD(of: book)
        try recordCode(Self.unknownCode, inRecordOf: book)
        XCTAssertEqual(try recordedCode(of: book), Self.unknownCode, "the record must hold the code, or this proves nothing")
        book.brailleFileCode = Self.unknownCode
        let sentence = "TextMouth has no braille file characters named “ascii-braillo-no-047-01”."

        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book, replacingEditedText: true)) {
            XCTAssertEqual($0 as? BrailleFileError, .unknownFileCode(Self.unknownCode))
            XCTAssertEqual($0.localizedDescription, sentence)
        }
        XCTAssertEqual(try contentMD(of: book), before)
        XCTAssertEqual(book.brailleFileCode, Self.unknownCode)
        XCTAssertEqual(try recordedCode(of: book), Self.unknownCode)

        XCTAssertThrowsError(try BookParser.parse(
            url: URL(fileURLWithPath: book.filePath), format: .braille, brailleFileCode: Self.unknownCode
        )) {
            XCTAssertEqual($0.localizedDescription, sentence)
        }
    }

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
