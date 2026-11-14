import Foundation
import Combine

// MARK: - Subsystems

/// The stores TextMouth keeps on disk, and the cleanup an import does,
/// whose failed writes the user is told about (TODO S09). Every failure
/// belongs to one subsystem, and the Library window's banner gives each
/// subsystem with a failure one row, in the order of these cases.
enum PersistenceSubsystem: CaseIterable, Comparable, Sendable {
    /// library.json: the folders, sort settings, manual order, and every
    /// book's place and reading state.
    case libraryIndex
    /// A book's bookInfo.json in its package, or where its package is after
    /// a failed move could not be undone.
    case bookRecord
    /// reading_stats.json: listening time and finished books.
    case statistics
    /// config.json: the settings.
    case configuration
    /// The text substitution rules.
    case substitutions
    /// A feed subscription's record, Feeds/<feed ID>.json (FR03): its
    /// address, settings, and the episodes and articles it keeps.
    case feedRecords
    /// Deleting the original file of a book just imported, when the "After
    /// Importing a Book" preference asks for it.
    case originalFileCleanup

    /// Whether a failure here means changes that exist only in memory, so
    /// quitting would leave them unsaved. An original file left behind after
    /// an import is not one: the book is already safe in the library.
    var holdsUnsavedChanges: Bool {
        self != .originalFileCleanup
    }

    /// What the subsystem holds, as the banner's buttons and announcements
    /// name it: "library changes", "listening statistics".
    var topic: String {
        switch self {
        case .libraryIndex: return "library changes"
        case .bookRecord: return "changes to books"
        case .statistics: return "listening statistics"
        case .configuration: return "settings"
        case .substitutions: return "text substitution rules"
        case .feedRecords: return "feed subscriptions"
        case .originalFileCleanup: return "original files"
        }
    }

    /// What a successful operation here does to its files: "saved", or
    /// "removed" for original-file cleanup.
    var outcomeWord: String {
        self == .originalFileCleanup ? "removed" : "saved"
    }

    /// What VoiceOver says for the banner's Retry button, which a sighted
    /// user sees beside the sentence it retries: "Retry saving settings".
    var retryLabel: String {
        self == .originalFileCleanup ? "Retry removing \(topic)" : "Retry saving \(topic)"
    }

    /// What VoiceOver says for the banner's Dismiss button: "Dismiss the
    /// notice about settings".
    var dismissLabel: String {
        "Dismiss the notice about \(topic)"
    }

    /// What VoiceOver says once a retry has settled every failure here:
    /// "Settings saved.", "Original files removed."
    var retriedAnnouncement: String {
        topic.prefix(1).uppercased() + topic.dropFirst() + " \(outcomeWord)."
    }

    /// The sentence that follows a banner row's failure when `count` more
    /// failures of this subsystem wait behind it, or nil when none do. Only
    /// book records, feed records, and original files can fail several at
    /// once; every other subsystem is one file.
    func othersSentence(count: Int) -> String? {
        guard count > 0 else { return nil }
        switch self {
        case .bookRecord:
            return count == 1
                ? "Changes to 1 other book could not be saved either."
                : "Changes to \(count) other books could not be saved either."
        case .feedRecords:
            return count == 1
                ? "Changes to 1 other feed could not be saved either."
                : "Changes to \(count) other feeds could not be saved either."
        case .originalFileCleanup:
            return count == 1
                ? "1 other original file could not be removed either."
                : "\(count) other original files could not be removed either."
        case .libraryIndex, .statistics, .configuration, .substitutions:
            return nil
        }
    }
}

// MARK: - Failures

/// One failed write or cleanup, as reported to `PersistenceFailureCenter`:
/// what it was for, the file it was for, why it failed, when, and how to
/// run it again.
struct PersistenceFailure: Identifiable, Sendable {
    /// Identifies one report. A later report has a higher ID.
    typealias ID = UInt64

    /// Runs the failed operation again with the same data, on the main
    /// actor, and returns once it has finished; the operation reports its
    /// own outcome. It is told which failure it retries: a retry that runs
    /// on a queue stands down when a later write has settled that failure
    /// in the meantime, because an older state must never replace a newer
    /// one.
    typealias Retry = @MainActor @Sendable (_ failure: ID) -> Void

    /// What the failed operation was for.
    enum Subject: Equatable, Sendable {
        /// Writing library.json.
        case libraryIndex
        /// Writing the bookInfo.json of the book `bookID`, titled `title`.
        case bookRecord(bookID: UUID, title: String)
        /// Putting back the package of the book `bookID` after a move that
        /// failed: the package is at `location`, not at `home`, where the
        /// library expects it.
        case strandedPackage(bookID: UUID, title: String, location: String, home: String)
        /// Writing reading_stats.json.
        case statistics
        /// Writing config.json.
        case configuration
        /// Writing the substitution rules.
        case substitutions
        /// Writing the record of the feed `feedID`, titled `title` (FR03).
        case feedRecord(feedID: UUID, title: String)
        /// Deleting the original file at `path` after its book was imported:
        /// to the Trash when `movesToTrash`, otherwise permanently.
        case originalFile(path: String, movesToTrash: Bool)
    }

    /// What a later outcome must concern to settle a failure: the file, or
    /// for book records the book. A key has at most one outstanding
    /// failure, the latest reported.
    enum Key: Hashable, Sendable {
        case libraryIndex
        case book(UUID)
        case statistics
        case configuration
        case substitutions
        /// A feed's record, by the feed's ID.
        case feed(UUID)
        /// An original file, by its path.
        case originalFile(String)
    }

    /// This report's place in the order of reports.
    let id: ID
    /// What the operation was for.
    let subject: Subject
    /// The file or folder the operation was for.
    let path: String
    /// Why it failed.
    let error: any Error
    /// When it failed.
    let date: Date
    /// Runs it again, or nil when it cannot be run again with the same data.
    let retry: Retry?

    /// The key a later outcome settles this failure by.
    var key: Key { subject.key }

    /// The subsystem the failure belongs to.
    var subsystem: PersistenceSubsystem { subject.subsystem }

    /// Why it failed, in the system's words, as a sentence.
    var reason: String { Self.sentence(error.localizedDescription) }

    /// What failed and why, as one sentence: "Settings could not be saved:
    /// You don’t have permission to save the file “config.json” in the
    /// folder “.TextMouth”."
    var sentence: String { subject.sentence(reason: reason) }

    /// `text` without surrounding white space, ending as a sentence ends:
    /// a full stop is added unless it already ends with one, a question
    /// mark, or an exclamation mark.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "No reason was given." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

extension PersistenceFailure.Subject {
    /// The subsystem a failure of this subject belongs to.
    var subsystem: PersistenceSubsystem {
        switch self {
        case .libraryIndex: return .libraryIndex
        case .bookRecord, .strandedPackage: return .bookRecord
        case .statistics: return .statistics
        case .configuration: return .configuration
        case .substitutions: return .substitutions
        case .feedRecord: return .feedRecords
        case .originalFile: return .originalFileCleanup
        }
    }

    /// The key that a later outcome settles a failure of this subject by. A
    /// book's record and its package share the book's key: a stranded
    /// package is settled by putting it back and writing the record there.
    var key: PersistenceFailure.Key {
        switch self {
        case .libraryIndex: return .libraryIndex
        case .bookRecord(let bookID, _), .strandedPackage(let bookID, _, _, _): return .book(bookID)
        case .statistics: return .statistics
        case .configuration: return .configuration
        case .substitutions: return .substitutions
        case .feedRecord(let feedID, _): return .feed(feedID)
        case .originalFile(let path, _): return .originalFile(path)
        }
    }

    /// What the operation was for, as the debug log names it.
    var logName: String {
        switch self {
        case .libraryIndex: return "the library index"
        case .bookRecord(_, let title): return "the record of “\(title)”"
        case .strandedPackage(_, let title, _, _): return "the package of “\(title)”"
        case .statistics: return "the listening statistics"
        case .configuration: return "the settings"
        case .substitutions: return "the text substitution rules"
        case .feedRecord(_, let title): return "the record of the feed “\(title)”"
        case .originalFile(let path, _): return "the original file at \(path)"
        }
    }

    /// What failed, followed by `reason`, as one sentence: the subsystem
    /// first, so a listener knows at once what is affected.
    func sentence(reason: String) -> String {
        switch self {
        case .libraryIndex:
            return "Library changes could not be saved: \(reason)"
        case .bookRecord(_, let title):
            return "Changes to “\(title)” could not be saved: \(reason)"
        case .strandedPackage(_, let title, let location, let home):
            return "“\(title)” could not be moved back after a failed move, "
                + "so its files are at \(location) instead of \(home): \(reason)"
        case .statistics:
            return "Listening statistics could not be saved: \(reason)"
        case .configuration:
            return "Settings could not be saved: \(reason)"
        case .substitutions:
            return "Text substitution rules could not be saved: \(reason)"
        case .feedRecord(_, let title):
            return "Changes to the feed “\(title)” could not be saved: \(reason)"
        case .originalFile(let path, let movesToTrash):
            return OriginalFileDeletionWording(
                movesToTrash: movesToTrash,
                fileName: URL(fileURLWithPath: path).lastPathComponent
            ).failureSentence(reason: reason)
        }
    }
}

// MARK: - Banner Rows

/// One row of the Library window's banner: the latest failure of one
/// subsystem, and how many more that subsystem has.
struct PersistenceBannerRow: Identifiable, Equatable {
    /// The subsystem the row reports.
    let subsystem: PersistenceSubsystem
    /// What failed and why: the latest failure's sentence, then a sentence
    /// counting the others, if any.
    let text: String
    /// Whether any of the row's failures can be run again.
    let canRetry: Bool

    /// One row per subsystem, so a subsystem identifies its row.
    var id: PersistenceSubsystem { subsystem }

    /// What VoiceOver says when the row first appears: its text, then where
    /// to act on it, since the listener may be in another window.
    var announcement: String {
        Self.announcement(for: [self]) ?? text
    }

    /// One announcement for `rows` that appeared together, such as every
    /// subsystem a full disk stops at once: each row's text, then where to
    /// act, said once. One announcement, because each high-priority one
    /// would cut the one before it short. Nil when there are no rows.
    static func announcement(for rows: [PersistenceBannerRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        let action = rows.contains(where: \.canRetry)
            ? "Retry is at the top of the Library window."
            : "Details are at the top of the Library window."
        return (rows.map(\.text) + [action]).joined(separator: " ")
    }

    /// The rows for `failures`, one for each subsystem among them, in
    /// subsystem order. Each row leads with its subsystem's latest failure.
    static func rows(for failures: [PersistenceFailure]) -> [PersistenceBannerRow] {
        let bySubsystem = Dictionary(grouping: failures, by: \.subsystem)
        return bySubsystem.keys.sortedStably().compactMap { subsystem in
            guard let group = bySubsystem[subsystem],
                  let latest = group.max(by: { $0.id < $1.id }) else { return nil }
            let others = subsystem.othersSentence(count: group.count - 1)
            return PersistenceBannerRow(
                subsystem: subsystem,
                text: [latest.sentence, others].compactMap { $0 }.joined(separator: " "),
                canRetry: group.contains { $0.retry != nil }
            )
        }
    }
}

// MARK: - The Ledger

/// The failures outstanding right now, under a lock, so services can report
/// from their own queues without waiting for the main actor, and the
/// termination path can read the answer the moment the writes finish.
private final class PersistenceFailureLedger: @unchecked Sendable {
    private let lock = NSLock()
    /// The latest outstanding failure for each key.
    private var failures: [PersistenceFailure.Key: PersistenceFailure] = [:]
    /// The ID given to the latest report.
    private var lastID: PersistenceFailure.ID = 0
    /// Whether a publish to the main actor is already on its way.
    private var publishIsScheduled = false

    /// Stores the failure `make` builds from the next ID, replacing the one
    /// outstanding for the same key. Returns it, and whether its key had an
    /// outstanding failure already.
    func record(
        _ make: (PersistenceFailure.ID) -> PersistenceFailure
    ) -> (failure: PersistenceFailure, replaced: Bool) {
        lock.lock()
        defer { lock.unlock() }
        lastID += 1
        let failure = make(lastID)
        let replaced = failures.updateValue(failure, forKey: failure.key) != nil
        return (failure, replaced)
    }

    /// Removes the failure outstanding for `key`, returning it, if any.
    func remove(_ key: PersistenceFailure.Key) -> PersistenceFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failures.removeValue(forKey: key)
    }

    /// Removes every outstanding failure.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        failures.removeAll()
    }

    /// Every outstanding failure, oldest first.
    func snapshot() -> [PersistenceFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures.values.sortedStably { $0.id < $1.id }
    }

    /// Whether the failure `id` is still outstanding: no later outcome has
    /// been reported for its key.
    func isOutstanding(_ id: PersistenceFailure.ID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failures.values.contains { $0.id == id }
    }

    /// Whether any outstanding failure satisfies `predicate`.
    func contains(where predicate: (PersistenceFailure) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failures.values.contains(where: predicate)
    }

    /// Claims the next publish: true when none was on its way, so the caller
    /// must schedule one; false when one already is and will see this change.
    func claimPublish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !publishIsScheduled else { return false }
        publishIsScheduled = true
        return true
    }

    /// Ends the claim as a publish starts, so a report arriving while it
    /// reads the failures schedules another.
    func releasePublishClaim() {
        lock.lock()
        defer { lock.unlock() }
        publishIsScheduled = false
    }
}

// MARK: - The Center

/// Where every failed write of the library index, a book record, the
/// statistics, the settings, the substitution rules, or a feed's record,
/// and every failed cleanup of an imported book's original file, is
/// reported (TODO S09), so none of them is known only to a log.
///
/// Services report from any thread and are never held up: a report updates
/// the ledger under a lock and asks the main actor to publish. The center
/// keeps the latest failure of each file (of each book, for book records),
/// with its path, error, time, and a retry when the operation can run again
/// with the same data. A later success for the same file settles it, which
/// is how "readable in memory" is told from "saved": while a failure of a
/// subsystem that holds changes is outstanding, `hasUnsavedChanges` is true
/// and no status may say the work was saved.
///
/// The Library window shows the published failures as a banner, one row per
/// subsystem, and VoiceOver announces a subsystem once when it starts to
/// fail. Failures recur every half second while a disk stays unavailable,
/// so nothing here is ever a modal alert.
@MainActor
final class PersistenceFailureCenter: ObservableObject {
    /// The center every service reports to.
    nonisolated static let shared = PersistenceFailureCenter()

    /// Every outstanding failure as last published, oldest first. Views
    /// read this; logic that must not wait for a publish asks the ledger
    /// through `outstandingFailures()` or `hasUnsavedChanges`.
    @Published private(set) var failures: [PersistenceFailure] = []

    /// Subsystems whose banner row the user dismissed. A subsystem stays
    /// dismissed until it has no failure left, so a problem that clears and
    /// comes back is shown and announced again.
    @Published private(set) var dismissedSubsystems: Set<PersistenceSubsystem> = []

    /// The subsystems that had failures at the last publish, so each new
    /// one is announced exactly once.
    private var subsystemsFailingAtLastPublish: Set<PersistenceSubsystem> = []

    /// The outstanding failures, readable and writable from any thread.
    nonisolated private let ledger = PersistenceFailureLedger()

    /// A center with no failures. The app uses `shared`; tests make their
    /// own so they never disturb it.
    nonisolated init() {}

    // MARK: Reporting, from any thread

    /// Reports that an operation for `subject` failed with `error`. The
    /// failure replaces any still outstanding for the same key, so a write
    /// that keeps failing holds one entry, the latest, and its retry runs
    /// the latest data. The debug log records the failure the first time
    /// its key fails, not on every repetition.
    ///
    /// - Parameters:
    ///   - subject: What the operation was for.
    ///   - path: The file or folder it was for.
    ///   - error: Why it failed.
    ///   - retry: Runs it again with the same data; nil when it cannot.
    nonisolated func recordFailure(
        _ subject: PersistenceFailure.Subject,
        path: String,
        error: any Error,
        retry: PersistenceFailure.Retry? = nil
    ) {
        let (failure, replaced) = ledger.record { id in
            PersistenceFailure(id: id, subject: subject, path: path, error: error, date: Date(), retry: retry)
        }
        if !replaced {
            Self.log("PERSISTENCE_FAILURE: \(failure.sentence) Path: \(DiagnosticLog.loggablePath(path))")
        }
        schedulePublish()
    }

    /// Reports that an operation for `key` succeeded, settling the failure
    /// outstanding for it, if any.
    nonisolated func recordSuccess(_ key: PersistenceFailure.Key) {
        guard let settled = ledger.remove(key) else { return }
        Self.log("PERSISTENCE_RECOVERED: \(settled.subject.logName) is \(settled.subsystem.outcomeWord)")
        schedulePublish()
    }

    /// Withdraws the failure outstanding for `key`, if any, because nothing
    /// is left to save for it: the book left the library, for example.
    nonisolated func withdraw(_ key: PersistenceFailure.Key) {
        guard let withdrawn = ledger.remove(key) else { return }
        Self.log(
            "PERSISTENCE_WITHDRAWN: \(withdrawn.subject.logName) no longer needs to be "
                + withdrawn.subsystem.outcomeWord
        )
        schedulePublish()
    }

    // MARK: Questions, from any thread

    /// Whether any outstanding failure leaves changes only in memory: what
    /// quitting checks, and what keeps a status from saying "saved".
    nonisolated var hasUnsavedChanges: Bool {
        ledger.contains { $0.subsystem.holdsUnsavedChanges }
    }

    /// Every outstanding failure, oldest first, as of this moment.
    nonisolated func outstandingFailures() -> [PersistenceFailure] {
        ledger.snapshot()
    }

    /// The outstanding failures that leave changes only in memory.
    nonisolated func unsavedFailures() -> [PersistenceFailure] {
        outstandingFailures().filter { $0.subsystem.holdsUnsavedChanges }
    }

    /// Whether the failure `id` is still outstanding, which a retry checks
    /// on its queue just before it writes.
    nonisolated func isOutstanding(_ id: PersistenceFailure.ID) -> Bool {
        ledger.isOutstanding(id)
    }

    // MARK: The banner

    /// The banner's rows: one for each subsystem with a published failure
    /// that the user has not dismissed.
    var bannerRows: [PersistenceBannerRow] {
        PersistenceBannerRow.rows(for: failures).filter { !dismissedSubsystems.contains($0.subsystem) }
    }

    /// The rows of the published failures that leave changes unsaved,
    /// dismissed or not: what any status that would say "saved" must
    /// account for first.
    var unsavedRows: [PersistenceBannerRow] {
        PersistenceBannerRow.rows(for: failures.filter { $0.subsystem.holdsUnsavedChanges })
    }

    /// Runs again every outstanding failure of `subsystem` that can be, then
    /// tells VoiceOver how it went: the subsystem is saved, or the row's
    /// sentence, now naming the latest failure. Each retry finishes before
    /// this returns, so the banner is up to date at once.
    func retry(_ subsystem: PersistenceSubsystem) {
        rerun(outstandingFailures().filter { $0.subsystem == subsystem })
        publish()
        announceRetryOutcome(for: [subsystem])
    }

    /// Runs again every outstanding failure that leaves changes unsaved, as
    /// the prompt shown on quitting and Storage settings ask, and publishes
    /// the result. With `announcing`, VoiceOver then hears how it went.
    func retryUnsavedChanges(announcing: Bool = false) {
        let unsaved = unsavedFailures()
        rerun(unsaved)
        publish()
        if announcing {
            announceRetryOutcome(for: Set(unsaved.map(\.subsystem)))
        }
    }

    /// Hides `subsystem`'s banner row until the subsystem has no failure
    /// left. The failures stay outstanding: dismissing saves nothing.
    func dismiss(_ subsystem: PersistenceSubsystem) {
        guard failures.contains(where: { $0.subsystem == subsystem }) else { return }
        dismissedSubsystems.insert(subsystem)
    }

    /// Brings the published failures up to date with the ledger, forgets the
    /// dismissal of every subsystem that has no failure left, and announces
    /// the subsystems that have started to fail since the last publish, in
    /// one announcement. Reports schedule this on the main queue; tests call
    /// it directly.
    func publish() {
        ledger.releasePublishClaim()
        let current = ledger.snapshot()
        let failing = Set(current.map(\.subsystem))
        let newlyFailing = failing.subtracting(subsystemsFailingAtLastPublish)
        subsystemsFailingAtLastPublish = failing
        let stillDismissed = dismissedSubsystems.intersection(failing)
        if stillDismissed != dismissedSubsystems {
            dismissedSubsystems = stillDismissed
        }
        failures = current
        let appeared = PersistenceBannerRow.rows(for: current).filter { newlyFailing.contains($0.subsystem) }
        if let announcement = PersistenceBannerRow.announcement(for: appeared) {
            VoiceOverAnnouncer.announce(announcement)
        }
    }

    /// Forgets every failure and dismissal at once, announcing nothing.
    /// Tests that report through `shared` start and end with this.
    func reset() {
        ledger.removeAll()
        failures = []
        dismissedSubsystems = []
        subsystemsFailingAtLastPublish = []
    }

    // MARK: Private

    /// Tells VoiceOver how a retry of `subsystems` went, once publishing
    /// has caught up: "Retry did not succeed." and the row of each that
    /// still fails, or else that each is saved ("Settings saved.").
    private func announceRetryOutcome(for subsystems: Set<PersistenceSubsystem>) {
        // Nothing was waiting to run again, so there is nothing to tell.
        guard !subsystems.isEmpty else { return }
        let stillFailing = PersistenceBannerRow.rows(for: failures).filter { subsystems.contains($0.subsystem) }
        let message = stillFailing.isEmpty
            ? subsystems.sortedStably().map(\.retriedAnnouncement)
            : ["Retry did not succeed."] + stillFailing.map(\.text)
        VoiceOverAnnouncer.announce(message.joined(separator: " "))
    }

    /// Runs the retry of each of `failures` that has one, oldest first.
    private func rerun(_ failures: [PersistenceFailure]) {
        for failure in failures {
            failure.retry?(failure.id)
        }
    }

    /// Asks the main actor to publish, unless a publish is already on its
    /// way: it reads the ledger when it runs, so it will see this change.
    nonisolated private func schedulePublish() {
        guard ledger.claimPublish() else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { publish() }
        }
    }

    /// Records `message` as a storage event: in the debug log and the
    /// console, on one line, a line break in a title or a path becoming a
    /// space.
    nonisolated private static func log(_ message: String) {
        DiagnosticLog.event(.storage, message)
    }
}

// MARK: - Outcomes

extension OperationOutcome {
    /// This outcome as it may be reported while `unsaved` failures are
    /// outstanding (TODO S09). "Done" would claim the work reached the disk,
    /// so a success becomes a failure: its own message stays, without the
    /// "Done." it starts with, then "Some changes are not saved." and the
    /// sentence of each unsaved subsystem, as the banner words it. A failure,
    /// or a success with nothing unsaved, is returned as it is.
    func confirmingSaves(_ unsaved: [PersistenceFailure]) -> OperationOutcome {
        guard succeeded, !unsaved.isEmpty else { return self }
        let done = message.map(Self.withoutDoneClaim) ?? ""
        let report = [done, "Some changes are not saved."] + PersistenceBannerRow.rows(for: unsaved).map(\.text)
        return .failure(report.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// `message` without the "Done." that Storage settings' successes begin
    /// with ("Done. 3 books in library."), which a report of unsaved changes
    /// must not keep.
    private static func withoutDoneClaim(_ message: String) -> String {
        let claim = "Done."
        guard message.hasPrefix(claim) else { return message }
        return message.dropFirst(claim.count).trimmingCharacters(in: .whitespaces)
    }
}
