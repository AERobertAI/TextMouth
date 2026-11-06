import Foundation

// MARK: - Getting the Library's Files From the Cloud

/// When the data directory check finds the files the library opens from only
/// in the cloud (a library in Google Drive's Stream mode, after those files
/// were evicted), the library fetches them itself and opens when they have
/// arrived, instead of waiting for Try Again.
///
/// The check stays metadata-only on the main thread. A fetch reads the files
/// it named, on a background thread, with downloads allowed
/// (`LibraryFileFetcher`), and then runs the check again: a feed's folders
/// can't be named until the Feeds folder has been listed, so each pass
/// fetches whatever the last check named. It stops when the library is
/// available, when a pass names the same files as the one before (no
/// progress), or after `maxLibraryFetchPasses` passes, so it always ends.
/// Only the files the check names are ever read, never a book or an episode.
extension LibraryViewModel {
    /// The most passes one fetch makes: the Feeds folder, then the feeds'
    /// folders and indexes, with room to spare.
    static let maxLibraryFetchPasses = 6

    /// Starts fetching the files the last check named when `reason` says
    /// they are only in the cloud, and shows the screen's "getting your
    /// library" reason meanwhile. A fetch already running for this data
    /// directory is left to finish, so Try Again during a fetch starts
    /// nothing. Returns whether a fetch is running for `reason`, in which
    /// case the caller leaves the reason to it.
    func beginLibraryFetch(for reason: DataDirectoryUnavailability) -> Bool {
        guard let fetch = dataDirectoryEnvironment.libraryFetch,
              case .notDownloaded(let provider, let folder) = reason,
              !pendingLibraryFiles.isEmpty else { return false }
        let root = TextMouthPaths.root
        if libraryFetchTask != nil {
            if libraryFetchRoot == root.standardizedFileURL.path { return true }
            // The data directory changed since: that fetch's results are moot.
            cancelLibraryFetch()
        }
        let token = UUID()
        libraryFetchToken = token
        libraryFetchRoot = root.standardizedFileURL.path
        noteDataDirectoryUnavailable(.gettingFromCloud(provider, folder: folder, files: names(of: pendingLibraryFiles, in: root)))
        libraryFetchTask = Task { [weak self] in
            await self?.runLibraryFetch(token: token, root: root, provider: provider, folder: folder, fetch: fetch)
        }
        return true
    }

    /// Drops the running fetch, if any: its results are ignored from now on.
    func cancelLibraryFetch() {
        libraryFetchTask?.cancel()
        libraryFetchTask = nil
        libraryFetchToken = nil
        libraryFetchRoot = nil
    }

    // MARK: Passes

    /// The passes of one fetch: read what the last check named, check again,
    /// and repeat until the library is available (and opens), the check
    /// finds another reason, a pass names the same files as the one before,
    /// or the passes run out, which shows the failure.
    private func runLibraryFetch(
        token: UUID,
        root: URL,
        provider: CloudProvider?,
        folder: String,
        fetch: @escaping LibraryFileFetch
    ) async {
        var previousNames: [String] = []
        var lastFailure: String?
        for pass in 1...Self.maxLibraryFetchPasses {
            let files = pendingLibraryFiles
            let named = names(of: files, in: root)
            // The same files named again: whatever was read did not bring them.
            guard named != previousNames else { break }
            previousNames = named
            let failures = await Self.read(files, in: root, with: fetch)
            guard isCurrentLibraryFetch(token, root: root) else { return }
            lastFailure = failures.last ?? lastFailure
            DiagnosticLog.event(
                .storage,
                "LIBRARY_FETCH: pass \(pass) read \(DataDirectoryUnavailability.listed(named)); "
                    + (failures.isEmpty ? "all read" : "\(failures.count) failed (\(failures.joined(separator: "; ")))")
            )
            if checkDataDirectory() {
                openLibraryAfterDataDirectoryReturned()
                return
            }
            // The check found another reason (it is on the screen already),
            // or Use Default Location replaced this fetch.
            guard libraryFetchToken == token, !pendingLibraryFiles.isEmpty else {
                cancelLibraryFetchIfCurrent(token)
                return
            }
        }
        guard isCurrentLibraryFetch(token, root: root) else { return }
        let ending = lastFailure.map { "a read failed (\($0))" } ?? "the same files were still only in the cloud"
        DiagnosticLog.event(.storage, "LIBRARY_FETCH: gave up; \(ending)")
        cancelLibraryFetch()
        noteDataDirectoryUnavailable(.cloudFetchFailed(
            provider,
            folder: folder,
            files: names(of: pendingLibraryFiles, in: root),
            ending: ending
        ))
    }

    /// Reads each of `files` with `fetch` off the main thread, and returns
    /// how each read that failed failed, by the file's name in `root` and
    /// the error's domain and code (never a message that may hold a path).
    private nonisolated static func read(_ files: [URL], in root: URL, with fetch: @escaping LibraryFileFetch) async -> [String] {
        await Task.detached(priority: .utility) {
            files.compactMap { file -> String? in
                do {
                    try fetch(file)
                    return nil
                } catch {
                    let nsError = error as NSError
                    return "\(DataDirectoryPaths.relativeName(of: file, in: root)): \(nsError.domain) \(nsError.code)"
                }
            }
        }.value
    }

    // MARK: Helpers

    /// Whether `token` still names the running fetch and the data directory
    /// is still `root`. A fetch of a data directory no longer in use, as after
    /// Use Default Location, is dropped here.
    private func isCurrentLibraryFetch(_ token: UUID, root: URL) -> Bool {
        guard libraryFetchToken == token else { return false }
        guard TextMouthPaths.root.standardizedFileURL.path == root.standardizedFileURL.path else {
            cancelLibraryFetch()
            return false
        }
        return true
    }

    /// Ends the fetch named by `token`, unless another has replaced it.
    private func cancelLibraryFetchIfCurrent(_ token: UUID) {
        if libraryFetchToken == token {
            cancelLibraryFetch()
        }
    }

    /// `files` by name in the data directory `root`, as logs and the screen's
    /// log description list them.
    private func names(of files: [URL], in root: URL) -> [String] {
        files.map { DataDirectoryPaths.relativeName(of: $0, in: root) }
    }
}
