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
    /// is thrown.
    ///
    /// An install that fails leaves the transcript and its text as they
    /// were: a step that fails once transcript.json is written puts back
    /// each file the install wrote, byte for byte and with its dates (see
    /// `PackageFileBeforeInstall`), so the book's record, which an install
    /// that fails never changes, and the baseline a paused Edit Text session
    /// takes again both still describe them.
    ///
    /// The Transcribe Audio sheet looks at content.md and transcript.json
    /// before a transcription begins (`TranscriptionSheetModel.isBookInCloud`)
    /// and offers none while either is only in the cloud; the check here is
    /// the last guard, for a file that went to the cloud while the audio was
    /// transcribed.
    ///
    /// Runs as storage work (`StorageBoundary`), which a data-directory move
    /// waits for, and blocks while it reads and writes; call it off the main
    /// thread. Pass the book as the library holds it now: a transcription
    /// takes minutes, and the book may have moved meanwhile.
    /// - Parameter keepingExisting: Keeps a transcript the book has already:
    ///   when its package holds a transcript.json, on this Mac or only in
    ///   iCloud (`hasTranscript(of:)`, a look that never downloads), nothing
    ///   is read or written, and `OutsideTranscriptError.alreadyTranscribed`
    ///   is thrown. The podcast fetch (FMT25) passes true, so a transcript
    ///   the listener has, such as an earlier download's kept with the
    ///   episode, is never replaced. The look is made inside the storage
    ///   work, at the book's package as it is now, before anything is read,
    ///   so no data-directory move comes between it and the install's write;
    ///   installs are not made one at a time, though, so another install of
    ///   the same book at the same moment still could.
    /// - Parameter saveIndex: Saves the book's audio index, with the text's
    ///   layer, through the book's record, returning the book as the record
    ///   holds it then (`LibraryPersistenceService.saveContentAnalysis`);
    ///   tests pass one that fails.
    /// - Throws: `TranscriptionError.notAnAudiobook`, `.audioChanged` when a
    ///   file of the book is no longer the one transcribed,
    ///   `OutsideTranscriptError.alreadyTranscribed` when the book has a
    ///   transcript to keep, `TranscriptTextError.textOnlyInCloud` or
    ///   `.textNotKept`, and the error that kept a file from being written.
    @discardableResult
    static func install(
        _ transcript: Transcript,
        for book: Book,
        keepingExisting: Bool = false,
        hasher: FingerprintHasher = .md5,
        isDataless: @escaping (URL) -> Bool = DatalessFiles.isDataless,
        keepCopy: @escaping (URL, Data?) -> URL? = BookTextEditSessions.keepCopy(of:bytes:),
        saveIndex: @escaping (Book, BookContentIndex) throws -> Book? = {
            try LibraryPersistenceService.saveContentAnalysis(for: $0, index: $1, cacheFormatVersion: nil)
        }
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
            // A transcript the book has, kept when asked, before anything
            // is read or written.
            if keepingExisting, hasTranscript(of: book) {
                throw OutsideTranscriptError.alreadyTranscribed
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
            // transcript.json is written first, since the text's layer
            // fingerprints it as the text's source (`writeText`), so a later
            // step can fail with the new transcript in place: writing the
            // text, keeping a copy of the text it replaces, or saving the
            // index. Putting back what the install wrote keeps this order,
            // which is simpler than writing transcript.json last, as that
            // would mean fingerprinting it before it exists (transcripts
            // review, item 3). The text then still agrees with its
            // transcript, and a session's next save is never laid over a
            // transcript this install left behind.
            let transcriptBefore = PackageFileBeforeInstall(TextMouthPaths.transcriptPath(in: book.tmbDirectory))
            let textBefore = PackageFileBeforeInstall(TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory))
            // The stamp each file had once the install wrote it, nil until
            // then: only a file still holding that write is put back.
            var transcriptWritten: FileStamp?
            var textWritten: FileStamp?
            do {
                try write(transcript, into: book.tmbDirectory)
                transcriptWritten = FileStamp(of: transcriptBefore.url)
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
                textWritten = written.layer.textCacheFingerprint.cache.stamp
                // A transcription again replaces the text whatever its bytes,
                // so the reading text kept for the old one goes too.
                ReadingTextCache.shared.remove(bookID: book.id)
                var index = audioIndex
                index.transcript = written.layer
                let recorded = try saveIndex(book, index)
                return TranscriptInstallation(index: index, text: written.text, recordedBook: recorded)
            } catch {
                PackageFileBeforeInstall.putBack(
                    [(transcriptBefore, transcriptWritten), (textBefore, textWritten)],
                    of: book
                )
                throw error
            }
        }
    }
}

// MARK: - Whether a Book Has a Transcript

extension TranscriptStore {
    /// Whether `book`'s package holds a transcript, transcript.json, on this
    /// Mac or only in iCloud: a look at the package's folder, never a read,
    /// so nothing is downloaded, and whether the transcript can be read is
    /// not known from it. An install that keeps a transcript the book has
    /// looks with it (`install`'s `keepingExisting`), and so does an import
    /// deciding whether to offer to transcribe its book
    /// (`TranscriptionOffers`).
    static func hasTranscript(of book: Book) -> Bool {
        FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path)
    }
}

// MARK: - Putting Back What a Failed Install Wrote

/// A file of a book's package as an install found it before writing over it
/// (`TranscriptStore.install`), or a re-read in another encoding
/// (`LibraryViewModel.readTextAgain`, encodingchoice), kept so that a step
/// failing afterwards can put it back exactly: its bytes, and its access and
/// modification times, since the book's record and an Edit Text session's
/// baseline know the file by its size and modification time; or that there
/// was no file. Nothing is downloaded to keep it, so a file only in the
/// cloud, or one that can't be read, is not kept.
struct PackageFileBeforeInstall {
    /// What the file was before the install.
    private enum State {
        /// There was no file.
        case missing
        /// The file's bytes, its stamp, and its access and modification
        /// times, as stat(2) gave them.
        case kept(Data, stamp: FileStamp, times: [timespec])
        /// The file was only in the cloud, or could not be read.
        case unkept
    }

    /// Where the file is.
    let url: URL
    private let state: State

    /// The file at `url` as it is now: examined first, then read with
    /// dataless files left in the cloud.
    init(_ url: URL) {
        self.url = url
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &status) == 0
        }
        switch SavedFile.read(url, using: SavedFile.readWithoutDownloading) {
        case .missing:
            state = .missing
        case .contents(let bytes) where examined:
            state = .kept(
                bytes,
                stamp: FileStamp(
                    byteCount: Int64(status.st_size),
                    modificationTimeNanoseconds: FileStamp.nanoseconds(since1970: status.st_mtimespec)
                ),
                times: [status.st_atimespec, status.st_mtimespec]
            )
        case .contents, .inCloud, .unreadable:
            state = .unkept
        }
    }

    /// Puts back each of `files` that the install wrote, each given with the
    /// stamp its write left (nil when the install never wrote it), after an
    /// install of `book` failed. A file whose stamp is no longer the one its
    /// write left was written since by someone else, such as the user's
    /// editor saving content.md, and is left as it is, as is one the write
    /// left exactly as it was. When a file the install replaced was not
    /// kept, because it was only in the cloud or could not be read, none is
    /// put back: the new transcript then stays with any text written from
    /// it, and the next open of the book writes the text from transcript.json
    /// if none was. A file that cannot be put back is named in the debug log,
    /// in a line beginning with `logTag` that says `work` failed.
    static func putBack(
        _ files: [(file: PackageFileBeforeInstall, written: FileStamp?)],
        of book: Book,
        after work: String = "the install",
        logTag: String = TranscriptStore.logTag
    ) {
        let replaced = files.filter { $0.file.stillHolds($0.written) }.map(\.file)
        guard replaced.allSatisfy(\.isKept) else { return }
        for file in replaced {
            do {
                try file.restore()
            } catch {
                // Named by its domain and code: its own words can name the
                // package's folder by its absolute path.
                let failure = error as NSError
                DiagnosticLog.event(
                    .storage,
                    "\(logTag): \(book.title): \(file.url.lastPathComponent) could not be put back "
                        + "after \(work) failed: error \(failure.code) in \(failure.domain)"
                )
            }
        }
    }

    /// Whether the install replaced this file and the file still holds that
    /// write: `written` is the stamp the write left, it is not the stamp
    /// the file had before, and the file has it now.
    private func stillHolds(_ written: FileStamp?) -> Bool {
        guard let written else { return false }
        if case .kept(_, let stamp, _) = state, stamp == written { return false }
        return FileStamp(of: url) == written
    }

    /// Whether the file's state before the install is known, so it can be
    /// put back.
    private var isKept: Bool {
        if case .unkept = state { return false }
        return true
    }

    /// Puts the file back as it was: removes a file there was none of, or
    /// writes its bytes back and then its times.
    /// - Throws: Why the file could not be removed, written, or dated.
    private func restore() throws {
        switch state {
        case .missing:
            try FileManager.default.removeItem(at: url)
        case .kept(let bytes, _, let times):
            try bytes.write(to: url, options: .atomic)
            let dated = url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return utimensat(AT_FDCWD, path, times, 0) == 0
            }
            guard dated else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        case .unkept:
            break
        }
    }
}
