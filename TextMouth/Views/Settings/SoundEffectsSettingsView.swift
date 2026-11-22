import SwiftUI

struct SoundEffectsSettingsView: View {
    @EnvironmentObject var soundEffectService: SoundEffectService

    /// The volume as a whole percentage, 0 to 100.
    private var volumePercent: Int { Int(soundEffectService.volume * 100) }

    var body: some View {
        Form {
            Section {
                Toggle(SoundEffectsSettingsWording.enableTitle, isOn: $soundEffectService.soundsEnabled)
                    .accessibilityHint(SoundEffectsSettingsWording.enableHint)

                VStack(alignment: .leading, spacing: 4) {
                    // The volume for the eye; VoiceOver hears it once, as
                    // the slider's value (TODO A10).
                    Text(SoundEffectsSettingsWording.volumeCaption(percent: volumePercent))
                        .accessibilityHidden(true)

                    Slider(value: $soundEffectService.volume, in: 0...1, step: 0.05) {
                        Text(SoundEffectsSettingsWording.volumeTitle)
                    }
                    .accessibilityLabel(SoundEffectsSettingsWording.volumeLabel)
                    .accessibilityValue(SoundEffectsSettingsWording.volumeValue(percent: volumePercent))
                    .disabled(!soundEffectService.soundsEnabled)
                }
            } header: {
                Text(SoundEffectsSettingsWording.generalHeader)
            }

            Section {
                ForEach(SoundEvent.allCases) { event in
                    SoundEventRow(event: event)
                }
            } header: {
                Text(SoundEffectsSettingsWording.assignmentsHeader)
            }

            Section {
                Button(SoundEffectsSettingsWording.resetTitle) {
                    Self.resetEverySound(soundEffectService)
                }
                .accessibilityLabel(SoundEffectsSettingsWording.resetLabel)
            }
        }
        .padding()
    }
}

extension SoundEffectsSettingsView {
    /// Gives the sound assignments, the volume, and "sounds on" their
    /// defaults again, then says so: the button said nothing otherwise, and a
    /// VoiceOver user could not tell the reset had worked. No alert closes
    /// here, so VoiceOver hears `SoundEffectsSettingsWording.resetDone` at
    /// once. `announce` lets a test capture the words.
    static func resetEverySound(
        _ service: SoundEffectService,
        announce: (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        service.resetToDefaults()
        announce(SoundEffectsSettingsWording.resetDone)
    }
}

/// The words of the Sound Effects tab, pinned by tests.
enum SoundEffectsSettingsWording {
    /// The title of the switch that turns every sound effect on or off.
    static var enableTitle: String {
        // Translators: Title of the switch in Settings, Sound Effects that turns the short sounds for playback actions on or off.
        InterfaceText.line("soundEffectsSettings.enableTitle", "Enable Sound Effects")
    }
    /// The switch's hint. The switch speaks its title as its label.
    static var enableHint: String {
        // Translators: VoiceOver hint of the Enable Sound Effects switch.
        InterfaceText.line("soundEffectsSettings.enableHint", "Plays short sounds for playback actions")
    }

    /// The volume as the eye reads it, above the slider: "Volume: 50%".
    static func volumeCaption(percent: Int) -> String {
        // Translators: Caption above the sound effects volume slider in Settings. %lld is the volume as a percentage from 0 to 100; the percent sign after it is written as %%.
        InterfaceText.line("soundEffectsSettings.volumeCaption", "Volume: \(number: percent)%")
    }
    /// The slider's own title.
    static var volumeTitle: String {
        // Translators: Title of the sound effects volume slider in Settings, Sound Effects.
        InterfaceText.line("soundEffectsSettings.volumeTitle", "Volume")
    }
    /// What VoiceOver reads for the slider.
    static var volumeLabel: String {
        // Translators: VoiceOver label of the sound effects volume slider in Settings.
        InterfaceText.line("soundEffectsSettings.volumeLabel", "Sound effect volume")
    }
    /// What VoiceOver reads as the slider's value: "50 percent".
    static func volumeValue(percent: Int) -> String {
        // Translators: VoiceOver value of the sound effects volume slider. %lld is the volume as a percentage from 0 to 100.
        InterfaceText.line("common.countPercent", "\(number: percent) percent")
    }

    /// The heading of the section holding the switch and the volume.
    static var generalHeader: String {
        // Translators: Heading of the section of Settings, Sound Effects that holds the switch and the volume.
        InterfaceText.line("soundEffectsSettings.generalHeader", "General")
    }
    /// The heading of the section choosing each event's sound.
    static var assignmentsHeader: String {
        // Translators: Heading of the section of Settings, Sound Effects that chooses the sound for each event.
        InterfaceText.line("soundEffectsSettings.assignmentsHeader", "Sound Assignments")
    }

    /// What VoiceOver reads for an event's pop-up button: "Play sound".
    static func soundLabel(_ event: SoundEvent) -> String {
        // Translators: VoiceOver label of the pop-up button that chooses the sound for one event, in Settings, Sound Effects. %@ is the name of the event, such as Play or Pause.
        InterfaceText.line("soundEffectsSettings.soundLabel", "\(event.title) sound")
    }
    /// What VoiceOver reads for an event's preview button: "Preview Play sound".
    static func previewLabel(_ event: SoundEvent) -> String {
        // Translators: VoiceOver label of the button that plays the sound chosen for one event, in Settings, Sound Effects. %@ is the name of the event, such as Play or Pause.
        InterfaceText.line("soundEffectsSettings.previewLabel", "Preview \(event.title) sound")
    }
    /// The hint of an event's pop-up button: when its sound plays.
    static func eventHint(_ event: SoundEvent) -> String {
        switch event {
        case .play:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the Play event: when the sound plays.
            return InterfaceText.line("soundEffectsSettings.eventHint.play", "Plays when you start reading")
        case .pause:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the Pause event: when the sound plays.
            return InterfaceText.line("soundEffectsSettings.eventHint.pause", "Plays when you pause reading")
        case .skipForward:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the Skip Forward event: when the sound plays.
            return InterfaceText.line("soundEffectsSettings.eventHint.skipForward", "Plays when you skip forward")
        case .skipBackward:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the Skip Backward event: when the sound plays.
            return InterfaceText.line("soundEffectsSettings.eventHint.skipBackward", "Plays when you skip backward")
        case .whereAmIStart:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the start of the Where Am I announcement. Where Am I is the name of a command.
            return InterfaceText.line("soundEffectsSettings.eventHint.whereAmIStart", "Plays when Where Am I starts speaking")
        case .whereAmIEnd:
            // Translators: VoiceOver hint of the pop-up button that chooses the sound for the end of the Where Am I announcement. Where Am I is the name of a command.
            return InterfaceText.line("soundEffectsSettings.eventHint.whereAmIEnd", "Plays when Where Am I finishes speaking")
        }
    }

    /// The button's title, on screen and to VoiceOver as its name.
    static var resetTitle: String {
        // Translators: Title of the button in Settings, Sound Effects that restores every sound effect setting.
        InterfaceText.line("common.resetToDefaults", "Reset to Defaults")
    }
    /// The button's VoiceOver label: which settings it resets.
    static var resetLabel: String {
        // Translators: VoiceOver label of the Reset to Defaults button in Settings, Sound Effects.
        InterfaceText.line("soundEffectsSettings.resetLabel", "Reset all sound effects to defaults")
    }
    /// What VoiceOver hears after the reset. It follows the audio filter
    /// presets' reset wording.
    static var resetDone: String {
        // Translators: Announcement after Reset to Defaults restored every sound effect setting.
        InterfaceText.line("soundEffectsSettings.resetDone", "Sound effects reset to defaults")
    }
}

struct SoundEventRow: View {
    let event: SoundEvent
    @EnvironmentObject var soundEffectService: SoundEffectService

    /// The sound now chosen for the event: a system sound's name, or the
    /// stored name of no sound.
    private var chosenSound: String {
        soundEffectService.assignments[event] ?? SoundEffectService.noSound
    }

    private var currentSound: Binding<String> {
        Binding(
            get: { chosenSound },
            set: { soundEffectService.assignments[event] = $0 }
        )
    }

    var body: some View {
        HStack {
            Picker(event.title, selection: currentSound) {
                ForEach(SoundEffectService.availableSounds(), id: \.self) { name in
                    Text(SoundEffectService.title(ofSound: name)).tag(name)
                }
            }
            .accessibilityLabel(SoundEffectsSettingsWording.soundLabel(event))
            .accessibilityHint(SoundEffectsSettingsWording.eventHint(event))
            .disabled(!soundEffectService.soundsEnabled)

            Button {
                let name = chosenSound
                if name != SoundEffectService.noSound {
                    soundEffectService.previewSound(name)
                }
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(!soundEffectService.soundsEnabled || chosenSound == SoundEffectService.noSound)
            .accessibilityLabel(SoundEffectsSettingsWording.previewLabel(event))
        }
    }
}
