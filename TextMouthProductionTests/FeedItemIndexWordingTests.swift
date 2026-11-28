import XCTest
@testable import TextMouth

/// The library counts its books only and names its feeds beside them (FR11,
/// branch A1), as the user answered: "743 books, 2 feeds", in the summary
/// bar (seen and spoken alike), on entering a folder, in a folder's row, in
/// Storage settings and Use This Library, with "1 feed" in the singular and
/// the feeds left out where there are none; Rebuild Directory counts the
/// books alone. Each sentence is pinned here.
final class FeedItemIndexWordingTests: FeedItemIndexTestCase {

    // MARK: - The Words

    /// The books, and the feeds beside them where there are any.
    func testTheLibraryCountsBooksAndNamesItsFeedsBeside() {
        XCTAssertEqual(CountWording.booksAndFeeds(books: 743, feeds: 2), "743 books, 2 feeds")
        XCTAssertEqual(CountWording.booksAndFeeds(books: 1, feeds: 1), "1 book, 1 feed")
        XCTAssertEqual(CountWording.booksAndFeeds(books: 743, feeds: 0), "743 books")
        XCTAssertEqual(CountWording.booksAndFeeds(books: 0, feeds: 2), "2 feeds")
        XCTAssertEqual(CountWording.booksAndFeeds(books: 0, feeds: 0), "0 books")
        XCTAssertEqual(CountWording.feeds(1), "1 feed")
    }

    /// Refresh All Feeds ends its sentence with the new items counted in the
    /// kind's own words: none, one, and several, for episodes, articles, and
    /// a mixed feed.
    func testRefreshAllCountsTheNewItemsInTheKindsWords() {
        XCTAssertEqual(FeedWording.newItemsFound(0, .episode), "nothing new.")
        XCTAssertEqual(FeedWording.newItemsFound(1, .episode), "1 new episode.")
        XCTAssertEqual(FeedWording.newItemsFound(2, .episode), "2 new episodes.")
        XCTAssertEqual(FeedWording.newItemsFound(1, .article), "1 new article.")
        XCTAssertEqual(FeedWording.newItemsFound(12, .article), "12 new articles.")
        XCTAssertEqual(FeedWording.newItemsFound(1, .item), "1 new item.")
        XCTAssertEqual(FeedWording.newItemsFound(3, .item), "3 new items.")
    }

    // MARK: - The Summary Bar

    /// The summary bar shows and speaks the same count: the books, and the
    /// feeds the Feeds section lists there; in a feed's folder, the feed's
    /// items instead.
    @MainActor
    func testTheSummaryBarSaysWhatItShows() {
        let books = (1...3).map { Book(title: "Book \($0)", format: .txt, filePath: "/\($0).txt", md5Hash: "\($0)") }

        let withFeeds = TimeRemainingBar(books: books, wpm: 200, feedCount: 2)
        XCTAssertEqual(withFeeds.countText, "3 books, 2 feeds")
        XCTAssertTrue(withFeeds.summaryAccessibilityLabel.hasPrefix("3 books, 2 feeds. "), withFeeds.summaryAccessibilityLabel)

        XCTAssertEqual(TimeRemainingBar(books: books, wpm: 200, feedCount: 1).countText, "3 books, 1 feed")
        XCTAssertEqual(TimeRemainingBar(books: books, wpm: 200).countText, "3 books")
        XCTAssertEqual(TimeRemainingBar(books: [], wpm: 200, feedCount: 2).summaryAccessibilityLabel, "2 feeds")

        let check = FeedWording.Check(visible: "Checked today", spoken: "checked today", failed: false)
        let summary = FeedWording.FolderSummary(counts: "10 episodes, 1 downloaded", check: check)
        XCTAssertEqual(TimeRemainingBar(books: books, wpm: 200, feedSummary: summary).countText, "10 episodes, 1 downloaded")
    }

    // MARK: - Folders

    /// A folder's row, and its entry in the Folders rotor, name the feeds
    /// below it beside its books, or alone where it holds no book.
    @MainActor
    func testAFolderRowNamesTheFeedsBelowIt() {
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Podcasts", bookCount: 3, feedCounts: nil, feedsBelow: 2), "Podcasts, 3 books, 2 feeds")
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Shows", bookCount: 0, feedCounts: nil, feedsBelow: 1), "Shows, 1 feed")
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Fiction", bookCount: 12, feedCounts: nil), "Fiction, 12 books")
        XCTAssertEqual(FolderRow.countText(bookCount: 3, feedCounts: nil, feedsBelow: 2), "3 books, 2 feeds")
        XCTAssertEqual(FolderRow.countText(bookCount: 12, feedCounts: nil), "12 books")
    }

    /// Entering the library, or a folder holding feeds' folders, names the
    /// feeds there beside the books, as the Feeds section lists them.
    @MainActor
    func testEnteringALibraryOrFolderNamesItsFeeds() async throws {
        let item = try makeFeedItem(title: "Not A Book")
        let library = Library(books: [Book(title: "A", format: .txt, filePath: "/a.txt", md5Hash: "a"), item])
        XCTAssertEqual(FolderNavigationHistory.announcement(for: "", library: library, feedCount: 2), "Library, 1 book, 2 feeds")
        XCTAssertEqual(FolderNavigationHistory.announcement(for: "", library: library), "Library, 1 book")

        let world = try FeedTestWorld(self, label: "FeedItemWording")
        _ = try await subscribe(world, path: "/one.xml", title: "One Show")
        _ = try await subscribe(world, path: "/two.xml", title: "Two Show")
        let folders = LibraryFeedFolders(center: world.center)

        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: "", library: world.library.library, feedFolders: folders),
            "Library, 2 feeds"
        )
        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library, feedFolders: folders),
            "\(world.folder.path), 2 feeds"
        )
        let base = try XCTUnwrap(world.library.library.folders.first { $0.fullPath == world.folder.path })
        XCTAssertEqual(folders.feedCount(below: base), 2)
    }

    // MARK: - Storage Settings

    /// Library Statistics counts the library's own books, names the feeds on
    /// a line of their own where there are any, and counts the packages of
    /// its own books.
    func testStorageSettingsCountBooksAndFeeds() throws {
        let packaged = Book(title: "Packaged", format: .txt, filePath: "/p.txt", md5Hash: "p", tmbDirectoryName: "P.tmb")
        let loose = Book(title: "Loose", format: .txt, filePath: "/l.txt", md5Hash: "l")
        let item = try makeFeedItem(title: "An Episode")
        let library = Library(books: [packaged, loose, item], folders: [BookFolder(name: "Shelf")])

        XCTAssertEqual(LibraryStatistics(library: library, feedCount: 2).lines.map { "\($0.label): \($0.value)" }, [
            "Books: 2", "Feeds: 2", "Folders: 1", "TMB Packages: 1 of 2",
        ])
        XCTAssertEqual(LibraryStatistics(library: library, feedCount: 0).lines.map(\.label), ["Books", "Folders", "TMB Packages"])
    }

    /// Use This Library names the library in use by its books and feeds.
    func testUseThisLibraryNamesTheFeeds() {
        let withFeeds = StorageChoice.CurrentLibrary(folder: "/Users/me/.TextMouth", bookCount: 743, feedCount: 2, isAvailable: true)
        let without = StorageChoice.CurrentLibrary(folder: "/Users/me/.TextMouth", bookCount: 743, isAvailable: true)

        XCTAssertTrue(StorageWording.useSentence(of: "/Volumes/Other", current: withFeeds).contains("/Users/me/.TextMouth (743 books, 2 feeds) "))
        XCTAssertTrue(StorageWording.useSentence(of: "/Volumes/Other", current: without).contains("/Users/me/.TextMouth (743 books) "))
    }

    /// Rebuild Directory counts the library's own books, never a feed's
    /// items.
    func testRebuildDirectoryCountsTheBooks() throws {
        let books = (1...2).map { Book(title: "Book \($0)", format: .txt, filePath: "/\($0).txt", md5Hash: "\($0)") }
        let item = try makeFeedItem(title: "Left Where It Is")

        XCTAssertEqual(LibraryViewModel.rebuildDirectoryDoneMessage(Library(books: books + [item])), "Done. 2 books in library.")
        XCTAssertEqual(LibraryViewModel.rebuildDirectoryDoneMessage(Library(books: [books[0]])), "Done. 1 book in library.")
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed titled `title`, served at `path`, in a
    /// folder of its own inside the world's folder.
    @MainActor
    private func subscribe(_ world: FeedTestWorld, path: String, title: String) async throws -> Feed {
        let item = FeedXML.Item(guid: "ep-1", title: "Episode", enclosure: "https://atlas.example/audio/\(UUID().uuidString).mp3")
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: [item])))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(
            to: world.server.url(path).absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedItemIndexWordingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
