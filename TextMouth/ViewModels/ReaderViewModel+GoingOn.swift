import Foundation

/// What follows a finished book: the one answer the reading list, a plain
/// folder, and (FR19) a feed's folder each give when listening goes on from a
/// book that ended.
enum BookSuccession: Equatable {
    /// This book takes listening over.
    case book(Book)
    /// Nothing follows; the note says why, as the sentence after
    /// "Finished: <title>." says it.
    case nothing(note: String)
}

extension ReaderViewModel {

    /// Goes on from this finished book as `succession` says: the book it names
    /// takes listening over (`handOverToNextBook(to:titled:askingWith:)`),
    /// unless this reader's sleep timer is in effect, which could never pause
    /// it, or nothing follows. Then `say` says that the book finished and why
    /// nothing follows: the succession's note, or that the next book was not
    /// started because of the sleep timer.
    ///
    /// The one copy of the steps that the reading list's end
    /// (`followReadingListPastThisBook`) and Continue to Next Book
    /// (`continueToNextBookInFolder`) once each carried.
    ///
    /// - Parameters:
    ///   - succession: What follows this book.
    ///   - place: Where the succession was looked for, "the reading list" or
    ///     "its folder", for the debug log only.
    ///   - start: Opens the book with this ID to be played, after the
    ///     announcement that it is starting.
    ///   - sleepTimerEndsListening: Whether this reader's sleep timer is in
    ///     effect (`sleepTimerEndsListeningHere`).
    ///   - sleepTimerStoppedHere: Whether that timer stopped playback where
    ///     the book ended.
    ///   - say: Says what the listener hears when nothing follows: at the end,
    ///     it ends listening with it (`finishListening(announcing:)`).
    func goOnPastThisBook(
        to succession: BookSuccession,
        in place: String,
        startingWith start: @escaping (UUID) -> Void,
        sleepTimerEndsListening: Bool,
        sleepTimerStoppedHere: Bool,
        sayingNothingFollows say: (String) -> Void
    ) {
        switch succession {
        case .nothing(let note):
            DiagnosticLog.trace(.playback, "end of book: nothing follows in \(place) (\(note))")
            say(EndOfBookWording.finished(book.title, notes: [note], sleepTimerExpired: sleepTimerStoppedHere))

        case .book(let next):
            guard !sleepTimerEndsListening else {
                // The next book would play on past this reader's sleep timer,
                // which can pause only the reader that set it.
                DiagnosticLog.trace(.playback, "end of book: this reader's sleep timer is in effect; not starting the next book in \(place)")
                say(EndOfBookWording.finished(book.title, notes: [EndOfBookWording.nextBookNotStartedNote]))
                return
            }
            // The next book takes over, so this one no longer rests finished
            // at its end.
            handOverToNextBook(to: next.id, titled: next.title) {
                start(next.id)
            }
        }
    }
}
