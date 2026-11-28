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
    static var foldersHeader: String { LibraryListWording.foldersHeader }
    /// The search field's prompt.
    static var searchPrompt: String { LibraryListWording.searchPrompt }
    /// New Folder's spoken label.
    static var newFolderLabel: String { LibraryListWording.createNewFolder }
    /// Sort's visible title.
    static var sortTitle: String { LibraryListWording.sort }
    /// The Sort choice that gives every subfolder this folder's sort.
    static var applySortToSubfolders: String { LibraryListWording.applySortToSubfolders }

    // MARK: A Folder's Commands (the Mac's LibraryView)

    /// Renames the folder.
    static var renameFolder: String { LibraryListWording.renameFolder }
    /// Moves the folder into another.
    static var moveFolder: String { LibraryListWording.moveFolder }
    /// Deletes the folder.
    static var deleteFolder: String { LibraryListWording.deleteFolder }

    // MARK: A Book's Commands (the Mac's LibrarySubviews)

    /// Opens the book's Book Info.
    static var bookInfo: String { LibrarySubviewWording.bookInfo }

    // MARK: The Continue Row (the Mac's LibraryView)

    /// What the Continue row shows for sight: "Continue: " and the book's title.
    static func continueVisible(_ title: String) -> String { LibraryListWording.continueVisible(title) }
    /// What the Continue row does.
    static var continueHint: String { LibraryListWording.continueHint }

    // MARK: Book Info (the Mac's LibrarySheetViews, and its reader's words)

    /// The sheet's title, a heading.
    static var bookInformation: String { LibrarySheetWording.bookInformation }
    /// The title field's visible label.
    static var titleField: String { MetadataEditorWording.titleField }
    /// The title field's spoken label, before "edited by hand".
    static var titleFieldLabel: String { MetadataEditorWording.bookTitleLabel }
    /// The author field's visible label.
    static var authorField: String { MetadataEditorWording.authorField }
    /// The author field's spoken label, before "edited by hand".
    static var authorFieldLabel: String { LibrarySheetWording.bookAuthorLabel }
    /// The read-only row of the book's format.
    static var formatRow: String { MetadataEditorWording.formatRow }
    /// The read-only row of the day the book was added.
    static var addedRow: String { LibrarySheetWording.addedRow }
    /// The read-only row of the day the book was last opened.
    static var lastOpenedRow: String { LibrarySheetWording.lastOpenedRow }
    /// The read-only row of the book's word count.
    static var wordCountRow: String { LibrarySheetWording.wordCountRow }
    /// What VoiceOver says once Book Info is saved: the Mac's reader's own
    /// localized static, read here rather than copied (FR35).
    static var metadataUpdated: String { ReaderViewModel.metadataUpdatedAnnouncement }

    // MARK: Book Info of an EPUB or an Audiobook (the Mac's MetadataEditorView)

    /// An EPUB's publisher field, its visible name and spoken label.
    static var publisherField: String { MetadataEditorWording.publisherField }
    /// An EPUB's publication date field's visible name.
    static var publicationDateField: String { MetadataEditorWording.publicationDateField }
    /// An EPUB's publication date field's spoken label.
    static var publicationDateFieldLabel: String { MetadataEditorWording.publicationDateLabel }
    /// An EPUB's read-only row of its ISBN.
    static var isbnRow: String { MetadataEditorWording.isbnRow }
    /// An EPUB's read-only row of its language.
    static var languageRow: String { MetadataEditorWording.languageRow }
    /// An EPUB's read-only row of its identifier.
    static var identifierRow: String { MetadataEditorWording.identifierRow }
    /// An EPUB's read-only row of its EPUB version.
    static var epubVersionRow: String { MetadataEditorWording.epubVersionRow }
    /// An audiobook's artist field's visible name.
    static var artistField: String { MetadataEditorWording.artistField }
    /// An audiobook's artist field's spoken label.
    static var artistFieldLabel: String { MetadataEditorWording.artistLabel }
    /// An audiobook's album field's visible name.
    static var albumField: String { MetadataEditorWording.albumField }
    /// An audiobook's album field's spoken label.
    static var albumFieldLabel: String { MetadataEditorWording.albumLabel }
    /// An audiobook's genre field, its visible name and spoken label.
    static var genreField: String { MetadataEditorWording.genreField }
    /// An audiobook's year field, its visible name and spoken label.
    static var yearField: String { MetadataEditorWording.yearField }
    /// An audiobook's read-only row of its duration.
    static var durationRow: String { MetadataEditorWording.durationRow }
}
