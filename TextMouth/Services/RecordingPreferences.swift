import Foundation

/// The recording preferences TextMouth keeps in the preferences store, each
/// defined once by its owner, which the settings model mirrors in
/// config.json under the same names (`ConfigService.AppConfig.Portability`).
enum RecordingPreferences {
    /// Their keys: the microphone the Record window remembers
    /// (`RecordingInputChoice`), and its level announcements
    /// (`RecordingLevelAnnouncements`). What happens to a recording's
    /// original take is audio editing's (`AudioEditingPreferences`).
    static var keys: [String] {
        RecordingInputChoice.preferenceKeys + RecordingLevelAnnouncements.preferenceKeys
    }
}

/// The Record window's level announcements (FR04): whether VoiceOver speaks
/// the level every few seconds while recording, and how many seconds apart,
/// kept so the window opens as it was left rather than forgetting them.
enum RecordingLevelAnnouncements {
    /// Whether the level is announced while recording: off until the user
    /// turns it on.
    static let enabled = StoredPreference.flag("recordingAnnouncesLevel", default: false)

    /// How many seconds apart, a whole number read and written through
    /// `SettingsPolicy.recordingLevelAnnouncementSeconds`, so it is always
    /// within 5 to 60.
    static let interval = StoredPreference<Int>(
        key: SettingsPolicy.recordingLevelAnnouncementSeconds.key,
        read: { store, _ in Int(SettingsPolicy.recordingLevelAnnouncementSeconds.storedValue(in: store).rounded()) },
        write: { seconds, store, key in
            store.set(Int(SettingsPolicy.recordingLevelAnnouncementSeconds.validated(Double(seconds)).rounded()), forKey: key)
        }
    )

    /// The store keys the announcements keep, for the settings model's
    /// mirror.
    static var preferenceKeys: [String] {
        [enabled.key, interval.key]
    }
}

extension SettingsPolicy {
    /// How many seconds apart the Record window announces the level, when
    /// it does: 5 to 60, and 10 until the user picks another number.
    static let recordingLevelAnnouncementSeconds = NumericSettingRule(
        key: "recordingLevelAnnouncementSeconds",
        range: 5...60,
        defaultValue: 10
    )
}
