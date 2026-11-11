import Foundation

// MARK: - A Sleep Timer Going on with the Next Book (0.2.5)

/// What a move announced and not yet asked for did to the sleep timer's hold,
/// which a move that cancels it undoes (`ReaderViewModel.cancelPendingMoves()`).
enum PendingMoveHold: Equatable {
    /// The move held this reader's own timer for `target`: undoing it makes
    /// the timer this reader's own again, not held.
    case ownTimer(target: UUID)
    /// The move passed on a hold for this reader's own book, whose reader was
    /// still loading, to `target`: undoing it holds the timer for this
    /// reader's book again, asked as it was.
    case passedOn(target: UUID, wasAsked: Bool)

    /// The book the move held the timer for.
    var target: UUID {
        switch self {
        case .ownTimer(let target): return target
        case .passedOn(let target, _): return target
        }
    }
}

/// A move that has asked for its book, whose request to play it that book's
/// reader has not claimed yet: the last move wins until its book has started
/// (the user's question 17), so a later move from the same reader cancels it
/// within that span (`ReaderViewModel.cancelPendingMoves()`).
struct AskedMove: Equatable {
    /// The book the move asked for.
    let target: UUID
    /// What the move did to the sleep timer's hold, to be undone with it.
    let hold: PendingMoveHold?
    /// When the request to play the book was made, or nil when the move made
    /// none (a book only opened): the request that is this move's, which a
    /// request made later for the same book, by another move, is not (Y2).
    let requestMadeAt: Date?
}

/// The user's decision on November 1, 2026: "the sleeping timer in particular
/// I would like to move still running to the new book without a new window
/// opening". When listening goes on from this book to another, a running
/// timer this reader owns goes on with it: its owner becomes the reader that
/// takes the book, and its countdown is never restarted or reset.
///
/// The shared service holds the timer for the next book from the moment the
/// move is announced (`noteMoveAnnounced(to:)`, `SleepTimerService.hold`): it
/// stays this reader's, the one owner it has, whether this window closes in
/// the half second before the book is asked for, the book takes a long time
/// to download, or the book is opened in another window. The reader the book
/// goes on to takes it once it has loaded, before anything plays
/// (`claimSleepTimerHandOver()`), or at once when it is open already. When
/// the timer runs out first, it has ended listening: the next book is not
/// started. Every path that knows the book will not open releases the timer
/// (`releaseSleepTimerHeld(forBook:)`).
extension ReaderViewModel {

    /// Whether this reader owns a sleep timer that goes on with the next
    /// book: one that runs, counting minutes or waiting for the end of a
    /// heading or of a book, and is not fading out
    /// (`SleepTimerService.isCarriable(by:)`).
    var ownsCarriableSleepTimer: Bool {
        sleepTimerService.isCarriable(by: readerID)
    }

    /// Whether a move from this reader goes on carrying a sleep timer: this
    /// reader owns one that goes on, or holds one itself: the timer is held
    /// for this reader's book, which has not taken it yet because it is
    /// still loading, and a move to another book passes it on.
    var carriesSleepTimerOnAMove: Bool {
        ownsCarriableSleepTimer || sleepTimerService.isHeld(forBook: book.id)
    }

    /// Whether this reader's sleep timer is fading out, which ends listening
    /// at this book's end and when a book is asked for.
    var sleepTimerIsFadingOutHere: Bool {
        sleepTimerService.isFadingOut(ownedBy: readerID)
    }

    /// Notes, as a move to the book `nextBookID` is announced, when it was
    /// and whether it carries a sleep timer, and holds the timer for that
    /// book (`holdSleepTimer(forBook:)`): so `showNextBook` can tell, when it
    /// asks for the book, that the timer ran out meanwhile, and so closing
    /// this window in the meantime does not stop the timer.
    func noteMoveAnnounced(to nextBookID: UUID) {
        moveCarriesSleepTimer = carriesSleepTimerOnAMove
        moveExpiryMark = moveCarriesSleepTimer ? sleepTimerService.expiryCount : nil
        holdSleepTimer(forBook: nextBookID)
    }

    /// Holds the sleep timer this move carries for the book `nextBookID`: this
    /// reader's own, or one held for this book that a move on passes to the
    /// next. Nothing when no timer goes on (`carriesSleepTimerOnAMove`).
    func holdSleepTimer(forBook nextBookID: UUID) {
        let service = sleepTimerService
        guard !service.isHeld(forBook: nextBookID) else { return }
        if service.isCarriable(by: readerID) {
            if service.hold(forBook: nextBookID, from: readerID, isBookOpen: bookIsOpenCheck) {
                pendingMoveHold = .ownTimer(target: nextBookID)
            }
        } else {
            let wasAsked = service.isAsked(forBook: book.id)
            if service.passOnHold(fromBook: book.id, toBook: nextBookID, isBookOpen: bookIsOpenCheck) {
                pendingMoveHold = .passedOn(target: nextBookID, wasAsked: wasAsked)
            }
        }
    }

    /// Asks the library's registry of open readers whether a reader is open for
    /// a book, which a hold gives the service for its deadline: the one
    /// registry, so no second count is kept of the readers there are.
    var bookIsOpenCheck: (UUID) -> Bool {
        { [weak library = libraryViewModel] bookID in library?.openBookIDs.contains(bookID) ?? false }
    }

    /// Undoes the hold the move announced last made, if it is still in place
    /// and not asked for, and returns the timer to how it was before the move:
    /// this reader's own again, or held for this reader's own book again, asked
    /// as before. It also forgets the move's notes. A move that cancels it then
    /// holds the timer as any move does; the folder commands' download branch
    /// holds none, and the wait's own move carries the timer when the episode
    /// arrives.
    func undoPendingMoveHold() {
        let undoing = pendingMoveHold
        pendingMoveHold = nil
        moveCarriesSleepTimer = false
        moveExpiryMark = nil
        undo(undoing, evenIfAsked: false)
    }

    /// The move this reader asked for last, if its book's reader has not
    /// claimed the request to play it: the span in which a later move cancels
    /// it (`NextBookHandOver.isUnderWay` is the same span for a book's end),
    /// by the one meaning of the request still waiting
    /// (`ReaderRequestStore.hasRequest(for:madeAt:)`). It is the move's own
    /// request that must wait: a move whose request has been claimed, dropped,
    /// or has lapsed is forgotten, and a request made later for the same book
    /// never revives it (Y2).
    func underWayAskedMove() -> AskedMove? {
        guard let move = askedMove else { return nil }
        guard let madeAt = move.requestMadeAt,
              autoplayRequests.hasRequest(for: move.target, madeAt: madeAt) else {
            askedMove = nil
            return nil
        }
        return move
    }

    /// Cancels the move this reader asked for last while its book's reader has
    /// not started the book: the request to play it is discarded, so the book
    /// opens in its window without playing, and the hold the move made is
    /// undone, asked or not, unless the book has taken the timer already. The
    /// last move wins until its book has started (X1).
    func cancelAskedMoveUnderWay() {
        guard let move = underWayAskedMove() else { return }
        askedMove = nil
        autoplayRequests.discard(for: move.target)
        undo(move.hold, evenIfAsked: true)
    }

    /// Returns the timer to how it was before the move that made `hold`, and
    /// forgets that the timer ran out for the cancelled move's book: the move
    /// is gone, and a later move to that book must not find the mark (X2).
    ///
    /// The return is not a new carry (X3): a timer that has begun to fade out
    /// goes back too, and the move that cancels this one ends the fade as any
    /// move does (`beginMoveToAnotherBook()`).
    ///
    /// - Parameter evenIfAsked: Whether a hold the book has been asked for is
    ///   undone too, as the cancelling of a move whose book has not started
    ///   does, and not only one that is still waiting out the half second.
    private func undo(_ hold: PendingMoveHold?, evenIfAsked: Bool) {
        guard let hold else { return }
        let service = sleepTimerService
        let target = hold.target
        _ = service.consumeExpiredWhileHeld(forBook: target)
        guard service.isHeld(forBook: target), evenIfAsked || !service.isAsked(forBook: target) else { return }
        switch hold {
        case .ownTimer:
            // Only a hold that is still this reader's: another reader's hold
            // for the same book is not this move's to undo (Y2).
            if service.isHeld(from: readerID) {
                service.dropHold(forBook: target)
            }
        case .passedOn(_, let wasAsked):
            if service.passOnHold(
                fromBook: target, toBook: book.id, isBookOpen: bookIsOpenCheck, returning: true
            ) {
                if wasAsked { service.markAsked(forBook: book.id) }
            } else {
                // Not the reader's to put back: nothing is left held for a book
                // nobody will open.
                service.dropHold(forBook: target)
            }
        }
    }

    /// Refreshes the heading a timer for the end of the heading waits for,
    /// when this reader owns one: the heading after the place where playback
    /// reads now (`headingAfterPlaybackStart`). Called
    /// wherever the cursor or the headings change under such a timer: the
    /// book loading (a timer set while it loaded found no headings yet,
    /// finding #787), an edit of its text or manifest, a timer handed over to
    /// this reader, and a finished book starting over.
    func refreshSleepTimerHeading() {
        if sleepTimerService.waitsForHeadingEnd(ownedBy: readerID) {
            sleepTimerNextHeading = headingAfterPlaybackStart
        }
    }

    /// Takes over the sleep timer held for this book, once this reader has
    /// loaded (the headings a timer for the end of a heading waits for are
    /// known by then), and before anything plays.
    ///
    /// The timer changes hands (`SleepTimerService.adoptHeld`), and this
    /// reader gives it what a timer does to its book
    /// (`makeSleepTimerHandlers(fadeOutDuration:)`). A timer for the end of
    /// a heading then waits for the end of the heading playing in this book,
    /// and one for the end of the book for the end of this one. Its time
    /// left, its duration, and a countdown halted by the previous reader's
    /// pause are as they were; this reader's play resumes a halted one.
    ///
    /// A timer that ran out, or began to fade out, before this reader took it
    /// has ended listening, so the request to start this book is dropped, and
    /// nothing more is said: the timer said so as it ran out. A timer the
    /// listener cancelled or replaced meanwhile leaves nothing to take, and
    /// the book starts as asked.
    ///
    /// A closed reader, and one still loading, claims nothing: a reader
    /// loading claims as its load ends.
    func claimSleepTimerHandOver() {
        guard !hasClosed, !isLoading else { return }
        let service = sleepTimerService
        if service.consumeExpiredWhileHeld(forBook: book.id) {
            DiagnosticLog.trace(.playback, "next book: the sleep timer ended before this book took it; not starting")
            discardAutoplayRequest()
            return
        }
        // Held for this book and asked for: a timer only held, for a move still
        // waiting out the half second, is the old reader's until it asks.
        guard service.isAsked(forBook: book.id) else { return }
        // A fade begun before the take is putting the listener to sleep: it
        // ends listening, and the book is not started.
        if service.isFadingOut {
            DiagnosticLog.trace(.playback, "next book: the sleep timer began to fade out before this book took it; not starting")
            service.dropHold(forBook: book.id)
            discardAutoplayRequest()
            return
        }
        let handlers = makeSleepTimerHandlers(fadeOutDuration: service.fadeOutDuration)
        guard service.adoptHeld(
            forBook: book.id,
            as: readerID,
            onExpire: handlers.onExpire,
            onFadeStep: handlers.onFadeStep,
            onFadeCancelled: handlers.onFadeCancelled
        ) else { return }
        // A timer for the end of the heading waits for the end of the heading
        // the cursor is in now, in this book.
        refreshSleepTimerHeading()
        // As a timer started here does: a timer that stops playback at this
        // chapter's end is named so no file follows on, and audio near that
        // end fades from now on (TODO PERF09, P01).
        nameFileAfterCurrentChapter()
        fadeOutBeforeSleepTimerStop()
        DiagnosticLog.trace(.playback, "next book: took over the running sleep timer")
    }

    /// Releases the sleep timer held for the book `bookID`, which truly could
    /// not be opened: this reader's book failed to load or download, or the
    /// book the window was asked for is gone
    /// (`SleepTimerService.releaseHeld(forBook:announcingAfter:)`, which stops
    /// the timer and tells the listener, after current speech and, for a book
    /// that failed, once the reason has been read).
    ///
    /// - Parameter afterTheReason: Whether the book failed with a reason the
    ///   listener is being told, which the sentence must follow.
    func releaseSleepTimerHeld(forBook bookID: UUID, afterTheReason: Bool = false) {
        let delay = afterTheReason ? SleepTimerHandOverWording.afterTheReason : 0
        if sleepTimerService.releaseHeld(forBook: bookID, announcingAfter: delay) {
            DiagnosticLog.trace(.playback, "next book: no reader took the sleep timer; stopped it")
        }
    }
}
