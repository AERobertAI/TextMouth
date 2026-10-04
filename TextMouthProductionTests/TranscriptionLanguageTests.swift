import XCTest
@testable import TextMouth

/// The language transcription uses (FR05): a setting of each user, which is
/// the system's English until one is chosen, holds only identifiers that can
/// name a language, and travels in config.json as `transcriptionLocale`.
@MainActor
final class TranscriptionLanguageTests: XCTestCase {

    // MARK: - The Default

    /// Until a language is chosen, transcription uses English as the
    /// system's region writes it, or US English when the system names no
    /// region or speaks another language.
    func testUntilOneIsChosenTheLanguageIsTheSystemsEnglish() {
        XCTAssertEqual(TranscriptionLanguage.defaultIdentifier(for: Locale(identifier: "en_AU")), "en-AU")
        XCTAssertEqual(TranscriptionLanguage.defaultIdentifier(for: Locale(identifier: "en_GB")), "en-GB")
        XCTAssertEqual(TranscriptionLanguage.defaultIdentifier(for: Locale(identifier: "en")), "en-US")
        XCTAssertEqual(TranscriptionLanguage.defaultIdentifier(for: Locale(identifier: "de_DE")), "en-US")
        XCTAssertEqual(TranscriptionLanguage.defaultIdentifier, TranscriptionLanguage.defaultIdentifier(for: .current))
    }

    // MARK: - The Setting

    /// A store holding no language, or one that cannot name one, reads as
    /// the default; a language written reads back, an underscore read as
    /// the hyphen BCP 47 spells.
    func testTheSettingReadsAsAUsableIdentifier() {
        let store = makeSandboxedPreferences("transcription-language")
        let preference = TranscriptionLanguage.preference
        XCTAssertEqual(preference.key, "transcriptionLocale")
        XCTAssertEqual(preference.read(from: store), TranscriptionLanguage.defaultIdentifier)

        preference.write("en-NZ", to: store)
        XCTAssertEqual(preference.read(from: store), "en-NZ")
        store.set("en_IE", forKey: preference.key)
        XCTAssertEqual(preference.read(from: store), "en-IE")
        store.set("not a language", forKey: preference.key)
        XCTAssertEqual(preference.read(from: store), TranscriptionLanguage.defaultIdentifier)
        store.set(7, forKey: preference.key)
        XCTAssertEqual(preference.read(from: store), TranscriptionLanguage.defaultIdentifier)
    }

    /// An identifier is a language of two or three letters, then subtags of
    /// one to eight letters and digits, each after a hyphen.
    func testOnlyIdentifiersThatCanNameALanguageAreKept() {
        let usable: [(raw: String, kept: String)] = [
            ("en-US", "en-US"), ("en_GB", "en-GB"), (" en-AU ", "en-AU"), ("zh-Hant-TW", "zh-Hant-TW"),
            ("yue-CN", "yue-CN"), ("en-001", "en-001"), ("fr", "fr"),
        ]
        for (raw, kept) in usable {
            XCTAssertEqual(TranscriptionLanguage.validated(raw), kept, raw)
        }
        for unusable in ["", "e", "english", "en--US", "en-", "-US", "12-US", "en US", "en-ABCDEFGHI", "ën-US", "en-U$"] {
            XCTAssertNil(TranscriptionLanguage.validated(unusable), unusable)
        }
        XCTAssertNil(TranscriptionLanguage.validated(nil))
    }

    /// A language is named in messages as the system names it.
    func testALanguageIsNamedAsTheSystemNamesIt() {
        XCTAssertEqual(
            TranscriptionLanguage.name(of: "en-GB"),
            Locale.current.localizedString(forIdentifier: "en-GB")
        )
        XCTAssertFalse(TranscriptionLanguage.name(of: "en-GB").isEmpty)
    }

    // MARK: - config.json

    /// The language config.json gives is stored where transcription reads
    /// it, and saved back in its spelling; a store holding none is saved
    /// with the default, so the file always shows the language in force.
    func testTheLanguageIsAppliedFromAndSavedToConfigJSON() throws {
        let store = makeSandboxedPreferences("transcription-language-config")
        let viewModel = makeViewModel(store)
        var standard = ConfigService.AppConfig()
        viewModel.writePreferences(into: &standard)
        XCTAssertEqual(standard.transcriptionLocale, TranscriptionLanguage.defaultIdentifier)

        let chosen = TranscriptFixtures.languageOtherThanTheDefault
        viewModel.applyConfigChanges(try decodeConfig(#"{"transcriptionLocale": "\#(chosen)"}"#))

        XCTAssertEqual(store.string(forKey: "transcriptionLocale"), chosen)
        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.transcriptionLocale, chosen)
        let file = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ConfigService.fileData(for: saved)) as? [String: Any]
        )
        XCTAssertEqual(file["transcriptionLocale"] as? String, chosen)
    }

    /// A language config.json holds that cannot be one is repaired to "not
    /// chosen" as the file is read, and logged once; it, a missing one, a
    /// null, and an empty one leave the language in force alone. An
    /// underscore is read as a hyphen.
    func testUnusableLanguagesInConfigJSONLeaveTheSettingAlone() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = makeSandboxedPreferences("transcription-language-unusable")
        let viewModel = makeViewModel(store)
        TranscriptionLanguage.preference.write("en-IN", to: store)
        let unusable = "klingon \(UUID().uuidString)"

        XCTAssertEqual(try decodeConfig(#"{"transcriptionLocale": "en_GB"}"#).transcriptionLocale, "en-GB")
        let repaired = try decodeConfig(#"{"transcriptionLocale": "\#(unusable)"}"#)
        XCTAssertEqual(repaired.transcriptionLocale, "")
        XCTAssertEqual(try decodeConfig(#"{"transcriptionLocale": 7}"#).transcriptionLocale, "")
        for config in [repaired, try decodeConfig("{}"), try decodeConfig(#"{"transcriptionLocale": null}"#),
                       try decodeConfig(#"{"transcriptionLocale": ""}"#)] {
            viewModel.applyConfigChanges(config)
        }

        XCTAssertEqual(TranscriptionLanguage.preference.read(from: store), "en-IN")
        XCTAssertEqual(debugLogLines(containing: unusable).count, 1)
    }

    /// A language chosen outside the settings model, as the transcription
    /// settings will choose one, is saved to config.json with the next save.
    func testALanguageChosenAnywhereIsSavedToConfigJSON() throws {
        let store = makeSandboxedPreferences("transcription-language-anywhere")
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store,
            configService: service
        )
        let chosen = TranscriptFixtures.languageOtherThanTheDefault

        TranscriptionLanguage.preference.write(chosen, to: store)

        XCTAssertTrue(service.hasScheduledSave, "no save of config.json was asked for")
        service.flushScheduledSave()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["transcriptionLocale"] as? String, chosen)
        withExtendedLifetime(viewModel) {}
    }

    // MARK: - Helpers

    /// A settings model bound to `store` that starts no services and posts
    /// only to a private notification center.
    private func makeViewModel(_ store: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
    }

    /// Decodes config.json text the way `ConfigService` reads the file.
    private func decodeConfig(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }
}
