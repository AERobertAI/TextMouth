import XCTest
@testable import TextMouth

/// Removal wording says exactly what happens to the files in each mode:
/// kept in the library folder, moved to the Trash, or deleted permanently,
/// for one book or several, and the words VoiceOver speaks agree with the
/// words on screen (TODO A08).
final class RemovalWordingTests: XCTestCase {
    // MARK: - Modes

    /// The Trash preference chooses the deleting mode.
    func testTrashPreferenceChoosesTheDeletingMode() {
        XCTAssertEqual(RemovalMode.deleting(movesToTrash: true), .moveToTrash)
        XCTAssertEqual(RemovalMode.deleting(movesToTrash: false), .deletePermanently)
        XCTAssertEqual(RemovalPreferences(confirmsFirst: true, movesToTrash: false).deletionMode, .deletePermanently)
    }

    /// The preferences come from config.json's two removal fields.
    func testPreferencesReadConfigFields() {
        var config = ConfigService.AppConfig()
        config.confirmBeforeDelete = false
        config.moveToTrashInsteadOfDeleting = true

        XCTAssertEqual(RemovalPreferences(config), RemovalPreferences(confirmsFirst: false, movesToTrash: true))
    }

    // MARK: - One Book

    /// Every word about removing one book names it and says what happens to
    /// its files.
    func testWordingForOneBookInEachMode() {
        let trash = RemovalWording(.moveToTrash, count: 1, title: "Field Notes")
        XCTAssertEqual(trash.buttonTitle, "Move to Trash")
        XCTAssertEqual(trash.accessibilityLabel, "Move “Field Notes” to the Trash")
        XCTAssertEqual(trash.selectionButtonTitle, "Move 1 Selected to Trash")
        XCTAssertEqual(trash.selectionAccessibilityLabel, "Move 1 selected book to the Trash")
        XCTAssertEqual(trash.confirmationTitle, "Move Book to Trash?")
        XCTAssertEqual(
            trash.confirmationMessage,
            "“Field Notes” will be removed from the library. Its files go to the Trash, "
                + "where you can recover them until the Trash is emptied."
        )
        XCTAssertEqual(trash.completionMessage, "Moved “Field Notes” to the Trash.")

        let permanent = RemovalWording(.deletePermanently, count: 1, title: "Field Notes")
        XCTAssertEqual(permanent.buttonTitle, "Delete Permanently")
        XCTAssertEqual(permanent.accessibilityLabel, "Delete “Field Notes” permanently")
        XCTAssertEqual(permanent.confirmationTitle, "Delete Book Permanently?")
        XCTAssertEqual(
            permanent.confirmationMessage,
            "“Field Notes” will be removed from the library. Its files are deleted permanently and cannot be recovered."
        )
        XCTAssertEqual(permanent.completionMessage, "Deleted “Field Notes” permanently.")

        let keep = RemovalWording(.keepFiles, count: 1, title: "Field Notes")
        XCTAssertEqual(keep.buttonTitle, "Remove from Library Only")
        XCTAssertEqual(keep.accessibilityLabel, "Remove “Field Notes” from the library and keep the files")
        XCTAssertEqual(
            keep.completionMessage,
            "Removed “Field Notes” from the library. Its files stay in the TextMouth library folder."
        )
    }

    // MARK: - Several Books

    /// Words about several books count them and speak of their files.
    func testWordingForSeveralBooksInEachMode() {
        let trash = RemovalWording(.moveToTrash, count: 3, title: "Ignored for several")
        XCTAssertNil(trash.title)
        XCTAssertEqual(trash.subject, "3 books")
        XCTAssertEqual(trash.buttonTitle, "Move 3 Books to Trash")
        XCTAssertEqual(trash.accessibilityLabel, "Move 3 books to the Trash")
        XCTAssertEqual(trash.selectionButtonTitle, "Move 3 Selected to Trash")
        XCTAssertEqual(trash.selectionAccessibilityLabel, "Move 3 selected books to the Trash")
        XCTAssertEqual(trash.confirmationTitle, "Move 3 Books to Trash?")
        XCTAssertEqual(
            trash.confirmationMessage,
            "3 books will be removed from the library. Their files go to the Trash, "
                + "where you can recover them until the Trash is emptied."
        )
        XCTAssertEqual(trash.completionMessage, "Moved 3 books to the Trash.")

        let permanent = RemovalWording(.deletePermanently, count: 2)
        XCTAssertEqual(permanent.selectionButtonTitle, "Delete 2 Selected Permanently")
        XCTAssertEqual(permanent.selectionAccessibilityLabel, "Delete 2 selected books permanently")
        XCTAssertEqual(permanent.confirmationTitle, "Delete 2 Books Permanently?")
        XCTAssertEqual(permanent.completionMessage, "Deleted 2 books permanently.")

        let keep = RemovalWording(.keepFiles, count: 4)
        XCTAssertEqual(keep.buttonTitle, "Remove 4 Books from Library Only")
        XCTAssertEqual(
            keep.completionMessage,
            "Removed 4 books from the library. Their files stay in the TextMouth library folder."
        )
    }

    /// Words built from books name the one book, or count several.
    func testWordingBuiltFromBooks() {
        XCTAssertEqual(RemovalWording(.moveToTrash, books: [book("Tide Tables")]).subject, "“Tide Tables”")
        XCTAssertEqual(RemovalWording(.moveToTrash, books: [book("A"), book("B")]).subject, "2 books")
    }

    // MARK: - Failures

    /// A failure lists each book that stayed, under a heading that says
    /// what could not be done and agrees in number.
    func testFailureMessagesSayWhatCouldNotBeDone() {
        XCTAssertEqual(
            RemovalMode.moveToTrash.failureMessage(["Atlas: The volume has no Trash."]),
            "This book could not be moved to the Trash and remains in the library:\nAtlas: The volume has no Trash."
        )
        XCTAssertEqual(
            RemovalMode.deletePermanently.failureMessage(["Atlas: Permission denied.", "Bestiary: Permission denied."]),
            "These books could not be deleted and remain in the library:\n"
                + "Atlas: Permission denied.\nBestiary: Permission denied."
        )
        XCTAssertEqual(
            RemovalMode.keepFiles.failureHeading(count: 1, noun: "book"),
            "This book could not be removed from the library and remains in it:"
        )
        XCTAssertEqual(
            RemovalMode.keepFiles.failureHeading(count: 2, noun: "book"),
            "These books could not be removed from the library and remain in it:"
        )
    }

    // MARK: - The Library's Choice

    /// The library's confirmation offers the deleting mode the Trash
    /// preference chooses beside Remove from Library Only, and explains
    /// both.
    func testChoiceWordingForTheLibraryConfirmation() {
        let trash = RemovalChoiceWording(books: [book("Field Notes")], movesToTrash: true)
        XCTAssertEqual(trash.title, "Remove Book?")
        XCTAssertEqual(trash.deleteButtonTitle, "Move to Trash")
        XCTAssertEqual(trash.keepButtonTitle, "Remove from Library Only")
        XCTAssertEqual(
            trash.message,
            "Choose how to remove “Field Notes” from the library. "
                + "With Move to Trash, its files go to the Trash, where you can recover them until the Trash is emptied. "
                + "With Remove from Library Only, its files stay in the TextMouth library folder."
        )

        let permanent = RemovalChoiceWording(books: [book("A"), book("B")], movesToTrash: false)
        XCTAssertEqual(permanent.title, "Remove 2 Books?")
        XCTAssertEqual(permanent.deleteButtonTitle, "Delete Permanently")
        XCTAssertEqual(
            permanent.message,
            "Choose how to remove 2 books from the library. "
                + "With Delete Permanently, their files are deleted permanently and cannot be recovered. "
                + "With Remove from Library Only, their files stay in the TextMouth library folder."
        )
    }

    // MARK: - Deleting a Folder

    /// Delete Everything says whether the folder's files go to the Trash or
    /// are deleted permanently, in both dialogs and in a failure.
    func testFolderWordingInEachDeletingMode() {
        let trash = FolderRemovalWording(mode: .moveToTrash, folderName: "Fiction", bookCount: 3)
        XCTAssertEqual(trash.buttonTitle, "Move Everything to Trash")
        XCTAssertEqual(
            trash.choiceMessage,
            "“Fiction” contains 3 books and may have subfolders. "
                + "With Move Contents Out, they stay in the library and only the folder is deleted. "
                + "With Move Everything to Trash, the folder and everything in it leave the library, "
                + "and their files go to the Trash, where you can recover them until the Trash is emptied."
        )
        XCTAssertEqual(trash.confirmationTitle, "Move Everything in “Fiction” to Trash?")
        XCTAssertEqual(
            trash.confirmationMessage,
            "“Fiction”, any subfolders, and the 3 books inside will be removed from the library. "
                + "Their files go to the Trash, where you can recover them until the Trash is emptied."
        )
        XCTAssertEqual(
            trash.failureMessage(["Atlas: The volume has no Trash."]),
            "This item could not be moved to the Trash and remains in the library:\nAtlas: The volume has no Trash."
        )

        let permanent = FolderRemovalWording(mode: .deletePermanently, folderName: "Fiction", bookCount: 1)
        XCTAssertEqual(permanent.buttonTitle, "Delete Everything Permanently")
        XCTAssertEqual(permanent.confirmationTitle, "Delete Everything in “Fiction” Permanently?")
        XCTAssertEqual(
            permanent.confirmationMessage,
            "“Fiction”, any subfolders, and the book inside will be removed from the library. "
                + "Their files are deleted permanently and cannot be recovered."
        )
        XCTAssertTrue(permanent.choiceMessage.hasPrefix("“Fiction” contains 1 book and may have subfolders."))
        XCTAssertEqual(
            FolderRemovalWording(mode: .deletePermanently, folderName: "Empty Shelf", bookCount: 0).confirmationMessage,
            "“Empty Shelf” and any subfolders will be removed from the library. "
                + "Their files are deleted permanently and cannot be recovered."
        )
        XCTAssertEqual(
            permanent.failureMessage(["Atlas: Permission denied.", "Fiction: Permission denied."]),
            "These items could not be deleted and remain in the library:\n"
                + "Atlas: Permission denied.\nFiction: Permission denied."
        )
    }

    // MARK: - Spoken and Visible Agree

    /// For every mode and count, the button VoiceOver hears starts with the
    /// same verb as the button on screen and names the same place for the
    /// files, so neither can promise something the other does not.
    func testSpokenAndVisibleWordsAgreeInEveryModeAndCount() {
        for mode in RemovalMode.allCases {
            for count in [1, 2, 12] {
                let wording = RemovalWording(mode, count: count, title: count == 1 ? "Solo" : nil)
                let pairs = [
                    (wording.buttonTitle, wording.accessibilityLabel),
                    (wording.selectionButtonTitle, wording.selectionAccessibilityLabel),
                ]
                for (visible, spoken) in pairs {
                    XCTAssertEqual(firstWord(visible), firstWord(spoken), "\(mode) \(count): \(visible) / \(spoken)")
                    let destination = destinationWord(for: mode)
                    XCTAssertTrue(visible.lowercased().contains(destination), visible)
                    XCTAssertTrue(spoken.lowercased().contains(destination), spoken)
                }
                XCTAssertTrue(
                    wording.confirmationMessage.contains(mode.filesSentence(plural: count != 1)),
                    "the confirmation says what happens to the files"
                )
            }
        }
    }

    // MARK: - Helpers

    /// A book record for wording tests; nothing is written to disk.
    private func book(_ title: String) -> Book {
        Book(title: title, format: .txt, filePath: "/tmp/\(UUID().uuidString).txt", md5Hash: UUID().uuidString)
    }

    /// The first word of `text`.
    private func firstWord(_ text: String) -> String {
        String(text.split(separator: " ").first ?? "")
    }

    /// The word that tells where a mode's files end up.
    private func destinationWord(for mode: RemovalMode) -> String {
        switch mode {
        case .keepFiles: return "library"
        case .moveToTrash: return "trash"
        case .deletePermanently: return "permanently"
        }
    }
}
