import Foundation

/// Keeps the iPhone app running through the book's silent gaps, and saves the
/// place when the book stops in the background (spec: "Silent gaps", "Saving").
///
/// A chapter's pause, the wait before the next book, and a wait for a chapter's
/// speech all have no audio running, and iOS may suspend an app with no audio
/// almost at once, so the book would never go on. Apple's advice is "Use a
/// background task instead of streaming silence": a gap begins one hold, a named
/// background task, and the hold ends when audio may start again or has ended
/// for good. The system gives a task about 30 seconds, so a manifest's pause
/// longer than that is a known limit of the first version.
///
/// When the book's audio ends for good (a pause, a stop, the end of the book),
/// the reader has saved its place; with the app in the background, the save is
/// flushed at once, inside a hold of its own, since a suspended app may be ended
/// without a word.
///
/// The reader's hooks (`ReaderPhoneHooks.silentGapBegan`, `audioMayStart`,
/// `audioEnded`) call this; the hold itself is the life cycle's
/// (`PhoneLifeCycle.beginHold`), a background task on iOS. Plain and shared, so
/// the Mac's test host tests every decision; the wiring is iOS's
/// (`PhoneBackgroundWork`). Nothing here has run on an iPhone.
@MainActor
final class PhoneBackgroundHold {
    /// The name of the hold through a silent gap, which the system shows in its
    /// own diagnostics.
    nonisolated static let gapHoldName = "Waiting for the book's next audio"
    /// The name of the hold around the save after the book stops.
    nonisolated static let saveHoldName = "Saving the book's place"

    /// Begins a hold named by its argument, and gives back what ends it.
    private let beginHold: @MainActor (_ name: String) -> (@MainActor () -> Void)
    /// Whether the app is in the background now.
    private let isInBackground: @MainActor () -> Bool
    /// Flushes every pending write: the place the reader saved among them.
    private let flush: @MainActor () -> Void

    /// What ends the hold through the gap held now, or nil.
    private var endGapHold: (@MainActor () -> Void)?

    /// A hold over the life cycle's `beginHold`, asking `isInBackground`, and
    /// flushing with `flush`.
    init(
        beginHold: @escaping @MainActor (_ name: String) -> (@MainActor () -> Void),
        isInBackground: @escaping @MainActor () -> Bool,
        flush: @escaping @MainActor () -> Void
    ) {
        self.beginHold = beginHold
        self.isInBackground = isInBackground
        self.flush = flush
    }

    /// Whether a silent gap is held now.
    var isHoldingAGap: Bool {
        endGapHold != nil
    }

    /// The book has gone silent while it still plays: the app is held running,
    /// in one hold however many gaps begin before audio comes back.
    func silentGapBegan() {
        guard endGapHold == nil else { return }
        endGapHold = beginHold(Self.gapHoldName)
        DiagnosticLog.event(.playback, "PHONE_SILENT_GAP_HELD: the book is silent while it plays")
    }

    /// The reader asked whether its audio may start, and was answered:
    /// audio that may start ends the gap, and one that may not leaves it as it
    /// is, for the reader's own refusal to end.
    func audioMayStartAnswered(_ mayStart: Bool) {
        guard mayStart else { return }
        endGap(because: "audio-may-start")
    }

    /// The book's audio has ended for good: a pause, a stop, or the end of the
    /// book with nothing to follow. Any gap is over. In the background, the
    /// place the reader saved is flushed now, inside a hold of its own.
    func audioEnded() {
        endGap(because: "audio-ended")
        guard isInBackground() else { return }
        let endSaveHold = beginHold(Self.saveHoldName)
        flush()
        endSaveHold()
    }

    /// Ends the hold through the gap, once.
    private func endGap(because reason: String) {
        guard let end = endGapHold else { return }
        endGapHold = nil
        end()
        DiagnosticLog.event(.playback, "PHONE_SILENT_GAP_ENDED: reason=\(reason)")
    }
}
