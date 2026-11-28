import Foundation

/// What the iPhone's own code says to VoiceOver, at the two strengths the
/// spec uses. Each waits a moment first (`delay`), so that the words follow
/// VoiceOver's own speech about what just changed rather than cut it off.
///
/// Apple's header (`UIAccessibilityConstants.h`, "UIAccessibilityPriority")
/// says: high "will interrupt other speech and cannot be interrupted once
/// started"; default "will interrupt existing speech, but [is] interruptible
/// if a new speech utterance is started"; low is "queued and spoken when other
/// speech utterances have completed". So the words that must follow
/// VoiceOver's own speech (`say`) go at low, which the shared announcer posts
/// as iOS's low priority, and only `important` interrupts.
///
/// A run of words posted together would cut each other off if they went one by
/// one, since each new one interrupts or is queued behind a slow reading; so
/// a run is joined into one announcement (`joined`, `say(inOrder:)`).
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

    /// Says `message` after VoiceOver's current speech has finished: iOS's
    /// low priority, which queues rather than interrupts.
    static func say(_ message: String) {
        schedule(delay) { VoiceOverAnnouncer.announce(message, priority: .low) }
    }

    /// Says `messages` as one announcement after VoiceOver's current speech,
    /// so none is cut off by the next. Empty messages are left out; nothing is
    /// said when none is left.
    static func say(inOrder messages: [String]) {
        guard let words = joined(messages) else { return }
        say(words)
    }

    /// The sentences in `messages` run together as one announcement, each
    /// ending in a full stop, a question mark, or an exclamation mark (one is
    /// added when it lacks one, so the voice pauses between them), or nil when
    /// they're all empty. A lone message is returned as it is.
    static func joined(_ messages: [String]) -> String? {
        let kept = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // One message is said as it is, with no stop added.
        if kept.count == 1 { return kept[0] }
        let sentences = kept
            .map { sentence -> String in
                guard let last = sentence.last, !".!?…".contains(last) else { return sentence }
                return sentence + "."
            }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// `announcements` as one, for words posted together: their messages
    /// joined, at the most urgent priority among them, or nil when there are
    /// none worth saying.
    static func combined(_ announcements: [VoiceOverAnnouncement]) -> VoiceOverAnnouncement? {
        guard let words = joined(announcements.map(\.message)),
              let strongest = announcements.map(\.priority).max(by: { $0.rawValue < $1.rawValue })
        else { return nil }
        return VoiceOverAnnouncement(message: words, priority: strongest)
    }

    /// Says `message` at once, interrupting VoiceOver's current speech.
    static func important(_ message: String) {
        schedule(delay) { postImportant(message) }
    }

    /// Posts `message` at iOS's high priority, by a path of its own: the
    /// shared announcer posts its high priority at iOS's default, which a new
    /// utterance can cut off, while high "cannot be interrupted once started"
    /// (UIAccessibilityConstants.h). On the Mac, and in a process hosting
    /// tests, it goes through the announcer's poster at high priority, so a
    /// test reads it.
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
