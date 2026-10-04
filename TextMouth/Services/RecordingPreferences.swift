import Foundation

/// The recording preferences TextMouth keeps in the preferences store, each
/// defined once by its owner, which the settings model mirrors in
/// config.json under the same names (`ConfigService.AppConfig.Portability`).
enum RecordingPreferences {
    /// Their keys: the microphone the Record window remembers
    /// (`RecordingInputChoice`).
    static var keys: [String] {
        RecordingInputChoice.preferenceKeys
    }
}
