import Foundation

// MARK: - A Book's Place in the Reading List (FR09)

/// Where a book read from the reading list stands in it: its position in
/// the list as the Reading List shows it, counted from 1 at the top, and
/// how many books the list shows.
///
/// A reader holds one while it reads its book from the list
/// (`ReaderViewModel.readingListPlace`), and none otherwise; the reader's
/// window title, its header, and Where Am I? say what it holds.
struct ReadingListPlace: Equatable, Sendable {
    /// The book's position in the list, from 1 at the top.
    let position: Int
    /// How many books the list shows.
    let count: Int
}

extension ReadingListPlace {
    /// The place of the book `bookID` in `library`'s reading list, counted
    /// as the Reading List shows the list: passing over any ID that names no
    /// book in the library, as `LibraryViewModel.readingListBooks` does, so
    /// the place said is the row's place in the window. Nil when the list
    /// does not hold the book.
    ///
    /// Declared in an extension, so the memberwise initializer stays.
    init?(of bookID: UUID, in library: Library) {
        let listed = library.readingList.bookIDs
        // Most books are not in the list: answer them without gathering
        // every book's ID.
        guard listed.contains(bookID) else { return nil }
        let existing = Set(library.books.map(\.id))
        let shown = listed.filter(existing.contains)
        guard let index = shown.firstIndex(of: bookID) else { return nil }
        self.init(position: index + 1, count: shown.count)
    }
}

// MARK: - What Lies Beyond a Book in the List

/// What lies beyond a book in the reading list, one way through it, when
/// the list offers no book that way (FR09): no book at all, as below the
/// last book or above the first, or only books already finished, which the
/// list passes over while Skip Finished Books is on. A book read from the
/// list says which as it ends, and Next in Reading List and Previous in
/// Reading List say which when they have nowhere to go.
enum ReadingListEnd: Equatable, Sendable {
    /// No book lies that way.
    case noBookBeyond
    /// Only finished books lie that way, and the list passes over them.
    case onlyFinishedBooksBeyond
}
