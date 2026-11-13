import Foundation
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One sleep timer: each reader window has its own (November 13, 2026, the
/// user: "I want each sleep timer to be refactored to be per book view
/// window not global"), kept by the window's content above each book it
/// shows (`ReaderWindowContent`), so it stays with the window when
/// listening goes on to another book in place. The iPhone, which shows one
/// reader at a time, has one, `SleepTimerService.shared`, which its readers
/// share. Every timer joins the registry of every window's timer
/// (`SleepTimerRegistry`), which finds a timer on its way to a book from
/// another window.
///
/// Until November 13 the app had one timer for every window: a book opened
/// beside another that held a paused timer showed that timer, which its own
/// playback could neither run nor stop, and a timer set in one window
/// replaced another's.
///
/// ## Owner-scoped pause/resume
/// The minutes-based countdown is paused alongside playback so a timer
/// set before a long break doesn't expire silently in the background and
/// pause the user mid-sentence after they resume. A window's timer is
/// driven by one reader at a time, its owner: the reader of the book the
/// window shows, or, while the window goes on to another book, the reader
/// before it until the next one takes the timer. Each playback action
/// passes its `ownerID`, the reader's own ID (`ReaderViewModel.readerID`),
/// and a mismatching ID is silently ignored, so the closing reader of a
/// window that switched books never touches the timer its successor took.
@MainActor
final class SleepTimerService: ObservableObject {
    #if os(iOS)
    /// The iPhone's one timer: the phone shows one reader at a time, and
    /// every reader its session makes shares it. The Mac has none: each of
    /// its reader windows has a timer of its own.
    static let shared = SleepTimerService()
    #endif

    @Published var isActive = false
    @Published var remainingSeconds: Int = 0
    @Published var duration: SleepTimerDuration?
    @Published var isFadingOut = false

    /// Fired when the timer finishes (after any fade-out). Set by the
    /// owner via `start(...)`; cleared on stop. Only one handler at a
    /// time — replacing the timer replaces the handler.
    var onTimerExpired: (() -> Void)?
    /// Called during fade-out with a volume value from 1.0 down to 0.0.
    /// Set by the owner via `start(...)`; cleared on stop.
    var onFadeStep: ((Float) -> Void)?
    /// Restores the owning playback backend when an in-progress fade is
    /// cancelled, restarted, or replaced by another reader's timer.
    var onFadeCancelled: (() -> Void)?

    /// Fade-out duration in seconds (0 = instant pause, no fade)
    var fadeOutDuration: TimeInterval = 0

    /// Identifier of the reader that started the current timer. Used to
    /// gate `pauseCountdown(by:)`, `resumeCountdown(by:)`, and the
    /// heading/chapter-end notifications so another reader's playback
    /// events, even those of a second window of the same book, can't
    /// accidentally affect this timer.
    /// Nil means no active owner (timer is stopped, or was started
    /// without an owner — the latter only in tests).
    private(set) var ownerID: UUID?

    /// Most recently used duration, in any window: one preference for the
    /// app (`sleepTimer.lastUsedDuration`), saved by `start()`, so the
    /// "Restart Sleep Timer" shortcut and the media-gesture detector re-arm a
    /// fresh timer with the duration the user last picked, wherever they
    /// picked it, even after that timer has fully expired, and after the app
    /// restarts. Once any window's timer has started, the registry's copy
    /// answers (`SleepTimerRegistry.lastStartedDuration(savedIn:)`), as the
    /// one shared timer's own copy did; until then, the preference does.
    var lastUsedDuration: SleepTimerDuration? {
        registry.lastStartedDuration(savedIn: userDefaults) ?? savedLastUsedDuration
    }

    /// The duration saved in the preferences as the one last used, by this
    /// launch or an earlier one; nil when none is saved, or the saved one
    /// cannot be read.
    private var savedLastUsedDuration: SleepTimerDuration? {
        guard let data = userDefaults.data(forKey: Self.lastUsedDurationKey) else { return nil }
        // Encoded as JSON for forward-compatibility — adding new
        // SleepTimerDuration cases later won't break decoding old
        // saved values, since unknown cases just fail to decode and
        // we treat that as "no last duration".
        guard let decoded = try? JSONDecoder().decode(PersistedDuration.self, from: data) else {
            timerLog(.event, "RESTORE_LAST_DURATION result=decode-failed bytes=\(data.count)")
            return nil
        }
        return decoded.toModel()
    }

    /// The reader that owned the timer when it last ran out, whether it
    /// stopped the book at once or after a fade, kept until a timer starts
    /// or changes hands, and which expiry it was (`lastExpiryNumber`). A
    /// reader that a finished book's timer was to move to asks it
    /// (`didExpire(whileOwnedBy:sinceExpiry:)`):
    /// a timer that ran out before the next book took it has ended
    /// listening, and the next book must not start.
    private(set) var lastExpiredOwnerID: UUID?
    /// How many times a timer has run out, from the app's start: a counter
    /// that only goes up, so a move or an episode's wait notes it as it begins
    /// and asks whether the timer ran out since, whatever the wall clock does
    /// meanwhile.
    private(set) var expiryCount = 0
    /// The number of the expiry `lastExpiredOwnerID` ran out in.
    private(set) var lastExpiryNumber = 0

    // MARK: Held for the Next Book (0.2.5)

    /// How long a timer is held for a book that never takes it, in seconds,
    /// before it is stopped as a last resort: twenty minutes, far longer
    /// than any download or load of a book takes. Every path that knows the
    /// book will not open releases the timer at once (`releaseHeld(forBook:)`);
    /// this only catches the paths nobody knew of.
    nonisolated static let heldTimerDeadline: TimeInterval = 20 * 60

    /// The book the running timer is held for: listening goes on to it, and
    /// the reader that opens it takes the timer
    /// (`take(heldForBook:from:as:...)`, which an in-place switch does as
    /// `adoptHeld(forBook:as:...)`).
    /// From the moment the move is announced until then, the timer stays its
    /// previous owner's, the one owner it has, and nothing ages the hold but
    /// `heldTimerDeadline`: not the 30 seconds a request to a reader lives, so
    /// a book that takes a long time to download is not lost.
    private(set) var heldForBookID: UUID?
    /// The reader the held timer goes on from: its owner meanwhile.
    private var heldFromOwnerID: UUID?
    /// Counts holds, so a deadline made for an earlier one does nothing.
    private var holdGeneration = 0
    /// Asks whether a reader is open for a book, which the reader that made
    /// the hold gave (`hold(forBook:from:deadline:isBookOpen:)`): the library's
    /// registry of open readers, which this service does not know. A reader
    /// open for the book the timer is held for is the one opening it, and is
    /// responsible for the timer, which it releases on every way it can fail,
    /// so the deadline acts only when no reader is open for the book. Cleared
    /// with the hold; a hold made with no check has no reader to wait for.
    private var heldBookIsOpen: ((UUID) -> Bool)?
    /// The book this timer ran out for while it was held, before its reader
    /// took it: that reader must not start the book
    /// (`consumeExpiredWhileHeld(forBook:)`). The mark is the registry's, kept
    /// by book, so it outlives this timer when its window has closed and the
    /// registry has let the timer go.
    var expiredWhileHeldBookID: UUID? {
        registry.expiredWhileHeldBook(bySerial: serial)
    }
    /// The book the held timer has been asked for: the move's announcement
    /// holds the timer, and the ask, half a second later, lets the reader take
    /// it (`markAsked(forBook:)`). Until then a timer that runs out ends
    /// listening before the book starts, which only the old reader, still its
    /// owner, can tell.
    private(set) var askedBookID: UUID?

    /// The registry of every window's timer, which this timer joins as it is
    /// made: it tells each ask to the readers of every window
    /// (`SleepTimerRegistry.asksMade`), keeps this timer alive while it is
    /// held for a book, and keeps one timer held for each book.
    let registry: SleepTimerRegistry

    /// This timer's number in its registry, which names it in the run-out
    /// marks the registry keeps (`SleepTimerRegistry.noteExpiredWhileHeld`).
    private let serial: Int

    private static let lastUsedDurationKey = "sleepTimer.lastUsedDuration"

    /// Preferences store used for the restart-timer duration: this process's
    /// preferences, which are the standard store in the app and the
    /// sandboxed one under hosted tests. Tests may also inject a suite of
    /// their own, so resetting a fixture never removes a duration that
    /// another test, or the user, saved.
    private let userDefaults: UserDefaults

    private var timer: Timer?
    private var fadeTimer: Timer?
    /// Generation counter to prevent stale fade/expire callbacks from firing after stop()
    private var generation: Int = 0
    /// One-shot latch set after the final fade step lands at volume 0
    /// but before the owner callback pauses playback and restores volume.
    /// `isFadingOut` must flip back to false so UI state and formatted
    /// status stop saying "Fading out", yet the playback layer still
    /// needs to know this expiry came from a fade-completion path rather
    /// than an ordinary pause. Consumed by ReaderViewModel.pause().
    private var pendingFadeCompletion = false
    /// True when the minutes-based countdown is currently halted because
    /// playback is paused. The repeating Timer is invalidated and
    /// `remainingSeconds` is preserved; `resumeCountdown()` re-arms it
    /// with the same remaining time. Fade timers are NOT paused —
    /// once a fade has begun, the user is already being put to sleep
    /// and halting the fade would leave audio at an arbitrary low volume.
    private var isCountdownPausedByPlayback = false

    #if os(iOS)
    /// The countdown's deadline on the iPhone while it runs: set as the
    /// countdown is armed, at its start and at each resume, and cleared as it
    /// halts, runs out, or the timer stops. Each tick reads what is left from
    /// it (`PhoneSleepDeadline`), so a late tick loses no time, where the
    /// Mac's countdown takes one second off at each tick. The Mac has no such
    /// property, and its ticks stay as they are.
    private var phoneDeadline: PhoneSleepDeadline?
    /// Begins holding the iPhone app awake for a timer that has run out, and
    /// gives back what ends the hold. The phone's life cycle sets it to a
    /// background task: with the screen locked, the fade's last step is the
    /// last audio, and iOS may suspend an app with no audio almost at once,
    /// before the book's place is saved and flushed. Nil holds nothing, as in
    /// tests.
    var phoneExpiryHold: (@MainActor () -> (@MainActor () -> Void))?
    /// What ends the hold begun as the timer ran out, until it has ended.
    private var endPhoneExpiryHold: (@MainActor () -> Void)?
    #endif

    /// A timer, which joins `registry` as it is made. The preferences keep the
    /// duration last used; hosted tests give disposable ones.
    ///
    /// - Parameters:
    ///   - userDefaults: Where the duration last used is kept: this process's
    ///     preferences, unless a test gives its own.
    ///   - registry: The registry of every timer: the app's, read here rather
    ///     than as a default argument, inside this main-actor initializer,
    ///     unless a test gives one of its own.
    init(userDefaults: UserDefaults = TextMouthRuntime.current.preferences, registry: SleepTimerRegistry? = nil) {
        self.userDefaults = userDefaults
        self.registry = registry ?? .shared
        self.serial = self.registry.nextSerial()
        self.registry.register(self)
    }

    /// Record a line in the timer's own log (`DiagnosticLog.File.sleepTimer`).
    /// Shortcut routing and playback code use it too, so one file holds the
    /// complete path from an input event through expiry handling. Every line
    /// is an event, always written, except the countdown's progress ticks,
    /// which are trace.
    nonisolated static func log(_ level: DiagnosticLog.Level, _ message: @autoclosure () -> String) {
        DiagnosticLog.log(level, .playback, message(), in: .sleepTimer)
    }

    /// Short owner tokens make multi-window routing diagnosable without
    /// filling every event with a full UUID.
    private static func ownerToken(_ ownerID: UUID?) -> String {
        ownerID.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    /// Record `event` at `level` together with the state needed to
    /// reconstruct timer behavior after the fact. The state is described
    /// only when the line is written.
    private func timerLog(_ level: DiagnosticLog.Level, _ event: String) {
        Self.log(
            level,
            "\(event) active=\(isActive) duration=\(duration?.displayName ?? "none") "
                + "remaining=\(remainingSeconds) fading=\(isFadingOut) "
                + "countdownPaused=\(isCountdownPausedByPlayback) "
                + "owner=\(Self.ownerToken(ownerID)) generation=\(generation)"
        )
    }

    // MARK: - Last-Used-Duration Persistence

    /// Remember a duration as the most recently used, for every window: in
    /// the registry, which every window's timer reads it from, and in the
    /// preferences, for later launches. Called from `start()` whenever a
    /// fresh timer is configured. Failures to encode are swallowed: the timer
    /// runs all the same, Restart Sleep Timer repeats it in this launch, and
    /// a later launch repeats the duration saved before, the saving being
    /// only a convenience.
    private func rememberLastUsedDuration(_ duration: SleepTimerDuration) {
        registry.noteStarted(duration, savedIn: userDefaults)
        let model = PersistedDuration(from: duration)
        if let data = try? JSONEncoder().encode(model) {
            userDefaults.set(data, forKey: Self.lastUsedDurationKey)
            timerLog(.event, "PERSIST_LAST_DURATION result=saved value=\(duration.displayName)")
        } else {
            timerLog(.event, "PERSIST_LAST_DURATION result=encode-failed value=\(duration.displayName)")
        }
    }

    /// Codable bridge for SleepTimerDuration. The enum's associated
    /// value (.minutes(Int)) doesn't get an automatic Codable
    /// implementation, so this struct flattens it to (kind, value).
    private struct PersistedDuration: Codable {
        let kind: String
        let minutes: Int?

        init(from duration: SleepTimerDuration) {
            switch duration {
            case .minutes(let m):
                kind = "minutes"
                minutes = m
            case .endOfHeading:
                kind = "endOfHeading"
                minutes = nil
            case .endOfBook:
                kind = "endOfBook"
                minutes = nil
            }
        }

        /// The saved duration, or nil when it cannot be one. The value is
        /// editable with `defaults write`, so minutes below the supported
        /// range are rejected and minutes above it are clamped: arming a
        /// timer multiplies them by 60, which would overflow for Int.max.
        ///
        /// Every place-based timer the sheet ever offered besides End of book
        /// restores End of heading, the one such timer since October 6,
        /// 2026, so that Restart Sleep Timer arms the timer the listener last
        /// chose: "endOfDocument" was saved while the sheet offered End of
        /// document, "endOfChapter" while it offered End of chapter, which
        /// folded into End of heading, and "endOfHeading" is what is saved
        /// now and was saved by the End of current heading button before.
        func toModel() -> SleepTimerDuration? {
            switch kind {
            case "minutes":
                let supported = SettingsPolicy.sleepTimerMinutes
                guard let minutes, minutes >= supported.lowerBound else { return nil }
                return .minutes(min(minutes, supported.upperBound))
            case "endOfHeading", "endOfChapter", "endOfDocument": return .endOfHeading
            case "endOfBook": return .endOfBook
            default: return nil
            }
        }
    }

    // MARK: - Start / Stop / Restart

    /// Start a new timer. Replaces any timer already running, regardless
    /// of which reader owned it. The provided callbacks become the active
    /// callbacks; the previous owner's callbacks are dropped.
    ///
    /// - Parameters:
    ///   - duration: minutes, end-of-heading, or end-of-book
    ///   - ownerID: UUID of the reader starting the timer (use its
    ///     `readerID`, never its book's ID, which a second window of the
    ///     same book shares). Optional only because some unit tests don't
    ///     have a reader — production callers should always pass an ID so
    ///     pause/resume scoping works correctly.
    ///   - onExpire: fires after the timer finishes (after any fade).
    ///   - onFadeStep: optional per-step volume callback during fade.
    ///   - onFadeCancelled: restores playback if the fade is interrupted.
    ///   - fadeOutDuration: seconds to fade audio before pausing (0 = no fade).
    func start(
        duration: SleepTimerDuration,
        ownerID: UUID? = nil,
        onExpire: @escaping () -> Void,
        onFadeStep: ((Float) -> Void)? = nil,
        onFadeCancelled: (() -> Void)? = nil,
        fadeOutDuration: TimeInterval = 0
    ) {
        // stop() clears callbacks and ownerID, so set them AFTER stop().
        // The duration is saved as the one last used, for every window and
        // for later launches; stop() leaves it as it is.
        stop(reason: "replaced-before-start")
        self.ownerID = ownerID
        self.onTimerExpired = onExpire
        self.onFadeStep = onFadeStep
        self.onFadeCancelled = onFadeCancelled
        self.fadeOutDuration = fadeOutDuration
        self.duration = duration
        rememberLastUsedDuration(duration)
        self.isActive = true
        self.pendingFadeCompletion = false
        self.lastExpiredOwnerID = nil
        registry.forgetExpiredMarks(ofSerial: serial)
        registry.noteTimerChange()

        switch duration {
        case .minutes(let minutes):
            remainingSeconds = minutes * 60
            timerLog(.event, "START kind=minutes requestedMinutes=\(minutes) fadeSeconds=\(fadeOutDuration)")
            startCountdown()
        case .endOfHeading:
            remainingSeconds = 0
            timerLog(.event, "START kind=end-of-heading fadeSeconds=\(fadeOutDuration)")
        case .endOfBook:
            remainingSeconds = 0
            timerLog(.event, "START kind=end-of-book fadeSeconds=\(fadeOutDuration)")
        }
    }

    /// Restart the current timer with the same duration, owner, and
    /// callbacks. No-op when no timer is running.
    ///
    /// `fadeOutDuration` can be overridden so callers that want a
    /// restart to pick up the latest settings can do so explicitly.
    func restart(fadeOutDuration: TimeInterval? = nil) {
        guard let current = duration,
              let onExpire = onTimerExpired else {
            timerLog(.event, "RESTART_IGNORED reason=missing-current-duration-or-expiry-handler")
            return
        }
        let fadeOverrideLabel = fadeOutDuration.map { String($0) } ?? "none"
        timerLog(.event, "RESTART_REQUESTED overrideFadeSeconds=\(fadeOverrideLabel)")
        // Capture the existing callbacks/owner so start() can re-install
        // them after the implicit stop() inside it clears them.
        let owner = ownerID
        let onFade = onFadeStep
        let onFadeCancel = onFadeCancelled
        let fadeDuration = fadeOutDuration ?? self.fadeOutDuration
        start(
            duration: current,
            ownerID: owner,
            onExpire: onExpire,
            onFadeStep: onFade,
            onFadeCancelled: onFadeCancel,
            fadeOutDuration: fadeDuration
        )
    }

    /// Stop the timer, clearing all state and callbacks. Anyone may call this
    /// on a timer: no owner check. Each window has a timer of its own, so
    /// "Cancel Timer" in a window stops that window's timer, and the one on
    /// its way to its book from another window
    /// (`ReaderViewModel.cancelSleepTimer()`), and never another window's.
    func stop(reason: String = "requested") {
        let previousDurationLabel = duration?.displayName ?? "none"
        let previousSummary = "wasActive=\(isActive) wasDuration=\(previousDurationLabel) "
            + "wasRemaining=\(remainingSeconds) wasFading=\(isFadingOut)"
        // Capture the callback before clearing state. Calling it only for an
        // active fade prevents ordinary timer cancellation from needlessly
        // touching playback volume or restarting direct speech.
        let fadeCancellation = endFade()
        timer?.invalidate()
        timer = nil
        #if os(iOS)
        phoneDeadline = nil
        #endif
        isActive = false
        remainingSeconds = 0
        duration = nil
        isCountdownPausedByPlayback = false
        ownerID = nil
        onTimerExpired = nil
        onFadeStep = nil
        onFadeCancelled = nil
        clearHold()
        timerLog(.event, "STOP reason=\(reason) \(previousSummary)")
        fadeCancellation?()
    }

    /// Ends a fade in progress, which `stop()` and a restart of a held fade
    /// share: the stale fade steps and expiry are stranded (`generation`), the
    /// fade timer is gone, and the fade, and a completion it was about to hand
    /// to the owner's pause, are over. The countdown is left to the caller.
    ///
    /// - Returns: The owner's callback that restores its volume, for the
    ///   caller to call once its own state is settled, or nil when no fade was
    ///   running: ordinary cancellation must not touch playback volume or
    ///   restart direct speech.
    private func endFade() -> (() -> Void)? {
        let cancellation = isFadingOut ? onFadeCancelled : nil
        generation += 1
        fadeTimer?.invalidate()
        fadeTimer = nil
        isFadingOut = false
        pendingFadeCompletion = false
        #if os(iOS)
        // A fade cancelled, or a timer stopped, puts nobody to sleep: the
        // phone's hold for the expiry, if one was begun, has nothing to wait for.
        endPhoneExpiryHoldIfBegun()
        #endif
        return cancellation
    }

    /// Hands the running timer from the reader `previousOwnerID` to the
    /// reader `newOwnerID`, which now plays the book listening went on to
    /// (0.2.5): the owner and the callbacks change, and nothing else. The
    /// countdown is neither restarted nor reset, a countdown halted by the
    /// previous owner's pause stays halted until the new owner plays
    /// (`resumeCountdown(by:)`), and a timer waiting for a place waits for it
    /// in the new book. Exactly one owner holds the timer at every moment:
    /// the previous owner's callbacks are dropped as they are replaced, so it
    /// can never pause a book it no longer belongs to.
    ///
    /// Nothing is handed over unless the timer is carriable by
    /// `previousOwnerID` (`isCarriable(by:)`): a timer fading out is putting
    /// the listener to sleep, and ends listening.
    ///
    /// - Returns: Whether the timer changed hands.
    @discardableResult
    func transferOwnership(
        from previousOwnerID: UUID,
        to newOwnerID: UUID,
        onExpire: @escaping () -> Void,
        onFadeStep: ((Float) -> Void)? = nil,
        onFadeCancelled: (() -> Void)? = nil
    ) -> Bool {
        guard isCarriable(by: previousOwnerID) else {
            timerLog(
                .event,
                "TRANSFER_IGNORED from=\(Self.ownerToken(previousOwnerID)) to=\(Self.ownerToken(newOwnerID))"
            )
            return false
        }
        ownerID = newOwnerID
        lastExpiredOwnerID = nil
        onTimerExpired = onExpire
        self.onFadeStep = onFadeStep
        self.onFadeCancelled = onFadeCancelled
        registry.noteTimerChange()
        timerLog(
            .event,
            "TRANSFERRED from=\(Self.ownerToken(previousOwnerID)) to=\(Self.ownerToken(newOwnerID))"
        )
        return true
    }

    /// Whether the timer last ran out while `ownerID` owned it, and has not
    /// been started or handed over since (`lastExpiredOwnerID`), after the
    /// expiry count was `mark` when one is given (`expiryCount`): a timer that
    /// ran out before a move was announced, or before an episode's wait began,
    /// ended nothing there.
    func didExpire(whileOwnedBy ownerID: UUID, sinceExpiry mark: Int? = nil) -> Bool {
        guard lastExpiredOwnerID == ownerID else { return false }
        guard let mark else { return true }
        return lastExpiryNumber > mark
    }

    /// Whether `ownerID` owns a timer that is fading out, which is putting
    /// the listener to sleep.
    func isFadingOut(ownedBy ownerID: UUID) -> Bool {
        isActive && self.ownerID == ownerID && isFadingOut
    }

    /// Whether the timer `ownerID` owns ended listening: it ran out (after the
    /// expiry count was `mark`, when one is given), or is fading out. The book
    /// listening was to go on to must not be started then.
    func endedListening(ownedBy ownerID: UUID, sinceExpiry mark: Int? = nil) -> Bool {
        didExpire(whileOwnedBy: ownerID, sinceExpiry: mark) || isFadingOut(ownedBy: ownerID)
    }

    /// Whether `ownerID` owns a running timer that can go on with the next
    /// book: one counting minutes, or waiting for the end of a heading or of
    /// a book, and not fading out. This is the one place that says so; the
    /// hand-over (`transferOwnership`) and the hold (`hold(forBook:from:)`)
    /// both ask it.
    func isCarriable(by ownerID: UUID) -> Bool {
        isActive && self.ownerID == ownerID && !isFadingOut
    }

    // MARK: Holding the Timer for the Next Book

    /// Holds the timer `owner` owns for the book `bookID`, which listening
    /// goes on to, from the moment the move is announced until a reader of
    /// that book takes it (`take(heldForBook:from:as:onExpire:onFadeStep:onFadeCancelled:)`).
    /// Its owner stays `owner`, and `owner`'s close leaves it running
    /// (`isHeld(from:)`). A deadline stops it, as a last resort, if no reader
    /// ever takes it (`heldTimerDeadline`). A new hold replaces an earlier one.
    ///
    /// - Parameters:
    ///   - deadline: Seconds before the last resort; a test shortens it.
    ///   - isBookOpen: Whether a reader is open for a book, as the library
    ///     registers its readers: while one is open for `bookID` the deadline
    ///     leaves the hold alone.
    /// - Returns: Whether `owner` owns a timer that can be held.
    @discardableResult
    func hold(
        forBook bookID: UUID,
        from owner: UUID,
        deadline: TimeInterval = SleepTimerService.heldTimerDeadline,
        isBookOpen: ((UUID) -> Bool)? = nil
    ) -> Bool {
        guard isCarriable(by: owner) else { return false }
        setHold(forBook: bookID, from: owner, deadline: deadline, isBookOpen: isBookOpen)
        return true
    }

    /// Passes a hold on from the book `bookID`, whose reader moves on to
    /// another book before it has taken the timer, to the book `nextBookID`:
    /// the timer goes on to the book the listener ended up at.
    ///
    /// - Parameter returning: Whether this puts a hold back where it was before
    ///   a move that is cancelled (X3), which is a return and no new carry: a
    ///   timer that has begun to fade out goes back too, since the move that
    ///   cancels it ends the fade as any move does.
    /// - Returns: Whether the timer was held for `bookID`, and can go on.
    @discardableResult
    func passOnHold(
        fromBook bookID: UUID,
        toBook nextBookID: UUID,
        deadline: TimeInterval = SleepTimerService.heldTimerDeadline,
        isBookOpen: ((UUID) -> Bool)? = nil,
        returning: Bool = false
    ) -> Bool {
        guard heldForBookID == bookID, let owner = heldFromOwnerID,
              isCarriable(by: owner) || (returning && isActive && ownerID == owner) else { return false }
        setHold(forBook: nextBookID, from: owner, deadline: deadline, isBookOpen: isBookOpen)
        return true
    }

    /// Holds this timer for the book `bookID` from `owner`, whichever call
    /// asked (`hold`, `passOnHold`), with a last-resort deadline. The registry
    /// keeps the timer alive meanwhile, and stops any other window's timer
    /// held for the same book, so one timer goes on to each book.
    private func setHold(
        forBook bookID: UUID,
        from owner: UUID,
        deadline: TimeInterval,
        isBookOpen: ((UUID) -> Bool)?
    ) {
        holdGeneration += 1
        let generation = holdGeneration
        heldForBookID = bookID
        heldFromOwnerID = owner
        heldBookIsOpen = isBookOpen
        askedBookID = nil
        registry.forgetExpiredMarks(ofSerial: serial)
        registry.noteTimerChange()
        timerLog(.event, "HELD for=\(Self.ownerToken(bookID)) from=\(Self.ownerToken(owner))")
        registry.noteHold(of: self, forBook: bookID)
        armHoldDeadline(forBook: bookID, generation: generation, after: deadline)
    }

    /// Arms the last-resort deadline of the hold made as `generation`. It acts
    /// only when no reader is open for the book (`heldBookIsOpen`): a reader
    /// opening it, in a download that takes longer than the deadline or a load
    /// held up, keeps the hold alive, as a download keeps its autoplay request
    /// (`ReaderAutoplayRequests.hold(for:)`), and the deadline looks again a
    /// deadline later.
    private func armHoldDeadline(forBook bookID: UUID, generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.holdGeneration == generation else { return }
            if self.heldBookIsOpen?(bookID) == true {
                self.armHoldDeadline(forBook: bookID, generation: generation, after: delay)
                return
            }
            self.releaseHeld(forBook: bookID, reason: "no reader took it before the deadline")
        }
    }

    /// Says that the book `bookID`, which the timer is held for, has been
    /// asked for, so its reader may take the timer: a reader open already, in
    /// any window, takes it now (`SleepTimerRegistry.asksMade`), one the ask
    /// opens takes it once it has loaded.
    func markAsked(forBook bookID: UUID) {
        guard heldForBookID == bookID else { return }
        askedBookID = bookID
        registry.asksMade.send(bookID)
    }

    /// Whether the book `bookID` has been asked for while the timer is held for it.
    func isAsked(forBook bookID: UUID) -> Bool {
        heldForBookID == bookID && askedBookID == bookID
    }

    /// Ends the hold without stopping the timer. The registry goes on keeping
    /// the timer alive while it fades out (`updateRetention()`): the fade's
    /// expiry must still be said, though the window the timer came from has
    /// closed and the reader that took the hold dropped it.
    private func clearHold() {
        holdGeneration += 1
        heldForBookID = nil
        heldFromOwnerID = nil
        heldBookIsOpen = nil
        askedBookID = nil
        updateRetention()
    }

    /// Sets whether the registry keeps this timer alive, which a window that
    /// has let it go cannot. A timer held for a book is kept, and so is one
    /// that fades out after its hold ended, until the fade is over (it runs
    /// out, or `stop()` ends it): so the held timer's run-out is marked, and
    /// its expiry said, whatever became of its window. Otherwise it is the
    /// window's own again, and the registry lets it go.
    private func updateRetention() {
        if heldForBookID != nil {
            registry.setRetained(self, true)
        } else if !isFadingOut {
            registry.setRetained(self, false)
        }
    }

    /// Restarts the held timer, as Restart Sleep Timer asks, whichever reader
    /// the restart reaches: a timer counting minutes starts again at its full
    /// duration, one waiting for a place stays as it is, and the hold and the
    /// owner are kept. Nothing is resumed: the book the timer is held for
    /// plays or only opens, as its move said, and takes the timer as it is.
    ///
    /// A restart while the held timer fades out is the listener saying they
    /// are awake (W3): the fade is cancelled, the owner's volume restored
    /// (`onFadeCancelled`), and the countdown starts again at its full
    /// duration, halted until the book that takes the timer plays
    /// (`resumeCountdown(by:)`), as any held countdown is. A fade that began
    /// is not ended by the hold: it ends listening only if nobody restarts it.
    ///
    /// - Returns: Whether the timer is held and the restart was this one's.
    @discardableResult
    func restartHeld() -> Bool {
        guard heldForBookID != nil, isActive else { return false }
        if isFadingOut { cancelFadeForRestart() }
        if case .minutes(let minutes) = duration {
            remainingSeconds = minutes * 60
            #if os(iOS)
            // A countdown still running counts the full duration from now: its
            // ticks read the deadline, not the seconds just set.
            rebasePhoneDeadlineIfCounting()
            #endif
        }
        timerLog(.event, "RESTART_HELD kind=\(duration?.displayName ?? "none")")
        return true
    }

    /// Cancels the fade the held timer is in, leaving the timer active and
    /// held: a countdown it ran out of is halted, to run when its next book
    /// plays.
    private func cancelFadeForRestart() {
        let fadeCancellation = endFade()
        if case .minutes = duration { isCountdownPausedByPlayback = true }
        timerLog(.event, "FADE_CANCELLED_BY_RESTART")
        fadeCancellation?()
    }

    /// Whether the timer is held for any book.
    var isHolding: Bool {
        heldForBookID != nil
    }

    /// Whether the timer is held for the book `bookID`.
    func isHeld(forBook bookID: UUID) -> Bool {
        heldForBookID == bookID
    }

    /// Whether the timer is held for a book and still `ownerID`'s, which a
    /// closing reader leaves running for the reader that is to take it.
    func isHeld(from ownerID: UUID) -> Bool {
        heldForBookID != nil && heldFromOwnerID == ownerID
    }

    /// Gives the timer held for the book `bookID`, once it has been asked for
    /// (`markAsked(forBook:)`), to the reader `newOwnerID` that opened it, and
    /// ends the hold: owner and callbacks change, the
    /// countdown does not (`transferOwnership`).
    ///
    /// - Returns: Whether the timer changed hands.
    @discardableResult
    func adoptHeld(
        forBook bookID: UUID,
        as newOwnerID: UUID,
        onExpire: @escaping () -> Void,
        onFadeStep: ((Float) -> Void)? = nil,
        onFadeCancelled: (() -> Void)? = nil
    ) -> Bool {
        guard isAsked(forBook: bookID), let previous = heldFromOwnerID else { return false }
        clearHold()
        return transferOwnership(
            from: previous, to: newOwnerID, onExpire: onExpire, onFadeStep: onFadeStep, onFadeCancelled: onFadeCancelled
        )
    }

    /// Takes the timer held for the book `bookID`, once it has been asked for,
    /// into this timer, the window's of the reader `newOwnerID` that opened
    /// the book (November 13, 2026: each reader window has a timer of its
    /// own). `source` is the timer held for the book: this one, after the
    /// window switched to the book in place, or another window's, when the
    /// book opened in a new window or in its own window brought forward.
    ///
    /// From this timer itself, the owner and the callbacks change and nothing
    /// else (`adoptHeld`). From another window's, this timer takes its running
    /// state in place of any timer of its own: the duration, the time left,
    /// the fade-out time, and its countdown, counting, or halted by the
    /// previous owner's pause until the new owner plays
    /// (`resumeCountdown(by:)`). The countdown is neither reset nor
    /// restarted. The other timer stops without a word, its hold ended, so its
    /// window no longer shows it. A timer fading out is never taken: it is
    /// putting the listener to sleep (`isCarriable(by:)`).
    ///
    /// - Returns: Whether the timer changed hands.
    @discardableResult
    func take(
        heldForBook bookID: UUID,
        from source: SleepTimerService,
        as newOwnerID: UUID,
        onExpire: @escaping () -> Void,
        onFadeStep: ((Float) -> Void)? = nil,
        onFadeCancelled: (() -> Void)? = nil
    ) -> Bool {
        guard source !== self else {
            return adoptHeld(
                forBook: bookID, as: newOwnerID, onExpire: onExpire, onFadeStep: onFadeStep, onFadeCancelled: onFadeCancelled
            )
        }
        guard source.isAsked(forBook: bookID), let previous = source.heldFromOwnerID,
              source.isCarriable(by: previous), let carriedDuration = source.duration else {
            timerLog(.event, "TAKE_IGNORED for=\(Self.ownerToken(bookID)) to=\(Self.ownerToken(newOwnerID))")
            return false
        }
        // Read before the source stops, which clears it all.
        let secondsLeft = source.secondsLeftNow
        let fadeSeconds = source.fadeOutDuration
        let wasCounting = source.timer != nil
        let wasHalted = source.isCountdownPausedByPlayback
        source.stop(reason: "taken into another window")
        // This window's own timer, if it had one, gives way to the timer
        // listening goes on with; stopped first, as a new timer stops it.
        stop(reason: "replaced by a timer carried from another window")
        ownerID = newOwnerID
        onTimerExpired = onExpire
        self.onFadeStep = onFadeStep
        self.onFadeCancelled = onFadeCancelled
        fadeOutDuration = fadeSeconds
        duration = carriedDuration
        remainingSeconds = secondsLeft
        isCountdownPausedByPlayback = wasHalted
        isActive = true
        // As a timer started here does: what ran out here before is over.
        lastExpiredOwnerID = nil
        registry.forgetExpiredMarks(ofSerial: serial)
        registry.noteTimerChange()
        timerLog(
            .event,
            "TRANSFERRED from=\(Self.ownerToken(previous)) to=\(Self.ownerToken(newOwnerID)) window=another"
        )
        if wasCounting {
            startCountdown()
        }
        return true
    }

    /// The seconds left on the countdown now: what it shows, or, on the
    /// iPhone while it counts, what its deadline says, which a tick has not
    /// shown yet.
    private var secondsLeftNow: Int {
        #if os(iOS)
        if let phoneDeadline, timer != nil {
            return phoneDeadline.tick(at: ContinuousClock.now, after: remainingSeconds).secondsLeft
        }
        #endif
        return remainingSeconds
    }

    /// Ends the hold for the book `bookID` without stopping the timer: the
    /// timer is fading out, and ends listening.
    func dropHold(forBook bookID: UUID) {
        guard heldForBookID == bookID else { return }
        clearHold()
    }

    /// Stops the timer held for the book `bookID`, which will not open, and
    /// tells the listener, after VoiceOver's current speech so the reason the
    /// book did not open is not cut off: the timer would count toward pausing
    /// nothing, and the listener did not ask to cancel it.
    ///
    /// - Returns: Whether the timer was held for that book.
    @discardableResult
    func releaseHeld(
        forBook bookID: UUID,
        reason: String = "the book could not be opened",
        announcingAfter delay: TimeInterval = 0
    ) -> Bool {
        stopHeld(
            forBook: bookID,
            reason: "held for a book that took no timer: \(reason)",
            announcingAfter: delay
        )
    }

    /// Stops the timer held for the book `bookID`, and says nothing: the
    /// listener closed the book's window while it loaded, as closing the
    /// window a timer belongs to stops the timer. Forgets that the timer ran
    /// out for the book, too.
    func cancelHeld(forBook bookID: UUID) {
        stopHeld(forBook: bookID, reason: "the window of the book it was held for closed", announcingAfter: nil)
    }

    /// The one stop `releaseHeld` and `cancelHeld` share, with the one
    /// announcement: forgets that the timer ran out for `bookID`, which never
    /// outlives the move it was made for (a later move to the book, with no
    /// timer started since, must not find it), stops the timer held for it,
    /// and, when `delay` is given, says that it was stopped. The sentence is
    /// said after `delay`, when the reason the book did not open has been
    /// read, and only if nothing has started or held a timer since: a timer the
    /// listener started meanwhile is running, and the sentence would be false
    /// (W4).
    ///
    /// - Parameter delay: Seconds before the listener is told, or nil to say
    ///   nothing.
    /// - Returns: Whether the timer was held for that book.
    @discardableResult
    private func stopHeld(forBook bookID: UUID, reason: String, announcingAfter delay: TimeInterval?) -> Bool {
        _ = consumeExpiredWhileHeld(forBook: bookID)
        guard heldForBookID == bookID else { return false }
        stop(reason: reason)
        guard let delay else { return true }
        // Every start, hold, and take in any window counts from here, so any
        // timer started or held later, here or in another window, is seen.
        let stoppedAt = registry.timerChanges
        if delay > 0 {
            // Captured strongly, for the delay only: the stop let the registry
            // go of this timer, and a timer whose window has closed would be
            // freed before it said what it owes (V7).
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.announceNoBook(ifNoTimerChangedSince: stoppedAt)
            }
        } else {
            announceNoBook(ifNoTimerChangedSince: stoppedAt)
        }
        return true
    }

    /// Says that the timer was cancelled because the next book could not be
    /// opened, unless a timer has been started, held, or taken in any window
    /// since the stop made as the registry's `timerChanges` was `stoppedAt`
    /// (W4): a timer started in another window meanwhile, such as a Restart
    /// in the window whose book just failed, is running, and the sentence
    /// would be false.
    private func announceNoBook(ifNoTimerChangedSince stoppedAt: Int) {
        guard registry.timerChanges == stoppedAt else { return }
        VoiceOverAnnouncer.announce(SleepTimerHandOverWording.noBook, priority: .medium)
    }

    /// Whether the timer ran out while held for the book `bookID`, so that
    /// its reader must not start the book; forgotten once asked.
    func consumeExpiredWhileHeld(forBook bookID: UUID) -> Bool {
        registry.consumeExpiredWhileHeld(forBook: bookID)
    }

    /// Returns true once after a fade reaches silence and the timer is
    /// about to invoke its expiry callback. This lets the playback
    /// layer run the "pause first, then restore volume" cleanup even
    /// though `isFadingOut` has already been cleared for UI purposes.
    func consumePendingFadeCompletion() -> Bool {
        let pending = pendingFadeCompletion
        pendingFadeCompletion = false
        if pending {
            timerLog(.event, "FADE_COMPLETION_CONSUMED")
        }
        return pending
    }

    // MARK: - Owner-Scoped Countdown Pause / Resume

    /// Halt the minutes-based countdown without losing remaining time.
    /// Called from the playback layer when the user pauses, so the
    /// timer doesn't keep ticking in the background and expire while
    /// the user is away on a break.
    /// - No-op for a timer waiting for the end of the heading or of the
    ///   book, which counts no wall-clock time.
    /// - No-op when a fade is already in progress.
    /// - No-op when called by a non-owner — another reader pausing, even
    ///   one of the same book, must not affect this reader's timer.
    func pauseCountdown(by callerID: UUID) {
        // Ordinary playback pauses happen frequently with no timer armed;
        // keep the dedicated timer log focused on actual timer sessions.
        guard isActive else { return }
        guard self.ownerID == callerID else {
            timerLog(.event, "COUNTDOWN_PAUSE_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        guard case .minutes = duration else {
            timerLog(.event, "COUNTDOWN_PAUSE_IGNORED reason=non-minute-duration caller=\(Self.ownerToken(callerID))")
            return
        }
        guard !isFadingOut else {
            timerLog(.event, "COUNTDOWN_PAUSE_IGNORED reason=fade-in-progress caller=\(Self.ownerToken(callerID))")
            return
        }
        guard let activeTimer = timer else {
            timerLog(.event, "COUNTDOWN_PAUSE_IGNORED reason=countdown-not-armed caller=\(Self.ownerToken(callerID))")
            return
        }
        activeTimer.invalidate()
        timer = nil
        #if os(iOS)
        // The seconds left are read from the deadline as the countdown halts,
        // and kept, as the Mac keeps its count, for the resume to count from.
        haltPhoneDeadline()
        #endif
        isCountdownPausedByPlayback = true
        timerLog(.event, "COUNTDOWN_PAUSED caller=\(Self.ownerToken(callerID))")
    }

    /// Resume a previously-paused countdown with its preserved remaining
    /// time. Called from the playback layer when the user resumes.
    /// No-op when there's nothing paused or the caller isn't the owner.
    func resumeCountdown(by callerID: UUID) {
        // As with pause, a normal play action with no timer is not a timer
        // event and should not obscure the sessions under investigation.
        guard isActive else { return }
        guard self.ownerID == callerID else {
            timerLog(.event, "COUNTDOWN_RESUME_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        guard isCountdownPausedByPlayback else {
            timerLog(.event, "COUNTDOWN_RESUME_IGNORED reason=not-paused caller=\(Self.ownerToken(callerID))")
            return
        }
        guard case .minutes = duration else {
            timerLog(.event, "COUNTDOWN_RESUME_IGNORED reason=non-minute-duration caller=\(Self.ownerToken(callerID))")
            return
        }
        isCountdownPausedByPlayback = false
        timerLog(.event, "COUNTDOWN_RESUMED caller=\(Self.ownerToken(callerID))")
        startCountdown()
    }

    // MARK: - Stopping Where a Heading Ends

    /// Whether the timer `callerID` owns is in effect and waits for the end
    /// of a heading (TODO P01, finding #787). The owner, which alone knows
    /// its book's headings, asks before it looks for that end, so a reader
    /// that set no such timer does nothing more as its cursor moves.
    func waitsForHeadingEnd(ownedBy callerID: UUID) -> Bool {
        isActive && ownerID == callerID && duration == .endOfHeading
    }

    /// End the timer because its owner's reading position has reached the
    /// end of the heading the timer waits for, where the next heading
    /// begins: playback carried it there, or the listener moved it there
    /// (TODO P01, finding #787). The first such end ends the timer. As at a
    /// chapter's end (`expireAtChapterEnd`), the owner stops playback there
    /// itself and tells the listener, once: the timer ends as `stop()` ends
    /// it, without calling `onTimerExpired`, and without a fade of its own,
    /// since speech is not faded where a heading or a chapter ends. An
    /// audiobook's headings begin its chapters, so it fades toward a
    /// heading's end as toward that chapter's end.
    ///
    /// Only the owner's timer for the end of a heading ends this way; any
    /// other call changes nothing and writes nothing to the log, since the
    /// owner asks as its cursor moves.
    ///
    /// - Returns: Whether the timer ended, so the owner must stop playback.
    @discardableResult
    func expireAtHeadingEnd(by callerID: UUID) -> Bool {
        guard waitsForHeadingEnd(ownedBy: callerID) else { return false }
        timerLog(.event, "HEADING_END_REACHED caller=\(Self.ownerToken(callerID))")
        stop(reason: "heading-end-reached")
        return true
    }

    // MARK: - Stopping Where a Chapter Ends

    /// Whether the timer `callerID` owns is in effect and stops playback
    /// where the chapter playing now ends (TODO P01): a timer set for the end
    /// of the heading, where that heading ends too, as an audiobook's does
    /// with every chapter, or the book does (finding #787); or for the end
    /// of the book, at the end of its last chapter. Another owner's timer,
    /// one that has ended, and one counting minutes stop nothing there.
    ///
    /// - Parameters:
    ///   - endingTheHeading: Whether the heading the timer waits for, if it
    ///     waits for one, ends where that chapter does: the owner, which
    ///     alone knows its book's headings, finds the next heading beginning
    ///     where the next chapter does.
    ///   - endingTheBook: Whether that chapter is the book's last, with
    ///     nothing after it to play.
    ///   - callerID: The owner asking, as it passed to `start(...)`.
    func stopsPlaybackAtChapterEnd(endingTheHeading: Bool, endingTheBook: Bool, ownedBy callerID: UUID) -> Bool {
        guard isActive, ownerID == callerID, let duration else { return false }
        return duration.stopsPlaybackAtChapterEnd(endingTheHeading: endingTheHeading, endingTheBook: endingTheBook)
    }

    /// End the timer because its owner's playback has reached the end of a
    /// chapter where the timer stops it, and the owner has stopped there
    /// (TODO P01). The chapter has already played to its end, so no fade is
    /// left to run and nothing is left to pause: the timer ends as `stop()`
    /// ends it, without calling `onTimerExpired`, and the owner tells the
    /// listener itself, once, in words that say where playback stopped.
    ///
    /// Only the owner ends its timer this way, and only one that stops
    /// playback there
    /// (`stopsPlaybackAtChapterEnd(endingTheHeading:endingTheBook:ownedBy:)`).
    ///
    /// - Returns: Whether the timer ended, so the owner must stop rather
    ///   than play on.
    @discardableResult
    func expireAtChapterEnd(endingTheHeading: Bool, endingTheBook: Bool, by callerID: UUID) -> Bool {
        guard stopsPlaybackAtChapterEnd(
            endingTheHeading: endingTheHeading,
            endingTheBook: endingTheBook,
            ownedBy: callerID
        ) else { return false }
        timerLog(
            .event,
            "CHAPTER_END_REACHED caller=\(Self.ownerToken(callerID)) "
                + "endingTheHeading=\(endingTheHeading) endingTheBook=\(endingTheBook)"
        )
        stop(reason: "chapter-end-reached")
        return true
    }

    // MARK: - Internal Countdown / Fade

    private func startCountdown() {
        #if os(iOS)
        // Set before the tick timer is made, so every tick comes a whole
        // second or more after the deadline's start, and shows what the Mac's
        // tick would.
        phoneDeadline = PhoneSleepDeadline(secondsLeft: remainingSeconds, from: ContinuousClock.now)
        #endif
        let gen = generation
        // Ensure timer runs on main thread for @Published safety. A window's
        // timer can go with its window (November 13, 2026), and its countdown
        // then ends itself rather than tick for nothing.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] tick in
            guard let self = self else {
                tick.invalidate()
                return
            }
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                self.advanceCountdown()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerLog(.event, "COUNTDOWN_ARMED")
    }

    /// Applies one tick from the currently armed countdown. Keeping the state
    /// transition separate from `Timer` makes pause and expiry behavior
    /// deterministic while retaining the same production execution path.
    private func advanceCountdown() {
        guard timer != nil, isActive, case .minutes = duration else { return }
        #if os(iOS)
        advancePhoneCountdown()
        #else
        if remainingSeconds > 0 {
            remainingSeconds -= 1
        }
        // Minute boundaries and the final ten seconds provide enough detail
        // to prove that a countdown remained live without writing every tick.
        if remainingSeconds % 60 == 0 || remainingSeconds <= 10 {
            timerLog(.trace, "COUNTDOWN_PROGRESS")
        }
        announceIfMilestone()
        if remainingSeconds <= 0 {
            expire()
        }
        #endif
    }

    /// Notes that the timer ran out under its owner, and when; a timer that
    /// was held for a book ran out before that book's reader took it, which
    /// the reader asks (`consumeExpiredWhileHeld(forBook:)`).
    private func noteExpiry() {
        lastExpiredOwnerID = ownerID
        expiryCount += 1
        lastExpiryNumber = expiryCount
        if let held = heldForBookID {
            registry.noteExpiredWhileHeld(forBook: held, bySerial: serial)
        }
        clearHold()
    }

    private func expire() {
        guard isActive else {
            timerLog(.event, "EXPIRE_IGNORED reason=inactive")
            return
        }
        timer?.invalidate()
        timer = nil
        timerLog(.event, "EXPIRE_REACHED_ZERO fadeSeconds=\(fadeOutDuration)")
        #if os(iOS)
        // The countdown is over; the app is held awake from here, through any
        // fade, to the owner's pause and the save after it.
        phoneDeadline = nil
        beginPhoneExpiryHold()
        #endif

        if fadeOutDuration > 0 && !isFadingOut {
            startFadeOut()
        } else if !isFadingOut {
            isActive = false
            noteExpiry()
            timerLog(.event, "EXPIRY_CALLBACK_BEGIN mode=instant")
            onTimerExpired?()
            #if os(iOS)
            endPhoneExpiryHoldIfBegun()
            #endif
        } else {
            timerLog(.event, "EXPIRE_IGNORED reason=fade-already-running")
        }
    }

    private func startFadeOut() {
        // Cancel any existing fade
        fadeTimer?.invalidate()
        fadeTimer = nil

        isFadingOut = true
        let gen = generation
        let totalSteps = Self.fadeStepCount(duration: fadeOutDuration)
        let stepInterval = fadeOutDuration / Double(totalSteps)
        var currentStep = 0
        timerLog(.event, "FADE_STARTED steps=\(totalSteps) stepInterval=\(stepInterval)")

        let ft = Timer(timeInterval: stepInterval, repeats: true) { [weak self] timer in
            // The timer is not Sendable, and is used only inside the block
            // below, on the main thread: it runs on the main run loop, and
            // assumeIsolated would trap if it ever did not.
            nonisolated(unsafe) let callbackTimer = timer
            MainActor.assumeIsolated {
                guard let self = self else { callbackTimer.invalidate(); return }
                guard self.generation == gen else {
                    callbackTimer.invalidate()
                    return
                }
                currentStep += 1
                let volume = Self.fadeVolume(step: currentStep, totalSteps: totalSteps)
                self.onFadeStep?(volume)

                if currentStep >= totalSteps {
                    callbackTimer.invalidate()
                    self.fadeTimer = nil
                    self.pendingFadeCompletion = true
                    self.isFadingOut = false
                    self.isActive = false
                    self.noteExpiry()
                    self.timerLog(.event, "FADE_COMPLETED finalVolume=\(volume)")
                    self.timerLog(.event, "EXPIRY_CALLBACK_BEGIN mode=fade")
                    self.onTimerExpired?()
                    #if os(iOS)
                    self.endPhoneExpiryHoldIfBegun()
                    #endif
                }
            }
        }
        RunLoop.main.add(ft, forMode: .common)
        fadeTimer = ft
    }

    static func fadeStepCount(duration: TimeInterval) -> Int {
        max(1, Int(duration * 10))
    }

    static func fadeVolume(step: Int, totalSteps: Int) -> Float {
        guard totalSteps > 0 else { return 0 }
        return Float(max(0, 1 - Double(step) / Double(totalSteps)))
    }

    /// Announce remaining time at key milestones so VoiceOver users know the timer is active
    private func announceIfMilestone() {
        let milestones: Set<Int> = [300, 60, 30, 10] // 5 min, 1 min, 30 sec, 10 sec
        guard milestones.contains(remainingSeconds) else { return }

        let message: String
        if remainingSeconds >= 60 {
            message = "Sleep timer: \(remainingSeconds / 60) \(remainingSeconds == 60 ? "minute" : "minutes") remaining"
        } else {
            message = "Sleep timer: \(remainingSeconds) seconds remaining"
        }

        // Medium rather than high priority, so VoiceOver may finish what it
        // is already saying before this countdown reminder.
        VoiceOverAnnouncer.announce(message, priority: .medium)
    }

    /// The timer's state as the sheet and the reader show it: the time left
    /// as minutes and seconds, the place a timer waits for (End of heading,
    /// End of book), or Fading out; empty with no timer.
    var formattedRemaining: String {
        guard isActive, let duration else { return "" }
        if isFadingOut { return "Fading out" }
        // A timer waiting for a place in the book shows the place.
        guard case .minutes = duration else { return duration.displayName }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// The timer's state as VoiceOver reads it after "Sleep timer:": the
    /// time left ("4:59 remaining"), where a timer set for a place in the
    /// book stops playback ("stops at the end of this heading"), or "fading
    /// out"; empty with no timer.
    var spokenStatus: String {
        guard isActive, let duration else { return "" }
        if isFadingOut { return "fading out" }
        return duration.spokenStop ?? "\(formattedRemaining) remaining"
    }

    /// The label VoiceOver reads for the timer's status, wherever it is
    /// shown: "Sleep timer: 4:59 remaining", or "Sleep timer: stops at the
    /// end of the book"; empty with no timer.
    var spokenLabel: String {
        isActive ? "Sleep timer: \(spokenStatus)" : ""
    }

    // MARK: - Test Support

    /// Advances the real countdown transition without waiting for wall-clock
    /// time. Hosted tests use this to cover long pause/restart sequences.
    func _advanceCountdownForTesting() {
        advanceCountdown()
    }

    /// Starts the real expiry/fade path without waiting for a full countdown.
    func _expireForTesting() {
        expire()
    }

    /// Reset shared state for unit tests. Production code must not
    /// call this. Clears the last-used duration too, the registry's copy and
    /// the saved one, so a later test isn't surprised by leaked state from
    /// earlier ones.
    func _resetForTesting() {
        stop(reason: "test-reset")
        lastExpiredOwnerID = nil
        registry.forgetExpiredMarks(ofSerial: serial)
        registry.forgetLastStarted(savedIn: userDefaults)
        userDefaults.removeObject(forKey: Self.lastUsedDurationKey)
    }
}

#if os(iOS)
// MARK: - The iPhone's Countdown

/// The sleep timer's iOS branch (spec: "The sleep timer on a phone"): the
/// countdown of minutes keeps a deadline (`PhoneSleepDeadline`) and each tick
/// reads what is left from it; the milestones are logged and never spoken; a
/// return to running checks the deadline at once; and a timer that runs out is
/// held awake until the book is paused and its place saved. The rule that the
/// countdown halts while the book is paused is the Mac's, unchanged, so nothing
/// needs to fire while the app is suspended. Nothing here has run on an iPhone.
extension SleepTimerService {
    /// One tick of the iPhone's countdown: the seconds left read from the
    /// deadline, a late tick and the milestones passed written to the timer's
    /// log, and the timer run out once nothing is left. The milestones are not
    /// spoken on the phone (spec: "Announcements"), so `announceIfMilestone()`
    /// is never called here.
    fileprivate func advancePhoneCountdown() {
        guard let deadline = phoneDeadline else {
            // An armed countdown always has a deadline (`startCountdown()`);
            // should a path not foreseen arm one without, it counts from what
            // is shown rather than standing still.
            timerLog(.event, "DEADLINE_MISSING action=set-from-shown")
            phoneDeadline = PhoneSleepDeadline(secondsLeft: remainingSeconds, from: ContinuousClock.now)
            return
        }
        let tick = deadline.tick(at: ContinuousClock.now, after: remainingSeconds)
        remainingSeconds = tick.secondsLeft
        if tick.skippedSeconds > 0 {
            timerLog(.event, "COUNTDOWN_LATE_TICK skippedSeconds=\(tick.skippedSeconds)")
        }
        for milestone in tick.milestonesPassed {
            timerLog(.event, "MILESTONE_PASSED seconds=\(milestone) spoken=false")
        }
        if tick.isWorthTracing {
            timerLog(.trace, "COUNTDOWN_PROGRESS")
        }
        if tick.hasRunOut {
            expire()
        }
    }

    /// Checks a running countdown against its deadline at once, as the app
    /// comes back to running, before anything else happens: a timer whose time
    /// passed while its ticks could not run expires now, and its owner pauses
    /// the book and says the Mac's "Sleep timer expired. Playback paused."
    /// (`ReaderViewModel.sleepTimerExpiredAnnouncement`). A countdown that is
    /// halted, or a timer waiting for a place in the book, has nothing to
    /// check.
    func checkPhoneDeadline() {
        guard timer != nil, isActive, case .minutes = duration else { return }
        timerLog(.event, "DEADLINE_CHECKED reason=returned-to-running")
        advanceCountdown()
    }

    /// Halts the deadline as the countdown pauses: the seconds left are read
    /// from it and kept, and the resume sets a new one from them.
    fileprivate func haltPhoneDeadline() {
        guard let deadline = phoneDeadline else { return }
        remainingSeconds = deadline.tick(at: ContinuousClock.now, after: remainingSeconds).secondsLeft
        phoneDeadline = nil
    }

    /// Sets the deadline again from the seconds shown, while the countdown
    /// runs: a restart of the held timer sets its full duration while its tick
    /// timer goes on.
    fileprivate func rebasePhoneDeadlineIfCounting() {
        guard timer != nil else { return }
        phoneDeadline = PhoneSleepDeadline(secondsLeft: remainingSeconds, from: ContinuousClock.now)
    }

    /// Begins the hold that keeps the app awake while the timer that ran out
    /// puts the book to sleep, unless one is held already, as when a second
    /// expiry finds the fade running.
    fileprivate func beginPhoneExpiryHold() {
        guard endPhoneExpiryHold == nil, let begin = phoneExpiryHold else { return }
        endPhoneExpiryHold = begin()
        timerLog(.event, "EXPIRY_HOLD_BEGUN")
    }

    /// Ends the hold begun as the timer ran out, once: after its owner has
    /// paused the book, or as a fade is cancelled or the timer stopped. What
    /// the hold does as it ends (save, flush, let the app be suspended) is the
    /// life cycle's.
    fileprivate func endPhoneExpiryHoldIfBegun() {
        guard let end = endPhoneExpiryHold else { return }
        endPhoneExpiryHold = nil
        end()
        timerLog(.event, "EXPIRY_HOLD_ENDED")
    }
}
#endif
