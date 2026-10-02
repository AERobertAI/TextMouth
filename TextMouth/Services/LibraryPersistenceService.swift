import Foundation

/// Handles saving and loading the library index from disk.
/// The library index now lives at ~/.TextMouth/library.json.
///
/// An index that exists but cannot be read or decoded is never replaced by an
/// empty library. `load()` preserves its bytes (see `LibraryIndexQuarantine`)
/// and suspends every library.json write in the process: debounced saves,
/// flushes, and the legacy migration skip the index, and data-directory
/// migration refuses, until the library model adopts a readable index
/// (`resumeIndexWrites()`) or the user replaces the unreadable one
/// (`replaceUnreadableIndex(with:)`). Package metadata (bookInfo.json)
/// writes continue, so reading positions are still saved.
///
/// Package metadata is never written into a package that Remove from
/// Library Only retired (`retirePackage(of:)`): queued, flushed, and
/// analysis writes for it are dropped, so none can recreate the
/// bookInfo.json that orphan adoption would read.
///
/// A write that fails is reported to `PersistenceFailureCenter` with a
/// retry of the same write, and the next write of the same file that
/// succeeds settles it (TODO S09), so a full disk or a vanished volume is
/// never mistaken for saved data. A write skipped while index writes are
/// suspended is not a failure: the recovery banner already says so.
enum LibraryPersistenceService {

    /// All library-index writes and debounce state live on one queue so an
    /// older snapshot can never finish after a newer one.
    private static let saveQueue = DispatchQueue(
        label: "com.textmouth.libraryPersistence",
        qos: .utility
    )
    /// Every package metadata (bookInfo.json) write this service makes runs
    /// on this serial queue and ends in `writeBookInfo`, which drops writes
    /// into packages Remove from Library Only retired and gives each record
    /// the next revision. Its ordering guarantee, for each book:
    ///
    /// 1. A save waits half a second as the book's pending snapshot. A newer
    ///    save replaces it, and only the newest snapshot's debounce block
    ///    writes (`bookInfoGenerations`), so an older state is never
    ///    written after a newer one.
    /// 2. The latest durable state of a book is therefore its pending
    ///    snapshot while one waits, and otherwise its bookInfo.json on disk.
    /// 3. An analysis result is merged into that latest state on this queue
    ///    (`saveContentAnalysis`), so no save can land between reading the
    ///    state and writing the merge. It changes only the analysis fields
    ///    and the content index, and a later save without an index keeps
    ///    both (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`), so
    ///    neither kind of write undoes the other, in either order.
    /// 4. Revisions only rise: each write stores one more than both the
    ///    record it replaces and the highest revision written here before.
    /// 5. Library index writes run on `saveQueue`, so suspending them while
    ///    the index cannot be read never holds back a package write.
    /// 6. Each debounced or flushed write reports its outcome to the failure
    ///    center as it finishes, without waiting for anyone, so reporting
    ///    never changes this order (`writeQueuedBookInfo`).
    ///
    /// Imports, folder moves, and migrations write records directly
    /// (`Book.saveBookInfoThrowing`), under the same index and revision
    /// rules but outside this order.
    private static let bookInfoSaveQueue = DispatchQueue(
        label: "com.textmouth.bookInfoPersistence",
        qos: .utility
    )
    // Access is confined to saveQueue. `nonisolated(unsafe)` documents that
    // executor contract to Swift's global-state checker.
    nonisolated(unsafe) private static var pendingLibrary: Library?
    nonisolated(unsafe) private static var saveGeneration: UInt = 0
    /// True while an unreadable index must be protected. Confined to saveQueue
    /// with the pending snapshot, so a suspension and a write never interleave.
    nonisolated(unsafe) private static var indexWritesSuspended = false
    /// Whether a skipped write was logged during the current suspension, so
    /// frequent position saves do not flood the debug log.
    nonisolated(unsafe) private static var loggedSkippedIndexWrite = false
    nonisolated(unsafe) private static var pendingBookInfos: [UUID: (book: Book, contentIndex: BookContentIndex?)] = [:]
    nonisolated(unsafe) private static var bookInfoGenerations: [UUID: UInt] = [:]
    /// The highest revision this process has written into each book's
    /// bookInfo.json (`BookState.revision`). Every write stores at least one
    /// more, so the revisions of a book's writes keep rising even when its
    /// record is replaced without one or cannot be read. Confined to
    /// bookInfoSaveQueue.
    nonisolated(unsafe) private static var bookInfoRevisions: [UUID: Int] = [:]
    /// Packages retired by Remove from Library Only: those retired in this
    /// session, and those whose marker a write has already found. Confined
    /// to bookInfoSaveQueue, where every package metadata write checks it.
    nonisolated(unsafe) private static var retiredPackages: Set<RetiredPackage> = []

    /// A retired package: the removed book's ID and its package directory.
    /// Both identify it because a .tmb import of the same book keeps the ID
    /// in a new package, whose writes must not be dropped with this one's.
    private struct RetiredPackage: Hashable {
        let bookID: UUID
        let packagePath: String

        init(_ book: Book) {
            bookID = book.id
            packagePath = book.tmbDirectory.path
        }
    }

    private static var libraryFileURL: URL {
        TextMouthPaths.libraryIndexFile
    }

    /// Where failed writes are reported.
    private static var failureCenter: PersistenceFailureCenter {
        .shared
    }

    /// Legacy library file (for migration)
    private static var legacyLibraryFileURL: URL? {
        TextMouthPaths.oldLibraryFile
    }

    /// Whether library.json writes are suspended because the index on disk
    /// could not be read. Safe to call from any thread except saveQueue.
    static var areIndexWritesSuspended: Bool {
        saveQueue.sync { indexWritesSuspended }
    }

    /// Save the library index to disk. Does NOT write individual bookInfo.json files —
    /// use saveBookInfo(for:in:) for that when a specific book changes.
    static func save(_ library: Library) {
        saveQueue.async {
            // A snapshot taken while the index is protected is dropped, not
            // kept for later: it must never be written, even after writes resume.
            guard !indexWritesSuspended else {
                noteSkippedIndexWrite()
                return
            }
            pendingLibrary = library
            saveGeneration &+= 1
            let generation = saveGeneration

            saveQueue.asyncAfter(deadline: .now() + 0.5) {
                guard generation == saveGeneration, let library = pendingLibrary else { return }
                write(library)
                pendingLibrary = nil
            }
        }
    }

    /// Persist the newest pending snapshot before application termination.
    /// The synchronous barrier also waits for any write already in progress.
    /// While index writes are suspended only package metadata is flushed, so
    /// quitting leaves an unreadable index exactly as it was.
    static func flushPendingSave() {
        saveQueue.sync {
            saveGeneration &+= 1
            guard !indexWritesSuspended else {
                pendingLibrary = nil
                return
            }
            guard let library = pendingLibrary else { return }
            write(library)
            pendingLibrary = nil
        }
        bookInfoSaveQueue.sync {
            let pending = pendingBookInfos
            pendingBookInfos.removeAll()
            for (_, update) in pending {
                writeQueuedBookInfo(update.book, contentIndex: update.contentIndex)
            }
        }
    }

    /// Write a snapshot to library.json. Must run on saveQueue. Debounced saves
    /// and flushes both end here, so this check also stops a snapshot that was
    /// queued before the index was found unreadable.
    ///
    /// A failure is reported with a retry of this snapshot, and the library
    /// then counts as unsaved until an index write succeeds.
    private static func write(_ library: Library) {
        guard !indexWritesSuspended else {
            noteSkippedIndexWrite()
            return
        }
        do {
            try writeIndexFile(library)
        } catch {
            print("Failed to save library: \(error)")
            failureCenter.recordFailure(.libraryIndex, path: libraryFileURL.path, error: error) { failureID in
                retryIndexWrite(library, failureID: failureID)
            }
        }
    }

    /// Writes `library` again for a retry of the failed index write
    /// `failureID`, and waits for the write, which reports its own outcome.
    /// Nothing is written when a later index write has settled that failure
    /// meanwhile: this snapshot would replace a newer one. A snapshot still
    /// waiting for its debounce is newer, and is written after this one.
    private static func retryIndexWrite(_ library: Library, failureID: PersistenceFailure.ID) {
        saveQueue.sync {
            guard failureCenter.isOutstanding(failureID) else { return }
            write(library)
        }
    }

    /// Write `library` to library.json immediately, superseding any debounced
    /// snapshot queued before it, and report whether it reached the disk:
    /// false while index writes are suspended.
    private static func writeIndexNow(_ library: Library) throws -> Bool {
        try saveQueue.sync { () throws -> Bool in
            guard !indexWritesSuspended else {
                noteSkippedIndexWrite()
                return false
            }
            pendingLibrary = nil
            saveGeneration &+= 1
            try writeIndexFile(library)
            return true
        }
    }

    /// Writes `library` as library.json and tells the failure center that
    /// the index is saved, which settles any earlier failed write of it.
    /// Must run on saveQueue.
    private static func writeIndexFile(_ library: Library) throws {
        try encodeAndWrite(library, to: libraryFileURL)
        failureCenter.recordSuccess(.libraryIndex)
    }

    /// Encode `library` the way every index write does and replace `url`
    /// atomically, so a reader never sees a half-written index.
    private static func encodeAndWrite(_ library: Library, to url: URL) throws {
        try TextMouthPaths.ensureDirectoryStructure()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
    }

    /// Save a single book's bookInfo.json. Call this when a specific book's data changes.
    static func saveBookInfo(for book: Book) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        enqueueBookInfoSave(book: book, contentIndex: nil)
    }

    static func saveBookInfo(for book: Book, contentIndex: BookContentIndex) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        enqueueBookInfoSave(book: book, contentIndex: contentIndex)
    }

    /// Commits a completed content analysis immediately and returns the book
    /// as its package now records it, so the caller can give the library row
    /// the same analysis fields (`Book.contentAnalysisFields`); nil when
    /// nothing was written, because the book has no package or the result
    /// was dropped. Batch migrations commit each book this way instead of
    /// retaining every full index until the end.
    ///
    /// `analyzed` is the book as the analysis saw it when it started, which
    /// may be minutes out of date. On the metadata queue the result is merged
    /// into the latest durable state of the book: the snapshot still waiting
    /// in the debounce if there is one, otherwise the bookInfo.json on disk,
    /// and `analyzed` itself only when neither exists (a record that cannot
    /// be read counts as none, as it does for every save). Only the analysis
    /// fields and the content index change; the reading position, bookmarks,
    /// settings, and edited metadata stay exactly as that state has them.
    ///
    /// A result is dropped, with one CONTENT_ANALYSIS_DROPPED line in the
    /// debug log, when the latest state describes other content than was
    /// analyzed (`contentChange(from:to:)`). A result for a book removed with
    /// Remove from Library Only while it was being parsed is dropped quietly.
    /// Neither is an error.
    ///
    /// The content decides, not the revision. Every reading checkpoint,
    /// bookmark, and metadata edit raises a book's revision, and the reader
    /// saves a checkpoint every few seconds, so an analysis rejected for not
    /// matching the revision it started from would be thrown away whenever
    /// the user kept reading during a long extraction, and the book open in
    /// the reader would never get its index. None of those writes can make
    /// an analysis wrong: it reads only the book's source, and only another
    /// source can.
    @discardableResult
    static func saveContentAnalysis(
        for analyzed: Book,
        index: BookContentIndex,
        cacheFormatVersion: String?
    ) throws -> Book? {
        guard !analyzed.tmbDirectoryName.isEmpty else { return nil }

        return try bookInfoSaveQueue.sync { () throws -> Book? in
            let pending = pendingBookInfos[analyzed.id]?.book
            let stored = pending == nil ? analyzed.storedBookInfo() : nil
            // The record was read from the analyzed book's package, so that
            // is where the book it describes lives.
            let latest = pending ?? stored.map {
                Book(
                    record: $0,
                    filePath: analyzed.filePath,
                    folderPath: analyzed.folderPath,
                    tmbDirectoryName: analyzed.tmbDirectoryName
                )
            } ?? analyzed
            if let change = contentChange(from: analyzed, to: latest) {
                logDroppedAnalysis(of: analyzed, because: change)
                return nil
            }

            var merged = latest
            merged.applyContentAnalysis(index, cacheFormatVersion: cacheFormatVersion)
            // A failed write throws here, leaving any waiting snapshot to its
            // own debounce, so the newer user state outlives the lost result.
            guard try writeBookInfo(merged, contentIndex: index, stored: stored) else { return nil }
            // The waiting snapshot is on disk now, merged with the analysis:
            // forget it, so its debounce does not write it a second time.
            cancelQueuedWrites(for: analyzed)
            // That snapshot was the book's latest state, so an earlier failed
            // write of the book is settled too. A merge into the stored
            // record alone saved nothing newer and settles nothing.
            if pending != nil {
                failureCenter.recordSuccess(.book(analyzed.id))
            }
            return merged
        }
    }

    /// What changed about the content of `analyzed` by the time its analysis
    /// finished, as `latest`, the book's latest durable state, shows it,
    /// worded for the log; nil when `latest` still describes the analyzed
    /// content. An analysis holds for one book, the bytes of its source (the
    /// MD5 hash), the parser that read them (the format), and the file where
    /// they live, whose package also holds the text cache it wrote.
    private static func contentChange(from analyzed: Book, to latest: Book) -> String? {
        if latest.id != analyzed.id {
            return "the record in its package belongs to book \(latest.id.uuidString.prefix(8))"
        }
        if latest.md5Hash != analyzed.md5Hash {
            return "its source was replaced (MD5 \(analyzed.md5Hash) is now \(latest.md5Hash))"
        }
        if latest.format != analyzed.format {
            return "its format changed from \(analyzed.format.displayName) to \(latest.format.displayName)"
        }
        if latest.filePath != analyzed.filePath {
            return "its source file moved from \(analyzed.filePath) to \(latest.filePath)"
        }
        return nil
    }

    /// Records in the console and the debug log that an analysis of `book`
    /// was dropped because of `change`, as the single line
    /// `CONTENT_ANALYSIS_DROPPED: book <ID prefix> "<title>": <change>; ...`.
    /// A line break in the title or a path becomes a space, so the entry
    /// stays on one line.
    private static func logDroppedAnalysis(of book: Book, because change: String) {
        logLine(
            "CONTENT_ANALYSIS_DROPPED: book \(book.id.uuidString.prefix(8)) \"\(book.title)\": "
                + "\(change); the result was not saved"
        )
    }

    /// Records `line` in the console and the debug log as one line: a line
    /// break in a title or a path becomes a space.
    private static func logLine(_ line: String) {
        let singleLine = line.components(separatedBy: .newlines).joined(separator: " ")
        print(singleLine)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: singleLine)
    }

    /// Save all bookInfo.json files (for bulk operations like migration/rebuild).
    static func saveAllBookInfos(_ library: Library) {
        for book in library.books where !book.tmbDirectoryName.isEmpty {
            saveBookInfo(for: book)
        }
    }

    private static func enqueueBookInfoSave(book: Book, contentIndex: BookContentIndex?) {
        bookInfoSaveQueue.async {
            let retainedIndex = contentIndex ?? pendingBookInfos[book.id]?.contentIndex
            pendingBookInfos[book.id] = (book, retainedIndex)
            let generation = (bookInfoGenerations[book.id] ?? 0) &+ 1
            bookInfoGenerations[book.id] = generation

            bookInfoSaveQueue.asyncAfter(deadline: .now() + 0.5) {
                guard bookInfoGenerations[book.id] == generation,
                      let update = pendingBookInfos.removeValue(forKey: book.id) else { return }
                writeQueuedBookInfo(update.book, contentIndex: update.contentIndex)
            }
        }
    }

    /// Writes a queued record, as a debounced save and the termination flush
    /// do, and reports the outcome to the failure center without holding up
    /// the queue (TODO S09). A record written settles any earlier failure of
    /// the book; a failure is reported with the book's title, the record's
    /// path, and a retry of this same write. A package retired by Remove
    /// from Library Only is skipped quietly, as `writeBookInfo` decides.
    ///
    /// A write that fails because the book's package is gone, while the
    /// library folder is still there, is dropped with one debug log line
    /// instead: the book was moved, which wrote its record at the new place,
    /// or it left the library, after this write was queued. Must run on
    /// bookInfoSaveQueue.
    private static func writeQueuedBookInfo(_ book: Book, contentIndex: BookContentIndex?) {
        do {
            guard try writeBookInfo(book, contentIndex: contentIndex) else { return }
            failureCenter.recordSuccess(.book(book.id))
        } catch {
            guard !packageWasMovedOrRemoved(book) else {
                logLine(
                    "BOOK_METADATA_DROPPED: book \(book.id.uuidString.prefix(8)) \"\(book.title)\": "
                        + "no package at \(book.tmbDirectory.path); the book moved or left the library "
                        + "after this write was queued"
                )
                return
            }
            failureCenter.recordFailure(
                .bookRecord(bookID: book.id, title: book.title),
                path: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path,
                error: error
            ) { failureID in
                retryBookInfoWrite(book, contentIndex: contentIndex, failureID: failureID)
            }
        }
    }

    /// Writes `book`'s record again for a retry of the failed write
    /// `failureID`, on the metadata queue, and waits for it. Nothing is
    /// written when a later write of the book has settled that failure
    /// meanwhile. A book whose package has moved or left the library since
    /// has no record left to write there, so its failure is withdrawn.
    private static func retryBookInfoWrite(
        _ book: Book,
        contentIndex: BookContentIndex?,
        failureID: PersistenceFailure.ID
    ) {
        bookInfoSaveQueue.sync {
            guard failureCenter.isOutstanding(failureID) else { return }
            guard !packageWasMovedOrRemoved(book) else {
                failureCenter.withdraw(.book(book.id))
                return
            }
            writeQueuedBookInfo(book, contentIndex: contentIndex)
        }
    }

    /// Whether `book`'s package is gone while the library folder is still
    /// there, which means the book moved or left the library. An unavailable
    /// volume takes the library folder too, and a package that exists but
    /// cannot be examined is not missing, so neither is mistaken for this.
    private static func packageWasMovedOrRemoved(_ book: Book) -> Bool {
        isMissing(book.tmbDirectory) && !isMissing(TextMouthPaths.libraryDir)
    }

    /// Writes one package's metadata unless Remove from Library Only retired
    /// the package, and reports whether it was written. Debounced saves, the
    /// termination flush, and analysis results all end here. Each write
    /// stores the next revision, and never one below the highest this
    /// process has written for the book, even when the stored record has
    /// lost its own. `stored` is the record now in the package when the
    /// caller has just read it; otherwise it is read here. Must run on
    /// bookInfoSaveQueue.
    private static func writeBookInfo(
        _ book: Book,
        contentIndex: BookContentIndex?,
        stored: BookInfo? = nil
    ) throws -> Bool {
        guard !isRetired(book) else { return false }
        let record = book.bookInfo(
            replacing: stored ?? book.storedBookInfo(),
            contentIndex: contentIndex,
            revisionFloor: bookInfoRevisions[book.id] ?? 0
        )
        try record.save(to: book.tmbDirectory)
        bookInfoRevisions[book.id] = record.state.revision
        return true
    }

    // MARK: - Remove from Library Only

    /// Retires `book`'s package for Remove from Library Only, before its
    /// library row is removed. The removal marker is written first. Only once
    /// it is on disk are writes queued for the book cancelled, the package
    /// remembered so later writes into it are dropped, and bookInfo.json
    /// deleted. It all runs on the metadata queue, so no queued, flushed, or
    /// analysis write can land in between: one that ran earlier is deleted
    /// with bookInfo.json, and any later one is dropped.
    ///
    /// Throws `LibraryRemovalError` when the marker cannot be written; then
    /// nothing has changed, and the book must stay in the library. A record
    /// without a package on disk (a legacy record, or a package that is gone)
    /// leaves adoption nothing to find, so it needs no marker.
    ///
    /// Deleting bookInfo.json is only a courtesy to older TextMouth versions,
    /// which know nothing of the marker. When it fails, the failure is logged
    /// and returned, and the package stays retired regardless.
    static func retirePackage(of book: Book, removedAt: Date = Date()) throws -> PackageRetirement {
        try bookInfoSaveQueue.sync { () throws -> PackageRetirement in
            guard !book.tmbDirectoryName.isEmpty, !isMissing(book.tmbDirectory) else {
                cancelQueuedWrites(for: book)
                RemovedFromLibraryMarker.log("removed from the library; it has no package on disk", for: book)
                return PackageRetirement(isPackageMarked: false, recordDeletionError: nil)
            }
            let package = book.tmbDirectory
            do {
                try RemovedFromLibraryMarker(book: book, removedAt: removedAt).write(into: package)
            } catch {
                RemovedFromLibraryMarker.log(
                    "stays in the library: could not write the removal marker in \(package.path): \(error)",
                    for: book
                )
                throw LibraryRemovalError.couldNotMarkPackage(packageName: book.tmbDirectoryName, underlying: error)
            }
            retiredPackages.insert(RetiredPackage(book))
            cancelQueuedWrites(for: book)
            RemovedFromLibraryMarker.log("removed from the library; its package stays at \(package.path)", for: book)
            return PackageRetirement(isPackageMarked: true, recordDeletionError: deleteRecord(of: book))
        }
    }

    /// Undoes a retirement for a deliberate return of the retained package,
    /// such as importing it again or an explicit adopt action: deletes the
    /// removal marker, then forgets the retirement, so the book's metadata
    /// is saved again. Throws when the marker cannot be deleted, and the
    /// package then stays retired.
    static func reinstatePackage(of book: Book) throws {
        guard !book.tmbDirectoryName.isEmpty else { return }
        try bookInfoSaveQueue.sync {
            try RemovedFromLibraryMarker.remove(from: book.tmbDirectory)
            retiredPackages.remove(RetiredPackage(book))
            RemovedFromLibraryMarker.log("returned to the library from \(book.tmbDirectory.path)", for: book)
        }
    }

    /// Whether `book`'s package is retired, so a metadata write into it must
    /// be dropped: remembered here, or found on disk as a marker naming the
    /// book. A marker found on disk is remembered, so it is logged once and
    /// read once. Must run on bookInfoSaveQueue.
    private static func isRetired(_ book: Book) -> Bool {
        let package = RetiredPackage(book)
        if retiredPackages.contains(package) { return true }
        guard RemovedFromLibraryMarker.retires(book) else { return false }
        retiredPackages.insert(package)
        RemovedFromLibraryMarker.log(
            "dropping metadata writes: \(book.tmbDirectory.path) records its removal from the library",
            for: book
        )
        return true
    }

    /// Forgets any write queued for `book` and strands its scheduled debounce
    /// block. Must run on bookInfoSaveQueue.
    private static func cancelQueuedWrites(for book: Book) {
        pendingBookInfos.removeValue(forKey: book.id)
        bookInfoGenerations[book.id] = (bookInfoGenerations[book.id] ?? 0) &+ 1
    }

    /// Deletes bookInfo.json from `book`'s retired package, returning why it
    /// could not be deleted, if it could not. Must run on bookInfoSaveQueue.
    private static func deleteRecord(of book: Book) -> (any Error)? {
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        guard FileManager.default.fileExists(atPath: record.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: record)
            return nil
        } catch {
            RemovedFromLibraryMarker.log(
                "could not delete \(record.path), but the removal marker keeps the book out: \(error)",
                for: book
            )
            return error
        }
    }

    /// Whether nothing at all exists at `url`. Unlike `fileExists(atPath:)`,
    /// this is false for an item that exists but cannot be examined (inside a
    /// folder without permission), which must not be mistaken for a missing one.
    private static func isMissing(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch {
            return (error as? CocoaError)?.code == .fileReadNoSuchFile
        }
    }

    // MARK: - Loading

    /// Read the library index: the current location first, then the legacy
    /// location, which is migrated when it loads. An index that exists but
    /// cannot be used is reported as unreadable, never as an empty library;
    /// by the time this returns, its bytes are preserved and index writes are
    /// suspended, and the unreadable file itself has not been touched.
    static func load() -> LibraryLoadResult {
        // Try new location first
        if FileManager.default.fileExists(atPath: libraryFileURL.path) {
            return readIndex(at: libraryFileURL)
        }

        // Try legacy location and migrate. An unreadable legacy index gets the
        // same protection and, above all, is not deleted.
        if let legacyURL = legacyLibraryFileURL,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            let result = readIndex(at: legacyURL)
            guard case .loaded(var library) = result else { return result }
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                // A legacy book that cannot move into a package does not
                // throw: it keeps its record and original, the migration logs
                // why, and the startup repair tries it again and tells the user.
                try FileImportService.rebuildDirectoryStructure(library: &library)
                saveAllBookInfos(library)
                // Retire the legacy file only once the migrated index is on
                // disk. While index writes are suspended, or when the write
                // fails, it stays; the model's next save writes the index.
                if try writeIndexNow(library) {
                    try? FileManager.default.removeItem(at: legacyURL)
                }
            } catch {
                print("Migration failed: \(error)")
            }
            return .loaded(library)
        }

        return .missing
    }

    /// Read and decode one index file. On failure the file is preserved and
    /// index writes are suspended on saveQueue itself, so no queued write can
    /// land between the failed read and the suspension.
    private static func readIndex(at url: URL) -> LibraryLoadResult {
        saveQueue.sync { () -> LibraryLoadResult in
            // Kept outside the `do` so a decoding failure still preserves
            // exactly the bytes that failed to decode.
            var bytes: Data?
            do {
                let data = try Data(contentsOf: url)
                bytes = data
                return .loaded(try decodeLibrary(from: data))
            } catch {
                let failure = LibraryIndexReadFailure(
                    indexURL: url,
                    quarantineURL: LibraryIndexQuarantine.preserve(url, bytes: bytes),
                    error: error,
                    byteCount: bytes?.count
                )
                suspendIndexWrites(after: failure)
                return .unreadable(failure)
            }
        }
    }

    /// Decode an index the way every index read does.
    private static func decodeLibrary(from data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: data)
    }

    // MARK: - Unreadable Index Protection

    /// Stop every library.json write. Must run on saveQueue. A snapshot still
    /// waiting to be written is discarded: writing it would replace the file
    /// that just failed to load.
    private static func suspendIndexWrites(after failure: LibraryIndexReadFailure) {
        indexWritesSuspended = true
        loggedSkippedIndexWrite = false
        pendingLibrary = nil
        saveGeneration &+= 1
        logIndexEvent(
            "could not use \(failure.indexURL.path): \(failure.error); "
                + "preserved copy: \(failure.quarantineURL?.path ?? "none could be made"); "
                + "library index writes suspended"
        )
    }

    /// Re-enable library.json writes once the library model has adopted a
    /// readable index (Try Again). Nothing captured during the suspension is
    /// written; the caller saves its adopted library afresh.
    static func resumeIndexWrites() {
        saveQueue.sync {
            guard indexWritesSuspended else { return }
            endIndexWriteSuspension()
            logIndexEvent("library index writes resumed")
        }
    }

    /// Replace the unreadable index with `library` (Rebuild Library Index) and
    /// resume index writes. Whatever is at the index location is preserved
    /// first, and nothing is replaced when that fails, so a rebuild can never
    /// destroy the only copy of an index. Returns the preserved copy of the
    /// replaced file, or nil when there was no file to replace (the unreadable
    /// index was the legacy one, which stays untouched).
    @discardableResult
    static func replaceUnreadableIndex(with library: Library) throws -> URL? {
        try saveQueue.sync { () throws -> URL? in
            let indexURL = libraryFileURL
            var preservedCopy: URL?
            if FileManager.default.fileExists(atPath: indexURL.path) {
                // Re-read now: the file may have changed since the failed load.
                let currentBytes = try? Data(contentsOf: indexURL)
                preservedCopy = LibraryIndexQuarantine.preserve(indexURL, bytes: currentBytes)
                guard preservedCopy != nil else {
                    throw LibraryIndexRecoveryError.couldNotPreserve(indexURL)
                }
            }
            try writeIndexFile(library)
            endIndexWriteSuspension()
            logIndexEvent(
                "rebuilt the library index with \(library.books.count) book(s); "
                    + (preservedCopy.map { "previous index kept at \($0.path)" }
                        ?? "no index file was there to replace")
            )
            return preservedCopy
        }
    }

    /// Must run on saveQueue. Anything captured during the suspension is stale.
    private static func endIndexWriteSuspension() {
        indexWritesSuspended = false
        pendingLibrary = nil
        saveGeneration &+= 1
    }

    /// Must run on saveQueue. Logs only the first skipped write of each
    /// suspension; later ones would repeat it every few seconds of reading.
    private static func noteSkippedIndexWrite() {
        guard !loggedSkippedIndexWrite else { return }
        loggedSkippedIndexWrite = true
        logIndexEvent("skipped writing the library index because it could not be read")
    }

    /// Records a library index recovery event in the console and the debug log.
    private static func logIndexEvent(_ message: String) {
        logLine("LIBRARY_INDEX: \(message)")
    }
}
