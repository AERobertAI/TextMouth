import XCTest
@testable import TextMouth

/// The places that leave a feed's items out (FR11, branch A1): All Items,
/// Unopened, the top of Folders, the folder counts, search there, the
/// metadata refresh, Find Duplicate Books and the duplicate question,
/// Rebuild Directory, and folder edits; and the places that list them
/// otherwise: a feed's folder lists its feed's items by feed ID, Recent lists
/// each feed's item opened last, and Continue to Next Book follows a feed's
/// folder.
final class FeedItemIndexListTests: FeedItemIndexTestCase {

    // MARK: - All Items, Unopened, and the Top of Folders

    /// All Items and Unopened list the library's own books, never a feed's
    /// items, opened or not, and a search there finds none.
    @MainActor
    func testAllItemsAndUnopenedLeaveFeedItemsOut() throws {
        let unopened = try makePackagedBook(title: "Unopened Book")
        var opened = try makePackagedBook(title: "Opened Book")
        opened.lastOpened = Self.date(10)
        let newItem = try makeFeedItem(title: "New Lemmings")
        let playedItem = try makeFeedItem(title: "Played Lemmings", lastOpened: Self.date(20))
        let model = makeModel(with: [unopened, opened, newItem, playedItem])

        XCTAssertEqual(Set(model.displayedBooks(at: Self.allItems).map(\.id)), [unopened.id, opened.id])
        XCTAssertEqual(model.displayedBooks(at: Self.unopened).map(\.id), [unopened.id])
        XCTAssertEqual(model.library.unopenedBooks().map(\.id), [unopened.id])
        XCTAssertEqual(model.displayedBooks(at: Self.allItems, matching: "Lemmings"), [])
        XCTAssertEqual(model.displayedBooks(at: Self.unopened, matching: "Lemmings"), [])
    }

    /// The top of Folders lists the books there, and the folder counts and
    /// the count at the top count the library's own books, never a feed's
    /// items, which name no folder.
    @MainActor
    func testTheTopOfFoldersAndTheCountsLeaveFeedItemsOut() throws {
        let atTop = Book(title: "At The Top", format: .txt, filePath: "/top.txt", md5Hash: "top")
        let inFolder = try makePackagedBook(title: "In The Folder")
        let item = try makeFeedItem(title: "Not At The Top")
        let model = makeModel(with: [atTop, inFolder, item])

        XCTAssertEqual(model.displayedBooks(at: LibraryLocation(category: .folders, folderPath: "")).map(\.id), [atTop.id])
        XCTAssertEqual(model.library.booksInFolder("").map(\.id), [atTop.id])
        // The top level's tree counts the books there, as it always has.
        XCTAssertEqual(model.bookCount(inFolderTree: ""), 1)
        XCTAssertEqual(model.bookCount(inFolderTree: folderPath), 1)
        XCTAssertEqual(model.library.totalBooksInFolderTree(""), 1)
        XCTAssertEqual(model.library.libraryBookCount, 2)
        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: "", library: model.library),
            "Library, 2 books"
        )
    }

    // MARK: - A Feed's Folder

    /// A feed's folder lists the feed's items, found by feed ID, beside the
    /// folder's own books, and its listing shows each downloaded item as its
    /// book's row; no other folder lists them.
    @MainActor
    func testAFeedsFolderListsItsItemsBesideItsBooks() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemFolder")
        let feed = try await subscribe(world, guids: ["ep-1"])
        let feedFolder = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let item = try makeFeedItem(title: "A map you can touch", itemID: "guid:ep-1", of: feed.id)
        world.library.addFeedBook(item)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.state = .downloaded(bookID: item.id) }
        let location = LibraryLocation(category: .folders, folderPath: feedFolder)

        let listed = world.library.displayedBooks(at: location)
        XCTAssertEqual(listed.map(\.id), [item.id])
        XCTAssertEqual(world.library.displayedBooks(at: location, matching: "touch").map(\.id), [item.id])
        XCTAssertEqual(world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: world.folder.path)).map(\.id), [])
        let listing = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: listed, folderBooks: listed, search: "", wordsPerMinute: 200
        )
        XCTAssertEqual(listing.entries.map(\.id), ["book:" + item.id.uuidString])
    }

    /// Feed Info's change of folder takes the feed's items along, though no
    /// row changes: the list of each folder is derived again.
    @MainActor
    func testAFeedsItemsFollowItToAnotherFolder() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemFolderMove")
        let feed = try await subscribe(world, guids: ["ep-1"])
        let first = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let item = try makeFeedItem(title: "Moving Along", itemID: "guid:ep-1", of: feed.id)
        world.library.addFeedBook(item)
        XCTAssertEqual(world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: first)).map(\.id), [item.id])
        let second = try world.library.createFolderReturningFolder(name: "Elsewhere", parentPath: world.folder.path)

        world.center.setFolder(second.id, of: feed.id)

        XCTAssertEqual(world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: first)).map(\.id), [])
        XCTAssertEqual(world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: second.fullPath)).map(\.id), [item.id])
    }

    // MARK: - Recent

    /// Recent lists books as before and, of each feed's items, only the one
    /// opened last, within the same ten.
    func testRecentListsEachFeedsLastOpenedItemOnly() {
        let feedID = self.feedID
        let otherFeed = UUID()
        func book(_ title: String, opened seconds: TimeInterval?, feed: UUID? = nil) -> Book {
            Book(
                title: title, format: .txt, filePath: "/\(title).txt", md5Hash: title,
                lastOpened: seconds.map { Self.date($0) },
                feedLink: feed.map { FeedBookLink(feedID: $0, itemID: title) }
            )
        }
        let older = book("Older Episode", opened: 20, feed: feedID)
        let newest = book("Newest Episode", opened: 30, feed: feedID)
        let other = book("Other Show", opened: 5, feed: otherFeed)
        let plain = book("A Book", opened: 10)
        let never = book("Never Opened", opened: nil)

        XCTAssertEqual(LibraryBookSorter.recent([older, newest, other, plain, never]).map(\.title), ["Newest Episode", "A Book", "Other Show"])

        let books = (1...12).map { book("Book \($0)", opened: Double($0)) }
        let feedItems = (1...5).map { book("Episode \($0)", opened: Double(100 + $0), feed: feedID) }
        let recent = LibraryBookSorter.recent(books + feedItems)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.title, "Episode 5")
        XCTAssertEqual(recent.filter(\.isFeedItem).count, 1)
        XCTAssertEqual(LibraryBookSorter.recent(books, limit: 0), [])
    }

    // MARK: - Continue to Next Book

    /// Continue to Next Book from a feed's item goes to the next one
    /// downloaded that its feed's folder lists after it, newest first, and
    /// to none after the last.
    @MainActor
    func testContinueToNextBookFollowsTheFeedsFolder() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemNext")
        let feed = try await subscribe(world, guids: ["ep-3", "ep-2", "ep-1"])
        let third = try makeFeedItem(title: "Third", itemID: "guid:ep-3", of: feed.id)
        let first = try makeFeedItem(title: "First", itemID: "guid:ep-1", of: feed.id)
        for book in [third, first] {
            world.library.addFeedBook(book)
            world.center.store.updateItem(book.feedLink?.itemID ?? "", of: feed.id) { $0.state = .downloaded(bookID: book.id) }
        }

        XCTAssertEqual(world.library.nextBookInFolder(after: third)?.id, first.id)
        XCTAssertNil(world.library.nextBookInFolder(after: first))
    }

    // MARK: - Maintenance

    /// The metadata refresh never reads a feed's item again: its title and
    /// author come from its feed.
    func testTheMetadataRefreshSkipsFeedItems() throws {
        let item = try makeFeedItem(title: "Named By The Feed")
        let plain = Book(title: "Unstamped", format: .txt, filePath: "/u.txt", md5Hash: "u")

        XCTAssertFalse(LibraryViewModel.needsMetadataRefresh(item))
        XCTAssertTrue(LibraryViewModel.needsMetadataRefresh(plain))
    }

    /// Find Duplicate Books scans the library's own books, and a book of the
    /// same file as a feed's item is no duplicate: the import neither asks
    /// about the item nor keeps the book out.
    @MainActor
    func testDuplicatesLeaveFeedItemsOut() throws {
        let item = try makeFeedItem(title: "Shared File")
        let model = makeModel(with: [item])
        let imported = Book(title: "Shared File", format: .html, filePath: "/imported.html", md5Hash: item.md5Hash)

        XCTAssertEqual(model.booksForDuplicateScan, [])
        XCTAssertNil(model.duplicateMatch(for: imported))
        model.library.addBook(imported)
        XCTAssertNotNil(model.bookByID(imported.id))
    }

    /// Rebuild Directory reconciles the library's own books with the Library
    /// folder while a feed's items wait aside, and puts them back as they
    /// were: their packages stay in their feed's folder and their rows keep
    /// their places.
    func testRebuildDirectoryLeavesFeedItemsAsTheyAre() throws {
        let item = try makeFeedItem(title: "Not Rebuilt")
        let book = try makePackagedBook(title: "Rebuilt")
        var library = Library(books: [item, book])
        var seenDuringTheRebuild: [UUID] = []

        _ = try library.withFeedItemsSetAside { aside -> LegacyMigrationReport in
            seenDuringTheRebuild = aside.books.map(\.id)
            return try FileImportService.rebuildDirectoryStructure(library: &aside)
        }

        XCTAssertFalse(seenDuringTheRebuild.contains(item.id))
        XCTAssertTrue(seenDuringTheRebuild.contains(book.id))
        XCTAssertEqual(library.books.first { $0.id == item.id }, item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.bookFileURL.path))
    }

    /// Moving a selection to a folder moves no feed's item: its package stays
    /// in its feed's folder, its row keeps its place, and the move says it
    /// was left where it is (REV10, item 6), rather than nothing: the Move
    /// sheet's move returns the words for the sheet's owner to say once the
    /// sheet has closed (REV11 F6), and a move with no sheet says them at
    /// once.
    @MainActor
    func testAFolderEditMovesNoFeedItem() async throws {
        /// What VoiceOver was asked to say, in order.
        @MainActor
        final class Heard {
            var messages: [String] = []
        }
        let item = try makeFeedItem(title: "Stays In Its Feed")
        let model = makeModel(with: [item])
        let heard = Heard()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.messages.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }

        let note = "Left “Stays In Its Feed” where it is: episodes and articles stay in their feeds; Move to Library… makes one a book of your library."
        let outcome = await model.moveBooksReturningOutcome([item], toFolder: folderPath)

        XCTAssertEqual(outcome, .success(note))
        XCTAssertEqual(model.bookByID(item.id), item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.bookFileURL.path))
        XCTAssertEqual(heard.messages, [], "the note was said while the Move sheet closed")

        await model.moveBooks([item], toFolder: folderPath).value
        XCTAssertEqual(heard.messages, [note])
    }

    /// A changed feed link changes the lists, as a book moving between
    /// folders does.
    func testAChangedFeedLinkChangesTheLists() throws {
        let item = try makeFeedItem(title: "Linked")
        var unlinked = item
        unlinked.feedLink = nil

        XCTAssertTrue(LibraryListCache.listsMayDiffer([item], [unlinked]))
        XCTAssertFalse(LibraryListCache.listsMayDiffer([item], [item]))
    }

    // MARK: - Helpers

    /// All Items.
    private static let allItems = LibraryLocation(category: .allItems, folderPath: "")
    /// Unopened.
    private static let unopened = LibraryLocation(category: .unopened, folderPath: "")

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
            throw NSError(domain: "FeedItemIndexListTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
