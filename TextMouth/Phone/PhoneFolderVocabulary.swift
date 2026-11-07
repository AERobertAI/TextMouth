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
    // MARK: Every Sheet

    /// The button that closes a sheet with nothing changed.
    static let cancel = "Cancel"

    // MARK: New Folder (the Mac's `NewFolderSheet`)

    /// The New Folder sheet's title.
    static let newFolderTitle = "New Folder"
    /// The new folder's name field: its placeholder and its spoken label.
    static let folderName = "Folder name"
    /// The row choosing the folder the new one goes in: its caption and its
    /// spoken label.
    static let parentFolder = "Parent folder"
    /// The button that makes the folder.
    static let create = "Create"

    // MARK: Rename Folder (the Mac's `RenameFolderSheet`)

    /// The Rename Folder sheet's title.
    static let renameFolderTitle = "Rename Folder"
    /// The rename field's spoken label. Its placeholder is `folderName`.
    static let newFolderName = "New folder name"
    /// What the sheet says while the folder is renamed.
    static let renamingFolder = "Renaming the folder..."
    /// The button that renames the folder.
    static let rename = "Rename"

    // MARK: Move Folder (the Mac's `MoveFolderToParentSheet`)

    /// The Move Folder sheet's title, naming the folder: "Move "Fiction"".
    static func moveFolderTitle(folderName: String) -> String {
        "Move \"\(folderName)\""
    }

    /// The row choosing the folder's new parent: its caption.
    static let newParentFolder = "New parent folder"
    /// That row's spoken label.
    static let destinationParentFolder = "Destination parent folder"
    /// What the sheet says while the folder moves.
    static let movingFolder = "Moving the folder..."
    /// The button that moves, in Move Folder and in Move to Folder.
    static let move = "Move"

    // MARK: Move to Folder (the Mac's `MoveFolderSheet`)

    /// The Move to Folder sheet's title: "Move "Dune"" for one book, and
    /// "Move 3 Books" for several, as the Mac's sheet heads itself.
    static func moveBooksTitle(titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return "Move \"\(title)\""
        }
        return "Move \(titles.count) Books"
    }

    /// The row choosing where the books go: its caption.
    static let destination = "Destination"
    /// That row's spoken label.
    static let destinationFolder = "Destination folder"

    /// What the sheet says while the books move: "Moving 3 books...".
    static func movingBooks(count: Int) -> String {
        "Moving \(CountWording.books(count))..."
    }

    // MARK: Delete Folder (the Mac's question in `LibraryView`)

    /// The Delete Folder question's title.
    static let deleteFolderTitle = "Delete Folder?"
    /// The choice that keeps the folder's contents, moving them out first.
    static let moveContentsOut = "Move Contents Out"

    // MARK: Move Contents (the Mac's `DeleteFolderMoveContentsSheet`)

    /// The Move Contents screen's title, naming the folder: "Move Contents of
    /// "Fiction"".
    static func moveContentsTitle(folderName: String) -> String {
        "Move Contents of \"\(folderName)\""
    }

    /// What the Move Contents screen is for, naming the folder.
    static func moveContentsExplanation(folderName: String) -> String {
        "Choose where to move the books and subfolders before deleting \"\(folderName)\"."
    }

    /// The row choosing where the contents go: its caption.
    static let moveContentsTo = "Move contents to"
    /// That row's spoken label.
    static let destinationForContents = "Destination for folder contents"
    /// What the screen says while the contents move.
    static let movingContents = "Moving the folder's contents..."
    /// The button that moves the contents, then deletes the folder.
    static let moveContentsAndDelete = "Move Contents & Delete Folder"
}
