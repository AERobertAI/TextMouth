import Foundation

// MARK: - Reading Other Devices' Files (FR43, section 7)

/// How long reading may wait (section 7): 30 seconds a file, two minutes a
/// moment, so no moment waits on iCloud Drive for long (R2).
struct SyncReadLimits: Sendable {
    var perFile: Duration = .seconds(30)
    var perMoment: Duration = .seconds(120)
}

/// What one reading of the other devices' files found.
struct SyncReadResult: Equatable, Sendable {
    /// Every entry read, to merge into the registers; merging twice changes nothing.
    var entries: [SyncEntry] = []
    /// The cursors after the files merged: each device's last `seq` read.
    var cursors = SyncCursors()
    /// When each device last published (`device.json`'s `updated`), by device ID.
    var lastHeard: [String: Date] = [:]
    /// The names devices call themselves, by device ID.
    var names: [String: String] = [:]
    /// Devices whose newest files hadn't arrived: "some changes haven't downloaded yet".
    var notArrived: [String] = []
    /// A later TextMouth's files, left alone: the first device that wrote one.
    var laterVersionFrom: String?
    /// Whether a moment's own limit ran out before every device was read.
    var ranOutOfTime = false
}

/// Reads the change files other devices wrote, in `seq` order from each
/// device's cursor. A file that isn't here yet holds that device's cursor, so
/// it is tried again at the next moment; a device's later snapshot covers a
/// file that never reads, so the cursor then moves past it. A device's first
/// reading starts at its newest readable snapshot.
struct SyncReader: Sendable {
    /// The folder read.
    let folder: SyncFolder
    /// This device's ID, whose own folder is never read back.
    let ownDeviceID: String
    /// The waits allowed.
    var limits = SyncReadLimits()
    /// Reads the clock, so a test makes time pass; the real one by default.
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// Reads every other device's new files, after `cursors`.
    func read(after cursors: SyncCursors) async throws -> SyncReadResult {
        var result = SyncReadResult(cursors: cursors)
        let started = now()
        for deviceID in try folder.deviceIDs() where deviceID != ownDeviceID {
            if started.duration(to: now()) >= limits.perMoment {
                result.ranOutOfTime = true
                break
            }
            try await readDevice(deviceID, started: started, into: &result)
        }
        return result
    }

    /// Reads one device's files, and its `device.json`.
    private func readDevice(_ deviceID: String, started: ContinuousClock.Instant, into result: inout SyncReadResult) async throws {
        let directory = folder.deviceFolder(deviceID)
        // `list` never downloads; a file in the cloud only is named but not on this device.
        let listing = try folder.access.list(directory)
        await readDeviceFile(directory, deviceID: deviceID, into: &result)

        let files = listing.compactMap { item -> (seq: Int, kind: SyncChangeFile.Kind, name: String)? in
            SyncNames.parseChangeFile(item.name).map { ($0.seq, $0.kind, item.name) }
        }.sorted { $0.seq < $1.seq }
        var cursor = result.cursors.merged[deviceID] ?? 0
        let pending = files.filter { $0.seq > cursor }
        guard !pending.isEmpty else { return }

        // A device read for the first time starts at its newest snapshot that reads.
        var queue = pending
        if cursor == 0 {
            for snapshot in pending.filter({ $0.kind == .snapshot }).reversed() {
                if let file = await readFile(directory.appendingPathComponent(snapshot.name), expecting: snapshot.seq) {
                    result.entries += file.entries
                    cursor = snapshot.seq
                    queue = pending.filter { $0.seq > snapshot.seq }
                    break
                }
            }
        }

        var index = 0
        while index < queue.count {
            let next = queue[index]
            if started.duration(to: now()) >= limits.perMoment {
                result.ranOutOfTime = true
                break
            }
            if let file = await readFile(directory.appendingPathComponent(next.name), expecting: next.seq) {
                if file.formatVersion > SyncFileCoding.supportedFormatVersion {
                    result.laterVersionFrom = result.laterVersionFrom ?? deviceID
                    break
                }
                result.entries += file.entries
                cursor = next.seq
                index += 1
                continue
            }
            // Not here yet: a later snapshot that reads covers it, and the cursor moves past.
            let covering = queue[(index + 1)...].filter { $0.kind == .snapshot }
            var jumped = false
            for snapshot in covering.reversed() {
                if let file = await readFile(directory.appendingPathComponent(snapshot.name), expecting: snapshot.seq) {
                    result.entries += file.entries
                    cursor = snapshot.seq
                    index = queue.firstIndex { $0.seq > snapshot.seq } ?? queue.count
                    jumped = true
                    break
                }
            }
            if !jumped {
                result.notArrived.append(deviceID)
                break
            }
        }
        result.cursors.merged[deviceID] = cursor
    }

    /// Reads a device's `device.json` for its name and the time it last published; a
    /// file not here yet leaves them as they were.
    private func readDeviceFile(_ directory: URL, deviceID: String, into result: inout SyncReadResult) async {
        guard let data = try? await folder.access.read(directory.appendingPathComponent(SyncNames.deviceFile), within: limits.perFile),
              let device = SyncFileCoding.decode(SyncDeviceFile.self, from: data) else { return }
        result.lastHeard[deviceID] = device.updated
        result.names[deviceID] = device.name
    }

    /// A change file read whole: nil when it isn't here yet, doesn't decode,
    /// or holds other than `count` entries (section 3). A file of a later
    /// format is returned as read, with its `formatVersion`, for the caller to leave alone.
    private func readFile(_ url: URL, expecting seq: Int) async -> SyncChangeFile? {
        guard let data = try? await folder.access.read(url, within: limits.perFile),
              let file = SyncFileCoding.decode(SyncChangeFile.self, from: data),
              file.seq == seq, file.count == file.entries.count else { return nil }
        return file
    }
}
