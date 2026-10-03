import XCTest
@testable import TextMouth

/// The Stats settings pane (TODO C07) words each figure once, for the
/// screen and for VoiceOver alike, plural included, and reads every figure
/// at one instant, with the open session's uncredited time in each
/// listening time.
///
/// Each test that needs statistics drives its own service over a disposable
/// statistics file under the isolated test data root, and explicit times
/// stand in for the clock, so neither the app's statistics nor the hour the
/// suite runs at can change a result. Set-up and tear-down hold only plain
/// values; each test makes its services on the main actor.
final class ReadingStatsViewTests: XCTestCase {
    /// The spacing of the simulated checkpoints: the app's own interval.
    private let interval = ReadingStatsService.defaultCheckpointInterval
    /// Directory holding this test's statistics file, removed afterwards.
    private var directory: URL!
    /// The statistics file this test's services read and write.
    private var fileURL: URL!
    /// Local noon on an ordinary summer day (15 July 2026), far from
    /// midnight and from any daylight-saving change, so a session starting
    /// here stays on one day. Whole and half seconds keep every sum exact.
    private var noon: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TextMouthPaths.root.appendingPathComponent(
            "ReadingStatsViewTests-\(UUID().uuidString)", isDirectory: true
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

    // MARK: - Wording

    /// The streak reads "0 days", "1 day", or "2 days", and VoiceOver
    /// speaks that same phrase. Until C07 its label always said "days",
    /// so a one-day streak was spoken as "1 days".
    func testStreakIsPluralizedAlikeOnScreenAndForVoiceOver() {
        for (days, phrase) in [(0, "0 days"), (1, "1 day"), (2, "2 days"), (365, "365 days")] {
            XCTAssertEqual(
                ReadingStatsTile.currentStreak.wording(for: figures(currentStreakDays: days)),
                ReadingStatsTileWording(value: phrase, accessibilityLabel: "Current listening streak: \(phrase)")
            )
        }
    }

    /// Both book counts read "0 books", "1 book", or "2 books", and
    /// VoiceOver speaks that same phrase. Until C07 the labels always said
    /// "books": "1 books finished this year".
    func testBookCountsArePluralizedAlikeOnScreenAndForVoiceOver() {
        for (count, phrase) in [(0, "0 books"), (1, "1 book"), (2, "2 books"), (40, "40 books")] {
            let counts = figures(booksFinishedThisYear: count, booksFinishedAllTime: count)
            XCTAssertEqual(
                ReadingStatsTile.booksFinishedThisYear.wording(for: counts),
                ReadingStatsTileWording(value: phrase, accessibilityLabel: "\(phrase) finished this year")
            )
            XCTAssertEqual(
                ReadingStatsTile.booksFinishedAllTime.wording(for: counts),
                ReadingStatsTileWording(value: phrase, accessibilityLabel: "\(phrase) finished all time")
            )
        }
    }

    /// Listening times show in digits and are spoken in words, singular
    /// units included: spoken as digits, "1:05:03" could pass for a time of
    /// day, and until C07 the labels repeated the digits.
    func testListeningTimesShowInDigitsAndAreSpokenInWords() {
        let times = figures(today: 0, thisWeek: 3_903, allTime: 90_061)

        XCTAssertEqual(
            ReadingStatsTile.today.wording(for: times),
            ReadingStatsTileWording(value: "0:00", accessibilityLabel: "Listening time today: 0 seconds")
        )
        XCTAssertEqual(
            ReadingStatsTile.thisWeek.wording(for: times),
            ReadingStatsTileWording(
                value: "1:05:03",
                accessibilityLabel: "Listening time this week: 1 hour, 5 minutes, 3 seconds"
            )
        )
        XCTAssertEqual(
            ReadingStatsTile.allTime.wording(for: times),
            ReadingStatsTileWording(
                value: "25:01:01",
                accessibilityLabel: "Total listening time: 25 hours, 1 minute, 1 second"
            )
        )
    }

    // MARK: - Tiles

    /// The pane shows six tiles, three under each heading, every one once
    /// and in order, each with its title and an accessibility identifier of
    /// its own.
    func testTilesHaveTitlesAndDistinctFixedIdentifiers() {
        XCTAssertEqual(ReadingStatsTile.listeningTime + ReadingStatsTile.progress, ReadingStatsTile.allCases)
        XCTAssertEqual(ReadingStatsTile.allCases.map(\.title), [
            "Today", "This Week", "All Time",
            "Current Streak", "Books Finished This Year", "Books Finished All Time",
        ])
        XCTAssertEqual(ReadingStatsTile.allCases.map(\.accessibilityIdentifier), [
            "readingStats.today", "readingStats.thisWeek", "readingStats.allTime",
            "readingStats.currentStreak", "readingStats.booksFinishedThisYear", "readingStats.booksFinishedAllTime",
        ])
    }

    // MARK: - Figures

    /// Every figure is read at one instant during a session. Each listening
    /// time includes the open session's time since its last checkpoint, so
    /// All Time is the saved total plus that time and never lags Today. The
    /// streak and book counts come from the same reading. Half a minute
    /// later every listening time has advanced by half a minute and nothing
    /// else has changed, though nothing was credited in between.
    @MainActor
    func testFiguresIncludeTheOpenSessionAndAdvanceWithTheClock() throws {
        let service = makeService()
        try listen(500, daysBeforeToday: 10, on: service)
        try listen(1_000, daysBeforeToday: 2, on: service)
        try listen(120, daysBeforeToday: 1, on: service)
        let sameDayLastYear = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -1, to: noon))
        service.stats.finishedBooks = [sameDayLastYear, noon - 86_400, noon - 3_600].map { date in
            FinishedBookEntry(bookID: UUID().uuidString, title: "Finished \(date)", dateFinished: date)
        }
        service.startSession(bookID: UUID(), at: noon)
        service.checkpointActiveSession(at: noon + interval)
        let saved = service.stats.totalListeningSeconds

        let first = ReadingStatsFigures(service: service, at: noon + interval + 25)

        XCTAssertEqual(saved, 1_620 + interval)
        XCTAssertEqual(first, ReadingStatsFigures(
            today: interval + 25,
            thisWeek: 1_120 + interval + 25,
            allTime: saved + 25,
            // Today's minute is not more than a minute yet, so the streak
            // runs through yesterday and the day before.
            currentStreakDays: 2,
            booksFinishedThisYear: 2,
            booksFinishedAllTime: 3
        ))
        XCTAssertEqual(ReadingStatsTile.allTime.wording(for: first).value, TimeFormatting.format(saved + 25))

        let later = ReadingStatsFigures(service: service, at: noon + interval + 55)

        XCTAssertEqual(later, ReadingStatsFigures(
            today: first.today + 30,
            thisWeek: first.thisWeek + 30,
            allTime: first.allTime + 30,
            currentStreakDays: first.currentStreakDays,
            booksFinishedThisYear: first.booksFinishedThisYear,
            booksFinishedAllTime: first.booksFinishedAllTime
        ))
        XCTAssertEqual(service.stats.totalListeningSeconds, saved, "Nothing was credited between the readings")
    }

    // MARK: - Helpers

    /// A service over this test's file. Its checkpoint timer is a day apart
    /// so it never fires during a test: it would checkpoint at the real
    /// time, far from the explicit times the tests use. The timer stops
    /// when the test ends.
    @MainActor
    private func makeService() -> ReadingStatsService {
        let service = ReadingStatsService(fileURL: fileURL, checkpointInterval: 24 * 60 * 60)
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }

    /// Records a finished session of `seconds` starting at noon `days` days
    /// before today.
    @MainActor
    private func listen(_ seconds: TimeInterval, daysBeforeToday days: Int, on service: ReadingStatsService) throws {
        let start = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -days, to: noon))
        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start + seconds)
    }

    /// Figures that are zero except for those given.
    private func figures(
        today: TimeInterval = 0,
        thisWeek: TimeInterval = 0,
        allTime: TimeInterval = 0,
        currentStreakDays: Int = 0,
        booksFinishedThisYear: Int = 0,
        booksFinishedAllTime: Int = 0
    ) -> ReadingStatsFigures {
        ReadingStatsFigures(
            today: today,
            thisWeek: thisWeek,
            allTime: allTime,
            currentStreakDays: currentStreakDays,
            booksFinishedThisYear: booksFinishedThisYear,
            booksFinishedAllTime: booksFinishedAllTime
        )
    }
}
