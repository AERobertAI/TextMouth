import SwiftUI

/// The Record window (FR04): choose a microphone, title and place the
/// recording, then Record, Pause or Resume, and Stop, which saves it as an
/// audiobook.
///
/// Every control is a native one with an explicit label, value, and hint
/// from `RecordingWording`, so VoiceOver and a braille display meet the same
/// words the screen shows, in a plain form whose sections VoiceOver reads in
/// order, and Tab reaches every control. VoiceOver starts on the Microphone
/// pop-up. Record, Pause or Resume, and Stop answer Command-R, Command-P,
/// and Command-Period, which nothing else in TextMouth uses. The elapsed time
/// and the level are text that changes once a second and is read when the
/// user moves to it, never spoken on its own; the drawn meter beside the
/// level is for sighted helpers and hidden from VoiceOver.
struct RecordingWindowView: View {
    /// What the window shows and does.
    @ObservedObject var model: RecordingWindowModel
    /// The recorder, observed too, so the buttons follow its state at once.
    @ObservedObject private var service: RecordingService

    /// The window's view for `model`.
    init(model: RecordingWindowModel) {
        self.model = model
        service = model.service
    }

    var body: some View {
        Form {
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
        .modifier(InitialVoiceOverFocusModifier(isTarget: true))
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

    /// Record, Pause or Resume, and Stop, each with its shortcut.
    private var controlButtons: some View {
        HStack {
            Button(RecordingWording.recordTitle) {
                Task { await model.record() }
            }
            .keyboardShortcut(RecordingShortcuts.record)
            .disabled(!model.canRecord)
            .accessibilityHint(RecordingWording.recordHint(device: model.selectedDevice?.name))
            .help(RecordingWording.recordHint(device: model.selectedDevice?.name))

            Button(isPaused ? RecordingWording.resumeTitle : RecordingWording.pauseTitle) {
                Task { await model.togglePause() }
            }
            .keyboardShortcut(RecordingShortcuts.pauseOrResume)
            .disabled(!model.canPause)
            .accessibilityHint(isPaused ? RecordingWording.resumeHint : RecordingWording.pauseHint)
            .help(isPaused ? RecordingWording.resumeHint : RecordingWording.pauseHint)

            Button(RecordingWording.stopTitle) {
                Task { await model.stop() }
            }
            .keyboardShortcut(RecordingShortcuts.stop)
            .disabled(!model.canStop)
            .accessibilityHint(RecordingWording.stopHint)
            .help(RecordingWording.stopHint)
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

// MARK: - Shortcuts

/// The Record window's keyboard shortcuts: Command with R, P, and Period,
/// which no menu command and no default shortcut of the reader or the
/// library uses (the tests check both).
enum RecordingShortcuts {
    static let record = KeyboardShortcut("r", modifiers: .command)
    static let pauseOrResume = KeyboardShortcut("p", modifiers: .command)
    static let stop = KeyboardShortcut(".", modifiers: .command)
    /// File > New Recording…: Option-Command-N, beside Command-N for a new
    /// Library window.
    static let newRecording = KeyboardShortcut("n", modifiers: [.option, .command])
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
