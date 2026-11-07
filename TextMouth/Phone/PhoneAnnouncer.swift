import Foundation

/// What the iPhone's own code says to VoiceOver, at the three strengths the
/// spec uses. Each waits a moment first (`delay`), so that the words follow
/// VoiceOver's own speech about what just changed rather than cut it off.
///
/// On iOS the shared announcer's high and medium priorities both wait for
/// current speech (`VoiceOverAnnouncer.postThroughAccessibility`), so that the
/// shared code's many high-priority words never interrupt; `important` keeps
/// the interrupting priority by a path of its own, for the few words that must
/// be heard at once.
@MainActor
enum PhoneAnnouncer {
    /// How long each announcement waits, in seconds.
    nonisolated static let delay: TimeInterval = 0.15

    /// Runs the announcement after `delay`: the main queue, unless a test runs
    /// it at once.
    static var schedule: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void = {
        delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            work()
        }
    }

    /// Says `message` after VoiceOver's current speech.
    static func say(_ message: String) {
        schedule(delay) { VoiceOverAnnouncer.announce(message, priority: .medium) }
    }

    /// Says `message` with low priority: VoiceOver may drop it for speech of
    /// its own.
    static func low(_ message: String) {
        schedule(delay) { VoiceOverAnnouncer.announce(message, priority: .low) }
    }

    /// Says `message` at once, interrupting VoiceOver's current speech.
    static func important(_ message: String) {
        schedule(delay) { postImportant(message) }
    }

    /// Posts `message` at iOS's interrupting priority, by a path of its own,
    /// since the shared announcer's high priority waits on iOS. On the Mac, and
    /// in a process hosting tests, it goes through the announcer's poster at
    /// high priority, so a test reads it.
    private static func postImportant(_ message: String) {
        #if os(iOS)
        guard VoiceOverAnnouncer.defaultDelivery(for: .current) == .post else {
            VoiceOverAnnouncer.announce(message, priority: .high)
            return
        }
        VoiceOverAnnouncer.postToVoiceOver(message, priority: .high)
        #else
        VoiceOverAnnouncer.announce(message, priority: .high)
        #endif
    }
}
