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

    /// A book whose ID the library's books hold twice, as no write makes
    /// them, is found at its first place by the feed rows' lookup, as
    /// `bookByID` and the list cache find it (`LibraryListCache.index(of:)`).
    func testABookListedTwiceIsFoundAtItsFirstPlace() {
        let model = LibraryViewModel(initializeServices: false)
        let first = Book(title: "First", format: .txt, filePath: "/First.txt", md5Hash: "")
        var second = first
        second.title = "Second"
        model.library = Library(books: [first, second])

        XCTAssertEqual(model.feedBook(withID: first.id)?.title, "First")
        XCTAssertEqual(model.bookByID(first.id)?.title, "First")
        XCTAssertEqual(LibraryListCache.index(of: [first, second]), [first.id: 0])
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

    // MARK: - The Order of a Removal, and One That Fails

    /// The listener's latest place reaches the record, and the row the
    /// feed's index, before the file's removal begins: when it begins, the
    /// record on disk already holds a place saved a moment before, which was
    /// still waiting in the record's debounce, and the index on disk lists
    /// the row with that place.
    func testTheRecordAndTheIndexAreWrittenBeforeTheFileGoes() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRemovalOrder")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        var position = ReadingPosition(chapterIndex: 0, characterOffset: 77)
        position.lastUpdated = Self.whole(200)
        world.library.persistReadingPosition(bookID: book.id, position: position)
        let latest = try XCTUnwrap(world.library.bookByID(book.id))
        var recordedAtRemoval: Int?
        var indexedAtRemoval: Int?

        let outcome = try world.library.removeFeedFiles(of: [latest], keepingPackages: true) { removal in
            recordedAtRemoval = try recordedBook(in: removal.row.tmbDirectory).readingPosition?.characterOffset
            indexedAtRemoval = try indexedRows(of: feed.id).first { $0.id == book.id }?.readingPosition?.characterOffset
            try FileManager.default.removeItem(at: removal.row.bookFileURL)
        }

        XCTAssertEqual(outcome.removed.map(\.row.id), [book.id])
        XCTAssertEqual(recordedAtRemoval, 77, "the file's removal began before the record held the latest place")
        XCTAssertEqual(indexedAtRemoval, 77, "the file's removal began before the feed's index listed the row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath))
    }

    /// A removal readied with what a read off the main thread found for the
    /// packages uses those answers and reads nothing itself (the removal of
    /// many episodes read each transcript.json on the main actor): an
    /// answer of "holds files" keeps a package whose folder holds none, and
    /// an answer of "holds none" lets a package go whole though its folder
    /// now holds a transcript of the listener's. A book without an answer is
    /// read, as ever, and the answers a read off the main thread gives
    /// (`FeedItemPackage.listenersFilesHeld(in:)`) are those of reading
    /// each package.
    func testAReadiedRemovalUsesTheAnswersReadOffTheMainThread() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordPrereadAnswers")
        let (_, books) = try await downloadedEpisodes(3, in: world)
        let (told, contradicted, unasked) = (books[0], books[1], books[2])
        // `contradicted` holds a recognized transcript, the listener's.
        try TranscriptStore.write(
            TranscriptFixtures.transcript([(path: "a.m4a", duration: 1_000, sentences: [TranscriptFixtures.sentence("Heard.", from: 0, to: 500)])]),
            into: contradicted.tmbDirectory
        )
        XCTAssertTrue(FeedItemPackage.holdsListenersFiles(contradicted.tmbDirectory), "the test's transcript is not the listener's")
        XCTAssertFalse(FeedItemPackage.holdsListenersFiles(told.tmbDirectory))
        XCTAssertEqual(
            FeedItemPackage.listenersFilesHeld(in: [
                told.id: told.tmbDirectory, contradicted.id: contradicted.tmbDirectory,
            ]),
            [told.id: false, contradicted.id: true],
            "the answers read off the main thread are not those of reading each package"
        )

        let readied = try world.library.readyFeedFilesForRemoval(
            of: [told, contradicted, unasked],
            keepingPackages: true,
            listenersFilesHeld: [told.id: true, contradicted.id: false]
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: readied.map { ($0.row.id, $0.keepsPackage) }),
            [told.id: true, contradicted.id: false, unasked.id: false],
            "the readied removal did not use the answers it was given (told, contradicted, unasked)"
        )
    }

    /// When files cannot be removed, each row goes back where it was, with
    /// its place, still on the reading list: an opened download's row, which
    /// had moved to its feed's shelf, and an unopened one's, which had left
    /// the feed's index, are among the books again, and the index, written
    /// without the unopened one before the removal began, lists it again.
    func testRowsWhoseFilesCannotBeRemovedGoBackAmongTheBooks() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRemovalFails")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        let opened = try listen(to: books[0], in: world)
        let unopened = books[1]
        world.library.addToReadingList([opened.id, unopened.id])
        var indexedAtRemoval: [UUID: Bool] = [:]

        let outcome = try world.library.removeFeedFiles(of: [opened, unopened], keepingPackages: true) { removal in
            indexedAtRemoval[removal.row.id] = try indexedRows(of: feed.id).contains { $0.id == removal.row.id }
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(outcome.failures.map(\.row.id), [opened.id, unopened.id])
        XCTAssertEqual(indexedAtRemoval, [opened.id: true, unopened.id: false])
        XCTAssertEqual(world.library.bookByID(opened.id)?.readingPosition?.characterOffset, 42)
        XCTAssertNotNil(world.library.bookByID(unopened.id))
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(world.library.readingList.bookIDs, [opened.id, unopened.id])
        for book in books {
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), book.title)
        }
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(Set(try indexedRows(of: feed.id).map(\.id)), [opened.id, unopened.id], "the index was not written again")
    }

    /// When Delete Episode cannot remove the package kept on its feed's
    /// shelf, the row goes back to the shelf, not among the books, and the
    /// feed's index, written without it before the removal began, lists it
    /// again.
    func testAShelfRowWhosePackageCannotBeRemovedGoesBackToTheShelf() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordShelfRemovalFails")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        let kept = try XCTUnwrap(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"])
        var indexedAtRemoval: Bool?

        let outcome = try world.library.removeFeedFiles(of: [kept], keepingPackages: false) { removal in
            XCTAssertTrue(removal.wasOnShelf)
            indexedAtRemoval = try indexedRows(of: feed.id).contains { $0.id == book.id }
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertEqual(outcome.failures.map(\.row.id), [book.id])
        XCTAssertEqual(indexedAtRemoval, false)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id])
        XCTAssertNil(world.library.bookByID(book.id), "a kept row went among the books")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path))
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedRows(of: feed.id).map(\.id), [book.id], "the index was not written again")
    }

    // MARK: - An Article's Text

    /// The after-playing rule never deletes an article's text: it removes an
    /// opened article's HTML file and keeps its content.md, edited by hand
    /// before feed items lost Edit Text, beside its record; an article never
    /// opened whose package holds a copy Edit Text kept counts as the
    /// listener's, so its package stays with the copy and its text.
    func testTheAfterPlayingRuleKeepsAnArticlesText() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleSweep")
        let feed = try await subscribeToArticles(2, in: world)
        var articles: [Book] = []
        for number in 1...2 {
            world.center.download("guid:post-\(number)", of: feed.id)
            articles.append(try await downloadedBook(world, feed: feed, item: "guid:post-\(number)"))
        }
        let opened = try listen(to: articles[0], in: world)
        let editedText = TextMouthPaths.contentMarkdownPath(in: opened.tmbDirectory)
        try "# Edited by hand".write(to: editedText, atomically: true, encoding: .utf8)
        let neverOpened = articles[1]
        let copy = neverOpened.tmbDirectory.appendingPathComponent("content.md\(TextMouthPaths.keptTextCopyMarker)20261010T020000Z")
        try "# An edit not taken".write(to: copy, atomically: true, encoding: .utf8)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:post-1", of: feed.id)
        world.center.markPlayed("guid:post-2", of: feed.id)

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(Set(report.deletedBookIDs), [opened.id, neverOpened.id])
        XCTAssertEqual(Set(report.keptPackageBookIDs), [opened.id, neverOpened.id], "an article holding the listener's text went whole")
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.filePath), "the opened article's file stayed")
        XCTAssertEqual(try String(contentsOf: editedText, encoding: .utf8), "# Edited by hand")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: opened.tmbDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverOpened.filePath), "the unopened article's file stayed")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "# An edit not taken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentMarkdownPath(in: neverOpened.tmbDirectory).path))
        XCTAssertEqual(Set(world.library.feedItemRows(of: feed.id).kept.keys), ["guid:post-1", "guid:post-2"])
    }

    /// The newest-N rule never deletes an article's text either: holding
    /// more of its downloads than the number, it removes the oldest's HTML
    /// file, keeping its package with its place and its content.md, edited
    /// by hand, beside its record.
    func testTheNewestRuleKeepsAnArticlesText() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleNewest")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let feed = try await subscribeToArticles(2, in: world)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let newest = try await downloadedBook(world, feed: feed, item: "guid:post-1")
        let oldest = try listen(to: try await downloadedBook(world, feed: feed, item: "guid:post-2"), in: world)
        let editedText = TextMouthPaths.contentMarkdownPath(in: oldest.tmbDirectory)
        try "# Edited by hand".write(to: editedText, atomically: true, encoding: .utf8)

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.removedBookIDs, [oldest.id])
        XCTAssertEqual(report.keptPackageBookIDs, [oldest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.filePath), "the oldest article's file stayed")
        XCTAssertEqual(try String(contentsOf: editedText, encoding: .utf8), "# Edited by hand")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: oldest.tmbDirectory).path))
        XCTAssertNotNil(world.library.bookByID(newest.id))
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

    /// A restored record's note of its transcript follows its new index, as
    /// every record's note does: the kept record noted the transcript its
    /// index held, the new download's index holds no transcript layer, so
    /// the restored record notes none, though its package keeps the
    /// transcript; once the episode opens and its text is laid over the
    /// index again, the record notes it again.
    func testARestoredRecordsTranscriptNoteFollowsItsIndex() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRestoreNote")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        _ = try transcribe(book)
        try layTranscriptOverItsIndex(of: book, in: world)
        let note = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.transcript, "the opened episode's record noted no transcript")
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.transcript, note, "the kept record lost its note")

        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        let record = try BookInfo.load(from: restored.tmbDirectory)
        XCTAssertNil(record.contentIndex?.transcript)
        XCTAssertNil(record.state.transcript, "the restored record notes a transcript its index does not hold")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: restored.tmbDirectory).path))

        try layTranscriptOverItsIndex(of: restored, in: world)

        let reopened = try BookInfo.load(from: restored.tmbDirectory)
        XCTAssertEqual(reopened.state.transcript, note)
        XCTAssertEqual(reopened.contentIndex?.transcript?.transcript, note)
    }

    /// An audiobook's content.md holding a save no session took, as when a
    /// rule removed the episode's download while Edit Text's session was
    /// open and the listener saved afterwards, differs from the digest its
    /// record's transcript layer recorded: downloading the episode again
    /// keeps those bytes in the restored package as an `.edited-` copy, and
    /// logs it. A content.md that still matches the layer leaves no copy.
    func testDownloadingAnEpisodeAgainKeepsATextSaveNoSessionTook() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRestoreSavedText")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        // Episode 1's text is saved to after its layer was recorded;
        // episode 2's is left as the layer recorded it.
        let saved = try await keptTranscribedText(of: try XCTUnwrap(books.first), item: "guid:ep-1", in: world, feed: feed)
        let untouched = try await keptTranscribedText(of: try XCTUnwrap(books.last), item: "guid:ep-2", in: world, feed: feed)
        let savedText = Data("# Saved after the rule ran".utf8)
        try savedText.write(to: TextMouthPaths.contentMarkdownPath(in: saved.tmbDirectory))
        let keptLines = debugLogLines(containing: "FEED_ARTICLE_TEXT_KEPT: Episode 1").count

        for number in 1...2 {
            world.center.download("guid:ep-\(number)", of: feed.id)
            _ = try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)")
        }

        XCTAssertEqual(try keptCopies(in: saved.tmbDirectory).map { try Data(contentsOf: $0) }, [savedText], "the save was not kept")
        XCTAssertEqual(try keptCopies(in: untouched.tmbDirectory), [], "a copy of a text the record accounts for was kept")
        XCTAssertEqual(debugLogLines(containing: "FEED_ARTICLE_TEXT_KEPT: Episode 1").count, keptLines + 1)
    }

    /// A kept audiobook package with no record, so no transcript layer,
    /// holds no save to keep (`unrecordedTranscriptText(of:)`), whether it
    /// has a content.md or not.
    func testAPackageWithNoLayerOrNoTextHoldsNoUnrecordedText() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("FeedRecordUnrecordedText-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }

        XCTAssertNil(try FeedItemPackage.unrecordedTranscriptText(of: package), "an empty package held a text")

        try Data("# A text".utf8).write(to: TextMouthPaths.contentMarkdownPath(in: package))

        XCTAssertNil(try FeedItemPackage.unrecordedTranscriptText(of: package), "a text with no record was taken for a save")
    }

    /// The `.edited-` copies of a text that the package at `package` holds.
    private func keptCopies(in package: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: package.path)
            .filter(TextMouthPaths.isKeptTextCopy)
            .sorted()
            .map { package.appendingPathComponent($0) }
    }

    /// Listens to `book`, transcribes it and lays its transcript over its
    /// index, as its reader does when it opens (so its content.md is written
    /// and its record's layer records that file's digest), then deletes its
    /// download, which keeps its package. Returns the row as the listener
    /// left it.
    private func keptTranscribedText(of book: Book, item: String, in world: FeedTestWorld, feed: Feed) async throws -> Book {
        let listened = try listen(to: book, in: world)
        _ = try transcribe(listened)
        try layTranscriptOverItsIndex(of: listened, in: world)
        let layer = try XCTUnwrap(BookInfo.load(from: listened.tmbDirectory).contentIndex?.transcript, "the record holds no layer")
        let text = try Data(contentsOf: TextMouthPaths.contentMarkdownPath(in: listened.tmbDirectory))
        XCTAssertEqual(FingerprintHasher.md5.digestOfData(text), layer.textCacheFingerprint.cache.digest, "the layer does not match its text")
        try world.center.deleteDownload(item, of: feed.id)
        XCTAssertNotNil(world.library.library.feedShelf.rows.first { $0.id == listened.id }, "the package was not kept")
        return listened
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

    /// A download restoring a kept item that fails once its package is
    /// staged, its transcript copied in, as when the new file is no audio at
    /// all, leaves everything as it was: the kept package with its record and
    /// transcript, the row on its feed's shelf, and the item not downloaded,
    /// saying why.
    func testARestoreThatFailsAfterStagingLeavesTheKeptPackageAsItWas() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordRestoreFails")
        let (feed, book, transcript) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)
        let record = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(Data("This is no audio at all.".utf8), mimeType: "audio/mp4"))

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download fails") {
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason != nil
                && !world.center.downloads.isDownloading("guid:ep-1", of: feed.id)
        }

        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory)), transcript)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory)), record, "the kept record changed")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, book.id)
        XCTAssertNil(world.library.bookByID(book.id))
        let folder = FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)
        let packages = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmb") }
        XCTAssertEqual(packages, [book.tmbDirectoryName], "the failed download left a package")
    }

    /// The listener's only download is an article. Delete Download of it,
    /// opened, keeps its package with its place and record, its HTML file
    /// and text gone; downloading it again restores the same book, its place
    /// and settings kept, its text read again from the new file.
    func testAnArticleKeepsItsPlaceThroughDeleteDownloadAndDownloadingAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleAgain")
        let feed = try await subscribeToArticles(1, in: world)
        world.center.download("guid:post-1", of: feed.id)
        let article = try listen(to: try await downloadedBook(world, feed: feed, item: "guid:post-1"), in: world)
        let package = article.tmbDirectory
        let text = TextMouthPaths.contentMarkdownPath(in: package)
        XCTAssertEqual(article.format, .html)

        try world.center.deleteDownload("guid:post-1", of: feed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: article.filePath), "the article's file stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path), "Delete Download kept the article's text")
        try assertKeepsTheListenersState(try recordedBook(in: package), of: article, "the kept record")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:post-1"]?.id, article.id)

        world.center.download("guid:post-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:post-1")

        XCTAssertEqual(restored.id, article.id)
        XCTAssertEqual(restored.tmbDirectory, package)
        XCTAssertEqual(restored.format, .html)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "the article's text was not read again")
        try assertKeepsTheListenersState(restored, of: article, "the restored row")
        try assertKeepsTheListenersState(try recordedBook(in: package), of: article, "the restored record")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
    }

    /// Downloading an article again writes its text anew from the new file;
    /// the text the rules kept, which may hold an edit made before feed
    /// items lost Edit Text, stays beside it as an `.edited-` copy when the
    /// two differ, and no copy is made when they are the same (REV11).
    func testDownloadingAnArticleAgainKeepsItsEarlierTextWhenItDiffers() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleEarlierText")
        let feed = try await subscribeToArticles(2, in: world)
        var articles: [Book] = []
        for number in 1...2 {
            world.center.download("guid:post-\(number)", of: feed.id)
            articles.append(try listen(to: try await downloadedBook(world, feed: feed, item: "guid:post-\(number)"), in: world))
        }
        let editedPackage = try XCTUnwrap(articles.first).tmbDirectory
        let untouchedPackage = try XCTUnwrap(articles.last).tmbDirectory
        let editedText = TextMouthPaths.contentMarkdownPath(in: editedPackage)
        try "# Edited by hand".write(to: editedText, atomically: true, encoding: .utf8)
        let untouchedText = try Data(contentsOf: TextMouthPaths.contentMarkdownPath(in: untouchedPackage))
        // The rules remove both files and keep both texts.
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:post-1", of: feed.id)
        world.center.markPlayed("guid:post-2", of: feed.id)
        let report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(Set(report.keptPackageBookIDs), Set(articles.map(\.id)))

        for number in 1...2 {
            world.center.download("guid:post-\(number)", of: feed.id)
            _ = try await downloadedBook(world, feed: feed, item: "guid:post-\(number)")
        }

        let copies = try FileManager.default.contentsOfDirectory(atPath: editedPackage.path).filter(TextMouthPaths.isKeptTextCopy)
        XCTAssertEqual(copies.count, 1, "\(copies)")
        let copy = editedPackage.appendingPathComponent(try XCTUnwrap(copies.first))
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "# Edited by hand")
        XCTAssertNotEqual(try String(contentsOf: editedText, encoding: .utf8), "# Edited by hand", "the new download took the old text for its own")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: untouchedPackage.path).filter(TextMouthPaths.isKeptTextCopy),
            [],
            "a copy of the same text was kept"
        )
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.contentMarkdownPath(in: untouchedPackage)), untouchedText)
    }

    /// Delete Download of an article removes its file and its text, which
    /// may hold an edit, as one item, so the Trash holds one, which puts
    /// both back (REV11); a refused removal puts both back in the package,
    /// and nothing is left beside it.
    func testAnArticlesDeleteDownloadIsOneItem() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleOneItem")
        let feed = try await subscribeToArticles(1, in: world)
        world.center.download("guid:post-1", of: feed.id)
        let article = try listen(to: try await downloadedBook(world, feed: feed, item: "guid:post-1"), in: world)
        let fileName = article.bookFileURL.lastPathComponent
        let text = TextMouthPaths.contentMarkdownPath(in: article.tmbDirectory)
        let feedFolder = FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)
        /// The holders a removal left beside the packages, by name.
        func holdersLeft() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: feedFolder.path).filter { $0.hasPrefix(FeedItemPackage.removalHolderPrefix) }
        }

        world.refusesRemovals.value = true
        XCTAssertThrowsError(try world.center.deleteDownload("guid:post-1", of: feed.id))
        world.refusesRemovals.value = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: article.filePath), "a refused removal left the file out of its package")
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "a refused removal left the text out of its package")
        XCTAssertEqual(try holdersLeft(), [])
        XCTAssertEqual(world.removedItems.value, [])

        try world.center.deleteDownload("guid:post-1", of: feed.id)

        XCTAssertEqual(world.removedItems.value, [
            FeedTestWorld.RemovedItem(name: (fileName as NSString).deletingPathExtension, contents: ["content.md", fileName].sorted()),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: article.filePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
        XCTAssertEqual(try holdersLeft(), [], "the holder stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: article.tmbDirectory).path))
    }

    /// A Delete Download refused whose article and text could not go back
    /// into their package, as a permission changed meanwhile can keep them,
    /// leaves both in the hidden holder named for the download, whose row
    /// still says Downloaded; the next launch puts both back, so the row's
    /// file is there again, and sends nothing to the Trash, whatever Removal
    /// Behavior says (REV14 feeds 3).
    func testAnArticleARefusedDeleteDownloadCouldNotPutBackIsPutBackAtTheNextLaunch() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleHeldAside")
        let feed = try await subscribeToArticles(1, in: world)
        world.center.download("guid:post-1", of: feed.id)
        let article = try listen(to: try await downloadedBook(world, feed: feed, item: "guid:post-1"), in: world)
        let package = article.tmbDirectory
        let text = TextMouthPaths.contentMarkdownPath(in: package)
        let fileName = article.bookFileURL.lastPathComponent
        addTeardownBlock { _ = chmod(package.path, 0o755) }
        let heldAside = debugLogLines(containing: "FEED_DOWNLOAD_HELD_ASIDE: \(article.title)").count
        var holder: URL?

        // The Trash refuses the article, and its package then refuses both
        // back.
        XCTAssertThrowsError(try FeedItemPackage.removeFileAndText(of: article, in: package) { together in
            holder = together.deletingLastPathComponent()
            XCTAssertEqual(chmod(package.path, 0o555), 0)
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(chmod(package.path, 0o755), 0)

        let left = try XCTUnwrap(holder)
        XCTAssertEqual(FeedItemPackage.bookID(ofRemovalHolderNamed: left.lastPathComponent), article.id, "the holder is not named for its download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: article.filePath), "the files went back after all")
        XCTAssertEqual(debugLogLines(containing: "FEED_DOWNLOAD_HELD_ASIDE: \(article.title)").count, heldAside + 1)
        XCTAssertEqual(world.library.bookByID(article.id)?.feedLink, article.feedLink, "the refused download left its row")

        _ = await world.relaunch(self)

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(fileName).path), "the article was not put back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "the article's text was not put back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "the holder stayed")
        XCTAssertEqual(world.removedItems.value, [], "something of a refused deletion went through the listener's removal")
        XCTAssertNotNil(world.library.bookByID(article.id), "the download left the library")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:post-1")?.state, .downloaded(bookID: article.id))
    }

    /// A book's own speed is kept within its format's range in its row, as
    /// its record reads it back (REV11): an article given a playback rate of
    /// 1.5 keeps the slowest words per minute, 50, in its row as in its
    /// record, where its row once kept 1.5; a speed that can be none, and a
    /// pitch out of range, are kept as the record reads them too.
    func testAnArticlesOwnSpeedIsKeptWithinItsRange() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordArticleSpeed")
        let feed = try await subscribeToArticles(1, in: world)
        world.center.download("guid:post-1", of: feed.id)
        let article = try await downloadedBook(world, feed: feed, item: "guid:post-1")

        world.library.updateLocalVoiceAndSpeed(bookID: article.id, voiceID: nil, wpm: 1.5, pitch: 99)
        LibraryPersistenceService.writePendingBookInfoNow(bookID: article.id)

        let row = try XCTUnwrap(world.library.bookByID(article.id))
        XCTAssertEqual(row.localWPM, SettingsPolicy.wordsPerMinute.range.lowerBound)
        XCTAssertEqual(row.localPitch, SettingsPolicy.validatedLocalPitch(99))
        let recorded = try recordedBook(in: article.tmbDirectory)
        XCTAssertEqual(recorded.localWPM, row.localWPM, "the row's speed and the record's differ")
        XCTAssertEqual(recorded.localPitch, row.localPitch)

        world.library.updateLocalVoiceAndSpeed(bookID: article.id, voiceID: nil, wpm: .nan)
        XCTAssertNil(world.library.bookByID(article.id)?.localWPM)
    }

    // MARK: - A Kept Package That Cannot Be Listed

    /// A package that is there but cannot be listed, as one whose folder
    /// can't be read, is taken to hold a transcript, so its file's removal
    /// keeps it whatever its row holds; a package that is gone holds none,
    /// and one that can be listed holds one only when its transcript is
    /// there. Copying what a new download keeps out of a package that cannot
    /// be listed fails, rather than copying nothing, and out of one that is
    /// gone copies nothing without failing.
    func testAPackageThatCannotBeListedIsTakenToHoldATranscript() throws {
        let folder = try makeSandboxDirectory("FeedPackageListing")
        let listable = folder.appendingPathComponent("Listable.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: listable, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: TextMouthPaths.bookInfoPath(in: listable))
        let unlistable = folder.appendingPathComponent("Unlistable.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: unlistable, withIntermediateDirectories: true)
        try lockListing(of: unlistable)
        let gone = folder.appendingPathComponent("Gone.tmb", isDirectory: true)
        let staged = try makeSandboxDirectory("FeedPackageListingStaged")
        let neverOpened = Self.row("Never Opened", feedID: UUID(), itemID: "guid:never")

        XCTAssertFalse(FeedItemPackage.holdsListenersFiles(listable))
        try Data("{}".utf8).write(to: TextMouthPaths.transcriptPath(in: listable))
        XCTAssertTrue(FeedItemPackage.holdsListenersFiles(listable))
        XCTAssertTrue(FeedItemPackage.holdsListenersFiles(unlistable), "a package that cannot be listed was taken to hold no transcript")
        XCTAssertTrue(FeedItemPackage.holdsListenerState(neverOpened, package: unlistable))
        XCTAssertFalse(FeedItemPackage.holdsListenersFiles(gone))
        XCTAssertFalse(FeedItemPackage.holdsListenerState(neverOpened, package: gone))
        XCTAssertThrowsError(try FeedItemPackage.copyWhatANewDownloadKeeps(from: unlistable, to: staged))
        XCTAssertNoThrow(try FeedItemPackage.copyWhatANewDownloadKeeps(from: gone, to: staged))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.path), [])
    }

    /// Downloading again an item whose kept package cannot be listed fails,
    /// rather than taking the package for empty and putting a package
    /// without its transcript in its place: the kept package stays with its
    /// record and transcript, its row stays on the feed's shelf, and the
    /// item says why it is not downloaded. Once the package can be listed,
    /// the item downloads again as the same book, its transcript copied in.
    func testAKeptPackageThatCannotBeListedFailsItsDownloadAndStays() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordUnlistable")
        let (feed, book, transcript) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)
        let package = book.tmbDirectory
        let record = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: package))
        try lockListing(of: package)

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download fails") {
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason != nil
                && !world.center.downloads.isDownloading("guid:ep-1", of: feed.id)
        }

        XCTAssertEqual(chmod(package.path, 0o755), 0)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: package)), transcript)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: package)), record, "the kept record changed")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, book.id)
        XCTAssertNil(world.library.bookByID(book.id))

        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: restored.tmbDirectory)), transcript)
    }

    // MARK: - A Kept Package Set Aside

    /// A crash while the kept package stood aside, on a volume that cannot
    /// swap two folders, leaves it under its hidden name with nothing in its
    /// place; the item's next download puts it back first, so the same book
    /// is restored with the listener's state and transcript, and nothing is
    /// left aside.
    func testAKeptPackageACrashLeftAsideIsPutBackAsItsItemDownloadsAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordSetAside")
        let (feed, book, transcript) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)
        let aside = FeedItemPackage.setAsideURL(of: book.tmbDirectory)
        try FileManager.default.moveItem(at: book.tmbDirectory, to: aside)
        let putBack = debugLogLines(containing: "FEED_PACKAGE_PUT_BACK: \(book.tmbDirectoryName)").count

        world.center.download("guid:ep-1", of: feed.id)
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(restored.tmbDirectory, book.tmbDirectory)
        try assertKeepsTheListenersState(restored, of: book, "the restored row")
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: restored.tmbDirectory)), transcript)
        XCTAssertFalse(MaintenanceFileAccess.hasItem(at: aside), "the package set aside stayed")
        XCTAssertEqual(debugLogLines(containing: "FEED_PACKAGE_PUT_BACK: \(book.tmbDirectoryName)").count, putBack + 1)
    }

    /// On a volume that cannot swap two folders the new package still takes
    /// the kept one's place, the kept one standing aside meanwhile and then
    /// going, and the swap's errno is in the debug log.
    func testOnAVolumeThatCannotSwapTheNewPackageStillTakesTheKeptOnesPlace() throws {
        let (kept, staging) = try keptPackageAndStaging("FeedSwapless")
        defer { staging.discard() }
        let line = "FEED_PACKAGE_SWAP_FAILED: \(kept.lastPathComponent): errno \(ENOTSUP) (Operation not supported)"
        let logged = debugLogLines(containing: line).count

        try FeedItemPackage.putInPlace(staging, of: kept, swap: { _, _ in ENOTSUP })

        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("new.txt"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent("old.txt").path), "the kept package stayed")
        XCTAssertFalse(MaintenanceFileAccess.hasItem(at: FeedItemPackage.setAsideURL(of: kept)), "the kept package stayed aside")
        XCTAssertEqual(debugLogLines(containing: line).count, logged + 1)
    }

    /// On a volume that cannot swap two folders, a new package that cannot
    /// be published leaves the kept one where it was, with what it holds.
    func testWhenTheNewPackageCannotBePublishedTheKeptOneComesBack() throws {
        let (kept, staging) = try keptPackageAndStaging("FeedSwaplessUnpublished")
        defer { staging.discard() }
        // A staged package that is gone cannot be published.
        try FileManager.default.removeItem(at: staging.directory)

        XCTAssertThrowsError(try FeedItemPackage.putInPlace(staging, of: kept, swap: { _, _ in ENOTSUP }))

        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("old.txt"), encoding: .utf8), "old")
        XCTAssertFalse(MaintenanceFileAccess.hasItem(at: FeedItemPackage.setAsideURL(of: kept)), "the kept package stayed aside")
    }

    /// What a crash left set aside is put right before a download reads the
    /// kept package: alone, it moves back to its own name; beside a package
    /// a download published before the crash, which holds what it kept, it
    /// is a leftover, and goes. With nothing set aside, nothing changes.
    func testWhatACrashLeftAsideIsPutRight() throws {
        let folder = try makeSandboxDirectory("FeedSetAsideRecovery")
        let kept = folder.appendingPathComponent("Kept.tmb", isDirectory: true)
        let aside = FeedItemPackage.setAsideURL(of: kept)
        XCTAssertEqual(aside.lastPathComponent, ".replaced-Kept.tmb")
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try "old".write(to: aside.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        try FeedItemPackage.recoverSetAside(of: kept)

        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("old.txt"), encoding: .utf8), "old")
        XCTAssertFalse(MaintenanceFileAccess.hasItem(at: aside))

        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try FeedItemPackage.recoverSetAside(of: kept)

        XCTAssertFalse(MaintenanceFileAccess.hasItem(at: aside), "a leftover beside the published package stayed")
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("old.txt"), encoding: .utf8), "old")
        XCTAssertNoThrow(try FeedItemPackage.recoverSetAside(of: kept))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
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

    /// Delete Episode of an item whose kept package is already gone, as one
    /// removed by hand, deletes the item, its row leaving the shelf and its
    /// feed's index, the package counting as removed, nothing being left of
    /// it to keep, as Unsubscribe and Delete Feed… count one (REV14 feeds
    /// 8, one rule for a package gone); it was refused before.
    func testDeleteEpisodeOfAKeptPackageAlreadyGone() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordDeleteEpisodeGone")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let kept = try listen(to: try XCTUnwrap(books.first), in: world)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        try FileManager.default.removeItem(at: kept.tmbDirectory)
        let removedBefore = world.removedItems.value.count

        try world.center.deleteItem("guid:ep-1", of: feed.id)

        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertEqual(try indexedRows(of: feed.id), [])
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.deletedDate, "the item stayed")
        XCTAssertEqual(world.removedItems.value.count, removedBefore, "a package already gone went through the listener's removal")
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
        let removedBefore = world.removedItems.value.count

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
        // The restored package, holding the place kept for episode 1, went
        // as Delete Episode sends it, through the listener's own removal; the
        // new download of episode 2, which held nothing of the listener's,
        // went for good (REV14 feeds 2).
        XCTAssertEqual(world.removedItems.value.dropFirst(removedBefore).map(\.name), [kept.tmbDirectoryName])
    }

    /// Delete Episode while the item downloads again into its kept package,
    /// the restore waiting to be added: Delete Episode sends the kept
    /// package, with its transcript, as the listener's own deletions go, and
    /// the package the restore then publishes in its place, its record
    /// holding the place and bookmarks kept for the item, is discarded the
    /// same way, never for good behind the listener's back (REV14 feeds 2).
    /// Nothing of the item is listed.
    func testDeleteEpisodeDuringARestoreRemovesBothPackagesAsTheListenersDeletion() async throws {
        let world = try FeedTestWorld(self, label: "FeedRecordDeleteDuringRestore")
        let (feed, book, _) = try await transcribedEpisodeWhoseDownloadWasDeleted(in: world)
        let imports = await world.holdImports(self)
        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the kept episode's book is being added") {
            world.center.downloads.progress.state.download?.isAddingToLibrary == true
        }

        try world.center.deleteItem("guid:ep-1", of: feed.id)
        imports.release()
        await waitFor("the restore ends") { world.center.downloads.current == nil }

        let removed = world.removedItems.value.filter { $0.name == book.tmbDirectoryName }
        XCTAssertEqual(removed.count, 2, "\(world.removedItems.value)")
        XCTAssertTrue(removed.first?.contents.contains(where: TextMouthPaths.isTranscriptFile) == true, "the kept package went without its transcript")
        XCTAssertTrue(removed.last?.contents.contains(TextMouthPaths.bookInfoFileName) == true, "the restored package went other than through the listener's own removal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path), "a package of the deleted episode stayed")
        XCTAssertNil(world.library.bookByID(book.id), "the deleted episode's book was listed")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.deletedDate)
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

    // MARK: - Checking a Package Before Removing

    /// A feed's package is named by the library's rule for a package's name
    /// and is not hidden: a staged or set-aside package's name, a path of
    /// two folders, a name without ".tmb", and no name at all name none.
    func testAFeedsPackageNamesFollowTheLibrarysRule() {
        for name in ["Episode One - Atlas - 2026-10-10 - 1A2B.tmb", "Loud.TMB"] {
            XCTAssertTrue(FeedItemPackage.isPackageName(name), name)
            XCTAssertTrue(FileImportService.isManagedPackageName(name), name)
        }
        for name in ["", "Folder/Episode.tmb", "Episode.html", "..", "Feeds"] {
            XCTAssertFalse(FeedItemPackage.isPackageName(name), name)
            XCTAssertFalse(FileImportService.isManagedPackageName(name), name)
        }
        for name in [".import-\(UUID().uuidString).tmb", FeedItemPackage.setAsidePrefix + "Episode.tmb"] {
            XCTAssertFalse(FeedItemPackage.isPackageName(name), name)
        }
    }

    /// Before anything in it is removed, a feed item's package must be a
    /// folder of its feed's, not a symbolic link, and hold the row's file;
    /// one that is a link, or a row whose file is elsewhere, is refused.
    func testAPackageThatIsALinkOrHoldsNoneOfTheRowsFileIsRefused() throws {
        let root = try makeSandboxDirectory("FeedPackageChecks")
        let feedID = UUID()
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("Elsewhere.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = folder.appendingPathComponent("Real.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked.tmb"), withDestinationURL: elsewhere)
        var holding = Self.row("Real", feedID: feedID, itemID: "guid:real")
        holding.filePath = real.appendingPathComponent("Real.m4a").path
        var linked = Self.row("Linked", feedID: feedID, itemID: "guid:linked")
        linked.filePath = folder.appendingPathComponent("Linked.tmb/Linked.m4a").path
        var outside = holding
        outside.filePath = elsewhere.appendingPathComponent("Real.m4a").path

        XCTAssertEqual(try FeedItemPackage.packageForRemoval(of: holding, in: root).standardizedFileURL.path, real.standardizedFileURL.path)
        for refused in [linked, outside] {
            XCTAssertThrowsError(try FeedItemPackage.packageForRemoval(of: refused, in: root), refused.title) { error in
                XCTAssertEqual(error as? FeedItemPackageError, .notAFeedPackage)
            }
        }
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
    /// a reader calls: a place, playback times, a bookmark, a speed of its
    /// own (`ownSpeed(of:)`), and a skipped heading. Returns the row as the
    /// library holds it then.
    private func listen(to book: Book, in world: FeedTestWorld) throws -> Book {
        let library = world.library
        var position = ReadingPosition(chapterIndex: 0, characterOffset: 42)
        position.lastUpdated = Self.whole(100)
        library.persistReadingPosition(bookID: book.id, position: position)
        library.updatePlaybackTimestamps(bookID: book.id, started: Self.whole(40), stopped: Self.whole(100))
        library.addBookmark(bookID: book.id, chapterIndex: 0, characterOffset: 21, label: "The good part")
        library.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: nil, wpm: Self.ownSpeed(of: book))
        library.updateSkippedHeadings(bookID: book.id, headings: [Self.skippedCredits])
        return try XCTUnwrap(library.bookByID(book.id))
    }

    /// The heading `listen(to:in:)` skips, as a reader saves a skip (T06).
    private static let skippedCredits = SkippedHeading(level: 1, label: "Credits", chapterIndex: 0, characterOffset: 30)

    /// The speed of its own `listen(to:in:)` gives `book`: for an episode a
    /// playback rate, 1.5 times; for an article words per minute, 220, as a
    /// record keeps a text book's speed within its range (50 to 650).
    private static func ownSpeed(of book: Book) -> Double {
        book.format.isAudio ? 1.5 : 220
    }

    /// Downloads episode 1 into `world`, listens to it, gives it a transcript
    /// of its audio as the transcription service makes one, and deletes its
    /// download, which keeps its package. Returns the feed, the row as the
    /// listener left it, and transcript.json's bytes.
    private func transcribedEpisodeWhoseDownloadWasDeleted(in world: FeedTestWorld) async throws -> (Feed, Book, Data) {
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try listen(to: try XCTUnwrap(books.first), in: world)
        let bytes = try transcribe(book)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.library.feedShelf.rows.map(\.id), [book.id], "the transcribed download's package was not kept")
        return (feed, book, bytes)
    }

    /// Gives `book` a transcript of its audio as the transcription service
    /// makes one, and returns transcript.json's bytes.
    private func transcribe(_ book: Book) throws -> Data {
        let heard = try TranscriptionPlan.make(for: book).files.map { file in
            (file.path, [TranscriptFixtures.sentence("Quillwort grows by the ferry slip.", from: 0, to: 900)])
        }
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Dictionary(uniqueKeysWithValues: heard))
        _ = try TranscriptStore.write(transcript, into: book.tmbDirectory)
        return try Data(contentsOf: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
    }

    /// Lays `book`'s transcript text over its index as the episode's reader
    /// does when it opens (`TranscriptTextLoader`), and saves the index as
    /// the reader then does (`LibraryViewModel.updateContentIndex`), waiting
    /// until its record holds it.
    private func layTranscriptOverItsIndex(of book: Book, in world: FeedTestWorld) throws {
        let index = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let load = TranscriptTextLoader.load(for: book, audioIndex: index)
        XCTAssertNotNil(load.text, "the transcript of the episode's own audio shows no text")
        world.library.updateContentIndex(bookID: book.id, index: load.index)
        LibraryPersistenceService.flushPendingSave()
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
        XCTAssertEqual(kept.localWPM, Self.ownSpeed(of: listened), what, file: file, line: line)
        XCTAssertEqual(kept.skippedHeadings, [Self.skippedCredits], what, file: file, line: line)
        XCTAssertEqual(kept.skippedHeadingIDs, [Self.skippedCredits.id], what, file: file, line: line)
    }

    /// Takes away the read permission of the folder `folder`, so it cannot
    /// be listed while what it holds can still be reached by name, as a
    /// package whose folder TextMouth cannot read; the permission comes
    /// back when the test ends, before its sandbox goes. Skips for a user
    /// whom no permission stops, as root.
    private func lockListing(of folder: URL) throws {
        XCTAssertEqual(chmod(folder.path, 0o300), 0)
        addTeardownBlock { _ = chmod(folder.path, 0o755) }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil {
            throw XCTSkip("this user lists a folder without its read permission")
        }
    }

    /// A kept package holding "old.txt" in a sandbox folder labelled
    /// `label`, and a package staged to take its place holding "new.txt".
    /// The caller discards the staging once done.
    private func keptPackageAndStaging(_ label: String) throws -> (kept: URL, staging: ImportStaging) {
        let folder = try makeSandboxDirectory(label)
        let kept = folder.appendingPathComponent("Kept.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try "old".write(to: kept.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let staging = try ImportStaging.makeEmpty(publishingTo: kept)
        try "new".write(to: staging.directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        return (kept, staging)
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

    /// Starts `world`'s engine and subscribes it to a feed of `count`
    /// articles, "guid:post-1" onwards, the first the newest, each of 270
    /// words, so its web page is never fetched in place of its own text.
    private func subscribeToArticles(_ count: Int, in world: FeedTestWorld) async throws -> Feed {
        await world.start()
        let text = (1...30).map { "<p>Paragraph \($0) says what the release changed and why.</p>" }.joined()
        let items = (1...count).map { number in
            FeedXML.Item(
                guid: "post-\(number)",
                title: "Post \(number)",
                published: world.day(Double(-number)),
                description: text,
                link: "https://news.example/post-\(number)"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        return try await world.subscribe("/feed.xml")
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
