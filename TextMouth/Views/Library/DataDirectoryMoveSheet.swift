import SwiftUI

/// The progress of a data-directory move under way, with its Cancel (FR02):
/// a progress bar VoiceOver calls "Moving the library", whose value says how
/// far the move has got ("40 percent", or what it waits for), the same words
/// shown beneath it for the screen, any action refused meanwhile, and
/// Cancel, which Escape presses too. Cancel is unavailable once the copy is
/// complete, when the move can only finish. Every Library window's sheet and
/// Storage settings show it.
struct DataDirectoryMoveProgressView: View {
    /// The move.
    @ObservedObject var move: DataDirectoryMoveProgress
    /// Whether VoiceOver moves to the progress bar when the view appears:
    /// in the sheet, which takes over its window.
    var takesVoiceOverFocus = false

    var body: some View {
        VStack(spacing: 10) {
            // One progress view throughout, with no amount until the copy
            // starts, so VoiceOver finds the same element in every phase.
            ProgressView(value: move.fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel(DataDirectoryMoveWording.progressLabel)
                .accessibilityValue(move.spokenValue)
                .modifier(InitialVoiceOverFocusModifier(isTarget: takesVoiceOverFocus))
            // The bar's value, shown; VoiceOver hears it on the bar.
            Text(move.statusText)
                .font(.callout)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            if let notice = move.notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Cancel", action: move.cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(!move.canCancel || move.isCancelRequested)
                .accessibilityLabel(DataDirectoryMoveWording.cancelLabel)
                .accessibilityHint(DataDirectoryMoveWording.cancelHint)
        }
    }
}

/// What every Library window shows while the library moves (FR02): a sheet
/// that keeps the window's library from being changed until the move ends,
/// with a heading, where the library is going, and the move's progress and
/// Cancel. VoiceOver moves to the progress bar when the sheet appears. The
/// sheet closes by itself when the move ends; it can't be dismissed.
struct DataDirectoryMoveSheet: View {
    /// The move.
    @ObservedObject var move: DataDirectoryMoveProgress

    var body: some View {
        VStack(spacing: 16) {
            Text(DataDirectoryMoveWording.title)
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)
            Text(move.destinationText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            DataDirectoryMoveProgressView(move: move, takesVoiceOverFocus: true)
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}
