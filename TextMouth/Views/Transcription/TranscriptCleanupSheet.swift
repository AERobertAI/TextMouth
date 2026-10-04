import AppKit
import SwiftUI

/// The Clean Up sheet (FR05, experimental): the rules in use, what they
/// would change in the book's transcript, rule by rule with examples before
/// and after, and Apply, Undo Cleanup, Edit Rules…, and Cancel.
///
/// Every line is text VoiceOver reads, each rule's changes are one element
/// VoiceOver reads whole, each control has a label and a hint, and the
/// words come from `TranscriptCleanupWording`, the same on screen and in
/// speech. As the sheet appears, VoiceOver moves to its first control
/// (`TranscriptCleanupSheetModel.focusTarget`), then hears the sheet's lines
/// together. Return presses Apply, and Escape presses Cancel, OK, or Close.
/// Coming back to TextMouth, as after editing the rules, shows what the
/// rules would change then.
struct TranscriptCleanupSheet: View {
    /// The sheet's state, and the cleanup.
    @ObservedObject var model: TranscriptCleanupSheetModel

    /// The control with keyboard focus.
    @FocusState private var focused: TranscriptCleanupSheetModel.FocusTarget?

    /// The tallest the list of changes grows before it scrolls.
    static let changesHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.heading)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .onExitCommand { model.escape() }
        .task { await model.load() }
        .task(id: model.focusTarget) { await moveFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: Parts

    /// What the sheet holds in its phase.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView(TranscriptCleanupWording.checking)
                .progressViewStyle(.linear)
            buttonRow {
                cancelButton
            }
        case .unavailable(let reason):
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow {
                closingButton(TranscriptCleanupWording.okTitle, target: .ok)
            }
        case .ready, .working:
            readyLines
            changesList
            if case .working(let line) = model.phase {
                ProgressView(line)
                    .progressViewStyle(.linear)
            }
            buttonRow {
                editRulesButton
                Spacer()
                if model.canUndo {
                    undoButton
                }
                cancelButton
                applyButton
            }
        case .failed(let reason):
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow {
                closingButton(TranscriptCleanupWording.closeTitle, target: .close)
            }
        }
    }

    /// The lines above the list: what the cleanup is, the rules, notices
    /// about the user's copy of them, what would change, and the
    /// transcript's last cleanup.
    private var readyLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TranscriptCleanupWording.experimentalLine)
                .fixedSize(horizontal: false, vertical: true)
            if let rulesLine = model.rulesLine {
                Text(rulesLine)
            }
            ForEach(model.rulesNoticeLines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = model.summaryLine {
                Text(summary)
                    .font(.headline)
            }
            ForEach(model.historyLines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Each rule's changes, a line and its examples, read by VoiceOver as
    /// one element each, in a list that scrolls once it is tall.
    @ViewBuilder
    private var changesList: some View {
        let rows = model.changeRows
        if !rows.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .bold()
                            ForEach(row.examples, id: \.self) { example in
                                Text(example)
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: Self.changesHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(TranscriptCleanupWording.changesLabel)
        }
    }

    /// The row of buttons at the sheet's foot, to the right.
    private func buttonRow<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack {
            Spacer()
            buttons()
        }
    }

    /// Edit Rules…: opens the user's copy of the rules in their editor.
    private var editRulesButton: some View {
        Button(TranscriptCleanupWording.editRulesTitle) {
            Task { await model.editRules() }
        }
        .disabled(!model.isIdle)
        .accessibilityHint(TranscriptCleanupWording.editRulesHint)
    }

    /// Undo Cleanup: puts back the transcript from before the last cleanup.
    private var undoButton: some View {
        Button(TranscriptCleanupWording.undoTitle) {
            Task { await model.undo() }
        }
        .disabled(!model.canPressUndo)
        .accessibilityHint(TranscriptCleanupWording.undoHint)
    }

    /// Cancel: closes the sheet without changing the transcript.
    private var cancelButton: some View {
        Button(TranscriptCleanupWording.cancelTitle) {
            model.close()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(!model.isIdle)
        .accessibilityHint(TranscriptCleanupWording.cancelHint)
        .focusing(.cancel, first: model.focusTarget, $focused)
    }

    /// Apply: makes the changes listed.
    private var applyButton: some View {
        Button(TranscriptCleanupWording.applyTitle) {
            Task { await model.apply() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canApply)
        .accessibilityHint(TranscriptCleanupWording.applyHint)
        .focusing(.apply, first: model.focusTarget, $focused)
    }

    /// OK or Close: the one button of a sheet that only says why.
    private func closingButton(_ title: String, target: TranscriptCleanupSheetModel.FocusTarget) -> some View {
        Button(title) {
            model.close()
        }
        .keyboardShortcut(.defaultAction)
        .focusing(target, first: model.focusTarget, $focused)
    }

    // MARK: Focus and Announcements

    /// Gives the first control keyboard focus, then, once VoiceOver has had
    /// time to move to it too, announces the sheet's lines, so they follow
    /// the control's name rather than being cut off by it.
    private func moveFocus() async {
        guard let target = model.focusTarget else { return }
        focused = target
        try? await Task.sleep(for: .seconds(TranscriptionSheet.voiceOverFocusDelay + TranscriptionSheet.announcementLag))
        guard !Task.isCancelled else { return }
        model.announceSheet()
    }
}
