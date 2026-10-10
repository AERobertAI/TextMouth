import XCTest
@testable import TextMouth

// MARK: - The Move (FR11, Branch D)

/// Move to Library… (FR11, branch D, item 6) moves a downloaded episode into
/// a library folder as an ordinary book: the same package and book ID, with
/// its place, bookmarks, and reading-list place; library.json lists it, its
/// feed's index no longer does, and its record keeps its feed link; its item
/// says "In Library". The feed's record says so first, so a crash at any
/// point is settled at the next launch, and the book is never lost: before
/// the package moved, it stays in its feed, downloaded; after, it is a book
/// of the library's own in the folder chosen. A record that cannot be saved,
/// or a package that cannot move, leaves the book in its feed. No test
/// reaches the network: every request goes to the world's stub server.
@MainActor
final class FeedMoveToLibraryOperationTests: XCTestCase {

    // MARK: - The Move

    /// The episode becomes a book of the library's own in the folder chosen,
    /// keeping everything, and the next launch finds it there, nothing moving
    /// it back into its feed.
    func testTheEpisodeBecomesABookKeepingEverything() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoveToLibrary")
        let fixture = try await downloadedEpisode(world)

        let outcome = await world.library.moveToLibraryReturningOutcome([fixture.book], toFolder: fixture.keepers)

        XCTAssertEqual(outcome, .success(nil))
        XCTAssertEqual(world.library.lastMovedFolderPath, fixture.keepers)
        try await assertMoved(fixture, in: world, model: world.library)
        let next = await nextLaunch(of: world)
        try await assertMoved(fixture, in: world, model: next)
    }

    // MARK: - A Crash Between Two Steps

    /// A crash once the item said "In Library", before the package moved:
    /// the book stays in its feed, its item downloaded again.
    func testACrashAfterTheItemIsMarkedLeavesTheBookInItsFeed() async throws {
        try await assertCrashIsSettled(after: .itemMarked)
    }

    /// A crash once the package moved, before its record was written there.
    func testACrashAfterThePackageMovesFinishesTheMove() async throws {
        try await assertCrashIsSettled(after: .packageMoved)
    }

    /// A crash once the record was written where the package is now, before
    /// either index was.
    func testACrashAfterTheRecordIsWrittenFinishesTheMove() async throws {
        try await assertCrashIsSettled(after: .recordWritten)
    }

    /// A crash once the feed's index was written without the row, before
    /// library.json listed it.
    func testACrashAfterTheFeedsIndexIsWrittenFinishesTheMove() async throws {
        try await assertCrashIsSettled(after: .feedIndexWritten)
    }

    // MARK: - What Does Not Move

    /// A feed's record that cannot be saved moves nothing: the book stays in
    /// its feed, its item downloaded, and the sheet hears why.
    func testARecordThatCannotBeSavedMovesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoveToLibraryRecord")
        let fixture = try await downloadedEpisode(world)
        let obstruction = try WriteObstruction.place(at: FeedPaths.recordFile(of: fixture.feed.id, in: world.recordsFolder))

        let outcome = await world.library.moveToLibraryReturningOutcome([fixture.book], toFolder: fixture.keepers)

        XCTAssertEqual(
            outcome.failureMessage,
            "Could not move to the library: TextMouth couldn't save the feed's list of its items, so nothing moved."
        )
        try assertStaysInItsFeed(fixture, in: world, model: world.library)
        // The record is written again once it can be, settling the failure.
        obstruction.restoreOriginal()
        world.center.store.saveUnsavedRecords()
        await world.center.store.flush()
        XCTAssertEqual(world.center.store.unsavedFeedIDs, [])
    }

    /// A package that cannot move, as when a package of its name is in the
    /// folder chosen already, is left where it was, and its item's state
    /// goes back.
    func testAPackageThatCannotMoveStaysInItsFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoveToLibraryBlocked")
        let fixture = try await downloadedEpisode(world)
        var destination = fixture.book
        destination.feedLink = nil
        destination.folderPath = fixture.keepers
        try FileManager.default.createDirectory(at: destination.packageDirectory(inDataDirectory: TextMouthPaths.root), withIntermediateDirectories: true)

        let outcome = await world.library.moveToLibraryReturningOutcome([fixture.book], toFolder: fixture.keepers)

        XCTAssertNotNil(outcome.failureMessage)
        try assertStaysInItsFeed(fixture, in: world, model: world.library)
    }

    /// Only an episode or article downloaded in its feed moves, into a folder
    /// still in the library: a book of the library's own, or a folder gone,
    /// moves nothing, and says why.
    func testOnlyAFeedsDownloadMovesIntoAFolderThatIsThere() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoveToLibraryRefusals")
        let fixture = try await downloadedEpisode(world)
        let ownBook = Book(title: "Middlemarch", format: .txt, filePath: "/nonexistent/m.txt", md5Hash: UUID().uuidString)
        world.library.library.books.append(ownBook)

        let ownOutcome = await world.library.moveToLibraryReturningOutcome([ownBook], toFolder: fixture.keepers)
        let goneOutcome = await world.library.moveToLibraryReturningOutcome([fixture.book], toFolder: "\(fixture.keepers)/Gone")

        XCTAssertEqual(
            ownOutcome.failureMessage,
            "Could not move to the library: Only an episode or article downloaded in its feed can move into the library."
        )
        XCTAssertEqual(
            goneOutcome.failureMessage,
            "Could not move to the library: The folder chosen is no longer in the library. Choose another folder."
        )
        try assertStaysInItsFeed(fixture, in: world, model: world.library)
    }

    // MARK: - Fixtures

    /// What a move starts from: a feed's downloaded episode, opened, with a
    /// place and a bookmark, on the reading list, and the folder it moves to.
    struct Fixture {
        /// The feed.
        let feed: Feed
        /// The episode's book, as its feed holds it.
        let book: Book
        /// The episode's feed and item.
        let link: FeedBookLink
        /// The path of the library folder "Keepers", inside the world's.
        let keepers: String
    }

    /// The steps of the move after which a crash is settled.
    enum Step {
        /// The item says "In Library" in the record on disk.
        case itemMarked
        /// The package moved into the folder chosen.
        case packageMoved
        /// Its record was written there.
        case recordWritten
        /// The feed's index was written without its row, library.json not
        /// yet with it.
        case feedIndexWritten
    }

    /// The place and bookmark the fixture's episode holds.
    private static let place = 4_200
    private static let bookmarkOffset = 300

    /// Subscribes `world` to a feed of two episodes, downloads the newest,
    /// opens it with a place and a bookmark, puts it on the reading list,
    /// and makes the folder "Keepers" in the world's folder.
    private func downloadedEpisode(_ world: FeedTestWorld) async throws -> Fixture {
        let audio = try FeedMediaFixtures.silentAAC()
        let items = (1...2).map { number in
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
            return FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                                enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        let downloaded = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        world.library.markBookOpened(downloaded.id)
        world.library.persistReadingPosition(bookID: downloaded.id, position: ReadingPosition(chapterIndex: 0, characterOffset: Self.place))
        world.library.addBookmark(bookID: downloaded.id, chapterIndex: 0, characterOffset: Self.bookmarkOffset, label: "The cliff")
        world.library.addToReadingList([downloaded.id])
        XCTAssertTrue(world.library.createFolderReturningOutcome(name: "Keepers", parentPath: world.folder.path).succeeded)
        LibraryPersistenceService.flushPendingSave()
        let book = try XCTUnwrap(world.library.bookByID(downloaded.id))
        let link = try XCTUnwrap(book.feedLink)
        return Fixture(feed: feed, book: book, link: link, keepers: "\(world.folder.path)/Keepers")
    }

    /// The library model the next launch makes on `world`'s data:
    /// library.json and each feed's index read from disk, the startup repair
    /// and the feed items' join done, then the launch's moves of downloads
    /// into their feeds and its marking of items downloaded again, on the
    /// world's engine; and saved, so the files on disk say what it holds.
    private func nextLaunch(of world: FeedTestWorld) async -> LibraryViewModel {
        LibraryPersistenceService.flushPendingSave()
        let model = LibraryViewModel(initializeServices: false)
        model.feedEngine = world.center
        model.loadLibraryIndex()
        await model.moveDownloadsIntoTheirFeeds()
        model.markFeedItemsDownloadedAgain()
        model.save()
        LibraryPersistenceService.flushPendingSave()
        return model
    }

    /// Leaves on disk what a crash after `step` of the move leaves, then
    /// launches as the next launch does, and asserts the book ends where the
    /// move's commit point says: in its feed before the package moved, in
    /// the folder chosen once it has.
    private func assertCrashIsSettled(after step: Step, file: StaticString = #filePath, line: UInt = #line) async throws {
        let world = try FeedTestWorld(self, label: "FeedMoveToLibraryCrash")
        let fixture = try await downloadedEpisode(world)
        let root = TextMouthPaths.root
        world.center.store.updateItem(fixture.link.itemID, of: fixture.feed.id) { item in
            item.state = .inLibrary(bookID: fixture.book.id)
            item.downloadOrigin = .listener
        }
        await world.center.store.flush()
        var destination = fixture.book
        destination.feedLink = nil
        destination.folderPath = fixture.keepers
        switch step {
        case .itemMarked:
            break
        case .packageMoved:
            try FileManager.default.moveItem(at: fixture.book.tmbDirectory, to: destination.packageDirectory(inDataDirectory: root))
        case .recordWritten, .feedIndexWritten:
            _ = try LibraryViewModel.moveIntoTheLibrary(fixture.book, folderPath: fixture.keepers, root: root)
        }
        if step == .feedIndexWritten {
            try FeedIndexFiles.encoded(FeedIndex(feedID: fixture.feed.id, books: [])).write(to: FeedPaths.indexFile(of: fixture.feed.id, in: root))
        }

        let next = await nextLaunch(of: world)

        if step == .itemMarked {
            try assertStaysInItsFeed(fixture, in: world, model: next, file: file, line: line)
        } else {
            try await assertMoved(fixture, in: world, model: next, file: file, line: line)
        }
    }

    /// Asserts that the episode is a book of the library's own in the folder
    /// "Keepers", with everything it had, as `model` holds it and as the
    /// files on disk do, and that its item says "In Library".
    private func assertMoved(
        _ fixture: Fixture,
        in world: FeedTestWorld,
        model: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let row = try XCTUnwrap(model.bookByID(fixture.book.id), "the book left the library", file: file, line: line)
        XCTAssertNil(row.feedLink, "the book is still its feed's", file: file, line: line)
        XCTAssertEqual(row.folderPath, fixture.keepers, file: file, line: line)
        XCTAssertEqual(row.readingPosition?.characterOffset, Self.place, file: file, line: line)
        XCTAssertEqual(row.bookmarks.map(\.characterOffset), [Self.bookmarkOffset], file: file, line: line)
        XCTAssertNotNil(row.lastOpened, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath), "the book's file is not where its row says", file: file, line: line)
        let library = TextMouthPaths.libraryDir.appendingPathComponent(fixture.keepers, isDirectory: true)
        XCTAssertEqual(
            row.tmbDirectory.standardizedFileURL.path,
            library.appendingPathComponent(fixture.book.tmbDirectoryName).standardizedFileURL.path,
            file: file,
            line: line
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.book.tmbDirectory.path), "the package is still in its feed's folder", file: file, line: line)
        XCTAssertEqual(model.library.books.filter { $0.id == fixture.book.id }.count, 1, file: file, line: line)
        XCTAssertFalse(model.library.feedShelf.rows.contains { $0.id == fixture.book.id }, "the row is still on its feed's shelf", file: file, line: line)
        XCTAssertTrue(model.readingList.bookIDs.contains(fixture.book.id), "the book left the reading list", file: file, line: line)

        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, fixture.book.id, file: file, line: line)
        XCTAssertEqual(record.metadata.feedLink, fixture.link, "the record forgot the feed the book came from", file: file, line: line)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, Self.place, file: file, line: line)
        let libraryJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: TextMouthPaths.libraryIndexFile)) as? [String: Any]
        let listed = (libraryJSON?["books"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(listed.contains(fixture.book.id.uuidString), "library.json does not list the book", file: file, line: line)
        let indexed = try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: fixture.feed.id, in: TextMouthPaths.root))).books
        XCTAssertFalse(indexed.contains { $0.id == fixture.book.id }, "the feed's index still lists the book", file: file, line: line)

        await world.center.store.flush()
        XCTAssertEqual(world.center.store.record(of: fixture.feed.id)?.item(fixture.link.itemID)?.state, .inLibrary(bookID: fixture.book.id), file: file, line: line)
        let written = try FeedRecordCoding.decoder().decode(
            FeedRecord.self,
            from: Data(contentsOf: FeedPaths.recordFile(of: fixture.feed.id, in: world.recordsFolder))
        )
        XCTAssertEqual(written.item(fixture.link.itemID)?.state, .inLibrary(bookID: fixture.book.id), file: file, line: line)
        XCTAssertEqual(written.item(fixture.link.itemID)?.downloadOrigin, .listener, file: file, line: line)
    }

    /// Asserts that the episode is still its feed's download, its package in
    /// its feed's folder, its item downloaded, as `model` holds it.
    private func assertStaysInItsFeed(
        _ fixture: Fixture,
        in world: FeedTestWorld,
        model: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(model.bookByID(fixture.book.id), "the book left the library", file: file, line: line)
        XCTAssertEqual(row.feedLink, fixture.link, "the book left its feed", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.book.filePath), "the package left its feed's folder", file: file, line: line)
        XCTAssertEqual(row.readingPosition?.characterOffset, Self.place, file: file, line: line)
        XCTAssertEqual(
            world.center.store.record(of: fixture.feed.id)?.item(fixture.link.itemID)?.state,
            .downloaded(bookID: fixture.book.id),
            file: file,
            line: line
        )
    }
}

// MARK: - The "In Library" State (FR11, Branch D)

/// An item moved into the library by Move to Library… (FR11, branch D, item
/// 7; the listener's answer 5: "its feed then lists it as 'In Library' and
/// never downloads it again"): its record says "in library" with its book's
/// ID, which round-trips; its feed lists it "In Library", whose Open opens
/// the book; every refresh keeps it; it counts among the newest-N rule's
/// newest and is never downloaded again; Mark Played and Delete Episode…
/// stay on its row, Delete Episode hiding the row and leaving the book;
/// once its book leaves the library, it is not downloaded; and finishing
/// its book plays it, Books Finished counting it as an episode. Each item
/// is put in the library here through its record and a book row, as the
/// move leaves them. No test reaches the network: every request goes to the
/// world's stub server.
@MainActor
final class FeedInLibraryStateTests: XCTestCase {

    // MARK: - The State

    /// The state round-trips through a record, names its book, and says "In
    /// Library"; one missing its book reads as not downloaded, as any state
    /// a TextMouth cannot make sense of does.
    func testTheStateRoundTripsAndSaysInLibrary() throws {
        let bookID = UUID()
        let state = FeedItemState.inLibrary(bookID: bookID)

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: data), state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "inLibrary")
        XCTAssertEqual(object["bookID"] as? String, bookID.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: Data(#"{"kind": "inLibrary"}"#.utf8)), .notDownloaded)

        XCTAssertEqual(state.visibleNote, "In Library")
        XCTAssertEqual(state.spokenNote, "In Library")
        XCTAssertNil(state.bookID, "a book moved into the library was taken for its feed's download")
        XCTAssertEqual(state.libraryBookID, bookID)
        XCTAssertEqual(state.linkedBookID, bookID)
        XCTAssertEqual(FeedItemState.downloaded(bookID: bookID).linkedBookID, bookID)
        XCTAssertFalse(state.isTransient)
        XCTAssertEqual(state, FeedRecord(feed: Feed(feedURL: try XCTUnwrap(URL(string: "https://a.example/f.xml")), folderID: UUID(), subscribedDate: Date()), items: [
            FeedItem(id: "a", title: "A", firstSeen: Date(), state: state),
        ]).durable.items.first?.state, "a record file did not keep the state")
    }

    // MARK: - Its Row

    /// The item's row says "In Library" after its title, with its date and
    /// duration, and opens its book in the library; it offers Open, Mark
    /// Played, Show Description…, and Delete Episode…, which asks first,
    /// saying the book stays, hides the row, and leaves the book.
    func testTheRowSaysInLibraryAndDeleteEpisodeLeavesTheBook() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryRow")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        // Published after the subscription began, so it would be new if it
        // were not in the library.
        world.center.store.updateItem("guid:ep-1", of: feed.id) { item in
            item.duration = 64 * 60
            item.published = world.day(1)
        }
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))

        let content = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)

        let date = try XCTUnwrap(item.published)
        XCTAssertEqual(content.label, "Episode 1, In Library, \(FeedWording.itemDate(date)), \(TimeFormatting.spoken(64 * 60))")
        XCTAssertFalse(content.isNew, "an episode in the library was new")
        XCTAssertEqual(FeedWording.itemRowHint(content.state), "Opens its book in your library")
        let actions = FeedItemAction.actions(for: content)
        XCTAssertEqual(actions.map(\.title), ["Open", "Mark Played", "Show Description…", "Delete Episode…"])

        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        presenter.perform(try XCTUnwrap(actions.last), in: context)
        let question = try XCTUnwrap(presenter.confirmation)
        XCTAssertEqual(
            question.message,
            "The episode leaves the list for good; the book it became in your library stays. Checking the feed won't bring it back."
        )
        presenter.confirm(question, in: context)

        XCTAssertEqual(heard.last, "Deleted “Episode 1” from its feed; its book stays in your library.")
        XCTAssertNotNil(world.library.bookByID(book.id), "Delete Episode took the book from the library")
        XCTAssertFalse(world.center.listedItems(of: feed.id).contains { $0.id == "guid:ep-1" })
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .inLibrary(bookID: book.id))
    }

    // MARK: - The Rules

    /// While its book is in the library, the item is never downloaded again:
    /// the newest-N rule counts it among the newest and asks for the next
    /// one alone; Download asks for nothing; Open opens the book. It is not
    /// counted as a download of its feed. A refresh that leaves it outside
    /// the short list's newest 2, unplayed, keeps it, in the library; and
    /// played, it stays listed there.
    func testAnItemInTheLibraryIsKeptAndNeverDownloadedAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryRules")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }

        let pass = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(pass.requestedItemIDs, ["guid:ep-2"], "the rule's newest did not count the episode in the library")
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        world.center.download("guid:ep-1", of: feed.id)
        world.center.open("guid:ep-1", of: feed.id)

        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [], "an episode in the library was downloaded again")
        XCTAssertEqual(opened, [book.id])
        XCTAssertEqual(world.center.counts(of: feed.id).downloaded, 1)

        world.center.setItemPolicy(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 2), of: feed.id)
        let newer = [0.1, 0.2].map { age in
            FeedXML.Item(guid: "newer-\(age)", title: "Newer \(age)", published: world.day(-age),
                         enclosure: world.server.url("/audio/newer-\(age).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: newer + Self.episodes(world))))
        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state,
            .inLibrary(bookID: book.id),
            "a refresh let go of an episode in the library outside the newest"
        )
        world.center.markPlayed("guid:ep-1", of: feed.id)
        XCTAssertTrue(world.center.listedItems(of: feed.id).contains { $0.id == "guid:ep-1" }, "the short list hid the played episode in the library")
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [])
    }

    /// Once its book leaves the library the item reads not downloaded, and
    /// the after-playing sweep notes it so, leaving it the listener's; the
    /// listener's Download then downloads it.
    func testAnItemWhoseBookLeftTheLibraryIsNotDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryGone")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(world.center.state(of: item, in: feed.id), .inLibrary(bookID: book.id))

        world.library.library.books.removeAll { $0.id == book.id }

        XCTAssertEqual(world.center.state(of: item, in: feed.id), .notDownloaded)
        let sweep = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(sweep.forgottenItemIDs, ["guid:ep-1"])
        let noted = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(noted.state, .notDownloaded)
        XCTAssertEqual(noted.downloadDeletedDate, world.clock.value)
        XCTAssertEqual(noted.downloadOrigin, .listener)
        world.center.download("guid:ep-1", of: feed.id)
        let again = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertNotEqual(again.id, book.id)
    }

    /// Finishing the book an episode became in the library plays the
    /// episode, and Books Finished counts it as a podcast episode, as the
    /// record of where it came from says.
    func testFinishingTheBookPlaysTheItemAndCountsAnEpisode() async throws {
        let world = try FeedTestWorld(self, label: "FeedInLibraryFinished")
        let (feed, book) = try await feedWithAnEpisodeInTheLibrary(world)

        world.stats.markBookFinished(bookID: book.id, title: book.title)

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate, world.clock.value)
        XCTAssertEqual(world.center.finishedBookKind(of: book.id), .episode)
        XCTAssertEqual(world.stats.booksFinishedAllTimeByKind, FinishedBookCounts(episodes: 1))
    }

    // MARK: - Fixtures

    /// Three episodes, "guid:ep-1" the newest, each served as a second of
    /// silence at /audio/<number>.m4a.
    private static func episodes(_ world: FeedTestWorld) -> [FeedXML.Item] {
        (1...3).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
    }

    /// Subscribes `world` to a feed of three episodes, serving each, and
    /// puts the newest in the library as Move to Library… leaves it: a book
    /// of the library's own, its item "in library" with the book's ID, and
    /// the listener's.
    private func feedWithAnEpisodeInTheLibrary(_ world: FeedTestWorld) async throws -> (Feed, Book) {
        let audio = try FeedMediaFixtures.silentAAC()
        for number in 1...3 {
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: Self.episodes(world))))
        let feed = try await world.subscribe("/feed.xml")
        let book = Book(title: "Episode 1", format: .audio, filePath: "/nonexistent/Episode 1.m4a", md5Hash: UUID().uuidString, folderPath: world.folder.path)
        world.library.library.books.append(book)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { item in
            item.state = .inLibrary(bookID: book.id)
            item.downloadOrigin = .listener
        }
        return (feed, book)
    }
}
