import XCTest
@testable import TextMouth

/// A content analysis can run for minutes on a copy of its book taken when it
/// started. Its result must change only the fields an analysis owns, and
/// must land on the latest state of the book, never on that old copy
/// (TODO S05).
final class ContentAnalysisMergeTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Folders this test created in the test root's library, removed after
    /// it with every package inside.
    private var createdDirectories: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdDirectories = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        // Restoring flushes pending saves, so none lands in a removed folder.
        sandbox?.restore()
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - The Fields an Analysis Owns

    /// Setting a book's analysis fields changes exactly the five fields an
    /// analysis owns. Every other field (reading state, bookmarks, settings,
    /// metadata, and where the package is) keeps its value, so neither a
    /// package record nor a library row can lose user state to an analysis.
    func testSettingAnalysisFieldsChangesNothingElse() {
        let user = Self.bookWithEveryFieldSet(seed: 1)
        let analysis = Self.bookWithEveryFieldSet(seed: 2)
        XCTAssertEqual(
            Self.fieldsThatDiffer(user, analysis).count,
            Mirror(reflecting: user).children.count,
            "the fixtures must differ in every field, or this test proves nothing about it"
        )

        var changed = user
        changed.contentAnalysisFields = analysis.contentAnalysisFields

        XCTAssertEqual(changed.contentAnalysisFields, analysis.contentAnalysisFields)
        XCTAssertEqual(
            Set(Self.fieldsThatDiffer(user, changed)),
            ["totalWordCount", "totalCharacterCount", "audioDuration", "contentIndexVersion", "cacheFormatVersion"]
        )
    }

    /// Applying an analysis records the statistics and version of its index
    /// and the cache version the analysis vouches for. One that vouches for
    /// no cache keeps the book's cache version, as a bare summary does.
    func testApplyingAnAnalysisRecordsItsIndexAndTheCacheItVouchesFor() {
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )

        var vouched = Self.bookWithEveryFieldSet(seed: 3)
        vouched.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(vouched.contentAnalysisFields, Book.ContentAnalysisFields(
            totalWordCount: 3,
            totalCharacterCount: index.totalCharacterCount,
            audioDuration: index.totalAudioDuration,
            contentIndexVersion: index.version,
            cacheFormatVersion: "9.9.9"
        ))

        var silent = Self.bookWithEveryFieldSet(seed: 3)
        silent.applyContentAnalysis(index, cacheFormatVersion: nil)
        XCTAssertEqual(silent.cacheFormatVersion, "cache-3")
        XCTAssertEqual(silent.totalWordCount, 3)

        var summarized = Self.bookWithEveryFieldSet(seed: 3)
        summarized.applyContentIndexSummary(index)
        XCTAssertEqual(summarized.contentAnalysisFields, silent.contentAnalysisFields)
    }

    // MARK: - Saves Without an Index

    /// A library row hears of a committed analysis a moment after the
    /// package does, so a save of the row in between carries the counts and
    /// versions from before the analysis. That save still records the
    /// row's newer reading state, but keeps the stored index together with
    /// the analysis fields measured with it.
    func testSaveWithoutAnIndexKeepsTheStoredAnalysis() throws {
        let row = try makePackage(title: "Lagging Row")
        let index = Self.index(of: "one two three")
        try LibraryPersistenceService.saveContentAnalysis(for: row, index: index, cacheFormatVersion: "9.9.9")

        var lagging = row
        lagging.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 8)
        XCTAssertNil(lagging.totalWordCount, "the row has not heard of the analysis yet")
        LibraryPersistenceService.saveBookInfo(for: lagging)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 8)
        XCTAssertEqual(record.contentIndex, index)
        XCTAssertEqual(record.state.totalWordCount, 3)
        XCTAssertEqual(record.state.contentIndexVersion, index.version)
        XCTAssertEqual(record.state.cacheFormatVersion, "9.9.9")
    }

    /// A save that carries an index records that index with the saved
    /// book's own analysis fields, which describe it.
    func testSaveWithAnIndexRecordsItsOwnAnalysis() throws {
        let book = try makePackage(title: "Indexed Save")
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: Self.index(of: "one two three"), cacheFormatVersion: "9.9.9"
        )
        let newer = Self.index(of: "one two three four five")
        var analyzed = book
        analyzed.applyContentAnalysis(newer, cacheFormatVersion: "9.9.10")

        LibraryPersistenceService.saveBookInfo(for: analyzed, contentIndex: newer)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.contentIndex, newer)
        XCTAssertEqual(record.state.totalWordCount, 5)
        XCTAssertEqual(record.state.cacheFormatVersion, "9.9.10")
    }

    /// Over a record with no index there is no analysis to keep, so a save
    /// without an index records the book's own counts and versions.
    func testSaveOverAnUnindexedRecordRecordsTheBooksOwnFields() throws {
        var book = try makePackage(title: "Never Indexed")
        book.totalWordCount = 12
        book.totalCharacterCount = 60
        book.cacheFormatVersion = "9.9.9"

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNil(record.contentIndex)
        XCTAssertEqual(record.state.contentAnalysisFields, book.contentAnalysisFields)
    }

    // MARK: - Revisions

    /// Every write of a package record stores one more than the record it
    /// replaces, with an index or without one. A record without a revision,
    /// as earlier versions wrote, counts as 0.
    func testEveryRecordWriteStoresTheNextRevision() throws {
        let book = try makePackage(title: "Counted Writes", writingRecord: false)
        try book.makeBookInfo().save(to: book.tmbDirectory)
        XCTAssertNil(try revision(of: book), "a record from an earlier version has no revision")

        try book.saveBookInfoThrowing()
        XCTAssertEqual(try revision(of: book), 1)
        try book.saveBookInfoThrowing(contentIndex: Self.index(of: "one two"))
        XCTAssertEqual(try revision(of: book), 2)
        try book.saveBookInfoThrowing()
        XCTAssertEqual(try revision(of: book), 3)
        XCTAssertEqual(
            try BookInfo.load(from: book.tmbDirectory).contentIndex,
            Self.index(of: "one two"),
            "a save without an index keeps the stored one"
        )
    }

    /// A write numbers from the higher of the stored revision and the
    /// floor, so a record that lost its revision (or was never written)
    /// still gets one above every revision written before it.
    func testRevisionFollowsTheHigherOfTheStoredRevisionAndTheFloor() {
        let book = Self.bookWithEveryFieldSet(seed: 4)
        var stored = book.makeBookInfo()
        stored.state.revision = 9

        XCTAssertEqual(book.bookInfo(replacing: nil, contentIndex: nil).state.revision, 1)
        XCTAssertEqual(book.bookInfo(replacing: nil, contentIndex: nil, revisionFloor: 7).state.revision, 8)
        XCTAssertEqual(book.bookInfo(replacing: stored, contentIndex: nil, revisionFloor: 7).state.revision, 10)
        XCTAssertEqual(book.bookInfo(replacing: stored, contentIndex: nil, revisionFloor: 12).state.revision, 13)
    }

    /// A revision no record can have (negative, fractional, too large, or
    /// text) is dropped instead of failing the record, whose other fields
    /// still load. A valid one loads unchanged.
    func testUnusableRevisionsDecodeAsNone() throws {
        for value in ["-3", "1.5", "1e30", #""many""#] {
            let state = try Self.decodeState(#""manualSortOrder": 4, "revision": \#(value)"#)
            XCTAssertNil(state.revision, value)
            XCTAssertEqual(state.manualSortOrder, 4, value)
        }
        XCTAssertEqual(try Self.decodeState(#""revision": 41"#).revision, 41)
    }

    /// The revision after the largest integer is that integer, so a
    /// hand-edited record cannot make the next write overflow.
    func testRevisionStopsAtTheLargestInteger() {
        XCTAssertEqual(BookState.revision(after: 0), 1)
        XCTAssertEqual(BookState.revision(after: 41), 42)
        XCTAssertEqual(BookState.revision(after: .max), .max)
    }

    /// Each write through the metadata queue (a debounced save, the quit
    /// flush, and an analysis result) raises the book's revision by one.
    func testEveryMetadataQueueWriteRaisesTheRevision() throws {
        let book = try makePackage(title: "Queued Revisions")
        XCTAssertEqual(try revision(of: book), 1, "the import's own write")

        LibraryPersistenceService.saveBookInfo(for: book)
        waitPastLibrarySaveDebounce()
        XCTAssertEqual(try revision(of: book), 2, "the debounced save")

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try revision(of: book), 3, "the quit flush")

        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: Self.index(of: "one two three"), cacheFormatVersion: nil
        )
        XCTAssertEqual(try revision(of: book), 4, "the analysis result")
    }

    /// The queue numbers its first write of a book from the revision on
    /// disk, as it does after a restart, when it remembers nothing.
    func testMetadataQueueContinuesFromTheRevisionOnDisk() throws {
        let book = try makePackage(title: "Restarted", writingRecord: false)
        var record = book.makeBookInfo()
        record.state.revision = 41
        try record.save(to: book.tmbDirectory)

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try revision(of: book), 42)
    }

    /// A record replaced without a revision (as an earlier version, or a
    /// rewrite of every package, leaves it) does not send the book's
    /// revisions back to 1: the queue continues above its own last write.
    func testMetadataQueueRevisionsNeverFallWhenARecordLosesItsOwn() throws {
        let book = try makePackage(title: "Lost Revision")
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        let written = try XCTUnwrap(try revision(of: book))
        try book.makeBookInfo().save(to: book.tmbDirectory)
        XCTAssertNil(try revision(of: book))

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try revision(of: book), written + 1)
    }

    // MARK: - Fixtures

    /// Creates a real package in a folder of its own, as an import leaves
    /// it: a Markdown source whose unique words give it a unique hash and,
    /// unless `writingRecord` is false, its bookInfo.json. The folder and
    /// everything in it are removed after the test.
    private func makePackage(title: String, writingRecord: Bool = true) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "Analysis Merge \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true))
        let packageName = "AnalysisMerge-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("book.md")
        try "# Opening\n\nThe words of \(title), \(UUID().uuidString).".write(
            to: source, atomically: true, encoding: .utf8
        )
        let book = Book(
            title: title,
            author: "Merge Fixture",
            format: .markdown,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder,
            tmbDirectoryName: packageName,
            cacheFormatVersion: "3.0.3"
        )
        if writingRecord {
            try book.saveBookInfoThrowing()
        }
        return book
    }

    /// The revision of the bookInfo.json in `book`'s package.
    private func revision(of book: Book) throws -> Int? {
        try BookInfo.load(from: book.tmbDirectory).state.revision
    }

    /// An index of one chapter holding `text`.
    private static func index(of text: String) -> BookContentIndex {
        BookContentIndex.build(fromChapters: [Chapter(title: "Chapter", text: text)], format: .markdown)
    }

    /// Decodes a saved book state made of `fields` added to a minimal one,
    /// as someone editing bookInfo.json by hand could leave it.
    private static func decodeState(_ fields: String) throws -> BookState {
        let json = #"{"isNew": false, "tmbDirectoryName": "saved.tmb", \#(fields)}"#
        return try JSONDecoder().decode(BookState.self, from: Data(json.utf8))
    }

    /// A book with every field set, each to a value derived from `seed`, so
    /// books made from two different seeds differ in every field.
    private static func bookWithEveryFieldSet(seed: Int) -> Book {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seed * 1_000))
        return Book(
            id: UUID(),
            title: "Title \(seed)",
            author: "Author \(seed)",
            format: seed.isMultiple(of: 2) ? .epub : .txt,
            filePath: "/library/book-\(seed).txt",
            md5Hash: "hash-\(seed)",
            folderPath: "Folder \(seed)",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(1),
            readingPosition: ReadingPosition(chapterIndex: seed, characterOffset: seed * 10),
            bookmarks: [
                Bookmark(number: seed, chapterIndex: seed, characterOffset: seed, label: "Mark \(seed)", dateCreated: date)
            ],
            totalWordCount: seed * 100,
            totalCharacterCount: seed * 500,
            tmbDirectoryName: "Package-\(seed).tmb",
            sourceFilePath: "/sources/book-\(seed).txt",
            lastPlaybackStarted: date.addingTimeInterval(2),
            lastPlaybackStopped: date.addingTimeInterval(3),
            localVoiceID: "voice.\(seed)",
            localWPM: Double(200 + seed),
            localPitch: 1 + Double(seed) / 10,
            skippedHeadingIDs: ["heading-\(seed)"],
            localEndOfBookBehavior: "behavior-\(seed)",
            localSkipForwardUnit: "forward-\(seed)",
            localSkipBackwardUnit: "backward-\(seed)",
            manualSortOrder: seed,
            audioDuration: TimeInterval(seed * 60),
            audioAlbum: "Album \(seed)",
            audioGenre: "Genre \(seed)",
            audioYear: "\(2000 + seed)",
            epubPublisher: "Publisher \(seed)",
            epubPublicationDate: "Published \(seed)",
            epubISBN: "ISBN \(seed)",
            epubLanguage: "language-\(seed)",
            epubIdentifier: "identifier-\(seed)",
            epubVersion: "version-\(seed)",
            cacheFormatVersion: "cache-\(seed)",
            contentIndexVersion: "index-\(seed)"
        )
    }

    /// The names of `Book`'s stored properties whose values differ between
    /// `a` and `b`.
    private static func fieldsThatDiffer(_ a: Book, _ b: Book) -> [String] {
        zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).compactMap { left, right in
            String(reflecting: left.value) == String(reflecting: right.value) ? nil : left.label
        }
    }
}
