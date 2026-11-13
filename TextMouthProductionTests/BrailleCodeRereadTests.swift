import XCTest
@testable import TextMouth

/// A braille book read again with another braille code, the table its cells
/// are translated to print by (`Book.brailleTable`, FMT21), as Book
/// Information asks for it: through the one re-read an encoding and braille
/// file characters use too (`TextEncodingRereadTests`,
/// `BrailleFileCodeRereadTests`). The text, the row, and the record after it;
/// the summary that brings a lagging row to the record's table; the debug
/// log's line; and every refusal, after which nothing has changed.
///
/// The sample is a contracted (grade 2) UEB file, which the uncontracted
/// (grade 1) table reads as other words. Every import binds the table it
/// names, never the user's settings, and every book is a package in the
/// hosted test root's library, whose index is put back after each test
/// (`CloudMaintenanceTestCase`).
@MainActor
final class BrailleCodeRereadTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 2 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/grade2-short.brf"
    /// The uncontracted table the sample is imported with here, wrongly.
    private static let grade1 = "en-ueb-g1.ctb"
    /// The table the sample is written in: contracted UEB, with which it is
    /// read again.
    private static let grade2 = "en-ueb-g2.ctb"

    /// The bundled table with the stored value `id`.
    private func table(_ id: String) throws -> BrailleTable {
        try XCTUnwrap(BrailleTableCatalog.table(withID: id), id)
    }

    /// The sample imported with the table `tableID` as the Braille setting's,
    /// titled `title` with a suffix of its own, in its row and its record, so
    /// the debug log's lines that name it are this test's.
    private func importedSample(title: String, tableID: String = BrailleCodeRereadTests.grade1) throws -> Book {
        let copy = try copyOfFormatSample(Self.sample)
        var book = try BraillePreferences.$tableForImports.withValue(tableID) {
            try BraillePreferences.$fileCodeForImports.withValue("ascii-na") {
                try importedForTest(copy).book
            }
        }
        book.title = "\(title) \(UUID().uuidString.prefix(8))"
        try book.saveBookInfoThrowing()
        return book
    }

    /// The bytes of the files a re-read writes in `book`'s package: its
    /// content.md, contentIndex.json, and bookInfo.json, in that order.
    private func textIndexAndRecord(of book: Book) throws -> [Data] {
        try [
            MarkdownCacheService.cacheURL(for: book),
            TextMouthPaths.contentIndexPath(in: book.tmbDirectory),
            TextMouthPaths.bookInfoPath(in: book.tmbDirectory),
        ].map { try Data(contentsOf: $0) }
    }

    /// The sample's file read as North American Braille ASCII with the table
    /// `tableID`, with pages, as a generation writes content.md: its UTF-8.
    private func reading(of book: Book, tableID: String) throws -> Data {
        Data(try BrailleBookReader.markdown(
            of: book.bookFileURL, table: tableID, fileCode: "ascii-na", includesPages: true
        ).utf8)
    }

    /// What `model` makes of reading `book` again with `table`, with every
    /// announcement it makes on the way.
    private func readAgain(
        _ book: Book, with table: BrailleTable, in model: LibraryViewModel
    ) async -> (outcome: OperationOutcome, announced: [String]) {
        var announced: [String] = []
        let previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in announced.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previous }
        let outcome = await model.readTextAgain(bookID: book.id, choosing: .brailleTable(table))
        return (outcome, announced)
    }

    // MARK: - Reading Again

    /// A contracted file imported with the uncontracted table reads as other
    /// words; read again with the contracted table it is the right reading:
    /// its content.md is that reading, its row and record hold the table,
    /// VoiceOver hears the code's name, and the debug log says it in the
    /// table's line, never in an encoding's or a file code's.
    func testAnotherTableReadsTheBookAgainAndRecordsIt() async throws {
        let book = try importedSample(title: "Ledger", tableID: Self.grade1)
        let expected = try reading(of: book, tableID: Self.grade2)
        XCTAssertEqual(book.brailleTable, Self.grade1)
        XCTAssertNotEqual(
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)), expected,
            "the uncontracted table must read the file otherwise, or this proves nothing"
        )
        let model = makeModel(with: [book])

        let (outcome, announced) = await readAgain(book, with: try table(Self.grade2), in: model)

        let said = "“\(book.title)” is now read as Unified English Braille, contracted (Grade 2)."
        XCTAssertEqual(outcome, .success(said))
        XCTAssertEqual(announced, [said])
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)), expected)
        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.brailleTable, Self.grade2)
        XCTAssertNil(row.brailleTableVersion, "a bundled table records no liblouis version")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTable, Self.grade2)
        XCTAssertEqual(
            row.textCacheFingerprint?.cache.digest, FingerprintHasher.md5.digestOfData(expected),
            "the row's analysis is not the new text's"
        )
        XCTAssertEqual(logLineCount("BRAILLE_TABLE_CHANGED: \(book.title): read again with \(Self.grade2)"), 1)
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(book.title)"), 0, "a table re-read was logged as a file code's")
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(book.title)"), 0, "a table re-read was logged as an encoding's")
    }

    /// A reading that fails, here with a Mac table that is not there, changes
    /// nothing and says why in the re-read's own words: the text, the index,
    /// and the record are the bytes they were, the row keeps its table, and
    /// no copy of the text is kept.
    func testATableThatFailsLeavesTheBookAsItWas() async throws {
        let book = try importedSample(title: "Almanac")
        let model = makeModel(with: [book])
        let before = try textIndexAndRecord(of: book)
        let gone = BrailleTable(
            id: "mac:no-such-table-for-this-test.ctb", displayName: "Gone", indexName: nil, language: "en", system: "",
            contraction: .unstated, grade: nil
        )

        let (outcome, announced) = await readAgain(book, with: gone, in: model)

        let refusal = try XCTUnwrap(outcome.failureMessage, "\(outcome)")
        XCTAssertTrue(
            refusal.hasPrefix("TextMouth couldn't read “\(book.title)” again, so it left the book as it was"), refusal
        )
        XCTAssertEqual(announced, [], "the sheet says a refusal, not the library")
        XCTAssertEqual(try textIndexAndRecord(of: book), before)
        XCTAssertEqual(model.bookByID(book.id)?.brailleTable, Self.grade1)
        XCTAssertEqual(logLineCount("BRAILLE_TABLE_CHANGED: \(book.title)"), 0)
    }

    // MARK: - Who Is Offered the Choice

    /// Any braille book is offered the choice of its braille code, a PEF
    /// included, whose cells are translated by a table too; a feed's item and
    /// a book of another format are not, and a refused choice changes
    /// nothing.
    func testOnlyABrailleBookThatIsNotAFeedItemIsOffered() async throws {
        let brf = try importedSample(title: "Primer")
        let pef = Book(title: "Atlas", format: .braille, filePath: "/nowhere/Atlas.pef", md5Hash: "braille-code-pef")
        var feed = brf
        feed.feedLink = FeedBookLink(feedID: UUID(), itemID: "braille-code-feed-item")
        let text = Book(title: "Gazette", format: .txt, filePath: "/nowhere/Gazette.txt", md5Hash: "braille-code-text")
        XCTAssertTrue(brf.offersBrailleTableChoice)
        XCTAssertTrue(pef.offersBrailleTableChoice, "a PEF is translated by a table too")
        XCTAssertFalse(feed.offersBrailleTableChoice)
        XCTAssertFalse(text.offersBrailleTableChoice)

        let model = makeModel(with: [brf, text])
        let before = try textIndexAndRecord(of: brf)
        let (outcome, _) = await readAgain(text, with: try table(Self.grade2), in: model)

        XCTAssertEqual(outcome, .failure("TextMouth couldn't read “Gazette” again, so it left the book as it was."))
        XCTAssertEqual(try textIndexAndRecord(of: brf), before)
        XCTAssertEqual(model.bookByID(text.id), text)
    }

    /// The choice's tag begins the debug log's line, its own and the one
    /// that names a file it could not put back.
    func testTheChoiceHasItsOwnLogTag() throws {
        XCTAssertEqual(TextRereadChoice.brailleTable(try table(Self.grade2)).logTag, "BRAILLE_TABLE_CHANGED")
        XCTAssertEqual(
            LibraryViewModel.brailleTableLogLine(title: "Ledger", table: try table(Self.grade1), keptCopy: nil),
            "BRAILLE_TABLE_CHANGED: Ledger: read again with en-ueb-g1.ctb"
        )
    }

    // MARK: - A Row That Lags Behind the Record

    /// The summary of a commit carries the table and its version to the row,
    /// and the summary of a recovered analysis takes the record's table: a row
    /// a stop left behind a re-read, still holding the old table, catches up;
    /// a row without a table takes the record's; and a summary of a book with
    /// no table leaves the row's alone.
    func testASummaryBringsALaggingRowToTheRecordsTable() {
        func book(table: String?, version: String? = nil) -> Book {
            var book = Book(
                title: "Ledger", format: .braille, filePath: "/nowhere/Ledger.brf", md5Hash: "braille-code-summary",
                brailleTable: table, brailleTableVersion: version
            )
            book.tmbDirectoryName = "Ledger.tmb"
            return book
        }
        let row = book(table: Self.grade1)
        // The record of the same book, after a re-read with a Mac table.
        let record = book(table: "mac:fr-bfu-g2.ctb", version: "3.34.0").withID(row.id)

        var recovered = row
        ContentAnalysisSummary(recovered: row, record: record).apply(to: &recovered)
        XCTAssertEqual(recovered.brailleTable, "mac:fr-bfu-g2.ctb")
        XCTAssertEqual(recovered.brailleTableVersion, "3.34.0")

        var committed = row
        ContentAnalysisSummary(committed: record).apply(to: &committed)
        XCTAssertEqual(committed.brailleTable, "mac:fr-bfu-g2.ctb")
        XCTAssertEqual(committed.brailleTableVersion, "3.34.0")

        // A row that lost its table takes the record's of its own book, and
        // never the record of another.
        var lost = book(table: nil)
        ContentAnalysisSummary(recovered: lost, record: record).apply(to: &lost)
        XCTAssertNil(lost.brailleTable, "another book's record gives a row no table")
        let ownRecord = record.withID(lost.id)
        ContentAnalysisSummary(recovered: lost, record: ownRecord).apply(to: &lost)
        XCTAssertEqual(lost.brailleTable, "mac:fr-bfu-g2.ctb")

        var untabled = row
        ContentAnalysisSummary(committed: book(table: nil)).apply(to: &untabled)
        XCTAssertEqual(untabled.brailleTable, Self.grade1, "a summary that names no table leaves the row's")
    }
}
