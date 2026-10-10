import Combine
import XCTest
@testable import TextMouth

/// The feed settings (FR03): their defaults, as the listener decided them on
/// October 4 and changed them on October 7 (FR11's "List and download"
/// choice), how each is validated wherever it comes from, how config.json
/// mirrors them under readable keys, how a feed overrides two of them, and
/// App Transport Security allowing plain http feeds.
@MainActor
final class FeedSettingsTests: XCTestCase {

    // MARK: - Defaults and Validation

    /// With nothing saved, feeds refresh at launch and every hour, list every
    /// item with the newest 5 downloaded (FR11), delete a played download
    /// after a day, and announce nothing; the two settings the choice
    /// retired read as they always did, out of the keys config.json mirrors.
    func testTheDefaultsAreTheListenersDecisions() throws {
        let settings = FeedSettings.read(from: makeSandboxedPreferences("FeedDefaults"))

        XCTAssertEqual(settings, .standard)
        XCTAssertTrue(settings.refreshAtLaunch)
        XCTAssertEqual(settings.refreshIntervalHours, 1)
        XCTAssertEqual(settings.refreshInterval, 3_600)
        XCTAssertEqual(settings.itemPolicy, FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 5))
        XCTAssertEqual(settings.itemPolicy.listing, .every)
        XCTAssertEqual(settings.itemPolicy.downloading, .newest(5))
        XCTAssertEqual(settings.deleteDownloadsDaysAfterPlayed, 1)
        XCTAssertFalse(settings.refreshAlert)
        XCTAssertFalse(settings.notifications)
        XCTAssertEqual(settings.keepEntries, 10)
        XCTAssertFalse(settings.autoDownload)
        XCTAssertEqual(FeedSettings.preferenceKeys, [
            "feedRefreshAtLaunch", "feedRefreshIntervalHours", "feedItems", "feedNewestCount",
            "feedDeleteDownloadsDaysAfterPlayed", "feedRefreshAlert", "feedNotifications",
        ])
        XCTAssertEqual(FeedSettings.retiredPreferenceKeys, ["feedKeepEntries", "feedAutoDownload"])
    }

    /// Whatever the store holds, each number reads as one the settings
    /// support: a negative one as its off value (refreshing only at launch,
    /// never deleting), and the number of newest items as its lowest, 1,
    /// since it has none; a large one clamped, numeric text as its number,
    /// and anything else as the default. A choice the store names wrongly
    /// reads as the default choice.
    func testStoredNumbersAreValidated() throws {
        let store = makeSandboxedPreferences("FeedValidation")
        store.set(-3, forKey: "feedRefreshIntervalHours")
        store.set(9_999, forKey: "feedNewestCount")
        store.set(-2, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 0)
        XCTAssertNil(FeedSettings.read(from: store).refreshInterval)
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy.newestCount, 2_000)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, -1)

        store.set(500, forKey: "feedRefreshIntervalHours")
        store.set(-7, forKey: "feedNewestCount")
        store.set(1_000, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 168)
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy.newestCount, 1)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, 365)

        store.set("12", forKey: "feedRefreshIntervalHours")
        store.set("many", forKey: "feedNewestCount")
        store.set(0, forKey: "feedDeleteDownloadsDaysAfterPlayed")
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 12)
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy.newestCount, 5)
        XCTAssertEqual(FeedSettings.read(from: store).deleteDownloadsDaysAfterPlayed, 0)

        store.set("everything", forKey: "feedItems")
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy.choice, .everyListedNewestDownloaded)
        store.set("onlyNewestListed", forKey: "feedItems")
        store.set("7", forKey: "feedNewestCount")
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy, FeedItemPolicy(choice: .onlyNewestListed, newestCount: 7))

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

    /// The number of newest items has no off value (FR11): any number below
    /// 1 reads as 1, any above 2,000 as 2,000, a fraction as the nearest
    /// whole number, and NaN as the default, 5.
    func testTheNumberOfNewestItemsHasNoOffValue() {
        let count = SettingsPolicy.feedNewestCount
        XCTAssertEqual(count.range, 1...2_000)
        XCTAssertEqual(count.defaultValue, 5)
        XCTAssertEqual(count.validated(0), 1)
        XCTAssertEqual(count.validated(-40), 1)
        XCTAssertEqual(count.validated(1), 1)
        XCTAssertEqual(count.validated(381), 381)
        XCTAssertEqual(count.validated(2_001), 2_000)
        XCTAssertEqual(count.validated(0.4), 1)
        XCTAssertEqual(count.validated(-0.5), 1)
        XCTAssertEqual(count.validated(2.5), 3)
        XCTAssertEqual(count.validated(1e300), 2_000)
        XCTAssertEqual(count.validated(Double.nan), 5)
        XCTAssertEqual(count.supportedDescription, "1...2000")
    }

    /// Writing settings saves only the ones that changed, validated, so the
    /// store's observers hear nothing for the others.
    func testWritingSavesOnlyWhatChanged() throws {
        let store = makeSandboxedPreferences("FeedWrite")
        var settings = FeedSettings.standard
        settings.itemPolicy.choice = .onlyNewestListed
        settings.itemPolicy.newestCount = 9_000

        settings.write(to: store)

        XCTAssertEqual(store.object(forKey: "feedItems") as? String, "onlyNewestListed")
        XCTAssertEqual(store.object(forKey: "feedNewestCount") as? Int, 2_000)
        for unchanged in ["feedRefreshAtLaunch", "feedRefreshIntervalHours", "feedDeleteDownloadsDaysAfterPlayed",
                          "feedRefreshAlert", "feedNotifications", "feedKeepEntries", "feedAutoDownload"] {
            XCTAssertNil(store.object(forKey: unchanged), unchanged)
        }
    }

    /// A feed's own exceptions win over the settings, validated as the
    /// settings are; without one it follows the settings.
    func testAFeedsOverridesWinOverTheSettings() throws {
        let address = try XCTUnwrap(URL(string: "https://feeds.example/show.xml"))
        var feed = Feed(feedURL: address, folderID: UUID(), subscribedDate: Date())
        var settings = FeedSettings.standard
        settings.itemPolicy = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 25)
        settings.deleteDownloadsDaysAfterPlayed = 3

        XCTAssertEqual(feed.itemPolicy(under: settings), FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 25))
        XCTAssertEqual(feed.deleteDownloadsDaysAfterPlayed(under: settings), 3)

        feed.itemPolicyOverride = FeedItemPolicy(choice: .onlyNewestListed, newestCount: -5)
        feed.deleteDownloadsDaysAfterPlayedOverride = 0
        XCTAssertEqual(feed.itemPolicy(under: settings), FeedItemPolicy(choice: .onlyNewestListed, newestCount: 1))
        XCTAssertEqual(feed.itemPolicy(under: settings).listing, .newest(1))
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
        let unreadable = "config.json feedNewestCount: could not be read"
        let linesBefore = debugLogLines(containing: unreadable).count
        let config = try decodeConfig("""
        {"feedRefreshAtLaunch": false, "feedRefreshIntervalHours": -5, "feedItems": "onlyNewestListed",
         "feedNewestCount": "many", "feedDeleteDownloadsDaysAfterPlayed": 2, "feedRefreshAlert": null,
         "feedKeepEntries": 3, "feedAutoDownload": true}
        """)

        XCTAssertEqual(config.feedRefreshAtLaunch, false)
        XCTAssertEqual(config.feedRefreshIntervalHours, 0)
        XCTAssertEqual(config.feedItems, "onlyNewestListed")
        XCTAssertNil(config.feedNewestCount)
        XCTAssertEqual(config.feedDeleteDownloadsDaysAfterPlayed, 2)
        XCTAssertNil(config.feedRefreshAlert)
        XCTAssertNil(config.feedNotifications)
        XCTAssertEqual(debugLogLines(containing: unreadable).count, linesBefore + 1)

        viewModel.applyConfigChanges(config)

        var expected = FeedSettings.standard
        expected.refreshAtLaunch = false
        expected.refreshIntervalHours = 0
        expected.itemPolicy.choice = .onlyNewestListed
        expected.deleteDownloadsDaysAfterPlayed = 2
        XCTAssertEqual(FeedSettings.read(from: store), expected)
        XCTAssertEqual(viewModel.feedSettings, expected)
        // The retired fields a file written before the choice may still hold
        // are read no more.
        XCTAssertNil(store.object(forKey: "feedKeepEntries"))
        XCTAssertNil(store.object(forKey: "feedAutoDownload"))
    }

    /// config.json's number of newest items is moved into its range, and a
    /// choice it names wrongly leaves the choice alone, as an empty one does.
    func testConfigJSONsChoiceAndNumberAreRepaired() throws {
        let store = makeSandboxedPreferences("FeedConfigChoice")
        let viewModel = makeSettingsModel(store)

        let large = try decodeConfig(#"{"feedItems": "everything", "feedNewestCount": 9999}"#)
        XCTAssertEqual(large.feedItems, "")
        XCTAssertEqual(large.feedNewestCount, 2_000)
        viewModel.applyConfigChanges(large)
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy, FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 2_000))

        let small = try decodeConfig(#"{"feedItems": "everyListedDownloadsByHand", "feedNewestCount": -3}"#)
        XCTAssertEqual(small.feedNewestCount, 1)
        viewModel.applyConfigChanges(small)
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy, FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 1))

        viewModel.applyConfigChanges(try decodeConfig(#"{"feedItems": ""}"#))
        XCTAssertEqual(FeedSettings.read(from: store).itemPolicy.choice, .everyListedDownloadsByHand, "an empty choice changed it")
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
        XCTAssertEqual(object["feedItems"] as? String, "everyListedNewestDownloaded")
        XCTAssertEqual(object["feedNewestCount"] as? Int, 5)
        XCTAssertNil(object["feedKeepEntries"], "a retired setting was written")
        XCTAssertNil(object["feedAutoDownload"], "a retired setting was written")
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
        settings.itemPolicy.choice = .everyListedDownloadsByHand
        viewModel.feedSettings = settings

        XCTAssertEqual(store.object(forKey: "feedItems") as? String, "everyListedDownloadsByHand")
        XCTAssertTrue(service.hasScheduledSave, "no save of config.json was asked for")
        service.flushScheduledSave()
        XCTAssertEqual(try savedObject(url)["feedItems"] as? String, "everyListedDownloadsByHand")

        let announcedBefore = announcements
        FeedSettings.newestCountPreference.write(12, to: store)
        service.flushScheduledSave()

        XCTAssertEqual(try savedObject(url)["feedNewestCount"] as? Int, 12)
        XCTAssertGreaterThan(announcements, announcedBefore, "the settings model did not announce the change")
        XCTAssertEqual(viewModel.feedSettings.itemPolicy, FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 12))
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
