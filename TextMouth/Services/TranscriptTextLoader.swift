import Foundation

/// Reads a transcribed audiobook's transcript text as the book opens (FR05),
/// and writes it again from its transcript when it is missing or out of date.
///
/// The text is trusted as a text book's cache is (TODO T07): the transcript
/// layer of the book's audio index must pass validation against that index,
/// transcript.json and content.md must be the files it was made from, by
/// their sizes and dates (and digests, only when a date moved), and the
/// parsed content.md must line up with the layer's own index. The audio
/// files must be the ones transcribed: a file edited or replaced since makes
/// the transcript stale, which is logged (TRANSCRIPT_STALE) and shows no
/// text until the book is transcribed again. Otherwise a text that cannot
/// be trusted is written again from transcript.json, as a stale text cache
/// is extracted again from its source, and logged (TRANSCRIPT_TEXT_REBUILT);
/// a hand edit of content.md that Edit Text did not take is undone this way,
/// after it is kept beside content.md (`writeText`). Edit Text takes an edit
/// into transcript.json itself (`TranscriptStore.takeEdit`), so the text
/// written from it is the edit; a session editing the book is told of each
/// rewrite, so TextMouth's own is never taken as an edit. A file only in the
/// cloud is never read: the text waits until it is on this Mac.
enum TranscriptTextLoader {
    /// What reading a book's transcript text found.
    struct Load {
        /// The transcript text to show, or nil when the book has none that
        /// can be shown now.
        var text: TranscriptText?
        /// The book's audio index as it should be saved: with the transcript
        /// layer the text was read with or written by, or without a layer
        /// once the book's transcript is gone or unusable.
        var index: BookContentIndex
        /// Whether `index` differs from the index the load was given, so
        /// the caller saves it.
        var indexChanged: Bool
        /// Why a book that has a transcript shows none of its text, when it
        /// is one of the reasons Search in Book names; nil when text is
        /// shown, when the book has no transcript, and for any other reason.
        var withheld: TranscriptTextWithheld? = nil

        /// This load, saying `reason` why it shows no text.
        func withholding(_ reason: TranscriptTextWithheld) -> Load {
            var copy = self
            copy.withheld = reason
            return copy
        }
    }

    /// The tag of the debug log's line about a transcript that no longer
    /// describes its book's audio.
    static let staleTag = "TRANSCRIPT_STALE"
    /// The tag of the line about a transcript text written again from the
    /// book's transcript.
    static let rebuiltTag = "TRANSCRIPT_TEXT_REBUILT"

    /// `book`'s transcript text, laid over `audioIndex`, the book's audio
    /// index as its load gave it, through `readingTexts` (the reader's cache
    /// of large books' reading text, PERF22) when given. Writes content.md
    /// only when the text must be written again, as storage work, and then
    /// tells `sessions` of it: a session editing the book takes the text
    /// written as the one it starts from, never as the user's edit
    /// (`writeText`'s `sessions`).
    static func load(
        for book: Book,
        audioIndex: BookContentIndex,
        readingTexts: ReadingTextCache? = nil,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        hasher: FingerprintHasher = .md5,
        sessions: BookTextEditSessions = .shared
    ) -> Load {
        let unchanged = Load(text: nil, index: audioIndex, indexChanged: false)
        guard book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return unchanged }
        let package = book.tmbDirectory
        let transcriptURL = TextMouthPaths.transcriptPath(in: package)
        let cacheURL = TextMouthPaths.contentMarkdownPath(in: package)
        // Most audiobooks have no transcript: a look at the folder, which
        // never downloads anything, says so.
        guard audioIndex.transcript != nil || FileManager.default.fileExists(atPath: transcriptURL.path) else {
            return unchanged
        }
        // Reading either file only in the cloud would download it. The
        // transcript's is named first, as the lines about the cloud are.
        let transcriptInCloud = isDataless(transcriptURL)
        guard !transcriptInCloud, !isDataless(cacheURL) else {
            return unchanged.withholding(transcriptInCloud ? .transcriptInCloud : .textInCloud)
        }

        var rebuildReason = "the book's index holds no transcript text"
        if let layer = audioIndex.transcript {
            if let failure = layer.validationFailure(against: audioIndex) {
                rebuildReason = "its index was set aside: \(failure)"
            } else {
                switch audioCheck(of: layer.audioFiles, for: book, audioIndex: audioIndex, isDataless: isDataless, hasher: hasher) {
                case .changed(let reason):
                    // transcript.json may be newer than the index, as when
                    // another Mac transcribed the edited audio again: the
                    // rebuild checks the audio against it, and reports a
                    // transcript that is stale there too.
                    rebuildReason = "its index describes other audio: \(reason)"
                case .current(let audioFiles):
                    if let load = readSavedText(
                        of: book,
                        layer: layer,
                        audioFiles: audioFiles,
                        audioIndex: audioIndex,
                        readingTexts: readingTexts,
                        hasher: hasher,
                        rebuildReason: &rebuildReason
                    ) {
                        return load
                    }
                }
            }
        }
        return rebuild(
            for: book,
            audioIndex: audioIndex,
            because: rebuildReason,
            isDataless: isDataless,
            hasher: hasher,
            sessions: sessions
        )
    }

    // MARK: - The Saved Text

    /// The saved text of `book`, whose sound transcript layer is `layer` and
    /// whose audio files, as checked now, are `audioFiles`; nil, with
    /// `rebuildReason` saying why, when transcript.json or content.md is not
    /// what the layer was made from, or content.md does not line up with it.
    /// Neither file is dataless: the load has checked.
    private static func readSavedText(
        of book: Book,
        layer: BookContentTranscriptIndex,
        audioFiles: [TranscriptAudioFile],
        audioIndex: BookContentIndex,
        readingTexts: ReadingTextCache?,
        hasher: FingerprintHasher,
        rebuildReason: inout String
    ) -> Load? {
        let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let cacheURL = TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
        // Both stamped before either is read, so a file that changes while
        // it is read differs from its stamp next time.
        let cacheStamp = FileStamp(of: cacheURL)
        let cacheIdentity = readingTexts == nil ? nil : ContentFileIdentity(of: cacheURL)
        var bytes: Data?
        func cacheBytes() throws -> Data {
            if let bytes { return bytes }
            let read = try Data(contentsOf: cacheURL)
            bytes = read
            return read
        }
        let verification: TextCacheVerification
        do {
            verification = try layer.textCacheFingerprint.verify(
                sourceURL: transcriptURL,
                sourceStamp: FileStamp(of: transcriptURL),
                cacheStamp: cacheStamp,
                cacheDigest: { try hasher.digestOfData(cacheBytes()) },
                hasher: hasher
            )
        } catch {
            rebuildReason = "content.md could not be read"
            return nil
        }
        guard case .current(let fingerprint) = verification else {
            if case .stale(let staleness) = verification {
                rebuildReason = staleness == .sourceChanged ? "transcript.json changed" : "content.md changed"
            }
            return nil
        }

        var savedLayer = layer
        savedLayer.textCacheFingerprint = fingerprint
        savedLayer.audioFiles = audioFiles
        let readingIndex = savedLayer.readingIndex
        // A large book's reading text kept for this very content.md is read
        // from there instead (PERF22).
        let key = cacheIdentity.map {
            ReadingTextKey(contentDigest: fingerprint.cache.digest, content: $0, bookTitle: book.title)
        }
        var chapters: [Chapter]?
        if let readingTexts, let key, readingTexts.keeps(key),
           case .found(let kept) = readingTexts.chapters(for: book.id, key: key),
           readingIndex.alignmentFailure(with: kept, countingWords: false) == nil {
            chapters = kept
        }
        if chapters == nil {
            guard let data = try? cacheBytes(),
                  let markdown = try? MarkdownCacheService.cacheText(from: data, at: cacheURL) else {
                rebuildReason = "content.md could not be read"
                return nil
            }
            let parsed = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: book.title, bookAuthor: book.author)
            if let reason = readingIndex.alignmentFailure(with: parsed.chapters, countingWords: false) {
                rebuildReason = "content.md does not line up with its index: \(reason)"
                return nil
            }
            chapters = parsed.chapters
            if let readingTexts, let key {
                readingTexts.storeInBackground(parsed.chapters, for: book.id, key: key)
            }
        }
        guard let chapters else { return nil }
        var index = audioIndex
        index.transcript = savedLayer
        return Load(
            text: TranscriptText(chapters: chapters, index: savedLayer),
            index: index,
            indexChanged: savedLayer != layer
        )
    }

    // MARK: - Writing the Text Again

    /// The text of `book` written again from its transcript.json, `because`
    /// of what the load found, with the audio index carrying the new layer;
    /// or no text, and no layer, when the book's transcript is gone or
    /// unusable; or no text and the index as it was when the transcript is
    /// in the cloud, of a later layout, or stale. A session editing the book
    /// (`sessions`) is told when the text is written.
    private static func rebuild(
        for book: Book,
        audioIndex: BookContentIndex,
        because reason: String,
        isDataless: (URL) -> Bool,
        hasher: FingerprintHasher,
        sessions: BookTextEditSessions
    ) -> Load {
        let unchanged = Load(text: nil, index: audioIndex, indexChanged: false)
        var withoutText = audioIndex
        withoutText.transcript = nil
        let dropped = Load(text: nil, index: withoutText, indexChanged: audioIndex.transcript != nil)

        switch TranscriptStore.read(from: book.tmbDirectory) {
        case .missing, .unusable:
            return dropped
        case .inCloud:
            return unchanged.withholding(.transcriptInCloud)
        case .unsupportedVersion:
            return unchanged
        case .found(let transcript):
            switch audioCheck(of: transcript.audioFiles, for: book, audioIndex: audioIndex, isDataless: isDataless, hasher: hasher) {
            case .changed(let staleness):
                reportStale(book, staleness)
                return unchanged.withholding(.audioChanged)
            case .current:
                break
            }
            do {
                let written = try writeText(
                    of: transcript,
                    for: book,
                    over: withoutText,
                    replacing: audioIndex.transcript?.textCacheFingerprint.cache.digest,
                    hasher: hasher,
                    isDataless: isDataless,
                    sessions: sessions
                )
                logLine(rebuiltTag, about: book, "content.md and its index were written again from transcript.json: \(reason)")
                var index = withoutText
                index.transcript = written.layer
                return Load(text: written.text, index: index, indexChanged: index != audioIndex)
            } catch let error as TranscriptTextError where error.leavesTextAsItIs {
                // content.md is as it was: only in the cloud, or holding text
                // no copy could be made of. The book's index is left as it
                // is, and the next open tries again.
                logLine(rebuiltTag, about: book, "content.md was left as it is (\(reason)): \(error.logDescription)")
                return error == .textOnlyInCloud ? unchanged.withholding(.textInCloud) : unchanged
            } catch {
                // The error is named by its domain and code: its own words
                // can name the package's folder by its absolute path.
                let failure = error as NSError
                logLine(
                    rebuiltTag,
                    about: book,
                    "could not write the text from transcript.json (\(reason)): error \(failure.code) in \(failure.domain)"
                )
                return dropped
            }
        }
    }

    /// The text of `transcript`, written for `book` over `audioIndex`, its
    /// audio index without a transcript layer: content.md, written into the
    /// package as storage work only when it does not already hold exactly
    /// these bytes, and the layer describing it, fingerprinted with the
    /// package's transcript.json as its source. A content.md that changes
    /// takes the reading text this Mac kept for the book with it (PERF22).
    ///
    /// A content.md that is only in the cloud (`isDataless`) is never read,
    /// downloaded, or written over: nothing is touched, and
    /// `TranscriptTextError.textOnlyInCloud` is thrown.
    ///
    /// A content.md holding text TextMouth did not write, as the user may
    /// have saved in their own editor without the edit being taken (FR05),
    /// is kept beside it first (`keepCopy`, by default
    /// `BookTextEditSessions.keepCopy(of:bytes:)`), so nothing the user saved
    /// is lost. Its bytes must differ from the new bytes, and one of these
    /// must hold:
    /// - its digest is not `writtenDigest`, the digest of the content.md
    ///   TextMouth last wrote or took (any digest, when that is nil);
    /// - the transcript content.md was written from was edited by the user
    ///   (`Transcript.editedAt`; `previous`, or `transcript` itself when
    ///   `previous` is nil), and content.md's reading text is not the reading
    ///   text of the text written from that transcript (`readingText(of:)`):
    ///   an edit taken before edits outside the sentences were refused may
    ///   have left a renamed heading or words the transcript cannot hold,
    ///   under the very digest TextMouth recorded. A content.md that only
    ///   escapes or breaks its paragraphs differently reads the same, and is
    ///   not kept; nor is one that is exactly what an edited transcript
    ///   wrote, which a cleaned-up copy of it replaces.
    ///
    /// - Parameter previous: The transcript content.md was written from before
    ///   `transcript` replaces it, as an install's (`TranscriptStore.install`)
    ///   reads it from the package; nil when it is `transcript` itself, as in
    ///   the loader's rebuild.
    /// - Parameter sessions: The sessions to tell when the text is written
    ///   (`BookTextEditSessions.textRebuilt(_:writing:fingerprint:)`), none
    ///   by default. A session editing the book then starts from the text
    ///   just written, with its fingerprints, so the next check of content.md
    ///   finds nothing changed: without it, TextMouth's own rewrite (as when
    ///   the text's layer is out of date) would be taken as the user's edit.
    ///   The loader passes the app's; an install, which pauses the session
    ///   first, passes none.
    ///
    /// When a copy is needed and `keepCopy` cannot make it,
    /// `TranscriptTextError.textNotKept` is thrown before anything is
    /// written: content.md stays as it was.
    /// - Throws: `TranscriptTextError.textOnlyInCloud` or `.textNotKept`, or
    ///   why content.md or the fingerprints could not be written.
    static func writeText(
        of transcript: Transcript,
        for book: Book,
        over audioIndex: BookContentIndex,
        replacing writtenDigest: String? = nil,
        previous: Transcript? = nil,
        hasher: FingerprintHasher,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        keepCopy: (URL, Data?) -> URL? = BookTextEditSessions.keepCopy(of:bytes:),
        sessions: BookTextEditSessions? = nil
    ) throws -> (layer: BookContentTranscriptIndex, text: TranscriptText) {
        let chapters = TranscriptTextBuilder.chapters(
            of: transcript,
            over: audioIndex,
            bookFileName: book.bookFileURL.lastPathComponent
        )
        guard let text = TranscriptTextBuilder.text(of: chapters, bookTitle: book.title, bookAuthor: book.author) else {
            throw TranscriptTextError.chaptersNotReadBack
        }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            let book = boundary.rebasedToCurrent(book)
            let transcriptURL = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
            let cacheURL = TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
            let bytes = Data(text.markdown.utf8)
            // Nothing is read until content.md is known to be on this Mac.
            try requireTextOnThisMac(at: cacheURL, isDataless: isDataless)
            let existing = try? Data(contentsOf: cacheURL)
            if existing != bytes {
                if let existing,
                   unwrittenTextNeedsKeeping(
                       existing,
                       writtenDigest: writtenDigest,
                       replacedBy: text,
                       of: transcript,
                       previous: previous,
                       over: audioIndex,
                       book: book,
                       hasher: hasher
                   ),
                   !keepUnwrittenText(of: book, at: cacheURL, bytes: existing, keepCopy: keepCopy) {
                    throw TranscriptTextError.textNotKept
                }
                try bytes.write(to: cacheURL, options: .atomic)
                ReadingTextCache.shared.remove(bookID: book.id)
            }
            guard let source = FileFingerprint(of: transcriptURL, hasher: hasher),
                  let cacheStamp = FileStamp(of: cacheURL) else {
                throw TranscriptTextError.notFingerprinted
            }
            let fingerprint = TextCacheFingerprint(
                source: source,
                cache: FileFingerprint(stamp: cacheStamp, digest: hasher.digestOfData(bytes))
            )
            let layer = TranscriptTextBuilder.index(of: text, from: transcript, fingerprint: fingerprint)
            // Told as soon as the file is written, inside the same storage
            // work, so the window in which a check could find the new
            // content.md under the old baseline is as short as it can be.
            sessions?.textRebuilt(book, writing: bytes, fingerprint: fingerprint)
            return (layer, TranscriptText(chapters: text.chapters, index: layer))
        }
    }

    // MARK: - The Audio Transcribed

    /// Whether a book's audio files are the ones its transcript describes.
    enum AudioCheck: Equatable {
        /// They are, with the fingerprints to record now: the recorded ones,
        /// or, for a file rewritten without changing, its new stamp.
        case current([TranscriptAudioFile])
        /// One is not, for the reason given.
        case changed(String)
    }

    /// Whether `book`'s audio files, as `audioIndex` lists them, are the
    /// `files` a transcript describes: the same files, each with the
    /// recorded size, and the recorded date or, when only its date moved,
    /// the recorded digest. A file only in the cloud is taken on trust, as
    /// it cannot be judged without downloading it.
    static func audioCheck(
        of files: [TranscriptAudioFile],
        for book: Book,
        audioIndex: BookContentIndex,
        isDataless: (URL) -> Bool,
        hasher: FingerprintHasher
    ) -> AudioCheck {
        let locations = TranscriptionPlan.audioFileLocations(of: book, index: audioIndex)
        guard Set(locations.map(\.path)) == Set(files.map(\.path)) else {
            return .changed("the book's audio files are not the ones transcribed")
        }
        let urls = Dictionary(locations.map { ($0.path, $0.url) }) { first, _ in first }
        var checked: [TranscriptAudioFile] = []
        for file in files {
            guard let url = urls[file.path] else { return .changed("\(file.path) is not in the book") }
            var current = file
            switch file.fingerprint.comparison(with: FileStamp(of: url), isDataless: isDataless(url)) {
            case .same, .dataless:
                break
            case .resized, .unexamined:
                return .changed("\(file.path) changed since it was transcribed")
            case .redated(let stamp):
                guard (try? hasher.digestOfFile(url)) == file.fingerprint.digest else {
                    return .changed("\(file.path) changed since it was transcribed")
                }
                current.fingerprint = FileFingerprint(stamp: stamp, digest: file.fingerprint.digest)
            }
            checked.append(current)
        }
        return .current(checked)
    }

    /// Throws `TranscriptTextError.textOnlyInCloud` when the content.md at
    /// `url` is only in the cloud (`isDataless`): TextMouth never downloads
    /// a file by reading it, nor replaces one it has not read. One lstat; a
    /// missing file is not in the cloud.
    static func requireTextOnThisMac(at url: URL, isDataless: (URL) -> Bool) throws {
        if isDataless(url) { throw TranscriptTextError.textOnlyInCloud }
    }

    /// Whether the content.md `existing`, about to be replaced by `text`,
    /// holds text that must be kept beside it first (see `writeText`): it is
    /// not what TextMouth last wrote or took (`writtenDigest`), or the
    /// transcript it was written from was edited and it reads differently
    /// from the text written from that transcript. That transcript is
    /// `previous`, or, when nil, `transcript`, whose text is `text` itself.
    /// The caller has found `existing`'s bytes differ from `text`'s.
    private static func unwrittenTextNeedsKeeping(
        _ existing: Data,
        writtenDigest: String?,
        replacedBy text: TranscriptTextBuilder.Text,
        of transcript: Transcript,
        previous: Transcript?,
        over audioIndex: BookContentIndex,
        book: Book,
        hasher: FingerprintHasher
    ) -> Bool {
        if hasher.digestOfData(existing) != writtenDigest { return true }
        // Only a transcript the user edited can have a content.md that
        // TextMouth did not write under the digest it recorded.
        let source = previous ?? transcript
        guard source.editedAt != nil else { return false }
        let expected: TranscriptTextBuilder.Text?
        if let previous {
            expected = TranscriptTextBuilder.text(
                of: TranscriptTextBuilder.chapters(of: previous, over: audioIndex, bookFileName: book.bookFileURL.lastPathComponent),
                bookTitle: book.title,
                bookAuthor: book.author
            )
        } else {
            expected = text
        }
        // The text content.md holds when nothing but TextMouth wrote it; one
        // that cannot be built counts as differing.
        guard let expected else { return true }
        // Parsed as the builder reads its own text back. Bytes that are not
        // UTF-8 are not text TextMouth wrote.
        guard let markdown = try? MarkdownCacheService.cacheText(from: existing, at: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)) else {
            return true
        }
        let chapters = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: book.title, bookAuthor: book.author).chapters
        return readingText(of: chapters) != readingText(of: expected.chapters)
    }

    /// Each of `chapters`' title and text, with every run of white space
    /// taken as one space: what a reader shows, without how content.md
    /// escapes it or breaks its lines and paragraphs.
    private static func readingText(of chapters: [Chapter]) -> [[String]] {
        chapters.map { chapter in
            [chapter.title, chapter.text].map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
    }

    /// Keeps `bytes`, the content.md at `url` of `book`, beside it before
    /// its text is written again: text the user saved that no edit took,
    /// logged once as TEXT_EDIT_KEPT, as Edit Text keeps an edit it could
    /// not take (FR05).
    /// - Returns: Whether `keepCopy` made the copy.
    private static func keepUnwrittenText(
        of book: Book,
        at url: URL,
        bytes: Data,
        keepCopy: (URL, Data?) -> URL?
    ) -> Bool {
        let kept = keepCopy(url, bytes)
        let detail = kept.map { "content.md kept as \($0.lastPathComponent) before its text was written again from transcript.json" }
            ?? "content.md could not be kept before its text was written again from transcript.json"
        logLine("TEXT_EDIT_KEPT", about: book, detail)
        return kept != nil
    }

    // MARK: - Logging

    /// Records that `book`'s transcript no longer describes its audio.
    private static func reportStale(_ book: Book, _ reason: String) {
        logLine(staleTag, about: book, "\(reason); the book shows no transcript text until it is transcribed again")
    }

    /// Records `<tag>: <title>: <detail>` as a storage event. A detail names
    /// files by their places in the book, never quotes the transcript.
    private static func logLine(_ tag: String, about book: Book, _ detail: String) {
        DiagnosticLog.event(.storage, "\(tag): \(book.title): \(detail)")
    }
}

/// Why a book that has a transcript shows none of its text (FR05), for the
/// reasons Search in Book names in place of opening: the load gives the first
/// three (`TranscriptTextLoader.Load.withheld`), and the reader the last when
/// it meets an edit it cannot take. The words are `BookSearchWording`'s.
enum TranscriptTextWithheld: Equatable, Sendable {
    /// transcript.json is only in iCloud, so it was not read.
    case transcriptInCloud
    /// content.md is only in iCloud, so it was not read or written.
    case textInCloud
    /// The book's audio is no longer the audio transcribed, so the
    /// transcript no longer fits it.
    case audioChanged
    /// content.md holds an edit TextMouth cannot take, so the book keeps no
    /// text shown until the user settles it in their editor: why it cannot
    /// be taken, and the copy of it kept beside content.md, if any.
    case editHeld(BookTextEditRefusal, keptCopy: URL?)
}

/// Why a transcript's text could not be written.
enum TranscriptTextError: LocalizedError {
    /// The text written did not read back as one chapter for each of the
    /// book's chapters.
    case chaptersNotReadBack
    /// transcript.json or content.md could not be fingerprinted once written.
    case notFingerprinted
    /// content.md is only in iCloud: TextMouth leaves it as it is, rather
    /// than download it by reading it or replace what it has not read.
    case textOnlyInCloud
    /// content.md holds text that must be kept before it is replaced, and
    /// no copy of it could be made: it is left as it is.
    case textNotKept

    /// Whether the text was left exactly as it was (nothing written, and
    /// nothing in the package changed by the attempt).
    var leavesTextAsItIs: Bool {
        self == .textOnlyInCloud || self == .textNotKept
    }

    /// What the debug log says about this error: never a path or any text.
    var logDescription: String {
        switch self {
        case .textOnlyInCloud: return "it is only in iCloud"
        case .textNotKept: return "no copy of the text it holds could be kept"
        case .chaptersNotReadBack, .notFingerprinted: return "the text could not be written"
        }
    }

    var errorDescription: String? {
        switch self {
        case .textOnlyInCloud:
            // The same sentence the Transcribe Audio sheet says before a
            // transcription begins.
            return TranscriptionWording.textInCloud
        case .textNotKept:
            return "The book's text holds changes TextMouth couldn't keep a copy of, so it leaves the text as it is."
        case .chaptersNotReadBack:
            return "The transcript's text did not read back as one chapter for each of the book's chapters."
        case .notFingerprinted:
            return "The transcript's files could not be examined once they were written."
        }
    }
}
