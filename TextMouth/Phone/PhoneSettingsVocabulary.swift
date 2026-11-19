import Foundation

/// The words of the phone's Settings screen that the Mac keeps inline in its
/// settings views (the iPhone interface spec, under "One vocabulary").
///
/// Each case is a word the Mac keeps in `SettingsWording` (or
/// `StorageSettingsWording`), and its `title` is that static, so the phone can't
/// drift from the Mac and a translation serves both. Being `CaseIterable`, a new
/// case is checked with no list to keep. A word two rows share, such as
/// "Voice", is one case.
///
/// A word that a shared wording type already holds isn't here:
/// `ReaderTimeWording`, `ReaderPageWording`, `EndOfBookWording`, and the raw
/// values of `SkipUnit`, `RewindUnit`, and `EndOfBookBehavior` are called, not
/// copied.
enum PhoneSettingsVocabulary: CaseIterable {
    // MARK: Voice

    /// The section's name, and the Voice row's title.
    case voice
    case language
    case voiceLanguage
    /// The Language row's first choice, every language.
    case allLanguages
    case selectVoice
    case selectVoiceHint
    case previewVoice
    case previewSelectedVoice
    case defaultSpeed
    case defaultSpeedCaption
    case defaultPitch
    case defaultPitchCaption

    // MARK: Navigation

    /// The section's name, which holds the phone's navigation units as well
    /// as the Mac's switch.
    case navigation
    case autoPlayAfterNavigation
    case autoPlayHint

    // MARK: Rewind on Resume

    case rewindOnResume
    case rewindTo
    case rewindOnResumeUnit
    case rewindToHint
    case smartMode
    case smartRewindMode
    case smartModeHint
    case minimumPauseThreshold
    case minimumPauseCaption

    // MARK: Punctuation Pauses

    case punctuationPauses
    case punctuationPauseLevel
    case punctuationPauseCaption
    /// Level 0's name.
    case off
    /// Level 1's name.
    case subtle
    /// Level 2's name.
    case moderate
    /// Level 3's name.
    case heavy

    // MARK: End of Book

    case endOfBook
    case whenBookEnds
    case endOfBookBehavior
    case endOfBookHint

    // MARK: Sleep Timer

    case sleepTimer
    case fadeOutDuration
    case fadeOutCaption
    case closeSleepTimerSheet
    case closeSleepTimerSheetHint

    // MARK: Removal Behavior

    case removalBehavior
    case confirmBeforeRemoving

    // MARK: The Words

    /// What Preview Voice speaks. It is the previewed voice's to say, in its own
    /// language, so it is not the interface's text, and the Mac says the same.
    static let previewSentence = "Hello! This is TextMouth, ready to read for you." // l10n: no (spoken by the previewed voice, not read in the interface language)

    /// The word in the interface language: each is the Mac's own static, so one
    /// definition serves both apps (`PhoneSettingsVocabularyTests` checks that
    /// none is empty and that none repeats another).
    var title: String {
        switch self {
        case .voice: return SettingsWording.voiceTitle
        case .language: return SettingsWording.languageTitle
        case .voiceLanguage: return SettingsWording.voiceLanguageLabel
        case .allLanguages: return SettingsWording.allLanguages
        case .selectVoice: return SettingsWording.selectVoiceLabel
        case .selectVoiceHint: return SettingsWording.selectVoiceHint
        case .previewVoice: return SettingsWording.previewTitle
        case .previewSelectedVoice: return SettingsWording.previewLabel
        case .defaultSpeed: return SettingsWording.defaultSpeedLabel
        case .defaultSpeedCaption: return SettingsWording.defaultSpeedExplanation
        case .defaultPitch: return SettingsWording.defaultPitchLabel
        case .defaultPitchCaption: return SettingsWording.defaultPitchExplanation
        case .navigation: return SettingsWording.navigationHeader
        case .autoPlayAfterNavigation: return SettingsWording.autoPlayTitle
        case .autoPlayHint: return SettingsWording.autoPlayHint
        case .rewindOnResume: return SettingsWording.rewindHeader
        case .rewindTo: return SettingsWording.rewindToTitle
        case .rewindOnResumeUnit: return SettingsWording.rewindUnitLabel
        case .rewindToHint: return SettingsWording.rewindUnitHint
        case .smartMode: return SettingsWording.smartModeTitle
        case .smartRewindMode: return SettingsWording.smartModeLabel
        case .smartModeHint: return SettingsWording.smartModeHint
        case .minimumPauseThreshold: return SettingsWording.minimumPauseLabel
        case .minimumPauseCaption: return SettingsWording.minimumPauseExplanation
        case .punctuationPauses: return SettingsWording.punctuationHeader
        case .punctuationPauseLevel: return SettingsWording.pauseLevelLabel
        case .punctuationPauseCaption: return SettingsWording.punctuationLevelsExplanation
        case .off: return SettingsWording.punctuationLevelName(0)
        case .subtle: return SettingsWording.punctuationLevelName(1)
        case .moderate: return SettingsWording.punctuationLevelName(2)
        case .heavy: return SettingsWording.punctuationLevelName(3)
        case .endOfBook: return SettingsWording.endOfBookHeader
        case .whenBookEnds: return SettingsWording.whenBookEndsTitle
        case .endOfBookBehavior: return SettingsWording.endOfBookLabel
        case .endOfBookHint: return SettingsWording.endOfBookHint
        case .sleepTimer: return SettingsWording.sleepTimerHeader
        case .fadeOutDuration: return SettingsWording.fadeOutLabel
        case .fadeOutCaption: return SettingsWording.fadeOutExplanation
        case .closeSleepTimerSheet: return SettingsWording.autoCloseLabel
        case .closeSleepTimerSheetHint: return SettingsWording.autoCloseHint
        case .removalBehavior: return StorageSettingsWording.removalBehaviorHeader
        case .confirmBeforeRemoving: return StorageSettingsWording.confirmBeforeRemovingTitle
        }
    }
}
