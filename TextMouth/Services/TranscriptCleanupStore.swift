import Foundation

/// Why a transcript cleanup, or its undo, was not made (FR05), in words a
/// listener understands, the same on screen, in VoiceOver, and in braille.
enum TranscriptCleanupError: LocalizedError, Equatable {
    /// The book's transcript can't be read now: it is gone, only in the
    /// cloud, unusable, or of a layout this TextMouth does not read.
    case transcriptUnavailable
    /// transcript.json changed since the sheet showed what would change, as
    /// when another Mac transcribed the book again.
    case transcriptChanged
    /// The rules change nothing in the transcript.
    case nothingToChange
    /// There is no cleanup to undo: the transcript is not cleaned up, or the
    /// transcript from before it is gone.
    case nothingToUndo
    /// The transcript from before the cleanup is only in the cloud.
    case previousInCloud
    /// The transcript from before the cleanup can't be used, for the reason
    /// given, which names a field and never quotes the transcript.
    case previousUnusable(String)
    /// A file of the book's audio is not the one transcribed any more, for
    /// the reason given, so its transcript no longer fits it.
    case audioChanged(String)
    /// The book is being transcribed again now.
    case busyTranscribing
    /// The data directory can't be used now, or the app lacks its own rules.
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "The transcript can't be read now. If the book is only in the cloud, download it, then try again."
        case .transcriptChanged:
            return "The transcript changed since this was shown. Open Clean Up Transcript again to see what would change now."
        case .nothingToChange:
            return "The rules change nothing in this transcript."
        case .nothingToUndo:
            return "There is no cleanup to undo: the transcript from before it is gone."
        case .previousInCloud:
            return "The transcript from before the cleanup is only in the cloud. Download the book, then try again."
        case .previousUnusable(let reason):
            return "The transcript from before the cleanup can't be used: \(reason)."
        case .audioChanged(let reason):
            return "The book's audio changed since it was transcribed (\(reason)), so its transcript no longer fits it. "
                + "Transcribe it again."
        case .busyTranscribing:
            return "The book is being transcribed again. Clean up its transcript once that finishes."
        case .libraryUnavailable:
            return "The library isn't available, so the rules can't be opened now."
        }
    }
}

/// What a cleanup saved (`TranscriptStore.cleanUp`).
struct TranscriptCleanupResult: Sendable {
    /// The cleaned transcript, installed as the book's text.
    let installation: TranscriptInstallation
    /// How many corrections it made.
    let corrections: Int
    /// How many sentences it changed.
    let changedSentences: Int
}

extension TranscriptStore {
    /// Cleans up `book`'s transcript with `rules`, from `source` (FR05,
    /// experimental), when transcript.json still holds `expected`, the
    /// transcript the user saw the changes for.
    ///
    /// transcript.json as it was is kept beside it first, as
    /// transcript.json.before-cleanup, replacing a copy an earlier cleanup
    /// kept, so Undo Cleanup can put it back (`undoCleanup(of:)`). The
    /// cleaned transcript records the cleanup (`TranscriptCleanupNote`), and
    /// is installed as a transcription installs one
    /// (`install(_:for:hasher:)`): transcript.json, content.md written from
    /// it, with any text there that TextMouth did not write kept beside it,
    /// and the transcript's layer of the book's audio index, saved through
    /// the book's record. A cleanup that fails leaves transcript.json and its
    /// text as they were, since an install that fails puts back what it
    /// wrote, and so the copy beside it too. Positions and bookmarks stay as
    /// they are: they count time, which a cleanup does not change.
    ///
    /// Runs as storage work, which a data-directory move waits for, and
    /// blocks while it reads and writes; call it off the main thread.
    /// - Throws: `TranscriptionError.notAnAudiobook`; `TranscriptCleanupError`
    ///   when the transcript can't be read, changed, or would not change,
    ///   or the book's audio changed since it was transcribed;
    ///   and what installing it throws.
    @discardableResult
    static func cleanUp(
        _ book: Book,
        expecting expected: Transcript,
        with rules: TranscriptCleanupRuleSet,
        from source: TranscriptCleanupRuleSource,
        now: Date = Date(),
        hasher: FingerprintHasher = .md5
    ) throws -> TranscriptCleanupResult {
        guard book.format.isAudio else { throw TranscriptionError.notAnAudiobook }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let book = boundary.rebasedToCurrent(book)
            let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
            guard case .contents(let bytes) = SavedFile.read(transcriptURL, using: SavedFile.readWithoutDownloading),
                  let transcript = try? decoded(bytes), transcript.validationFailure() == nil else {
                throw TranscriptCleanupError.transcriptUnavailable
            }
            guard transcript == expected else { throw TranscriptCleanupError.transcriptChanged }
            let preview = TranscriptCleanup(rules: rules.rules).preview(of: transcript)
            guard preview.corrections > 0 else { throw TranscriptCleanupError.nothingToChange }
            var cleaned = preview.cleaned
            cleaned.cleanedUp = TranscriptCleanupNote(
                // Whole seconds, as transcript.json keeps its dates.
                cleanedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                rulesVersion: rules.version,
                rulesDate: rules.date,
                rules: source.rawValue,
                corrections: preview.corrections
            )

            let copyURL = TextMouthPaths.transcriptBeforeCleanupPath(in: book.tmbDirectory)
            // The copy an earlier cleanup kept, to put back should this one
            // fail before it replaces the transcript.
            let earlierCopy = try? SavedFile.readWithoutDownloading(copyURL)
            try bytes.write(to: copyURL, options: .atomic)
            let installation: TranscriptInstallation
            do {
                installation = try install(cleaned, for: book, hasher: hasher)
            } catch {
                // transcript.json unchanged: the copy goes back to what it was.
                if (try? SavedFile.readWithoutDownloading(transcriptURL)) == bytes {
                    if let earlierCopy {
                        try? earlierCopy.write(to: copyURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: copyURL)
                    }
                }
                throw cleanupError(for: error)
            }
            DiagnosticLog.event(
                .storage,
                "\(cleanupTag): \(book.title): \(preview.corrections) correction(s) in \(preview.changedSentences) sentence(s), "
                    + "\(source.rawValue) rules version \(rules.version); transcript.json kept as \(copyURL.lastPathComponent)"
            )
            return TranscriptCleanupResult(
                installation: installation,
                corrections: preview.corrections,
                changedSentences: preview.changedSentences
            )
        }
    }

    /// Undoes the last cleanup of `book`'s transcript (FR05): the transcript
    /// kept beside it before the cleanup, transcript.json.before-cleanup, is
    /// installed again as a transcription installs one, and the copy goes.
    /// Edits made in the user's editor since the cleanup go with it, as the
    /// Clean Up sheet says first.
    ///
    /// Runs as storage work, and blocks while it reads and writes; call it
    /// off the main thread.
    /// - Throws: `TranscriptionError.notAnAudiobook`; `TranscriptCleanupError`
    ///   when there is no cleanup to undo, the copy can't be used, or the
    ///   book's audio changed since it was transcribed; and what installing
    ///   it throws.
    @discardableResult
    static func undoCleanup(of book: Book, hasher: FingerprintHasher = .md5) throws -> TranscriptInstallation {
        guard book.format.isAudio else { throw TranscriptionError.notAnAudiobook }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let book = boundary.rebasedToCurrent(book)
            guard case .found(let current) = read(from: book.tmbDirectory), current.cleanedUp != nil else {
                throw TranscriptCleanupError.nothingToUndo
            }
            let copyURL = TextMouthPaths.transcriptBeforeCleanupPath(in: book.tmbDirectory)
            let previous: Transcript
            switch SavedFile.read(copyURL, using: SavedFile.readWithoutDownloading) {
            case .missing:
                throw TranscriptCleanupError.nothingToUndo
            case .inCloud:
                throw TranscriptCleanupError.previousInCloud
            case .unreadable(let reason):
                throw TranscriptCleanupError.previousUnusable(reason)
            case .contents(let bytes):
                do {
                    previous = try decoded(bytes)
                } catch {
                    throw TranscriptCleanupError.previousUnusable(describe(error))
                }
            }
            if let reason = previous.validationFailure() {
                throw TranscriptCleanupError.previousUnusable(reason)
            }
            let installation: TranscriptInstallation
            do {
                installation = try install(previous, for: book, hasher: hasher)
            } catch {
                throw cleanupError(for: error)
            }
            do {
                try FileManager.default.removeItem(at: copyURL)
            } catch {
                // The transcript is back; a copy left behind is offered for
                // undoing only while a cleaned transcript stands beside it.
                let failure = error as NSError
                DiagnosticLog.event(
                    .storage,
                    "\(cleanupTag): \(book.title): could not remove \(copyURL.lastPathComponent): "
                        + "error \(failure.code) in \(failure.domain)"
                )
            }
            DiagnosticLog.event(.storage, "\(cleanupUndoneTag): \(book.title): the transcript from before the cleanup is back")
            return installation
        }
    }

    /// `error`, from installing a transcript for a cleanup or its undo, in
    /// the cleanup's own words where it has them: audio changed since the
    /// book was transcribed, which a transcription words as a change while
    /// it ran.
    private static func cleanupError(for error: Error) -> Error {
        if case .audioChanged(let reason)? = error as? TranscriptionError {
            return TranscriptCleanupError.audioChanged(reason)
        }
        return error
    }

    /// Whether `book`'s package holds the transcript kept before a cleanup,
    /// by a look at its folder, which never downloads anything.
    static func hasTranscriptBeforeCleanup(of book: Book) -> Bool {
        FileManager.default.fileExists(atPath: TextMouthPaths.transcriptBeforeCleanupPath(in: book.tmbDirectory).path)
    }

    /// The tag of the debug log's line about a cleanup saved.
    static let cleanupTag = "TRANSCRIPT_CLEANED_UP"
    /// The tag of the line about a cleanup undone.
    static let cleanupUndoneTag = "TRANSCRIPT_CLEANUP_UNDONE"
}
