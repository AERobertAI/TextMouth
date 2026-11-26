import SwiftUI

/// The spoken audio rows of the iPhone's Export sheet (FR31, phase 2), shown after Text as spoken audio while it is on,
/// as the Mac's options follow its checkbox (`SpeechExportOptionsView`), in the Mac's order and its words: the format,
/// where the audio begins and ends, the speed and the pitch, the voice, and the licence line in the iPhone's words.
/// What each row says, its label, its value, and its hint, is decided by `PhoneExportOffer.speechRows`, which the Mac's
/// test host reads; this draws what it decides.
///
/// While the book's headings are read the rows are one line saying so, and for a text that can't be read, the Mac's
/// sentence. The format, From, and To are choice rows that ask the Export sheet for their sheets (`open`), which
/// presents them from its list: a row that scrolls away takes no presenter with it (`PhoneBrailleExportRows`). The speed
/// and the pitch are sliders VoiceOver adjusts, in the steps Settings' sliders move in, and each says its value once.
struct PhoneSpeechExportRows: View {
    /// What is made of the options: the headings are being read, they are made, or the book's text can't be read.
    let making: BookExportModel.SpeechOptionsMaking
    /// Whether an export is running, which dims every row.
    let isExporting: Bool
    /// Where VoiceOver's focus is asked to go, which is the Export sheet's.
    let focus: AccessibilityFocusState<PhoneExportSheet.Focus?>.Binding
    /// Asks the Export sheet to show a choice sheet.
    let open: (PhoneExportOffer.SpeechChoice) -> Void

    var body: some View {
        switch making {
        case .notMade:
            EmptyView()
        case .making:
            ProgressView(SpeechExportWording.readingHeadings)
                .progressViewStyle(.linear)
        case .unreadable:
            Text(SpeechExportWording.unreadableText)
        case .made(let state):
            MadeRows(state: state, isExporting: isExporting, focus: focus, open: open)
        }
    }

    /// The rows of the options that are made, drawn again as they change.
    private struct MadeRows: View {
        /// The options the rows show and set.
        @ObservedObject var state: SpeechExportOptionsState
        let isExporting: Bool
        let focus: AccessibilityFocusState<PhoneExportSheet.Focus?>.Binding
        let open: (PhoneExportOffer.SpeechChoice) -> Void

        var body: some View {
            ForEach(PhoneExportOffer.speechRows(state), id: \.label) { row in
                draw(row)
            }
        }

        /// The row `row` decides, drawn as its control.
        @ViewBuilder
        private func draw(_ row: PhoneExportOffer.SpeechRow) -> some View {
            switch row.control {
            case .choice(let which):
                Button {
                    open(which)
                } label: {
                    PhoneValueRow(name: row.label, value: row.value ?? "")
                }
                .disabled(isExporting)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.value ?? "")
                .accessibilityHint(row.hint)
                .accessibilityFocused(focus, equals: .speech(which))
            case .speed:
                slider(
                    row, value: $state.wordsPerMinute,
                    range: SettingsPolicy.wordsPerMinute.range, step: ReaderViewModel.speechSpeedStep
                )
            case .pitch:
                slider(row, value: $state.pitch, range: SettingsPolicy.pitchMultiplier.range, step: PhoneExportOffer.pitchStep)
            case .note:
                Text(row.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        /// A slider that says its label, its value in words, and its hint: the value is shown above it for the eye and
        /// hidden from VoiceOver, which hears it once, as the slider's own. The label is the slider's own label view: a
        /// second accessibility label would be added to it and read twice ("Speed, Speed").
        private func slider(_ row: PhoneExportOffer.SpeechRow, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                PhoneValueRow(name: row.label, value: row.value ?? "")
                    .accessibilityHidden(true)
                Slider(value: value, in: range, step: step) {
                    Text(row.label)
                }
                .accessibilityValue(row.value ?? "")
                .accessibilityHint(row.hint)
            }
            .disabled(isExporting)
        }
    }
}

// MARK: - The Choices

/// A request for one of the spoken audio choice sheets, which the Export sheet presents.
struct PhoneSpeechExportRequest: Identifiable {
    /// The choice to make.
    let choice: PhoneExportOffer.SpeechChoice

    var id: String { choice.rawValue }
}

/// The sheet of one spoken audio choice, over the options `state` holds: the format, where the audio begins, or where it ends.
struct PhoneSpeechExportChoices: View {
    /// The options the choice sets.
    @ObservedObject var state: SpeechExportOptionsState
    /// The choice to make.
    let choice: PhoneExportOffer.SpeechChoice

    var body: some View {
        switch choice {
        case .format:
            PhoneChoiceSheet(
                title: SpeechExportWording.formatLabel,
                choices: state.formats.map { PhoneChoice(id: $0, label: $0.title) },
                selected: state.format
            ) { state.format = $0 }
        case .from:
            PhoneChoiceSheet(
                title: SpeechExportWording.fromLabel,
                choices: state.fromItems.map { PhoneChoice(id: $0.tag, label: $0.title) },
                selected: state.fromTag
            ) { state.setFrom($0) }
        case .through:
            PhoneChoiceSheet(
                title: SpeechExportWording.throughLabel,
                choices: state.throughItems.map { PhoneChoice(id: $0.tag, label: $0.title) },
                selected: state.throughTag
            ) { state.setThrough($0) }
        }
    }
}
