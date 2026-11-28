import Foundation

/// The iPhone Library's words that aren't a row's own label: the Continue
/// row, what search says, the empty states, and removal's question (the
/// iPhone interface spec, "The Continue row", "Searching", "Removing a book",
/// and "Errors, empty states, long operations").
///
/// Each is the Mac's word, called from where the Mac keeps it, or a sentence
/// the spec gives, which is a full, plain sentence.
enum PhoneRowWording {
    // MARK: A Screen's Title and Arrival

    /// A Library screen's title, its heading: "Library" at the top of
    /// Folders, the folder's name in a folder, and "Library: All Items" in
    /// any other view (the spec's).
    static func screenTitle(for location: LibraryLocation) -> String {
        guard location.view.kind == .folders else {
            return SentenceWording.labelled(PhoneAppWording.libraryTitle, location.view.name)
        }
        return location.folderPath.isEmpty ? PhoneAppWording.libraryTitle : location.name
    }

    /// What VoiceOver says once a folder opens, the Mac's "Fiction, 12 books".
    static func folderArrival(at path: String, in library: Library) -> String {
        FolderNavigationHistory.announcement(for: path, library: library)
    }

    /// What VoiceOver says once a folder opens where feeds are kept (FR53), as the Mac says it: a feed's folder says its
    /// name, "Feed", and its items counted, "Planet Money, Feed, 10 of 381 episodes listed, 3 downloaded"; a folder
    /// holding feeds names them beside its books, "Podcasts, 3 books, 2 feeds".
    @MainActor
    static func folderArrival(at path: String, in library: Library, feedFolders: LibraryFeedFolders) -> String {
        FolderNavigationHistory.announcement(for: path, library: library, feedFolders: feedFolders)
    }

    // MARK: The Library View Row and the Bottom Bar

    /// The Library view row's label, the Mac's "Library view", which the
    /// Mac keeps on its main-actor view.
    @MainActor static var libraryViewLabel: String { LibraryView.categoryPickerLabel }
    /// What the Library view row does (the spec's).
    static var libraryViewHint: String {
        // Translators: Hint of the iPhone Library's row that chooses which view of the library is listed.
        InterfaceText.line("phoneRow.libraryViewHint", "Chooses what the Library lists.")
    }
    /// Settings' label and title (the spec's).
    static var settingsTitle: String {
        // Translators: Label and title of the iPhone Library's button that opens the app's settings.
        InterfaceText.line("common.settings", "Settings")
    }
    /// What Settings does (the spec's).
    static var settingsHint: String {
        // Translators: Hint of the iPhone Library's Settings button.
        InterfaceText.line("phoneRow.settingsHint", "Opens TextMouth's settings.")
    }
    /// What Sort does (the spec's).
    static var sortHint: String {
        // Translators: Hint of the iPhone Library's Sort button.
        InterfaceText.line("phoneRow.sortHint", "Chooses the order of the books.")
    }
    /// What Add to Library does on a phone, which offers only these two ways
    /// (the spec's; the Mac's hint names ways a phone doesn't have): the
    /// import's own words, kept in one place.
    static var addToLibraryHint: String { PhoneImportWording.addToLibraryButtonHint }

    // MARK: The Continue Row

    /// What VoiceOver says for the Continue row while `book` isn't playing:
    /// the Mac's "Continue listening to Emma, 16 minutes remaining", or
    /// "Continue listening to Emma" for a book with no time left to say.
    static func continueLabel(for book: Book, wordsPerMinute: Double) -> String {
        LibraryView.continueAccessibilityLabel(for: book, wpm: wordsPerMinute)
    }

    /// What VoiceOver says for the Continue row while the book titled `title`
    /// plays: "Now Playing: Emma" (the spec's). It holds no time left, which
    /// would change as the book plays, and its first cells differ from
    /// "Continue" for a braille display's Item Overview.
    static func nowPlayingLabel(title: String) -> String {
        // Translators: What VoiceOver says for the iPhone Library's Continue row while that book plays. %@ is the book's title.
        InterfaceText.line("phoneRow.nowPlayingLabel", "Now Playing: \(title)")
    }

    /// What the Continue row shows, for sight: the Mac's "Continue: Emma",
    /// whose time left, "16:00 left", is `continueTimeText`.
    static func continueVisibleTitle(for book: Book) -> String {
        PhoneLibraryVocabulary.continueVisible(book.title)
    }

    /// The time left the Continue row shows beside its title, the Mac's
    /// "16:00 left", or nil when the book has none to show.
    static func continueTimeText(for book: Book, wordsPerMinute: Double) -> String? {
        LibraryView.continueTimeText(for: book, wpm: wordsPerMinute)
    }

    /// The Continue row's hint, the Mac's.
    static var continueHint: String { PhoneLibraryVocabulary.continueHint }

    // MARK: Searching

    /// What VoiceOver says once typing in the search field stops: the books
    /// found, "3 books", in the Mac's counted words; or, when nothing at all
    /// matches, no book and no folder, the row's sentence "No books match.".
    static func searchCount(books: Int, folders: Int) -> String {
        books == 0 && folders == 0 ? noMatches : CountWording.books(books)
    }

    // MARK: Empty States

    /// The one row of a library with no books and no folders.
    static var emptyLibrary: String { PhoneAppWording.emptyLibrary }
    /// The row of a folder that holds no book and no folder.
    static var emptyFolder: String {
        // Translators: The only row of a folder in the iPhone Library that holds no book and no folder.
        InterfaceText.line("phoneRow.emptyFolder", "This folder is empty.")
    }
    /// The row of a search that matches nothing.
    static var noMatches: String {
        // Translators: The only row of the iPhone Library's list while a search matches nothing; also what VoiceOver says then.
        InterfaceText.line("phoneRow.noMatches", "No books match.")
    }
    /// The row of an empty Reading List: the Mac's sentence without its
    /// Library menu, which a phone doesn't have (the spec, "Words that say
    /// Mac").
    static var emptyReadingList: String {
        // Translators: The only row of the iPhone's empty Reading List. "Add to Reading List" is the name of a book's action, so keep it the same as that action's label.
        InterfaceText.line("phoneRow.emptyReadingList", "The reading list is empty. To add a book, choose Add to Reading List from its actions.")
    }
    /// The row of a view that lists nothing now, the Mac's.
    static var emptyView: String { LibraryViewPickerWording.emptyView }

    /// The sentence of `note`.
    static func sentence(for note: PhoneRowNote) -> String {
        switch note {
        case .emptyLibrary: emptyLibrary
        case .emptyFolder: emptyFolder
        case .noMatches: noMatches
        case .emptyReadingList: emptyReadingList
        case .emptyView: emptyView
        }
    }

    // MARK: The Reading List

    /// What VoiceOver says after a row's Add to Reading List, as the Mac's
    /// command says it: "Added to reading list: Dune", or, when it added
    /// nothing, "Dune is already in the reading list.".
    static func readingListAdded(title: String, added: Bool) -> String {
        added
            ? ReadingListWording.addedAnnouncement(added: [title], alreadyIn: 0)
            : ReadingListWording.addRefusal(selected: [title])
    }

    /// What VoiceOver says after a row's Remove from Reading List, as the
    /// Mac's command says it: "Removed from reading list: Dune", or, when it
    /// took nothing off, "Dune isn't in the reading list.".
    static func readingListRemoved(title: String, removed: Bool) -> String {
        removed
            ? ReadingListWording.removedAnnouncement(removed: [title], notIn: 0)
            : ReadingListWording.removeRefusal(selected: [title])
    }

    // MARK: Removing a Book

    /// The removal question's message on a phone, which has no Trash a person
    /// can open (the spec's).
    static var removalMessage: String {
        SentenceWording.joined([
            // Translators: First sentence of the message of the iPhone's question before a book is removed: nothing is kept on this iPhone.
            InterfaceText.line("phoneRow.removalMessage.permanently", "Permanently deletes the book and its files from this iPhone."),
            // Translators: Last sentence of the message of the iPhone's question before a book is removed: a copy of the book in a Mac's library stays.
            InterfaceText.line("phoneRow.removalMessage.library", "Your Mac's library isn't touched."),
        ])
    }

    /// The removal question's title, the Mac's "Remove Book?".
    static func removalTitle(for book: Book) -> String {
        RemovalChoiceWording(books: [book], movesToTrash: false).title
    }

    /// The removal question's button that deletes, the Mac's "Delete
    /// Permanently": the phone only ever deletes.
    static var removalDeleteButton: String { RemovalMode.deletePermanently.buttonTitle() }

    /// What VoiceOver says once `title` is deleted, the Mac's "Deleted “Dune”
    /// permanently.".
    static func removalDone(title: String) -> String {
        RemovalWording(.deletePermanently, count: 1, title: title).completionMessage
    }
}
