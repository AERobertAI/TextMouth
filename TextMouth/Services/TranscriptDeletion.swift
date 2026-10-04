import Foundation

/// What deleting a book's transcript did (`TranscriptStore.delete(for:)`).
struct TranscriptDeletion: Sendable {
    /// The book as its record holds it now, its audio index without the
    /// transcript's layer; nil when the record could not take the index, as
    /// when it is only in the cloud. The next open of the book then drops
    /// the layer itself, finding no transcript.json.
    let recordedBook: Book?
}

extension TranscriptStore {
    /// Deletes `book`'s transcript (FR05): transcript.json, the content.md
    /// written from it, the transcript's layer of the book's audio index,
    /// saved through the book's record (which drops bookInfo.json's note of
    /// it), and the reading text this Mac kept for the book. The audio, the
    /// reading position, the bookmarks, and the book's settings stay as
    /// they are: they count time, which a transcript does not change.
    ///
    /// transcript.json goes first, so a deletion cut short leaves no
    /// transcript for the next open to show: it then drops the rest itself.
    /// A file only in the cloud is removed without being downloaded. Copies
    /// TextMouth kept beside the files, of an edit it could not take or of
    /// an unusable transcript, are the user's, and stay.
    ///
    /// Runs as storage work (`StorageBoundary`), which a data-directory move
    /// waits for, and blocks while it writes; call it off the main thread.
    /// - Throws: `TranscriptionError.notAnAudiobook`, and the error that
    ///   kept a file from being removed or the record from being written.
    @discardableResult
    static func delete(for book: Book) throws -> TranscriptDeletion {
        guard book.format.isAudio else { throw TranscriptionError.notAnAudiobook }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let book = boundary.rebasedToCurrent(book)
            try removeIfPresent(TextMouthPaths.transcriptPath(in: book.tmbDirectory))
            try removeIfPresent(TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory))
            ReadingTextCache.shared.remove(bookID: book.id)
            var index = try BookContentAnalysisService.load(book: book).index
            index.transcript = nil
            let recorded = try LibraryPersistenceService.saveContentAnalysis(for: book, index: index, cacheFormatVersion: nil)
            return TranscriptDeletion(recordedBook: recorded)
        }
    }

    /// Removes the file at `url`, when there is one.
    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone: nothing to remove.
        }
    }
}
