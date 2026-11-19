import XCTest
@testable import TextMouth

/// The phone's Settings screen says what the Mac's says: each word
/// `PhoneSettingsVocabulary` holds for the phone is the Mac's own static, so
/// the two can't drift apart, and its English is pinned here.
///
/// The Mac's views are read as source only to see that they still show the
/// statics the phone forwards to (`LogContentPolicyTests` and
/// `UncheckedConcurrencyPolicyTests` read the app's source the same way,
/// through the same folder, `AppSourceFile.folder`).
final class PhoneSettingsVocabularyTests: XCTestCase {
    /// The Mac's views that show the words, read from the app's source
    /// folder and joined, since a word only has to stand in one of them.
    /// Fails the calling test when either can't be read, so a view that moved
    /// never lets the checks pass having read nothing. The model's tests read
    /// the Mac's steps here too.
    static func macSettingsSources() throws -> String {
        let folder = AppSourceFile.folder.appendingPathComponent("Views/Settings", isDirectory: true)
        let sources = try ["SettingsView.swift", "StorageSettingsView.swift"].map { name in
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        return sources.joined(separator: "\n")
    }

    /// Every word, as the phone says it in English: the phone's `title` is the
    /// Mac's static, which says these words.
    private static let englishWords: [(PhoneSettingsVocabulary, String)] = [
        (.voice, "Voice"),
        (.language, "Language"),
        (.voiceLanguage, "Voice language"),
        (.allLanguages, "All"),
        (.selectVoice, "Select voice"),
        (.selectVoiceHint, "Choose a voice for reading. Change takes effect immediately."),
        (.previewVoice, "Preview Voice"),
        (.previewSelectedVoice, "Preview selected voice"),
        (.defaultSpeed, "Default speed"),
        (.defaultSpeedCaption, "Default speed for new books. Each book can override this with its own speed."),
        (.defaultPitch, "Default pitch"),
        (.defaultPitchCaption, "Default pitch for new books. 1.0 is normal. Each book can override this."),
        (.navigation, "Navigation"),
        (.autoPlayAfterNavigation, "Auto-play after navigation"),
        (.autoPlayHint, "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result"),
        (.rewindOnResume, "Rewind on Resume"),
        (.rewindTo, "Rewind to"),
        (.rewindOnResumeUnit, "Rewind on resume unit"),
        (.rewindToHint, "When resuming playback, rewind to the start of this unit"),
        (.smartMode, "Smart mode"),
        (.smartRewindMode, "Smart rewind mode"),
        (.smartModeHint, "Only rewind if the pause was longer than the threshold"),
        (.minimumPauseThreshold, "Minimum pause threshold"),
        (.minimumPauseCaption, "Don't rewind if paused for less than this."),
        (.punctuationPauses, "Punctuation Pauses"),
        (.punctuationPauseLevel, "Punctuation pause level"),
        (.punctuationPauseCaption, "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)"),
        (.off, "Off"),
        (.subtle, "Subtle"),
        (.moderate, "Moderate"),
        (.heavy, "Heavy"),
        (.endOfBook, "End of Book"),
        (.whenBookEnds, "When book ends"),
        (.endOfBookBehavior, "End of book behavior"),
        (.endOfBookHint, "What happens when a book finishes playing"),
        (.sleepTimer, "Sleep Timer"),
        (.fadeOutDuration, "Fade out duration"),
        (.fadeOutCaption, "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly."),
        (.closeSleepTimerSheet, "Close sleep timer sheet after setting a timer"),
        (.closeSleepTimerSheetHint, "When off, the sheet stays open showing the remaining time and a reset button"),
        (.removalBehavior, "Removal Behavior"),
        (.confirmBeforeRemoving, "Confirm before removing a book"),
    ]

    /// Every case has its English, so a new case can't go unchecked.
    func testEveryWordSaysItsEnglish() {
        for (word, english) in Self.englishWords {
            XCTAssertEqual(word.title, english, "\(word)")
        }
        XCTAssertEqual(
            Set(Self.englishWords.map { "\($0.0)" }),
            Set(PhoneSettingsVocabulary.allCases.map { "\($0)" }),
            "a case of the vocabulary has no English pinned here"
        )
    }

    /// The Mac's views show the statics the phone forwards to, whole, so a
    /// word the Mac stops showing is noticed here.
    func testTheMacsViewsShowTheStaticsThePhoneSays() throws {
        let sources = try Self.macSettingsSources()
        XCTAssertTrue(sources.contains("Text(SettingsWording.punctuationLevelsExplanation)"))
        XCTAssertEqual(PhoneSettingsVocabulary.punctuationPauseCaption.title, SettingsWording.punctuationLevelsExplanation)
        XCTAssertTrue(sources.contains("SettingsWording.selectVoiceHint"))
        XCTAssertTrue(sources.contains("SettingsWording.autoPlayHint"))
        XCTAssertTrue(sources.contains("StorageSettingsWording.confirmBeforeRemovingTitle"))
    }

    /// The enumeration really holds the settings' words: one emptied by
    /// accident would pass the tests above having checked nothing.
    func testTheVocabularyHoldsEveryKindOfWordTheSpecLists() {
        let words = Set(PhoneSettingsVocabulary.allCases.map(\.title))
        XCTAssertGreaterThanOrEqual(words.count, 40)
        for expected in ["Voice", "Navigation", "Punctuation pause level", "Heavy", "Confirm before removing a book"] {
            XCTAssertTrue(words.contains(expected), "\(expected) is missing")
        }
    }

    /// A speed's words are the Mac's: its slider's value is `SettingsWording`'s
    /// whole-number words, which the phone says too.
    func testASpeedIsSaidAsTheMacsSliderSaysIt() throws {
        let sources = try Self.macSettingsSources()
        XCTAssertTrue(sources.contains(".accessibilityValue(SettingsWording.wordsPerMinuteValue(Int(settingsViewModel.wordsPerMinute)))"))
        XCTAssertEqual(SettingsWording.wordsPerMinuteValue(200), "200 words per minute")
        XCTAssertEqual(PhoneVoiceVocabulary.speedValue(wordsPerMinute: 200), SettingsWording.wordsPerMinuteValue(200))
        XCTAssertEqual(PhoneVoiceVocabulary.speedValue(wordsPerMinute: 650), "650 words per minute")
    }

    /// A voice's words are the Mac's: its list of voices names each one by
    /// its name and its quality, in `SettingsWording`'s form, which the phone
    /// says too.
    func testAVoiceIsSaidAsTheMacsListSaysIt() throws {
        let sources = try Self.macSettingsSources()
        XCTAssertTrue(
            sources.contains(".accessibilityLabel(SettingsWording.voiceLabel(name: voice.name, quality: settingsViewModel.voiceQualityLabel(voice)))")
        )
        XCTAssertEqual(SettingsWording.voiceLabel(name: "Samantha", quality: "Enhanced"), "Samantha, Enhanced quality")
        XCTAssertEqual(
            PhoneVoiceVocabulary.voiceChoice(name: "Samantha", quality: "Enhanced"),
            SettingsWording.voiceLabel(name: "Samantha", quality: "Enhanced")
        )
    }
}
