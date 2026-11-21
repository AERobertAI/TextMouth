import Foundation
import os

// MARK: - Reading a Copy of the Library, Read-Only (Phase 0 of the local-first design)

/// What Compare Libraries found.
enum LibraryComparisonOutcome: Equatable, Sendable {
    /// The two copies hold one library, and this is what differs.
    case compared(LibraryComparison)
    /// The folders hold different libraries, by identity.
    case differentLibraries
    /// Nothing could be compared, because these files, which the comparison
    /// needs, were not read: an identity marker or a library index.
    case notComparable([LibraryUnreadFile])
    /// The listener stopped it.
    case cancelled
}

/// Reads the files of a copy of the library, and compares two copies, with
/// no write to either: every file is read and nothing else is done to it.
///
/// A file only in the cloud is read with downloading allowed (it is asked of
/// the sync service with `fetch`, which blocks until the file arrives), never
/// on the main thread (the caller runs this off it), and with a limit on
/// every wait: a file that has not arrived after `waitLimit` seconds is
/// listed as unread, as is any file that can't be read or decoded, never as
/// missing. Once a file is on this Mac it is read inside
/// `DatalessFiles.withoutDownloading`, so no read waits on the network
/// whatever the sync service does.
///
/// Both ways of asking the system are passed in, so tests need no real
/// drive: `itemStatus` says where a file's content is, and `fetch` brings
/// one here.
/// Which files have a fetch out and how many fetches are out in all, so a
/// drive that never answers can't pile up stuck reads: a fetch is a blocking
/// read that cannot be cancelled, and each holds a thread. A file whose last
/// fetch has not returned is never fetched again, and no more than `limit`
/// fetches are out at once, as the library's own fetch bounds its reads
/// (`libraryFilesBeingRead`, `libraryFetchReadSlots`).
final class FetchGuard: Sendable {
    /// The one the app shares, across comparisons.
    static let shared = FetchGuard()

    /// How many fetches may be out at once.
    let limit: Int
    private let outstanding = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    init(limit: Int = 8) {
        self.limit = limit
    }

    /// Notes a fetch of `path` as out; false, noting nothing, when its last
    /// fetch has not returned or `limit` fetches are out.
    func begin(_ path: String) -> Bool {
        outstanding.withLock { paths in
            guard !paths.contains(path), paths.count < limit else { return false }
            paths.insert(path)
            return true
        }
    }

    /// Notes the fetch of `path` as returned.
    func end(_ path: String) {
        outstanding.withLock { _ = $0.remove(path) }
    }
}

struct LibraryCopyReader: Sendable {
    /// Says where each file's content is, without downloading anything.
    var itemStatus: any CloudItemStatusProviding
    /// Brings a file that is only in the cloud to this Mac, blocking until
    /// it arrives or fails (`LibraryFileFetch`).
    var fetch: LibraryFileFetch
    /// How many seconds any one file is waited for.
    var waitLimit: Int = 30
    /// How many seconds the whole comparison may take: a file not yet read
    /// when they have gone is listed as unread, so a library whose files
    /// are slow to arrive still ends the comparison.
    var overallLimit: Int = 300
    /// When the comparison under way ends, set by `compare`; none for a
    /// copy read on its own.
    private var deadline: Date?
    /// Bounds the fetches out, across comparisons.
    var fetchGuard: FetchGuard = .shared

    /// A reader asking `itemStatus` where files are and bringing files with
    /// `fetch`, with the limits given.
    init(
        itemStatus: any CloudItemStatusProviding,
        fetch: @escaping LibraryFileFetch,
        waitLimit: Int = 30,
        overallLimit: Int = 300,
        readSlots: Int = 8,
        fetchGuard: FetchGuard = .shared
    ) {
        self.fetchGuard = fetchGuard
        self.itemStatus = itemStatus
        self.fetch = fetch
        self.waitLimit = waitLimit
        self.overallLimit = overallLimit
        self.readSlots = readSlots
    }
    /// How many files are read at once, bounding the reads the sync
    /// service has to serve.
    var readSlots: Int = 8

    /// The reader the app uses: the app's sync service and fetch.
    @MainActor
    static func app() -> LibraryCopyReader {
        LibraryCopyReader(itemStatus: CloudServices.itemStatus, fetch: LibraryFileFetcher.app)
    }

    // MARK: Comparing

    /// Compares the library in `thisFolder` with the one in `otherFolder`,
    /// off the main thread, reading both and changing neither.
    /// - Parameter thisLibrary: The library in `thisFolder` as it is held in
    ///   memory, newer than its saved index; its index is then not read.
    /// - Parameter isCancelled: Asked before each file; true stops the
    ///   comparison.
    func compare(
        thisFolder: URL,
        thisLibrary: Library? = nil,
        otherFolder: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> LibraryComparisonOutcome {
        var timed = self
        timed.deadline = Date().addingTimeInterval(TimeInterval(overallLimit))
        return timed.compareBeforeDeadline(thisFolder: thisFolder, thisLibrary: thisLibrary, otherFolder: otherFolder, isCancelled: isCancelled)
    }

    /// `compare`, once its deadline is set.
    private func compareBeforeDeadline(
        thisFolder: URL,
        thisLibrary: Library?,
        otherFolder: URL,
        isCancelled: @Sendable () -> Bool
    ) -> LibraryComparisonOutcome {
        let identities = [(thisFolder, LibraryCopySide.thisCopy), (otherFolder, .otherCopy)].map { folder, side in
            readIdentity(in: folder, side: side)
        }
        var missing = identities.compactMap(\.unread)
        // Without both markers nothing says the copies are one library, so
        // nothing else is read.
        guard missing.isEmpty else { return .notComparable(missing) }
        if let this = identities[0].identity, let other = identities[1].identity, this.id != other.id {
            return .differentLibraries
        }
        if isCancelled() { return .cancelled }
        let this = readCopy(at: thisFolder, side: .thisCopy, library: thisLibrary, isCancelled: isCancelled)
        let other = readCopy(at: otherFolder, side: .otherCopy, library: nil, isCancelled: isCancelled)
        if isCancelled() { return .cancelled }
        missing += [this, other].compactMap { $0.indexUnread }
        guard missing.isEmpty, let thisCopy = this.copy, let otherCopy = other.copy else {
            return .notComparable(missing)
        }
        return .compared(LibraryComparison.compare(this: thisCopy, other: otherCopy))
    }

    // MARK: Reading One Copy

    /// A copy as far as it could be read.
    struct CopyReading: Sendable {
        /// The copy, nil when its index was not read.
        var copy: LibraryCopy?
        /// Why its index was not read, when it was not.
        var indexUnread: LibraryUnreadFile?
    }

    /// Reads the copy in `folder`: its index, unless `library` is given, and
    /// the record of each of its books.
    func readCopy(
        at folder: URL,
        side: LibraryCopySide,
        library: Library? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CopyReading {
        var library = library
        if library == nil {
            let index = folder.appendingPathComponent("library.json", isDirectory: false)
            switch readFile(at: index) {
            case .unread(let reason):
                return CopyReading(indexUnread: LibraryUnreadFile(subject: .libraryIndex, side: side, reason: reason))
            case .data(let data):
                do {
                    library = try LibraryPersistenceService.decodeIndex(from: data)
                } catch {
                    let reason = LibraryUnreadFile.Reason.cannotBeRead(Self.words(for: error))
                    return CopyReading(indexUnread: LibraryUnreadFile(subject: .libraryIndex, side: side, reason: reason))
                }
            }
        }
        guard let library else { return CopyReading() }
        let (records, unread) = readRecords(of: library.libraryBooks, in: folder, side: side, isCancelled: isCancelled)
        return CopyReading(copy: LibraryCopy(library: library, records: records, unread: unread))
    }

    /// What reading the identity marker of a folder found.
    private struct IdentityReading {
        var identity: LibraryIdentity?
        var unread: LibraryUnreadFile?
    }

    /// Reads the marker of the library in `folder`. A marker that isn't
    /// there is unread too: the comparison is of copies of one library, by
    /// identity, and cannot tell without it.
    private func readIdentity(in folder: URL, side: LibraryCopySide) -> IdentityReading {
        let marker = LibraryIdentity.markerURL(in: folder)
        func unread(_ reason: LibraryUnreadFile.Reason) -> IdentityReading {
            IdentityReading(unread: LibraryUnreadFile(subject: .identityMarker, side: side, reason: reason))
        }
        switch readFile(at: marker) {
        case .unread(let reason):
            return unread(reason)
        case .data(let data):
            do {
                return IdentityReading(identity: try LibraryIdentity.decode(data))
            } catch {
                return unread(.cannotBeRead(Self.words(for: error)))
            }
        }
    }

    /// Reads the record of each of `books` in the packages of `folder`, a
    /// few at a time, and notes each one that could not be read.
    private func readRecords(
        of books: [Book],
        in folder: URL,
        side: LibraryCopySide,
        isCancelled: @Sendable () -> Bool
    ) -> (records: [UUID: LibraryRecordFacts], unread: [LibraryUnreadFile]) {
        struct Found: Sendable { var records: [UUID: LibraryRecordFacts] = [:]; var unread: [LibraryUnreadFile] = [] }
        let found = OSAllocatedUnfairLock(initialState: Found())
        let slots = DispatchSemaphore(value: max(1, readSlots))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "LibraryCopyReader.records", qos: .userInitiated, attributes: .concurrent)
        for book in books {
            if isCancelled() { break }
            slots.wait()
            group.enter()
            queue.async {
                defer { slots.signal(); group.leave() }
                let record = TextMouthPaths.bookInfoPath(in: book.packageDirectory(inDataDirectory: folder))
                switch self.readFile(at: record) {
                case .unread(let reason):
                    let file = LibraryUnreadFile(subject: .record(bookID: book.id, title: book.title), side: side, reason: reason)
                    found.withLock { $0.unread.append(file) }
                case .data(let data):
                    do {
                        let info = try BookInfo.decodeRecordFile(data)
                        let facts = LibraryRecordFacts(
                            position: info.state.readingPosition,
                            bookmarks: info.bookmarks,
                            totalCharacterCount: info.state.totalCharacterCount
                        )
                        found.withLock { $0.records[book.id] = facts }
                    } catch {
                        let reason = LibraryUnreadFile.Reason.cannotBeRead(Self.words(for: error))
                        let file = LibraryUnreadFile(subject: .record(bookID: book.id, title: book.title), side: side, reason: reason)
                        found.withLock { $0.unread.append(file) }
                    }
                }
            }
        }
        group.wait()
        let result = found.withLock { $0 }
        // In the books' own order, so a list of them reads the same on every run.
        let order = Dictionary(books.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unread = result.unread.sortedStably { lhs, rhs in
            func place(_ file: LibraryUnreadFile) -> Int {
                if case .record(let id, _) = file.subject { return order[id] ?? Int.max }
                return -1
            }
            return place(lhs) < place(rhs)
        }
        return (result.records, unread)
    }

    // MARK: Reading One File

    /// What reading one file gave.
    private enum FileRead {
        case data(Data)
        case unread(LibraryUnreadFile.Reason)
    }

    /// The bytes of the file at `url`. A file only in the cloud is fetched
    /// first, waiting `waitLimit` seconds at most; one that is on this Mac
    /// is read at once, and in either case without waiting on the network.
    private func readFile(at url: URL) -> FileRead {
        let state = itemStatus.status(of: url).state
        if state == .notDownloaded || state == .downloading {
            // The wait is the file's own limit, or what is left of the whole.
            let remaining = deadline.map { Int($0.timeIntervalSinceNow.rounded(.up)) } ?? waitLimit
            guard remaining > 0 else { return .unread(.timeRanOut(seconds: overallLimit)) }
            if let reason = bringHere(url, waiting: min(waitLimit, remaining)) {
                return .unread(reason)
            }
        }
        return DatalessFiles.withoutDownloading { () -> FileRead in
            do {
                return .data(try Data(contentsOf: url))
            } catch where DatalessFiles.isDownloadRefusal(error) {
                return .unread(.notArrived(seconds: waitLimit))
            } catch {
                return .unread(.cannotBeRead(Self.words(for: error)))
            }
        }
    }

    /// Asks the sync service for the file at `url` and waits `seconds` for it. Returns why it did not arrive, or nil once it has.
    /// The fetch runs on a queue of its own, so a wait that gives up leaves
    /// it running without holding anything.
    private func bringHere(_ url: URL, waiting seconds: Int) -> LibraryUnreadFile.Reason? {
        // A file whose last fetch is still out, or a drive with every slot
        // taken by fetches it never answered, is not asked again: it is
        // unread at once.
        let path = url.standardizedFileURL.path
        guard fetchGuard.begin(path) else { return .stillBeingFetched }
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let fetch = self.fetch
        let fetchGuard = self.fetchGuard
        DispatchQueue.global(qos: .utility).async {
            do {
                try fetch(url)
            } catch {
                failure.withLock { $0 = Self.words(for: error) }
            }
            fetchGuard.end(path)
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success else {
            return .notArrived(seconds: seconds)
        }
        return failure.withLock { $0 }.map { .cannotBeRead($0) }
    }

    /// Why a read or a decoding failed, in words that name no path: the
    /// system's own sentence, or the key a damaged file lacks.
    private static func words(for error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            // A damage reason names what is wrong inside a file, so it stays English (question 3);
            // Compare Libraries' sentences carry it as it is.
            case .keyNotFound(let key, _): return "it has no \(key.stringValue)" // l10n: no (damage reason inside a file, question 3)
            case .dataCorrupted: return "its contents are damaged" // l10n: no (damage reason inside a file, question 3)
            default: return "its contents aren't a library file this TextMouth knows" // l10n: no (damage reason inside a file, question 3)
            }
        }
        return (error as? CocoaError)?.code == .fileReadNoSuchFile
            ? "no file is there" // l10n: no (a reason in English, carried as it is by Compare Libraries' sentences)
            : error.localizedDescription
    }
}
