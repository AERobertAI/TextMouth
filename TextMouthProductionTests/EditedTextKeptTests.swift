import XCTest
@testable import TextMouth

/// The text a user changes with Edit Text is never overwritten by an
/// automatic re-read of the book's file (B12). Taking an edit records it
/// on the book (`Book.editedText`: the digest of the content.md the edit
/// left); a cache-format bump, the reader's rebuild of an outdated cache,
/// and every other automatic generation then leave that content.md alone
/// and log one TEXT_EDIT_KEPT line, while Redo Text Extraction, which the
/// user asks for, still reads the book's file and drops the record. The
/// record holds only while content.md is that edit.
final class EditedTextKeptTests: CloudMaintenanceTestCase {
    /// The source every book here is made from: two chapters.
    private static let source = "# Harbour\n\nThe pilots meet the ships at dawn.\n\n"
        + "# Channel\n\nBuoys mark the channel. The tide sets across it twice a day.\n"

    /// A cache format older than the current one, as a library holds after
    /// a cache-format bump.
    private static let olderVersion = "3.0.3"

    // MARK: - Taking an Edit Records It

    /// An edit taken records `editedText` with content.md's digest and the
    /// time, in the record the package holds and in the book the check
    /// returns (the library row's source), and in `BookInfo` read back.
    func testAnEditTakenRecordsTheDigestOfTheTextItLeft() throws {
        let before = Date().addingTimeInterval(-1)
        let fixture = try makeEditedBook(title: "Recorded \(UUID().uuidString)")
        let after = Date().addingTimeInterval(1)

        let digest = try FileImportService.md5Hash(of: MarkdownCacheService.cacheURL(for: fixture.book))
        let recorded = try XCTUnwrap(fixture.book.editedText, "the book returned records no edit")
        XCTAssertEqual(recorded.cacheDigest, digest)
        XCTAssertTrue(recorded.takenAt >= before && recorded.takenAt <= after, "the edit was dated \(recorded.takenAt)")
        // The record the package holds says the same, and so does the
        // analysis fingerprint it left beside it.
        let record = try BookInfo.load(from: fixture.book.tmbDirectory)
        assertSameEdit(record.state.editedText, recorded)
        XCTAssertEqual(record.state.textCacheFingerprint?.cache.digest, digest)
        assertSameEdit(Book(
            record: record,
            filePath: fixture.book.filePath,
            folderPath: fixture.book.folderPath,
            tmbDirectoryName: fixture.book.tmbDirectoryName
        ).editedText, recorded)
    }

    // MARK: - Automatic Re-reads Keep the Edit

    /// A cache-format bump re-reads every book, but not this one: content.md
    /// stays byte for byte the edit, the debug log gets the one TEXT_EDIT_KEPT
    /// line and nothing else about the book, the book is stamped current
    /// with its edit still recorded, and a second pass picks nothing.
    @MainActor
    func testAVersionBumpKeepsTheEditAndTheNextPassPicksNothing() async throws {
        let title = "Bumped \(UUID().uuidString)"
        let fixture = try makeEditedBook(title: title)
        let older = try stampedAsOlder(fixture.book)
        let model = makeModel(with: [older])
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([older], access: .live).map(\.id), [older.id])

        await runCacheBatch(on: model)

        let cache = MarkdownCacheService.cacheURL(for: older)
        XCTAssertEqual(try Data(contentsOf: cache), fixture.edited, "the edit was read over")
        // The edit's own TEXT_EDIT_ADOPTED line came first; nothing else.
        let lines = debugLogLines(containing: title).filter { !$0.contains("TEXT_EDIT_ADOPTED") }
        XCTAssertEqual(lines.count, 1, "the log says more than one thing about the book: \(lines)")
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 1)
        let row = try XCTUnwrap(model.bookByID(older.id))
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(row.editedText, fixture.book.editedText)
        let record = try BookInfo.load(from: older.tmbDirectory)
        XCTAssertEqual(record.state.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        assertSameEdit(record.state.editedText, fixture.book.editedText)
        // The edit is indexed as it is, fingerprinted as content.md is.
        let headings = try XCTUnwrap(record.contentIndex).allHeadings.map(\.text)
        XCTAssertFalse(headings.isEmpty)
        XCTAssertEqual(headings, try MarkdownCacheService.loadFromCache(for: older).contentIndex.allHeadings.map(\.text))
        XCTAssertEqual(record.state.textCacheFingerprint?.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(keptCopies(of: older), [], "a copy was kept of text nothing replaced")
        // The next launch has nothing to do for it.
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
        await runCacheBatch(on: model)
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 1, "the second pass visited the book again")
        XCTAssertEqual(try Data(contentsOf: cache), fixture.edited)
    }

    /// The same edit beside a source that changed meanwhile is kept too:
    /// the source's new fingerprint is recorded, so the pass is not repeated.
    @MainActor
    func testAChangedSourceDoesNotReplaceTheEditEither() async throws {
        let title = "Changed Source \(UUID().uuidString)"
        let fixture = try makeEditedBook(title: title)
        let older = try stampedAsOlder(fixture.book)
        try (Self.source + "\n# Moorings\n\nChains rust in the shallows.\n")
            .write(to: older.bookFileURL, atomically: true, encoding: .utf8)
        let model = makeModel(with: [older])

        await runCacheBatch(on: model)

        let cache = MarkdownCacheService.cacheURL(for: older)
        XCTAssertEqual(try Data(contentsOf: cache), fixture.edited, "the edit was read over")
        let record = try BookInfo.load(from: older.tmbDirectory)
        XCTAssertEqual(record.state.textCacheFingerprint?.source.digest, try FileImportService.md5Hash(of: older.bookFileURL))
        let row = try XCTUnwrap(model.bookByID(older.id))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 1)
    }

    /// Generating the cache directly, which every automatic path does,
    /// throws `EditedTextKept` before reading the source, with the
    /// sentence the reader shows, and leaves the book unchanged.
    func testAGenerationThrowsEditedTextKeptAndChangesNothing() throws {
        let title = "Throws \(UUID().uuidString)"
        let fixture = try makeEditedBook(title: title)
        var older = try stampedAsOlder(fixture.book)
        let before = older

        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &older)) { error in
            XCTAssertTrue(error is EditedTextKept, "\(error)")
            XCTAssertEqual(error.localizedDescription, BookTextEditWording.keptOnReRead(bookTitle: title))
        }

        XCTAssertEqual(older, before)
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: older)), fixture.edited)
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 1)
    }

    /// The reader's rebuild of an outdated cache meets the edit, falls back
    /// to content.md as it is, shows the edited text, and writes nothing.
    func testTheReadersRebuildFallsBackToTheEditedText() throws {
        let title = "Reader \(UUID().uuidString)"
        let fixture = try makeEditedBook(title: title)
        let older = try stampedAsOlder(fixture.book)

        let result = try BookContentAnalysisService.load(book: older, regenerateTextCache: true)

        XCTAssertTrue(result.content.chapters.contains { $0.text.contains("every few hours") }, "the reader did not show the edit")
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: older)), fixture.edited)
        XCTAssertEqual(keptCopies(of: older), [])
        XCTAssertEqual(try BookInfo.load(from: older.tmbDirectory).state.cacheFormatVersion, Self.olderVersion, "the load wrote the record")
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 1)
    }

    // MARK: - Redo Text Extraction Replaces It

    /// Redo Text Extraction reads the book's file over the edit: content.md
    /// is the source's text again, the record of the edit is gone from the
    /// row and the package, and the text it replaced is kept beside
    /// content.md.
    @MainActor
    func testRedoTextExtractionReplacesTheEditAndDropsTheRecord() async throws {
        let title = "Redo \(UUID().uuidString)"
        let fixture = try makeEditedBook(title: title)
        let model = makeModel(with: [fixture.book])
        let finished = expectation(description: "Redo Text Extraction finished")
        // The pass reports once; a second report must not abort the host.
        finished.assertForOverFulfill = false

        XCTAssertTrue(model.redoAllTextExtraction(access: .live) { _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 20)

        let cache = MarkdownCacheService.cacheURL(for: fixture.book)
        XCTAssertEqual(try Data(contentsOf: cache), fixture.extracted, "the book's file was not read again")
        XCTAssertNil(model.bookByID(fixture.book.id)?.editedText)
        let record = try BookInfo.load(from: fixture.book.tmbDirectory)
        XCTAssertNil(record.state.editedText)
        XCTAssertEqual(record.state.textCacheFingerprint?.cache.digest, try FileImportService.md5Hash(of: cache))
        let copies = keptCopies(of: fixture.book)
        XCTAssertEqual(copies.count, 1, "the replaced edit was not kept")
        XCTAssertEqual(copies.first.flatMap { try? Data(contentsOf: $0) }, fixture.edited)
        // The replaced edit is logged as kept, by the copy's own line and
        // not as an automatic re-read's.
        XCTAssertEqual(logLineCount(Self.keptLine(title)), 0)
        XCTAssertEqual(logLineCount("TEXT_EDIT_KEPT: \(title): content.md held the text taken from Edit Text"), 1)
        // The rebuilt book is current, so the next automatic pass picks nothing.
        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
    }

    // MARK: - The Record Holds Only While It Matches

    /// A record whose digest content.md no longer has does not stop a
    /// rebuild: content.md changed by other means since the edit.
    func testARecordThatNoLongerMatchesDoesNotStopARebuild() throws {
        let fixture = try makeEditedBook(title: "Stale Record \(UUID().uuidString)")
        let cache = MarkdownCacheService.cacheURL(for: fixture.book)
        try Data((String(decoding: fixture.edited, as: UTF8.self) + "\nAn unrelated later change.\n").utf8).write(to: cache)
        var older = try stampedAsOlder(fixture.book)

        let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &older)

        XCTAssertNotNil(generated)
        XCTAssertEqual(try Data(contentsOf: cache), fixture.extracted, "the rebuild did not read the book's file")
        XCTAssertNil(older.editedText, "the record outlived the text it described")
    }

    /// The analysis of an index drops the record when the index's content.md
    /// digest is another than the edit's, keeps it when it is the same, and
    /// keeps it when the index says nothing about content.md.
    func testAnAnalysisKeepsTheRecordOnlyWhileContentMatchesIt() {
        let edit = EditedText(cacheDigest: "edit-digest", takenAt: Date(timeIntervalSince1970: 1_700_000_000))
        var book = Book(title: "Analyzed", format: .txt, filePath: "/tmp/analyzed.txt", md5Hash: "m", folderPath: "")
        book.editedText = edit
        var index = BookContentIndex.build(fromChapters: [Chapter(title: "One", text: "one two three")], format: .txt)

        var unfingerprinted = book
        unfingerprinted.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(unfingerprinted.editedText, edit, "an index without fingerprints says nothing about content.md")

        index.textCacheFingerprint = Self.fingerprint(cacheDigest: "edit-digest")
        var same = book
        same.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(same.editedText, edit)

        index.textCacheFingerprint = Self.fingerprint(cacheDigest: "source-text-digest")
        var replaced = book
        replaced.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertNil(replaced.editedText, "content.md is not the edit any more")
        XCTAssertNil(replaced.contentAnalysisFields.editedText)
    }

    // MARK: - Reading and Writing the Record

    /// Rows and records written before the field decode with none; a row,
    /// a state, and a record holding one round-trip through JSON; an
    /// unreadable one counts as none instead of failing the book.
    func testOlderRowsAndRecordsDecodeWithNoEditAndANewOneRoundTrips() throws {
        let edit = EditedText(cacheDigest: "abc123", takenAt: Date(timeIntervalSince1970: 1_700_000_000))
        var book = Book(title: "Round Trip", format: .txt, filePath: "/tmp/round-trip.txt", md5Hash: "m", folderPath: "")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // A book with no edit writes none, and reads back with none.
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        XCTAssertNil(row["editedText"])
        XCTAssertNil(try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row)).editedText)

        // A book with one round-trips: the row, and the record's state.
        book.editedText = edit
        XCTAssertEqual(try decoder.decode(Book.self, from: encoder.encode(book)).editedText, edit)
        let info = try decoder.decode(BookInfo.self, from: encoder.encode(book.makeBookInfo()))
        XCTAssertEqual(info.state.editedText, edit)
        XCTAssertEqual(info.state.contentAnalysisFields.editedText, edit)

        // A damaged one counts as none, and the rest of the book still loads.
        row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        row["editedText"] = "garbage"
        let damaged = try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(damaged.editedText)
        XCTAssertEqual(damaged.title, "Round Trip")
    }

    // MARK: - The Words

    /// The Edit Text explanation and the sentence for a kept edit, exactly:
    /// the explanation names the page marker after the chapter sentence.
    func testTheExplanationAndTheKeptSentenceAreExact() {
        XCTAssertEqual(
            BookTextEditWording.explanation,
            "TextMouth opens the book's text in your text editor, as a Markdown file. "
                + "Each line beginning with <!-- chapter: starts a chapter; keep those lines. "
                + "Each <!-- page: … --> marks where a page begins. "
                + "When you save, TextMouth reads your changes and updates the book, keeping your place as near as it can. "
                + "This explanation appears only once."
        )
        XCTAssertEqual(
            BookTextEditWording.keptOnReRead(bookTitle: "Harbour Pilots"),
            "TextMouth kept the text you changed in Harbour Pilots. Choose Redo Text Extraction to read the book's file again."
        )
        XCTAssertEqual(
            EditedTextKept(bookTitle: "Harbour Pilots").errorDescription,
            BookTextEditWording.keptOnReRead(bookTitle: "Harbour Pilots")
        )
    }

    // MARK: - Helpers

    /// A book whose text the user edited: its packaged source and extracted
    /// text, the edit's bytes, and the book as its record holds it once the
    /// edit was taken.
    private struct EditedBook {
        /// The book as the check that took the edit returned it.
        let book: Book
        /// content.md as the book's source extracts to.
        let extracted: Data
        /// content.md as the edit left it.
        let edited: Data
    }

    /// Why a fixture's edit could not be made.
    private enum FixtureError: Error {
        case editNotTaken
    }

    /// A packaged book of `Self.source`, cached and committed, whose
    /// content.md is then edited ("twice a day" becomes "every few hours")
    /// and the edit taken as the book's text, as an Edit Text session takes
    /// one (`BookTextEditSessions.check`).
    private func makeEditedBook(title: String) throws -> EditedBook {
        let committed = try commitCache(of: makePackagedBook(title: title, text: Self.source))
        let cache = MarkdownCacheService.cacheURL(for: committed)
        let extracted = try Data(contentsOf: cache)
        let edited = String(decoding: extracted, as: UTF8.self)
            .replacingOccurrences(of: "twice a day", with: "every few hours")
        XCTAssertNotEqual(Data(edited.utf8), extracted, "the edit changed nothing")

        let baseline = try BookTextEditSessions.baseline(of: committed, access: .live).get()
        try edited.write(to: cache, atomically: true, encoding: .utf8)
        let readingTexts = ReadingTextCache(folder: try makeSandboxDirectory("Edited Text Reading Texts"))
        let checked = BookTextEditSessions.check(
            committed, against: baseline, access: .live, readingTexts: readingTexts
        )
        guard case .adopted(let edit) = checked.found else { throw FixtureError.editNotTaken }
        return EditedBook(book: edit.committed, extracted: extracted, edited: Data(edited.utf8))
    }

    /// `book` as a library holds it after a cache-format bump: its row and
    /// its package record both stamped with a cache format older than the
    /// current one, everything else (the edit's record included) as it was.
    private func stampedAsOlder(_ book: Book) throws -> Book {
        var older = book
        older.cacheFormatVersion = Self.olderVersion
        let index = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        try older.saveBookInfoThrowing(contentIndex: index)
        LibraryPersistenceService.flushPendingSave()
        return older
    }

    /// Asserts that `stored`, an edit read back from a file, is `expected`:
    /// the same digest, and the same time to the second, which is how the
    /// files store dates (ISO 8601).
    private func assertSameEdit(
        _ stored: EditedText?, _ expected: EditedText?, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(stored?.cacheDigest, expected?.cacheDigest, file: file, line: line)
        XCTAssertEqual(
            stored.map { $0.takenAt.timeIntervalSince1970.rounded(.down) },
            expected.map { $0.takenAt.timeIntervalSince1970.rounded(.down) },
            file: file,
            line: line
        )
    }

    /// The copies of the user's text kept beside `book`'s content.md.
    private func keptCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(
            of: MarkdownCacheService.cacheURL(for: book),
            marker: TextMouthPaths.keptTextCopyMarker
        )
    }

    /// The start of the log line an automatic re-read writes for `title`.
    private static func keptLine(_ title: String) -> String {
        "TEXT_EDIT_KEPT: \(title): an automatic re-read kept the text changed with Edit Text; "
            + "Redo Text Extraction reads the book's file again"
    }

    /// A text cache fingerprint whose content.md digest is `cacheDigest`.
    private static func fingerprint(cacheDigest: String) -> TextCacheFingerprint {
        TextCacheFingerprint(
            source: FileFingerprint(stamp: FileStamp(byteCount: 10, modificationTimeNanoseconds: 20), digest: "source"),
            cache: FileFingerprint(stamp: FileStamp(byteCount: 30, modificationTimeNanoseconds: 40), digest: cacheDigest)
        )
    }
}
