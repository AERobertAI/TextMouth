import SwiftUI

/// The reading list's part of the library model (FR09): which books the list
/// holds and in what order, the changes the Library window makes to it, its
/// options, and the questions a reader opened from it asks when its book
/// ends.
///
/// Every change is made to the list as the window shows it, which leaves out
/// any ID that names no book in the library (`editReadingList(_:)`), so
/// positions and neighbors count only books the list shows; a change that
/// changes anything is one change of `library` and one save of the index,
/// and a request that changes nothing saves nothing. The list's order is
/// its own: moving or dragging a book here never touches a folder's manual
/// order (`Book.manualSortOrder`).
extension LibraryViewModel {

    // MARK: - Reading the List

    /// The books of the reading list, in reading order. An ID that names no
    /// book is passed over: only a removal that went around
    /// `Library.removeBook(id:)` can leave one, and the next change to the
    /// list drops it.
    var readingListBooks: [Book] {
        let books = booksByID
        return readingList.bookIDs.compactMap { books[$0] }
    }

    /// Whether the book `bookID` is in the reading list.
    func isInReadingList(_ bookID: UUID) -> Bool {
        readingList.contains(bookID)
    }

    // MARK: - Membership

    /// Adds the books `ids` names to the end of the reading list, in the
    /// order given, which is the order the list showing them shows them,
    /// leaving out every book already there, any named twice after the
    /// first, and any not in the library. Returns the books added, in that
    /// order; none when nothing changed, and then nothing is saved.
    @discardableResult
    func addToReadingList(_ ids: [UUID]) -> [Book] {
        editReadingList { list, books in
            list.append(ids.filter { books[$0] != nil }).compactMap { books[$0] }
        }
    }

    /// Takes the books `ids` names off the reading list, keeping the others
    /// in their order. Returns the books taken off, in the list's order;
    /// none when none was in it, and then nothing is saved.
    @discardableResult
    func removeFromReadingList(_ ids: [UUID]) -> [Book] {
        editReadingList { list, books in
            list.remove(Set(ids)).compactMap { books[$0] }
        }
    }

    // MARK: - The Commands

    /// Add to Reading List, from a row, a selection, or the Library menu:
    /// adds `books`, the books the command chose, to the end of the list in
    /// their order, and tells VoiceOver, from `window`, what it did: the
    /// books added and how many were in the list already
    /// (`ReadingListWording.addedAnnouncement`), or, when it added none,
    /// why (`ReadingListWording.addRefusal`). A book chosen twice counts
    /// once, and one no longer in the library not at all. Returns what it
    /// said.
    @discardableResult
    func addToReadingList(_ books: [Book], announcingFrom window: NSWindow?) -> String {
        let listedBefore = Set(readingList.bookIDs)
        let chosen = booksStillInLibrary(books)
        let added = addToReadingList(chosen.map(\.id))
        let message = added.isEmpty
            ? ReadingListWording.addRefusal(selected: chosen.map(\.title))
            : ReadingListWording.addedAnnouncement(
                added: added.map(\.title),
                alreadyIn: chosen.filter { listedBefore.contains($0.id) }.count
            )
        VoiceOverAnnouncer.announce(message, from: window)
        return message
    }

    /// Remove from Reading List, from a row, a selection, or the Library
    /// menu: takes `books` off the list, and tells VoiceOver, from `window`,
    /// what it did: the books taken off and how many were not in the list
    /// (`ReadingListWording.removedAnnouncement`), or, when it took none
    /// off, why (`ReadingListWording.removeRefusal`). The books stay in the
    /// library. Returns what it said.
    @discardableResult
    func removeFromReadingList(_ books: [Book], announcingFrom window: NSWindow?) -> String {
        let chosen = booksStillInLibrary(books)
        let removed = removeFromReadingList(chosen.map(\.id))
        let message = removed.isEmpty
            ? ReadingListWording.removeRefusal(selected: chosen.map(\.title))
            : ReadingListWording.removedAnnouncement(removed: removed.map(\.title), notIn: chosen.count - removed.count)
        VoiceOverAnnouncer.announce(message, from: window)
        return message
    }

    /// `books` as the library holds them now, in their order and each once,
    /// leaving out any no longer in it: what a command acts on, whatever
    /// the list showed when it was chosen.
    private func booksStillInLibrary(_ books: [Book]) -> [Book] {
        let current = booksByID
        var seen = Set<UUID>()
        return books.compactMap { book in
            guard seen.insert(book.id).inserted else { return nil }
            return current[book.id]
        }
    }

    // MARK: - Order

    /// Moves the book `bookID` one place up or down the reading list, past
    /// the book beside it, as Move Book Up and Move Book Down do there, and
    /// saves the new order at once. Returns what VoiceOver says of the move
    /// (the moved book, the book it passed, and where it went), or nil,
    /// changing nothing, when the book is not in the list or is already at
    /// that end of it.
    @discardableResult
    func moveInReadingList(bookID: UUID, direction: ReadingList.Direction) -> MoveResult? {
        editReadingList { list, books in
            guard let moved = books[bookID], let newIndex = list.move(bookID, direction) else { return nil }
            // The two books changed places: the one passed is now where
            // the moved one was.
            let passedIndex = newIndex - direction.step
            let passed = list.bookIDs.indices.contains(passedIndex) ? books[list.bookIDs[passedIndex]] : nil
            return MoveResult(
                movedTitle: moved.title,
                adjacentTitle: passed?.title ?? "",
                direction: direction.step,
                newIndex: newIndex
            )
        }
    }

    /// Moves the books at `source` to `destination` in the reading list, as
    /// a drag in the list does: the offsets are positions in the list as it
    /// shows it (`readingListBooks`), with no search narrowing it. Saves
    /// the new order at once; offsets outside the list change nothing.
    func reorderReadingList(from source: IndexSet, to destination: Int) {
        editReadingList { list, _ in
            list.move(fromOffsets: source, toOffset: destination)
        }
    }

    // MARK: - Options

    /// Makes `continuation` what a book opened from the reading list does
    /// when it ends, and saves it; choosing the option already chosen
    /// saves nothing.
    func setReadingListContinuation(_ continuation: ReadingList.Continuation) {
        editReadingList { list, _ in
            list.continuation = continuation
        }
    }

    /// Makes continuing through the reading list pass over finished books,
    /// or not, and saves the choice; the choice already made saves nothing.
    func setReadingListSkipsFinished(_ skipsFinished: Bool) {
        editReadingList { list, _ in
            list.skipsFinished = skipsFinished
        }
    }

    // MARK: - The Questions a Reader Asks
    //
    // FR09's second branch, the reader's part, builds on the two questions
    // below; this branch leaves the reader alone. A reader opened from the
    // Reading List is marked as reading from it, titles its window "Reading
    // List: <title> by <author>", and continues down or up the list when its
    // book ends. What it needs, as this branch leaves things:
    //
    // 1. A claim that the book was opened from the list:
    //    `ReadingListOpenRequests`, a main-actor store shaped like
    //    `ReaderAutoplayRequests` (Services/ReaderAutoplayRequests.swift).
    //    A Library window showing the Reading List makes a request for a
    //    book just before it opens it from the list: the row's default
    //    action and its Open command (`LibraryBookRowActions.open`) and
    //    Return on the selection (the `.openSelectedBook` handler), each
    //    ahead of `onOpenBook`, while `category == .readingList`; Continue
    //    Listening opens the last book, not the list's, and makes none. The
    //    book's reader claims the request once, as it finishes loading, or
    //    at once when its window was already open (`consume(for:)`); a
    //    request older than its lifetime is thrown away, so the same book
    //    opened later from elsewhere reads as before. A reader that
    //    continues through the list makes a request for the next book too,
    //    beside its autoplay request and before it posts
    //    `.continueToNextBook`, so the next reader is marked as well.
    // 2. At its book's end (`ReaderViewModel.handleEndOfBook`), a reader
    //    marked as reading from the list counts the book finished, as it
    //    does now, then asks `readingListContinuation(after:)` in place of
    //    its own end-of-book behavior. A book continues there through
    //    `continueToNextBook(_:)` and its autoplay request, which open or
    //    bring forward the next book's window and play it; nil stops the
    //    reader there and says why: Stop was chosen, the list ends, only
    //    finished books lie beyond, or the book has left the list.
    // 3. Next in Reading List and Previous in Reading List:
    //    `readingListNeighbor(of:direction:skippingFinished:)`, down for
    //    Next and up for Previous, with the list's `skipsFinished`.
    //
    // A book counts as finished by `finishedBookIDs`, what Books Finished
    // records, and the book asking is never its own answer.

    /// The book beside `bookID` in the reading list: down, the nearest book
    /// below it; up, the nearest above it; passing over every finished book
    /// (`finishedBookIDs`) when `skippingFinished`. Nil when `bookID` is not
    /// in the list, or nothing is left that way: at the end of the list
    /// going down, at its start going up, or past only finished books. A
    /// book whose file is only in the cloud is a neighbor like any other:
    /// opening it downloads it, as opening any such book does.
    ///
    /// A reader opened from the reading list asks this for Next in Reading
    /// List and Previous in Reading List, and, through
    /// `readingListContinuation(after:)`, when its book ends.
    func readingListNeighbor(
        of bookID: UUID,
        direction: ReadingList.Direction,
        skippingFinished: Bool
    ) -> Book? {
        let books = booksByID
        // A book no longer in the library is not in the list as shown.
        guard books[bookID] != nil else { return nil }
        let finished = skippingFinished ? finishedBookIDs() : []
        let neighbor = readingList.neighbor(of: bookID, direction) { id in
            books[id] != nil && !finished.contains(id)
        }
        return neighbor.flatMap { books[$0] }
    }

    /// The book to play once `bookID`, opened from the reading list, ends,
    /// as the list's options say: the book below it or the one above it,
    /// passing over finished books when Skip Finished Books is on, or none
    /// for Stop (`ReadingList.continuation`, `ReadingList.skipsFinished`).
    /// Nil too when `bookID` has left the list, or no book is left that
    /// way, which is where the reader stops. Asked as the book ends, after
    /// the reader has counted it finished, so the book itself is never the
    /// answer.
    func readingListContinuation(after bookID: UUID) -> Book? {
        let list = readingList
        guard let direction = list.continuation.direction else { return nil }
        return readingListNeighbor(of: bookID, direction: direction, skippingFinished: list.skipsFinished)
    }

    // MARK: - Changing the List

    /// Every book in the library, by ID; the first wins should an ID appear
    /// twice.
    private var booksByID: [UUID: Book] {
        Dictionary(library.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Applies `edit` to the reading list as the window shows it, leaving
    /// out any ID that names no book, and, when that changed it, makes the
    /// result the reading list, in one change of `library`, and saves the
    /// index once. Returns what `edit` returned. `edit` is given the
    /// library's books by ID.
    @discardableResult
    private func editReadingList<Result>(_ edit: (inout ReadingList, _ books: [UUID: Book]) -> Result) -> Result {
        let books = booksByID
        var shown = library.readingList
        shown.keepOnly(Set(books.keys))
        var edited = shown
        let result = edit(&edited, books)
        if edited != shown {
            library.readingList = edited
            save()
        }
        return result
    }
}

// MARK: - Finished Books

extension ReadingStats {
    /// The books Books Finished counts, by ID, which the reading list's Skip
    /// Finished Books passes over (FR09); an entry whose ID cannot be read
    /// is left out.
    var finishedBookIDs: Set<UUID> {
        Set(finishedBooks.compactMap { UUID(uuidString: $0.bookID) })
    }
}
