// Phase 0 stand-in: on the Mac, AudioEditorWindowController owns the audio
// editor windows, one per book, and holds a quit while edits are unsaved. The
// iPhone has no editor yet, so this version has the same name and the members
// shared code uses (AppDelegate and KeyboardShortcutManager) and holds
// nothing. Phase 1 may give it work; `IOSUnavailable.feature("Editing audio")`
// is the error for a throwing entry.
import Foundation

/// The iOS stand-in for the Mac's audio editor window controller.
@MainActor
final class AudioEditorWindowController {
    /// The one controller, as on the Mac.
    static let shared = AudioEditorWindowController()

    /// The identifier shared code compares a window's identifier with, the
    /// Mac's text; no iOS window carries it.
    nonisolated static let windowIdentifier = "audio-editor"

    /// Whether a quit must wait for unsaved edits. No editor is open on iOS,
    /// so nothing is held and the quit goes on.
    func holdQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        false
    }
}
