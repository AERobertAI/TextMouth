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
    /// A fresh bookmark for a stale one, or nil when it is current (`SyncFolderAccessFactory.renewedBookmark`).
    var renewedBookmark: @Sendable (Data) -> Data? = { _ in nil }

    /// A renewal that asks `SyncFolderAccessFactory` each time it is called, so an override the iPhone sets
    /// after the center was built is used.
    static let renewalThroughFactory: @Sendable (Data) -> Data? = { SyncFolderAccessFactory.renewedBookmark($0) }

    /// The name this device gives itself in the store: its host name without ".local", or "Mac" or "iPhone".
    @MainActor static func deviceName(isPhone: Bool) -> String {
        let name = LibrarySessionLease.systemComputerName()
        return name.isEmpty ? (isPhone ? "iPhone" : "Mac") : name // l10n: no (a device's name in the store, as the system gives it)
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
            },
            renewedBookmark: Self.renewalThroughFactory
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
    /// The engine, opened off the main actor: `engineTask` makes it, `readyEngine()` waits for it.
    private var engine: SyncEngine?
    private var engineTask: Task<SyncEngine?, Never>?
    private var access: (any SyncFolderAccess)?
    /// The bookmark of the sync folder in use, kept in `SyncPreferences`.
    private var bookmark: Data?
    private var local: SyncLocalFiles?
    private var scheduler = SyncScheduler()
    private var recorder: SyncRecorder?
    /// The run going now, and the moments that came during it, folded into one.
    private var isRunning = false
    private var pendingReason: SyncReason?
    private var runTask: Task<Void, Never>?
    /// The launch's check of R6 and of this store's files, which happens off the main actor.
    private var installTask: Task<Void, Never>?
    /// Callers of `waitUntilIdle` asleep until a run ends.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var wakeTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    /// Which backup task is current, so a stale one that ends late never clears a newer task.
    private var backupGeneration = 0
    /// True from launch until the first apply has finished, which settles the engine's launch hold: a book
    /// missing at launch (an offline launch, a change made while the launch sync reads) is never reported
    /// removed before then (R7). The apply runs even when nothing changed while it is true.
    private var firstApplyPending = true
    /// The device name of each applied key's winning writer, for the host to say.
    private var writers: [SyncKey: String] = [:]
    /// The names devices call themselves, by device ID, from what was read.
    private var deviceNames: [String: String] = [:]
    /// The confirmation asked of the engine when Sync Now was pressed with removals held.
    private var confirmation: Task<Void, Never>?
    /// Whether the host left keys alone at the last apply (a row it didn't touch, an open book's removal), so the
    /// next sync applies again even when nothing new arrives.
    private var applyAgain = false
    /// Whether a record was asked for while a merge was applied, and so must run after it.
    private var recordWantedAfterApply = false
    private var observingNetwork = false
    private var lastPath: NetworkPathReport?
    /// Books whose copy is made and whose upload is awaited, with what they hold.
    private var awaitingUpload: [UUID: AwaitingBook] = [:]
    /// Books refused by the backup (a symbolic link, an error), not tried again this launch.
    private var refusedBackups: Set<UUID> = []
    /// Books the backup has scanned and not finished with: from the scan to the book's copy being recorded (or
    /// the book refused). A book here has no copy in the registers yet, so its files must stay (FR46).
    private var backupQueued: Set<UUID> = []

    /// A book copied into the store whose upload is awaited: what the backup made, and what is
    /// needed to finish it without the library.
    private struct AwaitingBook: Sendable {
        var result: StoreBackupResult
        var bytes: Int64
        var package: URL
        var content: SyncContent
    }

    /// A book chosen for the backup, with what is needed to back it up and finish it off the main actor.
    private struct BackupCandidate: Sendable {
        var bookID: UUID
        var package: URL
        /// The package's size in bytes, scanned once for the run.
        var bytes: Int64
        /// The book's content for a manifest name.
        var content: @Sendable (String) -> SyncContent
    }

    /// A center in `environment`; nil means the live one.
    init(environment: SyncCenterEnvironment? = nil) {
        suppliedEnvironment = environment
    }

    // MARK: Installing

    /// Hands the sync its library and data directory. A device that joined a folder before
    /// picks it up again here and syncs at launch; one that has not does nothing (R1).
    ///
    /// It may be called again, as after Move Library Here: R6 is checked again, and sync is on only where
    /// this data directory's `Sync/` holds this store's files, so a library opened later, which has none,
    /// never joins the store another library did.
    func install(host: any SyncLibraryHost, dataDirectory: URL) {
        self.host = host
        // A second install starts over for the library now in hand; the preferences stay as they are.
        if status.isOn { deactivate() }
        self.dataDirectory = dataDirectory
        let preferences = environment.preferences
        installTask?.cancel()
        guard let bookmark = SyncPreferences.bookmark.read(from: preferences),
              let storeID = SyncPreferences.storeID.read(from: preferences) else { return }
        let files = SyncLocalFiles(syncFolder: dataDirectory.appendingPathComponent(TextMouthPaths.syncFolderName, isDirectory: true), storeID: storeID)
        // R6 and this store's files are looked at off the main actor (R2); sync is on once they are found.
        installTask = Task { [weak self] in
            guard let self, await self.libraryIsLocal(dataDirectory) else { return }
            let hasStoreFiles = await Task.detached { FileManager.default.fileExists(atPath: files.deviceURL.path) }.value
            guard hasStoreFiles, !Task.isCancelled, self.dataDirectory == dataDirectory else { return }
            guard self.activate(bookmark: bookmark, storeID: storeID) else { return }
            self.moment(.launch)
        }
    }

    /// Stops what runs for this library, keeping the preferences: the library is changing, not sync.
    private func deactivate() {
        wakeTask?.cancel()
        backupTask?.cancel()
        engineTask?.cancel()
        wakeTask = nil
        backupTask = nil
        engineTask = nil
        recorder?.cancel()
        recorder = nil
        engine = nil
        access = nil
        local = nil
        storeID = nil
        bookmark = nil
        awaitingUpload = [:]
        scheduler.turnOff()
        SyncActivity.set(false)
        status = SyncStatus()
        keptBookIDs = []
    }

    /// Starts the engine (off the main actor) and the timers for the store `storeID` in the folder
    /// `bookmark` leads to.
    @discardableResult
    private func activate(bookmark: Data, storeID: UUID) -> Bool {
        guard let dataDirectory else { return false }
        let environment = environment
        let installID = SyncPreferences.installIDCreatingIfNeeded(in: environment.preferences)
        let files = SyncLocalFiles(syncFolder: dataDirectory.appendingPathComponent(TextMouthPaths.syncFolderName, isDirectory: true), storeID: storeID)
        let identity = SyncDeviceIdentity(name: environment.deviceName, platform: environment.platform, appVersion: environment.appVersion, installID: installID)
        let now = environment.now
        // The engine reads the device's files, megabytes of JSON for a large library: not on the main actor (R2).
        engineTask = Task { try? await SyncEngine.open(local: files, identity: identity, now: now) }
        engine = nil
        local = files
        access = environment.makeAccess(bookmark)
        self.bookmark = bookmark
        self.storeID = storeID
        scheduler.turnOn(at: environment.now())
        let recorder = SyncRecorder { [weak self] in await self?.recordNow() }
        recorder.isOn = true
        self.recorder = recorder
        status.isOn = true
        SyncActivity.set(true)
        status.lastSynced = nil
        firstApplyPending = true
        observeNetwork()
        rearm()
        return true
    }

    /// The engine, once it has opened; nil when it couldn't, or sync is off.
    private func readyEngine() async -> SyncEngine? {
        if let engine { return engine }
        guard let task = engineTask else { return nil }
        let opened = await task.value
        // Sync may have stopped, or another folder been joined, while it opened.
        if engineTask == task { engine = opened }
        return engine
    }

    // MARK: Setting up, joining, stopping

    /// The folder a Debug build's interface test names in `TEXTMOUTH_SYNC_FOLDER` as one it may sync into (a
    /// sandbox folder, which R6 would refuse), as `TEXTMOUTH_EXPORT_TO` is for export. A Release build never
    /// reads it: nothing here exists there.
    nonisolated static func seamFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        guard let path = environment["TEXTMOUTH_SYNC_FOLDER"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        #else
        return nil
        #endif
    }

    /// Whether `url` is, or is inside, the folder the test seam names.
    nonisolated static func isSeamFolder(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let seam = seamFolder(environment: environment) else { return false }
        let path = url.standardizedFileURL.path
        return path == seam.path || path.hasPrefix(seam.path + "/")
    }

    /// Refuses what R6 refuses: a library kept in a cloud location or on another volume.
    private func requireLocalLibrary() async throws {
        guard let dataDirectory, await libraryIsLocal(dataDirectory) else { throw SyncProblem.libraryNotLocal }
    }

    /// Whether `dataDirectory` is a place a library may sync from (R6), looked at off the main actor.
    private func libraryIsLocal(_ dataDirectory: URL) async -> Bool {
        // A Debug build's interface test that names a sync folder has chosen to sync in a sandbox: the library is its own.
        if Self.seamFolder() != nil { return true }
        // On the iPhone the app's own container is local: `location(of:)` knows (it never says another volume there).
        let locate = environment.locate
        return await Task.detached { locate(dataDirectory) == .local }.value
    }

    /// Refuses a folder that isn't in iCloud Drive.
    private func requireICloudDrive(_ folder: URL) async throws {
        // A folder in a trash (deleted in Finder or Files) is not a place to sync into.
        let locate = environment.locate
        let inDrive = await Task.detached { Self.isSeamFolder(folder) || locate(folder) == .cloud(.iCloudDrive) }.value
        guard !SyncFolderIO.isDeleted(folder), inDrive else { throw SyncProblem.notInICloudDrive }
    }

    /// Makes TextMouth Sync and its store.json in `parent`, then joins it.
    func setUp(in parent: URL) async throws {
        try await requireLocalLibrary()
        try await requireICloudDrive(parent)
        let creator = environment.deviceName
        let version = environment.appVersion
        let created = environment.now()
        // The folder is made off the main actor.
        let made = try await Task.detached { try SyncFolder.create(in: parent, creator: creator, version: version, now: created) }.value
        try await join(made.folder)
    }

    /// Uses the TextMouth Sync folder another device made, waiting 60 seconds for its store.json and never making one.
    func join(_ folder: URL) async throws {
        try await requireLocalLibrary()
        try await requireICloudDrive(folder)
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
        guard await readyEngine() != nil else {
            stop()
            throw SyncProblem.folderMissing
        }
        requestRun(.launch)
    }

    /// Forgets the folder; deletes nothing, on this device or in the cloud.
    func stop() {
        installTask?.cancel()
        wakeTask?.cancel()
        backupTask?.cancel()
        engineTask?.cancel()
        wakeTask = nil
        backupTask = nil
        engineTask = nil
        recorder?.cancel()
        recorder = nil
        engine = nil
        access = nil
        local = nil
        storeID = nil
        bookmark = nil
        awaitingUpload = [:]
        scheduler.turnOff()
        SyncPreferences.bookmark.write(nil, to: environment.preferences)
        SyncPreferences.storeID.write(nil, to: environment.preferences)
        SyncActivity.set(false)
        status = SyncStatus()
        keptBookIDs = []
    }

    // MARK: Moments

    /// Sync Now: announces "Syncing." and, when the run ends, its outcome. A run already going
    /// makes one more after it, and this says nothing new.
    func syncNow() {
        guard status.isOn else { return }
        environment.announce(SyncWording.announceSyncing)
        // The removals held now are the ones the person is answering: the confirmation is asked of the engine at once,
        // ahead of any record made after the press, and the run waits for it.
        if status.heldRemovals > 0 || status.heldFeedRemovals > 0 {
            confirmation = Task { [weak self] in
                guard let engine = await self?.readyEngine() else { return }
                await engine.confirmHeldRemovals()
            }
        }
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

    /// The name of the device that wrote the winning value of `key` in the last merge, for a sentence such as
    /// "Moved to the place saved on iPhone"; nil when it isn't known.
    func deviceName(forKey key: SyncKey) -> String? {
        writers[key]
    }

    /// Asks for the merge to be applied again at the next sync, even when nothing new arrives: for a host
    /// that deferred a key and now can apply it.
    func applyAtNextSync() {
        applyAgain = true
    }

    /// How many of the library's books have files only in the sync folder now (FR46), which Stop Syncing's question
    /// counts: each package whose pointer says a file is away, looked at off the main actor without downloading
    /// anything. Counted from the packages, never from the rows' recorded states, which a launch (an offline one above
    /// all) has not filled yet, and which keep books removed since. 0 while sync is off.
    func countBooksOnlyInTheSyncFolder() async -> Int {
        guard status.isOn, let host else { return 0 }
        let packages = host.library.libraryBooks.filter { !$0.tmbDirectoryName.isEmpty }.map(\.tmbDirectory)
        return await OffMainWork.run { StoreFetch.countMissingFiles(in: packages) }
    }

    /// Says how many books this device's choice of books left undone at the last sweep (FR45): books kept on
    /// the device for want of a proven copy, and books not downloaded for want of room. Nothing changes when
    /// the counts do not.
    func noteSpace(removalsWaiting: Int? = nil, booksShortOfRoom: Int? = nil) {
        if let removalsWaiting, status.removalsWaiting != removalsWaiting { status.removalsWaiting = removalsWaiting }
        if let booksShortOfRoom, status.booksShortOfRoom != booksShortOfRoom { status.booksShortOfRoom = booksShortOfRoom }
    }

    /// Stamps Keep on All Devices on or off for `bookIDs`, as a person chose.
    func setKeep(_ keep: Bool, for bookIDs: [UUID]) {
        guard status.isOn, !bookIDs.isEmpty else { return }
        Task {
            guard let engine = await readyEngine() else { return }
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
        SyncActivity.setPathIsCostly(report.isExpensive || report.isConstrained)
        scheduler.notePath(satisfied: report.isSatisfied, at: environment.now())
        rearm()
    }

    // MARK: Running

    /// Whether `reason` reads other devices' files; the iPhone's background and the Mac's quit only send.
    private static func reads(_ reason: SyncReason) -> Bool {
        reason != .background && reason != .quit
    }

    /// Folds a moment that came during a run into the one waiting: Sync Now wins, so its outcome is
    /// announced, and a run that reads beats one that only sends.
    static func folded(_ waiting: SyncReason?, _ incoming: SyncReason) -> SyncReason {
        guard let waiting else { return incoming }
        if waiting == .syncNow || incoming == .syncNow { return .syncNow }
        if reads(incoming) { return incoming }
        return reads(waiting) ? waiting : incoming
    }

    /// Runs `reason` now, or after the run going now: one run at a time.
    private func requestRun(_ reason: SyncReason) {
        if isRunning {
            pendingReason = Self.folded(pendingReason, reason)
            return
        }
        runTask = Task { await run(reason) }
    }

    /// Waits until no run is going or waiting, including the one a moment made during another. A test
    /// uses it instead of guessing a time.
    func waitUntilIdle() async {
        // A launch's look at the library and its files comes first: sync is on only after it.
        if let install = installTask {
            await install.value
            if installTask == install { installTask = nil }
        }
        while true {
            if let task = runTask {
                await task.value
                if runTask == task { runTask = nil }
            } else if isRunning {
                // A run is going and is not the one in `runTask`: sleep until it ends, never spin.
                await withCheckedContinuation { idleWaiters.append($0) }
            } else {
                return
            }
        }
    }

    /// Wakes whoever sleeps in `waitUntilIdle` for a run to end.
    private func resumeIdleWaiters() {
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Keeps the renewed bookmark when the system found the folder's bookmark stale (the folder was moved
    /// or renamed): the preferences and the access use it from now on. It is checked again against R6: a
    /// renewal that now leads outside iCloud Drive (the Trash, a local copy left at sign-out) is not kept,
    /// and the folder is reported missing.
    @discardableResult
    private func renewBookmarkIfStale() async -> Bool {
        guard let current = bookmark else { return true }
        // Resolving a bookmark can wait on the file system: it is done off the main actor.
        let renew = environment.renewedBookmark
        let locate = environment.locate
        let checked = await Task.detached { () -> (fresh: Data, refused: Bool)? in
            guard let fresh = renew(current) else { return nil }
            if let target = PlainSyncFolderAccess.resolve(fresh)?.url, SyncFolderIO.isDeleted(target) || (!SyncCenter.isSeamFolder(target) && locate(target) != .cloud(.iCloudDrive)) { return (fresh, true) }
            return (fresh, false)
        }.value
        guard let checked, bookmark == current else { return true }
        if checked.refused {
            // The folder now leads outside iCloud Drive or into a trash: this run is not made with the old access.
            status.problem = .folderMissing
            return false
        }
        SyncPreferences.bookmark.write(checked.fresh, to: environment.preferences)
        bookmark = checked.fresh
        access = environment.makeAccess(checked.fresh)
        return true
    }

    /// Records this device's changes now, unless a merge is being applied (those values are not this
    /// device's changes) or the library may not sync (index recovery has emptied it): then it waits.
    func recordNow() async {
        guard let host, status.isOn else { return }
        if recorder?.isApplying == true {
            recordWantedAfterApply = true
            return
        }
        guard host.maySyncNow else {
            // Not now: look again soon, so a library that is whole again is recorded.
            recorder?.noteChange()
            return
        }
        guard let engine = await readyEngine() else { return }
        // The engine may have taken a while to open: look again, so nothing recorded meanwhile is a merge's.
        if recorder?.isApplying == true {
            recordWantedAfterApply = true
            return
        }
        guard host.maySyncNow else {
            recorder?.noteChange()
            return
        }
        // The library is read after the flags are looked at, and nothing awaits in between.
        let library = host.library
        let feeds = host.syncFeeds
        // A record that throws leaves what was held as it was.
        if let result = try? await engine.record(library: library, feeds: feeds) {
            status.heldRemovals = result.heldRemovals
            status.heldFeedRemovals = result.heldFeedRemovals
        }
        status.pendingChanges = await engine.pendingChanges()
    }

    /// Runs `operation`, giving up after `seconds`: nil then.
    private func bounded<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        let sleep = environment.sleep
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await sleep(seconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One sync, with its Sync Now confirmation: a Sync Now chosen while removals are held back is the person's
    /// word that exactly those are meant, and it ends with the run, however the run ends.
    private func run(_ reason: SyncReason) async {
        if reason == .syncNow, let pending = confirmation {
            confirmation = nil
            await pending.value
        }
        await runOnce(reason)
        if let engine { await engine.clearConfirmation() }
    }

    /// One sync: record, open the folder, copy and read, merge, apply, and let the backup go on.
    private func runOnce(_ reason: SyncReason) async {
        // The engine may still be opening; nothing is checked before it has, so two requests meet below.
        guard let engine = await readyEngine() else { return }
        // Two requests made before either began meet here: the later waits for the earlier.
        if isRunning {
            pendingReason = Self.folded(pendingReason, reason)
            return
        }
        guard await renewBookmarkIfStale() else {
            if reason == .syncNow { environment.announce(SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)) }
            return
        }
        // Another request may have started while the bookmark was looked at.
        if isRunning {
            pendingReason = Self.folded(pendingReason, reason)
            return
        }
        guard let access, let storeID, let host else { return }
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
            if recordWantedAfterApply {
                recordWantedAfterApply = false
                recorder?.noteChange()
            }
            if let next = pendingReason {
                pendingReason = nil
                requestRun(next)
            }
            resumeIdleWaiters()
        }

        await recorder?.flush()
        // The iPhone going to the background and the Mac quitting only send, in a bounded time: no store.json
        // read, no apply, no backup (section 7).
        if !Self.reads(reason) {
            let seconds: TimeInterval = reason == .quit ? 2 : 20
            let sent = await bounded(seconds) {
                try await access.withFolder { root -> Int in
                    try await engine.exchange(in: SyncFolder(root: root, access: access), readsOthers: false).pendingChanges
                }
            }
            if let sent { status.pendingChanges = sent }
            return
        }

        var announcement: String
        do {
            let result = try await access.withFolder { root -> SyncExchangeResult in
                let folder = SyncFolder(root: root, access: access)
                _ = try await folder.readStore(expecting: storeID, within: .seconds(30))
                return try await engine.exchange(in: folder, readsOthers: true)
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

    /// The problem of an exchange, in the order the status line speaks them: an upload refused, no
    /// network, a later TextMouth's files, files not arrived.
    private func problem(of result: SyncExchangeResult) -> SyncProblem? {
        if let upload = result.uploadProblem { return upload }
        if result.read.sawOffline { return .offline }
        if result.read.laterVersionFrom != nil { return .laterVersion }
        return result.read.notArrived.first.map { SyncProblem.notDownloaded(device: $0) }
    }

    /// Applies a finished exchange to the library and the status; returns what Sync Now says.
    private func finish(_ result: SyncExchangeResult, reason: SyncReason, engine: SyncEngine, host: any SyncLibraryHost) async throws -> String {
        status.problem = problem(of: result)
        status.isOffline = status.problem == .offline
        status.pendingChanges = result.pendingChanges
        for (id, date) in result.read.lastHeard { status.lastHeard[result.read.names[id] ?? id] = date }

        // Apply what other devices wrote; until the first apply after launch even when nothing changed, as an older
        // TextMouth left rows unstamped and a book missing at launch is put back by it.
        if !result.changedKeys.isEmpty || firstApplyPending || applyAgain {
            // The flag is set before the library is read, so nothing recorded meanwhile takes applied values for
            // changes. One library is read: it is recorded exactly as it is, the merge is computed from it, and the
            // host gets it as the start, keeping any field changed since.
            // The library may have stopped being fit to sync during the exchange's awaits (index recovery began).
            guard host.maySyncNow else { return SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay) }
            recorder?.isApplying = true
            // Reset however this ends: a record that throws must not leave recording off for good.
            defer { recorder?.isApplying = false }
            let source = host.library
            // The feeds are read with the library, so the merge is made from the subscriptions recorded (FR56).
            let sourceFeeds = host.syncFeeds
            let recorded = try await engine.record(library: source, feeds: sourceFeeds)
            status.heldRemovals = recorded.heldRemovals
            status.heldFeedRemovals = recorded.heldFeedRemovals
            let application = await engine.application(for: source, feeds: sourceFeeds, voices: host.availableVoiceIDs)
            // Who wrote each winning value, by name, for the host's words.
            deviceNames.merge(result.read.names) { _, new in new }
            let writerIDs = await engine.writers(of: application.appliedKeys.union(result.changedKeys))
            writers = writerIDs.compactMapValues { deviceNames[$0] }
            let applied = await host.applySync(application, from: source)
            // Keys the host left alone are applied again at the next sync, and so are feeds' keys
            // that waited for the host's feeds to load (FR56).
            applyAgain = !application.appliedKeys.isSubset(of: applied) || application.feeds.waitsForFeeds
            try await engine.didApply(application, keys: applied)
            // The launch hold ends at the first apply, the feeds' at the first apply that had them.
            let feedsAwaitSettle = await engine.launchHoldAwaitsFeeds
            if firstApplyPending || (sourceFeeds != nil && feedsAwaitSettle) {
                try await engine.settleLaunch(library: host.library, feeds: host.syncFeeds)
                firstApplyPending = false
            }
        }
        keptBookIDs = await engine.keptBookIDs()
        // Nothing downloads on its own until the network has told what kind of path it is.
        host.syncDidApply(keptBookIDs: keptBookIDs, mayDownload: lastPath?.allowsBackgroundDownloads ?? false)
        if status.problem == nil { status.lastSynced = environment.now() }
        startBackup()

        let line = SyncStatusLine.text(for: status, isPhone: environment.isPhone, time: Self.timeOfDay)
        guard status.problem == nil, status.pendingChanges == 0 else { return line }
        if result.changedKeys.isEmpty { return SyncWording.announceNothingNew }
        // The device the changes came from is the one that wrote them, never an old identity of this one.
        let device = result.read.names.sorted { $0.key < $1.key }.first?.value ?? ""
        return SyncWording.announceSynced(changes: result.changedKeys.count, from: device)
    }

    /// A time of day, as the status line shows it.
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: The backup

    /// Lets the backup go on, one book at a time, if it isn't going already (section 8).
    private func startBackup() {
        guard backupTask == nil, status.isOn else { return }
        backupGeneration += 1
        let generation = backupGeneration
        backupTask = Task { [weak self] in
            await self?.backUpBooks()
            // A task that stopped late never clears a newer one.
            if self?.backupGeneration == generation { self?.backupTask = nil }
        }
    }

    /// Backs books up, text books first and smaller first, until all are backed up, the budget is
    /// spent, a problem stops it, or sync stops. Each book is done when its blobs and manifest
    /// have uploaded; its content is then stamped, and the local copies of its blobs evicted. All
    /// file work happens off the main actor.
    private func backUpBooks() async {
        guard let engine = await readyEngine(), let access, let storeID, let local, let dataDirectory else { return }
        let staging = local.stagingFolder
        let free = environment.freeSpace(dataDirectory)
        let budget = StoreBackupBudget.limit(freeSpace: free)
        // The books to back up are found in one scan, off the main actor: the library's rows are read here, and
        // the packages (their pointers, their existence, their sizes) are looked at there, once for the run.
        let scanned = await scanBooksForBackup(engine: engine)
        backupQueued = Set(scanned.map(\.bookID))
        do {
            try await access.withFolder { root in
                var queue = scanned
                let folder = SyncFolder(root: root, access: access)
                let backup = StoreBackup(folder: folder, storeID: storeID, staging: staging)
                // Books whose copies have uploaded since the last look are done first.
                for (bookID, waiting) in await self.awaitingUpload {
                    await self.finishUpload(of: bookID, waiting, backup: backup, engine: engine)
                }
                while !Task.isCancelled {
                    let held = await self.awaitingUpload.values.reduce(Int64(0)) { $0 + $1.bytes }
                    guard !queue.isEmpty else { break }
                    let next = queue.removeFirst()
                    // A book over what is left of the local budget waits, unless nothing is held: then it goes alone.
                    if held > 0, held + next.bytes > budget { break }
                    do {
                        let result = try backup.back(up: next.package, bookID: next.bookID, budget: held == 0 ? .max : budget - held)
                        let waiting = AwaitingBook(result: result, bytes: result.bytesCopied, package: next.package, content: next.content(result.manifestName))
                        await self.noteCopied(next.bookID, waiting)
                        await self.finishUpload(of: next.bookID, waiting, backup: backup, engine: engine)
                        await self.noteBackupDone(next.bookID)
                    } catch let problem as SyncProblem where problem == .outOfSpace {
                        // The drive refused for room: the status says so (the local budget is checked above, not thrown).
                        throw problem
                    } catch {
                        // Any other error refuses the book for this launch, so a run never stops at it again; it is logged.
                        DiagnosticLog.event(.storage, "SYNC_BACKUP: a book could not be backed up and is passed by for this launch (\(type(of: error)))") // l10n: no (debug log text)
                        await self.refuse(next.bookID)
                        await self.noteBackupDone(next.bookID)
                    }
                }
            }
        } catch let problem as SyncProblem {
            status.problem = status.problem ?? problem
        } catch {
            DiagnosticLog.event(.storage, "SYNC_BACKUP: the backup stopped (\(type(of: error)))") // l10n: no (debug log text)
        }
        // Whatever stopped it, no book is queued now: the next run scans again.
        backupQueued = []
    }

    /// The backup is done with the book `id` for this run: its copy is recorded or awaited (`awaitingUpload`), or it
    /// was refused.
    private func noteBackupDone(_ id: UUID) {
        backupQueued.remove(id)
    }

    /// Whether the backup's state forbids freeing the book `bookID` now (FR46). Its files must stay while the backup
    /// still has it queued or is awaiting its upload, and unless the registers already hold its content: a manifest
    /// made later from the files left would omit the one that was freed, and be taken for the book's copy everywhere.
    nonisolated static func backupForbidsFreeing(
        _ bookID: UUID, queued: Set<UUID>, awaiting: Set<UUID>, recordedContent: Set<UUID>
    ) -> Bool {
        queued.contains(bookID) || awaiting.contains(bookID) || !recordedContent.contains(bookID)
    }

    /// Remembers a copied book while its upload is awaited.
    private func noteCopied(_ id: UUID, _ waiting: AwaitingBook) {
        awaitingUpload[id] = waiting
    }

    /// Passes a book by for this launch.
    private func refuse(_ id: UUID) {
        refusedBackups.insert(id)
    }

    /// What the library says of a book the backup may take: no file work is needed to read it.
    private struct BackupRow: Sendable {
        var bookID: UUID
        var package: URL
        var isPackage: Bool
        var isText: Bool
        var format: BookFormat
        var dateAdded: Date
        var md5Hash: String
        var totalWordCount: Int?
        var audioDuration: TimeInterval?
    }

    /// The books to back up, text books first and smaller first: those whose content isn't in the registers,
    /// whole here, not awaited, not refused. The rows are read on the main actor; each package's pointer,
    /// existence, and size are looked at once, off it.
    private func scanBooksForBackup(engine: SyncEngine) async -> [BackupCandidate] {
        guard let host else { return [] }
        let contents = await engine.contents()
        let rows: [BackupRow] = host.library.libraryBooks.compactMap { book in
            guard contents[book.id] == nil, awaitingUpload[book.id] == nil, !refusedBackups.contains(book.id) else { return nil }
            let package = BookPackage(book)
            return BackupRow(
                bookID: book.id, package: package.url, isPackage: package.isPackage, isText: !book.format.isAudio, format: book.format,
                dateAdded: book.dateAdded, md5Hash: book.md5Hash, totalWordCount: book.totalWordCount, audioDuration: book.audioDuration
            )
        }
        let found = await Task.detached { () -> [(BackupRow, Int64)] in
            rows.compactMap { row in
                guard row.isPackage, FileManager.default.fileExists(atPath: row.package.path), !StoreFetch.isMissingFiles(row.package) else { return nil }
                return (row, StoreBackup.bytes(of: row.package))
            }
        }.value
        status.booksToBackUp = contents.count + found.count
        status.booksBackedUp = contents.count
        let ordered = StoreBackup.order(found.map { StoreBackupCandidate(bookID: $0.0.bookID, isText: $0.0.isText, bytes: $0.1) })
        let byID = Dictionary(found.map { ($0.0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { candidate in
            guard let (row, bytes) = byID[candidate.bookID] else { return nil }
            return BackupCandidate(bookID: row.bookID, package: row.package, bytes: bytes) { manifest in
                SyncContent(
                    manifest: manifest, format: row.format, dateAdded: row.dateAdded, md5Hash: row.md5Hash,
                    totalWordCount: row.totalWordCount, audioDuration: row.audioDuration
                )
            }
        }
    }

    /// Once the drive reports a book's blobs uploaded (or reports nothing), stamps its content, notes the
    /// pointer, and evicts the local copies of the blobs; a failure is said in the status. The drive's
    /// states, the pointer, and the evictions are read and done here, off the main actor.
    private nonisolated func finishUpload(of id: UUID, _ waiting: AwaitingBook, backup: StoreBackup, engine: SyncEngine) async {
        let state = backup.uploadState(of: waiting.result, bookID: id)
        switch state {
        case .uploading:
            return
        case .failed(let problem):
            await self.noteBackupProblem(problem)
            return
        case .uploaded, .notReported:
            break
        }
        try? backup.markUploaded(package: waiting.package, bookID: id, result: waiting.result)
        try? await engine.recordContent(waiting.content, for: id)
        // Only blobs the drive reports uploaded are evicted; where it reports nothing the copy stays.
        if state == .uploaded { backup.evictBlobs(of: waiting.result, bookID: id) }
        await self.bookBackedUp(id)
    }

    /// Says a backup problem in the status.
    private func noteBackupProblem(_ problem: SyncProblem) {
        status.problem = status.problem ?? problem
    }

    /// A book's backup is complete.
    private func bookBackedUp(_ id: UUID) {
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

    /// Removes `package`'s files from this device once the store holds them, proven (FR46), for `StoreBookStorage`.
    /// Throws a `SyncRemovalRefusal` when it cannot be proven, with the book as it was.
    nonisolated static func removeDownload(_ package: BookPackage, mayDownload: Bool) async throws {
        try await SyncCenter.shared.removeBookDownload(package, mayDownload: mayDownload)
    }

    /// Runs the removal in the sync folder, off the main actor: the files are hashed and read back there.
    private func removeBookDownload(_ package: BookPackage, mayDownload: Bool) async throws {
        guard let access, let storeID, let local else { throw SyncRemovalRefusal.folderUnreachable }
        // The library's last word, which the command or sweep set for this call (`FreeingCheck`).
        let lastLook = FreeingCheck.current
        // The backup's own state, on the main actor, before anything is read: a book it has not finished with stays.
        guard let engine = await readyEngine() else { throw SyncRemovalRefusal.folderUnreachable }
        let recorded = Set(await engine.contents().keys)
        if Self.backupForbidsFreeing(package.bookID, queued: backupQueued, awaiting: Set(awaitingUpload.keys), recordedContent: recorded) {
            throw SyncRemovalRefusal.notUploaded("backup")
        }
        do {
            _ = try await access.withFolder { root in
                var removal = StoreRemoval(folder: SyncFolder(root: root, access: access), storeID: storeID, staging: local.stagingFolder)
                removal.finalCheck = lastLook
                return try await removal.removeDownload(of: package.url, bookID: package.bookID, mayDownload: mayDownload)
            }
        } catch SyncProblem.folderMissing {
            throw SyncRemovalRefusal.folderUnreachable
        }
    }

    /// Fetches `package`'s missing files, telling `progress` after each.
    private func fetchBook(_ package: BookPackage, progress: @escaping @Sendable (BookDownloadProgress) -> Void) async throws {
        guard let access, let storeID, let local else { throw SyncProblem.folderMissing }
        let contentPath = try await access.withFolder { root -> String? in
            let fetch = StoreFetch(folder: SyncFolder(root: root, access: access), storeID: storeID, staging: local.stagingFolder)
            return try await fetch.fetch(package: package.url) { files, bytes, totalFiles, totalBytes in
                progress(BookDownloadProgress(completedFiles: files, totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes))
            }
        }
        host?.syncDidFetch(bookID: package.bookID, contentPath: contentPath)
    }
}
