import SwiftUI

/// The spoken audio options of the Export dialog (FMT43), shown under its
/// "Text as spoken audio" checkbox while it is checked: the Format pop-up;
/// the From and To pop-ups choosing the range of headings, or, for a book
/// without headings, a line saying the whole book is exported; the Rate and
/// Pitch sliders, which start at the book's own speed and pitch; the line
/// naming the voice; and the line about Apple's licence.
///
/// VoiceOver finds the options in one group, "Spoken audio options". Every
/// control has a label, a value, and a hint, in the words of
/// `SpeechExportWording`, the same on screen and in speech; each slider's
/// value, shown after it for the eye, is spoken once, as the slider's value
/// (TODO A10). Nothing is said by colour or place alone: the licence line's
/// lighter colour only sets it apart, its words being the same for everyone.
struct SpeechExportOptionsView: View {
    /// The options the view shows and sets.
    @ObservedObject var state: SpeechExportOptionsState

    /// The widest the From and To pop-ups grow, so a long heading never
    /// widens the dialog: the pop-up shortens the heading it shows, and its
    /// menu shows every heading whole.
    static let rangePickerMaxWidth: CGFloat = 400

    /// The width the options are laid out at when nothing else sets one, as
    /// when the dialog measures how wide to be: the room the Export dialog
    /// leaves them at its narrowest (460 points, less its 20-point margins
    /// and the options' 24-point indent). The voice and licence lines wrap
    /// there, rather than widening the dialog to show each on one line.
    static let idealWidth: CGFloat = 396

    /// How far the Pitch slider moves in one step, as the reader's and
    /// Settings' pitch sliders move.
    private static let pitchStep = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            formatPicker
            if state.hasHeadings {
                RangePicker(
                    options: state,
                    label: SpeechExportWording.fromLabel,
                    hint: SpeechExportWording.fromHint,
                    items: state.fromItems,
                    chosenTag: state.fromTag,
                    choose: state.setFrom
                )
                .equatable()
                RangePicker(
                    options: state,
                    label: SpeechExportWording.throughLabel,
                    hint: SpeechExportWording.throughHint,
                    items: state.throughItems,
                    chosenTag: state.throughTag,
                    choose: state.setThrough
                )
                .equatable()
            } else {
                Text(SpeechExportWording.noHeadings)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sliderRow(
                SpeechExportWording.rateLabel,
                value: $state.wordsPerMinute,
                in: SettingsPolicy.wordsPerMinute.range,
                step: ReaderViewModel.speechSpeedStep,
                spoken: SpeechExportWording.rateValue(state.wordsPerMinute),
                hint: SpeechExportWording.rateHint
            )
            sliderRow(
                SpeechExportWording.pitchLabel,
                value: $state.pitch,
                in: SettingsPolicy.pitchMultiplier.range,
                step: Self.pitchStep,
                spoken: SpeechExportWording.pitchValue(state.pitch),
                hint: SpeechExportWording.pitchHint
            )
            Text(SpeechExportWording.voiceLine(state.voice))
                .fixedSize(horizontal: false, vertical: true)
            Text(SpeechExportWording.licence)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(idealWidth: Self.idealWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SpeechExportWording.optionsLabel)
    }

    // MARK: Parts

    /// The Format pop-up: each format by its name, at the pop-up's own size,
    /// as the dialog draws its Convert to pop-up.
    private var formatPicker: some View {
        Picker(SpeechExportWording.formatLabel, selection: $state.format) {
            ForEach(state.formats, id: \.self) { format in
                Text(format.title).tag(format)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(SpeechExportWording.formatLabel)
        .accessibilityHint(SpeechExportWording.formatHint)
    }

    /// A slider labelled `label`, setting `value` within `range` by `step`,
    /// with its value in words, `spoken`, shown after it. VoiceOver hears the
    /// label, `spoken` as the slider's value, and `hint`; the words shown
    /// after the slider are hidden from it, as it would otherwise hear the
    /// value twice (TODO A10).
    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        spoken: String,
        hint: String
    ) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range, step: step) {
                Text(label)
            }
            .accessibilityLabel(label)
            .accessibilityValue(spoken)
            .accessibilityHint(hint)
            Text(spoken)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

}

// MARK: - One End of the Range

/// The pop-up choosing one end of the range, From or To: it grows no wider than
/// `SpeechExportOptionsView.rangePickerMaxWidth`, and VoiceOver hears the chosen
/// item whole, as its value, however the pop-up shortens it.
///
/// Equatable on what it shows, never on its action: a book can have thousands
/// of headings, and SwiftUI builds a pop-up's whole menu whenever it draws one,
/// so a step of the Rate or Pitch slider, which draws the options anew, leaves
/// the two pop-ups as they are.
private struct RangePicker: View, Equatable {
    /// The options it sets: another's would need its own pop-up, even over the
    /// same headings.
    let options: SpeechExportOptionsState
    /// What it is called, which VoiceOver speaks and the pop-up shows.
    let label: String
    /// What it chooses, which VoiceOver speaks after its label and value.
    let hint: String
    /// What it offers: the beginning or the end, and every heading.
    let items: [SpeechExportOptionsState.Item]
    /// The tag of the item chosen now. A value, not a binding: comparing two
    /// bindings would read the options as they are now, twice, and find no
    /// change for ever.
    let chosenTag: String
    /// Chooses an item by its tag, as `setFrom(_:)` or `setThrough(_:)`, which
    /// keep the range in reading order.
    let choose: @MainActor (String) -> Void

    /// Whether two pop-ups show the same thing: everything but the action.
    nonisolated static func == (lhs: RangePicker, rhs: RangePicker) -> Bool {
        lhs.options === rhs.options
            && lhs.label == rhs.label
            && lhs.hint == rhs.hint
            && lhs.chosenTag == rhs.chosenTag
            && lhs.items == rhs.items
    }

    var body: some View {
        let _ = ViewBodyCounter.record("SpeechExportRangePicker")
        Picker(label, selection: Binding(get: { chosenTag }, set: { choose($0) })) {
            ForEach(items) { item in
                Text(item.title).tag(item.tag)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: SpeechExportOptionsView.rangePickerMaxWidth, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityValue(items.first { $0.tag == chosenTag }?.title ?? "")
        .accessibilityHint(hint)
    }
}
