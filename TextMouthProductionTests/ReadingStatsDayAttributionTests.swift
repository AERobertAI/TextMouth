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

    // MARK: - Helpers

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
