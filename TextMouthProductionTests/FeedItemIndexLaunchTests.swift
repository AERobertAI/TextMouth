import XCTest
@testable import TextMouth

/// A launch with feed items (FR11, branch A1): every feed item's row is read
/// from its feed's index with library.json, waits on the shelf through the
/// startup repair, and joins the library model's books when its file is
/// here, before anything can edit the reading list or open a reader; a
/// journaled checkpoint newer than the index comes from the record, and an
/// unreadable library.json loses no feed item.
final class FeedItemIndexLaunchTests: FeedItemIndexTestCase {

    // MARK: - The Join

    /// A feed item whose file is here joins the books, exactly as its index
    /// holds it, and library.json still holds none.
    @MainActor
    func testAFeedItemWhoseFileIsHereJoinsTheBooks() throws {
        let plain = try makePackagedBook(title: "Launch Book")
        let item = try makeFeedItem(title: "Launch Item", lastOpened: Self.date(30), position: Self.position(12, at: 30))
        saveNow(Library(books: [plain, item]))

        let model = launchedModel()

        XCTAssertEqual(model.bookByID(item.id), item)
        XCTAssertNotNil(model.bookByID(plain.id))
        XCTAssertFalse(model.library.feedShelf.rows.contains { $0.id == item.id })
        XCTAssertTrue(model.library.feedShelf.indexedFeedIDs.contains(feedID))
        try assertLibraryJSONHoldsNoFeedItem([item])
    }

    /// A feed item whose file is gone waits on the shelf, where nothing
    /// lists it, and its feed's index keeps it.
    @MainActor
    func testAFeedItemWhoseFileIsGoneWaitsOnTheShelf() throws {
        let item = try makeFeedItem(title: "Gone File", lastOpened: Self.date(5), position: Self.position(3, at: 5))
        saveNow(Library(books: [item]))
        try FileManager.default.removeItem(at: item.bookFileURL)

        let model = launchedModel()
        model.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNil(model.bookByID(item.id))
        XCTAssertEqual(model.library.feedShelf.rows.first { $0.id == item.id }, item)
        XCTAssertEqual(try indexedRows(), [item])
    }

    /// A checkpoint that reached the feed item's record but not its feed's
    /// index before TextMouth stopped is taken from the record, as a book's
    /// is from its record.
    @MainActor
    func testAJournaledCheckpointComesFromTheRecord() throws {
        let item = try makeFeedItem(title: "Checkpoint Then Crash", lastOpened: Self.date(20), position: Self.position(10, at: 20))
        saveNow(Library(books: [item]))
        var played = item
        played.readingPosition = Self.position(40, at: 50)
        played.lastOpened = Self.date(50)
        try played.saveBookInfoThrowing()
        LibraryPersistenceService.saveReadingCheckpoint(Library(books: [played]), of: item.id)
        LibraryPersistenceService._discardPendingIndexSaveForTesting()

        let model = launchedModel()

        XCTAssertEqual(model.bookByID(item.id)?.readingPosition, Self.position(40, at: 50))
        XCTAssertEqual(model.bookByID(item.id)?.lastOpened, Self.date(50))
    }

    /// The reading list keeps a feed item across a launch: its row joins the
    /// books before anything can edit the list, so an edit keeps its ID.
    @MainActor
    func testTheReadingListKeepsAFeedItemAcrossALaunch() throws {
        let plain = try makePackagedBook(title: "Listed Book")
        let item = try makeFeedItem(title: "Listed Item")
        var list = ReadingList()
        _ = list.append([item.id, plain.id])
        saveNow(Library(books: [plain, item], readingList: list))

        let model = launchedModel()
        XCTAssertEqual(model.readingList.bookIDs, [item.id, plain.id])
        _ = model.removeFromReadingList([plain.id])

        XCTAssertEqual(model.readingList.bookIDs, [item.id])
    }

    /// A row of library.json naming a download whose first-launch move had
    /// moved its package when TextMouth stopped gives way to the feed item's
    /// row, whose package is the one here: the book is listed once.
    @MainActor
    func testALibraryRowSharingAFeedItemsIDGivesWayToIt() throws {
        let item = try makeFeedItem(title: "Moved Before The Crash")
        var stale = item
        stale.feedLink = nil
        stale.folderPath = folderPath
        stale.filePath = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: item.tmbDirectoryName)
            .appendingPathComponent(item.bookFileURL.lastPathComponent).path
        saveNow(Library(books: [stale], feedShelf: FeedShelf(rows: [item])))
        XCTAssertTrue(try libraryJSONBookIDs().contains(item.id), "the fixture must hold the stale row")

        let model = launchedModel()

        XCTAssertEqual(model.library.books.filter { $0.id == item.id }, [item])
        XCTAssertFalse(model.library.feedShelf.rows.contains { $0.id == item.id })
    }

    /// Without a library.json, each feed's index is read all the same.
    @MainActor
    func testALaunchWithoutLibraryJSONReadsTheFeedItems() throws {
        let item = try makeFeedItem(title: "No Library Index")
        saveNow(Library(books: [item]))
        try FileManager.default.removeItem(at: TextMouthPaths.libraryIndexFile)

        let model = launchedModel()

        XCTAssertEqual(model.bookByID(item.id), item)
    }

    // MARK: - An Unreadable library.json

    /// While library.json cannot be read, the feed items are read from their
    /// packages, whose records hold their latest state, as the provisional
    /// library's books are, and they join the books.
    @MainActor
    func testRecoveryReadsTheFeedItemsFromTheirPackages() throws {
        let item = try makeFeedItem(title: "Recovered Item", lastOpened: Self.date(20), position: Self.position(10, at: 20))
        saveNow(Library(books: [item]))
        var played = item
        played.readingPosition = Self.position(40, at: 50)
        try played.saveBookInfoThrowing()
        try Data("{ damaged".utf8).write(to: TextMouthPaths.libraryIndexFile)

        let model = launchedModel()

        XCTAssertNotNil(model.indexRecovery)
        XCTAssertEqual(model.bookByID(item.id)?.readingPosition, Self.position(40, at: 50))
    }

    /// Try Again carries the session's feed items into the index it reads:
    /// no feed's index was written while library.json could not be, so the
    /// session's rows are the latest; a feed only the loaded library read
    /// keeps its rows from there.
    func testTryAgainCarriesTheSessionsFeedItems() throws {
        let item = try makeFeedItem(title: "Played In Recovery")
        var older = item
        older.readingPosition = Self.position(10, at: 20)
        var newer = item
        newer.readingPosition = Self.position(50, at: 60)
        let elsewhere = FeedBookLink(feedID: UUID(), itemID: "elsewhere")
        let other = Book(title: "Other Feed", format: .html, filePath: "/other.html", md5Hash: "o", feedLink: elsewhere)
        let loaded = Library(feedShelf: FeedShelf(rows: [older, other]))
        let provisional = Library(books: [newer])

        let merged = LibraryViewModel.carryingRecoverySessionState(from: provisional, into: loaded)

        XCTAssertTrue(merged.books.isEmpty, "the feed items wait on the shelf for the repair to join them")
        XCTAssertEqual(Set(merged.feedShelf.rows.map(\.id)), [item.id, other.id])
        XCTAssertEqual(merged.feedShelf.rows.first { $0.id == item.id }?.readingPosition, newer.readingPosition)
        XCTAssertEqual(merged.feedShelf.indexedFeedIDs, [feedID, elsewhere.feedID])
    }
}
