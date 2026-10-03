import XCTest
@testable import TextMouth

/// Day keys saved before TODO C06 followed the system's calendar and
/// digits. The migration reads each one back in the calendar that wrote
/// it and rewrites it as a Gregorian key, or keeps it as a legacy entry
/// when no calendar reads it as a day TextMouth could have recorded. These
/// tests write keys as the old default-configured formatter did, under
/// locales whose calendars and digits differ, and check every result
/// against the day's key counted independently in UTC. The clock stands at
/// noon UTC on 2 October 2026.
final class ListeningDayKeyMigrationTests: XCTestCase {
    /// Locales whose old keys were not Gregorian keys in ASCII digits, with
    /// what each wrote for 2 October 2026.
    private static let locales = [
        "th_TH", // Buddhist: 2569-10-02
        "th_TH@numbers=thai", // Buddhist in Thai digits
        "ja_JP@calendar=japanese", // Japanese era year: 0008-10-02
        "zh_TW@calendar=roc", // Republic of China: 0115-10-02
        "ar_SA", // Umm al-Qura in Arabic-Indic digits
        "en_US@calendar=islamic", // the other Islamic variants
        "en_US@calendar=islamic-civil",
        "en_US@calendar=islamic-tbla",
        "fa_IR", // Persian in Persian digits
        "he_IL@calendar=hebrew", // Hebrew, whose months shift in leap years
        "hi_IN@calendar=indian", // Indian national: 1948-07-10
        "en_US@calendar=coptic", // 1743-01-22
        "am_ET@calendar=ethiopic", // Ethiopian: 2019-01-22, a Gregorian-looking year
        "en_US@calendar=ethiopic-amete-alem", // 7519-01-22
        "zh_CN@calendar=chinese", // cyclic year, and a leap month in summer 2025
        "ar_EG", // Gregorian in Arabic-Indic digits
        "my_MM", // Gregorian in Myanmar digits
    ]

    /// The calendars whose keys can still be read after the user has gone
    /// back to the Gregorian calendar, each in a locale writing ASCII
    /// digits, and the leap-month marker the POSIX locale reads.
    private static let earlierCalendars = [
        "th_TH", "ja_JP@calendar=japanese", "zh_TW@calendar=roc", "en_US@calendar=islamic-umalqura",
        "fa_IR", "he_IL@calendar=hebrew", "hi_IN@calendar=indian", "en_US@calendar=coptic",
        "am_ET@calendar=ethiopic", "en_US@calendar=ethiopic-amete-alem", "en_US@calendar=chinese",
    ]

    /// The clock of every migration here: noon UTC on 2 October 2026.
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        now = try time("2026-10-02T12:00:00Z")
    }

    // MARK: - Reading old keys

    /// Every day from the first TextMouth could have recorded to two days
    /// from now, written under each locale's calendar and digits, is read
    /// back as its own Gregorian day while the user still has those
    /// settings: Buddhist and Japanese era years, Arabic-Indic and Persian
    /// digits, Hebrew months in a year without a leap month, the Chinese
    /// leap month of 2025 in Chinese, and Ethiopian years that look
    /// Gregorian.
    func testEveryDayWrittenUnderTheUsersSettingsBecomesItsGregorianKey() throws {
        let days = try everyDay(from: "2025-01-01", through: "2026-10-04")
        for localeID in Self.locales {
            let locale = Locale(identifier: localeID)
            var userCalendar = locale.calendar
            userCalendar.locale = locale
            let migration = try XCTUnwrap(ListeningDayKeyMigration(userCalendar: userCalendar, now: now))

            let misread = days.compactMap { day -> String? in
                let written = oldKey(for: day, locale: locale)
                let read = migration.gregorianKey(forLegacyKey: written)
                return read == gregorianKey(for: day) ? nil : "\(written) read as \(read ?? "nothing")"
            }
            XCTAssertEqual(misread, [], "Under \(localeID)")
        }
    }

    /// Keys written in another calendar are still read after the user has
    /// gone back to the Gregorian calendar: no calendar but the one that
    /// wrote a key reads it as a day TextMouth could have recorded. Every
    /// fifth day suffices here, since each key is tried in many calendars.
    func testKeysOfAnEarlierCalendarAreReadAfterASwitchToGregorian() throws {
        let days = try everyDay(from: "2025-01-01", through: "2026-10-04", step: 5)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US")
        let migration = try XCTUnwrap(ListeningDayKeyMigration(userCalendar: gregorian, now: now))
        for localeID in Self.earlierCalendars {
            let locale = Locale(identifier: localeID)
            let misread = days.compactMap { day -> String? in
                let written = oldKey(for: day, locale: locale)
                let read = migration.gregorianKey(forLegacyKey: written)
                return read == gregorianKey(for: day) ? nil : "\(written) read as \(read ?? "nothing")"
            }
            XCTAssertEqual(misread, [], "Written under \(localeID)")
        }
    }

    // MARK: - Migrating totals

    /// Keys that already name a day TextMouth could have recorded in the
    /// Gregorian calendar are left as they are, whatever the user's
    /// calendar now, the first and the last such days included.
    func testGregorianKeysAreLeftAsTheyAre() throws {
        let daily = ["2025-01-01": 60.0, "2026-03-20": 90, "2026-10-02": 30, "2026-10-04": 15]
        for identifier in [Calendar.Identifier.gregorian, .buddhist, .japanese, .ethiopicAmeteMihret] {
            let migration = try XCTUnwrap(
                ListeningDayKeyMigration(userCalendar: Calendar(identifier: identifier), now: now)
            )
            XCTAssertEqual(
                migration.migrate(daily), .init(dailyListeningSeconds: daily), "User calendar \(identifier)"
            )
        }
    }

    /// Keys naming one day, such as a Gregorian key written before the user
    /// chose the Buddhist calendar and Buddhist keys in two scripts written
    /// after, become one entry holding all their seconds.
    func testKeysNamingOneDayBecomeOneEntryWithAllTheirSeconds() throws {
        let migration = try XCTUnwrap(ListeningDayKeyMigration(userCalendar: thai(), now: now))

        let outcome = migration.migrate(["2026-10-01": 100, "2569-10-01": 50, "๒๕๖๙-๑๐-๐๑": 25.5])

        XCTAssertEqual(outcome.dailyListeningSeconds, ["2026-10-01": 175.5])
        XCTAssertEqual(outcome.rewrittenKeyCount, 2)
        XCTAssertEqual(outcome.legacyKeys, [])
    }

    /// A key no calendar reads as a day TextMouth could have recorded,
    /// whether malformed, before 2025, or more than two days ahead, is kept
    /// under the legacy prefix with its seconds, so the entries still add
    /// up to the total, and listed for the log.
    func testKeysNamingNoPossibleDayAreKeptAsLegacyEntries() throws {
        let migration = try XCTUnwrap(ListeningDayKeyMigration(userCalendar: Calendar(identifier: .gregorian), now: now))
        let daily = [
            "2026-13-45": 30.0, "yesterday": 45, "": 15, "2026-10-05": 60, "2024-12-31": 90, "2025-01-01": 120,
        ]

        let outcome = migration.migrate(daily)

        XCTAssertEqual(outcome.dailyListeningSeconds, [
            "legacy:2026-13-45": 30, "legacy:yesterday": 45, "legacy:": 15, "legacy:2026-10-05": 60,
            "legacy:2024-12-31": 90, "2025-01-01": 120,
        ])
        XCTAssertEqual(outcome.legacyKeys, ["", "2024-12-31", "2026-10-05", "2026-13-45", "yesterday"])
        XCTAssertEqual(outcome.rewrittenKeyCount, 0)
        XCTAssertEqual(outcome.dailyListeningSeconds.values.reduce(0, +), daily.values.reduce(0, +))
    }

    /// A legacy entry kept by an earlier migration, which a version without
    /// key versions then saved unmarked, is kept as it is and not listed
    /// again, while the keys beside it are read as usual.
    func testLegacyEntriesOfAnEarlierMigrationStayAsTheyAre() throws {
        let migration = try XCTUnwrap(ListeningDayKeyMigration(userCalendar: thai(), now: now))

        let outcome = migration.migrate(["legacy:2026-13-45": 30, "2569-10-01": 50])

        XCTAssertEqual(outcome.dailyListeningSeconds, ["legacy:2026-13-45": 30, "2026-10-01": 50])
        XCTAssertEqual(outcome.legacyKeys, [])
        XCTAssertEqual(outcome.rewrittenKeyCount, 1)
    }

    /// A clock that reads a day before TextMouth existed cannot tell which
    /// days are plausible, so there is no migration until it is right; from
    /// the first day TextMouth could have recorded on, there is.
    func testAClockBeforeTextMouthExistedPostponesTheMigration() throws {
        let gregorian = Calendar(identifier: .gregorian)
        XCTAssertNil(ListeningDayKeyMigration(userCalendar: gregorian, now: try time("2024-12-31T23:59:59Z")))
        XCTAssertNotNil(ListeningDayKeyMigration(userCalendar: gregorian, now: try time("2025-01-01T00:00:00Z")))
    }

    // MARK: - Digits and the log

    /// Decimal digits of every script become ASCII digits of the same
    /// value; other characters, numerals that are not decimal digits among
    /// them, are kept.
    func testDigitsOfEveryScriptBecomeASCII() {
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("١٤٤٨-٠٤-٢١"), "1448-04-21") // Arabic-Indic
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("۱۴۰۵-۰۷-۱۰"), "1405-07-10") // Persian
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("๒๕๖๙-๑๐-๐๒"), "2569-10-02") // Thai
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("२०२६-१०-०२"), "2026-10-02") // Devanagari
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("၂၀၂၆-၁၀-၀၂"), "2026-10-02") // Myanmar
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("２０２６-１０-０２"), "2026-10-02") // full width
        XCTAssertEqual(ListeningDayKeyMigration.asciiDigits("Ⅻ-五-06bis"), "Ⅻ-五-06bis")
    }

    /// The log line counts the rewritten keys and quotes the legacy ones;
    /// a migration that changed nothing has none.
    func testLogLineReportsRewrittenAndLegacyKeys() {
        let both = ListeningDayKeyMigration.Outcome(rewrittenKeyCount: 2, legacyKeys: ["2026-13-45", "yesterday"])
        XCTAssertEqual(
            both.logLine,
            #"READING_STATS_DAY_KEYS: rewritten 2, kept as legacy 2: "2026-13-45", "yesterday""#
        )
        XCTAssertEqual(
            ListeningDayKeyMigration.Outcome(rewrittenKeyCount: 3).logLine, "READING_STATS_DAY_KEYS: rewritten 3"
        )
        XCTAssertNil(ListeningDayKeyMigration.Outcome().logLine)
    }

    // MARK: - Helpers

    /// The key the old code wrote for `day` under `locale`: a
    /// default-configured "yyyy-MM-dd" formatter, which took its calendar
    /// and digits from the locale. UTC stands in for the user's time zone,
    /// since a key names a calendar day in whatever zone it was taken.
    private func oldKey(for day: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    /// The Gregorian key of the UTC day containing `day`, written by an
    /// ISO 8601 formatter rather than the code under test.
    private func gregorianKey(for day: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate] // "yyyy-MM-dd" in UTC
        return formatter.string(from: day)
    }

    /// Noon UTC on every `step`th day from `first` through `last`, both
    /// given as "yyyy-MM-dd". UTC days are all 24 hours long.
    private func everyDay(from first: String, through last: String, step: Int = 1) throws -> [Date] {
        let start = try time("\(first)T12:00:00Z")
        let end = try time("\(last)T12:00:00Z")
        return Array(stride(from: start, through: end, by: Double(step) * 86_400))
    }

    /// A Thai user's calendar: Buddhist, with the Thai locale.
    private func thai() -> Calendar {
        var calendar = Calendar(identifier: .buddhist)
        calendar.locale = Locale(identifier: "th_TH")
        return calendar
    }

    /// The moment named by `iso`, an ISO 8601 date and time with its offset
    /// from UTC.
    private func time(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "Not an ISO 8601 time: \(iso)")
    }
}
