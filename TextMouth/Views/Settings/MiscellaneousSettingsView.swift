import SwiftUI

/// Settings tab for miscellaneous options like Bluetooth monitoring
/// and the experimental restart-sleep-timer media gesture.
struct MiscellaneousSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            // The language of the interface comes first, so someone who switched by mistake finds it at once (FR39).
            InterfaceLanguageSettingsSection()
            bluetoothSection
            restartTimerGestureSection
        }
        .padding()
    }

    // MARK: - Bluetooth

    /// Existing Bluetooth-monitoring controls, unchanged.
    private var bluetoothSection: some View {
        Section {
            Toggle(MiscellaneousSettingsWording.bluetoothTitle, isOn: $settingsViewModel.bluetoothMonitoringEnabled)
                .accessibilityLabel(MiscellaneousSettingsWording.bluetoothTitle)
                .accessibilityHint(MiscellaneousSettingsWording.bluetoothHint)

            Text(MiscellaneousSettingsWording.bluetoothExplanation)
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsViewModel.bluetoothMonitoringEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    // The delay for the eye, in the slider's spoken words,
                    // "1 second"; VoiceOver hears it once, as the slider's
                    // value (TODO A10).
                    Text(MiscellaneousSettingsWording.disconnectDelayText(disconnectDelay))
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.bluetoothDisconnectDelay,
                        in: 1...10,
                        step: 1
                    ) {
                        Text(MiscellaneousSettingsWording.disconnectDelayTitle)
                    }
                    // VoiceOver says the control's kind itself, so the label
                    // names the setting alone (TODO A10).
                    .accessibilityLabel(MiscellaneousSettingsWording.disconnectDelayLabel)
                    .accessibilityValue(disconnectDelay)

                    Text(MiscellaneousSettingsWording.disconnectDelayExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text(MiscellaneousSettingsWording.bluetoothHeader)
        }
    }

    // MARK: - Restart Timer Gesture (Experimental)

    /// Settings for the experimental media-gesture detector that
    /// re-arms the most recently used sleep timer when a configured
    /// sequence of media-key / AirPods events occurs within a time
    /// window. Off by default — the feature monitors every media-key
    /// press, so it's opt-in for users who want it.
    private var restartTimerGestureSection: some View {
        Section {
            Toggle(MiscellaneousSettingsWording.restartGestureTitle,
                   isOn: $settingsViewModel.restartTimerGestureEnabled)
                .accessibilityHint(MiscellaneousSettingsWording.restartGestureHint)

            Text(MiscellaneousSettingsWording.restartGestureExplanation)
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsViewModel.restartTimerGestureEnabled {
                gestureConfiguration
            }

            Text(Self.restartShortcutNote)
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text(MiscellaneousSettingsWording.restartGestureHeader)
        }
    }

    /// Pattern / window controls. Hidden when the gesture is disabled
    /// to keep the settings page tidy and accessibility tree shorter.
    private var gestureConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pattern editor
            Text(MiscellaneousSettingsWording.patternHeading)
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text(MiscellaneousSettingsWording.patternExplanation)
                .font(.caption)
                .foregroundColor(.secondary)

            GesturePatternEditor(patternString: $settingsViewModel.restartTimerGesturePattern)

            Divider()

            // Window slider
            VStack(alignment: .leading, spacing: 6) {
                // The window for the eye; VoiceOver hears it once, as the
                // slider's value (TODO A10).
                Text(MiscellaneousSettingsWording.timeWindowText(formattedWindow))
                    .accessibilityHidden(true)
                Slider(
                    value: $settingsViewModel.restartTimerGestureWindow,
                    in: 0.5...10,
                    step: 0.5
                ) {
                    Text(MiscellaneousSettingsWording.timeWindowTitle)
                }
                .accessibilityLabel(MiscellaneousSettingsWording.timeWindowLabel)
                .accessibilityValue(formattedWindow)
                Text(MiscellaneousSettingsWording.timeWindowExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 4)
    }

    /// The note under the restart gesture: where its keyboard shortcut is
    /// set, by the Shortcuts tab's own name for the action, and its default
    /// key in words, which a braille display shows as words: "The keyboard
    /// shortcut for the same action is Restart Sleep Timer in the Shortcuts
    /// tab; its default is Shift + Command + R." It used to name a
    /// "Keyboard Shortcuts" tab, and the key in symbols (TODO A10).
    nonisolated static var restartShortcutNote: String {
        let action = ShortcutAction.restartSleepTimer
        let defaultKeys = KeyBinding.accessibleDisplayString(for: ShortcutAction.defaultBindings[action] ?? [])
        return MiscellaneousSettingsWording.restartShortcutNote(action: action.title, tab: SettingsTab.shortcuts.title, defaultKeys: defaultKeys)
    }

    /// The Bluetooth disconnect delay as the screen shows it and VoiceOver
    /// speaks it (see `disconnectDelayPhrase(_:)`).
    private var disconnectDelay: String {
        Self.disconnectDelayPhrase(settingsViewModel.bluetoothDisconnectDelay)
    }

    /// A disconnect delay of `seconds`, in the whole seconds the slider
    /// sets: "1 second", "5 seconds". The visible text and the slider's
    /// spoken value both use this phrase; VoiceOver used to hear "1 seconds"
    /// beside a screen that said "1 second".
    nonisolated static func disconnectDelayPhrase(_ seconds: Double) -> String {
        CountWording.seconds(Int(seconds))
    }

    /// The gesture's time window as the screen shows it and the slider's
    /// value speaks it, to the tenth: "0.5 seconds", "5 seconds", worded as
    /// the Shortcuts tab words its double press time
    /// (`CountWording.secondsToTheTenth`).
    private var formattedWindow: String {
        CountWording.secondsToTheTenth(settingsViewModel.restartTimerGestureWindow)
    }
}

// MARK: - Gesture Pattern Editor

/// Lets the user build the event sequence: a list of pickers, one per
/// pattern step, plus + / – buttons to grow or shrink the sequence.
/// Reads/writes the raw comma-separated pattern string the
/// SettingsViewModel persists, decoding it through MediaGestureDetector
/// so a malformed config produces a partial-but-functional editor
/// rather than a crash.
private struct GesturePatternEditor: View {
    @Binding var patternString: String

    /// Current pattern as a typed array. Decoded on read, encoded on
    /// every write so the source of truth remains the persisted string.
    private var pattern: [MediaGestureDetector.EventType] {
        get { MediaGestureDetector.patternFromString(patternString) }
    }

    private func setPattern(_ next: [MediaGestureDetector.EventType]) {
        patternString = MediaGestureDetector.patternToString(next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pattern.enumerated()), id: \.offset) { index, _ in
                HStack {
                    Text(MiscellaneousSettingsWording.stepNumbered(index + 1))
                        .frame(width: 60, alignment: .leading)
                        .accessibilityHidden(true)
                    // The picker's own label is empty: a hidden title would
                    // be spoken before the accessibility label, so VoiceOver
                    // would hear "Event for step 1, Step 1" (board #242).
                    Picker(selection: bindingForStep(index)) {
                        ForEach(MediaGestureDetector.EventType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .accessibilityLabel(MiscellaneousSettingsWording.stepLabel(index + 1))
                    .accessibilityValue(pattern[index].displayName)

                    Button(role: .destructive) {
                        var next = pattern
                        next.remove(at: index)
                        setPattern(next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel(MiscellaneousSettingsWording.removeStepLabel(index + 1))
                    // Don't let the user delete the last step — an
                    // empty pattern is equivalent to "disabled" but
                    // less obvious; keep at least one step so they
                    // see something to work with.
                    .disabled(pattern.count <= 1)
                }
            }

            Button {
                var next = pattern
                // Default new step to previousTrack so a 3-step pattern
                // built by clicking + + + works out of the box without
                // each picker change.
                next.append(.previousTrack)
                setPattern(next)
            } label: {
                Label(MiscellaneousSettingsWording.addStepTitle, systemImage: "plus.circle")
            }
            .accessibilityLabel(MiscellaneousSettingsWording.addStepLabel)
            .accessibilityHint(MiscellaneousSettingsWording.addStepHint)
            // Hard cap matches MediaGestureDetector.maxPatternLength so
            // the UI and the detector agree. Eight steps is comfortably
            // beyond any deliberate gesture; the cap mostly defends
            // against accidental long sequences from a stuck "+" press.
            .disabled(pattern.count >= MediaGestureDetector.maxPatternLength)

            // Plain-text summary so VoiceOver users can confirm the
            // pattern at a glance without tabbing through every picker.
            Text(MiscellaneousSettingsWording.currentPattern(humanReadable))
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel(MiscellaneousSettingsWording.currentPattern(humanReadable))
        }
    }

    /// Build a SwiftUI Binding<EventType> targeting one step of the
    /// pattern. Reads from the decoded array, writes through the
    /// re-encoder so persistence stays consistent.
    private func bindingForStep(_ index: Int) -> Binding<MediaGestureDetector.EventType> {
        Binding(
            get: {
                let p = pattern
                guard index < p.count else { return .previousTrack }
                return p[index]
            },
            set: { newValue in
                var next = pattern
                guard index < next.count else { return }
                next[index] = newValue
                setPattern(next)
            }
        )
    }

    /// Human-readable summary of the current pattern, e.g.
    /// "Previous track, then Previous track, then Play". Empty pattern
    /// returns "(none)" — the editor doesn't normally allow this
    /// state but defensive copy beats showing an empty field.
    private var humanReadable: String {
        MiscellaneousSettingsWording.steps(pattern.map { $0.displayName })
    }
}

// MARK: - The Words

/// The words of the Miscellaneous settings tab, each defined once for the
/// screen, VoiceOver, a braille display, and the tests (FR34).
enum MiscellaneousSettingsWording {
    /// The Bluetooth switch's title and label.
    static var bluetoothTitle: String {
        // Translators: Title and VoiceOver label of the switch in the Miscellaneous settings that turns on Bluetooth monitoring.
        InterfaceText.line("miscellaneousSettings.bluetoothTitle", "Enable Bluetooth monitoring")
    }
    /// The Bluetooth switch's hint.
    static var bluetoothHint: String {
        // Translators: VoiceOver hint of the Enable Bluetooth monitoring switch in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.bluetoothHint", "Stops playback resuming when headphones disconnect")
    }
    /// The text under the Bluetooth switch.
    static var bluetoothExplanation: String {
        // Translators: Explanation under the Enable Bluetooth monitoring switch in the Miscellaneous settings. macOS is the name of the operating system.
        InterfaceText.line("miscellaneousSettings.bluetoothExplanation", "Blocks the spurious play command macOS sends when Bluetooth headphones are removed.")
    }
    /// The delay as the screen shows it, beside its slider.
    static func disconnectDelayText(_ delay: String) -> String {
        // Translators: The Bluetooth disconnect delay shown above its slider in the Miscellaneous settings. %@ is the delay in seconds, such as "3 seconds".
        InterfaceText.line("miscellaneousSettings.disconnectDelayText", "Disconnect delay: \(delay)")
    }
    /// The slider's title.
    static var disconnectDelayTitle: String {
        // Translators: Title of the slider in the Miscellaneous settings that sets how long media commands are suppressed after a Bluetooth device disconnects.
        InterfaceText.line("miscellaneousSettings.disconnectDelayTitle", "Disconnect delay")
    }
    /// The slider's VoiceOver label.
    static var disconnectDelayLabel: String {
        // Translators: VoiceOver label of the Bluetooth disconnect delay slider in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.disconnectDelayLabel", "Bluetooth disconnect delay")
    }
    /// The text under the slider.
    static var disconnectDelayExplanation: String {
        // Translators: Explanation under the Bluetooth disconnect delay slider in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.disconnectDelayExplanation", "How long media commands are blocked after a Bluetooth device disconnects. Raise it if playback resumes after removing headphones.")
    }
    /// The Bluetooth group's heading.
    static var bluetoothHeader: String {
        // Translators: Heading of the Bluetooth group in the Miscellaneous settings. Bluetooth is a trademark and stays as written in most languages.
        InterfaceText.line("miscellaneousSettings.bluetoothHeader", "Bluetooth")
    }

    /// The restart gesture switch's title.
    static var restartGestureTitle: String {
        // Translators: Title of the switch in the Miscellaneous settings that turns on the experimental gesture that restarts the sleep timer.
        InterfaceText.line("miscellaneousSettings.restartGestureTitle", "Enable restart-timer gesture")
    }
    /// The restart gesture switch's hint.
    static var restartGestureHint: String {
        // Translators: VoiceOver hint of the Enable restart-timer gesture switch in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.restartGestureHint", "Restarts the most recent sleep timer with a sequence of media-control presses")
    }
    /// The text under the restart gesture switch.
    static var restartGestureExplanation: String {
        // Translators: Explanation under the Enable restart-timer gesture switch in the Miscellaneous settings. AirPods is a product name and stays as written.
        InterfaceText.line("miscellaneousSettings.restartGestureExplanation", "Experimental. A sequence of media keys or AirPods controls within a short time window re-arms the last sleep timer, handy after one expires.")
    }
    /// The restart gesture group's heading.
    static var restartGestureHeader: String {
        // Translators: Heading of the experimental restart gesture group in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.restartGestureHeader", "Restart Sleep Timer Gesture")
    }
    /// The pattern's heading.
    static var patternHeading: String {
        // Translators: Heading of the list of steps that make up the restart gesture, in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.patternHeading", "Gesture pattern")
    }
    /// The text under the pattern's heading.
    static var patternExplanation: String {
        // Translators: Explanation under the restart gesture's pattern heading in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.patternExplanation", "Media-control events that trigger the restart. The last one is consumed, not passed to playback, so it can't start audio.")
    }
    /// The time window as the screen shows it, above its slider.
    static func timeWindowText(_ window: String) -> String {
        // Translators: The restart gesture's time window shown above its slider in the Miscellaneous settings. %@ is the window in seconds, such as "2 seconds".
        InterfaceText.line("miscellaneousSettings.timeWindowText", "Time window: \(window)")
    }
    /// The time window slider's title.
    static var timeWindowTitle: String {
        // Translators: Title of the slider in the Miscellaneous settings that sets how long the restart gesture's sequence may take.
        InterfaceText.line("miscellaneousSettings.timeWindowTitle", "Time window")
    }
    /// The time window slider's VoiceOver label.
    static var timeWindowLabel: String {
        // Translators: VoiceOver label of the restart gesture's time window slider in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.timeWindowLabel", "Gesture time window")
    }
    /// The text under the time window slider.
    static var timeWindowExplanation: String {
        // Translators: Explanation under the restart gesture's time window slider in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.timeWindowExplanation", "The most time the whole sequence may take. Shorter windows mean fewer accidental matches but quicker presses.")
    }

    /// The note under the restart gesture: where its keyboard shortcut is
    /// set, by the Shortcuts tab's own name for the action, and its default
    /// key in words: "The keyboard shortcut for the same action is Restart
    /// Sleep Timer in the Shortcuts tab; its default is Shift + Command + R."
    nonisolated static func restartShortcutNote(action: String, tab: String, defaultKeys: String) -> String {
        // Translators: Note under the restart gesture in the Miscellaneous settings. %1$@ is the name of the shortcut's action, %2$@ is the name of the Settings tab where shortcuts are set, and %3$@ is the default key in words, such as "Shift + Command + R".
        InterfaceText.line("miscellaneousSettings.restartShortcutNote", "Set its shortcut with \(action) in the \(tab) tab; the default is \(defaultKeys).")
    }

    /// A step's place in the pattern editor, as the screen shows it beside its pop-up.
    static func stepNumbered(_ number: Int) -> String {
        // Translators: The number of a step of the restart gesture in the Miscellaneous settings, shown beside its pop-up, ending with a colon. %@ is the step's number, an identifier written without digit grouping.
        InterfaceText.line("miscellaneousSettings.stepNumbered", "Step \(String(number)):")
    }
    /// A step pop-up's VoiceOver label.
    static func stepLabel(_ number: Int) -> String {
        // Translators: VoiceOver label of one step's pop-up of the restart gesture in the Miscellaneous settings. %@ is the step's number, an identifier written without digit grouping.
        InterfaceText.line("miscellaneousSettings.stepLabel", "Step \(String(number))")
    }
    /// A step's remove button's VoiceOver label.
    static func removeStepLabel(_ number: Int) -> String {
        // Translators: VoiceOver label of the button that removes one step of the restart gesture in the Miscellaneous settings. %@ is the step's number, an identifier written without digit grouping.
        InterfaceText.line("miscellaneousSettings.removeStepLabel", "Remove step \(String(number))")
    }
    /// The button that adds a step.
    static var addStepTitle: String {
        // Translators: Title of the button that adds a step to the restart gesture in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.addStepTitle", "Add step")
    }
    /// The same button's VoiceOver label.
    static var addStepLabel: String {
        // Translators: VoiceOver label of the button that adds a step to the restart gesture in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.addStepLabel", "Add gesture step")
    }
    /// The same button's VoiceOver hint.
    static var addStepHint: String {
        // Translators: VoiceOver hint of the Add gesture step button in the Miscellaneous settings.
        InterfaceText.line("miscellaneousSettings.addStepHint", "Appends a new step to the gesture sequence")
    }
    /// The summary line under the steps, shown and spoken alike.
    static func currentPattern(_ summary: String) -> String {
        // Translators: A summary of the restart gesture's steps under its editor in the Miscellaneous settings, shown and read by VoiceOver. %@ is the steps in order, such as "Previous track, then Play".
        InterfaceText.line("miscellaneousSettings.currentPattern", "Current pattern: \(summary)")
    }
    /// The steps' names in order, as a summary reads them: "Previous
    /// track, then Previous track, then Play"; "(none)" for no step, which
    /// the editor does not normally allow.
    static func steps(_ names: [String]) -> String {
        guard let first = names.first else {
            // Translators: The restart gesture's summary when it has no steps, which the editor does not normally allow.
            return InterfaceText.line("miscellaneousSettings.steps.none", "(none)")
        }
        return names.dropFirst().reduce(first) { summary, next in
            // Translators: Joins two steps of the restart gesture's summary in the Miscellaneous settings. %1$@ is the steps so far and %2$@ is the next step, such as "Previous track, then Play".
            InterfaceText.line("miscellaneousSettings.steps.then", "\(summary), then \(next)")
        }
    }
}
