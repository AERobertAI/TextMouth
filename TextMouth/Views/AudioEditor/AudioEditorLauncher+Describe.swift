import Foundation

// How the audio editor's log lines name an error, defined once for both apps.
// The Mac's AudioEditorLauncher moved whole to Platform/macOS in phase 0 of the
// iOS port, and iOS has a stand-in of the same name; the shared models
// (AudioEditorModel+Saving, AudioEditSession) call this on either.
extension AudioEditorLauncher {
    /// An error as the debug log names it: an edit error by its case alone,
    /// any other by its domain and code, never by words that could hold a
    /// file's name or path.
    static func describe(_ error: Error) -> String {
        if let edit = error as? AudioEditError {
            return String(String(describing: edit).prefix { $0 != "(" })
        }
        let failure = error as NSError
        return "\(failure.domain) \(failure.code)"
    }
}
