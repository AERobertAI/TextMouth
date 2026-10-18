import XCTest
@testable import TextMouth

/// The setting that keeps the original of audio an import converts (FMT14):
/// the setting, its words, and (further down) what an import does with it.
/// Every file these tests touch lives in a folder of their own.
@MainActor
final class ConvertedOriginalTests: XCTestCase {
    // MARK: - The setting

    /// A fresh configuration keeps no originals: only imports made while the
    /// user has turned the setting on keep anything.
    func testTheSettingIsOffByDefault() {
        XCTAssertFalse(ConfigService.AppConfig().keepsOriginalOfConvertedAudio)
    }

    /// The setting is written to config.json under its own name and read back.
    func testTheSettingRoundTripsThroughTheConfigFile() throws {
        var config = ConfigService.AppConfig()
        config.keepsOriginalOfConvertedAudio = true

        let data = try ConfigService.fileData(for: config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["keepsOriginalOfConvertedAudio"] as? Bool, true)

        let decoded = try JSONDecoder().decode(ConfigService.AppConfig.self, from: data)
        XCTAssertTrue(decoded.keepsOriginalOfConvertedAudio)
    }

    /// A config.json written before the setting existed reads as off.
    func testAFileWithoutTheKeyReadsAsOff() throws {
        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data(#"{"wordsPerMinute": 200}"#.utf8)
        )
        XCTAssertFalse(decoded.keepsOriginalOfConvertedAudio)
    }

    /// A wrongly typed value falls back to off instead of failing the file.
    func testAWronglyTypedValueReadsAsOff() throws {
        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data(#"{"keepsOriginalOfConvertedAudio": "yes"}"#.utf8)
        )
        XCTAssertFalse(decoded.keepsOriginalOfConvertedAudio)
    }

    /// The settings model reads and saves the setting through config.json,
    /// and announces a change made to the file itself, so the control always
    /// shows the choice in force.
    func testTheSettingsModelSavesAndAnnouncesTheSetting() throws {
        let model = try makeIsolatedSettings("keeporig-settings")
        XCTAssertFalse(model.keepsOriginalOfConvertedAudio)

        model.keepsOriginalOfConvertedAudio = true
        XCTAssertTrue(model.keepsOriginalOfConvertedAudio)

        // A change made to the configuration itself reaches the model's
        // subscribers (the control redraws from it).
        var announced = 0
        let subscription = model.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }
        model.keepsOriginalOfConvertedAudio = false
        XCTAssertFalse(model.keepsOriginalOfConvertedAudio)
        XCTAssertGreaterThan(announced, 0)
    }

    // MARK: - The words

    /// The control's label, hint, and both captions, word for word.
    func testTheWordsAreAsAgreed() {
        XCTAssertEqual(ConvertedOriginalWording.label, "Keep originals of converted audio")
        XCTAssertEqual(
            ConvertedOriginalWording.hint,
            "Also keeps each audio file that an import converts, such as Ogg or AC-3, inside the book's package."
        )
        XCTAssertEqual(
            ConvertedOriginalWording.caption(keeping: true),
            "Audio that TextMouth converts at import keeps its original file too, which takes about as much disk "
                + "space again. Export offers it as the Original file. Feed episodes are not kept: they can be "
                + "downloaded again."
        )
        XCTAssertEqual(
            ConvertedOriginalWording.caption(keeping: false),
            "Audio that TextMouth converts at import keeps only the converted file."
        )
    }
}
