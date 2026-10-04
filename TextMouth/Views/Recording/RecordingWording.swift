import Foundation

/// The words of the Record window and its commands (FR04): what each
/// control shows, what VoiceOver speaks for it and a braille display shows,
/// and what the window announces. Every label, value, hint, and
/// announcement is made here, once, so the screen and VoiceOver always say
/// the same thing, and the tests check the words without a window.
enum RecordingWording {

    // MARK: - The Window and Its Commands

    /// The window's title, which VoiceOver reads as the window's name.
    static let windowTitle = "New Recording"
    /// The menu command that opens the window, in the File and Library menus.
    static let menuTitle = "New Recording…"

    // MARK: - Microphone

    /// The microphone pop-up's label.
    static let microphoneLabel = "Microphone"
    /// The microphone pop-up's hint.
    static let microphoneHint = "The microphone to record from. TextMouth remembers this choice for its own recordings; "
        + "the input macOS uses for everything else stays as it is."
    /// What the pop-up shows when no microphone is connected.
    static let noMicrophone = "No microphone connected"

    // MARK: - Title and Folder

    /// The title field's label.
    static let titleLabel = "Title"
    /// The title field's hint.
    static let titleHint = "The name the recording is saved under, as an audiobook in your library."
    /// The title a recording starts with: "Recording" and when the window
    /// opened or the last recording was saved, as New from Text names a
    /// paste.
    static func defaultTitle(at date: Date) -> String {
        TextImportPolicy.timestampedTitle("Recording", at: date)
    }

    /// The folder pop-up's label.
    static let folderLabel = "Save in"
    /// The folder pop-up's hint.
    static let folderHint = "The library folder the recording is saved in."
    /// How the folder pop-up names the library folder at `path`: "Library"
    /// for the top of the library, otherwise its path from there, its
    /// folders separated as the library shows them.
    static func folderName(_ path: String) -> String {
        path.isEmpty ? "Library" : "Library / " + path.split(separator: "/").joined(separator: " / ")
    }

    // MARK: - Buttons

    /// The Record button's title.
    static let recordTitle = "Record"
    /// The Pause button's title while recording.
    static let pauseTitle = "Pause"
    /// The same button's title while paused.
    static let resumeTitle = "Resume"
    /// The Stop button's title.
    static let stopTitle = "Stop"

    /// The Record button's hint, naming the microphone it records from and
    /// its shortcut.
    static func recordHint(device: String?) -> String {
        let source = device.map { "from \($0)" } ?? "once a microphone is connected"
        return "Starts recording \(source). Shortcut: Command-R."
    }
    /// The Pause button's hint while recording.
    static let pauseHint = "Pauses the recording; Resume continues the same recording. Shortcut: Command-P."
    /// The same button's hint while paused.
    static let resumeHint = "Continues the paused recording. Shortcut: Command-P."
    /// The Stop button's hint.
    static let stopHint = "Stops recording and saves it in your library as an audiobook. Shortcut: Command-Period."

    /// The button that opens the saved recording.
    static let openInReaderTitle = "Open in Reader"
    /// Its hint, naming the book.
    static func openInReaderHint(title: String) -> String {
        "Opens \(title) in a reader window."
    }
    /// The button that tries a failed save again.
    static let saveAgainTitle = "Save Again"
    /// Its hint.
    static let saveAgainHint = "Tries again to save the recording as an audiobook."
    /// The button that deletes a recording that could not be saved.
    static let discardTitle = "Discard Recording"
    /// Its hint.
    static let discardHint = "Deletes the recording without saving it."
    /// The button that opens the Microphone privacy settings after a no.
    static let privacySettingsTitle = "Open Privacy Settings"
    /// Its hint.
    static let privacySettingsHint = "Opens System Settings at Privacy & Security, Microphone, where TextMouth can be "
        + "allowed to use the microphone."

    // MARK: - Elapsed Time

    /// The elapsed time's label.
    static let elapsedLabel = "Elapsed"
    /// The elapsed time as the screen shows it: "Elapsed: 1:04".
    static func elapsedText(_ seconds: TimeInterval) -> String {
        "\(elapsedLabel): \(TimeFormatting.format(seconds))"
    }
    /// The elapsed time as VoiceOver speaks it: "1 minute, 4 seconds".
    static func elapsedValue(_ seconds: TimeInterval) -> String {
        TimeFormatting.spoken(seconds)
    }

    // MARK: - Level

    /// The level's label.
    static let levelLabel = "Level"

    /// How loud the microphone is, judged by its peak, for speech: the
    /// level a voice should reach is "good".
    enum Loudness: String, Equatable, Sendable {
        /// No sound at all reaches TextMouth: a muted microphone, or one
        /// macOS gives nothing.
        case silent
        /// Too quiet to be heard well.
        case quiet
        /// A voice at a good level.
        case good
        /// Loud, close to the most a recording can hold.
        case loud
        /// Too loud: peaks reach the top and are cut off.
        case tooLoud = "too loud"
    }

    /// How loud a peak of `peak` dBFS is: silent below −80, quiet below
    /// −36, good below −6, loud from −6 to −1, and too loud above −1.
    static func loudness(peak: Float) -> Loudness {
        guard peak.isFinite, peak >= -80 else { return .silent }
        switch peak {
        case ..<(-36): return .quiet
        case ..<(-6): return .good
        case ...(-1): return .loud
        default: return .tooLoud
        }
    }

    /// The level as the screen shows it: "Level: −12 dB peak, −24 dB
    /// average, good", or that nothing is measured while not recording.
    static func levelText(_ levels: RecordingLevels?) -> String {
        guard let levels else { return "\(levelLabel): not recording" }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else { return "\(levelLabel): silent" }
        return "\(levelLabel): \(decibels(levels.peak)) dB peak, \(decibels(levels.average)) dB average, \(loudness.rawValue)"
    }

    /// The level as VoiceOver speaks it and a braille display shows it: the
    /// peak in words, and how loud that is, as "minus 12 decibels, good".
    static func levelValue(_ levels: RecordingLevels?) -> String {
        guard let levels else { return "Not recording" }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else { return "Silent" }
        return "\(spokenDecibels(levels.peak)), \(loudness.rawValue)"
    }

    /// What VoiceOver says every few seconds when asked to announce the
    /// level: "Level minus 12 decibels, good".
    static func levelAnnouncement(_ levels: RecordingLevels?) -> String {
        "\(levelLabel) \(levelValue(levels).lowercasedFirst)"
    }

    /// Whether a peak of `peak` dBFS is digital silence: samples of zero, as
    /// a muted microphone, or one macOS gives nothing, delivers. Even a
    /// quiet room reads far above it.
    static func isDigitalSilence(peak: Float) -> Bool {
        !peak.isFinite || peak <= -120
    }

    /// What the window says, and VoiceOver announces, once a take has held
    /// nothing but silence for a few seconds.
    static func noSound(device: String) -> String {
        "No sound is reaching TextMouth from \(device). Check that the microphone is on and not muted."
    }

    /// A level in whole decibels as the screen shows it, with a true minus
    /// sign: "−12".
    private static func decibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        return whole < 0 ? "\u{2212}\(-whole)" : "\(whole)"
    }

    /// A level in whole decibels in words: "minus 12 decibels".
    private static func spokenDecibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        let magnitude = CountWording.phrase(abs(whole), singular: "decibel", plural: "decibels")
        return whole < 0 ? "minus \(magnitude)" : magnitude
    }

    // MARK: - Announcing the Level

    /// The level announcement switch's title.
    static func announceLevelTitle(seconds: Int) -> String {
        "Announce level every \(seconds) seconds"
    }
    /// Its hint.
    static let announceLevelHint = "While recording, VoiceOver speaks the level this often. Through speakers, "
        + "VoiceOver's speech can be recorded."
    /// The stepper choosing how often.
    static let announceIntervalLabel = "Seconds between level announcements"
    /// The intervals the stepper offers, in seconds.
    static let announceIntervals = 5...60
    /// The interval until the user picks another.
    static let defaultAnnounceInterval = 10

    // MARK: - Status and Announcements

    /// What the window says while nothing is recording.
    static func ready(device: String?) -> String {
        device.map { "Ready to record from \($0)." } ?? "Connect a microphone to record."
    }
    /// What the window says, and VoiceOver announces before capture
    /// begins, when recording starts.
    static func recording(device: String) -> String {
        "Recording from \(device)."
    }
    /// What the window says, and VoiceOver announces, once paused.
    static let paused = "Paused."
    /// What VoiceOver announces before capture resumes.
    static let resuming = "Resuming."

    /// What starting or resuming a recording says when it paused books that
    /// were playing, so the microphone would not pick them up: "Paused the
    /// book that was playing." or "Paused 2 books that were playing."; nil
    /// when it paused none.
    static func pausedReaders(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "Paused the book that was playing." : "Paused \(count) books that were playing."
    }

    /// `sentence`, after the one saying `pausedReaders` books were paused,
    /// when any were: one announcement, so VoiceOver speaks both, the books'
    /// first.
    static func afterPausingReaders(_ pausedReaders: Int, _ sentence: String) -> String {
        guard let paused = Self.pausedReaders(pausedReaders) else { return sentence }
        return "\(paused) \(sentence)"
    }
    /// What the window says while saving, and VoiceOver announces when a
    /// save takes more than a moment.
    static let saving = "Saving the recording…"
    /// What VoiceOver announces once a recording is saved.
    static func savedAnnouncement(title: String) -> String {
        "Saved Recording as \(title)"
    }
    /// What the window says once a recording is saved.
    static func saved(title: String) -> String {
        savedAnnouncement(title: title) + "."
    }
    /// What the window says, and VoiceOver announces, when a save failed.
    static func saveFailed(reason: String) -> String {
        "The recording couldn't be saved: \(reason) It is kept; choose Save Again or Discard Recording."
    }
    /// What the window says, and VoiceOver announces, when the microphone
    /// TextMouth remembers is not connected when the window opens.
    static func rememberedMicrophoneMissing(fallback: String) -> String {
        "The microphone TextMouth used last isn't connected, so recordings use \(fallback)."
    }
    /// What the window says, and VoiceOver announces, when the chosen
    /// microphone goes away while nothing is recording.
    static func microphoneDisconnected(_ name: String, fallback: String?) -> String {
        guard let fallback else { return "\(name) was disconnected. Connect a microphone to record." }
        return "\(name) was disconnected, so recordings use \(fallback)."
    }
    /// What the window says when the recording was discarded.
    static let discarded = "The recording was discarded."

    // MARK: - Recovered Recordings

    /// The heading of the takes recordings left behind, as a crash leaves
    /// one (`RecoveredTake`).
    static let recoveredHeading = "Recovered recordings"

    /// What the window says, and VoiceOver announces, when it finds takes
    /// left behind: how many, where they are listed, and what can be done
    /// with them.
    static func recoveredAnnouncement(count: Int) -> String {
        guard count != 1 else {
            return "TextMouth kept a recording from before it last quit, listed under Recovered recordings. "
                + "Save it as an audiobook, or discard it."
        }
        return "TextMouth kept \(count) recordings from before it last quit, listed under Recovered recordings. "
            + "Save each as an audiobook, or discard it."
    }

    /// A take left behind as the list shows it and VoiceOver reads it: when
    /// it was recorded and how long it lasts, as "Recording of October 4,
    /// 2026 at 6:30 AM, 1 minute, 4 seconds", or that it holds no sound.
    static func recoveredTake(startedAt: Date, duration: TimeInterval?) -> String {
        let when = startedAt.formatted(date: .long, time: .shortened)
        guard let duration, duration > 0 else { return "Recording of \(when), which holds no sound" }
        return "Recording of \(when), \(TimeFormatting.spoken(duration))"
    }

    /// The button that saves a take left behind.
    static let saveRecoveredTitle = "Save as Audiobook"
    /// Its label, naming the take, since the list can hold several.
    static func saveRecoveredLabel(_ take: String) -> String {
        "Save as Audiobook: \(take)"
    }
    /// Its hint.
    static let saveRecoveredHint = "Saves this recording as an audiobook in the folder chosen in Save in, "
        + "titled for when it was recorded."
    /// The button that deletes a take left behind.
    static let discardRecoveredTitle = "Discard"
    /// Its label, naming the take.
    static func discardRecoveredLabel(_ take: String) -> String {
        "Discard: \(take)"
    }
    /// Its hint.
    static let discardRecoveredHint = "Deletes this recording without saving it."
    /// What the window says, and VoiceOver announces, when a take left
    /// behind was discarded.
    static func recoveredDiscarded(_ take: String) -> String {
        "Discarded the \(take.lowercasedFirst)."
    }

    // MARK: - Closing While Recording

    /// The question asked when the window closes while recording.
    static let closeWhileRecordingQuestion = "Stop and save the recording?"
    /// The question asked when the window closes with a recording that
    /// could not be saved yet.
    static let closeWithUnsavedQuestion = "Save the recording?"
    /// What the question explains while recording.
    static let closeWhileRecordingExplanation = "Closing this window ends the recording. Stop and Save keeps what was "
        + "recorded as an audiobook in your library, Discard deletes it, and Cancel keeps recording."
    /// What the question explains for a recording that could not be saved.
    static let closeWithUnsavedExplanation = "This recording hasn't been saved. Save tries again to save it as an "
        + "audiobook in your library, Discard deletes it, and Cancel keeps the window open."
    /// The first, default button while recording.
    static let stopAndSaveButton = "Stop and Save"
    /// The first, default button for a recording that could not be saved.
    static let saveButton = "Save"
    /// The button that deletes the recording.
    static let discardButton = "Discard"
    /// The button that keeps the window open; it answers Escape.
    static let cancelButton = "Cancel"
}

private extension String {
    /// The string with its first letter in lower case, for a value read
    /// after a label: "Level minus 12 decibels, good".
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
