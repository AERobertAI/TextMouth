import Foundation

private final class ContentAnalysisResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Loads content and produces the versioned per-package index. Callers invoke
/// this service from import/analysis queues; it performs no main-actor work.
enum BookContentAnalysisService {
    struct Result {
        var content: DocumentContent
        var index: BookContentIndex
        var audioFilePaths: [String]?
        var audioSegments: [AudioSegment]?
        var usedPersistedIndex: Bool
        var cacheFormatVersion: String?
    }

    static func load(
        book: Book,
        regenerateTextCache: Bool = false
    ) throws -> Result {
        let url = URL(fileURLWithPath: book.filePath)
        let savedIndex = (try? BookInfo.load(from: book.tmbDirectory).contentIndex)
            .flatMap { $0?.isValid(for: book.format) == true ? $0 : nil }

        if book.format.isAudio {
            if let savedIndex,
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
        var cacheIsCurrent = hadExistingCache
            && book.cacheFormatVersion == MarkdownCacheService.currentCacheVersion
        if regenerateTextCache || !hadExistingCache {
            if let content = MarkdownCacheService.generateCacheContent(for: book) {
                // Regeneration already parsed and indexed this exact content.
                // Reading content.md again doubles that work for every book.
                return Result(
                    content: content,
                    index: content.contentIndex,
                    audioFilePaths: nil,
                    audioSegments: nil,
                    usedPersistedIndex: false,
                    cacheFormatVersion: MarkdownCacheService.currentCacheVersion
                )
            }
            cacheIsCurrent = false
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

        let mayUseSavedIndex = !regenerateTextCache
            && book.cacheFormatVersion == MarkdownCacheService.currentCacheVersion
        let precomputed = mayUseSavedIndex ? savedIndex : nil
        let content = try MarkdownCacheService.loadFromCache(
            for: book,
            contentIndex: precomputed
        )
        let index = precomputed ?? content.contentIndex.replacingFormat(book.format)
        let indexedContent: DocumentContent
        if content.contentIndex.format == index.format {
            indexedContent = content
        } else {
            indexedContent = DocumentContent(
                title: content.title,
                author: content.author,
                chapters: content.chapters,
                contentIndex: index
            )
        }
        return Result(
            content: indexedContent,
            index: index,
            audioFilePaths: nil,
            audioSegments: nil,
            usedPersistedIndex: precomputed != nil,
            cacheFormatVersion: cacheIsCurrent ? MarkdownCacheService.currentCacheVersion : nil
        )
    }

    /// Recover a fully committed cache/index after an interrupted library batch.
    /// Package metadata is written per book, so it can be newer than library.json.
    /// A missing cache, old index, or old extraction version must still rebuild.
    static func completedTextCacheIndex(for book: Book) -> BookContentIndex? {
        guard !book.format.isAudio,
              MarkdownCacheService.cacheExists(for: book),
              let info = try? BookInfo.load(from: book.tmbDirectory),
              info.state.cacheFormatVersion == MarkdownCacheService.currentCacheVersion,
              let index = info.contentIndex, index.isValid(for: book.format) else { return nil }
        return index
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
            let directoryResult = try waitForAsync {
                try await AudioBookParser.parseDirectory(url: url)
            }
            parsed = (directoryResult.content, directoryResult.filePaths, directoryResult.segments)
        } else {
            let content = try waitForAsync {
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

    private static func waitForAsync<Value>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = ContentAnalysisResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.load() else { throw AudioParseError.invalidDuration }
        return try result.get()
    }
}
