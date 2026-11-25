import Foundation

// MARK: - The Device's Own Sync Files (FR43)

/// What `device.json` of the device's own folder holds (section 3): who this
/// device is in the store, and the last change file it numbered.
struct SyncDeviceState: Codable, Equatable, Sendable {
    /// The device's ID in the store: a lower-case UUID.
    var deviceID: String
    /// Changes when a copy of the library is told from the original (a
    /// restore or a copy on one install), together with `deviceID`.
    var incarnation: UUID
    /// The install that made this state (`SyncPreferences.installID`).
    var installID: String
    /// The `seq` of the last change file or snapshot this device numbered.
    var lastSeq: Int
    /// The `seq` of this device's newest snapshot, and when it was made: a snapshot is due after 100 files, or a day.
    var lastSnapshotSeq: Int?
    var lastSnapshotAt: Date?
    /// Whether this device has recorded its library into the store (its first record is a joining one).
    var hasRecordedLibrary: Bool?
}

/// Each other device's last `seq` this device has merged (`cursors.json`).
struct SyncCursors: Codable, Equatable, Sendable {
    /// Device ID to the last `seq` merged from it.
    var merged: [String: Int] = [:]
}

/// The files a device keeps for itself in `Sync/<store id>/` of its data
/// directory, on its own disk (section 3): `device.json`, `clock.json`,
/// `cursors.json`, `registers.json`, `baseline.json`, and the outbox's
/// folders. Every write is atomic; a file that is missing or doesn't decode
/// reads as nothing, so a crash leaves a state the next run can repair.
struct SyncLocalFiles: Sendable {
    /// `Sync/<store id>/`: this store's folder.
    let root: URL

    /// The files of the store `storeID` under `syncFolder` (`TextMouthPaths.syncDir`).
    init(syncFolder: URL, storeID: UUID) {
        root = syncFolder.appendingPathComponent(SyncNames.id(storeID), isDirectory: true)
    }

    /// The files kept in `root`, for tests that make their own folder.
    init(root: URL) {
        self.root = root
    }

    // MARK: Paths

    /// `device.json`.
    var deviceURL: URL { root.appendingPathComponent("device.json") }
    /// `clock.json`.
    var clockURL: URL { root.appendingPathComponent("clock.json") }
    /// `cursors.json`.
    var cursorsURL: URL { root.appendingPathComponent("cursors.json") }
    /// `registers.json`.
    var registersURL: URL { root.appendingPathComponent("registers.json") }
    /// `baseline.json`.
    var baselineURL: URL { root.appendingPathComponent("baseline.json") }
    /// `Outbox/`: change files and snapshots not yet known to be uploaded.
    var outboxFolder: URL { root.appendingPathComponent("Outbox", isDirectory: true) }
    /// `outbox.json`: each outbox file's state.
    var outboxIndexURL: URL { root.appendingPathComponent("outbox.json") }
    /// `Staging/`: files being made, moved in when whole.
    var stagingFolder: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    // MARK: Reading and writing

    /// Makes `root` and its folders if they are missing.
    func prepare() throws {
        for folder in [root, outboxFolder, stagingFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// The value of `type` in the file at `url`, or nil when the file is missing or doesn't decode.
    func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SyncValueCoding.makeDecoder().decode(type, from: data)
    }

    /// Writes `value` atomically at `url`, making the folder first.
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare()
        try SyncFormats.encode(value).write(to: url, options: .atomic)
    }

    /// The device's state, or nil before it joined.
    func loadDevice() -> SyncDeviceState? { read(SyncDeviceState.self, at: deviceURL) }
    /// Saves the device's state.
    func saveDevice(_ state: SyncDeviceState) throws { try write(state, to: deviceURL) }

    /// The clock, or a new one for `device`.
    func loadClock(device: String) -> SyncClock { read(SyncClock.self, at: clockURL) ?? SyncClock(device: device) }
    /// Saves the clock.
    func saveClock(_ clock: SyncClock) throws { try write(clock, to: clockURL) }

    /// The merge cursors.
    func loadCursors() -> SyncCursors { read(SyncCursors.self, at: cursorsURL) ?? SyncCursors() }
    /// Saves the merge cursors.
    func saveCursors(_ cursors: SyncCursors) throws { try write(cursors, to: cursorsURL) }

    /// The registers, empty before the first merge.
    func loadRegisters() -> SyncRegisters { read(SyncRegisters.self, at: registersURL) ?? SyncRegisters() }
    /// Saves the registers.
    func saveRegisters(_ registers: SyncRegisters) throws { try write(registers, to: registersURL) }

    /// The baseline, empty before the first record.
    func loadBaseline() -> SyncProjection { read(SyncProjection.self, at: baselineURL) ?? SyncProjection() }
    /// Saves the baseline.
    func saveBaseline(_ baseline: SyncProjection) throws { try write(baseline, to: baselineURL) }
}
