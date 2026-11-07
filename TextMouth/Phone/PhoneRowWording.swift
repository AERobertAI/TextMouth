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
            return "\(PhoneAppWording.libraryTitle): \(location.view.name)"
        }
        return location.folderPath.isEmpty ? PhoneAppWording.libraryTitle : location.name
    }

    /// What VoiceOver says once a folder opens, the Mac's "Fiction, 12 books".
    static func folderArrival(at path: String, in library: Library) -> String {
        FolderNavigationHistory.announcement(for: path, library: library)
    }

    // MARK: The Library View Row and the Bottom Bar

    /// The Library view row's label, the Mac's "Library view".
    static let libraryViewLabel = LibraryView.categoryPickerLabel
    /// What the Library view row does (the spec's).
    static let libraryViewHint = "Chooses what the Library lists."
    /// Settings' label and title (the spec's).
    static let settingsTitle = "Settings"
    /// What Settings does (the spec's).
    static let settingsHint = "Opens TextMouth's settings."
    /// What Sort does (the spec's).
    static let sortHint = "Chooses the order of the books."
    /// What Add to Library does on a phone, which offers only these two ways
    /// (the spec's; the Mac's hint names ways a phone doesn't have).
    static let addToLibraryHint = "Opens a sheet with the ways to add to the library: open a book, or import a folder."

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
        "Now Playing: \(title)"
    }

    /// What the Continue row shows, for sight: the Mac's "Continue: Emma",
    /// whose time left, "16:00 left", is `continueTimeText`.
    static func continueVisibleTitle(for book: Book) -> String {
        PhoneLibraryVocabulary.continueVisiblePrefix + book.title
    }

    /// The time left the Continue row shows beside its title, the Mac's
    /// "16:00 left", or nil when the book has none to show.
    static func continueTimeText(for book: Book, wordsPerMinute: Double) -> String? {
        LibraryView.continueTimeText(for: book, wpm: wordsPerMinute)
    }

    /// The Continue row's hint, the Mac's.
    static let continueHint = PhoneLibraryVocabulary.continueHint

    // MARK: Searching

    /// What VoiceOver says once typing in the search field stops: the books
    /// found, "3 books", in the Mac's counted words; or, when nothing at all
    /// matches, no book and no folder, the row's sentence "No books match.".
    static func searchCount(books: Int, folders: Int) -> String {
        books == 0 && folders == 0 ? noMatches : CountWording.books(books)
    }

    // MARK: Empty States

    /// The one row of a library with no books and no folders.
    static let emptyLibrary = PhoneAppWording.emptyLibrary
    /// The row of a folder that holds no book and no folder.
    static let emptyFolder = "This folder is empty."
    /// The row of a search that matches nothing.
    static let noMatches = "No books match."
    /// The row of an empty Reading List: the Mac's sentence without its
    /// Library menu, which a phone doesn't have (the spec, "Words that say
    /// Mac").
    static let emptyReadingList = "The reading list is empty. To add a book, choose Add to Reading List from its actions."
    /// The row of a view that lists nothing now, the Mac's.
    static let emptyView = LibraryViewPickerWording.emptyView

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
    static let removalMessage = "This deletes the book and its files from this iPhone, and they can't be recovered. "
        + "Your Mac's library isn't touched."

    /// The removal question's title, the Mac's "Remove Book?".
    static func removalTitle(for book: Book) -> String {
        RemovalChoiceWording(books: [book], movesToTrash: false).title
    }

    /// The removal question's button that deletes, the Mac's "Delete
    /// Permanently": the phone only ever deletes.
    static let removalDeleteButton = RemovalMode.deletePermanently.buttonTitle()

    /// What VoiceOver says once `title` is deleted, the Mac's "Deleted “Dune”
    /// permanently.".
    static func removalDone(title: String) -> String {
        RemovalWording(.deletePermanently, count: 1, title: title).completionMessage
    }
}
