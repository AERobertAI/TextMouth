import AVFoundation
import SwiftUI

/// The Mac's words, which the Voice rows read.
private typealias Words = PhoneSettingsVocabulary

/// The iPhone's Settings screen: a pushed `Form`, in the spec's order and
/// words, with fewer settings than the Mac and the same words for each. Each
/// control reads and sets the model's own property, so a change takes effect
/// as it does on the Mac. Every decision is in `PhoneSettingsModel` and its
/// neighbors, where tests can see it; this view only draws them.
///
/// Nothing here has run on iOS. What can only be known from a first run is on
/// the report's hand-check list: that focus comes back to each row, that a
/// dimmed adjustable control says "dimmed" and doesn't move, and that a flick
/// on an adjustable control says the new value, not the last one.
struct PhoneSettingsView: View {
    /// The settings shown and changed: the app's one model, handed in.
    @ObservedObject private var settings: SettingsViewModel
    /// The removal choice, which the Mac keeps in config.json and shows from
    /// this model.
    @ObservedObject private var removal: RemovalPreferencesModel
    /// Pauses the open book for a preview, given by `PhoneSession`.
    private let pauseBookForPreview: PhoneSettingsVoicePreview.PauseBook?
    /// Asks whether the audio session may be active, before a preview speaks.
    private let audioMayStart: PhoneSettingsVoicePreview.AudioMayStart?

    /// The row whose sheet is open.
    @State private var openRow: PhoneSettingsRow?
    /// The row whose sheet was last opened: `onDismiss` runs once `openRow` is
    /// already nil, and focus returns here.
    @State private var lastOpenedRow: PhoneSettingsRow?
    /// Which row has VoiceOver's focus, set only on a return from what the row
    /// opened.
    @AccessibilityFocusState private var focusedRow: PhoneSettingsRow?
    /// The row focus is to return to, asked for by whatever closes over the
    /// screen, and carried out inside the list's `ScrollViewReader`.
    @State private var refocusRequest: PhoneSettingsRow?
    /// How many changes were made on this screen. Nothing shows the count:
    /// reading it in `body` is what redraws the screen after a change. Most of
    /// the model's settings are `@AppStorage` properties, and only some of
    /// them send `objectWillChange` themselves, as their comments in the model
    /// say, so the screen can't count on hearing of a change that way.
    @State private var changeCount = 0
    /// Speaks the preview, made on the first one and kept so that it isn't
    /// released while speaking, as the Mac's synthesizer is.
    @State private var preview: PhoneSettingsVoicePreview?
    /// The file to share, once gathered.
    @State private var logsFile: URL?
    /// Whether the logs are being gathered, so a second press does nothing.
    @State private var isGatheringLogs = false
    /// Why the logs couldn't be gathered, in the system's words, while an
    /// alert says so.
    @State private var logsFailure: String?

    /// - Parameters:
    ///   - settings: The app's settings model.
    ///   - removal: The removal choice: the app's own, unless a caller passes
    ///     another.
    ///   - pauseBookForPreview: Pauses the open book while Preview Voice
    ///     speaks, and gives what resumes it. With none, the preview just
    ///     speaks.
    ///   - audioMayStart: Asks, before a preview speaks, whether the app's
    ///     audio session may be active, as a reader's Play does. With none,
    ///     the preview asks nothing.
    init(
        settings: SettingsViewModel,
        removal: RemovalPreferencesModel = .shared,
        pauseBookForPreview: PhoneSettingsVoicePreview.PauseBook? = nil,
        audioMayStart: PhoneSettingsVoicePreview.AudioMayStart? = nil
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        _removal = ObservedObject(wrappedValue: removal)
        self.pauseBookForPreview = pauseBookForPreview
        self.audioMayStart = audioMayStart
    }

    var body: some View {
        // See `changeCount`.
        let _ = changeCount
        ScrollViewReader { proxy in
            Form {
                ForEach(PhoneSettingsSection.allCases) { section in
                    Section {
                        rows(in: section)
                    } header: {
                        // The header trait is what the Headings rotor moves
                        // by (the spec, under "Lists").
                        Text(section.title)
                            .phoneSecondaryText()
                            .accessibilityAddTraits(PhoneExperiment.has("header-plain") ? [] : .isHeader)
                    }
                }
            }
            // A row may not have been made by the list when focus is asked
            // for, so the shared helper scrolls it into being first (the
            // engineering review's F12), then asks after VoiceOver has landed.
            .onChange(of: refocusRequest) { _, request in
                guard let request else { return }
                PhoneListFocus.focus(request, proxy: proxy, state: $focusedRow)
                refocusRequest = nil
            }
        }
        .navigationTitle(PhoneSettingsWording.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The voices may not have been listed yet, should Settings come before
        // whatever else asks for them, as on the Mac. Until they are, the
        // Voice row never says there are none (`PhoneSettingsVoiceOffer`).
        .onAppear { settings.voiceCatalog.loadIfNeeded() }
        // A preview speaking as the screen goes stops, and the book it paused
        // resumes, rather than staying paused for a preview nobody hears out.
        .onDisappear { preview?.stop() }
        .sheet(item: $openRow, onDismiss: returnFocusToLastOpenedRow) { row in
            sheet(for: row)
        }
        // With no buttons given, the system gives an alert its standard OK.
        .alert(PhoneSettingsRow.shareLogs.title, isPresented: isShowingLogsFailure) {
        } message: {
            Text(logsFailure ?? "")
        }
    }

    // MARK: - The Rows, Section by Section

    /// The rows of `section`, in the spec's order.
    @ViewBuilder
    private func rows(in section: PhoneSettingsSection) -> some View {
        switch section {
        case .voice:
            choiceRow(.language, value: PhoneSettingsModel.languageName(settings.selectedLanguage))
            let offer = voiceOffer
            choiceRow(.voice, value: offer.rowValue, isEnabled: offer.canOpen)
            PhoneActionButton(title: Words.previewVoice.rawValue, action: previewVoice)
                .accessibilityLabel(Words.previewSelectedVoice.rawValue)
            sliderRow(.defaultSpeed, value: noted($settings.wordsPerMinute))
            sliderRow(.defaultPitch, value: noted($settings.pitchMultiplier))
        case .navigation:
            choiceRow(.textNavigationUnit, value: textNavigationUnit.rawValue)
            choiceRow(.audioNavigationUnit, value: audioNavigationUnit.rawValue)
            switchRow(.autoPlayAfterNavigation, isOn: noted($settings.autoPlayOnNavigate))
        case .rewindOnResume:
            choiceRow(.rewindTo, value: settings.rewindOnResumeUnit.rawValue)
            switchRow(
                .smartMode,
                isOn: noted($settings.rewindSmartMode),
                isEnabled: PhoneSettingsModel.isSmartModeAvailable(rewindUnit: settings.rewindOnResumeUnit)
            )
            stepperRow(
                .minimumPause,
                value: noted($settings.rewindSmartThreshold),
                isEnabled: PhoneSettingsModel.isMinimumPauseAvailable(
                    rewindUnit: settings.rewindOnResumeUnit,
                    smartMode: settings.rewindSmartMode
                )
            )
        case .punctuationPauses:
            stepperRow(.punctuationPauseLevel, value: noted($settings.punctuationPauseLevel))
        case .endOfBook:
            choiceRow(.endOfBook, value: settings.endOfBookBehavior.rawValue)
            // Left where VoiceOver and braille can read it, as on the Mac: the
            // row has a hint of its own, so this isn't said as one.
            Text(EndOfBookWording.playOnAFinishedBookCaption)
                .font(.caption)
                .phoneSecondaryText()
        case .sleepTimer:
            stepperRow(.fadeOutDuration, value: noted($settings.sleepFadeOutDuration))
            switchRow(.closeSleepTimerSheet, isOn: noted($settings.sleepTimerAutoClose))
        case .times:
            switchRow(.includeSpeedWithTimes, isOn: noted($settings.includeSpeedWithTimes))
        case .pages:
            switchRow(.showPageInReader, isOn: noted($settings.showsPageInReader))
            switchRow(.sayPageInWhereAmI, isOn: noted($settings.saysPageInWhereAmI))
        case .reading:
            switchRow(.followInBraille, isOn: followsInBraille)
        case .removalBehavior:
            switchRow(.confirmBeforeRemoving, isOn: confirmsBeforeRemoving)
        case .statistics:
            statisticsRow
        case .about:
            versionRow
            shareLogsRow
        }
    }

    /// A row opening a sheet of choices, saying the current one as its value.
    /// A row with nothing to open stays in its place, dimmed, with no hint,
    /// since the hint would say to do what can't be done.
    private func choiceRow(_ row: PhoneSettingsRow, value: String, isEnabled: Bool = true) -> some View {
        Button {
            open(row)
        } label: {
            PhoneValueRow(name: row.title, value: value)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(row.label)
        .accessibilityValue(value)
        .accessibilityHint(isEnabled ? row.hint ?? "" : "")
        .accessibilityFocused($focusedRow, equals: row)
        .id(row)
    }

    /// A slider, with its value and caption above and below it for the eye.
    /// VoiceOver hears each of those once, from the slider itself.
    @ViewBuilder
    private func sliderRow(_ adjustment: PhoneSettingsAdjustment, value: Binding<Double>) -> some View {
        if !PhoneExperiment.has("settings-no-sliders") {
        VStack(alignment: .leading, spacing: 8) {
            PhoneValueRow(name: adjustment.label, value: adjustment.words(value.wrappedValue))
                .accessibilityHidden(true)
            Slider(value: value, in: adjustment.range, step: adjustment.step) {
                Text(adjustment.label)
            }
            .modifier(SteppedAdjustment(adjustment: adjustment, value: value, isEnabled: true))
            caption(adjustment.hint)
        }
        }
    }

    /// A stepper, showing its label and value, with its caption below for the
    /// eye. VoiceOver hears each of those once, from the stepper itself.
    @ViewBuilder
    private func stepperRow(
        _ adjustment: PhoneSettingsAdjustment,
        value: Binding<Double>,
        isEnabled: Bool = true
    ) -> some View {
        if !PhoneExperiment.has("settings-no-steppers") {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: value, in: adjustment.range, step: adjustment.step) {
                PhoneValueRow(name: adjustment.label, value: adjustment.words(value.wrappedValue))
            }
            .modifier(SteppedAdjustment(adjustment: adjustment, value: value, isEnabled: isEnabled))
            caption(adjustment.hint)
        }
        .disabled(!isEnabled)
        }
    }

    /// A switch, with its hint below it for the eye where the Mac shows one.
    @ViewBuilder
    private func switchRow(_ item: PhoneSettingsSwitch, isOn: Binding<Bool>, isEnabled: Bool = true) -> some View {
        if !PhoneExperiment.has("settings-no-switches") {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(item.title, isOn: isOn)
                .accessibilityLabel(item.label)
                .accessibilityHint(item.hint ?? "")
            if item.showsHintAsCaption, let hint = item.hint {
                caption(hint)
            }
        }
        .disabled(!isEnabled)
        }
    }

    /// Words for the eye, in the small type of the Mac's captions, and hidden
    /// from VoiceOver, which hears them once, as the control's hint (the Mac's
    /// rule).
    private func caption(_ words: String) -> some View {
        Text(words)
            .font(.caption)
            .phoneSecondaryText()
            .accessibilityHidden(true)
    }

    /// Pushes the Mac's statistics, which have no title of their own, since on
    /// the Mac they're a tab: the title is given here, so the Mac's view stays
    /// as it is. Focus comes back to the row when they're left.
    private var statisticsRow: some View {
        let row = PhoneSettingsRow.readingStatistics
        return NavigationLink {
            ReadingStatsView()
                .navigationTitle(row.title)
                .navigationBarTitleDisplayMode(.inline)
                .onDisappear { returnFocus(to: row) }
        } label: {
            Text(row.title).phonePrimaryText()
        }
        .accessibilityFocused($focusedRow, equals: row)
        .id(row)
    }

    /// The app's version, as the Mac's About and its logs name it
    /// (`CFBundleShortVersionString`, read by `BuildIdentity`): one element,
    /// with the name and the value together.
    private var versionRow: some View {
        PhoneValueRow(name: PhoneSettingsWording.version, value: BuildIdentity.current.version)
            .accessibilityElement(children: .combine)
    }

    /// The button that gathers the logs and offers them to the share sheet.
    private var shareLogsRow: some View {
        let row = PhoneSettingsRow.shareLogs
        return PhoneActionButton(title: row.title, action: shareLogs)
            .accessibilityHint(row.hint ?? "")
            .accessibilityFocused($focusedRow, equals: row)
            .id(row)
    }

    // MARK: - The Sheets

    /// What `row` opens: a sheet of choices, or the share sheet. Reading
    /// statistics is pushed, so it never comes here.
    @ViewBuilder
    private func sheet(for row: PhoneSettingsRow) -> some View {
        switch row {
        case .language:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.languageChoices(settings.availableLanguages),
                selected: settings.selectedLanguage
            ) { code in
                PhoneSettingsModel.chooseLanguage(code, in: settings)
                noteChange()
            }
        case .voice:
            PhoneChoiceSheet(
                title: row.title,
                choices: voiceOffer.choices,
                selected: settings.selectedVoiceID
            ) { identifier in
                settings.selectedVoiceID = identifier
                noteChange()
            }
        case .textNavigationUnit:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.textNavigationUnitChoices,
                selected: textNavigationUnit
            ) { unit in
                PhoneDefaults.setTextNavigationUnit(unit, in: TextMouthRuntime.current.preferences)
                noteChange()
            }
        case .audioNavigationUnit:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.audioNavigationUnitChoices,
                selected: audioNavigationUnit
            ) { unit in
                PhoneDefaults.setAudioNavigationUnit(unit, in: TextMouthRuntime.current.preferences)
                noteChange()
            }
        case .rewindTo:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.rewindChoices,
                selected: settings.rewindOnResumeUnit
            ) { unit in
                settings.rewindOnResumeUnit = unit
                noteChange()
            }
        case .endOfBook:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.endOfBookChoices,
                selected: settings.endOfBookBehavior
            ) { behavior in
                settings.endOfBookBehavior = behavior
                noteChange()
            }
        case .shareLogs:
            if let logsFile {
                PhoneLogShareSheet(file: logsFile) { openRow = nil }
            }
        case .readingStatistics:
            EmptyView()
        }
    }

    /// Opens what `row` opens.
    private func open(_ row: PhoneSettingsRow) {
        lastOpenedRow = row
        openRow = row
    }

    /// Returns focus to the row whose sheet just closed.
    private func returnFocusToLastOpenedRow() {
        guard let lastOpenedRow else { return }
        returnFocus(to: lastOpenedRow)
    }

    /// Asks for VoiceOver's focus on `row`, once what covered it has gone.
    /// Sheets don't return focus by themselves (the spec, under "Focus on
    /// arrival and return"); `PhoneListFocus.focus` waits for VoiceOver to land
    /// first, since a request made at once is lost.
    private func returnFocus(to row: PhoneSettingsRow) {
        refocusRequest = row
    }

    // MARK: - The Actions

    /// Speaks the preview in the voice, speed, and pitch chosen, cutting off
    /// the last one, as the Mac's does, with the book paused while it speaks.
    private func previewVoice() {
        let speaker = preview ?? PhoneSettingsVoicePreview(pauseBook: pauseBookForPreview, audioMayStart: audioMayStart)
        preview = speaker
        speaker.speak(
            PhoneSettingsModel.previewUtterance(
                voiceID: settings.selectedVoiceID,
                wordsPerMinute: settings.wordsPerMinute,
                pitch: settings.pitchMultiplier
            )
        )
    }

    /// Gathers the logs, off the main thread, and offers them. A press while
    /// they're being gathered does nothing.
    private func shareLogs() {
        guard !isGatheringLogs else { return }
        isGatheringLogs = true
        Task {
            defer { isGatheringLogs = false }
            do {
                logsFile = try await PhoneLogExport.gather()
                open(.shareLogs)
            } catch {
                logsFailure = error.localizedDescription
            }
        }
    }

    // MARK: - What the Rows Read

    /// What the Voice row offers and says, from the model's voices.
    private var voiceOffer: PhoneSettingsVoiceOffer {
        PhoneSettingsVoiceOffer(
            current: settings.selectedVoice.map { PhoneVoiceOption($0) },
            forLanguage: settings.availableVoices.map { PhoneVoiceOption($0) },
            installed: settings.voiceCatalog.voices.map { PhoneVoiceOption($0) },
            hasListed: settings.voiceCatalog.isLoaded
        )
    }

    /// Counts a change made on this screen, so it redraws (see `changeCount`).
    private func noteChange() {
        changeCount &+= 1
    }

    /// `binding`, which also counts each change made through it. The change
    /// itself goes through the model's property, by its key path, so its
    /// validation and its `didSet` both run.
    private func noted<Value: Sendable>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                noteChange()
            }
        )
    }

    /// What a text book moves by until it has a unit of its own, as kept in
    /// `PhoneDefaults`, in the app's preferences.
    private var textNavigationUnit: SkipUnit {
        PhoneSettingsModel.textNavigationUnit(in: TextMouthRuntime.current.preferences)
    }

    /// What an audiobook moves by until it has a unit of its own.
    private var audioNavigationUnit: SkipUnit {
        PhoneSettingsModel.audioNavigationUnit(in: TextMouthRuntime.current.preferences)
    }

    /// Follow in Braille, as kept in `PhoneDefaults`, counting each change so
    /// the screen redraws.
    private var followsInBraille: Binding<Bool> {
        Binding(
            get: { PhoneDefaults.followInBraille(in: TextMouthRuntime.current.preferences) },
            set: { isOn in
                PhoneDefaults.setFollowInBraille(isOn, in: TextMouthRuntime.current.preferences)
                noteChange()
            }
        )
    }

    /// "Confirm before removing a book", through the model the Mac's toggle
    /// uses, which publishes its own changes.
    private var confirmsBeforeRemoving: Binding<Bool> {
        Binding(
            get: { removal.preferences.confirmsFirst },
            set: { removal.setConfirmsFirst($0) }
        )
    }

    /// Whether the alert saying the logs couldn't be gathered is up. Focus
    /// returns to the button when it's closed.
    private var isShowingLogsFailure: Binding<Bool> {
        Binding(
            get: { logsFailure != nil },
            set: { isShowing in
                guard !isShowing else { return }
                logsFailure = nil
                returnFocus(to: .shareLogs)
            }
        )
    }
}

/// Makes a slider or a stepper one adjustable element for VoiceOver, saying
/// its label, its value with its unit, and its caption as its hint, whose flick
/// up or down moves one step of the Mac's.
///
/// Apple doesn't document how VoiceOver sees either control, or how far a flick
/// moves a slider; flicks commonly move a slider 10 percent (REPORTED, AppleVis,
/// in the spec's research). Hiding what's inside and giving one explicit action
/// leaves nothing to chance: Apple's `AccessibilityChildBehavior.ignore` hides
/// the children, and `accessibilityAdjustableAction` adds the adjustable trait,
/// since SwiftUI's `AccessibilityTraits` has no way to name it in this SDK.
/// The action sets the value before it returns, since a value set later can be
/// read stale (REPORTED, in the same research).
private struct SteppedAdjustment: ViewModifier {
    /// The setting's words and steps.
    let adjustment: PhoneSettingsAdjustment
    /// The setting's value.
    let value: Binding<Double>
    /// False while the setting does nothing: dimmed, it doesn't move, even by
    /// an action that `.disabled` isn't documented to stop.
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(adjustment.label)
            .accessibilityValue(adjustment.words(value.wrappedValue))
            .accessibilityHint(adjustment.hint)
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                switch direction {
                case .increment:
                    value.wrappedValue = adjustment.value(after: value.wrappedValue, going: .up)
                case .decrement:
                    value.wrappedValue = adjustment.value(after: value.wrappedValue, going: .down)
                @unknown default:
                    break
                }
            }
    }
}
