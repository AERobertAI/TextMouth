import XCTest
@testable import TextMouth

/// The Library tab's Leading articles setting in the preferences store and
/// config.json (TITLE-ARTICLES-RESEARCH-2026-11-13.md), kept as the log
/// location is: applied and saved by its name, a value TextMouth can't use
/// leaving the choice alone, and a choice made anywhere saved and announced.
@MainActor
final class LeadingArticlesSettingsTests: XCTestCase {

    /// A choice config.json names is stored where the Library windows read
    /// it, and saved back by its name; a store holding none is saved with
    /// the default, so config.json always shows the choice in force.
    func testTheChoiceIsAppliedAndSavedByItsName() throws {
        let store = try isolatedDefaults()
        let viewModel = makeViewModel(store)
        var standard = ConfigService.AppConfig()
        viewModel.writePreferences(into: &standard)
        XCTAssertEqual(try jsonObject(standard)["leadingArticles"] as? String, "partOfTitle")

        for choice in LeadingArticles.allCases.reversed() {
            viewModel.applyConfigChanges(try decodeConfig(#"{"leadingArticles": "\#(choice.rawValue)"}"#))
            XCTAssertEqual(LeadingArticles.preference.read(from: store), choice)
            XCTAssertEqual(viewModel.leadingArticles, choice)
            var saved = ConfigService.AppConfig()
            viewModel.writePreferences(into: &saved)
            XCTAssertEqual(try jsonObject(saved)["leadingArticles"] as? String, choice.rawValue)
        }
    }

    /// A choice config.json holds that names none, in another spelling or
    /// letter case, or not text at all, is repaired to "not chosen" as the
    /// file is read and logged once; it, a missing one, a null, and an empty
    /// one all leave the choice in force alone.
    func testUnusableChoicesLeaveTheChoiceAlone() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let viewModel = makeViewModel(store)
        viewModel.leadingArticles = .ignoredWhenTyping
        let unsupported = "ignoredAlways-\(UUID().uuidString)"

        let unusable = try decodeConfig(#"{"leadingArticles": "\#(unsupported)"}"#)
        XCTAssertEqual(unusable.leadingArticles, "")
        XCTAssertEqual(try decodeConfig(#"{"leadingArticles": "IgnoredWhenTyping"}"#).leadingArticles, "")
        XCTAssertEqual(try decodeConfig(#"{"leadingArticles": 3}"#).leadingArticles, "")
        for config in [unusable, try decodeConfig("{}"), try decodeConfig(#"{"leadingArticles": null}"#),
                       try decodeConfig(#"{"leadingArticles": ""}"#)] {
            viewModel.applyConfigChanges(config)
        }

        XCTAssertEqual(LeadingArticles.preference.read(from: store), .ignoredWhenTyping)
        XCTAssertEqual(debugLogLines(containing: unsupported).count, 1)
    }

    /// A choice made in the Library tab is stored at once and saved to
    /// config.json with the next save, which waits for changes to pause
    /// (PERF17); so is one made outside the settings model, which the model
    /// also announces, so the pop-up and the Library windows show it.
    func testAChoiceMadeAnywhereIsSavedToConfigJSONAndAnnounced() throws {
        let store = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store,
            configService: service
        )
        var announcements = 0
        let subscription = viewModel.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }

        viewModel.leadingArticles = .ignoredWhenTypingAndSorting

        XCTAssertEqual(store.string(forKey: "leadingArticles"), "ignoredWhenTypingAndSorting")
        XCTAssertTrue(service.hasScheduledSave, "no save of config.json was asked for")
        service.flushScheduledSave()
        XCTAssertEqual(try jsonObject(from: Data(contentsOf: url))["leadingArticles"] as? String, "ignoredWhenTypingAndSorting")

        let announcedBefore = announcements
        LeadingArticles.preference.write(.partOfTitle, to: store)
        service.flushScheduledSave()

        XCTAssertEqual(try jsonObject(from: Data(contentsOf: url))["leadingArticles"] as? String, "partOfTitle")
        XCTAssertGreaterThan(announcements, announcedBefore, "the settings model did not announce the change")
        XCTAssertEqual(viewModel.leadingArticles, .partOfTitle)
    }

    // MARK: - Helpers

    /// A settings model bound to `store` that starts no services and posts
    /// only to a notification center of its own.
    private func makeViewModel(_ store: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
    }

    /// Decodes config.json text as `ConfigService` reads the file.
    private func decodeConfig(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }

    /// The JSON object config.json holds for `config`.
    private func jsonObject(_ config: ConfigService.AppConfig) throws -> [String: Any] {
        try jsonObject(from: ConfigService.fileData(for: config))
    }

    /// The JSON object `data` holds.
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
