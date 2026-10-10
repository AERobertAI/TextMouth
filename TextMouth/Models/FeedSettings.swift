import Foundation

// MARK: - The Feed Settings (FR03)

/// The feed reader's settings (FR03), as the listener decided them on
/// October 4 and changed them on October 7 (FR11): when feeds are
/// refreshed, what each lists and downloads by itself (the "List and
/// download" choice), when a played episode's download is deleted, and
/// whether a refresh is announced in an alert or a notification.
///
/// Each is a preference of its own in the preferences store, defined once
/// here (`StoredPreference`), which the feed engine reads and config.json
/// mirrors under the same readable key, through the settings model
/// (`SettingsViewModel.servicePreferenceKeys`). A feed may override two of
/// them for itself (`Feed.itemPolicyOverride` and
/// `Feed.deleteDownloadsDaysAfterPlayedOverride`).
struct FeedSettings: Equatable, Sendable {
    /// Whether every feed is refreshed when TextMouth opens, once the
    /// library has loaded. On until the listener turns it off.
    var refreshAtLaunch: Bool
    /// Hours between the refreshes of every feed while TextMouth runs, 1 to
    /// 168, or 0 to refresh only at launch and when asked. 1 by default.
    var refreshIntervalHours: Int
    /// What every feed lists, and what of it downloads by itself, unless the
    /// feed has a choice of its own (FR11): every item listed with the
    /// newest 5 downloaded until the listener picks another.
    var itemPolicy: FeedItemPolicy
    /// How many days after an episode plays to the end its download is
    /// deleted: 0 at once, up to 365, or -1 never. 1 by default.
    var deleteDownloadsDaysAfterPlayed: Int
    /// Whether a refresh the listener did not ask for is announced in an
    /// alert. Off by default.
    var refreshAlert: Bool
    /// Whether new episodes are announced in a notification. Off by default.
    var notifications: Bool

    // MARK: Retired by the "List and download" choice (FR11)

    /// How many of each feed's newest entries are kept besides its
    /// downloads, which are always kept: 0 to 2,000, or -1 for every entry.
    /// 10 by default. Retired by `itemPolicy`, which config.json carries in
    /// its place. It stays readable for the Feeds tab's and Feed Info's old
    /// controls, until the interface of the choice (FR11's branch C) takes
    /// their place.
    var keepEntries: Int
    /// Whether a new episode downloads by itself when a refresh finds it.
    /// Off by default: an episode downloads when the listener opens it or
    /// chooses Download. Retired by `itemPolicy`, as `keepEntries` is.
    var autoDownload: Bool

    /// The settings until the listener changes any.
    static let standard = FeedSettings(
        refreshAtLaunch: true,
        refreshIntervalHours: SettingsPolicy.feedRefreshIntervalHours.defaultValue,
        itemPolicy: .standard,
        deleteDownloadsDaysAfterPlayed: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.defaultValue,
        refreshAlert: false,
        notifications: false,
        keepEntries: SettingsPolicy.feedKeepEntries.defaultValue,
        autoDownload: false
    )

    /// The time between refreshes while TextMouth runs, or nil when feeds
    /// refresh only at launch and when asked.
    var refreshInterval: TimeInterval? {
        refreshIntervalHours > 0 ? TimeInterval(refreshIntervalHours) * 3_600 : nil
    }

    // MARK: The Preferences

    /// Whether feeds refresh at launch, under "feedRefreshAtLaunch".
    static let refreshAtLaunchPreference = StoredPreference.flag("feedRefreshAtLaunch", default: standard.refreshAtLaunch)
    /// The hours between refreshes, under "feedRefreshIntervalHours".
    static let refreshIntervalHoursPreference = StoredPreference.threshold(SettingsPolicy.feedRefreshIntervalHours)
    /// The "List and download" choice (FR11), under "feedItems", saved as its
    /// raw value and read through `SettingsPolicy.feedItems`, so a missing or
    /// unknown value reads as the default.
    static let itemsPreference = StoredPreference<FeedItemPolicy.Choice>(
        key: SettingsPolicy.feedItems.key,
        read: { store, key in SettingsPolicy.feedItems.value(fromRaw: store.object(forKey: key) as? String) },
        write: { choice, store, key in store.set(choice.rawValue, forKey: key) }
    )
    /// How many of each feed's newest items the choice counts (FR11), under
    /// "feedNewestCount", read and written through
    /// `SettingsPolicy.feedNewestCount`, so it is always within 1 to 2,000.
    static let newestCountPreference = StoredPreference<Int>(
        key: SettingsPolicy.feedNewestCount.key,
        read: { store, _ in SettingsPolicy.feedNewestCount.storedValue(in: store) },
        write: { count, store, key in store.set(SettingsPolicy.feedNewestCount.validated(count), forKey: key) }
    )
    /// The days after playing that a download is deleted, under
    /// "feedDeleteDownloadsDaysAfterPlayed".
    static let deleteDownloadsDaysAfterPlayedPreference = StoredPreference.threshold(
        SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
    )
    /// Whether a refresh is announced in an alert, under "feedRefreshAlert".
    static let refreshAlertPreference = StoredPreference.flag("feedRefreshAlert", default: standard.refreshAlert)
    /// Whether new episodes are announced in a notification, under
    /// "feedNotifications".
    static let notificationsPreference = StoredPreference.flag("feedNotifications", default: standard.notifications)

    /// The entries each feed kept, under "feedKeepEntries": retired with
    /// `keepEntries`.
    static let keepEntriesPreference = StoredPreference.threshold(SettingsPolicy.feedKeepEntries)
    /// Whether new episodes downloaded by themselves, under
    /// "feedAutoDownload": retired with `autoDownload`.
    static let autoDownloadPreference = StoredPreference.flag("feedAutoDownload", default: standard.autoDownload)

    /// The keys of every feed preference in force, in the order Settings
    /// lists them, which config.json mirrors.
    static var preferenceKeys: [String] {
        [
            refreshAtLaunchPreference.key,
            refreshIntervalHoursPreference.key,
            itemsPreference.key,
            newestCountPreference.key,
            deleteDownloadsDaysAfterPlayedPreference.key,
            refreshAlertPreference.key,
            notificationsPreference.key,
        ]
    }

    /// The keys of the feed preferences the "List and download" choice
    /// retired (FR11), left in the store as they were and out of
    /// config.json.
    static var retiredPreferenceKeys: [String] {
        [keepEntriesPreference.key, autoDownloadPreference.key]
    }

    /// The settings `store` holds, each validated, and each one the store
    /// holds none of at its default.
    static func read(from store: UserDefaults) -> FeedSettings {
        FeedSettings(
            refreshAtLaunch: refreshAtLaunchPreference.read(from: store),
            refreshIntervalHours: refreshIntervalHoursPreference.read(from: store),
            itemPolicy: FeedItemPolicy(
                choice: itemsPreference.read(from: store),
                newestCount: newestCountPreference.read(from: store)
            ),
            deleteDownloadsDaysAfterPlayed: deleteDownloadsDaysAfterPlayedPreference.read(from: store),
            refreshAlert: refreshAlertPreference.read(from: store),
            notifications: notificationsPreference.read(from: store),
            keepEntries: keepEntriesPreference.read(from: store),
            autoDownload: autoDownloadPreference.read(from: store)
        )
    }

    /// Moves the settings before the "List and download" choice to the
    /// choice, once (FR11): when `store` holds no choice yet, as at the
    /// first launch of the version that brought it, writes the choice and
    /// its number the retired settings ask for
    /// (`FeedItemPolicy.migrated(keepEntries:autoDownload:)`), the default
    /// for the listener's settings of October 4. Both are written even when
    /// they are the defaults, so the choice's key says from then on that the
    /// move was made, and a value chosen later is never moved over. The
    /// retired settings stay in the store as they were, unused, as a copy
    /// to go back to.
    /// - Returns: The choice written, or nil when the store held one.
    @discardableResult
    static func moveToItemPolicyIfNeeded(in store: UserDefaults) -> FeedItemPolicy? {
        guard store.object(forKey: itemsPreference.key) == nil else { return nil }
        let retired = read(from: store)
        let policy = FeedItemPolicy.migrated(keepEntries: retired.keepEntries, autoDownload: retired.autoDownload)
        store.set(policy.choice.rawValue, forKey: itemsPreference.key)
        store.set(policy.newestCount, forKey: newestCountPreference.key)
        let kept = retired.keepEntries < 0
            ? "every entry"
            : CountWording.phrase(retired.keepEntries, singular: "entry", plural: "entries")
        let downloads = retired.autoDownload ? "new episodes downloading by themselves" : "downloads by hand"
        DiagnosticLog.event(
            .feeds,
            "FEED_ITEM_POLICY_MOVED: keeping \(kept), with \(downloads), became \(policy.choice.rawValue) counting \(policy.newestCount)"
        )
        return policy
    }

    /// Saves every setting that differs from what `store` holds, validated,
    /// so an unchanged setting is not written and observers hear only real
    /// changes.
    func write(to store: UserDefaults) {
        let current = Self.read(from: store)
        /// Writes one setting when it changed.
        func save<Value: Equatable & Sendable>(_ keyPath: KeyPath<FeedSettings, Value>, _ preference: StoredPreference<Value>) {
            if self[keyPath: keyPath] != current[keyPath: keyPath] {
                preference.write(self[keyPath: keyPath], to: store)
            }
        }
        save(\.refreshAtLaunch, Self.refreshAtLaunchPreference)
        save(\.refreshIntervalHours, Self.refreshIntervalHoursPreference)
        save(\.itemPolicy.choice, Self.itemsPreference)
        save(\.itemPolicy.newestCount, Self.newestCountPreference)
        save(\.deleteDownloadsDaysAfterPlayed, Self.deleteDownloadsDaysAfterPlayedPreference)
        save(\.refreshAlert, Self.refreshAlertPreference)
        save(\.notifications, Self.notificationsPreference)
        save(\.keepEntries, Self.keepEntriesPreference)
        save(\.autoDownload, Self.autoDownloadPreference)
    }
}

// MARK: - A Feed's Own Exceptions

extension Feed {
    /// What this feed lists and downloads by itself under `settings`
    /// (FR11): its own choice and number when it has them, or the setting's.
    func itemPolicy(under settings: FeedSettings) -> FeedItemPolicy {
        itemPolicyOverride ?? settings.itemPolicy
    }

    /// How many of this feed's newest entries are kept under `settings`: its
    /// own override, validated, or the setting. -1 keeps every entry.
    func keepEntries(under settings: FeedSettings) -> Int {
        keepEntriesOverride.map(SettingsPolicy.feedKeepEntries.validated) ?? settings.keepEntries
    }

    /// How many days after playing this feed's downloads are deleted under
    /// `settings`: its own override, validated, or the setting. 0 deletes
    /// at once and -1 never.
    func deleteDownloadsDaysAfterPlayed(under settings: FeedSettings) -> Int {
        deleteDownloadsDaysAfterPlayedOverride.map(SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.validated)
            ?? settings.deleteDownloadsDaysAfterPlayed
    }
}
