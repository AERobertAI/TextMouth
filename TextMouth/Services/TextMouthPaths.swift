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

/// Central path manager for the ~/.TextMouth directory structure.
/// The location is configurable — stored in UserDefaults as the bootstrap source
/// (since we need to know where to look before we can read config.json).
/// The default is ~/.TextMouth in the user's real home directory.
enum TextMouthPaths {

    /// UserDefaults key for the custom data directory path
    private static let customPathKey = "textMouthDataDirectory"

    /// Hosted unit tests launch the application before the test bundle runs.
    /// Give that process an isolated root immediately so application startup,
    /// migrations, and cache maintenance cannot touch the user's real library.
    private static let unitTestRoot: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    /// The default location: ~/.TextMouth
    static var defaultRoot: URL {
        // Use ProcessInfo to get the real home directory, bypassing any sandbox redirection
        let realHome: String
        if let pw = getpwuid(getuid()) {
            realHome = String(cString: pw.pointee.pw_dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return URL(fileURLWithPath: realHome).appendingPathComponent(".TextMouth", isDirectory: true)
    }

    // MARK: - Root

    /// The active data directory. Returns the custom path if set, otherwise the default.
    static var root: URL {
        if let unitTestRoot {
            return unitTestRoot
        }
        if let customPath = UserDefaults.standard.string(forKey: customPathKey),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        return defaultRoot
    }

    /// Set a custom data directory path. Pass nil to reset to default.
    static func setCustomRoot(_ url: URL?) {
        if let url = url {
            UserDefaults.standard.set(url.path, forKey: customPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customPathKey)
        }
    }

    /// The currently configured path as a string (for display)
    static var rootPath: String {
        root.path
    }

    /// Whether a custom (non-default) path is set
    static var isCustomPath: Bool {
        if let customPath = UserDefaults.standard.string(forKey: customPathKey),
           !customPath.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Subdirectories

    static var libraryDir: URL {
        root.appendingPathComponent("Library", isDirectory: true)
    }

    static var logsDir: URL {
        root.appendingPathComponent("Logs", isDirectory: true)
    }

    static var configFile: URL {
        root.appendingPathComponent("config.json")
    }

    static var libraryIndexFile: URL {
        root.appendingPathComponent("library.json")
    }

    static var substitutionsFile: URL {
        root.appendingPathComponent("substitutions.json")
    }

    static var readingStatsFile: URL {
        root.appendingPathComponent("reading_stats.json")
    }

    // MARK: - Debug Log

    static var debugLogFile: URL {
        logsDir.appendingPathComponent("textmouth_debug.log")
    }

    // MARK: - TMB Package Helpers

    /// Generate a collision-resistant .tmb package name.
    /// The UUID prevents same-title imports created within the same second from
    /// sharing a directory and silently pointing at one another's book file.
    static func tmbName(title: String, author: String, dateAdded: Date, bookID: UUID) -> String {
        let sanitizedTitle = sanitizeForFilename(title)
        let sanitizedAuthor = sanitizeForFilename(author)
        let timestamp = Int(dateAdded.timeIntervalSince1970)
        return "\(sanitizedTitle)-\(sanitizedAuthor)-\(timestamp)-\(bookID.uuidString.lowercased()).tmb"
    }

    /// Full path to a .tmb package in a given library folder
    static func tmbPath(folderPath: String, tmbName: String) -> URL {
        if folderPath.isEmpty {
            return libraryDir.appendingPathComponent(tmbName, isDirectory: true)
        }
        return libraryDir.appendingPathComponent(folderPath, isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
    }

    /// Path to the book file inside a .tmb package
    static func bookFilePath(in tmbDir: URL, originalFileName: String) -> URL {
        tmbDir.appendingPathComponent(originalFileName)
    }

    /// Path to bookInfo.json inside a .tmb package
    static func bookInfoPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent("bookInfo.json")
    }

    /// Name of the marker recording that a package's book was removed from
    /// the library while the package stayed on disk. See
    /// `RemovedFromLibraryMarker`.
    static let removedFromLibraryMarkerName = "removedFromLibrary.json"

    /// Path to that removal marker inside a .tmb package
    static func removedFromLibraryMarkerPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(removedFromLibraryMarkerName)
    }

    /// Path to the cached Markdown content file inside a .tmb package
    static func contentMarkdownPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent("content.md")
    }

    /// Path to the per-book cached audio directory inside a .tmb package
    static func cachedAudioDir(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent("cachedAudio", isDirectory: true)
    }

    // MARK: - Directory Setup

    /// Create the full directory structure. Safe to call multiple times.
    static func ensureDirectoryStructure() throws {
        let fm = FileManager.default
        let dirs = [root, libraryDir, logsDir]
        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// Create a library subfolder on disk
    static func ensureLibrarySubfolder(_ folderPath: String) throws {
        guard BookFolder.isValidLibraryPath(folderPath) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !folderPath.isEmpty else { return }
        let dir = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Renames a library folder's directory to another spelling of the same
    /// name: a capitalization change on a case-insensitive volume, or a
    /// Unicode normalization change. Only the last component may differ, so
    /// both paths share a parent. Returns false when the folder has no
    /// directory yet and there is nothing to rename.
    ///
    /// A direct rename works on APFS, but some Foundation versions refuse a
    /// case-only move because the destination "already exists", and some
    /// file systems accept one without changing the stored name. The parent
    /// listing is therefore checked afterwards, and the rename falls back to
    /// two steps through a hidden temporary sibling. Tests pass false for
    /// `tryingDirectRenameFirst` to exercise that fallback on volumes where
    /// the direct rename always works.
    @discardableResult
    static func respellLibrarySubfolder(
        from oldPath: String,
        to newPath: String,
        tryingDirectRenameFirst: Bool = true
    ) throws -> Bool {
        guard !oldPath.isEmpty, !newPath.isEmpty,
              BookFolder.isValidLibraryPath(oldPath),
              BookFolder.isValidLibraryPath(newPath) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fileManager = FileManager.default
        let source = libraryDir.appendingPathComponent(oldPath, isDirectory: true)
        let destination = libraryDir.appendingPathComponent(newPath, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return false }

        let parent = destination.deletingLastPathComponent()
        let newName = destination.lastPathComponent
        // Swift's == is case-sensitive but ignores normalization form, which
        // is exactly the difference a listing may legitimately keep.
        let listingShowsNewName = {
            (try? fileManager.contentsOfDirectory(atPath: parent.path))?.contains(newName) ?? false
        }

        if tryingDirectRenameFirst,
           (try? fileManager.moveItem(at: source, to: destination)) != nil,
           listingShowsNewName() {
            return true
        }

        let temporary = parent.appendingPathComponent(
            ".textmouth-rename-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: source, to: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            // Restore the original name before reporting the failure.
            try? fileManager.moveItem(at: temporary, to: source)
            throw error
        }
        return true
    }

    /// Check if the .TextMouth directory exists at the current root
    static var directoryExists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // MARK: - Move Directory

    /// Move the entire data directory from the current location to a new one.
    /// Updates the custom path setting and rewrites file paths in the library.
    static func moveDataDirectory(to newRoot: URL, library: inout Library) throws {
        let oldRoot = root
        guard oldRoot.path != newRoot.path else { return }
        let migratedLibrary = try DataDirectoryMigrator.prepareMigration(
            from: oldRoot,
            to: newRoot,
            library: library
        )

        // Update the path setting
        if newRoot.path == defaultRoot.path {
            setCustomRoot(nil) // Reset to default
        } else {
            setCustomRoot(newRoot)
        }

        library = migratedLibrary
    }

    // MARK: - Old Path Helpers (for migration)

    /// Old sandbox container path
    static var oldContainerDir: URL? {
        // The sandbox container that macOS creates
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .deletingLastPathComponent() // go up from sandboxed home
        let containerPath = containers
            .appendingPathComponent("Containers/com.textmouth.TextMouth/Data/.TextMouth", isDirectory: true)
        if FileManager.default.fileExists(atPath: containerPath.path) {
            return containerPath
        }
        return nil
    }

    /// The Application Support directory used by the oldest TextMouth
    /// versions, which kept their library index and books there.
    ///
    /// Hosted tests get a location inside their isolated root instead. The
    /// legacy directory lies outside the data root, so without this the test
    /// host's startup could migrate, quarantine, or delete a developer's real
    /// legacy library, and legacy-location tests could not run safely.
    static var oldAppSupportDir: URL? {
        if let unitTestRoot {
            return unitTestRoot
                .appendingPathComponent("LegacyApplicationSupport", isDirectory: true)
                .appendingPathComponent("TextMouth", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TextMouth", isDirectory: true)
    }

    static var oldBooksDir: URL? {
        oldAppSupportDir?.appendingPathComponent("Books", isDirectory: true)
    }

    static var oldLibraryFile: URL? {
        oldAppSupportDir?.appendingPathComponent("library.json")
    }

    // MARK: - Async Logging

    /// Serial background queue for all log file writes. Logging uses
    /// synchronous FileHandle I/O (seekToEnd, write(contentsOf:), close)
    /// which blocks the calling thread. Without this queue, logging
    /// during playback callbacks blocks the main thread and causes
    /// UI freezes — especially when disk I/O is slow (Spotlight
    /// indexing, Time Machine backup, etc.). One queue for every log
    /// file also keeps lines from different writers from interleaving.
    private static let logQueue = DispatchQueue(
        label: "com.textmouth.logging",
        qos: .utility
    )

    /// Size at which a log file is rotated. Playback and VoiceOver focus
    /// diagnostics are written many times per minute, so without a cap a log
    /// grows for as long as the app is used.
    static let maxLogFileSize: UInt64 = 2 * 1024 * 1024

    /// Path extension of the single retained older generation of a log file,
    /// e.g. `textmouth_debug.log.previous`.
    static let rotatedLogExtension = "previous"

    /// Append a timestamped line to a log file on a background queue.
    /// Safe to call from any thread including main — the actual I/O
    /// is dispatched to logQueue so it never blocks the caller.
    static func appendLog(to logFile: URL, message: String) {
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logQueue.async {
            appendNow(data, to: logFile)
        }
    }

    /// Block until every log line queued so far has been written (or
    /// dropped). Tests use this to observe log files deterministically.
    static func flushLogs() {
        logQueue.sync {}
    }

    /// Perform one append on the log queue.
    ///
    /// Logging is diagnostic only, so every failure is swallowed: a full disk,
    /// an unwritable file, or a missing directory must never crash or stall
    /// reading. The legacy `seekToEndOfFile`/`write(_:)` calls raised
    /// Objective-C exceptions on such failures and took the whole app down
    /// (observed with ENOSPC); the throwing FileHandle APIs report them as
    /// errors instead. The end offset returned by `seekToEnd()` doubles as the
    /// size check that decides whether to rotate before writing.
    private static func appendNow(_ data: Data, to logFile: URL) {
        do {
            guard FileManager.default.fileExists(atPath: logFile.path) else {
                try data.write(to: logFile)
                return
            }
            let handle = try FileHandle(forWritingTo: logFile)
            let currentSize = try handle.seekToEnd()
            if currentSize >= maxLogFileSize {
                try handle.close()
                rotate(logFile)
                try data.write(to: logFile)
            } else {
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
            }
        } catch {
            // Intentionally dropped: see above.
        }
    }

    /// Keep the full log as its one `.previous` generation and let the caller
    /// start a fresh file, so a log never occupies more than two generations.
    /// Failures leave the current file in place; the next append retries.
    private static func rotate(_ logFile: URL) {
        let rotated = logFile.appendingPathExtension(rotatedLogExtension)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logFile, to: rotated)
    }

    // MARK: - Private

    private static func sanitizeForFilename(_ str: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        let result = str.unicodeScalars.filter { allowed.contains($0) }.map { Character($0) }
        var s = String(result)
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "Unknown" }
        s = s.replacingOccurrences(of: " ", with: "_")
        if s.count > 60 { s = String(s.prefix(60)) }
        return s
    }
}
