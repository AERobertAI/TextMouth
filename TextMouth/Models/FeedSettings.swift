import Foundation

// MARK: - The Feed Settings (FR03)

/// The feed reader's settings (FR03), as the listener decided them on
/// October 4: when feeds are refreshed, how many entries each keeps, whether
/// new episodes download by themselves, when a played episode's download is
/// deleted, and whether a refresh is announced in an alert or a
/// notification.
///
/// Each is a preference of its own in the preferences store, defined once
/// here (`StoredPreference`), which the feed engine reads and config.json
/// mirrors under the same readable key, through the settings model
/// (`SettingsViewModel.servicePreferenceKeys`). A feed may override two of
/// them for itself (`Feed.keepEntriesOverride` and
/// `Feed.deleteDownloadsDaysAfterPlayedOverride`).
struct FeedSettings: Equatable, Sendable {
    /// Whether every feed is refreshed when TextMouth opens, once the
    /// library has loaded. On until the listener turns it off.
    var refreshAtLaunch: Bool
    /// Hours between the refreshes of every feed while TextMouth runs, 1 to
    /// 168, or 0 to refresh only at launch and when asked. 1 by default.
    var refreshIntervalHours: Int
    /// How many of each feed's newest entries are kept besides its
    /// downloads, which are always kept: 0 to 2,000, or -1 for every entry.
    /// 10 by default.
    var keepEntries: Int
    /// Whether a new episode downloads by itself when a refresh finds it.
    /// Off by default: an episode downloads when the listener opens it or
    /// chooses Download.
    var autoDownload: Bool
    /// How many days after an episode plays to the end its download is
    /// deleted: 0 at once, up to 365, or -1 never. 1 by default.
    var deleteDownloadsDaysAfterPlayed: Int
    /// Whether a refresh the listener did not ask for is announced in an
    /// alert. Off by default.
    var refreshAlert: Bool
    /// Whether new episodes are announced in a notification. Off by default.
    var notifications: Bool

    /// The settings until the listener changes any.
    static let standard = FeedSettings(
        refreshAtLaunch: true,
        refreshIntervalHours: SettingsPolicy.feedRefreshIntervalHours.defaultValue,
        keepEntries: SettingsPolicy.feedKeepEntries.defaultValue,
        autoDownload: false,
        deleteDownloadsDaysAfterPlayed: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.defaultValue,
        refreshAlert: false,
        notifications: false
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
    /// The entries each feed keeps, under "feedKeepEntries".
    static let keepEntriesPreference = StoredPreference.threshold(SettingsPolicy.feedKeepEntries)
    /// Whether new episodes download by themselves, under "feedAutoDownload".
    static let autoDownloadPreference = StoredPreference.flag("feedAutoDownload", default: standard.autoDownload)
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

    /// The keys of every feed preference, in the order Settings lists them.
    static var preferenceKeys: [String] {
        [
            refreshAtLaunchPreference.key,
            refreshIntervalHoursPreference.key,
            keepEntriesPreference.key,
            autoDownloadPreference.key,
            deleteDownloadsDaysAfterPlayedPreference.key,
            refreshAlertPreference.key,
            notificationsPreference.key,
        ]
    }

    /// The settings `store` holds, each validated, and each one the store
    /// holds none of at its default.
    static func read(from store: UserDefaults) -> FeedSettings {
        FeedSettings(
            refreshAtLaunch: refreshAtLaunchPreference.read(from: store),
            refreshIntervalHours: refreshIntervalHoursPreference.read(from: store),
            keepEntries: keepEntriesPreference.read(from: store),
            autoDownload: autoDownloadPreference.read(from: store),
            deleteDownloadsDaysAfterPlayed: deleteDownloadsDaysAfterPlayedPreference.read(from: store),
            refreshAlert: refreshAlertPreference.read(from: store),
            notifications: notificationsPreference.read(from: store)
        )
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
        save(\.keepEntries, Self.keepEntriesPreference)
        save(\.autoDownload, Self.autoDownloadPreference)
        save(\.deleteDownloadsDaysAfterPlayed, Self.deleteDownloadsDaysAfterPlayedPreference)
        save(\.refreshAlert, Self.refreshAlertPreference)
        save(\.notifications, Self.notificationsPreference)
    }
}

// MARK: - A Feed's Own Exceptions

extension Feed {
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
