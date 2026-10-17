import XCTest
@testable import TextMouth

/// What follows a finished book, as the library finds it (FR19, task B3):
/// `LibraryViewModel.succession(after:going:skippingFinished:)`. In a plain
/// folder it is the next book or the note that says why there is none; in a
/// feed it is the next *listed* item in the direction, whether or not its file
/// is here (`BookSuccession.episodeToDownload`), where the old search passed
/// over items not downloaded.
///
/// The feed's items are, newest first, Fourth, Third, Second, First. Each test
/// downloads the ones it needs; the others are listed with no file.
final class EpisodeSuccessionTests: FeedItemIndexTestCase {

    // MARK: - A plain folder

    /// A plain folder's book is followed by the next book either way, and by
    /// the notes of `nextBook` where none is: the end of the folder, or only
    /// finished books.
    @MainActor
    func testAPlainFolderGivesTheNextBookOrTheNoteBothWays() {
        let model = shelfModel(["Almanac", "Bestiary", "Chronicle", "Ledger"], finished: ["Bestiary", "Chronicle"])
        func succession(after title: String, _ direction: ReadingList.Direction, skipping: Bool) -> String {
            describe(model.succession(after: shelfBook(title, in: model), going: direction, skippingFinished: skipping))
        }

        XCTAssertEqual(succession(after: "Almanac", .down, skipping: true), "book Ledger")
        XCTAssertEqual(succession(after: "Almanac", .down, skipping: false), "book Bestiary")
        XCTAssertEqual(succession(after: "Ledger", .up, skipping: true), "book Almanac")
        XCTAssertEqual(succession(after: "Ledger", .up, skipping: false), "book Chronicle")
        // The end of the folder, either way.
        XCTAssertEqual(succession(after: "Ledger", .down, skipping: true), "nothing No more books in folder")
        XCTAssertEqual(succession(after: "Almanac", .up, skipping: false), "nothing No more books in folder")
    }

    /// Only finished books beyond, passed over: the note names the direction.
    @MainActor
    func testAPlainFolderWithOnlyFinishedBooksBeyondSaysSo() {
        let model = shelfModel(["Almanac", "Bestiary", "Chronicle"], finished: ["Almanac", "Chronicle"])

        XCTAssertEqual(
            describe(model.succession(after: shelfBook("Bestiary", in: model), going: .down, skippingFinished: true)),
            "nothing Every book after it in the folder is finished"
        )
        XCTAssertEqual(
            describe(model.succession(after: shelfBook("Bestiary", in: model), going: .up, skippingFinished: true)),
            "nothing Every book before it in the folder is finished"
        )
    }

    // MARK: - A feed's folder

    /// An item whose file is not here is the episode to download, both ways:
    /// the item beside the book, finished or not, when its file is not here.
    @MainActor
    func testAFeedGivesTheNextListedItemWhetherOrNotItsFileIsHere() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccession")
        let feed = try await subscribe(world, guids: ["ep-4", "ep-3", "ep-2", "ep-1"])
        let fourth = try download("Fourth", "ep-4", of: feed, in: world)
        let third = try download("Third", "ep-3", of: feed, in: world)
        let first = try download("First", "ep-1", of: feed, in: world)
        // Episode 2 is listed, and its file is not here.

        XCTAssertEqual(describe(world.library.succession(after: fourth, going: .down, skippingFinished: true)), "book Third")
        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: true)), "download Episode ep-2")
        XCTAssertEqual(describe(world.library.succession(after: first, going: .up, skippingFinished: true)), "download Episode ep-2")
        XCTAssertEqual(describe(world.library.succession(after: third, going: .up, skippingFinished: true)), "book Fourth")
        // The order names the feed and the item.
        guard case .episodeToDownload(let feedID, let item) = world.library.succession(after: third, going: .down, skippingFinished: false) else {
            return XCTFail("The item with no file here is not the episode to download")
        }
        XCTAssertEqual(feedID, feed.id)
        XCTAssertEqual(item.id, "guid:ep-2")
    }

    /// An item that is listed and has a file here, but not the next one, is
    /// not passed to: the search takes the nearest.
    @MainActor
    func testTheNearestItemWins() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionNearest")
        let feed = try await subscribe(world, guids: ["ep-4", "ep-3", "ep-2", "ep-1"])
        let fourth = try download("Fourth", "ep-4", of: feed, in: world)
        _ = try download("First", "ep-1", of: feed, in: world)

        // Third is not here: it is the one to download, not First beyond it.
        XCTAssertEqual(describe(world.library.succession(after: fourth, going: .down, skippingFinished: true)), "download Episode ep-3")
    }

    /// A finished item with its file here is passed over while finished items
    /// are skipped, and is the next item when they are not.
    @MainActor
    func testAFinishedDownloadedItemIsPassedOverOnlyWhenSkipping() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionFinished")
        let feed = try await subscribe(world, guids: ["ep-4", "ep-3", "ep-2", "ep-1"])
        let fourth = try download("Fourth", "ep-4", of: feed, in: world)
        _ = try download("Third", "ep-3", of: feed, in: world, atEnd: true)
        _ = try download("Second", "ep-2", of: feed, in: world)
        let first = try download("First", "ep-1", of: feed, in: world)

        XCTAssertEqual(describe(world.library.succession(after: fourth, going: .down, skippingFinished: true)), "book Second")
        XCTAssertEqual(describe(world.library.succession(after: fourth, going: .down, skippingFinished: false)), "book Third")
        XCTAssertEqual(describe(world.library.succession(after: first, going: .up, skippingFinished: true)), "book Second")
    }

    /// An item played whose file has since gone is passed over while finished
    /// items are skipped; with skipping off it is downloaded again.
    @MainActor
    func testAPlayedItemWithNoFileIsPassedOverOnlyWhenSkipping() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionPlayed")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world)
        _ = try download("First", "ep-1", of: feed, in: world)
        world.center.store.updateItem("guid:ep-2", of: feed.id) { $0.playedDate = Self.date(5) }

        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: true)), "book First")
        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: false)), "download Episode ep-2")
    }

    /// An item moved into the library is the library's, not the feed's: it is
    /// left out, whether or not finished items are skipped.
    @MainActor
    func testAnItemMovedIntoTheLibraryIsLeftOut() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionMoved")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world)
        _ = try download("First", "ep-1", of: feed, in: world)
        world.center.store.updateItem("guid:ep-2", of: feed.id) { $0.state = .inLibrary(bookID: UUID()) }

        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: true)), "book First")
        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: false)), "book First")
    }

    /// An item the listener deleted is no longer listed, so it is neither
    /// downloaded nor stopped at.
    @MainActor
    func testADeletedItemIsAbsent() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionDeleted")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world)
        _ = try download("First", "ep-1", of: feed, in: world)
        world.center.store.updateItem("guid:ep-2", of: feed.id) { $0.deletedDate = Self.date(5) }

        XCTAssertEqual(describe(world.library.succession(after: third, going: .down, skippingFinished: false)), "book First")
    }

    /// Nothing is left past either end of the feed's listing, or past the items
    /// moved into the library at its end.
    @MainActor
    func testTheEndOfTheListingIsNoMoreBooks() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionEnd")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world)
        let second = try download("Second", "ep-2", of: feed, in: world)
        let first = try download("First", "ep-1", of: feed, in: world)
        let none = "nothing No more books in folder"

        XCTAssertEqual(describe(world.library.succession(after: first, going: .down, skippingFinished: true)), none)
        XCTAssertEqual(describe(world.library.succession(after: third, going: .up, skippingFinished: false)), none)

        // Moving the last item into the library leaves nothing after Second.
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.state = .inLibrary(bookID: UUID()) }
        XCTAssertEqual(describe(world.library.succession(after: second, going: .down, skippingFinished: false)), none)
    }

    /// When every item beyond is finished or played, and finished items are
    /// skipped, the note says so, in the direction's words.
    @MainActor
    func testOnlyFinishedItemsBeyondSaysSoBothWays() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionAllFinished")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world, atEnd: true)
        let second = try download("Second", "ep-2", of: feed, in: world)
        // First is played and its file has gone.
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.playedDate = Self.date(5) }

        XCTAssertEqual(
            describe(world.library.succession(after: second, going: .down, skippingFinished: true)),
            "nothing Every book after it in the folder is finished"
        )
        XCTAssertEqual(
            describe(world.library.succession(after: second, going: .up, skippingFinished: true)),
            "nothing Every book before it in the folder is finished"
        )
        // With skipping off both are next.
        XCTAssertEqual(describe(world.library.succession(after: second, going: .down, skippingFinished: false)), "download Episode ep-1")
        XCTAssertEqual(describe(world.library.succession(after: second, going: .up, skippingFinished: false)), "book Third")
        XCTAssertTrue(third.restsAtEnd)
    }

    /// A book whose item the listing does not hold has nothing beyond it.
    @MainActor
    func testABookWhoseItemIsGoneHasNothingBeyondIt() async throws {
        let world = try FeedTestWorld(self, label: "EpisodeSuccessionGone")
        let feed = try await subscribe(world, guids: ["ep-2", "ep-1"])
        _ = try download("First", "ep-1", of: feed, in: world)
        let orphan = try makeFeedItem(title: "Orphan", itemID: "guid:gone", of: feed.id)
        world.library.addFeedBook(orphan)

        XCTAssertEqual(
            describe(world.library.succession(after: orphan, going: .down, skippingFinished: true)),
            "nothing No more books in folder"
        )
    }

    // MARK: - Helpers

    /// The manual sort a shelf's folder is in.
    private static let manual = FolderSortSetting(sortField: .manual, sortAscending: true)

    /// A succession in a few words a test compares: "book <title>",
    /// "download <title>", or "nothing <note>".
    private func describe(_ succession: BookSuccession) -> String {
        switch succession {
        case .book(let book): return "book \(book.title)"
        case .episodeToDownload(_, let item): return "download \(item.title)"
        case .nothing(let note): return "nothing \(note)"
        }
    }

    /// A model whose library holds a book for each title, in `Shelf` in that
    /// manual order, with those in `finished` resting at their ends.
    @MainActor
    private func shelfModel(_ titles: [String], finished: Set<String>) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: titles.enumerated().map { position, title in
                var book = LibrarySortStateTests.shelvedBook(title, in: "Shelf", manualOrder: position)
                if finished.contains(title) { Self.restAtEnd(&book) }
                return book
            },
            folderSortSettings: ["Shelf": Self.manual]
        )
        return model
    }

    /// The book titled `title` in the model's library; the test fails when
    /// there is none.
    @MainActor
    private func shelfBook(_ title: String, in model: LibraryViewModel) -> Book {
        guard let book = model.library.books.first(where: { $0.title == title }) else {
            XCTFail("No book titled \(title)")
            return LibrarySortStateTests.shelvedBook(title, in: "Shelf", manualOrder: 0)
        }
        return book
    }

    /// Puts `book` at its end, as a finished book rests.
    private static func restAtEnd(_ book: inout Book) {
        book.totalCharacterCount = 1_000
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 1_000, globalCharacterOffset: 1_000)
    }

    /// Downloads the feed item `guid` of `feed` as a book titled `title`, in
    /// the world's library and the feed's record, resting at its end when
    /// `atEnd`.
    @MainActor
    private func download(_ title: String, _ guid: String, of feed: Feed, in world: FeedTestWorld, atEnd: Bool = false) throws -> Book {
        var book = try makeFeedItem(title: title, itemID: "guid:\(guid)", of: feed.id)
        if atEnd { Self.restAtEnd(&book) }
        world.library.addFeedBook(book)
        world.center.store.updateItem("guid:\(guid)", of: feed.id) { $0.state = .downloaded(bookID: book.id) }
        return book
    }

    /// Subscribes `world` to a feed listing an episode for each of `guids`,
    /// newest first, titled "Episode <guid>".
    @MainActor
    private func subscribe(_ world: FeedTestWorld, guids: [String]) async throws -> Feed {
        let items = guids.enumerated().map { offset, guid in
            FeedXML.Item(
                guid: guid,
                title: "Episode \(guid)",
                published: world.day(-Double(offset + 1)),
                enclosure: "https://atlas.example/audio/\(guid).mp3"
            )
        }
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: items)))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(
            to: world.server.url("/atlas.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "EpisodeSuccessionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
