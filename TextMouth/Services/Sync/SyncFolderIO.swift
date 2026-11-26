import Foundation
import os

// MARK: - The Folder's File Work, Shared by Both Platforms (FR43)

/// What both platforms' folder accesses do alike (the Mac's `PlainSyncFolderAccess` and the iPhone's): files
/// staged whole under a hidden name and moved in, reads and copies through `NSFileCoordinator` on a queue and
/// cancelled at a limit, the wait for a file to download, the upload rule, and the sweep of leftovers. One
/// copy, so the two never differ (R2, R4).
enum SyncFolderIO {
    // MARK: Where a folder has gone

    /// Whether `url` is in a trash: a path through `.Trash`, or the iPhone's Recently Deleted. A folder deleted in
    /// Finder or Files moves there and its bookmark follows, so the folder is treated as missing.
    static func isDeleted(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return parts.contains(".Trash") || parts.contains("Recently Deleted") || parts.contains(".Trashes")
    }

    // MARK: Coordination

    /// How long one coordinated call may take before it is cancelled, in seconds (R2).
    static let coordinationLimit: TimeInterval = 30

    /// The queue coordinated calls run on, so none holds the engine actor or a cooperative thread.
    static let coordinationQueue = DispatchQueue(label: "com.textmouth.sync-coordination", qos: .utility, attributes: .concurrent)

    /// A limit in seconds.
    static func seconds(of limit: Duration) -> TimeInterval {
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
    static func coordinated<T: Sendable>(
        reading url: URL, within limit: TimeInterval = coordinationLimit, _ body: @escaping @Sendable (URL) throws -> T
    ) throws -> T {
        try run(within: limit, at: url) { coordinator, error, finish in
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: error) { accessed in
                finish(Result { try body(accessed) })
            }
        }
    }

    /// Runs `body` with `url` coordinated for writing.
    static func coordinated<T: Sendable>(
        writing url: URL, replacing: Bool, within limit: TimeInterval = coordinationLimit, _ body: @escaping @Sendable (URL) throws -> T
    ) throws -> T {
        try run(within: limit, at: url) { coordinator, error, finish in
            coordinator.coordinate(writingItemAt: url, options: replacing ? [.forReplacing] : [], error: error) { accessed in
                finish(Result { try body(accessed) })
            }
        }
    }

    // MARK: Staged writes

    /// Makes the file at `file` whole under a hidden `.partial-<uuid>` name beside it, then moves it in, so a
    /// crash or an app ended mid-copy never leaves a half file under its final name. A file already there is
    /// `.exists` unless `replacing`.
    static func stagedPlace(at file: URL, replacing: Bool, _ make: (URL) throws -> Void) throws {
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

    /// Removes the hidden half-made files a crash left in `folder` (one level), older than `age` seconds.
    static func sweepPartialFiles(in folder: URL, olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".partial-") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            // A file still being written is not a leftover.
            if Date().timeIntervalSince(modified) >= age { try? fileManager.removeItem(at: url) }
        }
    }

    // MARK: Waiting for a download

    /// Waits within `limit` until `file` is on this device, asking iCloud Drive for it once. `.offline` at once
    /// when the network is gone; `.notDownloaded` once the file has stalled for `limit`: the limit counts only
    /// time spent not downloading, so a long track that is arriving is never cancelled.
    ///
    /// "Stalled" means no progress: the clock restarts only when the bytes that have arrived change, not whenever
    /// the state says `.downloading`, so a download stuck in that state still times out. `progress` and `state`
    /// are the file system's by default; a test passes its own.
    static func waitUntilHere(
        _ file: URL, within limit: Duration, items: UbiquitousItemStatusProvider, reachability: NetworkReachability, pollInterval: Duration,
        state: ((URL) -> CloudItemState)? = nil, progress: ((URL) -> Int64?)? = nil,
        now: (() -> ContinuousClock.Instant)? = nil, sleep: ((Duration) async throws -> Void)? = nil
    ) async throws {
        let stateOf = state ?? { items.status(of: $0).state }
        let progressOf = progress ?? { SyncFolderIO.allocatedBytes(of: $0) }
        let nowInstant = now ?? { ContinuousClock.now }
        let pause = sleep ?? { try await Task.sleep(for: $0) }
        // A file iCloud Drive is fetching already (it started on its own) is waited for by the same rule as one this call
        // asks for: its progress, not the time since the call. Only a file that is here, or none, returns at once.
        let starting = stateOf(file)
        guard starting == .notDownloaded || starting == .downloading else { return }
        guard reachability.isOnline() else { throw SyncProblem.offline }
        if starting == .notDownloaded { try? items.requestDownload(of: file) }
        var started = nowInstant()
        var seen = progressOf(file)
        while true {
            let now = stateOf(file)
            if now != .notDownloaded, now != .downloading { return }
            try Task.checkCancellation()
            // The network may go while a download waits: the caller is told at once, not at the limit.
            guard reachability.isOnline() else { throw SyncProblem.offline }
            let bytes = progressOf(file)
            if bytes != seen {
                seen = bytes
                started = nowInstant()
            }
            if started.duration(to: nowInstant()) >= limit {
                throw SyncProblem.notDownloaded(device: file.deletingLastPathComponent().lastPathComponent)
            }
            try await pause(pollInterval)
        }
    }

    /// The bytes of `file` that have arrived on this device, as the file system allocates them.
    static func allocatedBytes(of file: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: file.path)
        return (try? fresh.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
    }

    /// Reads `file` whole, after waiting for it to be here, on a queue of its own.
    static func read(
        _ file: URL, within limit: Duration, items: UbiquitousItemStatusProvider, reachability: NetworkReachability, pollInterval: Duration
    ) async throws -> Data {
        try await waitUntilHere(file, within: limit, items: items, reachability: reachability, pollInterval: pollInterval)
        let seconds = seconds(of: limit)
        return try await withCheckedThrowingContinuation { continuation in
            coordinationQueue.async {
                continuation.resume(with: Result { try coordinated(reading: file, within: seconds) { try Data(contentsOf: $0) } })
            }
        }
    }

    /// Copies `file` to `destination` (a clone where the volume allows, so a large blob is never in memory),
    /// after waiting for it to be here.
    static func copyOut(
        _ file: URL, to destination: URL, within limit: Duration, items: UbiquitousItemStatusProvider, reachability: NetworkReachability, pollInterval: Duration
    ) async throws {
        try await waitUntilHere(file, within: limit, items: items, reachability: reachability, pollInterval: pollInterval)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seconds = seconds(of: limit)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coordinationQueue.async {
                continuation.resume(with: Result { try coordinated(reading: file, within: seconds) { try FileManager.default.copyItem(at: $0, to: destination) } })
            }
        }
    }

    // MARK: The upload rule

    /// What iCloud Drive says of a file's upload, in the seam's words. A folder that carries no sync flags
    /// reports nothing at all. Where it does report, a missing upload flag means the file has not uploaded yet,
    /// and a quota refusal is the one failure told apart: the drive is full. Any other error is an upload that
    /// is not done (`.uploading`), never read as offline.
    static func uploadState(of file: URL, items: UbiquitousItemStatusProvider) -> SyncUploadState {
        let flagged = items.flaggedStatus(of: file)
        guard flagged.carriesSyncFlags else { return .notReported }
        guard flagged.status.isUploadReported else { return .uploading }
        if flagged.status.isUploaded { return .uploaded }
        let error = (try? file.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]))?.ubiquitousItemUploadingError
        if let error, (error as NSError).code == CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue {
            return .failed(.outOfSpace)
        }
        return .uploading
    }
}
