import SwiftUI
import Darwin

/// Long parser batches can leave gigabytes of freed Swift/Foundation storage
/// resident or compressed inside malloc's per-process regions. Give malloc a
/// pressure-relief opportunity after each book so a library-wide migration has
/// the memory profile of its active books, rather than the sum of every book.
private func releaseBatchParserMemory() {
    _ = malloc_zone_pressure_relief(nil, 0)
}

/// Small value retained until the main actor publishes a completed book. The
/// full chapter/heading index is already on disk and can be released after each
/// book instead of pinning parser allocation regions for the entire migration.
private struct ContentAnalysisSummary: Sendable {
    let bookID: UUID
    let cacheFormatVersion: String?
    let totalWordCount: Int
    let totalCharacterCount: Int
    let audioDuration: TimeInterval?
    let contentIndexVersion: String

    init(bookID: UUID, index: BookContentIndex, cacheFormatVersion: String?) {
        self.bookID = bookID
        self.cacheFormatVersion = cacheFormatVersion
        totalWordCount = index.totalWordCount
        totalCharacterCount = index.totalCharacterCount
        audioDuration = index.totalAudioDuration
        contentIndexVersion = index.version
    }

    func apply(to book: inout Book) {
        book.totalWordCount = totalWordCount
        book.totalCharacterCount = totalCharacterCount
        book.audioDuration = audioDuration
        book.contentIndexVersion = contentIndexVersion
        if let cacheFormatVersion {
            book.cacheFormatVersion = cacheFormatVersion
        }
    }
}

/// Extension for data migration, directory management, content cache extraction,
/// statistics calculation, and periodic refresh timing.
extension LibraryViewModel {

    /// Migrate any books still using old storage paths to .tmb packages,
    /// and fix any stale file paths pointing to old locations.
    func migrateOldBooksIfNeeded() {
        var needsSave = false

        // Merge folder rows that name one directory on this volume before the
        // repairs below reason about where each book's package lives.
        if repairEquivalentFolderDuplicates() { needsSave = true }

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

        // Repair legacy package-name collisions before background parsing can
        // write two different books' caches and indexes into the same directory.
        let separated = FileImportService.separateSharedTMBPackages(library: &library)
        if separated > 0 { needsSave = true }

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

    /// Merges folder rows that older versions let share one directory
    /// (`Reports` and `reports` on a case-insensitive volume, or composed and
    /// decomposed spellings of a name on any volume). Part of the startup
    /// repair path: it changes only the model, logs each merge, and rewrites
    /// the package records of books that moved; nothing is deleted from disk.
    /// Returns whether the library changed and needs saving. A second run
    /// finds nothing to merge.
    @discardableResult
    func repairEquivalentFolderDuplicates(
        equivalence: FolderPathEquivalence = .library
    ) -> Bool {
        let repair = library.mergeEquivalentFolders(equivalence: equivalence)
        guard repair.changedLibrary else { return false }

        for merge in repair.merges {
            logFolderRepair("merged duplicate folder '\(merge.duplicatePath)' into '\(merge.survivingPath)'")
        }
        if !repair.relocatedBookIDs.isEmpty {
            logFolderRepair(
                "moved \(repair.relocatedBookIDs.count) book(s) onto surviving folders; nothing was deleted from disk"
            )
        }
        let relocated = Set(repair.relocatedBookIDs)
        for book in library.books where relocated.contains(book.id) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
        return true
    }

    /// Records a startup folder repair in the console and the debug log.
    private func logFolderRepair(_ message: String) {
        let line = "FOLDER_REPAIR: \(message)"
        print(line)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
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

    /// Build any missing/outdated per-package content indexes. Parsing and word
    /// counting stay on the utility queue; the main actor receives only compact
    /// Book summary assignments and progress-independent persistence requests.
    func calculateMissingBookStats() {
        let booksNeedingStats = library.books.filter(Self.needsContentAnalysis)
        guard !booksNeedingStats.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for book in booksNeedingStats {
                let shouldContinue = autoreleasepool {
                    guard let self = self else { return false }
                    guard FileManager.default.fileExists(atPath: book.filePath) else { return true }

                    do {
                        let analysis = try BookContentAnalysisService.load(book: book)
                        try LibraryPersistenceService.saveContentAnalysis(
                            for: book,
                            index: analysis.index,
                            cacheFormatVersion: analysis.cacheFormatVersion
                        )
                        let summary = ContentAnalysisSummary(
                            bookID: book.id,
                            index: analysis.index,
                            cacheFormatVersion: analysis.cacheFormatVersion
                        )

                        DispatchQueue.main.async {
                            guard let index = self.library.books.firstIndex(where: { $0.id == summary.bookID }) else {
                                return
                            }
                            summary.apply(to: &self.library.books[index])
                            self.save()
                        }
                    } catch {
                        // Silently skip books that fail to parse — they'll be parsed when opened
                    }
                    return true
                }
                releaseBatchParserMemory()
                guard shouldContinue else { return }
            }
        }
    }

    nonisolated static func needsContentAnalysis(_ book: Book) -> Bool {
        book.contentIndexVersion != BookContentIndex.currentVersion
            || book.totalWordCount == nil
            || book.totalCharacterCount == nil
            || (book.format.isAudio && book.audioDuration == nil)
    }

    /// Generate content.md caches for any books that don't have one yet, or
    /// regenerate caches whose format version is older than the current version.
    /// Runs in the background with progress tracking so the UI stays responsive.
    /// Calls the optional completion handler on the main actor when finished.
    func extractMissingContentCaches(
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // A second scene/action must not launch the same library migration again.
        guard !isExtracting else { return }
        let booksNeedingCache = library.books.filter { book in
            guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return false }
            // Needs cache if missing or if the stored version is outdated
            if !MarkdownCacheService.cacheExists(for: book) { return true }
            return MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        }
        rebuildTextCaches(books: booksNeedingCache, force: false, completion: completion)
    }

    /// Re-extract content.md caches for all non-audio books.
    /// Called from the "Redo Text Extraction" button in Storage Settings.
    func redoAllTextExtraction() {
        guard !isExtracting else { return }
        let booksToExtract = library.books.filter { book in
            !book.format.isAudio && !book.tmbDirectoryName.isEmpty
        }
        rebuildTextCaches(books: booksToExtract, force: true)
    }

    /// Share automatic and manual extraction, releasing large parser results per
    /// book and publishing each durable checkpoint before advancing progress.
    /// Bounded utility workers keep memory and CPU available for reading.
    private func rebuildTextCaches(
        books: [Book],
        force: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !books.isEmpty else {
            completion?()
            return
        }

        isExtracting = true
        extractionProgressTotal = books.count
        extractionProgressCurrent = 0
        let activity = force ? "Re-extracting text" : "Updating text cache"
        extractionProgressMessage = "\(activity): 0 of \(books.count)..."

        let updateProgress: @MainActor @Sendable (ContentAnalysisSummary?) -> Void = { [weak self] summary in
            guard let self else { return }
            if let summary, let index = self.library.books.firstIndex(where: { $0.id == summary.bookID }) {
                summary.apply(to: &self.library.books[index])
                // Debounced library saves can be flushed at quit. A crash before
                // this update is recovered from the package checkpoint next time.
                self.save()
            }
            self.extractionProgressCurrent += 1
            self.extractionProgressMessage = "\(activity): \(self.extractionProgressCurrent) of \(books.count)..."
        }

        TextCacheUpdateQueue.run(books: books, update: { book in
            let currentVersion = MarkdownCacheService.currentCacheVersion
            let summary: ContentAnalysisSummary? = autoreleasepool {
                if !force, let savedIndex = BookContentAnalysisService.completedTextCacheIndex(for: book) {
                    // An earlier run already committed this book; repairing
                    // the library summary requires no source parsing or writes.
                    return ContentAnalysisSummary(bookID: book.id, index: savedIndex, cacheFormatVersion: currentVersion)
                }
                var updatedBook = book
                guard let contentIndex = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &updatedBook) else {
                    return nil
                }
                do {
                    try LibraryPersistenceService.saveContentAnalysis(
                        for: updatedBook, index: contentIndex, cacheFormatVersion: currentVersion
                    )
                    return ContentAnalysisSummary(bookID: book.id, index: contentIndex, cacheFormatVersion: currentVersion)
                } catch {
                    // Leave the library version unchanged so startup retries
                    // a book whose new index could not be committed.
                    return nil
                }
            }
            releaseBatchParserMemory()
            DispatchQueue.main.async { updateProgress(summary) }
        }, completion: { [weak self] in
            // Each worker enqueues its progress before returning, so this final
            // main-queue block follows all completed-book notifications.
            DispatchQueue.main.async { [weak self] in
                self?.isExtracting = false
                self?.extractionProgressMessage = ""
                completion?()
            }
        })
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
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTick &+= 1 }
        }
        refreshTimer = LibraryRefreshTimer(timer: timer)
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
