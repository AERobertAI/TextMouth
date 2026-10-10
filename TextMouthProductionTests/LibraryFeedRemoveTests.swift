import XCTest
@testable import TextMouth

/// The library's Remove on feed items, episodes and articles in their feeds'
/// folders, is their Delete Download (FR11, branch A2): their files go, as
/// the Trash preference says, and each item's place, bookmarks, and
/// transcript are kept. So when every book it removes is a feed item, its
/// question speaks of deleting downloads and offers no Remove from Library
/// Only, which a feed item refuses, and its report says what was kept rather
/// than that the item went to the Trash (the A2 review's item I).
final class LibraryFeedRemoveTests: XCTestCase {

    // MARK: - The Question

    /// For feed items alone the question is Delete Download's, in each
    /// deleting mode, with no Remove from Library Only; for books, or books
    /// and feed items together, it is the library's own, as before.
    func testTheQuestionForFeedItemsAloneIsDeleteDownloads() {
        let episode = Self.feedItem("Ep. 368")
        let article = Self.feedItem("Lamentable Lemmings")
        let book = Book(title: "Field Notes", format: .txt, filePath: "/Library/Notes.tmb/notes.txt", md5Hash: "notes", tmbDirectoryName: "Notes.tmb")

        let one = RemovalChoiceWording(books: [episode], movesToTrash: true)
        XCTAssertEqual(one.title, "Delete Download?")
        XCTAssertEqual(one.deleteButtonTitle, "Delete Download")
        XCTAssertFalse(one.offersLibraryOnly)
        XCTAssertEqual(
            one.message,
            "The download of “Ep. 368” will be deleted. Its files go to the Trash, where you can recover them until the Trash is emptied. "
                + "Its place, bookmarks, and transcript, if it has any, are kept, and it can be downloaded again."
        )

        let two = RemovalChoiceWording(books: [episode, article], movesToTrash: false)
        XCTAssertEqual(two.title, "Delete 2 Downloads?")
        XCTAssertEqual(two.deleteButtonTitle, "Delete Downloads")
        XCTAssertFalse(two.offersLibraryOnly)
        XCTAssertEqual(
            two.message,
            "2 downloads will be deleted. Their files are deleted permanently and cannot be recovered. "
                + "Their places, bookmarks, and transcripts, if they have any, are kept, and they can be downloaded again."
        )

        let mixed = RemovalChoiceWording(books: [book, episode], movesToTrash: true)
        XCTAssertTrue(mixed.offersLibraryOnly)
        XCTAssertEqual(mixed.title, "Remove 2 Books?")
        XCTAssertEqual(mixed.deleteButtonTitle, "Move to Trash")
    }

    // MARK: - The Report

    /// The report names the books that went and the downloads deleted, and
    /// says which downloads kept their place, bookmarks, and transcript.
    func testTheReportSaysWhatTheDownloadsKept() {
        let episode = Self.feedItem("Ep. 368")
        let others = [Self.feedItem("Ep. 367"), Self.feedItem("Ep. 366")]
        let book = Book(title: "Field Notes", format: .txt, filePath: "/Library/Notes.tmb/notes.txt", md5Hash: "notes", tmbDirectoryName: "Notes.tmb")

        XCTAssertEqual(
            LibraryViewModel.removalCompletion([book, episode], mode: .moveToTrash, keptIDs: [episode.id]),
            "Moved “Field Notes” to the Trash. Moved the download of “Ep. 368” to the Trash. "
                + "Its place, bookmarks, and transcript are kept."
        )
        XCTAssertEqual(
            LibraryViewModel.removalCompletion([episode], mode: .moveToTrash, keptIDs: []),
            "Moved the download of “Ep. 368” to the Trash."
        )
        XCTAssertEqual(
            LibraryViewModel.removalCompletion([episode] + others, mode: .deletePermanently, keptIDs: [episode.id, others[0].id]),
            "Deleted 3 downloads permanently. The places, bookmarks, and transcripts of 2 of them are kept."
        )
        XCTAssertEqual(
            LibraryViewModel.removalCompletion(others, mode: .moveToTrash, keptIDs: Set(others.map(\.id))),
            "Moved 2 downloads to the Trash. Their places, bookmarks, and transcripts are kept."
        )
        XCTAssertNil(LibraryViewModel.removalCompletion([], mode: .moveToTrash, keptIDs: []))
    }

    /// Removing an episode the listener opened, as the library's Remove does
    /// once its question is confirmed, deletes its download, keeps its row
    /// on its feed's shelf, and says so through VoiceOver in the words of
    /// the removal setting in force.
    @MainActor
    func testRemovingAnOpenedEpisodeSaysItsPlaceIsKept() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedRemove")
        await world.start()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4"))
        let item = FeedXML.Item(guid: "ep-1", title: "Episode One", published: world.day(-1),
                                enclosure: world.server.url("/audio/1.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        let mode = world.library.removalPreferences.deletionMode

        let heard = recordingAnnouncements {
            world.library.performRemoveBooks([book], deleteTMB: true)
        }

        XCTAssertFalse(world.library.showError, world.library.errorMessage ?? "")
        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, book.id)
        XCTAssertEqual(
            heard.announcements.map(\.message),
            [FeedDownloadRemovalWording(mode, items: [book]).completionMessage(keptCount: 1)]
        )
        XCTAssertTrue(heard.announcements.first?.message.hasSuffix("Its place, bookmarks, and transcript are kept.") == true)
    }

    // MARK: - Fixtures

    /// A feed item's row titled `title`, with no package behind it.
    private static func feedItem(_ title: String) -> Book {
        Book(
            title: title,
            format: .audio,
            filePath: "/Feeds/\(title).tmb/\(title).m4a",
            md5Hash: title,
            tmbDirectoryName: "\(title).tmb",
            feedLink: FeedBookLink(feedID: UUID(), itemID: "guid:\(title)")
        )
    }
}
