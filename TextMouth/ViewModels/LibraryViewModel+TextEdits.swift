import Foundation

// MARK: - Edited Text (FR05)

extension LibraryViewModel {
    /// Gives the library an edit of a book's text that Edit Text took,
    /// already committed to the book's record (`BookTextEditSessions`): the
    /// book's row takes the edit's analysis (its word and character counts,
    /// its index and cache versions, and the fingerprints of the edited
    /// content.md) and nothing else, and is saved; then the book's open
    /// readers show the edited text, near where each was reading, or, for a
    /// transcribed audiobook, its edited transcript text as the book plays
    /// on. The row's change reaches the readers first, through the usual
    /// updates (`LibraryBookUpdates`), so their copies of the book agree
    /// with the text they show.
    func commitTextEdit(_ edit: BookTextEdit) {
        // The row takes the moves of the book's places that the record took.
        applyAnalysisSummaries([ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)])
        switch edit.text {
        case .document(let content):
            bookUpdates.textReplaced(bookID: edit.committed.id, with: content)
        case .transcript(let text):
            bookUpdates.transcriptReplaced(bookID: edit.committed.id, with: text)
        }
    }
}
