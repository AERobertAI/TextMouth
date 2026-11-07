import XCTest
@testable import TextMouth

/// `PhoneLibraryVocabulary`: each of the Mac's inline words the phone's
/// Library uses is read from the Mac's own view, word for word, so the two
/// apps can't drift apart unnoticed.
final class PhoneLibraryVocabularyTests: XCTestCase {
    /// The list's words are LibraryView's.
    func testTheListsWordsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.foldersHeader)\")"))
        XCTAssertTrue(macView.contains("prompt: \"\(PhoneLibraryVocabulary.searchPrompt)\""))
        XCTAssertTrue(macView.contains("Label(\"\(PhoneLibraryVocabulary.newFolderTitle)\", systemImage:"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"\(PhoneLibraryVocabulary.newFolderLabel)\")"))
        XCTAssertTrue(macView.contains("Label(\"\(PhoneLibraryVocabulary.sortTitle)\", systemImage:"))
        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.applySortToSubfolders)\")"))
    }

    /// A folder's commands are LibraryView's.
    func testAFoldersCommandsAreLibraryViews() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.renameFolder)\")"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.moveFolder)\")"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.deleteFolder)\", role: .destructive)"))
    }

    /// Book Info is the book row's own command, in LibrarySubviews.
    func testBookInfoIsTheRowsCommand() throws {
        let macView = try Self.source("Views/Library/LibrarySubviews.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.bookInfo)\")"))
    }

    /// The Continue row's visible title and hint are the Continue button's.
    func testTheContinueRowsWordsAreTheContinueButtons() throws {
        let macView = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(macView.contains("Text(\"\(PhoneLibraryVocabulary.continueVisiblePrefix)\\(lastBook.title)\")"))
        XCTAssertTrue(macView.contains(".accessibilityHint(\"\(PhoneLibraryVocabulary.continueHint)\")"))
    }

    /// Removal's Cancel is the Mac's Remove Book question's.
    func testRemovalsCancelIsTheMacs() throws {
        let macView = try Self.source("Views/ContentView.swift")

        XCTAssertTrue(macView.contains("Button(\"\(PhoneLibraryVocabulary.cancel)\", role: .cancel)"))
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
