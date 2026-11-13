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
/// method, which says what it does. It also keeps the duration a timer last
/// started with, in any window (`lastStartedDuration(savedIn:)`), which every
/// window's Restart Sleep Timer repeats.
///
/// Each timer registers itself as it is made, weakly, so a timer goes when its
/// window does. A timer held for a book is retained besides, until its hold
/// ends and any fade it is in is over (`noteHold(of:forBook:)`,
/// `setRetained(_:_:)`): a hold made just before its window closed must outlive
/// the window, as the one shared timer always outlived every window. So must
/// the mark that a held timer ran out for a book (`noteExpiredWhileHeld`),
/// which the registry keeps by book, because the timer that made it may be
/// gone by the time the book's reader asks.
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

    /// The timers held for a book, or fading out after being held, kept alive
    /// until their holds end and their fades are over.
    private var retainedWhileHeld: [ObjectIdentifier: SleepTimerService] = [:]

    /// The serial the next timer registered gets (`nextSerial()`).
    private var lastSerial = 0

    /// The books a held timer ran out for before their readers took it, each
    /// with the serial of the timer that ran out (`noteExpiredWhileHeld`). Kept
    /// here, by book, so the mark outlives the timer: a reader loading in a
    /// new window must still find that listening has ended, when the window
    /// the timer came from has closed and the timer is gone.
    private var expiredWhileHeld: [UUID: Int] = [:]

    /// A number for a timer being made that no other timer of this registry
    /// has, which names it in the marks it leaves (`expiredWhileHeld`) without
    /// keeping it alive, and is never reused as a memory address would be.
    func nextSerial() -> Int {
        lastSerial += 1
        return lastSerial
    }

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
        // Listed first: each stop below lets its timer go.
        let others = timers.filter { $0 !== timer && $0.isHeld(forBook: bookID) }
        for other in others {
            other.stop(reason: "another window's timer went on to the same book")
        }
    }

    /// Keeps `timer` alive (`retained` true) or lets it go. A timer is kept
    /// while it is held for a book and while a fade it was in when its hold
    /// ended runs on, so that the fade's expiry is said by the owner it was
    /// armed with (`SleepTimerService.updateRetention()` says when).
    func setRetained(_ timer: SleepTimerService, _ retained: Bool) {
        retainedWhileHeld[ObjectIdentifier(timer)] = retained ? timer : nil
    }

    /// Whether the registry keeps `timer` alive.
    func isRetaining(_ timer: SleepTimerService) -> Bool {
        retainedWhileHeld[ObjectIdentifier(timer)] != nil
    }

    // MARK: The Run-Out Mark

    /// Notes that the timer `serial` ran out while held for the book
    /// `bookID`, before the book's reader took it: that reader must not start
    /// the book (`consumeExpiredWhileHeld(forBook:)`). A timer marks one book
    /// at a time.
    func noteExpiredWhileHeld(forBook bookID: UUID, bySerial serial: Int) {
        forgetExpiredMarks(ofSerial: serial)
        expiredWhileHeld[bookID] = serial
    }

    /// The book the timer `serial` ran out for while it was held, if its
    /// reader has not asked yet.
    func expiredWhileHeldBook(bySerial serial: Int) -> UUID? {
        expiredWhileHeld.first { $0.value == serial }?.key
    }

    /// Forgets the mark the timer `serial` left: a timer that starts or is
    /// taken into has not run out, and a later hold is a new one.
    func forgetExpiredMarks(ofSerial serial: Int) {
        expiredWhileHeld = expiredWhileHeld.filter { $0.value != serial }
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
    /// (`SleepTimerService.consumeExpiredWhileHeld(forBook:)`). The mark is
    /// the registry's own, so it is found even when the timer that made it
    /// has gone with its window.
    func consumeExpiredWhileHeld(forBook bookID: UUID) -> Bool {
        expiredWhileHeld.removeValue(forKey: bookID) != nil
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

    // MARK: The Duration Last Started

    /// The duration a timer of this registry last started with, and the
    /// preferences store it saved it in; nil until a timer starts, and after
    /// it is forgotten. One app preference (`sleepTimer.lastUsedDuration`)
    /// holds it for later launches, but every window's timer reads it from
    /// here once one has started, as the one shared timer read the copy it
    /// kept: the duration one window started is the one another window's
    /// Restart repeats, at once, whatever the store answers meanwhile. (A
    /// GitHub runner's store answered an older value for seconds after a
    /// write, November 13, 2026.)
    private var lastStarted: (store: UserDefaults, duration: SleepTimerDuration)?

    /// Notes that a timer saving its last duration in `store` has started
    /// with `duration`.
    func noteStarted(_ duration: SleepTimerDuration, savedIn store: UserDefaults) {
        lastStarted = (store, duration)
    }

    /// The duration a timer saving in `store` last started with, or nil when
    /// none has since the registry was made or last forgot it: a timer then
    /// reads the duration saved in its store. A timer saving in another store,
    /// as a test's own timers do, never sees it.
    func lastStartedDuration(savedIn store: UserDefaults) -> SleepTimerDuration? {
        guard let lastStarted, lastStarted.store === store else { return nil }
        return lastStarted.duration
    }

    /// Forgets the duration last started in `store`, which a timer's reset
    /// for a test removes from the store too.
    func forgetLastStarted(savedIn store: UserDefaults) {
        if lastStarted?.store === store {
            lastStarted = nil
        }
    }

    // MARK: Test Support

    /// Stops every timer that runs or is held, so none a test made runs on
    /// into the next test, and the registry keeps none alive. It forgets the
    /// duration last started too, so each test's timers read the saved one
    /// until one of them starts. Production code must not call this.
    func _stopEveryTimerForTesting() {
        for timer in timers where timer.isActive || timer.isHolding {
            timer.stop(reason: "test ended")
        }
        retainedWhileHeld = [:]
        expiredWhileHeld = [:]
        lastStarted = nil
    }
}
