import XCTest
@testable import TextMouth

/// `PhoneVoiceModel`: the phone's Voice & Speed sheet's choices, sliders,
/// and words, by the spec's "The Voice & Speed sheet".
@MainActor
final class PhoneVoiceModelTests: XCTestCase {
    /// Four voices: two English, one French, and a Personal Voice.
    private let samantha = PhoneVoiceOption(
        identifier: "com.apple.voice.enhanced.en-US.Samantha",
        name: "Samantha",
        qualityLabel: "Enhanced",
        language: "en-US",
        isPersonalVoice: false
    )
    private let daniel = PhoneVoiceOption(
        identifier: "com.apple.voice.compact.en-GB.Daniel",
        name: "Daniel",
        qualityLabel: "Standard",
        language: "en-GB",
        isPersonalVoice: false
    )
    private let thomas = PhoneVoiceOption(
        identifier: "com.apple.voice.compact.fr-FR.Thomas",
        name: "Thomas",
        qualityLabel: "Standard",
        language: "fr-FR",
        isPersonalVoice: false
    )
    private let personal = PhoneVoiceOption(
        identifier: "personal.voice",
        name: "My Voice",
        qualityLabel: "Premium",
        language: "de-DE",
        isPersonalVoice: true
    )

    /// A model of the four, filtered by `language`.
    private func model(language: String = "") -> PhoneVoiceModel {
        PhoneVoiceModel(installed: [samantha, daniel, thomas, personal], selectedLanguage: language)
    }

    /// A namer that shows which code it was given.
    private nonisolated static func named(_ code: String) -> String {
        "Language \(code)"
    }

    // MARK: Languages and voices

    /// A Personal Voice isn't listed, nor its language.
    func testAPersonalVoiceIsntListed() {
        XCTAssertEqual(model().voices, [samantha, daniel, thomas])
        XCTAssertEqual(model().languageCodes, ["en", "fr"])
    }

    /// The Language choices are "All", then each language by name.
    func testTheLanguageChoicesStartWithAll() {
        let choices = model().languageChoices(naming: Self.named)

        XCTAssertEqual(choices.map(\.id), ["", "en", "fr"])
        XCTAssertEqual(choices.map(\.label), ["All", "Language en", "Language fr"])
        XCTAssertEqual(model().languageValue(naming: Self.named), "All")
        XCTAssertEqual(model(language: "fr").languageValue(naming: Self.named), "Language fr")
    }

    /// The sheet opens on the current voice's language, else every one.
    func testTheSheetOpensOnTheVoicesLanguage() {
        XCTAssertEqual(PhoneVoiceModel.openingLanguage(currentVoiceLanguage: "en-US"), "en")
        XCTAssertEqual(PhoneVoiceModel.openingLanguage(currentVoiceLanguage: nil), "")
    }

    /// The Voice choices are the language's voices, each read as the Mac's
    /// picker reads it.
    func testTheVoiceChoicesAreTheLanguagesInTheMacsWords() {
        XCTAssertEqual(model(language: "en").voiceChoices.map(\.label), ["Samantha, Enhanced quality", "Daniel, Standard quality"])
        XCTAssertEqual(model().voiceChoices.map(\.id), [samantha.identifier, daniel.identifier, thomas.identifier])
    }

    /// The Voice row's value is the current voice's choice; a voice not
    /// offered has none.
    func testTheVoiceValueIsTheCurrentVoice() {
        XCTAssertEqual(model().voiceValue(identifier: samantha.identifier), "Samantha, Enhanced quality")
        XCTAssertNil(model().voiceValue(identifier: personal.identifier))
        XCTAssertNil(model().voiceValue(identifier: nil))
    }

    /// The list says no voice is installed only once the voices have loaded.
    func testNoVoicesIsSaidOnlyOnceLoaded() {
        let empty = PhoneVoiceModel(installed: [personal], selectedLanguage: "")

        XCTAssertFalse(empty.saysNoVoices(isLoaded: false))
        XCTAssertTrue(empty.saysNoVoices(isLoaded: true))
        XCTAssertFalse(model().saysNoVoices(isLoaded: true))
        XCTAssertEqual(PhoneVoiceWording.noVoices, "No voices are installed. Add voices in Settings, Accessibility, Read & Speak.")
    }

    // MARK: The sliders

    /// The speed moves by the reader's 25 words a minute, from 50 to 650.
    func testTheSpeedMovesByTheReadersStep() {
        XCTAssertEqual(PhoneVoiceModel.speedStep, ReaderViewModel.speechSpeedStep)
        XCTAssertEqual(PhoneVoiceModel.steppedSpeed(212), 200)
        XCTAssertEqual(PhoneVoiceModel.steppedSpeed(213), 225)
        XCTAssertEqual(PhoneVoiceModel.steppedSpeed(10), 50)
        XCTAssertEqual(PhoneVoiceModel.steppedSpeed(700), 650)
        XCTAssertEqual(PhoneVoiceVocabulary.speedValue(wordsPerMinute: 200), "200 words per minute")
    }

    /// The pitch moves by tenths, from 0.5 to 2, read in the Mac's words.
    func testThePitchMovesByTenths() {
        XCTAssertEqual(PhoneVoiceModel.steppedPitch(1.04), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PhoneVoiceModel.steppedPitch(3), 2.0, accuracy: 0.0001)
        XCTAssertEqual(PhoneVoiceModel.steppedPitch(0.1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SpeechService.pitchLabel(PhoneVoiceModel.steppedPitch(1.04)), "Normal (1.0x)")
    }

    // MARK: When this book ends

    /// The choices are the Mac's behaviors, then Use Global Default.
    func testTheEndOfBookChoicesEndWithTheGlobalDefault() {
        let choices = PhoneVoiceModel.endOfBookChoices

        XCTAssertEqual(choices.map(\.label), EndOfBookBehavior.allCases.map(\.title) + ["Use Global Default"])
        XCTAssertEqual(choices.last?.id, .some(nil))
        XCTAssertEqual(PhoneVoiceModel.endOfBookValue(effective: .continueNext), "Continue to Next Book")
    }
}

/// `PhoneVoiceVocabulary`: each word is the Mac's book voice sheet's, read
/// from its own source.
final class PhoneVoiceVocabularyTests: XCTestCase {
    /// Every inline word is in `BookVoicePickerView` as the phone has it.
    func testEveryWordIsTheMacsVoiceSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/ReaderView.swift"),
            encoding: .utf8
        )
        // The sheet says each word through `ReaderViewWording`, which the phone's word equals.
        let words: [(phone: String, mac: String, shown: String)] = [
            (PhoneVoiceVocabulary.languageFilterLabel, ReaderViewWording.languageFilterLabel,
             ".accessibilityLabel(ReaderViewWording.languageFilterLabel)"),
            (PhoneVoiceVocabulary.allLanguages, ReaderViewWording.allLanguages, "Text(ReaderViewWording.allLanguages).tag(\"\")"),
            (PhoneVoiceVocabulary.voiceLabel, ReaderViewWording.selectVoiceLabel, ".accessibilityLabel(ReaderViewWording.selectVoiceLabel)"),
            (PhoneVoiceVocabulary.previewTitle, ReaderViewWording.previewTitle, "Button(ReaderViewWording.previewTitle)"),
            (PhoneVoiceVocabulary.previewLabel, ReaderViewWording.previewLabel, ".accessibilityLabel(ReaderViewWording.previewLabel)"),
            (PhoneVoiceVocabulary.previewSentence, PhoneVoiceVocabulary.previewSentence,
             "AVSpeechUtterance(string: \"\(PhoneVoiceVocabulary.previewSentence)\")"),
            (PhoneVoiceVocabulary.speedLabel, ReaderViewWording.speedTitle, ".accessibilityLabel(ReaderViewWording.speedTitle)"),
            (PhoneVoiceVocabulary.pitchLabel, ReaderViewWording.pitchTitle, ".accessibilityLabel(ReaderViewWording.pitchTitle)"),
            (PhoneVoiceVocabulary.endOfBookTitle, ReaderViewWording.endOfBookTitle, "Picker(ReaderViewWording.endOfBookTitle"),
            (PhoneVoiceVocabulary.endOfBookLabel, ReaderViewWording.endOfBookLabel, ".accessibilityLabel(ReaderViewWording.endOfBookLabel)"),
            (PhoneVoiceVocabulary.useGlobalDefault, ReaderViewWording.useGlobalDefaultTitle, "Button(ReaderViewWording.useGlobalDefaultTitle)"),
            (PhoneAppWording.close, ReaderViewWording.closeTitle, "Button(ReaderViewWording.closeTitle)"),
            (PhoneVoiceVocabulary.voiceChoice(name: "Samantha", quality: "Enhanced"),
             ReaderViewWording.voiceSpoken(name: "Samantha", quality: "Enhanced"),
             ".accessibilityLabel(ReaderViewWording.voiceSpoken(name: voice.name, quality: voiceQualityLabel(voice)))"),
            (PhoneVoiceVocabulary.speedValue(wordsPerMinute: 175), PlaybackControlsWording.wordsPerMinute(175),
             ".accessibilityValue(PlaybackControlsWording.wordsPerMinute(Int(viewModel.speechService.wordsPerMinute)))"),
        ]

        for word in words {
            XCTAssertEqual(word.phone, word.mac, word.shown)
            XCTAssertTrue(macView.contains(word.shown), "The Mac's voice sheet no longer says \(word.shown)")
        }
        XCTAssertEqual(PhoneVoiceVocabulary.voiceChoice(name: "Samantha", quality: "Enhanced"), "Samantha, Enhanced quality")
    }

    /// A voice option reads its own choice label, which the Voice sheet and
    /// Settings' Voice row both say.
    func testAVoiceOptionSaysItsOwnChoiceLabel() {
        let option = PhoneVoiceOption(
            identifier: "com.apple.voice.enhanced.en-US.Samantha",
            name: "Samantha",
            qualityLabel: "Enhanced",
            language: "en-US",
            isPersonalVoice: false
        )
        XCTAssertEqual(option.choiceLabel, "Samantha, Enhanced quality")
    }
}
