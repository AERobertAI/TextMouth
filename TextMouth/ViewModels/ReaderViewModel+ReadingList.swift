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

    // MARK: - The End of a Book Read from the List

    /// Ends this book, read from the reading list, as the list's "When a
    /// book ends" says, in place of the book's own end-of-book behavior:
    /// the user decided on October 7, 2026 that "the reading list open mode
    /// should override it". `handleEndOfBook()` calls it once the book's
    /// listening session has closed and the book rests finished at its end.
    ///
    /// The book is counted finished, as a book that stops or continues is,
    /// before the list is asked what follows, so it is never its own answer.
    /// The book below or above it, passing over finished books while the
    /// list says so, then opens to be read from the list and plays, as
    /// Continue to Next Book starts the next book in a folder: "Starting:
    /// <title>", a moment for VoiceOver to begin saying it, then the
    /// requests and the window (`continueThroughReadingList(to:)`). Nothing
    /// follows for Stop, at that end of the list, or past only finished
    /// books, and the book says which. The sleep timer keeps its rules: this
    /// reader's timer in effect starts nothing, since it could never pause
    /// the next book, and a timer that stopped playback here says so last.
    ///
    /// - Parameters:
    ///   - sleepTimerEndsListening: Whether this reader's sleep timer was in
    ///     effect as the book ended (`sleepTimerEndsListeningHere`).
    ///   - sleepTimerStoppedHere: Whether that timer stopped playback here,
    ///     at the end of the heading or of the book.
    func finishBookReadFromReadingList(sleepTimerEndsListening: Bool, sleepTimerStoppedHere: Bool) {
        readingStatsService.markBookFinished(bookID: book.id, title: book.title)
        savePosition()
        guard let next = libraryViewModel.readingListContinuation(after: book.id) else {
            let note = readingListEndNote()
            DiagnosticLog.trace(.playback, "end of book: nothing follows in the reading list (\(note))")
            finishListening(
                announcing: EndOfBookWording.finished(book.title, notes: [note], sleepTimerExpired: sleepTimerStoppedHere)
            )
            return
        }
        guard !sleepTimerEndsListening else {
            DiagnosticLog.trace(.playback, "end of book: this reader's sleep timer is in effect; not starting the next book in the reading list")
            finishListening(
                announcing: EndOfBookWording.finished(book.title, notes: [EndOfBookWording.nextBookNotStartedNote])
            )
            return
        }
        announceToVoiceOver(EndOfBookWording.starting(next.title))
        // Asked for once VoiceOver has begun the announcement. This reader
        // is kept until then, so closing its window meanwhile still
        // continues, as announced.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
            self.continueThroughReadingList(to: next.id)
        }
    }

    /// Opens the book `nextBookID` to be read from the reading list, and
    /// starts it: the request to read it from the list comes first, so a
    /// reader already open for it claims that one at once, and then the
    /// book continues as Continue to Next Book continues to the next book in
    /// a folder (`continueToNextBook(_:)`): a request to start playing, and
    /// the notification that opens its window or brings it forward.
    func continueThroughReadingList(to nextBookID: UUID) {
        readingListRequests.request(for: nextBookID)
        continueToNextBook(nextBookID)
    }

    /// Why nothing follows this book at its end in the reading list, as the
    /// sentence after "Finished: <title>." says it: Stop is chosen, or no
    /// book, or only finished books, lie the way the list continues.
    private func readingListEndNote() -> String {
        guard let direction = libraryViewModel.readingList.continuation.direction else {
            return ReadingListReaderWording.stopNote
        }
        return ReadingListReaderWording.endNote(readingListEnd(going: direction), going: direction)
    }

    /// What lies beyond this book going `direction` through the reading
    /// list, when the list offers no book that way: no book at all, or only
    /// books already finished, which the list passed over.
    func readingListEnd(going direction: ReadingList.Direction) -> ReadingListEnd {
        let anyBook = libraryViewModel.readingListNeighbor(of: book.id, direction: direction, skippingFinished: false)
        return anyBook == nil ? .noBookBeyond : .onlyFinishedBooksBeyond
    }
}
