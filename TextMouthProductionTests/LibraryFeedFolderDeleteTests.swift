import XCTest
@testable import TextMouth

/// Delete Folder… asks first about a folder that holds anything: books,
/// subfolders, or a feed, whose folder it is (FR03). A feed's folder that
/// lists only the feed's downloads holds no book of the library's own, since
/// a feed item names no folder (FR11), so it was deleted at once with no
/// question (REV10, item 4). It is asked about now, and the question says
/// what becomes of the feed's downloads.
final class LibraryFeedFolderDeleteTests: XCTestCase {

    /// A feed's folder holding only the feed's download counts as having
    /// contents, so Delete Folder… asks first; an empty folder that is no
    /// feed's does not.
    @MainActor
    func testAFeedsFolderHoldingOnlyDownloadsIsAskedAbout() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedFolderDelete")
        await world.start()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4"))
        let item = FeedXML.Item(guid: "ep-1", title: "Episode One", published: world.day(-1),
                                enclosure: world.server.url("/audio/1.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        let empty = BookFolder(name: "Empty \(UUID().uuidString.prefix(8))")
        world.library.library.folders.append(empty)

        XCTAssertFalse(world.library.library.folderHasContents(world.bookFolder), "the feed's folder holds a book of the library's own")
        XCTAssertTrue(world.library.folderHasContents(world.bookFolder))
        XCTAssertFalse(world.library.folderHasContents(empty))
    }

    /// The question about a feed's folder says, last, that the feed's
    /// downloads stay either way and where they are listed then; a folder
    /// that is no feed's is asked about as before.
    func testTheQuestionSaysWhatBecomesOfTheFeedsDownloads() {
        let feeds = FolderRemovalWording(mode: .moveToTrash, folderName: "Atlas", bookCount: 0, feedTitle: "The Tactile Atlas")
        XCTAssertEqual(
            feeds.choiceMessage,
            "“Atlas” contains 0 books and may have subfolders. "
                + "With Move Contents Out, they stay in the library and only the folder is deleted. "
                + "With Move Everything to Trash, the folder and everything in it leave the library, "
                + "and their files go to the Trash, where you can recover them until the Trash is emptied. "
                + "It is also the folder of the feed “The Tactile Atlas”: either way, its downloads stay, "
                + "but no folder lists them until Feed Info gives the feed another folder."
        )
        let plain = FolderRemovalWording(mode: .moveToTrash, folderName: "Atlas", bookCount: 2)
        XCTAssertFalse(plain.choiceMessage.contains("feed"), plain.choiceMessage)
    }
}
