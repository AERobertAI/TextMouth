import XCTest
@testable import TextMouth

/// `PhoneFolderVocabulary`: each word of the iPhone's folder sheets is read
/// from the Mac's own sheet, where it sits inline, so the two apps can't drift
/// apart. Each check builds the Mac's line from the phone's word, so a change
/// on either side fails it.
final class PhoneFolderVocabularyTests: XCTestCase {
    /// The Mac's folder sheets, `Views/Library/LibrarySheetViews.swift`.
    private static let sheetsPath = "Views/Library/LibrarySheetViews.swift"

    /// Checks one word: the phone's word is the Mac's static, and the Mac's
    /// source shows that static in the line `shown`, so a change on either
    /// side fails (FR34: the sheets say each word through a localized static).
    private func assertWord(_ phone: String, _ mac: String, shownIn source: String, as shown: String, line: UInt = #line) {
        XCTAssertEqual(phone, mac, shown, line: line)
        XCTAssertTrue(source.contains(shown), "The Mac no longer says \(shown)", line: line)
    }

    /// New Folder's words are the Mac's `NewFolderSheet`'s.
    func testNewFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        assertWord(PhoneFolderVocabulary.newFolderTitle, LibrarySheetWording.newFolderTitle, shownIn: mac,
                   as: "Text(LibrarySheetWording.newFolderTitle)")
        XCTAssertTrue(mac.contains(".navigationTitle(LibrarySheetWording.newFolderTitle)"))
        assertWord(PhoneFolderVocabulary.folderName, LibrarySheetWording.folderNameField, shownIn: mac,
                   as: "TextField(LibrarySheetWording.folderNameField, text: $folderName)")
        XCTAssertTrue(mac.contains(".accessibilityLabel(LibrarySheetWording.folderNameField)"))
        assertWord(PhoneFolderVocabulary.parentFolder, LibrarySheetWording.parentFolder, shownIn: mac,
                   as: "Picker(LibrarySheetWording.parentFolder, selection: $parentPath)")
        XCTAssertTrue(mac.contains(".accessibilityLabel(LibrarySheetWording.parentFolder)"))
        XCTAssertTrue(mac.contains("Button(LibraryWindowWording.cancel, action: onCancel)"))
        assertWord(PhoneFolderVocabulary.create, LibrarySheetWording.create, shownIn: mac,
                   as: "Button(LibrarySheetWording.create) {")
    }

    /// Rename Folder's words are the Mac's `RenameFolderSheet`'s.
    func testRenameFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        assertWord(PhoneFolderVocabulary.renameFolderTitle, LibrarySheetWording.renameFolderTitle, shownIn: mac,
                   as: "Text(LibrarySheetWording.renameFolderTitle)")
        XCTAssertTrue(mac.contains("TextField(LibrarySheetWording.folderNameField, text: $newName)"))
        assertWord(PhoneFolderVocabulary.newFolderName, LibrarySheetWording.newFolderNameLabel, shownIn: mac,
                   as: ".accessibilityLabel(LibrarySheetWording.newFolderNameLabel)")
        assertWord(PhoneFolderVocabulary.renamingFolder, LibrarySheetWording.renamingTheFolder, shownIn: mac,
                   as: "SheetWorkIndicator(label: LibrarySheetWording.renamingTheFolder)")
        assertWord(PhoneFolderVocabulary.rename, LibrarySheetWording.rename, shownIn: mac,
                   as: "Button(LibrarySheetWording.rename) {")
    }

    /// Move Folder's words are the Mac's `MoveFolderToParentSheet`'s, its
    /// heading naming the folder as the Mac's does.
    func testMoveFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("Text(LibrarySheetWording.moveTitle(folderName: folder.name))"))
        XCTAssertEqual(LibrarySheetWording.moveTitle(folderName: "Fiction"), "Move \"Fiction\"")
        XCTAssertEqual(PhoneFolderVocabulary.moveFolderTitle(folderName: "Fiction"), LibrarySheetWording.moveTitle(folderName: "Fiction"))
        assertWord(PhoneFolderVocabulary.newParentFolder, LibrarySheetWording.newParentFolder, shownIn: mac,
                   as: "Picker(LibrarySheetWording.newParentFolder, selection: $selectedParent)")
        assertWord(PhoneFolderVocabulary.destinationParentFolder, LibrarySheetWording.destinationParentFolder, shownIn: mac,
                   as: ".accessibilityLabel(LibrarySheetWording.destinationParentFolder)")
        assertWord(PhoneFolderVocabulary.movingFolder, LibrarySheetWording.movingTheFolder, shownIn: mac,
                   as: "SheetWorkIndicator(label: LibrarySheetWording.movingTheFolder)")
        assertWord(PhoneFolderVocabulary.move, LibrarySheetWording.move, shownIn: mac,
                   as: "Button(LibrarySheetWording.move) {")
    }

    /// Move to Folder's words are the Mac's `MoveFolderSheet`'s: its heading
    /// names one book and counts several, and its work says how many move.
    func testMoveToFolderSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("return LibrarySheetWording.moveTitle(bookTitle: book.title)"))
        XCTAssertTrue(mac.contains("return LibrarySheetWording.moveTitle(count: books.count)"))
        XCTAssertEqual(PhoneFolderVocabulary.moveBooksTitle(titles: ["Dune"]), "Move \"Dune\"")
        XCTAssertEqual(PhoneFolderVocabulary.moveBooksTitle(titles: ["Dune", "Emma", "Kim"]), "Move 3 Books")
        XCTAssertEqual(LibrarySheetWording.moveTitle(bookTitle: "Dune"), "Move \"Dune\"")
        XCTAssertEqual(LibrarySheetWording.moveTitle(count: 3), "Move 3 Books")
        assertWord(PhoneFolderVocabulary.destination, LibrarySheetWording.destinationCaption, shownIn: mac,
                   as: "caption: LibrarySheetWording.destinationCaption,")
        assertWord(PhoneFolderVocabulary.destinationFolder, LibrarySheetWording.destinationFolderLabel, shownIn: mac,
                   as: "accessibilityLabel: LibrarySheetWording.destinationFolderLabel,")
        XCTAssertTrue(mac.contains("SheetWorkIndicator(label: LibrarySheetWording.movingBooks(count: books.count))"))
        XCTAssertEqual(PhoneFolderVocabulary.movingBooks(count: 1), "Moving 1 book...")
        XCTAssertEqual(PhoneFolderVocabulary.movingBooks(count: 3), "Moving 3 books...")
        XCTAssertEqual(LibrarySheetWording.movingBooks(count: 1), "Moving 1 book...")
        XCTAssertEqual(LibrarySheetWording.movingBooks(count: 3), "Moving 3 books...")
    }

    /// Move to Folder's New Folder... has the Mac's folder picker's words.
    func testMoveToFoldersNewFolderSaysWhatTheMacsPickerSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        assertWord(PhoneFolderVocabulary.newFolderButton, LibrarySheetWording.newFolderButton, shownIn: mac,
                   as: "Button(LibrarySheetWording.newFolderButton) {")
        XCTAssertTrue(mac.contains("GroupBox(LibrarySheetWording.newFolderTitle) {"))
        XCTAssertTrue(mac.contains("TextField(LibrarySheetWording.folderNameField, text: $newFolderName)"))
        assertWord(PhoneFolderVocabulary.newFolderName, LibrarySheetWording.newFolderNameLabel, shownIn: mac,
                   as: ".accessibilityLabel(LibrarySheetWording.newFolderNameLabel)")
        XCTAssertTrue(mac.contains("Picker(LibrarySheetWording.parentFolder, selection: $newFolderParent)"))
        assertWord(PhoneFolderVocabulary.parentFolderForNewFolder, LibrarySheetWording.parentFolderForNewFolder, shownIn: mac,
                   as: ".accessibilityLabel(LibrarySheetWording.parentFolderForNewFolder)")
    }

    /// Delete Folder's question has the Mac's title and Move Contents Out, in
    /// the Library window, where the Mac asks it.
    func testDeleteFolderAsksWhatTheMacAsks() throws {
        let mac = try Self.source("Views/Library/LibraryView.swift")

        XCTAssertEqual(PhoneFolderVocabulary.deleteFolderTitle, LibraryListWording.deleteFolderQuestion)
        XCTAssertTrue(mac.contains("LibraryListWording.deleteFolderQuestion,\n            isPresented: $libraryViewModel.showDeleteFolderDialog"))
        assertWord(PhoneFolderVocabulary.moveContentsOut, LibraryListWording.moveContentsOut, shownIn: mac,
                   as: "Button(LibraryListWording.moveContentsOut) {")
        XCTAssertTrue(mac.contains("Button(LibraryWindowWording.cancel, role: .cancel) {\n                libraryViewModel.pendingDeleteFolder = nil"))
    }

    /// The Move Contents screen's words are the Mac's
    /// `DeleteFolderMoveContentsSheet`'s, each naming the folder as the Mac's do.
    func testMoveContentsSaysWhatTheMacsSheetSays() throws {
        let mac = try Self.source(Self.sheetsPath)

        XCTAssertTrue(mac.contains("Text(LibrarySheetWording.moveContentsTitle(folder.name))"))
        XCTAssertEqual(PhoneFolderVocabulary.moveContentsTitle(folderName: "Fiction"), LibrarySheetWording.moveContentsTitle("Fiction"))
        XCTAssertEqual(LibrarySheetWording.moveContentsTitle("Fiction"), "Move Contents of \"Fiction\"")
        XCTAssertTrue(mac.contains("Text(LibrarySheetWording.moveContentsExplanation(folder.name))"))
        XCTAssertEqual(
            PhoneFolderVocabulary.moveContentsExplanation(folderName: "Fiction"),
            LibrarySheetWording.moveContentsExplanation("Fiction")
        )
        XCTAssertEqual(
            LibrarySheetWording.moveContentsExplanation("Fiction"),
            "Choose where to move the books and subfolders before deleting \"Fiction\"."
        )
        assertWord(PhoneFolderVocabulary.moveContentsTo, LibrarySheetWording.moveContentsTo, shownIn: mac,
                   as: "Picker(LibrarySheetWording.moveContentsTo, selection: $selectedDestination)")
        assertWord(PhoneFolderVocabulary.destinationForContents, LibrarySheetWording.destinationForContents, shownIn: mac,
                   as: ".accessibilityLabel(LibrarySheetWording.destinationForContents)")
        assertWord(PhoneFolderVocabulary.movingContents, LibrarySheetWording.movingTheFoldersContents, shownIn: mac,
                   as: "SheetWorkIndicator(label: LibrarySheetWording.movingTheFoldersContents)")
        assertWord(PhoneFolderVocabulary.moveContentsAndDelete, LibrarySheetWording.moveContentsAndDelete, shownIn: mac,
                   as: "Button(LibrarySheetWording.moveContentsAndDelete) {")
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
