import SwiftUI

/// The import's progress, rebuilt for the phone with the Mac's words (the
/// spec's "Progress"): "Importing Books", its lines, and the Mac's Cancel
/// Import. The Library places it at the top of its list. It isn't a modal,
/// so everything goes on working around it, and it shows nothing while
/// nothing imports.
///
/// Its words are read when VoiceOver asks, from a container labelled with
/// every line, as the Mac's overlay is; it announces nothing as it moves.
/// It observes only the copier and the library's `ImportProgress`, which
/// publish only while an import runs, never the library or the reader.
struct PhoneImportProgressCard: View {
    /// The copier, for the copy under way and whether anything imports.
    @ObservedObject private var copier: PhoneImportCopier
    /// The shared import's progress.
    @ObservedObject private var progress: ImportProgress

    /// The card over the process's copier and the app's library.
    init(copier: PhoneImportCopier = .shared) {
        self.copier = copier
        progress = TextMouthAppDelegate.model.library.importProgress
    }

    var body: some View {
        if copier.isUnderWay {
            // Ticks in the steps the time on a book moves in, as the Mac's
            // overlay does, so that time keeps up between reports.
            TimelineView(.periodic(from: progress.state.book?.startedAt ?? Date(), by: ImportProgressWording.timeOnBookStep)) { context in
                card(at: context.date)
            }
        }
    }

    /// The card as it is at `now`.
    private func card(at now: Date) -> some View {
        let lines = PhoneImportWording.cardLines(copying: copier.copyStatus, state: progress.state, at: now)
        let state = progress.state
        return VStack(alignment: .leading, spacing: 8) {
            Text(ImportProgressWording.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if copier.copyStatus == nil, state.total > 0 {
                ProgressView(value: Double(state.current), total: Double(state.total))
            } else {
                ProgressView()
            }
            // By position: a line's words change as the import moves, and
            // its place stays the same.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(AddToLibraryWording.cancel) {
                copier.cancelImports()
            }
            .accessibilityLabel(ProgressOverlay.cancelButtonLabel)
            .accessibilityHint(ProgressOverlay.cancelButtonHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A container, not one combined element: combining would fold the
        // Cancel button into the status, out of VoiceOver's reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PhoneImportWording.cardSummary(copying: copier.copyStatus, state: state, at: now))
    }
}
