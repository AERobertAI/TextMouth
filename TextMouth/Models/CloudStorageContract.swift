import Combine
import Darwin
import Foundation

// MARK: - FR02 Cloud Storage Contract
//
// The types every task of the cloud-library working draft builds against
// (feature request FR02). The `cloudcore` task owns this file. Copy it
// verbatim to TextMouth/Models/CloudStorageContract.swift, and change it only
// through `cloudcore` (post a question on the board), so every branch holds
// the same file. Nothing here downloads a file or reads one's content:
// `cloudcore` supplies the real services behind these protocols, and until
// it is installed every library behaves as a local one.

// MARK: - Where a Folder Lives

/// The sync service that manages a cloud folder.
enum CloudProvider: Equatable, Sendable {
    /// iCloud Drive, in ~/Library/Mobile Documents.
    case iCloudDrive
    /// Google Drive for desktop, streaming through File Provider.
    case googleDrive
    /// Dropbox on File Provider.
    case dropbox
    /// Another File Provider drive, named by its folder in ~/Library/CloudStorage.
    case other(String)

    /// The service's name as TextMouth shows and speaks it.
    var displayName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .other(let name): return name
        }
    }
}

/// Where a folder lives, as far as file-system metadata can tell.
enum StorageLocation: Equatable, Sendable {
    /// A folder on the startup disk that no sync service manages. A folder
    /// Google Drive mirrors looks like this too: all its files are local.
    case local
    /// A folder on another volume, such as an external or network drive,
    /// named by its volume.
    case otherVolume(name: String)
    /// A folder a sync service manages, whose files can be only in the cloud.
    case cloud(CloudProvider)

    /// Whether files here can be only in the cloud, so the library says
    /// each book's cloud state.
    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    /// The sync service, for a cloud location.
    var provider: CloudProvider? {
        if case .cloud(let provider) = self { return provider }
        return nil
    }
}

// MARK: - One File

/// Where one file's content is, read without downloading anything.
enum CloudItemState: Equatable, Sendable {
    /// An ordinary file that no sync service manages.
    case local
    /// A cloud file whose content is on this Mac.
    case downloaded
    /// A cloud file whose content is only in the cloud: a dataless file.
    case notDownloaded
    /// A cloud file the sync service is downloading now.
    case downloading
    /// Nothing is at the path.
    case missing
}

/// One file's cloud state, with the sync details the commands need.
struct CloudItemStatus: Equatable, Sendable {
    /// Where the file's content is.
    var state: CloudItemState
    /// False while local changes wait to upload; always true for a local file.
    var isUploaded: Bool
    /// The size the file system reports, or nil when unknown. Some dataless
    /// iCloud Drive files report 0, so a size is never proof of a change.
    var byteCount: Int64?
    /// Whether the sync service holds conflicting versions of the file.
    var hasUnresolvedConflicts: Bool
    /// The sync service's last download error in words, when it reported one.
    var downloadError: String?

    /// The status of a file that no sync service manages.
    static func local(byteCount: Int64?) -> CloudItemStatus {
        CloudItemStatus(
            state: .local,
            isUploaded: true,
            byteCount: byteCount,
            hasUnresolvedConflicts: false,
            downloadError: nil
        )
    }

    /// The status of a path where nothing is.
    static let missing = CloudItemStatus(
        state: .missing,
        isUploaded: true,
        byteCount: nil,
        hasUnresolvedConflicts: false,
        downloadError: nil
    )
}

/// Reads and changes the local copies of files a sync service manages.
///
/// Every method reads file-system metadata, which can wait on the network in
/// a cloud folder, so call them off the main thread. None reads a file's
/// content.
protocol CloudItemStatusProviding: Sendable {
    /// Where the folder at `folder` lives.
    func location(of folder: URL) -> StorageLocation
    /// The cloud state of the file at `file`.
    func status(of file: URL) -> CloudItemStatus
    /// Asks the sync service to download the file at `file`; returns at once.
    func requestDownload(of file: URL) throws
    /// Asks the sync service to remove the local copy of the file at `file`,
    /// keeping the file in the cloud.
    func removeLocalCopy(of file: URL) throws
}

/// The file-level provider used until `cloudcore` installs the real one:
/// every file is an ordinary local file, so nothing downloads and no local
/// copy is ever removed.
struct LocalItemStatusProvider: CloudItemStatusProviding {
    /// Every folder is local.
    func location(of folder: URL) -> StorageLocation {
        .local
    }

    /// A local status with the file's size, or `.missing` when nothing is
    /// at the path.
    func status(of file: URL) -> CloudItemStatus {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]) else {
            return .missing
        }
        return .local(byteCount: values.fileSize.map(Int64.init))
    }

    /// Nothing to download: a local file is already here.
    func requestDownload(of file: URL) throws {}

    /// Nothing to remove: a local file has no copy in the cloud to fall back
    /// on, so its content always stays.
    func removeLocalCopy(of file: URL) throws {}
}

// MARK: - One Book

/// The files of one book as the cloud services see them: made on the main
/// actor from a library row, then handed to background work.
struct BookPackage: Equatable, Sendable {
    /// The book's ID.
    let bookID: UUID
    /// The book's .tmb package folder or, for an old book without one, its file.
    let url: URL
    /// Whether `url` is a package folder rather than a single file.
    let isPackage: Bool
    /// Whether the book is an audiobook, whose files are read while it plays.
    let isAudio: Bool

    /// The package of `book` where the library has it now.
    init(_ book: Book) {
        let hasPackage = !book.tmbDirectoryName.isEmpty
        self.init(
            bookID: book.id,
            url: hasPackage ? book.tmbDirectory : book.bookFileURL,
            isPackage: hasPackage,
            isAudio: book.format.isAudio
        )
    }

    /// A package at `url`: for tests, and for packages the library does not
    /// list yet.
    init(bookID: UUID, url: URL, isPackage: Bool, isAudio: Bool) {
        self.bookID = bookID
        self.url = url
        self.isPackage = isPackage
        self.isAudio = isAudio
    }
}

/// How far a book's download has got.
///
/// A sync service may report how much of a file still arriving it has
/// downloaded. Such a part counts toward the progress: by size in
/// `completedBytes`, by files in `partialFiles`. A file it reports nothing
/// for counts only once it is on this Mac.
struct BookDownloadProgress: Equatable, Sendable {
    /// Files of the book whose content is on this Mac.
    var completedFiles: Int
    /// Files in the book.
    var totalFiles: Int
    /// Bytes of the files already on this Mac, by their reported sizes, and
    /// of the parts reported of files still arriving.
    var completedBytes: Int64
    /// Bytes of all the book's files by their reported sizes; 0 when no size
    /// is known.
    var totalBytes: Int64
    /// When progress goes by files, the parts reported of files still
    /// arriving, counted in files: 0.4 while the one file left is 40 percent
    /// here. Always 0 by size, where those parts are bytes.
    var partialFiles: Double = 0

    /// Progress from 0 to 1: by bytes when sizes are known, otherwise by
    /// files, the parts of files still arriving included.
    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        guard totalFiles > 0 else { return 0 }
        return min(1, max(0, (Double(completedFiles) + partialFiles) / Double(totalFiles)))
    }

    /// Whole percent from 0 to 100, rounded down, and never 100 while a file
    /// is still missing: a file can report a size of 0, and one can be
    /// reported whole a moment before it is on this Mac.
    var percent: Int {
        let whole = Int((fractionCompleted * 100).rounded(.down))
        return completedFiles < totalFiles ? min(whole, 99) : whole
    }
}

/// A book's cloud state as the library list and the reader describe it.
enum BookCloudState: Equatable, Sendable {
    /// The library is not in a cloud location: there is nothing to say.
    case local
    /// Every file of the book is on this Mac.
    case downloaded
    /// At least one file of the book is only in the cloud.
    case inCloud
    /// The book is being downloaded.
    case downloading(BookDownloadProgress)
    /// The book's last download failed; the reason in words.
    case downloadFailed(String)
    /// The book's package has not arrived on this Mac yet.
    case waitingForSync

    /// The note the library list shows, or nil for none.
    var visibleNote: String? {
        switch self {
        case .local: return nil
        case .downloaded: return "Downloaded"
        case .inCloud: return "In Cloud"
        case .downloading(let progress): return "Downloading \(progress.percent)%"
        case .downloadFailed: return "Download Failed"
        case .waitingForSync: return "Waiting for Sync"
        }
    }

    /// The same note as VoiceOver speaks it, or nil for none.
    var spokenNote: String? {
        switch self {
        case .downloading(let progress): return "Downloading, \(progress.percent) percent"
        default: return visibleNote
        }
    }
}

/// Why a cloud operation on a book did not happen.
enum BookCloudError: Error, Equatable, Sendable {
    /// This Mac is offline, so files only in the cloud cannot be downloaded.
    case offline
    /// The sync service made no progress for this many seconds.
    case stalled(seconds: Int)
    /// The sync service refused or failed a download, with its message.
    case provider(String)
    /// Remove Download refused: some of the book's changes are not uploaded yet.
    case notUploaded
    /// Remove Download refused: the book is open in a reader.
    case bookIsOpen
    /// Remove Download refused: the book is kept on this Mac (Keep on This
    /// Mac, `KeptBooks`).
    case keptOnThisMac
    /// Remove Download refused: the book is on the reading list, which this
    /// Mac keeps downloaded in a cloud library (`KeptBooks`), and the
    /// listener did not keep the book themselves.
    case keptForReadingList
    /// Remove Download failed: the sync service refused or failed to remove
    /// the local copy of one of the book's files, with its message.
    case removalFailed(String)
    /// The book's package is not on this Mac.
    case packageMissing

    /// A sentence the interface shows and VoiceOver speaks, naming `provider`
    /// (or "the cloud service" when it is unknown, capitalized where it
    /// begins a sentence, as a braille display shows).
    func explanation(in provider: CloudProvider?) -> String {
        let service = provider?.displayName ?? "the cloud service"
        let serviceStartingSentence = provider?.displayName ?? "The cloud service"
        switch self {
        case .offline:
            return "This Mac is offline, so the book can't be downloaded from \(service). "
                + "Connect to the internet and try again."
        case .stalled(let seconds):
            return "\(serviceStartingSentence) hasn't downloaded anything for \(seconds) seconds. "
                + "It may be paused, signed out, or not running."
        case .provider(let message):
            return "\(serviceStartingSentence) couldn't download the book: \(message)"
        case .notUploaded:
            return "Some changes to this book haven't been uploaded to \(service) yet, "
                + "so its download can't be removed. Try again in a moment."
        case .bookIsOpen:
            return "The book is open, so its download can't be removed. Close it first."
        case .keptOnThisMac:
            return "The book is kept on this Mac, so its download can't be removed. "
                + "Choose Stop Keeping on This Mac first."
        case .keptForReadingList:
            return "The book is on the reading list, which this Mac keeps downloaded, so its download can't be removed. "
                + "Take it off the reading list, or clear Keep these books on this Mac in the Reading List's options first."
        case .removalFailed(let message):
            return "\(serviceStartingSentence) couldn't remove the book's download: \(message)"
        case .packageMissing:
            return "The book's files aren't on this Mac yet. \(serviceStartingSentence) may still be syncing them."
        }
    }
}

/// Cloud state, downloads, and removals of whole books.
///
/// Every method reads file-system metadata, which can wait on the network in
/// a cloud folder, so call them off the main thread.
protocol BookCloudStorage: AnyObject, Sendable {
    /// Where the data directory lives now.
    func libraryLocation() -> StorageLocation
    /// The cloud state of `package`, read without downloading anything.
    func state(of package: BookPackage) -> BookCloudState
    /// The cloud state of `package` in a library at `location`, which the
    /// caller has just read with `libraryLocation()`: what `state(of:)`
    /// says, without working out the location again for each package of a
    /// refresh (PERF16).
    func state(of package: BookPackage, in location: StorageLocation) -> BookCloudState
    /// Downloads every file of `package`. The stream yields progress as files
    /// arrive, and as parts of them do where the sync service reports any,
    /// and finishes once every file is on this Mac; it throws a
    /// `BookCloudError` when the download cannot finish. Ending the
    /// iteration, or cancelling the task that iterates, stops the waiting
    /// (the sync service may finish the download anyway).
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error>
    /// Removes the local copies of `package`'s files, keeping them in the
    /// cloud. Throws `BookCloudError.notUploaded` while any change of the
    /// book waits to upload, and `.removalFailed` when the sync service
    /// refuses or fails to remove a file's local copy.
    func removeDownload(of package: BookPackage) throws
}

extension BookCloudStorage {
    /// `state(of:)`, for storage that works out nothing from the location:
    /// the local placeholder below, and the test doubles.
    func state(of package: BookPackage, in location: StorageLocation) -> BookCloudState {
        state(of: package)
    }
}

/// The book storage used until `cloudcore` installs the real one: every book
/// is local, downloads finish at once, and nothing is removed.
final class LocalBookStorage: BookCloudStorage {
    /// Storage that treats every book as local.
    init() {}

    /// Every library is local.
    func libraryLocation() -> StorageLocation {
        .local
    }

    /// Every book is local.
    func state(of package: BookPackage) -> BookCloudState {
        .local
    }

    /// A local book is already here, so the download finishes at once.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    /// A local book has no copy in the cloud, so nothing is removed.
    func removeDownload(of package: BookPackage) throws {}
}

// MARK: - Services

/// The cloud services the app uses. `cloudcore` installs the real ones at
/// launch; a test installs fakes and puts the previous ones back when it ends.
@MainActor
enum CloudServices {
    /// File-level cloud state, downloads, and removals.
    static var itemStatus: any CloudItemStatusProviding = LocalItemStatusProvider()
    /// Book-level cloud state, downloads, and removals.
    static var bookStorage: any BookCloudStorage = LocalBookStorage()
}

// MARK: - Shared State

/// Every book's cloud state for the interface (FR02). The library list shows
/// it; the list and the reader record here what they learn, a download's
/// progress included, so every window says the same thing.
@MainActor
final class BookCloudStates: ObservableObject {
    /// The app's store.
    static let shared = BookCloudStates()

    /// Where the data directory lives. The list shows notes only in a cloud
    /// location.
    @Published private(set) var libraryLocation: StorageLocation = .local
    /// The latest known state of each book, by ID. A book not listed has not
    /// been checked yet.
    @Published private(set) var states: [UUID: BookCloudState] = [:]
    /// How many downloads TextMouth is running for each book, by ID: each
    /// counts from its `beginDownload(of:)` to its `endDownload(of:)`. A
    /// refresh leaves these books' states to their downloads.
    private var runningDownloads: [UUID: Int] = [:]
    /// How many times a download of each book has begun or ended, by ID. A
    /// refresh skips a book whose download began or ended while it read the
    /// states, since its reading may be older than what the download recorded.
    private var downloadEvents: [UUID: Int] = [:]

    /// A store with nothing recorded. The app uses `shared`; tests make
    /// their own.
    init() {}

    /// Whether the library list says each book's cloud state.
    var showsCloudNotes: Bool {
        libraryLocation.isCloud
    }

    /// The latest known state of the book `bookID`, or nil when it has not
    /// been checked yet.
    func state(of bookID: UUID) -> BookCloudState? {
        states[bookID]
    }

    /// Records where the data directory lives. Leaving a cloud location
    /// forgets every book's state.
    func setLibraryLocation(_ location: StorageLocation) {
        guard location != libraryLocation else { return }
        libraryLocation = location
        if !location.isCloud {
            states = [:]
        }
    }

    /// Records `state` for the book `bookID`, publishing only a change.
    func record(_ state: BookCloudState, for bookID: UUID) {
        guard states[bookID] != state else { return }
        states[bookID] = state
    }

    /// Notes that a download TextMouth runs for the book `bookID` has
    /// started. Until it ends, a refresh leaves the book's state to it, so
    /// only the download records its progress and how it ended. Call it
    /// before iterating `BookCloudStorage.download(_:)`, and pair it with one
    /// `endDownload(of:)`: the reader and the list can each run a download
    /// of the same book.
    func beginDownload(of bookID: UUID) {
        runningDownloads[bookID, default: 0] += 1
        downloadEvents[bookID, default: 0] += 1
    }

    /// Notes that a download begun with `beginDownload(of:)` has ended,
    /// however it ended. Once none of the book's downloads is running, a
    /// refresh records its state again.
    func endDownload(of bookID: UUID) {
        guard let running = runningDownloads[bookID] else { return }
        runningDownloads[bookID] = running > 1 ? running - 1 : nil
        downloadEvents[bookID, default: 0] += 1
    }

    /// Reads where the library lives and the state of each of `packages` off
    /// the main thread through `storage`, then records them. A book TextMouth
    /// is downloading keeps its download's progress: only the download
    /// records how it ended. A download only the sync service reports, such
    /// as one Finder started, is refreshed like any other state.
    func refresh(_ packages: [BookPackage], using storage: any BookCloudStorage) async {
        let eventsBeforeReading = downloadEvents
        let (location, results) = await Task.detached(priority: .utility) {
            () -> (StorageLocation, [(UUID, BookCloudState)]) in
            // Where the library lives is read first, and once (PERF16): a
            // library outside the cloud holds only local books, so none of
            // its packages is read.
            let location = storage.libraryLocation()
            guard location.isCloud else { return (location, []) }
            return (location, packages.map { ($0.bookID, storage.state(of: $0, in: location)) })
        }.value
        setLibraryLocation(location)
        guard location.isCloud else { return }
        // Recorded in one assignment (PERF31): the states are one published
        // dictionary, which each assignment copies whole and announces, so
        // recording book by book published once per book, 644 times for a
        // 643-book library, and copied the dictionary each time. Nothing is
        // published when nothing changed.
        var refreshed = states
        for (bookID, state) in results
        where runningDownloads[bookID] == nil && downloadEvents[bookID] == eventsBeforeReading[bookID] {
            refreshed[bookID] = state
        }
        if refreshed != states {
            states = refreshed
        }
    }

    /// Forgets every book's recorded state, as for a new data directory.
    func reset() {
        states = [:]
    }
}

// MARK: - Dataless Files

/// Safe handling of dataless files: cloud files whose content is only in the
/// cloud, which any read downloads first, waiting on the network (Apple
/// TN3150, "Getting ready for dataless files").
enum DatalessFiles {
    /// Whether the item at `url` is dataless: one lstat(2), which reads no
    /// content. It can still wait while a dataless parent folder is listed,
    /// so call it off the main thread. False when nothing is there.
    static func isDataless(_ url: URL) -> Bool {
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &status) == 0
        }
        return examined && status.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Runs `body` on this thread with dataless files left in the cloud: a
    /// read of one fails at once with `EDEADLK` (see `isDownloadRefusal(_:)`)
    /// instead of downloading it. Restores the thread's previous policy
    /// afterwards. For scans and checks that must never download; never wrap
    /// the read of a book the user is opening, which downloads it first.
    static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let changed = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
        defer {
            if changed {
                _ = setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                    IOPOL_SCOPE_THREAD,
                    previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
                )
            }
        }
        return try body()
    }

    /// Whether `error`, or an error it wraps, is the refusal to read a
    /// dataless file inside `withoutDownloading(_:)` (`EDEADLK`).
    static func isDownloadRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EDEADLK) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isDownloadRefusal(underlying)
        }
        return false
    }
}

// MARK: - This Mac's Folders

/// Folders that belong to this Mac rather than to the data directory: they
/// never sync, and they stay usable while the data directory is unavailable.
/// Under hosted tests they are inside the test sandbox (`TextMouthRuntime`).
enum MachineLocalPaths {
    /// ~/Library/Application Support/com.textmouth.TextMouth. (Not
    /// ~/Library/Application Support/TextMouth, where the oldest releases
    /// kept their library and which the legacy migration still reads.)
    static var root: URL {
        TextMouthRuntime.current.homeDirectory
            .appendingPathComponent("Library/Application Support/com.textmouth.TextMouth", isDirectory: true)
    }

    /// ~/Library/Logs/TextMouth: the diagnostic logs when Storage settings
    /// put them on this Mac, and while the data directory can't take them
    /// (`TextMouthPaths.logDestination`).
    static var logs: URL {
        TextMouthRuntime.current.homeDirectory.appendingPathComponent(logsInHome, isDirectory: true)
    }

    /// How Storage settings, VoiceOver, and log lines name `logs`.
    static let logsName = "~/" + logsInHome

    /// Where `logs` is inside the home directory.
    private static let logsInHome = "Library/Logs/TextMouth"

    /// Copies of the books open in readers, so an open audiobook keeps
    /// playing when the sync service removes its download or the network
    /// goes away.
    static var workingCopies: URL {
        root.appendingPathComponent("Working Copies", isDirectory: true)
    }

    /// Books' old text, each copied aside with the book's saved places as
    /// they were while a rebuild of its text moves them to the new text
    /// (T06's branch D, `PlaceSnapshot`): this Mac's own, never in the data
    /// directory, which a cloud library would upload.
    static var placeSnapshots: URL {
        root.appendingPathComponent("Place Snapshots", isDirectory: true)
    }

    /// The text of each book being edited with Edit Text, as TextMouth last
    /// took or wrote it, kept with the book's places, from which each edit
    /// taken moves them (T06's branch E, `PlaceSnapshot`): this Mac's own,
    /// never in the data directory. It is apart from `placeSnapshots`, whose
    /// launch recovery finishes rebuilds' leftovers and removes any folder
    /// there it cannot read. Never nest one folder in the other.
    static var editTextSnapshots: URL {
        root.appendingPathComponent("Edit Text Snapshots", isDirectory: true)
    }

    /// Archives being extracted for import, while the data directory is on
    /// the startup volume.
    static var archiveExtraction: URL {
        root.appendingPathComponent("Archive Extraction", isDirectory: true)
    }

    /// Packages being built by imports, while the data directory is on the
    /// startup volume.
    static var importStaging: URL {
        root.appendingPathComponent("Import Staging", isDirectory: true)
    }

    /// The books this Mac keeps downloaded (Keep on This Mac, `KeptBooks`):
    /// a choice of this Mac's own, which another Mac sharing the library
    /// never reads, so it is kept here rather than in the data directory.
    static var keptBooks: URL {
        root.appendingPathComponent("Kept Books.json", isDirectory: false)
    }

    /// Whether this Mac keeps the reading list's books downloaded in a cloud
    /// library (`KeptBooks.keepsReadingListBooks`): a choice of this Mac's
    /// own, beside `keptBooks`, since another Mac sharing the library
    /// decides for itself.
    static var keepReadingListBooks: URL {
        root.appendingPathComponent("Keep Reading List Books.json", isDirectory: false)
    }

    /// The hidden staging folders data-directory moves have begun and not yet
    /// cleaned up (`MigrationStagingLeftovers`): a journal of this Mac's own,
    /// since the folders are on a volume that may be away, and a sweep at
    /// launch removes only what it lists.
    static var moveLeftovers: URL {
        root.appendingPathComponent("Move Leftovers.json", isDirectory: false)
    }

    /// ~/Library/Caches/com.textmouth.TextMouth: what TextMouth can always
    /// make again from the data directory. Time Machine leaves the Caches
    /// folder out of backups, and macOS may empty it when the disk runs low.
    static var caches: URL {
        TextMouthRuntime.current.homeDirectory
            .appendingPathComponent("Library/Caches/com.textmouth.TextMouth", isDirectory: true)
    }

    /// The reading text of the large books this Mac opened lately
    /// (`ReadingTextCache`), each kept for a day after it was last used.
    static var readingTextCache: URL {
        caches.appendingPathComponent("Reading Text", isDirectory: true)
    }
}
