import XCTest
@testable import TextMouth

/// A launch marks an item downloaded again when its feed's record says it
/// is not, an older TextMouth having lost sight of its download, only when
/// the download's file is here (the A2 review's item G). In a cloud library
/// a second Mac that removed the download leaves this Mac's package only in
/// the cloud, and marking such an item downloaded would undo that removal,
/// which the other Mac would undo in turn; nothing is decided from what the
/// cloud answers (FR02). Such a row, and one whose file is gone, goes back to
/// its feed's kept rows, as the record has it. The cloud is scripted; no real
/// cloud drive is used.
final class LibraryFeedItemHealTests: FeedItemIndexTestCase {

    /// Of three items the record says are not downloaded, the one whose
    /// file is here is marked downloaded again; the one whose package is
    /// only in the cloud, and the one whose file is gone, stay not
    /// downloaded and go back to the feed's kept rows; a second pass
    /// changes nothing.
    @MainActor
    func testOnlyAFileFoundHereMarksItsItemDownloadedAgain() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedHeal")
        let episodes = [
            FeedXML.Item(guid: "ep-3", title: "Here", enclosure: "https://atlas.example/audio/3.mp3"),
            FeedXML.Item(guid: "ep-2", title: "In the Cloud", enclosure: "https://atlas.example/audio/2.mp3"),
            FeedXML.Item(guid: "ep-1", title: "Gone", enclosure: "https://atlas.example/audio/1.mp3"),
        ]
        world.server.serve("/heal.xml", .feed(FeedXML.rss(items: episodes)))
        let feed = try await world.subscribe("/heal.xml")
        let here = try makeFeedItem(title: "Here", itemID: "guid:ep-3", of: feed.id)
        let inCloud = try makeFeedItem(title: "In the Cloud", itemID: "guid:ep-2", of: feed.id)
        let gone = try makeFeedItem(title: "Gone", itemID: "guid:ep-1", of: feed.id)
        for row in [here, inCloud, gone] {
            world.library.addFeedBook(row)
        }
        // The package only in the cloud: its listing is not on this Mac, so
        // its file is not found either; the other's file is simply gone.
        try FileManager.default.removeItem(at: inCloud.bookFileURL)
        cloud.markDataless(inCloud.tmbDirectory)
        try FileManager.default.removeItem(at: gone.bookFileURL)
        for itemID in ["guid:ep-3", "guid:ep-2", "guid:ep-1"] {
            world.center.store.updateItem(itemID, of: feed.id) { item in
                item.state = .notDownloaded
                item.downloadDeletedDate = world.clock.value
            }
        }

        XCTAssertEqual(world.library.markFeedItemsDownloadedAgain(access: cloud.access), 1)

        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.item("guid:ep-3")?.state, .downloaded(bookID: here.id))
        XCTAssertEqual(record.item("guid:ep-2")?.state, .notDownloaded)
        XCTAssertEqual(record.item("guid:ep-1")?.state, .notDownloaded)
        XCTAssertNotNil(world.library.bookByID(here.id))
        XCTAssertNil(world.library.bookByID(inCloud.id), "a download only in the cloud is still listed")
        XCTAssertNil(world.library.bookByID(gone.id), "a gone download is still listed")
        let kept = world.library.feedItemRows(of: feed.id).kept
        XCTAssertEqual(kept["guid:ep-2"], inCloud)
        XCTAssertEqual(kept["guid:ep-1"], gone)
        XCTAssertEqual(world.library.markFeedItemsDownloadedAgain(access: cloud.access), 0, "a second pass marked an item")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .notDownloaded)
    }
}
