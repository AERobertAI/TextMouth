import XCTest
@testable import TextMouth

// MARK: - Unsubscribe as a Switch (FR11, Branch D)

/// Unsubscribing is a switch (FR11, branch D; the listener's answer of
/// October 9: "just keep it a feed with rules kept except you can't check
/// it or manually check it for new items"): a feed's record says whether it
/// is subscribed, an absent field meaning subscribed, so every record
/// written before the switch, the listener's two among them, reads as
/// subscribed and is written exactly as it was.
final class FeedSubscriptionRecordTests: XCTestCase {

    // MARK: - The Record

    /// A record written before the switch, shaped like the listener's own
    /// two ("The Digital Antiquarian" and "Finish It!"), has no field for
    /// it, and reads as subscribed.
    func testARecordWrittenBeforeTheSwitchReadsAsSubscribed() throws {
        for (title, address) in [
            ("The Digital Antiquarian", "https://www.filfre.net/feed/"),
            ("Finish It!", "https://finish.example/feed.xml"),
        ] {
            let json = """
            {
              "feed" : {
                "feedURL" : "\(address)",
                "folderID" : "\(UUID().uuidString)",
                "id" : "\(UUID().uuidString)",
                "isSerial" : false,
                "newestItemDate" : "2026-10-03T18:00:00Z",
                "subscribedDate" : "2026-10-03T18:00:00Z",
                "title" : "\(title)",
                "usesInsecureTransport" : false
              },
              "formatVersion" : 1,
              "items" : [

              ]
            }
            """
            let record = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(json.utf8))
            XCTAssertNil(record.feed.unsubscribedDate, title)
            XCTAssertTrue(record.feed.isSubscribed, title)
        }
    }

    /// A subscribed feed's record writes no field for the switch, so its
    /// file is as it was; an unsubscribed feed's writes the date it was
    /// unsubscribed, and reads back unsubscribed, as it was written.
    func testOnlyAnUnsubscribedFeedWritesTheField() throws {
        let feed = Feed(
            feedURL: try XCTUnwrap(URL(string: "https://finish.example/feed.xml")),
            folderID: UUID(),
            subscribedDate: Date(timeIntervalSince1970: 1_790_000_000)
        )
        var record = FeedRecord(feed: feed, items: [FeedItem(id: "guid:ep-368", title: "Ep. 368", firstSeen: feed.subscribedDate)])
        XCTAssertTrue(record.feed.isSubscribed, "a new subscription was unsubscribed")

        let subscribed = try FeedRecordCoding.encoder().encode(record)
        let subscribedFeed = try XCTUnwrap(try JSONSerialization.jsonObject(with: subscribed) as? [String: Any])["feed"] as? [String: Any]
        XCTAssertNil(subscribedFeed?["unsubscribedDate"], "a subscribed feed's record wrote the field")

        record.feed.unsubscribedDate = Date(timeIntervalSince1970: 1_790_086_400)
        let unsubscribed = try FeedRecordCoding.encoder().encode(record)
        let unsubscribedFeed = try XCTUnwrap(try JSONSerialization.jsonObject(with: unsubscribed) as? [String: Any])["feed"] as? [String: Any]
        XCTAssertEqual(unsubscribedFeed?["unsubscribedDate"] as? String, "2026-09-22T14:13:20Z")

        let read = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: unsubscribed)
        XCTAssertEqual(read, record)
        XCTAssertFalse(read.feed.isSubscribed)
    }
}
