// Phase 0 stand-in: on the Mac, BookTextEditor is Edit Text in Default
// Editor and Edit Text With…: a text book's content.md opens in the user's
// own app, a session watches it, and what the user saves becomes the book's
// text. iPhone has no other app to edit in, so here no book is ever being
// edited: `canEditText` says no, the pause says nothing was being edited,
// and the commands do nothing. Only the members that shared code names are
// here, with the Mac's signatures and the same preference key.

import Foundation

/// The iOS stand-in for the Mac's BookTextEditor: no book is edited here.
@MainActor
final class BookTextEditor {
    /// The app's editor.
    static let shared = BookTextEditor()

    /// Whether Edit Text has explained itself: the same key as the Mac's,
    /// so ConfigService treats it as machine-local on both.
    nonisolated static let explainedPreference = StoredPreference.flag("editTextExplained", default: false)

    /// Would open `book`'s text in another app, as the Mac does. Does
    /// nothing on iPhone, where `canEditText(of:isTranscribed:)` keeps the
    /// command from being offered.
    func edit(_ book: Book, choosingApp: Bool, in library: LibraryViewModel, from window: PlatformWindow?) async {}

    /// Whether `book`'s text can be edited in another app: never on iPhone,
    /// so no menu or row offers Edit Text there.
    static func canEditText(of book: Book, isTranscribed: Bool) -> Bool {
        false
    }

    /// Would pause the book's Edit Text session before its text is
    /// rewritten. Returns false, the Mac's answer for a book that is not
    /// being edited, which is every book here; the caller then has nothing
    /// to resume.
    func pauseEditing(of book: Book) async -> Bool {
        false
    }

    /// Would begin the book's Edit Text session again after a failed
    /// change. Does nothing, since `pauseEditing(of:)` paused nothing.
    func resumeEditing(of book: Book) async {}

    /// Would end the book's Edit Text session because Replace Existing put a
    /// new copy in its place. Does nothing, since no session exists.
    func endBecauseBookWasReplaced(_ bookID: UUID, title: String) {}
}
