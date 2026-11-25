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
    /// Copies `file` out of the sync folder to the local `destination`, waiting for it to download,
    /// within `limit`: `.offline` at once, `.notDownloaded` at the limit. Unlike `read`, a large
    /// blob never sits in memory whole. A default does it through `read` and `write`.
    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws
}

extension SyncFolderAccess {
    /// The default fetch: reads the file whole, then writes it. An access that can copy by streaming overrides this.
    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws {
        let data = try await read(file, within: limit)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
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
    /// Set Up Sync was given a folder outside iCloud Drive, or the library is itself kept in a cloud folder (R6).
    case notInICloudDrive, libraryNotLocal
}

/// What started a sync.
enum SyncReason: String, Sendable { case launch, active, hourly, networkBack, afterChange, syncNow, background, quit }

/// What the Sync section shows.
struct SyncStatus: Equatable, Sendable {
    var isOn = false, isSyncing = false, isOffline = false, pendingChanges = 0
    var lastSynced: Date?, lastHeard: [String: Date] = [:], problem: SyncProblem?
    var booksBackedUp: Int?, booksToBackUp: Int?
}

/// Makes the folder access for a bookmark; the iPhone sets its own.
enum SyncFolderAccessFactory {
    @MainActor static var make: (_ bookmark: Data) -> any SyncFolderAccess = { PlainSyncFolderAccess(bookmark: $0) }
    /// Makes the bookmark of the folder a person chose; the iPhone sets its own (a folder picked in Files).
    @MainActor static var makeBookmark: (_ folder: URL) -> Data? = { DataDirectoryPreferences.makeBookmark(of: $0) }
    /// A fresh bookmark for `bookmark` when the system found it stale (the folder moved or was renamed, and the
    /// bookmark still found it), nil when it is current; the center keeps the fresh one in `SyncPreferences`.
    /// The iPhone sets its own, which opens the folder's scope to make it.
    @MainActor static var renewedBookmark: (_ bookmark: Data) -> Data? = { bookmark in
        guard let resolved = PlainSyncFolderAccess.resolve(bookmark), resolved.isStale else { return nil }
        return DataDirectoryPreferences.makeBookmark(of: resolved.url)
    }
}

// MARK: - The library's side, and the app's one sync

/// What the library offers the sync; `LibraryViewModel` conforms (sync-mac).
@MainActor protocol SyncLibraryHost: AnyObject {
    var library: Library { get }
    /// False while storage work is held, or the library is unavailable or recovering.
    var maySyncNow: Bool { get }
    /// Applies a merge; returns the keys applied.
    func applySync(_ application: SyncApplication) async -> Set<SyncKey>
    /// Called after each run with the books kept on all devices; `mayDownload` is true on a satisfied
    /// path that is neither expensive nor constrained (section 16).
    func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool)
    /// Called after a placeholder's files were fetched: `contentPath` is the content file's path in the package
    /// as the store names it (the name it had where it was backed up), which the host sets as the row's
    /// `filePath` if that differs. Nil when the manifest names no content file.
    func syncDidFetch(bookID: UUID, contentPath: String?)
    /// The IDs of the voices this device has, or nil for all: a voice a device lacks isn't applied to a row.
    var availableVoiceIDs: Set<String>? { get }
}

extension SyncLibraryHost {
    /// A host that doesn't say has every voice.
    var availableVoiceIDs: Set<String>? { nil }

    /// A host that keeps the row's file name as it made it has nothing to do.
    func syncDidFetch(bookID: UUID, contentPath: String?) {}
}

