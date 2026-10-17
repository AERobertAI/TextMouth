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
    /// A feed's next episode, whose file is not here: it is downloaded, and
    /// listening goes on once it arrives (FR19). Only
    /// `LibraryViewModel.succession(after:going:skippingFinished:)` gives it.
    case episodeToDownload(feedID: UUID, item: FeedItem)
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
                saySleepTimerKeepsNextBookFromStarting(in: place, saying: say)
                return
            }
            // The next book takes over, so this one no longer rests finished
            // at its end.
            handOverToNextBook(to: next.id, titled: next.title) {
                start(next.id)
            }

        case .episodeToDownload(let feedID, let item):
            guard !sleepTimerEndsListening else {
                // No download either: nothing would play it.
                saySleepTimerKeepsNextBookFromStarting(in: place, saying: say)
                return
            }
            DiagnosticLog.trace(.playback, "end of book: the next episode of \(place) is not here; downloading it")
            say(EndOfBookWording.finished(
                book.title,
                notes: [EndOfBookWording.downloadingNextNote(item)],
                sleepTimerExpired: sleepTimerStoppedHere
            ))
            waitForNextEpisode(item, of: feedID, startingWith: start)
        }
    }

    /// Says that the next book was not started because this reader's sleep
    /// timer is in effect: the next book would play on past it, and the
    /// timer can pause only the reader that set it.
    private func saySleepTimerKeepsNextBookFromStarting(in place: String, saying say: (String) -> Void) {
        DiagnosticLog.trace(.playback, "end of book: this reader's sleep timer is in effect; not starting the next book in \(place)")
        say(EndOfBookWording.finished(book.title, notes: [EndOfBookWording.nextBookNotStartedNote]))
    }
}
