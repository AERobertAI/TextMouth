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

    /// Private to enforce singleton access. Tests that need a fresh
    /// instance should call `_resetForTesting()` between cases.
    init() {
        loadLastUsedDuration()
    }

    // MARK: - Last-Used-Duration Persistence

    /// Read the persisted last-used duration on init so a "Restart
    /// Sleep Timer" gesture works even on the first launch after the
    /// app was relaunched mid-timer.
    private func loadLastUsedDuration() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastUsedDurationKey) else { return }
        // Encoded as JSON for forward-compatibility — adding new
        // SleepTimerDuration cases later won't break decoding old
        // saved values, since unknown cases just fail to decode and
        // we treat that as "no last duration".
        if let decoded = try? JSONDecoder().decode(PersistedDuration.self, from: data) {
            lastUsedDuration = decoded.toModel()
        }
    }

    /// Persist a duration as the most recently used. Called from
    /// `start()` whenever a fresh timer is configured. Failures to
    /// encode are swallowed — the in-memory value is still set, the
    /// persistence is only a convenience.
    private func persistLastUsedDuration(_ duration: SleepTimerDuration) {
        let model = PersistedDuration(from: duration)
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: Self.lastUsedDurationKey)
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

        func toModel() -> SleepTimerDuration? {
            switch kind {
            case "minutes":
                guard let m = minutes, m > 0 else { return nil }
                return .minutes(m)
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
    ///   - fadeOutDuration: seconds to fade audio before pausing (0 = no fade).
    func start(
        duration: SleepTimerDuration,
        ownerID: UUID? = nil,
        onExpire: @escaping () -> Void,
        onFadeStep: ((Float) -> Void)? = nil,
        fadeOutDuration: TimeInterval = 0
    ) {
        // stop() clears callbacks and ownerID, so set them AFTER stop().
        // Capture lastUsedDuration BEFORE stop() so even though stop()
        // doesn't clear it (by design), we don't accidentally race a
        // partial state. Record it here, persist for later launches.
        stop()
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
            startCountdown()
        case .endOfHeading:
            remainingSeconds = 0
            endOfHeadingTriggered = false
        case .endOfDocument:
            remainingSeconds = 0
        }
    }

    /// Restart the current timer with the same duration, owner, and
    /// callbacks. No-op when no timer is running.
    ///
    /// `fadeOutDuration` can be overridden so callers that want a
    /// restart to pick up the latest settings can do so explicitly.
    func restart(fadeOutDuration: TimeInterval? = nil) {
        guard let current = duration,
              let onExpire = onTimerExpired else { return }
        // Capture the existing callbacks/owner so start() can re-install
        // them after the implicit stop() inside it clears them.
        let owner = ownerID
        let onFade = onFadeStep
        let fadeDuration = fadeOutDuration ?? self.fadeOutDuration
        start(
            duration: current,
            ownerID: owner,
            onExpire: onExpire,
            onFadeStep: onFade,
            fadeOutDuration: fadeDuration
        )
    }

    /// Stop the timer, clearing all state and callbacks. Anyone may
    /// call this — tapping "Cancel Timer" in any window cancels.
    func stop() {
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
    }

    /// Returns true once after a fade reaches silence and the timer is
    /// about to invoke its expiry callback. This lets the playback
    /// layer run the "pause first, then restore volume" cleanup even
    /// though `isFadingOut` has already been cleared for UI purposes.
    func consumePendingFadeCompletion() -> Bool {
        let pending = pendingFadeCompletion
        pendingFadeCompletion = false
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
        guard self.ownerID == callerID,
              isActive,
              case .minutes = duration,
              !isFadingOut,
              let activeTimer = timer else { return }
        activeTimer.invalidate()
        timer = nil
        isCountdownPausedByPlayback = true
    }

    /// Resume a previously-paused countdown with its preserved remaining
    /// time. Called from the playback layer when the user resumes.
    /// No-op when there's nothing paused or the caller isn't the owner.
    func resumeCountdown(by callerID: UUID) {
        guard self.ownerID == callerID,
              isActive,
              isCountdownPausedByPlayback,
              case .minutes = duration else { return }
        isCountdownPausedByPlayback = false
        startCountdown()
    }

    /// Notify the timer that a heading boundary was crossed in the
    /// owner book. Only the owner can advance an `endOfHeading` timer.
    func notifyHeadingBoundary(by callerID: UUID) {
        guard self.ownerID == callerID,
              isActive,
              case .endOfHeading = duration else { return }
        if endOfHeadingTriggered {
            expire()
        } else {
            endOfHeadingTriggered = true
        }
    }

    /// Notify the timer that the document ended in the owner book.
    /// Only the owner can trigger an `endOfDocument` timer.
    func notifyDocumentEnd(by callerID: UUID) {
        guard self.ownerID == callerID, isActive else { return }
        if case .endOfDocument = duration {
            expire()
        }
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
    }

    /// Applies one tick from the currently armed countdown. Keeping the state
    /// transition separate from `Timer` makes pause and expiry behavior
    /// deterministic while retaining the same production execution path.
    private func advanceCountdown() {
        guard timer != nil, isActive, case .minutes = duration else { return }
        if remainingSeconds > 0 {
            remainingSeconds -= 1
        }
        announceIfMilestone()
        if remainingSeconds <= 0 {
            expire()
        }
    }

    private func expire() {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil

        if fadeOutDuration > 0 && !isFadingOut {
            startFadeOut()
        } else if !isFadingOut {
            isActive = false
            onTimerExpired?()
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
        stop()
        lastUsedDuration = nil
        lastOwnerID = nil
        UserDefaults.standard.removeObject(forKey: Self.lastUsedDurationKey)
    }
}
