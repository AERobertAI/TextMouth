import Foundation

/// Central path manager for the ~/.TextMouth directory structure.
/// The location is configurable — stored in UserDefaults as the bootstrap source
/// (since we need to know where to look before we can read config.json).
/// The default is ~/.TextMouth in the user's real home directory.
enum TextMouthPaths {

    /// UserDefaults key for the custom data directory path
    private static let customPathKey = "textMouthDataDirectory"

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

    /// Generate a .tmb package name: "Title-Author-timestamp.tmb"
    static func tmbName(title: String, author: String, dateAdded: Date) -> String {
        let sanitizedTitle = sanitizeForFilename(title)
        let sanitizedAuthor = sanitizeForFilename(author)
        let timestamp = Int(dateAdded.timeIntervalSince1970)
        return "\(sanitizedTitle)-\(sanitizedAuthor)-\(timestamp).tmb"
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
        guard !folderPath.isEmpty else { return }
        let dir = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Check if the .TextMouth directory exists at the current root
    static var directoryExists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // MARK: - Move Directory

    /// Move the entire data directory from the current location to a new one.
    /// Updates the custom path setting and rewrites file paths in the library.
    static func moveDataDirectory(to newRoot: URL, library: inout Library) throws {
        let fm = FileManager.default
        let oldRoot = root

        guard oldRoot.path != newRoot.path else { return }

        // Create new location
        if !fm.fileExists(atPath: newRoot.path) {
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        }

        // Move contents from old to new
        let contents = try fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil)
        for item in contents {
            let dest = newRoot.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: item, to: dest)
        }

        // Update the path setting
        if newRoot.path == defaultRoot.path {
            setCustomRoot(nil) // Reset to default
        } else {
            setCustomRoot(newRoot)
        }

        // Rewrite file paths in all books
        let oldRootPath = oldRoot.path
        let newRootPath = newRoot.path
        for i in library.books.indices {
            library.books[i].filePath = library.books[i].filePath
                .replacingOccurrences(of: oldRootPath, with: newRootPath)
        }

        // Clean up old directory if empty
        let remaining = (try? fm.contentsOfDirectory(atPath: oldRoot.path)) ?? []
        if remaining.isEmpty {
            try? fm.removeItem(at: oldRoot)
        }
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

    static var oldAppSupportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
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
    /// synchronous FileHandle I/O (seekToEndOfFile, write, closeFile)
    /// which blocks the calling thread. Without this queue, logging
    /// during playback callbacks blocks the main thread and causes
    /// UI freezes — especially when disk I/O is slow (Spotlight
    /// indexing, Time Machine backup, etc.).
    private static let logQueue = DispatchQueue(
        label: "com.textmouth.logging",
        qos: .utility
    )

    /// Append a timestamped line to a log file on a background queue.
    /// Safe to call from any thread including main — the actual I/O
    /// is dispatched to logQueue so it never blocks the caller.
    static func appendLog(to logFile: URL, message: String) {
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = logFile.path
        logQueue.async {
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
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
