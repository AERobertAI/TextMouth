import AVFoundation
import XCTest
@testable import TextMouth

/// The decisions of the phone's Settings screen, which can't run here: its
/// sections and rows in the spec's order and words, what each slider and
/// stepper says and does, and what the choice rows offer.
@MainActor
final class PhoneSettingsModelTests: XCTestCase {

    // MARK: - Sections and Rows

    /// The screen's headings are the spec's, in its order as the outside
    /// reviews left it: Navigation in Skip Controls' place, and Reading, new,
    /// after Sleep Timer.
    func testTheSectionsAreInTheSpecsOrderAndWords() {
        XCTAssertEqual(
            PhoneSettingsSection.allCases.map(\.title),
            [
                "Voice", "Navigation", "Rewind on Resume", "Punctuation Pauses", "End of Book", "Sleep Timer",
                "Reading", "Times", "Pages", "Removal Behavior", "Statistics", "About",
            ]
        )
    }

    /// Each row shows one set of words and VoiceOver hears another, as on the
    /// Mac, and a hint says what the row does.
    func testEachRowSaysTheSpecsWords() {
        let expected: [(row: PhoneSettingsRow, title: String, label: String, hint: String?)] = [
            (.language, "Language", "Voice language", nil),
            (.voice, "Voice", "Select voice", "Choose a voice for reading. Change takes effect immediately."),
            (
                .textNavigationUnit, "Navigation unit for text books", "Navigation unit for text books",
                "What a book of this kind moves by until it has a unit of its own."
            ),
            (
                .audioNavigationUnit, "Navigation unit for audiobooks", "Navigation unit for audiobooks",
                "What a book of this kind moves by until it has a unit of its own."
            ),
            (
                .rewindTo, "Rewind to", "Rewind on resume unit",
                "When resuming playback, rewind to the start of this unit"
            ),
            (.endOfBook, "When book ends", "End of book behavior", "What happens when a book finishes playing"),
            (.readingStatistics, "Reading Statistics", "Reading Statistics", nil),
            (
                .shareLogs, "Share Logs…", "Share Logs…",
                "Shares TextMouth's recent logs as a text file. They hold no book text."
            ),
        ]
        for entry in expected {
            XCTAssertEqual(entry.row.title, entry.title)
            XCTAssertEqual(entry.row.label, entry.label)
            XCTAssertEqual(entry.row.hint, entry.hint)
        }
    }

    /// The sentence for no voices is the spec's, word for word.
    func testTheSentenceForNoVoicesIsTheSpecs() {
        XCTAssertEqual(
            PhoneSettingsWording.noVoicesInstalled,
            "No voices are installed. Add voices in Settings, Accessibility, Read & Speak."
        )
    }

    // MARK: - What Sliders and Steppers Say

    /// Each control is called what the spec calls it, and says its value with
    /// its unit.
    func testEachAdjustmentSaysItsValueWithItsUnit() {
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.label, "Default speed")
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.words(200), "200 words per minute")

        XCTAssertEqual(PhoneSettingsAdjustment.defaultPitch.label, "Default pitch")
        XCTAssertEqual(PhoneSettingsAdjustment.defaultPitch.words(1), "Normal (1.0x)")
        XCTAssertEqual(PhoneSettingsAdjustment.defaultPitch.words(1.5), "1.5x")

        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.label, "Minimum pause threshold")
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.words(70), "70 seconds")

        XCTAssertEqual(PhoneSettingsAdjustment.punctuationPauseLevel.label, "Punctuation pause level")
        XCTAssertEqual(
            [0.0, 1, 2, 3].map(PhoneSettingsAdjustment.punctuationPauseLevel.words),
            ["Off", "Subtle", "Moderate", "Heavy"]
        )

        XCTAssertEqual(PhoneSettingsAdjustment.fadeOutDuration.label, "Fade out duration")
        XCTAssertEqual(PhoneSettingsAdjustment.fadeOutDuration.words(0), "Off")
        XCTAssertEqual(PhoneSettingsAdjustment.fadeOutDuration.words(1), "1 second")
        XCTAssertEqual(PhoneSettingsAdjustment.fadeOutDuration.words(5), "5 seconds")
    }

    /// The hints are the Mac's captions, which the spec gives word for word.
    func testEachAdjustmentsHintIsTheMacsCaption() {
        XCTAssertEqual(
            PhoneSettingsAdjustment.defaultSpeed.hint,
            "Default speed for new books. Each book can override this with its own speed."
        )
        XCTAssertEqual(
            PhoneSettingsAdjustment.defaultPitch.hint,
            "Default pitch for new books. 1.0 is normal. Each book can override this."
        )
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.hint, "Don't rewind if paused for less than this.")
        XCTAssertEqual(
            PhoneSettingsAdjustment.punctuationPauseLevel.hint,
            "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)"
        )
        XCTAssertEqual(
            PhoneSettingsAdjustment.fadeOutDuration.hint,
            "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly."
        )
    }

    /// A level out of range names the nearest level rather than trapping.
    func testAPunctuationLevelOutOfRangeNamesTheNearestLevel() {
        XCTAssertEqual(PhoneSettingsAdjustment.punctuationPauseLevel.words(-1), "Off")
        XCTAssertEqual(PhoneSettingsAdjustment.punctuationPauseLevel.words(9), "Heavy")
    }

    // MARK: - What a Step Does

    /// The Mac spells the steps of its sliders and steppers inline, and the
    /// phone's move by the same steps, over the same ranges.
    func testTheRangesAndStepsAreTheMacs() throws {
        // Whitespace is squeezed out, since the Mac's calls span several lines.
        let sources = try PhoneSettingsVocabularyTests.macSettingsSources().filter { !$0.isWhitespace }
        XCTAssertTrue(sources.contains("in:50...650,step:25"), "the Mac's speed slider")
        XCTAssertTrue(sources.contains("in:0.5...2.0,step:0.1"), "the Mac's pitch slider")
        XCTAssertTrue(sources.contains("in:5...600,step:5"), "the Mac's pause stepper")
        XCTAssertTrue(sources.contains("in:0...3,step:1"), "the Mac's pause level slider")
        XCTAssertTrue(sources.contains("in:0...10,step:1"), "the Mac's fade stepper")

        let adjustments: [(PhoneSettingsAdjustment, ClosedRange<Double>, Double)] = [
            (.defaultSpeed, 50...650, 25),
            (.defaultPitch, 0.5...2.0, 0.1),
            (.minimumPause, 5...600, 5),
            (.punctuationPauseLevel, 0...3, 1),
            (.fadeOutDuration, 0...10, 1),
        ]
        for (adjustment, range, step) in adjustments {
            XCTAssertEqual(adjustment.range, range, adjustment.label)
            XCTAssertEqual(adjustment.step, step, adjustment.label)
        }
    }

    /// One step moves by the Mac's step, either way.
    func testOneStepMovesByTheStep() {
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.value(after: 200, going: .up), 225)
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.value(after: 200, going: .down), 175)
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.value(after: 70, going: .up), 75)
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.value(after: 70, going: .down), 65)
        XCTAssertEqual(PhoneSettingsAdjustment.punctuationPauseLevel.value(after: 1, going: .up), 2)
        XCTAssertEqual(PhoneSettingsAdjustment.fadeOutDuration.value(after: 0, going: .up), 1)
    }

    /// Pitch moves in tenths, which binary fractions can't hold exactly: a
    /// step lands on the very value the decimal names, and none is lost going
    /// down from a value that came out a little high.
    func testAStepOfATenthLandsExactly() {
        let pitch = PhoneSettingsAdjustment.defaultPitch
        XCTAssertEqual(pitch.value(after: 1.1, going: .up), 1.2)
        XCTAssertEqual(pitch.value(after: 1.1, going: .down), 1.0)
        // What adding tenths one at a time leaves behind.
        XCTAssertEqual(pitch.value(after: 0.5 + 0.1 * 6, going: .down), 1.0)
        XCTAssertEqual(pitch.value(after: 0.5 + 0.1 * 6, going: .up), 1.2)
    }

    /// A step at either end of the range stays there.
    func testAStepNeverLeavesTheRange() {
        let cases: [(PhoneSettingsAdjustment, Double, PhoneSettingsAdjustment.Direction)] = [
            (.defaultSpeed, 650, .up), (.defaultSpeed, 50, .down),
            (.defaultPitch, 2, .up), (.defaultPitch, 0.5, .down),
            (.minimumPause, 600, .up), (.minimumPause, 5, .down),
            (.punctuationPauseLevel, 3, .up), (.punctuationPauseLevel, 0, .down),
            (.fadeOutDuration, 10, .up), (.fadeOutDuration, 0, .down),
        ]
        for (adjustment, value, direction) in cases {
            XCTAssertEqual(adjustment.value(after: value, going: direction), value, adjustment.label)
        }
    }

    /// A value between two steps, as config.json can hold, moves to the next
    /// step in the direction asked, not past it.
    func testAValueBetweenStepsMovesToTheNearerStep() {
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.value(after: 72, going: .up), 75)
        XCTAssertEqual(PhoneSettingsAdjustment.minimumPause.value(after: 72, going: .down), 70)
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.value(after: 210, going: .up), 225)
        XCTAssertEqual(PhoneSettingsAdjustment.defaultSpeed.value(after: 210, going: .down), 200)
    }

    /// Stepping from the bottom reaches the top in exactly the number of steps
    /// the range holds, each a value the setting accepts, and comes back.
    func testEveryStepOfEveryRangeIsReachedInBothDirections() {
        let adjustments: [(PhoneSettingsAdjustment, steps: Int)] = [
            (.defaultSpeed, 24), (.defaultPitch, 15), (.minimumPause, 119),
            (.punctuationPauseLevel, 3), (.fadeOutDuration, 10),
        ]
        for (adjustment, steps) in adjustments {
            var value = adjustment.range.lowerBound
            for _ in 0..<steps {
                value = adjustment.value(after: value, going: .up)
            }
            XCTAssertEqual(value, adjustment.range.upperBound, adjustment.label)
            for _ in 0..<steps {
                value = adjustment.value(after: value, going: .down)
            }
            XCTAssertEqual(value, adjustment.range.lowerBound, adjustment.label)
        }
    }

    // MARK: - Switches

    /// Each switch has the spec's title, label, and hint, and the hint stands
    /// under it for the eye only where the Mac shows one.
    func testEachSwitchSaysTheSpecsWords() {
        let expected: [(item: PhoneSettingsSwitch, title: String, label: String, hint: String?, caption: Bool)] = [
            (
                .smartMode, "Smart mode", "Smart rewind mode",
                "Only rewind if the pause was longer than the threshold", false
            ),
            (
                .autoPlayAfterNavigation, "Auto-play after navigation", "Auto-play after navigation",
                "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result",
                true
            ),
            (
                .closeSleepTimerSheet,
                "Close sleep timer sheet after setting a timer",
                "Close sleep timer sheet after setting a timer",
                "When off, the sheet stays open showing the remaining time and a reset button",
                false
            ),
            (
                .includeSpeedWithTimes, ReaderTimeWording.settingTitle, ReaderTimeWording.settingTitle,
                ReaderTimeWording.settingHint, true
            ),
            (
                .showPageInReader, ReaderPageWording.showInReaderTitle, ReaderPageWording.showInReaderTitle,
                ReaderPageWording.showInReaderHint, true
            ),
            (
                .sayPageInWhereAmI, ReaderPageWording.sayInWhereAmITitle, ReaderPageWording.sayInWhereAmITitle,
                ReaderPageWording.sayInWhereAmIHint, true
            ),
            (
                .followInBraille, "Follow in Braille", "Follow in Braille",
                "While the book plays, moves Book content on with the speech, even while you're reading it. "
                    + "For trying out with a braille display.",
                true
            ),
            (.confirmBeforeRemoving, "Confirm before removing a book", "Confirm before removing a book", nil, false),
        ]
        for entry in expected {
            XCTAssertEqual(entry.item.title, entry.title)
            XCTAssertEqual(entry.item.label, entry.label)
            XCTAssertEqual(entry.item.hint, entry.hint)
            XCTAssertEqual(entry.item.showsHintAsCaption, entry.caption, entry.title)
        }
    }

    // MARK: - Fixed Lists

    /// A text book can move by every one of the Mac's units, in its order.
    func testTextBooksOfferEveryUnit() {
        let choices = PhoneSettingsModel.textNavigationUnitChoices
        XCTAssertEqual(choices.map(\.id), SkipUnit.allCases)
        XCTAssertEqual(
            choices.map(\.label),
            [
                "10 seconds", "15 seconds", "30 seconds", "60 seconds", "Sentence", "Paragraph", "Page", "Heading",
                "Subheading", "Bookmark",
            ]
        )
    }

    /// An audiobook can't move by Sentence or Paragraph, having no text to
    /// stop at; the rest are offered in the Mac's order.
    func testAudiobooksOfferEveryUnitButSentenceAndParagraph() {
        let choices = PhoneSettingsModel.audioNavigationUnitChoices
        XCTAssertEqual(
            choices.map(\.label),
            ["10 seconds", "15 seconds", "30 seconds", "60 seconds", "Page", "Heading", "Subheading", "Bookmark"]
        )
        XCTAssertEqual(choices.map(\.id), PhoneSettingsModel.audioNavigationUnits)
    }

    /// Rewind to offers the spec's four units.
    func testRewindToOffersTheSpecsUnits() {
        let choices = PhoneSettingsModel.rewindChoices
        XCTAssertEqual(choices.map(\.id), RewindUnit.allCases)
        XCTAssertEqual(choices.map(\.label), ["None", "Sentence", "Paragraph", "Heading"])
    }

    /// When book ends offers the spec's four choices.
    func testWhenBookEndsOffersTheSpecsChoices() {
        let choices = PhoneSettingsModel.endOfBookChoices
        XCTAssertEqual(choices.map(\.id), EndOfBookBehavior.allCases)
        XCTAssertEqual(
            choices.map(\.label),
            ["Stop", "Stop, and Play Starts Over", "Loop to Start", "Continue to Next Book"]
        )
    }

    /// No fixed choice is dimmed or needs a hint of its own.
    func testTheFixedChoicesAreAllEnabled() {
        XCTAssertTrue(PhoneSettingsModel.textNavigationUnitChoices.allSatisfy(\.isEnabled))
        XCTAssertTrue(PhoneSettingsModel.audioNavigationUnitChoices.allSatisfy(\.isEnabled))
        XCTAssertTrue(PhoneSettingsModel.rewindChoices.allSatisfy(\.isEnabled))
        XCTAssertTrue(PhoneSettingsModel.endOfBookChoices.allSatisfy(\.isEnabled))
    }

    // MARK: - Language

    /// "All" comes first, with no code, then each language by its name.
    func testLanguageChoicesStartWithAll() {
        let english = Locale(identifier: "en_US")
        let choices = PhoneSettingsModel.languageChoices(["en", "fr"], locale: english)
        XCTAssertEqual(choices.map(\.id), ["", "en", "fr"])
        XCTAssertEqual(choices.map(\.label), ["All", "English", "French"])
    }

    /// With no languages listed yet, "All" is still there.
    func testLanguageChoicesWithNoLanguagesOfferAll() {
        let choices = PhoneSettingsModel.languageChoices([])
        XCTAssertEqual(choices.map(\.label), ["All"])
    }

    /// The row says the same name as its choice, and a code the system can't
    /// name is said as it is rather than left blank.
    func testALanguagesNameFollowsItsCode() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(PhoneSettingsModel.languageName("", locale: english), "All")
        XCTAssertEqual(PhoneSettingsModel.languageName("de", locale: english), "German")
        XCTAssertEqual(PhoneSettingsModel.languageName("zz", locale: english), "zz")
    }

    /// Choosing a language keeps it and offers its voices at once, leaving the
    /// voice chosen as it is, as on the Mac.
    func testChoosingALanguageOffersItsVoicesAndKeepsTheVoice() async throws {
        let installed = VoiceCatalog.installedVoices()
        let languages = Set(installed.map { String($0.language.prefix(2)) })
        guard languages.count >= 2, let voice = installed.first else {
            throw XCTSkip("This Mac needs voices of two languages")
        }
        let otherLanguage = try XCTUnwrap(languages.subtracting([String(voice.language.prefix(2))]).sorted().first)
        let settings = try makeSettings(installing: installed)
        settings.selectedVoiceID = voice.identifier

        PhoneSettingsModel.chooseLanguage(otherLanguage, in: settings)

        XCTAssertEqual(settings.selectedLanguage, otherLanguage)
        XCTAssertFalse(settings.availableVoices.isEmpty)
        XCTAssertTrue(settings.availableVoices.allSatisfy { $0.language.hasPrefix(otherLanguage) })
        XCTAssertEqual(settings.selectedVoiceID, voice.identifier)

        PhoneSettingsModel.chooseLanguage("", in: settings)

        XCTAssertEqual(settings.selectedLanguage, "")
        XCTAssertEqual(settings.availableVoices.count, installed.count)
    }

    // MARK: - Voices

    /// A Personal Voice isn't offered, since rendering can't use it, whether
    /// it's of the language chosen or among the others.
    func testAPersonalVoiceIsNotOffered() {
        let offer = PhoneSettingsVoiceOffer(
            current: Self.samantha,
            forLanguage: [Self.samantha, Self.personal],
            installed: [Self.samantha, Self.personal, Self.thomas],
            hasListed: true
        )
        XCTAssertEqual(offer.choices.map(\.id), ["samantha"])
        XCTAssertEqual(offer.choices.map(\.label), ["Samantha, Enhanced quality"])
        XCTAssertTrue(offer.canOpen)
    }

    /// The row says the voice chosen, in the choice's words.
    func testTheRowSaysTheCurrentVoice() {
        let offer = PhoneSettingsVoiceOffer(
            current: Self.samantha,
            forLanguage: [Self.samantha],
            installed: [Self.samantha],
            hasListed: true
        )
        XCTAssertEqual(offer.rowValue, "Samantha, Enhanced quality")
    }

    /// A voice of another language is still named as the current one, though
    /// the language offers others: only choosing changes it.
    func testTheRowNamesAVoiceTheLanguageDoesntOffer() {
        let offer = PhoneSettingsVoiceOffer(
            current: Self.thomas,
            forLanguage: [Self.samantha],
            installed: [Self.samantha, Self.thomas],
            hasListed: true
        )
        XCTAssertEqual(offer.rowValue, "Thomas, Standard quality")
        XCTAssertEqual(offer.choices.map(\.id), ["samantha"])
    }

    /// With no voices at all, the row says so, and doesn't open an empty sheet.
    func testWithNoVoicesTheRowSaysSoAndDoesntOpen() {
        let offer = PhoneSettingsVoiceOffer(current: nil, forLanguage: [], installed: [], hasListed: true)
        XCTAssertEqual(offer.rowValue, PhoneSettingsWording.noVoicesInstalled)
        XCTAssertFalse(offer.canOpen)
        XCTAssertTrue(offer.choices.isEmpty)
    }

    /// A voice can't be offered when the only one is the person's own, and
    /// that's what the row says then too.
    func testWithOnlyAPersonalVoiceTheRowSaysThereAreNone() {
        let offer = PhoneSettingsVoiceOffer(
            current: Self.personal,
            forLanguage: [Self.personal],
            installed: [Self.personal],
            hasListed: true
        )
        XCTAssertEqual(offer.rowValue, PhoneSettingsWording.noVoicesInstalled)
        XCTAssertFalse(offer.canOpen)
    }

    /// A language with no voices of its own offers the other languages'
    /// voices, since saying none are installed would be false.
    func testALanguageWithNoVoicesOffersTheOthers() {
        let offer = PhoneSettingsVoiceOffer(
            current: nil,
            forLanguage: [],
            installed: [Self.samantha, Self.thomas],
            hasListed: true
        )
        XCTAssertEqual(offer.choices.map(\.id), ["samantha", "thomas"])
        XCTAssertTrue(offer.canOpen)
        XCTAssertEqual(offer.rowValue, "")
    }

    /// A language whose only voice is the person's own does the same.
    func testALanguageWithOnlyAPersonalVoiceOffersTheOthers() {
        let offer = PhoneSettingsVoiceOffer(
            current: nil,
            forLanguage: [Self.personal],
            installed: [Self.personal, Self.thomas],
            hasListed: true
        )
        XCTAssertEqual(offer.choices.map(\.id), ["thomas"])
    }

    /// Before the voices are first listed, an empty list means nothing: the
    /// row doesn't say there are none, and its sheet fills when they arrive.
    func testBeforeTheVoicesAreListedTheRowDoesntSayThereAreNone() {
        let offer = PhoneSettingsVoiceOffer(current: Self.samantha, forLanguage: [], installed: [], hasListed: false)
        XCTAssertEqual(offer.rowValue, "Samantha, Enhanced quality")
        XCTAssertTrue(offer.canOpen)
    }

    /// A voice from the system is read through its own properties, the trait
    /// that says whether it's a Personal Voice included.
    func testASystemVoiceIsReadThroughItsProperties() throws {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first else {
            throw XCTSkip("This Mac has no voices")
        }
        let read = PhoneSettingsVoice(voice)
        XCTAssertEqual(read.identifier, voice.identifier)
        XCTAssertEqual(read.name, voice.name)
        XCTAssertEqual(read.quality, voice.qualityLabel)
        XCTAssertEqual(read.isPersonal, voice.voiceTraits.contains(.isPersonalVoice))
    }

    // MARK: - What Applies Now

    /// Smart mode applies only while something is rewound.
    func testSmartModeAppliesOnlyWhileSomethingIsRewound() {
        XCTAssertFalse(PhoneSettingsModel.isSmartModeAvailable(rewindUnit: .none))
        for unit in [RewindUnit.sentence, .paragraph, .heading] {
            XCTAssertTrue(PhoneSettingsModel.isSmartModeAvailable(rewindUnit: unit), unit.rawValue)
        }
    }

    /// The minimum pause applies only while Smart mode applies and is on.
    func testTheMinimumPauseAppliesOnlyWithSmartModeOn() {
        XCTAssertTrue(PhoneSettingsModel.isMinimumPauseAvailable(rewindUnit: .sentence, smartMode: true))
        XCTAssertFalse(PhoneSettingsModel.isMinimumPauseAvailable(rewindUnit: .sentence, smartMode: false))
        XCTAssertFalse(PhoneSettingsModel.isMinimumPauseAvailable(rewindUnit: .none, smartMode: true))
        XCTAssertFalse(PhoneSettingsModel.isMinimumPauseAvailable(rewindUnit: .none, smartMode: false))
    }

    // MARK: - Preview

    /// The preview says the Mac's sentence, at the speed and pitch given, as
    /// the Mac's does. It's only made here, never spoken.
    func testThePreviewSaysTheMacsSentenceAtTheSpeedAndPitchGiven() {
        let utterance = PhoneSettingsModel.previewUtterance(voiceID: "no such voice", wordsPerMinute: 300, pitch: 1.5)
        XCTAssertEqual(utterance.speechString, "Hello! This is TextMouth, ready to read for you.")
        XCTAssertEqual(utterance.rate, SpeechService.rateForWPM(300))
        XCTAssertEqual(utterance.pitchMultiplier, 1.5)
    }

    /// A pitch out of the range speech takes is brought into it.
    func testThePreviewKeepsThePitchInRange() {
        let utterance = PhoneSettingsModel.previewUtterance(voiceID: "no such voice", wordsPerMinute: 200, pitch: 5)
        XCTAssertEqual(utterance.pitchMultiplier, 2)
    }

    /// The preview uses the voice chosen.
    func testThePreviewUsesTheVoiceChosen() throws {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first else {
            throw XCTSkip("This Mac has no voices")
        }
        let utterance = PhoneSettingsModel.previewUtterance(
            voiceID: voice.identifier,
            wordsPerMinute: 200,
            pitch: 1
        )
        XCTAssertEqual(utterance.voice?.identifier, voice.identifier)
    }

    // MARK: - Support

    /// A voice of the language chosen.
    private static let samantha = PhoneSettingsVoice(identifier: "samantha", name: "Samantha", quality: "Enhanced")
    /// A voice of another language.
    private static let thomas = PhoneSettingsVoice(identifier: "thomas", name: "Thomas", quality: "Standard")
    /// The person's own voice.
    private static let personal = PhoneSettingsVoice(
        identifier: "personal",
        name: "My Voice",
        quality: "Standard",
        isPersonal: true
    )

    /// A Settings model of this test's own, in this test's sandbox, offering
    /// `voices`, which it has already listed. Nothing here speaks.
    private func makeSettings(installing voices: [AVSpeechSynthesisVoice]) throws -> SettingsViewModel {
        let catalog = VoiceCatalog(notificationCenter: NotificationCenter(), listVoices: { voices })
        catalog.listNow()
        let folder = try makeSandboxDirectory("PhoneSettingsModel")
        let configService = ConfigService(fileURL: folder.appendingPathComponent("config.json"))
        addTeardownBlock { configService.shutdown() }
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("PhoneSettingsModel"),
            configService: configService,
            voiceCatalog: catalog
        )
    }
}
