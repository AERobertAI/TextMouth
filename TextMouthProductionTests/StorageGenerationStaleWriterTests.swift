import XCTest
@testable import TextMouth

/// Writers that captured paths before a data-directory move published, and
/// write after it (TODO S04): each re-resolves its paths under the current
/// root, never writes under the old one, and never recreates it.
///
/// Each test makes a data directory of its own current, writes a book into
/// it, captures what a writer would, and then moves the data directory as
/// a move does it, by copying it and publishing the copy, before deleting
/// the old one, as a user might once the move is done.
@MainActor
final class StorageGenerationStaleWriterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Nothing an earlier test queued may land in this test's folders.
        LibraryPersistenceService.flushPendingSave()
    }

    // MARK: - The Library Index

    /// A library snapshot saved before the move and written after it is
    /// written in the new data directory, naming its books there, and the
    /// old data directory is not recreated.
    func testLibrarySnapshotTakenBeforeAMoveIsWrittenUnderTheNewRoot() throws {
        let old = try makeCurrentDataDirectory("StaleIndexOld")
        let book = try makeTextBook(in: old)
        var library = Library()
        library.books = [book]

        // The save waits for its timer while the data directory moves.
        LibraryPersistenceService.save(library)
        let new = try moveDataDirectory(from: old, label: "StaleIndexNew")
        try FileManager.default.removeItem(at: old)
        LibraryPersistenceService.flushPendingSave()

        let written = try Self.readLibrary(at: new.appendingPathComponent("library.json"))
        XCTAssertEqual(written.books.map(\.filePath), [Self.path(of: book, under: new)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "The old data directory was recreated")
    }

    // MARK: - Package Records

    /// A package record queued before the move and written after it lands
    /// in the book's moved package, and the old data directory is not
    /// recreated.
    func testRecordQueuedBeforeAMoveIsWrittenInTheMovedPackage() throws {
        let old = try makeCurrentDataDirectory("StaleRecordOld")
        var book = try makeTextBook(in: old)
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 21)

        LibraryPersistenceService.saveBookInfo(for: book)
        let new = try moveDataDirectory(from: old, label: "StaleRecordNew")
        try FileManager.default.removeItem(at: old)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: Self.package(of: book, under: new))
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 21)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "The old data directory was recreated")
    }

    /// An analysis of a book captured before the move is committed to the
    /// moved package's record, merged into the book's latest state there
    /// (a snapshot the library saved after the move), instead of being
    /// dropped as if the book's source had moved; the old package's record
    /// is not written.
    func testAnalysisOfABookCapturedBeforeAMoveIsCommittedToTheMovedPackage() throws {
        let old = try makeCurrentDataDirectory("StaleAnalysisOld")
        var analyzed = try makeTextBook(in: old)
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &analyzed))
        let oldRecord = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: analyzed.tmbDirectory))

        let new = try moveDataDirectory(from: old, label: "StaleAnalysisNew")
        // After the move the library saves the book's moved row.
        var moved = StorageBoundary.shared.rebasedToCurrent(analyzed)
        moved.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 8)
        LibraryPersistenceService.saveBookInfo(for: moved)

        let committed = try LibraryPersistenceService.saveContentAnalysis(
            for: analyzed,
            index: index,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )

        XCTAssertNotNil(committed, "The analysis was dropped")
        XCTAssertEqual(committed?.filePath, Self.path(of: analyzed, under: new))
        let record = try BookInfo.load(from: Self.package(of: analyzed, under: new))
        XCTAssertNotNil(record.contentIndex)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 8, "The latest state was not kept")
        XCTAssertEqual(try Data(contentsOf: Self.package(of: analyzed, under: old).appendingPathComponent("bookInfo.json")), oldRecord)
    }

    // MARK: - Text Caches

    /// A text cache generated for a book captured before the move is read
    /// from the moved source and written in the moved package, and the old
    /// data directory is not recreated.
    func testCacheGeneratedForABookCapturedBeforeAMoveIsWrittenInTheMovedPackage() throws {
        let old = try makeCurrentDataDirectory("StaleCacheOld")
        let book = try makeTextBook(in: old)
        let new = try moveDataDirectory(from: old, label: "StaleCacheNew")
        try FileManager.default.removeItem(at: old)

        let generated = try MarkdownCacheService.generateReportedCacheContent(for: book)

        let movedCache = Self.package(of: book, under: new).appendingPathComponent("content.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedCache.path), "The moved package has no content.md")
        XCTAssertNotNil(generated?.content.contentIndex.textCacheFingerprint, "The moved source was not fingerprinted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "The old data directory was recreated")
    }

    /// A text cache batch that queued a book before the move gives its
    /// update the book with its file in the new data directory.
    func testTextCacheBatchGetsABookQueuedBeforeAMoveInTheNewDataDirectory() async throws {
        let old = try makeCurrentDataDirectory("StaleBatchOld")
        let book = try makeTextBook(in: old)
        let new = try moveDataDirectory(from: old, label: "StaleBatchNew")
        try FileManager.default.removeItem(at: old)
        let expectedPath = Self.path(of: book, under: new)
        let updated = expectation(description: "the batch updated the book")

        TextCacheUpdateQueue.run(books: [book], update: { queued in
            XCTAssertEqual(queued.filePath, expectedPath)
            updated.fulfill()
        }, completion: {})

        await fulfillment(of: [updated], timeout: 10)
    }

    /// The statistics pass for a book the library listed before the move
    /// analyzes the moved book and commits the result to its moved package,
    /// without recreating the old data directory.
    func testStatisticsPassForABookListedBeforeAMoveAnalyzesTheMovedBook() throws {
        let old = try makeCurrentDataDirectory("StaleStatisticsOld")
        let book = try makeTextBook(in: old)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        model.library.books = [book]
        let new = try moveDataDirectory(from: old, label: "StaleStatisticsNew")
        try FileManager.default.removeItem(at: old)

        model.calculateMissingBookStats()

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.library.books.first?.totalWordCount != nil },
            "The pass never analyzed the book"
        )
        XCTAssertNotNil(try BookInfo.load(from: Self.package(of: book, under: new)).contentIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "The old data directory was recreated")
    }

    // MARK: - Fixtures

    /// A new data directory of the test's own, with its folders, made the
    /// current one until the test ends.
    private func makeCurrentDataDirectory(_ label: String) throws -> URL {
        let root = try makeDataDirectoryMoveDestination(label)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        StorageBoundary.shared.publish(root: root)
        return root
    }

    /// Moves the data directory at `old`, the current one, as a move does:
    /// copies it to a new folder, then publishes the copy. Returns the copy.
    private func moveDataDirectory(from old: URL, label: String) throws -> URL {
        let new = try makeDataDirectoryMoveDestination(label)
        try FileManager.default.copyItem(at: old, to: new)
        LibraryPersistenceService.betweenWrites {
            StorageBoundary.shared.publish(root: new)
        }
        return new
    }

    /// A plain-text book in a package of its own in the data directory at
    /// `root`, the current one, with its record.
    private func makeTextBook(in root: URL) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        XCTAssertTrue(package.path.hasPrefix(root.path + "/"))
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("Pilotage.txt")
        try Data("Slack water at the outer mark.\n\nThe pilot boards at the fairway buoy.\n".utf8).write(to: file)
        let book = Book(
            title: "Pilotage",
            format: .txt,
            filePath: file.path,
            md5Hash: try FileImportService.md5Hash(of: file),
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// Where `book`'s package is in the data directory at `root`, as
    /// `TextMouthPaths.tmbPath` places it there.
    private static func package(of book: Book, under root: URL) -> URL {
        var folder = root.appendingPathComponent("Library", isDirectory: true)
        if !book.folderPath.isEmpty {
            folder.appendPathComponent(book.folderPath, isDirectory: true)
        }
        return folder.appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
    }

    /// Where `book`'s file is in the data directory at `root`.
    private static func path(of book: Book, under root: URL) -> String {
        package(of: book, under: root).appendingPathComponent(URL(fileURLWithPath: book.filePath).lastPathComponent).path
    }

    /// The library index at `url`.
    private static func readLibrary(at url: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: url))
    }
}
