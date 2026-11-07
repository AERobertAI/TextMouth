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
                rangePicker(
                    SpeechExportWording.fromLabel,
                    hint: SpeechExportWording.fromHint,
                    items: state.fromItems,
                    selection: fromSelection
                )
                rangePicker(
                    SpeechExportWording.throughLabel,
                    hint: SpeechExportWording.throughHint,
                    items: state.throughItems,
                    selection: throughSelection
                )
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

    /// The pop-up choosing one end of the range, From or To: labelled
    /// `label`, offering `items`, with `selection` holding the chosen item's
    /// tag. It grows no wider than `rangePickerMaxWidth`; VoiceOver hears
    /// the chosen item whole, as its value, however the pop-up shortens it.
    private func rangePicker(
        _ label: String,
        hint: String,
        items: [SpeechExportOptionsState.Item],
        selection: Binding<String>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(items) { item in
                Text(item.title).tag(item.tag)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: Self.rangePickerMaxWidth, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityValue(items.first { $0.tag == selection.wrappedValue }?.title ?? "")
        .accessibilityHint(hint)
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

    // MARK: Selections

    /// The From pop-up's selection: read from the options, and set through
    /// `setFrom(_:)`, which keeps the range in reading order.
    private var fromSelection: Binding<String> {
        Binding(
            get: { state.fromTag },
            set: { state.setFrom($0) }
        )
    }

    /// The To pop-up's selection: read from the options, and set through
    /// `setThrough(_:)`, which keeps the range in reading order.
    private var throughSelection: Binding<String> {
        Binding(
            get: { state.throughTag },
            set: { state.setThrough($0) }
        )
    }
}
