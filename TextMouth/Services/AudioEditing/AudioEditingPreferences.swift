import Foundation

/// The audio editing preferences TextMouth keeps in the preferences store
/// (FR04), each defined once by its owner, which the settings model mirrors
/// in config.json under the same names (`ConfigService.AppConfig.Portability`).
enum AudioEditingPreferences {
    /// Their keys: what happens to the original audio of recordings and
    /// edited audiobooks (`AudioOriginalPolicy`).
    static var keys: [String] {
        AudioOriginalPolicy.preferenceKeys
    }
}
