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
    /// Whether a read of a file not downloaded was refused at once for want of a network.
    var sawOffline = false
}

/// Reads the change files other devices wrote, one `seq` after another from
/// each device's cursor. iCloud Drive promises no order, so the listing is
/// never taken to hold every file: the cursor only ever moves to the next
/// `seq`, and a `seq` that is missing or not readable yet holds it, unless a
/// later snapshot that reads covers it. The newest `seq` a device expects is
/// the highest it lists or its `device.json` says. A device read for the
/// first time starts at its newest readable snapshot.
struct SyncReader: Sendable {
    /// The folder read.
    let folder: SyncFolder
    /// This device's ID, whose own folder is never read back.
    let ownDeviceID: String
    /// The waits allowed.
    var limits = SyncReadLimits()
    /// Reads the clock, so a test makes time pass; the real one by default.
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// One change file or snapshot of a device, as listed.
    private struct Listed {
        var kind: SyncChangeFile.Kind
        var name: String
    }

    /// Reads every other device's new files, after `cursors`.
    func read(after cursors: SyncCursors) async throws -> SyncReadResult {
        var result = SyncReadResult(cursors: cursors)
        let started = now()
        for deviceID in try folder.deviceIDs() where deviceID != ownDeviceID {
            if isOutOfTime(since: started) {
                result.ranOutOfTime = true
                break
            }
            try await readDevice(deviceID, started: started, into: &result)
        }
        return result
    }

    /// Whether the moment's limit has run out.
    private func isOutOfTime(since started: ContinuousClock.Instant) -> Bool {
        started.duration(to: now()) >= limits.perMoment
    }

    /// Reads one device's files, and its `device.json`.
    private func readDevice(_ deviceID: String, started: ContinuousClock.Instant, into result: inout SyncReadResult) async throws {
        let directory = folder.deviceFolder(deviceID)
        // `list` never downloads; a file in the cloud only is named but not on this device.
        let listing = try folder.access.list(directory)
        let published = await readDeviceFile(directory, deviceID: deviceID, into: &result)

        var listed: [Int: Listed] = [:]
        for item in listing {
            if let parsed = SyncNames.parseChangeFile(item.name) { listed[parsed.seq] = Listed(kind: parsed.kind, name: item.name) }
        }
        var cursor = result.cursors.merged[deviceID] ?? 0
        // Every seq up to this one is expected: the listing may lack files that are on their way.
        let expectedLast = max(listed.keys.max() ?? 0, published?.lastSeq ?? 0)
        guard expectedLast > cursor else { return }
        let snapshots = listed.filter { $0.value.kind == .snapshot }.keys.sorted(by: >)

        // A device read for the first time starts at its newest snapshot that reads.
        if cursor == 0 {
            for seq in snapshots {
                if isOutOfTime(since: started) { result.ranOutOfTime = true; break }
                if case .file(let file) = await readFile(directory, listed[seq], expecting: seq, into: &result) {
                    result.entries += file.entries
                    cursor = seq
                    break
                }
            }
        }

        reading: while cursor < expectedLast {
            if isOutOfTime(since: started) {
                result.ranOutOfTime = true
                break
            }
            let next = cursor + 1
            switch await readFile(directory, listed[next], expecting: next, into: &result) {
            case .file(let file):
                result.entries += file.entries
                cursor = next
                continue reading
            case .laterVersion:
                // A later TextMouth's file is left alone, and said.
                result.laterVersionFrom = result.laterVersionFrom ?? deviceID
                break reading
            case .notHere:
                break
            }
            // Not here yet: a later snapshot that reads covers it, and the cursor moves past it.
            var covered = false
            for seq in snapshots where seq > next {
                if isOutOfTime(since: started) { result.ranOutOfTime = true; break }
                if case .file(let file) = await readFile(directory, listed[seq], expecting: seq, into: &result) {
                    result.entries += file.entries
                    cursor = seq
                    covered = true
                    break
                }
            }
            if !covered {
                if !result.ranOutOfTime { result.notArrived.append(deviceID) }
                break
            }
        }
        result.cursors.merged[deviceID] = cursor
    }

    /// Reads a device's `device.json` for its name and the time it last published; a
    /// file not here yet leaves them as they were. Returns the file when it was read.
    private func readDeviceFile(_ directory: URL, deviceID: String, into result: inout SyncReadResult) async -> SyncDeviceFile? {
        guard let data = try? await folder.access.read(directory.appendingPathComponent(SyncNames.deviceFile), within: limits.perFile),
              let device = try? SyncFormats.decodeDeviceFile(data) else { return nil }
        result.lastHeard[deviceID] = device.updated
        result.names[deviceID] = device.name
        return device
    }

    /// What reading one change file found.
    private enum FileRead {
        /// The file, whole.
        case file(SyncChangeFile)
        /// Not here yet: not listed, not downloaded, half there, not decodable, or holding other than `count` entries (section 3).
        case notHere
        /// Written by a later TextMouth: left alone.
        case laterVersion
    }

    /// A change file read through core's reader, which knows a half file from a later TextMouth's. A
    /// read refused at once for want of a network is noted in `result`.
    private func readFile(_ directory: URL, _ item: Listed?, expecting seq: Int, into result: inout SyncReadResult) async -> FileRead {
        guard let item else { return .notHere }
        let url = directory.appendingPathComponent(item.name)
        let data: Data
        do {
            data = try await folder.access.read(url, within: limits.perFile)
        } catch SyncProblem.offline {
            result.sawOffline = true
            return .notHere
        } catch {
            return .notHere
        }
        do {
            let file = try SyncFormats.decodeChangeFile(data, named: url.lastPathComponent)
            return file.seq == seq ? .file(file) : .notHere
        } catch SyncProblem.laterVersion {
            return .laterVersion
        } catch {
            return .notHere
        }
    }
}
