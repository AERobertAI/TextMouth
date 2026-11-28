import Foundation

// MARK: - Reaching the Sync Folder on the Mac (FR43)

/// The Mac's access to the sync folder: the folder found again from its
/// bookmark, reads and writes through `NSFileCoordinator`, and iCloud
/// Drive's upload and download states through `UbiquitousItemStatusProvider`.
/// The iPhone makes its own (`SyncFolderAccessFactory.make`).
///
/// Every wait is bounded (R2), nothing is ever written over an existing file
/// but `device.json` (R4), and TextMouth asks iCloud Drive to download only a
/// file it is about to read (R8).
struct PlainSyncFolderAccess: SyncFolderAccess {
    /// The folder's bookmark (`SyncPreferences.bookmark`).
    let bookmark: Data
    /// Reads the cloud states of the folder's files.
    var items = UbiquitousItemStatusProvider()
    /// Tells whether the network is there, so a read of a file not downloaded can fail at once offline.
    var reachability = NetworkReachability.system
    /// How often a wait for a download looks again.
    var pollInterval: Duration = .milliseconds(500)

    init(bookmark: Data) { self.bookmark = bookmark }

    // MARK: The folder

    /// The folder the bookmark leads to, and whether the bookmark is stale
    /// (the folder moved, so a fresh bookmark should be saved), or nil when it leads nowhere.
    static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        guard let folder = Self.resolve(bookmark)?.url, !SyncFolderIO.isDeleted(folder) else { throw SyncProblem.folderMissing }
        // A folder named as a folder: no stat of an item above it may download it.
        var isDirectory: ObjCBool = false
        let exists = DatalessFiles.withoutDownloading { FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) }
        guard exists, isDirectory.boolValue else { throw SyncProblem.folderMissing }
        return try await body(folder)
    }

    // MARK: Listing

    func list(_ folder: URL) throws -> [SyncFolderItem] {
        try DatalessFiles.withoutDownloading {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]).compactMap { url in
                var name = url.lastPathComponent
                // An evicted file may show as a hidden ".name.icloud" stand-in: it is the file `name`, not on this device.
                var standIn = false
                if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 {
                    name = String(name.dropFirst().dropLast(7))
                    standIn = true
                } else if name.hasPrefix(".") {
                    return nil
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                let here = !standIn && items.status(of: url).state != .notDownloaded
                return SyncFolderItem(name: name, size: size, isOnThisDevice: here)
            }
        }
    }

    // MARK: Reading

    func read(_ file: URL, within limit: Duration) async throws -> Data {
        try await SyncFolderIO.read(file, within: limit, items: items, reachability: reachability, pollInterval: pollInterval)
    }

    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws {
        try await SyncFolderIO.copyOut(file, to: destination, within: limit, items: items, reachability: reachability, pollInterval: pollInterval)
    }

    // MARK: Writing

    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        try SyncFolderIO.stagedPlace(at: file, replacing: replacing) { try data.write(to: $0) }
    }

    func copyIn(_ local: URL, to file: URL) throws {
        // A clone where the volume allows, made under a hidden name and moved in whole.
        try SyncFolderIO.stagedPlace(at: file, replacing: false) { try FileManager.default.copyItem(at: local, to: $0) }
    }

    // MARK: Cloud states

    func uploadState(of file: URL) -> SyncUploadState {
        SyncFolderIO.uploadState(of: file, items: items)
    }

    func evictLocalCopy(of file: URL) throws {
        try items.removeLocalCopy(of: file)
    }

    func sweepPartialFiles(in folder: URL, olderThan age: TimeInterval) {
        SyncFolderIO.sweepPartialFiles(in: folder, olderThan: age)
    }
}
