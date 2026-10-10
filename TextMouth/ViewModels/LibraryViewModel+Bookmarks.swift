import SwiftUI

/// Extension for bookmark CRUD operations — adding, updating labels,
/// removing, and querying bookmarks for a specific book.
extension LibraryViewModel {

    /// Adds a bookmark to the book `bookID` with `label` and `anchor`, the
    /// words around its place (T06), and saves it in the book's row and its
    /// record (`Library.addBookmark`).
    func addBookmark(
        bookID: UUID,
        chapterIndex: Int,
        characterOffset: Int,
        label: String = "",
        anchor: TextAnchor? = nil
    ) {
        library.addBookmark(
            bookID: bookID,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            label: label,
            anchor: anchor
        )
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func updateBookmarkLabel(bookID: UUID, bookmarkID: UUID, label: String) {
        guard let bookIndex = library.books.firstIndex(where: { $0.id == bookID }),
              let bmIndex = library.books[bookIndex].bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        library.books[bookIndex].bookmarks[bmIndex].label = label
        save()
        LibraryPersistenceService.saveBookInfo(for: library.books[bookIndex])
    }

    func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        library.removeBookmark(bookID: bookID, bookmarkID: bookmarkID)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func bookmarksForBook(_ bookID: UUID) -> [Bookmark] {
        library.books.first(where: { $0.id == bookID })?.bookmarks ?? []
    }
}
