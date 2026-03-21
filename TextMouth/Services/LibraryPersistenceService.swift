import Foundation

/// Handles saving and loading the library index from disk.
/// The library index now lives at ~/.TextMouth/library.json.
enum LibraryPersistenceService {

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
        DispatchQueue.global(qos: .utility).async {
            book.saveBookInfo()
        }
    }

    /// Save all bookInfo.json files (for bulk operations like migration/rebuild).
    static func saveAllBookInfos(_ library: Library) {
        DispatchQueue.global(qos: .utility).async {
            for book in library.books where !book.tmbDirectoryName.isEmpty {
                book.saveBookInfo()
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
