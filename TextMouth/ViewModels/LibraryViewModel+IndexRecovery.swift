import SwiftUI

/// The library index on disk exists but could not be read. While the model
/// publishes this, the library shown is provisional (rebuilt from the
/// packages and folders on disk) and nothing writes library.json.
struct LibraryIndexRecovery {
    /// The latest failure to read the index; Try Again replaces it.
    var failure: LibraryIndexReadFailure
    /// The result of the last recovery action that did not end recovery,
    /// shown in the recovery sheet until another action runs.
    var lastAttempt: LibraryIndexRecoveryOutcome?
    /// The parts of the library's arrangement, which only the index keeps,
    /// that the provisional library could not take from this session or
    /// from the unreadable index (FR09), which the outcome of saving the
    /// provisional library as the new index names.
    var arrangementNotKept: LibraryIndexArrangement = []
}

/// The parts of a library's arrangement that only its index, library.json,
/// keeps, and no book's record: the reading list (FR09), and the sort
/// settings of the folders and the views. While the index cannot be read,
/// the provisional library takes each from this session when it holds one,
/// or else from the unreadable index's own bytes, so Rebuild Library Index
/// keeps them (`LibraryViewModel.recoveredArrangement(session:unreadableIndex:)`).
struct LibraryIndexArrangement: OptionSet, Equatable, Sendable {
    let rawValue: Int

    /// The reading list: its books, in its order, and its options.
    static let readingList = LibraryIndexArrangement(rawValue: 1 << 0)
    /// The sort setting saved for each folder and view.
    static let sortSettings = LibraryIndexArrangement(rawValue: 1 << 1)

    /// The sentence saying these parts could not be read in the unreadable
    /// index, named `index` as the sentence's reader knows it: "TextMouth
    /// could not read the reading list or the sort settings in the
    /// previous index."; nil for no part. The recovery sheet and the
    /// outcome of saving the provisional library both say it.
    func notReadSentence(in index: String) -> String? {
        var parts: [String] = []
        if contains(.readingList) {
            parts.append("the reading list")
        }
        if contains(.sortSettings) {
            parts.append("the sort settings")
        }
        guard !parts.isEmpty else { return nil }
        return "TextMouth could not read \(parts.joined(separator: " or ")) in \(index)."
    }
}

/// What a recovery action did, with the sentence that describes it.
enum LibraryIndexRecoveryOutcome: Equatable {
    /// Try Again read the index, and the library is back to normal.
    case restored(bookCount: Int)
    /// Try Again found no index at all any more, so there was nothing left to
    /// protect and the provisional library was saved as the new index;
    /// `notKept` names the parts of the arrangement it could not keep.
    case savedProvisionalLibrary(bookCount: Int, preservedCopy: URL?, notKept: LibraryIndexArrangement = [])
    /// Try Again still could not read the index.
    case stillUnreadable(reason: String)
    /// Rebuild Library Index saved the provisional library as the new index;
    /// `notKept` names the parts of the arrangement it could not keep.
    case rebuilt(bookCount: Int, preservedCopy: URL?, notKept: LibraryIndexArrangement = [])
    /// Rebuild Library Index replaced nothing.
    case rebuildFailed(reason: String)
    /// No recovery was in progress.
    case notRecovering

    /// Plain sentences for VoiceOver and for the recovery sheet. Paths are
    /// spelled out so the preserved copy can be found by name.
    var message: String {
        switch self {
        case .restored(let bookCount):
            return "The library index was read successfully. Your library has "
                + "\(CountWording.books(bookCount)), and changes are being saved again."
        case .savedProvisionalLibrary(let bookCount, let preservedCopy, let notKept):
            return "The unreadable library index is no longer there, so TextMouth saved "
                + "the library rebuilt from your books as the new index, with \(CountWording.books(bookCount))."
                + Self.notKeptSentence(notKept)
                + Self.keptCopySentence(preservedCopy)
        case .stillUnreadable(let reason):
            return "The library index still could not be read. \(reason)"
        case .rebuilt(let bookCount, let preservedCopy, let notKept):
            return "The library index was rebuilt with \(CountWording.books(bookCount))."
                + Self.notKeptSentence(notKept)
                + Self.keptCopySentence(preservedCopy)
        case .rebuildFailed(let reason):
            return "The library index was not rebuilt. \(reason)"
        case .notRecovering:
            return "The library index is already readable."
        }
    }

    /// Names the parts of the arrangement the new index could not keep,
    /// when any: " TextMouth could not read the reading list or the sort
    /// settings in the previous index." The sentence after it names the
    /// copy that keeps them.
    private static func notKeptSentence(_ notKept: LibraryIndexArrangement) -> String {
        notKept.notReadSentence(in: "the previous index").map { " " + $0 } ?? ""
    }

    /// Names the preserved copy of the old index, when there is one.
    private static func keptCopySentence(_ preservedCopy: URL?) -> String {
        guard let preservedCopy else { return "" }
        return " The previous index is kept at \(preservedCopy.path)."
    }
}

/// The reading list and the sort settings that an index which cannot be read
/// as a whole still holds, read from its bytes on their own (FR09). A part
/// of the index in a layout this version cannot read (its folders, or its
/// list of books when it is not a list) makes the whole index unreadable but
/// leaves these readable; an index cut short, or not JSON at all, gives
/// neither. A single book entry this version cannot read, damaged or in a
/// format a later version wrote, no longer makes the index unreadable: its
/// row is kept as it is, unshown (V03, `Library.unreadableRows`).
struct SalvagedLibraryArrangement: Equatable {
    /// The reading list read; the empty list for an index that holds none,
    /// as one written before the list existed; nil when the index holds one
    /// that cannot be read.
    var readingList: ReadingList?
    /// The sort settings read; none for an index that holds none; only the
    /// readable ones when some cannot be read, and nil when none can be.
    var sortSettings: [String: FolderSortSetting]?
    /// The parts the index holds that could not be read, wholly or in part.
    var unread: LibraryIndexArrangement

    /// Reads the arrangement from `data`, the bytes of an unreadable index,
    /// or from nothing, when no copy of it could be read, which gives
    /// neither part.
    static func read(from data: Data?) -> SalvagedLibraryArrangement {
        guard let data, let fields = try? JSONDecoder().decode(Fields.self, from: data) else {
            return SalvagedLibraryArrangement(readingList: nil, sortSettings: nil, unread: [.readingList, .sortSettings])
        }
        return SalvagedLibraryArrangement(
            readingList: fields.readingList,
            sortSettings: fields.sortSettings,
            unread: fields.unread
        )
    }

    /// The two parts as an index holds them, each read on its own, so one
    /// that cannot be read never hides the other.
    private struct Fields: Decodable {
        var readingList: ReadingList? = ReadingList()
        var sortSettings: [String: FolderSortSetting]? = [:]
        var unread: LibraryIndexArrangement = []

        /// The keys library.json writes them under (`Library.CodingKeys`).
        private enum CodingKeys: String, CodingKey {
            case readingList, folderSortSettings
        }

        /// Reads each part present in the index; a missing part, or one
        /// written as null, holds nothing and so loses nothing.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if Self.holds(.readingList, in: container) {
                readingList = try? container.decode(ReadingList.self, forKey: .readingList)
                if readingList == nil {
                    unread.insert(.readingList)
                }
            }
            if Self.holds(.folderSortSettings, in: container) {
                if let settings = try? container.decode([String: FolderSortSetting].self, forKey: .folderSortSettings) {
                    sortSettings = settings
                } else {
                    // Keep every setting that can be read, and count the
                    // part as not wholly read.
                    let each = try? container.decode([String: Lenient<FolderSortSetting>].self, forKey: .folderSortSettings)
                    sortSettings = each?.compactMapValues(\.value)
                    unread.insert(.sortSettings)
                }
            }
        }

        /// Whether `container` holds a value other than null for `key`.
        private static func holds(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) -> Bool {
            container.contains(key) && (try? container.decodeNil(forKey: key)) != true
        }
    }

    /// A value read if it can be, and nil, without failing, if it cannot.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

/// Loading the library index, and recovering when it cannot be read.
extension LibraryViewModel {

    // MARK: - Loading

    /// Reads library.json and runs the startup repair; called once, at
    /// startup (Try Again uses `retryLibraryIndex()`). An unreadable index,
    /// which the service has already preserved and protected by suspending
    /// index writes, puts the model into recovery: the library shown is
    /// rebuilt from disk and the recovery options are presented.
    func loadLibraryIndex() {
        switch LibraryPersistenceService.load() {
        case .loaded(let loaded):
            library = loaded
        case .missing:
            // No library.json, but each feed's index may be there (FR11).
            library = Library(feedShelf: LibraryPersistenceService.loadFeedShelf())
        case .unreadable(let failure):
            beginIndexRecovery(failure)
        }
        migrateOldBooksIfNeeded()
    }

    /// Reads library.json again once the data directory is back after it was
    /// lost while TextMouth ran (FR02). The index on disk is authoritative,
    /// as at a launch; the reading progress and moved packages of this
    /// session are carried into it (`carryingRecoverySessionState`), and
    /// then the repair, a save, and the maintenance that waited all run.
    /// An index gone meanwhile leaves this session's library, saved as the
    /// new index, as a fresh start would; one that can't be read enters
    /// recovery, as at launch. When the index was already unreadable before
    /// the loss, recovery's own Try Again reads it.
    func reloadLibraryAfterDataDirectoryReturned() {
        guard indexRecovery == nil else {
            retryLibraryIndex()
            return
        }
        switch LibraryPersistenceService.load() {
        case .loaded(let loaded):
            library = Self.carryingRecoverySessionState(from: library, into: loaded)
            resumeStartupWork()
        case .missing:
            resumeStartupWork()
        case .unreadable(let failure):
            beginIndexRecovery(failure)
            migrateOldBooksIfNeeded()
        }
    }

    /// Enters recovery for an index that exists but can't be read: the
    /// library shown starts with no books, to be rebuilt from disk by the
    /// repair, and the recovery options are presented.
    ///
    /// The feed items are not in library.json, so its failure loses none of
    /// them (FR11): the rows the model holds stay, on the shelf, and when it
    /// holds none, as at launch, each feed's rows are read from its packages,
    /// whose records hold their latest state, as the provisional library's
    /// books are read from theirs.
    ///
    /// Nor is the arrangement only the index keeps lost (FR09): the reading
    /// list and the sort settings come from this session when it holds
    /// them, as when the data directory came back with an unreadable index,
    /// and otherwise from the unreadable index's preserved bytes, as far as
    /// they can be read (`recoveredArrangement(session:unreadableIndex:)`).
    /// The books adopted from their records keep their IDs, so the list
    /// names them; Rebuild Library Index saves it all.
    private func beginIndexRecovery(_ failure: LibraryIndexReadFailure) {
        var feedItems = library
        feedItems.shelveFeedItems()
        let heldNone = feedItems.feedShelf.isEmpty && feedItems.feedShelf.indexedFeedIDs.isEmpty
        let arrangement = Self.recoveredArrangement(session: library) {
            // The bytes that failed, as preserved, or, when no copy could be
            // made, the unreadable file itself, which is only read.
            try? Data(contentsOf: failure.quarantineURL ?? failure.indexURL)
        }
        library = Library(
            folderSortSettings: arrangement.sortSettings,
            readingList: arrangement.readingList,
            feedShelf: heldNone ? LibraryPersistenceService.loadFeedShelf(fromPackages: true) : feedItems.feedShelf,
            // Rows a newer TextMouth wrote, read before the index failed, are
            // still the user's: Rebuild Library Index writes them back (V03).
            unreadableRows: library.unreadableRows
        )
        indexRecovery = LibraryIndexRecovery(failure: failure, arrangementNotKept: arrangement.notKept)
        showIndexRecoveryOptions = true
    }

    /// The arrangement a provisional library starts with: the reading list
    /// and the sort settings, and the parts of them it could not keep.
    struct RecoveredArrangement: Equatable {
        /// The reading list, empty when none could be kept.
        var readingList: ReadingList
        /// The sort settings, none when none could be kept.
        var sortSettings: [String: FolderSortSetting]
        /// The parts this session did not hold and the unreadable index's
        /// bytes did not give.
        var notKept: LibraryIndexArrangement
    }

    /// The arrangement of the library shown while the index cannot be read
    /// (FR09): each part from `session`, the library this session held as
    /// the index became unreadable, when it holds one, since it is the
    /// latest; otherwise from `unreadableIndex()`, the unreadable index's
    /// bytes, read only when a part is needed and as far as it can be
    /// (`SalvagedLibraryArrangement`). At launch the session holds neither.
    nonisolated static func recoveredArrangement(
        session: Library,
        unreadableIndex: () -> Data?
    ) -> RecoveredArrangement {
        let holdsReadingList = session.readingList != ReadingList()
        let holdsSortSettings = !session.folderSortSettings.isEmpty
        guard !holdsReadingList || !holdsSortSettings else {
            return RecoveredArrangement(
                readingList: session.readingList,
                sortSettings: session.folderSortSettings,
                notKept: []
            )
        }
        let salvaged = SalvagedLibraryArrangement.read(from: unreadableIndex())
        var notKept: LibraryIndexArrangement = []
        if !holdsReadingList, salvaged.unread.contains(.readingList) {
            notKept.insert(.readingList)
        }
        if !holdsSortSettings, salvaged.unread.contains(.sortSettings) {
            notKept.insert(.sortSettings)
        }
        return RecoveredArrangement(
            readingList: holdsReadingList ? session.readingList : salvaged.readingList ?? ReadingList(),
            sortSettings: holdsSortSettings ? session.folderSortSettings : salvaged.sortSettings ?? [:],
            notKept: notKept
        )
    }

    /// Builds the provisional library shown while the index cannot be read:
    /// every package with a readable bookInfo.json, found by the existing
    /// orphan adoption, and a row for every folder on disk. Nothing is saved.
    func buildProvisionalLibrary() {
        FileImportService.adoptOrphanedTMBPackages(library: &library)
        FileImportService.adoptLibraryFolders(library: &library)
    }

    // MARK: - Recovery Actions

    /// Try Again: reads the index again. When it loads now, reading progress
    /// and moved packages from this session are carried into it, index
    /// writes resume, and the ordinary startup work runs: the repair (which
    /// also adopts books imported meanwhile) and a save.
    @discardableResult
    func retryLibraryIndex() -> LibraryIndexRecoveryOutcome {
        guard let recovery = indexRecovery else { return .notRecovering }
        switch LibraryPersistenceService.load() {
        case .unreadable(let failure):
            let outcome = LibraryIndexRecoveryOutcome.stillUnreadable(reason: failure.reason)
            // The library shown keeps the arrangement it began recovery
            // with, and so what of it could not be kept.
            indexRecovery = LibraryIndexRecovery(
                failure: failure,
                lastAttempt: outcome,
                arrangementNotKept: recovery.arrangementNotKept
            )
            return outcome
        case .loaded(let loaded):
            let merged = Self.carryingRecoverySessionState(from: library, into: loaded)
            finishRecovery()
            library = merged
            resumeStartupWork()
            return .restored(bookCount: library.libraryBookCount)
        case .missing:
            // The damaged file was moved or deleted outside TextMouth, so
            // nothing is left to protect. Keep the provisional library and
            // save it, as a fresh start would.
            finishRecovery()
            resumeStartupWork()
            return .savedProvisionalLibrary(
                bookCount: library.libraryBookCount,
                preservedCopy: recovery.failure.quarantineURL,
                notKept: recovery.arrangementNotKept
            )
        }
    }

    /// Rebuild Library Index: saves the provisional library as the new index,
    /// with the reading list and the sort settings it began recovery with,
    /// from this session or from the unreadable index (FR09); the outcome
    /// says which of them could not be kept. Folder rows and manual order
    /// that only the unreadable index held are lost; its preserved copy
    /// keeps them. Nothing is replaced when the current file cannot be
    /// preserved first.
    @discardableResult
    func rebuildLibraryIndex() -> LibraryIndexRecoveryOutcome {
        guard let recovery = indexRecovery else { return .notRecovering }
        do {
            let replacedCopy = try LibraryPersistenceService.replaceUnreadableIndex(with: library)
            finishRecovery()
            return .rebuilt(
                bookCount: library.libraryBookCount,
                preservedCopy: replacedCopy ?? recovery.failure.quarantineURL,
                notKept: recovery.arrangementNotKept
            )
        } catch {
            let outcome = LibraryIndexRecoveryOutcome.rebuildFailed(reason: error.localizedDescription)
            indexRecovery?.lastAttempt = outcome
            return outcome
        }
    }

    /// Quit: exits without writing library.json. Index writes stay suspended
    /// while recovering, so the termination flush saves only package metadata.
    func quitWithoutWritingLibraryIndex() {
        #if os(macOS)
        QuitRequest.ask()
        #else
        // iOS apps do not quit themselves (phase 0): nothing happens, and the
        // recovery screen stays up for another choice.
        #endif
    }

    /// Throws while the index cannot be read. Data-directory maintenance
    /// (Rebuild Directory, Reset to Default, Change Location) reconciles or
    /// copies the library index, so it would act on, or write out, the
    /// provisional library; it waits until recovery ends. While the data
    /// directory can't be used at all (FR02), there is no index to read and
    /// nothing to copy or rebuild, so it says that instead.
    func ensureLibraryIndexIsReadable() throws {
        if dataDirectoryUnavailability != nil {
            throw DataDirectoryUnavailableError(root: TextMouthPaths.root)
        }
        if indexRecovery != nil {
            throw LibraryIndexRecoveryError.indexUnreadable
        }
    }

    /// Ends recovery: index writes resume and the recovery options close.
    private func finishRecovery() {
        LibraryPersistenceService.resumeIndexWrites()
        indexRecovery = nil
        showIndexRecoveryOptions = false
    }

    /// Runs the startup work skipped while the index could not be read: the
    /// ordinary repair and a save, which also writes an index whose legacy
    /// migration was deferred. The app's model also refreshes text caches and
    /// statistics; the inert model used by tests starts no background work.
    private func resumeStartupWork() {
        migrateOldBooksIfNeeded()
        save()
        if runsBackgroundWork {
            updateContentCachesAndStatistics()
        }
    }

    // MARK: - Merging a Recovery Session

    /// Carries what happened while the index could not be read into the index
    /// that loaded on Try Again. The loaded index stays authoritative for
    /// folders, sort settings, order, and book metadata. For each book in
    /// both, it takes from the provisional library:
    /// - the package location, when the recorded file is gone but the
    ///   provisional path exists, because the package moved meanwhile; and
    /// - the reading position with its playback times, and the last-opened
    ///   date, when they are newer. They are timestamped, so newer is known
    ///   to be the latest progress, which was saved to bookInfo.json.
    ///
    /// The feed items' rows are the session's (FR11), on the shelf for the
    /// startup repair to join again: no feed's index was written while the
    /// library index could not be, or while the data directory was away, so
    /// the session holds their latest state. A feed only the loaded library
    /// read keeps its rows from there.
    nonisolated static func carryingRecoverySessionState(
        from provisional: Library,
        into loaded: Library,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Library {
        let sessionBooks = Dictionary(
            provisional.libraryBooks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var merged = loaded
        merged.feedShelf = feedItems(of: provisional, over: loaded)
        for index in merged.books.indices {
            guard let session = sessionBooks[merged.books[index].id] else { continue }
            var book = merged.books[index]
            if !fileExists(book.filePath), fileExists(session.filePath) {
                book.filePath = session.filePath
                book.folderPath = session.folderPath
                book.tmbDirectoryName = session.tmbDirectoryName
            }
            if let position = session.readingPosition,
               position.lastUpdated > (book.readingPosition?.lastUpdated ?? .distantPast) {
                book.readingPosition = position
                book.lastPlaybackStarted = session.lastPlaybackStarted
                book.lastPlaybackStopped = session.lastPlaybackStopped
            }
            if let opened = session.lastOpened, opened > (book.lastOpened ?? .distantPast) {
                book.lastOpened = opened
            }
            merged.books[index] = book
        }
        return merged
    }

    /// The feed shelf of a library merged from `session` into `loaded`
    /// (FR11): every feed item of `session`, among its books or on its
    /// shelf, and, of each feed `session` keeps no index of, the rows
    /// `loaded` read, with every feed's index either keeps kept. An index
    /// file `session` leaves alone stays left alone; one only `loaded` left
    /// alone (only in the cloud when it was read again) is left alone when
    /// its rows come from `loaded`, which then stand in for it, and not when
    /// the session's own rows of that feed, read before, are the ones kept.
    /// The rows of a feed's index this version cannot read (V03) are the
    /// session's, and, of a feed it holds none of, those `loaded` read.
    nonisolated static func feedItems(of session: Library, over loaded: Library) -> FeedShelf {
        var items = session
        items.shelveFeedItems()
        var shelf = items.feedShelf
        let sessionFeeds = shelf.indexedFeedIDs
        for row in loaded.feedShelf.rows {
            guard let feedID = row.feedLink?.feedID, !sessionFeeds.contains(feedID) else { continue }
            shelf.put(row)
        }
        for feedID in loaded.feedShelf.indexedFeedIDs {
            shelf.keepIndex(of: feedID)
        }
        // The rows of a feed's index that this version cannot read (V03)
        // stay with their feed: the session's own, when it read some, and
        // else those `loaded` read, as a session that read its rows from
        // the packages could not have known them.
        for (feedID, rows) in loaded.feedShelf.unreadableRows where shelf.unreadableRows[feedID] == nil {
            shelf.keepUnreadableRows(rows, of: feedID)
        }
        for feedID in loaded.feedShelf.indexesLeftAlone where !sessionFeeds.contains(feedID) {
            shelf.leaveIndexAlone(of: feedID)
        }
        return shelf
    }
}
