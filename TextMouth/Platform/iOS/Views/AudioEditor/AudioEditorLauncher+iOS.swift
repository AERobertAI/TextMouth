// Phase 0 stand-in: on the Mac, AudioEditorLauncher decides whether a book's
// audio can be edited and opens the editor window for it. The iPhone has no
// editor yet, so this version says no book can be edited and opens nothing.
// Phase 1's error for a throwing entry is
// `IOSUnavailable.feature("Editing audio")`.
import Foundation

/// The iOS stand-in for the Mac's audio editor launcher.
@MainActor
enum AudioEditorLauncher {
    /// Whether the book's audio can be edited: never on iOS yet.
    static func canEdit(_ book: Book) -> Bool {
        false
    }

    /// Opens the editor for the book on the Mac. On iOS it does nothing. The
    /// Mac's `window` is an `NSWindow?`; callers here pass `PlatformWindow?`.
    static func edit(_ book: Book, in library: LibraryViewModel, from window: PlatformWindow?) {}
}
