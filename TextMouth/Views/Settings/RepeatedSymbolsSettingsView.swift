import SwiftUI

/// The Repeated Symbols group of the Text settings: how TextMouth's own
/// speech reads a run of one symbol, such as a separator line of asterisks.
///
/// Every control carries its own label, value, and hint, so each one makes
/// sense to VoiceOver and on a braille display without its place on screen:
/// the style picker's options say what each style does at the current
/// threshold, the threshold field and stepper name the number they hold,
/// and the Never collapse checkbox says what checking it does. The group
/// opens with a heading, which VoiceOver's heading navigation finds. The
/// visible captions beside the threshold and symbols fields repeat their
/// controls' labels, so they are hidden from VoiceOver rather than read
/// twice.
///
/// The controls sit in a plain stack rather than a group box: a group box
/// hides the AppKit controls inside it from accessibility until an
/// assistive app connects, so the hosted tests could not read them.
struct RepeatedSymbolsSettingsView: View {
    /// The service keeping the settings, which speech preparation reads.
    @ObservedObject private var service: TextSubstitutionService
    /// The threshold the field and stepper show while Never collapse is
    /// checked, and the one unchecking it restores: the last threshold that
    /// collapsed runs, or the default when there has been none.
    @State private var lastCollapsingThreshold: Int
    /// The symbols as typed. They are saved a moment after the last
    /// keystroke, on Return, when the field loses focus, and when the group
    /// closes, so typing never saves, and re-renders speech, on every key.
    @State private var symbolsDraft: String
    /// Whether the symbols field has keyboard focus. While it does, the
    /// field keeps the user's text exactly as typed.
    @FocusState private var isEditingSymbols: Bool

    /// - Parameter service: The settings to show and change: the app's
    ///   shared service, unless a test supplies its own.
    init(service: TextSubstitutionService = .shared) {
        _service = ObservedObject(wrappedValue: service)
        _lastCollapsingThreshold = State(initialValue: Self.collapsingThreshold(service.repeatedSymbolThreshold))
        _symbolsDraft = State(initialValue: service.repeatedSymbolSet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            stylePicker
            thresholdRow
            symbolsRow
            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A threshold set elsewhere, such as in config.json, becomes the one
        // Never collapse restores.
        .onChange(of: service.repeatedSymbolThreshold) { _, threshold in
            if !Self.neverCollapses(threshold) {
                lastCollapsingThreshold = threshold
            }
        }
    }

    // MARK: - Controls

    /// The style picker. Each option names its style and what it does at
    /// the current threshold, which is also the picker's spoken value.
    private var stylePicker: some View {
        Picker(selection: $service.repeatedSymbolStyle) {
            ForEach(RepeatedSymbolStyle.allCases, id: \.self) { style in
                Text(style.optionTitle(threshold: service.repeatedSymbolThreshold)).tag(style)
            }
        } label: {
            Text(Self.styleCaption)
        }
        .accessibilityLabel(Self.styleLabel)
        .accessibilityHint(Self.styleHint)
    }

    /// The threshold as a number field with a stepper beside it, both dimmed
    /// while Never collapse is checked, and the Never collapse checkbox.
    private var thresholdRow: some View {
        HStack(spacing: 6) {
            Group {
                Text(Self.thresholdLabel)
                    .accessibilityHidden(true)
                TextField(Self.thresholdLabel, value: thresholdBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .accessibilityLabel(Self.thresholdLabel)
                    .accessibilityHint(Self.thresholdFieldHint)
                // The stepper's own label is empty: a hidden label would be
                // spoken before the accessibility label, so VoiceOver would
                // read the label twice.
                Stepper(value: thresholdBinding, in: SettingsPolicy.repeatedSymbolThreshold.range) {
                    EmptyView()
                }
                .accessibilityLabel(Self.thresholdLabel)
                .accessibilityValue(Self.thresholdValue(displayedThreshold))
                .accessibilityHint(Self.thresholdStepperHint)
                Text(Self.thresholdUnit)
                    .accessibilityHidden(true)
            }
            .disabled(Self.neverCollapses(service.repeatedSymbolThreshold))

            Spacer(minLength: 12)

            Toggle(Self.neverCollapseLabel, isOn: neverCollapseBinding)
                .accessibilityHint(Self.neverCollapseHint)
        }
    }

    /// The symbols field, saved as described at `symbolsDraft`, with the
    /// button that restores the default list.
    private var symbolsRow: some View {
        HStack(spacing: 6) {
            Text(Self.symbolsCaption)
                .accessibilityHidden(true)
            TextField(Self.symbolsLabel, text: $symbolsDraft)
                .font(.system(.body, design: .monospaced))
                .focused($isEditingSymbols)
                .onSubmit(saveSymbols)
                .accessibilityLabel(Self.symbolsLabel)
                .accessibilityHint(Self.symbolsHint)
                .help(Self.symbolsHint)
            Button(Self.resetTitle) {
                symbolsDraft = Self.resetSymbols(in: service)
            }
            .accessibilityLabel(Self.resetLabel)
            .accessibilityHint(Self.resetHint)
        }
        // A moment after the last keystroke, save what was typed. A newer
        // keystroke cancels the wait.
        .task(id: symbolsDraft) {
            try? await Task.sleep(for: Self.symbolsSaveDelay)
            guard !Task.isCancelled else { return }
            saveSymbols()
        }
        // Leaving the field saves it at once and shows the saved list, from
        // which spaces, repeats, letters, and digits have gone.
        .onChange(of: isEditingSymbols) { _, isEditing in
            guard !isEditing else { return }
            saveSymbols()
            symbolsDraft = service.repeatedSymbolSet
        }
        // A list changed elsewhere, such as in config.json, shows at once,
        // unless the user is typing in the field.
        .onChange(of: service.repeatedSymbolSet) { _, saved in
            if !isEditingSymbols {
                symbolsDraft = saved
            }
        }
        .onDisappear(perform: saveSymbols)
    }

    // MARK: - Bindings and actions

    /// The threshold the field and stepper show.
    private var displayedThreshold: Int {
        Self.displayedThreshold(service.repeatedSymbolThreshold, remembering: lastCollapsingThreshold)
    }

    /// The field and stepper's threshold. A value typed into the field is
    /// validated as stored ones are, so typing -1 or any negative number
    /// checks Never collapse.
    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { displayedThreshold },
            set: { threshold in
                service.repeatedSymbolThreshold = threshold
                if !Self.neverCollapses(service.repeatedSymbolThreshold) {
                    lastCollapsingThreshold = service.repeatedSymbolThreshold
                }
            }
        )
    }

    /// The Never collapse checkbox: checked while the threshold is -1.
    /// Checking it stores -1; unchecking it restores the last threshold.
    private var neverCollapseBinding: Binding<Bool> {
        Binding(
            get: { Self.neverCollapses(service.repeatedSymbolThreshold) },
            set: { never in
                service.repeatedSymbolThreshold = Self.threshold(neverCollapse: never, remembering: lastCollapsingThreshold)
            }
        )
    }

    /// Saves the symbols as typed, validated; an unchanged list saves and
    /// publishes nothing.
    private func saveSymbols() {
        service.repeatedSymbolSet = symbolsDraft
    }
}

// MARK: - Actions and threshold logic

extension RepeatedSymbolsSettingsView {
    /// Restores the default list in `service` and tells VoiceOver, since the
    /// Reset button keeps focus and the field's change is not spoken.
    ///
    /// - Returns: The list now saved, for the field to show.
    static func resetSymbols(in service: TextSubstitutionService) -> String {
        service.repeatedSymbolSet = SettingsPolicy.repeatedSymbolSet.defaultValue
        VoiceOverAnnouncer.announce(resetAnnouncement)
        return service.repeatedSymbolSet
    }

    /// Whether `threshold` is Never collapse's value, -1.
    nonisolated static func neverCollapses(_ threshold: Int) -> Bool {
        threshold == SettingsPolicy.repeatedSymbolThreshold.offValue
    }

    /// `threshold` when it collapses runs, and otherwise the default: the
    /// threshold to remember when the group opens.
    nonisolated static func collapsingThreshold(_ threshold: Int) -> Int {
        neverCollapses(threshold) ? SettingsPolicy.repeatedSymbolThreshold.defaultValue : threshold
    }

    /// What the field and stepper show for `threshold`: the threshold
    /// itself, or while Never collapse is checked, the `remembered` one that
    /// unchecking it restores, dimmed.
    nonisolated static func displayedThreshold(_ threshold: Int, remembering remembered: Int) -> Int {
        neverCollapses(threshold) ? remembered : threshold
    }

    /// The threshold to store when Never collapse becomes `neverCollapse`.
    nonisolated static func threshold(neverCollapse: Bool, remembering remembered: Int) -> Int {
        neverCollapse ? SettingsPolicy.repeatedSymbolThreshold.offValue : remembered
    }

    /// How long typing in the symbols field must pause before it is saved.
    static let symbolsSaveDelay: Duration = .milliseconds(700)
}

// MARK: - Wording

extension RepeatedSymbolsSettingsView {
    /// The group's heading.
    nonisolated static var title: String {
        // Translators: Heading of the group in Settings, Text that sets how the voice reads one symbol written several times in a row, such as a line of asterisks.
        InterfaceText.line("repeatedSymbolsSettingsView.title", "Repeated Symbols")
    }
    /// The style picker's visible caption.
    nonisolated static var styleCaption: String {
        // Translators: Caption beside the pop-up button that chooses how the voice reads a run of one symbol, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.styleCaption", "Style:")
    }
    /// The style picker's spoken label.
    nonisolated static var styleLabel: String {
        // Translators: VoiceOver label of the pop-up button that chooses how the voice reads a run of one symbol.
        InterfaceText.line("repeatedSymbolsSettingsView.styleLabel", "Repeated symbol style")
    }
    /// The style picker's spoken hint.
    nonisolated static var styleHint: String {
        // Translators: VoiceOver hint of the pop-up button that chooses how the voice reads a run of one symbol.
        InterfaceText.line("repeatedSymbolsSettingsView.styleHint", "How the voice reads a symbol written several times in a row")
    }
    /// The threshold field and stepper's label, shown beside them too.
    nonisolated static var thresholdLabel: String {
        // Translators: Label of the field and stepper that set the length from which a run of one symbol is collapsed, in Settings, Text, Repeated Symbols. The number of symbols and the word symbols follow it.
        InterfaceText.line("repeatedSymbolsSettingsView.thresholdLabel", "Collapse runs of at least")
    }
    /// The unit shown after the stepper.
    nonisolated static var thresholdUnit: String {
        // Translators: The unit shown after the field and stepper that set the length from which a run of one symbol is collapsed, such as "Collapse runs of at least 4 symbols".
        InterfaceText.line("repeatedSymbolsSettingsView.thresholdUnit", "symbols")
    }
    /// The threshold field's spoken hint.
    nonisolated static var thresholdFieldHint: String {
        // Translators: VoiceOver hint of the field that sets the length from which a run of one symbol is collapsed, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.thresholdFieldHint", "A number from 2 to 99")
    }
    /// The threshold stepper's spoken hint.
    nonisolated static var thresholdStepperHint: String {
        // Translators: VoiceOver hint of the stepper that sets the length from which a run of one symbol is collapsed, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.thresholdStepperHint", "Changes the number by one, from 2 to 99")
    }
    /// The Never collapse checkbox's label.
    nonisolated static var neverCollapseLabel: String {
        // Translators: Label of the checkbox in Settings, Text, Repeated Symbols that makes the voice read every symbol of a run, whatever the style.
        InterfaceText.line("repeatedSymbolsSettingsView.neverCollapseLabel", "Never collapse: read every symbol")
    }
    /// The Never collapse checkbox's spoken hint.
    nonisolated static var neverCollapseHint: String {
        // Translators: VoiceOver hint of the Never collapse checkbox in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.neverCollapseHint", "Overrides the style")
    }
    /// The symbols field's visible caption.
    nonisolated static var symbolsCaption: String {
        // Translators: Caption beside the field listing the symbols that can form a run, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.symbolsCaption", "Symbols:")
    }
    /// The symbols field's spoken label.
    nonisolated static var symbolsLabel: String {
        // Translators: VoiceOver label of the field listing the symbols that can form a run, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.symbolsLabel", "Symbols that form runs")
    }
    /// The symbols field's tooltip and spoken hint: what its characters mean.
    nonisolated static var symbolsHint: String {
        // Translators: Tooltip and VoiceOver hint of the field listing the symbols that can form a run, in Settings, Text, Repeated Symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.symbolsHint", "Each character listed can form a run. Spaces are ignored, and letters and digits never form runs.")
    }
    /// The reset button's title.
    nonisolated static var resetTitle: String {
        // Translators: Title of the button in Settings, Text, Repeated Symbols that restores the standard list of symbols.
        InterfaceText.line("common.resetToDefault", "Reset to Default")
    }
    /// The reset button's spoken label.
    nonisolated static var resetLabel: String {
        // Translators: VoiceOver label of the button in Settings, Text, Repeated Symbols that restores the standard list of symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.resetLabel", "Reset symbols to default")
    }
    /// The reset button's spoken hint.
    nonisolated static var resetHint: String {
        // Translators: VoiceOver hint of the button in Settings, Text, Repeated Symbols that restores the standard list of symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.resetHint", "Restores the standard list: the ASCII symbols, bullets, dashes, the ellipsis, and box-drawing lines")
    }
    /// What VoiceOver says once the list is reset.
    nonisolated static var resetAnnouncement: String {
        // Translators: Announcement after the list of symbols that can form a run was restored to the standard one.
        InterfaceText.line("repeatedSymbolsSettingsView.resetAnnouncement", "Symbols reset to the default list")
    }
    /// The caption under the group's controls.
    nonisolated static var explanation: String {
        // Translators: Caption under the controls of Settings, Text, Repeated Symbols that explains what a run is and that only speech changes.
        InterfaceText.line("repeatedSymbolsSettingsView.explanation", "A run is one symbol repeated, alone or with single spaces, such as * * * * or ====. Speech rewrites runs before the rules above; the screen and braille keep every symbol.")
    }

    /// The stepper's spoken value for `threshold`, such as "4 symbols".
    nonisolated static func thresholdValue(_ threshold: Int) -> String {
        // Translators: VoiceOver value of the stepper that sets the length from which a run of one symbol is collapsed. %lld is the number of symbols.
        InterfaceText.line("repeatedSymbolsSettingsView.thresholdValue", "\(number: threshold) symbols")
    }
}

extension RepeatedSymbolStyle {
    /// The style's short name.
    var title: String {
        switch self {
        case .repeatEach:
            // Translators: A style of reading a run of one symbol: the voice says every symbol of it.
            return InterfaceText.line("repeatedSymbolStyle.title.repeatEach", "Repeat each symbol")
        case .sayCount:
            // Translators: A style of reading a run of one symbol: the voice says how many symbols the run holds, such as 7 asterisks.
            return InterfaceText.line("repeatedSymbolStyle.title.sayCount", "Say how many")
        case .leaveOut:
            // Translators: A style of reading a run of one symbol: the voice leaves the run out and pauses in its place.
            return InterfaceText.line("repeatedSymbolStyle.title.leaveOut", "Leave out")
        }
    }

    /// The picker option for this style at `threshold`, naming the style and
    /// what it does, such as "Say how many: runs of 4 or more are read as a
    /// count". While Never collapse is checked (-1), the collapsing styles
    /// say they are off.
    func optionTitle(threshold: Int) -> String {
        let name = title
        switch self {
        case .repeatEach:
            // Translators: A choice of the pop-up button that sets how a run of one symbol is read. %@ is the name of the style, Repeat each symbol.
            return InterfaceText.line("repeatedSymbolStyle.optionTitle.repeatEach", "\(name): every symbol is read as written")
        case .sayCount where RepeatedSymbolsSettingsView.neverCollapses(threshold),
             .leaveOut where RepeatedSymbolsSettingsView.neverCollapses(threshold):
            // Translators: A choice of the pop-up button that sets how a run of one symbol is read, while the Never collapse checkbox is checked. %@ is the name of the style, Say how many or Leave out. Never collapse is the name of the checkbox.
            return InterfaceText.line("repeatedSymbolStyle.sayCount.collapse", "\(name): off while Never collapse is checked")
        case .sayCount:
            // Translators: A choice of the pop-up button that sets how a run of one symbol is read. %1$@ is the name of the style, Say how many; %2$lld is the length from which a run is collapsed.
            return InterfaceText.line("repeatedSymbolStyle.optionTitle.sayCount.runs", "\(name): runs of \(number: threshold) or more are read as a count")
        case .leaveOut:
            // Translators: A choice of the pop-up button that sets how a run of one symbol is read. %1$@ is the name of the style, Leave out; %2$lld is the length from which a run is collapsed.
            return InterfaceText.line("repeatedSymbolStyle.optionTitle.leaveOut", "\(name): runs of \(number: threshold) or more are skipped, with a pause")
        }
    }
}
