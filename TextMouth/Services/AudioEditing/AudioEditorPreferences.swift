import Foundation

/// The audio editor window's own preferences (FR04), kept in the
/// preferences store beside the rest of audio editing's
/// (`AudioEditingPreferences`).
enum AudioEditorPreferences {
    /// Whether half a second of the audio plays at the cursor after each
    /// move, so a blind user hears where it landed: "Play half a second
    /// after each move", on until turned off.
    static let playAfterMoves = StoredPreference.flag("audioEditorPlaysAfterMoves", default: true)
}
