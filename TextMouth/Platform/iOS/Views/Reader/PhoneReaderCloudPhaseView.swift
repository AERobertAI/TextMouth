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

/// The reader's content, or the cloud phase in its place while the book isn't on the phone: a view that watches the reader's
/// phase, which the screen above it, watching only the session, would not see change.
struct PhoneReaderCloudGate<Normal: View>: View {
    /// The open reader, or none.
    let reader: ReaderViewModel?
    /// What shows when the book is ready.
    @ViewBuilder let normal: () -> Normal

    var body: some View {
        if let reader {
            Watching(reader: reader, normal: normal)
        } else {
            normal()
        }
    }

    /// The part that observes `reader`.
    private struct Watching: View {
        @ObservedObject var reader: ReaderViewModel
        let normal: () -> Normal

        var body: some View {
            if let phase = reader.cloudPhase {
                PhoneReaderCloudPhaseView(reader: reader, phase: phase)
            } else {
                normal()
            }
        }
    }
}
