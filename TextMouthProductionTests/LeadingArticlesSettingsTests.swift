import Combine
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

    // MARK: - The Library Tab's Pop-Up

    /// The Titles section draws one pop-up offering the three choices by
    /// their names, the one in force chosen; choosing another in it changes
    /// the setting in the store; and the words under it say what the choice
    /// in force does, then which languages count.
    func testThePopUpOffersTheThreeChoicesAndChoosingOneChangesTheSetting() throws {
        let store = try isolatedDefaults()
        let settings = makeViewModel(store)
        settings.leadingArticles = .ignoredWhenTyping
        let section = LeadingArticlesSettingsSection()
            .environmentObject(settings)
            .frame(width: 600, height: 200)
        try withHostedView(section, size: NSSize(width: 600, height: 200), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty
        }) { hosting in
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.count, 1, "the section drew \(popUps.count) pop-ups")
            let popUp = try XCTUnwrap(popUps.first)
            XCTAssertEqual(popUp.itemTitles, LeadingArticles.allCases.map(LeadingArticleWording.name))
            XCTAssertEqual(popUp.titleOfSelectedItem, LeadingArticleWording.name(.ignoredWhenTyping))

            // Choosing a menu item runs the action SwiftUI gave the item;
            // the pop-up's own target and action are the second way.
            let attempts: [() -> Void] = [
                { popUp.menu?.performActionForItem(at: 2) },
                { popUp.selectItem(at: 2); _ = popUp.target?.perform(popUp.action, with: popUp) },
            ]
            var chose = false
            for attempt in attempts where !chose {
                attempt()
                chose = waitUntil(timeout: 1) { LeadingArticles.preference.read(from: store) == .ignoredWhenTypingAndSorting }
            }
            XCTAssertTrue(chose, "choosing the third choice left \(LeadingArticles.preference.read(from: store))")
        }
        XCTAssertEqual(
            LeadingArticlesSettingsSection.caption(for: .ignoredWhenTypingAndSorting),
            LeadingArticleWording.description(.ignoredWhenTypingAndSorting) + " " + LeadingArticleWording.languagesNote
        )
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
