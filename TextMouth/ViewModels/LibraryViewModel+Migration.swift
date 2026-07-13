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

        // Copy and validate the old sandbox directory. Keep the source as a
        // recovery copy; startup migration must never be the operation that
        // destroys the user's only known-good library.
        if fm.fileExists(atPath: containerTextMouth.path) && !fm.fileExists(atPath: realDefault.path) {
            do {
                let data = try Data(contentsOf: containerTextMouth.appendingPathComponent("library.json"))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let oldLibrary = try decoder.decode(Library.self, from: data)
                _ = try DataDirectoryMigrator.prepareMigration(
                    from: containerTextMouth,
                    to: realDefault,
                    library: oldLibrary
                )
                print("Copied and validated .TextMouth from sandbox container to \(realDefault.path); source retained")
            } catch {
                print("Failed to migrate from sandbox container: \(error)")
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
    /// Calls the optional completion handler on the main actor when finished.
    func extractMissingContentCaches(
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let currentVersion = MarkdownCacheService.currentCacheVersion
        let booksNeedingCache = library.books.filter { book in
            guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return false }
            // Needs cache if missing or if the stored version is outdated
            if !MarkdownCacheService.cacheExists(for: book) { return true }
            return MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        }
        guard !booksNeedingCache.isEmpty else {
            // No extraction needed — run completion immediately
            completion?()
            return
        }

        isExtracting = true
        extractionProgressTotal = booksNeedingCache.count
        extractionProgressCurrent = 0
        extractionProgressMessage = "Updating text cache for \(booksNeedingCache.count) book\(booksNeedingCache.count == 1 ? "" : "s")..."

        let updateProgress: @MainActor @Sendable (Int) -> Void = { [weak self] completed in
            self?.extractionProgressCurrent = completed
            self?.extractionProgressMessage = "Updating text cache: \(completed) of \(booksNeedingCache.count)..."
        }
        let finish: @MainActor @Sendable ([(UUID, String)]) -> Void = { [weak self] updates in
            guard let self else { return }
            for (bookID, version) in updates {
                if let idx = self.library.books.firstIndex(where: { $0.id == bookID }) {
                    self.library.books[idx].cacheFormatVersion = version
                }
            }
            self.save()
            for (bookID, _) in updates {
                if let book = self.library.books.first(where: { $0.id == bookID }) {
                    LibraryPersistenceService.saveBookInfo(for: book)
                }
            }
            self.isExtracting = false
            self.extractionProgressMessage = ""
        }

        DispatchQueue.global(qos: .utility).async {
            var updatedBookIDs: [(UUID, String)] = []

            for (index, book) in booksNeedingCache.enumerated() {
                // Delete stale cache before regenerating
                if MarkdownCacheService.cacheExists(for: book) {
                    MarkdownCacheService.deleteCache(for: book)
                }
                var regeneratedBook = book
                if MarkdownCacheService.generateCacheAndStampVersion(for: &regeneratedBook) {
                    updatedBookIDs.append((book.id, currentVersion))
                }

                let completed = index + 1
                DispatchQueue.main.async { updateProgress(completed) }
            }

            let completedUpdates = updatedBookIDs
            DispatchQueue.main.async {
                finish(completedUpdates)
                completion?()
            }
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

        let updateProgress: @MainActor @Sendable (Int) -> Void = { [weak self] completed in
            self?.extractionProgressCurrent = completed
            self?.extractionProgressMessage = "Re-extracting text: \(completed) of \(booksToExtract.count)..."
        }
        let finish: @MainActor @Sendable ([UUID], String) -> Void = { [weak self] updates, version in
            guard let self else { return }
            for bookID in updates {
                if let idx = self.library.books.firstIndex(where: { $0.id == bookID }) {
                    self.library.books[idx].cacheFormatVersion = version
                }
            }
            self.save()
            for bookID in updates {
                if let book = self.library.books.first(where: { $0.id == bookID }) {
                    LibraryPersistenceService.saveBookInfo(for: book)
                }
            }
            self.isExtracting = false
            self.extractionProgressMessage = ""
        }

        DispatchQueue.global(qos: .utility).async {
            let currentVersion = MarkdownCacheService.currentCacheVersion
            var updatedBookIDs: [UUID] = []

            for (index, book) in booksToExtract.enumerated() {
                // Delete existing cache first
                MarkdownCacheService.deleteCache(for: book)
                var regeneratedBook = book
                if MarkdownCacheService.generateCacheAndStampVersion(for: &regeneratedBook) {
                    updatedBookIDs.append(book.id)
                }

                let completed = index + 1
                DispatchQueue.main.async { updateProgress(completed) }
            }

            let completedUpdates = updatedBookIDs
            DispatchQueue.main.async {
                finish(completedUpdates, currentVersion)
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
            configService.config.dataDirectoryPath = TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
            configService.saveToDisk()
            errorMessage = "Failed to move directory: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Refresh Timer

    /// Start the periodic refresh timer that bumps refreshTick for time estimate updates
    func startRefreshTimer() {
        // Defensive invalidate-before-assign so a second call doesn't leak
        // a Timer (two copies firing every 10s — visible as accelerated
        // refreshTick updates and double the wakeups).
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTick &+= 1 }
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
