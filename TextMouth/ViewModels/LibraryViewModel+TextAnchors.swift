import Foundation

// MARK: - The Words of Places Saved Before Anchors (T06)

/// How the library gives the places saved before anchors their words
/// (T06, question 6): a reader's load hands over what it captured from the
/// text it shows, and the library keeps it in each book's row and record.
extension LibraryViewModel {

    /// Gives the places of each book `captures` names the words captured
    /// for them (`Book.adoptCapturedAnchors(_:)`), each only while the place
    /// is still saved where they were captured and has none, in one change
    /// of the library: library.json and each feed's index are saved once,
    /// and each book whose places took words has its record written. A book
    /// no longer in the library, or one `skipped` names, takes nothing.
    /// Neither a place's date nor a book's last-opened date changes: a place
    /// given its words has not moved, and its book was not opened.
    ///
    /// - Returns: The words given, by book; a book given none is left out.
    @discardableResult
    func adoptCapturedAnchors(
        _ captures: [UUID: CapturedPlaceAnchors],
        skipping skipped: Set<UUID> = []
    ) -> [UUID: CapturedPlaceAnchors] {
        var books = library.books
        var adopted: [UUID: CapturedPlaceAnchors] = [:]
        for index in books.indices {
            let id = books[index].id
            guard !skipped.contains(id), let captured = captures[id] else { continue }
            let given = books[index].adoptCapturedAnchors(captured)
            if !given.isEmpty {
                adopted[id] = given
            }
        }
        guard !adopted.isEmpty else { return adopted }
        library.books = books
        save()
        for book in books where adopted[book.id] != nil {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
        return adopted
    }
}
