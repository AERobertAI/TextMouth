import Foundation

// PhoneSyncFolderAccess.swift: how the iPhone reaches the TextMouth Sync folder
// (FR43, sync-iphone). The folder is one a person picked in Files, kept as a
// bookmark; every read and write goes through NSFileCoordinator, each bounded
// by a limit, so a stalled iCloud Drive never holds the library or the app
// (rules R2 and R8 of research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md).
// Nothing here has run on a phone.

/// The iPhone's `SyncFolderAccess`: the folder's bookmark, its security scope,
/// and coordinated, bounded file work.
struct PhoneSyncFolderAccess: SyncFolderAccess {
    /// The bookmark of the folder the person picked (`makeBookmark(of:)`).
    let bookmark: Data
    /// Whether the network is reachable now: the system's, unless a test gives its own.
    let reachability: NetworkReachability
    /// How long a write or a copy may wait on the coordinator before it is cancelled.
    let writeLimit: Duration

    /// - Parameters:
    ///   - bookmark: The folder's bookmark.
    ///   - reachability: Answers whether the network is reachable.
    ///   - writeLimit: The longest a write or copy waits for its coordination.
    init(
        bookmark: Data,
        reachability: NetworkReachability = .system,
        writeLimit: Duration = .seconds(30)
    ) {
        self.bookmark = bookmark
        self.reachability = reachability
        self.writeLimit = writeLimit
    }

    // MARK: - The Folder and Its Bookmark

    /// A bookmark of the folder at `folder`, to be kept in `SyncPreferences`.
    /// Call it while the scope of a URL from `.fileImporter` is open
    /// (`withScope(of:_:)`): a bookmark of a folder the app may not yet read
    /// would not find it again.
    static func makeBookmark(of folder: URL) throws -> Data {
        try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Runs `body` with the security scope of `url` open, as a URL given by
    /// `.fileImporter` needs, and closes it afterwards.
    static func withScope<T>(of url: URL, _ body: () throws -> T) rethrows -> T {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// The folder the bookmark names, and whether the system found it stale.
    /// A bookmark that no longer finds a folder is `.folderMissing`.
    static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return (url, isStale)
        } catch {
            throw SyncProblem.folderMissing
        }
    }

    /// A fresh bookmark of the folder `bookmark` names, when the system found it stale (the folder was moved or renamed, and
    /// the bookmark still finds it); nil when the bookmark is current. The caller keeps the new one in place of the old.
    static func renewedBookmark(for bookmark: Data) throws -> Data? {
        let (folder, isStale) = try resolve(bookmark)
        guard isStale else { return nil }
        return try withScope(of: folder) { try makeBookmark(of: folder) }
    }

    /// Opens the folder's scope, hands its URL to `body`, and closes the scope
    /// afterwards. The folder missing, or not a folder, is `.folderMissing`.
    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        let folder = try Self.resolve(bookmark).url
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw SyncProblem.folderMissing
        }
        return try await body(folder)
    }

    // MARK: - Listing

    /// What is in `folder`, without downloading anything. A file only in the
    /// cloud may be listed by its own name, or as the hidden stand-in
    /// `.<name>.icloud`; both come back under the real name, off this device.
    func list(_ folder: URL) throws -> [SyncFolderItem] {
        let urls: [URL]
        do {
            urls = try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [])
            }
        } catch {
            throw Self.problem(for: error, whenMissing: .folderMissing)
        }
        return urls.map { url in
            let name = url.lastPathComponent
            if let real = Self.nameBehindStandIn(name) {
                return SyncFolderItem(name: real, size: nil, isOnThisDevice: false)
            }
            let onDevice = !DatalessFiles.isDataless(url)
            let size = onDevice ? (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) : nil
            return SyncFolderItem(name: name, size: size, isOnThisDevice: onDevice)
        }
    }

    /// The real name behind iCloud Drive's stand-in name, `.<name>.icloud`, or
    /// nil for a name that is not a stand-in.
    static func nameBehindStandIn(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    // MARK: - Reading

    /// Reads `file`. A file not on the phone while the network is out is
    /// `.offline` at once; one that doesn't arrive within `limit` is
    /// `.notDownloaded`. The coordinated read is what asks iCloud Drive for a
    /// file's content, and TextMouth forces nothing more (R8).
    func read(_ file: URL, within limit: Duration) async throws -> Data {
        if DatalessFiles.isDataless(file), !reachability.isOnline() {
            throw SyncProblem.offline
        }
        let device = Self.deviceName(of: file)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try Self.runCoordinated(within: limit) { coordinator in
                        var failure: NSError?
                        var result: Result<Data, Error> = .failure(SyncProblem.notDownloaded(device: device))
                        coordinator.coordinate(readingItemAt: file, options: [.withoutChanges], error: &failure) { url in
                            result = Result { try Data(contentsOf: url) }
                        }
                        if let failure { throw failure }
                        return try result.get()
                    }
                    continuation.resume(returning: data)
                } catch {
                    // A cancelled coordination, or a file that isn't there, is a wait, not a loss; but a file whose whole
                    // folder is gone is the sync folder missing (moved, deleted, or iCloud Drive signed out).
                    let folderIsThere = FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
                    let missing: SyncProblem = folderIsThere ? .notDownloaded(device: device) : .folderMissing
                    continuation.resume(throwing: Self.problem(for: error, whenMissing: missing, whenCancelled: .notDownloaded(device: device)))
                }
            }
        }
    }

    /// The device a file belongs to, for "hasn't downloaded yet": the folder
    /// under `Devices`, or the file's own folder.
    static func deviceName(of file: URL) -> String {
        file.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Writing

    /// Writes `data` to `file`: staged in the app's temporary folder, then
    /// moved in under coordination, so no reader sees a half file. Without
    /// `replacing`, a file already there is `.exists` and stays untouched.
    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        let staged = Self.stagingURL()
        try data.write(to: staged, options: .atomic)
        // The staged copy is left for the system's cleanup of the temporary folder: nothing here deletes.
        try placeCoordinated(at: file, replacing: replacing) { destination in
            if replacing, FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        }
    }

    /// Copies `local` to `file`, as a clone where the volume allows (APFS
    /// does). A file already there is `.exists` and stays untouched.
    func copyIn(_ local: URL, to file: URL) throws {
        try placeCoordinated(at: file, replacing: false) { destination in
            try FileManager.default.copyItem(at: local, to: destination)
        }
    }

    /// Runs `place` under a coordinated write at `file`, bounded by
    /// `writeLimit`, and turns the system's errors into `SyncProblem`s.
    private func placeCoordinated(at file: URL, replacing: Bool, _ place: (URL) throws -> Void) throws {
        do {
            try Self.runCoordinated(within: writeLimit) { coordinator in
                var failure: NSError?
                var result: Result<Void, Error> = .success(())
                coordinator.coordinate(writingItemAt: file, options: replacing ? [.forReplacing] : [], error: &failure) { destination in
                    if !replacing, FileManager.default.fileExists(atPath: destination.path) {
                        result = .failure(SyncProblem.exists)
                        return
                    }
                    result = Result { try place(destination) }
                }
                if let failure { throw failure }
                try result.get()
            }
        } catch {
            throw Self.problem(for: error, whenMissing: .folderMissing, whenCancelled: .offline)
        }
    }

    /// A new file in the app's temporary folder, for a write to stage in.
    private static func stagingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sync-staging-\(UUID().uuidString)")
    }

    // MARK: - Upload and Eviction

    /// Whether iCloud Drive has uploaded `file`, from its upload flags, read
    /// without downloading. A file the system gives no flags for (not in a
    /// sync service, or one that says nothing) is `.notReported`, so a copy
    /// there counts as sent (section 4, step 7).
    func uploadState(of file: URL) -> SyncUploadState {
        let metadata = try? DatalessFiles.withoutDownloading {
            try UbiquitousItemStatusProvider.readFreshMetadata(
                of: file,
                keys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
            )
        }
        guard let metadata, metadata.isUbiquitousItem == true else { return .notReported }
        if metadata.uploadError != nil {
            return .failed(Self.uploadProblem(of: file))
        }
        if metadata.isUploading == true { return .uploading }
        switch metadata.isUploaded {
        case true?: return .uploaded
        case false?: return .uploading
        case nil: return .notReported
        }
    }

    /// Why `file`'s upload failed: no room in iCloud (the quota's own error),
    /// or else most likely the network.
    private static func uploadProblem(of file: URL) -> SyncProblem {
        let fresh = URL(fileURLWithPath: file.path)
        let error = try? fresh.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]).ubiquitousItemUploadingError
        if let error, error.domain == NSCocoaErrorDomain, error.code == NSUbiquitousFileNotUploadedDueToQuotaError {
            return .outOfSpace
        }
        return .offline
    }

    /// Asks iCloud Drive to drop the phone's copy of `file`, keeping it in the
    /// cloud. A refusal is thrown, and is a wait.
    func evictLocalCopy(of file: URL) throws {
        try UbiquitousItemStatusProvider().removeLocalCopy(of: file)
    }

    // MARK: - Bounded Coordination and Errors

    /// Runs `body` with a new coordinator, and cancels the coordinator once
    /// `limit` passes, so a coordination that waits on iCloud Drive ends with
    /// a cancellation error instead of waiting for ever. Blocks the calling
    /// thread: call it off the main thread.
    static func runCoordinated<T>(within limit: Duration, _ body: (NSFileCoordinator) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let timer = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        return try body(coordinator)
    }

    /// `error` as the `SyncProblem` it means. Out of room is `.outOfSpace`; a
    /// missing item is `whenMissing`; a cancelled coordination is
    /// `whenCancelled` (the limit passed); a `SyncProblem` is itself; any
    /// other error is thrown on as it is.
    static func problem(for error: Error, whenMissing: SyncProblem, whenCancelled: SyncProblem? = nil) -> Error {
        if let problem = error as? SyncProblem { return problem }
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return error }
        switch nsError.code {
        case NSFileWriteOutOfSpaceError: return SyncProblem.outOfSpace
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return whenMissing
        case NSUserCancelledError: return whenCancelled ?? error
        default: return error
        }
    }
}
