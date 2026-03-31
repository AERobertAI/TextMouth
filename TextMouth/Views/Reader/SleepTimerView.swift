import SwiftUI

struct SleepTimerView: View {
    @ObservedObject var sleepTimerService: SleepTimerService
    var onStartPlayback: (() -> Void)?
    /// Whether to dismiss the sheet after setting a timer.
    var autoClose: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes: Int = 30
    /// True when the sheet opened with a timer already running.
    /// Used to gate VoiceOverFocus — we only auto-focus when the user
    /// opens the sheet to an existing timer, not when isActive changes
    /// from a button press inside the sheet (which causes a focus race
    /// with dismiss() and corrupts VoiceOver state).
    @State private var openedWithActiveTimer = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Sleep Timer")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if sleepTimerService.isActive {
                activeTimerContent
            } else {
                presetContent
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Sleep Timer")
        .onAppear {
            openedWithActiveTimer = sleepTimerService.isActive
        }
    }

    // MARK: - Active Timer State

    private var activeTimerContent: some View {
        VStack(spacing: 8) {
            Text("Timer active")
                .font(.subheadline)
            Text(sleepTimerService.formattedRemaining)
                .font(.system(.title, design: .monospaced))
                .accessibilityLabel("\(sleepTimerService.formattedRemaining) remaining")

            Button("Cancel Timer", role: .destructive) {
                sleepTimerService.stop()
            }
            .accessibilityLabel("Cancel sleep timer")
            // Only apply VoiceOverFocus if the sheet OPENED with a timer running.
            // When the user just pressed a preset button (startTimerAndPlay),
            // the sheet is either dismissing or the user is already here — don't
            // retrigger focus, which races with dismiss and corrupts VO state.
            .modifier(ConditionalFocusModifier(shouldFocus: openedWithActiveTimer))

            Button("Reset Timer") {
                sleepTimerService.restart()
            }
            .accessibilityLabel("Restart timer with the same duration")
            .accessibilityHint("Resets the countdown to the original time")
        }
    }

    // MARK: - Preset Content (No Active Timer)

    private var presetContent: some View {
        VStack(spacing: 8) {
            Text("Pause playback after:")
                .foregroundColor(.secondary)

            // Preset durations — first button gets VoiceOver focus only
            // when the sheet opens to this state (not on in-sheet transitions)
            ForEach(Array([10, 15, 30, 45, 60].enumerated()), id: \.element) { index, minutes in
                Button("\(minutes) minutes") {
                    startTimerAndPlay(duration: .minutes(minutes))
                }
                .accessibilityLabel("Set timer for \(minutes) minutes and start playing")
                .modifier(ConditionalFocusModifier(shouldFocus: index == 0 && !openedWithActiveTimer))
            }

            Divider()

            // Custom duration
            HStack(spacing: 8) {
                Text("Custom:")
                TextField("Minutes", value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        customMinutes = max(1, min(customMinutes, 480))
                        startTimerAndPlay(duration: .minutes(customMinutes))
                    }
                    .accessibilityLabel("Custom timer minutes")
                    .accessibilityValue("\(customMinutes) minutes")
                    .accessibilityHint("Type a number or use the stepper arrows. Press Return to start the timer.")
                Stepper("", value: $customMinutes, in: 1...480, step: 5)
                    .labelsHidden()
                    .accessibilityLabel("Adjust minutes")
                    .accessibilityValue("\(customMinutes)")
                Text("min")
                    .foregroundColor(.secondary)

                Button("Set") {
                    customMinutes = max(1, min(customMinutes, 480))
                    startTimerAndPlay(duration: .minutes(customMinutes))
                }
                .accessibilityLabel("Set timer for \(customMinutes) minutes and start playing")
            }

            Divider()

            // End of heading / document
            Button("End of current heading") {
                startTimerAndPlay(duration: .endOfHeading)
            }
            .accessibilityLabel("Stop at end of current heading and start playing")

            Button("End of document") {
                startTimerAndPlay(duration: .endOfDocument)
            }
            .accessibilityLabel("Stop at end of document and start playing")
        }
    }

    private func startTimerAndPlay(duration: SleepTimerDuration) {
        sleepTimerService.start(duration: duration)
        onStartPlayback?()
        if autoClose {
            dismiss()
        }
    }
}

/// Applies VoiceOverFocus only when the condition is true.
/// Prevents focus attempts from firing on in-sheet state transitions
/// that race with sheet dismissal.
private struct ConditionalFocusModifier: ViewModifier {
    let shouldFocus: Bool

    func body(content: Content) -> some View {
        if shouldFocus {
            content
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: 1.2))
        } else {
            content
        }
    }
}
