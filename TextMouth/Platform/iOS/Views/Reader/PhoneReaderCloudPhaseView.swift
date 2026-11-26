import Combine
import SwiftUI

/// The reader's screen while its book is got from the cloud (FR43, as the Mac's
/// `ReaderCloudPhaseView`): the download with a progress bar and Cancel, or the
/// reason the book isn't ready with the one button that tries again. What it shows
/// is `PhoneReaderCloudPhaseContent`'s; this only draws it. VoiceOver's focus moves
/// to the progress bar, or to the reason, once the screen has settled. Back still works, so
/// there is no Close.
///
/// Nothing here has run on a phone: that VoiceOver lands on the bar, hears its value step
/// every few seconds, and that Cancel and Try Again are reachable is a hand check.
struct PhoneReaderCloudPhaseView: View {
    /// The reader, whose phase this shows and whose commands its buttons run.
    @ObservedObject var reader: ReaderViewModel
    /// The phase being shown.
    let phase: ReaderCloudPhase
    /// VoiceOver's focus: the bar of a download, the reason of a message.
    @AccessibilityFocusState private var targetFocused: Bool

    var body: some View {
        let content = PhoneReaderCloudPhaseContent.of(phase: phase, title: reader.book.title, provider: reader.cloudProvider)
        VStack(spacing: 16) {
            switch content.body {
            case .download(let heading, let source, let progressLabel, let cancel):
                Text(heading)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .phonePrimaryText()
                    .accessibilityAddTraits(.isHeader)
                Text(source).phoneSecondaryText()
                if case .downloading(let download) = phase {
                    progress(of: download, label: progressLabel)
                }
                Button(cancel.title) { reader.cancelDownload() }
                    .accessibilityHint(cancel.hint)
            case .message(let text, let action):
                Image(systemName: "icloud.and.arrow.down")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .phonePrimaryText()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($targetFocused)
                Button(action.title) { perform(action: phase) }
                    .accessibilityHint(action.hint)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The screen settles before focus is asked for; a request made at once is lost (`PhoneListFocus`).
        // Once per kind of phase: a download's progress changes the phase again and again, and focus is not asked for each time.
        .task(id: Self.kind(of: phase)) {
            try? await Task.sleep(for: .milliseconds(350))
            targetFocused = true
        }
    }

    /// The progress bar, its value stepping every few seconds so VoiceOver and a braille display are not kept busy.
    private func progress(of download: ReaderDownload, label: String) -> some View {
        TimelineView(.periodic(from: download.startedAt, by: ReaderCloudWording.elapsedStep)) { context in
            let elapsed = ReaderCloudWording.elapsed(since: download.startedAt, at: context.date)
            VStack(spacing: 6) {
                // One progress view, with no value while there is no percentage, so it stays the same element.
                ProgressView(value: ReaderCloudWording.fraction(of: download))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(label)
                    .accessibilityValue(ReaderCloudWording.progressValue(of: download, elapsed: elapsed, spoken: true))
                    .accessibilityFocused($targetFocused)
                // The bar's value, shown; VoiceOver hears it on the bar.
                Text(ReaderCloudWording.progressValue(of: download, elapsed: elapsed, spoken: false))
                    .font(.callout)
                    .monospacedDigit()
                    .phoneSecondaryText()
                    .accessibilityHidden(true)
            }
        }
    }

    /// Which of the four screens `phase` is, whatever its progress.
    private static func kind(of phase: ReaderCloudPhase) -> Int {
        switch phase {
        case .downloading: return 0
        case .notDownloaded: return 1
        case .failed: return 2
        case .waitingForSync: return 3
        }
    }

    /// What the message's button does: download again after a cancel, or open the book afresh.
    private func perform(action phase: ReaderCloudPhase) {
        if case .notDownloaded = phase {
            reader.downloadAgain()
        } else {
            reader.retryOpening()
        }
    }
}

/// The reader's content, or the cloud phase in its place while the book isn't on the phone. It watches the reader's
/// `cloudPhase` alone, never the reader itself: the reader publishes at every word it speaks, and the reader screen is
/// built to be drawn again only when the session's snapshot changes ("never as the place moves"). Watching the whole reader
/// here drew the screen's controls again at each word, and a sheet presented from it (Export, for one) was not safe. The
/// views swap inside a stack, so the stack, which the screen's sheets hang on, keeps one identity for every phase.
struct PhoneReaderCloudGate<Normal: View>: View {
    /// The open reader, or none.
    let reader: ReaderViewModel?
    /// What shows when the book is ready.
    @ViewBuilder let normal: () -> Normal
    /// The reader's phase, changing only when the phase does.
    @StateObject private var watcher = PhoneCloudPhaseWatcher()

    var body: some View {
        ZStack {
            if let reader, let phase = watcher.phase {
                PhoneReaderCloudPhaseView(reader: reader, phase: phase)
            } else {
                normal()
            }
        }
        // The same reader keeps the same watch; the next book's is a new one.
        .task(id: reader.map(ObjectIdentifier.init)) { watcher.watch(reader) }
    }
}

/// The cloud phase of one reader, republished when it changes, and not when anything else of the reader does.
@MainActor
final class PhoneCloudPhaseWatcher: ObservableObject {
    /// The phase of the reader being watched; nil when the book is ready, or no reader is open.
    @Published private(set) var phase: ReaderCloudPhase?
    /// The subscription to the reader's `cloudPhase`.
    private var subscription: AnyCancellable?

    /// Watches `reader`, or nothing.
    func watch(_ reader: ReaderViewModel?) {
        phase = reader?.cloudPhase
        subscription = reader?.$cloudPhase
            .removeDuplicates()
            .sink { [weak self] new in
                // `$cloudPhase` publishes just before the change, with the new value.
                MainActor.assumeIsolated { self?.phase = new }
            }
    }
}
