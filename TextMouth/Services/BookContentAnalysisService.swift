import Foundation

/// Loads content and produces the versioned per-package index. Callers invoke
/// this service from import/analysis queues; it performs no main-actor work.
enum BookContentAnalysisService {
    struct Result {
        var content: DocumentContent
        var index: BookContentIndex
        var audioFilePaths: [String]?
        var audioSegments: [AudioSegment]?
        /// Whether `index` is the saved index exactly as saved, so the caller
        /// has nothing new to save. False for a new index, and for a saved
        /// one that now carries new fingerprints of its text cache.
        var usedPersistedIndex: Bool
        var cacheFormatVersion: String?
        /// Whether the reading text came from the book's cached reading text
        /// (`ReadingTextCache`) rather than from parsing content.md.
        var readFromReadingTextCache = false
        /// The book's saved places that the rebuild this load made moved from
        /// the old text to the new one (T06's branch D); nil when the load
        /// rebuilt nothing or nothing needed moving. The caller commits them
        /// with the analysis (`LibraryPersistenceService.saveContentAnalysis`),
        /// which also discards the copy of the old text they were moved from.
        var movedPlaces: MovedPlaces? = nil
    }

    /// Load `book`'s content with its index. The index saved in the book's
    /// package is reused, skipping audio analysis or re-indexing the text
    /// cache, only when it passes validation (and, for text, matches the
    /// cached chapters); one that fails is reported in the debug log and the
    /// book is analyzed afresh, returning `usedPersistedIndex == false` so
    /// the caller's usual save replaces it.
    ///
    /// A text cache is first checked against the fingerprints recorded when
    /// it was written (TODO T07, see `loadExistingCache`): a cache whose
    /// source or content.md has changed since is rebuilt from the source.
    /// `hasher` computes the digests that check needs; tests pass one that
    /// counts them. `isDataless` says whether a file is dataless (FR02):
    /// the maintenance access's check, or `DatalessFiles.isDataless`.
    ///
    /// `readingTexts`, which only the reader passes, keeps the reading text
    /// of the large books opened lately (PERF22, `ReadingTextCache`): an
    /// unchanged book whose reading text it keeps is read from it instead
    /// of parsing content.md, and a large book whose content.md was parsed
    /// is kept in it for the next open. Imports and maintenance passes read
    /// content.md, and keep nothing.
    static func load(
        book: Book,
        regenerateTextCache: Bool = false,
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        readingTexts: ReadingTextCache? = nil
    ) throws -> Result {
        let url = URL(fileURLWithPath: book.filePath)

        if book.format.isAudio {
            // An audio index's file paths are relative to the book's own path.
            if let savedIndex = trustedSavedIndex(for: book, audioBaseURL: url),
               let content = savedIndex.makeAudioDocumentContent(
                   title: book.title,
                   author: book.author
               ) {
                return Result(
                    content: content,
                    index: savedIndex,
                    audioFilePaths: savedIndex.resolvedAudioFilePaths(relativeTo: url),
                    audioSegments: savedIndex.restoredAudioSegments(),
                    usedPersistedIndex: true,
                    cacheFormatVersion: nil
                )
            }
            return try analyzeAudio(book: book, url: url)
        }

        let hadExistingCache = MarkdownCacheService.cacheExists(for: book)
        if regenerateTextCache || !hadExistingCache {
            if let generated = MarkdownCacheService.generateCacheContent(for: book) {
                return regenerated(generated)
            }
            if !hadExistingCache {
                let content = try BookParser.parse(
                    url: url, format: book.format, brailleTable: book.brailleTable,
                    brailleTableVersion: book.brailleTableVersion,
                    brailleFileCode: book.brailleFileCodeForReading(),
                    encodingPolicy: book.recordedTextEncodingRecord().policy
                )
                let index = content.contentIndex.replacingFormat(book.format)
                return Result(
                    content: DocumentContent(
                        title: content.title,
                        author: content.author,
                        chapters: content.chapters,
                        contentIndex: index
                    ),
                    index: index,
                    audioFilePaths: nil,
                    audioSegments: nil,
                    usedPersistedIndex: false,
                    cacheFormatVersion: nil
                )
            }
        }

        // A requested rebuild that failed falls back to the cache as it is,
        // vouching for none of it and checking nothing that would only
        // send it back to the source that just failed.
        return try loadExistingCache(
            of: book,
            cacheIsCurrent: !regenerateTextCache
                && book.cacheFormatVersion == MarkdownCacheService.currentCacheVersion,
            verifying: !regenerateTextCache,
            hasher: hasher,
            isDataless: isDataless,
            readingTexts: readingTexts
        )
    }

    /// The result of a load that has just written `generated`'s cache.
    /// Regeneration already parsed and indexed this exact content, with the
    /// fingerprints of the files it read and wrote; reading content.md
    /// again would double that work for every book. The places the rebuild
    /// moved ride along for the caller to commit.
    private static func regenerated(_ generated: MarkdownCacheService.GeneratedCache) -> Result {
        Result(
            content: generated.content,
            index: generated.content.contentIndex,
            audioFilePaths: nil,
            audioSegments: nil,
            usedPersistedIndex: false,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
            movedPlaces: generated.movedPlaces
        )
    }

    /// Reads `book`'s existing content.md with the index saved beside it.
    ///
    /// - Parameters:
    ///   - cacheIsCurrent: Whether the book records a cache of the current
    ///     format, so its saved index may be used, the result vouches for
    ///     the cache's version, and a cache written before fingerprints may
    ///     be fingerprinted.
    ///   - verifying: Whether to check the fingerprints the package recorded
    ///     when the cache was written. A load that finds the source or
    ///     content.md changed since (`TextCacheFingerprint.verify`, which
    ///     reads a file only when its size is unchanged but its date is
    ///     not) logs `CACHE_STALE: <title>: <reason>` and rebuilds the cache
    ///     from the source. Unchanged files are verified by their sizes and
    ///     dates alone, so an unchanged book is read without hashing. A file
    ///     `isDataless` calls dataless when it is stamped (FR02) is never
    ///     judged by the size and date it reports, and a dataless source is
    ///     never read for its digest (`TextCacheFingerprint.verify`).
    ///   - readingTexts: The reader's cache of reading texts, or nil to
    ///     parse content.md and keep nothing (see `cachedContent`).
    ///
    /// A saved index that fails validation or alignment is reported and
    /// replaced by a fresh index of the text, as before fingerprints. Since
    /// such a failure may be the first sign of an edit that kept content.md's
    /// size and date, content.md's digest is confirmed first, and a cache
    /// that changed is rebuilt instead. An index whose recorded fingerprints
    /// prove it was measured from these very bytes is aligned without
    /// counting words, the one comparison that reads every character.
    ///
    /// A cache written before fingerprints is fingerprinted, once the saved
    /// index has passed every check, on its first such load: the reader's
    /// first open, or the statistics pass in the background. Its result does
    /// not count as the persisted index, so the caller's usual save records
    /// the fingerprints; that load reads both files in full, and every
    /// later one compares stamps. A cache whose source is dataless waits
    /// for a load that finds the source on this Mac: reading it for its
    /// digest would download it.
    ///
    /// When the source cannot be read again, a stale cache is read as it is,
    /// with the fingerprints it was written with, so the next load tries
    /// again instead of trusting it.
    ///
    /// content.md itself is read only when it is needed, for its digest or
    /// to be parsed: a book whose reading text is kept for this very file
    /// opens without reading it at all.
    private static func loadExistingCache(
        of book: Book,
        cacheIsCurrent: Bool,
        verifying: Bool,
        hasher: FingerprintHasher,
        isDataless: (URL) -> Bool,
        readingTexts: ReadingTextCache?
    ) throws -> Result {
        let sourceURL = book.bookFileURL
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let record = book.storedBookInfo()
        let recorded = record?.state.textCacheFingerprint
        // Stamp both files before reading either, so a file that changes
        // while it is read differs from its stamp next time. Whether each is
        // dataless is asked with its stamp, since reading content.md for the
        // reader downloads it. content.md's identity, which a kept reading
        // text must have been read from, is taken with its stamp too.
        let sourceStamp = FileStamp(of: sourceURL)
        let cacheStamp = FileStamp(of: cacheURL)
        let cacheIdentity = readingTexts == nil ? nil : ContentFileIdentity(of: cacheURL)
        let sourceIsDataless = isDataless(sourceURL)
        let cacheIsDataless = isDataless(cacheURL)

        // content.md's bytes, read when first needed, for its digest or to
        // parse it, and at most once.
        var knownBytes: Data?
        func cacheBytes() throws -> Data {
            if let knownBytes { return knownBytes }
            let bytes = try Data(contentsOf: cacheURL)
            knownBytes = bytes
            return bytes
        }

        // content.md's digest, computed only when a check needs it, and at
        // most once.
        var knownCacheDigest: String?
        func cacheDigest() throws -> String {
            if let knownCacheDigest { return knownCacheDigest }
            let digest = hasher.digestOfData(try cacheBytes())
            knownCacheDigest = digest
            return digest
        }

        // The fingerprints the returned index carries: the recorded ones
        // until a check vouches for others.
        var fingerprint = recorded
        // Whether the files were found to hold what `recorded` describes.
        var verified = false
        if verifying, let recorded {
            switch try recorded.verify(
                sourceURL: sourceURL,
                sourceStamp: sourceStamp,
                cacheStamp: cacheStamp,
                cacheDigest: cacheDigest,
                hasher: hasher,
                sourceIsDataless: sourceIsDataless,
                cacheIsDataless: cacheIsDataless
            ) {
            case .current(let current):
                fingerprint = current
                verified = true
            case .stale(let staleness):
                if let rebuilt = rebuildStaleCache(of: book, because: staleness) {
                    return rebuilt
                }
            }
        }

        var saved = cacheIsCurrent ? record?.contentIndex.flatMap { trusted($0, for: book, audioBaseURL: nil) } : nil
        // Whether a saved index that may be used was set aside, by validation
        // here (which reported why) or by alignment below.
        var savedIndexFailed = cacheIsCurrent && record?.contentIndex != nil && saved == nil

        /// The result for `content`, paired with the index chosen by now:
        /// the saved one, or one measured from `content` itself.
        func result(_ content: DocumentContent, readFromReadingTextCache: Bool) -> Result {
            var index = saved ?? content.contentIndex.replacingFormat(book.format)
            index.textCacheFingerprint = fingerprint
            // The saved index counts as used only when the package already
            // records these fingerprints, in its state and in that index;
            // otherwise the caller's save must record them.
            let unchangedRecord = saved != nil && saved?.textCacheFingerprint == fingerprint && recorded == fingerprint
            return Result(
                content: DocumentContent(
                    title: content.title,
                    author: content.author,
                    chapters: content.chapters,
                    contentIndex: index
                ),
                index: index,
                audioFilePaths: nil,
                audioSegments: nil,
                usedPersistedIndex: unchangedRecord,
                cacheFormatVersion: cacheIsCurrent ? MarkdownCacheService.currentCacheVersion : nil,
                readFromReadingTextCache: readFromReadingTextCache
            )
        }

        // What a reading text kept for this content.md must have been read
        // from: given only while the files hold what their record describes,
        // by that record's digest of content.md and by its identity now.
        let readingTextKey: ReadingTextKey? = {
            guard verified, let fingerprint, let cacheIdentity else { return nil }
            return ReadingTextKey(contentDigest: fingerprint.cache.digest, content: cacheIdentity, bookTitle: book.title)
        }()
        // The reading text kept for exactly that, when the book is large
        // enough to be kept and the saved index was measured from the same
        // content.md.
        if let readingTexts, let readingTextKey, readingTexts.keeps(readingTextKey), let index = saved,
           index.textCacheFingerprint?.cache.digest == readingTextKey.contentDigest,
           let content = cachedContent(of: book, in: readingTexts, key: readingTextKey, index: index) {
            return result(content, readFromReadingTextCache: true)
        }

        var content = MarkdownCacheService.parseMultiChapterMarkdown(
            try MarkdownCacheService.cacheText(from: try cacheBytes(), at: cacheURL),
            bookTitle: book.title,
            bookAuthor: book.author,
            contentIndex: saved
        )
        // A sound index may still describe other text than content.md holds.
        // Its offsets would then point into the wrong words, so index the
        // parsed chapters afresh, exactly as a load without a saved index does.
        if let index = saved {
            let measuredFromTheseBytes = verified
                && index.textCacheFingerprint?.cache.digest == recorded?.cache.digest
            if let reason = index.alignmentFailure(with: content.chapters, countingWords: !measuredFromTheseBytes) {
                reportRejectedIndex(of: book, reason: reason)
                saved = nil
                savedIndexFailed = true
                content = DocumentContent(title: content.title, author: content.author, chapters: content.chapters)
            }
        }
        // An index that could not be used may be the first sign of an edit
        // that kept content.md's size and date, so confirm content.md by its
        // digest before indexing it again. One that changed is rebuilt; when
        // that fails, the recorded fingerprints stay, as for any stale cache.
        if savedIndexFailed, verified, let recorded, try cacheDigest() != recorded.cache.digest {
            if let rebuilt = rebuildStaleCache(of: book, because: .cacheChanged) {
                return rebuilt
            }
            // content.md does not hold what its record describes after all.
            verified = false
            fingerprint = recorded
        }

        // A current cache written before fingerprints, which has now passed
        // every check, is fingerprinted for the caller's save to record: its
        // stamps as taken before reading, the bytes just read, and the
        // source read now.
        if verifying, recorded == nil, cacheIsCurrent, let cacheStamp, !sourceIsDataless,
           let source = FileFingerprint(of: sourceURL, hasher: hasher) {
            fingerprint = TextCacheFingerprint(
                source: source,
                cache: FileFingerprint(stamp: cacheStamp, digest: try cacheDigest())
            )
        }

        // A large book parsed from a content.md that holds what its record
        // describes is kept for its next open, which then reads no
        // content.md. It is kept in the background: this open never waits
        // for the write.
        if verified, let readingTexts, let readingTextKey {
            readingTexts.storeInBackground(content.chapters, for: book.id, key: readingTextKey)
        }
        return result(content, readFromReadingTextCache: false)
    }

    /// `book`'s reading text as `readingTexts` keeps it for the content.md
    /// `key` describes, paired with `index`, the saved index measured from
    /// that content.md; nil when none is kept for `key`. A kept reading text
    /// is checked against the index as a parsed one is, apart from counting
    /// words: each chapter's length, and its headings' places, labels, and
    /// levels. One that does not match, or a file that cannot be read, is
    /// reported as `READING_TEXT_CACHE_REJECTED: <title>: <reason>` and
    /// removed, so the caller parses content.md and keeps that instead.
    private static func cachedContent(
        of book: Book,
        in readingTexts: ReadingTextCache,
        key: ReadingTextKey,
        index: BookContentIndex
    ) -> DocumentContent? {
        let chapters: [Chapter]
        switch readingTexts.chapters(for: book.id, key: key) {
        case .found(let found):
            chapters = found
        case .none:
            return nil
        case .damaged(let reason):
            reportRejectedReadingText(of: book, reason: reason)
            return nil
        }
        if let reason = index.alignmentFailure(with: chapters, countingWords: false) {
            reportRejectedReadingText(of: book, reason: reason)
            readingTexts.remove(bookID: book.id)
            return nil
        }
        return DocumentContent(
            title: MarkdownCacheService.documentTitle(of: chapters, bookTitle: book.title),
            author: book.author,
            chapters: chapters,
            contentIndex: index
        )
    }

    /// Reports that `book`'s text cache is stale, `because` its source or
    /// content.md changed, and rebuilds it from the source as a requested
    /// regeneration does. Nil when nothing could be extracted from the
    /// source, so the caller reads the cache as it is.
    private static func rebuildStaleCache(of book: Book, because staleness: TextCacheStaleness) -> Result? {
        reportStaleCache(of: book, staleness)
        return MarkdownCacheService.generateCacheContent(for: book).map(regenerated)
    }

    /// Recover a fully committed cache/index after an interrupted library batch.
    /// Package metadata is written per book, so it can be newer than library.json.
    /// A missing cache, old index, or old extraction version must still rebuild,
    /// as must an index that fails validation (which is also reported), and a
    /// cache whose source or content.md changed since it was written, by the
    /// fingerprints the package recorded (which is reported as
    /// `CACHE_STALE: <title>: <reason>`). A file with a new date but the
    /// recorded size is read for its digest, which decides; one that kept
    /// its digest is current, and the index returned carries its new
    /// stamps. `isDataless`
    /// says whether a file is dataless (FR02): a dataless file is never read
    /// for its digest nor judged by the size and date it reports, and a
    /// check that met one gives no index, as any unreadable file does.
    static func completedTextCacheIndex(
        for book: Book,
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> BookContentIndex? {
        (try? recoveredTextCacheIndex(for: book, hasher: hasher, isDataless: isDataless)) ?? nil
    }

    /// `completedTextCacheIndex(for:hasher:isDataless:)` for a maintenance
    /// pass that reads with dataless files left in the cloud (FR02): a read
    /// refused because it met a dataless file throws that refusal
    /// (`DatalessFiles.isDownloadRefusal`) instead of answering nil, which
    /// would have the cache rebuilt from its source. A file not downloaded
    /// is no reason to rebuild anything; the pass leaves the book as it is.
    static func recoveredTextCacheIndex(
        for book: Book,
        hasher: FingerprintHasher,
        isDataless: (URL) -> Bool
    ) throws -> BookContentIndex? {
        try recoveredTextCache(for: book, hasher: hasher, isDataless: isDataless)?.index
    }

    /// What `recoveredTextCache(for:hasher:isDataless:)` found: the index of
    /// the cache an earlier run committed, and the record it was read from.
    struct RecoveredTextCache {
        /// The index `recoveredTextCacheIndex(for:hasher:isDataless:)` gives.
        let index: BookContentIndex
        /// The book's package record as it was read, so a caller that also
        /// needs it (for the places an earlier run moved) does not read it
        /// a second time.
        let record: BookInfo
    }

    /// `recoveredTextCacheIndex(for:hasher:isDataless:)` with the record the
    /// index was read from. It answers whenever that does, and refuses,
    /// throws, and gives nil in the same cases.
    static func recoveredTextCache(
        for book: Book,
        hasher: FingerprintHasher,
        isDataless: (URL) -> Bool
    ) throws -> RecoveredTextCache? {
        guard !book.format.isAudio, MarkdownCacheService.cacheExists(for: book) else { return nil }
        let info: BookInfo
        do {
            info = try BookInfo.load(from: book.tmbDirectory)
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            return nil
        }
        // A record whose content.md predates its format's page reader is not
        // recovered either while the launch re-read is switched on: the book
        // is read again for its pages (PG09).
        guard info.state.cacheFormatVersion == MarkdownCacheService.currentCacheVersion,
              !PageReaderVersions.isDueForPages(format: book.format, stored: info.state.pageReaderVersion),
              let index = info.contentIndex,
              let trustedIndex = trusted(index, for: book, audioBaseURL: nil) else { return nil }
        guard let recorded = info.state.textCacheFingerprint else { return RecoveredTextCache(index: trustedIndex, record: info) }
        let sourceURL = book.bookFileURL
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let verification: TextCacheVerification
        do {
            verification = try recorded.verify(
                sourceURL: sourceURL,
                sourceStamp: FileStamp(of: sourceURL),
                cacheStamp: FileStamp(of: cacheURL),
                cacheDigest: { try hasher.digestOfFile(cacheURL) },
                hasher: hasher,
                sourceIsDataless: isDataless(sourceURL),
                cacheIsDataless: isDataless(cacheURL)
            )
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            // content.md vanished or could not be read meanwhile: rebuild it.
            return nil
        }
        switch verification {
        case .current(let verified):
            // A file written again with the same bytes keeps its digests
            // with its new stamps, which the row takes, so the launch's
            // check of the file's date has nothing to read next time.
            guard verified != recorded else { return RecoveredTextCache(index: trustedIndex, record: info) }
            var refreshed = trustedIndex
            refreshed.textCacheFingerprint = verified
            return RecoveredTextCache(index: refreshed, record: info)
        case .stale(let staleness):
            reportStaleCache(of: book, staleness)
            return nil
        }
    }

    /// The index saved in `book`'s package, when it passes validation. A
    /// saved index that fails is reported and ignored, so the caller
    /// analyzes the book afresh and its usual save replaces the bad index.
    /// `audioBaseURL` is as for `BookContentIndex.validationFailure`.
    private static func trustedSavedIndex(for book: Book, audioBaseURL: URL?) -> BookContentIndex? {
        guard let saved = book.storedBookInfo()?.contentIndex else { return nil }
        return trusted(saved, for: book, audioBaseURL: audioBaseURL)
    }

    /// `index` when it passes validation for `book`; otherwise nil, after
    /// reporting why it was set aside.
    private static func trusted(_ index: BookContentIndex, for book: Book, audioBaseURL: URL?) -> BookContentIndex? {
        guard let reason = index.validationFailure(for: book.format, audioBaseURL: audioBaseURL) else {
            return index
        }
        reportRejectedIndex(of: book, reason: reason)
        return nil
    }

    /// Record in the console and the debug log that `book`'s saved index was
    /// set aside, and why, as the single line
    /// `CONTENT_INDEX_REJECTED: <title>: <reason>`.
    private static func reportRejectedIndex(of book: Book, reason: String) {
        logLine("CONTENT_INDEX_REJECTED", about: book, reason)
    }

    /// Record in the console and the debug log that the reading text kept
    /// for `book` (`ReadingTextCache`) could not be used, and why, as the
    /// single line `READING_TEXT_CACHE_REJECTED: <title>: <reason>`.
    private static func reportRejectedReadingText(of book: Book, reason: String) {
        logLine("READING_TEXT_CACHE_REJECTED", about: book, reason)
    }

    /// Record in the console and the debug log that `book`'s text cache no
    /// longer describes what it was written from, as the single line
    /// `CACHE_STALE: <title>: source changed` or
    /// `CACHE_STALE: <title>: content.md changed`.
    private static func reportStaleCache(of book: Book, _ staleness: TextCacheStaleness) {
        logLine("CACHE_STALE", about: book, staleness.rawValue)
    }

    /// Record `<tag>: <title>: <detail>` in the console and the debug log, as
    /// an event of the storage category (`DiagnosticLog`). The policy keeps
    /// the entry on one line, a line break in the title or the detail
    /// becoming a space.
    private static func logLine(_ tag: String, about book: Book, _ detail: String) {
        DiagnosticLog.event(.storage, "\(tag): \(book.title): \(detail)")
    }

    /// Analyzes `book`'s audio afresh from its file, or its folder of tracks,
    /// at `url`, ignoring any saved index: what a load does when no saved index
    /// can be trusted, and what saving edited audio does once the book's file
    /// has changed (FR04). Waits for AVFoundation, so call it off the main
    /// thread and outside Swift concurrency.
    ///
    /// A book of one file without chapters of its own takes the chapters of
    /// a podcast episode kept beside its audio, when they fit it (FMT25,
    /// `keptPodcastChapters(of:)`), unless `readingPodcastChapters` is false.
    /// - Parameter readingPodcastChapters: False when the audio is no longer
    ///   the audio the kept chapters were timed to, whatever the file beside
    ///   it still holds: an edit has replaced it, and setting the chapters
    ///   aside (`LibraryViewModel.setAsidePodcastChapters(of:in:)`) may have
    ///   failed.
    static func analyzeAudio(
        book: Book,
        url: URL,
        prober: AudioMediaProber = .avFoundation,
        readingPodcastChapters: Bool = true
    ) throws -> Result {
        var isDirectory: ObjCBool = false
        let parsed: (
            content: DocumentContent,
            filePaths: [String]?,
            segments: [AudioSegment]?
        )

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let directoryResult = try AsyncBridge.waitForResult(reading: url, timeLimit: AsyncBridge.audioAnalysisTimeLimit) {
                try await AudioBookParser.parseDirectory(url: url, prober: prober)
            }
            parsed = (directoryResult.content, directoryResult.filePaths, directoryResult.segments)
        } else {
            let podcastChapters = readingPodcastChapters ? keptPodcastChapters(of: book) : nil
            let file = try AsyncBridge.waitForResult(reading: url, timeLimit: AsyncBridge.audioAnalysisTimeLimit) {
                try await AudioBookParser.parseFile(url: url, prober: prober, fallbackChapters: podcastChapters)
            }
            if podcastChapters != nil {
                reportPodcastChapters(of: book, unusedBy: file.chapterSource)
            }
            parsed = (file.content, nil, nil)
        }

        let index = BookContentIndex.build(
            from: parsed.content,
            format: book.format,
            audioFilePaths: parsed.filePaths,
            audioSegments: parsed.segments,
            audioBaseURL: isDirectory.boolValue ? url : nil
        )
        let indexedContent = DocumentContent(
            title: parsed.content.title,
            author: parsed.content.author,
            chapters: parsed.content.chapters,
            contentIndex: index
        )
        return Result(
            content: indexedContent,
            index: index,
            audioFilePaths: parsed.filePaths,
            audioSegments: parsed.segments,
            usedPersistedIndex: false,
            cacheFormatVersion: nil
        )
    }

    // MARK: - A Podcast's Chapters (FMT25)

    /// The chapters of a podcast episode kept beside `book`'s audio in its
    /// package (`TextMouthPaths.podcastChaptersPath(in:)`), which become its
    /// chapters when its file has none of its own; nil when there are none
    /// to use. Only a book whose package is its own has them: during an
    /// import, the package the import is staging (`Book.tmbDirectory`).
    ///
    /// The file is TextMouth's own, but its chapters came from outside, so
    /// it is read without downloading anything, and only to one byte past
    /// `TimedTextLimits.podcastChaptersBytes`: a larger file is refused
    /// without being read whole. No file is nil, silently. A file only in
    /// the cloud, one that cannot be read, one too large, or one that
    /// `PodcastChapters.read` refuses is nil, with one
    /// `PODCAST_CHAPTERS_UNUSED` line saying why.
    private static func keptPodcastChapters(of book: Book) -> PodcastChapters? {
        guard !book.tmbDirectoryName.isEmpty else { return nil }
        let limit = TimedTextLimits.podcastChaptersBytes
        let bytes: Data
        do {
            bytes = try DatalessFiles.withoutDownloading {
                try leadingBytes(of: TextMouthPaths.podcastChaptersPath(in: book.tmbDirectory), count: limit + 1)
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            reportUnusedPodcastChapters(of: book, "the file is only in the cloud")
            return nil
        } catch where BookCloudStorageService.isMissingItem(error) {
            return nil
        } catch {
            // Named by its domain and code: its own words can name the
            // package's folder by its absolute path.
            let failure = error as NSError
            reportUnusedPodcastChapters(of: book, "the file could not be read: error \(failure.code) in \(failure.domain)")
            return nil
        }
        guard bytes.count <= limit else {
            reportUnusedPodcastChapters(of: book, "the file is larger than the \(limit / 1_048_576) MB TextMouth reads")
            return nil
        }
        do {
            return try PodcastChapters.read(bytes)
        } catch {
            // `PodcastChapters.read` throws only its own errors, each worded
            // for the log without quoting the file.
            let reason = (error as? PodcastChaptersError)?.description ?? "not a chapters file"
            reportUnusedPodcastChapters(of: book, reason)
            return nil
        }
    }

    /// The first `count` bytes of the file at `url`, or all of it when it
    /// is shorter; a file of more than `count` bytes is never read whole.
    /// - Throws: the error opening or reading the file.
    private static func leadingBytes(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    /// Records why the podcast's chapters kept beside `book`'s audio are not
    /// its chapters, when the analysis of its file, whose chapters came from
    /// `source`, left them unused: the file has chapters of its own, which
    /// always win, or none of the podcast's fits the file.
    private static func reportPodcastChapters(of book: Book, unusedBy source: AudioBookParser.ChapterSource) {
        switch source {
        case .podcastChapters:
            return
        case .file:
            reportUnusedPodcastChapters(of: book, "the audio has chapters of its own")
        case .wholeFile:
            reportUnusedPodcastChapters(of: book, "its last chapter begins past the end of the audio")
        }
    }

    /// Record in the console and the debug log that the podcast's chapters
    /// kept beside `book`'s audio are not its chapters, and why, as the
    /// single line `PODCAST_CHAPTERS_UNUSED: <title>: <reason>`. The reason
    /// never quotes the file, whose titles are the episode's text, and
    /// never names a path.
    private static func reportUnusedPodcastChapters(of book: Book, _ reason: String) {
        logLine("PODCAST_CHAPTERS_UNUSED", about: book, reason)
    }
}
