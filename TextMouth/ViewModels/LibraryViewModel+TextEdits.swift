import Foundation

// MARK: - Edited Text (FR05)

extension LibraryViewModel {
    /// Gives the library an edit of a book's text that Edit Text took,
    /// already committed to the book's record (`BookTextEditSessions`): the
    /// book's row takes the edit's analysis (its word and character counts,
    /// its index and cache versions, and the fingerprints of the edited
    /// content.md) and nothing else, and is saved; then the book's open
    /// readers show the edited text, near where each was reading. The
    /// row's change reaches the readers first, through the usual updates
    /// (`LibraryBookUpdates`), so their copies of the book agree with the
    /// text they show.
    func commitTextEdit(_ edit: BookTextEdit) {
        applyAnalysisSummaries([ContentAnalysisSummary(committed: edit.committed)])
        bookUpdates.textReplaced(bookID: edit.committed.id, with: edit.content)
    }
}
