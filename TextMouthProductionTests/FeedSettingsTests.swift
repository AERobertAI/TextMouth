import Combine
import XCTest
@testable import TextMouth

/// The feed settings (FR03): their defaults, as the listener decided them on
/// October 4, how each is validated wherever it comes from, how config.json
/// mirrors them under readable keys, how a feed overrides two of them, and
/// App Transport Security allowing plain http feeds.
@MainActor
final class FeedSettingsTests: XCTestCase {

    // MARK: - Defaults and Validation

    /// With nothing saved, feeds refresh at launch and every hour, keep their
    /// 10 newest entries, never download by themselves, delete a played
    /// download after a day, and announce nothing.
    func testTheDefaultsAreTheListenersDecisions() throws {
        let settings = FeedSettings.read(from: makeSandboxedPreferences("FeedDefaults"))

        XCTAssertEqual(settings, .standard)
        XCTAssertTrue(settings.refreshAtLaunch)
        XCTAssertEqual(settings.refreshIntervalHours, 1)
        XCTAssertEqual(settings.refreshInterval, 3_600)
        XCTAssertEqual(settings.keepEntries, 10)
        XCTAssertFalse(settings.autoDownload)
        XCTAssertEqual(settings.deleteDownloadsDaysAfterPlayed, 1)
        XCTAssertFalse(settings.refreshAlert)
        XCTAssertFalse(settings.notifications)
        XCTAssertEqual(FeedSettings.preferenceKeys, [
            "feedRefreshAtLaunch", "feedRefreshIntervalHours", "feedKeepEntries", "feedAutoDownload",
            "feedDeleteDownloadsDaysAfterPlayed", "feedRefreshAlert", "feedNotifications",
        ])
    }

    /// Whatever the store holds, each number reads as one the settings
    /// support: a negative one as its off value (refreshing only at launch,
    /// keeping every entry, never deleting), a large one clamped, numeric
    /// text as its number, and anything else as the default.
    func testStoredNumbersAreValidated() throws {
        let store = makeSandboxedPreferences("FeedValidation")
        store.set(-3, forKey: "feedRefreshIntervalHours")
        store.set(9_999, forKey: "feedKeepEntries")
        store.set(-2, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 0)
        XCTAssertNil(FeedSettings.read(from: store).refreshInterval)
        XCTAssertEqual(FeedSettings.read(from: store).keepEntries, 2_000)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, -1)

        store.set(500, forKey: "feedRefreshIntervalHours")
        store.set(-7, forKey: "feedKeepEntries")
        store.set(1_000, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 168)
        XCTAssertEqual(FeedSettings.read(from: store).keepEntries, -1)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, 365)

        store.set("12", forKey: "feedRefreshIntervalHours")
        store.set("many", forKey: "feedKeepEntries")
        store.set(0, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 12)
        XCTAssertEqual(FeedSettings.read(from: store).keepEntries, 10)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, 0)

        store.set(0, forKey: "feedRefreshIntervalHours")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 0, "0, refreshing only at launch, was not kept")
        XCTAssertNil(FeedSettings.read(from: store).refreshInterval)
    }

    /// A threshold is off at or below its own off value: the refresh
    /// interval's is 0, so 0, less, or less than an hour stops the schedule,
    /// while the repeated-symbol threshold, whose off value is -1, still
    /// reads 0 and 1 as its lowest value, 2.
    func testAThresholdIsOffAtOrBelowItsOffValue() {
        let interval = SettingsPolicy.feedRefreshIntervalHours
        XCTAssertEqual(interval.validated(0), 0)
        XCTAssertEqual(interval.validated(-4), 0)
        XCTAssertEqual(interval.validated(1), 1)
        XCTAssertEqual(interval.validated(0.6), 0)
        XCTAssertEqual(interval.validated(1.4), 1)
        XCTAssertEqual(interval.validated(2.5), 3)

        let symbols = SettingsPolicy.repeatedSymbolThreshold
        XCTAssertEqual(symbols.validated(0), 2)
        XCTAssertEqual(symbols.validated(1), 2)
        XCTAssertEqual(symbols.validated(-1), -1)
        XCTAssertEqual(symbols.validated(-0.5), -1)
        XCTAssertEqual(symbols.validated(0.4), 2)
    }

    /// Writing settings saves only the ones that changed, validated, so the
    /// store's observers hear nothing for the others.
    func testWritingSavesOnlyWhatChanged() throws {
        let store = makeSandboxedPreferences("FeedWrite")
        var settings = FeedSettings.standard
        settings.keepEntries = -40
        settings.autoDownload = true

        settings.write(to: store)

        XCTAssertEqual(store.object(forKey: "feedKeepEntries") as? Int, -1)
        XCTAssertEqual(store.object(forKey: "feedAutoDownload") as? Bool, true)
        for unchanged in ["feedRefreshAtLaunch", "feedRefreshIntervalHours", "feedDeleteDownloadsDaysAfterPlayed",
                          "feedRefreshAlert", "feedNotifications"] {
            XCTAssertNil(store.object(forKey: unchanged), unchanged)
        }
    }

    /// A feed's own exceptions win over the settings, validated as the
    /// settings are; without one it follows the settings.
    func testAFeedsOverridesWinOverTheSettings() throws {
        let address = try XCTUnwrap(URL(string: "https://feeds.example/show.xml"))
        var feed = Feed(feedURL: address, folderID: UUID(), subscribedDate: Date())
        var settings = FeedSettings.standard
        settings.keepEntries = 25
        settings.deleteDownloadsDaysAfterPlayed = 3

        XCTAssertEqual(feed.keepEntries(under: settings), 25)
        XCTAssertEqual(feed.deleteDownloadsDaysAfterPlayed(under: settings), 3)

        feed.keepEntriesOverride = -5
        feed.deleteDownloadsDaysAfterPlayedOverride = 0
        XCTAssertEqual(feed.keepEntries(under: settings), -1)
        XCTAssertEqual(feed.deleteDownloadsDaysAfterPlayed(under: settings), 0)
    }

    // MARK: - config.json

    /// config.json carries every feed setting under its readable key, and a
    /// value it gives reaches the store validated: out of range clamped or
    /// switched off, while a missing, null, or unreadable one leaves the
    /// setting alone and the last is logged once.
    func testConfigJSONCarriesTheSettingsValidated() throws {
        let store = makeSandboxedPreferences("FeedConfig")
        let viewModel = makeSettingsModel(store)
        // The line names the key, never the value, and the debug log keeps
        // earlier runs' lines, so the lines are counted before and after.
        let unreadable = "config.json feedAutoDownload: could not be read"
        let linesBefore = debugLogLines(containing: unreadable).count
        let config = try decodeConfig("""
        {"feedRefreshAtLaunch": false, "feedRefreshIntervalHours": -5, "feedKeepEntries": 9999,
         "feedAutoDownload": "often", "feedDeleteDownloadsDaysAfterPlayed": 2, "feedRefreshAlert": null}
        """)

        XCTAssertEqual(config.feedRefreshAtLaunch, false)
        XCTAssertEqual(config.feedRefreshIntervalHours, 0)
        XCTAssertEqual(config.feedKeepEntries, 2_000)
        XCTAssertNil(config.feedAutoDownload)
        XCTAssertEqual(config.feedDeleteDownloadsDaysAfterPlayed, 2)
        XCTAssertNil(config.feedRefreshAlert)
        XCTAssertNil(config.feedNotifications)
        XCTAssertEqual(debugLogLines(containing: unreadable).count, linesBefore + 1)

        viewModel.applyConfigChanges(config)

        var expected = FeedSettings.standard
        expected.refreshAtLaunch = false
        expected.refreshIntervalHours = 0
        expected.keepEntries = 2_000
        expected.deleteDownloadsDaysAfterPlayed = 2
        XCTAssertEqual(FeedSettings.read(from: store), expected)
        XCTAssertEqual(viewModel.feedSettings, expected)
    }

    /// Every feed setting is written to config.json, the defaults included,
    /// so the file always shows the settings in force.
    func testEveryFeedSettingIsWrittenToConfigJSON() throws {
        let viewModel = makeSettingsModel(makeSandboxedPreferences("FeedConfigWrite"))
        var config = ConfigService.AppConfig()

        viewModel.writePreferences(into: &config)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigService.fileData(for: config)) as? [String: Any])
        XCTAssertEqual(object["feedRefreshAtLaunch"] as? Bool, true)
        XCTAssertEqual(object["feedRefreshIntervalHours"] as? Int, 1)
        XCTAssertEqual(object["feedKeepEntries"] as? Int, 10)
        XCTAssertEqual(object["feedAutoDownload"] as? Bool, false)
        XCTAssertEqual(object["feedDeleteDownloadsDaysAfterPlayed"] as? Int, 1)
        XCTAssertEqual(object["feedRefreshAlert"] as? Bool, false)
        XCTAssertEqual(object["feedNotifications"] as? Bool, false)
    }

    /// A change made through the settings model reaches the store at once
    /// and config.json with the next save; one made in the store by anyone
    /// else is announced and saved too, so the Preferences section and the
    /// file follow it.
    func testAChangeMadeAnywhereReachesConfigJSON() throws {
        let store = makeSandboxedPreferences("FeedConfigSave")
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

        var settings = viewModel.feedSettings
        settings.autoDownload = true
        viewModel.feedSettings = settings

        XCTAssertEqual(store.object(forKey: "feedAutoDownload") as? Bool, true)
        XCTAssertTrue(service.hasScheduledSave, "no save of config.json was asked for")
        service.flushScheduledSave()
        XCTAssertEqual(try savedObject(url)["feedAutoDownload"] as? Bool, true)

        let announcedBefore = announcements
        FeedSettings.keepEntriesPreference.write(-1, to: store)
        service.flushScheduledSave()

        XCTAssertEqual(try savedObject(url)["feedKeepEntries"] as? Int, -1)
        XCTAssertGreaterThan(announcements, announcedBefore, "the settings model did not announce the change")
        XCTAssertEqual(viewModel.feedSettings.keepEntries, -1)
    }

    // MARK: - App Transport Security

    /// The app allows arbitrary loads, so feeds and episodes at plain http
    /// addresses can be read: the only network loads TextMouth makes.
    func testAppTransportSecurityAllowsPlainHTTPFeeds() throws {
        let security = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(security["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    // MARK: - Helpers

    /// A settings model bound to `store` that starts no services and posts
    /// only to a private notification center.
    private func makeSettingsModel(_ store: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
    }

    /// config.json text decoded as `ConfigService` decodes the file.
    private func decodeConfig(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }

    /// The JSON object config.json at `url` holds.
    private func savedObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
