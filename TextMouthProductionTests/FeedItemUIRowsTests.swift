import XCTest
@testable import TextMouth

/// A feed's item rows (FR11, branch C): an item whose package kept the
/// listener's place after its file went says how far it got, the time
/// left, and its bookmarks, in its book row's own words, and hints that it
/// opens where it was left; a played one says only its bookmarks; an item
/// whose download the newest-N rule put off says why it waits, and offers
/// Cancel Download, which says it waits no more. Each row shows the words
/// it speaks.
@MainActor
final class FeedItemUIRowsTests: XCTestCase {

    // MARK: - A Kept Record's Place

    /// An episode whose download went with its place kept says, after "Not
    /// Downloaded", its progress, the time left, and its bookmarks, the
    /// screen showing the same ("50%", "16:00 left", "2 bookmarks"), and its
    /// hint says it opens where it was left. Waiting, it says why first;
    /// downloading again, its progress is "read", beside the download's own
    /// percentage; played, it says its bookmarks alone; and a kept record
    /// without a place says no progress. A feed's folder lists the row so.
    func testAKeptRecordsRowSaysItsPlaceAndBookmarks() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIKeptRow")
        let feed = try await subscribe(world, items: [
            FeedXML.Item(guid: "ep-368", title: "Ep. 368", published: world.day(-2), enclosure: "https://atlas.example/368.mp3"),
        ])
        let itemID = "guid:ep-368"
        world.center.store.updateItem(itemID, of: feed.id) { $0.duration = 1_920 }
        var kept = Self.keptRow(of: feed.id, item: itemID)
        kept.audioDuration = 1_920
        kept.totalCharacterCount = 1_000
        kept.readingPosition = ReadingPosition(characterOffset: 500, globalCharacterOffset: 500)
        kept.lastOpened = world.clock.value
        kept.bookmarks = [
            Bookmark(number: 1, chapterIndex: 0, characterOffset: 100),
            Bookmark(number: 2, chapterIndex: 0, characterOffset: 300),
        ]
        world.library.library.feedShelf.put(kept)
        let date = FeedWording.itemDate(world.day(-2))
        func row() throws -> FeedItemRowContent {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            return FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)
        }

        let unplayed = try row()
        XCTAssertEqual(unplayed.label, "Ep. 368, Not Downloaded, 50 percent, 16 minutes remaining, 2 bookmarks, \(date), 32 minutes")
        XCTAssertEqual(unplayed.kept?.shownParts, ["50%", "16:00 left", "2 bookmarks"])
        XCTAssertEqual(FeedWording.itemRowHint(unplayed.state, keptPlace: unplayed.kept?.hasPlace ?? false), "Downloads it again, then opens it where you left off")
        let listing = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [], search: "", wordsPerMinute: 200)
        XCTAssertEqual(listing.entries, [.item(unplayed)], "the feed's folder lists another row")

        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .waiting(FeedDownloadWait.network.reason) }
        XCTAssertEqual(
            try row().label,
            "Ep. 368, Waiting to Download, it downloads on a network without data limits, 50 percent, 16 minutes remaining, 2 bookmarks, \(date), 32 minutes"
        )

        // The download's own percent is the feed downloads section's
        // (FR10); the kept place says "read", so it is never taken for it.
        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .downloading }
        XCTAssertEqual(
            try row().label,
            "Ep. 368, Downloading, 50 percent read, 16 minutes remaining, 2 bookmarks, \(date), 32 minutes",
            "a kept place beside Downloading was not said as read"
        )

        world.center.store.updateItem(itemID, of: feed.id) { $0.state = .notDownloaded }
        world.center.markPlayed(itemID, of: feed.id)
        let played = try row()
        XCTAssertEqual(played.label, "Ep. 368, Played, Not Downloaded, 2 bookmarks, \(date), 32 minutes")
        XCTAssertEqual(played.kept?.shownParts, ["2 bookmarks"])
        XCTAssertEqual(FeedWording.itemRowHint(played.state, keptPlace: played.kept?.hasPlace ?? false), "Downloads it, then opens it")

        // A record kept for its bookmark alone, with no place.
        world.center.markUnplayed(itemID, of: feed.id)
        kept.readingPosition = nil
        kept.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 100)]
        world.library.library.feedShelf.put(kept)
        let unplaced = try row()
        XCTAssertEqual(unplaced.label, "Ep. 368, Not Downloaded, 1 bookmark, \(date), 32 minutes")
        XCTAssertEqual(unplaced.kept?.hasPlace, false)
    }

    /// An article's time left after its kept place is estimated at the
    /// library's reading speed, as its book's row estimated it.
    func testAKeptArticlesTimeLeftFollowsTheReadingSpeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIKeptArticle")
        let feed = try await subscribe(world, items: [
            FeedXML.Item(guid: "note-1", title: "Harbour lights", published: world.day(-2), description: "<p>Which lamps are lit.</p>"),
        ])
        let itemID = "guid:note-1"
        var kept = Self.keptRow(of: feed.id, item: itemID, format: .html)
        kept.totalWordCount = 1_000
        kept.totalCharacterCount = 5_000
        kept.readingPosition = ReadingPosition(characterOffset: 2_500, globalCharacterOffset: 2_500)
        kept.lastOpened = world.clock.value
        world.library.library.feedShelf.put(kept)
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
        let date = FeedWording.itemDate(world.day(-2))

        XCTAssertEqual(
            FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200).label,
            "Harbour lights, Not Downloaded, 50 percent, 2 minutes, 30 seconds remaining, \(date)"
        )
        XCTAssertEqual(
            FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 100).label,
            "Harbour lights, Not Downloaded, 50 percent, 5 minutes remaining, \(date)"
        )
    }

    /// The time left reads as a book row reads it, on screen and aloud, so
    /// an episode says the same before and after its file goes.
    func testTheTimeLeftIsTheBookRowsOwnWords() {
        XCTAssertEqual(BookRow.remainingText(960).visible, "16:00 left")
        XCTAssertEqual(BookRow.remainingText(960).spoken, "16 minutes remaining")
        XCTAssertEqual(BookRow.remainingText(3_725).spoken, "1 hour, 2 minutes, 5 seconds remaining")
        XCTAssertEqual(CountWording.bookmarks(1), "1 bookmark")
        XCTAssertEqual(CountWording.bookmarks(2), "2 bookmarks")
    }

    // MARK: - Waiting to Download

    /// An item whose download the newest-N rule put off offers Download and
    /// Cancel Download; Cancel Download takes the wait back, leaving the
    /// item not downloaded and the listener's, so the rule never downloads
    /// it by itself again, and VoiceOver hears that it waits no more. A
    /// download under way still says it stopped.
    func testAWaitingItemOffersCancelDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIWaiting")
        let feed = try await subscribe(world, items: [
            FeedXML.Item(guid: "ep-1", title: "A crossing at dusk", published: world.day(-2), enclosure: "https://atlas.example/1.mp3"),
        ])
        let itemID = "guid:ep-1"
        world.center.store.updateItem(itemID, of: feed.id) {
            $0.state = .waiting(FeedDownloadWait.room(bytes: 61_000_000).reason)
            $0.downloadOrigin = .window
        }
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
        let content = FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200)
        let actions = FeedItemAction.actions(for: content)
        XCTAssertEqual(actions.map(\.title), [
            "Open", "Download", "Cancel Download", "Mark Played", "Show Description…", "Delete Episode…",
        ])

        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let cancel = try XCTUnwrap(actions.first { $0.command == .cancelDownload })
        presenter.perform(cancel, in: FeedCommandContext(center: world.center, library: world.library, window: nil))

        let after = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
        XCTAssertEqual(after.state, .notDownloaded)
        XCTAssertEqual(after.downloadOrigin, .listener, "the rule may download it by itself again")
        XCTAssertEqual(heard, ["“A crossing at dusk” no longer waits to download; it downloads when you choose Download."])
        XCTAssertEqual(FeedWording.downloadCancelled(title: "A crossing at dusk"), "Stopped downloading “A crossing at dusk”.")
        XCTAssertEqual(
            FeedItemAction.actions(feedID: feed.id, itemID: itemID, itemTitle: item.title, state: .notDownloaded, isPlayed: false, isArticle: false)
                .map(\.command),
            [.open, .download, .markPlayed, .showDescription, .deleteItem],
            "an item neither waiting nor downloading offered Cancel Download"
        )
    }

    // MARK: - Delete Download

    /// Delete Download's words name only what the kept package holds, each
    /// with its verb: one part, several, or none, which says only that it
    /// can be downloaded again (feed review item 18).
    func testDeleteDownloadNamesOnlyWhatItKept() {
        let deleted = "Deleted the download of “Ep. 368”."
        XCTAssertEqual(FeedWording.downloadDeleted(title: "Ep. 368"), "\(deleted) It can be downloaded again.")
        XCTAssertEqual(
            FeedWording.downloadDeleted(title: "Ep. 368", kept: [.transcript]),
            "\(deleted) Its transcript is kept for when you download it again."
        )
        XCTAssertEqual(
            FeedWording.downloadDeleted(title: "Ep. 368", kept: [.bookmarks]),
            "\(deleted) Its bookmarks are kept for when you download it again."
        )
        XCTAssertEqual(
            FeedWording.downloadDeleted(title: "Ep. 368", kept: [.place, .bookmarks, .settings, .transcript]),
            "\(deleted) Its place, bookmarks, own settings, and transcript are kept for when you download it again."
        )
    }

    /// Delete Download of an episode the listener opened says what is kept
    /// of it for when it is downloaded again, its place and bookmarks, and
    /// its row then says the place it kept; a download never opened says it
    /// can be downloaded again.
    func testDeleteDownloadSaysWhatItKept() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIDeleteDownload")
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, items: [1, 2].map { number in
            FeedXML.Item(
                guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4"
            )
        })
        world.center.download("guid:ep-1", of: feed.id)
        let opened = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        world.center.download("guid:ep-2", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        world.library.persistReadingPosition(bookID: opened.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 1))
        world.library.addBookmark(bookID: opened.id, chapterIndex: 0, characterOffset: 1, label: "Here")

        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        @MainActor func deleteDownload(_ itemID: FeedItem.ID) throws {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            let action = try XCTUnwrap(FeedItemAction.actions(
                feedID: feed.id, itemID: itemID, itemTitle: item.title, state: world.center.state(of: item, in: feed.id),
                isPlayed: false, isArticle: false, onBookRow: true
            ).first { $0.command == .deleteDownload })
            presenter.perform(action, in: context)
        }

        try deleteDownload("guid:ep-1")
        // Only what the kept package holds is named: here no transcript
        // (feed review item 18).
        XCTAssertEqual(
            heard.last,
            "Deleted the download of “Episode 1”. Its place and bookmarks are kept for when you download it again."
        )
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(FeedItemRowContent(item, of: feed, in: world.center, wordsPerMinute: 200).kept?.bookmarkCount, 1)

        try deleteDownload("guid:ep-2")
        XCTAssertEqual(heard.last, "Deleted the download of “Episode 2”. It can be downloaded again.")
    }

    // MARK: - Helpers

    /// Starts `world`'s engine and subscribes it to "The Tactile Atlas",
    /// served with `items`.
    private func subscribe(_ world: FeedTestWorld, items: [FeedXML.Item]) async throws -> Feed {
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: items)))
        return try await world.subscribe("/atlas.xml")
    }

    /// The row of the item `itemID` of the feed `feedID` as its feed's shelf
    /// keeps it after its file went (FR11, branch A2), as `format`.
    private static func keptRow(of feedID: UUID, item itemID: String, format: BookFormat = .audio) -> Book {
        Book(
            title: "Kept",
            format: format,
            filePath: format == .audio ? "/Kept.m4a" : "/Kept.html",
            md5Hash: "",
            tmbDirectoryName: "Kept.tmb",
            feedLink: FeedBookLink(feedID: feedID, itemID: itemID)
        )
    }
}
