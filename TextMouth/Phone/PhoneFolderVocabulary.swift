import Foundation

/// The words of the iPhone's five folder sheets: New Folder, Rename Folder,
/// Move Folder, Move to Folder, and Delete Folder with its Move Contents
/// choice (the iPhone interface spec, "Folder sheets").
///
/// Each is the Mac's word, which sits inline in a Mac view
/// (`Views/Library/LibrarySheetViews.swift`, and the Delete Folder question in
/// `Views/Library/LibraryView.swift`), held here for the phone, since the Mac's
/// sheets can't be shown on a phone and the Mac's views stay as they are.
/// `PhoneFolderVocabularyTests` reads those Mac sources and requires each word
/// to be there word for word, so the two apps can't drift apart unnoticed.
///
/// The Mac's words that are shared already are called where they live, never
/// copied here: "Library Root" (`LibraryFolderOption.rootLabel`), "Folder Q3
/// created in Reports." (`NewFolderSheet.createdAnnouncement`), "Error: " and
/// the reason (`OperationFailureNotice`), and every word of Delete Everything
/// (`FolderRemovalWording`).
///
/// The folder row's commands ("Rename Folder...", "Move Folder...", "Delete
/// Folder...") and New Folder's button ("Create new folder") are the Library's
/// controls, so they belong to the Library's vocabulary, not this one.
enum PhoneFolderVocabulary {
    // MARK: New Folder (the Mac's `NewFolderSheet`)

    /// New Folder's title: the sheet's, and the Library's menu item's.
    static var newFolderTitle: String { LibrarySheetWording.newFolderTitle }
    /// The new folder's name field: its placeholder and its spoken label.
    static var folderName: String { LibrarySheetWording.folderNameField }
    /// The row choosing the folder the new one goes in: its caption and its
    /// spoken label.
    static var parentFolder: String { LibrarySheetWording.parentFolder }
    /// The button that makes the folder.
    static var create: String { LibrarySheetWording.create }

    // MARK: Rename Folder (the Mac's `RenameFolderSheet`)

    /// The Rename Folder sheet's title.
    static var renameFolderTitle: String { LibrarySheetWording.renameFolderTitle }
    /// The rename field's spoken label. Its placeholder is `folderName`.
    static var newFolderName: String { LibrarySheetWording.newFolderNameLabel }
    /// What the sheet says while the folder is renamed.
    static var renamingFolder: String { LibrarySheetWording.renamingTheFolder }
    /// The button that renames the folder.
    static var rename: String { LibrarySheetWording.rename }

    // MARK: Move Folder (the Mac's `MoveFolderToParentSheet`)

    /// The Move Folder sheet's title, naming the folder: "Move "Fiction"".
    static func moveFolderTitle(folderName: String) -> String {
        LibrarySheetWording.moveTitle(folderName: folderName)
    }

    /// The row choosing the folder's new parent: its caption.
    static var newParentFolder: String { LibrarySheetWording.newParentFolder }
    /// That row's spoken label.
    static var destinationParentFolder: String { LibrarySheetWording.destinationParentFolder }
    /// What the sheet says while the folder moves.
    static var movingFolder: String { LibrarySheetWording.movingTheFolder }
    /// The button that moves, in Move Folder and in Move to Folder.
    static var move: String { LibrarySheetWording.move }

    // MARK: Move to Folder (the Mac's `MoveFolderSheet`)

    /// The Move to Folder sheet's title: "Move "Dune"" for one book, and
    /// "Move 3 Books" for several, as the Mac's sheet heads itself.
    static func moveBooksTitle(titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return LibrarySheetWording.moveTitle(bookTitle: title)
        }
        return LibrarySheetWording.moveTitle(count: titles.count)
    }

    /// The row choosing where the books go: its caption.
    static var destination: String { LibrarySheetWording.destinationCaption }
    /// That row's spoken label.
    static var destinationFolder: String { LibrarySheetWording.destinationFolderLabel }

    /// What the sheet says while the books move: "Moving 3 books...".
    static func movingBooks(count: Int) -> String {
        LibrarySheetWording.movingBooks(count: count)
    }

    // MARK: Move to Folder's New Folder... (the Mac's `LibraryFolderPicker`)

    /// The button that makes a folder to move the books into. Its sheet is
    /// titled `newFolderTitle`, its name field is labelled `newFolderName`,
    /// and its Cancel is the Mac's `LibraryFolderPicker.cancelNewFolderTitle`.
    static var newFolderButton: String { LibrarySheetWording.newFolderButton }
    /// The spoken label of the row choosing the new folder's parent, whose
    /// caption is `parentFolder`.
    static var parentFolderForNewFolder: String { LibrarySheetWording.parentFolderForNewFolder }

    // MARK: Delete Folder (the Mac's question in `LibraryView`)

    /// The Delete Folder question's title.
    static var deleteFolderTitle: String { LibraryListWording.deleteFolderQuestion }
    /// The choice that keeps the folder's contents, moving them out first.
    static var moveContentsOut: String { LibraryListWording.moveContentsOut }

    // MARK: Move Contents (the Mac's `DeleteFolderMoveContentsSheet`)

    /// The Move Contents screen's title, naming the folder: "Move Contents of
    /// "Fiction"".
    static func moveContentsTitle(folderName: String) -> String {
        LibrarySheetWording.moveContentsTitle(folderName)
    }

    /// What the Move Contents screen is for, naming the folder.
    static func moveContentsExplanation(folderName: String) -> String {
        LibrarySheetWording.moveContentsExplanation(folderName)
    }

    /// The row choosing where the contents go: its caption.
    static var moveContentsTo: String { LibrarySheetWording.moveContentsTo }
    /// That row's spoken label.
    static var destinationForContents: String { LibrarySheetWording.destinationForContents }
    /// What the screen says while the contents move.
    static var movingContents: String { LibrarySheetWording.movingTheFoldersContents }
    /// The button that moves the contents, then deletes the folder.
    static var moveContentsAndDelete: String { LibrarySheetWording.moveContentsAndDelete }
}
