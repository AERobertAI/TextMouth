import Foundation

// MARK: - Library Updates (TODO P10)

/// How an open reader keeps its copy of its book current while the library
/// edits, renames, or moves the book from another window.
///
/// A reader takes its own copy of its book when it opens. The library
/// publishes every change of what readers show or use of a book (where its
/// files are, its editable metadata, and its analysis; see
/// `Book.LibraryFields`) through `LibraryBookUpdates`, each with the book's
/// next revision. The reader applies each update it has not applied yet:
/// its copy takes the library's fields and keeps everything that is the
/// reader's own, and whatever the reader shows from those fields follows.
/// Nothing is reloaded, and playback goes on.
extension ReaderViewModel {

    /// Handles one event the library sent about this reader's book. A
    /// closed reader has nothing left to keep current.
    func handleLibraryEvent(_ event: LibraryBookEvent) {
        guard !hasClosed, case .updated(let update) = event else { return }
        applyLibraryUpdate(update)
    }

    /// Applies `update` when it is about this reader's book and newer than
    /// the last update applied; an older or repeated one changes nothing.
    ///
    /// The reader's copy of the book takes the library's fields from the
    /// update's row (`Book.LibraryFields`), so later saves, Continue to Next
    /// Book, and everything the reader shows start from the book as the
    /// library has it. The reader's own state (its cursor, bookmarks,
    /// voice, speed, and other settings, which it writes through to the
    /// library itself) stays as it is.
    func applyLibraryUpdate(_ update: LibraryBookUpdate) {
        guard update.book.id == book.id, update.revision > appliedLibraryRevision else { return }
        appliedLibraryRevision = update.revision
        let previous = book
        book.libraryFields = update.book.libraryFields
        if book.editableMetadata != previous.editableMetadata {
            showEditedMetadata()
        }
    }

    /// Shows the book's metadata as the library now has it wherever the
    /// reader keeps metadata of its own: the values its metadata editor
    /// starts from, so a later save there cannot put back what the library
    /// replaced, and Now Playing. The window title, Where Am I?, and the
    /// reader's announcements read the book itself.
    private func showEditedMetadata() {
        if let epubMetadata {
            self.epubMetadata = book.mergingEditableEPUBMetadata(epubMetadata)
        }
        if let audioMetadata {
            self.audioMetadata = book.mergingEditableAudioMetadata(audioMetadata)
        }
        // Now Playing names this reader's book only while it plays or is
        // paused; a stopped reader has nothing there to correct, and
        // updating it would put a stopped book back.
        if isCurrentlyPlaying || isCurrentlyPaused {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title,
                author: book.author,
                isPlaying: isPlaybackActivelyAdvancing
            )
        }
    }
}
