import XCTest
@testable import TextMouth

/// `PhoneLibraryOffer`: which commands a Library row has, in the spec's order,
/// under the Mac's names.
@MainActor
final class PhoneLibraryOfferTests: XCTestCase {
    /// A book outside the reading list, in no arranged order, offers Book
    /// Info, Add to Reading List, Move to Folder..., and the removal, in that
    /// order, each by the Mac's name.
    func testABooksCommandsInOrder() {
        let commands = PhoneLibraryOffer.bookCommands(
            for: PhoneLibraryFixture.book("Dune"),
            isInReadingList: false,
            moves: nil,
            removal: PhoneLibraryFixture.phoneRemoval
        )

        XCTAssertEqual(commands.map(\.action), [.bookInfo, .addToReadingList, .moveToFolder, .remove])
        XCTAssertEqual(commands.map(\.title), ["Book Info", "Add to Reading List", "Move to Folder...", "Remove from Library..."])
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
            ["Book Info", "Remove from Reading List", "Move to Folder...", "Move Up", "Move Down", "Remove from Library..."]
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

    /// A folder offers Rename, Move, and Delete where the Mac offers Delete.
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
