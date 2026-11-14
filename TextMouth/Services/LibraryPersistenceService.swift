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
///
/// Library index writes are skipped the same way while the library model
/// has found the data directory unavailable (FR02, `DataDirectoryGate`):
/// the Library Not Available screen says so, and Try Again reads the index
/// afresh before writing it again. A write that fails because a custom data
/// directory's folder is gone tells the library model, which checks the
/// data directory and, finding it gone, stops saving. Package metadata
/// writes are never held back: those that fail stay listed for a retry.
///
/// A package record that is only in the cloud (FR02) is neither read nor
/// written, since reading it, or its package, would download it first and
/// wait on the network: a save of its book goes to the library index alone
/// until the record is on this Mac again, with one `BOOK_RECORD_IN_CLOUD`
/// line saying so, and an analysis result for it is dropped.
///
/// A reading checkpoint, which the reader makes every 30 seconds of
/// playback, is written to the book's record at once but to library.json
/// within five minutes (`saveReadingCheckpoint(_:of:writingWithin:)`,
/// PERF15): the record, about a kilobyte, holds it durably, while
/// library.json is half a megabyte. A journal names the books whose records
/// are ahead of library.json, so a launch after a crash takes their newer
/// positions from the records.
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
    /// The holds a skipped write was logged for since each began, so
    /// frequent position saves do not flood the debug log. Confined to
    /// saveQueue.
    nonisolated(unsafe) private static var loggedIndexWriteHolds: Set<IndexWriteHold> = []
    /// What each feed's index holds on disk as this process last read or
    /// wrote it (FR11), so a save writes a feed's index only when its bytes
    /// changed. Confined to saveQueue, where every index is read and written.
    nonisolated(unsafe) private static var feedIndexesOnDisk = SavedFile.OnDiskMemory<UUID>()

    /// What library.json holds on disk as this process last read or wrote it,
    /// so a save writes it only when its bytes changed: reading an episode
    /// checkpoints every half minute, and most checkpoints change nothing of
    /// the library's own books. The same memory the feed indexes use, with
    /// one file to remember. Confined to saveQueue.
    nonisolated(unsafe) private static var libraryIndexOnDisk = SavedFile.OnDiskMemory<String>()
    /// The key library.json is remembered by in `libraryIndexOnDisk`.
    private static let libraryIndexMemoryKey = "library.json"

    /// Why library.json is not being written.
    private enum IndexWriteHold {
        /// The index on disk could not be read and is protected.
        case unreadableIndex
        /// The library model found the data directory unavailable (FR02).
        case dataDirectoryUnavailable

        /// The debug log's account of a write skipped for this hold.
        var skippedWriteNote: String {
            switch self {
            case .unreadableIndex:
                return "skipped writing the library index because it could not be read"
            case .dataDirectoryUnavailable:
                return "skipped writing the library index because the data directory isn't available"
            }
        }
    }
    /// Each book's record waiting for its debounced write, and the number of
    /// the book's latest save, so that only the latest save's debounce
    /// writes. Confined to bookInfoSaveQueue.
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
    /// How package metadata writes reach the files already in a package
    /// (FR02): `MaintenanceFileAccess.live` in the app, so a record only in
    /// the cloud is noticed without being read; hosted tests pretend files
    /// are dataless with an access of their own
    /// (`_useRecordAccessForTesting`). Confined to bookInfoSaveQueue.
    nonisolated(unsafe) private static var recordAccess = MaintenanceFileAccess.live
    /// The books whose saves went to the library index alone, because their
    /// records were only in the cloud, since each record was last written:
    /// each is logged once, so frequent saves do not flood the debug log.
    /// Confined to bookInfoSaveQueue.
    nonisolated(unsafe) private static var booksWithRecordsInCloud: Set<UUID> = []

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

    /// How long a snapshot waits before library.json is written: newer
    /// snapshots arriving meanwhile replace it, so a burst of changes is
    /// written once.
    private static let saveDelay: TimeInterval = 0.5

    /// How long library.json may wait to take a reading checkpoint
    /// (`saveReadingCheckpoint(_:of:writingWithin:)`, PERF15): five minutes,
    /// so 30-second checkpoints write the index a tenth as often.
    static let readingCheckpointDelay: TimeInterval = 5 * 60

    /// Save the library index to disk. Does NOT write individual bookInfo.json files —
    /// use saveBookInfo(for:in:) for that when a specific book changes.
    static func save(_ library: Library) {
        saveQueue.async {
            // A snapshot taken while the index is protected, or while the
            // data directory is unavailable, is dropped, not kept for later:
            // it must never be written, even after writes resume.
            if let hold = indexWriteHold() {
                noteSkippedIndexWrite(hold)
                return
            }
            scheduleIndexWrite(of: library, after: saveDelay)
        }
    }

    /// Saves `library`, whose only change since it was last saved is a
    /// reading checkpoint of the book `bookID` (PERF15). That checkpoint is
    /// durable once the book's record holds it, which the caller saves as
    /// well, so library.json, about half a megabyte, need not be rewritten
    /// for it every 30 seconds: it takes the snapshot within `delay`, or
    /// sooner, with the next ordinary save, when a reader closes or a record
    /// cannot take its checkpoint (`writePendingIndexSoon()`), or when
    /// TextMouth quits (`flushPendingSave()`). A snapshot already waiting
    /// keeps its time and is replaced by this newer one.
    ///
    /// Until library.json holds the checkpoint, the checkpoint journal names
    /// the book (`ReadingCheckpointJournal`), so a launch after a crash
    /// takes the newer position from the record
    /// (`booksWithCheckpointsAhead()`). The journal is noted before the
    /// record is written, so a crash between the two finds no record newer
    /// than library.json, and nothing to take.
    ///
    /// While an unreadable index is protected, library.json takes no
    /// snapshot, but the record still takes the checkpoint, so the journal
    /// names the book all the same. Only an index write clears the journal,
    /// and none is made while the index is protected, so the book stays
    /// named: the launch that reads the index again, once the user has put
    /// it back, takes the newer position from the record, instead of opening
    /// the book at the index's older one and saving that over it. While the
    /// data directory is unavailable (FR02), the journal, which is kept
    /// there, is neither read nor written.
    /// - Parameter delay: How long library.json may wait: tests pass a short
    ///   one.
    static func saveReadingCheckpoint(
        _ library: Library,
        of bookID: UUID,
        writingWithin delay: TimeInterval = readingCheckpointDelay
    ) {
        saveQueue.async {
            if let hold = indexWriteHold() {
                // The data directory is checked as well: when it becomes
                // unavailable while the index is protected, the protected
                // index is the hold named.
                if hold == .unreadableIndex, !TextMouthPaths.isDataDirectoryUnavailable {
                    ReadingCheckpointJournal.note(bookID)
                }
                noteSkippedIndexWrite(hold)
                return
            }
            ReadingCheckpointJournal.note(bookID)
            guard pendingLibrary == nil else {
                pendingLibrary = library
                return
            }
            scheduleIndexWrite(of: library, after: delay)
        }
    }

    /// Brings forward the write of a snapshot waiting for its checkpoint
    /// deadline, so library.json takes it within half a second: when a
    /// reader closes, and when a book's record could not take a checkpoint,
    /// being only in the cloud or failing to be written, so the index holds
    /// the position instead. Does nothing when no snapshot waits.
    static func writePendingIndexSoon() {
        saveQueue.async {
            guard let library = pendingLibrary else { return }
            scheduleIndexWrite(of: library, after: saveDelay)
        }
    }

    /// Makes `library` the snapshot waiting to be written, and writes it
    /// `delay` from now unless a newer schedule replaces this one first: only
    /// the latest schedule's block writes (`saveGeneration`), and it writes
    /// whatever snapshot is waiting then. Must run on saveQueue.
    private static func scheduleIndexWrite(of library: Library, after delay: TimeInterval) {
        pendingLibrary = library
        saveGeneration &+= 1
        let generation = saveGeneration

        saveQueue.asyncAfter(deadline: .now() + delay) {
            guard generation == saveGeneration, let library = pendingLibrary else { return }
            // Nothing waits once this is written, which lets the write clear
            // the checkpoint journal (`writeIndexFile`).
            pendingLibrary = nil
            write(library)
        }
    }

    /// Persist the newest pending snapshot before application termination.
    /// The synchronous barrier also waits for any write already in progress.
    /// While index writes are suspended, or the data directory is
    /// unavailable, only package metadata is flushed, so quitting leaves an
    /// unreadable index exactly as it was, and writes nothing where the
    /// library isn't.
    static func flushPendingSave() {
        saveQueue.sync {
            saveGeneration &+= 1
            guard indexWriteHold() == nil else {
                pendingLibrary = nil
                return
            }
            guard let library = pendingLibrary else { return }
            pendingLibrary = nil
            write(library)
        }
        bookInfoSaveQueue.sync {
            let pending = pendingBookInfos
            pendingBookInfos.removeAll()
            for (_, update) in pending {
                writeQueuedBookInfo(update.book, contentIndex: update.contentIndex)
            }
        }
    }

    /// Writes `library` at once, in place of any snapshot waiting, and waits
    /// for it: each feed's index, then library.json, in the one write that
    /// splits the library (`writeIndexFile`), as the move of a download made
    /// before FR11 into its feed's folder needs its row in the feed's index
    /// before library.json lets it go. A failure is reported, with a retry,
    /// as every index write's is; while index writes are held nothing is
    /// written. Call it on the main thread, never from either queue.
    ///
    /// Returns whether every index reached the disk: false while index
    /// writes are held, or when a feed's index or library.json could not be
    /// written. Removing a feed item's file waits for this (FR11, branch
    /// A2): a file goes only once its row is in its feed's index.
    @discardableResult
    static func saveAndWait(_ library: Library) -> Bool {
        saveQueue.sync {
            // `library` is newer than any snapshot waiting, which it holds.
            pendingLibrary = nil
            saveGeneration &+= 1
            return write(library)
        }
    }

    /// Writes the record of the book `bookID` still waiting in the debounce,
    /// if one is, at once, on the metadata queue, and waits for it: for a
    /// change that must be on disk before what it replaced is removed, as
    /// saving edited audio under a new file name removes the old file only
    /// once the book's record names the new one (FR04). A failure is
    /// reported as any queued write's is. Call it after queuing the save.
    ///
    /// Any thread may call it, the main thread too, as removing a feed
    /// item's file does (FR11, branch A2,
    /// `LibraryViewModel.readyFeedFilesForRemoval(of:keepingPackages:)`):
    /// nothing the metadata queue runs ever waits for the main thread, each
    /// report it makes reaching the main thread asynchronously
    /// (`PersistenceFailureCenter`, `DataDirectoryEvents`), so the wait
    /// cannot deadlock; it lasts until the writes queued before this one,
    /// and this one, are done. Work that can wait off the main thread, as
    /// the audio editor's save does, still calls it there.
    static func writePendingBookInfoNow(bookID: UUID) {
        bookInfoSaveQueue.sync {
            guard let update = pendingBookInfos.removeValue(forKey: bookID) else { return }
            writeQueuedBookInfo(update.book, contentIndex: update.contentIndex)
        }
    }

    /// Write a snapshot to library.json. Must run on saveQueue. Debounced saves
    /// and flushes both end here, so this check also stops a snapshot that was
    /// queued before the index was found unreadable.
    ///
    /// A failure is reported with a retry of this snapshot, and the library
    /// then counts as unsaved until an index write succeeds. Returns whether
    /// the snapshot reached the disk.
    @discardableResult
    private static func write(_ library: Library) -> Bool {
        if let hold = indexWriteHold() {
            noteSkippedIndexWrite(hold)
            return false
        }
        do {
            try writeIndexFile(library)
            return true
        } catch {
            print("Failed to save library: \(error)")
            // A feed's index that failed names its own file (FR11).
            let path = (error as? FeedIndexWriteError)?.file.path ?? libraryFileURL.path
            failureCenter.recordFailure(.libraryIndex, path: path, error: error) { failureID in
                retryIndexWrite(library, failureID: failureID)
            }
            reportIfDataDirectoryVanished()
            return false
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
            if let hold = indexWriteHold() {
                noteSkippedIndexWrite(hold)
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
    ///
    /// A snapshot taken before a data-directory move published names its
    /// books under the old root. Their paths are moved under the current
    /// root first, so the snapshot is written in the current data directory
    /// and names its books there; the old library.json is never written
    /// again, nor its folder recreated (TODO S04).
    ///
    /// A write that leaves no newer snapshot waiting holds every reading
    /// checkpoint made so far, so it clears the checkpoint journal (PERF15).
    /// The retry of an older failed snapshot, made while a newer one waits,
    /// leaves the journal for that newer one to clear, and so does a write
    /// while a feed's index is left alone (`FeedShelf.indexesLeftAlone`):
    /// that index holds none of this session's checkpoints, which the next
    /// launch then takes from the records the journal names.
    ///
    /// This is the one write path of library.json, and it splits the library
    /// (FR11): each feed's index takes that feed's rows first
    /// (`writeFeedIndexes(of:)`), and library.json the library's own books
    /// (`Library.encode(to:)`). A feed's index that cannot be written stops
    /// the write before library.json, so a row leaving library.json for its
    /// feed's index is never in neither.
    ///
    /// Neither file is written when its bytes are those this process last
    /// read or wrote of it and it is still there (`SavedFile.OnDiskMemory`).
    /// A write skipped so still counts as a save: the file already holds
    /// exactly this library, so an earlier failed write is settled, and every
    /// checkpoint so far is held, as after a write.
    private static func writeIndexFile(_ library: Library) throws {
        var library = library
        let moved = StorageBoundary.shared.rebaseToCurrent(&library)
        if moved > 0 {
            logIndexEvent(
                "\(moved) book path(s) in a snapshot taken before the data directory moved "
                    + "were moved to its new location before writing"
            )
        }
        try TextMouthPaths.ensureDirectoryStructure()
        try writeFeedIndexes(of: library)
        try writeLibraryFileIfChanged(library)
        failureCenter.recordSuccess(.libraryIndex)
        // Writing again: a later hold is logged afresh.
        loggedIndexWriteHolds.remove(.dataDirectoryUnavailable)
        if pendingLibrary == nil, library.feedShelf.indexesLeftAlone.isEmpty {
            ReadingCheckpointJournal.clear()
        }
    }

    /// Runs `body` while no library index or package record write is under
    /// way, so each of those writes happens wholly before it or wholly after
    /// it. A data-directory move publishes its new location this way
    /// (TODO S04): no write can resolve its file under the old root and then
    /// write after the new one is in use. Never call it from either queue.
    static func betweenWrites(_ body: () -> Void) {
        saveQueue.sync {
            bookInfoSaveQueue.sync(execute: body)
        }
    }

    /// Encodes `library` the way every index write does and replaces
    /// library.json atomically, so a reader never sees a half-written index,
    /// unless the file already holds those bytes: as this process last read
    /// or wrote them, and the file is still there. The bytes are remembered
    /// only once they are on disk; a write that throws forgets what was
    /// remembered, since the file's state is then unknown, so the retry, and
    /// any later save whatever it holds, writes again. Must run on saveQueue.
    private static func writeLibraryFileIfChanged(_ library: Library) throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let data = try encodedIndex(library)
        let file = libraryFileURL
        libraryIndexOnDisk.startOver(unlessIn: TextMouthPaths.root)
        if libraryIndexOnDisk.holds(data, for: libraryIndexMemoryKey, at: file) {
            // A trace line, never an event: checkpoints are frequent.
            DiagnosticLog.trace(.storage, "library.json is unchanged; not written again")
            return
        }
        try libraryIndexOnDisk.write(data, for: libraryIndexMemoryKey) {
            try data.write(to: file, options: .atomic)
        }
    }

    /// `library` as library.json holds it: compact JSON with ISO 8601
    /// dates. Only TextMouth reads the index, so it is not pretty-printed,
    /// which makes it about 16% smaller (PERF15); any JSON reader, older
    /// versions of TextMouth included, reads it the same.
    ///
    /// The bytes are the same for the same library: keys are sorted, as the
    /// feed indexes' are, because `Library.folderSortSettings` is a
    /// dictionary, whose order can differ between two equal ones, and a
    /// save that changed nothing writes nothing (`writeLibraryFileIfChanged`).
    static func encodedIndex(_ library: Library) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(library)
    }

    // MARK: - Feed Indexes (FR11)

    /// Writes each feed's index from `library`'s feed items
    /// (`Library.feedIndexRows`), each row placed where its package is
    /// (`FeedIndexFiles.placed(_:in:of:)`), and only the indexes whose bytes
    /// differ from what this process last read or wrote of them, or whose
    /// file is gone since (`SavedFile.OnDiskMemory`, which library.json's
    /// write uses too): listening to an episode rewrites its feed's small
    /// index, never another feed's.
    /// A feed the library keeps no row of now gets an empty index, unless its
    /// folder is gone too, when there is nothing left to keep and nothing is
    /// made again. Must run on saveQueue, after the data directory's folders
    /// are made.
    /// - Throws: `FeedIndexWriteError` for the first index that could not be
    ///   written; those written before it stay written.
    private static func writeFeedIndexes(of library: Library) throws {
        let root = TextMouthPaths.root
        feedIndexesOnDisk.startOver(unlessIn: root)
        for index in try FeedIndexFiles.encodedIndexes(of: library, placedIn: root) {
            let file = FeedPaths.indexFile(of: index.feedID, in: root)
            // The same bytes are written again when the file is gone, as when
            // it was deleted outside TextMouth since this process wrote it.
            if feedIndexesOnDisk.holds(index.data, for: index.feedID, at: file) {
                continue
            }
            let folder = FeedPaths.itemsFolder(of: index.feedID, in: root)
            if index.rowCount == 0, !FileManager.default.fileExists(atPath: folder.path) {
                feedIndexesOnDisk.remember(index.data, for: index.feedID)
                continue
            }
            try feedIndexesOnDisk.write(index.data, for: index.feedID) {
                do {
                    try FeedIndexFiles.write(index, in: root)
                } catch {
                    throw FeedIndexWriteError(file: file, underlying: error)
                }
            }
        }
    }

    /// Every feed's rows, read from each feed's folder in the data directory
    /// in use (`FeedIndexFiles.readAll(in:fromPackages:reader:)`), on the
    /// shelf, each feed's index kept, for the library model to join the rows
    /// whose files are here to its books once the startup repair is done
    /// (FR11). With `fromPackages`, as while the library index is recovered,
    /// the packages' records are read in place of the indexes. What was read
    /// of each index is noted, so the first save writes only what changed,
    /// and an index left alone, such as one only in the cloud, is left alone
    /// by every save (`FeedShelf.indexesLeftAlone`).
    /// - Parameter reader: How each index file is read: with dataless files
    ///   left in the cloud, unless a test pretends one is.
    static func loadFeedShelf(
        fromPackages: Bool = false,
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading
    ) -> FeedShelf {
        saveQueue.sync {
            let root = TextMouthPaths.root
            let read = FeedIndexFiles.readAll(in: root, fromPackages: fromPackages, reader: reader)
            feedIndexesOnDisk = SavedFile.OnDiskMemory(rootPath: root.path, bytes: read.compactMapValues(\.indexBytes))
            let rows = read.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { read[$0]?.rows ?? [] }
            return FeedShelf(
                rows: rows,
                indexedFeedIDs: Set(read.keys),
                indexesLeftAlone: Set(read.filter(\.value.isLeftAlone).keys),
                // The rows of an index this version cannot read stay with
                // their feeds, to be written back (V03).
                unreadableRows: read.mapValues(\.unreadableRows)
            )
        }
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
    /// The one exception is `movedPlaces`, the places a rebuild of the text
    /// moved (T06's branch D): they ride with the analysis into the same
    /// latest state, each taken only where that state still holds it as it
    /// was (`Book.takeMovedPlaces(original:moved:)`), so a place saved
    /// meanwhile wins. The copy of the old text they were moved from is
    /// discarded once they are written; a result dropped, or a write that
    /// throws, keeps it for the next launch to finish.
    ///
    /// `editedText` is the record of an edit the user made with Edit Text,
    /// which the analysis of that very edit passes (B12): the merged book
    /// takes it after the analysis is applied, so it survives the rule that
    /// drops a record content.md no longer matches. Nil leaves the record
    /// the analysis keeps or drops by that rule.
    ///
    /// `pageReaderVersion` is the page reader that wrote the content.md the
    /// analysis describes (`Book.pageReaderVersion`, PG09), which a
    /// generation or a text kept as it is passes. It is a double optional:
    /// nil keeps the record's own, and `.some(version)` sets it, `.some(nil)`
    /// for a format without pages.
    ///
    /// `textEncoding` is the encoding the content.md was read in and who
    /// decided it (`Book.textEncodingRecord`), which a re-read in an
    /// encoding the listener chose passes (encodingchoice), so the record
    /// never holds the new text beside the old encoding. It is a decision,
    /// which replaces the one the record holds (`Book.bookInfo(replacing:
    /// contentIndex:revisionFloor:decidingTextEncoding:decidingBrailleFileCode:)`);
    /// nil keeps the record's decision, or else the latest state's own
    /// encoding.
    ///
    /// `brailleFileCode` is the id of the braille file characters the
    /// content.md was read in, which a re-read of a BRF or BRL book in other
    /// braille file characters passes (braillecodes), so the record never
    /// holds the new text beside the old code. It is a decision too, which
    /// replaces the code the record holds; nil keeps the code that stands
    /// between the latest state and the record
    /// (`BrailleFileCodeRecord.standing(row:recorded:)`).
    ///
    /// `brailleTable` is the braille table the content.md was translated to
    /// print with, and the liblouis version of this Mac's tables when it is
    /// one of them, which a re-read of a braille book with another braille
    /// code passes (`Book.brailleTable`, FMT21), so the record never holds
    /// the new text beside the old table. Like the other two it is a
    /// decision, which replaces the table the latest state holds; nil keeps
    /// it.
    ///
    /// The book returned holds what the record now holds of the three
    /// decisions, the encoding, the braille file code, and the braille table,
    /// even when the latest state it was merged into (a waiting snapshot, a
    /// lagging row) held others, so the row that takes it catches up (the
    /// review of October 30, finding 2).
    ///
    /// A result is dropped, with one CONTENT_ANALYSIS_DROPPED line in the
    /// debug log, when the latest state describes other content than was
    /// analyzed (`contentChange(from:to:)`), or when it would have to be
    /// merged into a record only in the cloud (FR02), which is never read;
    /// a later pass tries again once the record is on this Mac. A result for
    /// a book removed with Remove from Library Only while it was being
    /// parsed is dropped quietly. None of these is an error.
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
        cacheFormatVersion: String?,
        movedPlaces: MovedPlaces? = nil,
        editedText: EditedText? = nil,
        pageReaderVersion: String?? = nil,
        textEncoding: TextEncodingRecord? = nil,
        brailleFileCode: String? = nil,
        brailleTable: BrailleTableDecision? = nil
    ) throws -> Book? {
        guard !analyzed.tmbDirectoryName.isEmpty else { return nil }

        return try bookInfoSaveQueue.sync { () throws -> Book? in
            guard let state = latestDurableState(of: analyzed) else {
                logDroppedAnalysis(of: analyzed, because: "its record is only in the cloud")
                return nil
            }
            // Compared as the rebased analyzed book, which names its file
            // under the current root, so a data-directory move alone never
            // makes the analysis look like other content (TODO S04).
            if let change = contentChange(from: state.book, to: state.latest) {
                logDroppedAnalysis(of: state.book, because: change)
                return nil
            }

            var merged = state.latest
            merged.applyContentAnalysis(index, cacheFormatVersion: cacheFormatVersion)
            if let editedText {
                merged.editedText = editedText
            }
            if let pageReaderVersion {
                merged.pageReaderVersion = pageReaderVersion
            }
            // The encoding the new text was read in, with who decided it.
            if let textEncoding {
                merged.textEncodingRecord = textEncoding
            }
            // The braille file characters the new text was read in.
            if let brailleFileCode {
                merged.brailleFileCode = brailleFileCode
            }
            // The braille table the new text was translated with, which the
            // record takes from the row it is written from
            // (`Book.bookInfo(replacing:...)`), with its version.
            if let brailleTable {
                merged.brailleTable = brailleTable.table
                merged.brailleTableVersion = brailleTable.version
                merged.brailleTableOrigin = brailleTable.origin
            }
            // The places a rebuild moved, each only where the latest state
            // still holds it as it was when the old text was copied aside.
            if let movedPlaces {
                merged.takeMovedPlaces(original: movedPlaces.original, moved: movedPlaces.moved)
            }
            guard let written = try writeMerged(
                merged,
                contentIndex: index,
                state: state,
                decidingTextEncoding: textEncoding != nil,
                decidingBrailleFileCode: brailleFileCode != nil
            ) else { return nil }
            // The record holds the moved places now: the copy is no longer needed.
            movedPlaces?.discardSnapshot()
            return takingDecisions(of: written, into: merged)
        }
    }

    /// Commits the places a rebuild of `book`'s text moved, alone, and
    /// returns the book as its package now records it, so the caller can give
    /// the library row the same places; nil when nothing was written. This is
    /// how a launch finishes the moves a stop left between a rebuild's write
    /// of the new text and its commit (T06's branch D): the analysis was
    /// never saved, so the places travel without one.
    ///
    /// The moved places merge into the book's latest durable state exactly as
    /// `saveContentAnalysis` merges an analysis (`latestDurableState(of:)`):
    /// the snapshot still waiting in the debounce if there is one, otherwise
    /// the bookInfo.json on disk, never downloaded. Each place is taken only
    /// where that state still holds it as it was
    /// (`Book.takeMovedPlaces(original:moved:)`), so a place saved meanwhile
    /// wins. Nothing else changes, and the package keeps its content index.
    /// The source's hash, format, and path do not matter: the places move
    /// between two texts of content.md, whatever source the new one came from.
    ///
    /// - A record only in the cloud: nil, and the copy of the old text stays
    ///   for a later launch.
    /// - A record of another book, or a book with no package: nil, and the
    ///   copy is discarded, since it can never be finished.
    /// - Nothing to change (every place was saved again meanwhile, or is
    ///   moved already): nothing is written, the copy is discarded, and the
    ///   latest state is returned.
    /// - Otherwise the merged book is written and returned, and the copy is
    ///   discarded. A write that throws keeps the copy and rethrows.
    @discardableResult
    static func saveMovedPlaces(_ movedPlaces: MovedPlaces, for book: Book) throws -> Book? {
        guard !book.tmbDirectoryName.isEmpty else {
            movedPlaces.discardSnapshot()
            return nil
        }

        return try bookInfoSaveQueue.sync { () throws -> Book? in
            guard let state = latestDurableState(of: book) else { return nil }
            guard state.latest.id == book.id else {
                movedPlaces.discardSnapshot()
                return nil
            }

            var merged = state.latest
            guard merged.takeMovedPlaces(original: movedPlaces.original, moved: movedPlaces.moved) else {
                movedPlaces.discardSnapshot()
                return state.latest
            }
            // A waiting snapshot keeps the content index it carries; with
            // none, the package keeps its own (a nil index is not written).
            guard let written = try writeMerged(merged, contentIndex: state.pendingContentIndex, state: state) else {
                return nil
            }
            movedPlaces.discardSnapshot()
            return takingDecisions(of: written, into: merged)
        }
    }

    /// A book's latest durable state, as a merge into it needs it.
    private struct LatestDurableState {
        /// The book the merge is for, rebased to the current data root.
        let book: Book
        /// The book as its latest durable state holds it.
        let latest: Book
        /// The record read from disk; nil when a snapshot waits (then no
        /// record was read) or the package holds none.
        let stored: StoredBookRecord?
        /// Whether a snapshot of the book waits in the debounce.
        let snapshotWaited: Bool
        /// The content index the waiting snapshot carries, if any.
        let pendingContentIndex: BookContentIndex?
    }

    /// The latest durable state of `book`: the snapshot still waiting in the
    /// debounce if there is one, otherwise the bookInfo.json on disk, and
    /// `book` itself only when neither exists (a record that cannot be read
    /// counts as none, as it does for every save). Nil when the merge would
    /// have to go into a record only in the cloud (FR02), which is never
    /// read. Must run on bookInfoSaveQueue.
    private static func latestDurableState(of book: Book) -> LatestDurableState? {
        // A book captured before a data-directory move published names its
        // file under the old root: both copies get their place under the
        // current one, where a write resolves the package (TODO S04).
        let book = StorageBoundary.shared.rebasedToCurrent(book)
        let waiting = pendingBookInfos[book.id]
        let pending = waiting.map { StorageBoundary.shared.rebasedToCurrent($0.book) }
        // The record is read only when no snapshot waits, and never
        // downloaded: one only in the cloud leaves nothing to merge into.
        let stored: StoredBookRecord?
        if pending == nil {
            switch storedRecord(of: book) {
            case .inCloud:
                return nil
            case .readable(let record):
                stored = record
            }
        } else {
            stored = nil
        }
        // The record was read from the book's package, so that is where the
        // book it describes lives: in the library's folder or its feed's, as
        // the book's location says (FR11).
        let latest = pending ?? stored.map { stored -> Book in
            var latest = Book(
                record: stored.info,
                filePath: book.filePath,
                folderPath: book.folderPath,
                tmbDirectoryName: book.tmbDirectoryName
            )
            latest.fileLocation = book.fileLocation
            return latest
        } ?? book
        return LatestDurableState(
            book: book,
            latest: latest,
            stored: stored,
            snapshotWaited: pending != nil,
            pendingContentIndex: waiting?.contentIndex
        )
    }

    /// Writes `merged`, a merge into `state`, and settles what the write
    /// replaces; returns the metadata of the record written, nil when
    /// nothing was (`writeBookInfo`). A failed write throws here,
    /// leaving any waiting snapshot to its own debounce, so the newer user
    /// state outlives the lost result. `decidingTextEncoding` and
    /// `decidingBrailleFileCode` are passed on to the record
    /// (`Book.bookInfo(replacing:contentIndex:revisionFloor:
    /// decidingTextEncoding:decidingBrailleFileCode:)`). Must run on
    /// bookInfoSaveQueue.
    private static func writeMerged(
        _ merged: Book,
        contentIndex: BookContentIndex?,
        state: LatestDurableState,
        decidingTextEncoding: Bool = false,
        decidingBrailleFileCode: Bool = false
    ) throws -> BookMetadata? {
        guard let written = try writeBookInfo(
            merged,
            contentIndex: contentIndex,
            stored: state.stored,
            decidingTextEncoding: decidingTextEncoding,
            decidingBrailleFileCode: decidingBrailleFileCode
        ) else { return nil }
        // The waiting snapshot is on disk now, merged: forget it, so its
        // debounce does not write it a second time.
        cancelQueuedWrites(for: state.book)
        // That snapshot was the book's latest state, so an earlier failed
        // write of the book is settled too. A merge into the stored record
        // alone saved nothing newer and settles nothing.
        if state.snapshotWaited {
            failureCenter.recordSuccess(.book(state.book.id))
        }
        return written
    }

    /// `book` with the decisions the record just written holds, its text
    /// encoding and who decided it, its braille file code, and its braille
    /// table with the version it was read under, which a merge into a lagging
    /// row or a waiting snapshot may not hold: the record keeps the one that
    /// stands (`Book.bookInfo(replacing:...)`), and a book returned to the
    /// library must say what was written, so a rebuild's summary brings the
    /// row up to date (the review of October 30, finding 2).
    private static func takingDecisions(of written: BookMetadata, into book: Book) -> Book {
        var book = book
        book.textEncodingRecord = written.textEncodingRecord
        book.brailleFileCode = written.brailleFileCode
        book.brailleTable = written.brailleTable
        book.brailleTableVersion = written.brailleTableVersion
        book.brailleTableOrigin = written.brailleTableOrigin
        return book
    }

    /// The braille table a re-read of a braille book with another braille
    /// code decides (`saveContentAnalysis`): the table's stored value, and
    /// the liblouis version of this Mac's tables when it is one of them, nil
    /// for a bundled table (`BrailleTableCatalog.versionToRecord(forTable:)`).
    struct BrailleTableDecision: Equatable, Sendable {
        /// The table's stored value (`Book.brailleTable`).
        let table: String
        /// The version the book is read under (`Book.brailleTableVersion`).
        let version: String?
        /// Who chose it (`Book.brailleTableOrigin`): nil, since a re-read
        /// with a table is the listener's choice, which replaces a guess.
        var origin: BrailleTableOrigin? = nil
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
            return "its source file moved from \(DiagnosticLog.loggablePath(analyzed.filePath)) "
                + "to \(DiagnosticLog.loggablePath(latest.filePath))"
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

    /// Records `line` as a storage event: in the debug log and the console,
    /// on one line, a line break in a title or a path becoming a space.
    private static func logLine(_ line: String) {
        DiagnosticLog.event(.storage, line)
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
            guard try writeBookInfo(book, contentIndex: contentIndex) != nil else { return }
            failureCenter.recordSuccess(.book(book.id))
        } catch {
            guard !packageWasMovedOrRemoved(book) else {
                logLine(
                    "BOOK_METADATA_DROPPED: book \(book.id.uuidString.prefix(8)) \"\(book.title)\": "
                        + "no package at \(DiagnosticLog.loggablePath(book.tmbDirectory)); the book moved or left the library "
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
            // The record did not take the book's state, so library.json
            // takes it now rather than at a checkpoint's deadline (PERF15).
            writePendingIndexSoon()
            reportIfDataDirectoryVanished()
        }
    }

    /// Tells the library model when a write failed because a custom data
    /// directory's folder is gone, as when its drive was unplugged or its
    /// cloud service signed out (FR02): the model checks the data directory
    /// again and, finding it unavailable, stops saving and shows the Library
    /// Not Available screen. A missing default location is not reported:
    /// the next index write creates it again, as on a first launch.
    private static func reportIfDataDirectoryVanished() {
        let root = TextMouthPaths.root
        guard !TextMouthPaths.isDefaultLocation(root), isMissing(root) else { return }
        DataDirectoryEvents.reportMissingFolder(root)
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
    /// the package, or the record is only in the cloud (FR02), and returns
    /// the metadata of the record written, which holds the decisions that
    /// stand, or nil when nothing was written. Debounced saves, the
    /// termination flush, and
    /// analysis results all end here. Each write stores the next revision,
    /// and never one below the highest this process has written for the
    /// book, even when the stored record has lost its own. `stored` is the
    /// record now in the package when the caller has just read it, without
    /// downloading anything; otherwise it is read here, the same way
    /// (`storedRecord(of:)`), before anything else in the package is
    /// looked at. Only a write `decidingTextEncoding`, a re-read's, replaces
    /// the decision about the text encoding the stored record holds, and
    /// only a write `decidingBrailleFileCode`, a re-read's in other braille
    /// file characters, the braille file code it holds
    /// (`Book.bookInfo(replacing:contentIndex:revisionFloor:decidingTextEncoding:decidingBrailleFileCode:)`).
    /// Must run on bookInfoSaveQueue.
    ///
    /// Only bookInfo.json is read and, unless `contentIndex` is given,
    /// written (PERF15): the package's contentIndex.json stays as it is, so
    /// a reading checkpoint writes about a kilobyte, however large the
    /// book's index. A record an older version wrote with its index inside
    /// has that index moved into contentIndex.json by its first write here.
    private static func writeBookInfo(
        _ book: Book,
        contentIndex: BookContentIndex?,
        stored: StoredBookRecord? = nil,
        decidingTextEncoding: Bool = false,
        decidingBrailleFileCode: Bool = false
    ) throws -> BookMetadata? {
        let replaced: StoredBookRecord?
        if let stored {
            replaced = stored
        } else {
            switch storedRecord(of: book) {
            case .inCloud(let item):
                noteRecordInCloud(of: book, at: item)
                // library.json is the save's only home now, so it takes the
                // book's state at once rather than at a checkpoint's
                // deadline (PERF15).
                writePendingIndexSoon()
                return nil
            case .readable(let record):
                replaced = record
            }
        }
        guard !isRetired(book) else { return nil }
        let record = book.bookInfo(
            replacing: replaced,
            contentIndex: contentIndex,
            revisionFloor: bookInfoRevisions[book.id] ?? 0,
            decidingTextEncoding: decidingTextEncoding,
            decidingBrailleFileCode: decidingBrailleFileCode
        )
        try record.saveRecord(to: book.tmbDirectory)
        bookInfoRevisions[book.id] = record.state.revision
        booksWithRecordsInCloud.remove(book.id)
        return record.metadata
    }

    // MARK: - Records Only in the Cloud (FR02)

    /// What a record write finds of the record already in a package.
    private enum RecordLookup {
        /// The record, or nil when there is none or it cannot be read, which
        /// counts as none for every save.
        case readable(StoredBookRecord?)
        /// The record, the package holding it, or the package's removal
        /// marker (the item named) is only in the cloud: reading any of them
        /// would download it, so the record is neither read nor written.
        case inCloud(URL)
    }

    /// The record in `book`'s package, read with dataless files left in the
    /// cloud, as orphan adoption reads a package's record: the package, its
    /// record, and its removal marker are first checked without reading
    /// them, and a read refused because the record went to the cloud
    /// meanwhile also leaves it there. The package's content index is never
    /// read here (`StoredBookRecord`). Must run on bookInfoSaveQueue.
    private static func storedRecord(of book: Book) -> RecordLookup {
        let package = book.tmbDirectory
        let record = TextMouthPaths.bookInfoPath(in: package)
        let marker = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        if let inCloud = [package, record, marker].first(where: recordAccess.isInCloud) {
            return .inCloud(inCloud)
        }
        do {
            return .readable(try recordAccess.read(record) { try StoredBookRecord.read(from: package) })
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .inCloud(record)
        } catch {
            return .readable(nil)
        }
    }

    /// Notes that a save of `book` went to the library index alone, because
    /// `item`, its record or a file beside it, is only in the cloud: one
    /// BOOK_RECORD_IN_CLOUD line, written once until the book's record is
    /// written again. Must run on bookInfoSaveQueue.
    private static func noteRecordInCloud(of book: Book, at item: URL) {
        guard booksWithRecordsInCloud.insert(book.id).inserted else { return }
        logLine(
            "BOOK_RECORD_IN_CLOUD: book \(book.id.uuidString.prefix(8)) \"\(book.title)\": "
                + "\(DiagnosticLog.loggablePath(item)) is only in the cloud, so the library index alone "
                + "holds its saves until the record is on this Mac"
        )
    }

    /// Makes package metadata writes reach the files already in a package
    /// through `access` from now on, after any write under way, and returns
    /// the access used before, for the test to put back. Hosted tests
    /// pretend records are dataless this way, since only a sync service
    /// makes dataless files.
    @discardableResult
    static func _useRecordAccessForTesting(_ access: MaintenanceFileAccess) -> MaintenanceFileAccess {
        bookInfoSaveQueue.sync {
            let previous = recordAccess
            recordAccess = access
            return previous
        }
    }

    // MARK: - Reading Checkpoints (PERF15)

    /// The books whose records hold reading checkpoints that library.json
    /// may not hold, as the journal a crash left names them, for launch to
    /// take their newer positions from their records (the library model's
    /// startup repair). Read on saveQueue, so it sees every journal write
    /// queued before it; empty when there is no journal. Call it before the
    /// launch's first index write, which clears the journal.
    static func booksWithCheckpointsAhead() -> Set<UUID> {
        saveQueue.sync { ReadingCheckpointJournal.books() }
    }

    /// Forgets the snapshot waiting to be written without writing it, as a
    /// crash would, leaving the checkpoint journal as it is. Tests use it to
    /// stand for the crash a launch recovers from.
    static func _discardPendingIndexSaveForTesting() {
        saveQueue.sync {
            pendingLibrary = nil
            saveGeneration &+= 1
        }
    }

    /// The checkpoint journal: a small file in the data directory naming the
    /// books whose package records hold reading checkpoints newer than
    /// library.json (`TextMouthPaths.readingCheckpointsFile`), as
    /// `{"books": [<book ID>, ...]}`. A checkpoint adds its book when the
    /// journal does not name it yet, so listening to one book writes the
    /// journal once per index write, and every index write that holds all
    /// checkpoints removes it. The file is the only state, read afresh each
    /// time, so another Mac's launch removing it after taking the positions
    /// costs this Mac nothing but the next checkpoint's note.
    ///
    /// A journal that cannot be written loses only what it would have
    /// recovered after a crash, the last few minutes of position, so failures
    /// pass silently, as for any cache. Every function must run on saveQueue.
    private enum ReadingCheckpointJournal {
        /// What the file holds.
        struct Contents: Codable {
            /// The books named, in order of their IDs.
            var books: [UUID]
        }

        /// Names `bookID` in the journal, unless it does already.
        static func note(_ bookID: UUID) {
            var named = books()
            guard named.insert(bookID).inserted else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let contents = Contents(books: named.sorted { $0.uuidString < $1.uuidString })
            try? encoder.encode(contents).write(to: TextMouthPaths.readingCheckpointsFile, options: .atomic)
        }

        /// The books the journal names; none when there is no journal or it
        /// cannot be read, read with dataless files left in the cloud, so
        /// saveQueue never waits on the network for it.
        static func books() -> Set<UUID> {
            let data = DatalessFiles.withoutDownloading {
                try? Data(contentsOf: TextMouthPaths.readingCheckpointsFile)
            }
            guard let data, let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return [] }
            return Set(contents.books)
        }

        /// Removes the journal: library.json holds every checkpoint now.
        static func clear() {
            try? FileManager.default.removeItem(at: TextMouthPaths.readingCheckpointsFile)
        }
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
    ///
    /// A failed write of the book's record is withdrawn either way: nothing
    /// is left to save for a book that has left the library (TODO S09).
    static func retirePackage(of book: Book, removedAt: Date = Date()) throws -> PackageRetirement {
        try bookInfoSaveQueue.sync { () throws -> PackageRetirement in
            guard !book.tmbDirectoryName.isEmpty, !isMissing(book.tmbDirectory) else {
                cancelQueuedWrites(for: book)
                failureCenter.withdraw(.book(book.id))
                RemovedFromLibraryMarker.log("removed from the library; it has no package on disk", for: book)
                return PackageRetirement(isPackageMarked: false, recordDeletionError: nil)
            }
            let package = book.tmbDirectory
            // The marker keeps the braille file code and the text encoding
            // that stand between the row and the record about to be deleted,
            // not the row's alone, which may lag behind a re-read or have
            // lost them to an earlier TextMouth (the review of October 30,
            // finding 2); both are read without downloading anything.
            var standing = book
            standing.brailleFileCode = book.recordedBrailleFileCode()
            standing.textEncodingRecord = book.recordedTextEncodingRecord()
            do {
                try RemovedFromLibraryMarker(book: standing, removedAt: removedAt).write(into: package)
            } catch {
                RemovedFromLibraryMarker.log(
                    "stays in the library: could not write the removal marker in \(package.path): \(error)",
                    for: book
                )
                throw LibraryRemovalError.couldNotMarkPackage(packageName: book.tmbDirectoryName, underlying: error)
            }
            retiredPackages.insert(RetiredPackage(book))
            cancelQueuedWrites(for: book)
            failureCenter.withdraw(.book(book.id))
            RemovedFromLibraryMarker.log("removed from the library; its package stays at \(package.path)", for: book)
            return PackageRetirement(isPackageMarked: true, recordDeletionError: deleteRecord(of: book))
        }
    }

    /// Forgets `book`, which has just left the library with its package
    /// deleted (TODO S09). Writes still queued for it are dropped, since its
    /// package is gone, and a failed write of its record is withdrawn, since
    /// nothing is left to save. It runs on the metadata queue, after any
    /// write for the book already under way, so that write's report cannot
    /// outlast the withdrawal.
    static func forgetDeletedBook(_ book: Book) {
        bookInfoSaveQueue.sync {
            cancelQueuedWrites(for: book)
            failureCenter.withdraw(.book(book.id))
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
    ///
    /// Each feed's index is read with it (FR11): a library that loads holds
    /// every feed's rows on its shelf (`loadFeedShelf(fromPackages:)`).
    static func load() -> LibraryLoadResult {
        let result = loadLibraryIndex()
        guard case .loaded(var library) = result else { return result }
        library.feedShelf = loadFeedShelf()
        return .loaded(library)
    }

    /// library.json alone, as `load()` reads it.
    private static func loadLibraryIndex() -> LibraryLoadResult {
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
                let library = try decodeLibrary(from: data)
                rememberLibraryIndex(data, readFrom: url)
                return .loaded(library)
            } catch {
                // What the file holds is not a library this process knows,
                // so whatever it remembered of it must not stand in for it.
                if url == libraryFileURL { libraryIndexOnDisk.forget(libraryIndexMemoryKey) }
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

    /// Notes the bytes of a library index that read and decoded, so the first
    /// save after launch writes nothing when it changes nothing, as
    /// `loadFeedShelf` does for the feed indexes. Only library.json itself is
    /// noted: a legacy index is migrated by writing the current one. Must run
    /// on saveQueue.
    private static func rememberLibraryIndex(_ data: Data, readFrom url: URL) {
        guard url == libraryFileURL else { return }
        libraryIndexOnDisk.startOver(unlessIn: TextMouthPaths.root)
        libraryIndexOnDisk.remember(data, for: libraryIndexMemoryKey)
    }

    /// Decode an index the way every index read does. An index that holds
    /// rows this version cannot read (V03) logs once how many it keeps; the
    /// log never names them.
    private static func decodeLibrary(from data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: data)
        let kept = library.unreadableRows.count
        if kept > 0 {
            DiagnosticLog.event(
                .storage,
                "LIBRARY_ROWS_KEPT: \(CountWording.phrase(kept, singular: "row", plural: "rows")) of library.json "
                    + "need a newer TextMouth; kept as they are and not shown"
            )
        }
        return library
    }

    // MARK: - Unreadable Index Protection

    /// Stop every library.json write. Must run on saveQueue. A snapshot still
    /// waiting to be written is discarded: writing it would replace the file
    /// that just failed to load.
    private static func suspendIndexWrites(after failure: LibraryIndexReadFailure) {
        indexWritesSuspended = true
        loggedIndexWriteHolds.remove(.unreadableIndex)
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
    ///
    /// Nor is an index that can be read again replaced, or left unread
    /// behind the new one. The index a load would read now, library.json or
    /// else the legacy index, is re-read first, since it may have changed
    /// since the failed load: another Mac may have finished saving it, or
    /// the user restored it from a backup while the recovery options were
    /// open. When it decodes, as a load decodes it, it is the user's index
    /// again, with the folders, manual order, and rows the rebuilt library
    /// would lose, and Try Again uses it: nothing is written or preserved,
    /// and index writes stay suspended.
    /// - Throws: `LibraryIndexRecoveryError.indexReadableAgain` when that
    ///   index can be read again, or `.couldNotPreserve` when library.json
    ///   could not be preserved; nothing is written either way.
    @discardableResult
    static func replaceUnreadableIndex(with library: Library) throws -> URL? {
        try saveQueue.sync { () throws -> URL? in
            let indexURL = libraryFileURL
            var preservedCopy: URL?
            // Re-read now, choosing the file as a load does
            // (`loadLibraryIndex()`): it may have changed since the failed load.
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let currentBytes = try? Data(contentsOf: indexURL)
                try refuseRebuildIfReadable(currentBytes, readFrom: indexURL)
                preservedCopy = LibraryIndexQuarantine.preserve(indexURL, bytes: currentBytes)
                guard preservedCopy != nil else {
                    throw LibraryIndexRecoveryError.couldNotPreserve(indexURL)
                }
            } else if let legacyURL = legacyLibraryFileURL, FileManager.default.fileExists(atPath: legacyURL.path) {
                // The legacy index stays untouched, but a load would read
                // the rebuilt library.json in its place from now on.
                let legacyBytes = try? Data(contentsOf: legacyURL)
                try refuseRebuildIfReadable(legacyBytes, readFrom: legacyURL)
            }
            try writeIndexFile(library)
            endIndexWriteSuspension()
            logIndexEvent(
                "rebuilt the library index with \(library.libraryBookCount) book(s); "
                    + (preservedCopy.map { "previous index kept at \($0.path)" }
                        ?? "no index file was there to replace")
            )
            return preservedCopy
        }
    }

    /// Refuses Rebuild Library Index when `bytes`, re-read from `url`, the
    /// index a load would read now, decode as a library the way a load
    /// decodes them (`decodeLibrary(from:)`): that index can be read again,
    /// for Try Again to use. Bytes that could not be read refuse nothing.
    /// Must run on saveQueue.
    /// - Throws: `LibraryIndexRecoveryError.indexReadableAgain` when they
    ///   decode.
    private static func refuseRebuildIfReadable(_ bytes: Data?, readFrom url: URL) throws {
        guard let bytes, (try? decodeLibrary(from: bytes)) != nil else { return }
        logIndexEvent(
            "did not rebuild the library index: \(url.path) can be read again, for Try Again to use; "
                + "library index writes stay suspended"
        )
        throw LibraryIndexRecoveryError.indexReadableAgain
    }

    /// Must run on saveQueue. Anything captured during the suspension is stale.
    private static func endIndexWriteSuspension() {
        indexWritesSuspended = false
        pendingLibrary = nil
        saveGeneration &+= 1
    }

    /// Why library.json may not be written now: its unreadable index is
    /// protected, or the library model found the data directory in use
    /// unavailable (FR02). Nil when it may be written. Must run on saveQueue.
    private static func indexWriteHold() -> IndexWriteHold? {
        if indexWritesSuspended { return .unreadableIndex }
        if TextMouthPaths.isDataDirectoryUnavailable { return .dataDirectoryUnavailable }
        return nil
    }

    /// Must run on saveQueue. Logs only the first write skipped for `hold`
    /// since it began; later ones would repeat it every few seconds of
    /// reading.
    private static func noteSkippedIndexWrite(_ hold: IndexWriteHold) {
        guard loggedIndexWriteHolds.insert(hold).inserted else { return }
        logIndexEvent(hold.skippedWriteNote)
    }

    /// Records a library index recovery event in the console and the debug log.
    private static func logIndexEvent(_ message: String) {
        logLine("LIBRARY_INDEX: \(message)")
    }
}

/// A feed's index that could not be written (FR11): the save stopped before
/// library.json, which keeps every row it held, and is reported and retried
/// as a failed library index write, naming this file.
struct FeedIndexWriteError: LocalizedError {
    /// The index that could not be written.
    let file: URL
    /// Why it could not be written.
    let underlying: any Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}
