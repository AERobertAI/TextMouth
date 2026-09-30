import Foundation
import Combine

/// Tracks reading/listening statistics.
///
/// Listening time is credited while a session runs, not only when it ends:
/// each checkpoint adds the open session's time since the one before to the
/// totals and saves them, so a crash or force quit loses only the time since
/// the last checkpoint. `ActiveSession` states the rule that keeps any second
/// from being counted twice.
@MainActor
final class ReadingStatsService: ObservableObject {
    static let shared = ReadingStatsService()

    /// The longest session that counts for nothing, so a stray play and
    /// pause does not register as listening. A longer session counts in full.
    private static let longestIgnoredSession: TimeInterval = 1

    @Published var stats = ReadingStats()

    /// The statistics file to use in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// reading_stats.json: the file this service was created for, or else the
    /// one in the data directory in use, which moves when the library does.
    var fileURL: URL { customFileURL ?? TextMouthPaths.readingStatsFile }

    /// A listening session in progress, and how much of it the totals
    /// already include.
    ///
    /// The rule that keeps any second from being counted twice: the totals
    /// include `start..<creditedThrough` exactly once, in the grand total, in
    /// `bookID`'s total, and in one day's total, and include nothing after
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
    private var saveTimer: Timer?

    /// Creates a service and loads its statistics file before returning.
    ///
    /// - Parameter fileURL: The file to read and write. Nil, as `shared`
    ///   uses, follows the data directory in use; tests pass a file of their
    ///   own so they never touch the app's statistics.
    init(fileURL: URL? = nil) {
        customFileURL = fileURL
        // `self.fileURL` is the resolved location, not the optional parameter.
        stats = Self.load(from: self.fileURL)
        startAutoSave()
    }

    func shutdown() {
        saveTimer?.invalidate()
        saveTimer = nil
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
    /// follows. The slice goes to the day containing `time`. Does nothing
    /// without an open session or while it is too short to count.
    func checkpointActiveSession(at time: Date = Date()) {
        guard let session = activeSession else { return }
        let seconds = uncreditedSessionTime(at: time)
        guard seconds > 0 else { return }
        stats.addListening(seconds, bookID: session.bookID, dayKey: Self.dateKey(time))
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

    /// Listening time on the day containing `now`: that day's total plus the
    /// open session's time since its last checkpoint. Its checkpointed time
    /// is already in the day's total, so adding the whole session would
    /// count that part twice.
    func todayListeningTime(at now: Date) -> TimeInterval {
        (stats.dailyListeningSeconds[Self.dateKey(now)] ?? 0) + uncreditedSessionTime(at: now)
    }

    /// Listening time over the last seven days, the open session included.
    var thisWeekListeningTime: TimeInterval {
        thisWeekListeningTime(at: Date())
    }

    /// Listening time over the seven days ending with the one containing
    /// `now`, plus the open session's time since its last checkpoint.
    func thisWeekListeningTime(at now: Date) -> TimeInterval {
        let calendar = Calendar.current
        var total: TimeInterval = 0
        for dayOffset in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) {
                let key = Self.dateKey(date)
                total += stats.dailyListeningSeconds[key] ?? 0
            }
        }
        return total + uncreditedSessionTime(at: now)
    }

    var booksFinishedThisYear: Int {
        let year = Calendar.current.component(.year, from: Date())
        return stats.finishedBooks.filter {
            Calendar.current.component(.year, from: $0.dateFinished) == year
        }.count
    }

    var currentStreak: Int {
        Self.streak(in: stats.dailyListeningSeconds, through: Date())
    }

    static func streak(
        in dailyListeningSeconds: [String: TimeInterval],
        through now: Date,
        calendar: Calendar = .current
    ) -> Int {
        var streak = 0
        var date = now
        // Check today and each preceding day
        while true {
            let key = Self.dateKey(date)
            if (dailyListeningSeconds[key] ?? 0) > 60 { // At least 1 minute counts
                streak += 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
                date = prev
            } else if streak == 0 {
                // Today might not have listening yet, check yesterday
                guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
                date = prev
                // Only allow one skip (today)
                let key2 = Self.dateKey(date)
                if (dailyListeningSeconds[key2] ?? 0) > 60 {
                    streak += 1
                    guard let prev2 = calendar.date(byAdding: .day, value: -1, to: date) else { break }
                    date = prev2
                } else {
                    break
                }
            } else {
                break
            }
        }
        return streak
    }

    // MARK: - Persistence

    /// Background queue for stats file I/O. JSON encoding and atomic
    /// file writes are synchronous operations that block the calling
    /// thread. Without this queue, save() blocks the main thread on
    /// every pause and every 60-second auto-save tick. A queue is safe to
    /// use from any thread, so it needs no actor isolation.
    nonisolated private static let saveQueue = DispatchQueue(
        label: "com.textmouth.readingStats",
        qos: .utility
    )

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
        Self.saveQueue.async {
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save reading stats: \(error)")
            }
        }
    }

    /// Wait for previously queued writes to finish. Intended for application
    /// termination, where returning before the asynchronous save completes can
    /// lose the final reading session.
    func flushPendingSaves() {
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

    private func startAutoSave() {
        // Defensive invalidate-before-assign: this is currently called once
        // from init on the shared singleton, but the pattern protects
        // against a future refactor that calls it twice (which would
        // otherwise leak a Timer onto the run loop with both copies firing
        // every 60s).
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
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
    /// Daily listening time in seconds, keyed by "yyyy-MM-dd"
    var dailyListeningSeconds: [String: TimeInterval] = [:]
    /// Total listening time across all time
    var totalListeningSeconds: TimeInterval = 0
    /// Per-book listening time in seconds, keyed by book UUID string
    var bookListeningSeconds: [String: TimeInterval] = [:]
    /// Books that have been finished
    var finishedBooks: [FinishedBookEntry] = []

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
