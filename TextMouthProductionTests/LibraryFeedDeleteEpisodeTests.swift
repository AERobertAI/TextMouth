import XCTest
@testable import TextMouth

/// Delete Episode… and Delete Article… delete everything TextMouth keeps of
/// an item, its package included (FR11, branch A2), so the question before
/// them says so when it keeps the listener's place, bookmarks, or transcript
/// for it: a package kept after its download went, or a download whose
/// package holds them (the A2 review's item F). VoiceOver reads the question
/// as the alert shows it.
final class LibraryFeedDeleteEpisodeTests: XCTestCase {

    /// The question's words, with and without what TextMouth keeps for the
    /// item.
    func testTheQuestionSaysWhatItDeletesOfTheListeners() {
        XCTAssertEqual(
            FeedWording.deleteItemMessage(isArticle: false),
            "The episode leaves the list for good, and its download, if any, is deleted. Checking the feed won't bring it back."
        )
        XCTAssertEqual(
            FeedWording.deleteItemMessage(isArticle: true, keepsListenerState: true),
            "The article leaves the list for good, and its download, if any, is deleted. "
                + "The place, bookmarks, and transcript kept for it are deleted too. Checking the feed won't bring it back."
        )
    }

    /// An episode whose download went while its package was kept, and one
    /// downloaded and listened to, are asked about with the sentence; one
    /// never downloaded, and one downloaded but never opened, without it.
    @MainActor
    func testTheQuestionNamesWhatTheItemKeeps() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedDeleteEpisode")
        let (feed, books) = try await downloadedEpisodes(4, downloading: 3, in: world)
        for book in books.prefix(2) {
            world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        }
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertNotNil(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"], "the listened download's package was not kept")
        let presenter = LibraryFeedsPresenter()
        presenter.announce = { _, _ in }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)

        /// The question Delete Episode… asks about the item `itemID`.
        func question(_ itemID: FeedItem.ID) throws -> String {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            presenter.perform(
                FeedItemAction(
                    command: .deleteItem,
                    feedID: feed.id,
                    itemID: itemID,
                    itemTitle: item.title,
                    isArticle: item.isArticle,
                    title: FeedWording.title(of: .deleteItem, isArticle: item.isArticle)
                ),
                in: context
            )
            return try XCTUnwrap(presenter.confirmation?.message)
        }

        let keeps = FeedWording.deleteItemMessage(isArticle: false, keepsListenerState: true)
        let keepsNothing = FeedWording.deleteItemMessage(isArticle: false)
        XCTAssertEqual(try question("guid:ep-1"), keeps, "the package kept after its download went")
        XCTAssertEqual(try question("guid:ep-2"), keeps, "the download listened to")
        XCTAssertEqual(try question("guid:ep-3"), keepsNothing, "the download never opened")
        XCTAssertEqual(try question("guid:ep-4"), keepsNothing, "the episode never downloaded")
    }

    // MARK: - Fixtures

    /// Starts `world`'s engine, subscribes it to a feed of `count` episodes,
    /// and downloads the first `downloading` of them; returns the feed and
    /// the books, episode 1 first.
    @MainActor
    private func downloadedEpisodes(_ count: Int, downloading: Int, in world: FeedTestWorld) async throws -> (Feed, [Book]) {
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        let items = (1...count).map { number in
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
            return FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(Double(-number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        var books: [Book] = []
        for number in 1...downloading {
            world.center.download("guid:ep-\(number)", of: feed.id)
            books.append(try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)"))
        }
        return (feed, books)
    }
}
