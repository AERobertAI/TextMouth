import Combine
import Foundation

// MARK: - Every Window's Sleep Timer (November 13, 2026)

/// Every sleep timer the app has: one for each reader window on the Mac
/// (`ReaderWindowContent`), and the one the iPhone's readers share. The user,
/// November 13, 2026: "I want each sleep timer to be refactored to be per book
/// view window not global".
///
/// A window's timer answers for itself. The registry answers what no single
/// timer can: which timer is on its way to a book from whichever window
/// (`timer(heldForBook:)`), so the reader that opens the book takes it, every
/// path that knows the book will not open releases it, and a reader open for
/// the book in another window hears that it was asked for (`asksMade`). Each
/// of its calls about a book finds that one timer and calls the timer's own
/// method, which says what it does.
///
/// Each timer registers itself as it is made, weakly, so a timer goes when its
/// window does. A timer held for a book is retained besides, until its hold
/// ends (`noteHold(of:forBook:)`, `noteHoldEnded(of:)`): a hold made just
/// before its window closed must outlive the window, as the one shared timer
/// always outlived every window.
@MainActor
final class SleepTimerRegistry {
    /// The app's registry, which every timer joins unless a test gives it one
    /// of its own.
    static let shared = SleepTimerRegistry()

    /// Tells, with the book's ID, each time a timer held for a book is asked
    /// for (`SleepTimerService.markAsked(forBook:)`), so a reader already open
    /// for that book, in any window, takes the timer before it plays.
    let asksMade = PassthroughSubject<UUID, Never>()

    /// A timer held weakly, so the registry never keeps a window's timer alive.
    private struct WeakTimer {
        weak var timer: SleepTimerService?
    }

    /// Every timer registered, those gone included until the next
    /// registration sweeps them out.
    private var registered: [WeakTimer] = []

    /// The timers held for a book, kept alive until their holds end.
    private var retainedWhileHeld: [ObjectIdentifier: SleepTimerService] = [:]

    /// Joins `timer` to the registry, as it is made.
    func register(_ timer: SleepTimerService) {
        registered.removeAll { $0.timer == nil }
        registered.append(WeakTimer(timer: timer))
    }

    /// Every registered timer still in existence, in the order they were made.
    var timers: [SleepTimerService] {
        registered.compactMap(\.timer)
    }

    // MARK: Holds

    /// Notes that `timer` is now held for the book `bookID`: it is kept alive
    /// until its hold ends, and any other timer held for that book is stopped.
    /// Only one timer goes on to a book: two windows moving to one book within
    /// the same moment is the only way two could, and stopping the other,
    /// rather than releasing it, leaves no timer running for a reader that
    /// closed or moved on.
    func noteHold(of timer: SleepTimerService, forBook bookID: UUID) {
        retainedWhileHeld[ObjectIdentifier(timer)] = timer
        // Listed first: each stop below ends its hold through `noteHoldEnded`.
        let others = timers.filter { $0 !== timer && $0.isHeld(forBook: bookID) }
        for other in others {
            other.stop(reason: "another window's timer went on to the same book")
        }
    }

    /// Notes that `timer`'s hold has ended: it is no longer kept alive for it.
    func noteHoldEnded(of timer: SleepTimerService) {
        retainedWhileHeld[ObjectIdentifier(timer)] = nil
    }

    /// Whether the registry keeps `timer` alive for a hold.
    func isRetainingForAHold(_ timer: SleepTimerService) -> Bool {
        retainedWhileHeld[ObjectIdentifier(timer)] != nil
    }

    // MARK: Finding the Timer Held for a Book

    /// The timer held for the book `bookID`, in whichever window, if any.
    func timer(heldForBook bookID: UUID) -> SleepTimerService? {
        timers.first { $0.isHeld(forBook: bookID) }
    }

    /// Whether a timer, in any window, is held for the book `bookID`.
    func isHeld(forBook bookID: UUID) -> Bool {
        timer(heldForBook: bookID) != nil
    }

    /// Says that the book `bookID` has been asked for, so the reader that
    /// opens it may take the timer held for it
    /// (`SleepTimerService.markAsked(forBook:)`).
    func markAsked(forBook bookID: UUID) {
        timer(heldForBook: bookID)?.markAsked(forBook: bookID)
    }

    /// Ends the hold for the book `bookID` without stopping its timer
    /// (`SleepTimerService.dropHold(forBook:)`).
    func dropHold(forBook bookID: UUID) {
        timer(heldForBook: bookID)?.dropHold(forBook: bookID)
    }

    /// Whether a timer ran out while held for the book `bookID`, so that its
    /// reader must not start the book; forgotten once asked
    /// (`SleepTimerService.consumeExpiredWhileHeld(forBook:)`). Every timer
    /// is asked, since a timer that ran out is no longer held.
    func consumeExpiredWhileHeld(forBook bookID: UUID) -> Bool {
        // Every timer forgets the mark, though only one can hold it.
        timers.reduce(false) { found, timer in timer.consumeExpiredWhileHeld(forBook: bookID) || found }
    }

    /// Stops the timer held for the book `bookID`, which will not open, and
    /// tells the listener after `delay` (`SleepTimerService.releaseHeld`). A
    /// mark that a timer ran out for the book is forgotten, whichever timer
    /// keeps it.
    ///
    /// - Returns: Whether a timer was held for that book.
    @discardableResult
    func releaseHeld(
        forBook bookID: UUID,
        reason: String = "the book could not be opened",
        announcingAfter delay: TimeInterval = 0
    ) -> Bool {
        _ = consumeExpiredWhileHeld(forBook: bookID)
        return timer(heldForBook: bookID)?.releaseHeld(forBook: bookID, reason: reason, announcingAfter: delay) ?? false
    }

    /// Stops the timer held for the book `bookID` without a word, as the
    /// window of the book it was going to closes
    /// (`SleepTimerService.cancelHeld(forBook:)`), and forgets that a timer
    /// ran out for the book, whichever timer keeps the mark.
    func cancelHeld(forBook bookID: UUID) {
        _ = consumeExpiredWhileHeld(forBook: bookID)
        timer(heldForBook: bookID)?.cancelHeld(forBook: bookID)
    }

    // MARK: Test Support

    /// Stops every timer that runs or is held, so none a test made runs on
    /// into the next test, and the registry keeps none alive. Production code
    /// must not call this.
    func _stopEveryTimerForTesting() {
        for timer in timers where timer.isActive || timer.isHolding {
            timer.stop(reason: "test ended")
        }
        retainedWhileHeld = [:]
    }
}
