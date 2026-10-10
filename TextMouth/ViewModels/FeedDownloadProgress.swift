import Combine
import Foundation

// MARK: - How a Download Ended (FR10)

/// How a feed download that was under way ended, as the downloads' progress
/// counts it (FR10).
enum FeedDownloadEnding: Equatable, Sendable {
    /// Its book is in the library: it is done.
    case downloaded
    /// It failed, its item's row saying why: it is done too.
    case failed
    /// The newest-N rule's download was put off, for a network without data
    /// limits or for room (FR11): it leaves the run, and is counted with the
    /// downloads waiting apart.
    case waiting
    /// It stopped before its end, as Cancel Download stops one, or its item
    /// went: it leaves the run.
    case stopped

    /// Whether the download counts among the run's downloads done.
    var isDone: Bool {
        self == .downloaded || self == .failed
    }
}

// MARK: - What the Section Shows (FR10)

/// What the Library window's feed downloads section shows at one moment
/// (FR10): the run of downloads under way, from the moment the download
/// manager had work until it had none, its downloads done of the total
/// (those done, the one under way, and those waiting to start), the one
/// under way with how far its file has come, the time left once a download
/// has finished, and the newest-N rule's downloads waiting apart, by their
/// reason, which outlast the run.
struct FeedDownloadProgressState: Equatable {
    /// The download under way.
    struct Download: Equatable {
        /// Its item's title.
        let title: String
        /// Its feed's title.
        let feedTitle: String
        /// When it began.
        let startedAt: Date
        /// How far its file has come, in bytes, against the size the server
        /// gives, or its feed's estimate until then; nil for an article,
        /// whose page comes without a count of its bytes.
        var transfer: BookDownloadProgress?
        /// Whether its file has come, or its article's page has been read,
        /// and its book is being added to the library.
        var isAddingToLibrary = false

        /// What it is doing, as its line says after its name: "40% of 63
        /// MB", "adding it to the library", or nothing yet.
        var activity: String? {
            if isAddingToLibrary {
                return FeedDownloadProgressWording.addingToLibrary
            }
            return transfer.flatMap(FeedDownloadProgressWording.transfer)
        }

        /// The bytes it has still to bring, when its size is known: none
        /// once its book is being added to the library.
        var bytesLeft: Int64? {
            if isAddingToLibrary {
                return 0
            }
            guard let transfer, transfer.totalBytes > 0 else { return nil }
            return max(0, transfer.totalBytes - transfer.completedBytes)
        }

        /// How far it has got, from 0 to 1: its file's fraction, whole once
        /// its book is being added; 0 for an article until then.
        var fractionDone: Double {
            isAddingToLibrary ? 1 : (transfer?.fractionCompleted ?? 0)
        }
    }

    /// The run's downloads that ended, downloaded or failed.
    private(set) var done = 0
    /// Of those, the ones that failed.
    private(set) var failed = 0
    /// The download under way, while one is.
    private(set) var download: Download?
    /// The downloads waiting to start, in order, each by its size as its
    /// feed gives it, or nil when unknown.
    private(set) var queued: [Int64?] = []
    /// The newest-N rule's downloads waiting apart, which outlast the run.
    private(set) var waits = FeedDownloadWaits()
    /// What the run's finished downloads took, which the time left is
    /// estimated from (`TimeLeftEstimate`).
    private(set) var timing = WorkTiming()
    /// When the run began; nil while none runs.
    private(set) var runStartedAt: Date?
    /// Whether Cancel was pressed during the run.
    private(set) var isCancelling = false

    /// Whether downloads run: one is under way, or waits to start. The
    /// section shows only then.
    var isRunning: Bool {
        download != nil || !queued.isEmpty
    }

    /// The run's downloads: those done, the one under way, and those
    /// waiting to start.
    var total: Int {
        done + (download == nil ? 0 : 1) + queued.count
    }

    /// How far the run has got, from 0 to 1, as the section's bar shows it:
    /// the downloads done, and the one under way by its file's bytes.
    var fractionDone: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(done) + (download?.fractionDone ?? 0)) / Double(total))
    }

    // MARK: Changes

    /// Takes the downloads waiting to start, by their sizes, and those
    /// waiting apart.
    mutating func setQueue(_ queued: [Int64?], waits: FeedDownloadWaits) {
        self.queued = queued
        self.waits = waits
    }

    /// The download `download` began. One beginning after Cancel, as one the
    /// listener asked for while the download Cancel let finish was still
    /// being added, ends the cancelling: the section stops saying
    /// "Cancelling..." and offers Cancel again (feed review item 13).
    mutating func begin(_ download: Download) {
        self.download = download
        isCancelling = false
    }

    /// The file of the download under way has come as far as `transfer`
    /// says, unless its book is already being added to the library, which a
    /// late report of its bytes must not undo.
    mutating func receive(_ transfer: BookDownloadProgress) {
        guard download?.isAddingToLibrary == false else { return }
        download?.transfer = transfer
    }

    /// The book of the download under way is being added to the library.
    mutating func beginAddingToLibrary() {
        download?.isAddingToLibrary = true
    }

    /// The download under way ended as `ending`, at `date`: one downloaded
    /// is done and timed, from its start to its book in the library; one
    /// that failed is done, untimed; any other leaves the run.
    mutating func end(_ ending: FeedDownloadEnding, at date: Date) {
        guard let ended = download else { return }
        download = nil
        switch ending {
        case .downloaded:
            done += 1
            timing.add(seconds: date.timeIntervalSince(ended.startedAt), bytes: ended.transfer?.completedBytes ?? 0)
        case .failed:
            done += 1
            failed += 1
        case .waiting, .stopped:
            break
        }
    }

    /// Notes that Cancel was pressed while downloads run: the section says
    /// so in place of the time left.
    mutating func cancel() {
        guard isRunning else { return }
        isCancelling = true
    }

    /// Notes that a run began at `date`.
    mutating func startRun(at date: Date) {
        runStartedAt = date
    }

    /// Forgets the run that ended, keeping the downloads waiting apart.
    mutating func resetRun() {
        done = 0
        failed = 0
        download = nil
        queued = []
        timing = WorkTiming()
        runStartedAt = nil
        isCancelling = false
    }

    // MARK: What It Says

    /// The seconds the run has left at `now`, once a download has finished
    /// (`TimeLeftEstimate`); nil before then, with nothing left, and
    /// once Cancel is pressed.
    func secondsLeft(at now: Date) -> TimeInterval? {
        guard !isCancelling else { return nil }
        var remaining: [TimeLeftEstimate.Remaining] = []
        if let download {
            remaining.append(.init(bytes: download.bytesLeft, elapsed: now.timeIntervalSince(download.startedAt)))
        }
        remaining += queued.map { TimeLeftEstimate.Remaining(bytes: $0) }
        return TimeLeftEstimate.secondsLeft(after: timing, for: remaining)
    }

    /// The lines the section shows at `now` under its title and bar, in
    /// order: the downloads done of the total, the download under way, the
    /// time left or that Cancel was pressed, and the downloads waiting
    /// apart; none while no download runs.
    func lines(at now: Date) -> [String] {
        guard isRunning else { return [] }
        var lines = [FeedDownloadProgressWording.count(done: done, of: total, failed: failed)]
        if let download {
            lines.append(FeedDownloadProgressWording.item(
                download.title,
                feed: download.feedTitle,
                number: done + 1,
                of: total,
                doing: download.activity
            ))
        }
        if isCancelling {
            lines.append(FeedDownloadProgressWording.cancelling)
        } else if let secondsLeft = secondsLeft(at: now) {
            lines.append(ImportProgressWording.timeLeft(secondsLeft))
        }
        return lines + FeedDownloadProgressWording.waits(waits)
    }

    /// What VoiceOver reads for the section at `now`: its title and every
    /// line it shows.
    func spokenStatus(at now: Date) -> String {
        FeedDownloadProgressWording.spokenStatus(lines(at: now))
    }
}

// MARK: - The Downloads' Progress (FR10)

/// The progress of the feed downloads under way, as the Library window's
/// feed downloads section shows it (FR10's feed half).
///
/// It is an object of its own, which only that section observes, as the
/// imports' progress is (`ImportProgress`, PERF12): a download reports its
/// bytes many times a second, and each report written into its feed's
/// record would compare the whole record twice and redraw the Library
/// windows' feed rows (board #1410). The download manager owns one and
/// tells it everything on the main actor. A download's bytes change the
/// state without publishing it (`receive(_:)`): the section reads them as
/// it shows itself anew every few seconds; whatever else changes publishes
/// it.
///
/// VoiceOver hears a run that lasts without having to find the section, by
/// the import overlay's rules: each quarter of the run's downloads, once,
/// at medium priority, and how the run ended, only once it has run for
/// `announcedAfter`, and never after Cancel; and, at once, what Cancel
/// stopped.
@MainActor
final class FeedDownloadProgress: ObservableObject {
    /// How long a run must have lasted before VoiceOver hears its quarters
    /// and its end unasked: the import overlay's 10 seconds.
    static let announcedAfter = ImportProgress.announcedAfter

    /// What the section shows now. Not `@Published`: each change publishes
    /// by hand (`change(publishing:_:)`), save a download's bytes.
    private(set) var state = FeedDownloadProgressState()
    /// Tells the time: the system's clock in the app, a test's own clock in
    /// a test.
    private let now: @MainActor () -> Date
    /// The highest quarter of the run's downloads reached so far, 1 for the
    /// first: each is announced once, or passes silently while the run is
    /// still short.
    private var quarterReached = 0
    /// The run's last download done, by its title, and whether it failed,
    /// which the end of a run of one names.
    private var lastDone: (title: String, failed: Bool)?

    /// Progress timed by `now`: the system's clock unless a test passes its
    /// own.
    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: What the Manager Tells It

    /// The downloads waiting to start are now `queued`, each by its size as
    /// its feed gives it, and those waiting apart `waits`.
    func update(queued: [Int64?], waits: FeedDownloadWaits) {
        change { $0.setQueue(queued, waits: waits) }
    }

    /// The download of the item titled `title`, of the feed titled
    /// `feedTitle`, began, its file at `transfer` (nil for an article),
    /// leaving `queued` waiting to start and `waits` waiting apart.
    func begin(title: String, feedTitle: String, transfer: BookDownloadProgress?, queued: [Int64?], waits: FeedDownloadWaits) {
        let download = FeedDownloadProgressState.Download(title: title, feedTitle: feedTitle, startedAt: now(), transfer: transfer)
        change { state in
            state.begin(download)
            state.setQueue(queued, waits: waits)
        }
    }

    /// The file of the download under way has come as far as `transfer`
    /// says: kept without publishing, so a download's many reports of its
    /// bytes redraw nothing; the section reads them as it shows itself anew.
    func receive(_ transfer: BookDownloadProgress) {
        change(publishing: false) { $0.receive(transfer) }
    }

    /// The book of the download under way is being added to the library.
    func beginAddingToLibrary() {
        change { $0.beginAddingToLibrary() }
    }

    /// The download under way ended as `ending`, leaving `queued` waiting to
    /// start and `waits` waiting apart. One done that takes the run past a
    /// quarter of its downloads is announced; the run's last ends the run.
    func end(_ ending: FeedDownloadEnding, queued: [Int64?], waits: FeedDownloadWaits) {
        let date = now()
        if ending.isDone, let ended = state.download {
            lastDone = (ended.title, ending == .failed)
        }
        change { state in
            state.end(ending, at: date)
            state.setQueue(queued, waits: waits)
        }
        if ending.isDone {
            announceQuarter(at: date)
        }
    }

    /// Notes that Cancel stopped the downloads titled `stopped`, and that
    /// the download titled `finishing`, if any, finishes all the same, its
    /// book already being added to the library; VoiceOver hears it at once,
    /// with the downloads left waiting apart. The run then ends without
    /// announcing its end.
    func cancel(stopped: [String], finishing: String?) {
        change { $0.cancel() }
        VoiceOverAnnouncer.announce(FeedDownloadProgressWording.cancelled(stopped: stopped, finishing: finishing, waits: state.waits))
    }

    /// Shows nothing more, and says nothing: TextMouth quits, and each
    /// download keeps its place for the next launch.
    func clear() {
        quarterReached = 0
        lastDone = nil
        guard state != FeedDownloadProgressState() else { return }
        objectWillChange.send()
        state = FeedDownloadProgressState()
    }

    // MARK: What It Says

    /// What Speak Download Progress says now: every line the section shows
    /// while downloads run; otherwise that none is under way, with the
    /// downloads waiting apart.
    func spokenStatus() -> String {
        guard state.isRunning else {
            return FeedDownloadProgressWording.noneUnderWay(waits: state.waits)
        }
        return state.spokenStatus(at: now())
    }

    // MARK: Changing

    /// Changes the state with `body`, publishing the change when
    /// `publishing` and anything changed. A change that gives downloads to
    /// run while none ran begins a run; one that leaves none to run ends it,
    /// announcing how it ended when it ran long and Cancel was not pressed,
    /// and forgets it.
    private func change(publishing: Bool = true, _ body: (inout FeedDownloadProgressState) -> Void) {
        let wasRunning = state.isRunning
        var next = state
        body(&next)
        var ending: String?
        if !wasRunning, next.isRunning {
            next.startRun(at: now())
        } else if wasRunning, !next.isRunning {
            ending = endAnnouncement(for: next)
            next.resetRun()
            quarterReached = 0
            lastDone = nil
        }
        guard next != state else { return }
        if publishing {
            objectWillChange.send()
        }
        state = next
        if let ending {
            VoiceOverAnnouncer.announce(ending)
        }
    }

    /// Announces the quarter of its downloads the run reached as a download
    /// ended at `date`, when it reached a new one: the highest, once, with
    /// the downloads done and the time left. A quarter reached before the
    /// run has lasted passes silently, as do those after Cancel; the run's
    /// end is announced on its own.
    private func announceQuarter(at date: Date) {
        let total = state.total
        guard state.isRunning, total > 0 else { return }
        let quarter = state.done * 4 / total
        guard quarter > quarterReached else { return }
        quarterReached = quarter
        guard quarter < 4, !state.isCancelling, hasRunLong(state, at: date) else { return }
        VoiceOverAnnouncer.announce(
            FeedDownloadProgressWording.quarter(
                done: state.done,
                of: total,
                failed: state.failed,
                secondsLeft: state.secondsLeft(at: date)
            ),
            priority: .medium
        )
    }

    /// What VoiceOver hears as `run` ends, or nil when it hears nothing: the
    /// run was short, or Cancel was pressed, which said what it stopped, or
    /// nothing downloaded, failed, or waits, as when the listener stopped
    /// the one download with Cancel Download. A run of one download names
    /// it.
    private func endAnnouncement(for run: FeedDownloadProgressState) -> String? {
        guard !run.isCancelling, hasRunLong(run, at: now()) else { return nil }
        guard run.done > 0 || !run.waits.isEmpty else { return nil }
        if run.done == 1, let lastDone {
            return FeedDownloadProgressWording.finished(download: lastDone.title, failed: lastDone.failed, waits: run.waits)
        }
        return FeedDownloadProgressWording.finished(downloaded: run.done - run.failed, failed: run.failed, waits: run.waits)
    }

    /// Whether `run` has lasted `announcedAfter` by `date`.
    private func hasRunLong(_ run: FeedDownloadProgressState, at date: Date) -> Bool {
        guard let startedAt = run.runStartedAt else { return false }
        return date.timeIntervalSince(startedAt) >= Self.announcedAfter
    }
}
