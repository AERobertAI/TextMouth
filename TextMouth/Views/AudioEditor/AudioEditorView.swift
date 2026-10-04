import SwiftUI

/// The audio editor window (FR04): one audio file of a book, edited by the
/// keyboard and VoiceOver.
///
/// The window is built of native elements VoiceOver and a braille display
/// read as they do everywhere in TextMouth: the book's title as a heading;
/// the time display, where VoiceOver starts, whose value says where the
/// cursor is in words; the status line, which says the rest; and the line
/// repeating the last announcement, so a braille display can read it again.
/// Nothing is announced while the audio plays.
struct AudioEditorView: View {
    /// What the window shows and does.
    @ObservedObject var model: AudioEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                timeDisplay
                statusLine
                messageLine
                // For sighted helpers; VoiceOver never meets it.
                AudioEditorWaveform(
                    levels: model.levels,
                    duration: model.duration,
                    cursor: model.cursor,
                    selection: model.selection,
                    chapters: model.chapters.map(\.start),
                    markers: model.markers.map(\.time)
                )
                ForEach(Self.groups) { group in
                    AudioEditorCommandGroup(heading: group.heading, actions: group.actions, model: model)
                }
                microphonePicker
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 640)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .prompt(let prompt):
                AudioEditorPromptSheet(
                    prompt: prompt,
                    initialText: model.initialText(for: prompt),
                    submit: { model.answer(prompt, with: $0) },
                    cancel: { model.sheet = nil }
                )
            case .markers:
                AudioEditorMarkersSheet(model: model)
            case .filter:
                AudioEditorFilterSheet(model: model)
            case .progress:
                AudioEditorProgressSheet(model: model)
            case .export:
                AudioEditorExportSheet(model: model)
            case .info:
                AudioEditorInfoSheet(model: model)
            }
        }
        .alert(AudioEditorWording.revertQuestion, isPresented: $model.confirmingRevert) {
            Button(AudioEditorWording.revertButton, role: .destructive) {
                Task { await model.revertToOriginal() }
            }
            Button(AudioEditorWording.cancelButton, role: .cancel) {}
        } message: {
            Text(AudioEditorWording.revertExplanation(model.session.list.cursor, markers: model.markers.count))
        }
    }

    /// The window's groups of command buttons, in order, each under its
    /// heading: every editor command has a button in one of them.
    static let groups: [AudioEditorCommandList] = [
        AudioEditorCommandList(heading: AudioEditorWording.listenHeading, actions: [
            .editorPlayPause, .editorStop,
            .editorSkipBack, .editorSkipForward, .editorSkipBackLong, .editorSkipForwardLong,
            .editorSkipBackShort, .editorSkipForwardShort,
            .editorGoToStart, .editorGoToEnd, .editorGoToTime,
            .editorPreviousChapter, .editorNextChapter, .editorPreviousPause, .editorNextPause,
            .editorWhereAmI,
        ]),
        AudioEditorCommandList(heading: AudioEditorWording.selectHeading, actions: [
            .editorMarkIn, .editorMarkOut, .editorSelectToPreviousPause, .editorSelectToNextPause,
            .editorSelectChapter, .editorSelectAll, .editorClearSelection, .editorSpeakSelection,
            .editorPlaySelection, .editorAddMarker, .editorShowMarkers,
        ]),
        AudioEditorCommandList(heading: AudioEditorWording.editHeading, actions: [
            .editorUndo, .editorRedo, .editorCut, .editorCopy, .editorPaste, .editorTrimToSelection,
            .editorInsertSilence, .editorInsertChapter, .editorApplyFilter, .editorPunchIn,
        ]),
        AudioEditorCommandList(heading: AudioEditorWording.fileHeading, actions: [
            .editorSave, .editorExport, .editorRevert, .editorInfo,
        ]),
    ]

    // MARK: - Pieces

    /// The microphone Punch In records from: the microphones connected, the
    /// one in use chosen, remembered as the Record window remembers it. It
    /// can't change while a punch-in records.
    private var microphonePicker: some View {
        Picker(AudioEditorWording.microphoneLabel, selection: Binding(
            get: { model.microphoneID },
            set: { model.chooseMicrophone($0) }
        )) {
            if model.microphones.isEmpty {
                Text(AudioEditorWording.noMicrophoneItem).tag("")
            }
            ForEach(model.microphones) { device in
                Text(device.name).tag(device.id)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 420)
        .disabled(model.microphones.isEmpty || model.punchIn != nil)
        .accessibilityLabel(AudioEditorWording.microphoneLabel)
        .accessibilityHint(AudioEditorWording.microphoneHint)
        .help(AudioEditorWording.microphoneHint)
    }

    /// The book's title as the window's heading, and the track's name in a
    /// book of several.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.bookTitle)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            if let track = model.trackTitle {
                Text(track)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Where the cursor is, of how long the audio lasts: a clock on screen,
    /// words to VoiceOver. VoiceOver starts here as the window opens.
    private var timeDisplay: some View {
        Text(model.positionText)
            .font(.system(.title, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AudioEditorWording.positionLabel)
            .accessibilityValue(model.positionValue)
            .modifier(InitialVoiceOverFocusModifier(isTarget: true))
    }

    /// The status line: where the cursor is, in which chapter, and, once
    /// there is one, the selection. Read when the user moves to it, never
    /// spoken on its own.
    private var statusLine: some View {
        Text(model.statusSentence)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AudioEditorWording.statusLabel)
            .accessibilityValue(model.statusSentence)
    }

    /// The last sentence announced, shown again so a braille display can
    /// read it at leisure.
    @ViewBuilder
    private var messageLine: some View {
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AudioEditorWording.messageLabel)
                .accessibilityValue(model.lastMessage)
        }
    }
}
