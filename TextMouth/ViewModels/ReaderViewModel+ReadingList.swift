import Foundation

// MARK: - Reading from the Reading List (FR09)

/// A reader that reads its book from the reading list.
///
/// The user asked on October 7, 2026 that a book opened from the reading
/// list be marked as using the list, with its window titled a little
/// differently, and that it continue through the list as the list's options
/// say. A reader window is identified by its book's ID alone, so the list
/// cannot ride on the window's value: the open leaves a request
/// (`ReadingListOpenRequests`), which the book's reader claims, and from
/// then on the reader holds the book's place in the list
/// (`readingListPlace`). A book opened any other way is not read from the
/// list, even when it is in it.
extension ReaderViewModel {

    /// Whether this reader reads its book from the reading list: it was
    /// opened from the Reading List, or reached through the list by a book
    /// that continued to it, and the book is still in the list.
    var isOpenedFromReadingList: Bool {
        readingListPlace != nil
    }

    /// Claims the request waiting for this book to be read from the reading
    /// list, if one is, and reads the book from the list from then on, at
    /// its place there as the library holds the list now. A book no longer
    /// in the list by then is not read from it; its request is used up all
    /// the same. A closed reader claims nothing, so the request waits for
    /// the reader of the window the open makes.
    func claimReadingListRequest() {
        guard !hasClosed, readingListRequests.consume(for: book.id) != nil else { return }
        readingListPlace = ReadingListPlace(of: book.id, in: libraryViewModel.library)
        DiagnosticLog.trace(
            .playback,
            readingListPlace == nil
                ? "reading list: opened from the list, but no longer in it; read as any book"
                : "reading list: reading this book from the list"
        )
    }

    /// Keeps the book's place current as the library changes to `library`,
    /// while the book is read from the reading list: a book moved, added,
    /// or taken off the list moves the place, and the book reads as any
    /// book once it leaves the list, by its own removal there or its removal
    /// from the library, so its window title says "Book" again and its end
    /// follows its own end-of-book behavior, since the list has nothing to
    /// say of it (`LibraryViewModel.readingListContinuation(after:)`). A
    /// book put back on the list is not read from it again until it is
    /// opened from it again. A closed reader keeps nothing current.
    func followReadingList(in library: Library) {
        guard !hasClosed, let current = readingListPlace else { return }
        let place = ReadingListPlace(of: book.id, in: library)
        guard place != current else { return }
        readingListPlace = place
        if place == nil {
            DiagnosticLog.trace(.playback, "reading list: this book left the list; read as any book from now on")
        }
    }
}
