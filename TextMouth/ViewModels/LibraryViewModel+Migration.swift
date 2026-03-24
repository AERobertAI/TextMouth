import SwiftUI

/// Extension for data migration, directory management, content cache extraction,
/// statistics calculation, and periodic refresh timing.
extension LibraryViewModel {

    /// Migrate any books still using old storage paths to .tmb packages,
    /// and fix any stale file paths pointing to old locations.
    func migrateOldBooksIfNeeded() {
        var needsSave = false

        // Fix stale file paths — if the file doesn't exist at the stored path,
        // search for the .tmb in the expected folder, then fall back to the root
        // Library directory (fixes a bug where folder moves updated the path
        // without physically moving the .tmb directory).
        for i in library.books.indices {
            let book = library.books[i]
            if !book.tmbDirectoryName.isEmpty &&
               !FileManager.default.fileExists(atPath: book.filePath) {
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent

                // First try the expected folder location
                let tmbDir = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
                let correctPath = tmbDir.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: correctPath) {
                    library.books[i].filePath = correctPath
                    needsSave = true
                    continue
                }

                // Fall back: check root Library directory (the .tmb may never
                // have been physically moved when the book was assigned to a folder)
                let rootTmbDir = TextMouthPaths.tmbPath(folderPath: "", tmbName: book.tmbDirectoryName)
                let rootPath = rootTmbDir.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: rootPath) {
                    // Move the .tmb to the correct folder location
                    do {
                        if !book.folderPath.isEmpty {
                            try? TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
                        }
                        try FileManager.default.moveItem(at: rootTmbDir, to: tmbDir)
                        library.books[i].filePath = correctPath
                    } catch {
                        // Move failed — just update the path to where the file actually is
                        library.books[i].filePath = rootPath
                    }
                    needsSave = true
                }
            }
        }

        // Migrate books with no .tmb package
        for i in library.books.indices {
            if library.books[i].tmbDirectoryName.isEmpty {
                if let migrated = try? FileImportService.migrateBookToTMB(library.books[i]) {
                    library.books[i] = migrated
                    needsSave = true
                }
            }
        }

        // Move .tmb packages that are at the root but should be in a subfolder.
        // This fixes books whose folder was assigned in the UI without physically
        // moving the directory (a bug fixed in d6c6b2c but existing books need repair).
        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library)
        if relocated > 0 { needsSave = true }

        // Adopt any .tmb packages on disk that aren't tracked in library.json.
        // This recovers books left behind by interrupted imports or crashes.
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library)
        if adopted > 0 { needsSave = true }

        if needsSave {
            save()
        }
    }

    /// Migrate data from the old sandbox container to the real ~/.TextMouth
    /// and clean up old container directories.
    func migrateFromSandboxContainer() {
        let fm = FileManager.default
        let realDefault = TextMouthPaths.defaultRoot

        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = NSHomeDirectory()
        }

        let containerBase = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/com.textmouth.TextMouth/Data", isDirectory: true)
        let containerTextMouth = containerBase.appendingPathComponent(".TextMouth", isDirectory: true)

        // Migrate .TextMouth dir from container if it exists and real one doesn't
        if fm.fileExists(atPath: containerTextMouth.path) && !fm.fileExists(atPath: realDefault.path) {
            do {
                try fm.createDirectory(at: realDefault, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: containerTextMouth, includingPropertiesForKeys: nil)
                for item in contents {
                    let dest = realDefault.appendingPathComponent(item.lastPathComponent)
                    try fm.moveItem(at: item, to: dest)
                }

                // Rewrite ALL container paths in library.json to real paths
                let libraryFile = realDefault.appendingPathComponent("library.json")
                if fm.fileExists(atPath: libraryFile.path) {
                    if var json = try? String(contentsOf: libraryFile, encoding: .utf8) {
                        // Replace the container data base path with real home
                        json = json.replacingOccurrences(
                            of: containerBase.path,
                            with: home
                        )
                        try? json.data(using: .utf8)?.write(to: libraryFile, options: .atomic)
                    }
                }

                try? fm.removeItem(at: containerTextMouth)
                print("Migrated .TextMouth from sandbox container to \(realDefault.path)")
            } catch {
                print("Failed to migrate from sandbox container: \(error)")
            }
        }

        // Clean up old container directories (Books dir, logs, etc.)
        let oldContainerAppSupport = containerBase
            .appendingPathComponent("Library/Application Support/TextMouth", isDirectory: true)
        if fm.fileExists(atPath: oldContainerAppSupport.path) {
            try? fm.removeItem(at: oldContainerAppSupport)
            print("Cleaned up old container app support dir")
        }

        // Clean up stale log files in container root
        for file in ["textmouth_debug.log", "textmouth_transition.log"] {
            let path = containerBase.appendingPathComponent(file)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
    }

    /// Parse any books that don't have word/char counts yet so the library
    /// can show time estimates without requiring each book to be opened first.
    func calculateMissingBookStats() {
        let booksNeedingStats = library.books.filter { book in
            if book.format.isAudio {
                return book.audioDuration == nil
            }
            return book.totalWordCount == nil || book.totalCharacterCount == nil
        }
        guard !booksNeedingStats.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for book in booksNeedingStats {
                guard let self = self else { return }
                let url = URL(fileURLWithPath: book.filePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                do {
                    // Use cached Markdown content when available (much faster)
                    let parsed: DocumentContent
                    if !book.format.isAudio && MarkdownCacheService.cacheExists(for: book) {
                        parsed = try MarkdownCacheService.loadFromCache(for: book)
                    } else {
                        parsed = try BookParser.parse(url: url, format: book.format)
                    }
                    let wordCount = parsed.totalWordCount
                    let charCount = parsed.totalCharacterCount

                    DispatchQueue.main.async {
                        self.library.updateWordCounts(bookID: book.id, wordCount: wordCount, charCount: charCount)

                        if book.format.isAudio {
                            if let index = self.library.books.firstIndex(where: { $0.id == book.id }) {
                                self.library.books[index].audioDuration = Double(charCount) / 10.0
                            }
                        }

                        self.save()
                        LibraryPersistenceService.saveBookInfo(for: self.library.books.first(where: { $0.id == book.id }) ?? book)
                    }
                } catch {
                    // Silently skip books that fail to parse — they'll be parsed when opened
                }
            }
        }
    }

    /// Generate content.md caches for any books that don't have one yet, or
    /// regenerate caches whose format version is older than the current version.
    /// Runs in the background with progress tracking so the UI stays responsive.
    /// Calls the optional completion handler when finished (on the background queue).
    func extractMissingContentCaches(then completion: (() -> Void)? = nil) {
        let currentVersion = MarkdownCacheService.currentCacheVersion
        let booksNeedingCache = library.books.filter { book in
            guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return false }
            // Needs cache if missing or if the stored version is outdated
            if !MarkdownCacheService.cacheExists(for: book) { return true }
            return MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        }
        guard !booksNeedingCache.isEmpty else {
            // No extraction needed — run completion immediately
            DispatchQueue.global(qos: .utility).async { completion?() }
            return
        }

        DispatchQueue.main.async {
            self.isExtracting = true
            self.extractionProgressTotal = booksNeedingCache.count
            self.extractionProgressCurrent = 0
            self.extractionProgressMessage = "Updating text cache for \(booksNeedingCache.count) book\(booksNeedingCache.count == 1 ? "" : "s")..."
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var updatedBookIDs: [(UUID, String)] = []

            for (index, book) in booksNeedingCache.enumerated() {
                guard self != nil else { return }
                // Delete stale cache before regenerating
                if MarkdownCacheService.cacheExists(for: book) {
                    MarkdownCacheService.deleteCache(for: book)
                }
                MarkdownCacheService.generateCache(for: book)
                updatedBookIDs.append((book.id, currentVersion))

                DispatchQueue.main.async {
                    self?.extractionProgressCurrent = index + 1
                    self?.extractionProgressMessage = "Updating text cache: \(index + 1) of \(booksNeedingCache.count)..."
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                // Stamp the new cache version on each regenerated book
                for (bookID, version) in updatedBookIDs {
                    if let idx = self.library.books.firstIndex(where: { $0.id == bookID }) {
                        self.library.books[idx].cacheFormatVersion = version
                    }
                }
                self.save()
                // Persist bookInfo.json for each updated book
                for (bookID, _) in updatedBookIDs {
                    if let book = self.library.books.first(where: { $0.id == bookID }) {
                        LibraryPersistenceService.saveBookInfo(for: book)
                    }
                }
                self.isExtracting = false
                self.extractionProgressMessage = ""
            }

            completion?()
        }
    }

    /// Re-extract content.md caches for all non-audio books.
    /// Called from the "Redo Text Extraction" button in Storage Settings.
    func redoAllTextExtraction() {
        let booksToExtract = library.books.filter { book in
            !book.format.isAudio && !book.tmbDirectoryName.isEmpty
        }
        guard !booksToExtract.isEmpty else { return }

        isExtracting = true
        extractionProgressTotal = booksToExtract.count
        extractionProgressCurrent = 0
        extractionProgressMessage = "Re-extracting text from \(booksToExtract.count) book\(booksToExtract.count == 1 ? "" : "s")..."

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let currentVersion = MarkdownCacheService.currentCacheVersion
            var updatedBookIDs: [UUID] = []

            for (index, book) in booksToExtract.enumerated() {
                guard self != nil else { return }
                // Delete existing cache first
                MarkdownCacheService.deleteCache(for: book)
                MarkdownCacheService.generateCache(for: book)
                updatedBookIDs.append(book.id)

                DispatchQueue.main.async {
                    self?.extractionProgressCurrent = index + 1
                    self?.extractionProgressMessage = "Re-extracting text: \(index + 1) of \(booksToExtract.count)..."
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                // Stamp new cache version on all re-extracted books
                for bookID in updatedBookIDs {
                    if let idx = self.library.books.firstIndex(where: { $0.id == bookID }) {
                        self.library.books[idx].cacheFormatVersion = currentVersion
                    }
                }
                self.save()
                for bookID in updatedBookIDs {
                    if let book = self.library.books.first(where: { $0.id == bookID }) {
                        LibraryPersistenceService.saveBookInfo(for: book)
                    }
                }
                self.isExtracting = false
                self.extractionProgressMessage = ""
            }
        }
    }

    // MARK: - Directory Management

    /// Rebuild the .TextMouth directory structure, migrate all books,
    /// adopt orphaned .tmb packages, and extract missing content caches.
    func rebuildDirectory() {
        do {
            try FileImportService.rebuildDirectoryStructure(library: &library)
            save()
            LibraryPersistenceService.saveAllBookInfos(library)
            // Extract content caches for any newly adopted books, then recalculate stats
            extractMissingContentCaches(then: { [weak self] in
                self?.calculateMissingBookStats()
            })
        } catch {
            errorMessage = "Failed to rebuild directory: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Rebuild to the default location (~/.TextMouth), moving data there
    func rebuildToDefault() {
        do {
            let defaultRoot = TextMouthPaths.defaultRoot
            if TextMouthPaths.root.path != defaultRoot.path {
                try TextMouthPaths.moveDataDirectory(to: defaultRoot, library: &library)
            }
            try TextMouthPaths.ensureDirectoryStructure()
            try FileImportService.rebuildDirectoryStructure(library: &library)
            configService.config.dataDirectoryPath = ""
            configService.saveToDisk()
            save()
        } catch {
            errorMessage = "Failed to rebuild to default: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Move the data directory to a new location
    func moveDataDirectory(to newURL: URL) {
        do {
            try TextMouthPaths.moveDataDirectory(to: newURL, library: &library)
            configService.config.dataDirectoryPath = newURL.path
            configService.saveToDisk()
            save()
        } catch {
            errorMessage = "Failed to move directory: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Refresh Timer

    /// Start the periodic refresh timer that bumps refreshTick for time estimate updates
    func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshTick &+= 1
            }
        }
    }

    // MARK: - Time Estimation

    func totalTimeRemaining(books: [Book], wpm: Double) -> (time: TimeInterval, knownCount: Int, unknownCount: Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }
}
