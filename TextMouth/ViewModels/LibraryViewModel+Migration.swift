import SwiftUI
import Darwin
import os

/// Long parser batches can leave gigabytes of freed Swift/Foundation storage
/// resident or compressed inside malloc's per-process regions. Give malloc a
/// pressure-relief opportunity after each book so a library-wide migration has
/// the memory profile of its active books, rather than the sum of every book.
/// The launch's passes that parse books one after another call it: the text
/// cache batch, and the pass that reads books for their places' words (T06).
func releaseBatchParserMemory() {
    _ = malloc_zone_pressure_relief(nil, 0)
}

/// Extension for data migration, directory management, content cache extraction,
/// statistics calculation, and time estimation.
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
        // The checkpoint journal, read once, before the repair's save clears
        // it: the library's own books and the feed items both take their
        // newer positions from it (PERF15, FR11).
        let journaled = LibraryPersistenceService.booksWithCheckpointsAhead()

        // Every repair below reconciles the index with the disk and then saves
        // the index. While the index cannot be read there is nothing to
        // reconcile, and saving would replace the evidence the user may still
        // recover, so show a library rebuilt from disk and save nothing. The
        // feed items join it all the same: their indexes are not library.json.
        guard indexRecovery == nil else {
            buildProvisionalLibrary()
            joinFeedItems(journaled: journaled, access: access, skips: nil)
            return
        }

        let skips = CloudSkips(.startupRepair)
        defer { skips.log() }
        var needsSave = false

        // Whether the library began the repair with nothing in it, as when
        // library.json was missing or held an empty library: no book of its
        // own, no folder, and no row kept unshown (V03). Read before any
        // repair below changes the library: it decides which folders the
        // folder rows' adoption counts.
        let beganEmpty = library.libraryBookCount == 0 && library.folders.isEmpty && library.unreadableRows.isEmpty

        // A feed item's row meets none of the repairs below, which reconcile
        // the library's own books with the Library folder: its package is in
        // its feed's folder (FR11). Every feed item's row waits on the shelf
        // until the repair is done, when those whose files are here join the
        // books again.
        library.shelveFeedItems()

        // A book taken out with Remove from Library Only stays out, even when
        // this index was saved before the removal. It goes first, so no
        // repair below touches its package.
        if !removeRetiredBooks(access: access, skips: skips).isEmpty { needsSave = true }

        // A crash can leave reading checkpoints that reached their books'
        // records but not this index (PERF15). Their newer positions come
        // next, so the repairs below and the save after them keep them.
        if adoptNewerRecordedPositions(journaled: journaled, access: access, skips: skips) { needsSave = true }

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
        // This recovers books left behind by interrupted imports or crashes,
        // and discards the duplicates' copies whose questions went unanswered.
        let adopted = adoptOrphanedPackages(access: access, skips: skips)
        if adopted > 0 { needsSave = true }

        // Every folder a book lies in gets a row, and, in a library that
        // began with nothing, every folder on disk too (`adoptFolderRows`).
        if adoptFolderRows(includingFoldersOnDisk: beganEmpty) { needsSave = true }

        // The feed items whose files are here join the books, before anything
        // can edit the reading list or open a reader (FR11).
        if joinFeedItems(journaled: journaled, access: access, skips: skips) { needsSave = true }

        if needsSave {
            save()
        }

        // Once, after the whole repair, so one alert covers every book.
        showLegacyMigrationIssues(migration)
    }

    /// Takes the books Remove from Library Only retired out of the library,
    /// and off the reading list (FR09), as
    /// `RemovedFromLibraryMarker.removeRetiredBooks(from:sparing:)` does,
    /// and returns them. A book whose removal marker is in the cloud keeps
    /// its row (FR02): the marker cannot be read without downloading it, and
    /// a marker that cannot be read counts as retiring its book. The book is
    /// counted in `skips`, and taken out once its marker is on this Mac.
    private func removeRetiredBooks(access: MaintenanceFileAccess, skips: CloudSkips) -> [Book] {
        let held = library.books.filter { book in
            !book.tmbDirectoryName.isEmpty
                && access.isInCloud(TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory))
        }
        held.forEach(skips.record)
        return RemovedFromLibraryMarker.removeRetiredBooks(from: &library, sparing: Set(held.map(\.id)))
    }

    /// Gives each book that the checkpoint journal (`journaled`) names the
    /// reading position its package record holds, when that is newer than
    /// its row's (PERF15): a reading checkpoint writes the record at once but
    /// library.json within minutes, so a crash in between leaves the record
    /// ahead (`LibraryPersistenceService.saveReadingCheckpoint`). Returns
    /// whether any row changed.
    private func adoptNewerRecordedPositions(journaled: Set<UUID>, access: MaintenanceFileAccess, skips: CloudSkips) -> Bool {
        guard !journaled.isEmpty else { return false }
        var books = library.books
        let adopted = Self.adoptNewerRecordedPositions(in: &books, journaled: journaled, access: access, skips: skips)
        guard adopted > 0 else { return false }
        library.books = books
        let phrase = CountWording.phrase(adopted, singular: "book", plural: "books")
        DiagnosticLog.event(
            .storage,
            "LIBRARY_INDEX: took the reading positions of \(phrase) from their records, "
                + "which held checkpoints saved after the index"
        )
        return true
    }

    /// Gives each of `rows` that `journaled` names the reading position its
    /// package record holds, when that is newer than the row's, and the
    /// record's last-opened date with it when that is newer too, as a
    /// checkpoint sets both. Returns how many rows changed. The library's
    /// own books and the feed items take their checkpoints this way alike.
    ///
    /// Only bookInfo.json is read, with dataless files left in the cloud. A
    /// row whose package or record is in the cloud stays as it is and is
    /// counted in `skips`; a record that is missing, cannot be read, or
    /// names another book changes nothing.
    private static func adoptNewerRecordedPositions(
        in rows: inout [Book],
        journaled: Set<UUID>,
        access: MaintenanceFileAccess,
        skips: CloudSkips?
    ) -> Int {
        var adopted = 0
        for index in rows.indices where journaled.contains(rows[index].id) {
            let book = rows[index]
            guard !book.tmbDirectoryName.isEmpty else { continue }
            let package = book.tmbDirectory
            let recordURL = TextMouthPaths.bookInfoPath(in: package)
            guard !access.isInCloud(package), !access.isInCloud(recordURL) else {
                skips?.record(book)
                continue
            }
            let record: BookInfo
            do {
                record = try access.read(recordURL) { try StoredBookRecord.read(from: package) }.info
            } catch where DatalessFiles.isDownloadRefusal(error) {
                skips?.record(book)
                continue
            } catch {
                continue
            }
            guard record.metadata.bookID == book.id,
                  let recorded = record.state.readingPosition,
                  recorded.lastUpdated > (book.readingPosition?.lastUpdated ?? .distantPast) else { continue }
            rows[index].readingPosition = recorded
            if let opened = record.metadata.lastOpened, opened > (book.lastOpened ?? .distantPast) {
                rows[index].lastOpened = opened
            }
            adopted += 1
        }
        return adopted
    }

    /// The feed's own repair, at the end of the startup repair (FR11):
    /// every feed item's row on the shelf whose file is on this Mac, or in
    /// the cloud, joins the library model's books, so the reader, positions,
    /// bookmarks, settings, and the reading list find it as they find any
    /// book; a row whose file is gone stays on the shelf, where nothing lists
    /// it and its feed's index keeps it. A checkpoint the journal names that
    /// is newer than a row comes from its record, as a book's does
    /// (`adoptNewerRecordedPositions(in:journaled:access:skips:)`), for every
    /// row on the shelf, the one that stays as well as the one that joins: a
    /// kept row's place is where downloading the item again opens it.
    ///
    /// A book of the library's own sharing a joining row's ID, as library.json
    /// still lists a download whose first-launch move had moved its package
    /// when TextMouth stopped, gives way to the feed item's row, whose
    /// package is the one here, and its record is written again where it is
    /// now, finishing that move. A shelf row sharing the ID of a book of the
    /// library's own that stays is dropped, the book standing, so no ID is
    /// ever both. Returns whether any row changed, which needs a save.
    @discardableResult
    func joinFeedItems(journaled: Set<UUID>, access: MaintenanceFileAccess = .live, skips: CloudSkips? = nil) -> Bool {
        guard !library.feedShelf.isEmpty else { return false }
        var joined = library
        var shelved = joined.feedShelf.takeRows { _ in true }
        let adopted = Self.adoptNewerRecordedPositions(in: &shelved, journaled: journaled, access: access, skips: skips)
        var rows: [Book] = []
        for row in shelved {
            if access.presence(of: row.bookFileURL) != .absent {
                rows.append(row)
            } else {
                joined.feedShelf.put(row)
            }
        }
        if adopted > 0 {
            DiagnosticLog.event(
                .storage,
                "FEED_INDEX: took the reading positions of "
                    + "\(CountWording.phrase(adopted, singular: "feed item", plural: "feed items")) from their records, "
                    + "which held checkpoints saved after their feeds' indexes"
            )
        }
        let joiningIDs = Set(rows.map(\.id))
        let replacedIDs = Set(joined.books.map(\.id)).intersection(joiningIDs)
        joined.books.removeAll { joiningIDs.contains($0.id) }
        joined.books.append(contentsOf: rows)
        let bookIDs = Set(joined.books.map(\.id))
        let shadowed = joined.feedShelf.takeRows { bookIDs.contains($0.id) }.count
        if replacedIDs.count + shadowed > 0 {
            DiagnosticLog.event(
                .storage,
                "FEED_INDEX: \(replacedIDs.count) row(s) of library.json gave way to the feed items holding their packages, "
                    + "and \(shadowed) feed item row(s) to the library's books holding theirs"
            )
        }
        library = joined
        for row in rows where replacedIDs.contains(row.id) {
            LibraryPersistenceService.saveBookInfo(for: row)
        }
        return adopted + replacedIDs.count + shadowed > 0
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
        // After the adoption's alert, if it raised one: both are heard.
        presentLaunchNotice(titled: nil, summary)
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

    /// Gives a row to every folder a book lies in, with its ancestors, and,
    /// when `includingFoldersOnDisk`, to every folder directory in the
    /// Library folder as well (`FileImportService.adoptLibraryFolders`), then
    /// logs how many rows that added and why. Returns whether it added any.
    ///
    /// The startup repair counts the folders on disk only for a library that
    /// began with nothing, its library.json missing or empty, as recovery's
    /// provisional library does: the books just adopted from their packages
    /// keep the folders they lie in, which would otherwise show in All Items
    /// and never in the Folders view, and the empty folders would be lost for
    /// good once the index is saved. Any other library's index records the
    /// user's folders, so only the folders its books name are added, and a
    /// directory with no row, such as one a deleted folder left behind,
    /// stays out.
    ///
    /// It runs at every launch, since a race can leave a book in a folder
    /// with no row: an import into a folder renamed or deleted while the
    /// import ran, or a move into such a folder, which is not refused. This
    /// repair is what mends such a book.
    private func adoptFolderRows(includingFoldersOnDisk: Bool) -> Bool {
        // A copy, so a launch that adds no row leaves the library, and the
        // lists derived from it, untouched.
        var repaired = library
        let added = FileImportService.adoptLibraryFolders(
            library: &repaired,
            includingFoldersOnDisk: includingFoldersOnDisk
        )
        guard added > 0 else { return false }
        library = repaired
        let rows = CountWording.phrase(added, singular: "folder row", plural: "folder rows")
        let source = includingFoldersOnDisk
            ? "the folders on disk and the folders books are in, since the library began with no books or folders"
            : "folders books are in that had none"
        logFolderRepair("added \(rows) for \(source)")
        return true
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
                // Once the pass ends, however it ends. Queued behind every
                // summary the pass sent the main queue: the summaries still
                // waiting reach the library, then the completion runs.
                skips.log()
                DispatchQueue.main.async { [weak self] in
                    self?.analysisSummaries.flush()
                    completion?()
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
                        // The book's record holds its analysis now; its row
                        // waits to change with others' (TODO PERF12).
                        DispatchQueue.main.async {
                            self.analysisSummaries.add(summary)
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
        // A book whose text is being edited in the user's editor is left to
        // its edit session (FR05): a load here would read an edit not taken
        // as it is, when its rebuild is refused, and commit its analysis.
        // Its analysis is committed as its edit is taken, or as it opens.
        guard !BookTextEditSessions.shared.isEditing(book.id) else { return nil }
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
                    cacheFormatVersion: analysis.cacheFormatVersion,
                    movedPlaces: analysis.movedPlaces
                ) else { return nil }
                return ContentAnalysisSummary(committed: committed, movedPlaces: analysis.movedPlaces)
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            skips.record(book)
            return nil
        } catch {
            // Silently skip books that fail to parse — they'll be parsed when opened
            return nil
        }
    }

    /// Bring every book's row and text up to date, each pass on a
    /// background queue: first, once for each library, the titles and
    /// authors edited by hand before FR17 kept in their books' manifests,
    /// queued at once on the manifest sessions' queue, so it comes before
    /// every look at a manifest, a reader's included
    /// (`keepHandEditedTitlesInManifestsOnce`); beside them all, once for
    /// each library, its Ogg audio converted to AAC, a book at a time
    /// (`convertOggBooksOnce`, B06); then the moves of places a
    /// stop left undone, before any pass reads a book's places or text
    /// (`finishLeftoverPlaceMoves(access:then:)`, T06), then the edits of
    /// audiobooks' manifests made while TextMouth was closed
    /// (`takeOutsideManifestEdits(access:editor:then:)`, FR18), then the metadata
    /// refresh, which reads a book's file again when an older reader read it
    /// and takes seconds (`refreshOutdatedMetadata(access:then:)`), then the words of the
    /// places saved before anchors, from each book's text as it reads before
    /// any is rebuilt (`captureMissingTextAnchors(access:then:)`, T06), then
    /// the text caches, then the statistics, which can use them.
    /// - Parameters:
    ///   - access: How the passes reach the books' files (FR02).
    ///   - completion: Called on the main actor once the last pass has ended.
    func updateContentCachesAndStatistics(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        keepHandEditedTitlesInManifestsOnce(access: access)
        // Ogg audio is converted to AAC beside the other passes, a book at a
        // time, since a large book takes minutes (B06).
        convertOggBooksOnce(access: access)
        finishLeftoverPlaceMoves(access: access) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            self.takeOutsideManifestEdits(access: access) { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.refreshOutdatedMetadata(access: access) { [weak self] in
                    guard let self else {
                        completion?()
                        return
                    }
                    self.captureMissingTextAnchors(access: access) { [weak self] _ in
                        guard let self else {
                            completion?()
                            return
                        }
                        self.extractMissingContentCaches(access: access) { [weak self] in
                            guard let self else {
                                completion?()
                                return
                            }
                            self.calculateMissingBookStats(access: access, then: completion)
                        }
                    }
                }
            }
        }
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
    /// A book whose text is being read again in another encoding is left to
    /// that re-read (`readingAgainRefusal(of:)`, encodingchoice): the content.md
    /// it writes before its record would look like an edit saved while
    /// TextMouth was closed, or a stale cache; no re-read begins while the
    /// batch runs (`textEncodingChangeRefusal(of:)`).
    /// - Parameter access: How the batch reaches the books' files (FR02):
    ///   `live` in the app; tests pass one that pretends files are in the
    ///   cloud.
    func extractMissingContentCaches(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // A second scene/action must not launch the same library migration again.
        guard !isExtracting else { return }
        // Finding the books makes several stat calls for every text book,
        // a fortieth of a second at launch for the user's library, so it
        // runs off the main thread (PERF13), and the batch starts once it is
        // done, unless another one has started meanwhile.
        let books = library.books
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let booksNeedingCache = Self.booksNeedingCacheUpdate(books, access: access)
            // The hop back takes its own weak reference, rather than sharing
            // the variable this closure captured with code that runs on
            // another thread.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isExtracting else { return }
                let notReadAgain = booksNeedingCache.filter { self.readingAgainRefusal(of: $0.id) == nil }
                self.rebuildTextCaches(books: notReadAgain, force: false, access: access) { _, _ in
                    // The pass has looked at every book: a copy of an edit's
                    // old text that a quit left, for a book with nothing
                    // saved since, is no use, except one whose book's
                    // content.md is only in the cloud, which a later launch
                    // still checks with. `completion` hears of it only once
                    // the others are gone.
                    Self.sweepLeftoverEditTexts(of: books, access: access) {
                        completion?()
                    }
                }
            }
        }
    }

    /// The text books of `books` whose caches the startup batch makes or
    /// rebuilds: those with no cache, an outdated one, a source or cache of
    /// another size than when the cache was written, or a cache of the same
    /// size with another date, which may hold an edit saved while
    /// TextMouth was closed (FR05). Run on any thread.
    ///
    /// The checks stat every book's files with dataless files left in the
    /// cloud (FR02): one that would download a folder's listing fails at
    /// once instead of waiting on the network, and the book it could not
    /// check is listed, for the batch to find its files in the cloud.
    nonisolated static func booksNeedingCacheUpdate(_ books: [Book], access: MaintenanceFileAccess) -> [Book] {
        DatalessFiles.withoutDownloading {
            books.filter { book in
                guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return false }
                // Needs cache if missing or if the stored version is outdated
                if !MarkdownCacheService.cacheExists(for: book) { return true }
                if MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion) { return true }
                // Its format gained pages since content.md was written, and
                // the launch re-read is switched on (PG09).
                if PageReaderVersions.isDueForPages(book) { return true }
                return hasResizedTextCacheFile(book, isDataless: access.isDataless)
                    || hasRedatedTextCache(book, isDataless: access.isDataless)
            }
        }
    }

    /// Whether `book`'s source or content.md now has another size than the
    /// fingerprints its library row recorded when the cache was written
    /// (TODO T07): a stale cache, found by two stat calls, so asking it of
    /// every book at startup reads no file. The batch then checks the
    /// fingerprints its package recorded (`completedTextCacheIndex`), which
    /// reports the stale cache and has it rebuilt like an outdated one; a
    /// package newer than the row is recovered instead. A source that only
    /// has a new date is left to the next open, which reads it for its
    /// digest and keeps a cache that did not change; a content.md that only
    /// has a new date is found by `hasRedatedTextCache(_:isDataless:)`. A
    /// book without fingerprints has nothing to compare.
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

    /// Whether `book`'s content.md has the size its library row recorded
    /// when the cache was written but another modification date: a file
    /// written again in place, which may hold an edit of the same length
    /// saved while TextMouth was closed (FR05). The batch reads only such a
    /// content.md for its digest, which tells an edit, taken as the book's
    /// text when it parses, from a file only touched, whose new date the
    /// row then records so that the next launch reads nothing. A dataless
    /// content.md, and a book without fingerprints, have no date to judge.
    /// - Parameter isDataless: Whether a file is dataless: the maintenance
    ///   access's check.
    nonisolated static func hasRedatedTextCache(
        _ book: Book,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Bool {
        guard let recorded = book.textCacheFingerprint else { return false }
        let cache = MarkdownCacheService.cacheURL(for: book)
        if case .redated = recorded.cache.comparison(with: FileStamp(of: cache), isDataless: isDataless(cache)) {
            return true
        }
        return false
    }

    /// Re-extract content.md caches for all non-audio books.
    /// Called from the "Redo Text Extraction" button in Storage Settings.
    /// - Parameters:
    ///   - access: How the pass reaches the books' files (FR02).
    ///   - completion: Told on the main actor, once every book is done, what
    ///     the pass did (`textReextractionOutcome(skippedInCloud:heldByEdits:)`).
    /// - Returns: Whether the pass started: false while another text
    ///   extraction runs, or while a book's text is being read again in
    ///   another encoding (`readingAgainRefusal(of:)`, encodingchoice), when
    ///   nothing is done and `completion` is not told.
    @discardableResult
    func redoAllTextExtraction(
        access: MaintenanceFileAccess = .live,
        completion: (@MainActor @Sendable (OperationOutcome) -> Void)? = nil
    ) -> Bool {
        guard !isExtracting, readingAgainRefusal() == nil else { return false }
        let booksToExtract = library.books.filter { book in
            !book.format.isAudio && !book.tmbDirectoryName.isEmpty
        }
        rebuildTextCaches(books: booksToExtract, force: true, access: access) { skippedInCloud, heldByEdits in
            completion?(Self.textReextractionOutcome(skippedInCloud: skippedInCloud, heldByEdits: heldByEdits))
        }
        return true
    }

    /// Redo Text Extraction for Storage settings, returning once every book
    /// is done with what the pass did, which Storage settings' status line
    /// says and VoiceOver hears; why it did not start while a book's text is
    /// being read again in another encoding, which it says the same way;
    /// nil when another text extraction runs and nothing was started.
    /// - Parameter access: How the pass reaches the books' files (FR02).
    func redoAllTextExtractionReturningOutcome(access: MaintenanceFileAccess = .live) async -> OperationOutcome? {
        await withCheckedContinuation { continuation in
            let started = redoAllTextExtraction(access: access) { outcome in
                continuation.resume(returning: outcome)
            }
            if !started {
                continuation.resume(returning: readingAgainRefusal().map(OperationOutcome.failure))
            }
        }
    }

    /// What Redo Text Extraction says once it is done: "Done.", and, when it
    /// left books as they were because their files are only in the cloud
    /// (FR02), how many, as in "Done. 12 books in the cloud were skipped."
    /// Before, only its MAINTENANCE_SKIPPED_IN_CLOUD log line told. Books it
    /// left because their content.md holds an edit TextMouth can't take yet
    /// (FR05), which a rebuild would replace, are counted in a sentence of
    /// their own: "Done. 1 book whose edited text can't be used yet was
    /// skipped." Before, only their TEXT_EDIT_HELD log lines told.
    nonisolated static func textReextractionOutcome(skippedInCloud: Int, heldByEdits: Int = 0) -> OperationOutcome {
        var sentences: [String] = []
        if skippedInCloud > 0 {
            let books = CountWording.phrase(skippedInCloud, singular: "book in the cloud was", plural: "books in the cloud were")
            sentences.append("\(books) skipped.")
        }
        if heldByEdits > 0 {
            let books = CountWording.phrase(
                heldByEdits,
                singular: "book whose edited text can't be used yet was",
                plural: "books whose edited text can't be used yet were"
            )
            sentences.append("\(books) skipped.")
        }
        guard !sentences.isEmpty else { return .success(nil) }
        return .success((["Done."] + sentences).joined(separator: " "))
    }

    /// Share automatic and manual extraction, releasing large parser results per
    /// book and committing each book's analysis to its package record before
    /// advancing progress. Bounded utility workers keep memory and CPU
    /// available for reading. The finished books' summaries reach the library
    /// rows together (`analysisSummaries`, TODO PERF12), and the progress has
    /// an object of its own (`textExtraction`), so a batch no longer
    /// re-renders every Library window's list once per book.
    /// `access` is how each book's files are reached (FR02): a book whose
    /// files are in the cloud counts toward the progress, is left as it is,
    /// and is counted in the batch's one `MAINTENANCE_SKIPPED_IN_CLOUD` line.
    /// A book whose rebuild was refused over an edit not taken (FR05) is
    /// left as it is and counted. `completion` is told, on the main actor
    /// once every book is done and every summary has reached the library,
    /// how many books the batch left in the cloud, and how many over edits.
    private func rebuildTextCaches(
        books: [Book],
        force: Bool,
        access: MaintenanceFileAccess,
        completion: (@MainActor @Sendable (_ skippedInCloud: Int, _ heldByEdits: Int) -> Void)? = nil
    ) {
        guard !books.isEmpty else {
            completion?(0, 0)
            return
        }

        textExtraction.begin(force ? "Re-extracting text" : "Updating text cache", total: books.count)

        let updateProgress: @MainActor @Sendable (TextCacheUpdate) -> Void = { [weak self] update in
            guard let self else { return }
            self.applyTextCacheUpdate(update)
            self.textExtraction.advance()
        }

        let skips = CloudSkips(force ? .textReextraction : .textCacheUpdate)
        let held = HeldTextEditTally()
        // The launch's batch sums up its re-read for pages (PG16); Redo Text
        // Extraction reads every book anyway.
        let pages: PageUpgradeTally? = force ? nil : PageUpgradeTally()
        // What the pass reads of each book. Redo Text Extraction writes a new
        // text cache without reading the one it replaces.
        let files: MaintainedFiles = force ? [.content, .record] : .all

        // Whether a book is open in a reader, asked from the batch's worker
        // threads (the activity, not `self`, which is main-actor state).
        let activity = audioEditActivity
        let isOpenInReader: @Sendable (UUID) -> Bool = { activity.isOpenInReader($0) }

        TextCacheUpdateQueue.run(books: Self.openBooksFirst(books, open: openBookIDs), update: { book in
            let update = autoreleasepool {
                Self.updateTextCache(
                    of: book, force: force, reading: files, access: access, skips: skips, held: held, pages: pages,
                    isOpenInReader: isOpenInReader
                )
            }
            releaseBatchParserMemory()
            DispatchQueue.main.async { updateProgress(update) }
        }, completion: { [weak self] in
            // Every worker has returned, so the tallies are complete.
            skips.log()
            pages?.log()
            let skippedInCloud = skips.count
            let heldByEdits = held.count
            // Each worker enqueues its progress before returning, so this final
            // main-queue block follows all completed-book notifications: the
            // summaries still waiting reach the library before the batch ends.
            DispatchQueue.main.async { [weak self] in
                self?.analysisSummaries.flush()
                self?.textExtraction.end()
                completion?(skippedInCloud, heldByEdits)
            }
        })
    }

    /// Gives the library `update`, what a rewrite of one book's text cache
    /// committed: a batch's (`rebuildTextCaches`), or a re-read in another
    /// encoding's (encodingchoice).
    ///
    /// A reader that has the book open shows its old text (ST01): the row
    /// takes the analysis now, as after an edit (`commitTextEdit`), so the
    /// reader's copy of the book agrees with the text it is given, which it
    /// shows in place of the old one, its cursor following its words. Any
    /// other book's summary waits to reach the library with the others
    /// (`analysisSummaries`, PERF12): the package record already holds the
    /// analysis, so a crash before the summary reaches the row loses
    /// nothing, as the next launch's batch recovers it from the record. With
    /// `atOnce`, for a book the listener is waiting on, the row takes it now
    /// whether or not a reader has the book open, once any summary waiting
    /// for it has gone first, so none lands over it afterwards.
    func applyTextCacheUpdate(_ update: TextCacheUpdate, atOnce: Bool = false) {
        guard let summary = update.summary else { return }
        let textForReader = openBookIDs.contains(summary.bookID) ? update.textForOpenReader : nil
        if atOnce {
            analysisSummaries.flush()
        }
        if textForReader != nil || atOnce {
            applyAnalysisSummaries([summary])
        } else {
            analysisSummaries.add(summary)
        }
        if let textForReader {
            bookUpdates.textReplaced(bookID: summary.bookID, with: textForReader.content, movedPlaces: textForReader.movedPlaces)
        }
    }

    /// `books` with those whose IDs are in `open` first, every open book and
    /// every other keeping its order (a stable partition). A reader restored
    /// at launch gets its book's new text in the batch's first moments (ST01),
    /// most likely before the listener plays.
    nonisolated static func openBooksFirst(_ books: [Book], open: Set<UUID>) -> [Book] {
        books.filter { open.contains($0.id) } + books.filter { !open.contains($0.id) }
    }

    /// Brings `book`'s text cache up to date on a batch's worker thread, and
    /// returns what its package now records (`TextCacheUpdate.summary`, nil
    /// when nothing new was committed), with the new text when a reader has
    /// the book open (`isOpenInReader`, ST01). `force` rebuilds the cache from the source even when an
    /// earlier run committed it, as Redo Text Extraction does.
    ///
    /// A book is left as it is, and counted in `skips`, when any of the
    /// `files` the batch reads is in the cloud (FR02). Its cache is caught up
    /// the next time its files are on this Mac, and the reader, which
    /// downloads a book before it loads it, rebuilds an outdated cache as it
    /// loads. Every read runs with dataless files left in the cloud, and a
    /// read refused because it met a dataless file leaves the book the same
    /// way: it is never logged as a failure, never rebuilds a cache, and
    /// never reaches the book's record. A book whose content.md holds an
    /// edit not taken, which the rebuild refused to replace (FR05), is left
    /// the same way and counted in `held`; its TEXT_EDIT_HELD line says why.
    /// What became of a book chosen for its pages is counted in `pages`,
    /// the launch batch's tally (nil for Redo Text Extraction).
    nonisolated private static func updateTextCache(
        of book: Book,
        force: Bool,
        reading files: MaintainedFiles,
        access: MaintenanceFileAccess,
        skips: CloudSkips,
        held: HeldTextEditTally,
        pages: PageUpgradeTally?,
        isOpenInReader: @Sendable (UUID) -> Bool
    ) -> TextCacheUpdate {
        // Only a book chosen for its pages counts toward their summary.
        let pages = PageReaderVersions.isDueForPages(book) ? pages : nil
        do {
            try access.requireOnThisMac(book, reading: files)
            return try access.read(book.bookFileURL) {
                try committedTextCache(
                    of: book, force: force, reading: files, access: access, pages: pages, isOpenInReader: isOpenInReader
                )
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            skips.record(book)
            pages?.record(.skippedInCloud)
            return .summaryOnly(nil)
        } catch is BookTextEditPending {
            held.record(book.id)
            pages?.record(.keptChanged)
            return .summaryOnly(nil)
        } catch is EditedTextKept {
            // The user's edit stands (B12); its TEXT_EDIT_KEPT line was
            // logged where it was met, and this is no failure.
            pages?.record(.keptChanged)
            return .summaryOnly(nil)
        } catch {
            MarkdownCacheService.logGenerationFailure(error, for: book)
            pages?.record(.failed)
            return .summaryOnly(nil)
        }
    }

    /// The work of `updateTextCache(of:force:reading:access:skips:held:pages:)`
    /// for a book whose `files` were on this Mac when it began: recovers the
    /// cache an earlier run committed, with the places that run moved,
    /// which its record holds and the row may lack; takes an edit of
    /// content.md saved while TextMouth was closed
    /// (`editSavedWhileClosed(of:access:)`); or writes the cache from the
    /// source and commits its analysis to the book's record. What it made
    /// of a book chosen for its pages is counted in `pages`.
    /// - Throws: why no cache could be written, including the refusal of a
    ///   read that met a file which went to the cloud meanwhile.
    nonisolated private static func committedTextCache(
        of book: Book,
        force: Bool,
        reading files: MaintainedFiles,
        access: MaintenanceFileAccess,
        pages: PageUpgradeTally?,
        isOpenInReader: @Sendable (UUID) -> Bool
    ) throws -> TextCacheUpdate {
        let currentVersion = MarkdownCacheService.currentCacheVersion
        // The copy kept of text the re-read for pages replaces, when it does.
        var replacedTextCopy: URL?
        if !force {
            if let saved = try BookContentAnalysisService.recoveredTextCache(
                for: book,
                hasher: access.hasher,
                isDataless: access.isDataless
            ) {
                // An earlier run already committed this book; repairing
                // the library summary requires no source parsing or writes.
                // The package records this index with the current version.
                var recovered = book
                recovered.applyContentAnalysis(saved.index, cacheFormatVersion: currentVersion)
                // The record owns the note of an edit taken (B12), as it
                // owns the rest of the analysis the row takes from it.
                recovered.editedText = saved.record.state.editedText
                recovered.pageReaderVersion = saved.record.state.pageReaderVersion
                // The record also holds the places that run moved, which
                // the row may have missed if TextMouth stopped before its
                // summary reached library.json; the row takes them where
                // it still holds its own places as they were.
                let record = Book(
                    record: saved.record,
                    filePath: book.filePath,
                    folderPath: book.folderPath,
                    tmbDirectoryName: book.tmbDirectoryName
                )
                return .summaryOnly(ContentAnalysisSummary(recovered: recovered, record: record))
            }
            // A book behind only in its pages is compared with its file
            // first (PG09, PG16), before an edit saved while TextMouth was
            // closed is looked for: a batch stopped between writing
            // content.md and committing its record leaves TextMouth's own
            // text there, which would otherwise be taken for the user's. An
            // edit Edit Text took is kept below, as every re-read keeps one.
            // Text an earlier page reader wrote, as its record describes it,
            // is read again without the compare (V05).
            if isBehindOnlyInPages(book), !BookTextEditSessions.holdsTakenEdit(book, access: access) {
                switch try pageUpgradeCheck(of: book, access: access) {
                case .readAgain, .stale:
                    break
                case .writtenWithPages:
                    pages?.record(.gainedPages)
                    return .summaryOnly(stampedText(of: book, access: access))
                case .changed(let bytes):
                    // Nothing records an edit of this text, and nothing can
                    // tell one made before B12 from an extraction that
                    // changed since: a copy of it is kept beside content.md,
                    // and the book is read again with its pages below. With
                    // no copy, the text is kept as it is.
                    guard let copy = PageUpgradeCopies.keep(MarkdownCacheService.cacheURL(for: book), bytes: bytes) else {
                        pages?.record(.keptChanged)
                        return .summaryOnly(keptChangedText(of: book, access: access))
                    }
                    replacedTextCopy = copy
                case .tryAgainNextLaunch:
                    pages?.record(.failed)
                    logCheckDeferred(of: book)
                    return .summaryOnly(nil)
                case let .unreadable(why, missingFile):
                    pages?.record(missingFile ? .skippedMissing : .failed)
                    return .summaryOnly(unreadableText(of: book, why: why, missingFile: missingFile, access: access))
                }
            }
            // The record no longer describes content.md: it may hold an
            // edit saved while TextMouth was closed, taken now when it
            // parses, and otherwise kept beside it before the rebuild below.
            if let taken = try editSavedWhileClosed(of: book, access: access) {
                pages?.record(.keptChanged)
                return .summaryOnly(taken)
            }
            // content.md holds an edit the user made and TextMouth took
            // (B12): the book's file is not read over it. The text is
            // indexed as it is and committed with the current format once,
            // so the batch does not visit the book again at the next launch.
            if BookTextEditSessions.holdsTakenEdit(book, access: access) {
                BookTextEditSessions.logEditedTextKept(of: book)
                pages?.record(.keptChanged)
                return .summaryOnly(keptText(of: book, access: access))
            }
        }
        var updatedBook = book
        // Redo Text Extraction reads the book's file over an edit too (B12);
        // no automatic pass does.
        guard let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(
            for: &updatedBook, replacingEditedText: force
        ) else {
            return .summaryOnly(nil)
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
                for: updatedBook,
                index: generated.content.contentIndex,
                cacheFormatVersion: currentVersion,
                movedPlaces: generated.movedPlaces,
                // The content.md just written has its format's pages (PG09).
                pageReaderVersion: .some(generated.pageReaderVersion)
            ) else { return .summaryOnly(nil) }
            if let replacedTextCopy {
                // The text read over is beside the new one, under this name.
                DiagnosticLog.event(.storage, "PAGES_REPLACED_TEXT: \(book.title); kept as \(replacedTextCopy.lastPathComponent)")
                pages?.record(.replacedText)
            } else {
                // A run for the pages that failed gave none (PG16).
                pages?.record(PageReaderVersions.notesFailure(generated.pageReaderVersion) ? .failed : .gainedPages)
            }
            // A reader that has this book open shows the text it loaded, which
            // this rewrite has replaced (ST01): the new text, already parsed
            // and indexed, goes to the main actor with the summary, kept only
            // for a book open in a reader at this moment.
            let textForOpenReader = isOpenInReader(book.id)
                ? TextForOpenReader(content: generated.content, movedPlaces: generated.movedPlaces)
                : nil
            return TextCacheUpdate(
                summary: ContentAnalysisSummary(committed: committed, movedPlaces: generated.movedPlaces),
                textForOpenReader: textForOpenReader
            )
        } catch {
            // Leave the library version unchanged so startup retries
            // a book whose new index could not be committed.
            return .summaryOnly(nil)
        }
    }

    /// Whether `book`'s text cache is current but for its pages: written by
    /// this build's cache format, and by an older page reader than its
    /// format has, while the launch re-read is switched on (PG09,
    /// `PageReaderVersions.isDueForPages`). Such a book is read again to
    /// gain its pages; one behind in its cache format too is rebuilt as
    /// every version bump rebuilds it.
    nonisolated private static func isBehindOnlyInPages(_ book: Book) -> Bool {
        PageReaderVersions.isDueForPages(book)
            && !MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
    }

    /// What the launch's re-read for pages makes of `book`, whose content.md
    /// predates its format's page reader (PG09). The whole content.md is
    /// compared, byte for byte, with what reading the book's file again
    /// without pages would write (PG16): chapter lines, headings and their
    /// levels, and every word, so an edit that only made a paragraph a
    /// heading, changed a heading's level, or renamed a chapter is found as
    /// surely as one that changed words.
    /// - A content.md that is exactly the file's text without pages is
    ///   TextMouth's own, and is read again with pages (`readAgain`), as is
    ///   a book with no content.md, which has nothing to keep.
    /// - So, without the compare, is a content.md an earlier page reader
    ///   wrote, which read its pages (`PageReaderVersions.notesSuccess(_:)`),
    ///   when its record still describes it and the book's file (V05): a
    ///   build that records every edit wrote it. One changed since its
    ///   record is looked at as below.
    /// - A content.md that is exactly the file's text with its pages is
    ///   TextMouth's own too (`writtenWithPages`): a batch wrote it, then
    ///   stopped before it committed the book's record, since a quit does
    ///   not wait for the batch. Only the record is stamped then; it is
    ///   never taken for an edit saved while TextMouth was closed.
    /// - Any other content.md (`changed`) may be text changed by hand before
    ///   B12 recorded such edits, by an older TextMouth on another Mac, or
    ///   written by an extraction this build cannot repeat exactly, and
    ///   nothing tells these apart: a copy of it is kept beside content.md
    ///   before the book is read again with pages, and with no copy it is
    ///   kept as it is.
    /// - A book whose file changed since content.md was written is not
    ///   compared (`stale`): it is read again as any stale cache is. Nor is
    ///   a content.md changed since then, unless it is the text with pages:
    ///   the check for an edit saved while TextMouth was closed decides.
    /// - A book whose file is missing, or no longer extracts, with pages or
    ///   without them, has nothing to compare its text with, nor pages to
    ///   read (`unreadable`).
    /// - When the read with pages could not read them (textutil's run for
    ///   them failed), it is never taken to match: a content.md changed
    ///   since its record is looked at again at the next launch
    ///   (`tryAgainNextLaunch`), and any other is `changed`.
    ///
    /// Internal, not private, for its tests.
    /// - Throws: why content.md could not be read, and the refusal of a read
    ///   that met a file only in the cloud.
    nonisolated static func pageUpgradeCheck(of book: Book, access: MaintenanceFileAccess) throws -> PageUpgradeCheck {
        // The batch's queue hands each update a rebased book already;
        // rebasing here keeps the check right for any caller (ST01), whose
        // book may have been captured before a data directory move, and
        // costs one lock.
        let book = StorageBoundary.shared.rebasedToCurrent(book)
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let sourceURL = book.bookFileURL
        guard FileStamp(of: cacheURL) != nil else { return .readAgain }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .unreadable(why: "its file is missing", missingFile: true)
        }
        // Whether content.md holds other bytes than its record describes.
        var contentChanged = false
        // Whether the record's fingerprints say content.md and the book's
        // file are both as TextMouth last wrote or took them.
        var contentAsRecorded = false
        if let recorded = BookTextEditSessions.recordedTextCacheFingerprint(of: book, access: access) {
            let hasher = access.hasher
            let verification = try recorded.verify(
                sourceURL: sourceURL,
                sourceStamp: FileStamp(of: sourceURL),
                cacheStamp: FileStamp(of: cacheURL),
                cacheDigest: { try hasher.digestOfFile(cacheURL) },
                hasher: hasher,
                sourceIsDataless: access.isDataless(sourceURL),
                cacheIsDataless: access.isDataless(cacheURL)
            )
            switch verification {
            case .current:
                contentAsRecorded = true
            case .stale(.sourceChanged):
                return .stale
            case .stale(.cacheChanged):
                contentChanged = true
            }
        }
        // Text an earlier page reader wrote, which read its pages, as its
        // record describes it, is read again without the compare (V05): a
        // build that records every edit wrote it (B12), and an edit taken is
        // kept before this check is asked. Compared, it would differ from
        // what the newer reader writes, and the first bump of a format's page
        // reader would keep a copy of every one of its books.
        if contentAsRecorded, PageReaderVersions.notesSuccess(book.pageReaderVersion) {
            return .readAgain
        }
        let kept = try access.read(cacheURL) { try Data(contentsOf: cacheURL) }
        if !contentChanged {
            let withoutPages: MarkdownCacheService.ExtractedText?
            do {
                withoutPages = try MarkdownCacheService.extractedText(for: book, includesPages: false)
            } catch where !DatalessFiles.isDownloadRefusal(error) {
                return .unreadable(why: error.localizedDescription, missingFile: false)
            }
            if withoutPages?.bytes == kept {
                return .readAgain
            }
            // A Kindle book stored before .mobi had a page reader (it has no stamp) holds what the
            // MOBI 6 half of a hybrid file read, which is not what the KF8 half reads now: the same
            // words, with the book's own headings and pages. Compared with the half it was stored
            // from, it is TextMouth's own text, and is read again without a copy (S6).
            if book.format == .mobi, book.pageReaderVersion == nil {
                let storedHalf: MarkdownCacheService.ExtractedText?
                do {
                    storedHalf = try MarkdownCacheService.extractedText(for: book, includesPages: false, kindleHalf: .mobi6)
                } catch where !DatalessFiles.isDownloadRefusal(error) {
                    return .unreadable(why: error.localizedDescription, missingFile: false)
                }
                if storedHalf?.bytes == kept {
                    return .readAgain
                }
            }
        }
        let withPages: MarkdownCacheService.ExtractedText?
        do {
            withPages = try MarkdownCacheService.extractedText(for: book, includesPages: true)
        } catch where !DatalessFiles.isDownloadRefusal(error) {
            // A file that reads without pages but not with them can't be read
            // again with them either: its text stays, as a file's that no
            // longer reads does, unless the edit check decides.
            return contentChanged ? .stale : .unreadable(why: error.localizedDescription, missingFile: false)
        }
        if withPages?.pageRunFailed == true {
            // The read has no pages, so it can't say whether content.md is
            // TextMouth's own text with them: never stamp it as such, nor
            // take a content.md changed since its record for an edit saved
            // while TextMouth was closed, but look again at the next launch.
            return contentChanged ? .tryAgainNextLaunch : .changed(kept)
        }
        if withPages?.bytes == kept {
            return .writtenWithPages
        }
        return contentChanged ? .stale : .changed(kept)
    }

    /// Records, in the debug log, that `book`, whose content.md changed since
    /// its record and whose run for its pages failed, is left as it is
    /// (PG16): neither stamped nor taken for an edit, and looked at again at
    /// the next launch. One `PAGES_DEFERRED` line naming the title.
    nonisolated private static func logCheckDeferred(of book: Book) {
        DiagnosticLog.event(
            .storage,
            "PAGES_DEFERRED: \(book.title): its pages could not be read to check its text; it is checked again at the next launch"
        )
    }

    /// Settles a book whose content.md is TextMouth's own text with its
    /// format's pages, written by a batch that stopped before it committed
    /// the book's record (PG16): only the record is stamped, with the page
    /// reader its format has now, as the batch would have stamped it. The
    /// text is not read again, nor taken for an edit, and the places stay
    /// where they are: the launch's place recovery moved them with the text
    /// first (`finishLeftoverPlaceMoves(access:then:)`). Nil when nothing
    /// was committed; a later launch tries again.
    nonisolated private static func stampedText(of book: Book, access: MaintenanceFileAccess) -> ContentAnalysisSummary? {
        settledText(of: book, pageReaderVersion: .some(PageReaderVersions.current(for: book.format)), access: access)
    }

    /// Settles a book whose file is missing (`missingFile`), or could not be
    /// read, so it could be neither compared nor read for its pages (PG16):
    /// content.md is kept as it is, without pages, and the row and record
    /// are stamped with a failure note, so the book is not chosen at every
    /// launch. A missing file is not looked for again
    /// (`PageReaderVersions.failedStamp(for:)`); a read may fail only for a
    /// moment, so it is tried at one more launch first
    /// (`PageReaderVersions.failureStamp(for:previous:)`). It is not recorded
    /// as edited, since nothing says it was. One line is logged:
    /// `PAGES_SKIPPED_UNREADABLE: <title>: <why>`. Nil when nothing was
    /// committed; a later launch tries again.
    nonisolated private static func unreadableText(
        of book: Book,
        why: String,
        missingFile: Bool,
        access: MaintenanceFileAccess
    ) -> ContentAnalysisSummary? {
        // The reason on one line, as every log entry is.
        let reason = why.components(separatedBy: .newlines).joined(separator: " ")
        DiagnosticLog.event(.storage, "PAGES_SKIPPED_UNREADABLE: \(book.title): \(reason)")
        let stamp = missingFile
            ? PageReaderVersions.failedStamp(for: book.format)
            : PageReaderVersions.failureStamp(for: book.format, previous: book.pageReaderVersion)
        return settledText(of: book, pageReaderVersion: .some(stamp), access: access)
    }

    /// Settles a book whose content.md is kept as it is: its summary, once
    /// the text is indexed and committed with the page reader its format
    /// has now when the book was behind in it while the launch re-read is
    /// switched on (`PAGES_SKIPPED_CHANGED_TEXT: <title>` is logged then),
    /// or nil when nothing was committed. While the re-read is off, the
    /// record keeps its own page reader, so a later re-read still checks it.
    nonisolated private static func keptText(of book: Book, access: MaintenanceFileAccess) -> ContentAnalysisSummary? {
        let behindInPages = PageReaderVersions.isDueForPages(book)
        if behindInPages {
            logChangedTextKept(of: book)
        }
        // Nil leaves the record's own page reader, for a book not behind.
        let stamp: String?? = behindInPages ? .some(PageReaderVersions.current(for: book.format)) : nil
        return settledText(of: book, pageReaderVersion: stamp, access: access)
    }

    /// Settles a book whose content.md the read for pages found changed, and
    /// of which no copy could be kept (PG16): kept as it is, without pages;
    /// its row and record stamped with its format's page reader, so the
    /// check runs once; and recorded as edited (`Book.editedText`, B12), so
    /// that no later automatic re-read, such as a cache-format bump, replaces
    /// the text either. Only Redo Text Extraction reads the book's file again
    /// over it. `PAGES_SKIPPED_CHANGED_TEXT: <title>` is logged. Nil when
    /// nothing was committed; a later launch tries again.
    nonisolated private static func keptChangedText(of book: Book, access: MaintenanceFileAccess) -> ContentAnalysisSummary? {
        logChangedTextKept(of: book)
        return settledText(
            of: book, pageReaderVersion: .some(PageReaderVersions.current(for: book.format)), recordingEdit: true, access: access
        )
    }

    /// Records, in the debug log, that `book` keeps its text without pages,
    /// since the text was changed: one `PAGES_SKIPPED_CHANGED_TEXT` line
    /// naming the title only, never text.
    nonisolated private static func logChangedTextKept(of book: Book) {
        DiagnosticLog.event(.storage, "PAGES_SKIPPED_CHANGED_TEXT: \(book.title)")
    }

    /// The summary of `book` once its content.md, kept as it is, is indexed
    /// and committed to its record with `pageReaderVersion`, and recorded as
    /// an edit with `recordingEdit`
    /// (`BookTextEditSessions.settleKeptText(of:pageReaderVersion:recordingEdit:access:)`),
    /// or nil when nothing was committed.
    nonisolated private static func settledText(
        of book: Book,
        pageReaderVersion: String??,
        recordingEdit: Bool = false,
        access: MaintenanceFileAccess
    ) -> ContentAnalysisSummary? {
        BookTextEditSessions.shared.settleKeptText(
            of: book, pageReaderVersion: pageReaderVersion, recordingEdit: recordingEdit, access: access
        )
        .map { ContentAnalysisSummary(committed: $0) }
    }

    /// Deletes the copies of an edit's old text that no session of this run
    /// uses (`PlaceSnapshot.leftovers(in:)` over `editTextSnapshots`), the
    /// ones a quit left, on a utility queue, then calls `completion` on the
    /// main actor, so a caller that waits for the cache pass finds them
    /// gone. The pass has settled every edit saved while TextMouth was
    /// closed by then (`editSavedWhileClosed(of:access:)`), using the copy of
    /// its book; one left for a book with nothing saved since is of no use.
    ///
    /// A copy stays when its book's content.md is only in the cloud now
    /// (`access.isDataless`): the check keeps such a copy
    /// (`BookTextEditSessions.settleEditSavedWhileClosed`), and a later
    /// launch, with the file here, still needs it. A copy of a book not
    /// among `books` is discarded: its places are gone with it.
    ///
    /// - Parameters:
    ///   - books: The rows the pass began with.
    ///   - access: How the pass reaches the books' files.
    nonisolated private static func sweepLeftoverEditTexts(
        of books: [Book],
        access: MaintenanceFileAccess,
        then completion: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let boundary = StorageBoundary.shared
            let rows = Dictionary(books.map { ($0.id, $0) }) { first, _ in first }
            for copy in PlaceSnapshot.leftovers(in: MachineLocalPaths.editTextSnapshots) {
                // The book as listed, with its paths in the data directory in
                // use now, as the place recovery reads it.
                if let listed = rows[copy.record.bookID],
                   access.isDataless(MarkdownCacheService.cacheURL(for: boundary.rebasedToCurrent(listed))) {
                    continue
                }
                copy.discard()
            }
            // The main queue is the main actor's executor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    /// What the launch's cache pass makes of an edit of `book`'s content.md
    /// saved while TextMouth was closed (FR05,
    /// `BookTextEditSessions.settleEditSavedWhileClosed(of:access:)`): the
    /// summary of the book with the edit taken as its text, committed to
    /// its record, and the book's places moved with it, from the copy of the
    /// text a quit left when it is the text they were saved in (T06's branch
    /// E); or nil when there was none to take, or it could not be
    /// taken and was kept beside content.md, so the cache is rebuilt from
    /// the source as before.
    /// - Throws: a refusal for a content.md only in the cloud, which leaves
    ///   the book as it is, as any file only in the cloud does (FR02).
    nonisolated private static func editSavedWhileClosed(
        of book: Book,
        access: MaintenanceFileAccess
    ) throws -> ContentAnalysisSummary? {
        switch BookTextEditSessions.shared.settleEditSavedWhileClosed(of: book, access: access) {
        case .adopted(let edit)?:
            // The row takes the moves of the book's places that the record took.
            return ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)
        case .inCloud?:
            throw MaintenanceFileAccess.refusal(of: MarkdownCacheService.cacheURL(for: book))
        default:
            // Nothing to take: content.md holds what its record describes,
            // or the edit was kept beside it for the rebuild that follows.
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
        return Self.maintenanceOutcome(
            run,
            failureContext: Self.rebuildFailureContext,
            done: Self.rebuildDirectoryDoneMessage(library)
        )
    }

    /// What Rebuild Directory says once it is done: "Done. 743 books in
    /// library.", counting the library's own books, never a feed's items
    /// (FR11), which the rebuild leaves where they are.
    nonisolated static func rebuildDirectoryDoneMessage(_ library: Library) -> String {
        "Done. \(CountWording.books(library.libraryBookCount)) in library."
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
                // A feed's items are never in the Library folder the rebuild
                // reconciles (FR11), so they wait aside while it does.
                let migration = try library.withFeedItemsSetAside {
                    try FileImportService.rebuildDirectoryStructure(library: &$0)
                }
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
                // As in Rebuild Directory, a feed's items wait aside (FR11).
                let migration = try library.withFeedItemsSetAside {
                    try FileImportService.rebuildDirectoryStructure(library: &$0)
                }
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

    /// Waits until the listening statistics' saves queued so far are
    /// written, as an operation holding the storage work does before it
    /// changes anything (`withStorageWorkHeld`), so a move's copy holds
    /// them, and no save is still writing its temporary file beside
    /// reading_stats.json while the copy lists the data directory. In the
    /// app it waits for the statistics service's save queue
    /// (`ReadingStatsService.waitForQueuedSaves()`); a test binds a queue of
    /// its own, holding a save the move must wait for.
    @TaskLocal static var waitForQueuedStatisticsSaves: @Sendable () -> Void = {
        ReadingStatsService.waitForQueuedSaves()
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
    /// copied: the library's and its books' records, config.json, the
    /// listening statistics (`waitForQueuedStatisticsSaves`), and the logs.
    /// So the copy holds them, none is written after the publication, and
    /// none is still writing its temporary file as the copy lists the data
    /// directory, which would vanish before the copy reached it and fail
    /// the move. The move copies and publishes off the main actor
    /// (`copyAndPublish`). The held work goes on once `body` returns or
    /// throws, under whichever generation is current then.
    ///
    /// Only one operation holds the storage work at a time: while another
    /// does (a move, a rebuild, or a folder edit moving books between
    /// folders), this throws `StorageBusyError`, saying which (#673).
    private func withStorageWorkHeld<Value>(
        moving move: DataDirectoryMoveRequest?,
        waiting: (StorageWork?) async -> Void,
        _ body: () throws -> Value
    ) async throws -> Value {
        if move != nil, let refusal = openBooksRefusal {
            throw refusal
        }
        // An operation that moves the data directory holds the work as a
        // move; every other one here rebuilds the directory where it is.
        let hold = try StorageBoundary.shared.holdWork(for: move == nil ? .rebuildingDirectory : .movingDataDirectory)
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
        configService.flushScheduledSave()
        Self.waitForQueuedStatisticsSaves()
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
    ///
    /// Internal rather than private only so that tests can call it.
    static func library(afterMoving migrated: Library, from snapshot: Library, current: Library) -> Library {
        // `migrated` holds every part of the library as `snapshot` had it,
        // only its books' and feed rows' paths moved, so it stands in only
        // for a library unchanged in every stored field (`Library`'s
        // synthesized `==`): a book added to the reading list meanwhile, or
        // a feed's rows changed, is kept below, as a changed book is.
        guard current != snapshot else { return migrated }
        var kept = current
        let moved = StorageBoundary.shared.rebaseToCurrent(&kept)
        // The feed shelf's rows move with the books' (FR11).
        kept.feedShelf.changeRows { $0 = StorageBoundary.shared.rebasedToCurrent($0) }
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
        let titles = library.books.filter { openBookIDs.contains($0.id) }.map(\.title).sortedStably()
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
    /// The switch holds the storage work, as a move does
    /// (`StorageBoundary.holdWork(for:)`), until TextMouth has asked to quit.
    /// While another operation holds it (a data-directory move, Rebuild
    /// Directory, or a folder edit moving books between folders) the switch
    /// is refused, saying which, since quitting would stop that operation
    /// part way; and none of them can begin while TextMouth opens again.
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
        let hold: StorageWorkHold
        do {
            hold = try StorageBoundary.shared.holdWork(for: .switchingLibraries)
        } catch {
            return .failure(Self.switchFailureContext, error)
        }
        defer { hold.release() }
        LibraryPersistenceService.flushPendingSave()
        configService.flushScheduledSave()
        let unsaved = failureCenter.unsavedFailures()
        if dataDirectoryUnavailability == nil, !unsaved.isEmpty {
            let reasons = PersistenceBannerRow.rows(for: unsaved).map(\.text)
            let message = ["\(Self.switchFailureContext): Some changes are not saved, and switching libraries would lose them."]
                + reasons + ["Choose Retry Saving, then try again."]
            return .failure(message.joined(separator: " "))
        }

        // A fetch of the old library's files is dropped first: its passes
        // would otherwise check the old folder against the new library's
        // expectations, while TextMouth waits to open again.
        let droppedFetch = cancelLibraryFetch()
        librarySwitchPending = true
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
            librarySwitchPending = false
            if droppedFetch {
                recheckAfterDroppedLibraryFetch()
            }
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

    // MARK: - Finished Books at Their Ends (TODO P07)

    /// The preference that records the one-time move of finished books to
    /// their ends (`moveFinishedBooksToTheirEndsOnce`) as made on this Mac:
    /// its version, `finishedBooksAtEndVersion`, once made.
    nonisolated static let finishedBooksAtEndKey = "library.finishedBooksAtEndVersion"

    /// The version of the one-time move this TextMouth makes.
    nonisolated static let finishedBooksAtEndVersion = 1

    /// The lowest percent a book's row shows as "100%": its percent rounds
    /// to a whole one (`BookRow.progressText(for:)`), and 99.5 rounds up.
    nonisolated static let rowsHundredPercent = 99.5

    /// Puts each book Books Finished counts whose row reads 100 percent at
    /// its end, once (TODO P07): the user decided on October 10, 2026
    /// ("yes", question 16) that the books already counted be "put at their
    /// end once", so they read as finished, as every book that plays to its
    /// end now rests (`ReaderViewModel.restAtEnd()`). The design note found
    /// 27 of the user's 28 counted books at 100 percent, some at their last
    /// word, some within the last second of an audiobook, and some saved
    /// past the end of a text extracted again since; the one at 99 percent
    /// stays where it is, and so does every book Books Finished does not
    /// count, however near its end.
    ///
    /// Runs once the launch's maintenance has ended
    /// (`updateContentCachesAndStatistics`), and only while this Mac has not
    /// made the move (`finishedBooksAtEndKey`) and the statistics were read
    /// from their file (`ReadingStatsService.statsReadFromFile`). Statistics
    /// that stand in for the file, one still in the cloud, in a data
    /// directory not there yet, not written yet, or that could not be read
    /// or decoded, list no finished book: a move made over them would move
    /// nothing and be recorded as made, so it would never run once the file
    /// could be read again (REV14). Until then nothing is moved, recorded, or
    /// logged, and a later launch that reads the file makes the move. The
    /// move is made once every book it is for was here to be moved: a book
    /// whose record or index is only in the cloud, or that a reader window
    /// has open, keeps its place and waits for a later launch, which makes
    /// the move then.
    ///
    /// - Parameters:
    ///   - statistics: The statistics whose Books Finished names the books.
    ///   - preferences: Where the move is recorded as made.
    ///   - access: How the move reaches the books' files: `live` in the app;
    ///     tests pass one that pretends files are in the cloud.
    ///   - completion: Called on the main actor once the move has ended, or
    ///     at once when it is not made.
    func moveFinishedBooksToTheirEndsOnce(
        statistics: ReadingStatsService = .shared,
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard preferences.integer(forKey: Self.finishedBooksAtEndKey) < Self.finishedBooksAtEndVersion,
              statistics.statsReadFromFile else {
            completion?()
            return
        }
        moveFinishedBooksToTheirEnds(counted: statistics.stats.finishedBookIDs, access: access) { outcome in
            if outcome.waiting == 0 {
                preferences.set(Self.finishedBooksAtEndVersion, forKey: Self.finishedBooksAtEndKey)
            }
            completion?()
        }
    }

    /// What the move of finished books to their ends did
    /// (`moveFinishedBooksToTheirEnds(counted:access:then:)`).
    struct FinishedBooksAtEndOutcome: Equatable, Sendable {
        /// The books put at their ends.
        var moved = 0
        /// The books left where they are for a later move: a record or
        /// index only in the cloud, or a reader window open on the book.
        var waiting = 0
        /// The books left where they are for good: no content index to
        /// find the end in, or one that disagrees with the row's measure.
        var unplaced = 0

        /// The debug log's line for the move, counts alone.
        var logLine: String {
            "FINISHED_BOOKS_AT_END: moved \(moved) of the books Books Finished counts to their ends; "
                + "\(waiting) wait for a later launch; \(unplaced) without a content index to place them by"
        }
    }

    /// One move of the one-time pass, read off the main thread: the book,
    /// the place its row held when the pass read it, and its end.
    private struct FinishedBookEndMove: Sendable {
        let bookID: UUID
        let from: ReadingPosition?
        let to: ReadingPosition
    }

    /// Puts each of the library's books that `counted` names, whose row
    /// reads 100 percent, at its end (`finishedBooksShortOfTheirEnds`), as
    /// `moveFinishedBooksToTheirEndsOnce` describes, and calls `completion`
    /// with what it did, on the main actor.
    ///
    /// Each book's content index is read off the main thread, with dataless
    /// files left in the cloud, for its last chapter and that chapter's
    /// length (`finishedBookEnd(of:index:)`). Each move goes to the row and
    /// its record, as a reader saves a place (`persistReadingPosition`), the
    /// place dated now, so a launch after a crash takes it from the record,
    /// but the book's last-opened date kept as it was: nobody opened the
    /// book, and Recently Opened, the Last Opened sort, and Speak Info's
    /// "Last opened" read that date (REV14). A book whose row moved
    /// meanwhile, or that a reader window opened meanwhile, keeps its place
    /// and waits. One `FINISHED_BOOKS_AT_END` line in the debug log counts
    /// what was done.
    func moveFinishedBooksToTheirEnds(
        counted: Set<UUID>,
        access: MaintenanceFileAccess = .live,
        then completion: @escaping @MainActor @Sendable (FinishedBooksAtEndOutcome) -> Void
    ) {
        let candidates = Self.finishedBooksShortOfTheirEnds(library.books, counted: counted)
        // A book a reader window has open keeps its place: the reader holds
        // the cursor, and its next save would put it back.
        let open = openBookIDs
        let readable = candidates.filter { !open.contains($0.id) }
        let openCount = candidates.count - readable.count
        DispatchQueue.global(qos: .utility).async {
            var moves: [FinishedBookEndMove] = []
            var inCloud = 0
            var unplaced = 0
            for book in readable {
                switch Self.readFinishedBookEnd(of: book, access: access) {
                case .end(let end):
                    moves.append(FinishedBookEndMove(bookID: book.id, from: book.readingPosition, to: end))
                case .atItsEnd:
                    break
                case .inCloud:
                    inCloud += 1
                case .unplaced:
                    unplaced += 1
                }
            }
            let read = (moves: moves, waiting: openCount + inCloud, unplaced: unplaced)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var outcome = FinishedBooksAtEndOutcome(waiting: read.waiting, unplaced: read.unplaced)
                for move in read.moves {
                    // A row that moved while the pass read, or a book a
                    // reader opened meanwhile, keeps its place for later.
                    guard self.bookByID(move.bookID)?.readingPosition == move.from,
                          !self.openBookIDs.contains(move.bookID) else {
                        outcome.waiting += 1
                        continue
                    }
                    // Nobody opened the book: its last-opened date stays.
                    self.persistReadingPosition(bookID: move.bookID, position: move.to, markingOpened: false)
                    outcome.moved += 1
                }
                DiagnosticLog.event(.storage, outcome.logLine)
                completion(outcome)
            }
        }
    }

    /// The books the one-time move is for, in `books`: each that `counted`
    /// names, Books Finished's, whose row reads 100 percent
    /// (`rowsHundredPercent`) and whose package is known. A book at its end
    /// already is among them, since only its index can say whether its
    /// place is exactly its end; past its end, as a place saved before its
    /// text was extracted again can be, it is not.
    nonisolated static func finishedBooksShortOfTheirEnds(_ books: [Book], counted: Set<UUID>) -> [Book] {
        books.filter { book in
            counted.contains(book.id)
                && !book.tmbDirectoryName.isEmpty
                && (book.percentComplete ?? 0) >= rowsHundredPercent
        }
    }

    /// What reading a finished book's content index found.
    private enum FinishedBookEndReading {
        /// The place the book moves to: its end.
        case end(ReadingPosition)
        /// The book's place is its end already.
        case atItsEnd
        /// Its record or index is only in the cloud: it waits.
        case inCloud
        /// It has no index to place it by, or one that disagrees with its
        /// row's measure.
        case unplaced
    }

    /// Reads `book`'s content index from its package, with dataless files
    /// left in the cloud, and finds where it moves (`finishedBookEnd`).
    nonisolated private static func readFinishedBookEnd(of book: Book, access: MaintenanceFileAccess) -> FinishedBookEndReading {
        let package = book.tmbDirectory
        let index: BookContentIndex?
        do {
            index = try access.read(TextMouthPaths.contentIndexPath(in: package)) {
                try BookInfo.load(from: package).contentIndex
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .inCloud
        } catch {
            return .unplaced
        }
        guard let index else { return .unplaced }
        guard index.totalCharacterCount == book.totalCharacterCount else { return .unplaced }
        guard let end = finishedBookEnd(of: book, index: index) else { return .atItsEnd }
        return .end(end)
    }

    /// Where the one-time move puts `book`, given `index`, its content
    /// index: its end, its last chapter at the length the index records,
    /// whose global offset is the book's total, as a reader puts a book
    /// that plays to its end (`ReaderViewModel.restAtEnd()`); nil when its
    /// place is that already, or the index has no chapter.
    nonisolated static func finishedBookEnd(of book: Book, index: BookContentIndex) -> ReadingPosition? {
        guard let last = index.chapters.last else { return nil }
        let end = ReadingPosition(
            chapterIndex: index.chapters.count - 1,
            characterOffset: last.characterCount,
            globalCharacterOffset: index.totalCharacterCount
        )
        if let place = book.readingPosition,
           place.chapterIndex == end.chapterIndex,
           place.characterOffset == end.characterOffset,
           place.globalCharacterOffset == end.globalCharacterOffset {
            return nil
        }
        return end
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

// MARK: - A Text Cache Batch's Update (ST01)

/// The text a text cache batch has just written for a book that a reader has
/// open: the book's new text, parsed and indexed as the batch wrote it, and
/// the moves of the book's saved places the rewrite took (nil for none). The
/// batch gives it to the book's reader, which shows it in place of the text
/// it loaded, its cursor following its words (`ReaderViewModel.showEditedText`).
struct TextForOpenReader: Sendable {
    /// The book's new text.
    let content: DocumentContent
    /// The moves of the book's saved places that the rewrite took.
    let movedPlaces: MovedPlaces?
}

/// What the text cache batch made of one book (`updateTextCache`), handed from
/// the batch's worker thread to the main actor.
struct TextCacheUpdate: Sendable {
    /// What the book's package now records, nil when nothing new was
    /// committed.
    let summary: ContentAnalysisSummary?
    /// The book's new text, when a reader had the book open as the batch
    /// committed it; nil for every other book, so the batch keeps no text.
    let textForOpenReader: TextForOpenReader?

    /// An update with `summary` and no text for a reader: what every outcome
    /// but a rewrite of an open book's text gives.
    static func summaryOnly(_ summary: ContentAnalysisSummary?) -> TextCacheUpdate {
        TextCacheUpdate(summary: summary, textForOpenReader: nil)
    }
}

// MARK: - The Launch Re-read for Pages (PG09, PG16)

/// What comparing a book's content.md with its file found, for the launch's
/// re-read for pages (`LibraryViewModel.pageUpgradeCheck(of:access:)`).
enum PageUpgradeCheck: Equatable {
    /// content.md is exactly the file's text without pages, TextMouth's own
    /// from before pages, or there is none, or an earlier page reader wrote
    /// it, as its record describes (V05): the file is read again, with its
    /// pages.
    case readAgain
    /// content.md is exactly the file's text with its pages, TextMouth's own
    /// from a batch that stopped before it committed the book's record: only
    /// the record is stamped.
    case writtenWithPages
    /// The file changed since content.md was written, or content.md did and
    /// is not the text with pages: the checks every book has decide, as for
    /// any stale cache, and for an edit saved while TextMouth was closed.
    case stale
    /// content.md, whose bytes these are, is not exactly what the file gives:
    /// a copy is kept, and the book is read again with pages.
    case changed(Data)
    /// content.md changed since its record, and the run for the pages
    /// failed, so nothing says whose text it is: the book is left as it is
    /// until the next launch.
    case tryAgainNextLaunch
    /// The file is missing (`missingFile`), or no longer extracts, for
    /// `why`: content.md is kept as it is, and the check runs once.
    case unreadable(why: String, missingFile: Bool)
}

/// What the launch's re-read for pages did with the books it chose (PG09,
/// PG16), counted from the batch's workers, each book once, for the one
/// line the batch writes to the debug log at its end (`log()`), which no
/// listener hears.
private final class PageUpgradeTally: Sendable {
    /// What became of a book chosen for its pages.
    enum Outcome {
        /// Read again with its pages, or found written with them already.
        case gainedPages
        /// Read again with its pages over text the compare could not match,
        /// a copy of which was kept first (`PAGES_REPLACED_TEXT`).
        case replacedText
        /// Kept as it is, without pages: its text was changed with Edit
        /// Text, or in an edit not taken yet, or differs and no copy of it
        /// could be kept.
        case keptChanged
        /// Left as it is: a file it needs is only in the cloud.
        case skippedInCloud
        /// Kept as it is, and stamped: its file is missing.
        case skippedMissing
        /// Not given its pages: its file no longer extracts, the run for its
        /// pages failed, or its new text could not be written.
        case failed
    }

    /// How many books came to each outcome, guarded by the lock itself.
    private let counts = OSAllocatedUnfairLock<[Outcome: Int]>(initialState: [:])

    /// Counts one book's `outcome`.
    func record(_ outcome: Outcome) {
        counts.withLock { $0[outcome, default: 0] += 1 }
    }

    /// The summary, as in "PAGES_UPGRADE_SUMMARY: 410 given pages, 2
    /// replaced keeping a copy, 1 kept as changed, 5 skipped (4 in the
    /// cloud, 1 missing), 2 failed"; nil when the batch chose no book for its
    /// pages.
    var logLine: String? {
        let counts = counts.withLock { $0 }
        guard !counts.isEmpty else { return nil }
        let count = { (outcome: Outcome) in counts[outcome, default: 0] }
        let skipped = count(.skippedInCloud) + count(.skippedMissing)
        return "PAGES_UPGRADE_SUMMARY: \(count(.gainedPages)) given pages, \(count(.replacedText)) replaced keeping a copy, "
            + "\(count(.keptChanged)) kept as changed, "
            + "\(skipped) skipped (\(count(.skippedInCloud)) in the cloud, \(count(.skippedMissing)) missing), "
            + "\(count(.failed)) failed"
    }

    /// Writes the summary to the debug log, once every worker has returned;
    /// nothing when the batch chose no book for its pages.
    func log() {
        if let logLine {
            DiagnosticLog.event(.storage, logLine)
        }
    }
}

/// How the launch's re-read for pages keeps a copy of text it reads over
/// (PG16): `BookTextEditSessions.keepCopy(of:bytes:)`, which writes
/// `content.md.edited-<UTC time>` beside content.md. Only that name is
/// used: a package rebuild would take another unknown file for the book's
/// own document (`FileImportService.isPackageContentName`). A test can make
/// every copy fail, to reach the text kept when none can be made.
enum PageUpgradeCopies {
    /// A copy of the content.md at `url`, holding `bytes`; nil when none
    /// could be made, or a test made every copy fail.
    static func keep(_ url: URL, bytes: Data) -> URL? {
        guard !copiesFail.withLock({ $0 }) else { return nil }
        return BookTextEditSessions.keepCopy(of: url, bytes: bytes)
    }

    /// Whether a test made every copy fail, held under a lock, since the
    /// batch asks on its worker threads.
    private static let copiesFail = OSAllocatedUnfairLock(initialState: false)

    /// Makes every copy fail, or not, for a test, and returns how it was,
    /// for the test to put back. The app never calls it.
    @discardableResult
    static func _setCopiesFailForTesting(_ fail: Bool) -> Bool {
        copiesFail.withLock { fails in
            let previous = fails
            fails = fail
            return previous
        }
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
        #if os(macOS)
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
            quit: { QuitRequest.ask() }
        )
        #else
        // iOS cannot open a second instance of the app, nor quit this one
        // (phase 0): opening throws, so Use This Library reports it, and
        // quitting does nothing, so this instance carries on.
        return TextMouthRelauncher(
            openNewInstance: { throw IOSUnavailable.feature("Opening TextMouth again") },
            quit: {}
        )
        #endif
    }
}
