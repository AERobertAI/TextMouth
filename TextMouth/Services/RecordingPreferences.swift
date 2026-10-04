import Foundation

/// The recording preferences TextMouth keeps in the preferences store, each
/// defined once by its owner, which the settings model mirrors in
/// config.json under the same names (`ConfigService.AppConfig.Portability`).
enum RecordingPreferences {
    /// Their keys: the microphone the Record window remembers
    /// (`RecordingInputChoice`). What happens to a recording's original take
    /// is audio editing's (`AudioEditingPreferences`).
    static var keys: [String] {
        RecordingInputChoice.preferenceKeys
    }
}
