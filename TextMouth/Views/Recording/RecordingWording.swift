import Foundation

/// The words of the Record window and its commands (FR04): what each
/// control shows, what VoiceOver speaks for it and a braille display shows,
/// and what the window announces. Every label, value, hint, and
/// announcement is made here, once, so the screen and VoiceOver always say
/// the same thing, and the tests check the words without a window.
///
/// Every sentence that names one of the window's controls interpolates the
/// control's own shown name, so a translation of the control and of the
/// sentence agree (FR34).
enum RecordingWording {

    // MARK: - The Window and Its Commands

    /// The window's title, which VoiceOver reads as the window's name, and
    /// the name of its buttons' group in the Shortcuts tab
    /// (`ShortcutAction.recordingWindowCategory`). The menu command that
    /// opens it, in the File and Library menus, is named by its action
    /// (`ShortcutAction.newRecording.title`).
    static var windowTitle: String {
        // Translators: Title of the Record window, which VoiceOver reads as the window's name, and the name of its group of buttons in the Shortcuts settings.
        InterfaceText.line("common.newRecording", "New Recording")
    }

    // MARK: - Microphone

    /// The microphone pop-up's label.
    static var microphoneLabel: String {
        // Translators: Label of the pop-up in the Record window that chooses the microphone to record from.
        InterfaceText.line("recording.microphoneLabel", "Microphone")
    }
    /// The microphone pop-up's hint.
    static var microphoneHint: String {
        // Translators: VoiceOver hint and tooltip of the Microphone pop-up in the Record window. TextMouth is the app's name.
        InterfaceText.line("recording.microphoneHint", "The microphone to record from. TextMouth remembers it; the input macOS uses elsewhere is unchanged.")
    }
    /// What the pop-up shows when no microphone is connected.
    static var noMicrophone: String {
        // Translators: What the Microphone pop-up in the Record window shows when no microphone is connected.
        InterfaceText.line("recording.noMicrophone", "No microphone connected")
    }

    // MARK: - Title and Folder

    /// The title field's label.
    static var titleLabel: String {
        // Translators: Label of the field in the Record window that names the recording, which becomes the audiobook's title.
        InterfaceText.line("common.title", "Title")
    }
    /// The title field's hint.
    static var titleHint: String {
        // Translators: VoiceOver hint and tooltip of the Title field in the Record window.
        InterfaceText.line("recording.titleHint", "The audiobook's title in your library.")
    }
    /// The title a recording starts with: "Recording" and when the window
    /// opened or the last recording was saved, as New from Text names a
    /// paste.
    static func defaultTitle(at date: Date) -> String {
        TextImportPolicy.timestampedTitle(defaultTitleName, at: date)
    }

    /// The name a new recording's title starts with, before the date and time.
    private static var defaultTitleName: String {
        // Translators: The name a new recording's title starts with, followed by the date and time, such as "Recording 2026-10-04 06:30". It becomes the title of the audiobook the recording is saved as.
        InterfaceText.line("recording.defaultTitleName", "Recording")
    }

    /// The folder pop-up's label.
    static var folderLabel: String {
        // Translators: Label of the pop-up in the Record window that chooses the library folder the recording is saved in.
        InterfaceText.line("recording.folderLabel", "Save in")
    }
    /// The folder pop-up's hint.
    static var folderHint: String {
        // Translators: VoiceOver hint of the Save in pop-up of the Record window.
        InterfaceText.line("recording.folderHint", "The library folder the recording is saved in.")
    }
    /// How the folder pop-up names the library folder at `path`: "Library"
    /// for the top of the library, otherwise its path from there, its
    /// folders separated as the library shows them.
    static func folderName(_ path: String) -> String {
        guard !path.isEmpty else {
            // Translators: The top of the library, as the Save in pop-up of the Record window names it.
            return InterfaceText.line("common.library", "Library")
        }
        let folders = path.split(separator: "/").joined(separator: " / ") // l10n: no (a folder path's separator, as the library shows it)
        // Translators: A library folder in the Save in pop-up of the Record window: the library, then the folder's path, its folders separated by slashes. %@ is the path, such as "Fiction / Sci-Fi".
        return InterfaceText.line("recording.folderName", "Library / \(folders)")
    }

    // MARK: - Buttons

    /// The Record button's title.
    static var recordTitle: String {
        // Translators: Title of the button in the Record window that starts recording.
        InterfaceText.line("common.record", "Record")
    }
    /// The Pause button's title while recording.
    static var pauseTitle: String {
        // Translators: Title of the button in the Record window that pauses the recording.
        InterfaceText.line("common.pause", "Pause")
    }
    /// The same button's title while paused.
    static var resumeTitle: String {
        // Translators: Title of the button in the Record window that continues a paused recording.
        InterfaceText.line("recording.resumeTitle", "Resume")
    }
    /// The Stop button's title.
    static var stopTitle: String {
        // Translators: Title of the button in the Record window that stops recording and saves it.
        InterfaceText.line("common.stop", "Stop")
    }

    /// The Record button's hint, naming the microphone it records from and
    /// `key`, its shortcut in force (`withShortcut(_:_:)`).
    static func recordHint(device: String?, key: KeyBinding?) -> String {
        guard let device else {
            // Translators: VoiceOver hint of the Record button in the Record window while no microphone is connected.
            return withShortcut(InterfaceText.line("recording.recordHint.microphone", "Starts recording once a microphone is connected."), key)
        }
        // Translators: VoiceOver hint of the Record button in the Record window. %@ is the name of the microphone it records from.
        return withShortcut(InterfaceText.line("recording.recordHint.starts", "Starts recording from \(device)."), key)
    }
    /// The Pause button's hint while recording, naming `key`, its shortcut
    /// in force.
    static func pauseHint(key: KeyBinding?) -> String {
        // Translators: VoiceOver hint of the Pause button in the Record window. %@ is the title of the button that continues a paused recording.
        withShortcut(InterfaceText.line("recording.pauseHint", "Pauses the recording; \(resumeTitle) continues the same recording."), key)
    }
    /// The same button's hint while paused, naming `key`, its shortcut in
    /// force.
    static func resumeHint(key: KeyBinding?) -> String {
        // Translators: VoiceOver hint of the Resume button in the Record window.
        withShortcut(InterfaceText.line("recording.resumeHint", "Continues the paused recording."), key)
    }
    /// The Stop button's hint, naming `key`, its shortcut in force.
    static func stopHint(key: KeyBinding?) -> String {
        // Translators: VoiceOver hint of the Stop button in the Record window.
        withShortcut(InterfaceText.line("recording.stopHint", "Stops recording and saves it in your library as an audiobook."), key)
    }

    /// `hint`, then, as a sentence of its own, `key`, the button's shortcut
    /// in force, in words, as the Shortcuts tab says keys
    /// (`KeyBinding.accessibleDisplayString`), as in "Shortcut: Command +
    /// R."; `hint` alone while the button has no key, as when the user gave
    /// its key to another action. Since the keys became the user's to change
    /// (FR12's branch D), a hint naming the old fixed keys could name a key
    /// that does something else.
    private static func withShortcut(_ hint: String, _ key: KeyBinding?) -> String {
        guard let key else { return hint }
        // Translators: The last sentence of a Record window button's hint: the key that presses it. %@ is the key spoken in words, such as "Command + R".
        let shortcut = InterfaceText.line("common.shortcutValue", "Shortcut: \(key.accessibleDisplayString).")
        return SentenceWording.joined([hint, shortcut])
    }

    /// The button that opens the saved recording.
    static var openInReaderTitle: String {
        // Translators: Title of the button in the Record window that opens the saved recording in a reader window.
        InterfaceText.line("recording.openInReaderTitle", "Open in Reader")
    }
    /// Its hint, naming the book.
    static func openInReaderHint(title: String) -> String {
        // Translators: VoiceOver hint of the Open in Reader button of the Record window. %@ is the saved recording's title.
        InterfaceText.line("recording.openInReaderHint", "Opens \(title) in a reader window.")
    }
    /// The button that tries a failed save again.
    static var saveAgainTitle: String {
        // Translators: Title of the button in the Record window that tries again to save a recording whose save failed.
        InterfaceText.line("recording.saveAgainTitle", "Save Again")
    }
    /// Its hint.
    static var saveAgainHint: String {
        // Translators: VoiceOver hint of the Save Again button of the Record window.
        InterfaceText.line("recording.saveAgainHint", "Tries again to save the recording as an audiobook.")
    }
    /// The button that deletes a recording that could not be saved.
    static var discardTitle: String {
        // Translators: Title of the button in the Record window that deletes a recording that could not be saved.
        InterfaceText.line("recording.discardTitle", "Discard Recording")
    }
    /// Its hint.
    static var discardHint: String {
        // Translators: VoiceOver hint of the Discard Recording button of the Record window.
        InterfaceText.line("recording.discardHint", "Deletes the recording without saving it.")
    }
    /// The button that opens the Microphone privacy settings after a no.
    static var privacySettingsTitle: String {
        // Translators: Title of the button in the Record window that opens the macOS Microphone privacy settings after macOS refused TextMouth the microphone.
        InterfaceText.line("recording.privacySettingsTitle", "Open Privacy Settings")
    }
    /// Its hint.
    static var privacySettingsHint: String {
        // Translators: VoiceOver hint of the Open Privacy Settings button of the Record window. Privacy & Security and Microphone are the names of places in macOS's System Settings, as macOS words them in the language.
        InterfaceText.line("recording.privacySettingsHint", "Opens the Microphone privacy settings in System Settings.")
    }

    // MARK: - Elapsed Time

    /// The elapsed time's label.
    static var elapsedLabel: String {
        // Translators: Label of the time recorded so far in the Record window.
        InterfaceText.line("recording.elapsedLabel", "Elapsed")
    }
    /// The elapsed time as the screen shows it: "Elapsed: 1:04".
    static func elapsedText(_ seconds: TimeInterval) -> String {
        SentenceWording.labelled(elapsedLabel, TimeFormatting.format(seconds))
    }
    /// The elapsed time as VoiceOver speaks it: "1 minute, 4 seconds".
    static func elapsedValue(_ seconds: TimeInterval) -> String {
        TimeFormatting.spoken(seconds)
    }

    // MARK: - Level

    /// The level's label.
    static var levelLabel: String {
        // Translators: Label of the microphone's loudness while recording, in the Record window.
        InterfaceText.line("recording.levelLabel", "Level")
    }

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
        case tooLoud = "too loud" // l10n: no (an identifier tests compare; `word` is shown)

        /// The loudness as a word, shown and spoken after the level's figures.
        var word: String {
            switch self {
            case .silent:
                // Translators: A word describing the microphone's loudness in the Record window: no sound reaches TextMouth. Lower case, since it follows figures.
                return InterfaceText.line("loudness.word.silent", "silent")
            case .quiet:
                // Translators: A word describing the microphone's loudness in the Record window: too quiet to be heard well. Lower case, since it follows figures.
                return InterfaceText.line("loudness.word.quiet", "quiet")
            case .good:
                // Translators: A word describing the microphone's loudness in the Record window: a voice at a good level. Lower case, since it follows figures.
                return InterfaceText.line("loudness.word.good", "good")
            case .loud:
                // Translators: A word describing the microphone's loudness in the Record window: close to the most a recording can hold. Lower case, since it follows figures.
                return InterfaceText.line("loudness.word.loud", "loud")
            case .tooLoud:
                // Translators: A word describing the microphone's loudness in the Record window: peaks reach the top and are cut off. Lower case, since it follows figures.
                return InterfaceText.line("loudness.word.tooLoud", "too loud")
            }
        }
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
        guard let levels else {
            // Translators: The microphone level line of the Record window while nothing is recording. %@ is the level's label.
            return InterfaceText.line("recording.levelText.idle", "\(levelLabel): not recording")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            // Translators: The microphone level line of the Record window when no sound reaches TextMouth. %@ is the level's label.
            return InterfaceText.line("recording.levelText.silent", "\(levelLabel): silent")
        }
        // Translators: The microphone level line of the Record window while recording. %1$@ is the level's label, %2$@ is the loudest sample's level in decibels with a minus sign, %3$@ is the average level in decibels, and %4$@ is a word for how loud that is, such as "good".
        return InterfaceText.line("recording.levelText.average", "\(levelLabel): \(decibels(levels.peak)) dB peak, \(decibels(levels.average)) dB average, \(loudness.word)")
    }

    /// The level as VoiceOver speaks it and a braille display shows it: the
    /// peak in words, and how loud that is, as "minus 12 decibels, good".
    static func levelValue(_ levels: RecordingLevels?) -> String {
        guard let levels else {
            // Translators: The value of the microphone level in the Record window, spoken, while nothing is recording.
            return InterfaceText.line("recording.levelValue.idle", "Not recording")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            // Translators: The value of the microphone level in the Record window, spoken, when no sound reaches TextMouth.
            return InterfaceText.line("recording.levelValue.silent", "Silent")
        }
        return spokenLevel(levels.peak, loudness)
    }

    /// What VoiceOver says every few seconds when asked to announce the
    /// level: "Level minus 12 decibels, good".
    static func levelAnnouncement(_ levels: RecordingLevels?) -> String {
        guard let levels else {
            // Translators: Announcement of the microphone level while nothing is recording. %@ is the level's label.
            return InterfaceText.line("recording.levelAnnouncement.idle", "\(levelLabel) not recording")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            // Translators: Announcement of the microphone level when no sound reaches TextMouth. %@ is the level's label.
            return InterfaceText.line("recording.levelAnnouncement.silent", "\(levelLabel) silent")
        }
        // Translators: Announcement of the microphone level every few seconds while recording. %1$@ is the level's label and %2$@ is the level in words, such as "minus 12 decibels, good".
        return InterfaceText.line("recording.levelAnnouncement", "\(levelLabel) \(spokenLevel(levels.peak, loudness))")
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
        // Translators: Said by the Record window when a recording has held nothing but silence for a few seconds. %@ is the name of the microphone.
        InterfaceText.line("recording.noSound", "No sound from \(device). Check that the microphone is on and not muted.")
    }

    /// A level in whole decibels as the screen shows it, with a true minus
    /// sign: "−12".
    private static func decibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        return whole < 0 ? "\u{2212}\(whole.magnitude.interfaceFormatted())" : whole.interfaceFormatted()
    }

    /// A level in whole decibels in words: "minus 12 decibels".
    private static func spokenDecibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        let magnitude = Int(whole.magnitude)
        guard whole < 0 else {
            // Translators: A sound level in decibels, spoken, in the Record window. %lld is the number of decibels.
            return InterfaceText.line("recording.spokenDecibels.positive", "\(number: magnitude) decibels")
        }
        // Translators: A negative sound level in decibels, spoken, in the Record window. %lld is the number of decibels below the maximum.
        return InterfaceText.line("recording.spokenDecibels.minus", "minus \(number: magnitude) decibels")
    }

    /// A level in words and how loud it is: "minus 12 decibels, good".
    private static func spokenLevel(_ peak: Float, _ loudness: Loudness) -> String {
        // Translators: The microphone level spoken in the Record window. %1$@ is the level in decibels in words, such as "minus 12 decibels", and %2$@ is a word for how loud that is, such as "good".
        InterfaceText.line("recording.spokenLevel", "\(spokenDecibels(peak)), \(loudness.word)")
    }

    // MARK: - Announcing the Level

    /// The level announcement switch's title.
    static func announceLevelTitle(seconds: Int) -> String {
        // Translators: Title of the switch in the Record window that makes VoiceOver speak the microphone level while recording. %lld is how many seconds pass between announcements.
        InterfaceText.line("recording.announceLevelTitle", "Announce level every \(number: seconds) seconds")
    }
    /// Its hint.
    static var announceLevelHint: String {
        // Translators: VoiceOver hint and tooltip of the switch in the Record window that announces the microphone level.
        InterfaceText.line("recording.announceLevelHint", "VoiceOver speaks the level while recording. Over speakers, its speech can be recorded.")
    }
    /// The stepper choosing how often.
    static var announceIntervalLabel: String {
        // Translators: Label of the stepper in the Record window that sets how many seconds pass between the spoken microphone levels.
        InterfaceText.line("recording.announceIntervalLabel", "Seconds between level announcements")
    }
    /// The stepper's text as the screen shows it: its label and the seconds.
    static func announceIntervalText(seconds: Int) -> String {
        SentenceWording.labelled(announceIntervalLabel, String(seconds)) // l10n: no (a count of seconds shown beside its label as figures, ungrouped like the stepper's own)
    }
    /// The stepper's value as VoiceOver speaks it: "10 seconds".
    static func announceIntervalValue(seconds: Int) -> String {
        CountWording.seconds(seconds)
    }
    /// The intervals the stepper offers, in seconds: the setting's
    /// (`SettingsPolicy.recordingLevelAnnouncementSeconds`).
    static var announceIntervals: ClosedRange<Int> {
        let range = SettingsPolicy.recordingLevelAnnouncementSeconds.range
        return Int(range.lowerBound)...Int(range.upperBound)
    }

    // MARK: - Status and Announcements

    /// What the window says while nothing is recording.
    static func ready(device: String?) -> String {
        guard let device else {
            // Translators: Status line of the Record window while no microphone is connected.
            return InterfaceText.line("recording.ready.microphone", "Connect a microphone to record.")
        }
        // Translators: Status line of the Record window while nothing is recording. %@ is the name of the microphone.
        return InterfaceText.line("recording.ready.record", "Ready to record from \(device).")
    }
    /// What the window says, and VoiceOver announces before capture
    /// begins, when recording starts.
    static func recording(device: String) -> String {
        // Translators: Status line and announcement of the Record window when recording starts. %@ is the name of the microphone.
        InterfaceText.line("recording.recording", "Recording from \(device).")
    }
    /// What the window says, and VoiceOver announces, once paused.
    static var paused: String {
        // Translators: Status line and announcement of the Record window once the recording is paused.
        InterfaceText.line("recording.paused", "Paused.")
    }
    /// What VoiceOver announces before capture resumes.
    static var resuming: String {
        // Translators: Announcement of the Record window before a paused recording continues.
        InterfaceText.line("recording.resuming", "Resuming.")
    }

    /// What starting or resuming a recording says when it paused books that
    /// were playing, so the microphone would not pick them up: "Paused the
    /// book that was playing." or "Paused 2 books that were playing."; nil
    /// when it paused none.
    static func pausedReaders(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        // Translators: Said by the Record window when starting or resuming a recording paused books that were playing, so the microphone would not pick them up. %lld is the number of books paused. The one form has no number: "Paused the book that was playing."
        return InterfaceText.line("recording.pausedReaders", "Paused \(number: count) books that were playing.")
    }

    /// `sentence`, after the one saying `pausedReaders` books were paused,
    /// when any were: one announcement, so VoiceOver speaks both, the books'
    /// first.
    static func afterPausingReaders(_ pausedReaders: Int, _ sentence: String) -> String {
        guard let paused = Self.pausedReaders(pausedReaders) else { return sentence }
        return SentenceWording.joined([paused, sentence])
    }
    /// What the window says while saving, and VoiceOver announces when a
    /// save takes more than a moment.
    static var saving: String {
        // Translators: Status line and announcement of the Record window while a recording is being saved as an audiobook.
        InterfaceText.line("recording.saving", "Saving the recording…")
    }
    /// What VoiceOver announces once a recording is saved.
    static func savedAnnouncement(title: String) -> String {
        // Translators: Announcement of the Record window once a recording is saved as an audiobook. %@ is the audiobook's title.
        InterfaceText.line("recording.savedAnnouncement", "Saved Recording as \(title)")
    }
    /// What the window says once a recording is saved.
    static func saved(title: String) -> String {
        // Translators: Status line of the Record window once a recording is saved as an audiobook, ending with a full stop. %@ is the audiobook's title.
        InterfaceText.line("recording.saved", "Saved Recording as \(title).")
    }
    /// What the window says, and VoiceOver announces, when a save failed.
    static func saveFailed(reason: String) -> String {
        // Translators: Status line and announcement of the Record window when saving a recording failed. %1$@ is the reason, a whole sentence that ends with its own full stop, %2$@ is the title of the button that tries again, and %3$@ is the title of the button that deletes the recording.
        InterfaceText.line("recording.saveFailed", "The recording couldn't be saved: \(reason) It is kept; choose \(saveAgainTitle) or \(discardTitle).")
    }
    /// What the window says, and VoiceOver announces, when the microphone
    /// TextMouth remembers is not connected when the window opens.
    static func rememberedMicrophoneMissing(fallback: String) -> String {
        // Translators: Said by the Record window when the microphone used last is not connected as the window opens. %@ is the name of the microphone recordings use instead.
        InterfaceText.line("recording.rememberedMicrophoneMissing", "The microphone TextMouth used last isn't connected, so recordings use \(fallback).")
    }
    /// What the window says, and VoiceOver announces, when a microphone
    /// connects while the window is open and recordings now use it: the one
    /// TextMouth remembers, back, or the first connected at all.
    static func microphoneConnectedAndChosen(_ name: String) -> String {
        // Translators: Said by the Record window when a microphone connects and recordings now use it. %@ is the microphone's name.
        InterfaceText.line("recording.microphoneConnectedAndChosen", "\(name) was connected, so recordings use it.")
    }
    /// What the window says, and VoiceOver announces, when microphones
    /// connect while the window is open and are added to the Microphone
    /// pop-up, recordings still using the one chosen.
    static func microphonesConnected(_ names: [String]) -> String {
        let list = CountWording.list(names)
        guard names.count != 1 else {
            // Translators: Said by the Record window when one microphone connects and is added to the Microphone pop-up. %1$@ is the microphone's name and %2$@ is the pop-up's label.
            return InterfaceText.line("recording.microphonesConnected.wasChoose", "\(list) was connected; choose it in the \(microphoneLabel) pop-up to record from it.")
        }
        // Translators: Said by the Record window when several microphones connect and are added to the Microphone pop-up. %1$@ is their names as a list and %2$@ is the pop-up's label.
        return InterfaceText.line("recording.microphonesConnected.were", "\(list) were connected; choose one in the \(microphoneLabel) pop-up to record from it.")
    }
    /// What the window says, and VoiceOver announces, when the chosen
    /// microphone goes away while nothing is recording.
    static func microphoneDisconnected(_ name: String, fallback: String?) -> String {
        guard let fallback else {
            // Translators: Said by the Record window when the chosen microphone is unplugged and no other is connected. %@ is the microphone's name.
            return InterfaceText.line("recording.microphoneDisconnected.connect", "\(name) was disconnected. Connect a microphone to record.")
        }
        // Translators: Said by the Record window when the chosen microphone is unplugged and another takes its place. %1$@ is the microphone that went away and %2$@ is the one recordings use now.
        return InterfaceText.line("recording.microphoneDisconnected.recordings", "\(name) was disconnected, so recordings use \(fallback).")
    }
    /// What the window says when the recording was discarded.
    static var discarded: String {
        // Translators: Status line of the Record window after a recording was discarded.
        InterfaceText.line("recording.discarded", "The recording was discarded.")
    }

    // MARK: - Recovered Recordings

    /// The heading of the takes recordings left behind, as a crash leaves
    /// one (`RecoveredTake`).
    static var recoveredHeading: String {
        // Translators: Heading of the list in the Record window of recordings TextMouth kept from before it last quit.
        InterfaceText.line("recording.recoveredHeading", "Recovered recordings")
    }

    /// What the window says, and VoiceOver announces, when it finds takes
    /// left behind: how many, where they are listed, and what can be done
    /// with them.
    static func recoveredAnnouncement(count: Int) -> String {
        guard count != 1 else {
            // Translators: Announcement of the Record window when it finds one recording left behind. %@ is the heading of the list of recovered recordings.
            return InterfaceText.line("recording.recoveredAnnouncement.discard", "Found a recording from before TextMouth last quit, under \(recoveredHeading). Save or discard it.")
        }
        // Translators: Announcement of the Record window when it finds several recordings left behind. %1$lld is how many and %2$@ is the heading of the list of recovered recordings.
        return InterfaceText.line("recording.recoveredAnnouncement.recordings", "Found \(number: count) recordings from before TextMouth last quit, under \(recoveredHeading). Save or discard each.")
    }

    /// A take left behind as the list shows it and VoiceOver reads it: when
    /// it was recorded and how long it lasts, as "Recording of October 4,
    /// 2026 at 6:30 AM, 1 minute, 4 seconds", or that it holds no sound.
    static func recoveredTake(startedAt: Date, duration: TimeInterval?) -> String {
        let when = startedAt.interfaceFormatted(date: .long, time: .shortened)
        guard let duration, duration > 0 else {
            // Translators: Describes a recording left behind that holds no sound. %@ is when it was recorded, a date and time.
            return InterfaceText.line("recording.recoveredTake.which", "Recording of \(when), which holds no sound")
        }
        // Translators: Describes a recording left behind. %1$@ is when it was recorded, a date and time, and %2$@ is how long it lasts, spoken, such as "1 minute, 4 seconds".
        return InterfaceText.line("recording.recoveredTake.withLength", "Recording of \(when), \(TimeFormatting.spoken(duration))")
    }

    /// The button that saves a take left behind.
    static var saveRecoveredTitle: String {
        // Translators: Title of the button in the Record window that saves a recording left behind as an audiobook.
        InterfaceText.line("recording.saveRecoveredTitle", "Save as Audiobook")
    }
    /// Its label, naming the take, since the list can hold several.
    static func saveRecoveredLabel(_ take: String) -> String {
        // Translators: VoiceOver label of the button that saves one recording left behind. %@ describes the recording, such as "Recording of October 4, 2026 at 6:30 AM, 1 minute, 4 seconds".
        InterfaceText.line("recording.saveRecoveredLabel", "Save as Audiobook: \(take)")
    }
    /// Its hint.
    static var saveRecoveredHint: String {
        // Translators: VoiceOver hint of the button that saves a recording left behind. %@ is the label of the pop-up that chooses the folder.
        InterfaceText.line("recording.saveRecoveredHint", "Saves this recording as an audiobook in the \(folderLabel) folder, titled by when it was recorded.")
    }
    /// The button that deletes a take left behind.
    static var discardRecoveredTitle: String {
        // Translators: Title of the button that deletes a recording, in the Record window's list of recordings left behind and in the question asked when it closes.
        InterfaceText.line("common.discard", "Discard")
    }
    /// Its label, naming the take.
    static func discardRecoveredLabel(_ take: String) -> String {
        // Translators: VoiceOver label of the button that deletes one recording left behind. %@ describes the recording, such as "Recording of October 4, 2026 at 6:30 AM, 1 minute, 4 seconds".
        InterfaceText.line("recording.discardRecoveredLabel", "Discard: \(take)")
    }
    /// Its hint.
    static var discardRecoveredHint: String {
        // Translators: VoiceOver hint of the button that deletes a recording left behind.
        InterfaceText.line("recording.discardRecoveredHint", "Deletes this recording without saving it.")
    }
    /// What the window says, and VoiceOver announces, when a take left
    /// behind was discarded: "Discarded the recording of October 4, 2026 at
    /// 6:30 AM, 1 minute, 4 seconds."
    static func recoveredDiscarded(startedAt: Date, duration: TimeInterval?) -> String {
        let when = startedAt.interfaceFormatted(date: .long, time: .shortened)
        guard let duration, duration > 0 else {
            // Translators: Said by the Record window after a recording left behind that held no sound was discarded. %@ is when it was recorded, a date and time.
            return InterfaceText.line("recording.recoveredDiscarded.which", "Discarded the recording of \(when), which holds no sound.")
        }
        // Translators: Said by the Record window after a recording left behind was discarded. %1$@ is when it was recorded, a date and time, and %2$@ is how long it lasted, spoken, such as "1 minute, 4 seconds".
        return InterfaceText.line("recording.recoveredDiscarded.withLength", "Discarded the recording of \(when), \(TimeFormatting.spoken(duration)).")
    }

    // MARK: - Closing While Recording

    /// The question asked when the window closes while recording.
    static var closeWhileRecordingQuestion: String {
        // Translators: The question asked when the Record window is closed while recording.
        InterfaceText.line("recording.closeWhileRecordingQuestion", "Stop and save the recording?")
    }
    /// The question asked when the window closes with a recording that
    /// could not be saved yet.
    static var closeWithUnsavedQuestion: String {
        // Translators: The question asked when the Record window is closed while it holds a recording that could not be saved yet.
        InterfaceText.line("recording.closeWithUnsavedQuestion", "Save the recording?")
    }
    /// What the question explains while recording.
    static var closeWhileRecordingExplanation: String {
        // Translators: Explanation under the question asked when the Record window is closed while recording. %1$@, %2$@, and %3$@ are the titles of the question's three buttons: the one that stops and saves, the one that deletes the recording, and the one that keeps recording.
        InterfaceText.line("recording.closeWhileRecordingExplanation", "Closing ends the recording. \(stopAndSaveButton) saves it as an audiobook, \(discardButton) deletes it, and \(cancelButton) keeps recording.")
    }
    /// What the question explains for a recording that could not be saved.
    static var closeWithUnsavedExplanation: String {
        // Translators: Explanation under the question asked when the Record window is closed with a recording that could not be saved. %1$@, %2$@, and %3$@ are the titles of the question's three buttons: the one that saves, the one that deletes the recording, and the one that keeps the window open.
        InterfaceText.line("recording.closeWithUnsavedExplanation", "This recording isn't saved. \(saveButton) tries again, \(discardButton) deletes it, and \(cancelButton) keeps the window open.")
    }
    /// The first, default button while recording.
    static var stopAndSaveButton: String {
        // Translators: Title of the question's default button when the Record window is closed while recording: it stops the recording and saves it.
        InterfaceText.line("recording.stopAndSaveButton", "Stop and Save")
    }
    /// The first, default button for a recording that could not be saved.
    static var saveButton: String {
        // Translators: Title of the question's default button when the Record window is closed with a recording that could not be saved: it tries to save it again.
        InterfaceText.line("common.save", "Save")
    }
    /// The button that deletes the recording.
    static var discardButton: String {
        // Translators: Title of the question's button that deletes the recording, when the Record window is closed.
        InterfaceText.line("common.discard", "Discard")
    }
    /// The button that keeps the window open; it answers Escape.
    static var cancelButton: String {
        // Translators: Title of the question's button that keeps the Record window open; it answers the Escape key.
        InterfaceText.line("common.cancel", "Cancel")
    }
}
