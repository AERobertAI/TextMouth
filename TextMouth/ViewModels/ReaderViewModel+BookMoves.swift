import Foundation

// MARK: - Moving to Another Book on a Command

/// Which way a command moves to another book, so the one step they share
/// asks for the book the way that route does.
enum BookMoveRoute: Equatable, Sendable {
    /// Next in Reading List and Previous in Reading List (FR09): the book is
    /// read from the list, and the window follows the global setting.
    case readingList
    /// Next in Folder and Previous in Folder (0.2.5): the book is opened as
    /// any book of its folder, and the window follows the feed's or folder's
    /// own choice, else the global one.
    case folder
}

/// What a command found when it began to move from this book: whether the
/// book was playing. A sleep timer of this reader's goes on with the next
/// book (`ReaderViewModel.noteMoveAnnounced(to:)`), so it keeps nothing from
/// starting.
struct BookMoveStart: Equatable, Sendable {
    /// Whether this book was playing: speech or audio under way, or paused
    /// only while a Where Am I announcement speaks, or until the end sound
    /// of one that ended has played (`ReaderViewModel.whereAmIWillPlayBook`).
    let wasPlaying: Bool
    /// Whether the move ended a sleep timer fading out: the pause the move
    /// begins with ends a fade as the listener's own Pause does, and the
    /// listener did not ask to cancel the timer, so it is told after
    /// "Starting: <title>" (`SleepTimerHandOverWording.fadeEndedByTheMove`).
    var timerFadeEnded = false

    /// Whether the book moved to plays: this one was playing.
    var plays: Bool { wasPlaying }
}

extension ReaderViewModel {

    /// Begins a move from this book to another, which the reading list's and
    /// the folder's Next and Previous share: reads whether this book was
    /// playing, and pauses it. A running sleep timer of this reader's goes on
    /// with the next book, its countdown halted by the pause until that book
    /// plays; one fading out ends, as a pause during its fade ends it
    /// (`pause(playingPauseSound:)`).
    ///
    /// A playing book pauses where it is, without the pause sound, since the
    /// book that starts makes its own; a Where Am I announcement speaking
    /// ends with that pause, without resuming its book, even for a book that
    /// was not playing, whose announcement would otherwise speak over the one
    /// moved to.
    ///
    /// A book that a move brought here, and that has not started yet, counts as
    /// playing: its book is still loading with a request to play it waiting
    /// (`ReaderAutoplayRequests`), or an earlier move of this reader to play
    /// was announced and not yet asked for. A second move then goes on to play
    /// its book, and carries the sleep timer held for this one
    /// (`holdSleepTimer(forBook:)`); the request to play this book is dropped,
    /// since the listener has moved on from it.
    func beginMoveToAnotherBook() -> BookMoveStart {
        let startPending = autoplayRequests.hasRequest(for: book.id)
        // A move cancelled by this one, or a wait for an episode it ends, was
        // to play its book: this book counts as playing then.
        // The last move wins until its book has started: a move asked for
        // whose book is still to claim its request to play was to play it, as
        // this book counts as playing then (X1).
        let wasPlaying = isPlaybackUnderWay || whereAmIWillPlayBook || pendingMovePlays || startPending
            || episodeWaitPlays || nextBookHandOver?.isPendingAsk == true || underWayAskedMove() != nil
        if startPending {
            autoplayRequests.discard(for: book.id)
        }
        // A reader has one move pending, however it began: this move cancels an
        // earlier one that has not asked yet (an announced command or the end
        // of a book's hand-over) and ends the wait for an episode.
        cancelPendingMoves()
        nextEpisodeWait = nil
        let pauses = wasPlaying || isWhereAmIUnderWay
        // A move ends the fade of any timer it carries, wherever it is held
        // (X3, Y1): this reader's own, held for another book or not, or one
        // held for this book, as a target still loading carries, in this
        // window or the one it is coming from. The fade and the timer end,
        // the book moved to starts, and the listener is told. The pause comes
        // first, so the owner's volume is restored only once its audio is
        // silent; a pause leaves a held fade alone, as the listener's own
        // Pause does (W2), so the stop is not left to it.
        let fading = sleepTimerFadingOutWithThisMove
        if pauses {
            pause(playingPauseSound: false)
        }
        if let fading, fading.isFadingOut {
            fading.stop(reason: "a move ended the fade of a timer it carries")
        }
        return BookMoveStart(wasPlaying: wasPlaying, timerFadeEnded: fading.map { !$0.isFadingOut } ?? false)
    }

    /// The sleep timer fading out that a move from this reader carries: its
    /// own window's, when this reader owns it, or one held for this reader's
    /// book, wherever it is held; nil when neither fades.
    private var sleepTimerFadingOutWithThisMove: SleepTimerService? {
        let own = sleepTimerService
        if own.isFadingOut, own.ownerID == readerID {
            return own
        }
        if let carried = sleepTimers.timer(heldForBook: book.id), carried.isFadingOut {
            return carried
        }
        return nil
    }

    /// Cancels a move this reader announced and has not asked for yet: a
    /// command's pending ask (`announceMove`) and the end of a book's
    /// hand-over (`handOverToNextBook`), and a move asked for whose book has
    /// not started (`cancelAskedMoveUnderWay()`: the last move wins). The hold
    /// the cancelled move made is undone (`undoPendingMoveHold()`): a cancelled
    /// move leaves no trace, and the move that cancels it holds the timer as
    /// any move does.
    func cancelPendingMoves() {
        cancelAskedMoveUnderWay()
        undoPendingMoveHold()
        pendingMoveGeneration += 1
        pendingMovePlays = false
        nextBookHandOver?.cancel()
    }

    /// Says, after current speech, that the move ended a sleep timer fading out
    /// (`BookMoveStart.timerFadeEnded`): the listener did not ask to cancel it.
    /// Every move says it, the download branch of the folder commands included.
    func announceTimerFadeEndedIfNeeded(by start: BookMoveStart) {
        if start.timerFadeEnded {
            announceToVoiceOverAfterCurrentSpeech(SleepTimerHandOverWording.fadeEndedByTheMove)
        }
    }

    /// Says that the book `bookID`, titled `title`, is starting or opening,
    /// and asks for it once VoiceOver has begun saying so: "Starting:
    /// <title>" for a book that plays (`EndOfBookWording.starting(_:)`),
    /// "Opening: <title>" for one that does not
    /// (`ReadingListReaderWording.opening(_:)`). A running sleep timer of this
    /// reader's is held for the book, so a timer that runs out before the book
    /// is asked for ends listening, and closing this window meanwhile stops
    /// nothing (`noteMoveAnnounced(to:)`). The book is asked for after
    /// `continueToNextBookDelay`, as Continue to Next Book asks for its book,
    /// so the announcement is not cut off by the next book's window or by the
    /// switch of this one. A later move of this reader announced before the
    /// ask cancels it: Next then Previous asks once.
    func announceMove(
        to bookID: UUID,
        titled title: String,
        start: BookMoveStart,
        through route: BookMoveRoute
    ) {
        announceToVoiceOver(
            start.plays ? EndOfBookWording.starting(title) : ReadingListReaderWording.opening(title)
        )
        // Said after "Starting", and after current speech: the listener did
        // not ask to cancel the timer the move's pause ended.
        announceTimerFadeEndedIfNeeded(by: start)
        noteMoveAnnounced(to: bookID)
        pendingMoveGeneration += 1
        let generation = pendingMoveGeneration
        pendingMovePlays = start.plays
        let plays = start.plays
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
            guard self.pendingMoveGeneration == generation else { return }
            self.pendingMovePlays = false
            self.askForBook(bookID, plays: plays, through: route)
        }
    }

    /// Asks for the book `bookID`, which a command moved to, as `route` asks:
    /// to be played, as a book that ends continues to the next one
    /// (`continueThroughReadingList(to:)`, `continueToNextBook(_:under:)`), or
    /// only opened (`openFromReadingList(_:)`, `openInFolder(_:)`). Also what
    /// an episode that was downloaded first is asked for with.
    func askForBook(_ bookID: UUID, plays: Bool, through route: BookMoveRoute) {
        switch (route, plays) {
        case (.readingList, true): continueThroughReadingList(to: bookID)
        case (.readingList, false): openFromReadingList(bookID)
        case (.folder, true): continueToNextBook(bookID, under: folderMoveWindowChoice)
        case (.folder, false): openInFolder(bookID)
        }
    }
}
