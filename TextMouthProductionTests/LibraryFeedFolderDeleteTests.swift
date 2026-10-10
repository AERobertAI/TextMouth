import XCTest
@testable import TextMouth

/// Delete Folder… and feeds (FR03, FR14). A feed's own folder offers no
/// Delete Folder…: its feed's commands offer Delete Feed… there, so a feed
/// has one command that deletes it. Delete Folder… on a folder holding
/// feeds' folders deeper inside asks first, naming each feed and saying
/// what happens to it: its folder moves with Move Contents Out, and with
/// Delete Everything the feed stays, with its downloads, listed by no
/// folder until Feed Info gives it another.
final class LibraryFeedFolderDeleteTests: XCTestCase {

    /// A feed's folder holding only the feed's download counts as having
    /// contents, and offers no Delete Folder…, which its feed's Delete Feed…
    /// stands for; the folder holding it, and an empty folder that is no
    /// feed's, offer Delete Folder…, the empty one deleted without a
    /// question.
    @MainActor
    func testAFeedsFolderOffersDeleteFeedInPlaceOfDeleteFolder() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedFolderDelete")
        let (feed, _) = try await feedWithDownloads(
            episodes: 1,
            downloading: 1,
            in: world,
            into: .newFolder(inParentPath: world.folder.path)
        )
        let feedFolder = try XCTUnwrap(world.library.library.folders.first { $0.id == feed.folderID })
        let empty = BookFolder(name: "Empty \(UUID().uuidString.prefix(8))")
        world.library.library.folders.append(empty)

        XCTAssertFalse(world.library.library.folderHasContents(feedFolder), "the feed's folder holds a book of the library's own")
        XCTAssertTrue(world.library.folderHasContents(feedFolder))
        XCTAssertFalse(world.library.offersDeleteFolder(feedFolder), "a feed's folder offered a second delete")
        XCTAssertTrue(FeedAction.actions(for: feed.id, in: world.center).contains { $0.command == .deleteFeed })
        XCTAssertTrue(world.library.offersDeleteFolder(world.bookFolder))
        XCTAssertTrue(world.library.offersDeleteFolder(empty))
        XCTAssertFalse(world.library.folderHasContents(empty))
    }

    /// The feeds whose folders are inside a folder, at any depth, are the
    /// ones its question names, by title; a feed's own folder names none.
    @MainActor
    func testTheFeedsInsideAFolderAreNamed() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedFolderDeleteNamed")
        let (atlas, _) = try await feedWithDownloads(episodes: 1, downloading: 0, in: world, into: .newFolder(inParentPath: world.folder.path))
        let atlasFolder = try XCTUnwrap(world.library.library.folders.first { $0.id == atlas.folderID })
        let showsName = "Shows \(UUID().uuidString.prefix(8))"
        XCTAssertTrue(world.library.createFolderReturningOutcome(name: showsName, parentPath: world.folder.path).succeeded)
        let shows = try XCTUnwrap(world.library.library.folders.first { $0.fullPath == "\(world.folder.path)/\(showsName)" })
        world.server.serve("/harbour.xml", .feed(FeedXML.rss(title: "The Harbour Log", items: [
            FeedXML.Item(guid: "log-1", title: "Low water", published: world.day(-1)),
        ])))
        _ = try await world.center.subscribe(to: world.server.url("/harbour.xml").absoluteString, into: .newFolder(inParentPath: shows.fullPath))

        XCTAssertEqual(world.library.feedTitles(inside: world.bookFolder), ["The Harbour Log", "The Tactile Atlas"])
        XCTAssertEqual(world.library.feedTitles(inside: shows), ["The Harbour Log"])
        XCTAssertEqual(world.library.feedTitles(inside: atlasFolder), [])
    }

    /// Move Contents Out moves a feed's folder with the rest, so the feed
    /// keeps listing its downloads there; Delete Everything's change to the
    /// library leaves the feed's downloads, which name no folder, and takes
    /// only its folder, as the questions say.
    @MainActor
    func testWhatHappensToAFeedInsideAFolderIsWhatTheQuestionSays() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedFolderDeleteFate")
        let parentName = "Shows \(UUID().uuidString.prefix(8))"
        XCTAssertTrue(world.library.createFolderReturningOutcome(name: parentName, parentPath: world.folder.path).succeeded)
        let parentPath = "\(world.folder.path)/\(parentName)"
        let (feed, books) = try await feedWithDownloads(episodes: 1, downloading: 1, in: world, into: .newFolder(inParentPath: parentPath))
        let parent = try XCTUnwrap(world.library.library.folders.first { $0.fullPath == parentPath })

        var everything = world.library.library
        _ = everything.removeFolderAndContents(id: parent.id)
        XCTAssertNil(everything.folders.first { $0.id == feed.folderID }, "Delete Everything kept the feed's folder")
        XCTAssertEqual(everything.books.filter { $0.feedLink?.feedID == feed.id }.map(\.id), books.map(\.id), "Delete Everything took a download")

        let outcome = await world.library.removeFolderMovingContentsReturningOutcome(parent, toPath: world.folder.path)

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        let moved = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID), "the feed's folder went with Move Contents Out")
        XCTAssertTrue(moved.hasPrefix(world.folder.path + "/"), moved)
        XCTAssertEqual(world.library.displayedBooks(at: LibraryLocation(category: .folders, folderPath: moved)).map(\.id), books.map(\.id))
        XCTAssertNotNil(world.center.store.record(of: feed.id))
    }

    /// The question about a folder holding feeds' folders names each feed
    /// and says what happens to it, for one feed and for several, in both
    /// questions; a folder holding none is asked about as before.
    func testTheQuestionSaysWhatHappensToEachFeedInside() {
        let one = FolderRemovalWording(mode: .moveToTrash, folderName: "Shows", bookCount: 0, feedTitles: ["The Tactile Atlas"])
        XCTAssertEqual(
            one.choiceMessage,
            "“Shows” contains 0 books and may have subfolders. "
                + "With Move Contents Out, they stay in the library and only the folder is deleted. "
                + "With Move Everything to Trash, the folder and everything in it leave the library, "
                + "and their files go to the Trash, where you can recover them until the Trash is emptied. "
                + "It holds the folder of the feed “The Tactile Atlas”. With Move Contents Out, the feed's folder moves "
                + "with the rest. With Move Everything to Trash, the feed stays, with its downloads, but no folder lists "
                + "them until Feed Info gives the feed another folder; Delete Feed… on the feed's row deletes a feed."
        )
        XCTAssertEqual(
            one.confirmationMessage,
            "“Shows” and any subfolders will be removed from the library. "
                + "Their files go to the Trash, where you can recover them until the Trash is emptied. "
                + "The feed “The Tactile Atlas” stays, with its downloads, without a folder until Feed Info gives it another."
        )
        let two = FolderRemovalWording(mode: .deletePermanently, folderName: "Shows", bookCount: 2, feedTitles: ["Finish It!", "The Harbour Log"])
        XCTAssertTrue(
            two.choiceMessage.hasSuffix(
                "It holds the folders of the feeds “Finish It!” and “The Harbour Log”. With Move Contents Out, their folders "
                    + "move with the rest. With Delete Everything Permanently, each feed stays, with its downloads, but no "
                    + "folder lists them until Feed Info gives the feed another folder; Delete Feed… on a feed's row deletes a feed."
            ),
            two.choiceMessage
        )
        XCTAssertTrue(
            two.confirmationMessage.hasSuffix(
                "The feeds “Finish It!” and “The Harbour Log” stay, with their downloads, without folders until Feed Info gives each another."
            ),
            two.confirmationMessage
        )
        let plain = FolderRemovalWording(mode: .moveToTrash, folderName: "Atlas", bookCount: 2)
        XCTAssertFalse(plain.choiceMessage.contains("feed"), plain.choiceMessage)
        XCTAssertFalse(plain.confirmationMessage.contains("feed"), plain.confirmationMessage)
    }
}
