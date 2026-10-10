import XCTest
@testable import TextMouth

/// FR11's branch A2: a feed item's row is found by its item's identity, a
/// removed download keeps its package and record while it holds something
/// of the listener's, and downloading it again restores the same book.
@MainActor
final class FeedItemRecordTests: XCTestCase {

    // MARK: - Rows by Item

    /// Each feed's rows are found by the identity of the item each came
    /// from: a feed item among the books as downloaded, one on the shelf as
    /// kept, each under its own feed, and a book of the library's own under
    /// none.
    func testRowsAreFoundByTheirItemsIdentity() {
        let feedID = UUID()
        let otherFeedID = UUID()
        let downloaded = Self.row("Downloaded", feedID: feedID, itemID: "guid:one")
        let kept = Self.row("Kept", feedID: feedID, itemID: "guid:two")
        let elsewhere = Self.row("Elsewhere", feedID: otherFeedID, itemID: "guid:one")
        let book = Book(title: "A Book of the Library's Own", format: .txt, filePath: "/Book.txt", md5Hash: "")
        let library = Library(books: [book, downloaded, elsewhere], feedShelf: FeedShelf(rows: [kept]))

        let rows = FeedItemRows.byFeed(in: library)

        XCTAssertEqual(rows[feedID]?.downloaded, ["guid:one": downloaded])
        XCTAssertEqual(rows[feedID]?.kept, ["guid:two": kept])
        XCTAssertEqual(rows[otherFeedID]?.downloaded, ["guid:one": elsewhere])
        XCTAssertEqual(rows.count, 2, "a book of the library's own is a feed's row")
    }

    /// The library model's lookups follow every change of its library: a
    /// book added is found by its ID, one taken out is not, and a feed
    /// item's row moving to the shelf is found as kept.
    func testTheLookupsFollowEveryChangeOfTheLibrary() {
        let feedID = UUID()
        let model = LibraryViewModel(initializeServices: false)
        let book = Book(title: "Found", format: .txt, filePath: "/Found.txt", md5Hash: "")
        let row = Self.row("Episode", feedID: feedID, itemID: "guid:ep")
        model.library = Library(books: [book, row])
        XCTAssertEqual(model.feedBook(withID: book.id)?.title, "Found")
        XCTAssertEqual(model.feedItemRows(of: feedID).downloaded["guid:ep"]?.id, row.id)

        model.library.removeBook(id: book.id)
        model.library.removeBook(id: row.id)
        model.library.feedShelf.put(row)

        XCTAssertNil(model.feedBook(withID: book.id))
        XCTAssertNil(model.feedBook(withID: row.id), "a kept row is not a book of the library model")
        XCTAssertEqual(model.feedItemRows(of: feedID).downloaded, [:])
        XCTAssertEqual(model.feedItemRows(of: feedID).kept["guid:ep"]?.id, row.id)
    }

    /// A feed's counts and its items' states find each row by the item's
    /// identity: an item whose row is here is downloaded and, never opened,
    /// new; an item whose row was kept after its file went is neither
    /// downloaded nor, once opened, new; an item whose book the library no
    /// longer lists is not downloaded.
    func testCountsAndStatesFindRowsByTheirItemsIdentity() async throws {
        let world = try FeedTestWorld(self, label: "FeedRowsByItem")
        let feed = try await subscribeToThreeEpisodes(in: world)
        let downloaded = Self.row("One", feedID: feed.id, itemID: "guid:ep-1")
        var kept = Self.row("Two", feedID: feed.id, itemID: "guid:ep-2")
        kept.lastOpened = world.clock.value
        world.library.library.books.append(downloaded)
        world.library.library.feedShelf.put(kept)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.state = .downloaded(bookID: downloaded.id) }
        world.center.store.updateItem("guid:ep-3", of: feed.id) { $0.state = .downloaded(bookID: UUID()) }

        let counts = world.center.counts(of: feed.id)

        XCTAssertEqual(counts.downloaded, 1)
        XCTAssertEqual(counts.new, 2, "the kept, opened item counts as new")
        let items = Dictionary(uniqueKeysWithValues: world.center.listedItems(of: feed.id).map { ($0.id, $0) })
        let one = try XCTUnwrap(items["guid:ep-1"])
        let two = try XCTUnwrap(items["guid:ep-2"])
        let three = try XCTUnwrap(items["guid:ep-3"])
        XCTAssertEqual(world.center.state(of: one, in: feed.id), .downloaded(bookID: downloaded.id))
        XCTAssertEqual(world.center.downloadedRow(of: one, in: feed.id)?.id, downloaded.id)
        XCTAssertEqual(world.center.state(of: three, in: feed.id), .notDownloaded, "a book the library lost is downloaded")
        XCTAssertTrue(world.center.isNew(one, of: feed))
        XCTAssertFalse(world.center.isNew(two, of: feed), "a kept record that was opened is new")
        XCTAssertTrue(world.center.isNew(three, of: feed))
    }

    // MARK: - Removing a Download

    /// Delete Download of a download never opened leaves nothing: its
    /// package goes whole, no row stays on the shelf, its feed's index on
    /// disk lists nothing, and the item is not downloaded.
    func testDeletingANeverOpenedDownloadLeavesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordNeverOpened")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try XCTUnwrap(books.first)

        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(try indexedRows(of: feed.id), [])
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(item.state, .notDownloaded)
        XCTAssertEqual(item.downloadDeletedDate, world.clock.value)
    }

    /// Delete Download of a download the listener opened keeps its package
    /// without its file: its record, content index, and transcript stay,
    /// while the file and the speech prepared from it go; its row, with its
    /// place, playback times, bookmarks, and settings, moves to its feed's
    /// shelf and is in its feed's index on disk; the item is not downloaded.
    func testDeletingAnOpenedDownloadKeepsItsPackageAndRecord() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordOpened")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        let package = book.tmbDirectory
        let transcript = Data("{\"kept\": true}".utf8)
        try transcript.write(to: TextMouthPaths.transcriptPath(in: package))
        let speech = TextMouthPaths.cachedAudioDir(in: package)
        try FileManager.default.createDirectory(at: speech, withIntermediateDirectories: true)
        try Data("prepared".utf8).write(to: speech.appendingPathComponent("chapter-0.caf"))

        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath), "the file stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: speech.path), "the speech prepared from it stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentIndexPath(in: package).path))
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: package)), transcript)
        try assertKeepsTheListenersState(try recordedBook(in: package), of: book, "the record")
        XCTAssertNil(world.library.bookByID(book.id))
        try assertKeepsTheListenersState(
            try XCTUnwrap(world.library.library.feedShelf.rows.first { $0.id == book.id }), of: book, "the shelf's row")
        try assertKeepsTheListenersState(try XCTUnwrap(indexedRows(of: feed.id).first { $0.id == book.id }), of: book, "the index's row")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, book.id)
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(item.state, .notDownloaded)
        XCTAssertEqual(item.downloadDeletedDate, world.clock.value)
    }

    /// The rule deleting played downloads removes each due file as Delete
    /// Download does: a download the listener opened keeps its package and
    /// row, and one never opened goes whole.
    func testTheSweepKeepsWhatTheListenerOpenedAndDeletesTheRest() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordSweep")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        let opened = try listen(to: books[0], in: world)
        let unopened = books[1]
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        world.center.markPlayed("guid:ep-2", of: feed.id)

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(Set(report.deletedBookIDs), [opened.id, unopened.id])
        XCTAssertEqual(report.keptPackageBookIDs, [opened.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: opened.tmbDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.filePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopened.tmbDirectory.path))
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [opened.id])
        XCTAssertEqual(try indexedRows(of: feed.id).map(\.id), [opened.id])
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.state), [.notDownloaded, .notDownloaded])
    }

    /// The library's Remove of a feed item is its Delete Download: the file
    /// goes, an opened item's package and row stay, and the item is not
    /// downloaded. Remove from Library Only refuses, saying why, and leaves
    /// the download as it was, since retiring the package would delete its
    /// record.
    func testTheLibrarysRemoveOfAFeedItemIsItsDeleteDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordLibraryRemove")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)

        world.library.removeBooksFromLibraryOnly([book])

        XCTAssertTrue(world.library.showError)
        XCTAssertTrue(world.library.errorMessage?.contains(try XCTUnwrap(FeedItemPackageError.staysInItsFeed.errorDescription)) ?? false)
        XCTAssertNotNil(world.library.bookByID(book.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path))
        world.library.showError = false

        let outcome = world.library.removeBooksAndDeleteReturningOutcome([book])

        if case .failure(let message) = outcome {
            XCTFail(message)
        }
        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path))
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
    }

    // MARK: - Helpers

    /// A date `seconds` after a fixed start, in whole seconds, which the
    /// ISO 8601 dates of an index and a record keep exactly.
    static func whole(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_791_000_000 + seconds)
    }

    /// Plays `book` as a reader does, through the library model's functions
    /// a reader calls: a place, playback times, a bookmark, a playback speed
    /// of its own, and a skipped heading. Returns the row as the library holds it
    /// then.
    private func listen(to book: Book, in world: FeedTestWorld) throws -> Book {
        let library = world.library
        var position = ReadingPosition(chapterIndex: 0, characterOffset: 42)
        position.lastUpdated = Self.whole(100)
        library.persistReadingPosition(bookID: book.id, position: position)
        library.updatePlaybackTimestamps(bookID: book.id, started: Self.whole(40), stopped: Self.whole(100))
        library.addBookmark(bookID: book.id, chapterIndex: 0, characterOffset: 21, label: "The good part")
        library.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: nil, wpm: 1.5)
        library.updateSkippedHeadings(bookID: book.id, skippedIDs: ["credits"])
        return try XCTUnwrap(library.bookByID(book.id))
    }

    /// Fails unless `kept` holds what the listener left in `listened`: its
    /// ID, place, playback times, bookmarks, speed, and skipped headings.
    private func assertKeepsTheListenersState(
        _ kept: Book,
        of listened: Book,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(kept.id, listened.id, what, file: file, line: line)
        XCTAssertEqual(kept.readingPosition?.chapterIndex, listened.readingPosition?.chapterIndex, what, file: file, line: line)
        XCTAssertEqual(kept.readingPosition?.characterOffset, listened.readingPosition?.characterOffset, what, file: file, line: line)
        XCTAssertEqual(kept.readingPosition?.lastUpdated, listened.readingPosition?.lastUpdated, what, file: file, line: line)
        XCTAssertNotNil(kept.lastOpened, what, file: file, line: line)
        XCTAssertEqual(kept.lastPlaybackStarted, listened.lastPlaybackStarted, what, file: file, line: line)
        XCTAssertEqual(kept.lastPlaybackStopped, listened.lastPlaybackStopped, what, file: file, line: line)
        XCTAssertEqual(kept.bookmarks.map(\.id), listened.bookmarks.map(\.id), what, file: file, line: line)
        XCTAssertEqual(kept.bookmarks.map(\.label), ["The good part"], what, file: file, line: line)
        XCTAssertEqual(kept.bookmarks.map(\.characterOffset), [21], what, file: file, line: line)
        XCTAssertEqual(kept.localWPM, 1.5, what, file: file, line: line)
        XCTAssertEqual(kept.skippedHeadingIDs, ["credits"], what, file: file, line: line)
    }

    /// The book the record of the package at `package` describes.
    private func recordedBook(in package: URL) throws -> Book {
        let record = try BookInfo.load(from: package)
        return Book(
            record: record,
            filePath: package.appendingPathComponent(record.metadata.originalFileName).path,
            folderPath: "",
            tmbDirectoryName: package.lastPathComponent
        )
    }

    /// The rows the feed `feedID`'s index holds on disk.
    private func indexedRows(of feedID: UUID) throws -> [Book] {
        try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: feedID, in: TextMouthPaths.root))).books
    }

    /// Starts `world`'s engine, subscribes it to a feed of `count`
    /// episodes, "guid:ep-1" onwards, each a second of silence, downloads
    /// each, and returns the feed and the books, in the episodes' order.
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

    /// A feed item's row titled `title`, of the item `itemID` of the feed
    /// `feedID`, with no package behind it.
    static func row(_ title: String, feedID: UUID, itemID: String) -> Book {
        Book(
            title: title,
            format: .audio,
            filePath: "/\(title).m4a",
            md5Hash: "",
            tmbDirectoryName: "\(title).tmb",
            feedLink: FeedBookLink(feedID: feedID, itemID: itemID)
        )
    }

    /// Starts `world`'s engine and subscribes it to a feed of three
    /// episodes, "guid:ep-1" to "guid:ep-3", published after the
    /// subscription began, so each is new until played or opened.
    private func subscribeToThreeEpisodes(in world: FeedTestWorld) async throws -> Feed {
        await world.start()
        let items = (1...3).map { number in
            FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(Double(number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }
}
