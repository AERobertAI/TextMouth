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
    /// An interface language chosen in its sheet, held until the sheet has
    /// closed. Switching at once flips the window's reading direction and
    /// words the screen again while the dismissal is still under way, which
    /// could leave the sheet open (the Arabic-to-System picker test).
    @State private var pendingInterfaceLanguage: InterfaceLanguageChoice?
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
    /// The person's own interface lines and what reading their file came to (FR39); the screen is drawn again when it changes.
    @ObservedObject private var overrides = InterfaceTextOverrides.shared
    /// The export of the interface text, while the system's file exporter is up.
    @State private var interfaceTextExport: InterfaceTextExportDocument?
    /// Whether the file exporter is up.
    @State private var isExportingInterfaceText = false
    /// Whether the alert saying the interface text could not be exported is up.
    @State private var exportFailed = false

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
                            .accessibilityAddTraits(.isHeader)
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
        // Export Interface Text…: the system's file exporter, where the person chooses a place for the file.
        .fileExporter(
            isPresented: $isExportingInterfaceText,
            document: interfaceTextExport,
            contentTypes: [.json],
            defaultFilename: InterfaceTextOverrides.exportFileName(language: InterfaceLanguage.current.language),
            onCompletion: { finishInterfaceTextExport(InterfaceTextExportOutcome($0)) },
            // A cancel never reaches `onCompletion`: without this, focus would not come back and the document would stay.
            onCancellation: { finishInterfaceTextExport(.cancelled) }
        )
        // An export that failed is an alert, as the failure of Share Logs is, and not only a sentence VoiceOver speaks.
        .alert(PhoneSettingsRow.exportInterfaceText.title, isPresented: isShowingExportFailure) {
        } message: {
            Text(InterfaceTextOverridesWording.exportFailed)
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
            PhoneActionButton(title: Words.previewVoice.title, action: previewVoice)
                .accessibilityLabel(Words.previewSelectedVoice.title)
            sliderRow(.defaultSpeed, value: noted($settings.wordsPerMinute))
            sliderRow(.defaultPitch, value: noted($settings.pitchMultiplier))
        case .navigation:
            choiceRow(.textNavigationUnit, value: textNavigationUnit.title)
            choiceRow(.audioNavigationUnit, value: audioNavigationUnit.title)
            switchRow(.autoPlayAfterNavigation, isOn: noted($settings.autoPlayOnNavigate))
        case .rewindOnResume:
            choiceRow(.rewindTo, value: settings.rewindOnResumeUnit.title)
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
            choiceRow(.endOfBook, value: settings.endOfBookBehavior.title)
            // Left where VoiceOver and braille can read it, as on the Mac: the
            // row has a hint of its own, so this isn't said as one.
            readableCaption(EndOfBookWording.playOnAFinishedBookCaption)
        case .sleepTimer:
            stepperRow(.fadeOutDuration, value: noted($settings.sleepFadeOutDuration))
            switchRow(.closeSleepTimerSheet, isOn: noted($settings.sleepTimerAutoClose))
            switchRow(.shakeToRestartTimer, isOn: shakeRestartsSleepTimer)
        case .times:
            switchRow(.includeSpeedWithTimes, isOn: noted($settings.includeSpeedWithTimes))
        case .pages:
            switchRow(.showPageInReader, isOn: noted($settings.showsPageInReader))
            switchRow(.sayPageInWhereAmI, isOn: noted($settings.saysPageInWhereAmI))
        case .reading:
            switchRow(.followInBraille, isOn: followsInBraille)
        case .braille:
            // The table braille files are read with from now on, a row opening the tables of every language, then the
            // characters a BRF or BRL file is read in, and whether a new book's code is guessed (FR32).
            choiceRow(.brailleTable, value: PhoneSettingsModel.brailleTableValue(settings.brailleTable))
            // Left where VoiceOver and braille can read it, as the End of Book caption is.
            readableCaption(PhoneSettingsWording.brailleCaption)
            // A chosen table that only writes braille is said so, in the words the Mac's Braille tab uses.
            if PhoneSettingsModel.brailleTableWritesOnly(settings.brailleTable) {
                readableCaption(BrailleSettingsWording.source(
                    ofTable: settings.brailleTable, isOffered: false, macLiblouisVersion: nil, writesOnly: true
                ))
            }
            choiceRow(.brailleFileCode, value: PhoneSettingsModel.brailleFileCodeName(settings.brailleFileCode))
            switchRow(.guessBrailleTable, isOn: noted($settings.guessesBrailleTable))
        case .removalBehavior:
            switchRow(.confirmBeforeRemoving, isOn: confirmsBeforeRemoving)
        case .statistics:
            statisticsRow
        case .interfaceLanguage:
            let options = InterfaceLanguagePicker.options()
            choiceRow(.interfaceLanguage, value: InterfaceLanguagePicker.option(for: interfaceLanguageChoice, in: options)?.label ?? "")
            // Left where VoiceOver and braille can read it, as the End of Book caption is.
            readableCaption(InterfaceLanguagePickerWording.launchNote)
            ownLinesRows
        case .about:
            versionRow
            shareLogsRow
        case .sync:
            // Its own view: the folder picker, the confirmation, and the failures are its own, and so is the focus they return.
            PhoneSyncSettingsSection()
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
    private func sliderRow(_ adjustment: PhoneSettingsAdjustment, value: Binding<Double>) -> some View {
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

    /// A stepper, showing its label and value, with its caption below for the
    /// eye. VoiceOver hears each of those once, from the stepper itself.
    private func stepperRow(
        _ adjustment: PhoneSettingsAdjustment,
        value: Binding<Double>,
        isEnabled: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: value, in: adjustment.range, step: adjustment.step) {
                PhoneValueRow(name: adjustment.label, value: adjustment.words(value.wrappedValue))
            }
            .modifier(SteppedAdjustment(adjustment: adjustment, value: value, isEnabled: isEnabled))
            caption(adjustment.hint)
        }
        .disabled(!isEnabled)
    }

    /// A switch, with its hint below it for the eye where the Mac shows one.
    private func switchRow(_ item: PhoneSettingsSwitch, isOn: Binding<Bool>, isEnabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The label takes the height its words need at any text size, and a little more (`phoneWholeWords`).
            Toggle(isOn: isOn) {
                Text(item.title)
                    .phoneWholeWords()
            }
            .accessibilityLabel(item.label)
                .accessibilityHint(item.hint ?? "")
            if item.showsHintAsCaption, let hint = item.hint {
                caption(hint)
            }
        }
        .disabled(!isEnabled)
    }

    /// Words in the small type of the Mac's captions that VoiceOver and braille read where they stand (a caption that is not a
    /// control's hint), with the height they need at any text size (`PhoneReadableCaption`).
    private func readableCaption(_ words: String) -> some View {
        PhoneReadableCaption(words)
    }

    /// Words for the eye, in the small type of the Mac's captions, and hidden
    /// from VoiceOver, which hears them once, as the control's hint (the Mac's
    /// rule).
    private func caption(_ words: String) -> some View {
        readableCaption(words).accessibilityHidden(true)
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

    /// The person's own interface lines (FR39), under Interface Language: how many are in use and how many are ignored, each
    /// problem as a sentence with its reason last, and the Export Interface Text… button. The sentences are static text, so
    /// VoiceOver and a braille display read each where it is.
    @ViewBuilder
    private var ownLinesRows: some View {
        let summary = InterfaceTextOverridesSummary(overrides.outcome)
        Text(summary.inUse).phonePrimaryText()
        Text(summary.ignored).phonePrimaryText()
        ForEach(Array(summary.details.enumerated()), id: \.offset) { _, sentence in
            readableCaption(sentence)
        }
        let row = PhoneSettingsRow.exportInterfaceText
        PhoneActionButton(title: row.title, action: exportInterfaceText)
            .accessibilityHint(row.hint ?? "")
            .accessibilityFocused($focusedRow, equals: row)
            .id(row)
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
        case .interfaceLanguage:
            PhoneChoiceSheet(
                title: row.title,
                choices: InterfaceLanguagePicker.options().map { PhoneChoice(id: $0.choice, label: $0.label) },
                selected: interfaceLanguageChoice
            ) { choice in
                // Applied in `onDismiss`, once the sheet is gone.
                pendingInterfaceLanguage = choice
            }
        case .brailleTable:
            PhoneChoiceSheet(
                title: row.title,
                groups: PhoneSettingsModel.brailleTableGroups(),
                // Spelled as the list's rows are, so a Mac's `mac:fr-bfu-g2.ctb` marks the pack's `fr-bfu-g2.ctb` row.
                selected: PhoneSettingsModel.brailleTableSelection(settings.brailleTable)
            ) { id in
                settings.brailleTable = id
                noteChange()
            }
        case .brailleFileCode:
            PhoneChoiceSheet(
                title: row.title,
                choices: PhoneSettingsModel.brailleFileCodeChoices,
                selected: settings.brailleFileCode
            ) { id in
                settings.brailleFileCode = id
                noteChange()
            }
        case .shareLogs:
            if let logsFile {
                PhoneShareSheet(files: [logsFile]) { openRow = nil }
            }
        case .readingStatistics, .exportInterfaceText:
            // Pushed, or presented by the system's file exporter (`.fileExporter` below): never a sheet of this screen's.
            EmptyView()
        }
    }

    /// Opens what `row` opens.
    private func open(_ row: PhoneSettingsRow) {
        lastOpenedRow = row
        openRow = row
    }

    /// Returns focus to the row whose sheet just closed.
    /// First applies an interface language chosen in the sheet, now that it has closed, so the switch never
    /// overlaps the dismissal; the switch is then announced as before.
    private func returnFocusToLastOpenedRow() {
        if let choice = pendingInterfaceLanguage {
            pendingInterfaceLanguage = nil
            InterfaceLanguagePicker.apply(choice)
            noteChange()
        }
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

    /// Export Interface Text…: makes the file of every line of the interface language as it reads now, and offers it to the
    /// system's file exporter. Say so when there is nothing to export.
    private func exportInterfaceText() {
        guard let data = overrides.exportData() else {
            InterfaceTextOverrides.logExportFailure("there is no pack to export from") // l10n: no (debug log text)
            exportFailed = true
            return
        }
        interfaceTextExport = InterfaceTextExportDocument(data: data)
        isExportingInterfaceText = true
    }

    /// The file exporter finished, or was cancelled: tells how it went (a cancel says nothing), lets go of the document, and
    /// brings focus back to the button, unless an alert is up, whose closing does.
    private func finishInterfaceTextExport(_ outcome: InterfaceTextExportOutcome) {
        interfaceTextExport = nil
        switch outcome {
        case .exported(let fileName):
            VoiceOverAnnouncer.announce(InterfaceTextOverridesWording.exported(fileName: fileName))
        case .cancelled:
            break
        case .failed(let reason):
            InterfaceTextOverrides.logExportFailure(reason)
            exportFailed = true
            return
        }
        returnFocus(to: .exportInterfaceText)
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

    /// The interface language chosen: what is stored in the app's domain of `AppleLanguages`, which includes a choice made
    /// in the iPhone's own Settings.
    private var interfaceLanguageChoice: InterfaceLanguageChoice {
        InterfaceLanguageStore().choice()
    }

    /// What an audiobook moves by until it has a unit of its own.
    private var audioNavigationUnit: SkipUnit {
        PhoneSettingsModel.audioNavigationUnit(in: TextMouthRuntime.current.preferences)
    }

    /// Follow in Braille, as kept in `PhoneDefaults`.
    private var followsInBraille: Binding<Bool> {
        phonePreference(get: PhoneDefaults.followInBraille(in:), set: PhoneDefaults.setFollowInBraille(_:in:))
    }

    /// Shake to restart the timer (FR55), as kept in `PhoneDefaults`.
    private var shakeRestartsSleepTimer: Binding<Bool> {
        phonePreference(get: PhoneDefaults.shakeRestartsSleepTimer(in:), set: PhoneDefaults.setShakeRestartsSleepTimer(_:in:))
    }

    /// A switch over one of the phone's own preferences in `PhoneDefaults`,
    /// read and kept in the app's preferences by `get` and `set`, counting
    /// each change so the screen redraws.
    private func phonePreference(
        get: @escaping @MainActor (UserDefaults) -> Bool,
        set: @escaping @MainActor (Bool, UserDefaults) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { get(TextMouthRuntime.current.preferences) },
            set: { isOn in
                set(isOn, TextMouthRuntime.current.preferences)
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

    /// Whether the alert saying the interface text could not be exported is up. Focus returns to the button when it's closed.
    private var isShowingExportFailure: Binding<Bool> {
        Binding(
            get: { exportFailed },
            set: { isShowing in
                guard !isShowing else { return }
                exportFailed = false
                returnFocus(to: .exportInterfaceText)
            }
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
