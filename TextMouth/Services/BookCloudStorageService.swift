import Foundation

// MARK: - Book Cloud Storage (FR02)

/// Cloud state, downloads, and removals of whole books (FR02), built on the
/// file-level `CloudItemStatusProviding`.
///
/// A book is its .tmb package folder (or, for an old book, its own file),
/// and its state is the state of every file inside. Listing a package and
/// reading its files' states happen inside `DatalessFiles.withoutDownloading`,
/// so they never wait on the network; they can still wait on the file
/// system, so call every method off the main thread.
///
/// A download asks the sync service for each missing file, then checks the
/// package every half second, reporting progress as files arrive, until
/// every file is on this Mac or it gives up: at once when this Mac is
/// offline, when a file reports a download error, when the package
/// disappears, or after a minute with no file arriving and none being
/// downloaded.
///
/// What is slow or outside the app is injectable, so tests run without a
/// cloud drive or real time: the file-level provider, network reachability,
/// the sleep between checks, the stall limit, the folder listing, and where
/// the one-line events go.
final class BookCloudStorageService: BookCloudStorage {

    // MARK: Types

    /// Waits for a span of time, or throws `CancellationError` when the
    /// waiting task is cancelled: `Task.sleep(for:)` in the app.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Lists the folders and regular files directly inside a folder; throws
    /// as `FileManager` does, including the refusal to list a folder that is
    /// only in the cloud (`DatalessFiles.isDownloadRefusal(_:)`).
    typealias FolderReader = @Sendable (URL) throws -> [PackageEntry]

    /// One folder or regular file directly inside a folder.
    struct PackageEntry: Equatable, Sendable {
        /// Where it is.
        let url: URL
        /// Whether it is a folder rather than a regular file.
        let isFolder: Bool
    }

    /// What a package holds, as far as it can be listed without downloading
    /// anything.
    struct PackageListing: Equatable, Sendable {
        /// The package's regular files in path order, every one but
        /// `.DS_Store`; for a book without a package, its own file.
        var files: [URL] = []
        /// The package's folders, its own included, that the system would
        /// not list because they are only in the cloud. What they hold is
        /// unknown until the sync service downloads them.
        var foldersInCloud: [URL] = []
    }

    /// One file of a package and its cloud state.
    struct FileStatus: Equatable, Sendable {
        /// Where the file is.
        let url: URL
        /// Its cloud state when it was read.
        let status: CloudItemStatus
    }

    // MARK: Settings

    /// How long a download waits between two checks of its files.
    static let pollInterval: Duration = .milliseconds(500)

    /// How long a download waits, with no file arriving and none being
    /// downloaded, before it gives up as stalled.
    static let defaultStallLimit: Duration = .seconds(60)

    // MARK: Dependencies

    /// The state of single files, and requests to the sync service.
    private let items: any CloudItemStatusProviding
    /// Whether this Mac is online.
    private let reachability: NetworkReachability
    /// The wait between two checks of a download's files.
    private let sleep: Sleep
    /// How long a download may make no progress before it gives up.
    private let stallLimit: Duration
    /// Lists one folder of a package.
    private let readFolder: FolderReader
    /// Writes one event line: the start, end, or failure of a download or
    /// a removal.
    private let logEvent: @Sendable (String) -> Void

    /// Storage built on `items`. The rest is for tests: reachability (the
    /// system's), the sleep between checks (a real one), the stall limit
    /// (60 seconds), the folder listing (`FileManager`'s), and where event
    /// lines go (the debug log, as storage events).
    init(
        items: any CloudItemStatusProviding,
        reachability: NetworkReachability = .system,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        stallLimit: Duration = BookCloudStorageService.defaultStallLimit,
        readFolder: @escaping FolderReader = { try BookCloudStorageService.readFolder($0) },
        logEvent: @escaping @Sendable (String) -> Void = { DiagnosticLog.event(.storage, $0) }
    ) {
        self.items = items
        self.reachability = reachability
        self.sleep = sleep
        self.stallLimit = stallLimit
        self.readFolder = readFolder
        self.logEvent = logEvent
    }

    // MARK: Where the Library Lives

    /// Where the data directory in use lives.
    func libraryLocation() -> StorageLocation {
        items.location(of: TextMouthPaths.root)
    }

    // MARK: A Book's State

    /// The cloud state of `package`, read without downloading anything:
    /// local when the library is not in a cloud location, waiting for sync
    /// when the package is not on this Mac yet, and otherwise what its files
    /// say (`Survey.bookState`).
    func state(of package: BookPackage) -> BookCloudState {
        guard libraryLocation().isCloud else { return .local }
        do {
            return try survey(of: package).bookState
        } catch BookCloudError.packageMissing {
            return .waitingForSync
        } catch {
            // The package is there but cannot be listed: nothing shows that
            // its files are on this Mac, and a download will say why.
            return .inCloud
        }
    }

    // MARK: Downloading a Book

    /// Downloads every file of `package` (see `BookCloudStorage`). One task
    /// asks for the files and then checks on them; the stream's end cancels
    /// it, so cancelling the task that iterates the stream stops every
    /// request and check.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let polling = Task.detached(priority: .utility) { [self] in
                do {
                    try await runDownload(of: package) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                polling.cancel()
            }
        }
    }

    /// The work of one download: ask the sync service for every missing
    /// item, then check the package every `pollInterval`, handing each new
    /// progress to `report`, until every file is on this Mac. Throws a
    /// `BookCloudError` when the download cannot finish, and
    /// `CancellationError` when its task is cancelled. Writes one event line
    /// when it starts and one when it ends, and only trace lines between.
    private func runDownload(of package: BookPackage, report: (BookDownloadProgress) -> Void) async throws {
        let name = Self.logName(of: package)
        let bookID = Self.traceName(of: package)
        let clock = ContinuousClock()
        let started = clock.now
        // The progress last reported, for the line a cancellation writes.
        var latest: BookDownloadProgress?
        do {
            var survey = try self.survey(of: package)
            // Every file is here already: there is nothing to download.
            guard !survey.isComplete else { return }
            guard reachability.isOnline() else { throw BookCloudError.offline }

            // Sizes measure progress only when every item still to come
            // reports one at the start, so the measure never switches to
            // sizes midway; it switches to files if new items lack sizes.
            var bySize = survey.sizesAreKnown
            var current = survey.progress(bySize: bySize)
            let service = items.location(of: package.url).provider?.displayName ?? "the sync service"
            logEvent(
                "CLOUD_DOWNLOAD_STARTED: \(name): \(current.totalFiles - current.completedFiles) of "
                    + "\(current.totalFiles) files to come from \(service)"
            )
            var requested = Set<URL>()
            try request(survey, of: bookID, requested: &requested)
            latest = current
            report(current)

            var idle = Duration.zero
            var foldersInCloud = survey.listing.foldersInCloud.count
            var filesWithErrors = Set<URL>()
            while true {
                try await sleep(Self.pollInterval)
                try Task.checkCancellation()
                survey = try self.survey(of: package)

                // A download error counts once a file still reports it at
                // the next check, so an error left from an earlier attempt,
                // which the new request clears, never ends this one.
                let errors = survey.downloadErrors
                if let repeated = errors.first(where: { filesWithErrors.contains($0.url) }) {
                    throw BookCloudError.provider(repeated.message)
                }
                filesWithErrors = Set(errors.map(\.url))

                bySize = bySize && survey.sizesAreKnown
                let next = survey.progress(bySize: bySize)
                if next != current {
                    report(next)
                    latest = next
                    DiagnosticLog.trace(
                        .storage,
                        "cloud download \(bookID): \(next.completedFiles) of \(next.totalFiles) files, \(next.percent) percent"
                    )
                }
                if survey.isComplete {
                    let seconds = (clock.now - started).components.seconds
                    logEvent("CLOUD_DOWNLOAD_FINISHED: \(name): \(next.totalFiles) files in \(seconds) seconds")
                    return
                }
                // Folders that arrived may hold files to ask for, and a file
                // can go back to the cloud.
                try request(survey, of: bookID, requested: &requested)

                // The download moves while a file or folder arrives, or while
                // the sync service downloads anything.
                let arrived = next.completedFiles > current.completedFiles
                    || survey.listing.foldersInCloud.count < foldersInCloud
                idle = arrived || survey.isDownloading ? .zero : idle + Self.pollInterval
                current = next
                foldersInCloud = survey.listing.foldersInCloud.count
                if idle >= stallLimit {
                    // A network that went away explains a stall better.
                    throw reachability.isOnline()
                        ? BookCloudError.stalled(seconds: Int(stallLimit.components.seconds))
                        : BookCloudError.offline
                }
            }
        } catch is CancellationError {
            let arrived = latest.map { "\($0.completedFiles) of \($0.totalFiles) files" } ?? "no files"
            logEvent("CLOUD_DOWNLOAD_STOPPED: \(name): cancelled with \(arrived) on this Mac")
            throw CancellationError()
        } catch let error as BookCloudError {
            logEvent("CLOUD_DOWNLOAD_FAILED: \(name): \(error.logDescription)")
            throw error
        } catch {
            logEvent("CLOUD_DOWNLOAD_FAILED: \(name): \(error.localizedDescription)")
            throw BookCloudError.provider(error.localizedDescription)
        }
    }

    /// Asks the sync service for each item `survey` finds only in the cloud
    /// that is not in `requested`, the items already asked for, and adds it
    /// there. An item that began downloading or arrived leaves `requested`,
    /// so it is asked for again if it goes back to the cloud. A refusal ends
    /// the download.
    private func request(_ survey: Survey, of bookID: String, requested: inout Set<URL>) throws {
        let missing = survey.itemsToRequest
        requested.formIntersection(missing)
        let new = missing.filter { !requested.contains($0) }
        guard !new.isEmpty else { return }
        for item in new {
            do {
                try items.requestDownload(of: item)
            } catch {
                throw BookCloudError.provider(error.localizedDescription)
            }
            requested.insert(item)
        }
        DiagnosticLog.trace(.storage, "cloud download \(bookID): asked for \(new.count) items")
    }

    // MARK: Removing a Download

    /// Removes the local copies of `package`'s downloaded files, keeping
    /// them in the cloud. Refuses with `BookCloudError.notUploaded`, before
    /// removing anything, while any file has changes waiting to upload;
    /// throws `.removalFailed` when the sync service refuses a removal, and
    /// `.packageMissing` when the package is not on this Mac.
    func removeDownload(of package: BookPackage) throws {
        let name = Self.logName(of: package)
        do {
            let survey = try self.survey(of: package)
            guard survey.files.allSatisfy(\.status.isUploaded) else {
                throw BookCloudError.notUploaded
            }
            let downloaded = survey.files.filter { $0.status.state == .downloaded }
            for file in downloaded {
                do {
                    try items.removeLocalCopy(of: file.url)
                } catch {
                    throw BookCloudError.removalFailed(error.localizedDescription)
                }
            }
            logEvent("CLOUD_DOWNLOAD_REMOVED: \(name): \(downloaded.count) of \(survey.files.count) files")
        } catch let error as BookCloudError {
            logEvent("CLOUD_DOWNLOAD_REMOVAL_FAILED: \(name): \(error.logDescription)")
            throw error
        }
    }

    // MARK: Surveying a Package

    /// A package's listing and the state of each of its files, read at one
    /// moment, with what follows from them.
    struct Survey: Equatable, Sendable {
        /// What the package holds.
        var listing: PackageListing
        /// Each listed file's state, in the listing's order.
        var files: [FileStatus]

        /// The book's state: in the cloud when any file, or any folder, is
        /// only in the cloud; otherwise downloading when any file is being
        /// downloaded; otherwise downloaded.
        var bookState: BookCloudState {
            if !listing.foldersInCloud.isEmpty || files.contains(where: { $0.status.state == .notDownloaded }) {
                return .inCloud
            }
            if isDownloading {
                return .downloading(progress(bySize: sizesAreKnown))
            }
            return .downloaded
        }

        /// Whether every item is on this Mac: no folder is only in the
        /// cloud, and every file's content is here. A file that vanished
        /// after the listing no longer counts.
        var isComplete: Bool {
            listing.foldersInCloud.isEmpty && files.allSatisfy { $0.status.state.isOnThisMac || $0.status.state == .missing }
        }

        /// Whether the sync service is downloading any file now.
        var isDownloading: Bool {
            files.contains { $0.status.state == .downloading }
        }

        /// What to ask the sync service for: every folder still in the
        /// cloud, then every file not downloaded and not being downloaded.
        var itemsToRequest: [URL] {
            listing.foldersInCloud + files.filter { $0.status.state == .notDownloaded }.map(\.url)
        }

        /// The download errors reported by files still only in the cloud.
        /// A file being downloaded, or already here, may still carry an
        /// error from an earlier attempt, which no longer matters.
        var downloadErrors: [(url: URL, message: String)] {
            files.compactMap { file in
                guard file.status.state == .notDownloaded, let message = file.status.downloadError else { return nil }
                return (file.url, message)
            }
        }

        /// Whether progress can be measured by size: every file still to
        /// come reports a size above zero, and no folder's contents are
        /// unknown.
        var sizesAreKnown: Bool {
            BookCloudStorageService.sizesAreKnown(of: files.map(\.status), foldersInCloud: listing.foldersInCloud.count)
        }

        /// How far the download has got, by size or by files.
        func progress(bySize: Bool) -> BookDownloadProgress {
            BookCloudStorageService.progress(
                of: files.map(\.status),
                foldersInCloud: listing.foldersInCloud.count,
                bySize: bySize
            )
        }
    }

    /// How far a book's download has got, from its files' states: a file is
    /// done once its content is on this Mac, a file that vanished does not
    /// count, and each folder still in the cloud counts as one file to come.
    /// By size, the bytes of the files done out of the bytes of all; by
    /// files, no bytes, so `BookDownloadProgress` counts files.
    static func progress(of statuses: [CloudItemStatus], foldersInCloud: Int, bySize: Bool) -> BookDownloadProgress {
        let present = statuses.filter { $0.state != .missing }
        let done = present.filter { $0.state.isOnThisMac }
        return BookDownloadProgress(
            completedFiles: done.count,
            totalFiles: present.count + foldersInCloud,
            completedBytes: bySize ? done.reduce(0) { $0 + ($1.byteCount ?? 0) } : 0,
            totalBytes: bySize ? present.reduce(0) { $0 + ($1.byteCount ?? 0) } : 0
        )
    }

    /// Whether a download's progress can be measured by size: every file
    /// still to come reports a size above zero, and no folder's contents are
    /// unknown. A dataless iCloud Drive file can report 0 bytes, which would
    /// make the files already here look like nearly the whole book.
    static func sizesAreKnown(of statuses: [CloudItemStatus], foldersInCloud: Int) -> Bool {
        foldersInCloud == 0 && statuses.allSatisfy { status in
            status.state.isOnThisMac || status.state == .missing || (status.byteCount ?? 0) > 0
        }
    }

    /// Lists `package` and reads the state of each of its files.
    private func survey(of package: BookPackage) throws -> Survey {
        let listing = try listing(of: package)
        return Survey(listing: listing, files: listing.files.map { FileStatus(url: $0, status: items.status(of: $0)) })
    }

    /// What `package` holds, listed inside `withoutDownloading`, so a folder
    /// that is only in the cloud is noted rather than downloaded. Throws
    /// `BookCloudError.packageMissing` when nothing is at the package's
    /// place, and `.provider` when a folder cannot be listed for another
    /// reason.
    func listing(of package: BookPackage) throws -> PackageListing {
        try DatalessFiles.withoutDownloading {
            guard package.isPackage else {
                // A book without a package is its own file.
                guard items.status(of: package.url).state != .missing else {
                    throw BookCloudError.packageMissing
                }
                return PackageListing(files: [package.url])
            }
            var listing = PackageListing()
            try collect(package.url, isPackageFolder: true, into: &listing)
            listing.files.sort { $0.path < $1.path }
            return listing
        }
    }

    /// Adds the files inside `folder`, and inside every folder within it, to
    /// `listing`, noting each folder the system would not list because it is
    /// only in the cloud.
    private func collect(_ folder: URL, isPackageFolder: Bool, into listing: inout PackageListing) throws {
        let entries: [PackageEntry]
        do {
            entries = try readFolder(folder)
        } catch let error where DatalessFiles.isDownloadRefusal(error) {
            listing.foldersInCloud.append(folder)
            return
        } catch let error where Self.isMissingItem(error) {
            // The package is gone; a folder within it vanished while it was
            // listed, which leaves nothing of it to download.
            if isPackageFolder { throw BookCloudError.packageMissing }
            return
        } catch {
            throw BookCloudError.provider(error.localizedDescription)
        }
        for entry in entries {
            if entry.isFolder {
                try collect(entry.url, isPackageFolder: false, into: &listing)
            } else if entry.url.lastPathComponent != ".DS_Store" {
                listing.files.append(entry.url)
            }
        }
    }

    /// The folders and regular files directly inside `folder`, through
    /// `FileManager`: the default listing. Links and other special files
    /// hold no book content and are left out.
    static func readFolder(_ folder: URL) throws -> [PackageEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
            .compactMap { child in
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
                if values.isDirectory == true {
                    return PackageEntry(url: child, isFolder: true)
                }
                return values.isRegularFile == true ? PackageEntry(url: child, isFolder: false) : nil
            }
    }

    /// Whether `error`, or an error it wraps, says nothing is at a path.
    static func isMissingItem(_ error: Error) -> Bool {
        let nsError = error as NSError
        let missingCodes: [String: Set<Int>] = [
            NSCocoaErrorDomain: [NSFileNoSuchFileError, NSFileReadNoSuchFileError],
            NSPOSIXErrorDomain: [Int(ENOENT)],
        ]
        if missingCodes[nsError.domain]?.contains(nsError.code) == true {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingItem(underlying)
        }
        return false
    }

    // MARK: Log Lines

    /// How an event line names the book of `package`: its package's path in
    /// the data directory, whose folder name begins with the book's title,
    /// or only the package's name when it is elsewhere. (A package carries
    /// no title of its own.)
    private static func logName(of package: BookPackage) -> String {
        DiagnosticLog.loggablePath(package.url)
    }

    /// How a trace line names the book of `package`: the first eight
    /// characters of its ID, as the log policy asks.
    private static func traceName(of package: BookPackage) -> String {
        String(package.bookID.uuidString.prefix(8))
    }
}

// MARK: - Installation

extension CloudServices {
    /// Puts the real cloud services in place of the local placeholders:
    /// called once at launch, before the library model is created, because
    /// the library's launch checks use them. The hosted tests' data
    /// directory is in their sandbox on the startup disk, so their libraries
    /// still read as local.
    static func installSystemServices() {
        itemStatus = UbiquitousItemStatusProvider()
        bookStorage = BookCloudStorageService(items: itemStatus)
    }
}

// MARK: - Helpers

private extension CloudItemState {
    /// Whether the content is on this Mac: downloaded, or a local file no
    /// sync service manages.
    var isOnThisMac: Bool {
        self == .downloaded || self == .local
    }
}

private extension BookCloudError {
    /// The reason in an event line's words.
    var logDescription: String {
        switch self {
        case .offline: return "this Mac is offline"
        case .stalled(let seconds): return "nothing arrived for \(seconds) seconds"
        case .provider(let message), .removalFailed(let message): return "the sync service said: \(message)"
        case .notUploaded: return "changes are waiting to upload"
        case .bookIsOpen: return "the book is open"
        case .packageMissing: return "the package is not on this Mac"
        }
    }
}
