import Foundation

/// Watches for a text book's pause growing long, so that what a paused
/// reader holds only for an instant resume is let go once the listener has
/// plainly walked away (audit C11 and C12).
///
/// One watch serves both savings, so they begin together: when it elapses
/// the reader lets go of the next chapter's rendered audio
/// (`ReaderViewModel.releaseLookAheadAudioForLongPause()`) and asks the
/// paused engine to wake less often (`SpeechService.throttlePausedEngine()`).
/// Whatever ends the pause ends the watch first: a resume, a new play, a
/// stop, the reader closing.
///
/// A value of its reader, begun and ended only on the main actor.
@MainActor
final class LongPauseWatch {
    /// How long a pause lasts before it counts as long: five minutes.
    ///
    /// Shorter pauses are a listener answering the door or a call, who comes
    /// back expecting everything as it was. Past five minutes the only costs
    /// of letting go are a render of a few seconds made again, for a pause
    /// near a chapter's end, and an output buffer set back before the first
    /// sound; neither is heard. It is the look-ahead's smallest lead too
    /// (`LookAheadLead.minimum`), so one number says what "a few minutes"
    /// means to playback.
    static let delay: TimeInterval = 5 * 60

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
