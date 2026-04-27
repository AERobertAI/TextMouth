import Foundation
import Combine
import AppKit

/// Manages the sleep timer. The minutes-based countdown is paused
/// alongside playback (via `pauseCountdown` / `resumeCountdown`) so a
/// timer set before a long break doesn't expire silently in the
/// background and pause the user mid-sentence after they resume.
/// Heading-end and document-end modes don't tick on a clock, so they
/// are unaffected by playback state.
class SleepTimerService: ObservableObject {
    @Published var isActive = false
    @Published var remainingSeconds: Int = 0
    @Published var duration: SleepTimerDuration?
    @Published var isFadingOut = false

    var onTimerExpired: (() -> Void)?
    /// Called during fade-out with a volume value from 1.0 down to 0.0
    var onFadeStep: ((Float) -> Void)?

    /// Fade-out duration in seconds (0 = instant pause, no fade)
    var fadeOutDuration: TimeInterval = 0

    private var timer: Timer?
    private var fadeTimer: Timer?
    private var endOfHeadingTriggered = false
    /// Generation counter to prevent stale fade/expire callbacks from firing after stop()
    private var generation: Int = 0
    /// True when the minutes-based countdown is currently halted because
    /// playback is paused. The repeating Timer is invalidated and
    /// `remainingSeconds` is preserved; `resumeCountdown()` re-arms it
    /// with the same remaining time. Fade timers are NOT paused —
    /// once a fade has begun, the user is already being put to sleep
    /// and halting the fade would leave audio at an arbitrary low volume.
    private var isCountdownPausedByPlayback = false

    func start(duration: SleepTimerDuration) {
        stop()
        self.duration = duration
        self.isActive = true
        self.endOfHeadingTriggered = false

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

    /// Restart the timer with the same duration. No-op if no timer is active.
    func restart() {
        guard let current = duration else { return }
        start(duration: current)
    }

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
    }

    /// Halt the minutes-based countdown without losing remaining time.
    /// Called from the playback layer when the user pauses, so the
    /// timer doesn't keep ticking in the background and expire while
    /// the user is away on a break.
    /// No-op for heading-end / document-end modes (which don't use a
    /// wall-clock timer), and no-op when a fade is already in progress
    /// (the user is in the middle of being put to sleep).
    func pauseCountdown() {
        guard isActive,
              case .minutes = duration,
              !isFadingOut,
              let activeTimer = timer else { return }
        activeTimer.invalidate()
        timer = nil
        isCountdownPausedByPlayback = true
    }

    /// Resume a previously-paused countdown with its preserved remaining
    /// time. Called from the playback layer when the user resumes.
    /// No-op when there's nothing paused.
    func resumeCountdown() {
        guard isActive, isCountdownPausedByPlayback, case .minutes = duration else { return }
        isCountdownPausedByPlayback = false
        startCountdown()
    }

    func notifyHeadingBoundary() {
        guard isActive, case .endOfHeading = duration else { return }
        if endOfHeadingTriggered {
            expire()
        } else {
            endOfHeadingTriggered = true
        }
    }

    func notifyDocumentEnd() {
        guard isActive else { return }
        if case .endOfDocument = duration {
            expire()
        }
    }

    private func startCountdown() {
        let gen = generation
        // Ensure timer runs on main thread for @Published safety
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                if self.remainingSeconds > 0 {
                    self.remainingSeconds -= 1
                }
                // Announce key milestones for VoiceOver users
                self.announceIfMilestone()
                if self.remainingSeconds <= 0 {
                    self.expire()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        let totalSteps = max(1, Int(fadeOutDuration * 10)) // 10 steps per second
        let stepInterval = fadeOutDuration / Double(totalSteps)
        var currentStep = 0

        let ft = Timer(timeInterval: stepInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            DispatchQueue.main.async {
                guard self.generation == gen else {
                    timer.invalidate()
                    return
                }
                currentStep += 1
                let volume = Float(max(0, 1.0 - Double(currentStep) / Double(totalSteps)))
                self.onFadeStep?(volume)

                if currentStep >= totalSteps {
                    timer.invalidate()
                    self.fadeTimer = nil
                    self.isFadingOut = false
                    self.isActive = false
                    self.onTimerExpired?()
                }
            }
        }
        RunLoop.main.add(ft, forMode: .common)
        fadeTimer = ft
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
}
