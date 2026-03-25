import SwiftUI

struct SleepTimerView: View {
    @ObservedObject var sleepTimerService: SleepTimerService
    var onStartPlayback: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes: Int = 30

    var body: some View {
        VStack(spacing: 16) {
            Text("Sleep Timer")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if sleepTimerService.isActive {
                VStack(spacing: 8) {
                    Text("Timer active")
                        .font(.subheadline)
                        .background(VoiceOverFocus())
                    Text(sleepTimerService.formattedRemaining)
                        .font(.system(.title, design: .monospaced))
                        .accessibilityLabel("\(sleepTimerService.formattedRemaining) remaining")

                    Button("Cancel Timer", role: .destructive) {
                        sleepTimerService.stop()
                    }
                    .accessibilityLabel("Cancel sleep timer")
                }
            } else {
                VStack(spacing: 8) {
                    Text("Pause playback after:")
                        .foregroundColor(.secondary)
                        .background(VoiceOverFocus())

                    // Preset durations
                    ForEach([10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            startTimerAndPlay(duration: .minutes(minutes))
                        }
                        .accessibilityLabel("Set timer for \(minutes) minutes and start playing")
                    }

                    Divider()

                    // Custom duration — editable numeric field with stepper arrows
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

            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Sleep Timer")
    }

    private func startTimerAndPlay(duration: SleepTimerDuration) {
        sleepTimerService.start(duration: duration)
        onStartPlayback?()
        dismiss()
    }
}
