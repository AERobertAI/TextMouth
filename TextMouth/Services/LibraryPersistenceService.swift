import Foundation

/// Handles saving and loading the library index from disk.
/// The library index now lives at ~/.TextMouth/library.json.
///
/// An index that exists but cannot be read or decoded is never replaced by an
/// empty library. `load()` preserves its bytes (see `LibraryIndexQuarantine`)
/// and suspends every library.json write in the process: debounced saves,
/// flushes, and the legacy migration skip the index, and data-directory
/// migration refuses, until the library model adopts a readable index
/// (`resumeIndexWrites()`) or the user replaces the unreadable one
/// (`replaceUnreadableIndex(with:)`). Package metadata (bookInfo.json)
/// writes continue, so reading positions are still saved.
enum LibraryPersistenceService {

    /// All library-index writes and debounce state live on one queue so an
    /// older snapshot can never finish after a newer one.
    private static let saveQueue = DispatchQueue(
        label: "com.textmouth.libraryPersistence",
        qos: .utility
    )
    /// Serialize package metadata writes as well. This prevents a frequent
    /// position save from overwriting an index produced by background analysis.
    private static let bookInfoSaveQueue = DispatchQueue(
        label: "com.textmouth.bookInfoPersistence",
        qos: .utility
    )
    // Access is confined to saveQueue. `nonisolated(unsafe)` documents that
    // executor contract to Swift's global-state checker.
    nonisolated(unsafe) private static var pendingLibrary: Library?
    nonisolated(unsafe) private static var saveGeneration: UInt = 0
    /// True while an unreadable index must be protected. Confined to saveQueue
    /// with the pending snapshot, so a suspension and a write never interleave.
    nonisolated(unsafe) private static var indexWritesSuspended = false
    /// Whether a skipped write was logged during the current suspension, so
    /// frequent position saves do not flood the debug log.
    nonisolated(unsafe) private static var loggedSkippedIndexWrite = false
    nonisolated(unsafe) private static var pendingBookInfos: [UUID: (book: Book, contentIndex: BookContentIndex?)] = [:]
    nonisolated(unsafe) private static var bookInfoGenerations: [UUID: UInt] = [:]

    private static var libraryFileURL: URL {
        TextMouthPaths.libraryIndexFile
    }

    /// Legacy library file (for migration)
    private static var legacyLibraryFileURL: URL? {
        TextMouthPaths.oldLibraryFile
    }

    /// Whether library.json writes are suspended because the index on disk
    /// could not be read. Safe to call from any thread except saveQueue.
    static var areIndexWritesSuspended: Bool {
        saveQueue.sync { indexWritesSuspended }
    }

    /// Save the library index to disk. Does NOT write individual bookInfo.json files —
    /// use saveBookInfo(for:in:) for that when a specific book changes.
    static func save(_ library: Library) {
        saveQueue.async {
            // A snapshot taken while the index is protected is dropped, not
            // kept for later: it must never be written, even after writes resume.
            guard !indexWritesSuspended else {
                noteSkippedIndexWrite()
                return
            }
            pendingLibrary = library
            saveGeneration &+= 1
            let generation = saveGeneration

            saveQueue.asyncAfter(deadline: .now() + 0.5) {
                guard generation == saveGeneration, let library = pendingLibrary else { return }
                write(library)
                pendingLibrary = nil
            }
        }
    }

    /// Persist the newest pending snapshot before application termination.
    /// The synchronous barrier also waits for any write already in progress.
    /// While index writes are suspended only package metadata is flushed, so
    /// quitting leaves an unreadable index exactly as it was.
    static func flushPendingSave() {
        saveQueue.sync {
            saveGeneration &+= 1
            guard !indexWritesSuspended else {
                pendingLibrary = nil
                return
            }
            guard let library = pendingLibrary else { return }
            write(library)
            pendingLibrary = nil
        }
        bookInfoSaveQueue.sync {
            let pending = pendingBookInfos
            pendingBookInfos.removeAll()
            for (_, update) in pending {
                try? update.book.saveBookInfoThrowing(contentIndex: update.contentIndex)
            }
        }
    }

    /// Write a snapshot to library.json. Must run on saveQueue. Debounced saves
    /// and flushes both end here, so this check also stops a snapshot that was
    /// queued before the index was found unreadable.
    private static func write(_ library: Library) {
        guard !indexWritesSuspended else {
            noteSkippedIndexWrite()
            return
        }
        do {
            try encodeAndWrite(library, to: libraryFileURL)
        } catch {
            print("Failed to save library: \(error)")
        }
    }

    /// Write `library` to library.json immediately, superseding any debounced
    /// snapshot queued before it, and report whether it reached the disk:
    /// false while index writes are suspended.
    private static func writeIndexNow(_ library: Library) throws -> Bool {
        try saveQueue.sync { () throws -> Bool in
            guard !indexWritesSuspended else {
                noteSkippedIndexWrite()
                return false
            }
            pendingLibrary = nil
            saveGeneration &+= 1
            try encodeAndWrite(library, to: libraryFileURL)
            return true
        }
    }

    /// Encode `library` the way every index write does and replace `url`
    /// atomically, so a reader never sees a half-written index.
    private static func encodeAndWrite(_ library: Library, to url: URL) throws {
        try TextMouthPaths.ensureDirectoryStructure()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
    }

    /// Save a single book's bookInfo.json. Call this when a specific book's data changes.
    static func saveBookInfo(for book: Book) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        enqueueBookInfoSave(book: book, contentIndex: nil)
    }

    static func saveBookInfo(for book: Book, contentIndex: BookContentIndex) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        enqueueBookInfoSave(book: book, contentIndex: contentIndex)
    }

    /// Commit a completed parser result immediately while preserving any newer
    /// reading-state snapshot already waiting on the metadata queue. Batch
    /// migrations use this instead of retaining every full index until the end.
    static func saveContentAnalysis(
        for book: Book,
        index: BookContentIndex,
        cacheFormatVersion: String?
    ) throws {
        guard !book.tmbDirectoryName.isEmpty else { return }

        try bookInfoSaveQueue.sync {
            var mergedBook = pendingBookInfos.removeValue(forKey: book.id)?.book ?? book
            bookInfoGenerations[book.id] = (bookInfoGenerations[book.id] ?? 0) &+ 1
            mergedBook.applyContentIndexSummary(index)
            if let cacheFormatVersion {
                mergedBook.cacheFormatVersion = cacheFormatVersion
            }
            try mergedBook.saveBookInfoThrowing(contentIndex: index)
        }
    }

    /// Save all bookInfo.json files (for bulk operations like migration/rebuild).
    static func saveAllBookInfos(_ library: Library) {
        for book in library.books where !book.tmbDirectoryName.isEmpty {
            saveBookInfo(for: book)
        }
    }

    private static func enqueueBookInfoSave(book: Book, contentIndex: BookContentIndex?) {
        bookInfoSaveQueue.async {
            let retainedIndex = contentIndex ?? pendingBookInfos[book.id]?.contentIndex
            pendingBookInfos[book.id] = (book, retainedIndex)
            let generation = (bookInfoGenerations[book.id] ?? 0) &+ 1
            bookInfoGenerations[book.id] = generation

            bookInfoSaveQueue.asyncAfter(deadline: .now() + 0.5) {
                guard bookInfoGenerations[book.id] == generation,
                      let update = pendingBookInfos.removeValue(forKey: book.id) else { return }
                try? update.book.saveBookInfoThrowing(contentIndex: update.contentIndex)
            }
        }
    }

    // MARK: - Loading

    /// Read the library index: the current location first, then the legacy
    /// location, which is migrated when it loads. An index that exists but
    /// cannot be used is reported as unreadable, never as an empty library;
    /// by the time this returns, its bytes are preserved and index writes are
    /// suspended, and the unreadable file itself has not been touched.
    static func load() -> LibraryLoadResult {
        // Try new location first
        if FileManager.default.fileExists(atPath: libraryFileURL.path) {
            return readIndex(at: libraryFileURL)
        }

        // Try legacy location and migrate. An unreadable legacy index gets the
        // same protection and, above all, is not deleted.
        if let legacyURL = legacyLibraryFileURL,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            let result = readIndex(at: legacyURL)
            guard case .loaded(var library) = result else { return result }
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                try FileImportService.rebuildDirectoryStructure(library: &library)
                saveAllBookInfos(library)
                // Retire the legacy file only once the migrated index is on
                // disk. While index writes are suspended, or when the write
                // fails, it stays; the model's next save writes the index.
                if try writeIndexNow(library) {
                    try? FileManager.default.removeItem(at: legacyURL)
                }
            } catch {
                print("Migration failed: \(error)")
            }
            return .loaded(library)
        }

        return .missing
    }

    /// Read and decode one index file. On failure the file is preserved and
    /// index writes are suspended on saveQueue itself, so no queued write can
    /// land between the failed read and the suspension.
    private static func readIndex(at url: URL) -> LibraryLoadResult {
        saveQueue.sync { () -> LibraryLoadResult in
            // Kept outside the `do` so a decoding failure still preserves
            // exactly the bytes that failed to decode.
            var bytes: Data?
            do {
                let data = try Data(contentsOf: url)
                bytes = data
                return .loaded(try decodeLibrary(from: data))
            } catch {
                let failure = LibraryIndexReadFailure(
                    indexURL: url,
                    quarantineURL: LibraryIndexQuarantine.preserve(url, bytes: bytes),
                    error: error,
                    byteCount: bytes?.count
                )
                suspendIndexWrites(after: failure)
                return .unreadable(failure)
            }
        }
    }

    /// Decode an index the way every index read does.
    private static func decodeLibrary(from data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: data)
    }

    // MARK: - Unreadable Index Protection

    /// Stop every library.json write. Must run on saveQueue. A snapshot still
    /// waiting to be written is discarded: writing it would replace the file
    /// that just failed to load.
    private static func suspendIndexWrites(after failure: LibraryIndexReadFailure) {
        indexWritesSuspended = true
        loggedSkippedIndexWrite = false
        pendingLibrary = nil
        saveGeneration &+= 1
        logIndexEvent(
            "could not use \(failure.indexURL.path): \(failure.error); "
                + "preserved copy: \(failure.quarantineURL?.path ?? "none could be made"); "
                + "library index writes suspended"
        )
    }

    /// Re-enable library.json writes once the library model has adopted a
    /// readable index (Try Again). Nothing captured during the suspension is
    /// written; the caller saves its adopted library afresh.
    static func resumeIndexWrites() {
        saveQueue.sync {
            guard indexWritesSuspended else { return }
            endIndexWriteSuspension()
            logIndexEvent("library index writes resumed")
        }
    }

    /// Replace the unreadable index with `library` (Rebuild Library Index) and
    /// resume index writes. Whatever is at the index location is preserved
    /// first, and nothing is replaced when that fails, so a rebuild can never
    /// destroy the only copy of an index. Returns the preserved copy of the
    /// replaced file, or nil when there was no file to replace (the unreadable
    /// index was the legacy one, which stays untouched).
    @discardableResult
    static func replaceUnreadableIndex(with library: Library) throws -> URL? {
        try saveQueue.sync { () throws -> URL? in
            let indexURL = libraryFileURL
            var preservedCopy: URL?
            if FileManager.default.fileExists(atPath: indexURL.path) {
                // Re-read now: the file may have changed since the failed load.
                let currentBytes = try? Data(contentsOf: indexURL)
                preservedCopy = LibraryIndexQuarantine.preserve(indexURL, bytes: currentBytes)
                guard preservedCopy != nil else {
                    throw LibraryIndexRecoveryError.couldNotPreserve(indexURL)
                }
            }
            try encodeAndWrite(library, to: indexURL)
            endIndexWriteSuspension()
            logIndexEvent(
                "rebuilt the library index with \(library.books.count) book(s); "
                    + (preservedCopy.map { "previous index kept at \($0.path)" }
                        ?? "no index file was there to replace")
            )
            return preservedCopy
        }
    }

    /// Must run on saveQueue. Anything captured during the suspension is stale.
    private static func endIndexWriteSuspension() {
        indexWritesSuspended = false
        pendingLibrary = nil
        saveGeneration &+= 1
    }

    /// Must run on saveQueue. Logs only the first skipped write of each
    /// suspension; later ones would repeat it every few seconds of reading.
    private static func noteSkippedIndexWrite() {
        guard !loggedSkippedIndexWrite else { return }
        loggedSkippedIndexWrite = true
        logIndexEvent("skipped writing the library index because it could not be read")
    }

    /// Records a library index recovery event in the console and the debug log.
    private static func logIndexEvent(_ message: String) {
        let line = "LIBRARY_INDEX: \(message)"
        print(line)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
    }
}
