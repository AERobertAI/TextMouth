import Foundation

/// How much later than its time the app lets a background timer fire, so
/// that macOS can coalesce its wake-ups with other work instead of waking
/// the processor for each timer alone (November 13, 2026 audit, C16).
///
/// Only timers nobody hears or sees to the second use it: the statistics
/// checkpoint, the session lease, the speech watchdogs, and the Stats pane's
/// refresh. The sleep timer's countdown keeps its interval exact, since its
/// announcements and its expiry are heard.
enum TimerCoalescing {
    /// The tolerance as a fraction of the timer's interval.
    static let fraction: Double = 0.1

    /// The tolerance a timer of `interval` seconds gets: a tenth of it.
    /// A zero or negative interval (a timer that fires at once) gets none.
    static func tolerance(forInterval interval: TimeInterval) -> TimeInterval {
        max(0, interval) * fraction
    }

    /// Lets `timer` fire up to a tenth of its interval late, and returns it,
    /// so a timer is made and loosened in one expression.
    @discardableResult
    static func loosen(_ timer: Timer) -> Timer {
        timer.tolerance = tolerance(forInterval: timer.timeInterval)
        return timer
    }
}
