import SwiftUI
import AVFoundation

/// The Settings window: one tab for each of `SettingsTab`'s cases, in their
/// order, each shown as `SettingsTabPage` shows it.
struct SettingsView: View {
    /// The window's size, which every tab shares and none can change. Wide
    /// enough for the eleven tabs' toolbar to show every one, so none hides
    /// in the toolbar's overflow menu (each tab added has needed about 80
    /// points: 780 for ten, 860 since the Library tab, October 30, 2026). A
    /// tab taller than this scrolls (`SettingsTab.scrollsAsAWhole`, TODO A10).
    nonisolated static let windowSize = CGSize(width: 860, height: 540)

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
    /// The braille code and contraction braille is read and written with (FMT21).
    case braille
    case sounds
    case stats
    /// The Library window's views: their order, when each is offered, and
    /// the views the listener makes (October 30, 2026).
    case library
    /// The podcast and article feeds' settings (FR03).
    case feeds
    case storage
    case miscellaneous

    var id: Self { self }

    /// The tab's name in the window's toolbar, which VoiceOver reads.
    var title: String {
        switch self {
        case .voice: return SettingsWording.voiceTab
        case .playback: return SettingsWording.playbackTab
        case .shortcuts: return SettingsWording.shortcutsTab
        case .text: return SettingsWording.textTab
        case .braille: return BrailleSettingsWording.tabTitle
        case .sounds: return SettingsWording.soundsTab
        case .stats: return SettingsWording.statsTab
        case .library: return LibraryViewsSettingsWording.tabTitle
        case .feeds: return FeedSettingsWording.tabTitle
        case .storage: return SettingsWording.storageTab
        case .miscellaneous: return SettingsWording.miscellaneousTab
        }
    }

    /// The SF Symbol drawn above the tab's name.
    var systemImage: String {
        switch self {
        case .voice: return "speaker.wave.2"
        case .playback: return "play.circle"
        case .shortcuts: return "keyboard"
        case .text: return "textformat.abc"
        case .braille: return "hand.point.up.braille"
        case .sounds: return "speaker.badge.exclamationmark"
        case .stats: return "chart.bar"
        case .library: return "books.vertical"
        case .feeds: return "dot.radiowaves.up.forward"
        case .storage: return "folder.badge.gearshape"
        case .miscellaneous: return "gearshape.2"
        }
    }

    /// Whether the tab scrolls as a whole when it is taller than the
    /// window: every tab drawn as a form, which is every tab but Text and
    /// Library. The Text tab's rule list and the Library tab's list of views
    /// fill the room their other controls leave and scroll by themselves,
    /// and a list inside a scrolling form would collapse to nothing.
    var scrollsAsAWhole: Bool {
        self != .text && self != .library
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
        case .braille: BrailleSettingsView()
        case .sounds: SoundEffectsSettingsView()
        case .stats: ReadingStatsView()
        case .library: LibraryViewsSettingsView()
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
                .checkboxToggleStyle()
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
            Picker(SettingsWording.languageTitle, selection: $settingsViewModel.selectedLanguage) {
                Text(SettingsWording.allLanguages).tag("")
                ForEach(settingsViewModel.availableLanguages, id: \.self) { lang in
                    Text(InterfaceLanguage.current.locale.localizedString(forLanguageCode: lang) ?? lang)
                        .tag(lang)
                }
            }
            .onChange(of: settingsViewModel.selectedLanguage) { _, _ in
                settingsViewModel.refreshVoices()
            }
            .accessibilityLabel(SettingsWording.voiceLanguageLabel)

            Picker(SettingsWording.voiceTitle, selection: $settingsViewModel.selectedVoiceID) {
                ForEach(settingsViewModel.availableVoices, id: \.identifier) { voice in
                    HStack {
                        Text(voice.name)
                        Text(SettingsWording.qualityInParentheses(settingsViewModel.voiceQualityLabel(voice)))
                            .foregroundColor(.secondary)
                    }
                    .tag(voice.identifier)
                    .accessibilityLabel(SettingsWording.voiceLabel(name: voice.name, quality: settingsViewModel.voiceQualityLabel(voice)))
                }
            }
            .accessibilityLabel(SettingsWording.selectVoiceLabel)
            .accessibilityHint(SettingsWording.selectVoiceHint)

            if let voice = settingsViewModel.selectedVoice {
                LabeledContent(SettingsWording.qualityTitle) {
                    Text(settingsViewModel.voiceQualityLabel(voice))
                }
                LabeledContent(SettingsWording.languageTitle) {
                    Text(voice.language)
                }
            }

            Button(SettingsWording.previewTitle) {
                previewVoice()
            }
            .accessibilityLabel(SettingsWording.previewLabel)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // The speed for the eye; VoiceOver hears it once, as
                    // the slider's value (TODO A10).
                    Text(SettingsWording.defaultSpeedText(Int(settingsViewModel.wordsPerMinute)))
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.wordsPerMinute,
                        in: 50...650,
                        step: 25
                    ) {
                        Text(SettingsWording.wordsPerMinuteTitle)
                    }
                    // VoiceOver says the control's kind itself, so the label
                    // names the setting alone (TODO A10).
                    .accessibilityLabel(SettingsWording.defaultSpeedLabel)
                    .accessibilityValue(SettingsWording.wordsPerMinuteValue(Int(settingsViewModel.wordsPerMinute)))

                    Text(SettingsWording.defaultSpeedExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(SettingsWording.defaultSpeedHeader)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // The pitch for the eye; VoiceOver hears it once, as the
                    // slider's value (TODO A10).
                    Text(SettingsWording.defaultPitchText(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier)))
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.pitchMultiplier,
                        in: 0.5...2.0,
                        step: 0.1
                    ) {
                        Text(SettingsWording.pitchTitle)
                    }
                    .accessibilityLabel(SettingsWording.defaultPitchLabel)
                    .accessibilityValue(SpeechService.pitchLabel(settingsViewModel.pitchMultiplier))

                    Text(SettingsWording.defaultPitchExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(SettingsWording.defaultPitchHeader)
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
                Picker(SettingsWording.skipForwardTitle, selection: Binding(
                    get: { settingsViewModel.skipForwardUnit },
                    set: { settingsViewModel.skipForwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .accessibilityLabel(SettingsWording.skipForwardLabel)
                .accessibilityHint(SettingsWording.skipForwardHint)

                Picker(SettingsWording.skipBackwardTitle, selection: Binding(
                    get: { settingsViewModel.skipBackwardUnit },
                    set: { settingsViewModel.skipBackwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .accessibilityLabel(SettingsWording.skipBackwardLabel)
                .accessibilityHint(SettingsWording.skipBackwardHint)
            } header: {
                Text(SettingsWording.skipControlsHeader)
            }

            Section {
                Picker(SettingsWording.shiftSkipForwardTitle, selection: Binding(
                    get: { settingsViewModel.shiftSkipForwardUnit },
                    set: { settingsViewModel.shiftSkipForwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .accessibilityLabel(SettingsWording.shiftSkipForwardLabel)
                .accessibilityHint(SettingsWording.shiftSkipForwardHint)

                Picker(SettingsWording.shiftSkipBackwardTitle, selection: Binding(
                    get: { settingsViewModel.shiftSkipBackwardUnit },
                    set: { settingsViewModel.shiftSkipBackwardUnit = $0 }
                )) {
                    ForEach(SkipUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .accessibilityLabel(SettingsWording.shiftSkipBackwardLabel)
                .accessibilityHint(SettingsWording.shiftSkipBackwardHint)

                Text(SettingsWording.shiftSkipExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(SettingsWording.shiftSkipHeader)
            }

            Section {
                Picker(SettingsWording.rewindToTitle, selection: Binding(
                    get: { settingsViewModel.rewindOnResumeUnit },
                    set: { settingsViewModel.rewindOnResumeUnit = $0 }
                )) {
                    ForEach(RewindUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .accessibilityLabel(SettingsWording.rewindUnitLabel)
                .accessibilityHint(SettingsWording.rewindUnitHint)

                if settingsViewModel.rewindOnResumeUnit != .none {
                    Toggle(SettingsWording.smartModeTitle, isOn: $settingsViewModel.rewindSmartMode)
                        .accessibilityLabel(SettingsWording.smartModeLabel)
                        .accessibilityHint(SettingsWording.smartModeHint)

                    if settingsViewModel.rewindSmartMode {
                        VStack(alignment: .leading, spacing: 4) {
                            // The pause for the eye; VoiceOver hears it
                            // once, as the stepper's value (TODO A10).
                            Text(SettingsWording.minimumPauseText(Int(settingsViewModel.rewindSmartThreshold)))
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
                            .accessibilityLabel(SettingsWording.minimumPauseLabel)
                            .accessibilityValue(CountWording.seconds(Int(settingsViewModel.rewindSmartThreshold)))

                            Text(SettingsWording.minimumPauseExplanation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text(SettingsWording.rewindHeader)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    let level = Int(settingsViewModel.punctuationPauseLevel)
                    let levelName = SettingsWording.punctuationLevelName(level)
                    // The level for the eye; VoiceOver hears it once, as the
                    // slider's value (TODO A10).
                    Text(SettingsWording.punctuationPausesText(levelName))
                        .accessibilityHidden(true)

                    Slider(
                        value: $settingsViewModel.punctuationPauseLevel,
                        in: 0...3,
                        step: 1
                    ) {
                        Text(SettingsWording.pauseLevelTitle)
                    }
                    .accessibilityLabel(SettingsWording.pauseLevelLabel)
                    .accessibilityValue(levelName)

                    Text(SettingsWording.punctuationLevelsExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(SettingsWording.punctuationHeader)
            }

            Section {
                Toggle(SettingsWording.autoPlayTitle, isOn: $settingsViewModel.autoPlayOnNavigate)
                    .accessibilityLabel(SettingsWording.autoPlayTitle)
                    .accessibilityHint(SettingsWording.autoPlayHint)

                // The hint for the eye; VoiceOver hears it once, as the
                // checkbox's hint (TODO A10).
                Text(SettingsWording.autoPlayExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            } header: {
                Text(SettingsWording.navigationHeader)
            }

            Section {
                Picker(SettingsWording.whenBookEndsTitle, selection: Binding(
                    get: { settingsViewModel.endOfBookBehavior },
                    set: { settingsViewModel.endOfBookBehavior = $0 }
                )) {
                    ForEach(EndOfBookBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .accessibilityLabel(SettingsWording.endOfBookLabel)
                .accessibilityHint(SettingsWording.endOfBookHint)

                Text(SettingsWording.continueNextExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // What Play does on a finished book with each choice that
                // stops there (TODO P07).
                Text(EndOfBookWording.playOnAFinishedBookCaption)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Where the next book opens when listening goes on from one
                // book to another (0.2.5), below the captions of "When book
                // ends", which stay under their picker. The label is spoken
                // from the control itself; its hint says what the choices
                // do, once.
                Picker(NextBookWindowWording.globalLabel, selection: Binding(
                    get: { settingsViewModel.nextBookWindow },
                    set: { settingsViewModel.nextBookWindow = $0 }
                )) {
                    // Each choice by its localized name; the raw value is
                    // what config.json keeps (FR35).
                    ForEach(NextBookWindow.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .accessibilityLabel(NextBookWindowWording.globalLabel)
                .accessibilityHint(NextBookWindowWording.globalHint)

                Text(NextBookWindowWording.globalHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            } header: {
                Text(SettingsWording.endOfBookHeader)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // The fade for the eye; VoiceOver hears it once, as the
                    // stepper's value, and the caption below says what off
                    // does (TODO A10).
                    Text(SettingsWording.fadeOutLine(Self.fadeOutText(settingsViewModel.sleepFadeOutDuration)))
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
                    .accessibilityLabel(SettingsWording.fadeOutLabel)
                    .accessibilityValue(Self.fadeOutText(settingsViewModel.sleepFadeOutDuration))

                    Text(SettingsWording.fadeOutExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle(SettingsWording.autoCloseTitle, isOn: $settingsViewModel.sleepTimerAutoClose)
                    .accessibilityLabel(SettingsWording.autoCloseLabel)
                    .accessibilityHint(SettingsWording.autoCloseHint)
            } header: {
                Text(SettingsWording.sleepTimerHeader)
            }

            Section {
                Picker(SettingsWording.navigationUnitControlsTitle, selection: Binding(
                    get: { settingsViewModel.playbackNavigationUnitControlMode },
                    set: { settingsViewModel.playbackNavigationUnitControlMode = $0 }
                )) {
                    ForEach(PlaybackNavigationUnitControlMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityLabel(SettingsWording.navigationUnitControlsLabel)
                .accessibilityHint(SettingsWording.navigationUnitControlsHint)

                // Use an explicit binding so the SettingsViewModel setter
                // publishes a playback-bar refresh. AppStorage's projected
                // binding writes its storage directly and can bypass didSet.
                Toggle(SettingsWording.showBookmarkTitle, isOn: Binding(
                    get: { settingsViewModel.showBookmarkInPlaybackControls },
                    set: { settingsViewModel.showBookmarkInPlaybackControls = $0 }
                ))
                    .accessibilityLabel(SettingsWording.showBookmarkLabel)
                    .accessibilityHint(SettingsWording.showBookmarkHint)

                Toggle(SettingsWording.showSpeedTitle, isOn: Binding(
                    get: { settingsViewModel.showSpeedInPlaybackControls },
                    set: { settingsViewModel.showSpeedInPlaybackControls = $0 }
                ))
                    .accessibilityLabel(SettingsWording.showSpeedLabel)
                    .accessibilityHint(SettingsWording.showSpeedHint)

                Text(SettingsWording.navigationMenuExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(SettingsWording.playbackControlsHeader)
            }

            // Times (P08): whether the reader names the speed that time
            // left and total time count at. An explicit binding, so the
            // model's setter publishes the change to open readers.
            Section {
                Toggle(ReaderTimeWording.settingTitle, isOn: Binding(
                    get: { settingsViewModel.includeSpeedWithTimes },
                    set: { settingsViewModel.includeSpeedWithTimes = $0 }
                ))
                    .accessibilityHint(ReaderTimeWording.settingHint)

                // The hint for the eye; VoiceOver hears it once, as the
                // checkbox's hint (TODO A10).
                Text(ReaderTimeWording.settingHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            } header: {
                Text(ReaderTimeWording.settingSection)
            }

            // Pages (PG03): whether the reader screen shows the page being
            // read. An explicit binding, so the model's setter publishes
            // the change to open readers.
            Section {
                Toggle(ReaderPageWording.showInReaderTitle, isOn: Binding(
                    get: { settingsViewModel.showsPageInReader },
                    set: { settingsViewModel.showsPageInReader = $0 }
                ))
                    .accessibilityHint(ReaderPageWording.showInReaderHint)

                // The hint for the eye; VoiceOver hears it once, as the
                // checkbox's hint.
                Text(ReaderPageWording.showInReaderHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                // Whether Where Am I?'s summaries say the page (PG04).
                Toggle(ReaderPageWording.sayInWhereAmITitle, isOn: Binding(
                    get: { settingsViewModel.saysPageInWhereAmI },
                    set: { settingsViewModel.saysPageInWhereAmI = $0 }
                ))
                    .accessibilityHint(ReaderPageWording.sayInWhereAmIHint)

                Text(ReaderPageWording.sayInWhereAmIHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            } header: {
                Text(ReaderPageWording.settingSection)
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
        seconds > 0 ? CountWording.seconds(Int(seconds)) : SettingsWording.off
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
        .accessibilityLabel(SentenceWording.labelled(action, key))
    }
}

// MARK: - The Words

/// The words of the Settings window's tab names and its Voice and Playback
/// tabs, each defined once for the screen, VoiceOver, a braille display, and
/// the tests (FR34). Every sentence that names a choice of a picker
/// interpolates the choice's own title.
enum SettingsWording {
    // MARK: Tabs

    /// The Voice tab's name.
    static var voiceTab: String {
        // Translators: Name of the Settings tab for the voice, its language, and the default speed and pitch. Shown in the Settings window's toolbar.
        InterfaceText.line("common.voice", "Voice")
    }
    /// The Playback tab's name.
    static var playbackTab: String {
        // Translators: Name of the Settings tab for skipping, rewinding, the end of a book, the sleep timer, and the playback controls.
        InterfaceText.line("common.playback", "Playback")
    }
    /// The Shortcuts tab's name.
    static var shortcutsTab: String {
        // Translators: Name of the Settings tab for keyboard shortcuts.
        InterfaceText.line("settings.shortcutsTab", "Shortcuts")
    }
    /// The Text tab's name.
    static var textTab: String {
        // Translators: Name of the Settings tab for text substitution rules and repeated symbols.
        InterfaceText.line("settings.textTab", "Text")
    }
    /// The Sounds tab's name.
    static var soundsTab: String {
        // Translators: Name of the Settings tab for the sounds played for playback events.
        InterfaceText.line("settings.soundsTab", "Sounds")
    }
    /// The Stats tab's name.
    static var statsTab: String {
        // Translators: Name of the Settings tab for reading statistics.
        InterfaceText.line("settings.statsTab", "Stats")
    }
    /// The Storage tab's name.
    static var storageTab: String {
        // Translators: Name of the Settings tab for where the library is stored, importing books, and the logs.
        InterfaceText.line("settings.storageTab", "Storage")
    }
    /// The Miscellaneous tab's name.
    static var miscellaneousTab: String {
        // Translators: Name of the Settings tab for the options that fit no other tab, such as Bluetooth monitoring.
        InterfaceText.line("settings.miscellaneousTab", "Miscellaneous")
    }

    /// A setting's off position, as a stepper or slider says it.
    static var off: String {
        // Translators: The word for a setting that is turned off, as a slider's or stepper's value says it, such as the sleep timer's fade out.
        InterfaceText.line("common.off", "Off")
    }

    // MARK: Voice

    /// The language pop-up's title, and the title of the selected voice's language.
    static var languageTitle: String {
        // Translators: Title of the pop-up in the Voice settings that narrows the voices to one language, and the label of the selected voice's language beneath it.
        InterfaceText.line("common.language", "Language")
    }
    /// The language pop-up's choice of every language.
    static var allLanguages: String {
        // Translators: A choice of the Language pop-up in the Voice settings: voices of every language are offered.
        InterfaceText.line("common.all", "All")
    }
    /// The language pop-up's VoiceOver label.
    static var voiceLanguageLabel: String {
        // Translators: VoiceOver label of the Language pop-up in the Voice settings.
        InterfaceText.line("settings.voiceLanguageLabel", "Voice language")
    }
    /// The voice pop-up's title.
    static var voiceTitle: String {
        // Translators: Title of the pop-up in the Voice settings that chooses the voice.
        InterfaceText.line("common.voice", "Voice")
    }
    /// A voice's quality beside its name in the pop-up.
    static func qualityInParentheses(_ quality: String) -> String {
        // Translators: A voice's quality, in parentheses, beside its name in the voice pop-up. %@ is the quality, such as Enhanced.
        InterfaceText.line("common.openValueClose", "(\(quality))")
    }
    /// A voice's VoiceOver label.
    static func voiceLabel(name: String, quality: String) -> String {
        // Translators: VoiceOver label of a voice in the voice pop-up. %1$@ is the voice's name and %2$@ is its quality, such as Enhanced.
        InterfaceText.line("common.valueValueQuality", "\(name), \(quality) quality")
    }
    /// The voice pop-up's VoiceOver label.
    static var selectVoiceLabel: String {
        // Translators: VoiceOver label of the voice pop-up in the Voice settings.
        InterfaceText.line("settings.selectVoiceLabel", "Select voice")
    }
    /// The voice pop-up's hint.
    static var selectVoiceHint: String {
        // Translators: VoiceOver hint of the voice pop-up in the Voice settings.
        InterfaceText.line("settings.selectVoiceHint", "Choose a voice for reading. Change takes effect immediately.")
    }
    /// The selected voice's quality, labelled.
    static var qualityTitle: String {
        // Translators: Label of the selected voice's quality in the Voice settings, such as Enhanced.
        InterfaceText.line("settings.qualityTitle", "Quality")
    }
    /// The button that speaks a sample.
    static var previewTitle: String {
        // Translators: Title of the button in the Voice settings that speaks a sample sentence in the selected voice.
        InterfaceText.line("common.previewVoice", "Preview Voice")
    }
    /// The same button's VoiceOver label.
    static var previewLabel: String {
        // Translators: VoiceOver label of the Preview Voice button in the Voice settings.
        InterfaceText.line("common.previewSelectedVoice", "Preview selected voice")
    }
    /// The default speed as the screen shows it, above its slider.
    static func defaultSpeedText(_ wordsPerMinute: Int) -> String {
        // Translators: The default reading speed shown above its slider in the Voice settings. %lld is the speed in words per minute; WPM is the abbreviation of words per minute.
        InterfaceText.line("settings.defaultSpeedText", "Default Speed: \(number: wordsPerMinute) WPM")
    }
    /// The speed slider's title.
    static var wordsPerMinuteTitle: String {
        // Translators: Title of the default speed slider in the Voice settings.
        InterfaceText.line("common.wordsPerMinute", "Words per minute")
    }
    /// The speed slider's VoiceOver label.
    static var defaultSpeedLabel: String {
        // Translators: VoiceOver label of the default speed slider in the Voice settings.
        InterfaceText.line("settings.defaultSpeedLabel", "Default speed")
    }
    /// The speed slider's value, spoken.
    static func wordsPerMinuteValue(_ wordsPerMinute: Int) -> String {
        // Translators: VoiceOver value of the default speed slider in the Voice settings. %lld is the speed in words per minute.
        InterfaceText.line("common.countWordsPerMinute", "\(number: wordsPerMinute) words per minute")
    }
    /// The text under the speed slider.
    static var defaultSpeedExplanation: String {
        // Translators: Explanation under the default speed slider in the Voice settings.
        InterfaceText.line("settings.defaultSpeedExplanation", "Default speed for new books. Each book can override this with its own speed.")
    }
    /// The speed group's heading.
    static var defaultSpeedHeader: String {
        // Translators: Heading of the default speed group in the Voice settings.
        InterfaceText.line("settings.defaultSpeedHeader", "Default Speed")
    }
    /// The default pitch as the screen shows it, above its slider.
    static func defaultPitchText(_ pitch: String) -> String {
        // Translators: The default pitch shown above its slider in the Voice settings. %@ is the pitch, such as Normal (1.0x).
        InterfaceText.line("settings.defaultPitchText", "Default Pitch: \(pitch)")
    }
    /// The pitch slider's title.
    static var pitchTitle: String {
        // Translators: Title of the default pitch slider in the Voice settings.
        InterfaceText.line("common.pitch", "Pitch")
    }
    /// The pitch slider's VoiceOver label.
    static var defaultPitchLabel: String {
        // Translators: VoiceOver label of the default pitch slider in the Voice settings.
        InterfaceText.line("settings.defaultPitchLabel", "Default pitch")
    }
    /// The text under the pitch slider.
    static var defaultPitchExplanation: String {
        // Translators: Explanation under the default pitch slider in the Voice settings.
        InterfaceText.line("settings.defaultPitchExplanation", "Default pitch for new books. 1.0 is normal. Each book can override this.")
    }
    /// The pitch group's heading.
    static var defaultPitchHeader: String {
        // Translators: Heading of the default pitch group in the Voice settings.
        InterfaceText.line("settings.defaultPitchHeader", "Default Pitch")
    }

    // MARK: Playback: Skipping

    /// The Skip Forward pop-up's title.
    static var skipForwardTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses what the skip forward button moves by.
        InterfaceText.line("common.skipForward", "Skip Forward")
    }
    /// The same pop-up's VoiceOver label.
    static var skipForwardLabel: String {
        // Translators: VoiceOver label of the Skip Forward pop-up in the Playback settings.
        InterfaceText.line("settings.skipForwardLabel", "Skip forward unit")
    }
    /// The same pop-up's VoiceOver hint.
    static var skipForwardHint: String {
        // Translators: VoiceOver hint of the Skip Forward pop-up in the Playback settings.
        InterfaceText.line("settings.skipForwardHint", "What happens when you skip forward")
    }
    /// The Skip Backward pop-up's title.
    static var skipBackwardTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses what the skip backward button moves by.
        InterfaceText.line("common.skipBackward", "Skip Backward")
    }
    /// The same pop-up's VoiceOver label.
    static var skipBackwardLabel: String {
        // Translators: VoiceOver label of the Skip Backward pop-up in the Playback settings.
        InterfaceText.line("settings.skipBackwardLabel", "Skip backward unit")
    }
    /// The same pop-up's VoiceOver hint.
    static var skipBackwardHint: String {
        // Translators: VoiceOver hint of the Skip Backward pop-up in the Playback settings.
        InterfaceText.line("settings.skipBackwardHint", "What happens when you skip backward")
    }
    /// The skip group's heading.
    static var skipControlsHeader: String {
        // Translators: Heading of the group of skip pop-ups in the Playback settings.
        InterfaceText.line("settings.skipControlsHeader", "Skip Controls")
    }
    /// The Shift+Skip Forward pop-up's title.
    static var shiftSkipForwardTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses what skipping forward moves by while Shift is held. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipForwardTitle", "Shift+Skip Forward")
    }
    /// The same pop-up's VoiceOver label.
    static var shiftSkipForwardLabel: String {
        // Translators: VoiceOver label of the Shift+Skip Forward pop-up in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipForwardLabel", "Shift skip forward unit")
    }
    /// The same pop-up's VoiceOver hint.
    static var shiftSkipForwardHint: String {
        // Translators: VoiceOver hint of the Shift+Skip Forward pop-up in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipForwardHint", "What happens when you hold Shift and skip forward")
    }
    /// The Shift+Skip Backward pop-up's title.
    static var shiftSkipBackwardTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses what skipping backward moves by while Shift is held. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipBackwardTitle", "Shift+Skip Backward")
    }
    /// The same pop-up's VoiceOver label.
    static var shiftSkipBackwardLabel: String {
        // Translators: VoiceOver label of the Shift+Skip Backward pop-up in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipBackwardLabel", "Shift skip backward unit")
    }
    /// The same pop-up's VoiceOver hint.
    static var shiftSkipBackwardHint: String {
        // Translators: VoiceOver hint of the Shift+Skip Backward pop-up in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipBackwardHint", "What happens when you hold Shift and skip backward")
    }
    /// The text under the Shift+Skip pop-ups.
    static var shiftSkipExplanation: String {
        // Translators: Explanation under the Shift+Skip pop-ups in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipExplanation", "Hold Shift while skipping to use a secondary skip amount.")
    }
    /// The Shift+Skip group's heading.
    static var shiftSkipHeader: String {
        // Translators: Heading of the group of Shift+Skip pop-ups in the Playback settings. Shift is the key's name.
        InterfaceText.line("settings.shiftSkipHeader", "Shift+Skip (Secondary)")
    }

    // MARK: Playback: Rewinding

    /// The Rewind to pop-up's title.
    static var rewindToTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses how far playback rewinds when it resumes: to the start of a sentence, paragraph, or heading.
        InterfaceText.line("settings.rewindToTitle", "Rewind to")
    }
    /// The same pop-up's VoiceOver label.
    static var rewindUnitLabel: String {
        // Translators: VoiceOver label of the Rewind to pop-up in the Playback settings.
        InterfaceText.line("settings.rewindUnitLabel", "Rewind on resume unit")
    }
    /// The same pop-up's VoiceOver hint.
    static var rewindUnitHint: String {
        // Translators: VoiceOver hint of the Rewind to pop-up in the Playback settings.
        InterfaceText.line("settings.rewindUnitHint", "When resuming playback, rewind to the start of this unit")
    }
    /// The smart mode checkbox's title.
    static var smartModeTitle: String {
        // Translators: Title of the checkbox in the Playback settings that makes playback rewind only after a long enough pause.
        InterfaceText.line("settings.smartModeTitle", "Smart mode")
    }
    /// The same checkbox's VoiceOver label.
    static var smartModeLabel: String {
        // Translators: VoiceOver label of the Smart mode checkbox in the Playback settings.
        InterfaceText.line("settings.smartModeLabel", "Smart rewind mode")
    }
    /// The same checkbox's VoiceOver hint.
    static var smartModeHint: String {
        // Translators: VoiceOver hint of the Smart mode checkbox in the Playback settings.
        InterfaceText.line("settings.smartModeHint", "Only rewind if the pause was longer than the threshold")
    }
    /// The minimum pause as the screen shows it, above its stepper.
    static func minimumPauseText(_ seconds: Int) -> String {
        // Translators: The smart rewind's minimum pause shown above its stepper in the Playback settings. %lld is the pause in seconds.
        InterfaceText.line("settings.minimumPauseText", "Minimum pause: \(number: seconds) seconds")
    }
    /// The stepper's VoiceOver label.
    static var minimumPauseLabel: String {
        // Translators: VoiceOver label of the minimum pause stepper in the Playback settings.
        InterfaceText.line("settings.minimumPauseLabel", "Minimum pause threshold")
    }
    /// The text under the stepper.
    static var minimumPauseExplanation: String {
        // Translators: Explanation under the minimum pause stepper in the Playback settings.
        InterfaceText.line("settings.minimumPauseExplanation", "Don't rewind if paused for less than this.")
    }
    /// The rewind group's heading.
    static var rewindHeader: String {
        // Translators: Heading of the rewind group in the Playback settings.
        InterfaceText.line("settings.rewindHeader", "Rewind on Resume")
    }

    // MARK: Playback: Punctuation Pauses

    /// A punctuation pause level's name: 0 Off, 1 Subtle, 2 Moderate, 3 Heavy.
    static func punctuationLevelName(_ level: Int) -> String {
        switch min(max(level, 0), 3) {
        case 0: return off
        case 1:
            // Translators: The name of punctuation pause level 1: only periods pause.
            return InterfaceText.line("settings.punctuationLevelName.subtle", "Subtle")
        case 2:
            // Translators: The name of punctuation pause level 2: periods and commas pause.
            return InterfaceText.line("settings.punctuationLevelName.moderate", "Moderate")
        default:
            // Translators: The name of punctuation pause level 3: periods, commas, and paragraph breaks pause.
            return InterfaceText.line("settings.punctuationLevelName.other", "Heavy")
        }
    }
    /// The level as the screen shows it, above its slider.
    static func punctuationPausesText(_ levelName: String) -> String {
        // Translators: The punctuation pause level shown above its slider in the Playback settings. %@ is the level's name, such as Subtle.
        InterfaceText.line("settings.punctuationPausesText", "Punctuation pauses: \(levelName)")
    }
    /// The slider's title.
    static var pauseLevelTitle: String {
        // Translators: Title of the punctuation pause level slider in the Playback settings.
        InterfaceText.line("settings.pauseLevelTitle", "Pause level")
    }
    /// The slider's VoiceOver label.
    static var pauseLevelLabel: String {
        // Translators: VoiceOver label of the punctuation pause level slider in the Playback settings.
        InterfaceText.line("settings.pauseLevelLabel", "Punctuation pause level")
    }
    /// The text under the slider, naming each level by the name the slider speaks.
    static var punctuationLevelsExplanation: String {
        // Translators: Explanation under the punctuation pause level slider in the Playback settings. %1$@ to %4$@ are the names of levels 0 to 3, as the slider speaks them: Off, Subtle, Moderate, and Heavy. The words in parentheses say what pauses at that level.
        InterfaceText.line("settings.punctuationLevelsExplanation", "0 = \(punctuationLevelName(0)), 1 = \(punctuationLevelName(1)) (periods), 2 = \(punctuationLevelName(2)) (+ commas), 3 = \(punctuationLevelName(3)) (+ paragraph breaks)")
    }
    /// The punctuation group's heading.
    static var punctuationHeader: String {
        // Translators: Heading of the punctuation pause group in the Playback settings.
        InterfaceText.line("settings.punctuationHeader", "Punctuation Pauses")
    }

    // MARK: Playback: Navigation and the End of a Book

    /// The auto-play checkbox's title and label.
    static var autoPlayTitle: String {
        // Translators: Title and VoiceOver label of the checkbox in the Playback settings that starts playing after a jump to a heading, bookmark, or search result.
        InterfaceText.line("settings.autoPlayTitle", "Auto-play after navigation")
    }
    /// The same checkbox's VoiceOver hint.
    static var autoPlayHint: String {
        // Translators: VoiceOver hint of the Auto-play after navigation checkbox in the Playback settings.
        InterfaceText.line("settings.autoPlayHint", "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result")
    }
    /// The text under the checkbox.
    static var autoPlayExplanation: String {
        // Translators: Explanation under the Auto-play after navigation checkbox in the Playback settings.
        InterfaceText.line("settings.autoPlayExplanation", "Automatically start playing when you navigate to a heading, bookmark, or search result.")
    }
    /// The navigation group's heading.
    static var navigationHeader: String {
        // Translators: Heading of the navigation group in the Playback settings.
        InterfaceText.line("common.navigation", "Navigation")
    }
    /// The When book ends pop-up's title.
    static var whenBookEndsTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses what happens when a book ends.
        InterfaceText.line("settings.whenBookEndsTitle", "When book ends")
    }
    /// The same pop-up's VoiceOver label.
    static var endOfBookLabel: String {
        // Translators: VoiceOver label of the When book ends pop-up in the Playback settings.
        InterfaceText.line("settings.endOfBookLabel", "End of book behavior")
    }
    /// The same pop-up's VoiceOver hint.
    static var endOfBookHint: String {
        // Translators: VoiceOver hint of the When book ends pop-up in the Playback settings.
        InterfaceText.line("settings.endOfBookHint", "What happens when a book finishes playing")
    }
    /// The text under the pop-up that says what the choice that goes on does.
    static var continueNextExplanation: String {
        // Translators: Explanation under the When book ends pop-up in the Playback settings. %@ is the title of the pop-up's choice that plays the next book, as the pop-up shows it.
        InterfaceText.line("settings.continueNextExplanation", "\"\(EndOfBookBehavior.continueNext.title)\" plays the next book in the same folder by sort order.")
    }
    /// The end of book group's heading.
    static var endOfBookHeader: String {
        // Translators: Heading of the end of book group in the Playback settings.
        InterfaceText.line("common.endOfBook", "End of Book")
    }

    // MARK: Playback: The Sleep Timer

    /// The fade as the screen shows it, above its stepper.
    static func fadeOutLine(_ fade: String) -> String {
        // Translators: The sleep timer's fade out shown above its stepper in the Playback settings. %@ is the fade as a length of time, such as 3 seconds, or Off.
        InterfaceText.line("settings.fadeOutLine", "Fade out: \(fade)")
    }
    /// The stepper's VoiceOver label.
    static var fadeOutLabel: String {
        // Translators: VoiceOver label of the sleep timer's fade out stepper in the Playback settings.
        InterfaceText.line("settings.fadeOutLabel", "Fade out duration")
    }
    /// The text under the stepper.
    static var fadeOutExplanation: String {
        // Translators: Explanation under the sleep timer's fade out stepper in the Playback settings.
        InterfaceText.line("settings.fadeOutExplanation", "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly.")
    }
    /// The auto close checkbox's title.
    static var autoCloseTitle: String {
        // Translators: Title of the checkbox in the Playback settings that closes the sleep timer sheet once a timer is set.
        InterfaceText.line("settings.autoCloseTitle", "Close sheet after setting timer")
    }
    /// The same checkbox's VoiceOver label.
    static var autoCloseLabel: String {
        // Translators: VoiceOver label of the Close sheet after setting timer checkbox in the Playback settings.
        InterfaceText.line("settings.autoCloseLabel", "Close sleep timer sheet after setting a timer")
    }
    /// The same checkbox's VoiceOver hint.
    static var autoCloseHint: String {
        // Translators: VoiceOver hint of the Close sheet after setting timer checkbox in the Playback settings.
        InterfaceText.line("settings.autoCloseHint", "When off, the sheet stays open showing the remaining time and a reset button")
    }
    /// The sleep timer group's heading.
    static var sleepTimerHeader: String {
        // Translators: Heading of the sleep timer group in the Playback settings.
        InterfaceText.line("common.sleepTimer", "Sleep Timer")
    }

    // MARK: Playback: Controls

    /// The navigation unit controls pop-up's title.
    static var navigationUnitControlsTitle: String {
        // Translators: Title of the pop-up in the Playback settings that chooses which navigation unit menus the playback bar shows.
        InterfaceText.line("settings.navigationUnitControlsTitle", "Navigation unit controls")
    }
    /// The same pop-up's VoiceOver label.
    static var navigationUnitControlsLabel: String {
        // Translators: VoiceOver label of the Navigation unit controls pop-up in the Playback settings.
        InterfaceText.line("settings.navigationUnitControlsLabel", "Navigation unit controls in playback bar")
    }
    /// The same pop-up's VoiceOver hint.
    static var navigationUnitControlsHint: String {
        // Translators: VoiceOver hint of the Navigation unit controls pop-up in the Playback settings.
        InterfaceText.line("settings.navigationUnitControlsHint", "Choose no per-book control, one shared picker, or a menu with separate forward and backward pickers")
    }
    /// The bookmark button checkbox's title.
    static var showBookmarkTitle: String {
        // Translators: Title of the checkbox in the Playback settings that adds a bookmark button to the playback controls.
        InterfaceText.line("settings.showBookmarkTitle", "Show bookmark button")
    }
    /// The same checkbox's VoiceOver label.
    static var showBookmarkLabel: String {
        // Translators: VoiceOver label of the Show bookmark button checkbox in the Playback settings.
        InterfaceText.line("settings.showBookmarkLabel", "Show bookmark button in playback controls")
    }
    /// The same checkbox's VoiceOver hint.
    static var showBookmarkHint: String {
        // Translators: VoiceOver hint of the Show bookmark button checkbox in the Playback settings.
        InterfaceText.line("settings.showBookmarkHint", "Adds or removes a bookmark at the current position")
    }
    /// The speed controls checkbox's title.
    static var showSpeedTitle: String {
        // Translators: Title of the checkbox in the Playback settings that adds speed buttons to the playback controls.
        InterfaceText.line("settings.showSpeedTitle", "Show speed controls")
    }
    /// The same checkbox's VoiceOver label.
    static var showSpeedLabel: String {
        // Translators: VoiceOver label of the Show speed controls checkbox in the Playback settings.
        InterfaceText.line("settings.showSpeedLabel", "Show speed controls in playback controls")
    }
    /// The same checkbox's VoiceOver hint.
    static var showSpeedHint: String {
        // Translators: VoiceOver hint of the Show speed controls checkbox in the Playback settings.
        InterfaceText.line("settings.showSpeedHint", "Adds speed buttons and the current speed")
    }
    /// The text under the playback control choices.
    static var navigationMenuExplanation: String {
        // Translators: Explanation under the playback controls group's choices in the Playback settings.
        InterfaceText.line("settings.navigationMenuExplanation", "Menu changes are saved as defaults for the current book. Hiding the menus uses the global skip choices; book defaults are kept.")
    }
    /// The playback controls group's heading.
    static var playbackControlsHeader: String {
        // Translators: Heading of the playback controls group in the Playback settings.
        InterfaceText.line("settings.playbackControlsHeader", "Playback Controls")
    }
}
