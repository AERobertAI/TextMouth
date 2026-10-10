import SwiftUI

/// The Record window (FR04): choose a microphone, title and place the
/// recording, then Record, Pause or Resume, and Stop, which saves it as an
/// audiobook; and, first, the recordings a crash left behind, when there
/// are any, to save or discard.
///
/// Every control is a native one with an explicit label, value, and hint
/// from `RecordingWording`, so VoiceOver and a braille display meet the same
/// words the screen shows, in a plain form whose sections VoiceOver reads in
/// order, and Tab reaches every control. VoiceOver starts on the Microphone
/// pop-up, or, in a window launch opened on recordings left behind, on the
/// first of them. Record, Pause or Resume, and Stop answer their keys in
/// force, Command-R, Command-P, and Command-Period unless changed in the
/// Shortcuts tab or config.json (FR12's branch D). The elapsed time
/// and the level are text that changes once a second and is read when the
/// user moves to it, never spoken on its own; the drawn meter beside the
/// level is for sighted helpers and hidden from VoiceOver.
struct RecordingWindowView: View {
    /// What the window shows and does.
    @ObservedObject var model: RecordingWindowModel
    /// The recorder, observed too, so the buttons follow its state at once.
    @ObservedObject private var service: RecordingService
    /// The buttons' keys in force, followed as the user changes them.
    @StateObject private var keys = StoredKeyEquivalents()

    /// The window's view for `model`.
    init(model: RecordingWindowModel) {
        self.model = model
        service = model.service
    }

    var body: some View {
        Form {
            if !model.recoveredTakes.isEmpty {
                recoveredTakesSection
            }

            Section {
                microphonePicker
                TextField(RecordingWording.titleLabel, text: $model.title)
                    .accessibilityLabel(RecordingWording.titleLabel)
                    .accessibilityHint(RecordingWording.titleHint)
                    .help(RecordingWording.titleHint)
                    .disabled(model.isSaving)
                folderPicker
            }

            Section {
                controlButtons
                Text(RecordingWording.elapsedText(model.elapsed))
                    .monospacedDigit()
                    .accessibilityLabel(RecordingWording.elapsedLabel)
                    .accessibilityValue(RecordingWording.elapsedValue(model.elapsed))
                Text(RecordingWording.levelText(model.levels))
                    .accessibilityLabel(RecordingWording.levelLabel)
                    .accessibilityValue(RecordingWording.levelValue(model.levels))
                RecordingLevelMeter(levels: service.levels)
                Toggle(
                    RecordingWording.announceLevelTitle(seconds: model.levelAnnouncementInterval),
                    isOn: $model.announcesLevel
                )
                .accessibilityHint(RecordingWording.announceLevelHint)
                .help(RecordingWording.announceLevelHint)
                Stepper(
                    value: $model.levelAnnouncementInterval,
                    in: RecordingWording.announceIntervals,
                    step: 5
                ) {
                    Text("\(RecordingWording.announceIntervalLabel): \(model.levelAnnouncementInterval)")
                }
                // A stepper's title does not become its accessibility label.
                .accessibilityLabel(RecordingWording.announceIntervalLabel)
                .accessibilityValue("\(model.levelAnnouncementInterval) seconds")
            }

            Section {
                // What is happening, in words: never the color of anything.
                Text(model.status)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                outcomeButtons
            }
        }
        // The plain form, as Settings uses: each control is an AppKit one,
        // which VoiceOver reaches directly.
        .padding()
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440)
    }

    // MARK: - Pieces

    /// The Microphone pop-up, where VoiceOver starts: the connected
    /// microphones by name, the one in use chosen. Choosing one remembers
    /// it. It cannot change while a take is under way.
    private var microphonePicker: some View {
        Picker(RecordingWording.microphoneLabel, selection: Binding(
            get: { model.selectedDeviceID },
            set: { model.chooseDevice($0) }
        )) {
            if model.devices.isEmpty {
                Text(RecordingWording.noMicrophone).tag("")
            }
            ForEach(model.devices) { device in
                Text(device.name).tag(device.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(model.devices.isEmpty || service.isRecording || service.state == .starting || model.isSaving)
        .accessibilityLabel(RecordingWording.microphoneLabel)
        .accessibilityHint(RecordingWording.microphoneHint)
        .help(RecordingWording.microphoneHint)
        .modifier(InitialVoiceOverFocusModifier(isTarget: model.recoveredTakeFocusedAtOpen == nil))
    }

    /// The takes recordings left behind, first in the window, each with
    /// Save as Audiobook and Discard. Each button names its take, since the
    /// list can hold several, so the line saying the same is hidden from
    /// VoiceOver rather than read three times. A window opened on them, as
    /// launch opens it, starts VoiceOver on the first take's Save button.
    private var recoveredTakesSection: some View {
        Section {
            ForEach(model.recoveredTakes) { recovered in
                let take = RecordingWording.recoveredTake(startedAt: recovered.startedAt, duration: recovered.duration)
                HStack {
                    Text(take)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                    Spacer()
                    Button(RecordingWording.saveRecoveredTitle) {
                        Task { await model.saveRecovered(recovered) }
                    }
                    .disabled(!model.canHandleRecoveredTakes || recovered.take == nil)
                    .accessibilityLabel(RecordingWording.saveRecoveredLabel(take))
                    .accessibilityHint(RecordingWording.saveRecoveredHint)
                    .help(RecordingWording.saveRecoveredHint)
                    .modifier(InitialVoiceOverFocusModifier(isTarget: recovered.id == model.recoveredTakeFocusedAtOpen))
                    Button(RecordingWording.discardRecoveredTitle) {
                        model.discardRecovered(recovered)
                    }
                    .disabled(!model.canHandleRecoveredTakes)
                    .accessibilityLabel(RecordingWording.discardRecoveredLabel(take))
                    .accessibilityHint(RecordingWording.discardRecoveredHint)
                    .help(RecordingWording.discardRecoveredHint)
                }
            }
        } header: {
            Text(RecordingWording.recoveredHeading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The Save in pop-up: the top of the library and each of its folders.
    private var folderPicker: some View {
        Picker(RecordingWording.folderLabel, selection: $model.folderPath) {
            ForEach(model.folders, id: \.self) { path in
                Text(RecordingWording.folderName(path)).tag(path)
            }
        }
        .pickerStyle(.menu)
        .disabled(model.isSaving)
        .accessibilityLabel(RecordingWording.folderLabel)
        .accessibilityHint(RecordingWording.folderHint)
        .help(RecordingWording.folderHint)
    }

    /// Record, Pause or Resume, and Stop, each with its key in force, which
    /// its hint names.
    private var controlButtons: some View {
        let recordKey = keys.keyEquivalent(for: .recordingRecord)
        let pauseKey = keys.keyEquivalent(for: .recordingPauseOrResume)
        let stopKey = keys.keyEquivalent(for: .recordingStop)
        let recordHint = RecordingWording.recordHint(device: model.selectedDevice?.name, key: recordKey)
        let pauseHint = isPaused ? RecordingWording.resumeHint(key: pauseKey) : RecordingWording.pauseHint(key: pauseKey)
        let stopHint = RecordingWording.stopHint(key: stopKey)
        return HStack {
            Button(RecordingWording.recordTitle) {
                Task { await model.record() }
            }
            .keyboardShortcut(recordKey?.keyboardShortcut)
            .disabled(!model.canRecord)
            .accessibilityHint(recordHint)
            .help(recordHint)

            Button(isPaused ? RecordingWording.resumeTitle : RecordingWording.pauseTitle) {
                Task { await model.togglePause() }
            }
            .keyboardShortcut(pauseKey?.keyboardShortcut)
            .disabled(!model.canPause)
            .accessibilityHint(pauseHint)
            .help(pauseHint)

            Button(RecordingWording.stopTitle) {
                Task { await model.stop() }
            }
            .keyboardShortcut(stopKey?.keyboardShortcut)
            .disabled(!model.canStop)
            .accessibilityHint(stopHint)
            .help(stopHint)
        }
    }

    /// What can be done once a take has ended: open the saved book, save
    /// again or discard a take that could not be saved, or open the privacy
    /// settings after a no.
    @ViewBuilder
    private var outcomeButtons: some View {
        switch model.phase {
        case .saved(let book):
            Button(RecordingWording.openInReaderTitle) {
                model.openInReader()
            }
            .accessibilityHint(RecordingWording.openInReaderHint(title: book.title))
        case .saveFailed:
            HStack {
                Button(RecordingWording.saveAgainTitle) {
                    Task { await model.saveAgain() }
                }
                .accessibilityHint(RecordingWording.saveAgainHint)
                Button(RecordingWording.discardTitle) {
                    Task { await model.discard() }
                }
                .accessibilityHint(RecordingWording.discardHint)
            }
        case .recordingControls, .saving:
            EmptyView()
        }
        if model.offersPrivacySettings {
            Button(RecordingWording.privacySettingsTitle) {
                model.openPrivacySettings()
            }
            .accessibilityHint(RecordingWording.privacySettingsHint)
        }
    }

    /// Whether the take is paused, so the middle button says Resume.
    private var isPaused: Bool {
        service.state == .paused
    }
}

// MARK: - The Drawn Meter

/// A bar as long as the peak level is loud, for sighted helpers. VoiceOver
/// never meets it: the Level text above says the same in words.
struct RecordingLevelMeter: View {
    /// The levels to draw, or nil for an empty bar.
    let levels: RecordingLevels?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    /// How much of the bar is filled: the peak from −60 dBFS to 0.
    var fraction: CGFloat {
        guard let peak = levels?.peak, peak.isFinite else { return 0 }
        return CGFloat(min(1, max(0, (peak + 60) / 60)))
    }

    /// Green while the level is good or quiet, orange when loud, red when
    /// too loud.
    private var color: Color {
        switch RecordingWording.loudness(peak: levels?.peak ?? -.infinity) {
        case .loud: return .orange
        case .tooLoud: return .red
        case .silent, .quiet, .good: return .green
        }
    }
}
