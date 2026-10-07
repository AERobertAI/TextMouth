import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The feeds in the library list (FR03): the Feeds section, shown only
/// where there are feeds, with a row per feed counting its items and saying
/// its last check in one sentence; a feed's folder, which lists the feed's
/// items newest first with the downloaded ones as their books; the note
/// "Feed" after a feed folder's name, in its row and the Folders rotor; the
/// summary bar counting a feed's items; and the announcement on entering a
/// feed's folder. The engine is a test's own, with a stub server, and the
/// records a test changes are changed in its store directly.
@MainActor
final class FeedUILibraryRowsTests: XCTestCase {

    // MARK: - Where the Feeds Section Shows

    /// The section lists the feeds whose folders are inside the location,
    /// at any depth, by title: every feed at the top of the library and in
    /// All Items, and in Unopened while it has an episode not yet played,
    /// none in a feed's own folder or in Recent.
    func testTheFeedsSectionListsTheFeedsInsideTheLocation() async throws {
        let world = try FeedTestWorld(self, label: "FeedUISection")
        let base = world.folder.path
        try world.library.createFolderReturningFolder(name: "Shows", parentPath: base)
        let atlas = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        let notes = try await subscribe(world, title: "Harbour Notes", path: "/notes.xml", into: "\(base)/Shows")
        let atlasFolder = try XCTUnwrap(world.library.feedFolderPath(forFolderID: atlas.folderID))

        func titles(_ category: LibraryCategory, _ path: String = "") -> [String] {
            LibraryFeedsSectionRows.rows(at: LibraryLocation(category: category, folderPath: path), center: world.center).map(\.title)
        }
        XCTAssertEqual(titles(.folders), ["Harbour Notes", "The Tactile Atlas"])
        XCTAssertEqual(titles(.folders, base), ["Harbour Notes", "The Tactile Atlas"])
        XCTAssertEqual(titles(.folders, "\(base)/Shows"), ["Harbour Notes"])
        XCTAssertEqual(titles(.folders, atlasFolder), [], "a feed's own folder listed itself")
        XCTAssertEqual(titles(.allItems), ["Harbour Notes", "The Tactile Atlas"])
        XCTAssertEqual(titles(.unopened), ["Harbour Notes", "The Tactile Atlas"], "each feed has an episode not yet played")
        XCTAssertEqual(titles(.recent), [])
        XCTAssertNotEqual(notes.id, atlas.id)
    }

    /// A feed whose folder is gone shows at the top of the library and in
    /// All Items, saying its folder is missing, so it can still be found.
    func testAFeedWhoseFolderIsGoneShowsAtTheTop() async throws {
        let world = try FeedTestWorld(self, label: "FeedUISectionGone")
        let feed = try await subscribe(world, title: "Lost Signal", path: "/lost.xml", into: world.folder.path)
        world.library.library.folders.removeAll { $0.id == feed.folderID }

        let top = LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: ""), center: world.center)
        XCTAssertEqual(top.map(\.title), ["Lost Signal"])
        XCTAssertNil(top.first?.folderPath)
        XCTAssertTrue(top.first?.label.hasPrefix("Lost Signal, Feed, Folder missing, 1 episode") ?? false, top.first?.label ?? "")
        XCTAssertEqual(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: world.folder.path), center: world.center), [])
        XCTAssertEqual(FeedWording.folderMissing(title: "Lost Signal"), "The folder of Lost Signal is no longer in the library.")
    }

    // MARK: - A Feed's Row

    /// A feed's row counts its items, its downloads and downloads under way,
    /// and the new ones, and says its last check, in one sentence.
    func testAFeedsRowCountsItsItemsAndSaysItsLastCheck() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIRowCounts")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-3", title: "Third", published: world.day(1)),
            FeedXML.Item(guid: "ep-2", title: "Second", published: world.day(0.5)),
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(-3)),
        ])
        // One downloaded, one downloading.
        let book = addBook(titled: "Second", to: world, feed: feed, item: "guid:ep-2")
        world.center.store.updateItem("guid:ep-3", of: feed.id) {
            $0.state = .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 40, totalBytes: 100))
        }

        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center).first)

        XCTAssertEqual(row.counts, FeedItemCounts(listed: 3, downloaded: 1, downloading: 1, new: 2, unplayed: 3, noun: .episode))
        XCTAssertEqual(row.countsText, "3 episodes, 1 downloaded, 1 downloading, 2 new")
        let check = FeedWording.check(world.center.fetchState(of: feed.id), isRefreshing: false, now: Date())
        XCTAssertEqual(row.check, check)
        XCTAssertTrue(check.spoken.hasPrefix("checked "), check.spoken)
        XCTAssertEqual(row.label, "The Tactile Atlas, Feed, 3 episodes, 1 downloaded, 1 downloading, 2 new, \(check.spoken)")

        // Opening the downloaded episode's book makes it no longer new. The
        // row is changed in place: the book has no package to save.
        let index = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == book.id })
        world.library.library.books[index].lastOpened = Date()
        XCTAssertEqual(world.center.counts(of: feed.id).new, 1)
        // Played, an episode is neither new nor unplayed.
        world.center.markPlayed("guid:ep-3", of: feed.id)
        XCTAssertEqual(world.center.counts(of: feed.id).new, 0)
        XCTAssertEqual(world.center.counts(of: feed.id).unplayed, 2)
    }

    /// The last check reads as being checked, never checked, failed with
    /// its reason, or the day and time: today, yesterday, a day this year,
    /// or a day of another year.
    func testTheLastCheckReadsAsADayAndATime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 15, minute: 30)))
        func reading(_ fetch: FeedFetchState, refreshing: Bool = false) -> FeedWording.Check {
            let check = FeedWording.check(fetch, isRefreshing: refreshing, now: now, calendar: calendar, locale: locale)
            // Some systems put a narrow space before AM and PM.
            return FeedWording.Check(
                visible: check.visible.replacingOccurrences(of: "\u{202F}", with: " "),
                spoken: check.spoken.replacingOccurrences(of: "\u{202F}", with: " "),
                failed: check.failed
            )
        }
        var fetch = FeedFetchState()
        XCTAssertEqual(reading(fetch), FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false))
        XCTAssertEqual(reading(fetch, refreshing: true), FeedWording.Check(visible: "Checking now", spoken: "checking now", failed: false))

        fetch.lastCheck = calendar.date(byAdding: .minute, value: -25, to: now)
        XCTAssertEqual(reading(fetch).visible, "Checked today at 3:05 PM")
        XCTAssertEqual(reading(fetch).spoken, "checked today at 3:05 PM")
        fetch.lastCheck = calendar.date(byAdding: .hour, value: -20, to: now)
        XCTAssertEqual(reading(fetch).visible, "Checked yesterday at 7:30 PM")
        fetch.lastCheck = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9, minute: 0))
        XCTAssertEqual(reading(fetch).visible, "Checked September 1 at 9:00 AM")
        fetch.lastCheck = calendar.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 9, minute: 0))
        XCTAssertEqual(reading(fetch).visible, "Checked December 30, 2025 at 9:00 AM")

        fetch.lastError = FeedRefreshFailure(message: "The server feeds.example couldn't be found. Check the address.", date: now)
        XCTAssertEqual(reading(fetch), FeedWording.Check(
            visible: "Last check failed: The server feeds.example couldn't be found. Check the address.",
            spoken: "last check failed: The server feeds.example couldn't be found. Check the address.",
            failed: true
        ))
    }

    // MARK: - Items

    /// An item's row says its title, its notes, its date, and its duration
    /// in one sentence, the most telling words first, for each state.
    func testAnItemsRowSaysItsStateDateAndDuration() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIItemRows")
        let published = world.day(0.5)
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-1", title: "How tides are measured", published: published),
        ])
        let itemID = "guid:ep-1"
        world.center.store.updateItem(itemID, of: feed.id) { $0.duration = 1_683 }
        let date = FeedWording.itemDate(published)
        func label() throws -> String {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            return FeedItemRowContent(item, of: feed, in: world.center).label
        }

        XCTAssertEqual(try label(), "How tides are measured, Not Downloaded, New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) {
            $0.state = .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 40, totalBytes: 100))
        }
        XCTAssertEqual(try label(), "How tides are measured, Downloading, 40 percent, New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .failed("The server says the file is gone.") }
        XCTAssertEqual(try label(), "How tides are measured, Download Failed, The server says the file is gone., New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) {
            $0.state = .notDownloaded
            $0.playedDate = world.day(1)
        }
        XCTAssertEqual(try label(), "How tides are measured, Played, Not Downloaded, \(date), 28 minutes, 3 seconds")
        XCTAssertEqual(FeedWording.playedNote(isArticle: true), "Read")
        XCTAssertEqual(FeedWording.itemRowHint(.notDownloaded), "Downloads it, then opens it")
        XCTAssertEqual(FeedWording.itemRowHint(.downloaded(bookID: UUID())), "Opens it")
    }

    /// A feed's folder lists the feed's items newest first, each downloaded
    /// one as its book, then the folder's other books; the search narrows
    /// items as it narrows books, and an item whose book lives in another
    /// folder stays an item row.
    func testAFeedsFolderListsItsItemsNewestFirstWithItsBooks() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderListing")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-3", title: "A map you can touch", published: world.day(1)),
            FeedXML.Item(guid: "ep-2", title: "Braille street signs", published: world.day(0.5)),
            FeedXML.Item(guid: "ep-1", title: "The first visit", published: world.day(-3)),
        ])
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let episode = addBook(titled: "Braille street signs", to: world, feed: feed, item: "guid:ep-2")
        let other = Book(title: "Field notes", format: .txt, filePath: "/nonexistent/notes.txt", md5Hash: "notes", folderPath: folderPath)
        world.library.library.books.append(other)

        let all = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [episode, other], folderBooks: [episode, other], search: "")
        XCTAssertEqual(all.entries.map(\.id), ["item:guid:ep-3", "book:\(episode.id.uuidString)", "item:guid:ep-1"])
        XCTAssertEqual(all.otherBooks, [other])
        XCTAssertEqual(all.noun, .episode)
        XCTAssertEqual(FeedWording.sectionTitle(all.noun, count: all.entries.count), "Episodes (3)")
        XCTAssertEqual(FeedWording.otherBooksTitle(count: 1), "Books (1)")

        // The search narrows items and books alike.
        let searched = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [episode, other], search: "MAP")
        XCTAssertEqual(searched.entries.map(\.id), ["item:guid:ep-3"])
        XCTAssertEqual(searched.otherBooks, [])

        // An episode whose book lives in another folder stays an item,
        // downloaded.
        let elsewhere = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [other], folderBooks: [other], search: "")
        guard case .item(let moved)? = elsewhere.entries.dropFirst().first else { return XCTFail("\(elsewhere.entries)") }
        XCTAssertEqual(moved.state, .downloaded(bookID: episode.id))
        XCTAssertEqual(moved.state.visibleNote, "Downloaded")
    }

    // MARK: - Folders, the Rotor, the Bar, and Entering

    /// A feed's folder says "Feed" after its name, in its row and in the
    /// Folders rotor, which share one label, and a folder of one book is
    /// "1 book" in both.
    func testAFeedsFolderSaysFeedAfterItsName() {
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Planet Money", bookCount: 3, isFeed: true), "Planet Money, Feed, 3 books")
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Poems", bookCount: 1, isFeed: false), "Poems, 1 book")
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Fiction", bookCount: 12, isFeed: false), "Fiction, 12 books")
    }

    /// Which folders hold feeds follows the engine, and changes only when a
    /// feed is subscribed or unsubscribed, never with a download's progress.
    func testWhichFoldersHoldFeedsChangesOnlyWithTheFeeds() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderMap")
        let folders = LibraryFeedFolders(center: world.center)
        var publishes = 0
        let subscription = folders.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path)
        XCTAssertEqual(folders.feedID(inFolder: feed.folderID), feed.id)
        let afterSubscribing = publishes
        XCTAssertGreaterThan(afterSubscribing, 0)

        for percent in stride(from: 10, through: 90, by: 10) {
            world.center.store.updateItem("guid:ep-1", of: feed.id) {
                $0.state = .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: Int64(percent), totalBytes: 100))
            }
        }
        XCTAssertEqual(publishes, afterSubscribing, "a download's progress published the folders")

        world.center.unsubscribe(feed.id)
        XCTAssertNil(folders.feedID(inFolder: feed.folderID))
        XCTAssertGreaterThan(publishes, afterSubscribing)
    }

    /// The summary bar of a feed's folder counts the feed's items in place
    /// of the books, shows even before any download, and ends with the last
    /// check.
    func testTheSummaryBarCountsTheFeedsItems() {
        let summary = FeedWording.FolderSummary(
            counts: "3 episodes, 1 new",
            check: FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        )
        let bar = TimeRemainingBar(books: [], wpm: 200, feedSummary: summary)
        XCTAssertEqual(bar.summaryAccessibilityLabel, "3 episodes, 1 new. Not checked yet")
        let plain = TimeRemainingBar(books: [], wpm: 200)
        XCTAssertEqual(plain.summaryAccessibilityLabel, "0 books")
    }

    /// Entering a feed's folder says its name, "Feed", and the feed's items
    /// counted; any other folder is announced as before.
    func testEnteringAFeedsFolderSaysItsItems() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIEnter")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-2", title: "Second", published: world.day(0.5)),
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(-3)),
        ])
        let folders = LibraryFeedFolders(center: world.center)
        let path = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))

        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: path, library: world.library.library, feedFolders: folders),
            "The Tactile Atlas, Feed, 2 episodes, 1 new"
        )
        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library, feedFolders: folders),
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library)
        )
    }

    // MARK: - The List as Drawn

    /// The library list draws a Feeds row for each feed at the top of the
    /// library, and, in a feed's folder, an item row for each item; a
    /// download's progress then redraws the feed's rows and never the list
    /// around them.
    func testTheListDrawsFeedRowsAndAProgressRedrawsOnlyThem() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIDrawn")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-2", title: "Second", published: world.day(0.5)),
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(-3)),
        ])
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let feedFolders = LibraryFeedFolders(center: world.center)

        // The top of the library: one Feeds row.
        let rowsBefore = ViewBodyCounter.count(of: "FeedRow")
        let top = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: feedFolders
            )
            .environmentObject(world.library)
            .environmentObject(settings)
        )
        settle(top.hostingView, seconds: 0.5)
        XCTAssertGreaterThan(ViewBodyCounter.count(of: "FeedRow"), rowsBefore, "no Feeds row was drawn")
        takeDown(top.window)

        // The feed's folder: an item row for each item.
        let itemsBefore = ViewBodyCounter.count(of: "FeedItemRow")
        let inside = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(folderPath),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: feedFolders
            )
            .environmentObject(world.library)
            .environmentObject(settings)
        )
        defer { takeDown(inside.window) }
        settle(inside.hostingView, seconds: 0.5)
        XCTAssertGreaterThanOrEqual(ViewBodyCounter.count(of: "FeedItemRow") - itemsBefore, 2, "the items were not drawn")

        let runs = bodyRuns(of: ["LibraryView.list", "FeedFolderSections"], in: inside.hostingView, publishing: 10) { index in
            let written = Int64(10 + max(index, 0) * 5)
            world.center.store.updateItem("guid:ep-2", of: feed.id) {
                $0.state = .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: written, totalBytes: 100))
            }
        }
        XCTAssertEqual(runs["LibraryView.list"], 0, "a download's progress drew the whole list again")
        XCTAssertGreaterThan(runs["FeedFolderSections", default: 0], 0, "the feed's rows never followed the progress")
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed titled `title` served at `path`, listing
    /// `items` (one episode by default), into a new folder inside the folder
    /// at `parentPath`. Each item offers audio, which no test downloads, so
    /// every one is an episode rather than an article.
    private func subscribe(
        _ world: FeedTestWorld,
        title: String,
        path: String,
        into parentPath: String,
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
        let outcome = try await world.center.subscribe(to: world.server.url(path).absoluteString, into: .newFolder(inParentPath: parentPath))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedUILibraryRowsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }

    /// A book standing for the download of the item `itemID` of `feed`,
    /// listed in the feed's folder, with the item marked downloaded as it.
    /// No package is written: nothing here reads one.
    @discardableResult
    private func addBook(titled title: String, to world: FeedTestWorld, feed: Feed, item itemID: FeedItem.ID) -> Book {
        let folderPath = world.library.feedFolderPath(forFolderID: feed.folderID) ?? world.folder.path
        let book = Book(
            title: title,
            format: .audio,
            filePath: "/nonexistent/\(UUID().uuidString).m4a",
            md5Hash: UUID().uuidString,
            folderPath: folderPath
        )
        world.library.library.books.append(book)
        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .downloaded(bookID: book.id) }
        return book
    }
}
