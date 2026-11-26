import Foundation

// PhoneSyncFolderAccess.swift: how the iPhone reaches the TextMouth Sync folder
// (FR43, sync-iphone). The folder is one a person picked in Files, kept as a
// bookmark. What the iPhone needs beyond the Mac is its security scope, held
// open for as long as the engine works in the folder; every read, write, copy,
// fetch, and upload state is the Mac's own (`PlainSyncFolderAccess`), so the
// two never differ: staged writes into folders not yet made, blobs made whole
// under a hidden name, a coordinated fetch with a limit that counts only stalled
// time, waits that tell offline from slow, and one upload rule.
// Nothing here has run on a phone.

/// The iPhone's `SyncFolderAccess`: the folder's bookmark and its security
/// scope around the Mac's access.
struct PhoneSyncFolderAccess: SyncFolderAccess {
    /// The bookmark of the folder the person picked (`makeBookmark(of:)`).
    let bookmark: Data
    /// The work in the folder: the Mac's, over the same bookmark.
    private let plain: PlainSyncFolderAccess

    /// - Parameters:
    ///   - bookmark: The folder's bookmark.
    ///   - reachability: Answers whether the network is reachable; the system's by default.
    ///   - pollInterval: How often a wait for a download looks again; a test's own is shorter.
    init(bookmark: Data, reachability: NetworkReachability = .system, pollInterval: Duration = .milliseconds(500)) {
        self.bookmark = bookmark
        var plain = PlainSyncFolderAccess(bookmark: bookmark)
        plain.reachability = reachability
        plain.pollInterval = pollInterval
        self.plain = plain
    }

    // MARK: - The Folder and Its Bookmark

    /// A bookmark of the folder at `folder`, to be kept in `SyncPreferences`. It is made with the folder's security scope
    /// open: a bookmark of a folder the app may not yet read would not find it again.
    static func makeBookmark(of folder: URL) throws -> Data {
        try withScope(of: folder) {
            try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    /// Runs `body` with the security scope of `url` open, as a URL given by `.fileImporter` needs, and closes it afterwards.
    static func withScope<T>(of url: URL, _ body: () throws -> T) rethrows -> T {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// The folder the bookmark names, and whether the system found it stale. A bookmark that no longer finds a folder is
    /// `.folderMissing`, and so is one whose folder is in Recently Deleted: Files moves a deleted folder there and the
    /// bookmark follows it, but it is gone as a sync folder.
    static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            throw SyncProblem.folderMissing
        }
        guard !SyncFolderIO.isDeleted(url) else { throw SyncProblem.folderMissing }
        return (url, isStale)
    }

    /// A fresh bookmark of the folder `bookmark` names, when the system found it stale (the folder was moved or renamed, and
    /// the bookmark still finds it); nil when the bookmark is current. The center keeps the new one in place of the old.
    /// - Parameters:
    ///   - resolving: Finds the folder and says whether the bookmark is stale; a test's own forces a stale one.
    ///   - making: Makes the new bookmark of the folder found.
    static func renewedBookmark(
        for bookmark: Data,
        resolving: (Data) throws -> (url: URL, isStale: Bool) = { try resolve($0) },
        making: (URL) throws -> Data = { try makeBookmark(of: $0) }
    ) throws -> Data? {
        let (folder, isStale) = try resolving(bookmark)
        guard isStale else { return nil }
        return try making(folder)
    }

    /// Opens the folder's scope, hands its URL to `body`, and closes the scope afterwards. The folder missing, deleted, or
    /// not a folder is `.folderMissing`.
    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        let folder = try Self.resolve(bookmark).url
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        var isFolder: ObjCBool = false
        // A folder named as a folder: no stat of an item above it may download it.
        let exists = DatalessFiles.withoutDownloading { FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) }
        guard exists, isFolder.boolValue else { throw SyncProblem.folderMissing }
        return try await body(folder)
    }

    // MARK: - The Mac's Work, with the System's Errors Made Problems

    func list(_ folder: URL) throws -> [SyncFolderItem] {
        do {
            return try plain.list(folder)
        } catch {
            throw Self.problem(for: error, missing: .folderMissing)
        }
    }

    func read(_ file: URL, within limit: Duration) async throws -> Data {
        do {
            return try await plain.read(file, within: limit)
        } catch {
            throw Self.problem(for: error, missing: Self.missing(file))
        }
    }

    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws {
        do {
            try await plain.fetch(file, to: destination, within: limit)
        } catch {
            throw Self.problem(for: error, missing: Self.missing(file))
        }
    }

    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        do {
            try plain.write(data, to: file, replacing: replacing)
        } catch {
            throw Self.problem(for: error, missing: .folderMissing)
        }
    }

    func copyIn(_ local: URL, to file: URL) throws {
        do {
            try plain.copyIn(local, to: file)
        } catch {
            throw Self.problem(for: error, missing: .folderMissing)
        }
    }

    func uploadState(of file: URL) -> SyncUploadState { plain.uploadState(of: file) }

    func evictLocalCopy(of file: URL) throws { try plain.evictLocalCopy(of: file) }

    func sweepPartialFiles(in folder: URL, olderThan age: TimeInterval) {
        plain.sweepPartialFiles(in: folder, olderThan: age)
    }

    // MARK: - Errors

    /// What a file that isn't there means: the sync folder is gone when the folder it was in is, and otherwise the file has
    /// not downloaded yet.
    private static func missing(_ file: URL) -> SyncProblem {
        let folder = file.deletingLastPathComponent()
        let isThere = DatalessFiles.withoutDownloading { FileManager.default.fileExists(atPath: folder.path) }
        return isThere ? .notDownloaded(device: folder.lastPathComponent) : .folderMissing
    }

    /// `error` as the `SyncProblem` it means. A `SyncProblem` is itself; no room is `.outOfSpace`; a missing item is
    /// `missing`; a refused permission is the folder missing, since the person can no longer reach it; a cancelled
    /// coordination is a download that hasn't come. Any other error is thrown on as it is.
    static func problem(for error: Error, missing: SyncProblem) -> Error {
        if let problem = error as? SyncProblem { return problem }
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return error }
        switch nsError.code {
        case NSFileWriteOutOfSpaceError: return SyncProblem.outOfSpace
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return missing
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return SyncProblem.folderMissing
        case NSUserCancelledError: return missing
        default: return error
        }
    }
}
