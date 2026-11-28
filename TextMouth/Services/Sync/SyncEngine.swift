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
    /// Whether this device found its own folder holding another incarnation's files (a restored or copied
    /// library) and so took a new identity.
    var tookNewIdentity = false
}

/// The steps of a run, in the order the code reaches them, after each of which a test stops the engine to see what a
/// crash there leaves (section 11): the outbox write (inside a record), the end of the record, the copy into the
/// folder, the upload check, the read of other devices' files, the merge, the saves of the registers, the clock,
/// and the cursors, and then the apply.
enum SyncStep: String, CaseIterable, Sendable {
    case outboxWrite, record, copy, upload, read, merge, registers, clock, cursors, apply
}

/// What recording the library did.
struct SyncRecordResult: Equatable, Sendable {
    /// How many keys were recorded.
    var recorded = 0
    /// How many book removals were held back, not sent: a library emptied at once (index recovery, a
    /// wrong folder) is not a person's removal of every book.
    var heldRemovals = 0
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
    /// The book and folder keys the baseline holds that the library lacked at launch, held until the first apply (R7).
    private var launchHold = SyncLaunchHold()
    private var cursors: SyncCursors
    /// Whether this device must publish a snapshot at its next exchange: it is new, or restored.
    private var snapshotDue: Bool
    /// How many change files make a snapshot due, so old files can leave the outbox and a joining device reads little.
    private let snapshotEvery = 100
    /// How long a snapshot may go without being renewed, in seconds.
    private let snapshotInterval: TimeInterval = 86_400
    /// The book removals the last record held back, and the ones the person has confirmed.
    private var heldKeys: Set<SyncKey> = []
    private var confirmedKeys: Set<SyncKey> = []
    /// How many runs in a row found a file of this device in the folder that could not be read.
    private var unreadableRuns = 0
    /// The most book removals one record may send: more, or most of the library at once, is held back.
    static let massRemovalLimit = 20

    /// A stop a test injects after a step, to see what a crash there leaves (tests only; nothing sets it in the app).
    private var stopAfter: (@Sendable (SyncStep) throws -> Void)?

    /// Sets the stop after steps (tests only).
    func setStopAfter(_ stop: (@Sendable (SyncStep) throws -> Void)?) {
        stopAfter = stop
    }

    /// This device's ID.
    var deviceID: String { outbox.device.deviceID }

    /// Opens the device's files, making them when the device is new or its
    /// library was restored onto another install (a new ID, then a
    /// snapshot), and puts back into the registers any outbox file past
    /// `throughSeq` that a crash kept out (section 4, step 6).
    ///
    /// It reads megabytes of JSON for a large library: call it off the main actor (`SyncEngine.open`).
    init(local: SyncLocalFiles, identity: SyncDeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.local = local
        self.identity = identity
        self.now = now
        try local.prepare()

        var state = local.loadDevice()
        var fresh = false
        if state == nil || state?.installID != identity.installID {
            // A new library, or one restored onto another install: a new ID, and the old outbox is not ours.
            state = try Self.startNewIdentity(local: local, identity: identity, replacing: state)
            fresh = true
        }
        let device = state!
        var outbox = SyncOutbox(local: local, device: device)
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
        clock = local.loadClock(device: device.deviceID)
        baseline = local.loadBaseline()
        cursors = local.loadCursors()
        snapshotDue = fresh
        // Whatever an earlier run left half made in Staging is not wanted: nothing is fetching now.
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: local.stagingFolder, includingPropertiesForKeys: nil) {
            for leftover in leftovers { try? FileManager.default.removeItem(at: leftover) }
        }
    }

    /// Opens the engine off the main actor: its files are read there.
    static func open(local: SyncLocalFiles, identity: SyncDeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) async throws -> SyncEngine {
        try await Task.detached(priority: .utility) {
            try SyncEngine(local: local, identity: identity, now: now)
        }.value
    }

    /// Makes a new identity for this library: a new device ID and incarnation, the old outbox set aside
    /// (never adopted, and never deleted), and empty registers, cursors, baseline, and clock, so the library is
    /// recorded afresh as a joining one. Returns the new state.
    private static func startNewIdentity(local: SyncLocalFiles, identity: SyncDeviceIdentity, replacing old: SyncDeviceState?) throws -> SyncDeviceState {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: local.outboxFolder.path) {
            // Even when device.json is damaged, so no old file is adopted under the new ID.
            let name = "Outbox." + (old?.deviceID ?? "unknown") + "." + UUID().uuidString.lowercased()
            try fileManager.moveItem(at: local.outboxFolder, to: local.root.appendingPathComponent(name, isDirectory: true))
        }
        try local.prepare()
        let state = SyncDeviceState(deviceID: UUID().uuidString.lowercased(), incarnation: UUID(), installID: identity.installID, lastSeq: 0)
        try local.saveDevice(state)
        try local.write(SyncOutboxIndex(), to: local.outboxIndexURL)
        try local.saveRegisters(SyncRegisters())
        try local.saveCursors(SyncCursors())
        try local.saveBaseline(SyncProjection())
        try local.saveClock(SyncClock(device: state.deviceID))
        return state
    }

    /// Takes a new identity while running: this library's files were restored or copied from an older state
    /// (the folder holds its device's files past what this device wrote, or of another incarnation).
    private func takeNewIdentity() throws {
        let state = try Self.startNewIdentity(local: local, identity: identity, replacing: outbox.device)
        outbox = SyncOutbox(local: local, device: state)
        clock = SyncClock(device: state.deviceID)
        registers = SyncRegisters()
        cursors = SyncCursors()
        baseline = SyncProjection()
        launchHold = SyncLaunchHold()
        snapshotDue = true
    }

    // MARK: Recording

    /// Stamps `changes`, writes them as the next outbox file, and puts them in the registers. The
    /// outbox file is written first, then the clock, registers, and (when asked) baseline, so a crash in
    /// between is found at the next start.
    @discardableResult
    private func append(_ pairs: [PendingChange], updatingBaseline: Bool, joining: Bool = false) throws -> Int {
        guard !pairs.isEmpty else { return 0 }
        let deviceID = outbox.device.deviceID
        // A device's first record in a store is a joining, restored, or copied library: its old places and
        // undated values are stamped as old as they are, so they lose to what the store holds already.
        let stamped = pairs.map { pair -> SyncEntry in
            let stamp = joining
                ? SyncMerge.joiningStamp(for: pair.key, value: pair.value, device: deviceID, now: now())
                : clock.next(at: now())
            return SyncEntry(key: pair.key, value: pair.value, stamp: stamp, byHand: pair.byHand)
        }
        let seq = try outbox.append(stamped)
        // The outbox file is on disk: the registers and the baseline take the entries in memory at once, before any
        // save that may fail, so a snapshot made after a failed save still holds them (a snapshot that left them out
        // would make every device skip the files that do).
        registers.merge(stamped)
        registers.throughSeq = seq
        if updatingBaseline {
            // Only `absorb` writes the baseline: it forgets removals, notes hand edits, and keeps list orders.
            baseline.absorb(stamped)
        }
        try stopAfter?(.outboxWrite)
        try local.saveClock(clock)
        try local.saveRegisters(registers)
        if updatingBaseline { try local.saveBaseline(baseline) }
        return pairs.count
    }

    /// Compares `library`'s projection with the baseline and records each changed key
    /// (section 6, the recorder). The projection is made here, off the main thread. The first
    /// record after launch learns which books and folders the library lacks (`SyncLaunchHold`),
    /// and none of those is reported removed until `settleLaunch` (R7). A record that would remove
    /// a great many books at once is held back and reported, not sent.
    /// - Parameter feeds: the subscriptions (FR56), or nil while the host has none to give: no feed
    ///   key is then recorded, and no feed is reported added or removed.
    @discardableResult
    func record(library: Library, feeds: [Feed]? = nil) throws -> SyncRecordResult {
        let projection = SyncProjection.of(library, contents: contents(), feeds: feeds)
        launchHold.observeLaunch(baseline: baseline, now: projection)
        var changes = SyncMerge.changes(from: baseline, to: projection, hold: launchHold)

        // A mass removal is not a person's: index recovery or a wrong folder empties the library at once.
        let removals = changes.filter { key, value in
            if case .book(_, .presence) = key { return value == .null }
            return false
        }.keys
        let known = baseline.values.keys.filter { if case .book(_, .presence) = $0 { return true } else { return false } }.count
        var held = 0
        // The removals the person confirmed with Sync Now (`confirmHeldRemovals`) are theirs; any other is held.
        let unconfirmed = removals.filter { !confirmedKeys.contains($0) }
        if removals.count > Self.massRemovalLimit || (known >= 4 && removals.count * 2 > known), !unconfirmed.isEmpty {
            for key in unconfirmed { changes[key] = nil }
            held = unconfirmed.count
            heldKeys = Set(unconfirmed)
            DiagnosticLog.event(.storage, "SYNC_RUN: \(held) book removals were held back, not sent, as they are most of the library or too many at once") // l10n: no (debug log text)
        }

        if held == 0 { heldKeys = [] }
        let ordered = changes.sorted { "\($0.key)" < "\($1.key)" }
        let joining = outbox.device.hasRecordedLibrary != true
        let recorded = try append(
            ordered.map { PendingChange(key: $0.key, value: $0.value, byHand: projection.byHand.contains($0.key)) },
            updatingBaseline: true, joining: joining
        )
        if joining && recorded > 0 {
            try outbox.updateDevice { $0.hasRecordedLibrary = true }
        }
        try stopAfter?(.record)
        return SyncRecordResult(recorded: recorded, heldRemovals: held)
    }

    /// The person chose Sync Now while removals were held: exactly those removals are now theirs to send. Any other
    /// removal, held later, stays held.
    func confirmHeldRemovals() {
        confirmedKeys = heldKeys
    }

    /// Takes the confirmation back, at the end of the run it was given for, however that run ended.
    func clearConfirmation() {
        confirmedKeys = []
    }

    /// Ends the launch hold, once the first apply after launch has had its chance to put books back:
    /// a book or folder still missing is forgotten by the baseline, so it is neither put back nor
    /// reported as removed (R7).
    /// The feeds' hold ends at the first settle given the feeds (FR56).
    func settleLaunch(library: Library, feeds: [Feed]? = nil) throws {
        launchHold.settle(baseline: &baseline, now: SyncProjection.of(library, contents: contents(), feeds: feeds))
        try local.saveBaseline(baseline)
    }

    /// Whether the launch hold of the feeds has yet to end (FR56): until a settle is given them.
    var launchHoldAwaitsFeeds: Bool { launchHold.awaitsFeeds }

    /// Records Keep on All Devices on or off, as a person chose (section 16): never projected from the library.
    func recordKeep(_ keep: Bool, for bookIDs: [UUID]) throws {
        try append(bookIDs.map { PendingChange(key: .book($0, .keep), value: .bool(keep), byHand: true) }, updatingBaseline: false)
    }

    /// Records a book's content, once the backup has it uploaded (section 8). The projection holds a
    /// book's content, so the baseline takes it too, or the next record would stamp it again.
    func recordContent(_ content: SyncContent, for bookID: UUID) throws {
        try append([PendingChange(key: .book(bookID, .content), value: SyncValueCoding.json(content), byHand: false)], updatingBaseline: true)
    }

    /// The contents of every book in the registers, for `SyncProjection.of`.
    func contents() -> [UUID: SyncContent] {
        var found: [UUID: SyncContent] = [:]
        for (key, entry) in registers.entries {
            if case .book(let id, .content) = key, let content = SyncValueCoding.decode(SyncContent.self, from: entry.value) {
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

    /// Whether a snapshot is due: this device is new, 100 files went by since its last, or a day did.
    private func isSnapshotDue() -> Bool {
        if snapshotDue { return true }
        let device = outbox.device
        if device.lastSeq - (device.lastSnapshotSeq ?? 0) >= snapshotEvery { return true }
        guard let last = device.lastSnapshotAt else { return device.lastSeq > 0 }
        return now().timeIntervalSince(last) >= snapshotInterval && device.lastSeq > (device.lastSnapshotSeq ?? 0)
    }

    /// Looks at this device's own folder in the store: files past what this device wrote, or of another
    /// incarnation, mean its library was restored or copied from an older state, so it takes a new identity (section 3).
    private func checkOwnFolder(_ folder: SyncFolder) async -> Bool {
        let own = folder.deviceFolder(outbox.device.deviceID)
        guard let listing = try? folder.access.list(own) else { return false }
        let files = listing.compactMap { item in SyncNames.parseChangeFile(item.name).map { (seq: $0.seq, name: item.name) } }
        guard let newest = files.max(by: { $0.seq < $1.seq }) else { return false }
        if newest.seq > outbox.device.lastSeq { return true }
        // Another incarnation in the newest file, where it can be read.
        guard let data = try? await folder.access.read(own.appendingPathComponent(newest.name), within: .seconds(10)),
              let file = try? SyncFormats.decodeChangeFile(data, named: newest.name) else { return false }
        return file.incarnation != outbox.device.incarnation
    }

    /// Writes a snapshot of every value this device knows into the outbox when one is due.
    private func appendSnapshotIfDue() throws {
        guard isSnapshotDue() else { return }
        let seq = try outbox.append(registers.entries.values.sorted { $0.stamp < $1.stamp }, kind: .snapshot)
        registers.throughSeq = seq
        try local.saveRegisters(registers)
        try outbox.updateDevice { $0.lastSnapshotSeq = seq; $0.lastSnapshotAt = now() }
        snapshotDue = false
    }

    /// Publishes this device, copies the outbox in, reads the upload states, reads other
    /// devices' new files, and merges them into the registers. Reads are bounded (R2). A
    /// folder problem is thrown after what could be done locally is saved.
    func exchange(in folder: SyncFolder, readsOthers: Bool = true, limits: SyncReadLimits = SyncReadLimits()) async throws -> SyncExchangeResult {
        var result = SyncExchangeResult()
        // Whether or not this run reads: a restored library must not send under an identity another writer holds.
        if await checkOwnFolder(folder) {
            try takeNewIdentity()
            result.tookNewIdentity = true
        }
        try await publishDevice(in: folder)
        // Half-made files a crash left beside this device's own are cleared.
        folder.access.sweepPartialFiles(in: folder.deviceFolder(outbox.device.deviceID), olderThan: 3_600)
        try appendSnapshotIfDue()
        var deviceFolder = folder.deviceFolder(outbox.device.deviceID)
        do {
            do {
                result.filesCopied = try await copyOutbox(into: deviceFolder, using: folder.access)
            } catch is SyncOutboxConflict {
                // A file of a seq this device wrote is in the folder with other bytes: another writer holds this
                // identity. This library takes a new one, sets the old outbox aside, and sends a snapshot.
                try takeNewIdentity()
                result.tookNewIdentity = true
                try await publishDevice(in: folder)
                try appendSnapshotIfDue()
                deviceFolder = folder.deviceFolder(outbox.device.deviceID)
                result.filesCopied = try await copyOutbox(into: deviceFolder, using: folder.access)
            }
            try stopAfter?(.copy)
            result.uploadProblem = try outbox.refreshUploads(in: deviceFolder, using: folder.access)
            try stopAfter?(.upload)
            try outbox.retireUploaded(now: now())
        } catch {
            result.pendingChanges = outbox.pendingChanges
            throw error
        }
        result.pendingChanges = outbox.pendingChanges
        // The iPhone going to the background and the Mac quitting only send (section 7).
        guard readsOthers else { return result }

        let reader = SyncReader(folder: folder, ownDeviceID: outbox.device.deviceID, limits: limits)
        let read = try await reader.read(after: cursors)
        try stopAfter?(.read)
        result.read = read
        var refused = 0
        for entry in read.entries where !clock.observe(entry.stamp, at: now()) { refused += 1 }
        if refused > 0 {
            // One device's clock far ahead must not freeze every device's time: its stamps are merged, but the clock doesn't follow.
            DiagnosticLog.event(.storage, "SYNC_RUN: \(refused) stamps from other devices were more than a day ahead of this clock, which did not follow them") // l10n: no (debug log text)
        }
        // What was read is merged even when a later TextMouth's file was left alone. The registers and the
        // clock are saved before the cursors, so a crash between them re-reads files, never loses their entries.
        result.changedKeys = registers.merge(read.entries)
        try stopAfter?(.merge)
        try local.saveRegisters(registers)
        try stopAfter?(.registers)
        try local.saveClock(clock)
        try stopAfter?(.clock)
        cursors = read.cursors
        try local.saveCursors(cursors)
        try stopAfter?(.cursors)
        return result
    }

    /// Writes this device's `device.json`: its name, platform, version, last `seq`, and the time.
    /// Copies the outbox's files into the device's folder: each copy runs off the actor and is awaited, and the
    /// outbox is marked after, so no change to it spans a wait. A file in the folder under an outbox name is
    /// compared with the outbox's own first; one that stays unreadable for several runs is logged.
    private func copyOutbox(into deviceFolder: URL, using access: any SyncFolderAccess) async throws -> Int {
        let verified = try await outbox.verifiedPresent(in: deviceFolder, using: access)
        let plan = outbox.copyPlan(into: deviceFolder, using: access, verified: verified)
        var done = plan.alreadyThere
        do {
            for item in plan.toCopy {
                try await access.copyInOffActor(item.source, to: item.destination)
                done.append(item.seq)
            }
        } catch {
            try? outbox.markCopied(done, now: now())
            throw error
        }
        try outbox.markCopied(done, now: now())
        unreadableRuns = plan.unreadable.isEmpty ? 0 : unreadableRuns + 1
        if unreadableRuns == 3 {
            DiagnosticLog.event(.storage, "SYNC_RUN: \(plan.unreadable.count) files of this device in the sync folder have stayed unreadable for three runs") // l10n: no (debug log text)
        }
        return plan.toCopy.count
    }

    private func publishDevice(in folder: SyncFolder) async throws {
        try await folder.publishDevice(SyncDeviceFile(
            formatVersion: SyncFormats.currentVersion, deviceID: outbox.device.deviceID, name: identity.name,
            platform: identity.platform, appVersion: identity.appVersion, lastSeq: outbox.device.lastSeq, updated: now()
        ))
    }

    // MARK: Applying

    /// What the merged registers do to `library`.
    func application(for library: Library, feeds: [Feed]? = nil, voices: Set<String>?) -> SyncApplication {
        SyncMerge.apply(registers, to: library, feeds: feeds, voices: voices)
    }

    /// Takes the values applied to the library into the baseline, key by key, so a change made
    /// meanwhile is still found; and records the entries applying made (same-named folders folded).
    func didApply(_ application: SyncApplication, keys: Set<SyncKey>) throws {
        try stopAfter?(.apply)
        // The baseline takes the winning entry of each applied key, through `absorbApplied` alone.
        baseline.absorbApplied(keys, from: registers)
        try local.saveBaseline(baseline)
        let folded = application.entriesToRecord.sorted { "\($0.key)" < "\($1.key)" }
        try append(folded.map { PendingChange(key: $0.key, value: $0.value, byHand: false) }, updatingBaseline: true)
    }

    /// The device ID that wrote the winning entry of each of `keys`.
    func writers(of keys: Set<SyncKey>) -> [SyncKey: String] {
        var found: [SyncKey: String] = [:]
        for key in keys { if let entry = registers.entries[key] { found[key] = entry.stamp.device } }
        return found
    }

    // MARK: Counts

    /// Changes still waiting for iCloud Drive to upload.
    func pendingChanges() -> Int { outbox.pendingChanges }

    /// Whether registers hold an entry for `key`: for tests and the center.
    func entry(for key: SyncKey) -> SyncEntry? { registers.entries[key] }

    /// The cursors, for tests.
    func currentCursors() -> SyncCursors { cursors }
}
