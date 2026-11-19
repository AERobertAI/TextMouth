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
        String(localized: "New Recording",
               comment: "Title of the Record window, which VoiceOver reads as the window's name, and the name of its group of buttons in the Shortcuts settings.")
    }

    // MARK: - Microphone

    /// The microphone pop-up's label.
    static var microphoneLabel: String {
        String(localized: "Microphone",
               comment: "Label of the pop-up in the Record window that chooses the microphone to record from.")
    }
    /// The microphone pop-up's hint.
    static var microphoneHint: String {
        String(localized: "The microphone to record from. TextMouth remembers it; the input macOS uses elsewhere is unchanged.",
               comment: "VoiceOver hint and tooltip of the Microphone pop-up in the Record window. TextMouth is the app's name.")
    }
    /// What the pop-up shows when no microphone is connected.
    static var noMicrophone: String {
        String(localized: "No microphone connected",
               comment: "What the Microphone pop-up in the Record window shows when no microphone is connected.")
    }

    // MARK: - Title and Folder

    /// The title field's label.
    static var titleLabel: String {
        String(localized: "Title",
               comment: "Label of the field in the Record window that names the recording, which becomes the audiobook's title.")
    }
    /// The title field's hint.
    static var titleHint: String {
        String(localized: "The audiobook's title in your library.",
               comment: "VoiceOver hint and tooltip of the Title field in the Record window.")
    }
    /// The title a recording starts with: "Recording" and when the window
    /// opened or the last recording was saved, as New from Text names a
    /// paste.
    static func defaultTitle(at date: Date) -> String {
        TextImportPolicy.timestampedTitle(defaultTitleName, at: date)
    }

    /// The name a new recording's title starts with, before the date and time.
    private static var defaultTitleName: String {
        String(localized: "Recording",
               comment: "The name a new recording's title starts with, followed by the date and time, such as \"Recording 2026-10-04 06:30\". It becomes the title of the audiobook the recording is saved as.")
    }

    /// The folder pop-up's label.
    static var folderLabel: String {
        String(localized: "Save in",
               comment: "Label of the pop-up in the Record window that chooses the library folder the recording is saved in.")
    }
    /// The folder pop-up's hint.
    static var folderHint: String {
        String(localized: "The library folder the recording is saved in.",
               comment: "VoiceOver hint of the Save in pop-up of the Record window.")
    }
    /// How the folder pop-up names the library folder at `path`: "Library"
    /// for the top of the library, otherwise its path from there, its
    /// folders separated as the library shows them.
    static func folderName(_ path: String) -> String {
        guard !path.isEmpty else {
            return String(localized: "Library",
                          comment: "The top of the library, as the Save in pop-up of the Record window names it.")
        }
        let folders = path.split(separator: "/").joined(separator: " / ") // l10n: no (a folder path's separator, as the library shows it)
        return String(localized: "Library / \(folders)",
                      comment: "A library folder in the Save in pop-up of the Record window: the library, then the folder's path, its folders separated by slashes. %@ is the path, such as \"Fiction / Sci-Fi\".")
    }

    // MARK: - Buttons

    /// The Record button's title.
    static var recordTitle: String {
        String(localized: "Record",
               comment: "Title of the button in the Record window that starts recording.")
    }
    /// The Pause button's title while recording.
    static var pauseTitle: String {
        String(localized: "Pause",
               comment: "Title of the button in the Record window that pauses the recording.")
    }
    /// The same button's title while paused.
    static var resumeTitle: String {
        String(localized: "Resume",
               comment: "Title of the button in the Record window that continues a paused recording.")
    }
    /// The Stop button's title.
    static var stopTitle: String {
        String(localized: "Stop",
               comment: "Title of the button in the Record window that stops recording and saves it.")
    }

    /// The Record button's hint, naming the microphone it records from and
    /// `key`, its shortcut in force (`withShortcut(_:_:)`).
    static func recordHint(device: String?, key: KeyBinding?) -> String {
        guard let device else {
            return withShortcut(String(localized: "Starts recording once a microphone is connected.",
                                       comment: "VoiceOver hint of the Record button in the Record window while no microphone is connected."), key)
        }
        return withShortcut(String(localized: "Starts recording from \(device).",
                                   comment: "VoiceOver hint of the Record button in the Record window. %@ is the name of the microphone it records from."), key)
    }
    /// The Pause button's hint while recording, naming `key`, its shortcut
    /// in force.
    static func pauseHint(key: KeyBinding?) -> String {
        withShortcut(String(localized: "Pauses the recording; \(resumeTitle) continues the same recording.",
                            comment: "VoiceOver hint of the Pause button in the Record window. %@ is the title of the button that continues a paused recording."), key)
    }
    /// The same button's hint while paused, naming `key`, its shortcut in
    /// force.
    static func resumeHint(key: KeyBinding?) -> String {
        withShortcut(String(localized: "Continues the paused recording.",
                            comment: "VoiceOver hint of the Resume button in the Record window."), key)
    }
    /// The Stop button's hint, naming `key`, its shortcut in force.
    static func stopHint(key: KeyBinding?) -> String {
        withShortcut(String(localized: "Stops recording and saves it in your library as an audiobook.",
                            comment: "VoiceOver hint of the Stop button in the Record window."), key)
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
        let shortcut = String(localized: "Shortcut: \(key.accessibleDisplayString).",
                              comment: "The last sentence of a Record window button's hint: the key that presses it. %@ is the key spoken in words, such as \"Command + R\".")
        return SentenceWording.joined([hint, shortcut])
    }

    /// The button that opens the saved recording.
    static var openInReaderTitle: String {
        String(localized: "Open in Reader",
               comment: "Title of the button in the Record window that opens the saved recording in a reader window.")
    }
    /// Its hint, naming the book.
    static func openInReaderHint(title: String) -> String {
        String(localized: "Opens \(title) in a reader window.",
               comment: "VoiceOver hint of the Open in Reader button of the Record window. %@ is the saved recording's title.")
    }
    /// The button that tries a failed save again.
    static var saveAgainTitle: String {
        String(localized: "Save Again",
               comment: "Title of the button in the Record window that tries again to save a recording whose save failed.")
    }
    /// Its hint.
    static var saveAgainHint: String {
        String(localized: "Tries again to save the recording as an audiobook.",
               comment: "VoiceOver hint of the Save Again button of the Record window.")
    }
    /// The button that deletes a recording that could not be saved.
    static var discardTitle: String {
        String(localized: "Discard Recording",
               comment: "Title of the button in the Record window that deletes a recording that could not be saved.")
    }
    /// Its hint.
    static var discardHint: String {
        String(localized: "Deletes the recording without saving it.",
               comment: "VoiceOver hint of the Discard Recording button of the Record window.")
    }
    /// The button that opens the Microphone privacy settings after a no.
    static var privacySettingsTitle: String {
        String(localized: "Open Privacy Settings",
               comment: "Title of the button in the Record window that opens the macOS Microphone privacy settings after macOS refused TextMouth the microphone.")
    }
    /// Its hint.
    static var privacySettingsHint: String {
        String(localized: "Opens the Microphone privacy settings in System Settings.",
               comment: "VoiceOver hint of the Open Privacy Settings button of the Record window. Privacy & Security and Microphone are the names of places in macOS's System Settings, as macOS words them in the language.")
    }

    // MARK: - Elapsed Time

    /// The elapsed time's label.
    static var elapsedLabel: String {
        String(localized: "Elapsed",
               comment: "Label of the time recorded so far in the Record window.")
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
        String(localized: "Level",
               comment: "Label of the microphone's loudness while recording, in the Record window.")
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
                return String(localized: "silent",
                              comment: "A word describing the microphone's loudness in the Record window: no sound reaches TextMouth. Lower case, since it follows figures.")
            case .quiet:
                return String(localized: "quiet",
                              comment: "A word describing the microphone's loudness in the Record window: too quiet to be heard well. Lower case, since it follows figures.")
            case .good:
                return String(localized: "good",
                              comment: "A word describing the microphone's loudness in the Record window: a voice at a good level. Lower case, since it follows figures.")
            case .loud:
                return String(localized: "loud",
                              comment: "A word describing the microphone's loudness in the Record window: close to the most a recording can hold. Lower case, since it follows figures.")
            case .tooLoud:
                return String(localized: "too loud",
                              comment: "A word describing the microphone's loudness in the Record window: peaks reach the top and are cut off. Lower case, since it follows figures.")
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
            return String(localized: "\(levelLabel): not recording",
                          comment: "The microphone level line of the Record window while nothing is recording. %@ is the level's label.")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            return String(localized: "\(levelLabel): silent",
                          comment: "The microphone level line of the Record window when no sound reaches TextMouth. %@ is the level's label.")
        }
        return String(localized: "\(levelLabel): \(decibels(levels.peak)) dB peak, \(decibels(levels.average)) dB average, \(loudness.word)",
                      comment: "The microphone level line of the Record window while recording. %1$@ is the level's label, %2$@ is the loudest sample's level in decibels with a minus sign, %3$@ is the average level in decibels, and %4$@ is a word for how loud that is, such as \"good\".")
    }

    /// The level as VoiceOver speaks it and a braille display shows it: the
    /// peak in words, and how loud that is, as "minus 12 decibels, good".
    static func levelValue(_ levels: RecordingLevels?) -> String {
        guard let levels else {
            return String(localized: "Not recording",
                          comment: "The value of the microphone level in the Record window, spoken, while nothing is recording.")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            return String(localized: "Silent",
                          comment: "The value of the microphone level in the Record window, spoken, when no sound reaches TextMouth.")
        }
        return spokenLevel(levels.peak, loudness)
    }

    /// What VoiceOver says every few seconds when asked to announce the
    /// level: "Level minus 12 decibels, good".
    static func levelAnnouncement(_ levels: RecordingLevels?) -> String {
        guard let levels else {
            return String(localized: "\(levelLabel) not recording",
                          comment: "Announcement of the microphone level while nothing is recording. %@ is the level's label.")
        }
        let loudness = loudness(peak: levels.peak)
        guard loudness != .silent else {
            return String(localized: "\(levelLabel) silent",
                          comment: "Announcement of the microphone level when no sound reaches TextMouth. %@ is the level's label.")
        }
        return String(localized: "\(levelLabel) \(spokenLevel(levels.peak, loudness))",
                      comment: "Announcement of the microphone level every few seconds while recording. %1$@ is the level's label and %2$@ is the level in words, such as \"minus 12 decibels, good\".")
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
        String(localized: "No sound from \(device). Check that the microphone is on and not muted.",
               comment: "Said by the Record window when a recording has held nothing but silence for a few seconds. %@ is the name of the microphone.")
    }

    /// A level in whole decibels as the screen shows it, with a true minus
    /// sign: "−12".
    private static func decibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        return whole < 0 ? "\u{2212}\(whole.magnitude.formatted())" : whole.formatted()
    }

    /// A level in whole decibels in words: "minus 12 decibels".
    private static func spokenDecibels(_ level: Float) -> String {
        let whole = Int(level.rounded())
        let magnitude = Int(whole.magnitude)
        guard whole < 0 else {
            return String(localized: "\(magnitude) decibels",
                          comment: "A sound level in decibels, spoken, in the Record window. %lld is the number of decibels.")
        }
        return String(localized: "minus \(magnitude) decibels",
                      comment: "A negative sound level in decibels, spoken, in the Record window. %lld is the number of decibels below the maximum.")
    }

    /// A level in words and how loud it is: "minus 12 decibels, good".
    private static func spokenLevel(_ peak: Float, _ loudness: Loudness) -> String {
        String(localized: "\(spokenDecibels(peak)), \(loudness.word)",
               comment: "The microphone level spoken in the Record window. %1$@ is the level in decibels in words, such as \"minus 12 decibels\", and %2$@ is a word for how loud that is, such as \"good\".")
    }

    // MARK: - Announcing the Level

    /// The level announcement switch's title.
    static func announceLevelTitle(seconds: Int) -> String {
        String(localized: "Announce level every \(seconds) seconds",
               comment: "Title of the switch in the Record window that makes VoiceOver speak the microphone level while recording. %lld is how many seconds pass between announcements.")
    }
    /// Its hint.
    static var announceLevelHint: String {
        String(localized: "VoiceOver speaks the level while recording. Over speakers, its speech can be recorded.",
               comment: "VoiceOver hint and tooltip of the switch in the Record window that announces the microphone level.")
    }
    /// The stepper choosing how often.
    static var announceIntervalLabel: String {
        String(localized: "Seconds between level announcements",
               comment: "Label of the stepper in the Record window that sets how many seconds pass between the spoken microphone levels.")
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
            return String(localized: "Connect a microphone to record.",
                          comment: "Status line of the Record window while no microphone is connected.")
        }
        return String(localized: "Ready to record from \(device).",
                      comment: "Status line of the Record window while nothing is recording. %@ is the name of the microphone.")
    }
    /// What the window says, and VoiceOver announces before capture
    /// begins, when recording starts.
    static func recording(device: String) -> String {
        String(localized: "Recording from \(device).",
               comment: "Status line and announcement of the Record window when recording starts. %@ is the name of the microphone.")
    }
    /// What the window says, and VoiceOver announces, once paused.
    static var paused: String {
        String(localized: "Paused.",
               comment: "Status line and announcement of the Record window once the recording is paused.")
    }
    /// What VoiceOver announces before capture resumes.
    static var resuming: String {
        String(localized: "Resuming.",
               comment: "Announcement of the Record window before a paused recording continues.")
    }

    /// What starting or resuming a recording says when it paused books that
    /// were playing, so the microphone would not pick them up: "Paused the
    /// book that was playing." or "Paused 2 books that were playing."; nil
    /// when it paused none.
    static func pausedReaders(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return String(localized: "Paused \(count) books that were playing.",
                      comment: "Said by the Record window when starting or resuming a recording paused books that were playing, so the microphone would not pick them up. %lld is the number of books paused. The one form has no number: \"Paused the book that was playing.\"")
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
        String(localized: "Saving the recording…",
               comment: "Status line and announcement of the Record window while a recording is being saved as an audiobook.")
    }
    /// What VoiceOver announces once a recording is saved.
    static func savedAnnouncement(title: String) -> String {
        String(localized: "Saved Recording as \(title)",
               comment: "Announcement of the Record window once a recording is saved as an audiobook. %@ is the audiobook's title.")
    }
    /// What the window says once a recording is saved.
    static func saved(title: String) -> String {
        String(localized: "Saved Recording as \(title).",
               comment: "Status line of the Record window once a recording is saved as an audiobook, ending with a full stop. %@ is the audiobook's title.")
    }
    /// What the window says, and VoiceOver announces, when a save failed.
    static func saveFailed(reason: String) -> String {
        String(localized: "The recording couldn't be saved: \(reason) It is kept; choose \(saveAgainTitle) or \(discardTitle).",
               comment: "Status line and announcement of the Record window when saving a recording failed. %1$@ is the reason, a whole sentence that ends with its own full stop, %2$@ is the title of the button that tries again, and %3$@ is the title of the button that deletes the recording.")
    }
    /// What the window says, and VoiceOver announces, when the microphone
    /// TextMouth remembers is not connected when the window opens.
    static func rememberedMicrophoneMissing(fallback: String) -> String {
        String(localized: "The microphone TextMouth used last isn't connected, so recordings use \(fallback).",
               comment: "Said by the Record window when the microphone used last is not connected as the window opens. %@ is the name of the microphone recordings use instead.")
    }
    /// What the window says, and VoiceOver announces, when a microphone
    /// connects while the window is open and recordings now use it: the one
    /// TextMouth remembers, back, or the first connected at all.
    static func microphoneConnectedAndChosen(_ name: String) -> String {
        String(localized: "\(name) was connected, so recordings use it.",
               comment: "Said by the Record window when a microphone connects and recordings now use it. %@ is the microphone's name.")
    }
    /// What the window says, and VoiceOver announces, when microphones
    /// connect while the window is open and are added to the Microphone
    /// pop-up, recordings still using the one chosen.
    static func microphonesConnected(_ names: [String]) -> String {
        let list = CountWording.list(names)
        guard names.count != 1 else {
            return String(localized: "\(list) was connected; choose it in the \(microphoneLabel) pop-up to record from it.",
                          comment: "Said by the Record window when one microphone connects and is added to the Microphone pop-up. %1$@ is the microphone's name and %2$@ is the pop-up's label.")
        }
        return String(localized: "\(list) were connected; choose one in the \(microphoneLabel) pop-up to record from it.",
                      comment: "Said by the Record window when several microphones connect and are added to the Microphone pop-up. %1$@ is their names as a list and %2$@ is the pop-up's label.")
    }
    /// What the window says, and VoiceOver announces, when the chosen
    /// microphone goes away while nothing is recording.
    static func microphoneDisconnected(_ name: String, fallback: String?) -> String {
        guard let fallback else {
            return String(localized: "\(name) was disconnected. Connect a microphone to record.",
                          comment: "Said by the Record window when the chosen microphone is unplugged and no other is connected. %@ is the microphone's name.")
        }
        return String(localized: "\(name) was disconnected, so recordings use \(fallback).",
                      comment: "Said by the Record window when the chosen microphone is unplugged and another takes its place. %1$@ is the microphone that went away and %2$@ is the one recordings use now.")
    }
    /// What the window says when the recording was discarded.
    static var discarded: String {
        String(localized: "The recording was discarded.",
               comment: "Status line of the Record window after a recording was discarded.")
    }

    // MARK: - Recovered Recordings

    /// The heading of the takes recordings left behind, as a crash leaves
    /// one (`RecoveredTake`).
    static var recoveredHeading: String {
        String(localized: "Recovered recordings",
               comment: "Heading of the list in the Record window of recordings TextMouth kept from before it last quit.")
    }

    /// What the window says, and VoiceOver announces, when it finds takes
    /// left behind: how many, where they are listed, and what can be done
    /// with them.
    static func recoveredAnnouncement(count: Int) -> String {
        guard count != 1 else {
            return String(localized: "Found a recording from before TextMouth last quit, under \(recoveredHeading). Save or discard it.",
                          comment: "Announcement of the Record window when it finds one recording left behind. %@ is the heading of the list of recovered recordings.")
        }
        return String(localized: "Found \(count) recordings from before TextMouth last quit, under \(recoveredHeading). Save or discard each.",
                      comment: "Announcement of the Record window when it finds several recordings left behind. %1$lld is how many and %2$@ is the heading of the list of recovered recordings.")
    }

    /// A take left behind as the list shows it and VoiceOver reads it: when
    /// it was recorded and how long it lasts, as "Recording of October 4,
    /// 2026 at 6:30 AM, 1 minute, 4 seconds", or that it holds no sound.
    static func recoveredTake(startedAt: Date, duration: TimeInterval?) -> String {
        let when = startedAt.formatted(date: .long, time: .shortened)
        guard let duration, duration > 0 else {
            return String(localized: "Recording of \(when), which holds no sound",
                          comment: "Describes a recording left behind that holds no sound. %@ is when it was recorded, a date and time.")
        }
        return String(localized: "Recording of \(when), \(TimeFormatting.spoken(duration))",
                      comment: "Describes a recording left behind. %1$@ is when it was recorded, a date and time, and %2$@ is how long it lasts, spoken, such as \"1 minute, 4 seconds\".")
    }

    /// The button that saves a take left behind.
    static var saveRecoveredTitle: String {
        String(localized: "Save as Audiobook",
               comment: "Title of the button in the Record window that saves a recording left behind as an audiobook.")
    }
    /// Its label, naming the take, since the list can hold several.
    static func saveRecoveredLabel(_ take: String) -> String {
        String(localized: "Save as Audiobook: \(take)",
               comment: "VoiceOver label of the button that saves one recording left behind. %@ describes the recording, such as \"Recording of October 4, 2026 at 6:30 AM, 1 minute, 4 seconds\".")
    }
    /// Its hint.
    static var saveRecoveredHint: String {
        String(localized: "Saves this recording as an audiobook in the \(folderLabel) folder, titled by when it was recorded.",
               comment: "VoiceOver hint of the button that saves a recording left behind. %@ is the label of the pop-up that chooses the folder.")
    }
    /// The button that deletes a take left behind.
    static var discardRecoveredTitle: String {
        String(localized: "Discard",
               comment: "Title of the button that deletes a recording, in the Record window's list of recordings left behind and in the question asked when it closes.")
    }
    /// Its label, naming the take.
    static func discardRecoveredLabel(_ take: String) -> String {
        String(localized: "Discard: \(take)",
               comment: "VoiceOver label of the button that deletes one recording left behind. %@ describes the recording, such as \"Recording of October 4, 2026 at 6:30 AM, 1 minute, 4 seconds\".")
    }
    /// Its hint.
    static var discardRecoveredHint: String {
        String(localized: "Deletes this recording without saving it.",
               comment: "VoiceOver hint of the button that deletes a recording left behind.")
    }
    /// What the window says, and VoiceOver announces, when a take left
    /// behind was discarded: "Discarded the recording of October 4, 2026 at
    /// 6:30 AM, 1 minute, 4 seconds."
    static func recoveredDiscarded(startedAt: Date, duration: TimeInterval?) -> String {
        let when = startedAt.formatted(date: .long, time: .shortened)
        guard let duration, duration > 0 else {
            return String(localized: "Discarded the recording of \(when), which holds no sound.",
                          comment: "Said by the Record window after a recording left behind that held no sound was discarded. %@ is when it was recorded, a date and time.")
        }
        return String(localized: "Discarded the recording of \(when), \(TimeFormatting.spoken(duration)).",
                      comment: "Said by the Record window after a recording left behind was discarded. %1$@ is when it was recorded, a date and time, and %2$@ is how long it lasted, spoken, such as \"1 minute, 4 seconds\".")
    }

    // MARK: - Closing While Recording

    /// The question asked when the window closes while recording.
    static var closeWhileRecordingQuestion: String {
        String(localized: "Stop and save the recording?",
               comment: "The question asked when the Record window is closed while recording.")
    }
    /// The question asked when the window closes with a recording that
    /// could not be saved yet.
    static var closeWithUnsavedQuestion: String {
        String(localized: "Save the recording?",
               comment: "The question asked when the Record window is closed while it holds a recording that could not be saved yet.")
    }
    /// What the question explains while recording.
    static var closeWhileRecordingExplanation: String {
        String(localized: "Closing ends the recording. \(stopAndSaveButton) saves it as an audiobook, \(discardButton) deletes it, and \(cancelButton) keeps recording.",
               comment: "Explanation under the question asked when the Record window is closed while recording. %1$@, %2$@, and %3$@ are the titles of the question's three buttons: the one that stops and saves, the one that deletes the recording, and the one that keeps recording.")
    }
    /// What the question explains for a recording that could not be saved.
    static var closeWithUnsavedExplanation: String {
        String(localized: "This recording isn't saved. \(saveButton) tries again, \(discardButton) deletes it, and \(cancelButton) keeps the window open.",
               comment: "Explanation under the question asked when the Record window is closed with a recording that could not be saved. %1$@, %2$@, and %3$@ are the titles of the question's three buttons: the one that saves, the one that deletes the recording, and the one that keeps the window open.")
    }
    /// The first, default button while recording.
    static var stopAndSaveButton: String {
        String(localized: "Stop and Save",
               comment: "Title of the question's default button when the Record window is closed while recording: it stops the recording and saves it.")
    }
    /// The first, default button for a recording that could not be saved.
    static var saveButton: String {
        String(localized: "Save",
               comment: "Title of the question's default button when the Record window is closed with a recording that could not be saved: it tries to save it again.")
    }
    /// The button that deletes the recording.
    static var discardButton: String {
        String(localized: "Discard",
               comment: "Title of the question's button that deletes the recording, when the Record window is closed.")
    }
    /// The button that keeps the window open; it answers Escape.
    static var cancelButton: String {
        String(localized: "Cancel",
               comment: "Title of the question's button that keeps the Record window open; it answers the Escape key.")
    }
}
