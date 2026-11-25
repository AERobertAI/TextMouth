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
        guard let folder = Self.resolve(bookmark)?.url else { throw SyncProblem.folderMissing }
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

    /// Whether `file` has to download before it can be read.
    private func isInCloudOnly(_ file: URL) -> Bool {
        items.status(of: file).state == .notDownloaded
    }

    /// Waits within `limit` until `file` is on this Mac, asking iCloud Drive for it once.
    /// `.offline` at once when the network is gone, `.notDownloaded` at the limit.
    private func waitUntilHere(_ file: URL, within limit: Duration) async throws {
        guard isInCloudOnly(file) else { return }
        guard reachability.isOnline() else { throw SyncProblem.offline }
        try? items.requestDownload(of: file)
        let clock = ContinuousClock()
        let started = clock.now
        while isInCloudOnly(file) || items.status(of: file).state == .downloading {
            try Task.checkCancellation()
            if clock.now - started >= limit {
                throw SyncProblem.notDownloaded(device: file.deletingLastPathComponent().lastPathComponent)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    func read(_ file: URL, within limit: Duration) async throws -> Data {
        try await waitUntilHere(file, within: limit)
        return try Self.coordinated(reading: file) { try Data(contentsOf: $0) }
    }

    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws {
        try await waitUntilHere(file, within: limit)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A clone where the volume allows: nothing is read into memory.
        try Self.coordinated(reading: file) { try FileManager.default.copyItem(at: $0, to: destination) }
    }

    // MARK: Writing

    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        if !replacing, FileManager.default.fileExists(atPath: file.path) { throw SyncProblem.exists }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coordinated(writing: file, replacing: replacing) { url in
            try data.write(to: url, options: replacing ? [.atomic] : [.withoutOverwriting])
        }
    }

    func copyIn(_ local: URL, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) { throw SyncProblem.exists }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coordinated(writing: file, replacing: false) { try FileManager.default.copyItem(at: local, to: $0) }
    }

    // MARK: Cloud states

    func uploadState(of file: URL) -> SyncUploadState {
        let flagged = items.flaggedStatus(of: file)
        guard flagged.carriesSyncFlags, flagged.status.isUploadReported else { return .notReported }
        if flagged.status.isUploaded { return .uploaded }
        // A quota refusal is the one failure that is told apart: the drive is full.
        let error = (try? file.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]))?.ubiquitousItemUploadingError
        if let error, (error as NSError).code == CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue {
            return .failed(.outOfSpace)
        }
        return .uploading
    }

    func evictLocalCopy(of file: URL) throws {
        try items.removeLocalCopy(of: file)
    }

    // MARK: Coordination

    /// Runs `body` with `url` coordinated for reading, so iCloud Drive's copy is not read mid-change.
    private static func coordinated<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) {
            result = Result { try body($0) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    /// Runs `body` with `url` coordinated for writing.
    private static func coordinated<T>(writing url: URL, replacing: Bool, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: replacing ? [.forReplacing] : [], error: &coordinationError) {
            result = Result { try body($0) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
}
