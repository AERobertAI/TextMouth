import Foundation

/// What saving a transcript into its book did (`TranscriptStore.install`).
struct TranscriptInstallation: Sendable {
    /// The book's audio index, now carrying the transcript text's layer, as
    /// the book's record holds it.
    let index: BookContentIndex
    /// The transcript text, as a reader opening the book now shows it.
    let text: TranscriptText
    /// The book as its record holds it now, or nil when the record could
    /// not take the index, as when it is only in the cloud; the next open
    /// of the book then writes the index from transcript.json.
    let recordedBook: Book?
}

extension TranscriptStore {
    /// Saves `transcript` as `book`'s transcript and makes it the book's text
    /// (FR05): transcript.json, content.md written from it, and the book's
    /// audio index carrying the text's layer, saved through the book's record
    /// (`LibraryPersistenceService.saveContentAnalysis`), which also notes
    /// the transcript in bookInfo.json. A transcript the book had is replaced,
    /// with its text, and the reading text this Mac kept for the book is
    /// dropped. The book's reading position, bookmarks, and settings are
    /// left as they are: they count time, which a transcript does not
    /// change.
    ///
    /// The text content.md holds is kept beside it before it goes when it is
    /// not what the transcript the package held wrote (`writeText`'s
    /// `previous`).
    ///
    /// content.md must be on this Mac: when it is only in the cloud,
    /// nothing is read, downloaded, or written, transcript.json stays as it
    /// was, and `TranscriptTextError.textOnlyInCloud` is thrown. When content.md
    /// holds text that must be kept first and no copy can be made
    /// (`TranscriptTextLoader.writeText`), `TranscriptTextError.textNotKept`
    /// is thrown; transcript.json is then already written, and the next
    /// open of the book writes the text from it again.
    ///
    /// Runs as storage work (`StorageBoundary`), which a data-directory move
    /// waits for, and blocks while it reads and writes; call it off the main
    /// thread. Pass the book as the library holds it now: a transcription
    /// takes minutes, and the book may have moved meanwhile.
    /// - Throws: `TranscriptionError.notAnAudiobook`, `.audioChanged` when a
    ///   file of the book is no longer the one transcribed,
    ///   `TranscriptTextError.textOnlyInCloud` or `.textNotKept`, and the
    ///   error that kept a file from being written.
    @discardableResult
    static func install(
        _ transcript: Transcript,
        for book: Book,
        hasher: FingerprintHasher = .md5,
        isDataless: @escaping (URL) -> Bool = DatalessFiles.isDataless,
        keepCopy: @escaping (URL, Data?) -> URL? = BookTextEditSessions.keepCopy(of:bytes:)
    ) throws -> TranscriptInstallation {
        guard book.format.isAudio else { throw TranscriptionError.notAnAudiobook }
        if let reason = transcript.validationFailure() {
            throw TranscriptionError.recognitionFailed("the transcript is not usable: \(reason)")
        }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let book = boundary.rebasedToCurrent(book)
            guard FileManager.default.fileExists(atPath: book.tmbDirectory.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: book.tmbDirectory.lastPathComponent])
            }
            var audioIndex = try BookContentAnalysisService.load(book: book).index
            // The text the book's transcript wrote last: other text in
            // content.md, which the user saved, is kept before it goes.
            let writtenDigest = audioIndex.transcript?.textCacheFingerprint.cache.digest
            audioIndex.transcript = nil
            switch TranscriptTextLoader.audioCheck(
                of: transcript.audioFiles,
                for: book,
                audioIndex: audioIndex,
                isDataless: isDataless,
                hasher: hasher
            ) {
            case .changed(let reason):
                throw TranscriptionError.audioChanged(reason)
            case .current:
                break
            }
            // Before transcript.json is written: a content.md only in the
            // cloud is neither read nor replaced, and nothing changes.
            try TranscriptTextLoader.requireTextOnThisMac(
                at: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory),
                isDataless: isDataless
            )
            // The transcript the package's content.md was written from, read
            // before it is replaced (nothing is downloaded: only a transcript
            // on this Mac is found), so a content.md that is exactly what an
            // edited transcript wrote is replaced without a copy.
            var previous: Transcript?
            if case .found(let found) = read(from: book.tmbDirectory) { previous = found }
            try write(transcript, into: book.tmbDirectory)
            let written = try TranscriptTextLoader.writeText(
                of: transcript,
                for: book,
                over: audioIndex,
                replacing: writtenDigest,
                previous: previous,
                hasher: hasher,
                isDataless: isDataless,
                keepCopy: keepCopy
            )
            // A transcription again replaces the text whatever its bytes,
            // so the reading text kept for the old one goes too.
            ReadingTextCache.shared.remove(bookID: book.id)
            var index = audioIndex
            index.transcript = written.layer
            let recorded = try LibraryPersistenceService.saveContentAnalysis(for: book, index: index, cacheFormatVersion: nil)
            return TranscriptInstallation(index: index, text: written.text, recordedBook: recorded)
        }
    }
}
