import Foundation

// MARK: - A Sleep Timer Going on with the Next Book (0.2.5)

/// The user's decision on November 1, 2026: "the sleeping timer in particular
/// I would like to move still running to the new book without a new window
/// opening". When listening goes on from this book to another, a running
/// timer this reader owns goes on with it: its owner becomes the reader that
/// takes the book, and its countdown is never restarted or reset.
///
/// The old reader asks as it shows the next book (`showNextBook`), in its own
/// window or another, by every way listening goes on; the reader the book
/// goes on to takes the timer once it has loaded, before anything plays
/// (`claimSleepTimerHandOver()`), or as the request is made when it is open
/// already. When the timer runs out first, it has ended listening: the next
/// book is not started.
extension ReaderViewModel {

    /// What the listener hears when a sleep timer that was to go on with the
    /// next book could not, because the book could not be opened: the timer
    /// is cancelled rather than left to count toward pausing nothing.
    nonisolated static let sleepTimerCancelledNoBookAnnouncement =
        "Sleep timer cancelled, because the next book could not be opened."

    /// Whether this reader owns a sleep timer that goes on with the next
    /// book: one that runs, counting minutes or waiting for the end of a
    /// heading or of a book, and is not fading out. A timer fading out is
    /// putting the listener to sleep, and ends listening instead.
    var ownsCarriableSleepTimer: Bool {
        sleepTimerService.isActive
            && sleepTimerService.ownerID == readerID
            && !sleepTimerService.isFadingOut
    }

    /// Whether this reader's sleep timer ran out, or began to fade out, which
    /// has ended listening: a book listening was to go on to is not started
    /// then. A timer the listener cancelled has not: nothing carries it, and
    /// the book starts as asked.
    var sleepTimerEndedListening: Bool {
        sleepTimerService.didExpire(whileOwnedBy: readerID)
            || (sleepTimerService.isActive
                && sleepTimerService.ownerID == readerID
                && sleepTimerService.isFadingOut)
    }

    /// Whether this reader's close would leave its sleep timer running for
    /// the reader that is to take it: it asked for the book to take it, and
    /// nobody has yet.
    var isWaitingForTheSleepTimerToBeTaken: Bool {
        sleepTimerHandedOverTo.map { sleepTimerHandOvers.hasRequest(for: $0) } ?? false
    }

    /// Notes, as a move to another book is announced, whether it is to carry
    /// a running sleep timer of this reader's, so that `showNextBook` can
    /// tell, when it asks for the book, that the timer ran out meanwhile.
    func noteMoveAnnounced() {
        moveCarriesSleepTimer = ownsCarriableSleepTimer
    }

    /// Asks the reader of `nextBookID` to take over this reader's sleep
    /// timer, as the book is asked for: made before the notification that
    /// opens a window, and before the switch of this one, so whichever
    /// reader the book goes to finds it. Nothing is asked when this reader
    /// owns no timer that goes on (`ownsCarriableSleepTimer`).
    func handOverSleepTimer(to nextBookID: UUID) {
        guard ownsCarriableSleepTimer else { return }
        DiagnosticLog.trace(.playback, "next book: the running sleep timer goes on with it")
        sleepTimerHandedOverTo = nextBookID
        sleepTimerHandOvers.request(for: nextBookID, from: readerID)
    }

    /// Takes over the sleep timer that the reader listening went on from
    /// asked this book's reader to take, once this reader has loaded (the
    /// headings a timer for the end of a heading waits for are known by
    /// then), and before anything plays.
    ///
    /// The timer changes hands (`SleepTimerService.transferOwnership`), and
    /// this reader gives it what a timer does to its book
    /// (`makeSleepTimerHandlers(fadeOutDuration:)`). A timer for the end of
    /// a heading then waits for the end of the heading playing in this book,
    /// and one for the end of the book for the end of this one. Its time
    /// left, its duration, and a countdown halted by the previous reader's
    /// pause are as they were; this reader's play resumes a halted one.
    ///
    /// A timer that ran out, or began to fade out, before this reader took it
    /// has ended listening, so the request to start this book is dropped, and
    /// nothing more is said: the timer said so as it ran out. One the listener
    /// cancelled or replaced meanwhile leaves nothing to take, and the book
    /// starts as asked.
    ///
    /// A closed reader, and one still loading, claims nothing: a reader
    /// loading claims as its load ends.
    func claimSleepTimerHandOver() {
        guard !hasClosed, !isLoading, let handOver = sleepTimerHandOvers.consume(for: book.id) else { return }
        let previous = handOver.previousOwnerID
        let service = sleepTimerService
        let handlers = makeSleepTimerHandlers(fadeOutDuration: service.fadeOutDuration)
        guard service.transferOwnership(
            from: previous,
            to: readerID,
            onExpire: handlers.onExpire,
            onFadeStep: handlers.onFadeStep,
            onFadeCancelled: handlers.onFadeCancelled
        ) else {
            let endedListening = service.didExpire(whileOwnedBy: previous)
                || (service.isActive && service.ownerID == previous && service.isFadingOut)
            DiagnosticLog.trace(
                .playback,
                "next book: the sleep timer \(endedListening ? "ended before this book took it; not starting" : "was cancelled or replaced")"
            )
            if endedListening {
                discardAutoplayRequest()
            }
            return
        }
        // A timer for the end of the heading waits for the end of the heading
        // the cursor is in now, in this book.
        if service.waitsForHeadingEnd(ownedBy: readerID) {
            sleepTimerNextHeading = headingAfterCursor
        }
        // As a timer started here does: a timer that stops playback at this
        // chapter's end is named so no file follows on, and audio near that
        // end fades from now on (TODO PERF09, P01).
        nameFileAfterCurrentChapter()
        fadeOutBeforeSleepTimerStop()
        DiagnosticLog.trace(.playback, "next book: took over the running sleep timer")
    }

    /// Lets go of a request to take over the sleep timer that this reader
    /// cannot take, because its book could not be opened or its window
    /// closed first, and stops the timer: it would count toward pausing a
    /// book nobody plays, and the sheet would show a timer that does nothing.
    ///
    /// - Parameter announcing: Whether to tell the listener, as when the book
    ///   fails to open; a window closed by the listener says nothing.
    func discardSleepTimerHandOver(announcing: Bool) {
        guard let handOver = sleepTimerHandOvers.consume(for: book.id) else { return }
        let service = sleepTimerService
        guard service.isActive, service.ownerID == handOver.previousOwnerID else { return }
        service.stop(reason: "the next book could not take it")
        DiagnosticLog.trace(.playback, "next book: no reader took the sleep timer; stopped it")
        if announcing {
            announceToVoiceOver(Self.sleepTimerCancelledNoBookAnnouncement)
        }
    }
}
