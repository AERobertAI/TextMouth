import XCTest
@testable import TextMouth

/// The newest-N rule of the "List and download" choice (FR11, branch B), and
/// what it needs: each download knowing who asked for it, so the rule
/// manages its own downloads alone. No test reaches the network: every
/// request goes to the world's stub server.
@MainActor
final class FeedNewestRuleTests: XCTestCase {

    // MARK: - Who Asked for a Download

    /// A download records who asked for it: the listener's as the listener's,
    /// over any network; the rule's as the rule's, as discretionary work; and
    /// the listener asking while the rule's download runs makes it the
    /// listener's. Opening an episode the rule downloaded leaves it the
    /// rule's: started and not finished, it may still go once older.
    func testADownloadRecordsWhoAskedForIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOrigin")
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/3.m4a", slow)
        let feed = try await subscribe(world, episodes: 3)

        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(origin(of: "guid:ep-1", in: feed, world), .listener)
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a").map(\.allowsExpensiveNetworkAccess), [true])

        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        let ruleBook = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        XCTAssertEqual(origin(of: "guid:ep-2", in: feed, world), .window)
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a").map(\.allowsExpensiveNetworkAccess), [false])
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }
        world.center.open("guid:ep-2", of: feed.id)
        XCTAssertEqual(opened, [ruleBook.id])
        XCTAssertEqual(origin(of: "guid:ep-2", in: feed, world), .window, "opening a download made it the listener's")

        world.center.downloads.download("guid:ep-3", of: feed.id, origin: .window)
        await waitFor("the rule's download is under way") { !world.server.requests(to: "/audio/3.m4a").isEmpty }
        world.center.download("guid:ep-3", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-3")
        XCTAssertEqual(origin(of: "guid:ep-3", in: feed, world), .listener)
    }

    /// Deleting a download, or stopping one, leaves the item to the
    /// listener, so the rule never asks for it again by itself: Delete
    /// Download of a download the rule made, Cancel Download of one the rule
    /// queued, and of one under way.
    func testDeletingOrStoppingADownloadLeavesTheItemToTheListener() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOriginDeclined")
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.1
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", slow)
        world.server.serve("/audio/3.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, episodes: 3)

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        let deleted = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(deleted.state, .notDownloaded)
        XCTAssertEqual(deleted.downloadDeletedDate, world.clock.value)
        XCTAssertEqual(deleted.downloadOrigin, .listener)

        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        world.center.downloads.download("guid:ep-3", of: feed.id, origin: .window)
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/2.m4a").isEmpty }
        world.center.cancelDownload("guid:ep-3", of: feed.id)
        world.center.cancelDownload("guid:ep-2", of: feed.id)
        await waitFor("the download under way stops") { world.center.downloads.current == nil }

        for itemID in ["guid:ep-2", "guid:ep-3"] {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            XCTAssertEqual(item.state, .notDownloaded, itemID)
            XCTAssertEqual(item.downloadOrigin, .listener, itemID)
        }
        XCTAssertEqual(world.server.requests(to: "/audio/3.m4a"), [], "a stopped download was fetched")
    }

    /// A download the listener asked for that fails is the listener's, to
    /// try again by hand; one the rule asked for that fails stays the
    /// rule's.
    func testAFailedDownloadKeepsWhoAskedForIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOriginFailed")
        world.server.serve("/audio/1.m4a", StubResponse(status: 404))
        world.server.serve("/audio/2.m4a", StubResponse(status: 404))
        let feed = try await subscribe(world, episodes: 2)

        world.center.download("guid:ep-1", of: feed.id)
        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        await waitFor("both downloads fail") {
            let items = world.center.store.record(of: feed.id)?.items ?? []
            return items.allSatisfy { $0.state.failureReason != nil } && world.center.downloads.current == nil
        }

        let listeners = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(listeners.state, .failed("The server says the file is gone."))
        XCTAssertEqual(listeners.downloadOrigin, .listener)
        XCTAssertNil(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.downloadOrigin)
    }

    /// Who asked is read without ever making a record unreadable: a name
    /// this version does not know, or a value that is no name, reads as the
    /// listener's, whose downloads the rule leaves alone, and none as no one
    /// asked; it is written only when someone did. The list of downloads at
    /// quit that a version before FR11 wrote names a download that started
    /// by itself "automatic", which reads as the rule's.
    func testWhoAskedIsReadWithoutFail() throws {
        let cases: [(json: String, expected: FeedDownloadOrigin?)] = [
            (#""window""#, .window),
            (#""listener""#, .listener),
            (#""someoneLater""#, .listener),
            ("5", .listener),
            ("null", nil),
        ]
        for (json, expected) in cases {
            let item = #"{"id": "guid:a", "title": "A", "firstSeen": "2026-10-03T00:00:00Z", "state": {"kind": "notDownloaded"}, "downloadOrigin": \#(json)}"#
            let read = try FeedRecordCoding.decoder().decode(FeedItem.self, from: Data(item.utf8))
            XCTAssertEqual(read.downloadOrigin, expected, json)
        }
        let none = #"{"id": "guid:a", "title": "A", "firstSeen": "2026-10-03T00:00:00Z", "state": {"kind": "notDownloaded"}}"#
        let unasked = try FeedRecordCoding.decoder().decode(FeedItem.self, from: Data(none.utf8))
        XCTAssertNil(unasked.downloadOrigin)
        XCTAssertFalse(String(decoding: try FeedRecordCoding.encoder().encode(unasked), as: UTF8.self).contains("downloadOrigin"))
        var asked = unasked
        asked.downloadOrigin = .window
        XCTAssertTrue(String(decoding: try FeedRecordCoding.encoder().encode(asked), as: UTF8.self).contains(#""downloadOrigin" : "window""#))

        let feedID = UUID()
        let list = #"[{"feedID": "\#(feedID.uuidString)", "itemID": "guid:a", "origin": "automatic"}, {"feedID": "\#(feedID.uuidString)", "itemID": "guid:b", "origin": "listener"}]"#
        let saved = try JSONDecoder().decode([FeedDownloadManager.SavedDownload].self, from: Data(list.utf8))
        XCTAssertEqual(saved.map(\.origin), [.window, .listener])
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed of `episodes` audio episodes, "guid:ep-1"
    /// the newest, each at /audio/<number>.m4a, published before the
    /// subscription.
    private func subscribe(_ world: FeedTestWorld, episodes: Int) async throws -> Feed {
        let items = (1...episodes).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }

    /// Who asked for the item `itemID` of `feed`'s download, as its record
    /// says now.
    private func origin(of itemID: FeedItem.ID, in feed: Feed, _ world: FeedTestWorld) -> FeedDownloadOrigin? {
        world.center.store.record(of: feed.id)?.item(itemID)?.downloadOrigin
    }
}
