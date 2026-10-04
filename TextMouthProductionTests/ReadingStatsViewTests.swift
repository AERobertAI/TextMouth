import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// The Stats settings pane (TODO C07) words each figure once, for the
/// screen and for VoiceOver alike, plural included, and reads every figure
/// at one instant, with the open session's uncredited time in each
/// listening time. While a book plays it stays live without disturbing
/// VoiceOver: each refresh tick reads the figures again and changes only
/// the tiles' words, never which views show them, and announces nothing.
///
/// The hosted tests render the pane offscreen in a window that is never
/// shown, with a clock the test sets by hand and ticks the test sends.
/// SwiftUI builds the accessibility elements of the pane's text only for
/// a connected assistive app, which these runs never have, so the tests
/// watch the pane through its clock instead: the pane reads the clock
/// once each time it reads its figures, so the clock's readings show when
/// the pane refreshed and for which instant.
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

    /// Books finished are counted by kind as well as together (FR03): text
    /// books, audiobooks, and podcast episodes, shown under the count and
    /// spoken with it as one sentence. A kind with no books is left out,
    /// books of no known kind come last as "other books", two parts are
    /// joined by "and", and with no kind known, or no books, the count is
    /// said alone.
    func testBooksFinishedAreCountedByKindInOneSentence() {
        var counted = figures(booksFinishedThisYear: 7, booksFinishedAllTime: 9)
        counted.booksFinishedThisYearByKind = FinishedBookCounts(textBooks: 4, audiobooks: 2, episodes: 1)
        counted.booksFinishedAllTimeByKind = FinishedBookCounts(textBooks: 1, audiobooks: 6)

        XCTAssertEqual(ReadingStatsTile.booksFinishedThisYear.wording(for: counted), ReadingStatsTileWording(
            value: "7 books",
            accessibilityLabel: "7 books finished this year: 4 text books, 2 audiobooks, and 1 podcast episode",
            detail: "4 text books, 2 audiobooks, and 1 podcast episode"
        ))
        XCTAssertEqual(ReadingStatsTile.booksFinishedAllTime.wording(for: counted), ReadingStatsTileWording(
            value: "9 books",
            accessibilityLabel: "9 books finished all time: 1 text book, 6 audiobooks, and 2 other books",
            detail: "1 text book, 6 audiobooks, and 2 other books"
        ))
        XCTAssertEqual(FinishedBookCounts(audiobooks: 1, episodes: 3).breakdown(of: 4), "1 audiobook and 3 podcast episodes")
        XCTAssertEqual(FinishedBookCounts(episodes: 1).breakdown(of: 1), "1 podcast episode")
        XCTAssertNil(FinishedBookCounts().breakdown(of: 5))
        XCTAssertNil(FinishedBookCounts(textBooks: 2).breakdown(of: 0))
        XCTAssertEqual(
            FinishedBookCounts(kinds: [.text, .episode, nil, .episode, .audiobook]),
            FinishedBookCounts(textBooks: 1, audiobooks: 1, episodes: 2)
        )
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

    // MARK: - Refreshing the rendered pane

    /// While a book plays, a refresh tick makes the pane read every figure
    /// again at the new time, though the saved statistics have not
    /// changed: Today, This Week, and All Time each advance by the half
    /// minute since the last reading, so their words change, and nothing
    /// else does. The tick announces nothing. Until C07 a tick refreshed
    /// nothing.
    @MainActor
    func testRefreshTickRereadsTheFiguresWhileABookPlays() throws {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)
        service.checkpointActiveSession(at: noon + interval)
        let saved = service.stats.totalListeningSeconds
        let clock = ManualClock(now: noon + interval + 10)
        let ticks = PassthroughSubject<Void, Never>()

        try withHostedPane(service: service, clock: clock, ticks: ticks) { hostingView in
            XCTAssertEqual(Set(clock.readings), [noon + interval + 10], "Every reading so far is at the first time")
            let shown = ReadingStatsFigures(service: service, at: noon + interval + 10)
            let readingsBeforeTick = clock.readings.count

            clock.now = noon + interval + 40
            let recorder = recordingAnnouncements {
                ticks.send()
                XCTAssertTrue(
                    waitForReading(after: readingsBeforeTick, in: hostingView, clock: clock),
                    "The tick refreshed the pane"
                )
            }

            XCTAssertEqual(clock.readings.last, noon + interval + 40)
            let refreshed = ReadingStatsFigures(service: service, at: noon + interval + 40)
            XCTAssertEqual(refreshed.today, shown.today + 30)
            XCTAssertEqual(refreshed.thisWeek, shown.thisWeek + 30)
            XCTAssertEqual(refreshed.allTime, shown.allTime + 30)
            for tile in ReadingStatsTile.listeningTime {
                XCTAssertNotEqual(tile.wording(for: refreshed), tile.wording(for: shown), tile.title)
            }
            for tile in ReadingStatsTile.progress {
                XCTAssertEqual(tile.wording(for: refreshed), tile.wording(for: shown), tile.title)
            }
            XCTAssertEqual(service.stats.totalListeningSeconds, saved, "The saved statistics did not change")
            XCTAssertEqual(recorder.announcements, [], "A tick announces nothing")
        }
    }

    /// A checkpoint, which changes the saved statistics, refreshes the pane
    /// at once, without waiting for a tick.
    @MainActor
    func testCheckpointRefreshesThePaneWithoutATick() throws {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)
        let clock = ManualClock(now: noon + 30)

        try withHostedPane(service: service, clock: clock, ticks: PassthroughSubject()) { hostingView in
            let readingsBeforeCheckpoint = clock.readings.count

            clock.now = noon + interval
            service.checkpointActiveSession(at: noon + interval)

            XCTAssertTrue(
                waitForReading(after: readingsBeforeCheckpoint, in: hostingView, clock: clock),
                "The checkpoint refreshed the pane"
            )
            XCTAssertEqual(clock.readings.last, noon + interval)
        }
    }

    /// Between ticks and changes to the statistics the pane reads nothing:
    /// it refreshes on those, not continuously.
    @MainActor
    func testPaneReadsNothingBetweenRefreshes() throws {
        let service = makeService()
        service.startSession(bookID: UUID(), at: noon)
        let clock = ManualClock(now: noon + 30)

        try withHostedPane(service: service, clock: clock, ticks: PassthroughSubject()) { hostingView in
            let readings = clock.readings.count
            // Time passing is not something the pane watches.
            clock.now = noon + 45

            _ = waitUntil(timeout: 0.5) {
                hostingView.layoutSubtreeIfNeeded()
                return false
            }

            XCTAssertEqual(clock.readings.count, readings)
        }
    }

    /// A refresh never replaces a tile, which would move VoiceOver's cursor
    /// off it: the pane identifies each tile's row by the tile, never by
    /// its figure, and neither the pane nor a row gives any view an
    /// explicit identity (`.id`) that a refresh could change. A view's type
    /// records both, and a refresh cannot change a type.
    @MainActor
    func testTileRowsKeepTheirIdentityAcrossRefreshes() {
        // An explicit identity shows in a view's type, so not finding one
        // below means something.
        XCTAssertTrue(String(reflecting: type(of: Text("Probe").id(0))).contains("IDView"))

        let pane = String(reflecting: ReadingStatsView.Body.self)
        let row = String(reflecting: ReadingStatsTileRow.Body.self)

        XCTAssertTrue(
            pane.contains(
                "ForEach<Swift.Array<TextMouth.ReadingStatsTile>, TextMouth.ReadingStatsTile, TextMouth.ReadingStatsTileRow>"
            ),
            pane
        )
        XCTAssertFalse(pane.contains("IDView"), pane)
        XCTAssertFalse(row.contains("IDView"), row)
    }

    // MARK: - Helpers

    /// Renders the Stats pane for `service` offscreen, reading `clock` and
    /// refreshing on `ticks`, and passes the hosting view to `body` once
    /// the pane has drawn and stopped reading the clock, so every later
    /// reading comes from what the test does.
    @MainActor
    private func withHostedPane(
        service: ReadingStatsService,
        clock: ManualClock,
        ticks: PassthroughSubject<Void, Never>,
        _ body: (NSView) throws -> Void
    ) throws {
        let pane = ReadingStatsView(
            statsService: service,
            clock: { clock.read() },
            refreshTicks: ticks.eraseToAnyPublisher()
        )
        try withHostedView(pane, until: { _ in !clock.readings.isEmpty }) { hostingView in
            XCTAssertFalse(clock.readings.isEmpty, "The pane never read its figures")
            waitUntilQuiet(hostingView, clock: clock)
            try body(hostingView)
        }
    }

    /// Lays out `hostingView` until the pane has gone a tenth of a second
    /// without reading `clock`, so a refresh left over from the first
    /// render cannot pass for one a test caused.
    @MainActor
    private func waitUntilQuiet(_ hostingView: NSView, clock: ManualClock) {
        var lastCount = clock.readings.count
        var quietChecks = 0
        _ = waitUntil(timeout: 2) {
            hostingView.layoutSubtreeIfNeeded()
            if clock.readings.count == lastCount {
                quietChecks += 1
            } else {
                lastCount = clock.readings.count
                quietChecks = 0
            }
            return quietChecks >= 5
        }
    }

    /// Lays out `hostingView` until the pane reads `clock` again after its
    /// first `count` readings. Returns whether it did within five seconds,
    /// which leaves room for a machine busy with other builds.
    @MainActor
    private func waitForReading(after count: Int, in hostingView: NSView, clock: ManualClock) -> Bool {
        waitUntil(timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return clock.readings.count > count
        }
    }

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

/// A clock a test sets by hand, which records each reading the pane takes.
@MainActor
private final class ManualClock {
    /// The time the clock gives now.
    var now: Date
    /// The times the clock has given, oldest first.
    private(set) var readings: [Date] = []

    init(now: Date) {
        self.now = now
    }

    /// Gives the time now, and records the reading.
    func read() -> Date {
        readings.append(now)
        return now
    }
}
