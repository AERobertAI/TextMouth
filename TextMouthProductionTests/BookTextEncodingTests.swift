import XCTest
@testable import TextMouth

/// The encoding a text book was guessed to be in (FMT16), kept in the book's
/// row, its package record, and its removal marker, so that every later
/// reading of the book uses it: written only for a book that has one, read
/// from files written before it existed, and repaired when it is damaged.
final class BookTextEncodingTests: XCTestCase {

    // MARK: - Fixtures

    /// A plain-text book guessed to be in `encoding`, nil for none.
    private func book(encoding: String?, format: BookFormat = .txt) -> Book {
        Book(
            title: "Ledger", format: format, filePath: "/nowhere/Ledger.\(format.fileExtensions.first ?? "txt")",
            md5Hash: "text-encoding-fixture", tmbDirectoryName: "Ledger.tmb", textEncoding: encoding
        )
    }

    /// The JSON a library row of `book` is written as.
    private func row(of book: Book) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
    }

    /// The book a library row's JSON decodes as.
    private func decoded(_ row: [String: Any]) throws -> Book {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
    }

    // MARK: - The Library Row

    /// A book guessed to be in an encoding writes it in its row, and reads it
    /// back; a book with none writes no key, so every other row of the
    /// library is exactly as it was.
    func testARowHoldsTheEncodingOnlyForABookThatHasOne() throws {
        let guessed = try row(of: book(encoding: "windows-1251"))
        XCTAssertEqual(guessed["textEncoding"] as? String, "windows-1251")
        XCTAssertEqual(try decoded(guessed).textEncoding, "windows-1251")

        XCTAssertNil(try row(of: book(encoding: nil))["textEncoding"])
    }

    /// A row written before the field existed, or one whose value cannot be
    /// read, decodes with no encoding and keeps the rest of the book: the
    /// whole library does not fail over one damaged field, and the book is
    /// read as every book was before guesses were recorded.
    func testARowWithoutTheFieldOrWithAnUnreadableOneDecodesWithNone() throws {
        var older = try row(of: book(encoding: "koi8-r"))
        older.removeValue(forKey: "textEncoding")
        XCTAssertNil(try decoded(older).textEncoding)

        var damaged = try row(of: book(encoding: "koi8-r"))
        damaged["textEncoding"] = 17
        let repaired = try decoded(damaged)
        XCTAssertNil(repaired.textEncoding)
        XCTAssertEqual(repaired.title, "Ledger")
        XCTAssertEqual(repaired.format, .txt)
    }

    // MARK: - The Package Record

    /// The package record keeps the encoding in its metadata, written to
    /// bookInfo.json and read from it, and the book made from the record has it.
    func testThePackageRecordKeepsTheEncoding() throws {
        let guessed = book(encoding: "shift_jis")
        let info = guessed.makeBookInfo()
        XCTAssertEqual(info.metadata.textEncoding, "shift_jis")

        let package = try makeSandboxDirectory("TextEncoding").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try info.save(to: package)
        let loaded = try BookInfo.load(from: package)
        XCTAssertEqual(loaded.metadata.textEncoding, "shift_jis")
        let rebuilt = Book(record: loaded, filePath: guessed.filePath, folderPath: "", tmbDirectoryName: "Ledger.tmb")
        XCTAssertEqual(rebuilt.textEncoding, "shift_jis")

        XCTAssertNil(book(encoding: nil).makeBookInfo().metadata.textEncoding)
    }

    /// A record written before the field existed loads, and the book made
    /// from it has no encoding.
    func testARecordWithoutTheFieldStillLoads() throws {
        let package = try makeSandboxDirectory("TextEncoding").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try book(encoding: "koi8-r").makeBookInfo().save(to: package)

        let recordURL = TextMouthPaths.bookInfoPath(in: package)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["textEncoding"] as? String, "koi8-r")
        metadata["textEncoding"] = nil
        record["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)

        let info = try BookInfo.load(from: package)
        XCTAssertNil(info.metadata.textEncoding)
        XCTAssertNil(Book(record: info, filePath: "/nowhere/Ledger.txt", folderPath: "", tmbDirectoryName: "Ledger.tmb").textEncoding)
    }

    /// A record whose encoding cannot be read (a number, a list, an object)
    /// loads with no encoding and keeps the rest of the book, as a row does:
    /// one damaged field does not fail the whole record, which would take
    /// the book's place, bookmarks, and settings with it. A value that reads
    /// is kept, and a null is none.
    func testARecordWithAnUnreadableEncodingStillLoadsWithNone() throws {
        let package = try makeSandboxDirectory("TextEncoding").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let recordURL = TextMouthPaths.bookInfoPath(in: package)
        func load(withEncoding value: Any) throws -> BookInfo {
            try book(encoding: "koi8-r").makeBookInfo().save(to: package)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
            metadata["textEncoding"] = value
            record["metadata"] = metadata
            try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
            return try BookInfo.load(from: package)
        }

        XCTAssertEqual(try load(withEncoding: "windows-1251").metadata.textEncoding, "windows-1251")
        XCTAssertNil(try load(withEncoding: NSNull()).metadata.textEncoding)
        for damaged in [17, ["koi8-r"], ["name": "koi8-r"], true] as [Any] {
            let info = try load(withEncoding: damaged)
            XCTAssertNil(info.metadata.textEncoding, "\(damaged)")
            XCTAssertEqual(info.metadata.title, "Ledger", "\(damaged)")
            XCTAssertEqual(info.metadata.format, .txt, "\(damaged)")
        }
    }

    /// A save of a row that lost its encoding keeps the stored record's, and
    /// a row's own encoding wins.
    func testTheStoredRecordsEncodingSurvivesARowThatLostIt() {
        let guessed = book(encoding: "windows-1250")
        let stored = StoredBookRecord(info: guessed.makeBookInfo(), keepsContentIndex: false)

        var lost = guessed
        lost.textEncoding = nil
        XCTAssertEqual(lost.bookInfo(replacing: stored, contentIndex: nil).metadata.textEncoding, "windows-1250")
        XCTAssertNil(lost.bookInfo(replacing: nil, contentIndex: nil).metadata.textEncoding)

        var changed = guessed
        changed.textEncoding = "iso-8859-2"
        XCTAssertEqual(changed.bookInfo(replacing: stored, contentIndex: nil).metadata.textEncoding, "iso-8859-2")
    }

    // MARK: - The Removal Marker

    /// The marker written when a book is removed from the library only keeps
    /// the encoding, which bookInfo.json, deleted by the removal, also held;
    /// a marker written before the field existed has none and still reads.
    func testTheMarkerKeepsTheEncodingAndAnOlderMarkerHasNone() throws {
        let package = try makeSandboxDirectory("TextEncoding").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let guessed = book(encoding: "euc-kr")
        XCTAssertEqual(RemovedFromLibraryMarker(book: guessed).textEncoding, "euc-kr")

        try RemovedFromLibraryMarker(book: guessed).write(into: package)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: package).textEncoding, "euc-kr")

        // Take the field out of the file, as a marker from an earlier build.
        let url = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fields.removeValue(forKey: "textEncoding")
        try JSONSerialization.data(withJSONObject: fields).write(to: url)

        let older = try RemovedFromLibraryMarker.read(in: package)
        XCTAssertEqual(older.bookID, guessed.id)
        XCTAssertNil(older.textEncoding)
    }

    /// A text book rebuilt from its marker (its record is gone) is read in
    /// the encoding the marker keeps; a book of a format that has no use for
    /// an encoding (an EPUB, whatever the marker holds) takes none from it.
    func testABookRebuiltFromItsMarkerKeepsItsEncoding() throws {
        let cases: [(format: BookFormat, fileName: String, encoding: String?)] = [
            (.txt, "Ledger.txt", "windows-1251"),
            (.markdown, "Ledger.md", "windows-1251"),
            (.epub, "Ledger.epub", nil),
        ]
        for (format, fileName, expected) in cases {
            let package = try makeSandboxDirectory("TextEncoding").appendingPathComponent("Ledger.tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("Hello\n".utf8).write(to: package.appendingPathComponent(fileName))
            let marker = RemovedFromLibraryMarker(book: book(encoding: "windows-1251", format: format))

            let rebuilt = try FileImportService.reconstructedBook(
                inPackage: package, marker: marker, folderPath: "", dateAdded: Date()
            )
            XCTAssertEqual(rebuilt.format, format, fileName)
            XCTAssertEqual(rebuilt.textEncoding, expected, fileName)
        }
    }

    // MARK: - Formats

    /// Only plain text, Markdown, and HTML go through the text file decoder
    /// and so have an encoding to guess.
    func testOnlyPlainTextMarkdownAndHTMLUseTheTextFileDecoder() {
        XCTAssertEqual(
            Set(BookFormat.allCases.filter(\.usesTextFileDecoder)), [.txt, .markdown, .html]
        )
    }
}
