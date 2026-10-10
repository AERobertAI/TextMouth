import SwiftUI

struct SoundEffectsSettingsView: View {
    @EnvironmentObject var soundEffectService: SoundEffectService

    var body: some View {
        Form {
            Section {
                Toggle("Enable Sound Effects", isOn: $soundEffectService.soundsEnabled)
                    .accessibilityLabel("Enable sound effects")
                    .accessibilityHint("When enabled, short sounds play for playback actions")

                VStack(alignment: .leading, spacing: 4) {
                    // The volume for the eye; VoiceOver hears it once, as
                    // the slider's value (TODO A10).
                    Text("Volume: \(Int(soundEffectService.volume * 100))%")
                        .accessibilityHidden(true)

                    Slider(value: $soundEffectService.volume, in: 0...1, step: 0.05) {
                        Text("Volume")
                    }
                    .accessibilityLabel("Sound effect volume")
                    .accessibilityValue("\(Int(soundEffectService.volume * 100)) percent")
                    .disabled(!soundEffectService.soundsEnabled)
                }
            } header: {
                Text("General")
            }

            Section {
                ForEach(SoundEvent.allCases) { event in
                    SoundEventRow(event: event)
                }
            } header: {
                Text("Sound Assignments")
            }

            Section {
                Button("Reset to Defaults") {
                    soundEffectService.resetToDefaults()
                }
                .accessibilityLabel("Reset all sound effects to defaults")
            }
        }
        .padding()
    }
}

struct SoundEventRow: View {
    let event: SoundEvent
    @EnvironmentObject var soundEffectService: SoundEffectService

    private var currentSound: Binding<String> {
        Binding(
            get: { soundEffectService.assignments[event] ?? "None" },
            set: { soundEffectService.assignments[event] = $0 }
        )
    }

    var body: some View {
        HStack {
            Picker(event.rawValue, selection: currentSound) {
                ForEach(SoundEffectService.availableSounds(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .accessibilityLabel("\(event.rawValue) sound")
            .accessibilityHint(eventDescription)
            .disabled(!soundEffectService.soundsEnabled)

            Button {
                let name = soundEffectService.assignments[event] ?? "None"
                if name != "None" {
                    soundEffectService.previewSound(name)
                }
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(!soundEffectService.soundsEnabled || (soundEffectService.assignments[event] ?? "None") == "None")
            .accessibilityLabel("Preview \(event.rawValue) sound")
        }
    }

    private var eventDescription: String {
        switch event {
        case .play: return "Plays when you start reading"
        case .pause: return "Plays when you pause reading"
        case .skipForward: return "Plays when you skip forward"
        case .skipBackward: return "Plays when you skip backward"
        case .whereAmIStart: return "Plays when Where Am I starts speaking"
        case .whereAmIEnd: return "Plays when Where Am I finishes speaking"
        }
    }
}
