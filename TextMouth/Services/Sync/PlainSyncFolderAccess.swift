import Foundation
import os

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
        var started = clock.now
        while isInCloudOnly(file) || items.status(of: file).state == .downloading {
            try Task.checkCancellation()
            // The limit is for time spent not downloading: a long track that is arriving is not stalled.
            if items.status(of: file).state == .downloading { started = clock.now }
            if clock.now - started >= limit {
                throw SyncProblem.notDownloaded(device: file.deletingLastPathComponent().lastPathComponent)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    func read(_ file: URL, within limit: Duration) async throws -> Data {
        try await waitUntilHere(file, within: limit)
        // Run on a queue of its own, so a stuck iCloud Drive call holds neither the engine nor a cooperative thread.
        let seconds = Self.seconds(of: limit)
        return try await withCheckedThrowingContinuation { continuation in
            Self.coordinationQueue.async {
                continuation.resume(with: Result { try Self.coordinated(reading: file, within: seconds) { try Data(contentsOf: $0) } })
            }
        }
    }

    func fetch(_ file: URL, to destination: URL, within limit: Duration) async throws {
        try await waitUntilHere(file, within: limit)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A clone where the volume allows: nothing is read into memory.
        let seconds = Self.seconds(of: limit)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.coordinationQueue.async {
                continuation.resume(with: Result { try Self.coordinated(reading: file, within: seconds) { try FileManager.default.copyItem(at: $0, to: destination) } })
            }
        }
    }

    // MARK: Writing

    func write(_ data: Data, to file: URL, replacing: Bool) throws {
        try Self.stagedPlace(at: file, replacing: replacing) { try data.write(to: $0) }
    }

    func copyIn(_ local: URL, to file: URL) throws {
        // A clone where the volume allows, made under a hidden name and moved in whole.
        try Self.stagedPlace(at: file, replacing: false) { try FileManager.default.copyItem(at: local, to: $0) }
    }

    /// Makes the file at `file` whole under a hidden name beside it, then moves it in, so a crash never
    /// leaves a half file under its final name. A file already there is `.exists` unless `replacing`.
    private static func stagedPlace(at file: URL, replacing: Bool, _ make: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        if !replacing, fileManager.fileExists(atPath: file.path) { throw SyncProblem.exists }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = file.deletingLastPathComponent().appendingPathComponent(".partial-" + UUID().uuidString.lowercased())
        try make(staged)
        do {
            try coordinated(writing: file, replacing: replacing) { destination in
                let fileManager = FileManager.default
                if replacing {
                    if fileManager.fileExists(atPath: destination.path) {
                        _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
                    } else {
                        try fileManager.moveItem(at: staged, to: destination)
                    }
                } else {
                    // `moveItem` never goes over a file: a second writer finds the name taken.
                    try fileManager.moveItem(at: staged, to: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            if !replacing, fileManager.fileExists(atPath: file.path) { throw SyncProblem.exists }
            throw error
        }
    }

    // MARK: Cloud states

    func uploadState(of file: URL) -> SyncUploadState {
        let flagged = items.flaggedStatus(of: file)
        // A folder that carries no sync flags reports nothing at all. Where it does report, a missing upload
        // flag means the file has not uploaded yet, never that it has.
        guard flagged.carriesSyncFlags else { return .notReported }
        guard flagged.status.isUploadReported else { return .uploading }
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

    func sweepPartialFiles(in folder: URL, olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".partial-") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            // A file still being written is not a leftover.
            if Date().timeIntervalSince(modified) >= age { try? fileManager.removeItem(at: url) }
        }
    }

    // MARK: Coordination

    /// How long one coordinated call may take before it is cancelled, in seconds (R2).
    static let coordinationLimit: TimeInterval = 30

    /// The queue coordinated calls run on, so none holds the engine actor or a cooperative thread.
    private static let coordinationQueue = DispatchQueue(label: "com.textmouth.sync-coordination", qos: .utility, attributes: .concurrent)

    /// A limit in seconds.
    private static func seconds(of limit: Duration) -> TimeInterval {
        Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    }

    /// Holds the coordinator of a call so the caller can cancel it at the limit.
    ///
    /// `@unchecked Sendable`: `coordinator` is set once, before the call starts, and `cancel()` only asks it to
    /// stop; `NSFileCoordinator.cancel()` is documented as callable from any thread.
    private final class CoordinatorBox: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        func cancel() { coordinator.cancel() }
    }

    /// Runs one coordinated call on a queue and waits for it at most `limit` seconds: at the limit the
    /// coordinator is cancelled, so a call still waiting for iCloud Drive gives up, and the caller is
    /// told `.notDownloaded` instead of waiting on.
    private static func run<T: Sendable>(
        within limit: TimeInterval,
        at url: URL,
        _ call: @escaping @Sendable (NSFileCoordinator, NSErrorPointer, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) throws -> T {
        let box = CoordinatorBox()
        let outcome = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        coordinationQueue.async {
            var failure: NSError?
            call(box.coordinator, &failure) { result in outcome.withLock { $0 = result } }
            if let failure {
                outcome.withLock { current in
                    if current == nil { current = .failure(failure) }
                }
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + limit) == .timedOut {
            box.cancel()
            throw SyncProblem.notDownloaded(device: url.deletingLastPathComponent().lastPathComponent)
        }
        guard let result = outcome.withLock({ $0 }) else { throw SyncProblem.damaged(file: url.lastPathComponent) }
        return try result.get()
    }

    /// Runs `body` with `url` coordinated for reading, so iCloud Drive's copy is not read mid-change.
    private static func coordinated<T: Sendable>(
        reading url: URL, within limit: TimeInterval = coordinationLimit, _ body: @escaping @Sendable (URL) throws -> T
    ) throws -> T {
        try run(within: limit, at: url) { coordinator, error, finish in
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: error) { accessed in
                finish(Result { try body(accessed) })
            }
        }
    }

    /// Runs `body` with `url` coordinated for writing.
    private static func coordinated<T: Sendable>(
        writing url: URL, replacing: Bool, within limit: TimeInterval = coordinationLimit, _ body: @escaping @Sendable (URL) throws -> T
    ) throws -> T {
        try run(within: limit, at: url) { coordinator, error, finish in
            coordinator.coordinate(writingItemAt: url, options: replacing ? [.forReplacing] : [], error: error) { accessed in
                finish(Result { try body(accessed) })
            }
        }
    }
}
