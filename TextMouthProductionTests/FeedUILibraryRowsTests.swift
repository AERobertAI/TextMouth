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
    /// All Items, and in Unopened only while it has a new episode (FR11,
    /// question 8), not for its back catalogue, none in a feed's own folder
    /// or in Recently Opened.
    func testTheFeedsSectionListsTheFeedsInsideTheLocation() async throws {
        let world = try FeedTestWorld(self, label: "FeedUISection")
        let base = world.folder.path
        try world.library.createFolderReturningFolder(name: "Shows", parentPath: base)
        // An episode published after subscribing is new; the undated one
        // seen as the feed is subscribed to is its back catalogue.
        let atlas = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base, items: [
            FeedXML.Item(guid: "ep-1", title: "A map you can touch", published: world.day(1)),
        ])
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
        XCTAssertEqual(titles(.unopened), ["The Tactile Atlas"], "only a feed with a new episode is unopened")
        XCTAssertEqual(world.center.counts(of: notes.id).unplayed, 1, "the back catalogue's episode is not played")
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

        XCTAssertEqual(
            row.counts,
            FeedItemCounts(listed: 3, total: FeedEntryTotal(count: 3), downloaded: 1, downloading: 1, new: 2, unplayed: 3, noun: .episode)
        )
        XCTAssertEqual(row.countsText, "3 episodes, 1 downloaded, 1 downloading, 2 new, 3 unplayed")
        let check = FeedWording.check(world.center.fetchState(of: feed.id), isRefreshing: false, now: Date())
        XCTAssertEqual(row.check, check)
        XCTAssertTrue(check.spoken.hasPrefix("checked "), check.spoken)
        XCTAssertEqual(row.label, "The Tactile Atlas, Feed, 3 episodes, 1 downloaded, 1 downloading, 2 new, 3 unplayed, \(check.spoken)")

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

    // MARK: - A Feed's Size

    /// A feed's size reads as the number listed of the feed's entries when
    /// the feed lists more than the library does, "10 of 381 episodes
    /// listed" (the user's answer to FR11's question 10, since every record
    /// is kept now), the noun agreeing with the number before it, and a feed
    /// longer than TextMouth reads said to list more; otherwise, and while
    /// the size is unknown, as the number listed alone, as it always read.
    /// Every count of a feed starts with it, shown and spoken alike.
    func testAFeedsSizeSaysHowManyOfItsEntriesAreListed() {
        /// The size `listed` of `total` reads as.
        func size(_ listed: Int, _ total: FeedEntryTotal?, _ noun: FeedWording.ItemNoun = .episode) -> String {
            FeedWording.sizePhrase(listed: listed, total: total, noun: noun)
        }
        XCTAssertEqual(size(10, FeedEntryTotal(count: 381)), "10 of 381 episodes listed")
        XCTAssertEqual(size(1, FeedEntryTotal(count: 381)), "1 of 381 episodes listed")
        XCTAssertEqual(size(0, FeedEntryTotal(count: 1)), "0 of 1 episode listed")
        XCTAssertEqual(size(10, FeedEntryTotal(count: 381), .article), "10 of 381 articles listed")
        XCTAssertEqual(size(10, FeedEntryTotal(count: 381), .item), "10 of 381 items listed")
        XCTAssertEqual(size(10, FeedEntryTotal(count: 2_000, listsMore: true)), "10 of more than 2000 episodes listed")
        XCTAssertEqual(size(2_000, FeedEntryTotal(count: 2_000, listsMore: true)), "2000 of more than 2000 episodes listed")
        // Every entry listed, more listed than the feed lists now, or the
        // size not known yet.
        XCTAssertEqual(size(12, FeedEntryTotal(count: 12)), "12 episodes")
        XCTAssertEqual(size(10, FeedEntryTotal(count: 5)), "10 episodes")
        XCTAssertEqual(size(1, FeedEntryTotal(count: 1)), "1 episode")
        XCTAssertEqual(size(12, nil), "12 episodes")
        XCTAssertEqual(size(1, nil, .article), "1 article")
        XCTAssertEqual(size(0, nil), "0 episodes")
        XCTAssertEqual(FeedWording.listedNote, "listed")
        XCTAssertEqual(FeedWording.moreThanNote, "more than")

        let counts = FeedItemCounts(listed: 10, total: FeedEntryTotal(count: 381), downloaded: 3, downloading: 1, new: 2, noun: .episode)
        XCTAssertEqual(FeedWording.sizePhrase(counts), "10 of 381 episodes listed")
        XCTAssertEqual(FeedWording.countsPhrase(counts), "10 of 381 episodes listed, 3 downloaded, 1 downloading, 2 new")
        XCTAssertEqual(
            FeedWording.folderAnnouncement(name: "Planet Money", counts: counts),
            "Planet Money, Feed, 10 of 381 episodes listed, 3 downloaded, 1 downloading, 2 new"
        )
        let check = FeedWording.Check(visible: "Checked today at 3:05 PM", spoken: "checked today at 3:05 PM", failed: false)
        XCTAssertEqual(
            FeedWording.feedRowLabel(title: "Planet Money", counts: counts, check: check, folderMissing: false),
            "Planet Money, Feed, 10 of 381 episodes listed, 3 downloaded, 1 downloading, 2 new, checked today at 3:05 PM"
        )
        XCTAssertEqual(FeedWording.subscribed(title: "Planet Money", counts: counts), "Subscribed to Planet Money: 10 of 381 episodes listed.")
    }

    /// Every place that counts a feed says its size the same way: its row,
    /// its folder's summary bar, entering its folder, Speak Info, and the
    /// announcement after subscribing. A feed whose size is not known yet,
    /// a feed listing every entry, a feed listing fewer entries than the
    /// library's short list counts, a feed of one entry, and a feed of
    /// articles each count as they should.
    func testEveryCountOfAFeedSaysItsSize() async throws {
        let world = try FeedTestWorld(self, label: "FeedUISize")
        // A short list of the newest 10 (FR11's "Only the newest 5 listed",
        // with 10 for its number), which every feed below keeps but one.
        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        FeedSettings.newestCountPreference.write(10, to: world.preferences)
        let episodes = (1...12).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)))
        }
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: episodes)
        let counts = world.center.counts(of: feed.id)
        XCTAssertEqual(counts.listed, 10)
        XCTAssertEqual(counts.total, FeedEntryTotal(count: 12))
        let size = "10 of 12 episodes listed"

        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center).first)
        XCTAssertTrue(row.countsText.hasPrefix(size), row.countsText)
        XCTAssertTrue(row.label.hasPrefix("The Tactile Atlas, Feed, \(size)"), row.label)
        let summary = world.center.folderSummary(of: feed.id, now: Date())
        XCTAssertTrue(summary.counts.hasPrefix(size), summary.counts)
        let path = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        let entering = FolderNavigationHistory.announcement(for: path, library: world.library.library, feedFolders: LibraryFeedFolders(center: world.center))
        XCTAssertTrue(entering.hasPrefix("The Tactile Atlas, Feed, \(size)"), entering)
        let facts = try XCTUnwrap(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: Date()))
        XCTAssertTrue(LibraryInfoWording.brief(.feed(facts)).hasPrefix("The Tactile Atlas. Feed. \(size)"), LibraryInfoWording.brief(.feed(facts)))
        XCTAssertEqual(FeedWording.subscribed(title: feed.title, counts: counts), "Subscribed to The Tactile Atlas: \(size).")

        // A record from before TextMouth recorded the size counts as it did.
        world.center.store.update(feed.id) { $0.feed.entryTotal = nil }
        XCTAssertEqual(FeedWording.sizePhrase(world.center.counts(of: feed.id)), "10 episodes")

        // Listing every item: the next check reads the feed whole, and
        // every entry is listed.
        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 10), of: feed.id)
        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(world.center.counts(of: feed.id).total, FeedEntryTotal(count: 12))
        XCTAssertEqual(FeedWording.sizePhrase(world.center.counts(of: feed.id)), "12 episodes")

        // Fewer entries than the short list counts, and one entry.
        let three = try await subscribe(world, title: "Three Rooms", path: "/three.xml", into: world.folder.path, items: Array(episodes.prefix(3)))
        XCTAssertEqual(FeedWording.sizePhrase(world.center.counts(of: three.id)), "3 episodes")
        let one = try await subscribe(world, title: "One Room", path: "/one.xml", into: world.folder.path)
        XCTAssertEqual(FeedWording.sizePhrase(world.center.counts(of: one.id)), "1 episode")

        // Articles: entries offering no audio or video.
        let notes = (1...12).map { number in
            FeedXML.Item(guid: "note-\(number)", title: "Note \(number)", published: world.day(-Double(number)), description: "<p>Words.</p>")
        }
        world.server.serve("/notes.xml", .feed(FeedXML.rss(title: "Harbour Notes", items: notes)))
        let outcome = try await world.center.subscribe(to: world.server.url("/notes.xml").absoluteString, into: .newFolder(inParentPath: world.folder.path))
        guard case .subscribed(let articles) = outcome else { return XCTFail("subscribing ended with \(outcome)") }
        XCTAssertEqual(FeedWording.sizePhrase(world.center.counts(of: articles.id)), "10 of 12 articles listed")
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
    /// in one sentence, the most telling words first, for each state: why a
    /// download failed, or why the newest-N rule's download waits (FR11),
    /// right after the state.
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
            return FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200).label
        }

        XCTAssertEqual(try label(), "How tides are measured, Not Downloaded, New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) {
            $0.state = .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 40, totalBytes: 100))
        }
        XCTAssertEqual(try label(), "How tides are measured, Downloading, 40 percent, New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .failed("The server says the file is gone.") }
        XCTAssertEqual(try label(), "How tides are measured, Download Failed, The server says the file is gone., New, \(date), 28 minutes, 3 seconds")

        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .waiting(FeedDownloadWait.network.reason) }
        XCTAssertEqual(
            try label(),
            "How tides are measured, Waiting to Download, it downloads on a network without data limits, New, \(date), 28 minutes, 3 seconds"
        )
        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .waiting(FeedDownloadWait.room(bytes: 61_000_000).reason) }
        XCTAssertEqual(
            try label(),
            "How tides are measured, Waiting to Download, it needs room for 61 MB on this Mac, New, \(date), 28 minutes, 3 seconds"
        )

        world.center.store.updateItem(itemID, of: feed.id) {
            $0.state = .notDownloaded
            $0.playedDate = world.day(1)
        }
        XCTAssertEqual(try label(), "How tides are measured, Played, Not Downloaded, \(date), 28 minutes, 3 seconds")
        XCTAssertEqual(FeedWording.playedNote(isArticle: true), "Read")
        XCTAssertEqual(FeedWording.itemRowHint(.notDownloaded), "Downloads it, then opens it")
        XCTAssertEqual(FeedWording.itemRowHint(.downloaded(bookID: UUID())), "Opens it")
        XCTAssertEqual(FeedWording.itemRowHint(.notDownloaded, keptPlace: true), "Downloads it again, then opens it where you left off")
        XCTAssertEqual(FeedWording.itemRowHint(.waiting(FeedDownloadWait.network.reason)), "Downloads it, then opens it")
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

        let all = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: [episode, other], folderBooks: [episode, other], search: "", wordsPerMinute: 200
        )
        XCTAssertEqual(all.entries.map(\.id), ["item:guid:ep-3", "book:\(episode.id.uuidString)", "item:guid:ep-1"])
        XCTAssertEqual(all.otherBooks, [other])
        XCTAssertEqual(all.noun, .episode)
        XCTAssertEqual(all.total, FeedEntryTotal(count: 3))
        XCTAssertEqual(FeedWording.sectionTitle(all.noun, count: all.entries.count, total: all.total), "Episodes (3)")
        XCTAssertEqual(FeedWording.otherBooksTitle(count: 1), "Books (1)")

        // The search narrows items and books alike.
        let searched = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [episode, other], search: "MAP", wordsPerMinute: 200
        )
        XCTAssertEqual(searched.entries.map(\.id), ["item:guid:ep-3"])
        XCTAssertEqual(searched.otherBooks, [])
        XCTAssertNil(searched.total, "a search's rows are not the entries listed")

        // An episode whose book lives in another folder stays an item,
        // downloaded.
        let elsewhere = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: [other], folderBooks: [other], search: "", wordsPerMinute: 200
        )
        guard case .item(let moved)? = elsewhere.entries.dropFirst().first else { return XCTFail("\(elsewhere.entries)") }
        XCTAssertEqual(moved.state, .downloaded(bookID: episode.id))
        XCTAssertEqual(moved.state.visibleNote, "Downloaded")
    }

    // MARK: - Folders, the Rotor, the Bar, and Entering

    /// A feed's folder says "Feed" after its name, in its row and in the
    /// Folders rotor, which share one label, and counts the feed's items as
    /// the feed's row does, never its downloads as books; any other folder
    /// counts its books, and a folder of one book is "1 book" in both.
    func testAFeedsFolderSaysFeedAfterItsNameAndCountsItsItems() {
        let counts = FeedItemCounts(listed: 10, total: FeedEntryTotal(count: 381), downloaded: 3, noun: .episode)
        XCTAssertEqual(
            FolderRow.accessibilityLabel(name: "Planet Money", bookCount: 3, feedCounts: counts),
            "Planet Money, Feed, 10 of 381 episodes listed, 3 downloaded"
        )
        XCTAssertEqual(FolderRow.countText(bookCount: 3, feedCounts: counts), "10 of 381 episodes listed, 3 downloaded")
        XCTAssertEqual(
            FolderRow.accessibilityLabel(name: "Harbour Notes", bookCount: 0, feedCounts: FeedItemCounts(listed: 1, unplayed: 1, noun: .article)),
            "Harbour Notes, Feed, 1 article, 1 unread"
        )
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Poems", bookCount: 1, feedCounts: nil), "Poems, 1 book")
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Fiction", bookCount: 12, feedCounts: nil), "Fiction, 12 books")
        XCTAssertEqual(FolderRow.countText(bookCount: 12, feedCounts: nil), "12 books")
    }

    /// A real feed's folder, holding a downloaded episode's book, reads as
    /// the feed's row counts it, where it read "1 book" before; the label
    /// is the one entering the folder speaks.
    func testAFeedsFolderRowCountsTheFeedsItemsNotItsBooks() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIFolderRowCounts")
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: [
            FeedXML.Item(guid: "ep-2", title: "Second", published: world.day(0.5)),
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(-3)),
        ])
        addBook(titled: "First", to: world, feed: feed, item: "guid:ep-1")
        let folder = try XCTUnwrap(world.library.library.folders.first { $0.id == feed.folderID })
        let label = FolderRow.accessibilityLabel(
            name: folder.name,
            bookCount: world.library.bookCount(inFolderTree: folder.fullPath),
            feedCounts: world.center.counts(of: feed.id)
        )

        XCTAssertEqual(label, "The Tactile Atlas, Feed, 2 episodes, 1 downloaded, 1 new, 2 unplayed")
        XCTAssertFalse(label.contains("book"), label)
        XCTAssertEqual(
            label,
            FolderNavigationHistory.announcement(for: folder.fullPath, library: world.library.library, feedFolders: LibraryFeedFolders(center: world.center))
        )
    }

    // MARK: - One Row for Each Feed

    /// Where the Feeds section lists a feed, the Folders section leaves out
    /// the feed's folder, and the Folders rotor's entry for it moves to the
    /// feed's row, naming the feed as that row does: at the top of the
    /// library, inside a folder, and inside a folder of a folder. A plain
    /// folder holding a feed's folder deeper down keeps its row as it was;
    /// a feed's folder the Feeds section does not list keeps its row,
    /// counting the feed's items; and outside the Folders category there
    /// are no folder rows, and so no rotor entries naming rows the list
    /// lacks.
    func testTheFoldersSectionLeavesOutTheFoldersOfTheFeedsItLists() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOneRow")
        let base = world.folder.path
        let shows = try world.library.createFolderReturningFolder(name: "Shows", parentPath: base)
        let atlas = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        let notes = try await subscribe(world, title: "Harbour Notes", path: "/notes.xml", into: shows.fullPath)
        // A feed whose folder is at the top of the library, removed with
        // its directory when the test ends.
        let wire = try await subscribe(world, title: "Open Wire \(UUID().uuidString.prefix(8))", path: "/wire.xml", into: "")
        let wireFolder = IntegrationLibraryFolder(path: try XCTUnwrap(world.library.feedFolderPath(forFolderID: wire.folderID)))
        addTeardownBlock { wireFolder.remove() }
        let feedFolders = LibraryFeedFolders(center: world.center)
        /// The rows and rotor entries at `path` in `category`, of the
        /// folders directly inside it unless `subfolders` are given.
        func rows(_ path: String, _ category: LibraryCategory = .folders, subfolders: [BookFolder]? = nil) -> LibraryFolderRows {
            feedFolders.folderRows(subfolders ?? world.library.subfoldersOf(path), at: LibraryLocation(category: category, folderPath: path)) {
                world.library.bookCount(inFolderTree: $0.fullPath)
            }
        }
        /// A plain folder's rotor entry, on its own row, naming the feeds
        /// below it beside its books (FR11).
        func folderEntry(_ folder: BookFolder) -> FolderRotorEntry {
            FolderRotorEntry(
                label: FolderRow.accessibilityLabel(
                    name: folder.name,
                    bookCount: world.library.bookCount(inFolderTree: folder.fullPath),
                    feedCounts: nil,
                    feedsBelow: feedFolders.feedCount(below: folder)
                ),
                id: folder.id
            )
        }
        /// A feed's rotor entry, on the feed's row in the Feeds section.
        func feedEntry(_ feed: Feed) -> FolderRotorEntry {
            FolderRotorEntry(label: FeedWording.folderAnnouncement(name: feed.title, counts: world.center.counts(of: feed.id)), id: feed.id)
        }

        // The top: the world's folder keeps its row, though it holds two
        // feeds' folders deeper down; Open Wire's folder is left out.
        let top = rows("")
        XCTAssertEqual(top.shown, [world.bookFolder])
        XCTAssertEqual(top.rotorEntries, [folderEntry(world.bookFolder), feedEntry(wire)])
        XCTAssertEqual(top.rotorEntries.last?.label, "\(wire.title), Feed, 1 episode, 1 unplayed")

        // Inside the world's folder: Shows keeps its row; the Atlas's folder
        // is left out, its entry on the Atlas's row.
        let inside = rows(base)
        XCTAssertEqual(inside.shown, [shows])
        XCTAssertEqual(inside.rotorEntries, [folderEntry(shows), feedEntry(atlas)])
        XCTAssertEqual(inside.rotorEntries.first?.label, "Shows, 1 feed", "a plain folder names the feeds below it")

        // Inside Shows: only the Notes' folder, left out.
        let nested = rows(shows.fullPath)
        XCTAssertEqual(nested.shown, [])
        XCTAssertEqual(nested.rotorEntries, [feedEntry(notes)])

        // Every rotor entry names a row the list shows: a folder's row, or
        // a feed's row in the Feeds section.
        for (path, listed) in [("", top), (base, inside), (shows.fullPath, nested)] {
            let feedRowIDs = Set(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: path), center: world.center).map(\.id))
            let rowIDs = Set(listed.shown.map(\.id)).union(feedRowIDs)
            XCTAssertTrue(listed.rotorEntries.allSatisfy { rowIDs.contains($0.id) }, "a rotor entry at \"\(path)\" names a row the list lacks")
        }

        // Elsewhere no folders are shown, so the rotor offers none.
        for category in [LibraryCategory.allItems, .unopened, .recent] {
            XCTAssertEqual(rows(base, category), LibraryFolderRows(), "\(category)")
        }

        // A feed's folder the Feeds section does not list here keeps its
        // row, counting the feed's items: the Atlas's folder, given as if
        // it were inside Shows, where the section lists only the Notes.
        let atlasFolder = try XCTUnwrap(world.library.library.folders.first { $0.id == atlas.folderID })
        let unlisted = rows(shows.fullPath, subfolders: [atlasFolder])
        XCTAssertEqual(unlisted.shown, [atlasFolder])
        XCTAssertEqual(unlisted.rotorEntries, [FolderRotorEntry(
            label: FolderRow.accessibilityLabel(name: atlasFolder.name, bookCount: 0, feedCounts: world.center.counts(of: atlas.id)),
            id: atlasFolder.id
        )])
        XCTAssertEqual(unlisted.rotorEntries.first?.label, "The Tactile Atlas, Feed, 1 episode, 1 unplayed")
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

    /// The open feed's summary bar and its items' heading say what the
    /// feed's row says. The bar: how many entries are listed of the feed's
    /// size, then the downloads, the new and the unplayed items, and the
    /// last check, spoken in one sentence of the words it shows. The
    /// heading: its rows counted with the feed's size while they are every
    /// entry listed, and its rows alone while a search narrows them.
    func testTheOpenFeedsSummaryAndHeadingSayWhatItsRowSays() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIOpenFeed")
        // A short list of the newest 10 (FR11's "Only the newest 5 listed",
        // with 10 for its number).
        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        FeedSettings.newestCountPreference.write(10, to: world.preferences)
        let episodes = (1...12).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)))
        }
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: world.folder.path, items: episodes)
        let book = addBook(titled: "Episode 2", to: world, feed: feed, item: "guid:ep-2")
        // Played, and still downloaded, so it stays on the short list.
        world.center.markPlayed("guid:ep-2", of: feed.id)
        let now = Date()
        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center, now: now).first)
        XCTAssertEqual(row.countsText, "10 of 12 episodes listed, 1 downloaded, 9 unplayed")

        // The summary bar.
        let summary = world.center.folderSummary(of: feed.id, now: now)
        XCTAssertEqual(summary.counts, row.countsText)
        XCTAssertEqual(summary.check, row.check)
        let bar = TimeRemainingBar(books: [], wpm: 200, feedSummary: summary)
        XCTAssertEqual(bar.summaryAccessibilityLabel, "10 of 12 episodes listed, 1 downloaded, 9 unplayed. \(row.check.visible)")

        // The heading, over every entry listed, and over a search's.
        let listing = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: [book], folderBooks: [book], search: "", wordsPerMinute: 200
        )
        XCTAssertEqual(listing.entries.count, 10)
        XCTAssertEqual(FeedWording.sectionTitle(listing.noun, count: listing.entries.count, total: listing.total), "Episodes (10 of 12 listed)")
        let searched = FeedFolderListing.make(
            feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [book], search: "Episode 1", wordsPerMinute: 200
        )
        XCTAssertEqual(searched.entries.map(\.id), ["item:guid:ep-1", "item:guid:ep-10"])
        XCTAssertEqual(FeedWording.sectionTitle(searched.noun, count: searched.entries.count, total: searched.total), "Episodes (2)")

        // Every form of the heading, and of the unplayed count.
        XCTAssertEqual(FeedWording.sectionTitle(.episode, count: 12), "Episodes (12)")
        XCTAssertEqual(FeedWording.sectionTitle(.episode, count: 1, total: FeedEntryTotal(count: 1)), "Episodes (1)")
        XCTAssertEqual(FeedWording.sectionTitle(.episode, count: 10, total: FeedEntryTotal(count: 381)), "Episodes (10 of 381 listed)")
        XCTAssertEqual(FeedWording.sectionTitle(.article, count: 10, total: FeedEntryTotal(count: 381)), "Articles (10 of 381 listed)")
        XCTAssertEqual(FeedWording.sectionTitle(.item, count: 3, total: FeedEntryTotal(count: 2)), "Items (3)")
        XCTAssertEqual(
            FeedWording.sectionTitle(.episode, count: 10, total: FeedEntryTotal(count: 2_000, listsMore: true)),
            "Episodes (10 of more than 2000 listed)"
        )
        XCTAssertEqual(FeedWording.countsPhrase(FeedItemCounts(listed: 2, unplayed: 1, noun: .article)), "2 articles, 1 unread")
        XCTAssertEqual(FeedWording.countsPhrase(FeedItemCounts(listed: 3, unplayed: 3, noun: .item)), "3 items, 3 unplayed")
        XCTAssertEqual(FeedWording.countsPhrase(FeedItemCounts(listed: 3, noun: .episode)), "3 episodes", "nothing unplayed is said")
    }

    /// Entering a feed's folder says its name, "Feed", and the feed's items
    /// counted; any other folder says its books and the feeds below it, as
    /// the Feeds section lists them there (FR11).
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
            "The Tactile Atlas, Feed, 2 episodes, 1 new, 2 unplayed"
        )
        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library, feedFolders: folders),
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library, feedCount: 1)
        )
        XCTAssertEqual(
            FolderNavigationHistory.announcement(for: world.folder.path, library: world.library.library, feedFolders: folders),
            "\(world.folder.path), 1 feed"
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
