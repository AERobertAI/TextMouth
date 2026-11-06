import Foundation

// MARK: - Getting the Library's Files From the Cloud

/// When the data directory check finds the files the library opens from only
/// in the cloud (a library in Google Drive's Stream mode, after those files
/// were evicted), the library fetches them itself and opens when they have
/// arrived, instead of waiting for Try Again.
///
/// The check stays metadata-only on the main thread. A fetch reads the files
/// it named, each on a queue of its own off Swift's cooperative threads, with
/// downloads allowed (`LibraryFileFetcher`), and then runs the check again: a
/// feed's folders can't be named until the Feeds folder has been listed, so
/// each pass fetches whatever the last check named. Only the files the check
/// names are ever read, never a book or an episode.
///
/// A fetch ends when the library is available (and opens), when the check
/// finds another reason, or with the failure screen when:
/// - a read has not returned within `libraryFetchStallLimit` (the sync
///   service is paused, signed out, or silent). The stuck reads stay in
///   `libraryFilesBeingRead`: later fetches and Try Again never read those
///   files again, so no threads pile up, and a read that returns late runs
///   the check again and opens the library;
/// - the same files are named again after the retries
///   (`libraryFetchRetryDelays`, which give a sync service that isn't up yet
///   just after a restart time to start, the screen saying "Getting Your
///   Library" meanwhile), or after `maxLibraryFetchPasses` passes.
extension LibraryViewModel {
    /// The most passes one fetch makes: the Feeds folder, then the feeds'
    /// folders and indexes, with room for the retries.
    static let maxLibraryFetchPasses = 6

    /// How long a fetch waits before each retry of files that were read
    /// without error and are still named: a sync service that isn't up yet
    /// just after a restart often is within half a minute.
    static let libraryFetchRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]

    // MARK: Starting and Stopping

    /// Starts fetching the files the last check named when `reason` says
    /// they are only in the cloud, and shows the screen's "getting your
    /// library" reason meanwhile. A fetch already running for this data
    /// directory is left to finish, so Try Again during a fetch starts
    /// nothing. Files whose earlier reads have not returned are not read
    /// again. Returns whether the fetch has taken over the reason, in which
    /// case the caller leaves it alone.
    func beginLibraryFetch(for reason: DataDirectoryUnavailability) -> Bool {
        guard let fetch = dataDirectoryEnvironment.libraryFetch,
              case .notDownloaded(let provider, let folder) = reason,
              !pendingLibraryFiles.isEmpty else { return false }
        let root = TextMouthPaths.root
        let rootPath = root.standardizedFileURL.path
        let named = names(of: pendingLibraryFiles, in: root)
        if libraryFetchTask != nil {
            if libraryFetchRoot == rootPath {
                // The screen may show a reason found since the fetch began.
                if dataDirectoryUnavailability?.isGettingFromCloud != true {
                    noteDataDirectoryUnavailable(.gettingFromCloud(provider, folder: folder, files: named))
                }
                return true
            }
            // The data directory changed since: that fetch's results are moot.
            cancelLibraryFetch()
        }
        guard pendingLibraryFiles.contains(where: { !isBeingRead($0) }) else {
            // Every file is held by a read that never returned: reading them
            // again would only pile up threads, and the check just ran.
            noteDataDirectoryUnavailable(.cloudFetchFailed(
                provider, folder: folder, files: named, ending: "a read of these files has not returned"
            ))
            return true
        }
        let token = UUID()
        libraryFetchToken = token
        libraryFetchRoot = rootPath
        noteDataDirectoryUnavailable(.gettingFromCloud(provider, folder: folder, files: named))
        DiagnosticLog.event(.storage, "LIBRARY_FETCH: began; \(DataDirectoryUnavailability.listed(named))")
        libraryFetchTask = Task { [weak self] in
            await self?.runLibraryFetch(token: token, root: root, provider: provider, folder: folder, fetch: fetch)
        }
        return true
    }

    /// Drops the running fetch, if any: its results are ignored from now on.
    /// Its reads can't be recalled, and stay listed until they return.
    /// - Returns: Whether a fetch was running.
    @discardableResult
    func cancelLibraryFetch() -> Bool {
        let wasRunning = libraryFetchTask != nil
        // The task itself is not cancelled: it may be the one calling this
        // on its way to opening the library, and it ends at its next step
        // when it finds its token gone.
        libraryFetchTask = nil
        libraryFetchToken = nil
        libraryFetchRoot = nil
        return wasRunning
    }

    /// Checks the data directory again after `cancelLibraryFetch()` dropped a
    /// fetch for a switch of libraries that did not happen, and opens the
    /// library if it is there (starting a new fetch if it is not).
    func recheckAfterDroppedLibraryFetch() {
        guard dataDirectoryUnavailability != nil else { return }
        if checkDataDirectory() {
            openLibraryAfterDataDirectoryReturned()
        }
    }

    // MARK: Passes

    /// The passes of one fetch: read what the last check named, check again,
    /// and repeat until the library is available (and opens), the check finds
    /// another reason, a read stalls, or the same files are named again after
    /// the retries and passes run out, which shows the failure.
    private func runLibraryFetch(
        token: UUID,
        root: URL,
        provider: CloudProvider?,
        folder: String,
        fetch: @escaping LibraryFileFetch
    ) async {
        var previousNames: [String] = []
        var retries = 0
        var lastFailure: String?
        for pass in 1...Self.maxLibraryFetchPasses {
            let named = names(of: pendingLibraryFiles, in: root)
            if named == previousNames {
                // The same files again: whatever was read did not bring them.
                // A sync service that isn't up yet may be in a moment.
                guard retries < Self.libraryFetchRetryDelays.count else { break }
                try? await Task.sleep(for: Self.libraryFetchRetryDelays[retries])
                retries += 1
                guard libraryFetchToken == token else { return }
                if checkDataDirectory() {
                    openLibraryAfterDataDirectoryReturned()
                    return
                }
                guard libraryFetchToken == token, !pendingLibraryFiles.isEmpty else {
                    endLibraryFetch(token)
                    return
                }
            }
            previousNames = names(of: pendingLibraryFiles, in: root)
            let files = pendingLibraryFiles.filter { !isBeingRead($0) }
            guard !files.isEmpty else {
                failLibraryFetch(token, provider, folder, root, ending: "a read of these files has not returned")
                return
            }
            let result = await readPass(files, in: root, with: fetch)
            guard isCurrentLibraryFetch(token, root: root) else { return }
            lastFailure = result.failures.last
            DiagnosticLog.event(
                .storage,
                "LIBRARY_FETCH: pass \(pass) read \(DataDirectoryUnavailability.listed(names(of: files, in: root))); "
                    + (result.failures.isEmpty
                        ? "all read"
                        : "\(result.failures.count) failed (\(DataDirectoryUnavailability.listed(result.failures)))")
            )
            if !result.stalled.isEmpty {
                let seconds = Int(libraryFetchStallLimit.components.seconds)
                let offline = libraryFetchReachability.isOnline() ? "" : ", and this Mac is offline"
                failLibraryFetch(token, provider, folder, root, ending: "no answer within \(seconds) seconds\(offline)")
                return
            }
            if checkDataDirectory() {
                openLibraryAfterDataDirectoryReturned()
                return
            }
            // The check found another reason (it is on the screen already),
            // or a switch of libraries replaced this fetch.
            guard libraryFetchToken == token, !pendingLibraryFiles.isEmpty else {
                endLibraryFetch(token)
                return
            }
        }
        guard isCurrentLibraryFetch(token, root: root) else { return }
        let ending = lastFailure.map { "a read failed (\($0))" } ?? "the same files were still only in the cloud"
        failLibraryFetch(token, provider, folder, root, ending: ending)
    }

    /// Reads each of `files` on a queue of its own, off Swift's cooperative
    /// threads, so one stuck read stops no other, and waits for all of them
    /// or for `libraryFetchStallLimit`. A read that returns after the wait
    /// is over is handled by `libraryFileReturned(_:late:)`.
    private func readPass(
        _ files: [URL],
        in root: URL,
        with fetch: @escaping LibraryFileFetch
    ) async -> LibraryFetchPass.Result {
        let pass = LibraryFetchPass(files: files)
        for file in files {
            libraryFilesBeingRead.insert(file.standardizedFileURL.path)
            Task { [weak self] in
                let failure = await OffMainWork.run { Self.failure(reading: file, in: root, with: fetch) }
                let inTime = pass.complete(file, failure: failure)
                self?.libraryFileReturned(file, late: !inTime)
            }
        }
        let limit = libraryFetchStallLimit
        let timer = Task {
            try? await Task.sleep(for: limit)
            pass.expire()
        }
        let result = await pass.result()
        timer.cancel()
        return result
    }

    /// How reading `file` with `fetch` failed, by the file's name in `root`
    /// and the error's domain and code (never a message that may hold a
    /// path); nil when the read succeeded. Blocks, so call it off the main
    /// thread.
    private nonisolated static func failure(reading file: URL, in root: URL, with fetch: LibraryFileFetch) -> String? {
        do {
            try fetch(file)
            return nil
        } catch {
            let nsError = error as NSError
            return "\(DataDirectoryPaths.relativeName(of: file, in: root)): \(nsError.domain) \(nsError.code)"
        }
    }

    /// A read of `file` returned. When it came after its fetch gave up
    /// (`late`) and no fetch runs now, the files it was holding may have
    /// been the last ones missing: the check runs again, and the library
    /// opens if it is there.
    private func libraryFileReturned(_ file: URL, late: Bool) {
        libraryFilesBeingRead.remove(file.standardizedFileURL.path)
        guard late, libraryFetchTask == nil, dataDirectoryUnavailability != nil else { return }
        DiagnosticLog.event(
            .storage,
            "LIBRARY_FETCH: a read of \(DataDirectoryPaths.relativeName(of: file, in: TextMouthPaths.root)) returned late"
        )
        if checkDataDirectory() {
            openLibraryAfterDataDirectoryReturned()
        }
    }

    // MARK: Endings

    /// Ends the fetch with the failure screen: `ending` says in a few words
    /// why, for the log, and the reason names the files still waiting.
    private func failLibraryFetch(
        _ token: UUID,
        _ provider: CloudProvider?,
        _ folder: String,
        _ root: URL,
        ending: String
    ) {
        guard isCurrentLibraryFetch(token, root: root) else { return }
        let named = names(of: pendingLibraryFiles, in: root)
        DiagnosticLog.event(.storage, "LIBRARY_FETCH: gave up on \(DataDirectoryUnavailability.listed(named)); \(ending)")
        endLibraryFetch(token)
        noteDataDirectoryUnavailable(.cloudFetchFailed(provider, folder: folder, files: named, ending: ending))
    }

    /// Ends the fetch named by `token`, unless another has replaced it.
    private func endLibraryFetch(_ token: UUID) {
        if libraryFetchToken == token {
            cancelLibraryFetch()
        }
    }

    // MARK: Helpers

    /// Whether `token` still names the running fetch and the data directory
    /// is still `root`. A fetch of a data directory no longer in use is
    /// dropped here.
    private func isCurrentLibraryFetch(_ token: UUID, root: URL) -> Bool {
        guard libraryFetchToken == token else { return false }
        guard TextMouthPaths.root.standardizedFileURL.path == root.standardizedFileURL.path else {
            cancelLibraryFetch()
            return false
        }
        return true
    }

    /// Whether a read of `file` was started and has not returned.
    private func isBeingRead(_ file: URL) -> Bool {
        libraryFilesBeingRead.contains(file.standardizedFileURL.path)
    }

    /// `files` by name in the data directory `root`, as logs and the
    /// screen's log description list them.
    private func names(of files: [URL], in root: URL) -> [String] {
        files.map { DataDirectoryPaths.relativeName(of: $0, in: root) }
    }
}

// MARK: - One Pass of Reads

/// The reads of one pass of a fetch: it hears each finish, from any thread,
/// and hands the waiting pass its result when all have, or when the stall
/// limit expires with some still out.
final class LibraryFetchPass: @unchecked Sendable {
    /// What a pass found.
    struct Result: Sendable {
        /// How each read that failed failed (`failure(reading:in:with:)`).
        var failures: [String] = []
        /// The files whose reads had not returned when the limit expired.
        var stalled: [URL] = []
    }

    /// Guards every stored property below.
    private let lock = NSLock()
    /// The files of this pass not yet read, by standardized path.
    private var outstanding: [String: URL]
    /// What has been found so far.
    private var found = Result()
    /// Whether the pass has ended, by every read returning or by expiry.
    private var isOver = false
    /// The waiting pass, until it is handed the result.
    private var waiter: CheckedContinuation<Result, Never>?

    /// A pass over `files`.
    init(files: [URL]) {
        outstanding = Dictionary(files.map { ($0.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Records the read of `file`, which failed as `failure` says, or nil.
    /// Returns whether it came in time: false when the pass was over already.
    func complete(_ file: URL, failure: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOver else { return false }
        outstanding[file.standardizedFileURL.path] = nil
        if let failure {
            found.failures.append(failure)
        }
        if outstanding.isEmpty {
            end()
        }
        return true
    }

    /// Ends the pass with the reads still out as stalled; does nothing if it
    /// has ended already.
    func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard !isOver else { return }
        found.stalled = Array(outstanding.values)
        end()
    }

    /// The result, once the pass is over.
    func result() async -> Result {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if isOver {
                continuation.resume(returning: found)
            } else {
                waiter = continuation
            }
        }
    }

    /// Marks the pass over and hands the result to the waiter. Call with
    /// `lock` held.
    private func end() {
        isOver = true
        waiter?.resume(returning: found)
        waiter = nil
    }
}

// MARK: - Checks That Ask Nothing of the Sync Service

/// The sync service as the library's check sees it while a fetch runs: the
/// same answers, but no request to download anything (`requestDownload`), since
/// the fetch is reading those files itself.
struct WithoutDownloadRequests: CloudItemStatusProviding {
    /// The service whose answers are passed on.
    let base: any CloudItemStatusProviding

    /// Where the folder at `folder` lives.
    func location(of folder: URL) -> StorageLocation { base.location(of: folder) }

    /// The cloud state of the file at `file`.
    func status(of file: URL) -> CloudItemStatus { base.status(of: file) }

    /// Asks nothing: the fetch reads the file itself.
    func requestDownload(of file: URL) throws {}

    /// Asks the sync service to remove the local copy of the file at `file`.
    func removeLocalCopy(of file: URL) throws { try base.removeLocalCopy(of: file) }
}
