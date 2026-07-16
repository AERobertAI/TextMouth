import Foundation

/// Handles saving and loading the library index from disk.
/// The library index now lives at ~/.TextMouth/library.json.
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
    nonisolated(unsafe) private static var pendingBookInfos: [UUID: (book: Book, contentIndex: BookContentIndex?)] = [:]
    nonisolated(unsafe) private static var bookInfoGenerations: [UUID: UInt] = [:]

    private static var libraryFileURL: URL {
        TextMouthPaths.libraryIndexFile
    }

    /// Legacy library file (for migration)
    private static var legacyLibraryFileURL: URL? {
        TextMouthPaths.oldLibraryFile
    }

    /// Save the library index to disk. Does NOT write individual bookInfo.json files —
    /// use saveBookInfo(for:in:) for that when a specific book changes.
    static func save(_ library: Library) {
        saveQueue.async {
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
    static func flushPendingSave() {
        saveQueue.sync {
            saveGeneration &+= 1
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

    private static func write(_ library: Library) {
        do {
            try TextMouthPaths.ensureDirectoryStructure()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(library)
            try data.write(to: libraryFileURL, options: .atomic)
        } catch {
            print("Failed to save library: \(error)")
        }
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

    static func load() -> Library {
        // Try new location first
        if FileManager.default.fileExists(atPath: libraryFileURL.path) {
            return loadFrom(url: libraryFileURL)
        }

        // Try legacy location and migrate
        if let legacyURL = legacyLibraryFileURL,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            var library = loadFrom(url: legacyURL)
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                try FileImportService.rebuildDirectoryStructure(library: &library)
                save(library)
                saveAllBookInfos(library)
                try? FileManager.default.removeItem(at: legacyURL)
            } catch {
                print("Migration failed: \(error)")
            }
            return library
        }

        return Library()
    }

    private static func loadFrom(url: URL) -> Library {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Library.self, from: data)
        } catch {
            print("Failed to load library from \(url): \(error)")
            return Library()
        }
    }
}
