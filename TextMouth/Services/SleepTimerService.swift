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
            case .endOfChapter:
                kind = "endOfChapter"
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
        /// "endOfDocument", saved before End of chapter took the place of
        /// End of document, restores End of chapter: that timer always
        /// stopped where a chapter ended, and Restart Sleep Timer should
        /// arm the timer the listener last chose.
        func toModel() -> SleepTimerDuration? {
            switch kind {
            case "minutes":
                let supported = SettingsPolicy.sleepTimerMinutes
                guard let minutes, minutes >= supported.lowerBound else { return nil }
                return .minutes(min(minutes, supported.upperBound))
            case "endOfHeading": return .endOfHeading
            case "endOfChapter", "endOfDocument": return .endOfChapter
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
    ///   - duration: minutes, end-of-heading, end-of-chapter, or end-of-book
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

        switch duration {
        case .minutes(let minutes):
            remainingSeconds = minutes * 60
            timerLog(.event, "START kind=minutes requestedMinutes=\(minutes) fadeSeconds=\(fadeOutDuration)")
            startCountdown()
        case .endOfHeading:
            remainingSeconds = 0
            timerLog(.event, "START kind=end-of-heading fadeSeconds=\(fadeOutDuration)")
        case .endOfChapter:
            remainingSeconds = 0
            timerLog(.event, "START kind=end-of-chapter fadeSeconds=\(fadeOutDuration)")
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
        timerLog(.event, "STOP reason=\(reason) \(previousSummary)")
        fadeCancellation?()
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
    /// - No-op for heading-end / chapter-end / book-end modes (no
    ///   wall-clock).
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
    /// of the chapter, at any chapter's end; for the end of a heading, where
    /// that heading ends too, or the book does (finding #787); or for the end
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
    /// End of chapter, End of book), or Fading out; empty with no timer.
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
    /// book stops playback ("stops at the end of this chapter"), or "fading
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
        userDefaults.removeObject(forKey: Self.lastUsedDurationKey)
    }
}
