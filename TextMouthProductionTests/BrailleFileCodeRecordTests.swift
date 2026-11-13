import XCTest
@testable import TextMouth

/// The braille file characters a BRF or BRL book's file is read in
/// (braillecodes), by the code's id, kept in the book's row, its package
/// record, and its removal marker: written only for a book that has one,
/// read from files written before it existed, repaired when it is damaged,
/// kept exactly as stored when this TextMouth does not know it, and settled
/// between a row and a record by one rule, the record's whenever it names
/// one (`BrailleFileCodeRecord.standing(row:recorded:)`).
final class BrailleFileCodeRecordTests: XCTestCase {

    // MARK: - Fixtures

    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// write one.
    private static let unknownCode = "ascii-braillo-no-047-01"

    /// When every fixture book was added: a whole second, which the JSON of
    /// a row and a record keeps exactly, so a book read back equals itself.
    private static let added = Date(timeIntervalSince1970: 1_790_000_000)

    /// A braille book whose file is read in the braille file characters
    /// `code` names, nil for none; or, for another `format`, a book of that
    /// format holding `code` in its row. Each call is a new book, with an
    /// ID of its own.
    private func book(code: String?, format: BookFormat = .braille) -> Book {
        Book(
            title: "Tide Tables",
            format: format,
            filePath: "/nowhere/Tide Tables.\(format.fileExtensions.first ?? "txt")",
            md5Hash: "braille-file-code-fixture",
            dateAdded: Self.added,
            tmbDirectoryName: "Tide Tables.tmb",
            brailleTable: format == .braille ? "en-ueb-g2.ctb" : nil,
            brailleFileCode: code
        )
    }

    /// `book` with its row's code set to `code`, the same book otherwise.
    private func book(_ book: Book, withCode code: String?) -> Book {
        var changed = book
        changed.brailleFileCode = code
        return changed
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

    /// A new, empty package folder in this test's sandbox, removed when the
    /// test ends, for a record or a marker read and written where it lies.
    private func makeSandboxPackage() throws -> URL {
        let package = try makeSandboxDirectory("BrailleFileCode")
            .appendingPathComponent("Tide Tables.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    /// A book of `format` (braille unless named) whose row holds `code`, in
    /// a package of its own holding its file and no record yet. A book's
    /// package is always where the data directory places it
    /// (`Book.tmbDirectory`), so the package is in a library folder of the
    /// hosted test root, made for this test and removed, with everything
    /// in it, when the test ends.
    private func makePackagedBook(code: String?, format: BookFormat = .braille) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "Braille File Code \(UUID().uuidString.prefix(8))"
        let folderURL = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folderURL) }
        let packageName = "BrailleFileCode-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("Tide Tables.\(format.fileExtensions.first ?? "txt")")
        try Data(",TIDE TABLES\n,HI< WAT]\n".utf8).write(to: source)
        return Book(
            title: "Tide Tables",
            format: format,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder,
            dateAdded: Self.added,
            tmbDirectoryName: packageName,
            brailleTable: format == .braille ? "en-ueb-g2.ctb" : nil,
            brailleFileCode: code
        )
    }

    /// The code the record in `book`'s package holds.
    private func recordedCode(of book: Book) throws -> String? {
        try BookInfo.load(from: book.tmbDirectory).metadata.brailleFileCode
    }

    // MARK: - The Library Row

    /// A braille book with a code writes it in its row, by its id, and reads
    /// it back; a book with none writes no key, so every row of a book that
    /// records none is exactly as it was.
    func testARowHoldsTheCodeOnlyForABookThatHasOne() throws {
        let eurobraille = try row(of: book(code: "ascii-eurobraille"))
        XCTAssertEqual(eurobraille["brailleFileCode"] as? String, "ascii-eurobraille")
        XCTAssertEqual(try decoded(eurobraille).brailleFileCode, "ascii-eurobraille")

        XCTAssertNil(try row(of: book(code: nil))["brailleFileCode"])
    }

    /// A row written before the key existed decodes with no code; so does
    /// one whose value cannot be read (a number, a list, an object, a
    /// truth value), which keeps every other field of the book, so the
    /// whole library never fails over one damaged field.
    func testARowWithoutTheKeyOrWithADamagedValueDecodesWithNone() throws {
        let original = book(code: "unicode")
        let expected = book(original, withCode: nil)

        var older = try row(of: original)
        older.removeValue(forKey: "brailleFileCode")
        XCTAssertEqual(try decoded(older), expected)

        for damaged in [17, ["ascii-na"], ["code": "ascii-na"], true] as [Any] {
            var damagedRow = try row(of: original)
            damagedRow["brailleFileCode"] = damaged
            XCTAssertEqual(try decoded(damagedRow), expected, "\(damaged)")
        }
    }

    // MARK: - The Package Record

    /// The package record keeps the code in its metadata, written to
    /// bookInfo.json only when there is one and read back from it, and the
    /// book made from the record has it.
    func testThePackageRecordKeepsTheCode() throws {
        let eurobraille = book(code: "ascii-eurobraille")
        let info = eurobraille.makeBookInfo()
        XCTAssertEqual(info.metadata.brailleFileCode, "ascii-eurobraille")

        let package = try makeSandboxPackage()
        try info.save(to: package)
        let recordURL = TextMouthPaths.bookInfoPath(in: package)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        let metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["brailleFileCode"] as? String, "ascii-eurobraille")

        let loaded = try BookInfo.load(from: package)
        XCTAssertEqual(loaded.metadata.brailleFileCode, "ascii-eurobraille")
        let rebuilt = Book(
            record: loaded, filePath: eurobraille.filePath, folderPath: "", tmbDirectoryName: eurobraille.tmbDirectoryName
        )
        XCTAssertEqual(rebuilt.brailleFileCode, "ascii-eurobraille")

        // A book that records none writes no key.
        try book(code: nil).makeBookInfo().save(to: package)
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        let noneMetadata = try XCTUnwrap(none["metadata"] as? [String: Any])
        XCTAssertNil(noneMetadata["brailleFileCode"])
        XCTAssertNil(try BookInfo.load(from: package).metadata.brailleFileCode)
    }

    /// A record written before the key existed, or one whose value cannot be
    /// read (a null, a number, a list, an object, a truth value), still
    /// loads, with no code and the rest of the record: one damaged field
    /// never fails the record, which would take the book's place,
    /// bookmarks, and settings with it. A value that reads is kept.
    func testARecordWithoutTheKeyOrWithADamagedValueStillLoadsWithNone() throws {
        let package = try makeSandboxPackage()
        let recordURL = TextMouthPaths.bookInfoPath(in: package)
        let original = book(code: "unicode")
        /// The record of `original` with its code's value replaced by
        /// `value`, or its key removed when `value` is nil, as loaded.
        func load(withCode value: Any?) throws -> BookInfo {
            try original.makeBookInfo().save(to: package)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
            XCTAssertEqual(metadata["brailleFileCode"] as? String, "unicode", "the record held the code")
            metadata["brailleFileCode"] = value
            record["metadata"] = metadata
            try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
            return try BookInfo.load(from: package)
        }

        XCTAssertEqual(try load(withCode: "ascii-na").metadata.brailleFileCode, "ascii-na")
        for damaged in [nil, NSNull(), 17, ["ascii-na"], ["code": "ascii-na"], true] as [Any?] {
            let label = String(describing: damaged)
            let info = try load(withCode: damaged)
            XCTAssertNil(info.metadata.brailleFileCode, label)
            XCTAssertEqual(info.metadata.title, "Tide Tables", label)
            XCTAssertEqual(info.metadata.bookID, original.id, label)
            XCTAssertEqual(info.metadata.brailleTable, "en-ueb-g2.ctb", label)
            let rebuilt = Book(record: info, filePath: original.filePath, folderPath: "", tmbDirectoryName: "Tide Tables.tmb")
            XCTAssertEqual(rebuilt, book(original, withCode: nil), label)
        }
    }

    // MARK: - A Code This TextMouth Does Not Know

    /// An id no code of this TextMouth has, as a later TextMouth's may be,
    /// is kept exactly as it is stored by the row, the record, the book made
    /// from the record, a save of the row over the record, and the removal
    /// marker: it is never dropped, nor read as another code.
    func testAnUnknownCodeSurvivesTheRowTheRecordAndTheMarkerUnchanged() throws {
        let later = book(code: Self.unknownCode)
        XCTAssertEqual(try decoded(row(of: later)).brailleFileCode, Self.unknownCode)

        let package = try makeSandboxPackage()
        try later.makeBookInfo().save(to: package)
        let loaded = try BookInfo.load(from: package)
        XCTAssertEqual(loaded.metadata.brailleFileCode, Self.unknownCode)
        let rebuilt = Book(record: loaded, filePath: later.filePath, folderPath: "", tmbDirectoryName: later.tmbDirectoryName)
        XCTAssertEqual(rebuilt.brailleFileCode, Self.unknownCode)

        let stored = StoredBookRecord(info: loaded, keepsContentIndex: false)
        XCTAssertEqual(rebuilt.bookInfo(replacing: stored, contentIndex: nil).metadata.brailleFileCode, Self.unknownCode)
        XCTAssertEqual(
            book(rebuilt, withCode: nil).bookInfo(replacing: stored, contentIndex: nil).metadata.brailleFileCode,
            Self.unknownCode,
            "a row that lost it takes the record's back"
        )

        try RemovedFromLibraryMarker(book: later).write(into: package)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: package).brailleFileCode, Self.unknownCode)
    }

    // MARK: - The Rule

    /// The record's code stands whenever it names one, whatever the row
    /// holds, an id this TextMouth does not know included; the row's, nil
    /// included, stands when the record names none.
    func testTheRecordsCodeStandsWhenItNamesOneAndTheRowsOtherwise() {
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: "ascii-na", recorded: "ascii-eurobraille"), "ascii-eurobraille")
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: nil, recorded: "unicode"), "unicode")
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: "unicode", recorded: "unicode"), "unicode")
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: "unicode", recorded: Self.unknownCode), Self.unknownCode)
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: Self.unknownCode, recorded: nil), Self.unknownCode)
        XCTAssertEqual(BrailleFileCodeRecord.standing(row: "ascii-eurobraille", recorded: nil), "ascii-eurobraille")
        XCTAssertNil(BrailleFileCodeRecord.standing(row: nil, recorded: nil))
    }

    // MARK: - Writes of the Record

    /// A write of the record keeps the stored record's code over a row that
    /// lags behind a re-read, with or without an index, or lost its own;
    /// only the next re-read's write, which decides, replaces it, North
    /// American Braille ASCII's included. Over a record that names none,
    /// the row's code is written, its nil included.
    func testAWriteKeepsTheRecordsCodeOverALaggingRowUnlessItDecides() {
        let original = book(code: "ascii-eurobraille")
        let eurobrailleRecord = StoredBookRecord(info: original.makeBookInfo(), keepsContentIndex: true)
        let noCodeRecord = StoredBookRecord(info: book(original, withCode: nil).makeBookInfo(), keepsContentIndex: true)
        let index = BookContentIndex.build(fromChapters: [Chapter(title: "One", text: "high water")], format: .braille)
        /// The code a write of `original`'s row holding `code` puts in the
        /// record over `stored`.
        func written(
            _ code: String?, over stored: StoredBookRecord?, index: BookContentIndex? = nil, deciding: Bool = false
        ) -> String? {
            book(original, withCode: code)
                .bookInfo(replacing: stored, contentIndex: index, decidingBrailleFileCode: deciding)
                .metadata.brailleFileCode
        }

        // The record's code, kept by a lagging row or one that lost its own.
        for code in ["ascii-na", nil] as [String?] {
            let label = String(describing: code)
            XCTAssertEqual(written(code, over: eurobrailleRecord), "ascii-eurobraille", label)
            XCTAssertEqual(written(code, over: eurobrailleRecord, index: index), "ascii-eurobraille", label)
        }
        // Replaced by the next re-read's code.
        XCTAssertEqual(written("ascii-na", over: eurobrailleRecord, index: index, deciding: true), "ascii-na")
        XCTAssertEqual(written("unicode", over: eurobrailleRecord, deciding: true), "unicode")
        // A deciding write names a code; one without leaves the record's.
        XCTAssertEqual(written(nil, over: eurobrailleRecord, index: index, deciding: true), "ascii-eurobraille")

        // No code in the record: the row's.
        XCTAssertEqual(written("ascii-na", over: noCodeRecord), "ascii-na")
        XCTAssertEqual(written("unicode", over: noCodeRecord, index: index), "unicode")
        XCTAssertNil(written(nil, over: noCodeRecord))
        XCTAssertEqual(written("unicode", over: nil), "unicode")
        XCTAssertNil(written(nil, over: nil))
    }

    // MARK: - Reading the Book's File

    /// A braille book's file is read in the code its own package record
    /// keeps when the record names one, over a row that lags behind it or
    /// lost its own.
    func testAReadingTakesTheRecordsCodeOverTheRows() throws {
        let packaged = try makePackagedBook(code: "ascii-eurobraille")
        try packaged.makeBookInfo().save(to: packaged.tmbDirectory)

        XCTAssertEqual(packaged.recordedBrailleFileCode(), "ascii-eurobraille")
        XCTAssertEqual(book(packaged, withCode: "ascii-na").recordedBrailleFileCode(), "ascii-eurobraille")
        XCTAssertEqual(book(packaged, withCode: nil).recordedBrailleFileCode(), "ascii-eurobraille")
    }

    /// The row's code stands, its nil included, when the record names none,
    /// names another book (as an old shared package's may), cannot be read,
    /// or is not there; and for a book without a package.
    func testAReadingTakesTheRowsCodeWhenTheRecordCannotHelp() throws {
        let packaged = try makePackagedBook(code: "unicode")
        XCTAssertEqual(packaged.recordedBrailleFileCode(), "unicode", "no record yet")

        try book(packaged, withCode: nil).makeBookInfo().save(to: packaged.tmbDirectory)
        XCTAssertNil(try recordedCode(of: packaged), "the record must name none, or this proves nothing")
        XCTAssertEqual(packaged.recordedBrailleFileCode(), "unicode", "the record names none")
        XCTAssertNil(book(packaged, withCode: nil).recordedBrailleFileCode())

        var another = packaged.makeBookInfo()
        another.metadata.bookID = UUID()
        another.metadata.brailleFileCode = "ascii-eurobraille"
        try another.save(to: packaged.tmbDirectory)
        XCTAssertEqual(try recordedCode(of: packaged), "ascii-eurobraille", "the record must name a code")
        XCTAssertEqual(packaged.recordedBrailleFileCode(), "unicode", "the record names another book")
        XCTAssertNil(book(packaged, withCode: nil).recordedBrailleFileCode(), "the record names another book")

        try Data("not json".utf8).write(to: TextMouthPaths.bookInfoPath(in: packaged.tmbDirectory))
        XCTAssertEqual(packaged.recordedBrailleFileCode(), "unicode", "an unreadable record")

        let unpackaged = Book(
            title: "Loose", format: .braille, filePath: "/nowhere/Loose.brf", md5Hash: "loose", brailleFileCode: "unicode"
        )
        XCTAssertEqual(unpackaged.recordedBrailleFileCode(), "unicode", "no package, no record")
    }

    /// A book of another format is given its row's code as it is: its own
    /// record is not read, even when it names a code.
    func testABookOfAnotherFormatReadsNoRecord() throws {
        let text = try makePackagedBook(code: nil, format: .txt)
        var info = text.makeBookInfo()
        info.metadata.brailleFileCode = "ascii-eurobraille"
        try info.save(to: text.tmbDirectory)
        XCTAssertEqual(try recordedCode(of: text), "ascii-eurobraille", "the record must name a code, or this proves nothing")

        XCTAssertNil(text.recordedBrailleFileCode())
        XCTAssertEqual(book(text, withCode: "unicode").recordedBrailleFileCode(), "unicode")
    }

    // MARK: - A Recovered Analysis

    /// An analysis recovered from a package record takes the record's code
    /// only for a braille book, and only from its own record: another
    /// book's record, as an old shared package's may be, and a book of
    /// another format, give none. A committed analysis carries the
    /// committed book's code.
    func testARecoveredAnalysisTakesTheCodeOnlyFromABrailleBooksOwnRecord() {
        let row = book(code: "ascii-na")
        let record = book(row, withCode: "ascii-eurobraille")
        XCTAssertEqual(ContentAnalysisSummary(recovered: row, record: record).brailleFileCode, "ascii-eurobraille")

        let anotherBook = book(code: "ascii-eurobraille")
        XCTAssertNotEqual(anotherBook.id, row.id, "the record must be another book's, or this proves nothing")
        XCTAssertNil(ContentAnalysisSummary(recovered: row, record: anotherBook).brailleFileCode)

        let text = book(code: nil, format: .txt)
        XCTAssertNil(ContentAnalysisSummary(recovered: text, record: book(text, withCode: "ascii-eurobraille")).brailleFileCode)

        XCTAssertEqual(ContentAnalysisSummary(committed: record).brailleFileCode, "ascii-eurobraille")
        XCTAssertNil(ContentAnalysisSummary(committed: book(row, withCode: nil)).brailleFileCode)
    }

    /// A row given its analysis takes the record's code whenever the record
    /// names one: a row lagging behind a re-read catches up, and one that
    /// lost its code has it back. A record that names none, or a summary
    /// that carries none, leaves the row's own.
    func testARowGivenItsAnalysisFollowsTheRule() {
        let original = book(code: "ascii-na")
        /// The code a row holding `rowCode` has once it is given the
        /// analysis recovered from its record holding `recorded`.
        func applied(_ rowCode: String?, recorded: String?) -> String? {
            var row = book(original, withCode: rowCode)
            ContentAnalysisSummary(recovered: row, record: book(original, withCode: recorded)).apply(to: &row)
            return row.brailleFileCode
        }

        XCTAssertEqual(applied("ascii-na", recorded: "ascii-eurobraille"), "ascii-eurobraille", "a lagging row catches up")
        XCTAssertEqual(applied(nil, recorded: "unicode"), "unicode", "a row that lost its code has it back")
        XCTAssertEqual(applied("ascii-eurobraille", recorded: nil), "ascii-eurobraille", "the row's own stands")
        XCTAssertEqual(applied("unicode", recorded: Self.unknownCode), Self.unknownCode)
        XCTAssertNil(applied(nil, recorded: nil))

        // Another book's record carries nothing, so the row keeps its own.
        var kept = original
        ContentAnalysisSummary(recovered: kept, record: book(code: "unicode")).apply(to: &kept)
        XCTAssertEqual(kept.brailleFileCode, "ascii-na")
    }

    // MARK: - The Removal Marker

    /// The marker written when a book is removed from the library only
    /// keeps the code, which bookInfo.json, deleted by the removal, also
    /// held. A marker without the key, as an earlier build wrote, or with a
    /// value that cannot be read, still reads, with none, and still names
    /// its book.
    func testTheMarkerKeepsTheCodeAndAnOlderOrDamagedMarkerHasNone() throws {
        let package = try makeSandboxPackage()
        let eurobraille = book(code: "ascii-eurobraille")
        XCTAssertEqual(RemovedFromLibraryMarker(book: eurobraille).brailleFileCode, "ascii-eurobraille")
        XCTAssertNil(RemovedFromLibraryMarker(book: book(code: nil)).brailleFileCode)

        try RemovedFromLibraryMarker(book: eurobraille).write(into: package)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: package).brailleFileCode, "ascii-eurobraille")

        let url = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        for value in [nil, NSNull(), 17, ["ascii-na"], true] as [Any?] {
            let label = String(describing: value)
            try RemovedFromLibraryMarker(book: eurobraille).write(into: package)
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(fields["brailleFileCode"] as? String, "ascii-eurobraille", label)
            fields["brailleFileCode"] = value
            try JSONSerialization.data(withJSONObject: fields).write(to: url)

            let marker = try RemovedFromLibraryMarker.read(in: package)
            XCTAssertNil(marker.brailleFileCode, label)
            XCTAssertEqual(marker.bookID, eurobraille.id, label)
            XCTAssertEqual(marker.brailleTable, "en-ueb-g2.ctb", label)
        }
    }

    /// A braille book added back from its marker (its record is gone) is
    /// read in the code the marker keeps, a BRF's and a BRL's alike; a book
    /// of another format takes none from it, whatever the marker holds.
    func testABookAddedBackFromItsMarkerKeepsItsCode() throws {
        let cases: [(format: BookFormat, fileName: String, expected: String?)] = [
            (.braille, "Tide Tables.brf", "ascii-eurobraille"),
            (.braille, "Tide Tables.brl", "ascii-eurobraille"),
            (.txt, "Tide Tables.txt", nil),
        ]
        for (format, fileName, expected) in cases {
            let package = try makeSandboxPackage()
            try Data(",TIDE TABLES\n".utf8).write(to: package.appendingPathComponent(fileName))
            let marker = RemovedFromLibraryMarker(book: book(code: "ascii-eurobraille", format: format))

            let rebuilt = try FileImportService.reconstructedBook(
                inPackage: package, marker: marker, folderPath: "", dateAdded: Date()
            )
            XCTAssertEqual(rebuilt.format, format, fileName)
            XCTAssertEqual(rebuilt.brailleFileCode, expected, fileName)
        }
    }

    /// Remove from Library Only writes into the marker the code that stands,
    /// the record's, not a row's that lags behind it or lost it to an earlier
    /// TextMouth (review of October 30, finding 2), so the book added back
    /// is read in it: a row holding none, and one holding North American
    /// Braille ASCII, over a record holding Eurobraille.
    func testRemovalKeepsTheCodeThatStandsInTheMarker() throws {
        for rowCode in [nil, "ascii-na"] as [String?] {
            let label = String(describing: rowCode)
            let row = try makePackagedBook(code: rowCode)
            try book(row, withCode: "ascii-eurobraille").makeBookInfo().save(to: row.tmbDirectory)

            let retirement = try LibraryPersistenceService.retirePackage(of: row)
            XCTAssertTrue(retirement.isPackageMarked, label)
            let marker = try RemovedFromLibraryMarker.read(in: row.tmbDirectory)
            XCTAssertEqual(marker.brailleFileCode, "ascii-eurobraille", label)

            let rebuilt = try FileImportService.reconstructedBook(
                inPackage: row.tmbDirectory, marker: marker, folderPath: row.folderPath, dateAdded: Self.added
            )
            XCTAssertEqual(rebuilt.brailleFileCode, "ascii-eurobraille", label)
        }
    }

    /// The marker keeps the text encoding that stands the same way: a text
    /// book whose row records none, over a record holding a chosen one,
    /// leaves the record's in its marker (review of October 30, finding 2).
    func testRemovalKeepsTheTextEncodingThatStandsInTheMarker() throws {
        let row = try makePackagedBook(code: nil, format: .txt)
        var recorded = row
        recorded.textEncodingRecord = TextEncodingRecord(identifier: "koi8-r", source: .chosen)
        try recorded.makeBookInfo().save(to: row.tmbDirectory)

        XCTAssertTrue(try LibraryPersistenceService.retirePackage(of: row).isPackageMarked)
        let marker = try RemovedFromLibraryMarker.read(in: row.tmbDirectory)
        XCTAssertEqual(marker.textEncoding, "koi8-r")
        XCTAssertEqual(marker.textEncodingSource, .chosen)
    }

    /// An analysis saved over a reading checkpoint that waits to be written,
    /// whose row lags behind the record's code, returns the code the record
    /// holds, not the snapshot's (review of October 30, finding 2), so the
    /// row that takes the analysis catches up.
    func testAnAnalysisSavedOverAWaitingSnapshotReturnsTheRecordsCode() throws {
        let row = try makePackagedBook(code: "ascii-na")
        try book(row, withCode: "ascii-eurobraille").makeBookInfo().save(to: row.tmbDirectory)
        // A save of the lagging row waits on the metadata queue.
        LibraryPersistenceService.saveBookInfo(for: row)
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Tide Tables", text: "High water at noon.")], format: .braille
        )

        let committed = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: row, index: index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))

        XCTAssertEqual(committed.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: row), "ascii-eurobraille")
    }

    // MARK: - A Re-read's Save

    /// A re-read's analysis saved with its code writes the code into the
    /// record and the book it returns. A later save from a row still
    /// holding the old code (an analysis without one, or a reading
    /// checkpoint's save of the row) keeps the record's, and the row takes
    /// the record's with the analysis. The next re-read's code, North
    /// American Braille ASCII's included, replaces it.
    func testAReReadsSaveRecordsItsCodeAndALaggingRowKeepsIt() throws {
        let row = try makePackagedBook(code: "ascii-na")
        try row.saveBookInfoThrowing()
        XCTAssertEqual(try recordedCode(of: row), "ascii-na", "the record holds the import's code")
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Tide Tables", text: "High water at noon.")], format: .braille
        )
        let version = MarkdownCacheService.currentCacheVersion

        let reread = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: row, index: index, cacheFormatVersion: version, brailleFileCode: "ascii-eurobraille"
        ))
        XCTAssertEqual(reread.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: row), "ascii-eurobraille")

        // The row still holds the import's code.
        let later = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: row, index: index, cacheFormatVersion: version
        ))
        XCTAssertEqual(later.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: row), "ascii-eurobraille", "an analysis without a code")
        try row.saveBookInfoThrowing()
        XCTAssertEqual(try recordedCode(of: row), "ascii-eurobraille", "a save of the lagging row")

        var caughtUp = row
        ContentAnalysisSummary(committed: later).apply(to: &caughtUp)
        XCTAssertEqual(caughtUp.brailleFileCode, "ascii-eurobraille")

        let next = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: caughtUp, index: index, cacheFormatVersion: version, brailleFileCode: "ascii-na"
        ))
        XCTAssertEqual(next.brailleFileCode, "ascii-na")
        XCTAssertEqual(try recordedCode(of: row), "ascii-na")
    }

    // MARK: - The Reader's Library Fields

    /// The code is one of the library fields a reader takes from its book's
    /// row while the book is open, so its Book Information shows a new
    /// choice: a change of the code changes them, and taking them gives the
    /// reader the code while it keeps its own place.
    func testTheCodeIsALibraryFieldTheReaderTakes() {
        let open = book(code: "ascii-na")
        let reread = book(open, withCode: "ascii-eurobraille")
        XCTAssertNotEqual(reread.libraryFields, open.libraryFields)

        var reader = open
        reader.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 9)
        reader.libraryFields = reread.libraryFields
        XCTAssertEqual(reader.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(reader.readingPosition?.characterOffset, 9, "the reader keeps its own place")
    }

    /// The braille table, with the version it was read under, is a library
    /// field too (FMT21): a Braille Code re-read changes them, and an open
    /// reader that takes them follows the new table (its Book Information
    /// opens on it, and a regeneration in the reader translates with it),
    /// keeping its own place.
    func testTheTableAndItsVersionAreLibraryFieldsTheReaderTakes() {
        var open = book(code: "ascii-na")
        open.brailleTable = "en-ueb-g1.ctb"
        var reread = open
        reread.brailleTable = "mac:fr-bfu-g2.ctb"
        reread.brailleTableVersion = "3.34.0"
        XCTAssertNotEqual(reread.libraryFields, open.libraryFields)

        var versionOnly = open
        versionOnly.brailleTableVersion = "3.34.0"
        XCTAssertNotEqual(versionOnly.libraryFields, open.libraryFields)

        var reader = open
        reader.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 9)
        reader.libraryFields = reread.libraryFields
        XCTAssertEqual(reader.brailleTable, "mac:fr-bfu-g2.ctb")
        XCTAssertEqual(reader.brailleTableVersion, "3.34.0")
        XCTAssertEqual(reader.readingPosition?.characterOffset, 9, "the reader keeps its own place")
    }
}
