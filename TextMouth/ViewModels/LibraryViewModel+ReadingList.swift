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
    func addToReadingList(_ books: [Book], announcingFrom window: PlatformWindow?) -> String {
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
        // In a cloud library the books added are kept on this Mac, and those
        // only in the cloud download at once, as Download Now's do.
        cloudCommands.downloadBooksAddedToReadingList(added, in: self, from: window)
        return message
    }

    /// Remove from Reading List, from a row, a selection, or the Library
    /// menu: takes `books` off the list, and tells VoiceOver, from `window`,
    /// what it did: the books taken off and how many were not in the list
    /// (`ReadingListWording.removedAnnouncement`), or, when it took none
    /// off, why (`ReadingListWording.removeRefusal`). The books stay in the
    /// library. Returns what it said.
    @discardableResult
    func removeFromReadingList(_ books: [Book], announcingFrom window: PlatformWindow?) -> String {
        let chosen = booksStillInLibrary(books)
        let removed = removeFromReadingList(chosen.map(\.id))
        let message = removed.isEmpty
            ? ReadingListWording.removeRefusal(selected: chosen.map(\.title))
            : ReadingListWording.removedAnnouncement(removed: removed.map(\.title), notIn: chosen.count - removed.count)
        VoiceOverAnnouncer.announce(message, from: window)
        return message
    }

    /// Adds `books`, which an import made with `request` has just put in the
    /// library, to the end of the reading list, in that order, when the
    /// import was made at the Reading List (`ImportRequest.addsToReadingList`,
    /// FR09): Import Book, Open Book..., Import Folder…, or New from
    /// Text there. Since the list is no folder, VoiceOver then hears that
    /// they joined it and where the books themselves went
    /// (`ReadingListWording.importedAnnouncement`), at medium priority: it
    /// comes right after the import's own end announcement, at high
    /// priority, or a ZIP batch's alert, and waits for that speech rather
    /// than cutting it off, as the import's quarter announcements wait
    /// (FR10). Books already in the list, as a replaced book's copy that
    /// took the old one's place, stay where they are, and nothing is said
    /// when none joins it. An import made anywhere else changes nothing
    /// here.
    func addImportedBooksToReadingList(_ books: [Book], request: ImportRequest) {
        guard request.addsToReadingList else { return }
        let added = addToReadingList(books.map(\.id))
        guard let folderPath = added.first?.folderPath else { return }
        VoiceOverAnnouncer.announce(
            ReadingListWording.importedAnnouncement(added: added.map(\.title), folderPath: folderPath),
            priority: .medium
        )
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
    /// (the moved book, the book it passed, and where it went, counted in
    /// the list as shown), or nil, changing nothing, when the book is not in
    /// the list or is already at that end of it.
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
                newIndex: newIndex,
                // The list as shown: `editReadingList` left out every ID
                // naming no book.
                count: list.bookIDs.count
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

    /// Makes a book leave the reading list as soon as it is finished, or
    /// not, and saves the choice; the choice already made saves nothing.
    /// Turning it on takes off none of the books already finished: it acts
    /// on books finished from then on (`removeFinishedBookFromReadingList`).
    func setReadingListRemovesFinished(_ removesFinished: Bool) {
        editReadingList { list, _ in
            list.removesFinished = removesFinished
        }
    }

    // MARK: - Keeping the Books on This Mac
    //
    // In a cloud library this Mac keeps the reading list's books downloaded
    // (`KeptBooks`, the user, November 13, 2026), while the Reading List's
    // "Keep these books on this Mac" is on, which it is until cleared. The
    // set of books kept for the list is derived from the list each time the
    // list changes, never stored.

    /// Starts handing the reading list's books to `cloudCommands.kept` each
    /// time the list changes, one turn of the main queue after the change,
    /// then downloads the kept books only in the cloud, quietly
    /// (`LibraryCloudCommands.downloadEvictedKeptBooks(in:)`): a book that
    /// reached the list through a sync from another Mac downloads here. A
    /// book the listener just added has been downloading since the turn
    /// before, announced (`downloadBooksAddedToReadingList`), and is not
    /// started twice. The library starts it once, with its other observers.
    func observeReadingListKeeping() {
        $library
            .map { Set($0.readingList.bookIDs) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listed in
                guard let self else { return }
                cloudCommands.kept.setReadingListBooks(listed)
                cloudCommands.downloadEvictedKeptBooks(in: self)
            }
            .store(in: &cancellables)
    }

    /// Makes this Mac keep the reading list's books downloaded in a cloud
    /// library, or not, and saves the choice in this Mac's own folder. Turning
    /// it on downloads the list's books that are only in the cloud, quietly;
    /// turning it off removes nothing from this Mac.
    func setKeepsReadingListBooks(_ keeps: Bool) {
        cloudCommands.kept.setKeepsReadingListBooks(keeps)
        if keeps {
            cloudCommands.downloadEvictedKeptBooks(in: self)
        }
    }

    // MARK: - Removing Finished Books
    //
    // The reading list's "Remove books when finished" (the user, November
    // 13, 2026). A book's end is told by `.bookDidFinish`
    // (`ReadingStatsService.markBookFinished`), whether the book was opened
    // from the list or not, and the list hears of it here.
    //
    // Two things decide when the book leaves the list:
    //
    // 1. The reader asks the list at once, in the same turn of the main
    //    queue as the telling, which book follows
    //    (`readingListContinuation(after:)`), and the list answers only for
    //    a book it still holds. So the removal never happens within the
    //    telling, but one turn of the main queue after it.
    // 2. A reader that reads its book from the list and rests on it at its
    //    end holds it (`holdFinishedBookOnReadingList(_:)`): the book is
    //    still the list's for that reader, whose Rewind after the end, Play
    //    at the end, and Next in Reading List all ask the list, and the
    //    list overrides the book's own end rule (the user, October 7, 2026).
    //    The book leaves when its readers have moved on to another book or
    //    closed (`releaseFinishedBookFromReadingList(_:)`). A book with no
    //    such reader, finished elsewhere (a feed item marked played, or a
    //    book read from the library), leaves at once.

    /// Starts hearing of finished books from `source`, whose end the
    /// reading list then acts on (`removeFinishedBookFromReadingList`).
    /// The library starts it once, with its other observers.
    ///
    /// The turn of the main queue the removal waits for is
    /// `receive(on: DispatchQueue.main)`: Combine always schedules it
    /// asynchronously, even when the notification is posted on the main
    /// queue, as this one is.
    func observeFinishedBooks(of source: ReadingStatsService = .shared) {
        NotificationCenter.default.publisher(for: .bookDidFinish, object: source)
            .compactMap { $0.userInfo?[ReadingStatsService.finishedBookIDKey] as? UUID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bookID in self?.bookFinished(bookID) }
            .store(in: &cancellables)
    }

    /// Acts on the end of the book `bookID`: when the list says to drop
    /// finished books and holds it, the book leaves the list now, or, while
    /// a reader rests on it from the list, when that reader leaves it
    /// (`releaseFinishedBookFromReadingList(_:)`).
    private func bookFinished(_ bookID: UUID) {
        guard readingList.removesFinished, readingList.contains(bookID) else { return }
        if readingListHoldCounts[bookID, default: 0] > 0 {
            finishedBooksAwaitingRelease.insert(bookID)
        } else {
            removeFinishedBookFromReadingList(bookID)
        }
    }

    /// A reader that reads the book `bookID` from the reading list rests on
    /// it at its end: until the reader releases the book, the book is not
    /// dropped from the list for being finished. Every hold is released
    /// once (`releaseFinishedBookFromReadingList(_:)`). Made before the
    /// reader tells the book's end, so the telling finds it.
    func holdFinishedBookOnReadingList(_ bookID: UUID) {
        readingListHoldCounts[bookID, default: 0] += 1
    }

    /// Lets go of a hold made by `holdFinishedBookOnReadingList(_:)`: its
    /// reader moved on to another book or closed. When no reader holds the
    /// book any more and it was finished while the list dropped finished
    /// books, it leaves the list now (`removeFinishedBookFromReadingList`,
    /// which asks the option again, so one cleared meanwhile keeps it).
    func releaseFinishedBookFromReadingList(_ bookID: UUID) {
        let remaining = readingListHoldCounts[bookID, default: 0] - 1
        guard remaining <= 0 else {
            readingListHoldCounts[bookID] = remaining
            return
        }
        readingListHoldCounts[bookID] = nil
        if finishedBooksAwaitingRelease.remove(bookID) != nil {
            removeFinishedBookFromReadingList(bookID)
        }
    }

    /// Takes the book `bookID`, just finished, off the reading list when the
    /// list says to (`ReadingList.removesFinished`) and holds it, through
    /// the removal Remove from Reading List makes
    /// (`removeFromReadingList(_:)`), so it is saved as that is. Silent:
    /// the end of the book says what it says, and a Reading List showing
    /// changes by itself. A book not on the list, and any book while the
    /// option is off, are left alone.
    ///
    /// - Returns: Whether the book was taken off the list.
    @discardableResult
    func removeFinishedBookFromReadingList(_ bookID: UUID) -> Bool {
        guard readingList.removesFinished, readingList.contains(bookID) else { return false }
        return !removeFromReadingList([bookID]).isEmpty
    }

    // MARK: - The Questions a Reader Asks
    //
    // A reader opened from the Reading List reads its book from the list
    // (ReaderViewModel+ReadingList.swift): it titles its window "Reading
    // List: <title> by <author>", and continues down or up the list when its
    // book ends, asking the two questions below. How it comes to read from
    // the list, and what it asks:
    //
    // 1. The mark. A reader window's value is its book's ID alone, so a
    //    Library window showing the Reading List makes a request
    //    (`ReadingListOpenRequests`, one kind of `ReaderRequestStore`) just
    //    before it opens a book from the list
    //    (`ReadingListOpenRequests.open(_:shownIn:libraryIsMoving:with:)`):
    //    by the row's default action and its Open command
    //    (`LibraryBookRowActions.open`) and by Return on the selection (the
    //    `.openSelectedBook` handler). Continue Listening opens the last
    //    book, not the list's, and makes none. The book's reader claims the
    //    request once, as the reader is made
    //    (`ReaderViewModel.claimReadingListRequest()`), so neither a long
    //    load nor a download from the cloud can outlive it, or at once when
    //    its window is already open and the open brings it forward
    //    (`requestsMade`). A request older than its lifetime is thrown away,
    //    so the same book opened later from elsewhere reads as before, and
    //    an open the window refuses drops it (`ReaderOpenRefusal`). A reader
    //    that continues through the list, or goes to the next or previous
    //    book in it, makes the request for that book itself
    //    (`continueThroughReadingList(to:)`, `openFromReadingList(_:)`), so
    //    its reader is marked as well.
    // 2. At its book's end (`ReaderViewModel.handleEndOfBook()`), a reader
    //    reading from the list counts the book finished, then asks
    //    `readingListContinuation(after:)` in place of its own end-of-book
    //    behavior (`finishBookReadFromReadingList`). The book below or above
    //    it continues there through `continueThroughReadingList(to:)`, with
    //    an autoplay request that opens or brings forward its window and
    //    plays it; nil stops the reader there, which says why: Stop was
    //    chosen, the list ends, only finished books lie beyond, or the book
    //    has left the list.
    // 3. Next in Reading List and Previous in Reading List
    //    (`goThroughReadingList(_:)`) ask
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
