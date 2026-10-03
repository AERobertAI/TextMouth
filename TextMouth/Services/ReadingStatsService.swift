import Foundation
import Combine

/// Tracks reading/listening statistics.
///
/// Listening time is credited while a session runs, not only when it ends:
/// every `checkpointInterval` a timer adds the open session's time since the
/// previous checkpoint to the totals and saves them, so a crash or force quit
/// loses at most one interval. `ActiveSession` states the rule that keeps any
/// second from being counted twice.
@MainActor
final class ReadingStatsService: ObservableObject {
    static let shared = ReadingStatsService()

    /// How often the app checkpoints an open session: the most listening
    /// time a crash can lose.
    nonisolated static let defaultCheckpointInterval: TimeInterval = 60

    /// The longest session that counts for nothing, so a stray play and
    /// pause does not register as listening. A longer session counts in full.
    private static let longestIgnoredSession: TimeInterval = 1

    @Published var stats = ReadingStats()

    /// The statistics file to use in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// reading_stats.json: the file this service was created for, or else the
    /// one in the data directory in use, which moves when the library does.
    var fileURL: URL { customFileURL ?? TextMouthPaths.readingStatsFile }

    /// Seconds between the timer's checkpoints of an open session.
    let checkpointInterval: TimeInterval

    /// The user's calendar as the system reports it at this moment. Only its
    /// time zone bears on listening days: it decides which local day a
    /// credited second falls on. Its calendar system, locale, and digits
    /// never reach a day key (`ListeningDays`). It is asked afresh at every
    /// credit and every reading of the totals, so a change of time zone,
    /// as on a journey, applies from then on and moves nothing already
    /// credited.
    private let userCalendar: () -> Calendar

    /// The days listening is attributed to at this moment: local days in
    /// the time zone the user's calendar is in now.
    private var listeningDays: ListeningDays {
        ListeningDays(timeZone: userCalendar().timeZone)
    }

    /// The user's calendar from the system, with its time zone read afresh.
    /// Foundation renews `TimeZone.current` when the system time zone
    /// changes, as it does on arrival in another zone, while the cached
    /// `Calendar.current` may keep the zone it was made with.
    nonisolated static func systemCalendar() -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = .current
        return calendar
    }

    /// A listening session in progress, and how much of it the totals
    /// already include.
    ///
    /// The rule that keeps any second from being counted twice: the totals
    /// include `start..<creditedThrough` exactly once, in the grand total, in
    /// `bookID`'s total, and in the daily totals, where each second is in
    /// the total of the local day it fell on, and include nothing after
    /// `creditedThrough`. Crediting, which each checkpoint and the final
    /// `endSession` do, adds only `creditedThrough..<time` and then moves
    /// `creditedThrough` up to `time`. It never moves backwards, so a clock
    /// set back cannot credit the same time again either.
    private struct ActiveSession {
        /// The book being listened to.
        let bookID: UUID
        /// When the session started.
        let start: Date
        /// The end of the span the totals already include.
        var creditedThrough: Date
    }

    /// The session in progress, if any.
    private var activeSession: ActiveSession?

    /// Fires every `checkpointInterval` to checkpoint the open session.
    private var checkpointTimer: Timer?

    /// Creates a service, loads its statistics file, and starts its
    /// checkpoint timer before returning.
    ///
    /// - Parameters:
    ///   - fileURL: The file to read and write. Nil, as `shared` uses,
    ///     follows the data directory in use; tests pass a file of their own
    ///     so they never touch the app's statistics.
    ///   - checkpointInterval: Seconds between checkpoints; must be
    ///     positive. Tests shorten it to watch the timer work.
    ///   - userCalendar: The user's calendar now, read each time listening
    ///     is credited or totals are read: the system's unless a test
    ///     stands in another calendar system or time zone.
    init(
        fileURL: URL? = nil,
        checkpointInterval: TimeInterval = defaultCheckpointInterval,
        userCalendar: @escaping () -> Calendar = ReadingStatsService.systemCalendar
    ) {
        precondition(checkpointInterval > 0, "The checkpoint interval must be positive")
        customFileURL = fileURL
        self.checkpointInterval = checkpointInterval
        self.userCalendar = userCalendar
        // `self.fileURL` is the resolved location, not the optional parameter.
        stats = Self.load(from: self.fileURL)
        migrateDayKeysIfNeeded(at: Date())
        startCheckpointTimer()
    }

    /// Rewrites the day keys of statistics saved before TODO C06, which
    /// followed the system's calendar, as Gregorian keys
    /// (`ListeningDayKeyMigration`), logs what changed, and saves at once
    /// with `dayKeyVersion` set, so the migration runs, and logs, once.
    /// Keys this version writes are never read in another calendar. Does
    /// nothing for statistics already migrated or new, and waits for a
    /// later launch while the clock reads a date before TextMouth existed.
    private func migrateDayKeysIfNeeded(at now: Date) {
        guard stats.dayKeyVersion == nil,
              let migration = ListeningDayKeyMigration(userCalendar: userCalendar(), now: now)
        else { return }
        let outcome = migration.migrate(stats.dailyListeningSeconds)
        var migrated = stats
        migrated.dailyListeningSeconds = outcome.dailyListeningSeconds
        migrated.dayKeyVersion = ListeningDays.keyVersion
        stats = migrated
        if let line = outcome.logLine {
            print(line)
            TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
        }
        save()
    }

    /// Stops the checkpoint timer. At termination this follows
    /// `flushPendingSaves()`, which has already saved everything.
    func shutdown() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    // MARK: - Session Tracking

    /// Starts crediting listening time to `bookID` from `startTime`, first
    /// ending any open session at that same moment.
    func startSession(bookID: UUID, at startTime: Date = Date()) {
        endSession(at: startTime) // End any existing session first
        activeSession = ActiveSession(bookID: bookID, start: startTime, creditedThrough: startTime)
    }

    /// Closes the open session after a final checkpoint at `endTime`, which
    /// adds only the time no earlier checkpoint credited.
    func endSession(at endTime: Date = Date()) {
        checkpointActiveSession(at: endTime)
        activeSession = nil
    }

    /// Reader windows may stop or close while a different book is playing.
    /// Only the session's owner can finalize it; app shutdown and starting a
    /// different session retain the explicit unscoped operation above.
    func endSession(bookID: UUID, at endTime: Date = Date()) {
        guard activeSession?.bookID == bookID else { return }
        endSession(at: endTime)
    }

    /// Credits the open session's time since its last checkpoint and saves,
    /// leaving the session open, so a crash afterwards loses only what
    /// follows. The slice is split at every local midnight it crosses, in
    /// the time zone current now, so each day gets exactly the seconds
    /// heard on it (`ListeningDays.split`). Does nothing without an open
    /// session or while it is too short to count.
    func checkpointActiveSession(at time: Date = Date()) {
        guard let session = activeSession, uncreditedSessionTime(at: time) > 0 else { return }
        // Credit every piece to a copy and publish the result once, so no
        // observer ever sees a slice half credited.
        var credited = stats
        for piece in listeningDays.split(from: session.creditedThrough, to: time) {
            credited.addListening(piece.seconds, bookID: session.bookID, dayKey: piece.dayKey)
        }
        stats = credited
        activeSession?.creditedThrough = time
        save()
    }

    /// The open session's time that the totals do not include yet: what
    /// ending it at `time` would add. Zero without an open session, while the
    /// session is too short to count, and when `time` is not after its last
    /// checkpoint because the clock was set back.
    func uncreditedSessionTime(at time: Date) -> TimeInterval {
        guard let session = activeSession,
              time.timeIntervalSince(session.start) > Self.longestIgnoredSession
        else { return 0 }
        return max(0, time.timeIntervalSince(session.creditedThrough))
    }

    /// The part of the open session's uncredited time from `start` on: what
    /// ending the session at `now` would credit to the days that begin at
    /// `start`, since crediting splits time at midnight. Zero whenever
    /// `uncreditedSessionTime(at:)` is.
    private func uncreditedSessionTime(at now: Date, since start: Date) -> TimeInterval {
        guard let session = activeSession, uncreditedSessionTime(at: now) > 0 else { return 0 }
        return max(0, now.timeIntervalSince(max(session.creditedThrough, start)))
    }

    /// Whether a listening session is open.
    var hasActiveSession: Bool {
        activeSession != nil
    }

    func markBookFinished(bookID: UUID, title: String) {
        let entry = FinishedBookEntry(
            bookID: bookID.uuidString,
            title: title,
            dateFinished: Date()
        )
        stats.finishedBooks.append(entry)
        save()
    }

    // MARK: - Computed Stats

    /// Listening time today, the open session included.
    var todayListeningTime: TimeInterval {
        todayListeningTime(at: Date())
    }

    /// Listening time on the local day containing `now`, in the time zone
    /// current now: that day's total plus the open session's time since its
    /// last checkpoint, as much of it as falls on that day. Its checkpointed
    /// time is already in the day's total, so adding the whole session
    /// would count that part twice, and time before midnight belongs to the
    /// day before, where the next checkpoint will put it.
    func todayListeningTime(at now: Date) -> TimeInterval {
        let days = listeningDays
        let today = days.calendar.startOfDay(for: now)
        return (stats.dailyListeningSeconds[days.key(for: now)] ?? 0)
            + uncreditedSessionTime(at: now, since: today)
    }

    /// Listening time over the last seven days, the open session included.
    var thisWeekListeningTime: TimeInterval {
        thisWeekListeningTime(at: Date())
    }

    /// Listening time over the seven local days ending with the one
    /// containing `now`, plus the open session's time since its last
    /// checkpoint, as much of it as falls on those days.
    func thisWeekListeningTime(at now: Date) -> TimeInterval {
        // Days are counted back in the calendar that wrote their keys.
        let week = listeningDays.span(ofDays: 7, endingWith: now)
        let saved = week.keys.reduce(0) { $0 + (stats.dailyListeningSeconds[$1] ?? 0) }
        return saved + uncreditedSessionTime(at: now, since: week.start)
    }

    var booksFinishedThisYear: Int {
        let year = Calendar.current.component(.year, from: Date())
        return stats.finishedBooks.filter {
            Calendar.current.component(.year, from: $0.dateFinished) == year
        }.count
    }

    /// The listening streak through today, in the time zone current now.
    var currentStreak: Int {
        currentStreak(at: Date())
    }

    /// The listening streak through the local day containing `now`, in the
    /// time zone current now.
    func currentStreak(at now: Date) -> Int {
        Self.streak(in: stats.dailyListeningSeconds, through: now, timeZone: userCalendar().timeZone)
    }

    /// A day joins a streak once it has more listening than this, a minute,
    /// so a stray play and pause does not keep a streak alive.
    nonisolated private static let streakDayMinimum: TimeInterval = 60

    /// The number of consecutive local days, in `timeZone`, with more than
    /// a minute of listening, ending with the day containing `now` or, while
    /// that day has no such listening yet, with the day before.
    nonisolated static func streak(
        in dailyListeningSeconds: [String: TimeInterval],
        through now: Date,
        timeZone: TimeZone = .current
    ) -> Int {
        // Days are counted back in the calendar that wrote their keys, one
        // calendar day at a time, so a 23- or 25-hour day is neither
        // skipped nor counted twice.
        let days = ListeningDays(timeZone: timeZone)
        /// Whether the day containing `date` has enough listening to count.
        func counts(_ date: Date) -> Bool {
            (dailyListeningSeconds[days.key(for: date)] ?? 0) > streakDayMinimum
        }
        // Today joins the streak once it counts; until then the streak may
        // still run through yesterday.
        var day = counts(now) ? now : days.dayBefore(now)
        var streak = 0
        while counts(day) {
            streak += 1
            day = days.dayBefore(day)
        }
        return streak
    }

    // MARK: - Persistence

    /// Background queue for stats file I/O. JSON encoding and atomic
    /// file writes are synchronous operations that block the calling
    /// thread. Without this queue, save() blocks the main thread on
    /// every pause and every checkpoint. A queue is safe to use from
    /// any thread, so it needs no actor isolation.
    nonisolated private static let saveQueue = DispatchQueue(
        label: "com.textmouth.readingStats",
        qos: .utility
    )

    /// The key of the local day in `timeZone` containing `date`: Gregorian
    /// "yyyy-MM-dd" in ASCII digits, whatever the user's calendar and
    /// locale (`ListeningDays`).
    nonisolated static func dateKey(_ date: Date, in timeZone: TimeZone = .current) -> String {
        ListeningDays(timeZone: timeZone).key(for: date)
    }

    /// Persist stats to disk on a background queue. Safe to call
    /// from the main thread — the actual encoding and file write
    /// are dispatched asynchronously.
    func save() {
        // Snapshot the stats value type on the calling thread so
        // the background write captures a consistent copy, and resolve
        // the destination here too, where the main actor owns it
        let snapshot = stats
        let url = fileURL
        let retry = retryAfterFailure
        Self.saveQueue.async {
            Self.write(snapshot, to: url, retry: retry)
        }
    }

    /// Saves the statistics again for a retry of the failed save
    /// `failureID`, and waits for the write. Nothing is written when a later
    /// save has settled that failure, which a save still queued ahead of
    /// this one may have done. The statistics written are the ones in use
    /// now: they hold everything the failed save had, since a failure
    /// changes nothing in memory, and they go to wherever this service's
    /// file is now, which moves when the data directory does.
    func retrySave(failureID: PersistenceFailure.ID) {
        let snapshot = stats
        let url = fileURL
        let retry = retryAfterFailure
        Self.saveQueue.sync {
            guard PersistenceFailureCenter.shared.isOutstanding(failureID) else { return }
            Self.write(snapshot, to: url, retry: retry)
        }
    }

    /// The retry reported with a failed save: `retrySave(failureID:)` on
    /// this service, while it exists.
    private var retryAfterFailure: PersistenceFailure.Retry {
        { [weak self] failureID in self?.retrySave(failureID: failureID) }
    }

    /// Writes `snapshot` to `url` and reports the outcome to the failure
    /// center (TODO S09): a file written settles any earlier failed save of
    /// the statistics, and a failure is reported with `retry`, so it is
    /// never known only to the console. Must run on saveQueue.
    nonisolated private static func write(
        _ snapshot: ReadingStats,
        to url: URL,
        retry: @escaping PersistenceFailure.Retry
    ) {
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            PersistenceFailureCenter.shared.recordSuccess(.statistics)
        } catch {
            print("Failed to save reading stats: \(error)")
            PersistenceFailureCenter.shared.recordFailure(.statistics, path: url.path, error: error, retry: retry)
        }
    }

    /// Checkpoints the open session at `time` without ending it, then waits
    /// for every queued write to finish. Application termination calls this,
    /// so the last stretch of listening is on disk before the app exits,
    /// even when the reader is still playing and never ends its session.
    func flushPendingSaves(at time: Date = Date()) {
        checkpointActiveSession(at: time)
        Self.waitForQueuedSaves()
    }

    /// Blocks until every save queued so far, by any service, has been
    /// written. All services share one queue, so this covers them all. It
    /// touches only that queue, so any thread may wait, test tear-down too.
    nonisolated static func waitForQueuedSaves() {
        saveQueue.sync {}
    }

    /// Reads the statistics saved at `url`, starting empty when there is no
    /// file yet or it cannot be decoded.
    private static func load(from url: URL) -> ReadingStats {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReadingStats()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ReadingStats.self, from: data)
        } catch {
            print("Failed to load reading stats: \(error)")
            return ReadingStats()
        }
    }

    /// Starts the timer that checkpoints the open session every
    /// `checkpointInterval`. A tick with nothing to credit writes nothing:
    /// every other change to the statistics saves itself, so rewriting them
    /// unchanged, as this timer once did, would add nothing.
    private func startCheckpointTimer() {
        // Defensive invalidate-before-assign: this is currently called once
        // from init, but the pattern protects against a future refactor that
        // calls it twice (which would otherwise leak a Timer onto the run
        // loop with both copies firing).
        checkpointTimer?.invalidate()
        let timer = Timer(timeInterval: checkpointInterval, repeats: true) { [weak self] timer in
            // A service that no longer exists, such as one a test made and
            // released, stops its own timer instead of ticking forever.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.checkpointActiveSession() }
        }
        // The common modes keep checkpoints coming while a menu is open or a
        // modal panel runs; a timer in the default mode would wait for them.
        RunLoop.main.add(timer, forMode: .common)
        checkpointTimer = timer
    }

    /// Prune daily entries older than 90 days to keep the file small
    func pruneOldEntries() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: Date()) else { return }
        let cutoffKey = Self.dateKey(cutoff)
        stats.dailyListeningSeconds = stats.dailyListeningSeconds.filter { $0.key >= cutoffKey }
        save()
    }
}

// MARK: - Data Model

struct ReadingStats: Codable {
    /// Daily listening time in seconds, keyed by local day as
    /// `ListeningDays` writes keys: "yyyy-MM-dd", Gregorian, ASCII digits.
    /// A key from an earlier version that names no day is kept under
    /// `ListeningDayKeyMigration.legacyKeyPrefix`; it counts in the total
    /// but in no day. All entries together add up to the total.
    var dailyListeningSeconds: [String: TimeInterval] = [:]
    /// Total listening time across all time
    var totalListeningSeconds: TimeInterval = 0
    /// Per-book listening time in seconds, keyed by book UUID string
    var bookListeningSeconds: [String: TimeInterval] = [:]
    /// Books that have been finished
    var finishedBooks: [FinishedBookEntry] = []
    /// The version of the rules the keys of `dailyListeningSeconds`
    /// follow: `ListeningDays.keyVersion` once they are Gregorian keys, as
    /// new statistics are from the start. A file saved before TODO C06
    /// decodes with none, since its keys followed the system's calendar;
    /// the service migrates them once when it loads the file.
    var dayKeyVersion: Int? = ListeningDays.keyVersion

    /// Adds `seconds` of listening to `bookID` on the day `dayKey` names,
    /// keeping the grand, per-book, and daily totals in step.
    mutating func addListening(_ seconds: TimeInterval, bookID: UUID, dayKey: String) {
        dailyListeningSeconds[dayKey, default: 0] += seconds
        totalListeningSeconds += seconds
        bookListeningSeconds[bookID.uuidString, default: 0] += seconds
    }
}

struct FinishedBookEntry: Codable {
    var bookID: String
    var title: String
    var dateFinished: Date
}
