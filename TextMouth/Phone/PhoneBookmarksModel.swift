import Foundation

// MARK: - The Mac's words

/// The words of the Mac's Bookmarks sheet that sit inline in its view,
/// `BookmarkPanelView`, held here for the phone's sheet, which is rebuilt
/// for the phone rather than wrapped (the iPhone interface spec, "The
/// Bookmarks sheet"). `PhoneBookmarksVocabularyTests` reads the Mac's source
/// and requires each word to be there as it is.
enum PhoneBookmarksVocabulary {
    /// The sheet's title, read as its heading: the name of the button that
    /// opens it.
    static let title: String = PhoneReaderVocabulary.bookmarks
    /// The toolbar button that closes the sheet.
    static let done = "Done"
    /// The Add Bookmark button's visible word, and the Add sheet's title.
    static let addBookmark = "Add Bookmark"
    /// What VoiceOver calls the Add Bookmark button.
    static let addBookmarkLabel = "Add bookmark at current position"
    /// What the sheet says for a book without bookmarks.
    static let empty = "No bookmarks yet."
    /// A bookmark row's hint: what choosing it does, never a gesture.
    static let rowHint = "Goes to this bookmark and closes the list."
    /// The Add sheet's field, as it shows.
    static let addNoteField = "Note (optional)"
    /// The Edit sheet's field, as it shows.
    static let editNoteField = "Note"
    /// What VoiceOver calls either sheet's field.
    static let noteLabel = "Bookmark note"
    /// The Add sheet's field's hint.
    static let addNoteHint = "Optional note to describe this bookmark"
    /// The Add sheet's button that adds the bookmark.
    static let add = "Add"

    /// The Edit sheet's title, as in "Edit Bookmark 3".
    static func editTitle(number: Int) -> String {
        "Edit Bookmark \(number)"
    }
}

// MARK: - The phone's own words

/// The Bookmarks sheet's words the Mac doesn't have, from the spec's "New
/// words, in one place", and the Mac's words a phone needs said its way.
enum PhoneBookmarksWording {
    /// The empty list's help: the Mac's, with no keys named, since the phone
    /// has none (the spec, "Words that say Mac").
    static let emptyHelp = BookmarkPanelView.emptyListHelp(keys: [])

    /// The title of the question asked before a bookmark with a note is
    /// removed, as in "Remove Bookmark 3?". Its message is the note.
    static func removeQuestion(number: Int) -> String {
        "Remove Bookmark \(number)?"
    }

    /// What VoiceOver says once the sheet has closed on a bookmark chosen in
    /// it: the Mac's short word, "Bookmark 3", whether the book plays or
    /// not, since the book's own words can't name a bookmark (the spec,
    /// "What a move says").
    static func jumpAnnouncement(to bookmark: Bookmark) -> String {
        "Bookmark \(bookmark.number)"
    }
}

// MARK: - A row

/// One bookmark's row in the phone's Bookmarks sheet.
struct PhoneBookmarksRow: Identifiable, Equatable {
    /// The bookmark the row goes to.
    let bookmark: Bookmark
    /// What VoiceOver reads: the Mac's label, as in "Bookmark 3, The Battle,
    /// Note: Check this, added October 9, 2026".
    let label: String
    /// The heading the bookmark is in, shown under its number; nil leaves it
    /// out, as on the Mac.
    let headingText: String?

    /// The bookmark's own ID, which never changes when the list refreshes.
    var id: UUID { bookmark.id }
    /// What the row shows first, the Mac's "Bookmark 3".
    var shownTitle: String { "Bookmark \(bookmark.number)" }
}

// MARK: - The place taken

/// Where a bookmark will go: the place being read as Add Bookmark opened, so
/// that a note written while the book plays doesn't land wherever the book
/// has got to (the spec, "The Bookmarks sheet").
struct PhoneBookmarkPlace: Equatable, Sendable {
    /// The content unit the place is in.
    let chapterIndex: Int
    /// The place's offset in that unit, in UTF-16 code units.
    let characterOffset: Int
}

// MARK: - The sheet

/// What the phone's Bookmarks sheet lists and decides for one book: its
/// rows, in the order the bookmarks lie in the book, where focus lands on
/// arrival and after a change, and when a removal asks first.
///
/// The Mac lists bookmarks in the order they were added; the phone lists
/// them as they lie in the book, as the spec asks, by the reader's own rule
/// for Next and Previous Bookmark: by place, two at one place by number.
/// Focus goes by the Mac's rules (`BookmarkPanelView.focusTarget`) over that
/// order.
struct PhoneBookmarksModel {
    /// The rows, in book order.
    let rows: [PhoneBookmarksRow]

    /// A model for `bookmarks`, each row naming the heading
    /// `headingText(bookmark)` gives.
    init(bookmarks: [Bookmark], headingText: (Bookmark) -> String?) {
        rows = Self.bookOrder(of: bookmarks).map { bookmark in
            let heading = headingText(bookmark)
            return PhoneBookmarksRow(
                bookmark: bookmark,
                label: bookmark.accessibilityLabel(headingText: heading),
                headingText: heading
            )
        }
    }

    /// `bookmarks` in the order they lie in the book: by content unit, then
    /// by place within it, two at one place by their numbers, as the reader
    /// orders Next and Previous Bookmark.
    static func bookOrder(of bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.sortedStably { first, second in
            (first.chapterIndex, first.characterOffset, first.number)
                < (second.chapterIndex, second.characterOffset, second.number)
        }
    }

    /// The bookmarks as listed.
    var listed: [Bookmark] {
        rows.map(\.bookmark)
    }

    /// Whether the list is empty, when the sheet shows the Mac's "No
    /// bookmarks yet." and its help.
    var isEmpty: Bool {
        rows.isEmpty
    }

    /// Where focus lands as the sheet opens at `place`: the bookmark nearest
    /// before the place, else the first after it, by the Mac's rule; the Add
    /// Bookmark button when there are none.
    func openingFocus(at place: PhoneBookmarkPlace) -> BookmarkPanelFocusTarget {
        BookmarkPanelView.focusTarget(
            after: .open(chapterIndex: place.chapterIndex, characterOffset: place.characterOffset),
            in: listed
        )
    }

    /// Where focus goes after `operation`, by the Mac's rule over the
    /// phone's order. For a delete, ask the model of the list as it was
    /// before: the bookmark listed after the one deleted, else the one
    /// before it, else the Add Bookmark button.
    func focus(after operation: BookmarkPanelOperation) -> BookmarkPanelFocusTarget {
        BookmarkPanelView.focusTarget(after: operation, in: listed)
    }

    /// Whether removing `bookmark` asks first: only when it has a note,
    /// which would be lost (the spec, "Add bookmark" and "The Bookmarks
    /// sheet"). A bookmark without one goes at once.
    static func asksBeforeRemoving(_ bookmark: Bookmark) -> Bool {
        !bookmark.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - From a reader

extension PhoneBookmarksModel {
    /// The model for `reader`'s bookmarks, each row naming its heading as
    /// the Mac's row does.
    @MainActor
    init(reader: ReaderViewModel) {
        self.init(bookmarks: reader.bookmarks) { reader.headingText(forBookmark: $0) }
    }
}

extension PhoneBookmarkPlace {
    /// The place `reader` is reading now.
    @MainActor
    init(readingIn reader: ReaderViewModel) {
        self.init(chapterIndex: reader.currentChapterIndex, characterOffset: reader.currentCharacterOffset)
    }
}

extension ReaderViewModel {
    /// The phone's Add Bookmark: adds a bookmark with `note` at `place`, the
    /// place taken as the Add sheet opened, keeping the words around it,
    /// and says which bookmark it made, or, a moment later, that it made
    /// none. It returns the bookmark added, for focus to land on.
    ///
    /// It takes the steps of the Mac's own add (`addBookmark(atOffset:label:)`
    /// in `ReaderViewModel+Bookmarks.swift`), which is private and adds in
    /// the chapter being read now: a note written while the book plays may
    /// outlast the chapter its place is in, and the phone's bookmark must
    /// stay where Add Bookmark opened. The Mac never calls this.
    @discardableResult
    func addBookmark(at place: PhoneBookmarkPlace, note: String) -> Bookmark? {
        let existingIDs = Set(libraryViewModel.bookmarksForBook(book.id).map(\.id))
        libraryViewModel.addBookmark(
            bookID: book.id,
            chapterIndex: place.chapterIndex,
            characterOffset: place.characterOffset,
            label: note,
            anchor: anchorToSave(at: TextPlace(chapter: place.chapterIndex, offset: place.characterOffset))
        )
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        let added = bookmarks.first { !existingIDs.contains($0.id) }
        if let added {
            announceToVoiceOver("Bookmark \(added.number) added")
        } else {
            // The Mac's sentence for a book the library no longer holds,
            // said once focus has settled, as the Mac says it.
            let sentence = Self.bookmarkNotAddedAnnouncement(bookTitle: book.title)
            VoiceOverAnnouncer.afterSheetCloses { [weak self] in
                self?.announceToVoiceOver(sentence)
            }
        }
        return added
    }
}
