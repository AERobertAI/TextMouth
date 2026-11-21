import Foundation

// MARK: - The Small Files the Library Opens With

/// The few small files other services read when a library opens, besides
/// the ones the library itself waits for: the settings (config.json), the
/// substitutions, the reading statistics, and each feed's record. Never a
/// book, and never an episode.
enum LibraryLaunchFile: Hashable, Sendable {
    /// config.json, the settings.
    case settings
    /// substitutions.json, the user's own rules.
    case substitutions
    /// reading_stats.json, the listening statistics.
    case readingStatistics
    /// A feed's record, in the Feeds folder.
    case feedRecord(UUID)
}

/// What each service does once its file has been fetched. Each service
/// reads the file again with its own rules, which never write over a file
/// that is still in the cloud, and merge or take up one that has arrived;
/// the app's hooks call them, and tests pass recorders.
struct LibraryLaunchFileTakeUp {
    /// config.json is on this Mac now.
    var settings: @MainActor () -> Void
    /// substitutions.json is on this Mac now.
    var substitutions: @MainActor () -> Void
    /// reading_stats.json is on this Mac now.
    var readingStatistics: @MainActor () -> Void
    /// A feed's record is on this Mac now.
    var feedRecords: @MainActor () -> Void

    /// The app's services.
    @MainActor static var app: LibraryLaunchFileTakeUp { LibraryLaunchFileTakeUp(
        settings: { ConfigService.shared.fileMayHaveArrived() },
        substitutions: {
            TextSubstitutionService.shared.readFileWaitingInTheCloud()
            TextSubstitutionService.shared.readFileThatArrived()
        },
        readingStatistics: { ReadingStatsService.shared.fileMayHaveArrived() },
        feedRecords: { Task { await FeedCenter.shared.store.loadRecordsInCloud() } }
    ) }

    /// Tells the service that reads `file` that it is on this Mac.
    @MainActor
    func fileArrived(_ file: LibraryLaunchFile) {
        switch file {
        case .settings: settings()
        case .substitutions: substitutions()
        case .readingStatistics: readingStatistics()
        case .feedRecord: feedRecords()
        }
    }
}

extension LibraryViewModel {
    /// Fetches the small launch files that are only in the cloud, when the
    /// library is in a cloud location, and tells each service when its file
    /// is on this Mac. Reads each file on a queue of its own, off the main
    /// thread and off Swift's cooperative threads, and never holds the
    /// library back: it runs after the library has opened, a file that does
    /// not arrive is simply taken up by the services' own re-reads (as the
    /// app becomes active, and before a save), and a read still out is not
    /// started again.
    ///
    /// - A file still in the cloud is never written over: every service
    ///   leaves it alone and reports changes made meanwhile unsaved, or
    ///   keeps them in memory, until it has read the file
    ///   (`MultiMacCrashSafetyTests`).
    /// - Settings: the preferences stand until the file arrives; the next
    ///   save, or this hook, merges the file's settings with any changed
    ///   here meanwhile, without a restart.
    func fetchLaunchFilesInBackground() {
        guard let fetch = dataDirectoryEnvironment.libraryFetch else { return }
        let root = TextMouthPaths.root
        let itemStatus = CloudServices.itemStatus
        guard itemStatus.location(of: root).provider != nil else { return }
        let known: [(LibraryLaunchFile, URL)] = [
            (.settings, TextMouthPaths.configFile),
            (.substitutions, TextMouthPaths.substitutionsFile),
            (.readingStatistics, TextMouthPaths.readingStatsFile)
        ]
        let records = FeedPaths.recordsFolder(in: root)
        Task { [weak self] in
            let feeds = await OffMainWork.run { Self.feedRecordFiles(in: records) }
            for (file, url) in known + feeds {
                self?.fetchLaunchFile(file, at: url, root: root, itemStatus: itemStatus, fetch: fetch)
            }
        }
    }

    /// The record files in the Feeds folder at `folder`, listed with
    /// downloads refused. Blocks, so call it off the main thread.
    private nonisolated static func feedRecordFiles(in folder: URL) -> [(LibraryLaunchFile, URL)] {
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        return names.sortedStably().compactMap { name in
            FeedPaths.feedID(ofRecordNamed: name).map { (.feedRecord($0), FeedPaths.recordFile(of: $0, in: folder)) }
        }
    }

    /// Fetches `url` if it is only in the cloud and no read of it is out,
    /// and tells the service that reads it once it is on this Mac.
    private func fetchLaunchFile(
        _ file: LibraryLaunchFile,
        at url: URL,
        root: URL,
        itemStatus: any CloudItemStatusProviding,
        fetch: @escaping LibraryFileFetch
    ) {
        guard !isBeingRead(url) else { return }
        libraryFilesBeingRead.insert(url.standardizedFileURL.path)
        let slots = libraryFetchReadSlots
        Task { [weak self] in
            // Sharing the library fetch's cap on reads in flight.
            await slots.acquire()
            let read: LaunchFileRead = await OffMainWork.run {
                // Metadata only, with downloads refused; a file on this Mac
                // needs nothing.
                guard DatalessFiles.withoutDownloading({ DataDirectoryCheck.isOnlyInCloud(url, itemStatus: itemStatus) }) else {
                    return .notNeeded
                }
                return Self.failure(reading: url, in: root, with: fetch).map { .failed($0) } ?? .fetched
            }
            slots.release()
            self?.launchFileReturned(file, at: url, root: root, read: read)
        }
    }

    /// What came of the read of a launch file.
    private enum LaunchFileRead: Sendable {
        /// The file was on this Mac already.
        case notNeeded
        /// The file was only in the cloud and its read succeeded.
        case fetched
        /// The file was only in the cloud and its read failed, as this says.
        case failed(String)
    }

    /// A launch file's read returned: a file fetched is announced to the
    /// service that reads it, and a failure is logged.
    private func launchFileReturned(_ file: LibraryLaunchFile, at url: URL, root: URL, read: LaunchFileRead) {
        libraryFilesBeingRead.remove(url.standardizedFileURL.path)
        guard !librarySwitchPending else { return }
        let name = DataDirectoryPaths.relativeName(of: url, in: root)
        switch read {
        case .notNeeded:
            return
        case .failed(let problem):
            DiagnosticLog.event(.storage, "LAUNCH_FILES: could not get \(name): \(problem)")
        case .fetched:
            DiagnosticLog.event(.storage, "LAUNCH_FILES: got \(name) from the cloud")
            launchFileTakeUp.fileArrived(file)
        }
    }
}
