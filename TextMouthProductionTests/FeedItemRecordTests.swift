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

    // MARK: - Downloading Again

    /// Downloading again an item whose package was kept restores the same
    /// book: the same ID and package, its place, playback times, bookmarks,
    /// and settings, in its row and its record, and its transcript, copied
    /// into the new package and read again there, as the new file's audio
    /// is the one transcribed; the row joins the books, leaving the shelf,
    /// and the item is downloaded as that book.
    func testDownloadingAgainRestoresTheSameBook() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRestore")
        let (feed, book, transcript) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)

        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(restored.tmbDirectory, book.tmbDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.filePath))
        try assertKeepsTheListenersState(restored, of: book, "the restored row")
        try assertKeepsTheListenersState(try recordedBook(in: restored.tmbDirectory), of: book, "the restored record")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: restored.tmbDirectory)), transcript)
        let index = try XCTUnwrap(BookInfo.load(from: restored.tmbDirectory).contentIndex)
        XCTAssertNotNil(TranscriptTextLoader.load(for: restored, audioIndex: index).text, "the transcript of the same audio shows no text")
    }

    /// A transcript whose audio differs from the new download's, as when a
    /// host inserts other advertisements into each download, is kept in the
    /// restored package, and the episode finds it stale: one
    /// TRANSCRIPT_STALE line, and no text until it is transcribed again.
    func testATranscriptOfOtherAudioIsKeptAndFoundStale() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRestoreStale")
        let (feed, book, transcript) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 2), mimeType: "audio/mp4"))

        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        let stale = "\(TranscriptTextLoader.staleTag): \(restored.title)"
        let staleBefore = debugLogLines(containing: stale).count
        let index = try XCTUnwrap(BookInfo.load(from: restored.tmbDirectory).contentIndex)

        XCTAssertNil(TranscriptTextLoader.load(for: restored, audioIndex: index).text)
        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: restored.tmbDirectory)), transcript)
        XCTAssertEqual(debugLogLines(containing: stale).count, staleBefore + 1)
    }

    // MARK: - Delete Episode

    /// Delete Episode deletes an item's package whole, whether its package
    /// was kept after its file went or its file is here and opened: no row
    /// stays on the shelf, among the books, or in the feed's index, and
    /// both items leave the feed's list.
    func testDeleteEpisodeDeletesThePackageKeptOrNot() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordDeleteEpisode")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        let kept = try listen(to: books[0], in: world)
        let opened = try listen(to: books[1], in: world)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [kept.id])

        try world.center.deleteItem("guid:ep-1", of: feed.id)
        try world.center.deleteItem("guid:ep-2", of: feed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.tmbDirectory.path), "the kept package stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.tmbDirectory.path), "the opened download's package was kept")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertNil(world.library.bookByID(opened.id))
        XCTAssertEqual(try indexedRows(of: feed.id), [])
        XCTAssertEqual(world.center.listedItems(of: feed.id), [])
        XCTAssertEqual(world.center.keptRecordItemIDs(of: feed.id), [])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .notDownloaded)
    }

    /// Delete Episode while a download of the item imports, which it cannot
    /// stop once begun, leaves nothing of the item: the import lists no row
    /// for it and deletes the package it published, whether the download
    /// was new or restoring the item's kept package; the item stays deleted,
    /// and no download is announced as finished.
    func testDeleteEpisodeWhileADownloadImportsLeavesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordDeleteDuringImport")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        // Episode 1's package kept with its place; episode 2's, never
        // opened, gone whole.
        let kept = try listen(to: books[0], in: world)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        try world.center.deleteDownload("guid:ep-2", of: feed.id)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [kept.id])
        var finished: [FeedItem.ID] = []
        let subscription = world.center.events.sink { event in
            if case .downloadFinished(_, let itemID, _) = event {
                finished.append(itemID)
            }
        }
        defer { subscription.cancel() }
        // Delete Episode as each import ends, just before its book is listed.
        world.center.downloads.beforeCommit = { request in
            try? world.center.deleteItem(request.itemID, of: request.feedID)
        }

        for itemID in ["guid:ep-1", "guid:ep-2"] {
            world.center.download(itemID, of: feed.id)
            await waitFor("\(itemID)'s download ends") {
                world.center.downloads.current == nil
                    && world.center.store.record(of: feed.id)?.item(itemID)?.deletedDate != nil
            }
        }

        XCTAssertEqual(finished, [], "a download of a deleted item was announced as finished")
        XCTAssertFalse(world.library.library.books.contains { $0.feedLink?.feedID == feed.id }, "a deleted item's book was listed")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.tmbDirectory.path), "the restored package stayed")
        let folder = FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)
        let packages = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tmb") }
        XCTAssertEqual(packages, [], "a deleted item's package stayed")
        for itemID in ["guid:ep-1", "guid:ep-2"] {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            XCTAssertNotNil(item.deletedDate, itemID)
            XCTAssertNil(item.state.bookID, itemID)
        }
    }

    // MARK: - What a Refresh Keeps

    /// A merge keeps in the record, however far outside the newest it
    /// falls, an item played, with its played date (board #1412), and an
    /// item whose package was kept; an item neither played nor kept leaves
    /// the record outside the newest, as before.
    func testAMergeKeepsPlayedItemsAndKeptRecordsOutsideTheNewest() throws {
        let address = try XCTUnwrap(URL(string: "https://atlas.example/feed.xml"))
        let items = (1...4).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: Self.whole(Double(number) * 86_400))
        }
        var record = FeedRecord(feed: Feed(feedURL: address, folderID: UUID(), subscribedDate: Self.whole(0)))
        var texts = FeedTextCache()
        let everything = try FeedParser.parse(Data(FeedXML.rss(items: items).utf8), baseURL: address)
        FeedReconciler.merge(everything, into: &record, keepEntries: -1, now: Self.whole(5 * 86_400), texts: &texts)
        let played = Self.whole(6 * 86_400)
        let playedIndex = try XCTUnwrap(record.index(of: "guid:ep-1"))
        record.items[playedIndex].playedDate = played

        let newestOnly = try FeedParser.parse(Data(FeedXML.rss(items: [items[3]]).utf8), baseURL: address)
        FeedReconciler.merge(
            newestOnly,
            into: &record,
            keepEntries: 1,
            now: Self.whole(7 * 86_400),
            texts: &texts,
            keepingRecordsOf: ["guid:ep-2"]
        )

        XCTAssertEqual(Set(record.items.map(\.id)), ["guid:ep-4", "guid:ep-2", "guid:ep-1"])
        XCTAssertEqual(record.item("guid:ep-1")?.playedDate, played)
    }

    /// A refresh keeps the item of a row the library kept after its file
    /// went, found through the library model, and a played item, when the
    /// feed's own short list leaves both outside the newest (FR11); both
    /// stay in the record, hidden from the list, which lists the newest.
    func testARefreshKeepsTheItemsOfKeptRowsAndPlayedItems() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRefreshKeeps")
        await world.start()
        let items = (1...3).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(Double(-4 + number)))
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        world.library.library.feedShelf.put(Self.row("Two", feedID: feed.id, itemID: "guid:ep-2"))
        world.center.markPlayed("guid:ep-1", of: feed.id)
        world.center.setItemPolicy(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 1), of: feed.id)

        await world.center.refresh(feed.id)

        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(Set(record.items.map(\.id)), ["guid:ep-3", "guid:ep-2", "guid:ep-1"])
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.id), ["guid:ep-3"])
        XCTAssertEqual(world.center.keptRecordItemIDs(of: feed.id), ["guid:ep-2"])
    }

    // MARK: - A Failed Index Write

    /// When the feed's index cannot be written, Delete Download keeps the
    /// file and the row among the books, with the place, refuses saying
    /// why, and leaves the item downloaded, the failure reported; once the
    /// index can be written, Delete Download goes ahead, and the write that
    /// succeeds settles the failure.
    func testAFailedIndexWriteKeepsTheFile() async throws {
        let failures = cleanSharedFailureCenter()
        let world = try FeedTestWorld(self, label: "FeedRecordIndexFails")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        LibraryPersistenceService.flushPendingSave()
        let obstruction = try WriteObstruction.place(at: FeedPaths.indexFile(of: feed.id, in: TextMouthPaths.root))
        defer { obstruction.clear() }
        let book = try listen(to: try XCTUnwrap(books.first), in: world)

        XCTAssertThrowsError(try world.center.deleteDownload("guid:ep-1", of: feed.id)) { error in
            XCTAssertEqual(error as? FeedItemPackageError, .indexNotWritten)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "the file went before its row was in the index")
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, 42)
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(failures.outstandingFailures().map(\.subject), [.libraryIndex])

        obstruction.clear()
        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertEqual(try indexedRows(of: feed.id).map(\.id), [book.id])
        XCTAssertEqual(failures.outstandingFailures().map(\.subject), [], "the index write that succeeded settled nothing")
    }

    /// When the feed's index cannot be written, the rule deleting played
    /// downloads removes no file, of a download opened or not, keeps every
    /// row among the books, and says so in one line of the debug log.
    func testASweepWhoseIndexCannotBeWrittenKeepsEveryFile() async throws {
        _ = cleanSharedFailureCenter()
        let world = try FeedTestWorld(self, label: "FeedRecordSweepIndexFails")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        LibraryPersistenceService.flushPendingSave()
        let obstruction = try WriteObstruction.place(at: FeedPaths.indexFile(of: feed.id, in: TextMouthPaths.root))
        defer { obstruction.clear() }
        _ = try listen(to: books[0], in: world)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        world.center.markPlayed("guid:ep-2", of: feed.id)
        let putOffBefore = debugLogLines(containing: "FEED_SWEEP_PUT_OFF").count

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.deletedBookIDs, [])
        for book in books {
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), book.title)
            XCTAssertNotNil(world.library.bookByID(book.id), book.title)
        }
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(world.center.listedItems(of: feed.id).compactMap(\.state.bookID).count, 2)
        XCTAssertEqual(debugLogLines(containing: "FEED_SWEEP_PUT_OFF").count, putOffBefore + 1)
    }

    // MARK: - What a Refusal Says

    /// What a refused removal says, as its alert shows it and VoiceOver
    /// speaks it: a download not where its feed keeps it, a feed's list
    /// that could not be saved first, and Remove from Library Only on a
    /// feed's item.
    func testWhatARefusedRemovalSays() {
        XCTAssertEqual(
            FeedItemPackageError.notAFeedPackage.localizedDescription,
            "This download isn't where its feed keeps its downloads, so TextMouth left its files as they are."
        )
        XCTAssertEqual(
            FeedItemPackageError.indexNotWritten.localizedDescription,
            "TextMouth couldn't save its list of this feed's downloads, so the download was kept. Try again once the library can be saved."
        )
        XCTAssertEqual(
            FeedItemPackageError.staysInItsFeed.localizedDescription,
            "It belongs to its feed while it is downloaded. Delete Download removes its file and keeps its place and bookmarks."
        )
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

    /// Downloads episode 1 into `world`, listens to it, gives it a transcript
    /// of its audio as the transcription service makes one, and deletes its
    /// download, which keeps its package. Returns the feed, the row as the
    /// listener left it, and transcript.json's bytes.
    private func transcribedEpisodeWhoseDownloadWasDeleted(in world: FeedTestWorld) async throws -> (Feed, Book, Data) {
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        let heard = try TranscriptionPlan.make(for: book).files.map { file in
            (file.path, [TranscriptFixtures.sentence("Quillwort grows by the ferry slip.", from: 0, to: 900)])
        }
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Dictionary(uniqueKeysWithValues: heard))
        _ = try TranscriptStore.write(transcript, into: book.tmbDirectory)
        let bytes = try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id], "the transcribed download's package was not kept")
        return (feed, book, bytes)
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
