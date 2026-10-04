import Foundation

/// One location of the data directory as this process uses it (TODO S04).
///
/// Every file TextMouth keeps lives under the data directory's root, and the
/// root changes only when a data-directory move publishes its copy. A
/// generation numbers those changes: the location the process started with
/// is generation 0, and each published move starts the next. Work that
/// writes into the data directory resolves its paths under the current
/// generation (`StorageBoundary`), so a write prepared under one root never
/// lands under another.
struct StorageGeneration: Sendable {
    /// How many moves this process had published when this generation
    /// began: 0 for the location the process started with.
    let number: Int
    /// The data directory, spelled as `TextMouthPaths.root` returns it: as
    /// the preferences name it, or the default location.
    let root: URL
    /// The data directory as named and as the file system resolved it when
    /// the generation began, so a path spelled through a link that leads
    /// there is recognized as inside it too.
    let location: DataDirectoryLocation
}

extension StorageGeneration: Equatable {
    /// Two generations are the same when they have the same number and the
    /// same root. Paths are compared, not URLs: URLs for one folder can
    /// differ in whether they are marked as directories.
    static func == (lhs: StorageGeneration, rhs: StorageGeneration) -> Bool {
        lhs.number == rhs.number && lhs.root.path == rhs.root.path
    }
}

/// A kind of work that writes into the data directory, which a
/// data-directory move waits for, and names while it waits (TODO S04).
enum StorageWork: Sendable, CaseIterable {
    /// One import from the import queue, from choosing where its package
    /// goes to adding its book to the library.
    case importing
    /// Deleting recordings' original takes whose time is up, at launch and
    /// after each recording is saved (`RecordingTakeSweep`).
    case recordingTakes
    /// Writing a book's text cache: startup maintenance, Redo Text
    /// Extraction, or a reader rebuilding a stale cache.
    case textExtraction
    /// Analyzing a book for its statistics and index, in the background
    /// pass that follows the text caches.
    case contentAnalysis

    /// What a move's status line says while it waits for this work, as the
    /// screen shows it and VoiceOver reads it.
    var waitingMessage: String {
        switch self {
        case .importing:
            return "Waiting for the current import to finish..."
        case .recordingTakes:
            return "Waiting for old recording takes to be removed..."
        case .textExtraction:
            return "Waiting for text extraction to finish..."
        case .contentAnalysis:
            return "Waiting for book analysis to finish..."
        }
    }
}

/// What an operation holding the storage work is doing (#673), which an
/// operation refused meanwhile names (`StorageBusyError`), so the refusal
/// says what is actually happening rather than that a data-directory move
/// is under way, whatever holds the work.
enum StorageHoldReason: Sendable, CaseIterable {
    /// Moving the data directory: Change Location's Move Library Here, a
    /// location requested in config.json, or Reset to Default from a custom
    /// location.
    case movingDataDirectory
    /// Rebuild Directory, or Reset to Default where the library already is:
    /// misplaced packages are put back and unlisted ones adopted.
    case rebuildingDirectory
    /// A folder edit from the library's sheets moving its books' packages
    /// between folders (PERF14).
    case movingBooksBetweenFolders
    /// Use This Library, or Start New Library while the library isn't
    /// available: switching to the library in another folder, from the
    /// moment the switch begins until TextMouth has asked to open again on
    /// that library and quit (FR02).
    case switchingLibraries
}

/// The refusal of an operation that needs the storage work held while
/// another operation holds it (TODO S04, #673). Its description, which
/// Storage settings' status line, the library's error alert, and VoiceOver
/// give after the refused operation's own words, such as "Failed to move
/// directory: ", says what the other operation is doing.
struct StorageBusyError: LocalizedError, Equatable {
    /// What the operation holding the storage work is doing.
    let reason: StorageHoldReason

    var errorDescription: String? {
        switch reason {
        case .movingDataDirectory:
            return "TextMouth is already moving its data directory. Try again once that move is done."
        case .rebuildingDirectory:
            return "TextMouth is rebuilding its data directory. Try again when that finishes."
        case .movingBooksBetweenFolders:
            return "TextMouth is moving books between folders. Try again when that finishes."
        case .switchingLibraries:
            return "TextMouth is switching to another library and opening again on it."
        }
    }
}

/// Where the data directory is now, and the boundary between data-directory
/// moves and the work that writes into the data directory (TODO S04).
///
/// `TextMouthPaths.root` is the root of the current generation. A
/// data-directory move publishes the next generation (`publish(root:)`)
/// only once its copy is in place, and nothing else changes it, so two
/// reads of the root by one piece of work can differ only across a
/// published move. In the app the first generation is the location the
/// preferences name; a process hosting tests always starts in its sandbox,
/// and only a move a test publishes, into a folder of its own, takes it
/// elsewhere until the test puts it back.
///
/// Work that writes into the data directory runs through `perform(_:...)`,
/// which keeps it from running across a publication: a move holds new work
/// back (`holdWork(for:)`), waits for the work already under way, copies and
/// publishes, and then lets the held work go on under the new generation.
/// Rebuild Directory, a folder edit moving books between folders, and Use
/// This Library hold new work back the same way, each saying why
/// (`StorageHoldReason`), and only one operation holds it at a time.
///
/// `@unchecked Sendable`: every stored property is guarded by `condition`,
/// a lock never held while calling out, so nothing reached from here, such
/// as a log line naming a path in the data directory, can wait for it.
final class StorageBoundary: @unchecked Sendable {
    /// The boundary of this process, starting at the data directory its
    /// runtime names (`TextMouthPaths.root(for:)`).
    static let shared = StorageBoundary(root: TextMouthPaths.root(for: .current))

    /// Guards every stored property below.
    private let condition = NSCondition()
    /// The generation in use.
    private var generation: StorageGeneration
    /// Every earlier generation, oldest first, so a path captured under any
    /// of them can be moved under the current root.
    private var earlierGenerations: [StorageGeneration] = []
    /// The work under way on background threads, by ticket.
    private var workUnderWay: [Int: StorageWork] = [:]
    /// The ticket the next piece of work gets.
    private var nextTicket = 0
    /// How many pieces of work have finished, so a waiting move can tell
    /// whether any finished since it last looked.
    private var finishedWorkCount = 0
    /// Moves waiting for a piece of work to finish.
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the operation holding new work back is doing; nil while no
    /// operation holds it.
    private var holdReason: StorageHoldReason?
    /// The key of this boundary's work depth in each thread's dictionary:
    /// how deep that thread is inside work it is performing here.
    private let workDepthKey = "com.textmouth.storageWorkDepth.\(UUID().uuidString)"

    /// A boundary whose first generation is the data directory at `root`.
    init(root: URL) {
        generation = StorageGeneration(number: 0, root: root, location: DataDirectoryLocation(root))
    }

    // MARK: - Generations

    /// The generation in use now.
    var current: StorageGeneration {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    /// Makes the data directory at `root` the current one, as the next
    /// generation, and returns that generation. A data-directory move calls
    /// this once its copy is published (`TextMouthPaths.moveDataDirectory`);
    /// tests call it to put the data directory back where it was.
    @discardableResult
    func publish(root: URL) -> StorageGeneration {
        // Resolved before taking the lock: resolving reads the file system.
        let location = DataDirectoryLocation(root)
        condition.lock()
        defer { condition.unlock() }
        earlierGenerations.append(generation)
        generation = StorageGeneration(number: generation.number + 1, root: root, location: location)
        return generation
    }

    /// The current generation and the earlier ones, read together.
    private func generations() -> (current: StorageGeneration, earlier: [StorageGeneration]) {
        condition.lock()
        defer { condition.unlock() }
        return (generation, earlierGenerations)
    }

    // MARK: - Paths Captured Earlier

    /// `path` at its place under the current root, when it was captured
    /// under an earlier generation: a path inside an earlier generation's
    /// data directory, and not inside the current one, moves to the same
    /// place in the current one, taken from the most recent such
    /// generation. Any other path, and every path until a move has
    /// published, is returned as it is.
    ///
    /// Work that captured paths before a move published, such as a library
    /// snapshot waiting for its save or a book a batch queued, passes them
    /// through here before it reads or writes anything, so it never writes
    /// under the old root or recreates it (TODO S04).
    func rebasedToCurrent(_ path: String) -> String {
        let (current, earlier) = generations()
        return Self.rebase(path, to: current, from: earlier) ?? path
    }

    /// `book` with its file path at its place under the current root, when
    /// it was captured under an earlier generation (see
    /// `rebasedToCurrent(_:)` for a path). Nothing else about it changes:
    /// its package is named by its folder and package name, which do not
    /// depend on the root.
    func rebasedToCurrent(_ book: Book) -> Book {
        let (current, earlier) = generations()
        guard let moved = Self.rebase(book.filePath, to: current, from: earlier) else { return book }
        var rebased = book
        rebased.filePath = moved
        return rebased
    }

    /// Moves every book path in `library` captured under an earlier
    /// generation to its place under the current root (see
    /// `rebasedToCurrent(_:)` for a path).
    /// - Returns: How many books' paths moved.
    @discardableResult
    func rebaseToCurrent(_ library: inout Library) -> Int {
        let (current, earlier) = generations()
        var moved = 0
        for index in library.books.indices {
            if let path = Self.rebase(library.books[index].filePath, to: current, from: earlier) {
                library.books[index].filePath = path
                moved += 1
            }
        }
        return moved
    }

    /// `path` moved from the most recent of `earlier` that holds it to the
    /// same place under `current`, spelled as the migrator spells the books
    /// it moves; nil when `path` is inside `current`'s data directory or
    /// inside none of `earlier`.
    private static func rebase(
        _ path: String,
        to current: StorageGeneration,
        from earlier: [StorageGeneration]
    ) -> String? {
        guard !earlier.isEmpty, !current.location.contains(path) else { return nil }
        for generation in earlier.reversed() {
            if let moved = generation.location.relocating(path, to: current.location.named) {
                return moved
            }
        }
        return nil
    }

    // MARK: - Work

    /// Runs `body`, a piece of `work` that writes into the data directory,
    /// with the generation it runs under, and returns what it returns.
    ///
    /// While an operation holds work (`holdWork(for:)`), such as a
    /// data-directory move, work started on a background thread first tells
    /// `whileHeld`, then waits until the hold is released, as when the move
    /// publishes or gives up, and runs under the generation current then. A
    /// move waits for the work under way before it copies anything, so no
    /// piece of work runs across a publication.
    ///
    /// Two kinds of work run at once, unrecorded. Work on the main thread,
    /// where waiting would stall the very work a move waits for, such as an
    /// import adding its book to the library. A move copies and publishes
    /// on a background queue (`copyAndPublish`), not on the main actor, so
    /// nothing here keeps main-thread work from running across a
    /// publication: its callers must. Today they do. They are the startup
    /// repair and the migration of a legacy library index, which run as the
    /// library loads, and no move runs before the library has loaded or
    /// while its index is being recovered; and the legacy migration of
    /// Rebuild Directory and Reset to Default, which runs inside their own
    /// hold on storage work (`withStorageWorkHeld`), where no other move
    /// can begin. Main-thread work added later that writes into the data
    /// directory needs the same care, or belongs on a background thread.
    /// And work started inside other work on the same thread, such as the
    /// text extraction an import does: it is part of that work.
    func perform<Result>(
        _ work: StorageWork,
        whileHeld: (() -> Void)? = nil,
        _ body: (StorageGeneration) throws -> Result
    ) rethrows -> Result {
        if Thread.isMainThread || workDepth > 0 {
            return try body(current)
        }
        let (ticket, generation) = begin(work, whileHeld: whileHeld)
        workDepth += 1
        defer {
            workDepth -= 1
            finish(ticket)
        }
        return try body(generation)
    }

    /// How deep the current thread is inside work it performs here.
    private var workDepth: Int {
        get { Thread.current.threadDictionary[workDepthKey] as? Int ?? 0 }
        set { Thread.current.threadDictionary[workDepthKey] = newValue }
    }

    /// Records `work` as under way, once no operation holds work back, and
    /// returns its ticket and the generation it runs under. An operation
    /// holding work makes it tell `whileHeld`, outside the lock, and wait.
    private func begin(_ work: StorageWork, whileHeld: (() -> Void)?) -> (ticket: Int, generation: StorageGeneration) {
        condition.lock()
        if holdReason != nil, let whileHeld {
            condition.unlock()
            whileHeld()
            condition.lock()
        }
        while holdReason != nil {
            condition.wait()
        }
        let ticket = nextTicket
        nextTicket += 1
        workUnderWay[ticket] = work
        let generation = self.generation
        condition.unlock()
        return (ticket, generation)
    }

    /// Records the work `ticket` as finished, and resumes every move
    /// waiting for a piece of work to finish.
    private func finish(_ ticket: Int) {
        condition.lock()
        workUnderWay[ticket] = nil
        finishedWorkCount += 1
        let waiters = finishWaiters
        finishWaiters.removeAll()
        condition.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Holding Work

    /// Holds new work back for the operation `reason` names, such as a
    /// data-directory move, until the hold is released. The operation then
    /// waits for the work already under way
    /// (`StorageWorkHold.waitForWorkUnderWay`) before it changes anything,
    /// and releases the hold once it is done, or has given up.
    /// - Throws: `StorageBusyError` while another operation holds the work,
    ///   saying what that operation is doing (#673): only one holds it at a
    ///   time.
    func holdWork(for reason: StorageHoldReason) throws -> StorageWorkHold {
        condition.lock()
        defer { condition.unlock() }
        if let heldFor = holdReason {
            throw StorageBusyError(reason: heldFor)
        }
        holdReason = reason
        return StorageWorkHold(boundary: self)
    }

    /// Lets the held work go on, under the generation current now.
    fileprivate func releaseWork() {
        condition.lock()
        holdReason = nil
        condition.broadcast()
        condition.unlock()
    }

    /// The first kind of work under way, in the order of
    /// `StorageWork.allCases`, with how many pieces had finished when it
    /// looked; nil when no work is under way.
    fileprivate func firstWorkUnderWay() -> (work: StorageWork, finished: Int)? {
        condition.lock()
        defer { condition.unlock() }
        let kinds = Set(workUnderWay.values)
        guard let first = StorageWork.allCases.first(where: kinds.contains) else { return nil }
        return (first, finishedWorkCount)
    }

    /// Returns once a piece of work finishes after `seen` pieces had, or at
    /// once when one already has.
    fileprivate func workFinished(after seen: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            guard finishedWorkCount == seen else {
                condition.unlock()
                continuation.resume()
                return
            }
            finishWaiters.append(continuation)
            condition.unlock()
        }
    }
}

/// An operation's hold on the work that writes into the data directory
/// (TODO S04): a data-directory move's, Rebuild Directory's, or a folder
/// edit's (`StorageHoldReason`). While it lasts, new work started on a
/// background thread waits (`StorageBoundary.perform`);
/// `waitForWorkUnderWay` waits for the work already running. Releasing it
/// lets the held work go on, under whatever generation is current then.
///
/// `@unchecked Sendable`: its one variable is guarded by `lock`.
final class StorageWorkHold: @unchecked Sendable {
    /// The boundary whose work is held.
    private let boundary: StorageBoundary
    /// Guards `isReleased`.
    private let lock = NSLock()
    /// Whether the hold was released.
    private var isReleased = false

    /// A hold on `boundary`'s work, which `StorageBoundary.holdWork(for:)` makes.
    fileprivate init(boundary: StorageBoundary) {
        self.boundary = boundary
    }

    /// A hold that is never released explicitly still lets the work go on.
    deinit {
        release()
    }

    /// Returns once no work is under way, telling `report` each kind of
    /// work it waits for, in turn: an import first when several kinds are
    /// under way. Work started meanwhile is held, so the wait ends. `report`
    /// is awaited, so a status line can be drawn before the wait goes on.
    @MainActor
    func waitForWorkUnderWay(reporting report: (StorageWork) async -> Void) async {
        var reported: StorageWork?
        while let underWay = boundary.firstWorkUnderWay() {
            if underWay.work != reported {
                await report(underWay.work)
                reported = underWay.work
            }
            await boundary.workFinished(after: underWay.finished)
        }
    }

    /// Lets the held work go on. Releasing a hold again does nothing.
    func release() {
        lock.lock()
        let wasReleased = isReleased
        isReleased = true
        lock.unlock()
        if !wasReleased {
            boundary.releaseWork()
        }
    }
}
