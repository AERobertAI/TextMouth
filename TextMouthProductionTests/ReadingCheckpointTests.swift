import XCTest
@testable import TextMouth

/// A reading checkpoint, which the reader makes every 30 seconds of
/// playback, is written to the book's record at once and to library.json
/// within five minutes (PERF15): sooner when anything else is saved, when
/// the book's reader closes, when the record cannot take it, and when
/// TextMouth quits. Until library.json holds it, a journal names the book,
/// and a launch after a crash takes the newer position from the record.
///
/// Built on the cloud maintenance fixtures: each test's packages are in a
/// library folder of its own, removed afterwards, with the library index
/// and the checkpoint journal put back as they were.
final class ReadingCheckpointTests: CloudMaintenanceTestCase {

    // MARK: - A Checkpoint's Writes

    /// A checkpoint reaches the book's record within half a second and
    /// leaves library.json as it was, while the journal names the book.
    @MainActor
    func testCheckpointWritesTheRecordAndLeavesTheIndexForLater() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])
        let indexBefore = try LibraryIndexSandbox.inode(of: indexURL)

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        waitPastLibrarySaveDebounce()

        XCTAssertEqual(try recordedOffset(of: book), 40)
        XCTAssertEqual(try LibraryIndexSandbox.inode(of: indexURL), indexBefore, "library.json was written")
        XCTAssertEqual(try indexedOffset(of: book), 10)
        XCTAssertEqual(try journaledBooks(), [book.id])
    }

    /// Quitting writes the waiting checkpoint into library.json and
    /// removes the journal.
    @MainActor
    func testQuittingWritesTheWaitingCheckpointAndRemovesTheJournal() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertEqual(try recordedOffset(of: book), 40)
        XCTAssertFalse(journalExists(), "the journal outlived the index write")
    }

    /// Any other change saved meanwhile takes the waiting checkpoint into
    /// library.json with it, within half a second.
    @MainActor
    func testAnotherSaveCarriesTheCheckpointIntoTheIndex() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        model.updateEndOfBookBehavior(bookID: book.id, behavior: "stop")
        waitPastLibrarySaveDebounce()

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertFalse(journalExists())
    }

    /// Closing the book's reader writes its last checkpoint into
    /// library.json within half a second.
    @MainActor
    func testClosingTheReaderWritesItsLastCheckpoint() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        model.unregisterOpenBook(book.id)
        waitPastLibrarySaveDebounce()

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertFalse(journalExists())
    }

    /// Left alone, library.json takes the checkpoint at its deadline, not
    /// before.
    @MainActor
    func testTheIndexTakesTheCheckpointAtItsDeadline() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])
        var checkpointed = model.library
        checkpointed.updateReadingPosition(bookID: book.id, position: Self.position(at: 40))

        LibraryPersistenceService.saveReadingCheckpoint(checkpointed, of: book.id, writingWithin: 1.5)
        wait(seconds: 0.8)
        XCTAssertEqual(try indexedOffset(of: book), 10, "library.json took the checkpoint before its deadline")
        wait(seconds: 1.2)

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertFalse(journalExists())
    }

    /// A book without a package has no record to hold its checkpoint, so
    /// library.json takes it within half a second, and no journal is kept.
    @MainActor
    func testBookWithoutAPackageWritesItsCheckpointToTheIndex() throws {
        let book = Book(
            title: "Loose Notes",
            format: .txt,
            filePath: "/nonexistent/reading-checkpoint/loose-notes.txt",
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            readingPosition: Self.position(at: 10, secondsAfterStart: 0)
        )
        let model = makeSavedModel(with: [book])

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        waitPastLibrarySaveDebounce()

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertFalse(journalExists())
    }

    /// A book whose record is only in the cloud cannot take its checkpoint,
    /// so library.json takes it within about a second instead.
    @MainActor
    func testRecordInTheCloudSendsTheCheckpointToTheIndex() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])
        cloud.markDataless(TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        let previous = LibraryPersistenceService._useRecordAccessForTesting(cloud.access)
        addTeardownBlock { LibraryPersistenceService._useRecordAccessForTesting(previous) }

        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        wait(seconds: 1.4)

        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertEqual(try recordedOffset(of: book), 10, "a record in the cloud was written")
    }

    // MARK: - A Crash

    /// The crash this all guards against: a checkpoint reaches the record,
    /// then TextMouth stops before library.json takes it. The next launch
    /// reads the older index, takes the newer position and last-opened date
    /// from the record, says so in one line, and saves them, which removes
    /// the journal.
    @MainActor
    func testLaunchAfterACrashTakesTheCheckpointFromTheRecord() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])
        let tookLine = "LIBRARY_INDEX: took the reading positions of 1 book from their records"
        let tookLinesBefore = logLineCount(tookLine)
        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        waitPastLibrarySaveDebounce()
        LibraryPersistenceService._discardPendingIndexSaveForTesting()
        XCTAssertEqual(try indexedOffset(of: book), 10)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 40)

        let relaunched = LibraryViewModel(initializeServices: false)
        relaunched.loadLibraryIndex()

        let row = try XCTUnwrap(relaunched.bookByID(book.id))
        XCTAssertEqual(row.readingPosition, record.state.readingPosition)
        XCTAssertEqual(row.lastOpened, try XCTUnwrap(record.metadata.lastOpened))
        XCTAssertEqual(logLineCount(tookLine), tookLinesBefore + 1)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedOffset(of: book), 40)
        XCTAssertFalse(journalExists())
    }

    /// A row whose position is newer than its record's keeps it: a launch
    /// takes only a newer position from a record.
    @MainActor
    func testLaunchKeepsARowNewerThanItsRecord() throws {
        var book = try makeRecordedBook(at: 10)
        book.readingPosition = Self.position(at: 50, secondsAfterStart: 600)
        let model = makeSavedModel(with: [book])
        LibraryPersistenceService.saveReadingCheckpoint(model.library, of: book.id)
        LibraryPersistenceService._discardPendingIndexSaveForTesting()
        XCTAssertEqual(try journaledBooks(), [book.id])

        let relaunched = LibraryViewModel(initializeServices: false)
        relaunched.loadLibraryIndex()

        XCTAssertEqual(relaunched.bookByID(book.id)?.readingPosition?.characterOffset, 50)
    }

    /// A book whose record is in the cloud at launch keeps its row and is
    /// counted in the repair's one cloud line; the journal stays for a later
    /// launch that finds the record on this Mac.
    @MainActor
    func testLaunchLeavesARecordInTheCloudAndCountsIt() throws {
        let book = try makeRecordedBook(at: 10)
        let model = makeSavedModel(with: [book])
        model.persistReadingPosition(bookID: book.id, position: Self.position(at: 40))
        waitPastLibrarySaveDebounce()
        LibraryPersistenceService._discardPendingIndexSaveForTesting()
        cloud.markDataless(TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 1))

        let relaunched = makeModel(with: try XCTUnwrap(LibraryPersistenceService.load().library).books)
        relaunched.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(relaunched.bookByID(book.id)?.readingPosition?.characterOffset, 10)
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 1)), skipLinesBefore + 1)
        XCTAssertEqual(try journaledBooks(), [book.id])
    }

    // MARK: - Fixtures

    /// library.json in the hosted test root.
    private var indexURL: URL {
        TextMouthPaths.libraryIndexFile
    }

    /// A packaged book whose record holds a reading position at `offset`,
    /// saved at the start of the test's timeline.
    private func makeRecordedBook(at offset: Int) throws -> Book {
        var book = try makePackagedBook(title: "Checkpoint \(UUID().uuidString.prefix(6))")
        book.readingPosition = Self.position(at: offset, secondsAfterStart: 0)
        try book.saveBookInfoThrowing()
        return book
    }

    /// A library model listing `books`, whose index is on disk as it lists
    /// them.
    @MainActor
    private func makeSavedModel(with books: [Book]) -> LibraryViewModel {
        let model = makeModel(with: books)
        model.save()
        LibraryPersistenceService.flushPendingSave()
        return model
    }

    /// A position at `offset` in the first chapter, saved `secondsAfterStart`
    /// seconds into the test's timeline, or now when that is nil.
    private static func position(at offset: Int, secondsAfterStart: TimeInterval? = nil) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: 0, characterOffset: offset)
        if let secondsAfterStart {
            position.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000 + secondsAfterStart)
        }
        return position
    }

    /// The offset library.json records for `book`, read from the file.
    private func indexedOffset(of book: Book) throws -> Int? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: Data(contentsOf: indexURL))
        return library.books.first { $0.id == book.id }?.readingPosition?.characterOffset
    }

    /// The offset `book`'s record holds.
    private func recordedOffset(of book: Book) throws -> Int? {
        try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.characterOffset
    }

    /// The books the checkpoint journal names, read from the file.
    private func journaledBooks() throws -> Set<UUID> {
        let data = try Data(contentsOf: TextMouthPaths.readingCheckpointsFile)
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        return Set(try XCTUnwrap(journal["books"]).compactMap(UUID.init(uuidString:)))
    }

    /// Whether the checkpoint journal exists.
    private func journalExists() -> Bool {
        FileManager.default.fileExists(atPath: TextMouthPaths.readingCheckpointsFile.path)
    }

    /// Lets `seconds` pass with the main run loop turning.
    private func wait(seconds: TimeInterval) {
        let elapsed = expectation(description: "\(seconds) seconds elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 5)
    }
}
