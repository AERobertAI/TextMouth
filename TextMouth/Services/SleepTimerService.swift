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
/// take effect when issued by the *owning* book — Book B pausing should
/// not halt Book A's running timer. Each playback action passes its
/// `ownerID`; mismatching IDs are silently ignored.
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
    /// cancelled, restarted, or replaced by another book's timer.
    var onFadeCancelled: (() -> Void)?

    /// Fade-out duration in seconds (0 = instant pause, no fade)
    var fadeOutDuration: TimeInterval = 0

    /// Identifier of the book that started the current timer. Used to
    /// gate `pauseCountdown(by:)`, `resumeCountdown(by:)`, and the
    /// heading/document-end notifications so a different book's
    /// playback events can't accidentally affect this timer.
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
    /// book reader. The reader whose book.id matches lastOwnerID is
    /// the one that originally owned the (now expired) timer; that's
    /// who should respond. Cleared only when no prior timer exists
    /// at all.
    private(set) var lastOwnerID: UUID?

    private static let lastUsedDurationKey = "sleepTimer.lastUsedDuration"

    /// Preferences store used for the restart-timer duration. Production uses
    /// the app's standard defaults; tests inject an isolated suite so resetting
    /// a fixture can never remove the user's real saved duration.
    private let userDefaults: UserDefaults

    private var timer: Timer?
    private var fadeTimer: Timer?
    private var endOfHeadingTriggered = false
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
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadLastUsedDuration()
    }

    /// Append a structured event to the dedicated timer log. This is also
    /// available to shortcut routing and playback code so one file contains
    /// the complete path from input event through expiration handling.
    nonisolated static func appendDiagnosticLog(_ message: String) {
        let logFile = TextMouthPaths.logsDir.appendingPathComponent("textmouth_timer.log")
        TextMouthPaths.appendLog(to: logFile, message: message)
    }

    /// Short owner tokens make multi-window routing diagnosable without
    /// filling every event with a full UUID.
    private static func ownerToken(_ ownerID: UUID?) -> String {
        ownerID.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    /// Record an event together with the state needed to reconstruct timer
    /// behavior after the fact.
    private func timerLog(_ event: String) {
        let durationLabel = duration?.displayName ?? "none"
        Self.appendDiagnosticLog(
            "\(event) active=\(isActive) duration=\(durationLabel) "
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
            timerLog("RESTORE_LAST_DURATION result=missing")
            return
        }
        // Encoded as JSON for forward-compatibility — adding new
        // SleepTimerDuration cases later won't break decoding old
        // saved values, since unknown cases just fail to decode and
        // we treat that as "no last duration".
        if let decoded = try? JSONDecoder().decode(PersistedDuration.self, from: data) {
            lastUsedDuration = decoded.toModel()
            let restoredLabel = lastUsedDuration?.displayName ?? "invalid"
            timerLog("RESTORE_LAST_DURATION result=decoded value=\(restoredLabel)")
        } else {
            timerLog("RESTORE_LAST_DURATION result=decode-failed bytes=\(data.count)")
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
            timerLog("PERSIST_LAST_DURATION result=saved value=\(duration.displayName)")
        } else {
            timerLog("PERSIST_LAST_DURATION result=encode-failed value=\(duration.displayName)")
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
            case .endOfDocument:
                kind = "endOfDocument"
                minutes = nil
            }
        }

        /// The saved duration, or nil when it cannot be one. The value is
        /// editable with `defaults write`, so minutes below the supported
        /// range are rejected and minutes above it are clamped: arming a
        /// timer multiplies them by 60, which would overflow for Int.max.
        func toModel() -> SleepTimerDuration? {
            switch kind {
            case "minutes":
                let supported = SettingsPolicy.sleepTimerMinutes
                guard let minutes, minutes >= supported.lowerBound else { return nil }
                return .minutes(min(minutes, supported.upperBound))
            case "endOfHeading": return .endOfHeading
            case "endOfDocument": return .endOfDocument
            default: return nil
            }
        }
    }

    // MARK: - Start / Stop / Restart

    /// Start a new timer. Replaces any timer already running, regardless
    /// of which book owned it. The provided callbacks become the active
    /// callbacks; the previous owner's callbacks are dropped.
    ///
    /// - Parameters:
    ///   - duration: minutes, end-of-heading, or end-of-document
    ///   - ownerID: UUID of the book starting the timer (use `book.id`).
    ///     Optional only because some unit tests don't have a book —
    ///     production callers should always pass an ID so pause/resume
    ///     scoping works correctly.
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
        self.endOfHeadingTriggered = false
        self.pendingFadeCompletion = false

        switch duration {
        case .minutes(let minutes):
            remainingSeconds = minutes * 60
            timerLog("START kind=minutes requestedMinutes=\(minutes) fadeSeconds=\(fadeOutDuration)")
            startCountdown()
        case .endOfHeading:
            remainingSeconds = 0
            endOfHeadingTriggered = false
            timerLog("START kind=end-of-heading fadeSeconds=\(fadeOutDuration)")
        case .endOfDocument:
            remainingSeconds = 0
            timerLog("START kind=end-of-document fadeSeconds=\(fadeOutDuration)")
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
            timerLog("RESTART_IGNORED reason=missing-current-duration-or-expiry-handler")
            return
        }
        let fadeOverrideLabel = fadeOutDuration.map { String($0) } ?? "none"
        timerLog("RESTART_REQUESTED overrideFadeSeconds=\(fadeOverrideLabel)")
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
        endOfHeadingTriggered = false
        isCountdownPausedByPlayback = false
        pendingFadeCompletion = false
        ownerID = nil
        onTimerExpired = nil
        onFadeStep = nil
        onFadeCancelled = nil
        timerLog("STOP reason=\(reason) \(previousSummary)")
        fadeCancellation?()
    }

    /// Returns true once after a fade reaches silence and the timer is
    /// about to invoke its expiry callback. This lets the playback
    /// layer run the "pause first, then restore volume" cleanup even
    /// though `isFadingOut` has already been cleared for UI purposes.
    func consumePendingFadeCompletion() -> Bool {
        let pending = pendingFadeCompletion
        pendingFadeCompletion = false
        if pending {
            timerLog("FADE_COMPLETION_CONSUMED")
        }
        return pending
    }

    // MARK: - Owner-Scoped Countdown Pause / Resume

    /// Halt the minutes-based countdown without losing remaining time.
    /// Called from the playback layer when the user pauses, so the
    /// timer doesn't keep ticking in the background and expire while
    /// the user is away on a break.
    /// - No-op for heading-end / document-end modes (no wall-clock).
    /// - No-op when a fade is already in progress.
    /// - No-op when called by a non-owner — Book B pausing must not
    ///   affect a timer owned by Book A.
    func pauseCountdown(by callerID: UUID) {
        // Ordinary playback pauses happen frequently with no timer armed;
        // keep the dedicated timer log focused on actual timer sessions.
        guard isActive else { return }
        guard self.ownerID == callerID else {
            timerLog("COUNTDOWN_PAUSE_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        guard case .minutes = duration else {
            timerLog("COUNTDOWN_PAUSE_IGNORED reason=non-minute-duration caller=\(Self.ownerToken(callerID))")
            return
        }
        guard !isFadingOut else {
            timerLog("COUNTDOWN_PAUSE_IGNORED reason=fade-in-progress caller=\(Self.ownerToken(callerID))")
            return
        }
        guard let activeTimer = timer else {
            timerLog("COUNTDOWN_PAUSE_IGNORED reason=countdown-not-armed caller=\(Self.ownerToken(callerID))")
            return
        }
        activeTimer.invalidate()
        timer = nil
        isCountdownPausedByPlayback = true
        timerLog("COUNTDOWN_PAUSED caller=\(Self.ownerToken(callerID))")
    }

    /// Resume a previously-paused countdown with its preserved remaining
    /// time. Called from the playback layer when the user resumes.
    /// No-op when there's nothing paused or the caller isn't the owner.
    func resumeCountdown(by callerID: UUID) {
        // As with pause, a normal play action with no timer is not a timer
        // event and should not obscure the sessions under investigation.
        guard isActive else { return }
        guard self.ownerID == callerID else {
            timerLog("COUNTDOWN_RESUME_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        guard isCountdownPausedByPlayback else {
            timerLog("COUNTDOWN_RESUME_IGNORED reason=not-paused caller=\(Self.ownerToken(callerID))")
            return
        }
        guard case .minutes = duration else {
            timerLog("COUNTDOWN_RESUME_IGNORED reason=non-minute-duration caller=\(Self.ownerToken(callerID))")
            return
        }
        isCountdownPausedByPlayback = false
        timerLog("COUNTDOWN_RESUMED caller=\(Self.ownerToken(callerID))")
        startCountdown()
    }

    /// Notify the timer that a heading boundary was crossed in the
    /// owner book. Only the owner can advance an `endOfHeading` timer.
    func notifyHeadingBoundary(by callerID: UUID) {
        guard isActive, case .endOfHeading = duration else { return }
        guard self.ownerID == callerID else {
            timerLog("HEADING_BOUNDARY_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        if endOfHeadingTriggered {
            timerLog("HEADING_BOUNDARY_EXPIRING caller=\(Self.ownerToken(callerID))")
            expire()
        } else {
            endOfHeadingTriggered = true
            timerLog("HEADING_BOUNDARY_ARMED caller=\(Self.ownerToken(callerID))")
        }
    }

    /// Notify the timer that the document ended in the owner book.
    /// Only the owner can trigger an `endOfDocument` timer.
    func notifyDocumentEnd(by callerID: UUID) {
        guard isActive, case .endOfDocument = duration else { return }
        guard self.ownerID == callerID else {
            timerLog("DOCUMENT_END_IGNORED reason=owner-mismatch caller=\(Self.ownerToken(callerID))")
            return
        }
        timerLog("DOCUMENT_END_EXPIRING caller=\(Self.ownerToken(callerID))")
        expire()
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
        timerLog("COUNTDOWN_ARMED")
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
            timerLog("COUNTDOWN_PROGRESS")
        }
        announceIfMilestone()
        if remainingSeconds <= 0 {
            expire()
        }
    }

    private func expire() {
        guard isActive else {
            timerLog("EXPIRE_IGNORED reason=inactive")
            return
        }
        timer?.invalidate()
        timer = nil
        timerLog("EXPIRE_REACHED_ZERO fadeSeconds=\(fadeOutDuration)")

        if fadeOutDuration > 0 && !isFadingOut {
            startFadeOut()
        } else if !isFadingOut {
            isActive = false
            timerLog("EXPIRY_CALLBACK_BEGIN mode=instant")
            onTimerExpired?()
        } else {
            timerLog("EXPIRE_IGNORED reason=fade-already-running")
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
        timerLog("FADE_STARTED steps=\(totalSteps) stepInterval=\(stepInterval)")

        let ft = Timer(timeInterval: stepInterval, repeats: true) { [weak self] timer in
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
                    self.timerLog("FADE_COMPLETED finalVolume=\(volume)")
                    self.timerLog("EXPIRY_CALLBACK_BEGIN mode=fade")
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

        // Post VoiceOver announcement
        if let window = NSApp?.keyWindow ?? NSApp?.mainWindow {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
    }

    var formattedRemaining: String {
        guard isActive else { return "" }
        if isFadingOut { return "Fading out" }
        if case .endOfHeading = duration { return "End of heading" }
        if case .endOfDocument = duration { return "End of document" }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
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
