import Foundation

// MARK: - The Engine (FR43, sections 4 to 6)

/// What one exchange with the folder found.
struct SyncExchangeResult: Equatable, Sendable {
    /// The keys whose winning entry changed by what other devices wrote.
    var changedKeys: Set<SyncKey> = []
    /// What was read from other devices (cursors, times, devices not arrived).
    var read = SyncReadResult()
    /// Changes still waiting for iCloud Drive to upload.
    var pendingChanges = 0
    /// Why an upload failed, as the drive said (a full drive).
    var uploadProblem: SyncProblem?
    /// How many outbox files were copied into the folder.
    var filesCopied = 0
}

/// What names this device in the store.
struct SyncDeviceIdentity: Equatable, Sendable {
    /// The name other devices show ("Mac", "iPhone").
    var name: String
    /// "macos" or "ios".
    var platform: String
    /// The app's version.
    var appVersion: String
    /// This install's ID (`SyncPreferences.installID`).
    var installID: String
}

/// A value to stamp and record.
private struct PendingChange {
    var key: SyncKey
    var value: JSONValue
    var byHand: Bool
}

/// The sync engine for one store on one device: the device's own files, the
/// outbox, the registers, and the exchange with the folder. An actor, so the
/// library never waits on it (R2); the center, on the main actor, calls it
/// and applies what it returns.
///
/// It holds no library: callers pass projections and libraries in, and take
/// applications and counts out, so every step is a pure merge or a file write.
actor SyncEngine {
    /// The device's own files.
    private let local: SyncLocalFiles
    /// This device in the store.
    private let identity: SyncDeviceIdentity
    /// Reads the time, so a test sets it.
    private let now: @Sendable () -> Date
    private var outbox: SyncOutbox
    private var clock: SyncClock
    private var registers: SyncRegisters
    private var baseline: SyncProjection
    private var cursors: SyncCursors
    /// Whether this device must publish a snapshot at its next exchange: it is new, or restored.
    private var snapshotDue: Bool
    /// How many change files this device wrote since its last snapshot.
    private var filesSinceSnapshot = 0
    /// How many change files make a snapshot due, so old files can leave the outbox.
    private let snapshotEvery = 100

    /// This device's ID.
    nonisolated let deviceID: String

    /// Opens the device's files, making them when the device is new or its
    /// library was restored onto another install (a new ID, then a
    /// snapshot), and puts back into the registers any outbox file past
    /// `throughSeq` that a crash kept out (section 4, step 6).
    init(local: SyncLocalFiles, identity: SyncDeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.local = local
        self.identity = identity
        self.now = now
        try local.prepare()

        var device = local.loadDevice()
        var fresh = false
        if device == nil || device?.installID != identity.installID {
            // A new library, or one restored onto another install: a new ID, and the old outbox is not ours.
            device = SyncDeviceState(deviceID: UUID().uuidString.lowercased(), incarnation: UUID(), installID: identity.installID, lastSeq: 0)
            try local.saveDevice(device!)
            try local.write(SyncOutboxIndex(), to: local.outboxIndexURL)
            try local.saveRegisters(SyncRegisters())
            try local.saveCursors(SyncCursors())
            try local.saveBaseline(SyncBaselineFile())
            fresh = true
        }
        let state = device!
        deviceID = state.deviceID
        var outbox = SyncOutbox(local: local, device: state)
        try outbox.adoptUnindexedFiles()
        var registers = local.loadRegisters()
        // Files past `throughSeq` never reached the registers.
        let missed = outbox.entries(after: registers.throughSeq)
        if !missed.isEmpty {
            registers.merge(missed)
            registers.throughSeq = outbox.device.lastSeq
        }
        self.outbox = outbox
        self.registers = registers
        clock = local.loadClock(device: state.deviceID)
        baseline = local.loadBaseline().projection
        cursors = local.loadCursors()
        snapshotDue = fresh
    }

    // MARK: Recording

    /// Stamps `changes`, writes them as the next outbox file, and puts them in the registers. The
    /// clock, registers, and (when asked) baseline are saved after the file, so a crash in between
    /// is found at the next start.
    @discardableResult
    private func append(_ pairs: [PendingChange], updatingBaseline: Bool) throws -> Int {
        guard !pairs.isEmpty else { return 0 }
        let stamped = pairs.map { SyncEntry(key: $0.key, value: $0.value, stamp: clock.next(at: now()), byHand: $0.byHand) }
        let seq = try outbox.append(stamped)
        try local.saveClock(clock)
        registers.merge(stamped)
        registers.throughSeq = seq
        try local.saveRegisters(registers)
        filesSinceSnapshot += 1
        if updatingBaseline {
            for pair in pairs { baseline.values[pair.key] = pair.value }
            try local.saveBaseline(SyncBaselineFile(baseline))
        }
        return pairs.count
    }

    /// Compares `library`'s projection with the baseline and records each changed key
    /// (section 6, the recorder); returns how many. The projection is made here, off the
    /// main thread. `atLaunch` is the first run after launch, which stamps what an older
    /// TextMouth left.
    @discardableResult
    func record(library: Library, atLaunch: Bool) throws -> Int {
        let projection = SyncProjection.of(library, contents: contents())
        let changes = SyncMerge.changes(from: baseline, to: projection, atLaunch: atLaunch)
        let ordered = changes.sorted { "\($0.key)" < "\($1.key)" }
        return try append(ordered.map { PendingChange(key: $0.key, value: $0.value, byHand: projection.byHand.contains($0.key)) }, updatingBaseline: true)
    }

    /// Records Keep on All Devices on or off, as a person chose (section 16): never projected from the library.
    func recordKeep(_ keep: Bool, for bookIDs: [UUID]) throws {
        try append(bookIDs.map { PendingChange(key: .book($0, .keep), value: .bool(keep), byHand: true) }, updatingBaseline: false)
    }

    /// Records a book's content, once the backup has it uploaded (section 8).
    func recordContent(_ content: SyncContent, for bookID: UUID) throws {
        try append([PendingChange(key: .book(bookID, .content), value: try SyncFileCoding.jsonValue(of: content), byHand: false)], updatingBaseline: false)
    }

    /// The contents of every book in the registers, for `SyncProjection.of`.
    func contents() -> [UUID: SyncContent] {
        var found: [UUID: SyncContent] = [:]
        for (key, entry) in registers.entries {
            if case .book(let id, .content) = key, let content = SyncFileCoding.value(entry.value, as: SyncContent.self) {
                found[id] = content
            }
        }
        return found
    }

    /// The books kept on all devices, from the registers (section 16).
    func keptBookIDs() -> Set<UUID> {
        var kept: Set<UUID> = []
        for (key, entry) in registers.entries {
            if case .book(let id, .keep) = key, entry.value == .bool(true) { kept.insert(id) }
        }
        return kept
    }

    // MARK: Exchanging

    /// Publishes this device, copies the outbox in, reads the upload states, reads other
    /// devices' new files, and merges them into the registers. Reads are bounded (R2). A
    /// folder problem is thrown after what could be done locally is saved.
    func exchange(in folder: SyncFolder, readsOthers: Bool = true, limits: SyncReadLimits = SyncReadLimits()) async throws -> SyncExchangeResult {
        var result = SyncExchangeResult()
        try publishDevice(in: folder)
        if snapshotDue || filesSinceSnapshot >= snapshotEvery {
            try outbox.append(registers.entries.values.sorted { $0.stamp < $1.stamp }, kind: .snapshot)
            registers.throughSeq = outbox.device.lastSeq
            try local.saveRegisters(registers)
            snapshotDue = false
            filesSinceSnapshot = 0
        }
        let deviceFolder = folder.deviceFolder(deviceID)
        do {
            result.filesCopied = try outbox.copy(into: deviceFolder, using: folder.access)
            result.uploadProblem = try outbox.refreshUploads(in: deviceFolder, using: folder.access)
            try outbox.retireUploaded()
        } catch {
            result.pendingChanges = outbox.pendingChanges
            throw error
        }
        result.pendingChanges = outbox.pendingChanges
        // The iPhone going to the background and the Mac quitting only send (section 7).
        guard readsOthers else { return result }

        let reader = SyncReader(folder: folder, ownDeviceID: deviceID, limits: limits)
        let read = try await reader.read(after: cursors)
        result.read = read
        if read.laterVersionFrom != nil { throw SyncProblem.laterVersion }
        for entry in read.entries { clock.observe(entry.stamp, at: now()) }
        result.changedKeys = registers.merge(read.entries)
        cursors = read.cursors
        try local.saveCursors(cursors)
        try local.saveRegisters(registers)
        try local.saveClock(clock)
        return result
    }

    /// Writes this device's `device.json`: its name, platform, version, last `seq`, and the time.
    private func publishDevice(in folder: SyncFolder) throws {
        try folder.publishDevice(SyncDeviceFile(
            formatVersion: SyncFileCoding.supportedFormatVersion, deviceID: deviceID, name: identity.name,
            platform: identity.platform, appVersion: identity.appVersion, lastSeq: outbox.device.lastSeq, updated: now()
        ))
    }

    // MARK: Applying

    /// What the merged registers do to `library`.
    func application(for library: Library, voices: Set<String>?) -> SyncApplication {
        SyncMerge.apply(registers, to: library, voices: voices)
    }

    /// Takes the values applied to the library into the baseline, key by key, so a change made
    /// meanwhile is still found; and records the entries applying made (same-named folders folded).
    func didApply(_ application: SyncApplication, keys: Set<SyncKey>, library: Library) throws {
        let projection = SyncProjection.of(library, contents: contents())
        for key in keys {
            if let value = projection.values[key] { baseline.values[key] = value } else { baseline.values.removeValue(forKey: key) }
        }
        try local.saveBaseline(SyncBaselineFile(baseline))
        let folded = application.entriesToRecord.sorted { "\($0.key)" < "\($1.key)" }
        try append(folded.map { PendingChange(key: $0.key, value: $0.value, byHand: false) }, updatingBaseline: true)
    }

    // MARK: Counts

    /// Changes still waiting for iCloud Drive to upload.
    func pendingChanges() -> Int { outbox.pendingChanges }

    /// Whether registers hold an entry for `key`: for tests and the center.
    func entry(for key: SyncKey) -> SyncEntry? { registers.entries[key] }

    /// The cursors, for tests.
    func currentCursors() -> SyncCursors { cursors }
}
