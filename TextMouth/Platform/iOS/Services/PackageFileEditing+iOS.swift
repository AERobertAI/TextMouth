// Phase 0 stand-in: on the Mac, PackageFileEditing is what Edit Text and
// Edit Manifest share to open a book's content.md or manifest.json in the
// user's own app (NSWorkspace), watch the file, and take the saved file
// back. iPhone has no other app to edit the file in, so here the one member
// that shared code names, `openWithWorkspace(_:app:)`, throws
// `IOSUnavailable`. The rest of the Mac type (the explanation, the app
// chooser, the watchers) is not named by shared code and has no stand-in.

import Foundation

/// The iOS stand-in for the Mac's PackageFileEditing: it opens nothing.
@MainActor
final class PackageFileEditing {
    /// Would open `file` in `app`, or in the default app for its kind, as
    /// the Mac does. iPhone cannot hand a file to another app to be edited
    /// and taken back, so this always throws `IOSUnavailable`, whose words
    /// read "Editing a file in another app is not available on iPhone yet."
    static func openWithWorkspace(_ file: URL, app: URL?) async throws {
        throw IOSUnavailable.feature("Editing a file in another app")
    }
}
