import XCTest
@testable import TextMouth

// MARK: - A Feed's Downloads Return to the Library

/// Until Unsubscribe keeps a feed's downloads by the listener's choice (FR11,
/// branch D), a feed whose record is gone gets its downloads back as books of
/// the library's own, at Unsubscribe and at launch (REV10, item 3): each keeps
/// its book ID, place, bookmarks, and place on the reading list, and what the
/// feed kept of downloads removed earlier is deleted. A crash between any two
/// steps is finished at the next launch. The fixture is this test's feed's
/// folder, holding one download the listener opened and one package kept after
/// its download went, with this test's library folder as the feed's own.
final class LibraryFeedDownloadReturnTests: FeedItemIndexTestCase {

    // MARK: - One Feed

    /// The download becomes a book of the library's own in the feed's
    /// folder, keeping its ID, place, bookmarks, and reading-list place;
    /// library.json lists it; the kept package and the feed's folder go; and
    /// the next launch finds the book there.
    @MainActor
    func testTheDownloadsBecomeBooksInTheFeedsFolder() async throws {
        let fixture = try makeUnsubscribedFeed()
        let model = launchedModel()

        let outcome = await model.returnDownloads(ofFeed: feedID, toFolderID: fixture.folder.id, removingWith: Self.deleteForGood)

        XCTAssertEqual(outcome.returned.map(\.id), [fixture.download.id])
        XCTAssertEqual(outcome.stayed, [])
        XCTAssertEqual(outcome.deletedKeptPackages, 1)
        XCTAssertTrue(outcome.removedFeedFolder)
        XCTAssertFalse(model.library.feedShelf.indexedFeedIDs.contains(feedID), "the gone feed's index is still kept")
        try assertReturned(fixture, toFolder: folderPath, in: model)
    }

    /// When the feed's library folder is gone, its downloads become books at
    /// the library's top level.
    @MainActor
    func testTheDownloadsOfAFeedWhoseFolderIsGoneGoToTheTopLevel() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()

        let outcome = await model.returnDownloads(ofFeed: feedID, toFolderID: UUID(), removingWith: Self.deleteForGood)

        XCTAssertEqual(outcome.returned.map(\.id), [fixture.download.id])
        try assertReturned(fixture, toFolder: "", in: model)
    }

    /// A row that is no feed item's, or names no package the library
    /// manages, is refused before anything on disk is touched.
    func testTheReturnRefusesARowNamingNoManagedPackage() throws {
        let fixture = try makeUnsubscribedFeed()
        var unnamed = fixture.download
        unnamed.tmbDirectoryName = ""
        var ownBook = fixture.download
        ownBook.feedLink = nil

        for row in [unnamed, ownBook] {
            XCTAssertThrowsError(try LibraryViewModel.returnIntoTheLibrary(row, folderPath: folderPath, root: TextMouthPaths.root)) { error in
                XCTAssertEqual(error as? FeedItemMoveError, .packageNotManaged)
            }
        }
        XCTAssertThrowsError(try LibraryViewModel.returnIntoTheLibrary(fixture.download, folderPath: "../Outside", root: TextMouthPaths.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.download.filePath), "the download moved")
    }

    // MARK: - At Launch

    /// The launch finds the feed's folder with no record of it, and returns
    /// its download to the library's top level, since nothing names the
    /// feed's folder any more; a subscribed feed, and a feed whose record
    /// file is there though it could not be read, are left alone.
    @MainActor
    func testTheLaunchReturnsTheDownloadsOfAFeedWhoseRecordIsGone() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])

        XCTAssertEqual(model.feedsWithoutRecords(subscribed: others.union([feedID])), [])
        let record = FeedPaths.recordFile(of: feedID, in: FeedPaths.recordsFolder(in: TextMouthPaths.root))
        try Data("{ unreadable".utf8).write(to: record)
        XCTAssertEqual(model.feedsWithoutRecords(subscribed: others), [], "a feed whose record file is there was taken for gone")
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(model.feedsWithoutRecords(subscribed: others), [feedID])

        let returned = await model.returnDownloadsOfFeedsWithoutRecords(subscribed: others, removingWith: Self.deleteForGood)

        XCTAssertEqual(returned, 1)
        try assertReturned(fixture, toFolder: "", in: model)
    }

    /// A feed whose index is left alone, as one only in the cloud, is never
    /// taken for gone: its rows here may be only some of its own.
    @MainActor
    func testAFeedWhoseIndexIsLeftAloneIsNotTakenForGone() throws {
        _ = try makeUnsubscribedFeed()
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        model.library.feedShelf.leaveIndexAlone(of: feedID)

        XCTAssertEqual(model.feedsWithoutRecords(subscribed: others), [])
    }

    // MARK: - A Crash Between Two Steps

    /// A crash once the download's package moved into the library folder,
    /// before its record was written there.
    @MainActor
    func testACrashAfterThePackageMovesIsFinished() async throws {
        try await assertCrashIsFinished(after: .packageMoved)
    }

    /// A crash once the record was written, before library.json was.
    @MainActor
    func testACrashAfterTheRecordIsWrittenIsFinished() async throws {
        try await assertCrashIsFinished(after: .recordWritten)
    }

    /// A crash once library.json listed the book, before the kept package
    /// and the feed's folder went.
    @MainActor
    func testACrashAfterLibraryJSONIsWrittenIsFinished() async throws {
        try await assertCrashIsFinished(after: .libraryWritten)
    }

    /// A crash once the kept package went, before the feed's folder did.
    @MainActor
    func testACrashAfterTheKeptPackageGoesIsFinished() async throws {
        try await assertCrashIsFinished(after: .keptPackageDeleted)
    }

    // MARK: - The Fixture

    /// The steps of the return after which a crash is finished.
    enum Step {
        /// The download's package moved into the feed's library folder.
        case packageMoved
        /// Its record was written there.
        case recordWritten
        /// library.json listed it as a book.
        case libraryWritten
        /// The package kept for a removed download went.
        case keptPackageDeleted
    }

    /// A feed no longer subscribed, as its folder holds it.
    struct UnsubscribedFeed {
        /// The library folder that was the feed's: this test's folder.
        var folder: BookFolder
        /// A book of the library's own in that folder.
        var book: Book
        /// The download the listener opened, with a place and a bookmark,
        /// on the reading list.
        var download: Book
        /// The row kept after another download went, its package without
        /// its file.
        var kept: Book
    }

    /// This test's feed's folder holding a download the listener opened,
    /// with a place and a bookmark, and a package kept after its download
    /// went, beside a book of the library's own in this test's folder, the
    /// feed's library folder; the reading list holds the download, then the
    /// book; library.json and the feed's index are on disk.
    private func makeUnsubscribedFeed() throws -> UnsubscribedFeed {
        let folder = BookFolder(name: folderPath)
        let book = try makePackagedBook(title: "Middlemarch")
        var download = try makeFeedItem(title: "Lamentable Lemmings", lastOpened: Self.date(60), position: Self.position(1_234, at: 60))
        // A whole second, which ISO 8601 dates keep exactly, so the bookmark
        // read back compares equal.
        download.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 300, label: "The cliff", dateCreated: Self.date(45))]
        try download.makeBookInfo().save(to: download.tmbDirectory)
        let kept = try makeFeedItem(title: "Kept Article", lastOpened: Self.date(30), position: Self.position(55, at: 30))
        try FileManager.default.removeItem(at: kept.bookFileURL)
        var list = ReadingList()
        _ = list.append([download.id, book.id])
        saveNow(Library(books: [book, download], folders: [folder], readingList: list, feedShelf: FeedShelf(rows: [kept])))
        return UnsubscribedFeed(folder: folder, book: book, download: download, kept: kept)
    }

    /// Leaves on disk what a crash after `step` of Unsubscribe's return into
    /// the feed's folder leaves, then launches, finds the feed without its
    /// record, and saves, as the next launch does, and asserts that the
    /// download ends as an uninterrupted return leaves it.
    @MainActor
    private func assertCrashIsFinished(after step: Step, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try makeUnsubscribedFeed()
        let root = TextMouthPaths.root
        if step == .packageMoved {
            var moved = fixture.download
            moved.feedLink = nil
            moved.folderPath = folderPath
            try FileManager.default.moveItem(at: fixture.download.tmbDirectory, to: moved.packageDirectory(inDataDirectory: root))
        } else {
            let returned = try LibraryViewModel.returnIntoTheLibrary(fixture.download, folderPath: folderPath, root: root)
            if step != .recordWritten {
                var list = ReadingList()
                _ = list.append([returned.id, fixture.book.id])
                saveNow(Library(
                    books: [fixture.book, returned],
                    folders: [fixture.folder],
                    readingList: list,
                    feedShelf: FeedShelf(rows: [fixture.kept], indexesLeftAlone: [feedID])
                ))
            }
            if step == .keptPackageDeleted {
                try FileManager.default.removeItem(at: fixture.kept.tmbDirectory)
            }
        }

        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        await model.returnDownloadsOfFeedsWithoutRecords(subscribed: others, removingWith: Self.deleteForGood)
        model.save()
        LibraryPersistenceService.flushPendingSave()

        try assertReturned(fixture, toFolder: folderPath, in: model, file: file, line: line)
    }

    /// Asserts that the download is a book of the library's own in the
    /// library folder `folder`, with everything the listener left, as `model`
    /// holds it, as library.json and its record hold it, and as the next
    /// launch finds it; that the kept package and the feed's folder are gone;
    /// and that the book of the library's own is as it was.
    @MainActor
    private func assertReturned(
        _ fixture: UnsubscribedFeed,
        toFolder folder: String,
        in model: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let download = fixture.download
        let row = try XCTUnwrap(model.bookByID(download.id), "the download left the library", file: file, line: line)
        XCTAssertNil(row.feedLink, file: file, line: line)
        XCTAssertEqual(row.folderPath, folder, file: file, line: line)
        XCTAssertEqual(row.readingPosition, download.readingPosition, file: file, line: line)
        XCTAssertEqual(row.bookmarks, download.bookmarks, file: file, line: line)
        XCTAssertEqual(row.lastOpened, download.lastOpened, file: file, line: line)
        let library = TextMouthPaths.libraryDir
        let expectedFolder = folder.isEmpty ? library : library.appendingPathComponent(folder, isDirectory: true)
        XCTAssertEqual(row.tmbDirectory.standardizedFileURL.path, expectedFolder.appendingPathComponent(download.tmbDirectoryName).standardizedFileURL.path, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath), "the book's file is not where its row says", file: file, line: line)
        XCTAssertEqual(model.library.books.filter { $0.id == download.id }.count, 1, file: file, line: line)
        XCTAssertFalse(model.library.feedShelf.rows.contains { $0.feedLink?.feedID == feedID }, "a row of the feed is still on the shelf", file: file, line: line)
        XCTAssertEqual(model.readingList.bookIDs, [download.id, fixture.book.id], file: file, line: line)

        XCTAssertTrue(try libraryJSONBookIDs().contains(download.id), "library.json does not list the book", file: file, line: line)
        try assertLibraryJSONHoldsNoFeedItem(file: file, line: line)
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, download.id, file: file, line: line)
        XCTAssertEqual(record.metadata.folderPath, folder, file: file, line: line)
        XCTAssertEqual(record.metadata.feedLink, download.feedLink, "the record forgot the feed the book came from", file: file, line: line)
        XCTAssertEqual(record.state.readingPosition, download.readingPosition, file: file, line: line)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.kept.tmbDirectory.path), "the kept package stayed", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedFolderURL.path), "the feed's folder stayed", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.book.filePath), file: file, line: line)

        let next = launchedModel()
        XCTAssertEqual(next.bookByID(download.id)?.folderPath, folder, file: file, line: line)
        XCTAssertNil(next.bookByID(download.id)?.feedLink, file: file, line: line)
        XCTAssertEqual(next.bookByID(download.id)?.readingPosition, download.readingPosition, file: file, line: line)
    }

    /// Removes, when the test ends, the package named `name` that a return
    /// to the library's top level puts there, outside this test's folder.
    private func removeAtTheEnd(topLevelPackageNamed name: String) {
        let package = TextMouthPaths.libraryDir.appendingPathComponent(name, isDirectory: true)
        addTeardownBlock {
            LibraryPersistenceService.flushPendingSave()
            try? FileManager.default.removeItem(at: package)
        }
    }

    /// Removes the item at `url` for good, never to the Trash, as a test
    /// must.
    private static func deleteForGood(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - The Unsubscribe Command

/// Unsubscribe… through the feed commands' runner, as the Library window runs
/// it (REV10, item 3): its question names the downloads that stay and what
/// the feed kept of removed downloads, which goes; confirmed, the feed ends,
/// VoiceOver hears it at once, and the downloads become books in the feed's
/// folder while the kept package goes.
final class LibraryFeedUnsubscribeCommandTests: XCTestCase {

    /// The download the listener kept and the package kept after another
    /// download went: the question says so, and Unsubscribe makes the first
    /// a book in the feed's folder and deletes the second, with the feed's
    /// own folder.
    @MainActor
    func testUnsubscribeReturnsTheDownloadsAndDeletesWhatTheFeedKept() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedUnsubscribe")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        let keptBook = try XCTUnwrap(books.first)
        let download = try XCTUnwrap(books.last)
        world.library.persistReadingPosition(bookID: keptBook.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, keptBook.id, "the opened download's package was not kept")
        let presenter = LibraryFeedsPresenter()
        let heard = Heard()
        presenter.announce = { message, _ in heard.lines.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)

        let confirmation = try XCTUnwrap(presenter.unsubscribeConfirmation(for: feed.id, in: context))
        XCTAssertEqual(
            confirmation.message,
            FeedWording.unsubscribeMessage(bookTitles: [download.title], folderPath: world.folder.path, keptCount: 1)
        )
        XCTAssertTrue(
            confirmation.message.hasSuffix(" It also deletes the place, bookmarks, and transcript kept for 1 removed download."),
            confirmation.message
        )

        let title = try XCTUnwrap(world.center.store.record(of: feed.id)?.feed.title)
        let outcome = await presenter.unsubscribe(feed.id, in: context)?.value

        XCTAssertTrue(world.center.feeds.isEmpty)
        XCTAssertEqual(heard.lines.last, "Unsubscribed from \(title). 1 book it downloaded stays in the library.")
        XCTAssertEqual(outcome?.returned.map(\.id), [download.id])
        XCTAssertEqual(outcome?.deletedKeptPackages, 1)
        let returned = try XCTUnwrap(world.library.bookByID(download.id))
        XCTAssertNil(returned.feedLink)
        XCTAssertEqual(returned.folderPath, world.folder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: returned.filePath))
        XCTAssertTrue(returned.tmbDirectory.path.hasPrefix(world.folder.url.path), returned.tmbDirectory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptBook.tmbDirectory.path), "the kept package stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root).path))
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
    }

    /// The question's last sentence, which names what unsubscribing deletes
    /// of downloads removed earlier, as VoiceOver reads it, and none when the
    /// feed kept nothing.
    func testTheQuestionNamesWhatTheFeedKept() {
        let stops = "TextMouth stops checking this feed and forgets the items it hasn't downloaded."
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(bookTitles: ["One"], folderPath: "Atlas", keptCount: 1),
            "\(stops) This book it downloaded stays in Atlas: “One”. "
                + "It also deletes the place, bookmarks, and transcript kept for 1 removed download."
        )
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(bookTitles: [], folderPath: nil, keptCount: 3),
            "\(stops) Nothing it downloaded is left. It also deletes the places, bookmarks, and transcripts kept for 3 removed downloads."
        )
        XCTAssertEqual(
            FeedWording.unsubscribeMessage(bookTitles: [], folderPath: "Atlas", keptCount: 0),
            "\(stops) Nothing it downloaded is left; its folder stays in Atlas."
        )
    }

    // MARK: - Fixtures

    /// What VoiceOver was asked to say, in order.
    @MainActor
    private final class Heard {
        var lines: [String] = []
    }

    /// Starts `world`'s engine, subscribes it to a feed of `count` episodes,
    /// and downloads each; returns the feed and the books, episode 1 first.
    @MainActor
    private func downloadedEpisodes(_ count: Int, in world: FeedTestWorld) async throws -> (Feed, [Book]) {
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        let items = (1...count).map { number in
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
            return FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(Double(-number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        var books: [Book] = []
        for number in 1...count {
            world.center.download("guid:ep-\(number)", of: feed.id)
            books.append(try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)"))
        }
        return (feed, books)
    }
}
