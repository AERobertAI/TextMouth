import AVFoundation
import SwiftUI

/// The phone's Voice & Speed sheet, or an audiobook's Audio Settings (the
/// iPhone interface spec, "The Voice & Speed sheet"), rebuilt with the Mac's
/// words: Language and Voice, each a row opening `PhoneChoiceSheet`; Preview
/// Voice; the Speed and Pitch sliders; When this book ends; then Save to
/// Global Settings and Reset to Global Settings. An audiobook's has Audio
/// speed, When this book ends, and Reset to Normal Speed.
///
/// Thin over `PhoneVoiceModel`. The settings are the reader's, set through
/// its own functions, as the Mac's sheet sets them; the sheet keeps its own
/// copy of what they are, read again after each change, so it never observes
/// the reader as the book plays.
struct PhoneVoiceSheet: View {
    /// The reader whose voice and speed the sheet sets.
    let reader: ReaderViewModel
    /// What the sheet leaves to say once it has closed.
    let farewell: PhoneSheetFarewell
    /// Pauses the book that plays for Preview Voice, and gives what plays it
    /// on (`PhoneSession.pauseBookForPreview`).
    let pauseBookForPreview: PhoneSettingsVoicePreview.PauseBook?

    /// The voices and choices offered.
    @State private var model: PhoneVoiceModel
    /// The reader's settings as the sheet shows them.
    @State private var shown: Shown
    /// Whether the voices have been listed.
    @State private var voicesListed = VoiceCatalog.shared.isLoaded
    /// The list of choices open over the sheet, if any.
    @State private var choosing: Choosing?
    /// The list of choices last opened, for the return of focus.
    @State private var lastChoosing: Choosing?
    /// What a choice leaves to say once its list has closed.
    @State private var choiceFarewell = PhoneSheetFarewell()
    /// Where VoiceOver's focus is asked to go.
    @AccessibilityFocusState private var focus: Choosing?
    /// Speaks Preview Voice, made at the first preview and kept so that a
    /// second one takes the first's place, as Settings' preview does.
    @State private var preview: PhoneSettingsVoicePreview?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`, its preview
    /// pausing the book with `pauseBookForPreview`.
    init(
        reader: ReaderViewModel,
        farewell: PhoneSheetFarewell,
        pauseBookForPreview: PhoneSettingsVoicePreview.PauseBook? = nil
    ) {
        self.reader = reader
        self.farewell = farewell
        self.pauseBookForPreview = pauseBookForPreview
        _model = State(initialValue: PhoneVoiceModel(reader: reader))
        _shown = State(initialValue: Shown(reader))
    }

    /// The reader's settings as the sheet shows them, read from the reader.
    struct Shown {
        /// Whether the book is an audiobook.
        let isAudioBook: Bool
        /// The book's voice's identifier, if it has one.
        let voiceIdentifier: String?
        /// A text book's speed, in words per minute.
        let wordsPerMinute: Double
        /// A text book's pitch.
        let pitch: Double
        /// An audiobook's speed, as a multiple.
        let audioSpeed: Double
        /// What happens when the book ends.
        let endOfBook: EndOfBookBehavior
        /// Whether the book has an end-of-book choice of its own.
        let hasOwnEndOfBook: Bool
        /// Whether the book has settings of its own to reset.
        let hasOwnSettings: Bool

        /// The settings `reader` has now.
        @MainActor
        init(_ reader: ReaderViewModel) {
            isAudioBook = reader.isAudioBook
            voiceIdentifier = reader.speechService.currentVoice?.identifier
            wordsPerMinute = reader.speechService.wordsPerMinute
            pitch = reader.speechService.pitchMultiplier
            audioSpeed = reader.audioSpeed
            endOfBook = reader.effectiveEndOfBookBehavior
            hasOwnEndOfBook = reader.book.localEndOfBookBehavior != nil
            hasOwnSettings = reader.hasLocalSettings
        }
    }

    /// Which list of choices is open over the sheet, and which row VoiceOver's
    /// focus returns to.
    enum Choosing: String, Identifiable, Sendable {
        /// The Language row's.
        case language
        /// The Voice row's.
        case voice
        /// The When this book ends row's.
        case endOfBook

        /// The list itself, for `sheet(item:)`.
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                if shown.isAudioBook {
                    audioSpeedSection
                } else {
                    voiceSection
                    sliders
                }
                endOfBookSection
                globalSection
            }
            .navigationTitle(BookSettingsWording.heading(isAudioBook: shown.isAudioBook))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneAppWording.close) { dismiss() }
            }
            .sheet(item: $choosing, onDismiss: afterChoosing) { list in
                choices(for: list)
            }
            // A preview still speaking as the sheet closes stops, and the
            // book it paused plays on, rather than staying paused for a
            // preview nobody hears out.
            .onDisappear { preview?.stop() }
            .task {
                guard !shown.isAudioBook else { return }
                VoiceCatalog.shared.loadIfNeeded()
                await VoiceCatalog.shared.waitUntilListed()
                model = PhoneVoiceModel(reader: reader)
                voicesListed = VoiceCatalog.shared.isLoaded
            }
        }
    }

    // MARK: A text book's voice

    /// Language, Voice, and Preview Voice, or the sentence for no voices.
    @ViewBuilder
    private var voiceSection: some View {
        Section {
            if model.saysNoVoices(isLoaded: voicesListed) {
                Text(PhoneVoiceWording.noVoices)
            } else {
                choiceRow(.language, label: PhoneVoiceVocabulary.languageFilterLabel, value: model.languageValue())
                choiceRow(
                    .voice,
                    label: PhoneVoiceVocabulary.voiceLabel,
                    value: model.voiceValue(identifier: shown.voiceIdentifier) ?? ""
                )
                PhoneActionButton(title: PhoneVoiceVocabulary.previewTitle, action: previewVoice)
                    .accessibilityLabel(PhoneVoiceVocabulary.previewLabel)
            }
        }
    }

    /// The Speed and Pitch sliders, each read by its value in words.
    @ViewBuilder
    private var sliders: some View {
        Section {
            Slider(
                value: Binding(get: { shown.wordsPerMinute }, set: { setSpeed($0) }),
                in: PhoneVoiceModel.speedRange,
                step: PhoneVoiceModel.speedStep
            ) {
                Text(PhoneVoiceVocabulary.speedLabel)
            }
            // The label closure above is the label: given again, as the
            // simulator showed, it is read "Speed, Speed".
            .accessibilityValue(PhoneVoiceVocabulary.speedValue(wordsPerMinute: shown.wordsPerMinute))
        }
        Section {
            Slider(
                value: Binding(get: { shown.pitch }, set: { setPitch($0) }),
                in: PhoneVoiceModel.pitchRange,
                step: PhoneVoiceModel.pitchStep
            ) {
                Text(PhoneVoiceVocabulary.pitchLabel)
            }
            .accessibilityValue(SpeechService.pitchLabel(shown.pitch))
        }
    }

    // MARK: An audiobook's speed

    /// The Mac's Audio speed slider, read as "Audio speed, 1.25 times speed".
    private var audioSpeedSection: some View {
        Section {
            Slider(
                value: Binding(get: { shown.audioSpeed }, set: { setAudioSpeed($0) }),
                in: AudioSpeed.range,
                step: AudioSpeed.fineStep
            ) {
                Text(BookSettingsWording.audioSpeedLabel)
            }
            .accessibilityValue(AudioSpeed.spokenLabel(for: shown.audioSpeed))
            .accessibilityHint(AudioSpeed.stepHint(AudioSpeed.fineStep))
        }
    }

    // MARK: When this book ends, and the global settings

    /// When this book ends, a row opening its choices.
    private var endOfBookSection: some View {
        Section {
            choiceRow(
                .endOfBook,
                label: PhoneVoiceVocabulary.endOfBookLabel,
                value: PhoneVoiceModel.endOfBookValue(effective: shown.endOfBook)
            )
        }
    }

    /// Save to Global Settings, a text book's alone, and the Reset button,
    /// which stays in its place and is dimmed while the book has no settings
    /// of its own, so nothing appears or vanishes as settings change.
    private var globalSection: some View {
        Section {
            if !shown.isAudioBook {
                PhoneActionButton(title: BookSettingsWording.saveButtonTitle) {
                    sayAfterwards { reader.saveSettingsToGlobal() }
                }
                .accessibilityLabel(BookSettingsWording.saveAsDefaultsLabel)
                .accessibilityHint(BookSettingsWording.saveAsDefaultsHint)
            }
            PhoneActionButton(title: BookSettingsWording.resetButtonTitle(isAudioBook: shown.isAudioBook)) {
                sayAfterwards { reader.resetToGlobalSettings() }
            }
            .disabled(!shown.hasOwnSettings)
            .accessibilityLabel(BookSettingsWording.resetLabel(isAudioBook: shown.isAudioBook))
            .accessibilityHint(BookSettingsWording.resetHint(isAudioBook: shown.isAudioBook))
        }
    }

    // MARK: The rows of choices

    /// A row named `label`, its value `value`, that opens the list `list`.
    private func choiceRow(_ list: Choosing, label: String, value: String) -> some View {
        PhoneActionButton(title: label) {
            lastChoosing = list
            choosing = list
        }
        .accessibilityValue(value)
        .accessibilityFocused($focus, equals: list)
    }

    /// The list of choices `list` names, each closing it as it's made.
    @ViewBuilder
    private func choices(for list: Choosing) -> some View {
        switch list {
        case .language:
            PhoneChoiceSheet(
                title: PhoneVoiceVocabulary.languageFilterLabel,
                choices: model.languageChoices(),
                selected: model.selectedLanguage
            ) { language in
                model.selectedLanguage = language
            }
        case .voice:
            PhoneChoiceSheet(
                title: PhoneVoiceVocabulary.voiceLabel,
                choices: model.voiceChoices,
                selected: shown.voiceIdentifier
            ) { identifier in
                guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { return }
                keepForAfterChoosing { reader.setLocalVoice(voice) }
            }
        case .endOfBook:
            // The book's own choice, or nil, Use Global Default's, as the
            // choice selected: never no choice at all.
            let current: EndOfBookBehavior? = shown.hasOwnEndOfBook ? shown.endOfBook : nil
            PhoneChoiceSheet(
                title: PhoneVoiceVocabulary.endOfBookTitle,
                choices: PhoneVoiceModel.endOfBookChoices,
                selected: .some(current)
            ) { behavior in
                keepForAfterChoosing { reader.setLocalEndOfBookBehavior(behavior) }
            }
        }
    }

    /// Runs `change` on the reader, keeping what it said for once the list
    /// of choices has closed, and reads the settings again.
    private func keepForAfterChoosing(_ change: () -> Void) {
        let said = VoiceOverAnnouncer.collectingAnnouncements(during: change)
        choiceFarewell.keep(said.map(\.message))
        shown = Shown(reader)
    }

    /// A list of choices has closed: focus returns to its row, and what the
    /// choice said is said after.
    private func afterChoosing() {
        let target = lastChoosing
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = target
        }
        choiceFarewell.sheetDidClose()
    }

    // MARK: The sliders' changes

    /// Sets a text book's speed, by the reader's own step, as the Mac's
    /// slider does. VoiceOver reads the slider's new value itself, so the
    /// reader's spoken speed isn't also said (the spec, under "Speed").
    private func setSpeed(_ requested: Double) {
        let delta = PhoneVoiceModel.steppedSpeed(requested) - reader.speechService.wordsPerMinute
        guard abs(delta) >= 1 else { return }
        VoiceOverAnnouncer.collectingAnnouncements {
            reader.adjustSpeed(delta: delta)
        }
        shown = Shown(reader)
    }

    /// Sets a text book's pitch, as the Mac's slider does, its spoken pitch
    /// left to the slider's value.
    private func setPitch(_ requested: Double) {
        let pitch = PhoneVoiceModel.steppedPitch(requested)
        guard abs(pitch - reader.speechService.pitchMultiplier) >= 0.05 else { return }
        VoiceOverAnnouncer.collectingAnnouncements {
            reader.adjustPitch(to: pitch)
        }
        shown = Shown(reader)
    }

    /// Sets an audiobook's speed through the reader's own setter, as the
    /// Mac's slider does, its spoken speed left to the slider's value.
    private func setAudioSpeed(_ requested: Double) {
        VoiceOverAnnouncer.collectingAnnouncements {
            reader.setAudioSpeed(requested)
        }
        shown = Shown(reader)
    }

    // MARK: Buttons

    /// Runs `change` on the reader, says what it said a moment later, and
    /// reads the settings again.
    private func sayAfterwards(_ change: () -> Void) {
        let said = VoiceOverAnnouncer.collectingAnnouncements(during: change)
        PhoneAnnouncer.say(inOrder: said.map(\.message))
        shown = Shown(reader)
    }

    /// Speaks the Mac's sample in the voice, speed, and pitch chosen, as the
    /// Mac's Preview Voice does, through the same speaker as Settings'
    /// (`PhoneSettingsVoicePreview`): it asks the audio session first, as a
    /// reader's Play does, pauses the book that plays, and plays it on once
    /// the sample ends.
    private func previewVoice() {
        let speaker = preview ?? PhoneSettingsVoicePreview(
            pauseBook: pauseBookForPreview,
            audioMayStart: { PhoneAudioSession.shared.audioMayStart() }
        )
        preview = speaker
        let utterance = AVSpeechUtterance(string: PhoneVoiceVocabulary.previewSentence)
        utterance.voice = reader.speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(reader.speechService.wordsPerMinute)
        utterance.pitchMultiplier = Float(SpeechService.clampedPitch(reader.speechService.pitchMultiplier))
        speaker.speak(utterance)
    }
}
