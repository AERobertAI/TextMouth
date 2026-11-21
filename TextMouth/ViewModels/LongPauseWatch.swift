import Foundation

/// Watches for a text book's pause growing long, so that what a paused
/// reader holds only for an instant resume is let go once the listener has
/// plainly walked away (audit C11).
///
/// When it elapses the reader lets go of the next chapter's rendered audio
/// (`ReaderViewModel.settleIntoLongPause()`). Whatever ends the pause ends
/// the watch first: a resume, a new play, a stop, the reader closing. It is
/// the one timer for anything else a long pause should let go of later, as
/// the audit's C12 would have the paused engine's output wake less often
/// (measured and not built: `Scripts/agents/probes/paused-engine-wakeups-probe.swift`).
///
/// A value of its reader, begun and ended only on the main actor.
@MainActor
final class LongPauseWatch {
    /// How long a pause lasts before it counts as long: five minutes.
    ///
    /// Shorter pauses are a listener answering the door or a call, who comes
    /// back expecting everything as it was. Past five minutes the only cost
    /// of letting go is a render of a few seconds made again, for a pause
    /// near a chapter's end, which is not heard. It is the look-ahead's
    /// smallest lead (`LookAheadLead.minimum`), so one number says what "a
    /// few minutes" means to playback.
    ///
    /// Only time the Mac is awake counts: the watch waits on the main
    /// queue's uptime clock, which stops while the Mac sleeps, so a pause
    /// that spans a sleep grows long five waking minutes after it began.
    static let delay: TimeInterval = LookAheadLead.minimum

    /// The pause's end of patience, waiting on the main queue, or nil.
    private var pending: DispatchWorkItem?

    /// What to do when the pause grows long, kept while the watch waits so
    /// that a test can elapse it without waiting (`_elapseNowForTesting()`).
    private var whenElapsed: (@MainActor () -> Void)?

    /// Whether the pause being watched has lasted `delay`; false again once
    /// the watch ends.
    private(set) var hasElapsed = false

    /// Whether a pause is being watched that has not grown long yet.
    var isWaiting: Bool { pending != nil }

    /// Begin watching a pause that starts now, in place of any pause watched
    /// before. `elapsed` runs once, on the main actor, if the watch has not
    /// ended `delay` seconds from now.
    func begin(after delay: TimeInterval = LongPauseWatch.delay, _ elapsed: @escaping @MainActor () -> Void) {
        end()
        whenElapsed = elapsed
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.elapse() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// End the watch: the pause is over, or what was paused is gone. Nothing
    /// runs later, and the pause no longer counts as long.
    func end() {
        pending?.cancel()
        pending = nil
        whenElapsed = nil
        hasElapsed = false
    }

    /// The pause has grown long: note it, then tell the reader, once.
    private func elapse() {
        guard let whenElapsed else { return }
        pending = nil
        self.whenElapsed = nil
        hasElapsed = true
        whenElapsed()
    }

    /// Lets the pause being watched grow long at once, as though `delay` had
    /// passed; nothing happens when no pause is waiting.
    func _elapseNowForTesting() {
        pending?.cancel()
        elapse()
    }
}
