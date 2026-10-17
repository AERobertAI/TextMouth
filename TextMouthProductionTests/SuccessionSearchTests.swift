import XCTest
@testable import TextMouth

/// The library's search for the book beside another, either way (FR19, B1):
/// `booksBeyond(_:going:)` and `nextBook(after:going:skippingFinished:)`, in a
/// plain folder by its manual order and in a feed's folder by the feed's
/// listing, newest first; and the old names, `laterBooksInFolder(after:)` and
/// `nextBookInFolder(after:)`, which now go through them.
final class SuccessionSearchTests: FeedItemIndexTestCase {

    // MARK: - A plain folder

    /// A plain folder's books beyond one, nearest first: those after it going
    /// down, those before it, read backward, going up; and none beyond either end.
    @MainActor
    func testBooksBeyondInAPlainFolderGoBothWays() {
        let model = shelfModel(["Almanac", "Bestiary", "Chronicle", "Ledger"], finished: [])
        let bestiary = shelfBook("Bestiary", in: model)

        XCTAssertEqual(model.booksBeyond(bestiary, going: .down).map(\.title), ["Chronicle", "Ledger"])
        XCTAssertEqual(model.booksBeyond(bestiary, going: .up).map(\.title), ["Almanac"])
        XCTAssertEqual(model.booksBeyond(shelfBook("Ledger", in: model), going: .down), [])
        XCTAssertEqual(model.booksBeyond(shelfBook("Almanac", in: model), going: .up), [])
    }

    /// The folder's manual order decides, not the order of the library's rows.
    @MainActor
    func testBooksBeyondFollowTheManualOrderNotTheRows() {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: [
                LibrarySortStateTests.shelvedBook("Third", in: "Shelf", manualOrder: 2),
                LibrarySortStateTests.shelvedBook("First", in: "Shelf", manualOrder: 0),
                LibrarySortStateTests.shelvedBook("Second", in: "Shelf", manualOrder: 1),
            ],
            folderSortSettings: ["Shelf": Self.manual]
        )
        let second = shelfBook("Second", in: model)

        XCTAssertEqual(model.booksBeyond(second, going: .down).map(\.title), ["Third"])
        XCTAssertEqual(model.booksBeyond(second, going: .up).map(\.title), ["First"])
    }

    /// A book the sequence does not hold has no books beyond it.
    @MainActor
    func testBooksBeyondABookOutsideTheLibraryAreEmpty() {
        let model = shelfModel(["Almanac", "Bestiary"], finished: [])
        let stranger = LibrarySortStateTests.shelvedBook("Stranger", in: "Shelf", manualOrder: 0)

        XCTAssertEqual(model.booksBeyond(stranger, going: .down), [])
        XCTAssertEqual(model.booksBeyond(stranger, going: .up), [])
    }

    /// Skipping finished books passes over those resting at their ends, either
    /// way; not skipping returns the adjacent book, finished or not; nothing
    /// qualifying, or the end of the folder, gives nil.
    @MainActor
    func testNextBookSkipsFinishedBooksInAPlainFolderBothWays() {
        let model = shelfModel(
            ["Almanac", "Bestiary", "Chronicle", "Ledger", "Margins"],
            finished: ["Bestiary", "Chronicle", "Margins"]
        )
        func next(after title: String, _ direction: ReadingList.Direction, skipping: Bool) -> String? {
            model.nextBook(after: shelfBook(title, in: model), going: direction, skippingFinished: skipping)?.title
        }

        XCTAssertEqual(next(after: "Almanac", .down, skipping: true), "Ledger")
        XCTAssertEqual(next(after: "Almanac", .down, skipping: false), "Bestiary")
        XCTAssertEqual(next(after: "Ledger", .up, skipping: true), "Almanac")
        XCTAssertEqual(next(after: "Ledger", .up, skipping: false), "Chronicle")
        XCTAssertNil(next(after: "Ledger", .down, skipping: true), "Only a finished book follows Ledger")
        XCTAssertEqual(next(after: "Ledger", .down, skipping: false), "Margins")
        XCTAssertNil(next(after: "Margins", .down, skipping: false))
        XCTAssertNil(next(after: "Almanac", .up, skipping: false))
    }

    /// The old names give what they always gave: `laterBooksInFolder` all the
    /// books after, `nextBookInFolder` the first that is not finished.
    @MainActor
    func testTheOldNamesReturnWhatTheyReturned() {
        let model = shelfModel(
            ["Almanac", "Bestiary", "Chronicle", "Ledger"],
            finished: ["Bestiary", "Chronicle"]
        )
        let almanac = shelfBook("Almanac", in: model)
        let ledger = shelfBook("Ledger", in: model)

        XCTAssertEqual(model.laterBooksInFolder(after: almanac).map(\.title), ["Bestiary", "Chronicle", "Ledger"])
        XCTAssertEqual(model.nextBookInFolder(after: almanac)?.title, "Ledger")
        XCTAssertEqual(model.laterBooksInFolder(after: ledger), [])
        XCTAssertNil(model.nextBookInFolder(after: ledger))
    }

    // MARK: - A feed's folder

    /// A feed's books beyond an item are the items downloaded that its
    /// listing puts beyond it, newest first going down and the other way going
    /// up; an item not downloaded is passed over both ways.
    @MainActor
    func testBooksBeyondInAFeedsFolderLeaveOutItemsNotDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "SuccessionBeyond")
        let feed = try await subscribe(world, guids: ["ep-4", "ep-3", "ep-2", "ep-1"])
        // Episode 2 is listed but its file is not here.
        let fourth = try download("Fourth", "ep-4", of: feed, in: world)
        let third = try download("Third", "ep-3", of: feed, in: world)
        let first = try download("First", "ep-1", of: feed, in: world)

        XCTAssertEqual(world.library.booksBeyond(fourth, going: .down).map(\.id), [third.id, first.id])
        XCTAssertEqual(world.library.booksBeyond(third, going: .down).map(\.id), [first.id])
        XCTAssertEqual(world.library.booksBeyond(first, going: .up).map(\.id), [third.id, fourth.id])
        XCTAssertEqual(world.library.booksBeyond(third, going: .up).map(\.id), [fourth.id])
        XCTAssertEqual(world.library.booksBeyond(first, going: .down), [])
        XCTAssertEqual(world.library.booksBeyond(fourth, going: .up), [])
        XCTAssertEqual(world.library.laterBooksInFolder(after: fourth).map(\.id), [third.id, first.id])
    }

    /// The next book in a feed's folder either way, passing over a finished
    /// item while skipping and returning it otherwise; the old name goes down
    /// and skips.
    @MainActor
    func testNextBookInAFeedsFolderSkipsFinishedItemsBothWays() async throws {
        let world = try FeedTestWorld(self, label: "SuccessionNext")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try download("Third", "ep-3", of: feed, in: world)
        let second = try download("Second", "ep-2", of: feed, in: world, atEnd: true)
        let first = try download("First", "ep-1", of: feed, in: world)

        XCTAssertEqual(world.library.nextBook(after: third, going: .down, skippingFinished: true)?.id, first.id)
        XCTAssertEqual(world.library.nextBook(after: third, going: .down, skippingFinished: false)?.id, second.id)
        XCTAssertEqual(world.library.nextBook(after: first, going: .up, skippingFinished: true)?.id, third.id)
        XCTAssertEqual(world.library.nextBook(after: first, going: .up, skippingFinished: false)?.id, second.id)
        XCTAssertNil(world.library.nextBook(after: first, going: .down, skippingFinished: false))
        XCTAssertNil(world.library.nextBook(after: third, going: .up, skippingFinished: false))
        XCTAssertEqual(world.library.nextBookInFolder(after: third)?.id, first.id)
    }

    // MARK: - Helpers

    /// The manual sort a shelf's folder is in.
    private static let manual = FolderSortSetting(sortField: .manual, sortAscending: true)

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
    /// newest first, in a folder of its own inside the world's folder.
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
            throw NSError(domain: "SuccessionSearchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
