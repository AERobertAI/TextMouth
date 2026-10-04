import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        TabView {
            VoiceSettingsView()
                .tabItem {
                    Label("Voice", systemImage: "speaker.wave.2")
                }

            PlaybackSettingsView()
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }

            KeyboardShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            SubstitutionsSettingsView()
                .tabItem {
                    Label("Text", systemImage: "textformat.abc")
                }

            SoundEffectsSettingsView()
                .tabItem {
                    Label("Sounds", systemImage: "speaker.badge.exclamationmark")
                }

            ReadingStatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }

            StorageSettingsView()
                .tabItem {
                    Label("Storage", systemImage: "folder.badge.gearshape")
                }

            MiscellaneousSettingsView()
                .tabItem {
                    Label("Miscellaneous", systemImage: "gearshape.2")
                }
        }
        .frame(width: 600, height: 540)
    }
}

struct VoiceSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Retained so it doesn't get deallocated while speaking
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Picker("Language", selection: $settingsViewModel.selectedLanguage) {
                Text("All").tag("")
                ForEach(settingsViewModel.availableLanguages, id: \.self) { lang in
                    Text(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                        .tag(lang)
                }
            }
            .onChange(of: settingsViewModel.selectedLanguage) { _, _ in
                settingsViewModel.refreshVoices()
            }
            .accessibilityLabel("Voice language")

            Picker("Voice", selection: $settingsViewModel.selectedVoiceID) {
                ForEach(settingsViewModel.availableVoices, id: \.identifier) { voice in
                    HStack {
                        Text(voice.name)
                        Text("(\(settingsViewModel.voiceQualityLabel(voice)))")
                            .foregroundColor(.secondary)
                    }
                    .tag(voice.identifier)
                    .accessibilityLabel("\(voice.name), \(settingsViewModel.voiceQualityLabel(voice)) quality")
                }
            }
            .accessibilityLabel("Select voice")
            .accessibilityHint("Choose a voice for reading. Change takes effect immediately.")

            if let voice = settingsViewModel.selectedVoice {
                LabeledContent("Quality") {
                    Text(settingsViewModel.voiceQualityLabel(voice))
                }
                LabeledContent("Language") {
                    Text(voice.language)
                }
            }

            Button("Preview Voice") {
                previewVoice()
            }
            .accessibilityLabel("Preview selected voice")

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Speed: \(Int(settingsViewModel.wordsPerMinute)) WPM")
                        .accessibilityLabel("Default speed: \(Int(settingsViewModel.wordsPerMinute)) words per minute")

                    Slider(
                        value: $settingsViewModel.wordsPerMinute,
                        in: 50...650,
                        step: 25
                    ) {
                        Text("Words per minute")
                    }
                    .accessibilityLabel("Speed slider")
                    .accessibilityValue("\(Int(settingsViewModel.wordsPerMinute)) words per minute")

                    Text("Default speed for new books. Each book can override this with its own speed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Default Speed")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Pitch: \(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier))")
                        .accessibilityLabel("Default pitch: \(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier))")

                    Slider(
                        value: $settingsViewModel.pitchMultiplier,
                        in: 0.5...2.0,
                        step: 0.1
                    ) {
                        Text("Pitch")
                    }
                    .accessibilityLabel("Pitch slider")
                    .accessibilityValue(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier))

                    Text("Default pitch for new books. 1.0 is normal. Each book can override this.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Default Pitch")
            }
        }
        .padding()
        // The pickers offer the shared voice list (TODO PERF07), which the
        // first Library window has asked for; ask too, should this come first.
        .onAppear { settingsViewModel.voiceCatalog.loadIfNeeded() }
    }

    private func previewVoice() {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hello! This is TextMouth, ready to read for you.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: settingsViewModel.selectedVoiceID)
        utterance.rate = SpeechService.rateForWPM(settingsViewModel.wordsPerMinute)
        utterance.pitchMultiplier = Float(SpeechService.clampedPitch(settingsViewModel.pitchMultiplier))
        previewSynthesizer.speak(utterance)
    }
}

struct PlaybackSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Skip Forward", selection: Binding(
                    get: { settingsViewModel.skipForwardUnit },
                    set: { settingsViewModel.skipForwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .accessibilityLabel("Skip forward unit")
                .accessibilityHint("What happens when you skip forward")

                Picker("Skip Backward", selection: Binding(
                    get: { settingsViewModel.skipBackwardUnit },
                    set: { settingsViewModel.skipBackwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .accessibilityLabel("Skip backward unit")
                .accessibilityHint("What happens when you skip backward")
            } header: {
                Text("Skip Controls")
            }

            Section {
                Picker("Shift+Skip Forward", selection: Binding(
                    get: { settingsViewModel.shiftSkipForwardUnit },
                    set: { settingsViewModel.shiftSkipForwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .accessibilityLabel("Shift skip forward unit")
                .accessibilityHint("What happens when you hold Shift and skip forward")

                Picker("Shift+Skip Backward", selection: Binding(
                    get: { settingsViewModel.shiftSkipBackwardUnit },
                    set: { settingsViewModel.shiftSkipBackwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .accessibilityLabel("Shift skip backward unit")
                .accessibilityHint("What happens when you hold Shift and skip backward")

                Text("Hold Shift while skipping to use a secondary skip amount.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Shift+Skip (Secondary)")
            }

            Section {
                Picker("Rewind to", selection: Binding(
                    get: { settingsViewModel.rewindOnResumeUnit },
                    set: { settingsViewModel.rewindOnResumeUnit = $0 }
                )) {
                    ForEach(RewindUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .accessibilityLabel("Rewind on resume unit")
                .accessibilityHint("When resuming playback, rewind to the start of this unit")

                if settingsViewModel.rewindOnResumeUnit != .none {
                    Toggle("Smart mode", isOn: $settingsViewModel.rewindSmartMode)
                        .accessibilityLabel("Smart rewind mode")
                        .accessibilityHint("Only rewind if the pause was longer than the threshold")

                    if settingsViewModel.rewindSmartMode {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Minimum pause: \(Int(settingsViewModel.rewindSmartThreshold)) seconds")
                                .accessibilityLabel("Minimum pause before rewinding: \(Int(settingsViewModel.rewindSmartThreshold)) seconds")
                            // The stepper's own label is empty: a hidden
                            // title would be spoken before the accessibility
                            // label ("Seconds, Minimum pause threshold").
                            Stepper(
                                value: $settingsViewModel.rewindSmartThreshold,
                                in: 5...600,
                                step: 5
                            ) {
                                EmptyView()
                            }
                            .accessibilityLabel("Minimum pause threshold")
                            .accessibilityValue("\(Int(settingsViewModel.rewindSmartThreshold)) seconds")

                            Text("Don't rewind if paused for less than this.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Rewind on Resume")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    let level = Int(settingsViewModel.punctuationPauseLevel)
                    let levelName = ["Off", "Subtle", "Moderate", "Heavy"][min(level, 3)]
                    Text("Punctuation pauses: \(levelName)")
                        .accessibilityLabel("Punctuation pause level: \(levelName)")

                    Slider(
                        value: $settingsViewModel.punctuationPauseLevel,
                        in: 0...3,
                        step: 1
                    ) {
                        Text("Pause level")
                    }
                    .accessibilityLabel("Punctuation pause level")
                    .accessibilityValue(levelName)

                    Text("0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Punctuation Pauses")
            }

            Section {
                Toggle("Auto-play after navigation", isOn: $settingsViewModel.autoPlayOnNavigate)
                    .accessibilityLabel("Auto-play after navigation")
                    .accessibilityHint("When enabled, playback starts automatically after jumping to a heading, bookmark, or search result")

                Text("Automatically start playing when you navigate to a heading, bookmark, or search result.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Navigation")
            }

            Section {
                Picker("When book ends", selection: Binding(
                    get: { settingsViewModel.endOfBookBehavior },
                    set: { settingsViewModel.endOfBookBehavior = $0 }
                )) {
                    ForEach(EndOfBookBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.rawValue).tag(behavior)
                    }
                }
                .accessibilityLabel("End of book behavior")
                .accessibilityHint("What happens when a book finishes playing")

                Text("\"Continue to Next Book\" plays the next book in the same folder by sort order.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("End of Book")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if settingsViewModel.sleepFadeOutDuration > 0 {
                        Text("Fade out: \(Int(settingsViewModel.sleepFadeOutDuration)) seconds")
                            .accessibilityLabel("Sleep timer fade out: \(Int(settingsViewModel.sleepFadeOutDuration)) seconds")
                    } else {
                        Text("Fade out: Off")
                            .accessibilityLabel("Sleep timer fade out: off, playback stops instantly")
                    }
                    // The stepper's own label is empty: a hidden title
                    // would be spoken before the accessibility label
                    // ("Seconds, Fade out duration").
                    Stepper(
                        value: $settingsViewModel.sleepFadeOutDuration,
                        in: 0...10,
                        step: 1
                    ) {
                        EmptyView()
                    }
                    .accessibilityLabel("Fade out duration")
                    .accessibilityValue(settingsViewModel.sleepFadeOutDuration > 0 ? "\(Int(settingsViewModel.sleepFadeOutDuration)) seconds" : "Off")

                    Text("Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Close sheet after setting timer", isOn: $settingsViewModel.sleepTimerAutoClose)
                    .accessibilityLabel("Close sleep timer sheet after setting a timer")
                    .accessibilityHint("When off, the sheet stays open showing the remaining time and a reset button")
            } header: {
                Text("Sleep Timer")
            }

            Section {
                Picker("Navigation unit controls", selection: Binding(
                    get: { settingsViewModel.playbackNavigationUnitControlMode },
                    set: { settingsViewModel.playbackNavigationUnitControlMode = $0 }
                )) {
                    ForEach(PlaybackNavigationUnitControlMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityLabel("Navigation unit controls in playback bar")
                .accessibilityHint(
                    "Choose no per-book control, one picker for both directions, or one menu with separate forward and backward pickers"
                )

                // Use an explicit binding so the SettingsViewModel setter
                // publishes a playback-bar refresh. AppStorage's projected
                // binding writes its storage directly and can bypass didSet.
                Toggle("Show bookmark button", isOn: Binding(
                    get: { settingsViewModel.showBookmarkInPlaybackControls },
                    set: { settingsViewModel.showBookmarkInPlaybackControls = $0 }
                ))
                    .accessibilityLabel("Show bookmark button in playback controls")
                    .accessibilityHint("Adds a button to add or remove a bookmark at the current position")

                Toggle("Show speed controls", isOn: Binding(
                    get: { settingsViewModel.showSpeedInPlaybackControls },
                    set: { settingsViewModel.showSpeedInPlaybackControls = $0 }
                ))
                    .accessibilityLabel("Show speed controls in playback controls")
                    .accessibilityHint("Shows the speed adjustment buttons and current speed display")

                Text("Navigation menu changes are saved as defaults for the current book. Hiding the menus always uses the global skip choices while retaining book defaults for later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Playback Controls")
            }

            // The reader's toolbar (FR05): File > Export… is always there;
            // this adds a button for it beside the reader's other tools.
            Section {
                Toggle(BookExportWording.settingTitle, isOn: Binding(
                    get: { settingsViewModel.showExportInReaderToolbar },
                    set: { settingsViewModel.showExportInReaderToolbar = $0 }
                ))
                    .accessibilityLabel(BookExportWording.settingLabel)
                    .accessibilityHint(BookExportWording.settingHint)
            } header: {
                Text(BookExportWording.settingSection)
            }

            // Transcribing audiobooks (FR05): the language and the offer
            // after an import.
            TranscriptionSettingsSection()
        }
        .padding()
    }
}

struct ShortcutRow: View {
    let key: String
    let action: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action): \(key)")
    }
}
