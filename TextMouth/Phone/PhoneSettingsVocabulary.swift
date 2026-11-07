import Foundation

/// The words of the phone's Settings screen that the Mac keeps inline in its
/// settings views (the iPhone interface spec, under "One vocabulary").
///
/// The Mac's views stay as they are, so the phone holds its own copy of each
/// word here, and `PhoneSettingsVocabularyTests` reads the Mac's two source
/// files, `Views/Settings/SettingsView.swift` and
/// `Views/Settings/StorageSettingsView.swift`, and requires every case's word
/// to be there, word for word, as a whole string, so that the two can't drift
/// apart unnoticed. Being `CaseIterable`, a new case is checked with no list
/// to keep. A word two rows share, such as "Voice", is one case, since raw
/// values are unique.
///
/// A word that a shared wording type already holds isn't here:
/// `ReaderTimeWording`, `ReaderPageWording`, `EndOfBookWording`, and the raw
/// values of `SkipUnit`, `RewindUnit`, and `EndOfBookBehavior` are called, not
/// copied.
enum PhoneSettingsVocabulary: String, CaseIterable {
    // MARK: Voice

    /// The section's name, and the Voice row's title.
    case voice = "Voice"
    case language = "Language"
    case voiceLanguage = "Voice language"
    /// The Language row's first choice, every language.
    case allLanguages = "All"
    case selectVoice = "Select voice"
    case selectVoiceHint = "Choose a voice for reading. Change takes effect immediately."
    case previewVoice = "Preview Voice"
    case previewSelectedVoice = "Preview selected voice"
    /// What Preview Voice speaks.
    case previewSentence = "Hello! This is TextMouth, ready to read for you."
    case defaultSpeed = "Default speed"
    case defaultSpeedCaption = "Default speed for new books. Each book can override this with its own speed."
    case defaultPitch = "Default pitch"
    case defaultPitchCaption = "Default pitch for new books. 1.0 is normal. Each book can override this."

    // MARK: Navigation

    /// The section's name, which holds the phone's navigation units as well
    /// as the Mac's switch.
    case navigation = "Navigation"
    case autoPlayAfterNavigation = "Auto-play after navigation"
    case autoPlayHint =
        "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result"

    // MARK: Rewind on Resume

    case rewindOnResume = "Rewind on Resume"
    case rewindTo = "Rewind to"
    case rewindOnResumeUnit = "Rewind on resume unit"
    case rewindToHint = "When resuming playback, rewind to the start of this unit"
    case smartMode = "Smart mode"
    case smartRewindMode = "Smart rewind mode"
    case smartModeHint = "Only rewind if the pause was longer than the threshold"
    case minimumPauseThreshold = "Minimum pause threshold"
    case minimumPauseCaption = "Don't rewind if paused for less than this."

    // MARK: Punctuation Pauses

    case punctuationPauses = "Punctuation Pauses"
    case punctuationPauseLevel = "Punctuation pause level"
    case punctuationPauseCaption =
        "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)"
    /// Level 0's name.
    case off = "Off"
    /// Level 1's name.
    case subtle = "Subtle"
    /// Level 2's name.
    case moderate = "Moderate"
    /// Level 3's name.
    case heavy = "Heavy"

    // MARK: End of Book

    case endOfBook = "End of Book"
    case whenBookEnds = "When book ends"
    case endOfBookBehavior = "End of book behavior"
    case endOfBookHint = "What happens when a book finishes playing"

    // MARK: Sleep Timer

    case sleepTimer = "Sleep Timer"
    case fadeOutDuration = "Fade out duration"
    case fadeOutCaption = "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly."
    case closeSleepTimerSheet = "Close sleep timer sheet after setting a timer"
    case closeSleepTimerSheetHint = "When off, the sheet stays open showing the remaining time and a reset button"

    // MARK: Removal Behavior

    case removalBehavior = "Removal Behavior"
    case confirmBeforeRemoving = "Confirm before removing a book"

    // MARK: Words Built from a Value

    /// A speed as the Mac's slider says it: "200 words per minute". The test
    /// pins the Mac's own string, which interpolates the same whole number.
    static func wordsPerMinute(_ wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute)) words per minute"
    }

    /// A voice as the Mac's list of voices says it: "Samantha, Enhanced
    /// quality".
    static func voiceChoice(name: String, quality: String) -> String {
        "\(name), \(quality) quality"
    }
}
