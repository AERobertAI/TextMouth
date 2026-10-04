import Foundation

/// The audio editor window's own preferences (FR04), shown in Storage
/// settings' Audio Editing group and kept in the preferences store beside
/// the rest of audio editing's (`AudioEditingPreferences`), which the
/// settings model mirrors in config.json under the same names.
enum AudioEditorPreferences {
    /// Whether Apply Filter plays a preview of a filter before applying it:
    /// "Preview filters before applying", on until turned off. Apply then
    /// previews first, and applies when chosen again.
    static let previewFiltersFirst = StoredPreference.flag("audioEditorPreviewsFilters", default: true)

    /// Whether half a second of the audio plays at the cursor after each
    /// move, so a blind user hears where it landed: "Play half a second
    /// after each move", on until turned off.
    static let playAfterMoves = StoredPreference.flag("audioEditorPlaysAfterMoves", default: true)

    /// Their keys, for the settings model's mirror.
    static var keys: [String] {
        [previewFiltersFirst.key, playAfterMoves.key]
    }
}
