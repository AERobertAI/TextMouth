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

    // MARK: - Helpers

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
