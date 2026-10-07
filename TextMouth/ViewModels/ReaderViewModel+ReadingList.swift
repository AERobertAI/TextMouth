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
}
