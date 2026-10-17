import Foundation

/// What follows a finished book in its folder or feed (FR19, task B3): the
/// one search the reader's Continue to Next Book asks. Unlike
/// `nextBook(after:going:skippingFinished:)`, which sees only books that are
/// here, a feed's search also finds an episode whose file is not here, so a
/// serial is not read with a part missing: the reader downloads it
/// (`BookSuccession.episodeToDownload`).
extension LibraryViewModel {

    /// What follows `book` going `direction`.
    ///
    /// A plain folder's book is followed by the next book in the folder's
    /// order (`nextBook(after:going:skippingFinished:)`), or by nothing, with
    /// the note that says why: no book lies that way, or only finished ones
    /// do and `skippingFinished` passes over them.
    ///
    /// A feed's item is followed by the next item the library lists
    /// (`FeedCenter.listedItems(of:)`, newest first) that is not passed over:
    /// the book of an item downloaded here, or, for an item whose file is not
    /// here, the order to download it. Items moved into the library are the
    /// library's own, and are left out. When `skippingFinished`, an item
    /// whose book rests at its end (`Book.restsAtEnd`) is passed over, and so
    /// is an item with no file here that was played (`FeedItem.playedDate`),
    /// its file since deleted.
    ///
    /// - Parameters:
    ///   - book: The book that ended.
    ///   - direction: The way to go: down the list, or up it.
    ///   - skippingFinished: Whether finished items are passed over.
    func succession(
        after book: Book,
        going direction: ReadingList.Direction,
        skippingFinished: Bool
    ) -> BookSuccession {
        if let feedID = book.feedLink?.feedID {
            return feedSuccession(after: book, of: feedID, going: direction, skippingFinished: skippingFinished)
        }
        if let next = nextBook(after: book, going: direction, skippingFinished: skippingFinished) {
            return .book(next)
        }
        // Nothing qualified: either nothing lies that way, or all that does
        // is finished.
        return .nothing(note: booksBeyond(book, going: direction).isEmpty
            ? EndOfBookWording.noMoreBooksInFolderNote
            : EndOfBookWording.onlyFinishedBooksInFolderNote(going: direction))
    }

    /// What follows `book`, an item of the feed `feedID`, in the feed's
    /// listing (`succession(after:going:skippingFinished:)`).
    private func feedSuccession(
        after book: Book,
        of feedID: UUID,
        going direction: ReadingList.Direction,
        skippingFinished: Bool
    ) -> BookSuccession {
        let items = feeds.listedItems(of: feedID)
        // The book's item: the one whose book it is, or whose identity the
        // book's link names (its file may have been replaced).
        let itemID = book.feedLink?.itemID
        guard let current = items.firstIndex(where: { $0.state.bookID == book.id || $0.id == itemID }) else {
            return .nothing(note: EndOfBookWording.noMoreBooksInFolderNote)
        }
        // The listing's positions stand for its items, as in `booksBeyond`.
        // Items moved into the library are the library's, not the feed's.
        let beyond = (ListNeighbors.beyond(current, going: direction, in: Array(items.indices)) ?? [])
            .map { items[$0] }
            .filter { $0.state.libraryBookID == nil }
        guard !beyond.isEmpty else {
            return .nothing(note: EndOfBookWording.noMoreBooksInFolderNote)
        }
        // Each downloaded item's row, found by one pass over the library.
        let rows = Dictionary(library.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in beyond {
            if let bookID = item.state.bookID, let row = rows[bookID], row.feedLink?.feedID == feedID {
                // Its file is here: its book, unless it is finished and
                // finished books are passed over.
                if !(skippingFinished && row.restsAtEnd) { return .book(row) }
            } else if !(skippingFinished && item.playedDate != nil) {
                // Its file is not here: download it, unless it was played
                // and played items are passed over.
                return .episodeToDownload(feedID: feedID, item: item)
            }
        }
        return .nothing(note: EndOfBookWording.onlyFinishedBooksInFolderNote(going: direction))
    }
}
