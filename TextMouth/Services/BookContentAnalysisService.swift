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
    static func load(
        book: Book,
        regenerateTextCache: Bool = false,
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
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
            if let content = MarkdownCacheService.generateCacheContent(for: book) {
                return regenerated(content)
            }
            if !hadExistingCache {
                let content = try BookParser.parse(url: url, format: book.format)
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
            isDataless: isDataless
        )
    }

    /// The result of a load that has just written `content`'s cache.
    /// Regeneration already parsed and indexed this exact content, with the
    /// fingerprints of the files it read and wrote; reading content.md
    /// again would double that work for every book.
    private static func regenerated(_ content: DocumentContent) -> Result {
        Result(
            content: content,
            index: content.contentIndex,
            audioFilePaths: nil,
            audioSegments: nil,
            usedPersistedIndex: false,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
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
    private static func loadExistingCache(
        of book: Book,
        cacheIsCurrent: Bool,
        verifying: Bool,
        hasher: FingerprintHasher,
        isDataless: (URL) -> Bool
    ) throws -> Result {
        let sourceURL = book.bookFileURL
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let record = book.storedBookInfo()
        let recorded = record?.state.textCacheFingerprint
        // Stamp both files before reading either, so a file that changes
        // while it is read differs from its stamp next time. Whether each is
        // dataless is asked with its stamp, since reading content.md for the
        // reader downloads it.
        let sourceStamp = FileStamp(of: sourceURL)
        let cacheStamp = FileStamp(of: cacheURL)
        let sourceIsDataless = isDataless(sourceURL)
        let cacheIsDataless = isDataless(cacheURL)
        let bytes = try Data(contentsOf: cacheURL)

        // content.md's digest, computed only when a check needs it, and at
        // most once.
        var knownCacheDigest: String?
        func cacheDigest() -> String {
            if let knownCacheDigest { return knownCacheDigest }
            let digest = hasher.digestOfData(bytes)
            knownCacheDigest = digest
            return digest
        }

        // The fingerprints the returned index carries: the recorded ones
        // until a check vouches for others.
        var fingerprint = recorded
        // Whether the files were found to hold what `recorded` describes.
        var verified = false
        if verifying, let recorded {
            switch recorded.verify(
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
        var content = MarkdownCacheService.parseMultiChapterMarkdown(
            try MarkdownCacheService.cacheText(from: bytes, at: cacheURL),
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
        if savedIndexFailed, verified, let recorded, cacheDigest() != recorded.cache.digest {
            if let rebuilt = rebuildStaleCache(of: book, because: .cacheChanged) {
                return rebuilt
            }
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
                cache: FileFingerprint(stamp: cacheStamp, digest: cacheDigest())
            )
        }

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
            cacheFormatVersion: cacheIsCurrent ? MarkdownCacheService.currentCacheVersion : nil
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
    /// recorded size is read for its digest, which decides. `isDataless`
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
        guard !book.format.isAudio, MarkdownCacheService.cacheExists(for: book) else { return nil }
        let info: BookInfo
        do {
            info = try BookInfo.load(from: book.tmbDirectory)
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            return nil
        }
        guard info.state.cacheFormatVersion == MarkdownCacheService.currentCacheVersion,
              let index = info.contentIndex,
              let trustedIndex = trusted(index, for: book, audioBaseURL: nil) else { return nil }
        guard let recorded = info.state.textCacheFingerprint else { return trustedIndex }
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
        case .current:
            return trustedIndex
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

    private static func analyzeAudio(book: Book, url: URL) throws -> Result {
        var isDirectory: ObjCBool = false
        let parsed: (
            content: DocumentContent,
            filePaths: [String]?,
            segments: [AudioSegment]?
        )

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let directoryResult = try AsyncBridge.waitForResult {
                try await AudioBookParser.parseDirectory(url: url)
            }
            parsed = (directoryResult.content, directoryResult.filePaths, directoryResult.segments)
        } else {
            let content = try AsyncBridge.waitForResult {
                try await AudioBookParser.parse(url: url)
            }
            parsed = (content, nil, nil)
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
}
