import Foundation

// SyncSeams.swift: the engine's seams, the library's side, and the app's one
// sync (FR43): the last two parts of section 9 of
// research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md. Owned by sync-store. At
// `sync/base` every body is inert: it does nothing or returns an empty or
// default value, and never traps.

// MARK: - The engine's seams

/// How the engine reaches the sync folder; the Mac's and the iPhone's differ.
protocol SyncFolderAccess: Sendable {
    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T
    /// Lists a folder without downloading anything.
    func list(_ folder: URL) throws -> [SyncFolderItem]
    /// Reads `file`: `.offline` at once, `.notDownloaded` at the limit.
    func read(_ file: URL, within limit: Duration) async throws -> Data
    /// Writes `data` staged and coordinated.
    func write(_ data: Data, to file: URL, replacing: Bool) throws
    /// Copies `local` in, as a clone where the volume allows.
    func copyIn(_ local: URL, to file: URL) throws
    /// Whether iCloud Drive has uploaded `file`.
    func uploadState(of file: URL) -> SyncUploadState
    /// Evicts the local copy; a refusal is a wait.
    func evictLocalCopy(of file: URL) throws
}

/// One entry of a folder listing.
struct SyncFolderItem: Equatable, Sendable {
    var name: String
    var size: Int64?
    var isOnThisDevice: Bool
}

/// Whether iCloud Drive has uploaded a file.
enum SyncUploadState: Equatable, Sendable { case uploaded, uploading, failed(SyncProblem), notReported }

/// Why sync cannot go on; each has its spoken form in `SyncWording`.
enum SyncProblem: Error, Equatable, Sendable {
    case offline, folderMissing, notASyncFolder, anotherStore, laterVersion, outOfSpace
    case notDownloaded(device: String), exists, damaged(file: String)
}

/// What started a sync.
enum SyncReason: String, Sendable { case launch, active, hourly, networkBack, afterChange, syncNow, background, quit }

/// What the Sync section shows.
struct SyncStatus: Equatable, Sendable {
    var isOn = false, isSyncing = false, isOffline = false, pendingChanges = 0
    var lastSynced: Date?, lastHeard: [String: Date] = [:], problem: SyncProblem?
    var booksBackedUp: Int?, booksToBackUp: Int?
}

/// A stub of the folder access: every call does nothing, until sync-store builds it.
struct PlainSyncFolderAccess: SyncFolderAccess {
    /// The folder's bookmark.
    let bookmark: Data

    init(bookmark: Data) { self.bookmark = bookmark }

    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        throw SyncProblem.folderMissing
    }
    func list(_ folder: URL) throws -> [SyncFolderItem] { [] }
    func read(_ file: URL, within limit: Duration) async throws -> Data { throw SyncProblem.folderMissing }
    func write(_ data: Data, to file: URL, replacing: Bool) throws {}
    func copyIn(_ local: URL, to file: URL) throws {}
    func uploadState(of file: URL) -> SyncUploadState { .notReported }
    func evictLocalCopy(of file: URL) throws {}
}

/// Makes the folder access for a bookmark; the iPhone sets its own.
enum SyncFolderAccessFactory {
    @MainActor static var make: (_ bookmark: Data) -> any SyncFolderAccess = { PlainSyncFolderAccess(bookmark: $0) }
}

/// A book not on this device, answered as a cloud book. Inert at `sync/base`:
/// every call goes to the live storage.
final class StoreBookStorage: BookCloudStorage {
    private let live: any BookCloudStorage

    /// Wraps the live storage, which answers for every book that is on this device.
    init(wrapping live: any BookCloudStorage) { self.live = live }

    func libraryLocation() -> StorageLocation { live.libraryLocation() }
    func state(of package: BookPackage) -> BookCloudState { live.state(of: package) }
    func state(of package: BookPackage, in location: StorageLocation) -> BookCloudState {
        live.state(of: package, in: location)
    }
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        live.download(package)
    }
    func removeDownload(of package: BookPackage) throws { try live.removeDownload(of: package) }
    func bytesToDownload(of package: BookPackage) -> Int64? { live.bytesToDownload(of: package) }
}

// MARK: - The library's side, and the app's one sync

/// What the library offers the sync; `LibraryViewModel` conforms (sync-mac).
@MainActor protocol SyncLibraryHost: AnyObject {
    var library: Library { get }
    /// False while storage work is held, or the library is unavailable or recovering.
    var maySyncNow: Bool { get }
    /// Applies a merge; returns the keys applied.
    func applySync(_ application: SyncApplication) async -> Set<SyncKey>
}

/// The app's one sync; the interfaces and life cycles call it.
@MainActor final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()
    @Published private(set) var status = SyncStatus()

    /// Hands the sync its library and data directory.
    func install(host: any SyncLibraryHost, dataDirectory: URL) {}
    /// Makes TextMouth Sync and store.json, then joins.
    func setUp(in parent: URL) async throws {}
    /// Waits 60 seconds for store.json; never makes one.
    func join(_ folder: URL) async throws {}
    /// Announces "Syncing." and the outcome.
    func syncNow() {}
    /// A moment to sync at.
    func moment(_ reason: SyncReason) {}
    /// Called from `LibraryViewModel.library`'s `didSet`.
    func libraryDidChange() {}
    /// Forgets the folder; deletes nothing.
    func stop() {}
}
