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
/// a hand edit of content.md is undone this way. A file only in the cloud is
/// never read: the text waits until it is on this Mac.
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
    /// only when the text must be written again, as storage work.
    static func load(
        for book: Book,
        audioIndex: BookContentIndex,
        readingTexts: ReadingTextCache? = nil,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        hasher: FingerprintHasher = .md5
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
        // Reading either file only in the cloud would download it.
        guard !isDataless(transcriptURL), !isDataless(cacheURL) else { return unchanged }

        var rebuildReason = "the book's index holds no transcript text"
        if let layer = audioIndex.transcript {
            if let failure = layer.validationFailure(against: audioIndex) {
                rebuildReason = "its index was set aside: \(failure)"
            } else {
                switch audioCheck(of: layer.audioFiles, for: book, audioIndex: audioIndex, isDataless: isDataless, hasher: hasher) {
                case .changed(let reason):
                    reportStale(book, reason)
                    return unchanged
                case .current(let audioFiles):
                    if let load = readSavedText(
                        of: book,
                        layer: layer,
                        audioFiles: audioFiles,
                        audioIndex: audioIndex,
                        readingTexts: readingTexts,
                        isDataless: isDataless,
                        hasher: hasher,
                        rebuildReason: &rebuildReason
                    ) {
                        return load
                    }
                }
            }
        }
        return rebuild(for: book, audioIndex: audioIndex, because: rebuildReason, isDataless: isDataless, hasher: hasher)
    }

    // MARK: - The Saved Text

    /// The saved text of `book`, whose sound transcript layer is `layer` and
    /// whose audio files, as checked now, are `audioFiles`; nil, with
    /// `rebuildReason` saying why, when transcript.json or content.md is not
    /// what the layer was made from, or content.md does not line up with it.
    private static func readSavedText(
        of book: Book,
        layer: BookContentTranscriptIndex,
        audioFiles: [TranscriptAudioFile],
        audioIndex: BookContentIndex,
        readingTexts: ReadingTextCache?,
        isDataless: (URL) -> Bool,
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
    /// in the cloud, of a later layout, or stale.
    private static func rebuild(
        for book: Book,
        audioIndex: BookContentIndex,
        because reason: String,
        isDataless: (URL) -> Bool,
        hasher: FingerprintHasher
    ) -> Load {
        let unchanged = Load(text: nil, index: audioIndex, indexChanged: false)
        var withoutText = audioIndex
        withoutText.transcript = nil
        let dropped = Load(text: nil, index: withoutText, indexChanged: audioIndex.transcript != nil)

        switch TranscriptStore.read(from: book.tmbDirectory) {
        case .missing, .unusable:
            return dropped
        case .inCloud, .unsupportedVersion:
            return unchanged
        case .found(let transcript):
            switch audioCheck(of: transcript.audioFiles, for: book, audioIndex: audioIndex, isDataless: isDataless, hasher: hasher) {
            case .changed(let staleness):
                reportStale(book, staleness)
                return unchanged
            case .current:
                break
            }
            do {
                let written = try writeText(of: transcript, for: book, over: withoutText, hasher: hasher)
                logLine(rebuiltTag, about: book, "content.md and its index were written again from transcript.json: \(reason)")
                var index = withoutText
                index.transcript = written.layer
                return Load(text: written.text, index: index, indexChanged: index != audioIndex)
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
    /// - Throws: why content.md or the fingerprints could not be written.
    static func writeText(
        of transcript: Transcript,
        for book: Book,
        over audioIndex: BookContentIndex,
        hasher: FingerprintHasher
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
            if (try? Data(contentsOf: cacheURL)) != bytes {
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

/// Why a transcript's text could not be written.
enum TranscriptTextError: LocalizedError {
    /// The text written did not read back as one chapter for each of the
    /// book's chapters.
    case chaptersNotReadBack
    /// transcript.json or content.md could not be fingerprinted once written.
    case notFingerprinted

    var errorDescription: String? {
        switch self {
        case .chaptersNotReadBack:
            return "The transcript's text did not read back as one chapter for each of the book's chapters."
        case .notFingerprinted:
            return "The transcript's files could not be examined once they were written."
        }
    }
}
