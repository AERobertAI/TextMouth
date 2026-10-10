import XCTest
@testable import TextMouth

/// The first launch of FR11's build (branch A1) moves each download made
/// before it into its feed's folder, keeping everything the reader saved,
/// and a crash between any two of the move's steps is mended at the next
/// launch. The fixture is shaped like the user's library on October 7,
/// 2026: books of the library's own, one downloaded article of "The Digital
/// Antiquarian", opened, with a position, its package in its feed's library
/// folder and its record naming its feed and item, and a second feed with
/// nothing downloaded. The user's own library is never read.
final class FeedItemIndexMoveTests: FeedItemIndexTestCase {

    // MARK: - The Move

    /// The article moves into its feed's folder: library.json loses its row
    /// and keeps every other, the feed's index holds it with its book ID,
    /// position, and last-opened date, its package and record are in the
    /// feed's folder, it stays on the reading list, and the next launch
    /// finds it there.
    @MainActor
    func testTodaysDownloadMovesIntoItsFeedKeepingEverything() async throws {
        let fixture = try makeUsersLibrary()
        let model = launchedModel()

        let moved = await model.moveDownloadsIntoTheirFeeds(records: fixture.records)

        XCTAssertEqual(moved, 1)
        try assertMoved(fixture, in: model)
        let next = launchedModel()
        XCTAssertEqual(next.bookByID(fixture.article.id)?.feedLink, fixture.link)
        XCTAssertEqual(next.bookByID(fixture.article.id)?.readingPosition, fixture.article.readingPosition)
        XCTAssertEqual(next.readingList.bookIDs, [fixture.article.id, fixture.books[0].id])
        let movedAgain = await next.moveDownloadsIntoTheirFeeds(records: fixture.records)
        XCTAssertEqual(movedAgain, 0, "a second launch moves nothing")
    }

    // MARK: - A Crash Between Two Steps

    /// A crash once the feed's folder was made, before the package moved.
    @MainActor
    func testACrashAfterTheFolderIsMadeIsMended() async throws {
        try await assertCrashIsMended(after: .folderMade)
    }

    /// A crash once the package moved, before its record was written.
    @MainActor
    func testACrashAfterThePackageMovesIsMended() async throws {
        try await assertCrashIsMended(after: .packageMoved)
    }

    /// A crash once the record was written, before the feed's index was.
    @MainActor
    func testACrashAfterTheRecordIsWrittenIsMended() async throws {
        try await assertCrashIsMended(after: .recordWritten)
    }

    /// A crash once the feed's index was written, before library.json was.
    @MainActor
    func testACrashAfterTheIndexIsWrittenIsMended() async throws {
        try await assertCrashIsMended(after: .indexWritten)
    }

    // MARK: - What Does Not Move

    /// A download whose feed is no longer subscribed stays a book of the
    /// library's own, as Unsubscribe has always promised.
    @MainActor
    func testADownloadOfAFeedNoLongerSubscribedStaysABook() async throws {
        let fixture = try makeUsersLibrary()
        let model = launchedModel()
        let before = contents(of: TextMouthPaths.libraryIndexFile)

        let moved = await model.moveDownloadsIntoTheirFeeds(records: [:])

        XCTAssertEqual(moved, 0)
        XCTAssertNil(model.bookByID(fixture.article.id)?.feedLink)
        XCTAssertEqual(contents(of: TextMouthPaths.libraryIndexFile), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.article.bookFileURL.path))
    }

    /// While another operation holds the storage work, nothing moves, and
    /// the next launch tries again.
    @MainActor
    func testNothingMovesWhileTheStorageWorkIsHeld() async throws {
        let fixture = try makeUsersLibrary()
        let model = launchedModel()
        let hold = try StorageBoundary.shared.holdWork(for: .rebuildingDirectory)
        defer { hold.release() }

        let moved = await model.moveDownloadsIntoTheirFeeds(records: fixture.records)

        XCTAssertEqual(moved, 0)
        XCTAssertNil(model.bookByID(fixture.article.id)?.feedLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.article.bookFileURL.path))
    }

    /// A download whose record cannot be written where it moved is put back
    /// where it was, and stays a book of the library's own.
    func testAMoveWhoseRecordCannotBeWrittenIsPutBack() throws {
        let fixture = try makeUsersLibrary()
        let destination = FeedPaths.packageDirectory(named: fixture.article.tmbDirectoryName, of: feedID, in: TextMouthPaths.root)
        // A folder where the record goes makes its write fail.
        let record = TextMouthPaths.bookInfoPath(in: fixture.article.tmbDirectory)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: record.appendingPathComponent("obstruction"))

        XCTAssertThrowsError(try LibraryViewModel.moveIntoItsFeed(fixture.article, link: fixture.link, root: TextMouthPaths.root))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.article.bookFileURL.path), "the package was not put back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - The Fixture

    /// The steps of the move after which a crash is mended.
    enum Step {
        /// The feed's folder was made.
        case folderMade
        /// The package moved into it.
        case packageMoved
        /// Its record was written there.
        case recordWritten
        /// The feed's index was written, library.json not yet.
        case indexWritten
    }

    /// The user's library in miniature, on disk: library.json, its books,
    /// and the downloaded article, with the feeds' records that name it.
    struct UsersLibrary {
        /// The books of the library's own.
        var books: [Book]
        /// The downloaded article, as library.json holds it before FR11.
        var article: Book
        /// The article's feed and item.
        var link: FeedBookLink
        /// "The Digital Antiquarian", which names the article as downloaded,
        /// and "Finish It!", with nothing downloaded.
        var records: [UUID: FeedRecord]
    }

    /// Writes the user's library in miniature: three books of the library's
    /// own, two in this test's folder and one at the top, and the article,
    /// opened with a position and on the reading list, its package in the
    /// feed's library folder (this test's folder) holding its HTML, its text
    /// cache, and its record naming its feed and item, as a download before
    /// FR11 left it; library.json lists all four.
    private func makeUsersLibrary() throws -> UsersLibrary {
        let books = [
            try makePackagedBook(title: "Middlemarch"),
            try makePackagedBook(title: "Bleak House"),
            Book(title: "Top Level Notes", format: .txt, filePath: "/nonexistent/notes.txt", md5Hash: UUID().uuidString),
        ]
        let link = FeedBookLink(feedID: feedID, itemID: "guid:lemmings")
        let bookID = UUID()
        let name = TextMouthPaths.tmbName(title: "The Lamentable Later Life of Lemmings", author: "Jimmy Maher", dateAdded: Self.date(), bookID: bookID)
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("The Lamentable Later Life of Lemmings.html")
        try "<html><body><h1>Lemmings</h1><p>Words.</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        try "# Lemmings\n\nWords.".write(to: TextMouthPaths.contentMarkdownPath(in: package), atomically: true, encoding: .utf8)
        let article = Book(
            id: bookID,
            title: "The Lamentable Later Life of Lemmings",
            author: "Jimmy Maher",
            format: .html,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            dateAdded: Self.date(),
            lastOpened: Self.date(3_600),
            readingPosition: Self.position(1_234, at: 3_600),
            tmbDirectoryName: name
        )
        var record = article.makeBookInfo()
        record.metadata.feedLink = link
        try record.save(to: package)
        var list = ReadingList()
        _ = list.append([article.id, books[0].id])
        saveNow(Library(books: books + [article], readingList: list))

        let antiquarian = Feed(
            id: feedID,
            feedURL: try XCTUnwrap(URL(string: "https://www.filfre.net/feed/")),
            folderID: UUID(),
            subscribedDate: Self.date()
        )
        let finishIt = Feed(feedURL: try XCTUnwrap(URL(string: "https://finish.example/feed.xml")), folderID: UUID(), subscribedDate: Self.date())
        let records = [
            antiquarian.id: FeedRecord(feed: antiquarian, items: [
                FeedItem(id: "guid:newer", title: "A Newer Article", firstSeen: Self.date()),
                FeedItem(id: "guid:lemmings", title: article.title, firstSeen: Self.date(), state: .downloaded(bookID: article.id)),
            ]),
            finishIt.id: FeedRecord(feed: finishIt, items: [
                FeedItem(id: "guid:ep-368", title: "Ep. 368", firstSeen: Self.date()),
            ]),
        ]
        return UsersLibrary(books: books, article: article, link: link, records: records)
    }

    /// Leaves on disk what a crash after `step` of the move leaves, then
    /// launches, moves, and saves as the next launch does, and asserts that
    /// the article ends where an uninterrupted move puts it.
    @MainActor
    private func assertCrashIsMended(after step: Step, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try makeUsersLibrary()
        let root = TextMouthPaths.root
        var moved = fixture.article
        moved.folderPath = ""
        moved.feedLink = fixture.link
        let destination = moved.packageDirectory(inDataDirectory: root)
        moved.filePath = destination.appendingPathComponent(fixture.article.bookFileURL.lastPathComponent).path
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if step != .folderMade {
            try FileManager.default.moveItem(at: fixture.article.tmbDirectory, to: destination)
        }
        if step == .recordWritten || step == .indexWritten {
            try moved.saveBookInfoThrowing(inPackageAt: destination)
        }
        if step == .indexWritten {
            try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [moved])).write(to: feedIndexURL)
        }

        let model = launchedModel()
        await model.moveDownloadsIntoTheirFeeds(records: fixture.records)
        model.save()
        LibraryPersistenceService.flushPendingSave()

        try assertMoved(fixture, in: model, file: file, line: line)
    }

    /// Asserts that the article has moved into its feed's folder whole, as
    /// `model` holds it and as the files on disk do.
    @MainActor
    private func assertMoved(_ fixture: UsersLibrary, in model: LibraryViewModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let article = fixture.article
        XCTAssertEqual(try libraryJSONBookIDs(), Set(fixture.books.map(\.id)), "library.json lost a book or kept the article", file: file, line: line)
        try assertLibraryJSONHoldsNoFeedItem([article], file: file, line: line)

        let rows = try indexedRows()
        XCTAssertEqual(rows.map(\.id), [article.id], file: file, line: line)
        let row = try XCTUnwrap(rows.first, file: file, line: line)
        XCTAssertEqual(row.feedLink, fixture.link, file: file, line: line)
        XCTAssertEqual(row.folderPath, "", file: file, line: line)
        XCTAssertEqual(row.readingPosition, article.readingPosition, file: file, line: line)
        XCTAssertEqual(row.lastOpened, article.lastOpened, file: file, line: line)
        XCTAssertEqual(row.dateAdded, article.dateAdded, file: file, line: line)

        let package = row.tmbDirectory
        XCTAssertTrue(package.path.hasPrefix(feedFolderURL.path + "/"), package.path, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentMarkdownPath(in: package).path), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: article.tmbDirectory.path), "the old package is still there", file: file, line: line)
        let record = try BookInfo.load(from: package)
        XCTAssertEqual(record.metadata.bookID, article.id, file: file, line: line)
        XCTAssertEqual(record.metadata.feedLink, fixture.link, file: file, line: line)
        XCTAssertEqual(record.metadata.folderPath, "", file: file, line: line)
        XCTAssertEqual(record.state.readingPosition, article.readingPosition, file: file, line: line)

        XCTAssertEqual(model.library.books.filter { $0.id == article.id }.count, 1, file: file, line: line)
        XCTAssertEqual(model.bookByID(article.id)?.feedLink, fixture.link, file: file, line: line)
        XCTAssertEqual(model.readingList.bookIDs, [article.id, fixture.books[0].id], file: file, line: line)
    }
}
