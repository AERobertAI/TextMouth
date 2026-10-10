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

    // MARK: - Helpers

    /// A record of one feed with one item, as a subscription writes it.
    private static func record() throws -> FeedRecord {
        let address = try XCTUnwrap(URL(string: "https://atlas.example/feed.xml"))
        let subscribed = Date(timeIntervalSince1970: 1_791_000_000)
        let feed = Feed(feedURL: address, folderID: UUID(), subscribedDate: subscribed)
        return FeedRecord(feed: feed, items: [FeedItem(id: "guid:a", guid: "a", title: "A", firstSeen: subscribed)])
    }
}
