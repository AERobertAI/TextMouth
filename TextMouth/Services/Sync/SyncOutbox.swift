import Foundation

// MARK: - The Outbox (FR43, section 4)

/// Each outbox file's state in `outbox.json`.
enum SyncOutboxState: String, Codable, Sendable {
    /// In the outbox only.
    case written
    /// Copied into the device's folder in the sync folder.
    case copied
    /// iCloud Drive reports its copy uploaded, or reports nothing and the copy counts as sent.
    case uploaded
}

/// `outbox.json`: the files of `Outbox/` and their states.
struct SyncOutboxIndex: Codable, Equatable, Sendable {
    /// One outbox file.
    struct Item: Codable, Equatable, Sendable {
        var seq: Int
        var kind: SyncChangeFile.Kind
        /// How many entries the file holds, for the "3 changes wait" count.
        var count: Int
        var state: SyncOutboxState
        /// Whether the drive reported the upload (true) or reported nothing (false).
        var confirmed: Bool
    }
    var items: [Item] = []
}

/// A change leaves its device only through here: every batch of stamped
/// entries goes first into `Outbox/<seq>.changes.json` on the device's own
/// disk (rule R3), is copied into the device's folder in the sync folder at
/// each moment that reaches it, and leaves the outbox once it and a later
/// snapshot have uploaded. Offline, nothing is lost: the file stays.
///
/// A value type; the engine actor owns the one that works on a store.
struct SyncOutbox: Sendable {
    /// The device's own files.
    let local: SyncLocalFiles
    /// This device's state: its ID, incarnation, and last `seq`.
    private(set) var device: SyncDeviceState
    /// The outbox files and their states.
    private(set) var index: SyncOutboxIndex

    /// The outbox of the device in `local`, read from disk; `device` is
    /// used when the device has no state saved yet.
    init(local: SyncLocalFiles, device fallback: SyncDeviceState) {
        self.local = local
        device = local.loadDevice() ?? fallback
        index = local.read(SyncOutboxIndex.self, at: local.outboxIndexURL) ?? SyncOutboxIndex()
    }

    // MARK: Writing

    /// The name of an outbox file.
    private func fileURL(_ seq: Int, _ kind: SyncChangeFile.Kind) -> URL {
        local.outboxFolder.appendingPathComponent(SyncNames.changeFile(seq: seq, kind: kind))
    }

    /// Writes `entries` as the next change file (or snapshot), and returns its `seq`.
    ///
    /// The file is written atomically before the index and the device's
    /// `lastSeq` follow, so a crash between them leaves a file the next
    /// start finds (`adoptUnindexedFiles`). The caller saves the clock with it.
    @discardableResult
    mutating func append(_ entries: [SyncEntry], kind: SyncChangeFile.Kind = .changes) throws -> Int {
        let seq = device.lastSeq + 1
        let file = SyncChangeFile(
            formatVersion: SyncFileCoding.supportedFormatVersion, deviceID: device.deviceID,
            incarnation: device.incarnation, seq: seq, kind: kind, count: entries.count, entries: entries
        )
        try local.prepare()
        try SyncFileCoding.encode(file).write(to: fileURL(seq, kind), options: .atomic)
        device.lastSeq = seq
        index.items.append(.init(seq: seq, kind: kind, count: entries.count, state: .written, confirmed: false))
        try local.saveDevice(device)
        try local.write(index, to: local.outboxIndexURL)
        return seq
    }

    /// Reads the outbox file `seq`, or nil when it is missing or doesn't decode.
    func file(_ seq: Int, kind: SyncChangeFile.Kind) -> SyncChangeFile? {
        local.read(SyncChangeFile.self, at: fileURL(seq, kind))
    }

    /// The entries of every outbox file past `seq`, oldest first: what goes
    /// back into the registers after a crash (section 4, step 6).
    func entries(after seq: Int) -> [SyncEntry] {
        index.items.filter { $0.seq > seq }.sorted { $0.seq < $1.seq }
            .flatMap { file($0.seq, kind: $0.kind)?.entries ?? [] }
    }

    /// Indexes outbox files that a crash left unindexed, so they are copied too.
    /// Returns how many it found.
    @discardableResult
    mutating func adoptUnindexedFiles() throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: local.outboxFolder.path)) ?? []
        var found = 0
        for name in names.sorted() {
            guard let parsed = SyncNames.parseChangeFile(name),
                  !index.items.contains(where: { $0.seq == parsed.seq }),
                  let file = file(parsed.seq, kind: parsed.kind) else { continue }
            index.items.append(.init(seq: parsed.seq, kind: parsed.kind, count: file.entries.count, state: .written, confirmed: false))
            device.lastSeq = max(device.lastSeq, parsed.seq)
            found += 1
        }
        if found > 0 {
            try local.saveDevice(device)
            try local.write(index, to: local.outboxIndexURL)
        }
        return found
    }

    // MARK: Copying and uploading

    /// Copies every file still `written`, or `copied` but now missing from
    /// the device's folder, into `deviceFolder`; a file already there is
    /// left alone (a file sent again keeps its name and bytes). Returns how
    /// many it copied. A problem stops the copying and is thrown after the
    /// files copied so far are recorded.
    @discardableResult
    mutating func copy(into deviceFolder: URL, using access: any SyncFolderAccess) throws -> Int {
        // A device folder not made yet lists as empty: `copyIn` makes it.
        let present = Set(((try? access.list(deviceFolder)) ?? []).map(\.name))
        var copied = 0
        var failure: Error?
        for position in index.items.indices where index.items[position].state != .uploaded {
            let item = index.items[position]
            let name = SyncNames.changeFile(seq: item.seq, kind: item.kind)
            if item.state == .copied, present.contains(name) { continue }
            do {
                if !present.contains(name) {
                    try access.copyIn(fileURL(item.seq, item.kind), to: deviceFolder.appendingPathComponent(name))
                    copied += 1
                }
                index.items[position].state = .copied
            } catch {
                failure = error
                break
            }
        }
        try local.write(index, to: local.outboxIndexURL)
        if let failure { throw failure }
        return copied
    }

    /// Reads the upload state of each copied file, marking those uploaded.
    /// Where the drive reports nothing the copy counts as sent (section 4,
    /// step 7). A failed upload stays copied, counted as waiting; the first
    /// failure is returned so the status can say why.
    @discardableResult
    mutating func refreshUploads(in deviceFolder: URL, using access: any SyncFolderAccess) throws -> SyncProblem? {
        var problem: SyncProblem?
        for position in index.items.indices where index.items[position].state == .copied {
            let item = index.items[position]
            let name = SyncNames.changeFile(seq: item.seq, kind: item.kind)
            switch access.uploadState(of: deviceFolder.appendingPathComponent(name)) {
            case .uploaded:
                index.items[position].state = .uploaded
                index.items[position].confirmed = true
            case .notReported:
                index.items[position].state = .uploaded
            case .uploading:
                break
            case .failed(let reason):
                problem = problem ?? reason
            }
        }
        try local.write(index, to: local.outboxIndexURL)
        return problem
    }

    /// Lets files leave the outbox: a file goes once it has uploaded and a
    /// later snapshot has too (which rebuilds anything it held). Returns how
    /// many went. A snapshot itself goes when a later one has uploaded.
    @discardableResult
    mutating func retireUploaded() throws -> Int {
        guard let newestSnapshot = index.items.filter({ $0.kind == .snapshot && $0.state == .uploaded })
            .map(\.seq).max() else { return 0 }
        let retiring = index.items.filter { $0.state == .uploaded && $0.seq < newestSnapshot }
        for item in retiring {
            // The outbox's own file: a copy exists in the sync folder, uploaded.
            try? FileManager.default.removeItem(at: fileURL(item.seq, item.kind))
        }
        index.items.removeAll { item in retiring.contains { $0.seq == item.seq } }
        try local.write(index, to: local.outboxIndexURL)
        return retiring.count
    }

    // MARK: Counts

    /// How many changes are not yet uploaded: the entries of every file whose
    /// copy hasn't uploaded. Snapshots hold no new change, so they don't count.
    var pendingChanges: Int {
        index.items.filter { $0.kind == .changes && $0.state != .uploaded }.reduce(0) { $0 + $1.count }
    }
}
