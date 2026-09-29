import Foundation
import Combine

/// Tracks reading/listening statistics.
@MainActor
final class ReadingStatsService: ObservableObject {
    static let shared = ReadingStatsService()

    @Published var stats: ReadingStats

    private var sessionStartTime: Date?
    private var sessionBookID: UUID?
    private var saveTimer: Timer?

    private init() {
        stats = Self.load()
        startAutoSave()
    }

    func shutdown() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

    // MARK: - Session Tracking

    func startSession(bookID: UUID, at startTime: Date = Date()) {
        endSession(at: startTime) // End any existing session first
        sessionStartTime = startTime
        sessionBookID = bookID
    }

    func endSession(at endTime: Date = Date()) {
        guard let start = sessionStartTime, let bookID = sessionBookID else { return }
        let duration = endTime.timeIntervalSince(start)
        sessionStartTime = nil
        sessionBookID = nil
        guard duration > 1 else { return } // Ignore sub-second sessions

        let today = Self.dateKey(endTime)
        stats.dailyListeningSeconds[today, default: 0] += duration
        stats.totalListeningSeconds += duration

        // Per-book tracking
        stats.bookListeningSeconds[bookID.uuidString, default: 0] += duration

        save()
    }

    /// Reader windows may stop or close while a different book is playing.
    /// Only the session's owner can finalize it; app shutdown and starting a
    /// different session retain the explicit unscoped operation above.
    func endSession(bookID: UUID, at endTime: Date = Date()) {
        guard sessionBookID == bookID else { return }
        endSession(at: endTime)
    }

    var hasActiveSession: Bool {
        sessionStartTime != nil && sessionBookID != nil
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

    var todayListeningTime: TimeInterval {
        let today = Self.dateKey(Date())
        let saved = stats.dailyListeningSeconds[today] ?? 0
        // Add current session time if active
        if let start = sessionStartTime {
            return saved + Date().timeIntervalSince(start)
        }
        return saved
    }

    var thisWeekListeningTime: TimeInterval {
        let calendar = Calendar.current
        let now = Date()
        var total: TimeInterval = 0
        for dayOffset in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) {
                let key = Self.dateKey(date)
                total += stats.dailyListeningSeconds[key] ?? 0
            }
        }
        if let start = sessionStartTime {
            total += Date().timeIntervalSince(start)
        }
        return total
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
    /// every pause and every 60-second auto-save tick.
    private static let saveQueue = DispatchQueue(
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
        // the background write captures a consistent copy
        let snapshot = stats
        Self.saveQueue.async {
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: TextMouthPaths.readingStatsFile, options: .atomic)
            } catch {
                print("Failed to save reading stats: \(error)")
            }
        }
    }

    /// Wait for previously queued writes to finish. Intended for application
    /// termination, where returning before the asynchronous save completes can
    /// lose the final reading session.
    func flushPendingSaves() {
        Self.saveQueue.sync {}
    }

    private static func load() -> ReadingStats {
        let url = TextMouthPaths.readingStatsFile
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
}

struct FinishedBookEntry: Codable {
    var bookID: String
    var title: String
    var dateFinished: Date
}
