import Foundation

/// When a shake of the iPhone starts the sleep timer again (FR55), as the
/// Audible app does: within a minute after a timer ended by itself, the shake
/// restarts the same timer, the one last used.
///
/// The shake reaches the app through UIKit's motion events
/// (`motionEnded(_:with:)` with `.motionShake`, on `MagicTapWindow`), which
/// UIKit delivers only to the app in front, the screen unlocked; nothing polls
/// the motion sensors in the background.
///
/// A plain decision with no clock of its own, so a test gives it the moments.
enum PhoneShakeRestart {
    /// How long after a timer ends a shake still starts it again.
    static let window: Duration = .seconds(60)

    /// Whether a shake at `now` starts the timer again.
    ///
    /// - Parameters:
    ///   - isEnabled: Settings' switch, on by default.
    ///   - timerRuns: Whether a timer runs now: a running timer is restarted
    ///     on its own control, never by a shake.
    ///   - endedAt: When the timer last ended by itself, or nil
    ///     (`SleepTimerService.endedByItselfAt`): a timer cancelled, or one
    ///     started since, leaves nothing to restart.
    ///   - now: The moment of the shake, on the same clock.
    static func restarts(
        isEnabled: Bool,
        timerRuns: Bool,
        endedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard isEnabled, !timerRuns, let endedAt else { return false }
        let since = endedAt.duration(to: now)
        return since >= .zero && since <= window
    }
}
