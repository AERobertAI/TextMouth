import Foundation

/// The Mac's words that sit inline in its Library views, held here for the
/// iPhone's Library, whose views are its own (the iPhone interface spec, "One
/// vocabulary"). The Mac's views stay as they are: `PhoneLibraryVocabularyTests`
/// reads each Mac source file and requires every word here to be there, word
/// for word, so the two apps can't drift apart unnoticed.
///
/// Words the Mac keeps in shared wording types aren't here: those are called
/// where they're used, never copied.
enum PhoneLibraryVocabulary {
    // MARK: The List (the Mac's LibraryView)

    /// The heading of the folders' section.
    static let foldersHeader = "Folders"
    /// The search field's prompt.
    static let searchPrompt = "Search books"
    /// New Folder's visible title.
    static let newFolderTitle = "New Folder"
    /// New Folder's spoken label.
    static let newFolderLabel = "Create new folder"
    /// Sort's visible title.
    static let sortTitle = "Sort"
    /// The Sort choice that gives every subfolder this folder's sort.
    static let applySortToSubfolders = "Apply Sort to All Subfolders"

    // MARK: A Folder's Commands (the Mac's LibraryView)

    /// Renames the folder.
    static let renameFolder = "Rename Folder..."
    /// Moves the folder into another.
    static let moveFolder = "Move Folder..."
    /// Deletes the folder.
    static let deleteFolder = "Delete Folder..."

    // MARK: A Book's Commands (the Mac's LibrarySubviews)

    /// Opens the book's Book Info.
    static let bookInfo = "Book Info"

    // MARK: The Continue Row (the Mac's LibraryView)

    /// What the Continue row shows before the book's title, for sight.
    static let continueVisiblePrefix = "Continue: "
    /// What the Continue row does.
    static let continueHint = "Opens the last book you were reading"

    // MARK: Removing a Book (the Mac's ContentView)

    /// The removal question's button that removes nothing.
    static let cancel = "Cancel"
}
