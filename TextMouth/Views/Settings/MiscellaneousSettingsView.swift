import SwiftUI

/// Settings tab for miscellaneous options like Bluetooth monitoring
/// and the experimental restart-sleep-timer media gesture.
struct MiscellaneousSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            bluetoothSection
            restartTimerGestureSection
        }
        .padding()
    }

    // MARK: - Bluetooth

    /// Existing Bluetooth-monitoring controls, unchanged.
    private var bluetoothSection: some View {
        Section {
            Toggle("Enable Bluetooth monitoring", isOn: $settingsViewModel.bluetoothMonitoringEnabled)
                .accessibilityLabel("Enable Bluetooth monitoring")
                .accessibilityHint("When enabled, prevents spurious auto-resume when Bluetooth audio devices disconnect")

            Text("Monitors Bluetooth audio disconnections and blocks the spurious play command macOS sends when headphones are removed.")
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsViewModel.bluetoothMonitoringEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Disconnect delay: \(Int(settingsViewModel.bluetoothDisconnectDelay)) \(Int(settingsViewModel.bluetoothDisconnectDelay) == 1 ? "second" : "seconds")")
                        .accessibilityLabel("Disconnect delay: \(Int(settingsViewModel.bluetoothDisconnectDelay)) seconds")

                    Slider(
                        value: $settingsViewModel.bluetoothDisconnectDelay,
                        in: 1...10,
                        step: 1
                    ) {
                        Text("Disconnect delay")
                    }
                    .accessibilityLabel("Bluetooth disconnect delay slider")
                    .accessibilityValue("\(Int(settingsViewModel.bluetoothDisconnectDelay)) seconds")

                    Text("How long to suppress spurious media commands after a Bluetooth device disconnects. Increase if playback sometimes auto-resumes after removing headphones.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Bluetooth")
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
            Toggle("Enable restart-timer gesture",
                   isOn: $settingsViewModel.restartTimerGestureEnabled)
                .accessibilityHint("Lets you restart the most recent sleep timer with a sequence of media-control button presses")

            Text("Experimental. Press a configurable sequence of media keys or AirPods controls within a short time window to re-arm the most recently used sleep timer — handy for restarting a timer that just expired without going back to the keyboard.")
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsViewModel.restartTimerGestureEnabled {
                gestureConfiguration
            }

            Text("The keyboard shortcut for the same action is configurable under Keyboard Shortcuts (default ⌘⇧R).")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Restart Sleep Timer Gesture")
        }
    }

    /// Pattern / window controls. Hidden when the gesture is disabled
    /// to keep the settings page tidy and accessibility tree shorter.
    private var gestureConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pattern editor
            Text("Gesture pattern")
                .font(.subheadline)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text("Sequence of media-control events that trigger the restart. The final event in the sequence is consumed (not passed to playback) so it can't accidentally start audio.")
                .font(.caption)
                .foregroundColor(.secondary)

            GesturePatternEditor(patternString: $settingsViewModel.restartTimerGesturePattern)

            Divider()

            // Window slider
            VStack(alignment: .leading, spacing: 6) {
                Text("Time window: \(formattedWindow)")
                    .accessibilityLabel("Time window: \(formattedWindow)")
                Slider(
                    value: $settingsViewModel.restartTimerGestureWindow,
                    in: 0.5...10,
                    step: 0.5
                ) {
                    Text("Time window")
                }
                .accessibilityLabel("Gesture time window slider")
                .accessibilityValue(formattedWindow)
                Text("Maximum total elapsed time for the sequence to count as a match. Shorter windows reduce accidental matches but require quicker presses.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 4)
    }

    /// Display string for the time window slider that handles both
    /// "0.5 seconds" and "5 seconds" cleanly.
    private var formattedWindow: String {
        let value = settingsViewModel.restartTimerGestureWindow
        if value == floor(value) {
            return CountWording.phrase(Int(value), singular: "second", plural: "seconds")
        }
        return String(format: "%.1f seconds", value)
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
                    Text("Step \(index + 1):")
                        .frame(width: 60, alignment: .leading)
                        .accessibilityHidden(true)
                    Picker("Event for step \(index + 1)",
                           selection: bindingForStep(index)) {
                        ForEach(MediaGestureDetector.EventType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Step \(index + 1)")
                    .accessibilityValue(pattern[index].displayName)

                    Button(role: .destructive) {
                        var next = pattern
                        next.remove(at: index)
                        setPattern(next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove step \(index + 1)")
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
                Label("Add step", systemImage: "plus.circle")
            }
            .accessibilityLabel("Add gesture step")
            .accessibilityHint("Appends a new step to the gesture sequence")
            // Hard cap matches MediaGestureDetector.maxPatternLength so
            // the UI and the detector agree. Eight steps is comfortably
            // beyond any deliberate gesture; the cap mostly defends
            // against accidental long sequences from a stuck "+" press.
            .disabled(pattern.count >= MediaGestureDetector.maxPatternLength)

            // Plain-text summary so VoiceOver users can confirm the
            // pattern at a glance without tabbing through every picker.
            Text("Current pattern: \(humanReadable)")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel("Current pattern: \(humanReadable)")
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
        let names = pattern.map { $0.displayName }
        if names.isEmpty { return "(none)" }
        return names.joined(separator: ", then ")
    }
}
