import XCTest
@testable import TextMouth

/// The "List and download" choice (FR11, branch B): what each of its three
/// answers lists and downloads by itself, its one number always within the
/// setting's range, and a feed's own choice in its record, read without
/// ever making the record unreadable.
@MainActor
final class FeedItemPolicyTests: XCTestCase {

    // MARK: - The Three Answers

    /// Each answer is what it lists and what downloads by itself: every item
    /// listed with the newest downloaded; every item listed with downloads by
    /// hand; only the newest listed, with downloads by hand. The number
    /// counts for the first and third only, and the record keeps every
    /// entry under the first two.
    func testEachAnswerIsWhatItListsAndWhatDownloadsByItself() {
        let newest = FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 5)
        XCTAssertEqual(newest.listing, .every)
        XCTAssertEqual(newest.downloading, .newest(5))
        XCTAssertEqual(newest.listing.keptEntries, -1)

        let byHand = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5)
        XCTAssertEqual(byHand.listing, .every)
        XCTAssertEqual(byHand.downloading, .byHand)

        let short = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 7)
        XCTAssertEqual(short.listing, .newest(7))
        XCTAssertEqual(short.downloading, .byHand, "the short list downloads by hand (question 3)")
        XCTAssertEqual(short.listing.keptEntries, 7)

        XCTAssertEqual(FeedItemPolicy.standard, newest)
        XCTAssertEqual(
            FeedItemPolicy.Choice.allCases.map(\.rawValue),
            ["everyListedNewestDownloaded", "everyListedDownloadsByHand", "onlyNewestListed"]
        )
    }

    /// The number is always one the setting allows, given or set: below 1 it
    /// is 1, above 2,000 it is 2,000.
    func testTheNumberIsAlwaysInRange() {
        XCTAssertEqual(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 0).newestCount, 1)
        XCTAssertEqual(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 9_999).newestCount, 2_000)

        var policy = FeedItemPolicy.standard
        policy.newestCount = -3
        XCTAssertEqual(policy.newestCount, 1)
        XCTAssertEqual(policy.downloading, .newest(1))
        policy.newestCount = 2_500
        XCTAssertEqual(policy.newestCount, 2_000)
        policy.newestCount = 12
        XCTAssertEqual(policy.newestCount, 12)
    }

    // MARK: - A Feed's Own Choice in Its Record

    /// A feed's own choice is written in its record under the names
    /// config.json gives the global setting's fields, and read back as it
    /// was.
    func testAFeedsOwnChoiceIsWrittenAndReadBack() throws {
        var record = try Self.record()
        record.feed.itemPolicyOverride = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 12)

        let data = try FeedRecordCoding.encoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let feed = try XCTUnwrap(object["feed"] as? [String: Any])
        let written = try XCTUnwrap(feed["itemPolicyOverride"] as? [String: Any])
        XCTAssertEqual(written["items"] as? String, "onlyNewestListed")
        XCTAssertEqual(written["newestCount"] as? Int, 12)

        let read = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data)
        XCTAssertEqual(read, record)
    }

    /// A record written before the choice existed, with no choice of its
    /// own, loads following the global setting, and is written back without
    /// the key, byte for byte as it was.
    func testARecordWithoutAChoiceOfItsOwnIsUnchanged() throws {
        let record = try Self.record()
        let data = try FeedRecordCoding.encoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("itemPolicyOverride"))

        let read = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data)
        XCTAssertNil(read.feed.itemPolicyOverride)
        XCTAssertEqual(try FeedRecordCoding.encoder().encode(read), data)
    }

    /// A feed's own choice that a later version, or a hand, wrote oddly never
    /// makes its record unreadable: a choice this version does not know, or
    /// none, reads as the default; a number out of range is moved into it,
    /// and one missing or not whole reads as 5; a choice that is no object at
    /// all reads as the default policy.
    func testAnOddChoiceNeverMakesTheRecordUnreadable() throws {
        let cases: [(json: String, expected: FeedItemPolicy)] = [
            (#"{"items": "listEverythingTwice", "newestCount": 3}"#, FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 3)),
            (#"{"newestCount": 9999}"#, FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 2_000)),
            (#"{"items": "onlyNewestListed"}"#, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 5)),
            (#"{"items": "onlyNewestListed", "newestCount": 2.5}"#, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 5)),
            (#"{"items": 7, "newestCount": "many"}"#, .standard),
            (#""onlyNewestListed""#, .standard),
            ("[1, 2]", .standard),
        ]
        let data = try FeedRecordCoding.encoder().encode(try Self.record())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var feed = try XCTUnwrap(object["feed"] as? [String: Any])
        for (json, expected) in cases {
            feed["itemPolicyOverride"] = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            object["feed"] = feed
            let edited = try JSONSerialization.data(withJSONObject: object)
            let read = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: edited)
            XCTAssertEqual(read.feed.itemPolicyOverride, expected, json)
            XCTAssertEqual(read.items.count, 1, json)
        }
    }

    /// The engine gives a feed its own choice, which its record keeps on
    /// disk, and takes it away again, the feed then following the global
    /// setting.
    func testTheEngineGivesAFeedItsOwnChoice() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemPolicyOwn")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A", published: world.day(-1))])))
        let feed = try await world.subscribe("/feed.xml")
        let own = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 3)

        world.center.setItemPolicy(own, of: feed.id)
        await world.center.store.flush()

        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.itemPolicyOverride, own)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.itemPolicy(under: world.center.settings), own)
        let file = FeedPaths.recordFile(of: feed.id, in: world.recordsFolder)
        let onDisk = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk.feed.itemPolicyOverride, own)

        world.center.setItemPolicy(nil, of: feed.id)
        XCTAssertNil(world.center.store.record(of: feed.id)?.feed.itemPolicyOverride)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.itemPolicy(under: world.center.settings), .standard)
    }

    // MARK: - The Short List

    /// "Only the newest 5 listed" lists the newest, counting played items
    /// and never deleted ones, less those played whose files are not here,
    /// whose places no older item takes; and every item whose file is here,
    /// or that downloads, wherever it falls. Listing every item lists every
    /// one not deleted.
    func testTheShortListListsTheNewestLessThePlayedWithoutTheirFiles() throws {
        let played = Date(timeIntervalSince1970: 1_791_000_000)
        var items = (1...8).map { number in
            FeedItem(id: "guid:\(number)", title: "Item \(number)", firstSeen: played)
        }
        items[1].deletedDate = played
        items[2].playedDate = played
        items[3].playedDate = played
        items[6].state = .downloading
        let record = FeedRecord(feed: try Self.record().feed, items: items)
        let withFiles: Set<FeedItem.ID> = ["guid:4", "guid:6"]

        // The newest 4: items 1, 3, 4, and 5, item 2 deleted. Item 3 played
        // without its file drops off; item 4, played, keeps its file; item 5
        // is listed; and items 6 and 7, outside, have a file or download.
        let short = record.listedItems(under: .newest(4)) { withFiles.contains($0.id) }
        XCTAssertEqual(short.map(\.id), ["guid:1", "guid:4", "guid:5", "guid:6", "guid:7"])
        XCTAssertEqual(record.newestItems(4).map(\.id), ["guid:1", "guid:3", "guid:4", "guid:5"])

        let every = record.listedItems(under: .every) { _ in false }
        XCTAssertEqual(every.map(\.id), ["guid:1", "guid:3", "guid:4", "guid:5", "guid:6", "guid:7", "guid:8"])
    }

    /// Under the short list, a played episode drops off the list and the
    /// counts, its record kept, and no older one takes its place; a larger
    /// number lists more once the next check reads the feed whole, the
    /// played one still left off; and listing every item brings every
    /// entry back, the played one among them.
    func testTheShortListDropsPlayedItemsAndWidens() async throws {
        let world = try FeedTestWorld(self, label: "FeedPolicyShortList")
        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let items = (1...6).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)))
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        /// The titles the library lists.
        func listed() -> [String] {
            world.center.listedItems(of: feed.id).map(\.title)
        }
        XCTAssertEqual(listed(), ["Episode 1", "Episode 2", "Episode 3"])

        world.center.markPlayed("guid:ep-1", of: feed.id)
        XCTAssertEqual(listed(), ["Episode 2", "Episode 3"], "an older episode took the played one's place")
        XCTAssertEqual(world.center.counts(of: feed.id).listed, 2)
        XCTAssertEqual(world.center.counts(of: feed.id).unplayed, 2)
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate, "the played episode's record went")

        FeedSettings.newestCountPreference.write(5, to: world.preferences)
        XCTAssertEqual(listed(), ["Episode 2", "Episode 3"], "items the record let go came back before the feed was read")
        let wider = try await unwrap(world.center.refresh(feed.id))
        XCTAssertEqual(wider.outcome, .updated(newItemIDs: []), "the unchanged feed was not read again")
        XCTAssertEqual(listed(), ["Episode 2", "Episode 3", "Episode 4", "Episode 5"])

        FeedSettings.itemsPreference.write(.everyListedNewestDownloaded, to: world.preferences)
        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(listed(), (1...6).map { "Episode \($0)" })
    }

    // MARK: - The Move From the Settings Before the Choice

    /// The settings before the choice become it: left as TextMouth shipped
    /// them (10 entries, downloads by hand), as the listener's are, they
    /// become the new default; downloading by themselves keeps the newest 5
    /// downloaded; every entry kept lists every item, downloads by hand; any
    /// other number kept lists only that many, at least 1.
    func testTheSettingsBeforeTheChoiceBecomeIt() {
        let cases: [(keepEntries: Int, autoDownload: Bool, expected: FeedItemPolicy)] = [
            (10, false, .standard),
            (10, true, .standard),
            (-1, true, .standard),
            (3, true, .standard),
            (-1, false, FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5)),
            (25, false, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 25)),
            (0, false, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 1)),
            (2_000, false, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 2_000)),
        ]
        for (keepEntries, autoDownload, expected) in cases {
            XCTAssertEqual(
                FeedItemPolicy.migrated(keepEntries: keepEntries, autoDownload: autoDownload),
                expected,
                "keeping \(keepEntries), downloading by themselves \(autoDownload)"
            )
        }
    }

    /// A feed's number of entries kept becomes a choice of its own: none
    /// follows the global setting still; every entry, as "Finish It!" keeps,
    /// uses the global setting when it lists every item, and otherwise
    /// lists every item with downloads by hand; a number lists only that
    /// many, at least 1.
    func testAFeedsNumberOfEntriesBecomesAChoiceOfItsOwn() {
        let byHand = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5)
        let shortList = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 3)

        XCTAssertNil(FeedItemPolicy.migrated(keepEntriesOverride: nil, under: .standard))
        XCTAssertNil(FeedItemPolicy.migrated(keepEntriesOverride: -1, under: .standard), "Finish It! uses the global setting")
        XCTAssertNil(FeedItemPolicy.migrated(keepEntriesOverride: -1, under: byHand))
        XCTAssertEqual(
            FeedItemPolicy.migrated(keepEntriesOverride: -1, under: shortList),
            FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 3)
        )
        XCTAssertEqual(FeedItemPolicy.migrated(keepEntriesOverride: 7, under: .standard), FeedItemPolicy(choice: .onlyNewestListed, newestCount: 7))
        XCTAssertEqual(FeedItemPolicy.migrated(keepEntriesOverride: 0, under: byHand), FeedItemPolicy(choice: .onlyNewestListed, newestCount: 1))
    }

    /// The global move is made once: a store holding no choice gets the one
    /// its retired settings ask for, written even when it is the default; a
    /// store holding a choice is left alone, whatever its retired settings
    /// say; and the retired settings stay as they were.
    func testTheGlobalMoveIsMadeOnce() {
        let shipped = makeSandboxedPreferences("FeedPolicyMoveShipped")
        XCTAssertEqual(FeedSettings.moveToItemPolicyIfNeeded(in: shipped), .standard)
        XCTAssertEqual(shipped.object(forKey: "feedItems") as? String, "everyListedNewestDownloaded")
        XCTAssertEqual(shipped.object(forKey: "feedNewestCount") as? Int, 5)
        XCTAssertNil(FeedSettings.moveToItemPolicyIfNeeded(in: shipped), "the move was made twice")

        let everyEntry = makeSandboxedPreferences("FeedPolicyMoveEvery")
        FeedSettings.keepEntriesPreference.write(-1, to: everyEntry)
        FeedSettings.autoDownloadPreference.write(false, to: everyEntry)
        XCTAssertEqual(FeedSettings.moveToItemPolicyIfNeeded(in: everyEntry), FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5))
        XCTAssertEqual(everyEntry.object(forKey: "feedKeepEntries") as? Int, -1, "a retired setting was changed")

        // A choice made since is never moved over, whatever the retired
        // settings say now.
        FeedSettings.keepEntriesPreference.write(3, to: everyEntry)
        FeedSettings.itemsPreference.write(.everyListedNewestDownloaded, to: everyEntry)
        XCTAssertNil(FeedSettings.moveToItemPolicyIfNeeded(in: everyEntry))
        XCTAssertEqual(FeedSettings.read(from: everyEntry).itemPolicy.choice, .everyListedNewestDownloaded)

        // A number the store holds already stays, the choice moved beside it.
        let numbered = makeSandboxedPreferences("FeedPolicyMoveNumbered")
        FeedSettings.newestCountPreference.write(8, to: numbered)
        XCTAssertEqual(FeedSettings.moveToItemPolicyIfNeeded(in: numbered), FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 8))
        XCTAssertEqual(numbered.object(forKey: "feedNewestCount") as? Int, 8)
        XCTAssertEqual(numbered.object(forKey: "feedItems") as? String, "everyListedNewestDownloaded")
    }

    /// The user's settings and two feeds, as they were on October 7, at the
    /// first start of the engine that brings the choice: the settings, as
    /// TextMouth shipped them, become every item listed with the newest 5
    /// downloaded; "Finish It!", which kept every entry, uses that global
    /// setting, with all 381 items kept and its override cleared on disk;
    /// "The Digital Antiquarian", which followed the setting, is left as it
    /// was, its record not even written again. A later start moves nothing,
    /// and a choice made in between stays.
    func testTheUsersSettingsAndFeedsMoveOnce() async throws {
        let world = try FeedTestWorld(self, label: "FeedPolicyMoveUser")
        let users = try UsersFeeds(world)
        try users.write(to: world)
        let antiquarianFile = FeedPaths.recordFile(of: users.antiquarian.feed.id, in: world.recordsFolder)
        let antiquarianBefore = try Data(contentsOf: antiquarianFile)

        await world.start()
        await world.center.store.flush()

        XCTAssertEqual(world.preferences.object(forKey: "feedItems") as? String, "everyListedNewestDownloaded")
        XCTAssertEqual(world.preferences.object(forKey: "feedNewestCount") as? Int, 5)
        XCTAssertNil(world.preferences.object(forKey: "feedKeepEntries"), "a retired setting was written")
        XCTAssertNil(world.preferences.object(forKey: "feedAutoDownload"), "a retired setting was written")

        let finishIt = try XCTUnwrap(world.center.store.record(of: users.finishIt.feed.id))
        XCTAssertNil(finishIt.feed.itemPolicyOverride, "Finish It! does not use the global setting")
        XCTAssertNil(finishIt.feed.keepEntriesOverride)
        XCTAssertEqual(finishIt.items.count, 381)
        XCTAssertEqual(finishIt.feed.itemPolicy(under: world.center.settings).listing, .every)
        let finishItOnDisk = try Data(contentsOf: FeedPaths.recordFile(of: users.finishIt.feed.id, in: world.recordsFolder))
        XCTAssertFalse(String(decoding: finishItOnDisk, as: UTF8.self).contains("keepEntriesOverride"))
        XCTAssertEqual(try FeedRecordCoding.decoder().decode(FeedRecord.self, from: finishItOnDisk).items.count, 381)

        XCTAssertEqual(try Data(contentsOf: antiquarianFile), antiquarianBefore, "The Digital Antiquarian's record was written again")
        XCTAssertEqual(world.center.store.record(of: users.antiquarian.feed.id), users.antiquarian)

        // A choice made since, and retired settings changed since: the next
        // start moves nothing.
        FeedSettings.itemsPreference.write(.everyListedDownloadsByHand, to: world.preferences)
        FeedSettings.keepEntriesPreference.write(3, to: world.preferences)
        let next = FeedCenter(environment: world.environment)
        addTeardownBlock { await FeedTestWorld.finish(next) }
        await next.start(library: world.library)?.value
        XCTAssertEqual(next.settings.itemPolicy, FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5))
        XCTAssertNil(next.store.record(of: users.finishIt.feed.id)?.feed.itemPolicyOverride)
        XCTAssertEqual(next.moveKeptEntriesOverrides(), [], "a feed moved twice")
    }

    /// A feed's override met later, as when a record arrives from the cloud
    /// after the first start, moves as the others did, keeping a choice of
    /// its own the feed has already.
    func testAnOverrideMetLaterMovesToo() async throws {
        let world = try FeedTestWorld(self, label: "FeedPolicyMoveLater")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A", published: world.day(-1))])))
        let feed = try await world.subscribe("/feed.xml")
        let other = try await subscribeAnother(world)

        // As a record written before the choice holds them: nothing sets
        // the retired override any more.
        world.center.store.update(feed.id) { $0.feed.keepEntriesOverride = 4 }
        world.center.store.update(other.id) { $0.feed.keepEntriesOverride = 9 }
        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 2), of: other.id)
        let moved = world.center.moveKeptEntriesOverrides()

        XCTAssertEqual(Set(moved), [feed.id, other.id])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.itemPolicyOverride, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 4))
        XCTAssertEqual(
            world.center.store.record(of: other.id)?.feed.itemPolicyOverride,
            FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 2),
            "a feed's own choice was moved over"
        )
        XCTAssertNil(world.center.store.record(of: feed.id)?.feed.keepEntriesOverride)
        XCTAssertNil(world.center.store.record(of: other.id)?.feed.keepEntriesOverride)
    }

    // MARK: - Helpers

    /// Subscribes `world` to a second feed, at /other.xml, in a folder of
    /// its own.
    private func subscribeAnother(_ world: FeedTestWorld) async throws -> Feed {
        world.server.serve("/other.xml", .feed(FeedXML.rss(title: "Other Rooms", items: [FeedXML.Item(guid: "b", title: "B", published: world.day(-2))])))
        let outcome = try await world.center.subscribe(to: world.server.url("/other.xml").absoluteString, into: .newFolder(inParentPath: world.folder.path))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedItemPolicyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "subscribing ended with \(outcome)"])
        }
        return feed
    }

    /// A record of one feed with one item, as a subscription writes it.
    private static func record() throws -> FeedRecord {
        let address = try XCTUnwrap(URL(string: "https://atlas.example/feed.xml"))
        let subscribed = Date(timeIntervalSince1970: 1_791_000_000)
        let feed = Feed(feedURL: address, folderID: UUID(), subscribedDate: subscribed)
        return FeedRecord(feed: feed, items: [FeedItem(id: "guid:a", guid: "a", title: "A", firstSeen: subscribed)])
    }
}
