import Foundation
import os

// MARK: - Book Cloud Storage (FR02)

/// Cloud state, downloads, and removals of whole books (FR02), built on the
/// file-level `SyncFlagReporting`.
///
/// A book is its .tmb package folder (or, for an old book, its own file),
/// and its state is the state of every file inside. Listing a package and
/// reading its files' states happen inside `DatalessFiles.withoutDownloading`,
/// so they never wait on the network; they can still wait on the file
/// system, so call every method off the main thread.
///
/// Each look at a package decides once which items the sync service syncs.
/// iCloud Drive syncs a package as one item: the package carries the sync
/// flags and its files none, and the service refuses a download or a
/// removal asked for one of those files as for an item that doesn't exist.
/// Then the package's own flags say whether the book's changes have
/// uploaded and whether it is downloading, and the package is what a
/// download asks for and a removal removes. Google Drive and Dropbox sync
/// each file, and every file carries its own flags (their package folders
/// carry flags too), so each file counts on its own (`Survey.packageItem`).
///
/// A download asks the sync service for each missing item, then checks the
/// package every half second, reporting progress as files arrive, until
/// every file is on this Mac or it gives up: at once when this Mac is
/// offline, when an item reports a download error, when the package
/// disappears, or after a minute with nothing arriving and nothing being
/// downloaded. Meanwhile it listens for the progress the sync service
/// publishes for the package as a whole, as iCloud Drive does for a package
/// it syncs as one item, and for each file still to come, as Google Drive
/// and Dropbox do (`PublishedFileProgress`). A part it publishes counts
/// toward the progress, by size or by files, so a book of one large file,
/// or a package arriving as one item, shows how far it has got. What it
/// publishes nothing for counts only once it is here, as before.
///
/// What is slow or outside the app is injectable, so tests run without a
/// cloud drive or real time: the file-level provider, network reachability,
/// the sleep between checks, the stall limit, the folder listing, where the
/// one-line events go, and the progress published for files.
final class BookCloudStorageService: BookCloudStorage {

    // MARK: Types

    /// Waits for a span of time, or throws `CancellationError` when the
    /// waiting task is cancelled: `Task.sleep(for:)` in the app.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Lists the folders and regular files directly inside a folder; throws
    /// as `FileManager` does, including the refusal to list a folder that is
    /// only in the cloud (`DatalessFiles.isDownloadRefusal(_:)`).
    typealias FolderReader = @Sendable (URL) throws -> [PackageEntry]

    /// Listens for the progress the sync service publishes for a download of
    /// one item, a file or a package, handing each fraction heard, from 0 to
    /// 1, to the handler, on the thread it is heard on; calling the closure
    /// it returns stops the listening. `PublishedFileProgress` in the app.
    typealias ProgressListener = @Sendable (URL, @escaping @Sendable (Double) -> Void) -> @Sendable () -> Void

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

    /// One item of a book, a file or the package folder itself, and its
    /// cloud state.
    struct FileStatus: Equatable, Sendable {
        /// Where the item is.
        let url: URL
        /// Its cloud state when it was read.
        let status: CloudItemStatus
        /// Whether it carried sync flags of its own when it was read
        /// (`FlaggedItemStatus`).
        let carriesSyncFlags: Bool
    }

    // MARK: Settings

    /// How long a download waits between two checks of its files.
    static let pollInterval: Duration = .milliseconds(500)

    /// How long a download waits, with no file arriving and none being
    /// downloaded, before it gives up as stalled.
    static let defaultStallLimit: Duration = .seconds(60)

    // MARK: Dependencies

    /// The state of single items, the package and its files, whether each
    /// carries sync flags of its own, and requests to the sync service.
    private let items: any SyncFlagReporting
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
    /// Listens for the progress the sync service publishes for one item.
    private let listenForProgress: ProgressListener

    /// Storage built on `items`. The rest is for tests: reachability (the
    /// system's), the sleep between checks (a real one), the stall limit
    /// (60 seconds), the folder listing (`FileManager`'s), where event lines
    /// go (the debug log, as storage events), and how a download listens
    /// for the progress published for an item (`PublishedFileProgress`).
    init(
        items: any SyncFlagReporting,
        reachability: NetworkReachability = .system,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        stallLimit: Duration = BookCloudStorageService.defaultStallLimit,
        readFolder: @escaping FolderReader = { try BookCloudStorageService.readFolder($0) },
        logEvent: @escaping @Sendable (String) -> Void = { DiagnosticLog.event(.storage, $0) },
        listenForProgress: @escaping ProgressListener = { file, hear in
            let listening = PublishedFileProgress.listen(to: file, hearing: hear)
            return { listening.stop() }
        }
    ) {
        self.items = items
        self.reachability = reachability
        self.sleep = sleep
        self.stallLimit = stallLimit
        self.readFolder = readFolder
        self.logEvent = logEvent
        self.listenForProgress = listenForProgress
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
        state(of: package, in: libraryLocation())
    }

    /// The cloud state of `package` in a library at `location`, which the
    /// caller has just read (see `BookCloudStorage`): `state(of:)` without
    /// working out the location again, as a refresh of every package asks
    /// (PERF16).
    func state(of package: BookPackage, in location: StorageLocation) -> BookCloudState {
        guard location.isCloud else { return .local }
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
    /// progress to `report`, until every file is on this Mac. Meanwhile it
    /// listens for the progress published for the package as a whole and
    /// for each file still to come, and counts the parts heard. Throws a
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
        // The parts the sync service publishes of the package as a whole and
        // of the files still to come, and how to stop listening to each, by
        // path. Every listening stops when the download ends, however it
        // ends.
        let parts = PublishedParts()
        var listening: [String: @Sendable () -> Void] = [:]
        defer { listening.values.forEach { $0() } }
        do {
            var survey = try self.survey(of: package)
            // Every file is here already: there is nothing to download.
            guard !survey.isComplete else { return }
            guard reachability.isOnline() else { throw BookCloudError.offline }

            // Sizes measure progress only when every item still to come
            // reports one at the start, so the measure never switches to
            // sizes midway; it switches to files if new items lack sizes.
            var bySize = survey.sizesAreKnown
            listen(to: survey, of: package, into: parts, listening: &listening)
            var heard = parts.percents
            var current = survey.progress(bySize: bySize, parts: heard)
            let service = items.location(of: package.url).provider?.displayName ?? "the sync service"
            let asOneItem = survey.packageItem == nil ? "" : ", which syncs the package as one item"
            logEvent(
                "CLOUD_DOWNLOAD_STARTED: \(name): \(current.totalFiles - current.completedFiles) of "
                    + "\(current.totalFiles) files to come from \(service)\(asOneItem)"
            )
            var requested = Set<URL>()
            try request(survey, of: bookID, requested: &requested)
            latest = current
            report(current)

            var idle = Duration.zero
            var foldersInCloud = survey.listing.foldersInCloud.count
            var itemsWithErrors = Set<URL>()
            // Whether the trace has said that the sync service publishes
            // parts of files or of the package, which it says once a
            // download.
            var tracedParts = false
            while true {
                try await sleep(Self.pollInterval)
                try Task.checkCancellation()
                survey = try self.survey(of: package)

                // A download error counts once an item still reports it at
                // the next check, so an error left from an earlier attempt,
                // which the new request clears, never ends this one.
                let errors = survey.downloadErrors
                if let repeated = errors.first(where: { itemsWithErrors.contains($0.url) }) {
                    throw BookCloudError.provider(repeated.message)
                }
                itemsWithErrors = Set(errors.map(\.url))

                // Files found since, such as those of a folder that arrived,
                // are listened to as well. A part heard of a file that is
                // here now, or gone, is forgotten, so a file that goes back
                // to the cloud counts from nothing again. The package's part
                // lasts the whole download, which ends once it is here.
                listen(to: survey, of: package, into: parts, listening: &listening)
                parts.forget(survey.files.filter { !$0.status.state.isArriving }.map(\.url.path))
                let heardBefore = heard
                heard = parts.percents
                if !tracedParts, !heard.isEmpty {
                    tracedParts = true
                    let whose = package.isPackage && heard[package.url.path] != nil ? "for the package as a whole" : "within files"
                    DiagnosticLog.trace(.storage, "cloud download \(bookID): the sync service publishes progress \(whose)")
                }

                bySize = bySize && survey.sizesAreKnown
                let next = survey.progress(bySize: bySize, parts: heard)
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

                // The download moves while a file or folder arrives, while
                // the sync service downloads anything, or while it publishes
                // more of a file or of the package.
                let arrived = next.completedFiles > current.completedFiles
                    || survey.listing.foldersInCloud.count < foldersInCloud
                    || heard.contains { path, percent in percent > heardBefore[path] ?? 0 }
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

    /// Starts listening for the progress the sync service publishes for
    /// `package` as a whole, which iCloud Drive publishes for a package it
    /// syncs as one item, and for each file of `survey` still to come, which
    /// Google Drive and Dropbox publish, each not listened to yet; what is
    /// heard is noted in `parts`, and `listening` keeps how to stop each. A
    /// book without a package is its own file, listened to once.
    private func listen(
        to survey: Survey,
        of package: BookPackage,
        into parts: PublishedParts,
        listening: inout [String: @Sendable () -> Void]
    ) {
        let arriving = survey.files.filter { $0.status.state.isArriving }.map(\.url)
        for item in [package.url] + arriving where listening[item.path] == nil {
            let path = item.path
            listening[path] = listenForProgress(item) { fraction in
                parts.hear(fraction, of: path)
            }
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

    /// Removes the local copies of `package`'s downloaded items, keeping
    /// them in the cloud: the package as one item when the sync service
    /// syncs it so, and otherwise each downloaded file. Refuses with
    /// `BookCloudError.notUploaded`, before removing anything, while any of
    /// those items has changes waiting to upload; throws `.removalFailed`
    /// when the sync service refuses a removal, and `.packageMissing` when
    /// the package is not on this Mac.
    func removeDownload(of package: BookPackage) throws {
        let name = Self.logName(of: package)
        do {
            let survey = try self.survey(of: package)
            guard survey.isUploaded else {
                throw BookCloudError.notUploaded
            }
            let removing = survey.itemsToRemove
            for item in removing {
                do {
                    try items.removeLocalCopy(of: item)
                } catch {
                    throw BookCloudError.removalFailed(error.localizedDescription)
                }
            }
            logEvent("CLOUD_DOWNLOAD_REMOVED: \(name): \(survey.removalWords(removing: removing))")
        } catch let error as BookCloudError {
            logEvent("CLOUD_DOWNLOAD_REMOVAL_FAILED: \(name): \(error.logDescription)")
            throw error
        }
    }

    // MARK: Surveying a Package

    /// A package's listing, the state of each of its files, and the
    /// package folder's own state, read at one moment, with what follows
    /// from them.
    struct Survey: Equatable, Sendable {
        /// What the package holds.
        var listing: PackageListing
        /// Each listed file's state, in the listing's order.
        var files: [FileStatus]
        /// The package folder's own state, for a book with a package; nil
        /// for an old book that is its own file.
        var package: FileStatus?

        /// The package, when the sync service syncs it as one item: the
        /// package carries sync flags of its own and none of its listed
        /// files does, as on iCloud Drive (none is listed while the whole
        /// package is only in the cloud). Nil when the service syncs each
        /// file on its own, as Google Drive and Dropbox do: their files
        /// carry flags, as their package folders do too.
        var packageItem: FileStatus? {
            guard let package, package.carriesSyncFlags, !files.contains(where: \.carriesSyncFlags) else { return nil }
            return package
        }

        /// The items the sync service syncs: the package as one item, or
        /// each file on its own. Their flags say what has uploaded and what
        /// is downloading, and they are what a download asks for and a
        /// removal removes.
        var syncedItems: [FileStatus] {
            packageItem.map { [$0] } ?? files
        }

        /// The book's state: downloading while the sync service downloads a
        /// package it syncs as one item, whose folder stays only in the
        /// cloud until the whole package arrives; otherwise in the cloud
        /// when any file or folder, or such a package, is only in the cloud;
        /// otherwise downloading when any item is being downloaded;
        /// otherwise downloaded.
        var bookState: BookCloudState {
            let packageItemState = packageItem?.status.state
            if packageItemState == .downloading {
                return .downloading(progress(bySize: sizesAreKnown))
            }
            let onlyInCloud = !listing.foldersInCloud.isEmpty
                || files.contains { $0.status.state == .notDownloaded }
                || packageItemState == .notDownloaded
            if onlyInCloud {
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

        /// Whether the sync service is downloading any item it syncs now.
        var isDownloading: Bool {
            syncedItems.contains { $0.status.state == .downloading }
        }

        /// Whether every item the sync service syncs has uploaded its
        /// changes, by that item's own flag: the package's, when the service
        /// syncs the package as one item, and never an upload flag its files
        /// leave out, which counts as uploaded.
        var isUploaded: Bool {
            syncedItems.allSatisfy(\.status.isUploaded)
        }

        /// What to ask the sync service for. A package it syncs as one item
        /// is asked for whole, while anything of it is still in the cloud and
        /// the service is not downloading it already: it refuses a request
        /// for a file inside. Otherwise every folder still in the cloud,
        /// then every file not downloaded and not being downloaded.
        var itemsToRequest: [URL] {
            if let packageItem {
                return isComplete || packageItem.status.state == .downloading ? [] : [packageItem.url]
            }
            return listing.foldersInCloud + files.filter { $0.status.state == .notDownloaded }.map(\.url)
        }

        /// What a removal removes: each item the sync service syncs whose
        /// content is on this Mac.
        var itemsToRemove: [URL] {
            syncedItems.filter { $0.status.state == .downloaded }.map(\.url)
        }

        /// The removal of `removing` in an event line's words: how many of
        /// the book's files lose their local copies, and, for a package the
        /// sync service syncs as one item, that they go as one.
        func removalWords(removing: [URL]) -> String {
            guard packageItem != nil else {
                return "\(removing.count) of \(files.count) files"
            }
            let removed = removing.isEmpty ? 0 : files.filter { $0.status.state.isOnThisMac }.count
            return "\(removed) of \(files.count) files, as one package"
        }

        /// The download errors reported by the items the sync service syncs
        /// that are still only in the cloud. An item being downloaded, or
        /// already here, may still carry an error from an earlier attempt,
        /// which no longer matters.
        var downloadErrors: [(url: URL, message: String)] {
            syncedItems.compactMap { item in
                guard item.status.state == .notDownloaded, let message = item.status.downloadError else { return nil }
                return (item.url, message)
            }
        }

        /// Whether progress can be measured by size: every file still to
        /// come reports a size above zero, and no folder's contents are
        /// unknown.
        var sizesAreKnown: Bool {
            BookCloudStorageService.sizesAreKnown(of: files.map(\.status), foldersInCloud: listing.foldersInCloud.count)
        }

        /// How far the download has got, by size or by files, with `parts`,
        /// the parts the sync service published, in whole percent by path,
        /// folded in. Each file still to come counts its own part or, when
        /// that is less, the part published for the package as a whole, as
        /// iCloud Drive publishes a package arriving as one item: by size,
        /// the file's reported size times that part; by files, that part of
        /// one file. By files, each folder still in the cloud, the package's
        /// own among them, counts as one file to come, of which the
        /// package's part is done. What nothing was published for counts
        /// only once it is here.
        func progress(bySize: Bool, parts: [String: Int] = [:]) -> BookDownloadProgress {
            var progress = BookCloudStorageService.progress(
                of: files.map(\.status),
                foldersInCloud: listing.foldersInCloud.count,
                bySize: bySize
            )
            let packagePart = package.flatMap { parts[$0.url.path] } ?? 0
            for file in files where file.status.state.isArriving {
                let percent = max(parts[file.url.path] ?? 0, packagePart)
                guard percent > 0 else { continue }
                if bySize {
                    progress.completedBytes += (file.status.byteCount ?? 0) * Int64(percent) / 100
                } else {
                    progress.partialFiles += Double(percent) / 100
                }
            }
            // By size no folder is still in the cloud: one makes the
            // download count files (`sizesAreKnown`).
            if !bySize {
                progress.partialFiles += Double(packagePart) / 100 * Double(listing.foldersInCloud.count)
            }
            return progress
        }
    }

    /// The parts of the package as a whole, and of its files still to come,
    /// that the sync service publishes during one download: heard on the
    /// system's threads, and read at each check.
    private struct PublishedParts: Sendable {
        /// Each item's part, in whole percent, by path: the most heard since
        /// a file was last seen here, or, for the package, since the download
        /// began, so a download the sync service starts again never takes
        /// the progress back. Whole percents keep the progress from changing
        /// at every check of a download that takes minutes.
        private let percentsByPath = OSAllocatedUnfairLock(initialState: [String: Int]())

        /// Notes that the sync service published `fraction` of the item at
        /// `path`; a fraction that is no number is passed over.
        func hear(_ fraction: Double, of path: String) {
            guard fraction.isFinite else { return }
            let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
            percentsByPath.withLock { percents in
                percents[path] = max(percents[path] ?? 0, percent)
            }
        }

        /// Forgets the parts heard of the files at `paths`.
        func forget(_ paths: [String]) {
            guard !paths.isEmpty else { return }
            percentsByPath.withLock { percents in
                for path in paths {
                    percents[path] = nil
                }
            }
        }

        /// Each item's part so far, in whole percent, by path.
        var percents: [String: Int] {
            percentsByPath.withLock { $0 }
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

    /// Lists `package`, and reads the state of each of its files and, for a
    /// package folder, of the folder itself, each with whether it carries
    /// sync flags of its own, from which the survey tells whether the sync
    /// service syncs the package as one item (`Survey.packageItem`). The
    /// real-drive tests use it to act on the items the app acts on.
    func survey(of package: BookPackage) throws -> Survey {
        let listing = try listing(of: package)
        return Survey(
            listing: listing,
            files: listing.files.map(fileStatus(of:)),
            package: package.isPackage ? fileStatus(of: package.url) : nil
        )
    }

    /// The state of the item at `item`, with whether it carries sync flags
    /// of its own, from one read.
    private func fileStatus(of item: URL) -> FileStatus {
        let read = items.flaggedStatus(of: item)
        return FileStatus(url: item, status: read.status, carriesSyncFlags: read.carriesSyncFlags)
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
        let items = UbiquitousItemStatusProvider()
        itemStatus = items
        bookStorage = BookCloudStorageService(items: items)
    }
}

// MARK: - Helpers

private extension CloudItemState {
    /// Whether the content is on this Mac: downloaded, or a local file no
    /// sync service manages.
    var isOnThisMac: Bool {
        self == .downloaded || self == .local
    }

    /// Whether the content is still to come: only in the cloud, or being
    /// downloaded.
    var isArriving: Bool {
        self == .notDownloaded || self == .downloading
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
        case .keptOnThisMac: return "the book is kept on this Mac"
        case .keptForReadingList: return "the book is kept on this Mac for the reading list"
        case .packageMissing: return "the package is not on this Mac"
        }
    }
}
