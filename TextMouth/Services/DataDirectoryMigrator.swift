import Foundation

enum DataDirectoryMigrationError: LocalizedError {
    case invalidRelationship
    case destinationNotEmpty
    case missingSource
    case missingBook(String)
    case invalidLibrary

    var errorDescription: String? {
        switch self {
        case .invalidRelationship: return "The new data directory cannot contain, or be contained by, the current directory."
        case .destinationNotEmpty: return "The selected data directory is not empty. Choose an empty location."
        case .missingSource: return "The current data directory does not exist."
        case .missingBook(let title): return "The migrated copy is missing the content for \(title)."
        case .invalidLibrary: return "The migrated library index could not be validated."
        }
    }
}

/// Copy-and-validate migration primitive. It does not mutate global path state,
/// which makes failure behavior deterministic and independently testable.
enum DataDirectoryMigrator {
    static func prepareMigration(
        from oldRoot: URL,
        to newRoot: URL,
        library: Library,
        fileManager: FileManager = .default
    ) throws -> Library {
        // The copy's library.json is written from `library`. While the index
        // cannot be read, that library is only the provisional one rebuilt
        // from disk, and publishing it would bypass the index write
        // suspension, so migration waits until the index is recovered.
        guard !LibraryPersistenceService.areIndexWritesSuspended else {
            throw LibraryIndexRecoveryError.indexUnreadable
        }
        let source = oldRoot.standardizedFileURL
        let destination = newRoot.standardizedFileURL
        let sourcePath = source.path
        let destinationPath = destination.path
        // Compare physical locations before copying: a selected symlink can
        // otherwise disguise a child directory and stage a copy inside itself.
        let physicalSource = physicalLocation(of: source, fileManager: fileManager).path
        let physicalDestination = physicalLocation(of: destination, fileManager: fileManager).path
        guard physicalSource != physicalDestination,
              !physicalDestination.hasPrefix(physicalSource + "/"),
              !physicalSource.hasPrefix(physicalDestination + "/") else {
            throw DataDirectoryMigrationError.invalidRelationship
        }
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw DataDirectoryMigrationError.missingSource
        }
        if fileManager.fileExists(atPath: destinationPath) {
            let contents = try fileManager.contentsOfDirectory(atPath: destinationPath)
            guard contents.isEmpty else { throw DataDirectoryMigrationError.destinationNotEmpty }
        }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".TextMouth-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)

        var migratedLibrary = library
        for index in migratedLibrary.books.indices {
            let oldPath = migratedLibrary.books[index].filePath
            if oldPath == sourcePath || oldPath.hasPrefix(sourcePath + "/") {
                migratedLibrary.books[index].filePath = destinationPath + String(oldPath.dropFirst(sourcePath.count))
            }

            let stagedBookPath = staging.path + String(
                migratedLibrary.books[index].filePath.dropFirst(destinationPath.count)
            )
            guard fileManager.fileExists(atPath: stagedBookPath) else {
                throw DataDirectoryMigrationError.missingBook(migratedLibrary.books[index].title)
            }

            if !migratedLibrary.books[index].tmbDirectoryName.isEmpty {
                let stagedPackage = staging
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent(migratedLibrary.books[index].folderPath, isDirectory: true)
                    .appendingPathComponent(migratedLibrary.books[index].tmbDirectoryName, isDirectory: true)
                var info = migratedLibrary.books[index].makeBookInfo()
                info.contentIndex = (try? BookInfo.load(from: stagedPackage))?.contentIndex
                try info.save(to: stagedPackage)
            }
        }

        let libraryURL = staging.appendingPathComponent("library.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(migratedLibrary).write(to: libraryURL, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let validated = try? decoder.decode(Library.self, from: Data(contentsOf: libraryURL)),
              validated.books.count == migratedLibrary.books.count else {
            throw DataDirectoryMigrationError.invalidLibrary
        }

        if fileManager.fileExists(atPath: destinationPath) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        return migratedLibrary
    }

    /// Foundation does not reliably resolve a symlink ancestor when the final
    /// destination does not exist yet. Resolve its closest existing ancestor,
    /// then reattach the missing path components before checking containment.
    private static func physicalLocation(of url: URL, fileManager: FileManager) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}
