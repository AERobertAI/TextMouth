import SwiftUI

/// The Transcribe Audio sheet (FR05): the book's title and audio length,
/// how long transcribing should take, the language from the setting with its
/// model's status, a Download button when the model is missing, and
/// Transcribe, which starts the transcription and shows it here with Cancel.
///
/// Every line is text VoiceOver reads, each control has a label and a hint,
/// and the words come from `TranscriptionWording`, the same on screen and in
/// speech. As the sheet appears, and whenever it changes what it offers,
/// VoiceOver moves to its first control (`TranscriptionSheetModel.focusTarget`),
/// then hears the sheet's lines together. Return presses the default
/// button, and Escape presses Cancel, OK, or Close.
struct TranscriptionSheet: View {
    /// The sheet's state, and the transcription.
    @ObservedObject var model: TranscriptionSheetModel

    /// The control with keyboard focus.
    @FocusState private var focused: TranscriptionSheetModel.FocusTarget?

    /// How long VoiceOver waits before moving to the first control, as
    /// other sheets wait while one slides in.
    static let voiceOverFocusDelay: TimeInterval = 1.2
    /// How long after VoiceOver's move the sheet's lines are announced: time
    /// for VoiceOver to land on the control and say its name.
    static let announcementLag: TimeInterval = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.heading)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .onExitCommand { model.escape() }
        .task { await model.load() }
        .task(id: model.focusTarget) { await moveFocus() }
        .onDisappear { model.sheetClosed() }
    }

    // MARK: Parts

    /// What the sheet holds in its phase.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView(TranscriptionWording.checking)
                .progressViewStyle(.linear)
            buttonRow {
                cancelButton
            }
        case .unavailable(let reason):
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow {
                closingButton(TranscriptionWording.okTitle, target: .ok)
            }
        case .ready:
            readyLines
            buttonRow {
                cancelButton
                transcribeButton
            }
        case .transcribing:
            transcriptionProgress
            buttonRow {
                stopButton
            }
        case .failed(let reason):
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow {
                closingButton(TranscriptionWording.closeTitle, target: .close)
            }
        }
    }

    /// The lines of a sheet ready to transcribe: the audio, the estimate,
    /// the language with its model's status and the download's controls,
    /// the book's transcript, another transcription under way, and how the
    /// last download ended.
    @ViewBuilder
    private var readyLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.audioLine)
            Text(model.estimateLine)
            Text(model.languageLine)
            Text(TranscriptionWording.languageHint)
                .font(.caption)
                .foregroundColor(.secondary)
            downloadControls
            ForEach(model.noticeLines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The Download button while the model is missing, or the download's
    /// progress and Cancel Download while it downloads.
    @ViewBuilder
    private var downloadControls: some View {
        if model.offersDownload {
            Button(TranscriptionWording.downloadTitle(languageName: model.modelLanguageName)) {
                model.downloadModel()
            }
            .accessibilityHint(TranscriptionWording.downloadHint)
            .focusing(.download, first: model.focusTarget, $focused)
        } else if let line = model.downloadLine {
            HStack {
                downloadProgress(line)
                Button(TranscriptionWording.cancelDownloadTitle) {
                    model.cancelDownload()
                }
                .accessibilityHint(TranscriptionWording.cancelDownloadHint)
                .focusing(.cancelDownload, first: model.focusTarget, $focused)
            }
        }
    }

    /// The download's progress bar, labelled and valued with `line`.
    @ViewBuilder
    private func downloadProgress(_ line: String) -> some View {
        Group {
            if case .downloading(let fraction?) = model.modelState {
                ProgressView(value: fraction) {
                    Text(line)
                }
            } else {
                ProgressView {
                    Text(line)
                }
            }
        }
        .progressViewStyle(.linear)
        .accessibilityLabel(line)
    }

    /// The transcription under way: the file being transcribed and how much
    /// of the audio is done, how long it has run, and its progress bar,
    /// which VoiceOver moves to and reads as "40 percent, file 3 of 12".
    @ViewBuilder
    private var transcriptionProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.progressLines, id: \.self) { line in
                Text(line)
            }
            if let started = model.transcriptionStartedAt {
                // Ticks once a second, so the time shown keeps up between
                // the transcription's reports.
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(TranscriptionWording.elapsedLine(context.date.timeIntervalSince(started)))
                }
            }
            transcriptionProgressBar
                .focusing(.progress, first: model.focusTarget, $focused)
        }
    }

    /// The transcription's progress bar: how much of the book's audio is
    /// done, or, before its first file begins, a bar that only moves.
    private var transcriptionProgressBar: some View {
        Group {
            if let progress = model.progress {
                ProgressView(value: progress.fractionDone) {
                    Text(TranscriptionWording.progressLabel)
                }
            } else {
                ProgressView {
                    Text(TranscriptionWording.progressLabel)
                }
            }
        }
        .progressViewStyle(.linear)
        .accessibilityLabel(TranscriptionWording.progressLabel)
        .accessibilityValue(model.progressValue)
    }

    /// The row of buttons at the sheet's foot, to the right.
    private func buttonRow<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack {
            Spacer()
            buttons()
        }
    }

    /// Cancel: closes the sheet without transcribing.
    private var cancelButton: some View {
        Button(TranscriptionWording.cancelTitle) {
            model.close()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityHint(TranscriptionWording.cancelHint)
        .focusing(.cancel, first: model.focusTarget, $focused)
    }

    /// Transcribe, or Retranscribe for a book transcribed already.
    private var transcribeButton: some View {
        Button(model.transcribeTitle) {
            model.transcribe()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canTranscribe)
        .accessibilityHint(model.transcribeHint)
        .focusing(.transcribe, first: model.focusTarget, $focused)
    }

    /// Cancel while the book is transcribed: stops the transcription.
    private var stopButton: some View {
        Button(TranscriptionWording.cancelTitle) {
            model.cancelTranscription()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityHint(TranscriptionWording.stopHint)
        .focusing(.stop, first: model.focusTarget, $focused)
    }

    /// OK or Close: the one button of a sheet that only says why.
    private func closingButton(_ title: String, target: TranscriptionSheetModel.FocusTarget) -> some View {
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
        try? await Task.sleep(for: .seconds(Self.voiceOverFocusDelay + Self.announcementLag))
        guard !Task.isCancelled else { return }
        model.announceSheet()
    }
}

extension View {
    /// Marks this control as `target` of a transcription sheet whose first
    /// control is now `first`, the Transcribe Audio sheet's or the Clean Up
    /// sheet's: it takes keyboard focus while the sheet's focus is on it,
    /// and VoiceOver moves to it once when it becomes the first control.
    func focusing<Target: Hashable>(
        _ target: Target,
        first: Target?,
        _ focus: FocusState<Target?>.Binding
    ) -> some View {
        focused(focus, equals: target)
            .modifier(InitialVoiceOverFocusModifier(
                isTarget: first == target,
                delay: TranscriptionSheet.voiceOverFocusDelay
            ))
    }
}
