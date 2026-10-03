import SwiftUI
import Darwin

/// Long parser batches can leave gigabytes of freed Swift/Foundation storage
/// resident or compressed inside malloc's per-process regions. Give malloc a
/// pressure-relief opportunity after each book so a library-wide migration has
/// the memory profile of its active books, rather than the sum of every book.
private func releaseBatchParserMemory() {
    _ = malloc_zone_pressure_relief(nil, 0)
}

/// Small value retained until the main actor publishes a completed book: the
/// analysis fields its package records. The full chapter/heading index is
/// already on disk and can be released after each book instead of pinning
/// parser allocation regions for the entire migration.
private struct ContentAnalysisSummary: Sendable {
    let bookID: UUID
    let fields: Book.ContentAnalysisFields

    /// The analysis fields of `committed`, the book as its package records
    /// it once the analysis is saved (`LibraryPersistenceService.saveContentAnalysis`).
    init(committed: Book) {
        bookID = committed.id
        fields = committed.contentAnalysisFields
    }

    /// Gives `book`, the library row, the committed analysis fields and
    /// nothing else. The row keeps its own reading state, settings, and
    /// metadata, which are at least as new as its package's.
    func apply(to book: inout Book) {
        book.contentAnalysisFields = fields
    }
}

/// Extension for data migration, directory management, content cache extraction,
/// statistics calculation, and periodic refresh timing.
extension LibraryViewModel {

    /// Migrate any books still using old storage paths to .tmb packages,
    /// and fix any stale file paths pointing to old locations.
    func migrateOldBooksIfNeeded() {
        // Every repair below reconciles the index with the disk and then saves
        // the index. While the index cannot be read there is nothing to
        // reconcile, and saving would replace the evidence the user may still
        // recover, so show a library rebuilt from disk and save nothing.
        guard indexRecovery == nil else {
            buildProvisionalLibrary()
            return
        }

        var needsSave = false

        // A book taken out with Remove from Library Only stays out, even when
        // this index was saved before the removal. It goes first, so no
        // repair below touches its package.
        if !RemovedFromLibraryMarker.removeRetiredBooks(from: &library).isEmpty { needsSave = true }

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

        // Move books that have no .tmb package yet into packages. Each copy
        // is verified before its original is removed; a book that cannot
        // move keeps its record and original, and the pass logs why.
        let migration = FileImportService.migrateLegacyBooks(in: &library)
        if migration.migratedCount > 0 { needsSave = true }

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

        // Once, after the whole repair, so one alert covers every book.
        showLegacyMigrationIssues(migration)
    }

    /// Tells the user, through the library's error alert, which legacy books
    /// could not move into packages and which moved with a problem, each
    /// with the reason. A migration with nothing to report shows nothing.
    private func showLegacyMigrationIssues(_ report: LegacyMigrationReport) {
        guard let summary = report.userSummary else { return }
        errorMessage = summary
        showError = true
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

    /// Records a startup folder repair as a storage event, in the debug log
    /// and the console.
    private func logFolderRepair(_ message: String) {
        DiagnosticLog.event(.storage, "FOLDER_REPAIR: \(message)")
    }

    /// Copies the data directory a sandboxed release of TextMouth left in its
    /// container to the default location in `home`, the first time the app
    /// starts without one there.
    ///
    /// - Parameter home: The home directory both locations are in. The app
    ///   passes nothing and gets the runtime's home: the user's real home,
    ///   or the sandbox under hosted tests, so a test host never reads a real
    ///   container or creates a real ~/.TextMouth. Tests pass a home of their
    ///   own to exercise the copy.
    func migrateFromSandboxContainer(home: URL = TextMouthRuntime.current.homeDirectory) {
        let fm = FileManager.default
        let defaultRoot = TextMouthPaths.defaultRoot(in: home)
        let containerRoot = TextMouthPaths.sandboxContainerRoot(in: home)

        // Only a first launch after the move out of the sandbox migrates: a
        // default location that exists is the current library.
        guard fm.fileExists(atPath: containerRoot.path), !fm.fileExists(atPath: defaultRoot.path) else { return }

        // Copy and validate the old sandbox directory. Keep the source as a
        // recovery copy; startup migration must never be the operation that
        // destroys the user's only known-good library.
        do {
            let data = try Data(contentsOf: containerRoot.appendingPathComponent("library.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let oldLibrary = try decoder.decode(Library.self, from: data)
            _ = try DataDirectoryMigrator.prepareMigration(
                from: containerRoot,
                to: defaultRoot,
                library: oldLibrary
            )
            print("Copied and validated .TextMouth from sandbox container to \(defaultRoot.path); source retained")
        } catch {
            print("Failed to migrate from sandbox container: \(error)")
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
                        // `book` is the row as it was when this pass began. The
                        // result lands on the book's latest state; a dropped one
                        // leaves the row alone, so a later pass tries again.
                        guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                            for: book,
                            index: analysis.index,
                            cacheFormatVersion: analysis.cacheFormatVersion
                        ) else { return true }
                        let summary = ContentAnalysisSummary(committed: committed)

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

    /// Bring every book's text cache and statistics up to date: caches first,
    /// then statistics, which can use them. Both run on background queues.
    func updateContentCachesAndStatistics() {
        extractMissingContentCaches(then: { [weak self] in
            self?.calculateMissingBookStats()
        })
    }

    nonisolated static func needsContentAnalysis(_ book: Book) -> Bool {
        book.contentIndexVersion != BookContentIndex.currentVersion
            || book.totalWordCount == nil
            || book.totalCharacterCount == nil
            || (book.format.isAudio && book.audioDuration == nil)
            || needsTextCacheFingerprint(book)
    }

    /// Whether `book` has a current text cache that was written before
    /// caches were fingerprinted (TODO T07). The statistics pass loads such
    /// a book once, and that load, once the cache passes every check,
    /// fingerprints it and the pass saves the result, so the book's later
    /// loads verify it by size and date alone. The pass reads one book at a
    /// time at utility priority, after the cache batch, so a library of
    /// hundreds of such books is never hashed at once; opening a book first
    /// fingerprints it the same way. A book whose source is missing is
    /// skipped by the pass and keeps its cache unfingerprinted.
    nonisolated static func needsTextCacheFingerprint(_ book: Book) -> Bool {
        !book.format.isAudio
            && !book.tmbDirectoryName.isEmpty
            && book.textCacheFingerprint == nil
            && book.cacheFormatVersion == MarkdownCacheService.currentCacheVersion
    }

    /// Generate content.md caches for any books that don't have one yet, or
    /// regenerate caches whose format version is older than the current version,
    /// or whose source or content.md has changed size since the cache was written.
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
            if MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion) { return true }
            return Self.hasResizedTextCacheFile(book)
        }
        rebuildTextCaches(books: booksNeedingCache, force: false, completion: completion)
    }

    /// Whether `book`'s source or content.md now has another size than the
    /// fingerprints its library row recorded when the cache was written
    /// (TODO T07): a stale cache, found by two stat calls, so asking it of
    /// every book at startup reads no file. The batch then checks the
    /// fingerprints its package recorded (`completedTextCacheIndex`), which
    /// reports the stale cache and has it rebuilt like an outdated one; a
    /// package newer than the row is recovered instead. A file that only has
    /// a new date is left to the next open, which reads it for its digest
    /// and keeps a cache that did not change. A book without fingerprints
    /// has nothing to compare.
    nonisolated static func hasResizedTextCacheFile(_ book: Book) -> Bool {
        guard let recorded = book.textCacheFingerprint else { return false }
        return recorded.hasResizedFile(
            sourceStamp: FileStamp(of: book.bookFileURL),
            cacheStamp: FileStamp(of: MarkdownCacheService.cacheURL(for: book))
        )
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
                    // The package records this index with the current version.
                    var recovered = book
                    recovered.applyContentAnalysis(savedIndex, cacheFormatVersion: currentVersion)
                    return ContentAnalysisSummary(committed: recovered)
                }
                var updatedBook = book
                guard let contentIndex = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &updatedBook) else {
                    return nil
                }
                do {
                    // `book` is the row as it was when the batch was queued. The
                    // result lands on the book's latest state; a dropped one
                    // leaves the library version unchanged, so a later pass
                    // tries again.
                    guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                        for: updatedBook, index: contentIndex, cacheFormatVersion: currentVersion
                    ) else { return nil }
                    return ContentAnalysisSummary(committed: committed)
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
    //
    // Each maintenance operation comes in two forms (TODO A07). The plain
    // form explains problems through the library's alerts, as it always
    // did. The `...ReturningOutcome` form, which Storage settings use,
    // presents nothing and returns the outcome, so the status line where
    // the user started the operation says what really happened. Both forms
    // run the same work.

    /// Words that begin each maintenance failure, before the reason.
    private static let rebuildFailureContext = "Failed to rebuild directory"
    private static let resetFailureContext = "Failed to rebuild to default"
    private static let moveFailureContext = "Failed to move directory"

    /// Rebuild the .TextMouth directory structure, migrate all books,
    /// adopt orphaned .tmb packages, and extract missing content caches.
    /// Problems are explained through the library's alerts.
    func rebuildDirectory() {
        presentThroughAlerts(runDirectoryRebuild(), failureContext: Self.rebuildFailureContext)
    }

    /// Rebuild Directory, returning its outcome and presenting nothing. It
    /// succeeds with "Done. N books in library.", followed by any legacy
    /// books that could not move into packages, or fails with the reason
    /// nothing was rebuilt, such as an unreadable library index.
    func rebuildDirectoryReturningOutcome() -> OperationOutcome {
        let run = runDirectoryRebuild()
        let bookCount = library.books.count
        return Self.maintenanceOutcome(
            run,
            failureContext: Self.rebuildFailureContext,
            done: "Done. \(bookCount) \(bookCount == 1 ? "book" : "books") in library."
        )
    }

    /// The work of Rebuild Directory: the legacy migration report, or the
    /// error that stopped the rebuild.
    private func runDirectoryRebuild() -> Result<LegacyMigrationReport?, Error> {
        Result {
            try ensureLibraryIndexIsReadable()
            let migration = try FileImportService.rebuildDirectoryStructure(library: &library)
            save()
            LibraryPersistenceService.saveAllBookInfos(library)
            // Extract content caches for any newly adopted books, then recalculate stats
            updateContentCachesAndStatistics()
            return migration
        }
    }

    /// Rebuild to the default location (~/.TextMouth), moving data there.
    /// Problems are explained through the library's alerts.
    func rebuildToDefault() {
        presentThroughAlerts(runRebuildToDefault(), failureContext: Self.resetFailureContext)
    }

    /// Reset to Default, returning its outcome and presenting nothing. It
    /// succeeds with "Done. Data is now at <path>." (see
    /// `dataLocationDone(since:)`), followed by any legacy books that could
    /// not move into packages, or fails with the reason, such as a default
    /// location that already holds other files.
    func rebuildToDefaultReturningOutcome() -> OperationOutcome {
        let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
        let run = runRebuildToDefault()
        return Self.maintenanceOutcome(
            run,
            failureContext: Self.resetFailureContext,
            done: Self.dataLocationDone(since: previousRoot)
        )
    }

    /// The work of Reset to Default: the legacy migration report, or the
    /// error that stopped it.
    private func runRebuildToDefault() -> Result<LegacyMigrationReport?, Error> {
        Result {
            try ensureLibraryIndexIsReadable()
            let defaultRoot = TextMouthPaths.defaultRoot
            if TextMouthPaths.root.path != defaultRoot.path {
                try TextMouthPaths.moveDataDirectory(to: defaultRoot, library: &library)
            }
            try TextMouthPaths.ensureDirectoryStructure()
            let migration = try FileImportService.rebuildDirectoryStructure(library: &library)
            configService.config.dataDirectoryPath = ""
            configService.saveToDisk()
            save()
            return migration
        }
    }

    /// Move the data directory to a new location. A failure is explained
    /// through the library's error alert; a location requested by editing
    /// config.json arrives this way.
    func moveDataDirectory(to newURL: URL) {
        presentThroughAlerts(runDataDirectoryMove(to: newURL), failureContext: Self.moveFailureContext)
    }

    /// Change Location, returning its outcome and presenting nothing. It
    /// succeeds with "Done. Data is now at <path>." (see
    /// `dataLocationDone(since:)`) or fails with the reason nothing moved,
    /// such as a destination that is not empty or that changed while the
    /// data was copied.
    func moveDataDirectoryReturningOutcome(to newURL: URL) -> OperationOutcome {
        let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
        let run = runDataDirectoryMove(to: newURL)
        return Self.maintenanceOutcome(
            run,
            failureContext: Self.moveFailureContext,
            done: Self.dataLocationDone(since: previousRoot)
        )
    }

    /// "Done. Data is now at <path>." for a run that began with the data
    /// directory at `previousRoot` and left it where `TextMouthPaths.root`
    /// names it now, with the folder each link in either location leads to
    /// (TODO S10). Built after the run, so it describes the state the run
    /// left.
    private static func dataLocationDone(since previousRoot: DataDirectoryLocation) -> String {
        DataDirectoryMigrator.doneMessage(
            dataAt: DataDirectoryLocation(TextMouthPaths.root),
            copiedFrom: previousRoot
        )
    }

    /// The work of moving the data directory: no legacy migration report,
    /// or the error that stopped the move. A failed move leaves config.json
    /// naming the directory still in use.
    private func runDataDirectoryMove(to newURL: URL) -> Result<LegacyMigrationReport?, Error> {
        do {
            try ensureLibraryIndexIsReadable()
            try TextMouthPaths.moveDataDirectory(to: newURL, library: &library)
            configService.config.dataDirectoryPath = newURL.path
            configService.saveToDisk()
            save()
            return .success(nil)
        } catch {
            configService.config.dataDirectoryPath = TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
            configService.saveToDisk()
            return .failure(error)
        }
    }

    /// Reports a maintenance run through the library's alerts: a failure as
    /// "<context>: <reason>", or after a success any legacy books that could
    /// not move into packages.
    private func presentThroughAlerts(
        _ run: Result<LegacyMigrationReport?, Error>,
        failureContext: String
    ) {
        switch run {
        case .success(let migration):
            if let migration {
                showLegacyMigrationIssues(migration)
            }
        case .failure(let error):
            presentFilesystemError(failureContext, error: error)
        }
    }

    /// The outcome of a maintenance run for the workflow that started it:
    /// `done`, followed by any legacy books that could not move into
    /// packages, or the failure as "<context>: <reason>". Callers build
    /// `done` after the run, so it describes the state the run left.
    nonisolated static func maintenanceOutcome(
        _ run: Result<LegacyMigrationReport?, Error>,
        failureContext: String,
        done: String
    ) -> OperationOutcome {
        switch run {
        case .success(let migration):
            guard let issues = migration?.userSummary else { return .success(done) }
            return .success(done + "\n\n" + issues)
        case .failure(let error):
            return .failure(failureContext, error)
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
