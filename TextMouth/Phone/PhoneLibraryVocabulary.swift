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

    // MARK: Book Info (the Mac's LibrarySheetViews, and its reader's words)

    /// The sheet's title, a heading.
    static let bookInformation = "Book Information"
    /// The title field's visible label.
    static let titleField = "Title"
    /// The title field's spoken label, before "edited by hand".
    static let titleFieldLabel = "Book title"
    /// The author field's visible label.
    static let authorField = "Author"
    /// The author field's spoken label, before "edited by hand".
    static let authorFieldLabel = "Book author"
    /// The read-only row of the book's format.
    static let formatRow = "Format"
    /// The read-only row of the day the book was added.
    static let addedRow = "Added"
    /// The read-only row of the day the book was last opened.
    static let lastOpenedRow = "Last Opened"
    /// The read-only row of the book's word count.
    static let wordCountRow = "Word Count"
    /// The button that saves the sheet.
    static let save = "Save"
    /// What VoiceOver says once Book Info is saved (the Mac's reader's).
    static let metadataUpdated = "Metadata updated"

    // MARK: Book Info of an EPUB or an Audiobook (the Mac's MetadataEditorView)

    /// An EPUB's publisher field, its visible name and spoken label.
    static let publisherField = "Publisher"
    /// An EPUB's publication date field's visible name.
    static let publicationDateField = "Publication Date"
    /// An EPUB's publication date field's spoken label.
    static let publicationDateFieldLabel = "Publication date"
    /// An EPUB's read-only row of its ISBN.
    static let isbnRow = "ISBN"
    /// An EPUB's read-only row of its language.
    static let languageRow = "Language"
    /// An EPUB's read-only row of its identifier.
    static let identifierRow = "Identifier"
    /// An EPUB's read-only row of its EPUB version.
    static let epubVersionRow = "EPUB Version"
    /// An audiobook's artist field's visible name.
    static let artistField = "Artist"
    /// An audiobook's artist field's spoken label.
    static let artistFieldLabel = "Artist or narrator"
    /// An audiobook's album field's visible name.
    static let albumField = "Album"
    /// An audiobook's album field's spoken label.
    static let albumFieldLabel = "Album name"
    /// An audiobook's genre field, its visible name and spoken label.
    static let genreField = "Genre"
    /// An audiobook's year field, its visible name and spoken label.
    static let yearField = "Year"
    /// An audiobook's read-only row of its duration.
    static let durationRow = "Duration"

    // MARK: Removing a Book (the Mac's ContentView)

    /// The removal question's button that removes nothing.
    static let cancel = "Cancel"
}
