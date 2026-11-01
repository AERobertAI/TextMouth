import Foundation
import Combine
import AppKit

/// Manages the sleep timer. There is exactly ONE timer at a time across
/// the whole app (any number of book windows may exist) — accessed via
/// `SleepTimerService.shared`.
///
/// ## Why a singleton
/// The user expectation is "one sleep timer running at once". Per-window
/// instances allowed Book A's timer to run alongside Book B's, with each
/// window's UI showing only its own state. Sharing a single source of
/// truth means starting a timer from any window automatically replaces
/// any previous timer, and every open sleep-timer sheet reflects the
/// same live state.
///
/// ## Owner-scoped pause/resume
/// The minutes-based countdown is paused alongside playback so a timer
/// set before a long break doesn't expire silently in the background and
/// pause the user mid-sentence after they resume. With a single shared
/// timer but multiple book windows, the pause/resume calls must only
/// take effect when issued by the *owning* reader — Book B pausing should
/// not halt Book A's running timer. Each playback action passes its
/// `ownerID`, the reader's own ID (`ReaderViewModel.readerID`), so two
/// windows of the same book are told apart too; mismatching IDs are
/// silently ignored.
@MainActor
final class SleepTimerService: ObservableObject {
    /// The single shared instance. All book windows and views read and
    /// write timer state here so only one timer is ever active.
    static let shared = SleepTimerService()

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

    /// Most recently used duration. Persisted (in `start()`) and
    /// preserved across `stop()` so the "Restart Sleep Timer"
    /// shortcut and the media-gesture detector can re-arm a fresh
    /// timer with the same duration the user last picked, even after
    /// the previous timer has fully expired. Persisted to
    /// UserDefaults so it also survives app restarts.
    private(set) var lastUsedDuration: SleepTimerDuration?

    /// Owner ID of the most recently started timer, preserved across
    /// `stop()`. Used to route the .restartSleepTimer notification
    /// from the gesture detector — when the app is backgrounded and
    /// no window is "key", the gesture must still target the right
    /// book reader. The reader whose readerID matches lastOwnerID is
    /// the one that originally owned the (now expired) timer; that's
    /// who should respond. Nil when no prior timer exists at all, or
    /// when that reader has closed (`forgetLastOwner(_:)`).
    private(set) var lastOwnerID: UUID?

    /// The reader that owned the timer when it last ran out, whether it
    /// stopped the book at once or after a fade, kept until a timer starts
    /// or changes hands, and when (`lastExpiry`). A reader that a finished
    /// book's timer was to move to asks it (`didExpire(whileOwnedBy:since:)`):
    /// a timer that ran out before the next book took it has ended
    /// listening, and the next book must not start.
    private(set) var lastExpiredOwnerID: UUID?
    /// When the timer last ran out, for `didExpire(whileOwnedBy:since:)`.
    private(set) var lastExpiry: Date?

    // MARK: Held for the Next Book (0.2.5)

    /// How long a timer is held for a book that never takes it, in seconds,
    /// before it is stopped as a last resort: twenty minutes, far longer
    /// than any download or load of a book takes. Every path that knows the
    /// book will not open releases the timer at once (`releaseHeld(forBook:)`);
    /// this only catches the paths nobody knew of.
    nonisolated static let heldTimerDeadline: TimeInterval = 20 * 60

    /// The book the running timer is held for: listening goes on to it, and
    /// the reader that opens it takes the timer (`adoptHeld(forBook:as:...)`).
    /// From the moment the move is announced until then, the timer stays its
    /// previous owner's, the one owner it has, and nothing ages the hold but
    /// `heldTimerDeadline`: not the 30 seconds a request to a reader lives, so
    /// a book that takes a long time to download is not lost.
    private(set) var heldForBookID: UUID?
    /// The reader the held timer goes on from: its owner meanwhile.
    private var heldFromOwnerID: UUID?
    /// Counts holds, so a deadline made for an earlier one does nothing.
    private var holdGeneration = 0
    /// How many readers exist for each book, from the reader's making to its
    /// close: a reader that exists for a book a timer is held for is the one
    /// opening it, and is responsible for the timer, which it releases on
    /// every way it can fail (`noteReaderExists(forBook:)`). The deadline acts
    /// only when no reader is opening the book.
    private var readersByBook: [UUID: Int] = [:]
    /// The book a held timer ran out for before its reader took it: that
    /// reader must not start the book (`consumeExpiredWhileHeld(forBook:)`).
    private(set) var expiredWhileHeldBookID: UUID?
    /// The book the held timer has been asked for: the move's announcement
    /// holds the timer, and the ask, half a second later, lets the reader take
    /// it (`markAsked(forBook:)`). Until then a timer that runs out ends
    /// listening before the book starts, which only the old reader, still its
    /// owner, can tell.
    private(set) var askedBookID: UUID?
    /// Tells, with the book's ID, each time the held timer is asked for, so a
    /// reader already open for it takes the timer before it plays.
    let asksMade = PassthroughSubject<UUID, Never>()

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

    /// Production uses the shared instance. The internal initializer remains
    /// injectable so hosted tests can use disposable preferences storage.
    init(userDefaults: UserDefaults = TextMouthRuntime.current.preferences) {
        self.userDefaults = userDefaults
        loadLastUsedDuration()
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

    /// Read the persisted last-used duration on init so a "Restart
    /// Sleep Timer" gesture works even on the first launch after the
    /// app was relaunched mid-timer.
    private func loadLastUsedDuration() {
        guard let data = userDefaults.data(forKey: Self.lastUsedDurationKey) else {
            timerLog(.event, "RESTORE_LAST_DURATION result=missing")
            return
        }
        // Encoded as JSON for forward-compatibility — adding new
        // SleepTimerDuration cases later won't break decoding old
        // saved values, since unknown cases just fail to decode and
        // we treat that as "no last duration".
        if let decoded = try? JSONDecoder().decode(PersistedDuration.self, from: data) {
            lastUsedDuration = decoded.toModel()
            let restoredLabel = lastUsedDuration?.displayName ?? "invalid"
            timerLog(.event, "RESTORE_LAST_DURATION result=decoded value=\(restoredLabel)")
        } else {
            timerLog(.event, "RESTORE_LAST_DURATION result=decode-failed bytes=\(data.count)")
        }
    }

    /// Persist a duration as the most recently used. Called from
    /// `start()` whenever a fresh timer is configured. Failures to
    /// encode are swallowed — the in-memory value is still set, the
    /// persistence is only a convenience.
    private func persistLastUsedDuration(_ duration: SleepTimerDuration) {
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
        // Capture lastUsedDuration BEFORE stop() so even though stop()
        // doesn't clear it (by design), we don't accidentally race a
        // partial state. Record it here, persist for later launches.
        stop(reason: "replaced-before-start")
        self.ownerID = ownerID
        // Track the most recent owner separately from `ownerID` so it
        // survives stop() — the gesture notification routing depends
        // on knowing which reader owned the previous timer even after
        // it expired. Falls back to the active ownerID when we have
        // one; nil only on tests that don't pass an owner.
        if let ownerID = ownerID {
            self.lastOwnerID = ownerID
        }
        self.onTimerExpired = onExpire
        self.onFadeStep = onFadeStep
        self.onFadeCancelled = onFadeCancelled
        self.fadeOutDuration = fadeOutDuration
        self.duration = duration
        self.lastUsedDuration = duration
        persistLastUsedDuration(duration)
        self.isActive = true
        self.pendingFadeCompletion = false
        self.lastExpiredOwnerID = nil
        self.expiredWhileHeldBookID = nil

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

    /// Stop the timer, clearing all state and callbacks. Anyone may
    /// call this — tapping "Cancel Timer" in any window cancels.
    func stop(reason: String = "requested") {
        let previousDurationLabel = duration?.displayName ?? "none"
        let previousSummary = "wasActive=\(isActive) wasDuration=\(previousDurationLabel) "
            + "wasRemaining=\(remainingSeconds) wasFading=\(isFadingOut)"
        // Capture the callback before clearing state. Calling it only for an
        // active fade prevents ordinary timer cancellation from needlessly
        // touching playback volume or restarting direct speech.
        let fadeCancellation = isFadingOut ? onFadeCancelled : nil
        generation += 1
        timer?.invalidate()
        timer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        isActive = false
        isFadingOut = false
        remainingSeconds = 0
        duration = nil
        isCountdownPausedByPlayback = false
        pendingFadeCompletion = false
        ownerID = nil
        onTimerExpired = nil
        onFadeStep = nil
        onFadeCancelled = nil
        clearHold()
        timerLog(.event, "STOP reason=\(reason) \(previousSummary)")
        fadeCancellation?()
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
        lastOwnerID = newOwnerID
        lastExpiredOwnerID = nil
        onTimerExpired = onExpire
        self.onFadeStep = onFadeStep
        self.onFadeCancelled = onFadeCancelled
        timerLog(
            .event,
            "TRANSFERRED from=\(Self.ownerToken(previousOwnerID)) to=\(Self.ownerToken(newOwnerID))"
        )
        return true
    }

    /// Whether the timer last ran out while `ownerID` owned it, and has not
    /// been started or handed over since (`lastExpiredOwnerID`), no earlier
    /// than `date` when one is given: a timer that ran out before a move was
    /// announced, or before an episode's wait began, ended nothing there.
    func didExpire(whileOwnedBy ownerID: UUID, since date: Date? = nil) -> Bool {
        guard lastExpiredOwnerID == ownerID else { return false }
        guard let date else { return true }
        return (lastExpiry ?? .distantPast) >= date
    }

    /// Whether `ownerID` owns a timer that is fading out, which is putting
    /// the listener to sleep.
    func isFadingOut(ownedBy ownerID: UUID) -> Bool {
        isActive && self.ownerID == ownerID && isFadingOut
    }

    /// Whether the timer `ownerID` owns ended listening: it ran out (since
    /// `date`, when one is given), or is fading out. The book listening was to
    /// go on to must not be started then.
    func endedListening(ownedBy ownerID: UUID, since date: Date? = nil) -> Bool {
        didExpire(whileOwnedBy: ownerID, since: date) || isFadingOut(ownedBy: ownerID)
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
    /// that book takes it (`adoptHeld(forBook:as:onExpire:onFadeStep:onFadeCancelled:)`).
    /// Its owner stays `owner`, and `owner`'s close leaves it running
    /// (`isHeld(from:)`). A deadline stops it, as a last resort, if no reader
    /// ever takes it (`heldTimerDeadline`). A new hold replaces an earlier one.
    ///
    /// - Parameter deadline: Seconds before the last resort; a test shortens it.
    /// - Returns: Whether `owner` owns a timer that can be held.
    @discardableResult
    func hold(
        forBook bookID: UUID,
        from owner: UUID,
        deadline: TimeInterval = SleepTimerService.heldTimerDeadline
    ) -> Bool {
        guard isCarriable(by: owner) else { return false }
        setHold(forBook: bookID, from: owner, deadline: deadline)
        return true
    }

    /// Passes a hold on from the book `bookID`, whose reader moves on to
    /// another book before it has taken the timer, to the book `nextBookID`:
    /// the timer goes on to the book the listener ended up at.
    ///
    /// - Returns: Whether the timer was held for `bookID`, and can go on.
    @discardableResult
    func passOnHold(
        fromBook bookID: UUID,
        toBook nextBookID: UUID,
        deadline: TimeInterval = SleepTimerService.heldTimerDeadline
    ) -> Bool {
        guard heldForBookID == bookID, let owner = heldFromOwnerID, isCarriable(by: owner) else { return false }
        setHold(forBook: nextBookID, from: owner, deadline: deadline)
        return true
    }

    private func setHold(forBook bookID: UUID, from owner: UUID, deadline: TimeInterval) {
        holdGeneration += 1
        let generation = holdGeneration
        heldForBookID = bookID
        heldFromOwnerID = owner
        askedBookID = nil
        expiredWhileHeldBookID = nil
        timerLog(.event, "HELD for=\(Self.ownerToken(bookID)) from=\(Self.ownerToken(owner))")
        armHoldDeadline(forBook: bookID, generation: generation, after: deadline)
    }

    /// Arms the last-resort deadline of the hold made as `generation`. It acts
    /// only when no reader exists for the book: a reader opening it, in a
    /// download that takes longer than the deadline or a load held up, keeps
    /// the hold alive, as a download keeps its autoplay request
    /// (`ReaderAutoplayRequests.hold(for:)`), and the deadline looks again a
    /// deadline later.
    private func armHoldDeadline(forBook bookID: UUID, generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.holdGeneration == generation else { return }
            if self.readersByBook[bookID, default: 0] > 0 {
                self.armHoldDeadline(forBook: bookID, generation: generation, after: delay)
                return
            }
            self.releaseHeld(forBook: bookID, reason: "no reader took it before the deadline")
        }
    }

    /// Notes that a reader exists for the book `bookID`, which opens it: a
    /// timer held for the book is that reader's to release, and the deadline
    /// leaves it alone while the reader exists.
    func noteReaderExists(forBook bookID: UUID) {
        readersByBook[bookID, default: 0] += 1
    }

    /// Notes that a reader of the book `bookID` has closed.
    func noteReaderGone(forBook bookID: UUID) {
        guard let count = readersByBook[bookID] else { return }
        readersByBook[bookID] = count > 1 ? count - 1 : nil
    }

    /// Says that the book `bookID`, which the timer is held for, has been
    /// asked for, so its reader may take the timer: a reader open already
    /// takes it now (`asksMade`), one the ask opens takes it once it has
    /// loaded.
    func markAsked(forBook bookID: UUID) {
        guard heldForBookID == bookID else { return }
        askedBookID = bookID
        asksMade.send(bookID)
    }

    /// Whether the book `bookID` has been asked for while the timer is held for it.
    func isAsked(forBook bookID: UUID) -> Bool {
        heldForBookID == bookID && askedBookID == bookID
    }

    /// Ends the hold without stopping the timer.
    private func clearHold() {
        holdGeneration += 1
        heldForBookID = nil
        heldFromOwnerID = nil
        askedBookID = nil
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
    func releaseHeld(forBook bookID: UUID, reason: String = "the book could not be opened") -> Bool {
        guard heldForBookID == bookID else { return false }
        stop(reason: "held for a book that took no timer: \(reason)")
        VoiceOverAnnouncer.announce(SleepTimerHandOverWording.noBook, priority: .medium)
        return true
    }

    /// Whether the timer ran out while held for the book `bookID`, so that
    /// its reader must not start the book; forgotten once asked.
    func consumeExpiredWhileHeld(forBook bookID: UUID) -> Bool {
        guard expiredWhileHeldBookID == bookID else { return false }
        expiredWhileHeldBookID = nil
        return true
    }

    /// Forget `ownerID` as the owner of the most recent timer, because that
    /// reader is closing: Restart Sleep Timer from a media gesture, which
    /// belongs to no window, then goes to the focused reader rather than to
    /// none. The duration last used is kept for it. Nothing changes when
    /// another reader owned the most recent timer.
    func forgetLastOwner(_ ownerID: UUID) {
        guard lastOwnerID == ownerID else { return }
        lastOwnerID = nil
        timerLog(.event, "LAST_OWNER_FORGOTTEN owner=\(Self.ownerToken(ownerID))")
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
        let gen = generation
        // Ensure timer runs on main thread for @Published safety
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
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
    }

    /// Notes that the timer ran out under its owner, and when; a timer that
    /// was held for a book ran out before that book's reader took it, which
    /// the reader asks (`consumeExpiredWhileHeld(forBook:)`).
    private func noteExpiry() {
        lastExpiredOwnerID = ownerID
        lastExpiry = Date()
        if let held = heldForBookID {
            expiredWhileHeldBookID = held
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

        if fadeOutDuration > 0 && !isFadingOut {
            startFadeOut()
        } else if !isFadingOut {
            isActive = false
            noteExpiry()
            timerLog(.event, "EXPIRY_CALLBACK_BEGIN mode=instant")
            onTimerExpired?()
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
    /// call this. Clears the persisted last-used duration too so a
    /// later test isn't surprised by leaked state from earlier ones.
    func _resetForTesting() {
        stop(reason: "test-reset")
        lastUsedDuration = nil
        lastOwnerID = nil
        lastExpiredOwnerID = nil
        lastExpiry = nil
        expiredWhileHeldBookID = nil
        userDefaults.removeObject(forKey: Self.lastUsedDurationKey)
    }
}
