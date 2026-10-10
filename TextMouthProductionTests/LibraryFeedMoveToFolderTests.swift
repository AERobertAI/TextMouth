import XCTest
@testable import TextMouth

/// Move to Folder… never moves a feed item, an episode or an article in its
/// feed's folder (FR11). It used to close as if it had worked while doing
/// nothing for one (REV10, item 6): it is not offered now for feed items
/// alone, and for a selection mixing them with books it moves the books and
/// says, through VoiceOver, which items it left where they are.
final class LibraryFeedMoveToFolderTests: FeedItemIndexTestCase {

    /// The row's command counts only the books it can move, and is not
    /// offered for feed items alone.
    func testTheCommandIsOfferedOnlyForBooksItCanMove() throws {
        let book = try makePackagedBook(title: "Middlemarch")
        let other = try makePackagedBook(title: "Bleak House")
        let item = try makeFeedItem(title: "Lamentable Lemmings")

        XCTAssertNil(LibraryTransitionWording.moveToFolderTitle(for: [item]))
        XCTAssertEqual(LibraryTransitionWording.moveToFolderTitle(for: [book]), "Move to Folder...")
        XCTAssertEqual(LibraryTransitionWording.moveToFolderTitle(for: [book, item]), "Move to Folder...")
        XCTAssertEqual(LibraryTransitionWording.moveToFolderTitle(for: [book, other, item]), "Move 2 Books to Folder...")
    }

    /// What VoiceOver hears of the items left: each named, up to three, then
    /// how many more; nothing when none was left.
    func testWhatIsSaidOfTheItemsLeft() {
        XCTAssertNil(LibraryTransitionWording.feedItemsLeft(titles: []))
        XCTAssertEqual(
            LibraryTransitionWording.feedItemsLeft(titles: ["Ep. 368"]),
            "Left “Ep. 368” where it is: episodes and articles stay in their feeds."
        )
        XCTAssertEqual(
            LibraryTransitionWording.feedItemsLeft(titles: ["Ep. 368", "Ep. 367"]),
            "Left “Ep. 368” and “Ep. 367” where they are: episodes and articles stay in their feeds."
        )
        XCTAssertEqual(
            LibraryTransitionWording.feedItemsLeft(titles: ["A", "B", "C", "D", "E"]),
            "Left “A”, “B”, “C”, and 2 more where they are: episodes and articles stay in their feeds."
        )
    }

    /// A mixed selection's move takes the book into the folder, leaves the
    /// article in its feed's folder, and returns which it left, saying
    /// nothing itself, for the Move sheet's owner to say once the sheet has
    /// closed, so its closing never cuts the words off (REV11 F6).
    @MainActor
    func testAMixedSelectionMovesTheBooksAndSaysWhatItLeft() async throws {
        let book = try makePackagedBook(title: "Middlemarch")
        let item = try makeFeedItem(title: "Lamentable Lemmings")
        let destination = "\(folderPath)/Shelf"
        try TextMouthPaths.ensureLibrarySubfolder(destination)
        let model = makeModel(with: [book, item])
        model.library.folders = [BookFolder(name: folderPath), BookFolder(name: "Shelf", parentPath: folderPath)]
        let heard = Heard()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.messages.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }

        let outcome = await model.moveBooksReturningOutcome([book, item], toFolder: destination)

        XCTAssertEqual(outcome, .success("Left “Lamentable Lemmings” where it is: episodes and articles stay in their feeds."))
        let moved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(moved.folderPath, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.filePath), "the book's file is not where its row says")
        XCTAssertEqual(model.bookByID(item.id), item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.bookFileURL.path))
        XCTAssertEqual(heard.messages, [], "the note was said while the Move sheet closed")
    }

    // MARK: - Fixtures

    /// What VoiceOver was asked to say, in order.
    @MainActor
    private final class Heard {
        var messages: [String] = []
    }
}
