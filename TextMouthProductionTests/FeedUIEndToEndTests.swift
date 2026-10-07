import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// A feed through the Library window's interface, from end to end (FR03),
/// against a stub server: subscribed to from the Add Feed sheet's work into
/// a folder of its own, listed in the Feeds section where its folder is,
/// its folder listing its episodes; an episode downloaded from its row's
/// command, then listed as its book's row with the episode's commands
/// beside the book's, marked played from there, its download deleted, and
/// the feed unsubscribed after a confirmation naming what stays. No episode
/// is played aloud: a download only becomes a book.
@MainActor
final class FeedUIEndToEndTests: XCTestCase {

    /// From Add Feed to Unsubscribe, through the interface's own models.
    func testAFeedFromAddFeedToUnsubscribe() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIEndToEnd")
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 1), mimeType: "audio/mp4"))
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [
            FeedXML.Item(
                guid: "ep-1",
                title: "A map you can touch",
                published: world.day(1),
                enclosure: world.server.url("/audio/1.m4a").absoluteString,
                enclosureType: "audio/mp4",
                description: "<p>Raised lines and dots, read by hand.</p>"
            ),
            FeedXML.Item(guid: "ep-2", title: "The first visit", published: world.day(-3), enclosure: world.server.url("/audio/2.m4a").absoluteString),
        ])))
        await world.start()
        let feedFolders = LibraryFeedFolders(center: world.center)
        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)

        // Add Feed, into the world's folder, which the sheet offers first
        // when the window shows it.
        presenter.showAddFeed(
            center: world.center,
            parentPath: AddFeedPlaces.initialParent(shownPath: world.folder.path, in: world.library.library, feedFolders: feedFolders)
        )
        let sheet = try XCTUnwrap(presenter.addFeed)
        XCTAssertEqual(sheet.parentPath, world.folder.path)
        sheet.address = world.server.url("/feed.xml").absoluteString
        await sheet.subscribe()?.value
        let feed = try XCTUnwrap(sheet.subscribedFeed)
        presenter.addFeedSubscribed(feed)
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        XCTAssertEqual(folderPath, "\(world.folder.path)/The Tactile Atlas")
        XCTAssertEqual(feedFolders.feedID(inFolder: feed.folderID), feed.id, "the folder does not say Feed")

        // The Feeds section where the feed's folder is, and its folder's
        // episodes.
        let rows = LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: world.folder.path), center: world.center)
        XCTAssertEqual(rows.map(\.title), ["The Tactile Atlas"])
        XCTAssertEqual(rows.first?.countsText, "2 episodes, 1 new, 2 unplayed")
        var listing = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [], search: "")
        XCTAssertEqual(listing.entries.map(\.id), ["item:guid:ep-1", "item:guid:ep-2"])

        // Download, from the episode's row.
        guard case .item(let row)? = listing.entries.first else { return XCTFail("\(listing.entries)") }
        let download = try XCTUnwrap(FeedItemAction.actions(for: row).first { $0.command == .download })
        presenter.perform(download, in: context)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(book.folderPath, folderPath)

        // Now the episode is its book's row, with the episode's commands.
        listing = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [book], folderBooks: [book], search: "")
        guard case .book(let listed, let actions)? = listing.entries.first else { return XCTFail("\(listing.entries)") }
        XCTAssertEqual(listed.id, book.id)
        XCTAssertEqual(actions.map(\.title), ["Mark Played", "Show Description…", "Delete Download", "Delete Episode…"])
        XCTAssertEqual(world.center.counts(of: feed.id).downloaded, 1)

        // Mark Played, from the book's row.
        presenter.perform(try XCTUnwrap(actions.first), in: context)
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate)
        XCTAssertEqual(world.center.counts(of: feed.id).unplayed, 1)

        // Delete Download: the book goes, the episode stays.
        presenter.perform(try XCTUnwrap(actions.first { $0.command == .deleteDownload }), in: context)
        XCTAssertNil(world.library.bookByID(book.id))
        listing = FeedFolderListing.make(feedID: feed.id, center: world.center, shownBooks: [], folderBooks: [], search: "")
        guard case .item(let after)? = listing.entries.first else { return XCTFail("\(listing.entries)") }
        XCTAssertEqual(after.state, .notDownloaded)
        XCTAssertTrue(after.isPlayed)

        // Unsubscribe, after a confirmation: the feed goes, and its folder
        // stays as a plain folder.
        let unsubscribe = try XCTUnwrap(FeedAction.actions(for: feed.id, noun: .episode).first { $0.command == .unsubscribe })
        presenter.perform(unsubscribe, in: context)
        let question = try XCTUnwrap(presenter.confirmation)
        XCTAssertEqual(question.message, FeedWording.unsubscribeMessage(bookTitles: [], folderPath: folderPath))
        presenter.confirm(question, in: context)
        XCTAssertTrue(world.center.feeds.isEmpty)
        XCTAssertNotNil(world.library.library.folders.first { $0.id == feed.folderID }, "unsubscribing removed the folder")
        XCTAssertNil(feedFolders.feedID(inFolder: feed.folderID), "the plain folder still says Feed")
        XCTAssertTrue(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center).isEmpty)
        XCTAssertEqual(heard.last, "Unsubscribed from The Tactile Atlas.")
    }
}
