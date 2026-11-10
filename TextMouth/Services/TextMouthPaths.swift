import Foundation

/// Central path manager for the ~/.TextMouth directory structure.
/// The location is configurable — stored in the preferences as the bootstrap
/// source (since we need to know where to look before we can read
/// config.json). The default is .TextMouth in the home directory that
/// `TextMouthRuntime` supplies: the user's real home in the app, and the
/// process's sandbox under hosted tests.
enum TextMouthPaths {

    /// Name of the data directory inside a home directory.
    static let dataDirectoryName = ".TextMouth"

    /// The default data directory inside `home`.
    static func defaultRoot(in home: URL) -> URL {
        #if os(iOS)
        // On iOS, `home` is the app's container, whose top level is not a
        // place to write: Apple documents Documents, Library, and tmp. The
        // library goes in Library/Application Support, backed up and hidden
        // from the Files app, so library.json and the book packages cannot be
        // touched by a stray flick there. The folder keeps its name with the
        // dot: `legacyApplicationSupportDirectory(in:)` names
        // Library/Application Support/TextMouth, without it, and the legacy
        // migration would read a library there as an old one.
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
        #else
        home.appendingPathComponent(dataDirectoryName, isDirectory: true)
        #endif
    }

    /// The default location: .TextMouth in this process's home directory,
    /// which is the user's real home in the app and the sandbox under
    /// hosted tests.
    static var defaultRoot: URL {
        defaultRoot(in: TextMouthRuntime.current.homeDirectory)
    }

    // MARK: - Root

    /// The data directory a process with `runtime` starts with: the custom
    /// location when one is in use (see `customRootPath(for:)`), otherwise
    /// the default location in the runtime's home.
    ///
    /// The storage generation's first root comes from here
    /// (`StorageBoundary.shared`), so this is where a custom location that
    /// moved is found again, before anything reads or writes the data
    /// directory (FR02): when its path is missing but its bookmark leads to
    /// a folder holding this library under another path, as after a rename
    /// or a remount under another name, that folder is the data directory,
    /// and the preferences name it from now on. Whether the library there
    /// can be used is the library model's launch check.
    static func root(for runtime: TextMouthRuntime) -> URL {
        guard let customPath = customRootPath(for: runtime) else {
            return defaultRoot(in: runtime.homeDirectory)
        }
        // Named as a folder, so no lstat(2) decides it: a folder above the library
        // may be dataless, and a stat on the main thread would download it.
        let named = URL(fileURLWithPath: customPath, isDirectory: true)
        let check = DataDirectoryCheck.of(root: named, preferences: runtime.preferences, runtime: runtime)
        guard let relocated = check.relocatedLibrary()?.folder else { return named }
        let line = recordRelocation(from: named, to: relocated, in: runtime.preferences)
        // Logged on a later turn of the main queue: a log line names paths
        // relative to the data directory, and the storage generation that
        // knows the data directory may be resolving its root right now.
        DispatchQueue.main.async {
            DiagnosticLog.event(.storage, line)
        }
        return relocated
    }

    /// Makes `newRoot`, where the bookmark found the data directory last
    /// named `oldRoot`, the data directory the preferences name, with a
    /// fresh bookmark of it (FR02). Returns the debug log line saying so,
    /// for the caller to write when it safely can.
    static func recordRelocation(from oldRoot: URL, to newRoot: URL, in preferences: UserDefaults) -> String {
        DataDirectoryPreferences.customPath.write(newRoot.path, to: preferences)
        DataDirectoryPreferences.bookmark.write(DataDirectoryPreferences.makeBookmark(of: newRoot), to: preferences)
        return "DATA_DIRECTORY_FOUND: \(DataDirectoryPaths.shortName(of: oldRoot)) was missing; its bookmark "
            + "found the library at \(DataDirectoryPaths.shortName(of: newRoot)), which is the data directory now"
    }

    /// The active data directory of this process: the root of the current
    /// storage generation (TODO S04). It starts where `root(for:)` says and
    /// changes only when a data-directory move publishes its copy
    /// (`moveDataDirectory`), never because the preference changed.
    static var root: URL {
        StorageBoundary.shared.current.root
    }

    /// Set a custom data directory path. Pass nil to reset to default.
    ///
    /// Beside the path it records a bookmark of the folder, which finds the
    /// folder again after it is renamed or its drive mounts under another
    /// name, and the identity of the library the folder holds, so a folder
    /// that only has the right name is never taken for this library (FR02).
    /// A custom location always exists before it is set: a move publishes
    /// its copy first, and choosing a library points at an existing one. A
    /// folder holding no identity yet leaves none expected; the library
    /// model records it when the library opens.
    /// - Parameters:
    ///   - url: The new data directory, or nil for the default location.
    ///   - preferences: The store holding the setting: this process's
    ///     preferences unless a test passes its own.
    static func setCustomRoot(_ url: URL?, in preferences: UserDefaults = TextMouthRuntime.current.preferences) {
        DataDirectoryPreferences.customPath.write(url?.path, to: preferences)
        DataDirectoryPreferences.bookmark.write(url.flatMap(DataDirectoryPreferences.makeBookmark), to: preferences)
        let identity = DataDirectoryPreferences.identity(in: url ?? defaultRoot)
        DataDirectoryPreferences.expectedIdentity.write(identity?.id, to: preferences)
    }

    /// The currently configured path as a string (for display)
    static var rootPath: String {
        root.path
    }

    /// Whether this process uses a custom (non-default) data directory.
    static var isCustomPath: Bool {
        customRootPath(for: .current) != nil
    }

    /// The custom data directory a process with `runtime` uses, or nil when
    /// it uses the default location.
    ///
    /// The app uses the location the user chose, when the preferences hold
    /// one; an empty path counts as none, as it always has. A process
    /// hosting tests always starts at the default location in its sandbox
    /// and ignores a custom one, even one a test sets through
    /// `setCustomRoot`, so hosted startup, migrations, cache maintenance,
    /// and the background saves and logs that follow the root never leave
    /// the sandbox. Only a move a test publishes, into a folder of its own,
    /// takes the root elsewhere, until the test puts it back.
    private static func customRootPath(for runtime: TextMouthRuntime) -> String? {
        guard !runtime.isHostedTest,
              let path = DataDirectoryPreferences.customPath.read(from: runtime.preferences),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    // MARK: - Subdirectories

    /// The name of the folder of books inside the data directory.
    static let libraryFolderName = "Library"

    static var libraryDir: URL {
        root.appendingPathComponent(libraryFolderName, isDirectory: true)
    }

    /// The name of the folder of logs inside the data directory.
    static let logsFolderName = "Logs"

    /// The folder the diagnostic logs are written to now (`logDestination`):
    /// the data directory's Logs folder, or this Mac's
    /// ~/Library/Logs/TextMouth.
    static var logsDir: URL {
        logDestination.folder
    }

    static var configFile: URL {
        root.appendingPathComponent("config.json")
    }

    static var libraryIndexFile: URL {
        root.appendingPathComponent("library.json")
    }

    /// The books whose package records hold reading checkpoints newer than
    /// library.json (PERF15): written while library.json waits to take a
    /// checkpoint, removed once it has, and read at launch to take those
    /// positions from the records after a crash.
    static var readingCheckpointsFile: URL {
        root.appendingPathComponent("reading-checkpoints.json")
    }

    static var substitutionsFile: URL {
        root.appendingPathComponent("substitutions.json")
    }

    static var readingStatsFile: URL {
        root.appendingPathComponent("reading_stats.json")
    }

    // MARK: - Where the Logs Go

    /// The main diagnostic log (`DiagnosticLog.File.debug`), which names
    /// every log file, in the folder lines go to now.
    static var debugLogFile: URL {
        DiagnosticLog.File.debug.url
    }

    /// Where the diagnostic logs are written now, and why there: under
    /// Storage settings' choice, in the data directory in use, as the app's
    /// log writer resolves it for every line (`LogWriter.Environment.app`).
    static var logDestination: LogDestination {
        LogWriter.Environment.app.destination
    }

    /// Where the logs would go under `location`, with the data directory in
    /// use and this Mac's Logs folder as they are now: what Storage settings
    /// show for the choice on screen.
    static func logDestination(for location: LogLocation) -> LogDestination {
        LogWriter.Environment.app.destination(for: location)
    }

    /// The folder Storage settings' Show Logs in Finder opens under
    /// `location`: the one lines go to now, this Mac's Logs folder made
    /// first when it is missing, as before the first line written there. A
    /// folder in the data directory is never made: the resolution names the
    /// data directory's Logs folder only while it is there.
    static func preparedLogsFolder(for location: LogLocation) -> URL {
        let destination = logDestination(for: location)
        if destination.reason.isThisMac {
            // A folder that can't be made is reported when Finder can't open it.
            try? LogWriter.makeThisMacsFolder(destination.folder)
        }
        return destination.folder
    }

    /// The one resolution of the logs' folder (the user's decision of
    /// October 3), with everything it depends on given, so tests can give
    /// their own; every log line's folder is resolved here.
    ///
    /// - `machine`: this Mac's Logs folder, `thisMacsFolder`.
    /// - `dataDirectory`: the Logs folder inside `dataDirectory`, while the
    ///   library model has not found the data directory unavailable
    ///   (`isUnavailable`) and that folder is there. Otherwise this Mac's
    ///   Logs folder, with the reason, until the data directory's can take
    ///   lines again. Nothing is made here: the data directory's Logs folder
    ///   is made with its other folders (`ensureDirectoryStructure`), so a
    ///   line never brings back a data directory that is gone (FR02).
    ///
    /// Reads metadata only, never downloading anything, since it runs for
    /// every line and on the main thread for Storage settings.
    static func logDestination(
        for location: LogLocation,
        dataDirectory: URL,
        thisMacsFolder: URL,
        isUnavailable: (URL) -> Bool
    ) -> LogDestination {
        guard location == .dataDirectory else {
            return LogDestination(folder: thisMacsFolder, reason: .thisMac)
        }
        let fallback = { (why: LogFallback) in LogDestination(folder: thisMacsFolder, reason: .fallback(why)) }
        guard !isUnavailable(dataDirectory) else {
            return fallback(.libraryUnavailable)
        }
        let logs = dataDirectory.appendingPathComponent(logsFolderName, isDirectory: true)
        switch DatalessFiles.withoutDownloading({ FolderState(of: logs) }) {
        case .folder:
            return LogDestination(folder: logs, reason: .dataDirectory)
        case .missing:
            // Either the Logs folder or the data directory itself is gone.
            let isDataDirectoryThere = DatalessFiles.withoutDownloading { FolderState(of: dataDirectory).isFolder }
            return fallback(isDataDirectoryThere ? .logsFolderMissing : .dataDirectoryMissing)
        case .notAFolder:
            return fallback(.logsFolderUnusable("it is a file, not a folder"))
        case .unreadable(let reason):
            return fallback(.logsFolderUnusable(reason))
        case .onlyInCloud:
            return fallback(.logsFolderUnusable("it is only in the cloud"))
        }
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

    /// Name of a package's record, which holds its book's metadata, state,
    /// and bookmarks. See `BookInfo`.
    static let bookInfoFileName = "bookInfo.json"

    /// Path to bookInfo.json inside a .tmb package
    static func bookInfoPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(bookInfoFileName)
    }

    /// Name of the file holding a package's content index (PERF15), beside
    /// bookInfo.json, which no longer holds it. See `BookInfo`.
    static let contentIndexFileName = "contentIndex.json"

    /// Path to the content index inside a .tmb package
    static func contentIndexPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(contentIndexFileName)
    }

    /// Name of the marker recording that a package's book was removed from
    /// the library while the package stayed on disk. See
    /// `RemovedFromLibraryMarker`.
    static let removedFromLibraryMarkerName = "removedFromLibrary.json"

    /// Path to that removal marker inside a .tmb package
    static func removedFromLibraryMarkerPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(removedFromLibraryMarkerName)
    }

    /// Name of a package's text as the reader reads it: a text book's
    /// cached Markdown, or a transcribed audiobook's transcript text.
    static let contentMarkdownFileName = "content.md"

    /// Path to the cached Markdown content file inside a .tmb package
    static func contentMarkdownPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(contentMarkdownFileName)
    }

    /// Name of a transcribed audiobook's transcript inside its package
    /// (FR05). See `Transcript` and `TranscriptStore`.
    static let transcriptFileName = "transcript.json"

    /// The marker between content.md's name and the time in the name of a
    /// copy Edit Text keeps of the user's edited text beside it (FR05), as
    /// in "content.md.edited-20261004T123012Z" (`BookTextEditSessions`).
    /// Such a copy is TextMouth's own file, never part of the book
    /// (`FileImportService.isPackageContentName`).
    static let keptTextCopyMarker = ".edited-"

    /// Whether `name`, an entry at the top of a package, is a copy Edit Text
    /// kept of the user's edited text (`keptTextCopyMarker`).
    static func isKeptTextCopy(_ name: String) -> Bool {
        name.hasPrefix(contentMarkdownFileName + keptTextCopyMarker)
    }

    /// Path to the transcript inside a .tmb package
    static func transcriptPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(transcriptFileName)
    }

    /// Name of the transcript a cleanup replaced, kept beside it so Undo
    /// Cleanup can put it back (FR05, `TranscriptStore.cleanUp`).
    static let transcriptBeforeCleanupFileName = transcriptFileName + ".before-cleanup"

    /// Path to the transcript kept before a cleanup inside a .tmb package
    static func transcriptBeforeCleanupPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(transcriptBeforeCleanupFileName)
    }

    /// Whether `name`, an entry at the top of a package, is the audiobook's
    /// transcript, the transcript kept before its cleanup, or a copy kept
    /// beside it of one that could not be used (`TranscriptStore`, as in
    /// "transcript.json.unreadable-20261004T101500Z"): TextMouth's own
    /// files, never part of the book (`FileImportService.isPackageContentName`).
    static func isTranscriptFile(_ name: String) -> Bool {
        name == transcriptFileName || name == transcriptBeforeCleanupFileName
            || name.hasPrefix(transcriptFileName + LibraryIndexQuarantine.nameMarker)
    }

    /// Name of a podcast episode's chapters, kept beside its audio in its
    /// package by its download (FMT25), in the normalized form
    /// `PodcastChapters.normalizedJSON()` writes, and read when the audio is
    /// analyzed (`BookContentAnalysisService.analyzeAudio`). TextMouth's own
    /// file, never part of the book (`FileImportService.isPackageContentName`).
    static let podcastChaptersFileName = "podcastChapters.json"

    /// Path to a podcast episode's chapters inside a .tmb package
    static func podcastChaptersPath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(podcastChaptersFileName)
    }

    /// Name of the podcast chapters set aside while edits of the episode's
    /// audio are saved in its file, whose times the chapters no longer fit.
    /// Undoing every edit and saving brings the original audio back, and
    /// the chapters come back with it (`LibraryViewModel.restorePodcastChapters`).
    /// Hidden, so it is never taken for the book's own content
    /// (`FileImportService.isPackageContentName`), and removed with the
    /// audio that made it, as the chapters are
    /// (`FeedItemPackage.removeWhatTheFileMade`).
    static let podcastChaptersSetAsideFileName = ".podcastChapters.unedited.json"

    /// Path to the podcast chapters set aside inside a .tmb package
    /// (`podcastChaptersSetAsideFileName`).
    static func podcastChaptersSetAsidePath(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(podcastChaptersSetAsideFileName)
    }

    /// The name of the folder inside a .tmb package holding the speech
    /// prepared for the book (`cachedAudioDir(in:)`). Packages on disk use
    /// it, so it never changes.
    static let cachedAudioFolderName = "cachedAudio"

    /// Path to the per-book cached audio directory inside a .tmb package
    static func cachedAudioDir(in tmbDir: URL) -> URL {
        tmbDir.appendingPathComponent(cachedAudioFolderName, isDirectory: true)
    }

    // MARK: - Directory Setup

    /// Creates the data directory's folders where that is safe; every writer
    /// of the data directory's own files calls it first. Safe to call any
    /// number of times.
    ///
    /// - The default location is created when missing, with its folders, as
    ///   on a first launch, and the library created there is given its
    ///   identity at once (`LibraryIdentity`).
    /// - A custom location is never created, nor any folder above it (FR02).
    ///   It always exists before it is set: a move publishes its folder
    ///   first, and choosing a library points at an existing one. A missing
    ///   one is an unplugged drive, a signed-out cloud service, or a folder
    ///   that was removed, and creating it would make a new, empty library
    ///   in its place. Only folders inside it are created.
    /// - Nothing is created while the library model has found the data
    ///   directory unavailable (`DataDirectoryGate`).
    /// - Throws: `DataDirectoryUnavailableError` when the data directory
    ///   can't be written into now, or the file system's error.
    static func ensureDirectoryStructure() throws {
        let root = self.root
        try ensureDirectoryStructure(at: root, isDefaultLocation: isDefaultLocation(root))
    }

    /// `ensureDirectoryStructure()` for the data directory at `root`, which
    /// is the default location when `isDefaultLocation`: separate so tests
    /// can lay out folders of their own.
    static func ensureDirectoryStructure(at root: URL, isDefaultLocation: Bool) throws {
        let fileManager = FileManager.default
        if isDefaultLocation {
            guard !DataDirectoryGate.isClosed(root) else { throw DataDirectoryUnavailableError(root: root) }
            if !fileManager.fileExists(atPath: root.path) {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                // A new library: it is given its identity as it is created.
                _ = try? LibraryIdentity.adopt(in: root)
            }
        } else {
            try requireExistingDataDirectory(root)
        }
        // The data directory's own folders, each directly inside it: its
        // books, and its logs, which the log writer never makes itself.
        for name in [libraryFolderName, logsFolderName] {
            try createFolders([name], inside: root)
        }
    }

    /// Creates the library subfolder `folderPath`, with any folder above it
    /// inside the data directory, which must exist already (FR02): nothing
    /// is created outside it, and nothing while the library model has found
    /// it unavailable.
    /// - Throws: `DataDirectoryUnavailableError` when the data directory is
    ///   missing or unavailable, or the file system's error.
    static func ensureLibrarySubfolder(_ folderPath: String) throws {
        guard BookFolder.isValidLibraryPath(folderPath) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !folderPath.isEmpty else { return }
        let root = self.root
        try requireExistingDataDirectory(root)
        let components = folderPath.split(separator: "/").map(String.init)
        try createFolders([libraryFolderName] + components, inside: root)
    }

    /// Creates the folders named by `components`, each inside the one
    /// before, inside the existing folder `base`, one level at a time: a
    /// `base` that vanishes meanwhile, as an unplugged drive does, makes
    /// this fail instead of reappearing, with nothing created above it. A
    /// folder already there, or made by another writer first, is kept; a
    /// file with a folder's name fails with the file system's reason.
    private static func createFolders(_ components: [String], inside base: URL) throws {
        var folder = base
        for component in components {
            folder.appendPathComponent(component, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists where isExistingFolder(folder) {
                // Already there.
            }
        }
    }

    /// Whether a folder, or a link to one, is at `url`.
    private static func isExistingFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Whether the data directory at `root` is the default location.
    static func isDefaultLocation(_ root: URL) -> Bool {
        root.standardizedFileURL.path == defaultRoot.standardizedFileURL.path
    }

    /// Whether the data directory in use is one the library model found
    /// unavailable, so nothing may be read from it or written into it (FR02).
    static var isDataDirectoryUnavailable: Bool {
        DataDirectoryGate.isClosed(root)
    }

    /// Throws unless the data directory at `root` is an existing folder whose
    /// gate is open: the condition for creating anything inside it.
    private static func requireExistingDataDirectory(_ root: URL) throws {
        guard !DataDirectoryGate.isClosed(root), isExistingFolder(root) else {
            throw DataDirectoryUnavailableError(root: root)
        }
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
    /// Updates the custom path setting, starts the next storage generation,
    /// and rewrites file paths in the library.
    ///
    /// All three change only once the copy is published. A migration refused
    /// or stopped before then (TODO S10) throws with the data directory in
    /// use, its setting, and `library` as they were. From the publication on,
    /// `root` and every path built from it name the new location (TODO S04).
    /// - Parameter fileManager: The file manager the migration works with;
    ///   tests pass one that changes the new location while it copies.
    static func moveDataDirectory(
        to newRoot: URL,
        library: inout Library,
        fileManager: FileManager = .default
    ) throws {
        let oldRoot = root
        guard oldRoot.path != newRoot.path else { return }
        let migratedLibrary = try DataDirectoryMigrator.prepareMigration(
            from: oldRoot,
            to: newRoot,
            library: library,
            fileManager: fileManager
        )

        // Update the path setting, and use the new location from now on,
        // spelled exactly as `root(for:)` will read it at the next launch.
        let publishedRoot: URL
        if newRoot.path == defaultRoot.path {
            setCustomRoot(nil) // Reset to default
            publishedRoot = defaultRoot
        } else {
            setCustomRoot(newRoot)
            publishedRoot = URL(fileURLWithPath: newRoot.path)
        }
        // Between the persistence queues' writes, so none of them resolves
        // its file under the old root and writes it after this.
        LibraryPersistenceService.betweenWrites {
            StorageBoundary.shared.publish(root: publishedRoot)
        }

        library = migratedLibrary
    }

    // MARK: - Old Path Helpers (for migration)

    /// Where a sandboxed release of TextMouth kept its data directory, in
    /// `home`: the .TextMouth folder in the app's container, which such a
    /// release saw as its home directory.
    static func sandboxContainerRoot(in home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/com.textmouth.TextMouth/Data", isDirectory: true)
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    /// The Application Support folder in `home` where the oldest releases of
    /// TextMouth kept their library index and books.
    static func legacyApplicationSupportDirectory(in home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("TextMouth", isDirectory: true)
    }

    /// The oldest releases' Application Support folder in this process's home.
    ///
    /// It lies outside the data root, so only the runtime's home keeps it
    /// apart from the user's: under hosted tests it is inside the sandbox,
    /// where the test host's startup cannot migrate, quarantine, or delete a
    /// developer's real legacy library, and legacy-location tests can run
    /// safely. Never nil; it stays optional for its callers.
    static var oldAppSupportDir: URL? {
        legacyApplicationSupportDirectory(in: TextMouthRuntime.current.homeDirectory)
    }

    static var oldBooksDir: URL? {
        oldAppSupportDir?.appendingPathComponent("Books", isDirectory: true)
    }

    static var oldLibraryFile: URL? {
        oldAppSupportDir?.appendingPathComponent("library.json")
    }

    // MARK: - Writing Logs

    /// Size at which a log file is rotated. `DiagnosticLog` keeps routine
    /// chatter out unless tracing is on, but events accumulate for as long as
    /// the app is used, and tracing writes many lines a minute, so every log
    /// is capped.
    static let maxLogFileSize: UInt64 = 2 * 1024 * 1024

    /// Path extension of the single retained older generation of a log file,
    /// e.g. `textmouth_debug.log.previous`.
    static let rotatedLogExtension = "previous"

    /// Appends a timestamped line to the log `file`, through the app's log
    /// writer (`LogWriter.shared`), which resolves the log's folder as it
    /// writes the line, on a queue of its own. Safe to call from any thread:
    /// it never waits for the write.
    ///
    /// This is the writer beneath `DiagnosticLog`, which decides what a line
    /// may say and whether it is written at all; log through that, not here.
    static func appendLog(to file: DiagnosticLog.File, message: String) {
        LogWriter.shared.append(message, to: file)
    }

    /// Blocks until every log line queued so far has been written, or
    /// dropped. A data-directory move calls this before it copies anything,
    /// and tests before they read a log.
    static func flushLogs() {
        LogWriter.shared.flush()
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
