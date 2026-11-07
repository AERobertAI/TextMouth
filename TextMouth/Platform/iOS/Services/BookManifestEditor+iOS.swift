// Phase 0 stand-in: on the Mac, BookManifestEditor is Edit Manifest: an
// audiobook of tracks has its manifest.json opened in the user's own app,
// a session watches it, and what the user saves is taken and announced.
// iPhone has no other app to edit in, so here no manifest is ever edited
// outside TextMouth: the commands and the looks for an outside edit do
// nothing. Only the members that shared code names are here, with the Mac's
// signatures and the same preference key.

import Foundation

/// The iOS stand-in for the Mac's BookManifestEditor: no manifest is edited
/// in another app here.
@MainActor
final class BookManifestEditor {
    /// The app's editor.
    static let shared = BookManifestEditor()

    /// Whether Edit Manifest has explained itself: the same key as the
    /// Mac's, so ConfigService treats it as machine-local on both.
    nonisolated static let explainedPreference = StoredPreference.flag("editManifestExplained", default: false)

    /// The sessions of the manifests being edited; the launch's look for
    /// outside edits (`takeOutsideManifestEdits`) reads them, and on iPhone
    /// none is ever begun.
    let sessions: BookManifestEditSessions = .shared

    /// Would open `book`'s manifest in another app, as the Mac does. Does
    /// nothing on iPhone.
    func edit(_ book: Book, choosingApp: Bool, in library: LibraryViewModel, from window: PlatformWindow?) async {}

    /// Would end the book's Edit Manifest session. Does nothing, since no
    /// session exists.
    func end(_ bookID: UUID) {}

    /// Would look for an edit of the book's manifest made outside Edit
    /// Manifest. Does nothing on iPhone, where nothing else edits it.
    func lookForOutsideEdit(of book: Book, showingPauses pauses: ChapterPauses?, in library: LibraryViewModel) {}

    /// Would act on what a look found: take an edit, or announce a refusal.
    /// Does nothing on iPhone.
    func handle(_ found: BookManifestEditCheck, for bookID: UUID, in library: LibraryViewModel) {}
}
