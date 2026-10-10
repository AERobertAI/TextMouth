import XCTest
@testable import TextMouth

/// Speak Info names where a book is: its folder, or, for an episode or an
/// article in its feed's folder, which names no folder of its own (FR11),
/// its feed. It used to say "Not in a folder" for one (REV10, item 7).
final class LibraryFeedSpeakInfoTests: XCTestCase {

    /// The place a feed item's brief summary names is its feed; a book's is
    /// its folder, or none.
    func testTheBriefSummaryNamesAnEpisodesFeed() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let article = BookInfoFacts(
            title: "The Lamentable Later Life of Lemmings",
            author: Book.unknownAuthor,
            format: "HTML",
            folderPath: "",
            progress: nil,
            timeRemaining: nil,
            isUnopened: true,
            dateAdded: added,
            lastOpened: nil,
            bookmarkCount: 0,
            fileSize: nil,
            cloudNote: nil,
            isKeptOnThisMac: false,
            isOpenInWindow: false,
            feedTitle: "The Digital Antiquarian"
        )
        var book = article
        book.feedTitle = nil

        XCTAssertEqual(
            LibraryInfoWording.briefParts(of: article),
            ["The Lamentable Later Life of Lemmings", "HTML", "In The Digital Antiquarian, a feed", "Unopened"]
        )
        XCTAssertEqual(LibraryInfoWording.placeNote(of: book), "Not in a folder")
        book.folderPath = "Classics"
        XCTAssertEqual(LibraryInfoWording.placeNote(of: book), "In Classics")
    }

    /// A downloaded episode's facts name its feed, by the feed's title, and
    /// a book of the library's own's name none.
    @MainActor
    func testAnEpisodesFactsNameItsFeed() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedSpeakInfo")
        await world.start()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4"))
        let item = FeedXML.Item(guid: "ep-1", title: "Episode One", published: world.day(-1),
                                enclosure: world.server.url("/audio/1.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        let episode = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        var book = episode
        book.feedLink = nil
        let title = try XCTUnwrap(world.center.store.record(of: feed.id)?.feed.title)

        /// The facts Speak Info reads of `row`.
        func facts(_ row: Book) -> BookInfoFacts {
            BookInfoFacts(row, library: world.library, wordsPerMinute: 200, cloudStates: BookCloudStates(), keptBooks: KeptBooks(file: nil), measuresFileSize: false)
        }

        XCTAssertEqual(facts(episode).feedTitle, title)
        XCTAssertTrue(LibraryInfoWording.briefParts(of: facts(episode)).contains("In \(title), a feed"))
        XCTAssertNil(facts(book).feedTitle)
    }
}
