import Foundation

// MARK: - Edited Manifests (FR17)

extension LibraryViewModel {
    /// Gives the library an edit of a book's manifest that Edit Manifest
    /// took, already committed to the book's record
    /// (`BookManifestEditSessions`): the book's row takes the edit's
    /// analysis (its duration, its counts, and its index version), which
    /// its list shows, and the moves of its places the record took, and is
    /// saved.
    func commitManifestEdit(_ edit: BookManifestEdit) {
        applyAnalysisSummaries([ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)])
    }
}
