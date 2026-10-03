import XCTest
@testable import TextMouth

/// Listening time is kept by local day under keys that never change with
/// the user's calendar settings (TODO C06). Each test stands in the user's
/// calendar (its calendar system, locale, and time zone) and passes explicit
/// times for the clock, over statistics files of its own under the isolated
/// test data root, so neither the shared service nor the Mac's own settings
/// play any part. Set-up and tear-down hold only plain values; each test
/// makes its services on the main actor.
final class ReadingStatsDayAttributionTests: XCTestCase {
    /// Directory holding this test's statistics files, removed afterwards.
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TextMouthPaths.root.appendingPathComponent(
            "ReadingStatsDayAttributionTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Queued writes target the directory; let them land before removing it.
        ReadingStatsService.waitForQueuedSaves()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Stable keys

    /// The same hour of listening is kept under the same Gregorian key in
    /// ASCII digits whichever calendar the user has chosen, including those
    /// whose formatters write other years, months, and digits (Buddhist
    /// 2569, Japanese era year 8, Islamic 1448 in Arabic-Indic digits), and
    /// Today, This Week, and the streak all find it there.
    @MainActor
    func testDayKeysAreGregorianWhateverCalendarTheUserChooses() throws {
        let noon = try time("2026-07-15T12:00:00+02:00")
        let systems: [(Calendar.Identifier, String)] = [
            (.gregorian, "en_US"), (.buddhist, "th_TH"), (.japanese, "ja_JP"),
            (.republicOfChina, "zh_TW"), (.islamicUmmAlQura, "ar_SA"), (.persian, "fa_IR"),
            (.hebrew, "he_IL"), (.indian, "hi_IN"), (.chinese, "zh_CN"), (.ethiopicAmeteMihret, "am_ET"),
        ]
        for (identifier, locale) in systems {
            let userCalendar = try calendar(identifier, in: "Europe/Berlin", locale: locale)
            let service = makeService(named: "\(identifier)", userCalendar: { userCalendar })
            service.startSession(bookID: UUID(), at: noon - 3_600)
            service.checkpointActiveSession(at: noon - 1_800)
            service.endSession(at: noon)

            let context = "Calendar \(identifier)"
            XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 3_600], context)
            XCTAssertEqual(try savedStats(of: service).dailyListeningSeconds, ["2026-07-15": 3_600], context)
            XCTAssertEqual(service.todayListeningTime(at: noon), 3_600, context)
            XCTAssertEqual(service.thisWeekListeningTime(at: noon), 3_600, context)
            XCTAssertEqual(service.currentStreak(at: noon), 1, context)
        }
    }

    /// Switching calendar systems strands nothing: the days before and
    /// after the switch are kept under keys of the same kind, so the week
    /// adds both and the streak runs through the switch.
    @MainActor
    func testSwitchingCalendarsKeepsEarlierDaysInTheWeekAndTheStreak() throws {
        var userCalendar = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { userCalendar })
        let firstNoon = try time("2026-07-14T12:00:00+02:00")
        service.startSession(bookID: UUID(), at: firstNoon)
        service.endSession(at: firstNoon + 600)

        userCalendar = try calendar(.buddhist, in: "Europe/Berlin", locale: "th_TH")
        let secondNoon = try time("2026-07-15T12:00:00+02:00")
        service.startSession(bookID: UUID(), at: secondNoon)
        service.endSession(at: secondNoon + 600)

        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-14": 600, "2026-07-15": 600])
        XCTAssertEqual(service.thisWeekListeningTime(at: secondNoon + 600), 1_200)
        XCTAssertEqual(service.currentStreak(at: secondNoon + 600), 2)
    }

    /// A key names the local day in the time zone it is made for: one
    /// moment is 15 July in Tokyo and still 14 July in Los Angeles.
    func testDateKeyNamesTheLocalDayInTheGivenTimeZone() throws {
        let moment = try time("2026-07-15T03:00:00Z")
        XCTAssertEqual(ReadingStatsService.dateKey(moment, in: try zone("Asia/Tokyo")), "2026-07-15")
        XCTAssertEqual(ReadingStatsService.dateKey(moment, in: try zone("America/Los_Angeles")), "2026-07-14")
    }

    /// Listening goes to the local day of the user's time zone: the same
    /// half hour is 15 July for a listener in Tokyo and 14 July for one in
    /// Los Angeles, and each one's Today finds it.
    @MainActor
    func testListeningGoesToTheLocalDayOfTheUsersTimeZone() throws {
        let moment = try time("2026-07-15T03:00:00Z")
        let tokyoCalendar = try calendar(.gregorian, in: "Asia/Tokyo")
        let losAngelesCalendar = try calendar(.gregorian, in: "America/Los_Angeles")
        let tokyo = makeService(named: "tokyo", userCalendar: { tokyoCalendar })
        let losAngeles = makeService(named: "losAngeles", userCalendar: { losAngelesCalendar })

        for service in [tokyo, losAngeles] {
            service.startSession(bookID: UUID(), at: moment)
            service.endSession(at: moment + 1_800)
        }

        XCTAssertEqual(tokyo.stats.dailyListeningSeconds, ["2026-07-15": 1_800])
        XCTAssertEqual(losAngeles.stats.dailyListeningSeconds, ["2026-07-14": 1_800])
        XCTAssertEqual(tokyo.todayListeningTime(at: moment + 1_800), 1_800)
        XCTAssertEqual(losAngeles.todayListeningTime(at: moment + 1_800), 1_800)
    }

    // MARK: - Midnight

    /// A session across midnight credits each day exactly the seconds heard
    /// on it, whether checkpoints credit it along the way or it is credited
    /// whole when it ends: 100.25 s to the day before and 45.5 s to the new
    /// day, in memory and on disk.
    @MainActor
    func testSessionAcrossMidnightCreditsEachDayExactlyItsSeconds() throws {
        let berlin = try calendar(.gregorian, in: "Europe/Berlin")
        let midnight = try time("2026-07-16T00:00:00+02:00")
        let checkpointIntervals: [TimeInterval?] = [60, nil]
        for interval in checkpointIntervals {
            let context = interval == nil ? "Without checkpoints" : "With checkpoints"
            let service = makeService(named: context, userCalendar: { berlin })
            let book = UUID()
            listen(with: service, book: book, from: midnight - 100.25, to: midnight + 45.5, checkpointingEvery: interval)

            let expected = ["2026-07-15": 100.25, "2026-07-16": 45.5]
            XCTAssertEqual(service.stats.dailyListeningSeconds, expected, context)
            XCTAssertEqual(service.stats.totalListeningSeconds, 145.75, context)
            XCTAssertEqual(service.stats.bookListeningSeconds, [book.uuidString: 145.75], context)
            XCTAssertEqual(try savedStats(of: service).dailyListeningSeconds, expected, context)
        }
    }

    /// A checkpoint made exactly at midnight leaves the new day nothing from
    /// before it: the slice ending there belongs wholly to the day before,
    /// and the new day gets an entry only once time is heard on it.
    @MainActor
    func testCheckpointExactlyAtMidnightCreditsItsSliceToTheDayBefore() throws {
        let berlin = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { berlin })
        let midnight = try time("2026-07-16T00:00:00+02:00")
        service.startSession(bookID: UUID(), at: midnight - 60)

        service.checkpointActiveSession(at: midnight)
        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 60])

        service.endSession(at: midnight + 30)
        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 60, "2026-07-16": 30])
    }

    /// One slice can span several days, as when nothing checkpoints a
    /// session for a long while: each day it crosses gets its share, and
    /// each day wholly inside it a full 24 hours.
    @MainActor
    func testSliceSpanningSeveralDaysCreditsEveryDayItCrosses() throws {
        let berlin = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { berlin })
        let start = try time("2026-07-14T22:00:00+02:00")
        let end = try time("2026-07-17T03:00:00+02:00")

        listen(with: service, from: start, to: end, checkpointingEvery: nil)

        XCTAssertEqual(service.stats.dailyListeningSeconds, [
            "2026-07-14": 7_200, "2026-07-15": 86_400, "2026-07-16": 86_400, "2026-07-17": 10_800,
        ])
        XCTAssertEqual(service.stats.totalListeningSeconds, end.timeIntervalSince(start))
        XCTAssertEqual(service.currentStreak(at: end), 4)
    }

    /// While a session is open across midnight, Today counts only its
    /// uncredited time since midnight and This Week all of it: the seconds
    /// before midnight belong to the day before, where the next checkpoint
    /// puts them, so both read the same before and after that checkpoint.
    @MainActor
    func testTodayCountsOnlyTheOpenSessionsTimeSinceMidnight() throws {
        let berlin = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { berlin })
        let midnight = try time("2026-07-16T00:00:00+02:00")
        service.startSession(bookID: UUID(), at: midnight - 90)
        service.checkpointActiveSession(at: midnight - 30)
        let now = midnight + 45

        XCTAssertEqual(service.uncreditedSessionTime(at: now), 75)
        XCTAssertEqual(service.todayListeningTime(at: now), 45)
        XCTAssertEqual(service.thisWeekListeningTime(at: now), 135)

        service.checkpointActiveSession(at: now)

        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 90, "2026-07-16": 45])
        XCTAssertEqual(service.todayListeningTime(at: now), 45)
        XCTAssertEqual(service.thisWeekListeningTime(at: now), 135)
    }

    /// Splitting a span gives its pieces in order, one per day, adding up
    /// to the span; an empty or backward span has none.
    func testSplitGivesEachDayItsPieceInOrder() throws {
        let days = ListeningDays(timeZone: try zone("Europe/Berlin"))
        let midnight = try time("2026-07-16T00:00:00+02:00")

        XCTAssertEqual(days.split(from: midnight - 10, to: midnight + 5), [
            ListeningDays.Piece(dayKey: "2026-07-15", seconds: 10),
            ListeningDays.Piece(dayKey: "2026-07-16", seconds: 5),
        ])
        XCTAssertEqual(days.split(from: midnight, to: midnight), [])
        XCTAssertEqual(days.split(from: midnight + 5, to: midnight), [])
    }

    // MARK: - Helpers

    /// Listens to `book` from `start` to `end` with `service`, as the
    /// reader does: a session that the timer checkpoints every
    /// `interval` seconds from its start, or not at all when `interval` is
    /// nil, and that then ends.
    @MainActor
    private func listen(
        with service: ReadingStatsService,
        book: UUID = UUID(),
        from start: Date,
        to end: Date,
        checkpointingEvery interval: TimeInterval?
    ) {
        service.startSession(bookID: book, at: start)
        if let interval {
            var checkpoint = start + interval
            while checkpoint < end {
                service.checkpointActiveSession(at: checkpoint)
                checkpoint += interval
            }
        }
        service.endSession(at: end)
    }

    /// A service over a statistics file of this test's own, named `name`,
    /// whose user's calendar is whatever `userCalendar` returns when asked.
    /// Its timer checkpoints only hourly, so the explicit checkpoints of the
    /// test are the only ones, and it stops when the test ends.
    @MainActor
    private func makeService(
        named name: String = "reading_stats",
        userCalendar: @escaping () -> Calendar
    ) -> ReadingStatsService {
        let service = ReadingStatsService(
            fileURL: directory.appendingPathComponent("\(name).json"),
            checkpointInterval: 3_600,
            userCalendar: userCalendar
        )
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }

    /// The statistics `service` has saved, read once its queued writes land.
    @MainActor
    private func savedStats(of service: ReadingStatsService) throws -> ReadingStats {
        ReadingStatsService.waitForQueuedSaves()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReadingStats.self, from: Data(contentsOf: service.fileURL))
    }

    /// A user's calendar: the `identifier` calendar system in the time zone
    /// named `zoneID`, with the language and digits of `locale`.
    private func calendar(
        _ identifier: Calendar.Identifier,
        in zoneID: String,
        locale: String = "en_US_POSIX"
    ) throws -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try zone(zoneID)
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    /// The time zone with the identifier `identifier`.
    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier), "No time zone \(identifier)")
    }

    /// The moment named by `iso`, an ISO 8601 date and time with its offset
    /// from UTC, such as "2026-07-15T12:00:00+02:00".
    private func time(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "Not an ISO 8601 time: \(iso)")
    }
}
