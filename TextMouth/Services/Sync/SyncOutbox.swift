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
        /// When the file was copied into the folder; a copy the drive never confirms leaves the outbox only a week on.
        var copiedAt: Date?
    }
    var items: [Item] = []
}

/// What the outbox found that it can't mend: a file of a seq it wrote is in the folder with other bytes.
enum SyncOutboxConflict: Error, Equatable {
    /// Another writer holds this device's seq: the library was restored or copied from an older state.
    case anotherWriter(seq: Int)
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
            formatVersion: SyncFormats.currentVersion, deviceID: device.deviceID,
            incarnation: device.incarnation, seq: seq, kind: kind, count: entries.count, entries: entries
        )
        try local.prepare()
        try SyncFormats.encode(file).write(to: fileURL(seq, kind), options: .atomic)
        device.lastSeq = seq
        index.items.append(.init(seq: seq, kind: kind, count: entries.count, state: .written, confirmed: false, copiedAt: nil))
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
            index.items.append(.init(seq: parsed.seq, kind: parsed.kind, count: file.entries.count, state: .written, confirmed: false, copiedAt: nil))
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
    mutating func copy(into deviceFolder: URL, using access: any SyncFolderAccess, now: Date = Date()) async throws -> Int {
        let verified = try await verifiedPresent(in: deviceFolder, using: access)
        return try copyVerified(into: deviceFolder, using: access, now: now, verified: verified)
    }

    /// The names of outbox files that are in the device's folder with the outbox's own bytes. A file there
    /// with other bytes is another writer's (a library restored on the same install writes seqs the folder
    /// holds already): `SyncOutboxConflict.anotherWriter`. One that can't be read yet is left out: not known to
    /// be ours. This reads, so it is done before `copyVerified`, which changes the outbox; an actor calls the two
    /// in turn, never holding the outbox across a wait.
    func verifiedPresent(in deviceFolder: URL, using access: any SyncFolderAccess) async throws -> Set<String> {
        let present = Set(((try? access.list(deviceFolder)) ?? []).map(\.name))
        var verified: Set<String> = []
        for item in index.items where item.state != .uploaded {
            let name = SyncNames.changeFile(seq: item.seq, kind: item.kind)
            guard present.contains(name), item.state != .copied else { continue }
            guard let remote = try? await access.read(deviceFolder.appendingPathComponent(name), within: .seconds(10)) else { continue }
            guard let mine = try? Data(contentsOf: fileURL(item.seq, item.kind)), mine == remote else {
                throw SyncOutboxConflict.anotherWriter(seq: item.seq)
            }
            verified.insert(name)
        }
        return verified
    }

    /// One file the outbox still has to put in the device's folder.
    struct CopyItem: Sendable {
        var seq: Int
        var source: URL
        var destination: URL
    }

    /// What a copy has to do: the files to put in the folder, and the seqs whose files are there already (verified
    /// to be the outbox's own, or sent before) and only need marking.
    struct CopyPlan: Sendable {
        var toCopy: [CopyItem] = []
        var alreadyThere: [Int] = []
        /// Files in the folder under an outbox name that could not be read, so are not known to be ours.
        var unreadable: [String] = []
    }

    /// Works out what to copy, from what the folder lists and what `verified` says. A file present and not
    /// verified stays unsent and is named in `unreadable`. Changes nothing, so it holds no state across a wait.
    func copyPlan(into deviceFolder: URL, using access: any SyncFolderAccess, verified: Set<String>) -> CopyPlan {
        // A device folder not made yet lists as empty: `copyIn` makes it.
        let present = Set(((try? access.list(deviceFolder)) ?? []).map(\.name))
        var plan = CopyPlan()
        for item in index.items where item.state != .uploaded {
            let name = SyncNames.changeFile(seq: item.seq, kind: item.kind)
            if present.contains(name) {
                if item.state == .copied || verified.contains(name) {
                    plan.alreadyThere.append(item.seq)
                } else {
                    plan.unreadable.append(name)
                }
            } else {
                plan.toCopy.append(CopyItem(seq: item.seq, source: fileURL(item.seq, item.kind), destination: deviceFolder.appendingPathComponent(name)))
            }
        }
        return plan
    }

    /// Marks the files of `seqs` as copied into the folder, and saves the index.
    mutating func markCopied(_ seqs: [Int], now: Date = Date()) throws {
        for seq in seqs {
            guard let position = index.items.firstIndex(where: { $0.seq == seq }) else { continue }
            index.items[position].state = .copied
            index.items[position].copiedAt = index.items[position].copiedAt ?? now
        }
        try local.write(index, to: local.outboxIndexURL)
    }

    /// Copies what the plan says, on the calling thread, marking each as it goes: for a caller that owns the outbox
    /// (a test). An actor does this itself, awaiting each copy, so no change to the outbox spans a wait.
    @discardableResult
    mutating func copyVerified(into deviceFolder: URL, using access: any SyncFolderAccess, now: Date = Date(), verified: Set<String>) throws -> Int {
        let plan = copyPlan(into: deviceFolder, using: access, verified: verified)
        var done = plan.alreadyThere
        do {
            for item in plan.toCopy {
                try access.copyIn(item.source, to: item.destination)
                done.append(item.seq)
            }
        } catch {
            try markCopied(done, now: now)
            throw error
        }
        try markCopied(done, now: now)
        return plan.toCopy.count
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

    /// How long a copy the drive never confirms stays in the outbox after a later snapshot, in seconds.
    static let unconfirmedStay: TimeInterval = 7 * 86_400

    /// Lets files leave the outbox: a file goes once the drive confirmed its upload and a
    /// later snapshot has uploaded too (which rebuilds anything it held). A copy the drive
    /// never reports on goes only a week after it was copied. Returns how many went. A
    /// snapshot itself goes when a later one has uploaded.
    @discardableResult
    mutating func retireUploaded(now: Date = Date()) throws -> Int {
        guard let newestSnapshot = index.items.filter({ $0.kind == .snapshot && $0.state == .uploaded })
            .map(\.seq).max() else { return 0 }
        let retiring = index.items.filter { item in
            guard item.state == .uploaded, item.seq < newestSnapshot else { return false }
            if item.confirmed { return true }
            return now.timeIntervalSince(item.copiedAt ?? now) >= Self.unconfirmedStay
        }
        for item in retiring {
            // The outbox's own file: a copy exists in the sync folder, uploaded.
            try? FileManager.default.removeItem(at: fileURL(item.seq, item.kind))
        }
        index.items.removeAll { item in retiring.contains { $0.seq == item.seq } }
        try local.write(index, to: local.outboxIndexURL)
        return retiring.count
    }

    // MARK: The device's state

    /// Changes this device's own state and saves it.
    mutating func updateDevice(_ change: (inout SyncDeviceState) -> Void) throws {
        change(&device)
        try local.saveDevice(device)
    }

    // MARK: Counts

    /// How many changes are not yet uploaded: the entries of every file whose
    /// copy hasn't uploaded. Snapshots hold no new change, so they don't count.
    var pendingChanges: Int {
        index.items.filter { $0.kind == .changes && $0.state != .uploaded }.reduce(0) { $0 + $1.count }
    }
}
