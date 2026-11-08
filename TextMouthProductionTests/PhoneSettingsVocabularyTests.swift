import XCTest
@testable import TextMouth

/// The phone's Settings screen says what the Mac's says: each word
/// `PhoneSettingsVocabulary` holds for the phone must stand in the Mac's own
/// settings views, word for word, so the two can't drift apart unnoticed.
///
/// Nothing is run on the Mac's views here: the test reads their source, as
/// `LogContentPolicyTests` and `UncheckedConcurrencyPolicyTests` read the
/// app's source, through the same folder (`AppSourceFile.folder`).
final class PhoneSettingsVocabularyTests: XCTestCase {
    /// The Mac's views that hold the words inline, read from the app's source
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

    /// Every word is in the Mac's source as a whole string, so "Voice" isn't
    /// satisfied by "Voice language" or by a comment.
    func testEveryWordStandsInTheMacsViewsWordForWord() throws {
        let sources = try Self.macSettingsSources()
        for word in PhoneSettingsVocabulary.allCases {
            XCTAssertTrue(
                sources.contains("\"\(word.rawValue)\""),
                "The Mac's settings views no longer say \"\(word.rawValue)\" (\(word))."
            )
        }
    }

    /// The enumeration really holds the settings' words: one emptied by
    /// accident would pass the test above having checked nothing.
    func testTheVocabularyHoldsEveryKindOfWordTheSpecLists() {
        let words = Set(PhoneSettingsVocabulary.allCases.map(\.rawValue))
        XCTAssertGreaterThanOrEqual(words.count, 43)
        for expected in ["Voice", "Navigation", "Punctuation pause level", "Heavy", "Confirm before removing a book"] {
            XCTAssertTrue(words.contains(expected), "\(expected) is missing")
        }
    }

    /// A speed's words are the Mac's: its slider's value interpolates the
    /// speed as a whole number before the same words.
    func testASpeedIsSaidAsTheMacsSliderSaysIt() throws {
        let sources = try Self.macSettingsSources()
        XCTAssertTrue(sources.contains(#".accessibilityValue("\(Int(settingsViewModel.wordsPerMinute)) words per minute")"#))
        XCTAssertEqual(PhoneVoiceVocabulary.speedValue(wordsPerMinute: 200), "200 words per minute")
        XCTAssertEqual(PhoneVoiceVocabulary.speedValue(wordsPerMinute: 650), "650 words per minute")
    }

    /// A voice's words are the Mac's: its list of voices names each one by
    /// its name and its quality, in this form.
    func testAVoiceIsSaidAsTheMacsListSaysIt() throws {
        let sources = try Self.macSettingsSources()
        XCTAssertTrue(
            sources.contains(#".accessibilityLabel("\(voice.name), \(settingsViewModel.voiceQualityLabel(voice)) quality")"#)
        )
        XCTAssertEqual(
            PhoneVoiceVocabulary.voiceChoice(name: "Samantha", quality: "Enhanced"),
            "Samantha, Enhanced quality"
        )
    }
}
