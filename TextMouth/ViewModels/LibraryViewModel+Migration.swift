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
    ///
    /// The data directory may be in a cloud folder (FR02), so every check
    /// and read of the repair runs with dataless files left in the cloud: one
    /// that would download a file or a folder's listing fails at once instead
    /// of waiting on the network, here on the main thread. Nothing is moved,
    /// rewritten, adopted, separated, or relocated on the strength of a check
    /// that met a dataless folder or a read that was refused: such a book
    /// keeps its row as it is, and one `MAINTENANCE_SKIPPED_IN_CLOUD` line
    /// counts such books.
    /// - Parameter access: How the repair reaches the books' files: `live`
    ///   in the app; tests pass one that pretends files are in the cloud.
    func migrateOldBooksIfNeeded(access: MaintenanceFileAccess = .live) {
        DatalessFiles.withoutDownloading {
            repairLibrary(access: access)
        }
    }

    /// The work of `migrateOldBooksIfNeeded(access:)`, run with dataless
    /// files left in the cloud.
    private func repairLibrary(access: MaintenanceFileAccess) {
        // Every repair below reconciles the index with the disk and then saves
        // the index. While the index cannot be read there is nothing to
        // reconcile, and saving would replace the evidence the user may still
        // recover, so show a library rebuilt from disk and save nothing.
        guard indexRecovery == nil else {
            buildProvisionalLibrary()
            return
        }

        let skips = CloudSkips(.startupRepair)
        defer { skips.log() }
        var needsSave = false

        // A book taken out with Remove from Library Only stays out, even when
        // this index was saved before the removal. It goes first, so no
        // repair below touches its package.
        if !removeRetiredBooks(access: access, skips: skips).isEmpty { needsSave = true }

        // A crash can leave reading checkpoints that reached their books'
        // records but not this index (PERF15). Their newer positions come
        // next, so the repairs below and the save after them keep them.
        if adoptNewerRecordedPositions(access: access, skips: skips) { needsSave = true }

        // Merge folder rows that name one directory on this volume before the
        // repairs below reason about where each book's package lives.
        if repairEquivalentFolderDuplicates() { needsSave = true }

        if repairStaleFilePaths(access: access, skips: skips) { needsSave = true }

        // Move books that have no .tmb package yet into packages. Each copy
        // is verified before its original is removed; a book that cannot
        // move keeps its record and original, and the pass logs why.
        let migration = migrateLegacyBooks(access: access, skips: skips)
        if migration.migratedCount > 0 { needsSave = true }

        // Repair legacy package-name collisions before background parsing can
        // write two different books' caches and indexes into the same directory.
        let separated = FileImportService.separateSharedTMBPackages(library: &library, access: access, skips: skips)
        if separated > 0 { needsSave = true }

        // Move .tmb packages that are at the root but should be in a subfolder.
        // This fixes books whose folder was assigned in the UI without physically
        // moving the directory (a bug fixed in d6c6b2c but existing books need repair).
        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library, access: access, skips: skips)
        if relocated > 0 { needsSave = true }

        // Adopt any .tmb packages on disk that aren't tracked in library.json.
        // This recovers books left behind by interrupted imports or crashes.
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, access: access, skips: skips)
        if adopted > 0 { needsSave = true }

        if needsSave {
            save()
        }

        // Once, after the whole repair, so one alert covers every book.
        showLegacyMigrationIssues(migration)
    }

    /// Takes the books Remove from Library Only retired out of the library,
    /// as `RemovedFromLibraryMarker.removeRetiredBooks(from:)` does, and
    /// returns them. A book whose removal marker is in the cloud keeps its
    /// row (FR02): the marker cannot be read without downloading it, and a
    /// marker that cannot be read counts as retiring its book. The book is
    /// counted in `skips`, and taken out once its marker is on this Mac.
    private func removeRetiredBooks(access: MaintenanceFileAccess, skips: CloudSkips) -> [Book] {
        let held = library.books.filter { book in
            !book.tmbDirectoryName.isEmpty
                && access.isInCloud(TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory))
        }
        guard !held.isEmpty else {
            return RemovedFromLibraryMarker.removeRetiredBooks(from: &library)
        }
        held.forEach(skips.record)
        let heldIDs = Set(held.map(\.id))
        var checkable = library
        checkable.books.removeAll { heldIDs.contains($0.id) }
        let retired = RemovedFromLibraryMarker.removeRetiredBooks(from: &checkable)
        let retiredIDs = Set(retired.map(\.id))
        library.books.removeAll { retiredIDs.contains($0.id) }
        return retired
    }

    /// Gives each book that the checkpoint journal names the reading position
    /// its package record holds, when that is newer than its row's (PERF15):
    /// a reading checkpoint writes the record at once but library.json
    /// within minutes, so a crash in between leaves the record ahead
    /// (`LibraryPersistenceService.saveReadingCheckpoint`). The record's
    /// last-opened date comes with it when that is newer too, as a
    /// checkpoint sets both. Returns whether any row changed.
    ///
    /// Only bookInfo.json is read, with dataless files left in the cloud. A
    /// book whose package or record is in the cloud keeps its row and is
    /// counted in `skips`; a record that is missing, cannot be read, or
    /// names another book changes nothing.
    private func adoptNewerRecordedPositions(access: MaintenanceFileAccess, skips: CloudSkips) -> Bool {
        let journaled = LibraryPersistenceService.booksWithCheckpointsAhead()
        guard !journaled.isEmpty else { return false }
        var adopted = 0
        for index in library.books.indices where journaled.contains(library.books[index].id) {
            let book = library.books[index]
            guard !book.tmbDirectoryName.isEmpty else { continue }
            let package = book.tmbDirectory
            let recordURL = TextMouthPaths.bookInfoPath(in: package)
            guard !access.isInCloud(package), !access.isInCloud(recordURL) else {
                skips.record(book)
                continue
            }
            let record: BookInfo
            do {
                record = try access.read(recordURL) { try StoredBookRecord.read(from: package) }.info
            } catch where DatalessFiles.isDownloadRefusal(error) {
                skips.record(book)
                continue
            } catch {
                continue
            }
            guard record.metadata.bookID == book.id,
                  let recorded = record.state.readingPosition,
                  recorded.lastUpdated > (book.readingPosition?.lastUpdated ?? .distantPast) else { continue }
            library.books[index].readingPosition = recorded
            if let opened = record.metadata.lastOpened, opened > (book.lastOpened ?? .distantPast) {
                library.books[index].lastOpened = opened
            }
            adopted += 1
        }
        guard adopted > 0 else { return false }
        let books = CountWording.phrase(adopted, singular: "book", plural: "books")
        DiagnosticLog.event(
            .storage,
            "LIBRARY_INDEX: took the reading positions of \(books) from their records, "
                + "which held checkpoints saved after the index"
        )
        return true
    }

    /// Fixes stale file paths: when a book's file is not at its recorded
    /// path, the package is looked for in the book's folder, then at the top
    /// of the library, where a folder assignment may have left it without
    /// moving it (a bug fixed in d6c6b2c), and is moved into its folder.
    /// Returns whether any row changed.
    ///
    /// Only a file found missing counts as missing (FR02). A check that met
    /// a dataless folder, or a package that is itself in the cloud, decides
    /// nothing: the book keeps its row as it is, and is counted in `skips`.
    private func repairStaleFilePaths(access: MaintenanceFileAccess, skips: CloudSkips) -> Bool {
        var changed = false
        for i in library.books.indices {
            let book = library.books[i]
            guard !book.tmbDirectoryName.isEmpty else { continue }
            /// What is at `url`, with the book counted in `skips` when the
            /// answer is in the cloud.
            func presence(of url: URL) -> ItemPresence {
                let found = access.presence(of: url)
                if found == .inCloud {
                    skips.record(book)
                }
                return found
            }
            guard presence(of: book.bookFileURL) == .absent else { continue }
            let fileName = book.bookFileURL.lastPathComponent

            // First try the expected folder location
            let tmbDir = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
            let correctPath = tmbDir.appendingPathComponent(fileName)
            switch presence(of: correctPath) {
            case .present:
                library.books[i].filePath = correctPath.path
                changed = true
                continue
            case .inCloud:
                continue
            case .absent:
                break
            }

            // Fall back: check root Library directory (the .tmb may never
            // have been physically moved when the book was assigned to a folder)
            let rootTmbDir = TextMouthPaths.tmbPath(folderPath: "", tmbName: book.tmbDirectoryName)
            let rootPath = rootTmbDir.appendingPathComponent(fileName)
            guard presence(of: rootPath) == .present else { continue }
            // A package that is itself in the cloud is not moved on the
            // strength of what this Mac knows of it.
            guard !access.isDataless(rootTmbDir) else {
                skips.record(book)
                continue
            }
            // Move the .tmb to the correct folder location
            do {
                if !book.folderPath.isEmpty {
                    try? TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
                }
                try FileManager.default.moveItem(at: rootTmbDir, to: tmbDir)
                library.books[i].filePath = correctPath.path
            } catch {
                // Move failed — just update the path to where the file actually is
                library.books[i].filePath = rootPath.path
            }
            changed = true
        }
        return changed
    }

    /// Moves the books recorded without a package into packages
    /// (`FileImportService.migrateLegacyBooks(in:)`) and returns its report,
    /// unless an original is in the cloud (FR02): copying it would download
    /// it. The migration decides whether an original may be removed by every
    /// record that reads it, so then none of the books moves this time; the
    /// ones in the cloud are counted in `skips`, and all of them move at a
    /// launch that finds their originals on this Mac.
    private func migrateLegacyBooks(access: MaintenanceFileAccess, skips: CloudSkips) -> LegacyMigrationReport {
        let inCloud = library.books.filter { book in
            book.tmbDirectoryName.isEmpty && access.fileInCloud(of: book, reading: .content) != nil
        }
        guard inCloud.isEmpty else {
            inCloud.forEach(skips.record)
            return LegacyMigrationReport()
        }
        return FileImportService.migrateLegacyBooks(in: &library)
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
    ///
    /// Each book's analysis is storage work (TODO S04): a data-directory move
    /// waits for the one under way and holds the rest until it has published,
    /// and a book listed before the move is then analyzed in the new data
    /// directory.
    ///
    /// A book whose files are in the cloud is left as it is (FR02), and the
    /// pass's one `MAINTENANCE_SKIPPED_IN_CLOUD` line counts such books (see
    /// `commitStatistics(of:access:skips:)`).
    /// - Parameters:
    ///   - access: How the pass reaches the books' files: `live` in the app;
    ///     tests pass one that pretends files are in the cloud.
    ///   - completion: Called on the main actor once the pass has ended,
    ///     after the updates of every book it analyzed.
    func calculateMissingBookStats(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let booksNeedingStats = library.books.filter(Self.needsContentAnalysis)
        guard !booksNeedingStats.isEmpty else {
            completion?()
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let boundary = StorageBoundary.shared
            let skips = CloudSkips(.statistics)
            defer {
                // Once the pass ends, however it ends. The completion is
                // queued behind every update the pass sent the main queue.
                skips.log()
                if let completion {
                    DispatchQueue.main.async { completion() }
                }
            }
            for listedBook in booksNeedingStats {
                let shouldContinue = autoreleasepool {
                    boundary.perform(.contentAnalysis) { _ -> Bool in
                        // The book as listed when the pass began, with its
                        // paths in the data directory in use now.
                        let book = boundary.rebasedToCurrent(listedBook)
                        guard let self = self else { return false }
                        guard let summary = Self.commitStatistics(of: book, access: access, skips: skips) else {
                            return true
                        }
                        DispatchQueue.main.async {
                            guard let index = self.library.books.firstIndex(where: { $0.id == summary.bookID }) else {
                                return
                            }
                            summary.apply(to: &self.library.books[index])
                            self.save()
                        }
                        return true
                    }
                }
                releaseBatchParserMemory()
                guard shouldContinue else { return }
            }
        }
    }

    /// Analyzes `book` for the statistics pass, on the pass's thread, and
    /// commits the analysis to the book's record; returns the analysis
    /// fields its package now records, or nil when nothing was committed.
    ///
    /// A book is left as it is, and counted in `skips`, when any of its
    /// files is in the cloud (FR02): the pass can read its record, its text
    /// cache, and its content, which for an audiobook is every track. Every
    /// read runs with dataless files left in the cloud, and a read refused
    /// because it met a dataless file leaves the book the same way, as does
    /// a file that went to the cloud while the book was read: nothing read in
    /// part is committed. A book whose file is missing, or that fails to
    /// parse, is skipped quietly too, and is parsed when it is opened.
    nonisolated private static func commitStatistics(
        of book: Book,
        access: MaintenanceFileAccess,
        skips: CloudSkips
    ) -> ContentAnalysisSummary? {
        do {
            try access.requireOnThisMac(book, reading: .all)
            guard access.presence(of: book.bookFileURL) == .present else { return nil }
            return try access.read(book.bookFileURL) {
                let analysis = try BookContentAnalysisService.load(
                    book: book,
                    hasher: access.hasher,
                    isDataless: access.isDataless
                )
                try access.requireOnThisMac(book, reading: .all)
                // `book` is the row as it was when this pass began. The
                // result lands on the book's latest state; a dropped one
                // leaves the row alone, so a later pass tries again.
                guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                    for: book,
                    index: analysis.index,
                    cacheFormatVersion: analysis.cacheFormatVersion
                ) else { return nil }
                return ContentAnalysisSummary(committed: committed)
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            skips.record(book)
            return nil
        } catch {
            // Silently skip books that fail to parse — they'll be parsed when opened
            return nil
        }
    }

    /// Bring every book's text cache and statistics up to date: caches first,
    /// then statistics, which can use them. Both run on background queues.
    /// - Parameter access: How both passes reach the books' files (FR02).
    func updateContentCachesAndStatistics(access: MaintenanceFileAccess = .live) {
        extractMissingContentCaches(access: access, then: { [weak self] in
            self?.calculateMissingBookStats(access: access)
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
    /// - Parameter access: How the batch reaches the books' files (FR02):
    ///   `live` in the app; tests pass one that pretends files are in the
    ///   cloud.
    func extractMissingContentCaches(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // A second scene/action must not launch the same library migration again.
        guard !isExtracting else { return }
        // These checks stat every book's files with dataless files left in
        // the cloud (FR02): one that would download a folder's listing fails
        // at once instead of waiting on the network, and the book it could
        // not check is listed, for the batch to find its files in the cloud.
        let booksNeedingCache = DatalessFiles.withoutDownloading {
            library.books.filter { book in
                guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return false }
                // Needs cache if missing or if the stored version is outdated
                if !MarkdownCacheService.cacheExists(for: book) { return true }
                if MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion) { return true }
                return Self.hasResizedTextCacheFile(book, isDataless: access.isDataless)
            }
        }
        rebuildTextCaches(books: booksNeedingCache, force: false, access: access) { _ in
            completion?()
        }
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
    ///
    /// A dataless file is never resized by the size it reports (FR02): an
    /// evicted iCloud Drive file reports 0 bytes, which would otherwise call
    /// its cache stale and have it rebuilt from a source downloaded for it.
    /// - Parameter isDataless: Whether a file is dataless: the maintenance
    ///   access's check.
    nonisolated static func hasResizedTextCacheFile(
        _ book: Book,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Bool {
        guard let recorded = book.textCacheFingerprint else { return false }
        let source = book.bookFileURL
        let cache = MarkdownCacheService.cacheURL(for: book)
        return recorded.hasResizedFile(
            sourceStamp: FileStamp(of: source),
            cacheStamp: FileStamp(of: cache),
            sourceIsDataless: isDataless(source),
            cacheIsDataless: isDataless(cache)
        )
    }

    /// Re-extract content.md caches for all non-audio books.
    /// Called from the "Redo Text Extraction" button in Storage Settings.
    /// - Parameters:
    ///   - access: How the pass reaches the books' files (FR02).
    ///   - completion: Told on the main actor, once every book is done, what
    ///     the pass did (`textReextractionOutcome(skippedInCloud:)`).
    /// - Returns: Whether the pass started: false while another text
    ///   extraction runs, when nothing is done and `completion` is not told.
    @discardableResult
    func redoAllTextExtraction(
        access: MaintenanceFileAccess = .live,
        completion: (@MainActor @Sendable (OperationOutcome) -> Void)? = nil
    ) -> Bool {
        guard !isExtracting else { return false }
        let booksToExtract = library.books.filter { book in
            !book.format.isAudio && !book.tmbDirectoryName.isEmpty
        }
        rebuildTextCaches(books: booksToExtract, force: true, access: access) { skippedInCloud in
            completion?(Self.textReextractionOutcome(skippedInCloud: skippedInCloud))
        }
        return true
    }

    /// Redo Text Extraction for Storage settings, returning once every book
    /// is done with what the pass did, which Storage settings' status line
    /// says and VoiceOver hears; nil when another text extraction runs and
    /// nothing was started.
    /// - Parameter access: How the pass reaches the books' files (FR02).
    func redoAllTextExtractionReturningOutcome(access: MaintenanceFileAccess = .live) async -> OperationOutcome? {
        await withCheckedContinuation { continuation in
            let started = redoAllTextExtraction(access: access) { outcome in
                continuation.resume(returning: outcome)
            }
            if !started {
                continuation.resume(returning: nil)
            }
        }
    }

    /// What Redo Text Extraction says once it is done: "Done.", and, when it
    /// left books as they were because their files are only in the cloud
    /// (FR02), how many, as in "Done. 12 books in the cloud were skipped."
    /// Before, only its MAINTENANCE_SKIPPED_IN_CLOUD log line told.
    nonisolated static func textReextractionOutcome(skippedInCloud: Int) -> OperationOutcome {
        guard skippedInCloud > 0 else { return .success(nil) }
        let books = CountWording.phrase(skippedInCloud, singular: "book in the cloud was", plural: "books in the cloud were")
        return .success("Done. \(books) skipped.")
    }

    /// Share automatic and manual extraction, releasing large parser results per
    /// book and publishing each durable checkpoint before advancing progress.
    /// Bounded utility workers keep memory and CPU available for reading.
    /// `access` is how each book's files are reached (FR02): a book whose
    /// files are in the cloud counts toward the progress, is left as it is,
    /// and is counted in the batch's one `MAINTENANCE_SKIPPED_IN_CLOUD` line.
    /// `completion` is told, on the main actor once every book is done, how
    /// many books the batch left in the cloud.
    private func rebuildTextCaches(
        books: [Book],
        force: Bool,
        access: MaintenanceFileAccess,
        completion: (@MainActor @Sendable (_ skippedInCloud: Int) -> Void)? = nil
    ) {
        guard !books.isEmpty else {
            completion?(0)
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

        let skips = CloudSkips(force ? .textReextraction : .textCacheUpdate)
        // What the pass reads of each book. Redo Text Extraction writes a new
        // text cache without reading the one it replaces.
        let files: MaintainedFiles = force ? [.content, .record] : .all

        TextCacheUpdateQueue.run(books: books, update: { book in
            let summary = autoreleasepool {
                Self.updateTextCache(of: book, force: force, reading: files, access: access, skips: skips)
            }
            releaseBatchParserMemory()
            DispatchQueue.main.async { updateProgress(summary) }
        }, completion: { [weak self] in
            // Every worker has returned, so the tally is complete.
            skips.log()
            let skippedInCloud = skips.count
            // Each worker enqueues its progress before returning, so this final
            // main-queue block follows all completed-book notifications.
            DispatchQueue.main.async { [weak self] in
                self?.isExtracting = false
                self?.extractionProgressMessage = ""
                completion?(skippedInCloud)
            }
        })
    }

    /// Brings `book`'s text cache up to date on a batch's worker thread, and
    /// returns what its package now records, or nil when nothing new was
    /// committed. `force` rebuilds the cache from the source even when an
    /// earlier run committed it, as Redo Text Extraction does.
    ///
    /// A book is left as it is, and counted in `skips`, when any of the
    /// `files` the batch reads is in the cloud (FR02). Its cache is caught up
    /// the next time its files are on this Mac, and the reader, which
    /// downloads a book before it loads it, rebuilds an outdated cache as it
    /// loads. Every read runs with dataless files left in the cloud, and a
    /// read refused because it met a dataless file leaves the book the same
    /// way: it is never logged as a failure, never rebuilds a cache, and
    /// never reaches the book's record.
    nonisolated private static func updateTextCache(
        of book: Book,
        force: Bool,
        reading files: MaintainedFiles,
        access: MaintenanceFileAccess,
        skips: CloudSkips
    ) -> ContentAnalysisSummary? {
        do {
            try access.requireOnThisMac(book, reading: files)
            return try access.read(book.bookFileURL) {
                try committedTextCache(of: book, force: force, reading: files, access: access)
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            skips.record(book)
            return nil
        } catch {
            MarkdownCacheService.logGenerationFailure(error, for: book)
            return nil
        }
    }

    /// The work of `updateTextCache(of:force:reading:access:skips:)` for a
    /// book whose `files` were on this Mac when it began: recovers the cache
    /// an earlier run committed, or writes the cache from the source and
    /// commits its analysis to the book's record.
    /// - Throws: why no cache could be written, including the refusal of a
    ///   read that met a file which went to the cloud meanwhile.
    nonisolated private static func committedTextCache(
        of book: Book,
        force: Bool,
        reading files: MaintainedFiles,
        access: MaintenanceFileAccess
    ) throws -> ContentAnalysisSummary? {
        let currentVersion = MarkdownCacheService.currentCacheVersion
        if !force, let savedIndex = try BookContentAnalysisService.recoveredTextCacheIndex(
            for: book,
            hasher: access.hasher,
            isDataless: access.isDataless
        ) {
            // An earlier run already committed this book; repairing
            // the library summary requires no source parsing or writes.
            // The package records this index with the current version.
            var recovered = book
            recovered.applyContentAnalysis(savedIndex, cacheFormatVersion: currentVersion)
            return ContentAnalysisSummary(committed: recovered)
        }
        var updatedBook = book
        guard let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &updatedBook) else {
            return nil
        }
        // A file that went to the cloud while the cache was written may have
        // been read only in part, so nothing is committed from it.
        try access.requireOnThisMac(book, reading: files)
        do {
            // `book` is the row as it was when the batch was queued. The
            // result lands on the book's latest state; a dropped one
            // leaves the library version unchanged, so a later pass
            // tries again.
            guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                for: updatedBook, index: generated.content.contentIndex, cacheFormatVersion: currentVersion
            ) else { return nil }
            return ContentAnalysisSummary(committed: committed)
        } catch {
            // Leave the library version unchanged so startup retries
            // a book whose new index could not be committed.
            return nil
        }
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
    /// Problems are explained through the library's alerts. Returns the
    /// task doing the work, which first waits for the storage work under
    /// way (TODO S04); callers need not wait for it.
    @discardableResult
    func rebuildDirectory() -> Task<Void, Never> {
        Task {
            presentThroughAlerts(
                await runDirectoryRebuild(waiting: { _ in }),
                failureContext: Self.rebuildFailureContext
            )
        }
    }

    /// Rebuild Directory, returning its outcome and presenting nothing. It
    /// succeeds with "Done. N books in library.", followed by any legacy
    /// books that could not move into packages, or fails with the reason
    /// nothing was rebuilt, such as an unreadable library index.
    /// - Parameter waiting: Told what the rebuild waits for before it
    ///   changes anything (see `withStorageWorkHeld(moving:waiting:_:)`).
    func rebuildDirectoryReturningOutcome(
        waiting: (StorageWork?) async -> Void = { _ in }
    ) async -> OperationOutcome {
        let run = await runDirectoryRebuild(waiting: waiting)
        let bookCount = library.books.count
        return Self.maintenanceOutcome(
            run,
            failureContext: Self.rebuildFailureContext,
            done: "Done. \(bookCount) \(bookCount == 1 ? "book" : "books") in library."
        )
    }

    /// The work of Rebuild Directory: the legacy migration report, or the
    /// error that stopped the rebuild.
    ///
    /// The relocation of misplaced packages and the adoption of packages
    /// the library does not list run as one unit of storage work, as a
    /// move's copy does (`withStorageWorkHeld`, with no move): new imports,
    /// text extractions, and book analyses are held back, and the rebuild
    /// first waits for those under way. An import that has published its
    /// package but not yet added its book to the library therefore adds it
    /// first, so its package is never adopted as an orphan as well (TODO
    /// S04). The text caches and statistics of adopted books are brought up
    /// to date afterwards, once the held work has gone on.
    private func runDirectoryRebuild(
        waiting: (StorageWork?) async -> Void
    ) async -> Result<LegacyMigrationReport?, Error> {
        do {
            try ensureLibraryIndexIsReadable()
            let migration = try await withStorageWorkHeld(moving: nil, waiting: waiting) { () throws -> LegacyMigrationReport? in
                let migration = try FileImportService.rebuildDirectoryStructure(library: &library)
                save()
                LibraryPersistenceService.saveAllBookInfos(library)
                return migration
            }
            updateContentCachesAndStatistics()
            return .success(migration)
        } catch {
            return .failure(error)
        }
    }

    /// Rebuild to the default location (~/.TextMouth), moving data there.
    /// Problems are explained through the library's alerts, and VoiceOver
    /// hears how a move ended (`presentMove`). Returns the task doing the
    /// work, which first waits for the storage work under way (TODO S04);
    /// callers need not wait for it.
    @discardableResult
    func rebuildToDefault() -> Task<Void, Never> {
        Task {
            let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
            let run = await runRebuildToDefault(access: .live, waiting: { _ in })
            presentMove(run, failureContext: Self.resetFailureContext, since: previousRoot)
        }
    }

    /// Reset to Default, returning its outcome and presenting nothing. It
    /// succeeds with "Done. Data is now at <path>." (see
    /// `dataLocationDone(since:)`), followed by any legacy books that could
    /// not move into packages, ends with "Move cancelled." after Cancel, or
    /// fails with the reason, such as a default location that already holds
    /// other files (see `moveOutcome`).
    /// - Parameters:
    ///   - access: How the move tells which books are only in the cloud:
    ///     `live` in the app; tests pass one that pretends files are there.
    ///   - waiting: Told what the move waits for before it copies anything
    ///     (see `withStorageWorkHeld(moving:waiting:_:)`).
    func rebuildToDefaultReturningOutcome(
        access: MaintenanceFileAccess = .live,
        waiting: (StorageWork?) async -> Void = { _ in }
    ) async -> OperationOutcome {
        let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
        let run = await runRebuildToDefault(access: access, waiting: waiting)
        return moveOutcome(run, failureContext: Self.resetFailureContext, since: previousRoot)
    }

    /// The work of Reset to Default: the legacy migration report, or the
    /// error that stopped it. A library already in the default location is
    /// only rebuilt; any other is first moved there, with progress and
    /// Cancel (FR02). Like a move, it holds back the storage work that
    /// writes into the data directory until it is done, the rebuild in the
    /// default location included.
    private func runRebuildToDefault(
        access: MaintenanceFileAccess,
        waiting: (StorageWork?) async -> Void
    ) async -> Result<LegacyMigrationReport?, Error> {
        do {
            try ensureLibraryIndexIsReadable()
            let defaultRoot = TextMouthPaths.defaultRoot
            let move = TextMouthPaths.root.path == defaultRoot.path
                ? nil
                : DataDirectoryMoveRequest(destination: defaultRoot, isResetToDefault: true, access: access)
            let migration = try await withStorageWorkHeld(moving: move, waiting: waiting) { () throws -> LegacyMigrationReport? in
                try TextMouthPaths.ensureDirectoryStructure()
                let migration = try FileImportService.rebuildDirectoryStructure(library: &library)
                configService.config.dataDirectoryPath = ""
                configService.saveToDisk()
                save()
                return migration
            }
            return .success(migration)
        } catch {
            return .failure(error)
        }
    }

    /// Move the data directory to a new location. A failure is explained
    /// through the library's error alert, and VoiceOver hears how the move
    /// ended (`presentMove`); a location requested by editing config.json
    /// arrives this way. Returns the task doing the work, which first waits
    /// for the storage work under way (TODO S04); callers need not wait for
    /// it.
    @discardableResult
    func moveDataDirectory(to newURL: URL) -> Task<Void, Never> {
        Task {
            let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
            let run = await runDataDirectoryMove(to: newURL, access: .live, waiting: { _ in })
            presentMove(run, failureContext: Self.moveFailureContext, since: previousRoot)
        }
    }

    /// Change Location's Move Library Here, returning its outcome and
    /// presenting nothing. It succeeds with "Done. Data is now at <path>."
    /// (see `dataLocationDone(since:)`), ends with "Move cancelled." after
    /// Cancel, or fails with the reason nothing moved, such as an open book,
    /// books only in the cloud, or a destination that is not empty or that
    /// changed while the data was copied (see `moveOutcome`).
    /// - Parameters:
    ///   - access: How the move tells which books are only in the cloud:
    ///     `live` in the app; tests pass one that pretends files are there.
    ///   - waiting: Told what the move waits for before it copies anything
    ///     (see `withStorageWorkHeld(moving:waiting:_:)`).
    func moveDataDirectoryReturningOutcome(
        to newURL: URL,
        access: MaintenanceFileAccess = .live,
        waiting: (StorageWork?) async -> Void = { _ in }
    ) async -> OperationOutcome {
        let previousRoot = DataDirectoryLocation(TextMouthPaths.root)
        let run = await runDataDirectoryMove(to: newURL, access: access, waiting: waiting)
        return moveOutcome(run, failureContext: Self.moveFailureContext, since: previousRoot)
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
    /// or the error that stopped the move. Either way config.json then names
    /// the directory in use, as launch reads it
    /// (`ConfigService.AppConfig.currentDataDirectoryPath`).
    private func runDataDirectoryMove(
        to newURL: URL,
        access: MaintenanceFileAccess,
        waiting: (StorageWork?) async -> Void
    ) async -> Result<LegacyMigrationReport?, Error> {
        do {
            try ensureLibraryIndexIsReadable()
            let move = DataDirectoryMoveRequest(destination: newURL, access: access)
            try await withStorageWorkHeld(moving: move, waiting: waiting) {
                configService.config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
                configService.saveToDisk()
                save()
            }
            return .success(nil)
        } catch {
            configService.config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
            configService.saveToDisk()
            return .failure(error)
        }
    }

    /// Runs a data-directory operation with no other storage work under way
    /// (TODO S04): first, when `move` asks for one, the move of the data
    /// directory, then `body`, and returns what `body` returns.
    ///
    /// A move is refused at once while any book is open, naming the open
    /// books (FR02). New imports, text extractions, and book analyses are
    /// then held back, until `body` is done. A move shows its progress from
    /// here on (`dataDirectoryMove`): every Library window's sheet, which
    /// keeps the library from changing meanwhile, and Storage settings. Next
    /// the operation waits for the storage work under way, telling the
    /// move's progress and `waiting` each kind it waits for, an import
    /// first, and `waiting` nil once it waits for nothing more. The writes
    /// still queued are then made, in the data directory about to be
    /// copied, so the copy holds them and none is written after the
    /// publication. The move copies and publishes off the main actor
    /// (`copyAndPublish`). The held work goes on once `body` returns or
    /// throws, under whichever generation is current then.
    ///
    /// Only one move runs at a time: another throws
    /// `DataDirectoryMigrationError.moveInProgress`.
    private func withStorageWorkHeld<Value>(
        moving move: DataDirectoryMoveRequest?,
        waiting: (StorageWork?) async -> Void,
        _ body: () throws -> Value
    ) async throws -> Value {
        if move != nil, let refusal = openBooksRefusal {
            throw refusal
        }
        guard let hold = StorageBoundary.shared.holdWork() else {
            throw DataDirectoryMigrationError.moveInProgress
        }
        defer { hold.release() }
        let progress = move.map { DataDirectoryMoveProgress(destination: $0.destination, isResetToDefault: $0.isResetToDefault) }
        if let progress {
            progress.begin()
            dataDirectoryMove = progress
        }
        // However the move ends, its progress goes, and whatever waited for
        // its end, such as a request to quit, goes on.
        defer {
            if let progress {
                dataDirectoryMove = nil
                progress.end()
            }
        }
        var waited = false
        await hold.waitForWorkUnderWay { work in
            waited = true
            DiagnosticLog.event(.storage, "DATA_DIRECTORY_MOVE: \(work.waitingMessage)")
            progress?.wait(for: work)
            await waiting(work)
        }
        if waited {
            await waiting(nil)
        }
        LibraryPersistenceService.flushPendingSave()
        TextMouthPaths.flushLogs()
        if let move, let progress {
            try await copyAndPublish(move, showing: progress)
        }
        return try body()
    }

    /// Copies the data directory to `move`'s destination and publishes the
    /// copy (`TextMouthPaths.moveDataDirectory`) off the main actor, its
    /// progress shown in `progress`, whose Cancel stops it (FR02). Then the
    /// library takes its books' places there, and so do the books held by
    /// the questions imports are waiting to ask: a duplicate's new copy and
    /// a ZIP archive's books, published before the move, are answered about
    /// in the new data directory (TODO S04).
    ///
    /// Before copying it stops when Cancel was pressed while it waited, and
    /// refuses while any book has files only in the cloud, which the copy
    /// would have to download first: counted off the main thread with
    /// dataless files left there.
    ///
    /// The library is taken as it is now, after the wait, and nothing should
    /// change it until the copy is published: every Library window shows the
    /// move's sheet, no book is open, and storage work is held. A change made
    /// anyway is kept (`library(afterMoving:from:current:)`).
    private func copyAndPublish(_ move: DataDirectoryMoveRequest, showing progress: DataDirectoryMoveProgress) async throws {
        try progress.checkCancellation()
        progress.beginPreparing()
        let books = library.books
        let root = TextMouthPaths.root
        let access = move.access
        let notDownloaded = await OffMainWork.run {
            Self.countBooksOnlyInCloud(books, in: root, access: access)
        }
        guard notDownloaded == 0 else {
            let count = CountWording.phrase(notDownloaded, singular: "book is", plural: "books are")
            DiagnosticLog.event(.storage, "DATA_DIRECTORY_MOVE: refused, since \(count) only in the cloud")
            throw DataDirectoryMoveRefusal.booksNotDownloaded(notDownloaded)
        }
        try progress.checkCancellation()

        let snapshot = library
        let destination = move.destination
        // An observer bound around the move, as a test binds one, hears the
        // copy too.
        let observer = progress.copyObserver(followedBy: DataDirectoryMigrator.copyObserver)
        progress.beginCopying()
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_MOVE: copying the library to \(DataDirectoryPaths.shortName(of: destination))")
        let migrated: Library
        do {
            migrated = try await OffMainWork.runThrowing {
                try DataDirectoryMigrator.$copyObserver.withValue(observer) {
                    var moved = snapshot
                    try TextMouthPaths.moveDataDirectory(to: destination, library: &moved)
                    return moved
                }
            }
        } catch DataDirectoryMigrationError.cancelled {
            DiagnosticLog.event(.storage, "DATA_DIRECTORY_MOVE: cancelled; the partial copy was deleted")
            throw DataDirectoryMigrationError.cancelled
        }
        if progress.isCancelRequested {
            // Cancel came once the last item was copied.
            VoiceOverAnnouncer.announce(DataDirectoryMoveWording.finishedDespiteCancelSentence)
        }
        library = Self.library(afterMoving: migrated, from: snapshot, current: library)
        importDecisions.mapBooks(StorageBoundary.shared.rebasedToCurrent)
    }

    /// The library to hold once a move has published `migrated`, which it
    /// made from `snapshot`: `migrated`, unless the library changed while it
    /// was copied, which nothing should do; then the library as it is now,
    /// with its books' paths moved into the new data directory as the
    /// copy's were, so no change is lost, and a log line saying so.
    private static func library(afterMoving migrated: Library, from snapshot: Library, current: Library) -> Library {
        let unchanged = current.books == snapshot.books
            && current.folders == snapshot.folders
            && current.folderSortSettings == snapshot.folderSortSettings
        guard !unchanged else { return migrated }
        var kept = current
        let moved = StorageBoundary.shared.rebaseToCurrent(&kept)
        DiagnosticLog.event(
            .storage,
            "DATA_DIRECTORY_MOVE: the library changed while it was copied; kept the change, "
                + "\(CountWording.phrase(moved, singular: "book path", plural: "book paths")) moved"
        )
        return kept
    }

    /// Why the data directory can't move now because books are open in
    /// readers, naming them; nil when none is. A reader reads and saves its
    /// book in the data directory, which must not change while it is copied
    /// (FR02). Storage settings ask before offering a move.
    var openBooksRefusal: DataDirectoryMoveRefusal? {
        guard !openBookIDs.isEmpty else { return nil }
        let titles = library.books.filter { openBookIDs.contains($0.id) }.map(\.title).sorted()
        return .booksOpen(titles)
    }

    /// How many of `books` have files only in the cloud inside the data
    /// directory at `root`, which copying it would download first (FR02):
    /// each book's package, or its own file for an old book without one,
    /// checked with dataless files left in the cloud, reading nothing
    /// (`MaintenanceFileAccess.itemInCloud`). A book whose files lie
    /// outside the data directory is not copied, so it is not counted.
    nonisolated static func countBooksOnlyInCloud(_ books: [Book], in root: URL, access: MaintenanceFileAccess) -> Int {
        books.filter { book in
            let files = BookPackage(book).url
            return MaintenanceFileAccess.isItem(files, inside: root) && access.itemInCloud(files) != nil
        }.count
    }

    /// Reports a move started outside Storage settings, by a location
    /// config.json names (FR02): VoiceOver hears that it is done, or that it
    /// was cancelled; a failure, and any legacy books that could not move
    /// into packages, are explained through the library's alerts.
    private func presentMove(
        _ run: Result<LegacyMigrationReport?, Error>,
        failureContext: String,
        since previousRoot: DataDirectoryLocation
    ) {
        switch run {
        case .failure(let error) where Self.isCancellation(error):
            VoiceOverAnnouncer.announce(DataDirectoryMoveWording.cancelled(stillAt: DataDirectoryLocation(TextMouthPaths.root)))
        case .success:
            VoiceOverAnnouncer.announce(Self.dataLocationDone(since: previousRoot))
            presentThroughAlerts(run, failureContext: failureContext)
        case .failure:
            presentThroughAlerts(run, failureContext: failureContext)
        }
    }

    /// The outcome of a move for the workflow that started it: as any
    /// maintenance run's (`maintenanceOutcome`), except that a cancelled
    /// move ends with "Move cancelled. The library is still at <path>.",
    /// reported as no failure: nothing changed, as was asked.
    private func moveOutcome(
        _ run: Result<LegacyMigrationReport?, Error>,
        failureContext: String,
        since previousRoot: DataDirectoryLocation
    ) -> OperationOutcome {
        if case .failure(let error) = run, Self.isCancellation(error) {
            return .success(DataDirectoryMoveWording.cancelled(stillAt: DataDirectoryLocation(TextMouthPaths.root)))
        }
        return Self.maintenanceOutcome(run, failureContext: failureContext, done: Self.dataLocationDone(since: previousRoot))
    }

    /// Whether `error` is a move's Cancel.
    private static func isCancellation(_ error: Error) -> Bool {
        if case DataDirectoryMigrationError.cancelled = error {
            return true
        }
        return false
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

    // MARK: - Using Another Library (FR02)

    /// Words that begin each Use This Library failure, before the reason.
    private static let switchFailureContext = "Failed to switch libraries"

    /// Use This Library, and Start New Library while the library isn't
    /// available (FR02): makes the library in `folder` the one TextMouth
    /// uses, as it is, with nothing copied, and opens TextMouth again so its
    /// startup runs on that library. Returns the outcome, presenting
    /// nothing; on success TextMouth is quitting.
    ///
    /// Unsaved changes are written first
    /// (`LibraryPersistenceService.flushPendingSave`). While the library is
    /// available, a change that still can't be saved, as the failure center
    /// lists it, refuses the switch, saying which: it could still be saved
    /// with Retry Saving. While the library isn't available, such changes
    /// can't be saved anywhere; the confirmation said that switching loses
    /// them, so they are given up once the new TextMouth has opened.
    ///
    /// `TextMouthPaths.setCustomRoot` then records the location, a bookmark
    /// of it, and the identity of the library in it; the default location is
    /// recorded as no custom location at all. Nothing is created or changed
    /// in either folder, and nothing at a location that is missing.
    /// - Parameter relauncher: How TextMouth opens again: the app's own
    ///   unless a test passes one that records the request.
    func useLibraryReturningOutcome(
        at folder: URL,
        relaunching relauncher: TextMouthRelauncher = .live
    ) async -> OperationOutcome {
        guard dataDirectoryMove == nil else {
            return .failure(Self.switchFailureContext, DataDirectoryMigrationError.moveInProgress)
        }
        LibraryPersistenceService.flushPendingSave()
        let unsaved = failureCenter.unsavedFailures()
        if dataDirectoryUnavailability == nil, !unsaved.isEmpty {
            let reasons = PersistenceBannerRow.rows(for: unsaved).map(\.text)
            let message = ["\(Self.switchFailureContext): Some changes are not saved, and switching libraries would lose them."]
                + reasons + ["Choose Retry Saving, then try again."]
            return .failure(message.joined(separator: " "))
        }

        TextMouthPaths.setCustomRoot(
            TextMouthPaths.isDefaultLocation(folder) ? nil : folder,
            in: dataDirectoryEnvironment.preferences
        )
        DiagnosticLog.event(
            .storage,
            "DATA_DIRECTORY_SWITCH: TextMouth opens the library in \(DataDirectoryPaths.shortName(of: folder)) from now on"
        )
        do {
            try await relauncher.openNewInstance()
        } catch {
            DiagnosticLog.event(.storage, "DATA_DIRECTORY_SWITCH: TextMouth couldn't open again: \(error.localizedDescription)")
            return .failure(
                "TextMouth will open the library in \(folder.path) the next time it opens, but it couldn't open again "
                    + "by itself: \(error.localizedDescription) Quit TextMouth and open it again."
            )
        }
        // The changes a library that isn't available couldn't take are given
        // up, as the confirmation said, so quitting doesn't ask about them.
        for failure in unsaved {
            failureCenter.withdraw(failure.key)
        }
        relauncher.quit()
        return .success("Opening the library in \(folder.path)…")
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

// MARK: - Opening TextMouth Again (FR02)

/// How TextMouth opens again, so its startup runs on the library the
/// preferences name now (FR02): a new instance of its bundle opens through
/// NSWorkspace, and this one then quits, through the usual request to quit.
/// Use This Library takes one; tests pass their own, so nothing opens or
/// quits.
struct TextMouthRelauncher {
    /// Opens a new instance of TextMouth, returning once it has launched.
    var openNewInstance: @MainActor () async throws -> Void
    /// Quits this instance.
    var quit: @MainActor () -> Void

    /// The app's way. A process hosting tests never opens again or quits:
    /// it logs the request instead, should a test forget to pass its own.
    @MainActor static var live: TextMouthRelauncher {
        guard !TextMouthRuntime.current.isHostedTest else {
            return TextMouthRelauncher(
                openNewInstance: {
                    DiagnosticLog.event(.storage, "DATA_DIRECTORY_SWITCH: a process hosting tests does not open again")
                },
                quit: {}
            )
        }
        return TextMouthRelauncher(
            openNewInstance: {
                let configuration = NSWorkspace.OpenConfiguration()
                // A second instance, which starts while this one quits.
                configuration.createsNewApplicationInstance = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}
