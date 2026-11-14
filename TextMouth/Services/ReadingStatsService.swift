import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// Tracks reading/listening statistics.
///
/// Listening time is credited while a session runs, not only when it ends:
/// every `checkpointInterval` a timer adds the open session's time since the
/// previous checkpoint to the totals and saves them, so a crash or force quit
/// loses at most one interval. `ActiveSession` states the rule that keeps any
/// second from being counted twice, `SleepNote` the one that keeps the time
/// the Mac sleeps from being counted at all, and `ListeningDays` the rules
/// for the local day each second is credited to and the key that day is
/// saved under.
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

    /// Tells what kind of book the book with an ID is, for Books Finished
    /// by kind (FR03): a text book, an audiobook, or a podcast episode, or
    /// nil when it can't tell, as for a book no longer in the library. The
    /// feed engine gives it, since it knows which audiobooks are its
    /// episodes (`FeedCenter.finishedBookKind(of:)`); nil until then.
    var finishedBookKind: (@MainActor (UUID) -> FinishedBookKind?)?

    /// The statistics file to use in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// Whether `stats` only stand in for reading_stats.json, left unread
    /// because the library model found the data directory unavailable when
    /// this service was made (FR02); the file is read once the library is
    /// back, so the empty stand-ins are never saved over it.
    private(set) var statsAwaitDataDirectory = false
    /// Hears when the data directory is available again.
    private var availabilitySubscription: AnyCancellable?

    /// Whether `stats` stand in for reading_stats.json, found only in the
    /// cloud (FR02 polish: several Macs): it was not read, since reading it
    /// here, on the main thread, would have waited on the network, and the
    /// sync service was asked for it. The stand-ins hold only the listening
    /// credited since, so no save replaces the file meanwhile, which would
    /// put this session's listening in place of all it holds: each save
    /// reads it again first, and once it is on this Mac, adds the stand-ins
    /// to what it holds and saves the sum.
    private(set) var statsAwaitFileInCloud = false

    /// Whether `stats` hold what reading_stats.json held when this service
    /// read it (REV14): true once the file was read and decoded, at launch,
    /// once the library is available again (`dataDirectoryBecameAvailable()`),
    /// or once a file that was only in the cloud is on this Mac and its
    /// statistics were added to the stand-ins (`mayReplaceStatsFile()`).
    /// False while the statistics only stand in for the file: with no file
    /// yet, with one that could not be read or decoded, which is preserved
    /// beside itself, with one only in the cloud, or with the data
    /// directory not there yet.
    ///
    /// The one-time move of finished books to their ends waits for it
    /// (`LibraryViewModel.moveFinishedBooksToTheirEndsOnce`): stand-ins list
    /// no finished book, so a move made over them would move nothing and be
    /// recorded as made, and would never run once the file could be read.
    private(set) var statsReadFromFile = false
    /// Reads reading_stats.json, with dataless files left in the cloud.
    private let readFile: SavedFile.Reader

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

    /// The system's awake clock: how long the Mac has been awake since it
    /// started, in seconds. It stops while the Mac sleeps, as the wall
    /// clock does not (`SleepNote`).
    nonisolated static func systemAwakeTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// A listening session in progress, and how much of it the totals
    /// already include.
    ///
    /// The rule that keeps any second from being counted twice: the totals
    /// include `start..<creditedThrough` exactly once, less the time the Mac
    /// slept (`SleepNote`), in the grand total, in `bookID`'s total, and in
    /// the daily totals, where each second is in the total of the local day
    /// it fell on, and include nothing after `creditedThrough`. Crediting,
    /// which each checkpoint and the final `endSession` do, adds only
    /// `creditedThrough..<time`, from the wake on should the Mac have slept
    /// in it, and then moves `creditedThrough` up to `time`. It never moves
    /// backwards, so a clock set back cannot credit the same time again
    /// either.
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
    private(set) var checkpointTimer: Timer?

    /// When the Mac said it was going to sleep, by the wall clock and by the
    /// awake clock (`awakeClock`), which stops while the Mac sleeps, so the
    /// wall clock runs ahead of it by exactly the time asleep. No second of
    /// that time is credited: a book left playing as the lid closes for a
    /// night is not a night of listening.
    ///
    /// The awake clock is why the rule holds whatever order the wake's
    /// events come in. The Mac's notices alone would not do: the checkpoint
    /// timer runs on a clock that stops in sleep too, so its first tick
    /// after a wake can come before AppKit delivers the wake's notice, and
    /// so can a reader ending its session as the audio comes back; and an
    /// app can miss either notice altogether. Every credit made while a
    /// note is kept finds the wake by the awake clock instead
    /// (`creditStart(of:at:)`), from the timer, a session's end, or the
    /// wake's notice alike.
    private struct SleepNote {
        /// When the Mac said it was going to sleep.
        let date: Date
        /// The awake clock's reading then, in seconds.
        let awakeTime: TimeInterval

        /// When the Mac woke, as found at `now`, while the awake clock reads
        /// `awakeNow`: the note's date moved on by every second the Mac has
        /// slept since, which the wall clock counted and the awake clock
        /// did not. What follows it up to `now` is exactly as long as the
        /// Mac has been awake since the note. It is the note's own date
        /// when the Mac never slept, as when a sleep was cancelled.
        func wake(seenAt now: Date, awakeNow: TimeInterval) -> Date {
            let asleep = now.timeIntervalSince(date) - (awakeNow - awakeTime)
            return date.addingTimeInterval(max(0, asleep))
        }
    }

    /// The Mac's last word that it was going to sleep, kept until it says it
    /// woke (`noteSystemDidWake(at:)`) or that it goes to sleep again; nil
    /// otherwise.
    private var sleepNote: SleepNote?

    /// Reads the awake clock: how long the Mac has been awake since it
    /// started, in seconds, a clock that stops while the Mac sleeps.
    private let awakeClock: () -> TimeInterval

    /// Hears the Mac say it is going to sleep.
    private var sleepSubscription: AnyCancellable?
    /// Hears the Mac say it woke.
    private var wakeSubscription: AnyCancellable?

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
    ///   - readFile: How the statistics file is read: with dataless files
    ///     left in the cloud, unless a test reads it otherwise.
    ///   - awakeClock: Reads the awake clock, which stops while the Mac
    ///     sleeps: the system's unless a test stands in its own.
    ///   - workspaceNotifications: Where the Mac says it is going to sleep
    ///     and that it woke: the shared workspace's notification center, the
    ///     only one AppKit posts them to, unless a test posts its own.
    init(
        fileURL: URL? = nil,
        checkpointInterval: TimeInterval = defaultCheckpointInterval,
        userCalendar: @escaping () -> Calendar = ReadingStatsService.systemCalendar,
        readFile: @escaping SavedFile.Reader = SavedFile.readWithoutDownloading,
        awakeClock: @escaping () -> TimeInterval = ReadingStatsService.systemAwakeTime,
        workspaceNotifications: NotificationCenter = {
            #if os(macOS)
            NSWorkspace.shared.notificationCenter
            #else
            // iOS has no workspace and no sleep or wake notices for now: an
            // unshared center, which nothing posts to, stands in.
            NotificationCenter()
            #endif
        }()
    ) {
        precondition(checkpointInterval > 0, "The checkpoint interval must be positive")
        customFileURL = fileURL
        self.checkpointInterval = checkpointInterval
        self.userCalendar = userCalendar
        self.readFile = readFile
        self.awakeClock = awakeClock
        // The time the Mac sleeps is never listening (`SleepNote`). AppKit
        // posts both notices on the main thread, the first before the Mac
        // sleeps, so its checkpoint is made while the app still runs.
        #if os(macOS)
        sleepSubscription = workspaceNotifications
            .publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.noteSystemWillSleep(at: Date()) }
        wakeSubscription = workspaceNotifications
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.noteSystemDidWake(at: Date()) }
        #endif
        if fileURL == nil {
            // Nothing is read from a data directory the library model found
            // unavailable (FR02): fresh statistics stand in until it is back.
            statsAwaitDataDirectory = TextMouthPaths.isDataDirectoryUnavailable
            availabilitySubscription = NotificationCenter.default
                .publisher(for: .dataDirectoryDidBecomeAvailable)
                .sink { [weak self] _ in self?.dataDirectoryBecameAvailable() }
        }
        if !statsAwaitDataDirectory {
            loadStatsFile()
        }
        migrateDayKeysIfNeeded(at: Date())
        startCheckpointTimer()
    }

    /// Reads reading_stats.json once the data directory is back, when the
    /// statistics in use only stood in for it (FR02). No book opens while
    /// the library is unavailable, so nothing was credited to the stand-ins.
    func dataDirectoryBecameAvailable() {
        guard statsAwaitDataDirectory, !TextMouthPaths.isDataDirectoryUnavailable else { return }
        statsAwaitDataDirectory = false
        loadStatsFile()
        migrateDayKeysIfNeeded(at: Date())
        PersistenceFailureCenter.shared.withdraw(.statistics)
        DiagnosticLog.event(.statistics, "READING_STATS_FILE: read the statistics now that the library is available")
    }

    /// Rewrites the day keys of statistics saved before TODO C06, which
    /// followed the system's calendar, as Gregorian keys
    /// (`ListeningDayKeyMigration`), logs what changed, and saves at once
    /// with `dayKeyVersion` set, so the migration runs, and logs, once.
    /// Keys this version writes are never read in another calendar. Does
    /// nothing for statistics already migrated or new, and waits for a
    /// later launch while the clock reads a date before TextMouth existed.
    private func migrateDayKeysIfNeeded(at now: Date) {
        guard let migrated = dayKeysMigrated(stats, at: now) else { return }
        stats = migrated
        save()
    }

    /// `saved` with day keys from before TODO C06 rewritten as Gregorian
    /// keys, with what changed logged, as `migrateDayKeysIfNeeded(at:)`
    /// describes; nil when they need no migration now.
    private func dayKeysMigrated(_ saved: ReadingStats, at now: Date) -> ReadingStats? {
        guard saved.dayKeyVersion == nil,
              let migration = ListeningDayKeyMigration(userCalendar: userCalendar(), now: now)
        else { return nil }
        let outcome = migration.migrate(saved.dailyListeningSeconds)
        var migrated = saved
        migrated.dailyListeningSeconds = outcome.dailyListeningSeconds
        migrated.dayKeyVersion = ListeningDays.keyVersion
        if let line = outcome.logLine {
            DiagnosticLog.event(.statistics, line)
        }
        return migrated
    }

    // MARK: - The Statistics File

    /// What reading_stats.json gives the service when it is read.
    private enum SavedStats {
        /// The statistics the file holds.
        case saved(ReadingStats)
        /// None: there is no file yet, or it can't be used.
        case none
        /// The file is only in the cloud, so it was not read.
        case inCloud
    }

    /// Reads reading_stats.json into `stats`: its statistics, or fresh ones
    /// when there is none yet or it can't be used, or, when it is only in
    /// the cloud, fresh ones that stand in for it until a save finds it on
    /// this Mac (`statsAwaitFileInCloud`), the sync service asked for it.
    /// Only the file's own statistics count as read (`statsReadFromFile`).
    private func loadStatsFile() {
        statsAwaitFileInCloud = false
        statsReadFromFile = false
        switch readSavedStats() {
        case .saved(let saved):
            stats = saved
            statsReadFromFile = true
        case .none:
            stats = ReadingStats()
        case .inCloud:
            stats = ReadingStats()
            statsAwaitFileInCloud = true
            SavedFile.requestDownload(of: fileURL)
            DiagnosticLog.event(
                .statistics,
                "READING_STATS_FILE: \(fileURL.lastPathComponent) is only in the cloud, so it was not read; "
                    + "asked the sync service for it, and this session's listening is kept in memory "
                    + "until the file is on this Mac"
            )
        }
    }

    /// What reading_stats.json holds, read with dataless files left in the
    /// cloud, so the read never waits on the network. A file that can't be
    /// read or decoded, such as one a write interrupted on another Mac cut
    /// short, holds none: it is preserved beside itself first, so the save
    /// that later replaces it loses nothing it held.
    private func readSavedStats() -> SavedStats {
        switch SavedFile.read(fileURL, using: readFile) {
        case .missing:
            return .none
        case .inCloud:
            return .inCloud
        case .contents(let data):
            do {
                return .saved(try Self.decodeStats(data))
            } catch {
                preserveUnusableStatsFile(bytes: data, because: error.localizedDescription)
                return .none
            }
        case .unreadable(let reason):
            preserveUnusableStatsFile(bytes: nil, because: reason)
            return .none
        }
    }

    /// Keeps a copy of reading_stats.json, which can't be used, beside it,
    /// holding `bytes` when they could be read, and logs why the statistics
    /// start afresh.
    private func preserveUnusableStatsFile(bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            fileURL,
            bytes: bytes,
            because: reason,
            logging: "READING_STATS_FILE",
            in: .statistics,
            standIn: "the statistics start afresh"
        )
    }

    /// Reads reading_stats.json again once it may be on this Mac, after it was
    /// found only in the cloud (`statsAwaitFileInCloud`), without waiting for
    /// a save: the listening credited meanwhile is added to what the file
    /// holds, as a save would do. Does nothing unless the file was waiting;
    /// while it still is, nothing is read or written.
    func fileMayHaveArrived() {
        guard statsAwaitFileInCloud else { return }
        _ = mayReplaceStatsFile()
    }

    /// Whether a save may replace reading_stats.json now: always, unless
    /// the file waits in the cloud (`statsAwaitFileInCloud`). Then it is read
    /// again first: once it is on this Mac, the listening credited meanwhile
    /// is added to what it holds, the wait ends, and the save goes on with
    /// the sum; while it is still in the cloud, nothing is written over it.
    /// The statistics count as read from the file (`statsReadFromFile`) only
    /// when the file held some.
    private func mayReplaceStatsFile() -> Bool {
        guard statsAwaitFileInCloud else { return true }
        let saved: ReadingStats
        let readFromFile: Bool
        switch readSavedStats() {
        case .inCloud:
            return false
        case .none:
            // The file went, or can't be used: the stand-ins are all there is.
            saved = ReadingStats()
            readFromFile = false
        case .saved(let found):
            saved = dayKeysMigrated(found, at: Date()) ?? found
            readFromFile = true
        }
        let standIn = stats
        stats = saved.adding(standIn)
        statsAwaitFileInCloud = false
        statsReadFromFile = readFromFile
        DiagnosticLog.event(
            .statistics,
            "READING_STATS_FILE: read the statistics now that the file is on this Mac, adding "
                + "\(Int(standIn.totalListeningSeconds.rounded())) seconds listened while it was in the cloud"
        )
        return true
    }

    /// Decodes reading_stats.json's bytes, as `write` encodes them.
    private static func decodeStats(_ data: Data) throws -> ReadingStats {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReadingStats.self, from: data)
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
    /// follows. Time the Mac slept since is left out (`SleepNote`). The
    /// slice is split at every local midnight it crosses, in the time zone
    /// current now, so each day gets exactly the seconds heard on it
    /// (`ListeningDays.split`). Does nothing without an open session or
    /// while it is too short to count.
    func checkpointActiveSession(at time: Date = Date()) {
        guard let session = activeSession, uncreditedSessionTime(at: time) > 0 else { return }
        // Credit every piece to a copy and publish the result once, so no
        // observer ever sees a slice half credited.
        var credited = stats
        for piece in listeningDays.split(from: creditStart(of: session, at: time), to: time) {
            credited.addListening(piece.seconds, bookID: session.bookID, dayKey: piece.dayKey)
        }
        stats = credited
        activeSession?.creditedThrough = time
        save()
    }

    /// The open session's time that the totals do not include yet: what
    /// ending it at `time` would add. Zero without an open session, while the
    /// session is too short to count, and when `time` is not after its last
    /// checkpoint because the clock was set back. Time the Mac slept since
    /// that checkpoint is not counted (`SleepNote`).
    func uncreditedSessionTime(at time: Date) -> TimeInterval {
        guard let session = activeSession,
              time.timeIntervalSince(session.start) > Self.longestIgnoredSession
        else { return 0 }
        return max(0, time.timeIntervalSince(creditStart(of: session, at: time)))
    }

    /// The part of the open session's uncredited time from `start` on: what
    /// ending the session at `now` would credit to the days that begin at
    /// `start`, since crediting splits time at midnight. Zero whenever
    /// `uncreditedSessionTime(at:)` is.
    private func uncreditedSessionTime(at now: Date, since start: Date) -> TimeInterval {
        guard let session = activeSession, uncreditedSessionTime(at: now) > 0 else { return 0 }
        return max(0, now.timeIntervalSince(max(creditStart(of: session, at: now), start)))
    }

    /// Where crediting `session` at `time` begins: the end of what the
    /// totals include, or, should the Mac have slept since it last said it
    /// would (`sleepNote`), the moment it woke, found by the awake clock,
    /// whichever is later. Every credit and every total read goes through
    /// here, so none counts a second of the sleep, whatever order the
    /// wake's events come in.
    private func creditStart(of session: ActiveSession, at time: Date) -> Date {
        guard let sleepNote else { return session.creditedThrough }
        return max(session.creditedThrough, sleepNote.wake(seenAt: time, awakeNow: awakeClock()))
    }

    /// Whether a listening session is open.
    var hasActiveSession: Bool {
        activeSession != nil
    }

    /// Records that the book `bookID`, titled `title`, played or was read to
    /// its end now: Books Finished counts it, once (TODO P07), and whoever
    /// follows finished books hears of it (`.bookDidFinish`).
    ///
    /// The user decided on October 10, 2026: "yes, only one finish per book
    /// for now". A book Books Finished counts already is not counted again,
    /// whatever ends it how many times, so nothing is written for it. A book
    /// counted for the first time is written with what kind of book it is
    /// (`finishedBookKind`), told while the library still holds it: a podcast
    /// episode's download is deleted soon after it plays, and nothing could
    /// tell its kind later.
    ///
    /// Either way the end is told (`.bookDidFinish`), as the feed engine marks
    /// a downloaded episode or article played then (FR03): an item marked
    /// unplayed and heard to its end again is played again. A reader whose
    /// rewind after the end replays a finished book's end does not call
    /// this at all (`ReaderViewModel.finishAtTheEnd(replayingAFinishedEnd:)`).
    ///
    /// - Returns: Whether Books Finished counted the book now, for the first
    ///   time.
    @discardableResult
    func markBookFinished(bookID: UUID, title: String) -> Bool {
        let isCountedAlready = stats.finishedBooks.contains { $0.bookID == bookID.uuidString }
        if !isCountedAlready {
            let entry = FinishedBookEntry(
                bookID: bookID.uuidString,
                title: title,
                dateFinished: Date(),
                kind: finishedBookKind?(bookID)
            )
            stats.finishedBooks.append(entry)
            save()
        }
        // Whoever follows finished books hears of this one, as the feed
        // engine marks a downloaded episode or article played (FR03).
        NotificationCenter.default.post(name: .bookDidFinish, object: self, userInfo: [Self.finishedBookIDKey: bookID])
        return !isCountedAlready
    }

    /// The key of the finished book's ID in a `.bookDidFinish` notification.
    nonisolated static let finishedBookIDKey = "bookID"

    // MARK: - The Mac's Sleep

    /// The Mac is going to sleep, as it said at `time`: everything heard so
    /// far is credited and its save begun, and the moment is noted with the
    /// awake clock's reading (`SleepNote`), so that no credit after it
    /// counts the time asleep. The session stays open, since playback may
    /// go on after the wake.
    func noteSystemWillSleep(at time: Date) {
        checkpointActiveSession(at: time)
        sleepNote = SleepNote(date: time, awakeTime: awakeClock())
    }

    /// The Mac woke, as it said at `time`: the open session goes on, its
    /// credit beginning no earlier than the wake, never moving backwards,
    /// and the note of the sleep is done with. When the Mac said beforehand
    /// that it was going to sleep, the wake is the one the awake clock
    /// finds, so a credit made before this notice, which already left the
    /// sleep out, loses nothing. When it said nothing, the wake is `time`:
    /// the sleep is left out all the same, at the cost of what was heard
    /// between the last checkpoint and the sleep. With no open session
    /// there is nothing to move.
    func noteSystemDidWake(at time: Date) {
        if let session = activeSession {
            let wake = sleepNote?.wake(seenAt: time, awakeNow: awakeClock()) ?? time
            activeSession?.creditedThrough = max(session.creditedThrough, wake)
        }
        sleepNote = nil
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

    /// Listening time over all time at `now`: the saved grand total plus
    /// the open session's time since its last checkpoint, which the next
    /// checkpoint will add to it. Like Today and This Week it adds only that
    /// remainder, since the checkpointed part is already in the total, so
    /// All Time never lags Today while a book plays. Unlike them it needs
    /// no split at midnight: every day counts.
    func allTimeListeningTime(at now: Date) -> TimeInterval {
        stats.totalListeningSeconds + uncreditedSessionTime(at: now)
    }

    /// Books finished in the current year.
    var booksFinishedThisYear: Int {
        booksFinishedThisYear(at: Date())
    }

    /// Books finished in the year containing `now`, in the system's
    /// calendar, so a display can read this at the same instant as the
    /// listening times. Each book counts once, in the year of the finish
    /// Books Finished counts (`ReadingStats.countedFinishes`, TODO P07).
    func booksFinishedThisYear(at now: Date) -> Int {
        finishedBooks(inYearOf: now).count
    }

    /// The books finished in the year containing `now`, in the system's
    /// calendar: the year each counted finish falls in, whatever its kind.
    private func finishedBooks(inYearOf now: Date) -> [FinishedBookEntry] {
        let year = Calendar.current.component(.year, from: now)
        return stats.countedFinishes.filter {
            Calendar.current.component(.year, from: $0.dateFinished) == year
        }
    }

    /// The books finished in the year containing `now`, counted by kind.
    func booksFinishedThisYearByKind(at now: Date) -> FinishedBookCounts {
        FinishedBookCounts(kinds: finishedBooks(inYearOf: now).map(kind(of:)))
    }

    /// The books finished ever, each counted once (TODO P07): how many
    /// books Books Finished All Time says.
    var booksFinishedAllTime: Int {
        stats.countedFinishes.count
    }

    /// The books finished ever, each counted once, by kind.
    var booksFinishedAllTimeByKind: FinishedBookCounts {
        FinishedBookCounts(kinds: stats.countedFinishes.map(kind(of:)))
    }

    /// The kind of the book `entry` counts: the one recorded as it finished,
    /// or, for a book finished before TextMouth recorded kinds, the one
    /// `finishedBookKind` tells while the library still holds the book;
    /// nil when neither knows.
    private func kind(of entry: FinishedBookEntry) -> FinishedBookKind? {
        entry.kind ?? UUID(uuidString: entry.bookID).flatMap { finishedBookKind?($0) }
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
    /// are dispatched asynchronously. Nothing is written while the file
    /// waits in the cloud (`mayReplaceStatsFile()`).
    func save() {
        guard mayReplaceStatsFile() else { return }
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
    /// file is now, which moves when the data directory does. Nothing is
    /// written while the file waits in the cloud (`mayReplaceStatsFile()`).
    func retrySave(failureID: PersistenceFailure.ID) {
        guard mayReplaceStatsFile() else { return }
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
        // A checkpoint is bookkeeping nobody hears: let macOS coalesce it.
        TimerCoalescing.loosen(timer)
        RunLoop.main.add(timer, forMode: .common)
        checkpointTimer = timer
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
    /// Books that have been finished, oldest first, as each finish was
    /// written: one entry for each book since TextMouth counts each book
    /// once (TODO P07), and more for a book an earlier version counted at
    /// each of its ends, which are kept as they were and counted once
    /// (`countedFinishes`).
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

    /// These statistics with `other`'s added: its listening to each day,
    /// each book, and the total, and the books it finished that these don't
    /// list yet. Statistics that stood in for a file only in the cloud are
    /// added so to what the file holds once it is read. The day keys stay
    /// these statistics' own version.
    func adding(_ other: ReadingStats) -> ReadingStats {
        var sum = self
        sum.dailyListeningSeconds.merge(other.dailyListeningSeconds, uniquingKeysWith: +)
        sum.totalListeningSeconds += other.totalListeningSeconds
        sum.bookListeningSeconds.merge(other.bookListeningSeconds, uniquingKeysWith: +)
        for entry in other.finishedBooks where !sum.finishedBooks.contains(where: {
            $0.bookID == entry.bookID && $0.dateFinished == entry.dateFinished
        }) {
            sum.finishedBooks.append(entry)
        }
        return sum
    }

    // MARK: Books Finished, Each Once (TODO P07)

    /// How many books Recently Finished lists.
    static let recentlyFinishedLimit = 10

    /// The finishes Books Finished counts: each book once, by the first
    /// entry naming it, in the order the entries were written. The user
    /// decided on October 10, 2026: "yes, only one finish per book for now".
    /// An earlier version wrote an entry at each end of a book, a finish
    /// heard again or replayed by Play at the end, and those entries are
    /// kept in the file as they were, and counted once: the user's
    /// statistics held 67 entries for 28 books, and Books Finished counts 28.
    var countedFinishes: [FinishedBookEntry] {
        var counted = Set<String>()
        return finishedBooks.filter { counted.insert($0.bookID).inserted }
    }

    /// The books Recently Finished lists, newest first: the last `limit`
    /// finishes Books Finished counts (`countedFinishes`), so each book is
    /// listed once, by the finish it counts. Its rows were once the last
    /// entries, one book nine times among the user's ten.
    func recentlyFinished(limit: Int = recentlyFinishedLimit) -> [FinishedBookEntry] {
        Array(countedFinishes.suffix(limit).reversed())
    }
}

/// One book counted among Books Finished.
struct FinishedBookEntry: Codable, Identifiable {
    var bookID: String
    var title: String
    var dateFinished: Date
    /// What kind of book it was, when known (FR03): told as it finished.
    /// None for a book finished before TextMouth recorded kinds, or one it
    /// could not tell, which Books Finished counts by the library's answer
    /// while the library holds it.
    var kind: FinishedBookKind?

    /// The entry's own identity, its book and the moment it finished, by
    /// which Recently Finished keys its rows: no two entries share it,
    /// while two entries an earlier version wrote for one book share their
    /// book's ID (TODO P07).
    var id: String {
        "\(bookID) \(dateFinished.timeIntervalSinceReferenceDate)"
    }

    /// The keys of an entry in reading_stats.json.
    private enum CodingKeys: String, CodingKey {
        case bookID, title, dateFinished, kind
    }

    /// An entry for the book `bookID`, titled `title`, finished at
    /// `dateFinished`, of the kind `kind` when known.
    init(bookID: String, title: String, dateFinished: Date, kind: FinishedBookKind? = nil) {
        self.bookID = bookID
        self.title = title
        self.dateFinished = dateFinished
        self.kind = kind
    }

    /// Reads an entry. A kind this version does not know, as a later
    /// version might write, reads as none, so it never makes the
    /// statistics unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try container.decode(String.self, forKey: .bookID)
        title = try container.decode(String.self, forKey: .title)
        dateFinished = try container.decode(Date.self, forKey: .dateFinished)
        kind = try? container.decodeIfPresent(FinishedBookKind.self, forKey: .kind)
    }
}

/// What kind of book a finished book was, as Books Finished counts them
/// (FR03): a text book, which an article a feed downloaded is too; an
/// audiobook; or a podcast episode, an audiobook a feed downloaded.
enum FinishedBookKind: String, Codable, CaseIterable, Sendable {
    case text
    case audiobook
    case episode

    /// The kind of a book in `format`, which a feed downloaded when
    /// `isFeedDownload`: a podcast episode for audio a feed downloaded, an
    /// audiobook for any other audio, and a text book for anything else.
    static func of(format: BookFormat, isFeedDownload: Bool) -> FinishedBookKind {
        guard format.isAudio else { return .text }
        return isFeedDownload ? .episode : .audiobook
    }
}

extension Notification.Name {
    /// A book played or was read to its end
    /// (`ReadingStatsService.markBookFinished(bookID:title:)`): posted by the
    /// statistics service told of it, naming the book under
    /// `ReadingStatsService.finishedBookIDKey`, at each such end, whether
    /// Books Finished counted the book then or had counted it already, since
    /// it counts each book once (TODO P07). A rewind's replay of a finished
    /// book's end posts nothing: the book had ended already.
    static let bookDidFinish = Notification.Name("bookDidFinish")
}
