import XCTest
@testable import TextMouth

/// The diagnostic log policy (TODO Q07): which lines are written, how many,
/// and what they may say. Most tests drive a gate of their own, with their
/// own trace switch, clock, data directory, and writer, so the app's
/// background logging can neither disturb them nor be disturbed by them; the
/// last tests check the app's own gate against the hosted test's sandbox.
final class DiagnosticLogTests: XCTestCase {

    // MARK: - The Rate Limit

    /// A full bucket writes one second's worth of lines at once and drops
    /// the next.
    func testBucketWritesItsRateAtOnceThenDrops() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 20)

        XCTAssertEqual(admitted(&limiter, at: 0, attempts: 20), 20)
        XCTAssertFalse(limiter.admit(at: 0).writesLine, "the 21st line in the same instant is dropped")
    }

    /// The bucket refills at its rate, and never holds more than one
    /// second's worth however long it waits.
    func testBucketRefillsAtItsRateUpToOneSecondsWorth() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 20)
        drain(&limiter, at: 0)

        XCTAssertEqual(admitted(&limiter, at: 0.5, attempts: 15), 10, "half a second earns half the rate")
        XCTAssertEqual(admitted(&limiter, at: 1.5, attempts: 30), 20, "a second earns the full rate")
        XCTAssertEqual(admitted(&limiter, at: 600, attempts: 100), 20, "a long pause still earns one second's worth")
    }

    /// The lines dropped in a burst are reported with the first line the
    /// limit lets through again: how many, and how long ago the first was.
    func testDroppedLinesAreReportedWithTheNextLineWritten() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 20)
        XCTAssertEqual(admitted(&limiter, at: 0, attempts: 20), 20)
        for _ in 0..<5 {
            XCTAssertEqual(limiter.admit(at: 0.01), .init(writesLine: false, droppedLines: nil))
        }

        let next = limiter.admit(at: 1.01)

        XCTAssertTrue(next.writesLine)
        XCTAssertEqual(next.droppedLines?.count, 5)
        XCTAssertEqual(next.droppedLines?.secondsSinceFirst ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(limiter.admit(at: 1.02).droppedLines, "a report starts a new count")
    }

    /// Reports come at most once a minute, however many bursts there are;
    /// the next report counts every line dropped since the last one.
    func testDroppedLinesAreReportedAtMostOnceAMinute() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 20, reportInterval: 60)
        drain(&limiter, at: 0)
        XCTAssertEqual(limiter.admit(at: 1).droppedLines?.count, 1, "the first burst is reported at once")

        for second in 2...59 {
            drain(&limiter, at: TimeInterval(second))
        }
        XCTAssertNil(limiter.admit(at: 60.5).droppedLines, "within a minute of the last report")

        let report = limiter.admit(at: 61).droppedLines
        XCTAssertEqual(report?.count, 58, "one dropped line in each of seconds 2 through 59")
        XCTAssertEqual(report?.secondsSinceFirst ?? 0, 59, accuracy: 1e-9)
    }

    /// Lines that all fit within the limit never produce a report.
    func testNothingIsReportedWhenNothingWasDropped() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 2)

        let admissions = stride(from: 0.0, to: 30.0, by: 0.5).map { limiter.admit(at: $0) }

        XCTAssertTrue(admissions.allSatisfy { $0 == .init(writesLine: true, droppedLines: nil) })
    }

    /// A time earlier than the last refill earns nothing and breaks nothing.
    func testAnEarlierTimeEarnsNothing() {
        var limiter = DiagnosticLog.TraceRateLimiter(linesPerSecond: 20)
        drain(&limiter, at: 100)

        XCTAssertFalse(limiter.admit(at: 50).writesLine)
        XCTAssertEqual(admitted(&limiter, at: 101, attempts: 30), 20)
    }

    // MARK: - The Trace Switch

    /// The environment variable turns tracing on unless its value says off.
    func testEnvironmentVariableTurnsTracingOnUnlessItSaysOff() {
        let variable = DiagnosticLog.TraceSwitch.environmentVariable
        XCTAssertEqual(variable, "TEXTMOUTH_TRACE_LOG")
        XCTAssertFalse(DiagnosticLog.TraceSwitch.environmentTurnsTracingOn([:]))
        for on in ["1", "true", "YES", "on", "verbose"] {
            XCTAssertTrue(DiagnosticLog.TraceSwitch.environmentTurnsTracingOn([variable: on]), on)
        }
        for off in ["", "0", "false", "No", "OFF", " 0 "] {
            XCTAssertFalse(DiagnosticLog.TraceSwitch.environmentTurnsTracingOn([variable: off]), "'\(off)'")
        }
    }

    /// The hidden preference turns tracing on, read leniently, and either
    /// switch alone is enough.
    func testHiddenPreferenceTurnsTracingOn() {
        let store = makeSandboxedPreferences("diagnostic-trace")
        let preference = DiagnosticLog.TraceSwitch.preference
        XCTAssertEqual(preference.key, "diagnosticTraceLogging")
        XCTAssertFalse(DiagnosticLog.TraceSwitch.isOn(environmentTurnsTracingOn: false, preferences: store))
        XCTAssertTrue(DiagnosticLog.TraceSwitch.isOn(environmentTurnsTracingOn: true, preferences: store))

        preference.write(true, to: store)
        XCTAssertTrue(DiagnosticLog.TraceSwitch.isOn(environmentTurnsTracingOn: false, preferences: store))
        store.set("YES", forKey: preference.key)
        XCTAssertTrue(preference.read(from: store), "defaults write -string YES counts")
        preference.write(false, to: store)
        XCTAssertFalse(DiagnosticLog.TraceSwitch.isOn(environmentTurnsTracingOn: false, preferences: store))
    }

    // MARK: - Levels and Files

    /// Trace lines are dropped while tracing is off, and their message is
    /// not even built; once it is on they are written, marked as trace.
    func testTraceLinesAreWrittenOnlyWhileTracingIsOn() {
        let harness = GateHarness()
        var built = 0
        let message: () -> String = {
            built += 1
            return "skipForward called"
        }

        harness.gate.record(.trace, .playback, message(), in: .debug)
        XCTAssertEqual(harness.lines, [])
        XCTAssertEqual(built, 0, "a dropped trace message is never built")

        harness.isTracing = true
        harness.gate.record(.trace, .playback, message(), in: .debug)
        XCTAssertEqual(harness.lines, [Line("TRACE playback: skipForward called", .debug)])
        XCTAssertEqual(harness.echoes, [], "trace lines stay out of the console")
    }

    /// Events are written whether or not tracing is on, exactly as given,
    /// to the file they name, and echoed to the console.
    func testEventLinesAreAlwaysWrittenAsGiven() {
        let harness = GateHarness()

        harness.gate.record(.event, .import, "IMPORT_FAILED: Notes.txt: Reading its text failed", in: .debug)
        harness.gate.record(.event, .playback, "START kind=minutes", in: .sleepTimer)

        XCTAssertEqual(harness.lines, [
            Line("IMPORT_FAILED: Notes.txt: Reading its text failed", .debug),
            Line("START kind=minutes", .sleepTimer)
        ])
        XCTAssertEqual(harness.echoes, ["IMPORT_FAILED: Notes.txt: Reading its text failed", "START kind=minutes"])
    }

    /// The rate limit applies to trace lines only: events are never dropped.
    func testEventsAreNeverRateLimited() {
        let harness = GateHarness(linesPerSecond: 2)

        for index in 0..<10 {
            harness.gate.record(.event, .storage, "LIBRARY_INDEX: event \(index)", in: .debug)
        }

        XCTAssertEqual(harness.lines.count, 10)
    }

    /// A trace line goes to the file it names, marked with its category.
    func testTraceLinesAreMarkedWithTheirCategoryAndGoToTheirFile() {
        let harness = GateHarness()
        harness.isTracing = true

        harness.gate.record(.trace, .playback, "CHUNK_START: offset=0 len=5000", in: .speechTransitions)
        harness.gate.record(.trace, .focus, "scheduled: delay=1.2s", in: .debug)

        XCTAssertEqual(harness.lines, [
            Line("TRACE playback: CHUNK_START: offset=0 len=5000", .speechTransitions),
            Line("TRACE focus: scheduled: delay=1.2s", .debug)
        ])
    }

    /// Each category has its own rate limit: a flood of one never silences
    /// another.
    func testEachCategoryHasItsOwnRateLimit() {
        let harness = GateHarness(linesPerSecond: 3)
        harness.isTracing = true

        for index in 0..<10 {
            harness.gate.record(.trace, .playback, "flood \(index)", in: .debug)
        }
        harness.gate.record(.trace, .focus, "still heard", in: .debug)

        XCTAssertEqual(harness.lines.map(\.text), [
            "TRACE playback: flood 0", "TRACE playback: flood 1", "TRACE playback: flood 2",
            "TRACE focus: still heard"
        ])
    }

    /// Trace lines over the limit are dropped and reported in the debug log,
    /// with the next line the limit lets through, at most once a minute.
    func testDroppedTraceLinesAreReportedInTheDebugLogOnceAMinute() {
        let harness = GateHarness(linesPerSecond: 2)
        harness.isTracing = true

        for index in 0..<5 {
            harness.gate.record(.trace, .playback, "burst \(index)", in: .sleepTimer)
        }
        harness.time = 1
        harness.gate.record(.trace, .playback, "after the burst", in: .sleepTimer)

        let lines = harness.lines
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertEqual(lines.prefix(2).map(\.text), ["TRACE playback: burst 0", "TRACE playback: burst 1"])
        if lines.count == 4 {
            XCTAssertEqual(lines[2].file, .debug, "the report goes to the debug log")
            XCTAssertTrue(
                lines[2].text.hasPrefix("TRACE_SUPPRESSED: dropped 3 playback trace lines since "),
                lines[2].text
            )
            XCTAssertTrue(lines[2].text.hasSuffix(", over the limit of 2 a second"), lines[2].text)
            XCTAssertEqual(lines[3], Line("TRACE playback: after the burst", .sleepTimer))
        }

        // Later bursts within the minute are counted but not yet reported.
        for second in 2...5 {
            harness.time = TimeInterval(second)
            for index in 0..<3 {
                harness.gate.record(.trace, .playback, "second \(second) line \(index)", in: .debug)
            }
        }
        XCTAssertEqual(suppressionReports(in: harness).count, 1)

        harness.time = 61
        harness.gate.record(.trace, .playback, "a minute on", in: .debug)
        let reports = suppressionReports(in: harness)
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(
            reports.last?.hasPrefix("TRACE_SUPPRESSED: dropped 4 playback trace lines since ") == true,
            "one dropped line in each of seconds 2 through 5: \(reports)"
        )
    }

    // MARK: - Content

    /// Every line is kept to one line, and the data directory's location is
    /// cut out of every path in it, in either spelling of a /var path.
    func testLinesAreOneLineWithPathsRelativeToTheDataDirectory() {
        let harness = GateHarness(dataDirectory: "/var/folders/xy/T/Sandbox/.TextMouth")
        harness.isTracing = true

        harness.gate.record(
            .event, .storage,
            "PERSISTENCE_FAILURE: could not save\nPath: /var/folders/xy/T/Sandbox/.TextMouth/library.json",
            in: .debug
        )
        harness.gate.record(
            .trace, .import,
            "read /private/var/folders/xy/T/Sandbox/.TextMouth/Library/Fiction/A.tmb/content.md\nagain",
            in: .debug
        )

        XCTAssertEqual(harness.lines.map(\.text), [
            "PERSISTENCE_FAILURE: could not save Path: library.json",
            "TRACE import: read Library/Fiction/A.tmb/content.md again"
        ])
    }

    /// A loggable path is relative inside the data directory and a bare
    /// name anywhere else; a path that is already relative is left alone.
    func testLoggablePathIsPackageRelativeInsideTheDataDirectoryAndANameOutside() {
        let root = URL(fileURLWithPath: "/tmp/Home/.TextMouth", isDirectory: true)
        func loggable(_ path: String) -> String {
            DiagnosticLog.loggablePath(path, dataDirectory: root)
        }

        XCTAssertEqual(loggable("/tmp/Home/.TextMouth/Library/Fiction/A.tmb/book.epub"), "Library/Fiction/A.tmb/book.epub")
        XCTAssertEqual(loggable("/private/tmp/Home/.TextMouth/library.json"), "library.json")
        XCTAssertEqual(loggable("/Users/someone/Downloads/Field Notes.epub"), "Field Notes.epub")
        XCTAssertEqual(loggable("/tmp/Home/.TextMouth-old/library.json"), "library.json", "a sibling is not inside")
        XCTAssertEqual(loggable("/tmp/Home/.TextMouth"), ".TextMouth", "the data directory is named by its name")
        XCTAssertEqual(loggable("Library/Fiction"), "Library/Fiction")
    }

    /// The prefixes cut from lines always end in a slash, come longest
    /// first, and never include the root directory itself.
    func testDataDirectoryPrefixes() {
        func prefixes(_ path: String) -> [String] {
            DiagnosticLog.dataDirectoryPrefixes(of: URL(fileURLWithPath: path))
        }

        XCTAssertEqual(prefixes("/Users/someone/.TextMouth/"), ["/Users/someone/.TextMouth/"])
        XCTAssertEqual(
            prefixes("/var/folders/T/.TextMouth"),
            ["/private/var/folders/T/.TextMouth/", "/var/folders/T/.TextMouth/"]
        )
        XCTAssertEqual(prefixes("/private/tmp/.TextMouth"), ["/private/tmp/.TextMouth/", "/tmp/.TextMouth/"])
        XCTAssertEqual(prefixes("/"), [])
    }

    // MARK: - The App's Own Gate

    /// An event reaches the real debug log, in the sandbox, with nothing
    /// before its tag but the timestamp.
    func testEventReachesTheDebugLogWithItsTagFirst() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = UUID().uuidString

        DiagnosticLog.event(.storage, "DIAGNOSTIC_PROBE: \(marker)")

        let lines = debugLogLines(containing: marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix(": DIAGNOSTIC_PROBE: \(marker)") == true, "\(lines)")
    }

    /// The app's trace lines follow the hidden preference in the runtime's
    /// preferences store: dropped while it is off, written once it is on.
    func testAppTraceLinesFollowTheHiddenPreference() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = UUID().uuidString

        setAppTracing(false)
        DiagnosticLog.trace(.statistics, "while off \(marker)")
        setAppTracing(true)
        DiagnosticLog.trace(.statistics, "while on \(marker)")

        let lines = debugLogLines(containing: marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix(": TRACE statistics: while on \(marker)") == true, "\(lines)")
    }

    // MARK: - Helpers

    /// Use up every token at `time`, dropping one line more.
    private func drain(_ limiter: inout DiagnosticLog.TraceRateLimiter, at time: TimeInterval) {
        while limiter.admit(at: time).writesLine {}
    }

    /// How many of `attempts` lines arriving at `time` are written.
    private func admitted(
        _ limiter: inout DiagnosticLog.TraceRateLimiter,
        at time: TimeInterval,
        attempts: Int
    ) -> Int {
        var written = 0
        for _ in 0..<attempts where limiter.admit(at: time).writesLine {
            written += 1
        }
        return written
    }

    /// The reports of dropped lines `harness`'s gate has written.
    private func suppressionReports(in harness: GateHarness) -> [String] {
        harness.lines.map(\.text).filter { $0.hasPrefix("\(DiagnosticLog.suppressionTag):") }
    }
}

// MARK: - A Gate of a Test's Own

/// One line a test's gate wrote, and the log it went to.
private struct Line: Equatable, CustomStringConvertible {
    let text: String
    let file: DiagnosticLog.File

    init(_ text: String, _ file: DiagnosticLog.File) {
        self.text = text
        self.file = file
    }

    var description: String { "\(file.rawValue): \(text)" }
}

/// A gate whose switch, clock, and data directory the test sets, and which
/// records the lines it would write and echo instead of writing them.
///
/// `@unchecked Sendable`: the gate's closures may reach this state from any
/// thread, so every stored value is read and changed under `lock`.
private final class GateHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var tracing = false
    private var clock: TimeInterval = 0
    private var written: [Line] = []
    private var echoed: [String] = []

    /// The gate under test.
    private(set) var gate: DiagnosticLog.Gate!

    /// A harness whose gate keeps `linesPerSecond` trace lines a second, its
    /// tracing off and its clock at zero, for a data directory at
    /// `dataDirectory`.
    init(linesPerSecond: Int = 20, dataDirectory: String = "/Users/someone/.TextMouth") {
        let root = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        gate = DiagnosticLog.Gate(
            isTracing: { [unowned self] in self.isTracing },
            now: { [unowned self] in self.time },
            dataDirectory: { root },
            traceLinesPerSecond: linesPerSecond,
            reportInterval: 60,
            write: { [unowned self] line, file in self.locked { self.written.append(Line(line, file)) } },
            echo: { [unowned self] line in self.locked { self.echoed.append(line) } }
        )
    }

    /// Whether the gate traces.
    var isTracing: Bool {
        get { locked { tracing } }
        set { locked { tracing = newValue } }
    }

    /// The gate's clock, in seconds.
    var time: TimeInterval {
        get { locked { clock } }
        set { locked { clock = newValue } }
    }

    /// The lines written so far, in order.
    var lines: [Line] { locked { written } }

    /// The lines echoed to the console so far, in order.
    var echoes: [String] { locked { echoed } }

    /// Runs `body` while holding the lock.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Logging in the Hosted App

/// The hidden trace preference as the runtime's preferences store held it
/// before a test changed it, to put back when the test ends.
///
/// `@unchecked Sendable` so a teardown block can restore it: the value is a
/// constant property-list object, which the store only copies.
private struct SavedTracePreference: @unchecked Sendable {
    /// The value under the key before, or nil when there was none.
    let value: Any?

    /// Read the preference's value from the runtime's store.
    init() {
        value = TextMouthRuntime.current.preferences.object(forKey: DiagnosticLog.TraceSwitch.preference.key)
    }

    /// Put the earlier value back, or remove the key if there was none.
    func restore() {
        let store = TextMouthRuntime.current.preferences
        let key = DiagnosticLog.TraceSwitch.preference.key
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
}

extension XCTestCase {
    /// Turn the app's tracing on or off through the hidden preference in the
    /// runtime's preferences store, as the developer would, restoring the
    /// store's earlier value when the test ends.
    func setAppTracing(_ isOn: Bool) {
        let saved = SavedTracePreference()
        addTeardownBlock { saved.restore() }
        DiagnosticLog.TraceSwitch.preference.write(isOn, to: TextMouthRuntime.current.preferences)
    }

    /// The lines written to the log `file` while `body` runs, waiting first
    /// for every queued write. A log rotated meanwhile starts a new file
    /// holding only new lines.
    func logLines(in file: DiagnosticLog.File, writtenDuring body: () throws -> Void) rethrows -> [String] {
        let log = file.url
        TextMouthPaths.flushLogs()
        let before = (try? Data(contentsOf: log)) ?? Data()
        try body()
        TextMouthPaths.flushLogs()
        let after = (try? Data(contentsOf: log)) ?? Data()
        let written = after.starts(with: before) ? after.dropFirst(before.count) : after
        return String(decoding: written, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
