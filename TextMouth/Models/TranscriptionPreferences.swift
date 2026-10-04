import Foundation

/// The preferences transcription keeps beside its language
/// (`TranscriptionLanguage`), each defined once with its key and stored
/// form, for the settings model and config.json to share (FR05).
enum TranscriptionPreferences {
    /// Whether TextMouth offers to transcribe each audiobook just imported,
    /// with the same Transcribe Audio sheet the command opens. Off until the
    /// user turns it on in Playback settings or config.json: nothing is
    /// transcribed unless the user asks.
    static let offerAfterImport = StoredPreference.flag("offerTranscriptionAfterImport", default: false)
}
