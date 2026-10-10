import Combine
import XCTest
@testable import TextMouth

/// Listening time is credited while a session runs, so a crash loses at most
/// one checkpoint interval and no second is ever counted twice (TODO C05).
/// Each test drives its own services over a disposable statistics file under
/// the isolated test data root, so neither the shared service nor another
/// test's numbers are touched, and explicit times stand in for the
/// checkpoint timer's ticks. Set-up and tear-down hold only plain values;
/// each test makes its services on the main actor.
final class ReadingStatsServiceTests: XCTestCase {
    /// The spacing of the simulated checkpoints: the app's own interval.
    private let interval = ReadingStatsService.defaultCheckpointInterval
    /// Directory holding this test's statistics file, removed afterwards.
    private var directory: URL!
    /// The statistics file this test's services read and write.
    private var fileURL: URL!
    /// Local noon on an ordinary summer day (15 July 2026), far from
    /// midnight and from any daylight-saving change, so a session starting
    /// here stays on one day. Times in whole and quarter seconds keep every
    /// sum exact.
    private var noon: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TextMouthPaths.root.appendingPathComponent(
            "ReadingStatsServiceTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("reading_stats.json")
        noon = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_784_116_800) // 2026-07-15 12:00 UTC
        ))
    }

    override func tearDownWithError() throws {
        // Queued writes target the directory; let them land before removing it.
        ReadingStatsService.waitForQueuedSaves()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Statistics file

    /// A service given its own file saves there, and a new service over the
    /// same file starts with what was saved, as the next launch does.
    @MainActor
    func testServiceSavesToItsOwnFileAndTheNextLaunchLoadsIt() {
        let service = makeService()
        let book = UUID()
        service.startSession(bookID: book, at: noon)
        service.endSession(at: noon + 90)

        let relaunched = relaunchedService()
        XCTAssertEqual(relaunched.stats.totalListeningSeconds, 90)
        XCTAssertEqual(relaunched.stats.bookListeningSeconds, [book.uuidString: 90])
        XCTAssertFalse(relaunched.hasActiveSession)
    }

    /// Only statistics read from their file say so (REV14), which the
    /// one-time move of finished books waits for: statistics standing in
    /// for no file yet, for a file cut short, or for a file only in the
    /// cloud say they were not read, and saving them does not change that;
    /// statistics read from the file say they were, and so do stand-ins
    /// once their file is on this Mac and they were added to what it holds.
    @MainActor
    func testOnlyStatisticsReadFromTheirFileSaySo() throws {
        let fresh = makeService()
        XCTAssertFalse(fresh.statsReadFromFile, "Statistics with no file yet said they were read from it")
        fresh.markBookFinished(bookID: UUID(), title: "Read Before")
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertFalse(fresh.statsReadFromFile, "Saving statistics that stood in made them read")

        let relaunched = relaunchedService()
        XCTAssertTrue(relaunched.statsReadFromFile, "Statistics read from their file said they were not")
        XCTAssertEqual(relaunched.stats.finishedBooks.map(\.title), ["Read Before"])

        // Cut short, as a write interrupted on another Mac leaves it.
        let whole = try Data(contentsOf: fileURL)
        try whole.prefix(whole.count / 2).write(to: fileURL)
        let cut = relaunchedService()
        XCTAssertFalse(cut.statsReadFromFile, "Statistics standing in for a file cut short said they were read")
        XCTAssertEqual(cut.stats.finishedBooks.map(\.title), [])

        // Only in the cloud, then on this Mac by the next save.
        try whole.write(to: fileURL)
        let previousItemStatus = CloudServices.itemStatus
        CloudServices.itemStatus = FakeCloudItemStatusProvider()
        addTeardownBlock { @MainActor in CloudServices.itemStatus = previousItemStatus }
        var isInCloud = true
        let waiting = ReadingStatsService(fileURL: fileURL, readFile: { url in
            // A dataless file refuses a read that would download it.
            guard !isInCloud else { throw POSIXError(.EDEADLK) }
            return try Data(contentsOf: url)
        })
        addTeardownBlock { @MainActor in waiting.shutdown() }
        XCTAssertTrue(waiting.statsAwaitFileInCloud)
        XCTAssertFalse(waiting.statsReadFromFile, "Statistics standing in for a file in the cloud said they were read")

        isInCloud = false
        waiting.markBookFinished(bookID: UUID(), title: "Read Meanwhile")
        XCTAssertFalse(waiting.statsAwaitFileInCloud)
        XCTAssertTrue(waiting.statsReadFromFile, "Statistics added to their file's did not say they were read")
        XCTAssertEqual(waiting.stats.finishedBooks.map(\.title).sorted(), ["Read Before", "Read Meanwhile"])
    }

    /// The app's service follows the data directory in use, which the user
    /// can move, instead of a file fixed when the service was created.
    @MainActor
    func testSharedServiceFollowsTheDataDirectory() {
        XCTAssertEqual(ReadingStatsService.shared.fileURL, TextMouthPaths.readingStatsFile)
    }

    // MARK: - Checkpoints

    /// Checkpoints credit a session as it runs and its end adds only the
    /// rest, so five intervals and a remainder add up to the session's
    /// length, counted once, in every total and on disk.
    @MainActor
    func testFiveCheckpointsAndARemainderCreditTheWholeSessionOnce() {
        let service = makeService()
        let book = UUID()
        let length = 5 * interval + 17.5
        service.startSession(bookID: book, at: noon)

        for checkpoint in 1...5 {
            service.checkpointActiveSession(at: noon + Double(checkpoint) * interval)
            XCTAssertEqual(service.stats.totalListeningSeconds, Double(checkpoint) * interval)
            XCTAssertTrue(service.hasActiveSession)
        }
        service.endSession(at: noon + length)

        XCTAssertFalse(service.hasActiveSession)
        XCTAssertEqual(service.stats.totalListeningSeconds, length)
        XCTAssertEqual(service.stats.bookListeningSeconds, [book.uuidString: length])
        XCTAssertEqual(service.stats.dailyListeningSeconds, [ReadingStatsService.dateKey(noon): length])
        XCTAssertEqual(relaunchedService().stats.totalListeningSeconds, length)

        // Nothing is left to credit: ending again or checkpointing adds nothing.
        service.endSession(at: noon + 2 * length)
        service.checkpointActiveSession(at: noon + 2 * length)
        XCTAssertEqual(service.stats.totalListeningSeconds, length)
    }

    /// A crash loses at most one checkpoint interval. Each checkpoint saves
    /// the session so far, so a crash 59 seconds after the third finds three
    /// intervals on disk and loses only those 59 seconds. The next launch
    /// starts from exactly that, with no open session: nothing about the
    /// lost session is resumed, so ending one there adds nothing.
    @MainActor
    func testCrashAfterCheckpointsLosesOnlyTheTimeSinceTheLastOne() {
        let service = makeService()
        let book = UUID()
        service.startSession(bookID: book, at: noon)
        for checkpoint in 1...3 {
            let credited = Double(checkpoint) * interval
            service.checkpointActiveSession(at: noon + credited)
            XCTAssertEqual(
                relaunchedService().stats.totalListeningSeconds, credited, "Saved by checkpoint \(checkpoint)"
            )
        }

        // The app dies 59 seconds later. Nothing ends the session, flushes,
        // or saves again, so only what the checkpoints wrote survives.
        let crash = noon + 3 * interval + 59
        let relaunched = relaunchedService()

        XCTAssertEqual(relaunched.stats.totalListeningSeconds, 3 * interval)
        XCTAssertEqual(relaunched.stats.bookListeningSeconds, [book.uuidString: 3 * interval])
        XCTAssertEqual(relaunched.stats.dailyListeningSeconds, [ReadingStatsService.dateKey(noon): 3 * interval])
        XCTAssertLessThan(crash.timeIntervalSince(noon) - relaunched.stats.totalListeningSeconds, interval)
        XCTAssertFalse(relaunched.hasActiveSession)
        relaunched.endSession(at: crash + interval)
        XCTAssertEqual(relaunched.stats.totalListeningSeconds, 3 * interval)
    }

    /// Starting a session for another book ends the open one at that moment:
    /// the first book gets exactly its time up to the switch, its
    /// checkpointed part counted once, and the second is credited from there.
    @MainActor
    func testStartingAnotherBookCreditsTheFirstUpToTheSwitch() {
        let service = makeService()
        let first = UUID()
        let second = UUID()
        service.startSession(bookID: first, at: noon)
        service.checkpointActiveSession(at: noon + interval)

        service.startSession(bookID: second, at: noon + 100)
        service.checkpointActiveSession(at: noon + 100 + interval)
        service.endSession(at: noon + 175)

        let expected = [first.uuidString: 100.0, second.uuidString: 75.0]
        XCTAssertEqual(service.stats.bookListeningSeconds, expected)
        XCTAssertEqual(service.stats.totalListeningSeconds, 175)
        XCTAssertEqual(relaunchedService().stats.bookListeningSeconds, expected)
    }

    /// A session of one second or less counts for nothing, as before
    /// checkpoints: checkpoints within it credit nothing, its end adds
    /// nothing, and nothing is written.
    @MainActor
    func testSessionOfOneSecondOrLessCreditsNothing() {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)

        service.checkpointActiveSession(at: noon + 0.5)
        service.checkpointActiveSession(at: noon + 1)
        XCTAssertEqual(service.uncreditedSessionTime(at: noon + 1), 0)
        service.endSession(at: noon + 1)

        XCTAssertFalse(service.hasActiveSession)
        XCTAssertEqual(service.stats.totalListeningSeconds, 0)
        XCTAssertEqual(service.stats.bookListeningSeconds, [:])
        XCTAssertEqual(service.stats.dailyListeningSeconds, [:])
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A checkpoint made while a session is too short to count does not
    /// move its start: past one second, the session counts in full.
    @MainActor
    func testSessionLongerThanOneSecondCountsFromItsStart() {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)

        service.checkpointActiveSession(at: noon + 0.5)
        service.endSession(at: noon + 1.25)

        XCTAssertEqual(service.stats.totalListeningSeconds, 1.25)
    }

    /// Each credit reaches the grand total, one book's total, and one day's
    /// total together, so the daily and per-book totals always add up to
    /// the grand total: across books, checkpoints, a switch, and midnight.
    @MainActor
    func testDailyAndPerBookTotalsAlwaysAddUpToTheGrandTotal() {
        let service = makeService()
        let midnight = Calendar.current.startOfDay(for: noon)
        service.startSession(bookID: UUID(), at: midnight - 90)
        service.checkpointActiveSession(at: midnight - 30)
        assertTotalsAgree(service.stats)

        service.startSession(bookID: UUID(), at: midnight + 10.25)
        assertTotalsAgree(service.stats)
        service.checkpointActiveSession(at: midnight + 70.25)
        service.endSession(at: midnight + 95.5)

        assertTotalsAgree(service.stats)
        XCTAssertEqual(service.stats.totalListeningSeconds, 185.5)
        XCTAssertEqual(service.stats.dailyListeningSeconds.count, 2)
        XCTAssertEqual(service.stats.bookListeningSeconds.count, 2)
        assertTotalsAgree(relaunchedService().stats)
    }

    /// A checkpoint whose slice straddles midnight splits it there: the day
    /// before gets the seconds up to midnight and the new day the rest
    /// (TODO C06). Until C06 the whole slice went to the day the checkpoint
    /// was made on. ReadingStatsDayAttributionTests covers the split fully.
    @MainActor
    func testCheckpointSplitsTheSliceThatStraddlesMidnight() {
        let service = makeService()
        let midnight = Calendar.current.startOfDay(for: noon)
        let dayBefore = ReadingStatsService.dateKey(midnight - 1)
        let dayAfter = ReadingStatsService.dateKey(midnight)
        XCTAssertNotEqual(dayBefore, dayAfter)
        service.startSession(bookID: UUID(), at: midnight - 90)

        service.checkpointActiveSession(at: midnight - 30)
        service.checkpointActiveSession(at: midnight + 30)
        service.endSession(at: midnight + 45)

        // 60 s before midnight, then a 60 s slice split 30 s and 30 s, and 15 s after.
        XCTAssertEqual(service.stats.dailyListeningSeconds, [dayBefore: 90, dayAfter: 45])
        XCTAssertEqual(service.stats.totalListeningSeconds, 135)
    }

    /// Credited time is never credited again, even when the clock is set
    /// back: a checkpoint or an end before the last checkpoint adds nothing,
    /// and crediting resumes only after it.
    @MainActor
    func testClockSetBackNeverCreditsTheSameTimeTwice() {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)
        service.checkpointActiveSession(at: noon + 2 * interval)

        service.checkpointActiveSession(at: noon + interval)
        XCTAssertEqual(service.stats.totalListeningSeconds, 2 * interval)
        service.checkpointActiveSession(at: noon + 2 * interval + 5)
        XCTAssertEqual(service.stats.totalListeningSeconds, 2 * interval + 5)
        service.endSession(at: noon + interval)

        XCTAssertEqual(service.stats.totalListeningSeconds, 2 * interval + 5)
        XCTAssertFalse(service.hasActiveSession)
    }

    // MARK: - Checkpoint timer

    /// The app checkpoints every minute, so a crash loses at most a minute
    /// of listening.
    @MainActor
    func testSharedServiceCheckpointsEveryMinute() {
        XCTAssertEqual(ReadingStatsService.defaultCheckpointInterval, 60)
        XCTAssertEqual(ReadingStatsService.shared.checkpointInterval, 60)
    }

    /// The timer checkpoints an open session by itself: a session that has
    /// run for half a minute is credited and saved while it stays open, and
    /// its end then adds only the rest, so it is counted exactly once.
    @MainActor
    func testTimerCheckpointsAnOpenSessionAndSavesIt() {
        let service = makeService(checkpointInterval: 0.05)
        let start = Date().addingTimeInterval(-30)
        service.startSession(bookID: UUID(), at: start)

        let checkpoint = expectation(description: "The timer credited the open session")
        let subscription = service.$stats
            .first { $0.totalListeningSeconds > 0 }
            .sink { _ in checkpoint.fulfill() }
        defer { subscription.cancel() }
        wait(for: [checkpoint], timeout: 10)

        XCTAssertTrue(service.hasActiveSession)
        XCTAssertGreaterThanOrEqual(service.stats.totalListeningSeconds, 30)
        XCTAssertEqual(relaunchedService().stats.totalListeningSeconds, service.stats.totalListeningSeconds)
        let end = Date()
        service.endSession(at: end)
        XCTAssertEqual(service.stats.totalListeningSeconds, end.timeIntervalSince(start))
    }

    /// Shutting down stops the timer, so however many intervals pass, an
    /// open session is no longer checkpointed.
    @MainActor
    func testShutdownStopsTheTimersCheckpoints() {
        let service = makeService(checkpointInterval: 0.05)
        service.shutdown()
        service.startSession(bookID: UUID(), at: Date().addingTimeInterval(-30))

        let checkpoint = expectation(description: "A checkpoint after shutdown")
        checkpoint.isInverted = true
        let subscription = service.$stats
            .first { $0.totalListeningSeconds > 0 }
            .sink { _ in checkpoint.fulfill() }
        defer { subscription.cancel() }
        wait(for: [checkpoint], timeout: 0.5)

        XCTAssertEqual(service.stats.totalListeningSeconds, 0)
        XCTAssertTrue(service.hasActiveSession)
    }

    // MARK: - Flushing at quit

    /// Flushing during a session saves its time so far and leaves it open,
    /// and the file is complete when the flush returns. The end then adds
    /// only the rest, and flushing after the end adds nothing.
    @MainActor
    func testFlushDuringASessionSavesItsTimeAndTheEndAddsOnlyTheRest() {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)

        service.flushPendingSaves(at: noon + 90)

        XCTAssertTrue(service.hasActiveSession)
        // Loaded without waiting again: the flush itself waited for the write.
        XCTAssertEqual(makeService().stats.totalListeningSeconds, 90)
        service.endSession(at: noon + 100)
        service.flushPendingSaves(at: noon + 200)
        XCTAssertEqual(service.stats.totalListeningSeconds, 100)
        XCTAssertEqual(makeService().stats.totalListeningSeconds, 100)
    }

    // MARK: - Displayed totals

    /// Today and This Week add only the open session's time since its last
    /// checkpoint, since the checkpointed part is already in the day's
    /// total; adding the whole session would count that part twice. Once
    /// the session ends, both show the same values as just before.
    @MainActor
    func testTodayAndThisWeekAddOnlyTheOpenSessionsUncreditedTime() throws {
        let service = makeService()
        let twoDaysEarlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: noon))
        service.startSession(bookID: UUID(), at: twoDaysEarlier)
        service.endSession(at: twoDaysEarlier + 1_000)
        service.startSession(bookID: UUID(), at: noon)
        service.checkpointActiveSession(at: noon + 2 * interval)
        let now = noon + 2 * interval + 30

        XCTAssertEqual(service.uncreditedSessionTime(at: now), 30)
        XCTAssertEqual(service.todayListeningTime(at: now), 2 * interval + 30)
        XCTAssertEqual(service.thisWeekListeningTime(at: now), 1_000 + 2 * interval + 30)

        service.endSession(at: now)

        XCTAssertEqual(service.uncreditedSessionTime(at: now), 0)
        XCTAssertEqual(service.todayListeningTime(at: now), 2 * interval + 30)
        XCTAssertEqual(service.thisWeekListeningTime(at: now), 1_000 + 2 * interval + 30)
    }

    /// All Time adds the open session's time since its last checkpoint to
    /// the saved total, as Today does, so it never lags Today while a book
    /// plays (TODO C07): until then it showed the saved total alone, up to
    /// a checkpoint interval behind. At every moment of the session it
    /// exceeds Today by exactly the listening before today, and once the
    /// session ends the saved total alone gives the same value.
    @MainActor
    func testAllTimeAddsOnlyTheOpenSessionsUncreditedTime() throws {
        let service = makeService()
        let twoDaysEarlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: noon))
        service.startSession(bookID: UUID(), at: twoDaysEarlier)
        service.endSession(at: twoDaysEarlier + 1_000)
        service.startSession(bookID: UUID(), at: noon)
        service.checkpointActiveSession(at: noon + 2 * interval)

        // From the checkpoint itself to just before the next one.
        for sinceCheckpoint in [0, 30, 59.5] {
            let now = noon + 2 * interval + sinceCheckpoint
            XCTAssertEqual(service.allTimeListeningTime(at: now), 1_000 + 2 * interval + sinceCheckpoint)
            XCTAssertEqual(
                service.allTimeListeningTime(at: now) - service.todayListeningTime(at: now), 1_000,
                "\(sinceCheckpoint) s after the checkpoint"
            )
        }

        let end = noon + 2 * interval + 30
        service.endSession(at: end)

        XCTAssertEqual(service.allTimeListeningTime(at: end), 1_000 + 2 * interval + 30)
        XCTAssertEqual(service.allTimeListeningTime(at: end), service.stats.totalListeningSeconds)
    }

    /// While a session crosses midnight, All Time counts its whole
    /// uncredited slice and Today only the part after midnight: the part
    /// before belongs to yesterday, which All Time includes as well.
    @MainActor
    func testAllTimeCountsTheWholeUncreditedSliceAcrossMidnight() {
        let service = makeService()
        let midnight = Calendar.current.startOfDay(for: noon)
        service.startSession(bookID: UUID(), at: midnight - 90)
        service.checkpointActiveSession(at: midnight - 30)
        let now = midnight + 45

        XCTAssertEqual(service.uncreditedSessionTime(at: now), 75)
        XCTAssertEqual(service.todayListeningTime(at: now), 45)
        XCTAssertEqual(service.allTimeListeningTime(at: now), 135)

        service.endSession(at: now)

        XCTAssertEqual(service.allTimeListeningTime(at: now), 135)
        XCTAssertEqual(service.stats.totalListeningSeconds, 135)
    }

    /// Books Finished This Year counts the books finished in the year
    /// containing the instant asked about, from its first moment on, so the
    /// Stats pane can read it at the same instant as every other figure.
    @MainActor
    func testBooksFinishedThisYearCountsTheYearContainingTheInstant() throws {
        let service = makeService()
        let calendar = Calendar.current
        let sameDayLastYear = try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: noon))
        let startOfYear = try XCTUnwrap(calendar.date(from: calendar.dateComponents([.era, .year], from: noon)))
        service.stats.finishedBooks = [sameDayLastYear, startOfYear, noon - 3_600].map { date in
            FinishedBookEntry(bookID: UUID().uuidString, title: "Finished \(date)", dateFinished: date)
        }

        XCTAssertEqual(service.booksFinishedThisYear(at: noon), 2)
        XCTAssertEqual(service.booksFinishedThisYear(at: startOfYear), 2)
        XCTAssertEqual(service.booksFinishedThisYear(at: startOfYear - 1), 1, "The last second of the year before")
        XCTAssertEqual(service.booksFinishedThisYear(at: sameDayLastYear), 1)
    }

    // MARK: - Helpers

    /// A service over this test's file, checkpointing every
    /// `checkpointInterval`. Its timer stops when the test ends.
    // MARK: - Books Finished by Kind

    /// A finished book is saved with the kind the library tells as it
    /// finishes, which the next launch reads back; a book the library can't
    /// tell is saved with none. Books are counted by kind all time and in
    /// the year they finished; one finished before kinds were recorded is
    /// counted by the library's answer while the library holds it, and in
    /// no kind after.
    @MainActor
    func testFinishedBooksAreRecordedAndCountedByKind() throws {
        let service = makeService()
        let (audiobook, episode, article, gone) = (UUID(), UUID(), UUID(), UUID())
        let kinds: [UUID: FinishedBookKind] = [audiobook: .audiobook, episode: .episode, article: .text]
        service.finishedBookKind = { kinds[$0] }

        service.markBookFinished(bookID: episode, title: "An episode")
        service.markBookFinished(bookID: gone, title: "No longer held")
        XCTAssertEqual(service.stats.finishedBooks.map(\.kind), [.episode, nil])
        XCTAssertEqual(relaunchedService().stats.finishedBooks.map(\.kind), [.episode, nil])

        let lastYear = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -1, to: Date()))
        service.stats.finishedBooks += [
            FinishedBookEntry(bookID: audiobook.uuidString, title: "Before kinds", dateFinished: lastYear),
            FinishedBookEntry(bookID: article.uuidString, title: "An article", dateFinished: Date(), kind: .text),
        ]

        XCTAssertEqual(service.booksFinishedAllTimeByKind, FinishedBookCounts(textBooks: 1, audiobooks: 1, episodes: 1))
        XCTAssertEqual(service.booksFinishedThisYearByKind(at: Date()), FinishedBookCounts(textBooks: 1, episodes: 1))
        XCTAssertEqual(service.booksFinishedThisYear(at: Date()), 3)
        let figures = ReadingStatsFigures(service: service, at: Date())
        XCTAssertEqual(figures.booksFinishedAllTime, 4)
        XCTAssertEqual(
            ReadingStatsTile.booksFinishedAllTime.wording(for: figures).accessibilityLabel,
            "4 books finished all time: 1 text book, 1 audiobook, 1 podcast episode, and 1 other book"
        )

        service.finishedBookKind = nil
        XCTAssertEqual(service.booksFinishedAllTimeByKind, FinishedBookCounts(textBooks: 1, episodes: 1))
    }

    /// A finished book's kind is written with it. An entry saved before
    /// kinds were recorded, or with a kind this version does not know, reads
    /// with none, and the rest of the statistics read as ever.
    func testFinishedBookKindsRoundTripAndUnknownOnesReadAsNone() throws {
        let saved = #"""
        {"dailyListeningSeconds":{},"totalListeningSeconds":12,"bookListeningSeconds":{},"finishedBooks":[
        {"bookID":"A","title":"Before kinds","dateFinished":0},
        {"bookID":"B","title":"From a later version","dateFinished":0,"kind":"comic"},
        {"bookID":"C","title":"An episode","dateFinished":0,"kind":"episode"}]}
        """#

        let stats = try JSONDecoder().decode(ReadingStats.self, from: Data(saved.utf8))
        let again = try JSONDecoder().decode(ReadingStats.self, from: JSONEncoder().encode(stats))

        XCTAssertEqual(stats.totalListeningSeconds, 12)
        XCTAssertEqual(stats.finishedBooks.map(\.title), ["Before kinds", "From a later version", "An episode"])
        XCTAssertEqual(stats.finishedBooks.map(\.kind), [nil, nil, .episode])
        XCTAssertEqual(again.finishedBooks.map(\.kind), [nil, nil, .episode])
        XCTAssertEqual(FinishedBookKind.of(format: .audio, isFeedDownload: true), .episode)
        XCTAssertEqual(FinishedBookKind.of(format: .audio, isFeedDownload: false), .audiobook)
        XCTAssertEqual(FinishedBookKind.of(format: .html, isFeedDownload: true), .text, "an article is a text book")
        XCTAssertEqual(FinishedBookKind.of(format: .epub, isFeedDownload: false), .text)
    }

    @MainActor
    private func makeService(
        checkpointInterval: TimeInterval = ReadingStatsService.defaultCheckpointInterval
    ) -> ReadingStatsService {
        let service = ReadingStatsService(fileURL: fileURL, checkpointInterval: checkpointInterval)
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }

    /// What the next launch would find: waits for every queued write, then
    /// loads the file into a fresh service, as startup does.
    @MainActor
    private func relaunchedService() -> ReadingStatsService {
        ReadingStatsService.waitForQueuedSaves()
        return makeService()
    }

    /// Checks that the daily and the per-book totals each add up to the
    /// grand total.
    private func assertTotalsAgree(
        _ stats: ReadingStats, file: StaticString = #filePath, line: UInt = #line
    ) {
        let total = stats.totalListeningSeconds
        XCTAssertEqual(
            stats.dailyListeningSeconds.values.reduce(0, +), total, "Daily totals", file: file, line: line
        )
        XCTAssertEqual(
            stats.bookListeningSeconds.values.reduce(0, +), total, "Per-book totals", file: file, line: line
        )
    }
}
