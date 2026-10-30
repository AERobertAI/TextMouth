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
    /// The PEF of the same chapter.
    private static let pefSample = "pef/pride-and-prejudice-ch1-grade1.pef"
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

    /// What `book`'s file reads as in the code the id `code` names, with
    /// pages, as a generation writes content.md: its UTF-8.
    private func reading(of book: Book, in code: String?) throws -> Data {
        Data(try BrailleBookReader.markdown(
            of: URL(fileURLWithPath: book.filePath), table: Self.table, fileCode: code, includesPages: true
        ).utf8)
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

    // MARK: - The Import

    /// A BRF imported with the setting North American Braille ASCII records
    /// "ascii-na" explicitly, in its row and its package record, as the table
    /// is recorded, and reads as a book that records no code reads, as every
    /// braille book read before files had a code: its content.md is, byte
    /// for byte, what the reader gives with no code (`BrailleSampleGoldenTests`
    /// pins those bytes).
    func testANorthAmericanBRFRecordsItsCodeAndReadsAsBefore() throws {
        let book = try imported(copyOfFormatSample(Self.sample), settingCode: .northAmerican)

        XCTAssertEqual(book.brailleFileCode, "ascii-na")
        XCTAssertEqual(try recordedCode(of: book), "ascii-na")
        XCTAssertEqual(try contentMD(of: book), try reading(of: book, in: nil))
    }

    /// The sample written in Eurobraille, imported with the setting
    /// Eurobraille, records "ascii-eurobraille" and reads, byte for byte, as
    /// the North American sample does. Imported with the setting North
    /// American instead, it reads with no error and gives other text: no byte
    /// tells the seven-bit codes apart, which is why the listener chooses the
    /// code and the book keeps it.
    func testAEurobrailleBRFIsReadInTheSettingsCode() throws {
        let expected = try contentMD(of: imported(copyOfFormatSample(Self.sample), settingCode: .northAmerican))
        let eurobraille = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)

        let book = try imported(eurobraille, settingCode: .eurobraille)
        XCTAssertEqual(book.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: book), "ascii-eurobraille")
        XCTAssertEqual(try contentMD(of: book), expected)

        let misread = try imported(eurobraille, settingCode: .northAmerican)
        XCTAssertEqual(misread.brailleFileCode, "ascii-na")
        XCTAssertNotEqual(try contentMD(of: misread), expected, "a wrong choice is silent, but it is wrong")
    }

    /// The sample written in Unicode braille patterns records "unicode"
    /// whatever the setting names (Eurobraille here), since its bytes say so
    /// for certain, and reads, byte for byte, as the North American sample
    /// does.
    func testAUnicodeBRFIsKnownByItsBytesWhateverTheSetting() throws {
        let expected = try contentMD(of: imported(copyOfFormatSample(Self.sample), settingCode: .northAmerican))

        let book = try imported(copyOfBrailleSample(Self.sample, writtenIn: .unicode), settingCode: .eurobraille)

        XCTAssertEqual(book.brailleFileCode, "unicode")
        XCTAssertEqual(try recordedCode(of: book), "unicode")
        XCTAssertEqual(try contentMD(of: book), expected)
    }

    /// A PEF records no code, whatever the setting names, and so does a PEF
    /// named .xml: its rows are always Unicode braille patterns.
    func testAPEFRecordsNoCode() throws {
        let imports: [(name: String?, setting: BrailleFileCode)] = [
            (nil, .northAmerican),
            (nil, .eurobraille),
            ("pride-and-prejudice-ch1-grade1.xml", .eurobraille),
        ]
        for (name, setting) in imports {
            let book = try imported(copyOfFormatSample(Self.pefSample, named: name), settingCode: setting)
            let label = "\(name ?? "the PEF") with the setting \(setting.id)"
            XCTAssertEqual(book.format, .braille, label)
            XCTAssertNil(book.brailleFileCode, label)
            XCTAssertNil(try recordedCode(of: book), label)
        }
    }

    // MARK: - Every Later Reading

    /// A rebuild reads the book's file in the code its package record keeps,
    /// over a row that lags behind it: a Eurobraille book whose row says
    /// North American Braille ASCII writes its content.md again unchanged,
    /// which reading it as North American would change, and the row takes
    /// the record's code back.
    func testARebuildReadsTheRecordsCodeOverALaggingRow() throws {
        var book = try imported(copyOfBrailleSample(Self.sample, writtenIn: .eurobraille), settingCode: .eurobraille)
        let before = try contentMD(of: book)
        XCTAssertNotEqual(try reading(of: book, in: "ascii-na"), before, "the codes must read otherwise, or this proves nothing")
        book.brailleFileCode = "ascii-na"

        XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book, replacingEditedText: true))

        XCTAssertEqual(try contentMD(of: book), before)
        XCTAssertEqual(book.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: book), "ascii-eurobraille")
    }

    /// A read that decides, as an import's does and a re-read's in other
    /// braille file characters will, reads the book's file in the code its
    /// row names, over the record's, and the row keeps it: that read is the
    /// decision, which the record takes when the re-read commits it.
    func testAReadThatDecidesReadsTheRowsCode() throws {
        var book = try imported(copyOfBrailleSample(Self.sample, writtenIn: .eurobraille), settingCode: .eurobraille)
        let before = try contentMD(of: book)
        book.brailleFileCode = "ascii-na"

        XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(
            for: &book, replacingEditedText: true, decidingEncoding: true
        ))

        let after = try contentMD(of: book)
        XCTAssertNotEqual(after, before, "the row's code was not read")
        XCTAssertEqual(after, try reading(of: book, in: "ascii-na"))
        XCTAssertEqual(book.brailleFileCode, "ascii-na")
    }

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

// MARK: - A Braille Sample in Another Code

extension XCTestCase {
    /// A copy of the BRF or BRL sample at `relativePath` inside
    /// `TestData/format-samples`, a North American Braille ASCII file, with
    /// its cells written in `code` instead (`BrailleFileCodeSampleTests
    /// .bytes(_:writtenIn:)`), named as the sample is, in a new folder of
    /// this test's own. No sample was written in another code by the
    /// software of a country that uses it, so a book of such a copy proves
    /// round trips, not real use. Shared by the tests of the import and of
    /// the re-read in other braille file characters.
    func copyOfBrailleSample(_ relativePath: String, writtenIn code: BrailleFileCode) throws -> URL {
        let copy = try copyOfFormatSample(relativePath)
        let bytes = try [UInt8](Data(contentsOf: copy))
        // Written atomically, in place of the copy, whatever the copy's
        // permissions: the samples' folder itself is never written.
        try Data(BrailleFileCodeSampleTests.bytes(bytes, writtenIn: code)).write(to: copy, options: .atomic)
        return copy
    }
}
