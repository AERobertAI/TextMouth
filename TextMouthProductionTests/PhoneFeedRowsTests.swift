import Combine
import XCTest
@testable import TextMouth

/// Feeds on the iPhone's Library (FR53, phase F1): the Feeds section's rows, a
/// feed's folder listing its items, the commands each row offers, and the words
/// of all of them, which are the Mac's. The engine is a test's own, with a stub
/// server, and the records a test changes are changed in its store directly: no
/// test reaches the network, plays a sound, or opens a book.
@MainActor
final class PhoneFeedRowsTests: XCTestCase {
    // MARK: - The Feeds Section

    /// The top of the library lists a feed under the Mac's "Feeds" heading, one
    /// row that says what the Mac's feed row says, with the Mac's commands; the
    /// feed's own folder is not also listed as a folder.
    func testTheFeedsSectionListsAFeedWithTheMacsWordsAndCommands() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsSection")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "A map you can touch", published: world.day(1)),
        ])
        let rows = PhoneLibraryFixture.rows(of: world.library)

        let section = try XCTUnwrap(rows.sections.first { $0.id == "feeds" })
        XCTAssertEqual(section.header, "Feeds")
        let row = try XCTUnwrap(section.rows.first)
        XCTAssertEqual(row.id, .feed(feed.id))
        XCTAssertEqual(row.kind, .feed)
        let content = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: ""), center: world.center).first)
        XCTAssertEqual(row.label, content.label)
        XCTAssertTrue(row.label.hasPrefix("The Tactile Atlas, Feed, 1 episode"), row.label)
        XCTAssertEqual(row.title, "The Tactile Atlas")
        XCTAssertEqual(row.hint, FeedWording.feedRowHint)
        XCTAssertEqual(row.commands.map(\.title), FeedAction.actions(for: feed.id, in: world.center).map(\.title))
        XCTAssertEqual(row.commands.map(\.action), FeedAction.actions(for: feed.id, in: world.center).map { .feed($0.command) })
        XCTAssertTrue(row.commands.last?.isDestructive == true, "Delete Feed… is destructive")
    }

    /// The folder that holds a feed's own folder says so beside its books, as
    /// the Mac's row does, and the feed's own folder is left out of its list.
    func testAFolderHoldingAFeedNamesIt() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsFolder")
        _ = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml")
        let rows = PhoneLibraryFixture.rows(of: world.library)

        let folders = try XCTUnwrap(rows.sections.first { $0.id == "folders" })
        XCTAssertEqual(folders.rows.count, 1, "the feed's own folder was listed")
        XCTAssertEqual(folders.rows.first?.id, .folder(world.bookFolder.id))
        XCTAssertEqual(folders.rows.first?.label, "\(world.bookFolder.name), 0 books, 1 feed")
        XCTAssertEqual(folders.rows.first?.detail, "0 books, 1 feed")
    }

    /// With no feed there is no Feeds section, and a library of books lists as it did.
    func testWithNoFeedThereIsNoFeedsSection() {
        let model = PhoneLibraryFixture.model(books: [PhoneLibraryFixture.book("Emma")])
        let rows = PhoneLibraryFixture.rows(of: model)

        XCTAssertEqual(rows.sections.map(\.header), ["Books (1)"])
        XCTAssertEqual(rows.rowIDs, [.book(model.library.books[0].id)])
    }

    /// The Mac's summary says the feeds beside the books, "2 books, 1 feed".
    func testTheSummaryCountsFeedsBesideBooks() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsSummary")
        _ = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml")
        world.library.library.books.append(PhoneLibraryFixture.book("Emma"))
        let rows = PhoneLibraryFixture.rows(of: world.library)

        XCTAssertTrue(rows.summary?.hasPrefix("1 book, 1 feed") ?? false, rows.summary ?? "nil")
    }

    // MARK: - The Feeds View

    /// The Feeds view lists the feeds alone, with no Books heading and no note.
    func testTheFeedsViewListsOnlyFeeds() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsView")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml")
        let view = try XCTUnwrap(LibraryViewDefinitionList.shipped.view(.feeds))
        let rows = PhoneLibraryFixture.rows(of: world.library, at: LibraryLocation(view: view, folderPath: ""))

        XCTAssertEqual(rows.sections.map(\.header), ["Feeds"])
        XCTAssertEqual(rows.rowIDs, [.feed(feed.id)])
        XCTAssertNil(rows.summary)
    }

    /// Offered the views, the sheet lists Feeds once there is a feed to list.
    func testTheViewsSheetOffersFeedsWithAFeed() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsChoices")
        let list = LibraryViewDefinitionList.shipped
        XCTAssertFalse(PhoneLibraryChoices.views(in: world.library, list: list, current: .category(.folders), center: world.center).contains { $0.id == .feeds })

        _ = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml")

        let offered = PhoneLibraryChoices.views(in: world.library, list: list, current: .category(.folders), center: world.center)
        XCTAssertTrue(offered.contains { $0.id == .feeds }, "Feeds was not offered: \(offered.map(\.label))")
        XCTAssertEqual(offered.first { $0.id == .feeds }?.label, "Feeds")
    }

    // MARK: - A Feed's Folder

    /// A feed's folder lists its items newest first under the Mac's heading;
    /// each item not downloaded is a row of its own whose label, notes, hint,
    /// and commands are the Mac's, less the two the phone doesn't have yet.
    func testAFeedsFolderListsItsItems() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsItems")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-2", title: "Second map", published: world.day(1)),
            FeedXML.Item(guid: "ep-1", title: "First map", published: world.day(-3)),
        ])
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let rows = PhoneLibraryFixture.rows(of: world.library, at: LibraryLocation(category: .folders, folderPath: folderPath))

        XCTAssertEqual(rows.sections.map(\.header), ["Episodes (2)"])
        XCTAssertEqual(rows.rowIDs, [.feedItem(feedID: feed.id, itemID: "guid:ep-2"), .feedItem(feedID: feed.id, itemID: "guid:ep-1")])
        let row = try XCTUnwrap(rows.sections.first?.rows.first)
        XCTAssertEqual(row.kind, .feedItem)
        XCTAssertEqual(row.title, "Second map")
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-2"))
        let content = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)
        XCTAssertEqual(row.label, content.label)
        XCTAssertTrue(row.label.hasPrefix("Second map, Not Downloaded"), row.label)
        XCTAssertEqual(row.hint, "Downloads it, then opens it")
        XCTAssertTrue(row.detail?.hasPrefix("Not Downloaded") ?? false, row.detail ?? "nil")
        XCTAssertEqual(row.commands.map(\.title), ["Open", "Download", "Mark Played", "Show Description…", "Delete Episode…"])
        XCTAssertEqual(
            row.commands.map(\.action),
            [.feedItem(.open), .feedItem(.download), .feedItem(.markPlayed), .feedItem(.showDescription), .feedItem(.deleteItem)]
        )
        XCTAssertTrue(row.commands.last?.isDestructive == true, "Delete Episode… is destructive")
        XCTAssertFalse(row.commands.contains { $0.action == .feedItem(.showInFinder) }, "Show in Finder is the Mac's")
        XCTAssertFalse(row.commands.contains { $0.action == .feedItem(.moveToLibrary) }, "Move to Library… waits for its sheet")
    }

    /// A downloaded item is its book's row, which says what any book's row
    /// says, and offers the item's commands beside the book's own; Delete
    /// Download stands for the removal, so Remove is not offered with it.
    func testADownloadedItemIsItsBooksRowWithTheItemsCommands() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsBook")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "First map", published: world.day(1)),
        ])
        let book = addBook(titled: "First map", to: world, feed: feed, item: "guid:ep-1")
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let rows = PhoneLibraryFixture.rows(of: world.library, at: LibraryLocation(category: .folders, folderPath: folderPath))

        XCTAssertEqual(rows.rowIDs, [.book(book.id)])
        let row = try XCTUnwrap(rows.sections.first?.rows.first)
        let titles = row.commands.map(\.title)
        XCTAssertTrue(titles.contains("Book Info"), "\(titles)")
        XCTAssertTrue(titles.contains("Delete Download"), "\(titles)")
        XCTAssertTrue(titles.contains("Mark Played"), "\(titles)")
        XCTAssertFalse(row.commands.contains { $0.action == .remove }, "Remove stands down for Delete Download: \(titles)")
        XCTAssertFalse(row.commands.contains { $0.action == .feedItem(.open) }, "a book's row opens itself")
        XCTAssertFalse(row.commands.contains { $0.action == .feedItem(.showInFinder) })
    }

    /// The summary of a feed's folder counts its items and says its last check,
    /// the Mac's words, even while no item is downloaded.
    func testAFeedsFolderSummarySaysItsItemsAndLastCheck() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsFolderSummary")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml")
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let rows = PhoneLibraryFixture.rows(of: world.library, at: LibraryLocation(category: .folders, folderPath: folderPath))

        let summary = world.center.folderSummary(of: feed.id, now: Date())
        XCTAssertEqual(rows.summary?.hasPrefix(summary.counts), true, rows.summary ?? "nil")
        XCTAssertTrue(rows.summary?.hasSuffix(summary.check.visible) ?? false, rows.summary ?? "nil")
        XCTAssertTrue(summary.counts.hasPrefix("1 episode"), summary.counts)
    }

    // MARK: - What Republishes

    /// An item played, or one downloaded, is a change of the list its row says;
    /// a checkpoint of a downloaded book's reading position is not.
    func testAnItemPlayedRepublishesTheList() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsRepublish")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "First map", published: world.day(1)),
        ])
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let rows = PhoneLibraryFixture.rows(of: world.library, at: LibraryLocation(category: .folders, folderPath: folderPath))
        XCTAssertFalse(rows.sections.first?.rows.first?.label.contains("Played") ?? true)
        let builds = rows.buildCount

        world.center.markPlayed("guid:ep-1", of: feed.id)
        await waitFor("the rows are built again") { rows.buildCount > builds }

        XCTAssertTrue(rows.sections.first?.rows.first?.label.contains("Played") ?? false, rows.sections.first?.rows.first?.label ?? "nil")
        XCTAssertEqual(rows.sections.first?.rows.first?.commands.map(\.title).contains("Mark Unplayed"), true)
    }

    // MARK: - Finding What a Command Acts On

    /// A command from a book's row or an item's row is built from the engine's
    /// record as it is now, in the Mac's words; none for an item that is gone.
    func testAnItemActionIsBuiltFromTheEnginesRecord() async throws {
        let world = try FeedTestWorld(self, label: "PhoneFeedRowsAction")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "First map", published: world.day(1)),
        ])

        let action = try XCTUnwrap(PhoneFeedRows.itemAction(.markPlayed, feedID: feed.id, itemID: "guid:ep-1", in: world.center))
        XCTAssertEqual(action.title, "Mark Played")
        XCTAssertEqual(action.itemTitle, "First map")
        XCTAssertEqual(action.feedID, feed.id)
        XCTAssertFalse(action.isArticle)
        XCTAssertNil(PhoneFeedRows.itemAction(.markPlayed, feedID: feed.id, itemID: "guid:gone", in: world.center))

        XCTAssertEqual(PhoneFeedRows.feedAction(.checkFeed, feedID: feed.id, in: world.center)?.title, "Check Feed")
        XCTAssertNil(PhoneFeedRows.feedAction(.resubscribe, feedID: feed.id, in: world.center), "a subscribed feed offers no Resubscribe")
    }

    /// The phone leaves out Show in Finder, which is the Mac's, and Move to
    /// Library…, whose sheet it has yet to have, and keeps the rest in the Mac's order.
    func testThePhoneOffersTheItemCommandsItHasASheetFor() {
        let all: [FeedItemCommand] = [
            .open, .download, .cancelDownload, .deleteDownload, .markPlayed, .markUnplayed, .showDescription, .moveToLibrary, .showInFinder, .deleteItem,
        ]
        XCTAssertEqual(all.filter(PhoneFeedRows.offers), [.open, .download, .cancelDownload, .deleteDownload, .markPlayed, .markUnplayed, .showDescription, .deleteItem])
    }

    // MARK: - Helpers

    /// Subscribes to a feed titled `title` served at `path` by the world's stub
    /// server, whose items default to one episode, in the world's library folder.
    private func subscribe(
        _ world: FeedTestWorld,
        title: String,
        path: String,
        items: [FeedXML.Item] = [FeedXML.Item(guid: "ep-1", title: "A map you can touch")]
    ) async throws -> Feed {
        let episodes = items.map { item -> FeedXML.Item in
            var episode = item
            if episode.enclosure == nil {
                episode.enclosure = "https://atlas.example/audio/\(item.guid ?? UUID().uuidString).mp3"
            }
            return episode
        }
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: episodes)))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(to: world.server.url(path).absoluteString, into: .newFolder(inParentPath: world.folder.path))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "PhoneFeedRowsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }

    /// A book standing for the download of the item `itemID` of `feed`, listed
    /// in the feed's folder, with the item marked downloaded as it. No package
    /// is written: nothing here reads one.
    @discardableResult
    private func addBook(titled title: String, to world: FeedTestWorld, feed: Feed, item itemID: FeedItem.ID) -> Book {
        // A feed item's row carries the link and no library folder: the feed's folder lists it by the link (FR11).
        var book = Book(
            title: title,
            format: .audio,
            filePath: "/nonexistent/\(UUID().uuidString).m4a",
            md5Hash: UUID().uuidString
        )
        book.feedLink = FeedBookLink(feedID: feed.id, itemID: itemID)
        world.library.library.books.append(book)
        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .downloaded(bookID: book.id) }
        return book
    }
}
