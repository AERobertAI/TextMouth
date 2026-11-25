import Foundation

// MARK: - The App's One Sync (FR43)

/// What the center needs from the world, so a test supplies its own: where
/// preferences live, who this device is, how a bookmark becomes folder
/// access, where a folder lives, how the network is told, and how the
/// clock and the announcer work.
struct SyncCenterEnvironment {
    /// This device's preferences (`SyncPreferences`).
    var preferences: UserDefaults
    /// The device's name, platform, and the app's version; the install ID is added.
    var deviceName: String
    var platform: String
    var appVersion: String
    /// Whether this device is an iPhone: words say "this iPhone".
    var isPhone: Bool
    /// The folder access for a bookmark (`SyncFolderAccessFactory.make` by default).
    var makeAccess: @Sendable @MainActor (Data) -> any SyncFolderAccess
    /// Where a folder lives.
    var locate: @Sendable (URL) -> StorageLocation
    /// Makes a bookmark of the folder.
    var makeBookmark: @Sendable @MainActor (URL) -> Data?
    /// Whether the network is there, and how it reports.
    var reachability: NetworkReachability
    /// The time.
    var now: @Sendable () -> Date
    /// Waits this many seconds before the timers fire, so a test doesn't.
    var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Says words aloud (`VoiceOverAnnouncer.announce`).
    var announce: @Sendable @MainActor (String) -> Void
    /// Free bytes on the device's disk, for the backup's budget.
    var freeSpace: @Sendable (URL) -> Int64
    /// The pause between looks when Join waits for store.json to arrive; a test answers at once.
    var pauseWhileJoining: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The name this device gives itself in the store: its host name without ".local", or "Mac" or "iPhone".
    static func deviceName(isPhone: Bool) -> String {
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return host.isEmpty ? (isPhone ? "iPhone" : "Mac") : host
    }

    /// The app's own: the process's preferences, iCloud Drive's location, and the real clock and voice.
    @MainActor static func live() -> SyncCenterEnvironment {
        let provider = UbiquitousItemStatusProvider()
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        // Told from the platform's name, so no constant is folded into a warning.
        let phone = platform == "ios"
        return SyncCenterEnvironment(
            preferences: TextMouthRuntime.current.preferences,
            deviceName: Self.deviceName(isPhone: phone),
            platform: platform,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            isPhone: phone,
            makeAccess: { SyncFolderAccessFactory.make($0) },
            locate: { provider.location(of: $0) },
            makeBookmark: { SyncFolderAccessFactory.makeBookmark($0) },
            reachability: .system,
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            announce: { VoiceOverAnnouncer.announce($0) },
            freeSpace: { url in
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage ?? 0
            }
        )
    }
}

/// The app's one sync: the interfaces and life cycles call it. It owns the
/// engine and the scheduler, runs one sync at a time (moments during a run
/// make one run after it), records changes through the recorder, applies
/// merges through the library's host, and says its state in `status`.
///
/// Rule R1: until a folder is set up or joined it does nothing at all, no
/// task and no file, and `status.isOn` is false.
@MainActor final class SyncCenter: ObservableObject {
    /// The app's center.
    static let shared = SyncCenter()

    /// What the Sync section shows.
    @Published private(set) var status = SyncStatus()
    /// The books kept on all devices, from the registers (section 16).
    @Published private(set) var keptBookIDs: Set<UUID> = []
    /// The ID of the store this device syncs with, nil while sync is off: what a placeholder's
    /// pointer names (`StoreFetch.placeholderPointer`).
    private(set) var storeID: UUID?

    /// The world; the live one is made on first use, since it needs the process's runtime.
    private var suppliedEnvironment: SyncCenterEnvironment?
    private var environment: SyncCenterEnvironment {
        if let suppliedEnvironment { return suppliedEnvironment }
        let live = SyncCenterEnvironment.live()
        suppliedEnvironment = live
        return live
    }

    private weak var host: (any SyncLibraryHost)?
    private var dataDirectory: URL?
    private var engine: SyncEngine?
    private var access: (any SyncFolderAccess)?
    private var local: SyncLocalFiles?
    private var scheduler = SyncScheduler()
    private var recorder: SyncRecorder?
    /// The run going now, and the moment that came during it.
    private var isRunning = false
    private var pendingReason: SyncReason?
    private var wakeTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    private var didRecordSinceLaunch = false
    private var observingNetwork = false
    private var lastPath: NetworkPathReport?
    /// Books whose copy is made and whose upload is awaited, with what they hold.
    private var awaitingUpload: [UUID: (result: StoreBackupResult, bytes: Int64)] = [:]
    /// Books refused by the backup (a symbolic link, say), not tried again this launch.
    private var refusedBackups: Set<UUID> = []

    /// A center in `environment`; nil means the live one.
    init(environment: SyncCenterEnvironment? = nil) {
        suppliedEnvironment = environment
    }

    // MARK: Installing

    /// Hands the sync its library and data directory. A device that joined a folder before
    /// picks it up again here and syncs at launch; one that has not does nothing (R1).
    func install(host: any SyncLibraryHost, dataDirectory: URL) {
        self.host = host
        self.dataDirectory = dataDirectory
        let preferences = environment.preferences
        guard let bookmark = SyncPreferences.bookmark.read(from: preferences),
              let storeID = SyncPreferences.storeID.read(from: preferences) else { return }
        guard activate(bookmark: bookmark, storeID: storeID) else { return }
        moment(.launch)
    }

    /// Starts the engine and the timers for the store `storeID` in the folder `bookmark` leads to.
    @discardableResult
    private func activate(bookmark: Data, storeID: UUID) -> Bool {
        guard let dataDirectory else { return false }
        let environment = environment
        let installID = SyncPreferences.installIDCreatingIfNeeded(in: environment.preferences)
        let files = SyncLocalFiles(syncFolder: dataDirectory.appendingPathComponent(TextMouthPaths.syncFolderName, isDirectory: true), storeID: storeID)
        let identity = SyncDeviceIdentity(name: environment.deviceName, platform: environment.platform, appVersion: environment.appVersion, installID: installID)
        let now = environment.now
        guard let engine = try? SyncEngine(local: files, identity: identity, now: now) else { return false }
        self.engine = engine
        local = files
        access = environment.makeAccess(bookmark)
        self.storeID = storeID
        scheduler.turnOn(at: environment.now())
        let recorder = SyncRecorder { [weak self] in await self?.recordNow() }
        recorder.isOn = true
        self.recorder = recorder
        status.isOn = true
        status.lastSynced = nil
        didRecordSinceLaunch = false
        observeNetwork()
        rearm()
        return true
    }

    // MARK: Setting up, joining, stopping

    /// Refuses what R6 refuses: a library kept in a cloud location or on another volume.
    private func requireLocalLibrary() throws {
        guard let dataDirectory, environment.locate(dataDirectory) == .local else { throw SyncProblem.libraryNotLocal }
    }

    /// Refuses a folder that isn't in iCloud Drive.
    private func requireICloudDrive(_ folder: URL) throws {
        guard environment.locate(folder) == .cloud(.iCloudDrive) else { throw SyncProblem.notInICloudDrive }
    }

    /// Makes TextMouth Sync and its store.json in `parent`, then joins it.
    func setUp(in parent: URL) async throws {
        try requireLocalLibrary()
        try requireICloudDrive(parent)
        let made = try SyncFolder.create(in: parent, creator: environment.deviceName, version: environment.appVersion, now: environment.now())
        try await join(made.folder)
    }

    /// Uses the TextMouth Sync folder another device made, waiting 60 seconds for its store.json and never making one.
    func join(_ folder: URL) async throws {
        try requireLocalLibrary()
        try requireICloudDrive(folder)
        guard let bookmark = environment.makeBookmark(folder) else { throw SyncProblem.folderMissing }
        let newAccess = environment.makeAccess(bookmark)
        let pause = environment.pauseWhileJoining
        let store = try await newAccess.withFolder { root in
            try await SyncFolder(root: root, access: newAccess).waitForStore(sleep: pause)
        }
        stop()
        SyncPreferences.bookmark.write(bookmark, to: environment.preferences)
        SyncPreferences.storeID.write(store.storeID, to: environment.preferences)
        guard activate(bookmark: bookmark, storeID: store.storeID) else { throw SyncProblem.folderMissing }
        requestRun(.launch)
    }

    /// Forgets the folder; deletes nothing, on this device or in the cloud.
    func stop() {
        wakeTask?.cancel()
        backupTask?.cancel()
        wakeTask = nil
        backupTask = nil
        recorder?.cancel()
        recorder = nil
        engine = nil
        access = nil
        local = nil
        storeID = nil
        awaitingUpload = [:]
        scheduler.turnOff()
        SyncPreferences.bookmark.write(nil, to: environment.preferences)
        SyncPreferences.storeID.write(nil, to: environment.preferences)
        status = SyncStatus()
        keptBookIDs = []
    }

    // MARK: Moments

    /// Sync Now: announces "Syncing." and, when the run ends, its outcome. A run already going
    /// makes one more after it, and this says nothing new.
    func syncNow() {
        guard status.isOn else { return }
        environment.announce(SyncWording.announceSyncing)
        requestRun(.syncNow)
    }

    /// A moment to sync at (launch, activation, background, quit); the timed ones come from the scheduler.
    func moment(_ reason: SyncReason) {
        guard status.isOn else { return }
        requestRun(reason)
    }

    /// Called from `LibraryViewModel.library`'s `didSet`: the recorder runs two seconds later,
    /// and a run three minutes after the first change not yet sent.
    func libraryDidChange() {
        guard status.isOn else { return }
        recorder?.noteChange()
        scheduler.noteChange(at: environment.now())
        rearm()
    }

    /// Stamps Keep on All Devices on or off for `bookIDs`, as a person chose.
    func setKeep(_ keep: Bool, for bookIDs: [UUID]) {
        guard status.isOn, let engine, !bookIDs.isEmpty else { return }
        Task {
            try? await engine.recordKeep(keep, for: bookIDs)
            keptBookIDs = await engine.keptBookIDs()
            scheduler.noteChange(at: environment.now())
            rearm()
        }
    }

    // MARK: Timers

    /// Arms the timer for the next moment the scheduler will want.
    private func rearm() {
        wakeTask?.cancel()
        wakeTask = nil
        guard let wake = scheduler.nextWake(after: environment.now()) else { return }
        let delay = max(0, wake.timeIntervalSince(environment.now()))
        wakeTask = Task { [weak self] in
            guard let self else { return }
            try? await self.environment.sleep(delay)
            if Task.isCancelled { return }
            self.fire()
        }
    }

    /// The timer fired: run what is due, then arm again.
    private func fire() {
        if let reason = scheduler.nextDue(at: environment.now()) { requestRun(reason) }
        rearm()
    }

    /// Starts watching the network path once.
    private func observeNetwork() {
        guard !observingNetwork else { return }
        observingNetwork = true
        environment.reachability.observe { [weak self] report in
            Task { @MainActor in self?.networkReport(report) }
        }
    }

    /// The network path changed: the scheduler decides whether it is "back".
    private func networkReport(_ report: NetworkPathReport) {
        lastPath = report
        scheduler.notePath(satisfied: report.isSatisfied, at: environment.now())
        rearm()
    }

    // MARK: Running

    /// Runs `reason` now, or after the run going now: one run at a time.
    private func requestRun(_ reason: SyncReason) {
        if isRunning {
            pendingReason = reason
            return
        }
        Task { await run(reason) }
    }

    /// Records this device's changes now.
    private func recordNow() async {
        guard let engine, let host else { return }
        _ = try? await engine.record(library: host.library, atLaunch: !didRecordSinceLaunch)
        didRecordSinceLaunch = true
        status.pendingChanges = await engine.pendingChanges()
    }

    /// One sync: record, open the folder, copy and read, merge, apply, and let the backup go on.
    private func run(_ reason: SyncReason) async {
        // Two requests made before either began meet here: the later waits for the earlier.
        if isRunning {
            pendingReason = reason
            return
        }
        guard let engine, let access, let storeID, let host else { return }
        guard host.maySyncNow else {
            if reason == .syncNow { environment.announce(SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)) }
            return
        }
        isRunning = true
        status.isSyncing = true
        scheduler.runStarted(for: reason, at: environment.now())
        defer {
            isRunning = false
            status.isSyncing = false
            scheduler.runFinished(at: environment.now())
            rearm()
            if let next = pendingReason {
                pendingReason = nil
                requestRun(next)
            }
        }

        await recorder?.flush()
        var announcement: String
        do {
            let result = try await access.withFolder { root -> SyncExchangeResult in
                let folder = SyncFolder(root: root, access: access)
                _ = try await folder.readStore(expecting: storeID, within: .seconds(30))
                return try await engine.exchange(in: folder, readsOthers: reason != .background && reason != .quit)
            }
            announcement = try await finish(result, reason: reason, engine: engine, host: host)
        } catch let problem as SyncProblem {
            status.problem = problem
            status.isOffline = problem == .offline
            status.pendingChanges = await engine.pendingChanges()
            announcement = SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)
        } catch {
            status.problem = .folderMissing
            announcement = SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)
        }
        if reason == .syncNow { environment.announce(announcement) }
    }

    /// Applies a finished exchange to the library and the status; returns what Sync Now says.
    private func finish(_ result: SyncExchangeResult, reason: SyncReason, engine: SyncEngine, host: any SyncLibraryHost) async throws -> String {
        status.problem = result.uploadProblem ?? result.read.notArrived.first.map { SyncProblem.notDownloaded(device: $0) }
        status.isOffline = false
        status.pendingChanges = result.pendingChanges
        for (id, date) in result.read.lastHeard { status.lastHeard[result.read.names[id] ?? id] = date }

        // Apply what other devices wrote; at launch even when nothing changed, as an older TextMouth left rows unstamped.
        if !result.changedKeys.isEmpty || reason == .launch {
            let application = await engine.application(for: host.library, voices: nil)
            recorder?.isApplying = true
            let applied = await host.applySync(application)
            recorder?.isApplying = false
            try await engine.didApply(application, keys: applied, library: host.library)
        }
        keptBookIDs = await engine.keptBookIDs()
        host.syncDidApply(keptBookIDs: keptBookIDs, mayDownload: lastPath?.allowsBackgroundDownloads ?? true)
        if status.problem == nil { status.lastSynced = environment.now() }
        startBackup()

        let line = SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)
        guard status.problem == nil, status.pendingChanges == 0 else { return line }
        if result.changedKeys.isEmpty { return SyncWording.announceNothingNew }
        let device = result.read.names.values.sorted().first ?? ""
        return SyncWording.announceSynced(changes: result.changedKeys.count, from: device)
    }

    /// A time of day, as the status line shows it.
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: The backup

    /// Lets the backup go on, one book at a time, if it isn't going already (section 8).
    private func startBackup() {
        guard backupTask == nil, engine != nil else { return }
        backupTask = Task { [weak self] in
            await self?.backUpBooks()
            self?.backupTask = nil
        }
    }

    /// Backs books up, text books first and smaller first, until all are backed up, the budget is
    /// spent, a problem stops it, or sync stops. Each book is done when its blobs and manifest
    /// have uploaded; its content is then stamped, and the local copies of its blobs evicted.
    private func backUpBooks() async {
        guard let engine, let access, let storeID, let local, let dataDirectory else { return }
        let staging = local.stagingFolder
        let free = environment.freeSpace(dataDirectory)
        let budget = StoreBackupBudget.limit(freeSpace: free)
        do {
            try await access.withFolder { root in
                let folder = SyncFolder(root: root, access: access)
                let backup = StoreBackup(folder: folder, storeID: storeID, staging: staging)
                // Books whose copies have uploaded since the last look are done first.
                for (bookID, waiting) in await self.awaitingUpload {
                    await self.completeIfUploaded(bookID, waiting.result, backup: backup, engine: engine)
                }
                while !Task.isCancelled {
                    let held = await self.awaitingUpload.values.reduce(Int64(0)) { $0 + $1.bytes }
                    guard let next = await self.nextBookToBackUp(engine: engine), held < budget else { break }
                    do {
                        let result = try backup.back(up: next.package, bookID: next.book.id, budget: budget - held)
                        await self.noteCopied(next.book.id, result)
                        await self.completeIfUploaded(next.book.id, result, backup: backup, engine: engine)
                    } catch SyncProblem.outOfSpace {
                        throw SyncProblem.outOfSpace
                    } catch let problem as SyncProblem {
                        // A book that can't be backed up (a link, a damaged file) is passed by, not retried.
                        if case .damaged = problem { await self.refuse(next.book.id) } else { throw problem }
                    }
                }
            }
        } catch let problem as SyncProblem {
            status.problem = status.problem ?? problem
        } catch {}
    }

    /// Remembers a copied book while its upload is awaited.
    private func noteCopied(_ id: UUID, _ result: StoreBackupResult) {
        awaitingUpload[id] = (result, result.bytesCopied)
    }

    /// Passes a book by for this launch.
    private func refuse(_ id: UUID) {
        refusedBackups.insert(id)
    }

    /// The next book to back up: one whose content isn't in the registers, whole here, not awaited, not refused.
    private func nextBookToBackUp(engine: SyncEngine) async -> (book: Book, package: URL)? {
        guard let host else { return nil }
        let contents = await engine.contents()
        let candidates = host.library.libraryBooks.filter { book in
            let package = BookPackage(book)
            return contents[book.id] == nil && awaitingUpload[book.id] == nil && !refusedBackups.contains(book.id)
                && package.isPackage && !StoreFetch.isMissingFiles(package.url)
                && FileManager.default.fileExists(atPath: package.url.path)
        }
        status.booksToBackUp = contents.count + candidates.count
        status.booksBackedUp = contents.count
        let ordered = StoreBackup.order(candidates.map {
            StoreBackupCandidate(bookID: $0.id, isText: !$0.format.isAudio, bytes: StoreBackup.bytes(of: BookPackage($0).url))
        })
        guard let first = ordered.first, let book = candidates.first(where: { $0.id == first.bookID }) else { return nil }
        return (book, BookPackage(book).url)
    }

    /// Once the drive reports a book's blobs uploaded (or reports nothing), stamps its content, notes the
    /// pointer, and evicts the local copies of the blobs; a failure is said in the status.
    private func completeIfUploaded(_ id: UUID, _ result: StoreBackupResult, backup: StoreBackup, engine: SyncEngine) async {
        guard let host else { return }
        switch backup.uploadState(of: result, bookID: id) {
        case .uploading:
            return
        case .failed(let problem):
            status.problem = status.problem ?? problem
            return
        case .uploaded, .notReported:
            break
        }
        guard let book = host.library.libraryBooks.first(where: { $0.id == id }) else {
            awaitingUpload[id] = nil
            return
        }
        let uploaded = backup.uploadState(of: result, bookID: id) == .uploaded
        let content = SyncContent(
            manifest: result.manifestName, format: book.format, dateAdded: book.dateAdded, md5Hash: book.md5Hash,
            totalWordCount: book.totalWordCount, audioDuration: book.audioDuration
        )
        try? backup.markUploaded(package: BookPackage(book).url, bookID: id, result: result)
        try? await engine.recordContent(content, for: id)
        // Only blobs the drive reports uploaded are evicted; where it reports nothing the copy stays.
        if uploaded { backup.evictBlobs(of: result, bookID: id) }
        awaitingUpload[id] = nil
        status.booksBackedUp = (status.booksBackedUp ?? 0) + 1
    }

    // MARK: Fetching a book

    /// A stream that fetches the placeholder `package` from the store, for `StoreBookStorage`.
    nonisolated static func fetch(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await SyncCenter.shared.fetchBook(package) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches `package`'s missing files, telling `progress` after each.
    private func fetchBook(_ package: BookPackage, progress: @escaping @Sendable (BookDownloadProgress) -> Void) async throws {
        guard let access, let storeID, let local else { throw SyncProblem.folderMissing }
        let total = StoreFetch.pointer(in: package.url)?.files ?? []
        let totalBytes = total.reduce(Int64(0)) { $0 + $1.size }
        let contentPath = try await access.withFolder { root -> String? in
            let fetch = StoreFetch(folder: SyncFolder(root: root, access: access), storeID: storeID, staging: local.stagingFolder)
            return try await fetch.fetch(package: package.url) { files, bytes in
                progress(BookDownloadProgress(completedFiles: files, totalFiles: total.count, completedBytes: bytes, totalBytes: totalBytes))
            }
        }
        host?.syncDidFetch(bookID: package.bookID, contentPath: contentPath)
    }
}
