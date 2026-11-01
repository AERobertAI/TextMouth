import Foundation

// MARK: - A Sleep Timer Going on with the Next Book (0.2.5)

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
        moveAnnouncedAt = Date()
        moveCarriesSleepTimer = carriesSleepTimerOnAMove
        holdSleepTimer(forBook: nextBookID)
    }

    /// Holds the sleep timer this move carries for the book `nextBookID`: this
    /// reader's own, or one held for this book that a move on passes to the
    /// next. Nothing when no timer goes on (`carriesSleepTimerOnAMove`).
    func holdSleepTimer(forBook nextBookID: UUID) {
        let service = sleepTimerService
        guard !service.isHeld(forBook: nextBookID) else { return }
        if service.isCarriable(by: readerID) {
            service.hold(forBook: nextBookID, from: readerID)
        } else {
            service.passOnHold(fromBook: book.id, toBook: nextBookID)
        }
    }

    /// Refreshes the heading a timer for the end of the heading waits for,
    /// when this reader owns one: the heading after the cursor now. Called
    /// wherever the cursor or the headings change under such a timer: the
    /// book loading (a timer set while it loaded found no headings yet,
    /// finding #787), an edit of its text or manifest, a timer handed over to
    /// this reader, and a finished book starting over.
    func refreshSleepTimerHeading() {
        if sleepTimerService.waitsForHeadingEnd(ownedBy: readerID) {
            sleepTimerNextHeading = headingAfterCursor
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

    /// Releases the sleep timer held for the book `bookID`, which will not
    /// open: this reader's book failed to load or download, its window closed
    /// first, or the book the window was asked for is gone
    /// (`SleepTimerService.releaseHeld(forBook:)`, which stops the timer and
    /// tells the listener after current speech).
    func releaseSleepTimerHeld(forBook bookID: UUID) {
        if sleepTimerService.releaseHeld(forBook: bookID) {
            DiagnosticLog.trace(.playback, "next book: no reader took the sleep timer; stopped it")
        }
    }
}
