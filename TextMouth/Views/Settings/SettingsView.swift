import SwiftUI
import AVFoundation

/// The Settings window: one tab for each of `SettingsTab`'s cases, in their
/// order, each shown as `SettingsTabPage` shows it.
struct SettingsView: View {
    /// The window's size, which every tab shares and none can change. Wide
    /// enough for the nine tabs' toolbar to show every one, so none hides in
    /// the toolbar's overflow menu. A tab taller than this scrolls
    /// (`SettingsTab.scrollsAsAWhole`, TODO A10).
    nonisolated static let windowSize = CGSize(width: 700, height: 540)

    var body: some View {
        TabView {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabPage(tab: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }
}

/// The tabs of the Settings window, in the order its toolbar shows them.
///
/// The window is a fixed size (`SettingsView.windowSize`), and a macOS form
/// in its default, columns style does not scroll, so until TODO A10 a tab
/// taller than the window clipped the controls below its bottom edge, where
/// neither the keyboard nor VoiceOver could reach them: the Shortcuts tab
/// was nearly eight times the window's height, and Playback, Storage, and
/// Miscellaneous (with its gesture on) were taller than it too. Every tab
/// drawn as a form now scrolls as a whole (`SettingsTabPage`);
/// `SettingsTabFitTests` measures each tab against the window, so a tab
/// that outgrows it unseen fails a test.
enum SettingsTab: CaseIterable, Identifiable {
    case voice
    case playback
    case shortcuts
    case text
    case sounds
    case stats
    /// The podcast and article feeds' settings (FR03).
    case feeds
    case storage
    case miscellaneous

    var id: Self { self }

    /// The tab's name in the window's toolbar, which VoiceOver reads.
    var title: String {
        switch self {
        case .voice: return "Voice"
        case .playback: return "Playback"
        case .shortcuts: return "Shortcuts"
        case .text: return "Text"
        case .sounds: return "Sounds"
        case .stats: return "Stats"
        case .feeds: return FeedSettingsWording.tabTitle
        case .storage: return "Storage"
        case .miscellaneous: return "Miscellaneous"
        }
    }

    /// The SF Symbol drawn above the tab's name.
    var systemImage: String {
        switch self {
        case .voice: return "speaker.wave.2"
        case .playback: return "play.circle"
        case .shortcuts: return "keyboard"
        case .text: return "textformat.abc"
        case .sounds: return "speaker.badge.exclamationmark"
        case .stats: return "chart.bar"
        case .feeds: return "dot.radiowaves.up.forward"
        case .storage: return "folder.badge.gearshape"
        case .miscellaneous: return "gearshape.2"
        }
    }

    /// Whether the tab scrolls as a whole when it is taller than the
    /// window: every tab drawn as a form, which is every tab but Text. The
    /// Text tab's rule list fills the room its other controls leave and
    /// scrolls by itself, and a list inside a scrolling form would collapse
    /// to nothing.
    var scrollsAsAWhole: Bool {
        self != .text
    }
}

/// One tab's controls, as the window and the tests that measure it draw
/// them: the one place a tab is matched with its view.
struct SettingsTabContent: View {
    /// The tab whose controls to draw.
    let tab: SettingsTab

    var body: some View {
        switch tab {
        case .voice: VoiceSettingsView()
        case .playback: PlaybackSettingsView()
        case .shortcuts: KeyboardShortcutsSettingsView()
        case .text: SubstitutionsSettingsView()
        case .sounds: SoundEffectsSettingsView()
        case .stats: ReadingStatsView()
        case .feeds: FeedSettingsView()
        case .storage: StorageSettingsView()
        case .miscellaneous: MiscellaneousSettingsView()
        }
    }
}

/// One tab as the Settings window shows it.
///
/// A tab that scrolls as a whole is drawn in the grouped form style, which
/// on macOS puts the form in a scroll view exactly the width of the window,
/// with each section in a box: every control can be scrolled to, and Tab and
/// VoiceOver scroll it into view, in the order and under the labels it had.
/// A tab that fits shows no scroll bar. The grouped style also lays each
/// row out on its own: the columns style lines every row's controls up on
/// one label column, which made the Shortcuts tab 223 points wider than any
/// width it was given, so it was clipped at both sides as well as below.
///
/// Toggles stay checkboxes, as TextMouth's settings have always drawn and
/// spoken them, and text fields keep their borders; the grouped style alone
/// would make the toggles switches and draw the number fields as bare
/// numbers. The style reaches any form in a sheet such a tab presents; none
/// presents one.
struct SettingsTabPage: View {
    /// The tab to show.
    let tab: SettingsTab

    var body: some View {
        if tab.scrollsAsAWhole {
            SettingsTabContent(tab: tab)
                .formStyle(.grouped)
                .toggleStyle(.checkbox)
                .textFieldStyle(.roundedBorder)
        } else {
            SettingsTabContent(tab: tab)
        }
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
                    // The speed for the eye; VoiceOver hears it once, as
                    // the slider's value (TODO A10).
                    Text("Default Speed: \(Int(settingsViewModel.wordsPerMinute)) WPM")
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.wordsPerMinute,
                        in: 50...650,
                        step: 25
                    ) {
                        Text("Words per minute")
                    }
                    // VoiceOver says the control's kind itself, so the label
                    // names the setting alone (TODO A10).
                    .accessibilityLabel("Default speed")
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
                    // The pitch for the eye; VoiceOver hears it once, as the
                    // slider's value (TODO A10).
                    Text("Default Pitch: \(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier))")
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.pitchMultiplier,
                        in: 0.5...2.0,
                        step: 0.1
                    ) {
                        Text("Pitch")
                    }
                    .accessibilityLabel("Default pitch")
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
                            // The pause for the eye; VoiceOver hears it
                            // once, as the stepper's value (TODO A10).
                            Text("Minimum pause: \(Int(settingsViewModel.rewindSmartThreshold)) seconds")
                                .accessibilityHidden(true)
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
                    // The level for the eye; VoiceOver hears it once, as the
                    // slider's value (TODO A10).
                    Text("Punctuation pauses: \(levelName)")
                        .accessibilityHidden(true)

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

                // The hint for the eye; VoiceOver hears it once, as the
                // checkbox's hint (TODO A10).
                Text("Automatically start playing when you navigate to a heading, bookmark, or search result.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
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
                    // The fade for the eye; VoiceOver hears it once, as the
                    // stepper's value, and the caption below says what off
                    // does (TODO A10).
                    Text("Fade out: \(Self.fadeOutText(settingsViewModel.sleepFadeOutDuration))")
                        .accessibilityHidden(true)
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
                    .accessibilityValue(Self.fadeOutText(settingsViewModel.sleepFadeOutDuration))

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

    /// The sleep timer's fade as the Playback tab shows it and its stepper
    /// speaks it: "Off" for none, else its whole seconds counted, "1
    /// second", "3 seconds" (TODO A10; it said "1 seconds").
    nonisolated static func fadeOutText(_ seconds: Double) -> String {
        seconds > 0 ? CountWording.seconds(Int(seconds)) : "Off"
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
