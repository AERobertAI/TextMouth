import XCTest
@testable import TextMouth

/// `PhoneLibraryOffer`: which commands a Library row has, in the spec's order,
/// under the Mac's names.
@MainActor
final class PhoneLibraryOfferTests: XCTestCase {
    /// A book outside the reading list, in no arranged order, offers Book
    /// Info, Add to Reading List, Move to Folder..., Export..., and the
    /// removal, in that order, each by the Mac's name.
    func testABooksCommandsInOrder() {
        let commands = PhoneLibraryOffer.bookCommands(
            for: PhoneLibraryFixture.book("Dune"),
            isInReadingList: false,
            moves: nil,
            removal: PhoneLibraryFixture.phoneRemoval
        )

        XCTAssertEqual(commands.map(\.action), [.bookInfo, .addToReadingList, .moveToFolder, .export, .remove])
        XCTAssertEqual(
            commands.map(\.title),
            ["Book Info", "Add to Reading List", "Move to Folder...", "Export…", "Remove from Library..."]
        )
    }

    /// A book in the reading list offers Remove from Reading List instead,
    /// and Move Up and Move Down come before the removal where it can move.
    func testReadingListAndMoves() {
        let commands = PhoneLibraryOffer.bookCommands(
            for: PhoneLibraryFixture.book("Dune"),
            isInReadingList: true,
            moves: LibraryManualMoves(canMoveUp: true, canMoveDown: true),
            removal: PhoneLibraryFixture.phoneRemoval
        )

        XCTAssertEqual(
            commands.map(\.title),
            ["Book Info", "Remove from Reading List", "Move to Folder...", "Export…", "Move Up", "Move Down", "Remove from Library..."]
        )
    }

    /// With Confirm before removing a book off, the removal names what it
    /// does at once, in the Mac's words.
    func testRemovalWithoutAskingSaysWhatItDoes() {
        let commands = PhoneLibraryOffer.bookCommands(
            for: PhoneLibraryFixture.book("Dune"),
            isInReadingList: false,
            moves: LibraryManualMoves(canMoveUp: false, canMoveDown: true),
            removal: RemovalPreferences(confirmsFirst: false, movesToTrash: false)
        )

        XCTAssertEqual(commands.last?.title, "Delete Permanently")
        XCTAssertEqual(commands.filter { $0.action == .moveUp }.count, 0)
        XCTAssertEqual(commands.filter { $0.action == .moveDown }.count, 1)
    }

    /// A folder offers Rename, Move, and Delete where the Mac offers Delete; the Export command comes with books in it.
    func testAFoldersCommands() {
        XCTAssertEqual(
            PhoneLibraryOffer.folderCommands(offersDelete: true).map(\.action),
            [.renameFolder, .moveFolder, .deleteFolder]
        )
        XCTAssertEqual(
            PhoneLibraryOffer.folderCommands(offersDelete: false).map(\.title),
            ["Rename Folder...", "Move Folder..."]
        )
    }

    /// A folder that holds books offers the Mac's Export command for them, after Move Folder... and before Delete
    /// Folder..., named by how many there are: "Export…" for one, "Export 12 Books…" for several (FR31, phase 3). A folder
    /// of no books offers none.
    func testAFolderOfBooksOffersExportInTheMacsWords() {
        XCTAssertEqual(
            PhoneLibraryOffer.folderCommands(offersDelete: true, bookCount: 12).map(\.action),
            [.renameFolder, .moveFolder, .exportFolder, .deleteFolder]
        )
        XCTAssertEqual(
            PhoneLibraryOffer.folderCommands(offersDelete: true, bookCount: 12).map(\.title),
            ["Rename Folder...", "Move Folder...", "Export 12 Books…", "Delete Folder..."]
        )
        XCTAssertEqual(PhoneLibraryOffer.folderCommands(offersDelete: false, bookCount: 1).last?.title, "Export…")
        XCTAssertFalse(PhoneLibraryOffer.folderCommands(offersDelete: true, bookCount: 0).contains { $0.action == .exportFolder })
        // The title is the Mac's own, for the count.
        XCTAssertEqual(PhoneLibraryOffer.folderCommands(offersDelete: false, bookCount: 3).last?.title, BookExportWording.commandTitle(count: 3))
    }

    /// Each command is offered once, so its action identifies it.
    func testNoCommandTwice() {
        let commands = PhoneLibraryOffer.bookCommands(
            for: PhoneLibraryFixture.book("Dune"),
            isInReadingList: false,
            moves: LibraryManualMoves(canMoveUp: true, canMoveDown: true),
            removal: PhoneLibraryFixture.phoneRemoval
        )
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
    }
}
