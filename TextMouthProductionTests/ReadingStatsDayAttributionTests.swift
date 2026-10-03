import XCTest
@testable import TextMouth

/// Listening time is kept by local day under keys that never change with
/// the user's calendar settings, every second goes to the day it was heard
/// on across midnight, clock changes, and journeys, and keys saved by
/// earlier versions are migrated once with every total kept (TODO C06).
/// Each test stands in the user's calendar (its calendar system, locale,
/// and time zone) and passes explicit times for the clock, over statistics
/// files of its own under the isolated test data root, so neither the
/// shared service nor the Mac's own settings play any part. Set-up and
/// tear-down hold only plain values; each test makes its services on the
/// main actor.
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

    // MARK: - Daylight saving

    /// A day that a clock change makes other than 24 hours long, with a
    /// session that runs from 11:30 p.m. the day before to 12:30 a.m. the
    /// day after.
    private struct ClockChangeDay: Sendable {
        /// The time zone whose clocks change.
        let zone: String
        /// When the session starts, half an hour before the day begins.
        let start: String
        /// When the session ends, half an hour after the day ends.
        let end: String
        /// The keys of the day before, the day itself, and the day after.
        let keys: [String]
        /// How long the day itself is.
        let hours: Double
    }

    /// Clock changes of every kind: New York's 23-hour spring day and
    /// 25-hour autumn day, Santiago's spring day that begins at 1 a.m.
    /// because its clocks jump at midnight, and Lord Howe Island's
    /// 23.5-hour day from its half-hour change.
    private static let clockChangeDays = [
        ClockChangeDay(
            zone: "America/New_York", start: "2026-03-07T23:30:00-05:00", end: "2026-03-09T00:30:00-04:00",
            keys: ["2026-03-07", "2026-03-08", "2026-03-09"], hours: 23
        ),
        ClockChangeDay(
            zone: "America/New_York", start: "2026-10-31T23:30:00-04:00", end: "2026-11-02T00:30:00-05:00",
            keys: ["2026-10-31", "2026-11-01", "2026-11-02"], hours: 25
        ),
        ClockChangeDay(
            zone: "America/Santiago", start: "2026-09-05T23:30:00-04:00", end: "2026-09-07T00:30:00-03:00",
            keys: ["2026-09-05", "2026-09-06", "2026-09-07"], hours: 23
        ),
        ClockChangeDay(
            zone: "Australia/Lord_Howe", start: "2026-10-03T23:30:00+10:30", end: "2026-10-05T00:30:00+11:00",
            keys: ["2026-10-03", "2026-10-04", "2026-10-05"], hours: 23.5
        ),
    ]

    /// A day a clock change makes 23, 23.5, or 25 hours long, or starts at
    /// 1 a.m., gets exactly its own length of a session that spans it, with
    /// hourly checkpoints and without, and its neighbors their half hours;
    /// the three days keep a streak and fill This Week.
    @MainActor
    func testClockChangeDaysCreditTheirTrueLengthAndKeepTheStreak() throws {
        for day in Self.clockChangeDays {
            let userCalendar = try calendar(.gregorian, in: day.zone)
            let start = try time(day.start)
            let end = try time(day.end)
            let checkpointIntervals: [TimeInterval?] = [3_600, nil]
            for interval in checkpointIntervals {
                let context = "\(day.keys[1]) in \(day.zone) \(interval == nil ? "without" : "with") checkpoints"
                let service = makeService(named: UUID().uuidString, userCalendar: { userCalendar })
                listen(with: service, from: start, to: end, checkpointingEvery: interval)

                XCTAssertEqual(service.stats.dailyListeningSeconds, [
                    day.keys[0]: 1_800, day.keys[1]: day.hours * 3_600, day.keys[2]: 1_800,
                ], context)
                XCTAssertEqual(service.stats.totalListeningSeconds, end.timeIntervalSince(start), context)
                XCTAssertEqual(service.todayListeningTime(at: end), 1_800, context)
                XCTAssertEqual(service.thisWeekListeningTime(at: end), end.timeIntervalSince(start), context)
                XCTAssertEqual(service.currentStreak(at: end), 3, context)
            }
        }
    }

    /// Counting back across a clock change goes one calendar day at a
    /// time. Just after the midnight that ends a 23-hour day, going back
    /// 86,400 seconds would skip that day altogether. With listening on ten
    /// days in a row, the streak is ten and This Week holds seven of them,
    /// counted from either side of each kind of change.
    @MainActor
    func testStreakAndWeekCountEveryClockChangeDayOnce() throws {
        let moments = [
            (zone: "America/New_York", now: "2026-03-09T00:30:00-04:00", today: "2026-03-09"),
            (zone: "America/New_York", now: "2026-03-08T23:30:00-04:00", today: "2026-03-08"),
            (zone: "America/New_York", now: "2026-11-02T00:30:00-05:00", today: "2026-11-02"),
            (zone: "America/New_York", now: "2026-11-01T23:30:00-05:00", today: "2026-11-01"),
            (zone: "America/Santiago", now: "2026-09-07T00:30:00-03:00", today: "2026-09-07"),
            (zone: "Australia/Lord_Howe", now: "2026-10-05T00:15:00+11:00", today: "2026-10-05"),
        ]
        for moment in moments {
            let userCalendar = try calendar(.gregorian, in: moment.zone)
            let service = makeService(named: UUID().uuidString, userCalendar: { userCalendar })
            let tenDays = try keys(ofDays: 10, endingWith: moment.today)
            service.stats.dailyListeningSeconds = Dictionary(uniqueKeysWithValues: tenDays.map { ($0, 100) })
            let now = try time(moment.now)

            let context = "\(moment.now) in \(moment.zone)"
            XCTAssertEqual(service.currentStreak(at: now), 10, context)
            XCTAssertEqual(service.thisWeekListeningTime(at: now), 700, context)
            XCTAssertEqual(service.todayListeningTime(at: now), 100, context)
        }
    }

    /// Samoa skipped 30 December 2011 when it moved across the date line.
    /// Walking back from the 31st reaches the 29th, the day before that
    /// existed, and a streak runs through the missing day unbroken.
    func testWalkingBackCrossesADayATimeZoneSkipped() throws {
        let apia = try zone("Pacific/Apia")
        let days = ListeningDays(timeZone: apia)
        let lastDayOfYear = try time("2011-12-31T12:00:00+14:00")
        XCTAssertEqual(days.key(for: lastDayOfYear), "2011-12-31")

        XCTAssertEqual(days.key(for: days.dayBefore(lastDayOfYear)), "2011-12-29")
        let listening = ["2011-12-28": 120.0, "2011-12-29": 120, "2011-12-31": 120]
        XCTAssertEqual(ReadingStatsService.streak(in: listening, through: lastDayOfYear, timeZone: apia), 3)
    }

    // MARK: - Travel

    /// Moving west never moves what was credited. A listener in Berlin
    /// starts at 11:30 p.m. on 15 July, and the checkpoint at 12:30 a.m.
    /// gives half an hour each to the 15th and the 16th. Their Mac then
    /// takes New York's time zone, where it is still 6:30 p.m. on the 15th:
    /// the next half hour goes to the 15th, the 16th keeps its half hour,
    /// and Today and the streak read New York's day. Back in Berlin's zone,
    /// Today finds the 16th's half hour where it was left.
    @MainActor
    func testTravelWestNeverMovesListeningAlreadyCredited() throws {
        var userCalendar = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { userCalendar })
        let start = try time("2026-07-15T23:30:00+02:00")
        service.startSession(bookID: UUID(), at: start)
        service.checkpointActiveSession(at: start + 3_600)
        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 1_800, "2026-07-16": 1_800])

        userCalendar = try calendar(.gregorian, in: "America/New_York")
        let landed = start + 3_600
        XCTAssertEqual(service.todayListeningTime(at: landed), 1_800)
        service.checkpointActiveSession(at: landed + 1_800)
        service.endSession(at: landed + 1_800)

        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 3_600, "2026-07-16": 1_800])
        XCTAssertEqual(service.stats.totalListeningSeconds, 5_400)
        XCTAssertEqual(service.todayListeningTime(at: landed + 1_800), 3_600)
        XCTAssertEqual(service.currentStreak(at: landed + 1_800), 1)

        userCalendar = try calendar(.gregorian, in: "Europe/Berlin")
        XCTAssertEqual(service.todayListeningTime(at: landed + 1_800), 1_800)
        XCTAssertEqual(service.currentStreak(at: landed + 1_800), 2)
    }

    /// Moving east, the slice since the last checkpoint is attributed in
    /// the new zone when it is credited, the part heard before the move
    /// included, since the move itself is not seen. A listener in New York
    /// is credited 15 minutes on the 15th; then their Mac takes Tokyo's
    /// zone, and the next slice, 11:45 p.m. to 12:15 a.m. in Tokyo, is
    /// split at Tokyo's midnight, while the first 15 minutes stay put.
    @MainActor
    func testTravelEastSplitsTheNextSliceInTheNewZone() throws {
        var userCalendar = try calendar(.gregorian, in: "America/New_York")
        let service = makeService(userCalendar: { userCalendar })
        let start = try time("2026-07-15T10:30:00-04:00")
        service.startSession(bookID: UUID(), at: start)
        service.checkpointActiveSession(at: start + 900)

        userCalendar = try calendar(.gregorian, in: "Asia/Tokyo")
        let tokyoMidnight = try time("2026-07-16T00:00:00+09:00")
        XCTAssertEqual(tokyoMidnight, start + 1_800)
        service.endSession(at: tokyoMidnight + 900)

        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2026-07-15": 1_800, "2026-07-16": 900])
        XCTAssertEqual(service.stats.totalListeningSeconds, 2_700)
        XCTAssertEqual(service.todayListeningTime(at: tokyoMidnight + 900), 900)
    }

    // MARK: - Keys of earlier versions

    /// Statistics an earlier version saved for a Thai user, with Buddhist
    /// keys for the last three days and one key naming no day, are
    /// migrated when loaded. The days get their Gregorian keys, where
    /// Today, This Week, and the streak find them; the stray key becomes a
    /// legacy entry, in the all-time total but in no day; no total
    /// changes; and the file is saved marked at once. The next launch
    /// leaves the keys alone, even one that looks Buddhist.
    @MainActor
    func testBuddhistKeysOfAnEarlierVersionMigrateOnceWithTotalsKept() throws {
        let berlin = try zone("Europe/Berlin")
        let userCalendar = try calendar(.buddhist, in: "Europe/Berlin", locale: "th_TH")
        let now = Date()
        let lastThreeDays = try noons(ofDays: 3, endingWith: now, in: berlin)
        let book = UUID().uuidString
        var oldDaily = Dictionary(uniqueKeysWithValues: lastThreeDays.map { (thaiKey(for: $0, in: berlin), 600.0) })
        oldDaily["2569-13-45"] = 60
        try writeStatisticsOfAnEarlierVersion(daily: oldDaily, total: 1_860, books: [book: 1_860])

        let service = makeService(userCalendar: { userCalendar })

        var expected = Dictionary(uniqueKeysWithValues: lastThreeDays.map { (gregorianKey(for: $0, in: berlin), 600.0) })
        expected["legacy:2569-13-45"] = 60
        XCTAssertEqual(service.stats.dailyListeningSeconds, expected)
        XCTAssertEqual(service.stats.totalListeningSeconds, 1_860)
        XCTAssertEqual(service.stats.bookListeningSeconds, [book: 1_860])
        assertTotalAccountedFor(service.stats)
        XCTAssertEqual(service.todayListeningTime(at: now), 600)
        XCTAssertEqual(service.thisWeekListeningTime(at: now), 1_800)
        XCTAssertEqual(service.currentStreak(at: now), 3)
        var saved = try savedStats(of: service)
        XCTAssertEqual(saved.dayKeyVersion, ListeningDays.keyVersion)
        XCTAssertEqual(saved.dailyListeningSeconds, expected)

        // A Buddhist-looking key in the marked file is never read again.
        saved.dailyListeningSeconds["2569-01-01"] = 5
        saved.totalListeningSeconds += 5
        try save(saved, named: "reading_stats")
        let relaunched = makeService(userCalendar: { userCalendar })
        XCTAssertEqual(relaunched.stats.dailyListeningSeconds, saved.dailyListeningSeconds)
    }

    /// Statistics an earlier version saved with Gregorian keys, as most
    /// users' are, keep every key, and are saved marked at once, so the
    /// migration never runs on them again.
    @MainActor
    func testGregorianKeysOfAnEarlierVersionStayAndTheFileIsMarked() throws {
        let daily = ["2026-03-20": 90.0, "2026-03-21": 30]
        try writeStatisticsOfAnEarlierVersion(daily: daily, total: 120, books: ["book": 120])
        let userCalendar = try calendar(.gregorian, in: "America/New_York")

        let service = makeService(userCalendar: { userCalendar })

        XCTAssertEqual(service.stats.dailyListeningSeconds, daily)
        let saved = try savedStats(of: service)
        XCTAssertEqual(saved.dayKeyVersion, ListeningDays.keyVersion)
        XCTAssertEqual(saved.dailyListeningSeconds, daily)
    }

    /// New statistics start marked with the current key version, so there
    /// is nothing to migrate or save, while a file saved before TODO C06
    /// decodes unmarked.
    @MainActor
    func testNewStatisticsStartMarkedAndOldFilesDecodeUnmarked() throws {
        let userCalendar = try calendar(.gregorian, in: "Europe/Berlin")
        let service = makeService(userCalendar: { userCalendar })

        XCTAssertEqual(service.stats.dayKeyVersion, ListeningDays.keyVersion)
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.fileURL.path))
        let oldFile = #"{"dailyListeningSeconds":{},"totalListeningSeconds":0,"bookListeningSeconds":{},"finishedBooks":[]}"#
        XCTAssertNil(try JSONDecoder().decode(ReadingStats.self, from: Data(oldFile.utf8)).dayKeyVersion)
    }

    /// Keys that name no day are logged once, by the launch that migrates
    /// them, and never again.
    @MainActor
    func testKeysNamingNoDayAreLoggedOnce() throws {
        let stray = "nonsense-\(UUID().uuidString)"
        try writeStatisticsOfAnEarlierVersion(daily: [stray: 30], total: 30, books: ["book": 30])
        let userCalendar = try calendar(.gregorian, in: "Europe/Berlin")

        let firstLaunch = debugLogLines { _ = makeService(userCalendar: { userCalendar }) }
        // The second launch reads what the first saved.
        ReadingStatsService.waitForQueuedSaves()
        let secondLaunch = debugLogLines { _ = makeService(userCalendar: { userCalendar }) }

        XCTAssertEqual(firstLaunch.filter { $0.contains(stray) }.count, 1)
        XCTAssertTrue(firstLaunch.contains { $0.hasSuffix(#"READING_STATS_DAY_KEYS: rewritten 0, kept as legacy 1: "\#(stray)""#) })
        XCTAssertFalse(secondLaunch.contains { $0.contains(stray) })
    }

    /// The all-time total always equals the day totals plus the legacy
    /// entries: after a migration that keeps a legacy entry, and after
    /// listening across midnight, across a 25-hour day, and on a journey.
    @MainActor
    func testAllTimeTotalIsAlwaysTheDaysPlusTheLegacyEntries() throws {
        try writeStatisticsOfAnEarlierVersion(
            daily: ["2568-12-31": 600, "2026-13-45": 60.25], total: 660.25, books: ["book": 660.25]
        )
        var userCalendar = try calendar(.buddhist, in: "America/New_York", locale: "th_TH")
        let service = makeService(userCalendar: { userCalendar })
        XCTAssertEqual(service.stats.dailyListeningSeconds, ["2025-12-31": 600, "legacy:2026-13-45": 60.25])
        assertTotalAccountedFor(service.stats, "After the migration")

        let midnight = try time("2026-07-16T00:00:00-04:00")
        listen(with: service, from: midnight - 119.75, to: midnight + 60.5, checkpointingEvery: 60)
        assertTotalAccountedFor(service.stats, "After midnight")

        let longDay = try XCTUnwrap(Self.clockChangeDays.first { $0.hours == 25 })
        listen(with: service, from: try time(longDay.start), to: try time(longDay.end), checkpointingEvery: 3_600)
        assertTotalAccountedFor(service.stats, "After the 25-hour day")

        let departure = try time("2026-11-05T20:00:00-05:00")
        service.startSession(bookID: UUID(), at: departure)
        service.checkpointActiveSession(at: departure + 600)
        userCalendar = try calendar(.buddhist, in: "Asia/Tokyo", locale: "th_TH")
        service.endSession(at: departure + 1_200)
        assertTotalAccountedFor(service.stats, "After the journey")

        XCTAssertEqual(service.stats.totalListeningSeconds, 660.25 + 180.25 + 93_600 + 1_200)
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

    /// Writes `stats` to this test's statistics file named `name`, as the
    /// service saves them.
    private func save(_ stats: ReadingStats, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stats).write(to: directory.appendingPathComponent("\(name).json"))
    }

    /// Writes this test's statistics file named `name` as a version before
    /// TODO C06 saved it: without `dayKeyVersion`, holding `daily` and the
    /// totals.
    private func writeStatisticsOfAnEarlierVersion(
        daily: [String: TimeInterval],
        total: TimeInterval,
        books: [String: TimeInterval],
        named name: String = "reading_stats"
    ) throws {
        let file: [String: Any] = [
            "dailyListeningSeconds": daily,
            "totalListeningSeconds": total,
            "bookListeningSeconds": books,
            "finishedBooks": [Any](),
        ]
        try JSONSerialization.data(withJSONObject: file).write(to: directory.appendingPathComponent("\(name).json"))
    }

    /// The debug log lines written while `body` runs. A log rotated
    /// meanwhile starts a new file holding only the new lines.
    @MainActor
    private func debugLogLines(writtenDuring body: () throws -> Void) rethrows -> [String] {
        let log = TextMouthPaths.debugLogFile
        TextMouthPaths.flushLogs()
        let before = (try? Data(contentsOf: log)) ?? Data()
        try body()
        TextMouthPaths.flushLogs()
        let after = (try? Data(contentsOf: log)) ?? Data()
        let written = after.starts(with: before) ? after.dropFirst(before.count) : after
        return String(decoding: written, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Checks that the all-time total is exactly the day totals plus the
    /// legacy entries, so no second is lost or counted twice.
    private func assertTotalAccountedFor(
        _ stats: ReadingStats,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let isLegacy = { (key: String) in key.hasPrefix(ListeningDayKeyMigration.legacyKeyPrefix) }
        let days = stats.dailyListeningSeconds.filter { !isLegacy($0.key) }.values.reduce(0, +)
        let legacy = stats.dailyListeningSeconds.filter { isLegacy($0.key) }.values.reduce(0, +)
        XCTAssertEqual(days + legacy, stats.totalListeningSeconds, context, file: file, line: line)
    }

    /// Noon on each of the `count` days ending with the one containing
    /// `now` in `zone`, latest first, counted with Foundation's Gregorian
    /// calendar, where no clock change ever moves noon to another day.
    private func noons(ofDays count: Int, endingWith now: Date, in zone: TimeZone) throws -> [Date] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let todayAtNoon = try XCTUnwrap(gregorian.date(bySettingHour: 12, minute: 0, second: 0, of: now))
        return try (0..<count).map { try XCTUnwrap(gregorian.date(byAdding: .day, value: -$0, to: todayAtNoon)) }
    }

    /// The key the old code wrote for `day` on a Mac set to Thai in `zone`:
    /// a default-configured formatter, which wrote Buddhist years.
    private func thaiKey(for day: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    /// The Gregorian key of the day containing `day` in `zone`, written by a
    /// POSIX formatter rather than the code under test.
    private func gregorianKey(for day: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
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

    /// The keys of `count` consecutive days ending with the day `lastKey`
    /// names, latest first. They are counted in UTC, where every day is
    /// 24 hours long, with an ISO 8601 formatter, so the expected keys owe
    /// nothing to the code under test.
    private func keys(ofDays count: Int, endingWith lastKey: String) throws -> [String] {
        let lastNoon = try time("\(lastKey)T12:00:00Z")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate] // "yyyy-MM-dd" in UTC
        return (0..<count).map { formatter.string(from: lastNoon - Double($0) * 86_400) }
    }
}
