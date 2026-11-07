import XCTest
@testable import TextMouth

/// `PhoneFolderVocabulary`: each word of the iPhone's folder sheets is read
/// from the Mac's own sheet, where it sits inline, so the two apps can't drift
/// apart. Each check builds the Mac's line from the phone's word, so a change
/// on either side fails it.
final class PhoneFolderVocabularyTests: XCTestCase {
    /// The Mac's folder sheets, `Views/Library/LibrarySheetViews.swift`.
    private static let sheetsPath = "Views/Library/LibrarySheetViews.swift"

    /// New Folder's words are the Mac's `NewFolderSheet`'s.
    func testNewFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("Text(\"\(PhoneFolderVocabulary.newFolderTitle)\")"))
        XCTAssertTrue(mac.contains(".navigationTitle(\"\(PhoneFolderVocabulary.newFolderTitle)\")"))
        XCTAssertTrue(mac.contains("TextField(\"\(PhoneFolderVocabulary.folderName)\", text: $folderName)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.folderName)\")"))
        XCTAssertTrue(mac.contains("Picker(\"\(PhoneFolderVocabulary.parentFolder)\", selection: $parentPath)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.parentFolder)\")"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.cancel)\", action: onCancel)"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.create)\") {"))
    }

    /// Rename Folder's words are the Mac's `RenameFolderSheet`'s.
    func testRenameFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("Text(\"\(PhoneFolderVocabulary.renameFolderTitle)\")"))
        XCTAssertTrue(mac.contains("TextField(\"\(PhoneFolderVocabulary.folderName)\", text: $newName)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.newFolderName)\")"))
        XCTAssertTrue(mac.contains("SheetWorkIndicator(label: \"\(PhoneFolderVocabulary.renamingFolder)\")"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.rename)\") {"))
    }

    /// Move Folder's words are the Mac's `MoveFolderToParentSheet`'s, its
    /// heading naming the folder as the Mac's does.
    func testMoveFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains(#"Text("Move \"\(folder.name)\"")"#))
        XCTAssertEqual(PhoneFolderVocabulary.moveFolderTitle(folderName: "Fiction"), "Move \"Fiction\"")
        XCTAssertTrue(mac.contains("Picker(\"\(PhoneFolderVocabulary.newParentFolder)\", selection: $selectedParent)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.destinationParentFolder)\")"))
        XCTAssertTrue(mac.contains("SheetWorkIndicator(label: \"\(PhoneFolderVocabulary.movingFolder)\")"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.move)\") {"))
    }

    /// Move to Folder's words are the Mac's `MoveFolderSheet`'s: its heading
    /// names one book and counts several, and its work says how many move.
    func testMoveToFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains(#"return "Move \"\(book.title)\"""#))
        XCTAssertTrue(mac.contains(#"return "Move \(books.count) Books""#))
        XCTAssertEqual(PhoneFolderVocabulary.moveBooksTitle(titles: ["Dune"]), "Move \"Dune\"")
        XCTAssertEqual(PhoneFolderVocabulary.moveBooksTitle(titles: ["Dune", "Emma", "Kim"]), "Move 3 Books")
        XCTAssertTrue(mac.contains("caption: \"\(PhoneFolderVocabulary.destination)\","))
        XCTAssertTrue(mac.contains("accessibilityLabel: \"\(PhoneFolderVocabulary.destinationFolder)\","))
        XCTAssertTrue(mac.contains(#"SheetWorkIndicator(label: "Moving \(CountWording.books(books.count))...")"#))
        XCTAssertEqual(PhoneFolderVocabulary.movingBooks(count: 1), "Moving 1 book...")
        XCTAssertEqual(PhoneFolderVocabulary.movingBooks(count: 3), "Moving 3 books...")
    }

    /// Move to Folder's New Folder... has the Mac's folder picker's words.
    func testMoveToFoldersNewFolderSaysWhatTheMacsPickerSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.newFolderButton)\") {"))
        XCTAssertTrue(mac.contains("GroupBox(\"\(PhoneFolderVocabulary.newFolderTitle)\") {"))
        XCTAssertTrue(mac.contains("TextField(\"\(PhoneFolderVocabulary.folderName)\", text: $newFolderName)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.newFolderName)\")"))
        XCTAssertTrue(mac.contains("Picker(\"\(PhoneFolderVocabulary.parentFolder)\", selection: $newFolderParent)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.parentFolderForNewFolder)\")"))
    }

    /// Delete Folder's question has the Mac's title and Move Contents Out, in
    /// the Library window, where the Mac asks it.
    func testDeleteFolderAsksWhatTheMacAsks() throws {
        let mac = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertTrue(mac.contains("\"\(PhoneFolderVocabulary.deleteFolderTitle)\",\n            isPresented: $libraryViewModel.showDeleteFolderDialog"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.moveContentsOut)\") {"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.cancel)\", role: .cancel) {\n                libraryViewModel.pendingDeleteFolder = nil"))
    }

    /// The Move Contents screen's words are the Mac's
    /// `DeleteFolderMoveContentsSheet`'s, each naming the folder as the Mac's do.
    func testMoveContentsSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains(#"Text("Move Contents of \"\(folder.name)\"")"#))
        XCTAssertEqual(PhoneFolderVocabulary.moveContentsTitle(folderName: "Fiction"), "Move Contents of \"Fiction\"")
        XCTAssertTrue(mac.contains(#"Text("Choose where to move the books and subfolders before deleting \"\(folder.name)\".")"#))
        XCTAssertEqual(
            PhoneFolderVocabulary.moveContentsExplanation(folderName: "Fiction"),
            "Choose where to move the books and subfolders before deleting \"Fiction\"."
        )
        XCTAssertTrue(mac.contains("Picker(\"\(PhoneFolderVocabulary.moveContentsTo)\", selection: $selectedDestination)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"\(PhoneFolderVocabulary.destinationForContents)\")"))
        XCTAssertTrue(mac.contains("SheetWorkIndicator(label: \"\(PhoneFolderVocabulary.movingContents)\")"))
        XCTAssertTrue(mac.contains("Button(\"\(PhoneFolderVocabulary.moveContentsAndDelete)\") {"))
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
