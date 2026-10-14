import Foundation

// MARK: - Edited Manifests (FR17)

extension LibraryViewModel {
    /// Gives the library an edit of a book's manifest that Edit Manifest
    /// took, already committed to the book's record
    /// (`BookManifestEditSessions`): the book's row takes the edit's
    /// analysis (its duration, its counts, and its index version), which
    /// its list shows, and the moves of its places the record took, and is
    /// saved; then its title and author take the manifest's, when it gives
    /// them, through the one write of a manifest book's title and author.
    func commitManifestEdit(_ edit: BookManifestEdit) {
        applyAnalysisSummaries([ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)])
        setTitleAndAuthor(ofManifestBook: edit.committed.id, title: edit.title, author: edit.author)
    }

    // MARK: Title and Author, Kept in Step

    /// The one write of the title and author of an audiobook of tracks
    /// (FR17), so that its manifest and the book never say different things.
    /// The user, October 13, 2026: "I kind of think hand edited meta data in
    /// TextMouth in this case should just be synced / stored in the
    /// MANIFEST since it's both user editable and them diverging might get
    /// someone confused."
    ///
    /// The book's row, and so its record, takes `title` and `author` now,
    /// nil leaving either; then its manifest takes them, as storage work on
    /// the manifest sessions' queue, in the order they were given
    /// (`BookManifestFile.keepTitleAndAuthor`). Every path through which a
    /// manifest book's title or author changes calls this: an edited
    /// manifest taken (`commitManifestEdit`), whose manifest holds them
    /// already, and a metadata editor's save (`updateBookMetadata`), whose
    /// row holds them already. The launch's metadata refresh reads no tags
    /// from a folder of tracks, so it changes neither. A book that is no
    /// audiobook of tracks has only its row changed.
    func setTitleAndAuthor(
        ofManifestBook bookID: UUID,
        title: String?,
        author: String?,
        sessions: BookManifestEditSessions = .shared,
        written: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard let row = bookByID(bookID), title != nil || author != nil else {
            written?(false)
            return
        }
        let newTitle = title ?? row.title
        let newAuthor = author ?? row.author
        if newTitle != row.title || newAuthor != row.author {
            updateBook(id: bookID) { book in
                book.title = newTitle
                book.author = newAuthor
            }
        }
        guard let book = bookByID(bookID), BookManifestEditing.canEditManifest(of: book, isTrackFolder: true) else {
            written?(false)
            return
        }
        sessions.queue.async {
            let didWrite: Bool
            do {
                didWrite = try BookManifestFile.keepTitleAndAuthor(of: book, title: title, author: author, sessions: sessions)
            } catch {
                DiagnosticLog.event(.storage, "MANIFEST_NOT_WRITTEN: \(book.title): \(error.localizedDescription)")
                didWrite = false
            }
            Task { @MainActor in
                written?(didWrite)
            }
        }
    }
}
