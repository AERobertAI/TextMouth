import Combine
import Foundation
import os

// MARK: - Preparing Ahead of a Search

/// Prepares Search Library's search texts ahead of the first search, in the
/// background (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 2). The store
/// is keyed on the build (`LibrarySearchTextStore.currentProducer`), so each
/// installation of a new build, and macOS emptying the Caches folder, leave
/// every book to be prepared again; without this, the first search did it,
/// in 8.7 seconds on the user's library against 0.2 to 1.2 once prepared.
///
/// - **What a book costs.** A book whose text the store holds as its
///   content.md is now costs what `LibrarySearchTextStore.lookUp(_:fileAccess:)`
///   costs: a look for the cloud, a stat, and the header of its file. Any
///   other is parsed and kept, as a search would
///   (`LibrarySearchTextStore.prepare(_:key:fileAccess:gate:isCancelled:)`).
/// - **Gently.** Two books at a time (`laneCount`), at background priority
///   (efficiency cores, throttled reads), with at most 16 MB of content.md
///   being parsed at once (`preparingBudget`, half a search's), so its
///   memory stays near a search's. A book in the cloud is never read, so
///   nothing is downloaded, and a disk with no room for another text ends
///   the pass before it parses a book it could not keep.
/// - **Out of the way of a search.** A search pauses it (`pause()`,
///   `resume()`) and it yields at once: no book is begun while paused, and a
///   book waiting its turn at the gate, or read and not yet parsed, stops
///   there and is prepared later. Only a parse already under way, which
///   cannot be stopped, runs to its end. Low Power Mode ends a pass.
/// - **Raised** while the Search Library window is open
///   (`setPriority(.raised)`): the next books are prepared at user-initiated
///   priority, since a search is likely soon.
/// - **Sweeps** after a pass that looked at every book, keeping their texts
///   (`LibrarySearchTextStore.removeFiles(notFor:)`).
///
/// When a pass starts, and what stops it, is the app's to say
/// (`LibrarySearchPreparation`). Everything here is safe from any thread.
final class LibrarySearchPreparer: Sendable {

    // MARK: Progress and Endings

    /// What a pass has done, book by book.
    struct Progress: Equatable, Sendable {
        /// The books the pass was given.
        var booksGiven = 0
        /// The books whose text the store already held as their content.md
        /// is now: a stat and a header read each.
        var booksAlreadyPrepared = 0
        /// The books parsed and kept.
        var booksPrepared = 0
        /// The books not read because they are only in the cloud.
        var booksInCloud = 0
        /// The books without a content.md.
        var booksWithoutText = 0
        /// The books whose content.md could not be read.
        var booksUnreadable = 0

        /// The books the pass is done with.
        var booksDone: Int {
            booksAlreadyPrepared + booksPrepared + booksInCloud + booksWithoutText + booksUnreadable
        }
    }

    /// How a pass ended.
    enum Ending: String, Equatable, Sendable {
        /// Every book was looked at, and the store swept.
        case finished
        /// Low Power Mode came on.
        case lowPowerMode
        /// The disk had no room for another text.
        case noRoom
    }

    /// What a pass that ended did, and how long it took.
    struct PassReport: Equatable, Sendable {
        let progress: Progress
        let ending: Ending
        /// From the pass's start to its end, in seconds.
        let seconds: TimeInterval
    }

    /// The priority books are prepared at.
    enum Priority: Equatable, Sendable {
        /// Below everything the user waits for.
        case background
        /// While the Search Library window is open, a search being likely.
        case raised

        /// Dispatch's quality of service for the priority.
        var qos: DispatchQoS.QoSClass {
            self == .background ? .background : .userInitiated
        }
    }

    // MARK: The Preparer

    /// The app's preparer, for the app's store.
    static let shared = LibrarySearchPreparer(store: .shared)

    /// The most content.md bytes being parsed at once: 16 MB, half a
    /// search's (`LibrarySearchEngine.preparingBudget`), since parsing takes
    /// 5 to 22 times its text while it runs; one larger book is parsed alone.
    static let preparingBudget = 16 * 1_048_576

    /// How many books are prepared at once.
    static let laneCount = 2

    /// The store prepared.
    private let store: LibrarySearchTextStore
    /// How books' files are reached: `live` in the app, a fake in tests.
    private let fileAccess: MaintenanceFileAccess
    /// The gate the lanes share, across passes, so a pass begun while an
    /// older one's parse ends still keeps to the budget.
    private let gate: LibrarySearchPreparingGate
    /// How many books are prepared at once.
    private let laneCount: Int
    /// Whether Low Power Mode is on, asked before each book.
    private let isLowPowerMode: @Sendable () -> Bool
    /// Told, on a lane's thread, how each pass that ended went.
    private let onPassEnded: @Sendable (PassReport) -> Void
    /// The pass under way, or the last one, under its lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A preparer of `store`, preparing `lanes` books at once with at most
    /// `budget` bytes of content.md being parsed, and telling `onPassEnded`
    /// how each pass ended. The app's is `shared`; tests make their own.
    init(
        store: LibrarySearchTextStore,
        fileAccess: MaintenanceFileAccess = .live,
        budget: Int = LibrarySearchPreparer.preparingBudget,
        lanes: Int = LibrarySearchPreparer.laneCount,
        isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        onPassEnded: @escaping @Sendable (PassReport) -> Void = LibrarySearchPreparer.logPassEnded
    ) {
        self.store = store
        self.fileAccess = fileAccess
        gate = LibrarySearchPreparingGate(budget: budget)
        laneCount = max(1, lanes)
        self.isLowPowerMode = isLowPowerMode
        self.onPassEnded = onPassEnded
    }

    /// Notes in the diagnostic log how a pass ended: its counts and seconds,
    /// never a title.
    static let logPassEnded: @Sendable (PassReport) -> Void = { report in
        let progress = report.progress
        DiagnosticLog.event(
            .storage,
            "LIBRARY_SEARCH_PREPARATION: \(report.ending.rawValue) given=\(progress.booksGiven) "
                + "alreadyPrepared=\(progress.booksAlreadyPrepared) prepared=\(progress.booksPrepared) "
                + "inCloud=\(progress.booksInCloud) withoutText=\(progress.booksWithoutText) "
                + "unreadable=\(progress.booksUnreadable) seconds=\(String(format: "%.1f", report.seconds))"
        )
    }

    // MARK: Starting, Stopping, Pausing

    /// Starts a pass over `books`, in place of any pass under way, which
    /// stops at its next step. Nothing starts for an empty library or in Low
    /// Power Mode; while a search pauses the preparer, the pass waits for
    /// the search to end.
    func start(_ books: [LibrarySearchBook]) {
        let lowPowerMode = isLowPowerMode()
        let launch = state.withLock { state -> Launch? in
            state.begin(books, isAllowed: !lowPowerMode)
            return state.claimLanes(upTo: laneCount)
        }
        run(launch)
    }

    /// Stops the pass under way, if any, at its next step: a book being
    /// parsed is still kept, and nothing more is begun.
    func stop() {
        state.withLock { $0.end() }
    }

    /// Holds the pass while a search runs: no book is begun until
    /// `resume()`, and a book waiting its turn, or read and not yet parsed,
    /// stops where it is, to be prepared once the pass goes on. Each
    /// `pause()` takes its own `resume()`.
    func pause() {
        state.withLock { $0.pauses += 1 }
    }

    /// Ends one `pause()`; once none is left, the pass goes on.
    func resume() {
        let launch = state.withLock { state -> Launch? in
            state.pauses = max(0, state.pauses - 1)
            return state.claimLanes(upTo: laneCount)
        }
        run(launch)
    }

    /// Prepares the next books at `priority`.
    func setPriority(_ priority: Priority) {
        state.withLock { $0.priority = priority }
    }

    /// What the pass under way, or the last one, has done.
    var progress: Progress {
        state.withLock { $0.progress }
    }

    /// Whether a pass is under way, paused or not.
    var isRunning: Bool {
        state.withLock { $0.isActive }
    }

    /// Whether a search pauses the preparer now.
    var isPaused: Bool {
        state.withLock { $0.pauses > 0 }
    }

    /// The priority the next books are prepared at.
    var priority: Priority {
        state.withLock { $0.priority }
    }

    // MARK: The Lanes

    /// Lanes to start: `count` of them, for pass `pass`, at `qos`.
    fileprivate struct Launch: Sendable {
        let pass: Int
        let count: Int
        let qos: DispatchQoS.QoSClass
    }

    /// Starts the lanes `launch` names, if any.
    private func run(_ launch: Launch?) {
        guard let launch else { return }
        for _ in 0..<launch.count {
            dispatchStep(pass: launch.pass, qos: launch.qos)
        }
    }

    /// Runs a step of a lane of pass `pass` on a global queue, at exactly
    /// `qos`: enforced, so a pass started from the main thread never runs at
    /// the main thread's priority, which Dispatch would otherwise carry into
    /// the block.
    private func dispatchStep(pass: Int, qos: DispatchQoS.QoSClass) {
        DispatchQueue.global(qos: qos).async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
            self.step(pass: pass)
        }
    }

    /// One step of a lane of pass `pass`: its next book, prepared, then the
    /// next step, on a thread of the priority asked for by then; or the
    /// lane's end, and the pass's when it was the last lane and no book is
    /// left, or when Low Power Mode came on or the disk filled.
    private func step(pass: Int) {
        let lowPowerMode = isLowPowerMode()
        let next = state.withLock { $0.nextBook(for: pass, lowPowerMode: lowPowerMode) }
        switch next {
        case .stop:
            return
        case .ended(let report):
            end(report)
        case .book(let book):
            let outcome = prepare(book, pass: pass)
            let after = state.withLock { $0.record(outcome, of: book, in: pass) }
            switch after {
            case .ended(let report):
                end(report)
            case .stop, .book:
                dispatchStep(pass: pass, qos: state.withLock { $0.priority.qos })
            }
        }
    }

    /// Prepares `book` for pass `pass`: nothing when the store holds its
    /// text as its content.md is now, or it is in the cloud or has no text;
    /// otherwise, when the disk has room, a parse kept in the store. Yields,
    /// preparing nothing, when the pass is paused, stopped, or replaced
    /// while the book waits its turn or before its parse.
    private func prepare(_ book: LibrarySearchBook, pass: Int) -> Outcome {
        switch store.lookUp(book, fileAccess: fileAccess) {
        case .inCloud:
            return .inCloud
        case .withoutText:
            return .withoutText
        case .stored(let file, _):
            file.close()
            return .alreadyPrepared
        case .unprepared(let key):
            guard store.hasRoom(forAbout: key.content.byteCount) else { return .noRoom }
            let prepared = store.prepare(book, key: key, fileAccess: fileAccess, gate: gate) {
                self.state.withLock { $0.shouldYield(pass) }
            }
            switch prepared {
            case .prepared:
                return .prepared
            case .inCloud:
                return .inCloud
            case .unreadable:
                return .unreadable
            case .cancelled:
                return .yielded
            }
        }
    }

    /// Sweeps the store after a pass that finished, keeping the texts of
    /// its books, then says how the pass went.
    private func end(_ ended: EndedPass) {
        if let bookIDs = ended.bookIDs {
            store.removeFiles(notFor: bookIDs)
        }
        onPassEnded(PassReport(progress: ended.progress, ending: ended.ending, seconds: ended.seconds))
    }
}

// MARK: - When the App Prepares

/// When TextMouth prepares Search Library's texts in the background
/// (`LibrarySearchPreparer`), and what holds the preparation back
/// (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 2):
/// - a pass starts once the library's startup maintenance has ended
///   (`libraryIsReady(books:moves:)`), so it never competes with the passes
///   that rebuild books' texts at launch, and again when the Search Library
///   window opens with no pass under way, which costs a stat and a header
///   read a book when nothing changed;
/// - the window raises the pass's priority while it is open, and searches
///   pause it while they run (`LibrarySearchModel.engineRunner(store:preparer:)`);
/// - no pass runs in Low Power Mode or while the data directory moves: each
///   stops a pass under way, and a pass starts afresh once it is over.
///
/// The app's (`shared`) prepares only in the Mac app, never in a process
/// hosting tests, whose tests make their own, nor on the iPhone, which has
/// no Search Library yet.
@MainActor
final class LibrarySearchPreparation {
    /// The app's.
    static let shared = LibrarySearchPreparation(preparer: .shared, isEnabled: preparesInThisProcess)

    /// Whether this process prepares Search Library's texts: the Mac app's,
    /// unless it hosts tests.
    nonisolated static var preparesInThisProcess: Bool {
        #if os(macOS)
        return !TextMouthRuntime.current.isHostedTest
        #else
        return false
        #endif
    }

    /// The preparer this one starts and stops.
    private let preparer: LibrarySearchPreparer
    /// Whether this one prepares at all.
    private let isEnabled: Bool
    /// Whether Low Power Mode is on.
    private let isLowPowerMode: @Sendable () -> Bool
    /// Where the system says the power state changed.
    private let notificationCenter: NotificationCenter
    /// The library's searchable books, once the library is ready; nil before.
    private var books: (@MainActor () -> [LibrarySearchBook])?
    /// Whether the data directory is moving now.
    private(set) var isLibraryMoving = false
    /// The data directory's moves, heard once the library is ready.
    private var moveObservation: AnyCancellable?
    /// The power state's changes, heard once the library is ready. The app's
    /// coordinator lives as long as the app; a test's goes with the test's
    /// own notification center.
    private var powerObservation: NSObjectProtocol?

    /// A coordinator of `preparer`, preparing when `isEnabled`, reading Low
    /// Power Mode with `isLowPowerMode` and hearing it change on
    /// `notificationCenter`. The app's is `shared`; tests make their own.
    init(
        preparer: LibrarySearchPreparer,
        isEnabled: Bool,
        isLowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        notificationCenter: NotificationCenter = .default
    ) {
        self.preparer = preparer
        self.isEnabled = isEnabled
        self.isLowPowerMode = isLowPowerMode
        self.notificationCenter = notificationCenter
    }

    /// The library's startup maintenance has ended: its books, as `books`
    /// lists them each time, are prepared from now on, the first pass
    /// starting now, and `moves` says when the data directory starts and
    /// stops moving. Only the first call counts.
    func libraryIsReady(books: @escaping @MainActor () -> [LibrarySearchBook], moves: AnyPublisher<Bool, Never>) {
        guard isEnabled, self.books == nil else { return }
        self.books = books
        // The library publishes its move on the main actor, where this one
        // hears it.
        moveObservation = moves
            .removeDuplicates()
            .sink { [weak self] isMoving in self?.libraryMoving(isMoving) }
        powerObservation = notificationCenter.addObserver(
            forName: ProcessInfo.powerStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerStateChanged() }
        }
        startPass()
    }

    /// The Search Library window opened: the books are prepared at a raised
    /// priority while it is open, a search being likely soon, and a pass
    /// starts if none is under way, to prepare what changed since the last.
    func searchWindowOpened() {
        preparer.setPriority(.raised)
        if !preparer.isRunning {
            startPass()
        }
    }

    /// The Search Library window closed: the books are prepared in the
    /// background again.
    func searchWindowClosed() {
        preparer.setPriority(.background)
    }

    /// The data directory started or stopped moving: a move stops the pass,
    /// whose books are about to be elsewhere, and once it is over a pass
    /// starts afresh, with the books where they are now. A value that
    /// changes nothing, as the library's publisher sends its current one on
    /// subscription, does nothing.
    private func libraryMoving(_ isMoving: Bool) {
        guard isMoving != isLibraryMoving else { return }
        isLibraryMoving = isMoving
        if isMoving {
            preparer.stop()
        } else {
            startPass()
        }
    }

    /// Low Power Mode came on or went off: on, it stops the pass; off, a pass
    /// starts afresh.
    private func powerStateChanged() {
        if isLowPowerMode() {
            preparer.stop()
        } else if !preparer.isRunning {
            startPass()
        }
    }

    /// Starts a pass over the library's books, unless the library is not
    /// ready, the data directory moves, or Low Power Mode is on.
    private func startPass() {
        guard isEnabled, let books, !isLibraryMoving, !isLowPowerMode() else { return }
        preparer.start(books())
    }
}

// MARK: - A Pass's State

/// What happened to one book of a pass.
private enum Outcome: Sendable {
    case alreadyPrepared, prepared, inCloud, withoutText, unreadable
    /// The pass was paused, stopped, or replaced before the book was parsed.
    case yielded
    /// The disk has no room for the book's text.
    case noRoom
}

/// A pass that ended: how, with what, and, when it finished, the books
/// whose texts the sweep keeps.
private struct EndedPass: Sendable {
    let progress: LibrarySearchPreparer.Progress
    let ending: LibrarySearchPreparer.Ending
    let seconds: TimeInterval
    let bookIDs: Set<UUID>?
}

/// What a lane does next.
private enum NextStep: Sendable {
    /// Prepare this book.
    case book(LibrarySearchBook)
    /// End the lane; the pass goes on in its other lanes, or later.
    case stop
    /// End the lane and, with it, the pass.
    case ended(EndedPass)
}

/// The pass under way, or the last one: every decision about it is made
/// here, under the preparer's lock.
private struct State: Sendable {
    /// The pass's number. A pass begun or stopped raises it, so the lanes of
    /// an older pass end at their next step.
    var pass = 0
    /// Whether a pass is under way.
    var isActive = false
    /// The books not yet begun, the next one last.
    var pending: [LibrarySearchBook] = []
    /// Every book of the pass, whose texts the sweep keeps.
    var bookIDs: Set<UUID> = []
    /// What the pass has done.
    var progress = LibrarySearchPreparer.Progress()
    /// When the pass began.
    var startedAt = Date()
    /// The pass's lanes running now.
    var lanes = 0
    /// The searches pausing the preparer.
    var pauses = 0
    /// The priority the next books are prepared at.
    var priority: LibrarySearchPreparer.Priority = .background

    /// Begins a pass over `books`, in place of any other, when it
    /// `isAllowed` and there is a book to prepare.
    mutating func begin(_ books: [LibrarySearchBook], isAllowed: Bool) {
        pass += 1
        isActive = isAllowed && !books.isEmpty
        pending = isActive ? books.reversed() : []
        bookIDs = Set(books.map(\.id))
        progress = LibrarySearchPreparer.Progress(booksGiven: books.count)
        startedAt = Date()
        lanes = 0
    }

    /// Ends the pass under way, if any, so its lanes end at their next step.
    mutating func end() {
        pass += 1
        isActive = false
        pending = []
        lanes = 0
    }

    /// The lanes to start now for the pass under way: up to `limit` running
    /// in all and one for each book left; none while paused.
    mutating func claimLanes(upTo limit: Int) -> LibrarySearchPreparer.Launch? {
        guard isActive, pauses == 0 else { return nil }
        let count = min(limit - lanes, pending.count)
        guard count > 0 else { return nil }
        lanes += count
        return LibrarySearchPreparer.Launch(pass: pass, count: count, qos: priority.qos)
    }

    /// Whether work for pass `pass` should stop where it is: the pass was
    /// stopped or replaced, or a search pauses the preparer.
    func shouldYield(_ pass: Int) -> Bool {
        pass != self.pass || !isActive || pauses > 0
    }

    /// What a lane of pass `pass` does next. A lane of a pass stopped or
    /// replaced just ends. Low Power Mode ends the pass. With no book left,
    /// the lane ends, and the pass with the last lane, even while a search
    /// pauses it; with books left, a pause ends the lane, which `resume()`
    /// starts again.
    mutating func nextBook(for pass: Int, lowPowerMode: Bool) -> NextStep {
        guard pass == self.pass, isActive else { return .stop }
        if lowPowerMode {
            return .ended(close(.lowPowerMode))
        }
        if pending.isEmpty {
            lanes -= 1
            return lanes > 0 ? .stop : .ended(close(.finished))
        }
        if pauses > 0 {
            lanes -= 1
            return .stop
        }
        return .book(pending.removeLast())
    }

    /// Counts `outcome`, what became of `book` in pass `pass`, while that
    /// pass is under way: a book that yielded waits to be begun again, and a
    /// disk with no room ends the pass.
    mutating func record(_ outcome: Outcome, of book: LibrarySearchBook, in pass: Int) -> NextStep {
        guard pass == self.pass, isActive else { return .stop }
        switch outcome {
        case .alreadyPrepared:
            progress.booksAlreadyPrepared += 1
        case .prepared:
            progress.booksPrepared += 1
        case .inCloud:
            progress.booksInCloud += 1
        case .withoutText:
            progress.booksWithoutText += 1
        case .unreadable:
            progress.booksUnreadable += 1
        case .yielded:
            pending.append(book)
        case .noRoom:
            return .ended(close(.noRoom))
        }
        return .stop
    }

    /// Ends the pass under way as `ending`, and what it did.
    private mutating func close(_ ending: LibrarySearchPreparer.Ending) -> EndedPass {
        let ended = EndedPass(
            progress: progress,
            ending: ending,
            seconds: Date().timeIntervalSince(startedAt),
            bookIDs: ending == .finished ? bookIDs : nil
        )
        end()
        return ended
    }
}
