import Darwin
import Foundation
import XCTest
@testable import TextMouth

// Performance regression tests with committed baselines (TODO Q05, the
// developer's decision of October 3): what PerformanceBaselineTests measure,
// the baselines they compare with (performance-baselines.json, beside this
// file), and the rules that decide when a number has regressed.
//
// - Each measurement is the median of five runs, after one more that warms
//   caches and is not counted, since a process's first run of anything pays
//   costs the developer pays once a session at most.
// - A median more than twice its baseline is measured once more, five runs
//   again, and the test fails when the lower of the two medians is still
//   more than twice its baseline. A number at 1.5 times its baseline or more
//   prints a warning line, and one at half its baseline or less prints a
//   note that recording new baselines would tighten the check.
// - The tests skip, saying why, while the Mac is busy (its one-minute load
//   average above its number of cores), so other builds cannot fail them,
//   unless TEXTMOUTH_PERFORMANCE_STRICT is 1 (for xcodebuild,
//   TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1, which `make check` sets).
//   They also skip on any other Mac model or build configuration than the
//   baselines were recorded with, where the numbers say nothing.
// - With TEXTMOUTH_PERFORMANCE_RECORD set to 1 (`make perf-baselines`), they
//   compare nothing: each test waits for a quiet Mac, measures, and once
//   every measurement has its number, the run rewrites
//   performance-baselines.json, printing each old and new number.
//
// Every line the tests print starts with PERFORMANCE, so a log can be
// searched for them; `make check` repeats the warning and skip lines.

// MARK: - Units

/// The unit a measurement is in, named in full so that it reads clearly in
/// speech and braille.
enum PerformanceUnit: String, Codable, Sendable, CaseIterable {
    case milliseconds
    case microseconds
    case bytes
    case megabytes

    /// `value` rounded as a baseline in this unit is recorded: bytes to the
    /// whole byte, everything else to the thousandth.
    func rounded(_ value: Double) -> Double {
        switch self {
        case .bytes:
            return value.rounded()
        case .milliseconds, .microseconds, .megabytes:
            return (value * 1_000).rounded() / 1_000
        }
    }

    /// `value` in words, such as "12.345 milliseconds" or "838 bytes".
    func describe(_ value: Double) -> String {
        switch self {
        case .bytes:
            return "\(Int(value.rounded())) bytes"
        case .milliseconds, .microseconds, .megabytes:
            return "\(String(format: "%.3f", value)) \(rawValue)"
        }
    }
}

// MARK: - Measurements

/// One number PerformanceBaselineTests keeps a baseline for.
struct PerformanceMeasure: Hashable, Sendable {
    /// Its key in performance-baselines.json, such as "launch".
    let name: String
    /// What it measures, in a sentence of its own.
    let summary: String
    /// The unit it is measured in.
    let unit: PerformanceUnit
}

extension PerformanceMeasure {
    /// Launch with a library the size of the developer's.
    static let launch = PerformanceMeasure(
        name: "launch",
        summary: "Launch with a 643-book library: reading library.json, the startup repair, and the text cache check.",
        unit: .milliseconds
    )

    /// The first File Size sort, which measures every package.
    static let firstSortByFileSize = PerformanceMeasure(
        name: "list.firstSortByFileSize",
        summary: "The first sort of the 643 books by File Size, which measures every book's package.",
        unit: .milliseconds
    )

    /// One derivation of the whole library's list, sorted by `field`.
    static func listDerivation(_ field: LibrarySortField) -> PerformanceMeasure {
        PerformanceMeasure(
            name: "list.derivation.\(field.baselineName)",
            summary: "One derivation of the 643-book All Items list sorted by \(field.rawValue).",
            unit: .milliseconds
        )
    }

    /// One live reading position, as a playing reader reports each second.
    static let liveReadingPosition = PerformanceMeasure(
        name: "livePosition.update",
        summary: "One live reading position update in a 643-book library, as a playing reader makes each second.",
        unit: .microseconds
    )

    /// What one reading checkpoint writes.
    static let checkpointBytes = PerformanceMeasure(
        name: "checkpoint.bytes",
        summary: "Bytes one 30-second reading checkpoint writes for a book with a 690 KB content index "
            + "in a 643-book library.",
        unit: .bytes
    )

    /// Opening a text book, through the speech of the chapter it opens at.
    static let openTextBook = PerformanceMeasure(
        name: "open.textBook",
        summary: "Opening the 1 MB EPUB in a reader until the speech of its first chapter is prepared.",
        unit: .milliseconds
    )

    /// Opening an audiobook whose chapters are files of their own.
    static let openAudiobook = PerformanceMeasure(
        name: "open.audiobook",
        summary: "Opening a 3-file audiobook in a reader until it has loaded.",
        unit: .milliseconds
    )

    /// Preparing the speech of a chapter of a million characters.
    static let speechPreparation = PerformanceMeasure(
        name: "speech.millionCharacterChapter",
        summary: "Preparing the speech of a 1,000,000-character chapter with the developer's 16 substitution rules.",
        unit: .milliseconds
    )

    /// The most memory rendering a 40,000-character chapter takes.
    static let renderPeakMemory = PerformanceMeasure(
        name: "render.peakMemory",
        summary: "The most memory taken while a 40,000-character chapter's rendered speech is built.",
        unit: .megabytes
    )

    /// The memory a 40,000-character chapter's rendered speech keeps.
    static let renderKeptMemory = PerformanceMeasure(
        name: "render.keptMemory",
        summary: "The memory a 40,000-character chapter's rendered speech keeps once built.",
        unit: .megabytes
    )

    /// Extracting a 1 MB EPUB's text.
    static let epubExtraction = PerformanceMeasure(
        name: "epub.extraction",
        summary: "Extracting the 1 MB EPUB's text into content.md, with its index and fingerprints.",
        unit: .milliseconds
    )

    /// One cloud refresh of a library on this Mac, in processor time.
    static let cloudRefresh = PerformanceMeasure(
        name: "cloud.refreshLocalLibrary",
        summary: "Processor time, on every thread, of one cloud refresh of a 643-book library "
            + "that is not in a cloud location.",
        unit: .milliseconds
    )

    /// What a reader publish costs its open Headings sheet.
    static let headingSheetPublish = PerformanceMeasure(
        name: "headingSheet.publish",
        summary: "Main-thread time one reader publish costs the open Headings sheet of a 180-heading book.",
        unit: .milliseconds
    )

    /// Every measurement PerformanceBaselineTests makes, each once. A run
    /// that records baselines writes them only once it has all of these.
    static let all: [PerformanceMeasure] = [
        launch, firstSortByFileSize,
    ] + LibrarySortField.allCases.map(listDerivation) + [
        liveReadingPosition, checkpointBytes, openTextBook, openAudiobook, speechPreparation,
        renderPeakMemory, renderKeptMemory, epubExtraction, cloudRefresh, headingSheetPublish,
    ]
}

extension LibrarySortField {
    /// The field's name in a baseline's key: a fixed spelling of its own,
    /// so renaming the field in Settings never renames a baseline. A field
    /// added later must be named here, which asks for its baseline too.
    var baselineName: String {
        switch self {
        case .title: return "title"
        case .author: return "author"
        case .dateAdded: return "dateAdded"
        case .lastOpened: return "lastOpened"
        case .fileSize: return "fileSize"
        case .manual: return "manualOrder"
        }
    }
}

// MARK: - The Machine

/// The Mac the measurements run on, as the baselines record it.
struct MachineIdentity: Codable, Equatable, Sendable {
    /// The model identifier, such as "Mac15,12": the field compared.
    var model: String
    /// The processor, such as "Apple M3".
    var chip: String
    /// The cores macOS has active.
    var cores: Int
    /// The memory, in whole gigabytes.
    var memoryGigabytes: Int

    /// This Mac.
    static var current: MachineIdentity {
        let bytes = sysctlUnsignedInteger("hw.memsize") ?? 0
        return MachineIdentity(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            cores: ProcessInfo.processInfo.activeProcessorCount,
            memoryGigabytes: Int((Double(bytes) / 1_073_741_824).rounded())
        )
    }

    /// The Mac in words, such as "a Mac15,12 (Apple M3, 8 cores, 8 GB)".
    var spoken: String {
        "a \(model) (\(chip), \(cores) cores, \(memoryGigabytes) GB)"
    }

    /// The text value of the system control `name`, or nil when there is
    /// none.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // The value ends at its first NUL byte.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The 64-bit unsigned value of the system control `name`, or nil when
    /// there is none.
    private static func sysctlUnsignedInteger(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// How busy the Mac is.
enum MachineLoad {
    /// The one-minute load average: how many threads, on average over the
    /// last minute, were running or waiting to run. Nil when macOS gives
    /// none.
    static func oneMinuteAverage() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) >= 1 else { return nil }
        return averages[0]
    }
}

/// The build configuration the tests were compiled in, "Debug" or
/// "Release": baselines describe one configuration only.
let performanceBuildConfiguration: String = {
    #if DEBUG
    return "Debug"
    #else
    return "Release"
    #endif
}()

// MARK: - The Baselines File

/// performance-baselines.json: the Mac and configuration the baselines were
/// recorded with, the date, and each measurement's baseline.
struct PerformanceBaselineFile: Codable, Equatable, Sendable {
    /// One measurement's baseline.
    struct Baseline: Codable, Equatable, Sendable {
        /// The median of five runs when it was recorded.
        var value: Double
        /// The unit `value` is in.
        var unit: PerformanceUnit
        /// What the measurement measures.
        var summary: String
    }

    /// What the file is and how to rewrite it, for a person reading it.
    var about: String
    /// The Mac the baselines were recorded on.
    var machine: MachineIdentity
    /// The build configuration they were recorded in.
    var configuration: String
    /// The day they were recorded, as YYYY-MM-DD.
    var recorded: String
    /// How many runs each baseline is the median of.
    var runsPerMeasurement: Int
    /// Each measurement's baseline, by its name.
    var baselines: [String: Baseline]

    /// Where the file lives: beside this source file, in the checkout the
    /// tests were built from.
    static let location = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("performance-baselines.json")

    /// The text every recorded file carries in `about`.
    static let aboutText = "Baselines for PerformanceBaselineTests, each the median of five runs on the Mac named "
        + "below, in the build configuration named below. A test fails when its number is more than twice "
        + "its baseline (measured twice before it fails) and prints a warning at 1.5 times. Rewrite this file "
        + "with make perf-baselines after a deliberate change, on a quiet Mac."

    /// The file at `url`, decoded.
    static func read(from url: URL = location) throws -> PerformanceBaselineFile {
        try JSONDecoder().decode(PerformanceBaselineFile.self, from: Data(contentsOf: url))
    }

    /// The file as it is written: pretty-printed with sorted keys, so a
    /// change shows as a small diff, and ending with a line break.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

// MARK: - The Rules

/// The rules that turn runs into a number, compare a number with its
/// baseline, and decide when the Mac is fit to measure on. Pure, so
/// PerformanceBaselineRulesTests can check each one.
enum PerformanceRules {
    /// How many runs each measurement is the median of.
    static let runs = 5
    /// How many runs come first, uncounted, to warm caches: a process's
    /// first audiobook opened, for one, loads frameworks for seconds.
    static let warmUpRuns = 1
    /// A number more than this many times its baseline fails its test.
    static let failureRatio = 2.0
    /// A number at least this many times its baseline prints a warning.
    static let warningRatio = 1.5
    /// A number at most this many times its baseline prints a note that new
    /// baselines would tighten the check.
    static let tighteningRatio = 0.5

    /// The median of `samples`: the middle one, or the mean of the two
    /// middle ones when there are an even number. Nil for no samples.
    static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// How a number compares with its baseline.
    enum Verdict: Equatable {
        /// More than twice the baseline: the test fails.
        case regressed
        /// 1.5 times the baseline or more, up to twice: a warning line.
        case warning
        /// Between half the baseline and 1.5 times it.
        case within
        /// Half the baseline or less: new baselines would tighten the check.
        case muchFaster
    }

    /// How `value` compares with `baseline`, which must be above zero.
    static func verdict(value: Double, baseline: Double) -> Verdict {
        if value > baseline * failureRatio { return .regressed }
        if value >= baseline * warningRatio { return .warning }
        if value <= baseline * tighteningRatio { return .muchFaster }
        return .within
    }

    /// Why the Mac is too busy to measure on, or nil when it is not: its
    /// one-minute load average is above its number of cores.
    static func busyReason(loadAverage: Double, cores: Int) -> String? {
        guard loadAverage > Double(cores) else { return nil }
        return "the Mac is busy: its one-minute load average is \(String(format: "%.2f", loadAverage)), "
            + "above its \(cores) cores, so other work would distort the numbers"
    }

    /// Why `file`'s baselines do not apply to a run on `machine` in
    /// `configuration`, or nil when they do: they were recorded on another
    /// Mac model, or in another build configuration.
    static func mismatchReason(
        of file: PerformanceBaselineFile,
        machine: MachineIdentity,
        configuration: String
    ) -> String? {
        if file.machine.model != machine.model {
            return "the baselines were recorded on \(file.machine.spoken), and this Mac is \(machine.spoken); "
                + "run make perf-baselines on this Mac to record its own"
        }
        if file.configuration != configuration {
            return "the baselines were recorded in a \(file.configuration) build, and these tests were built "
                + "for \(configuration)"
        }
        return nil
    }

    /// A ratio in words, such as "1.04 times".
    static func describeRatio(_ ratio: Double) -> String {
        "\(String(format: "%.2f", ratio)) times"
    }
}

// MARK: - Settings

/// How a run of PerformanceBaselineTests was asked to behave, from the
/// test host's environment. xcodebuild hands the host every variable whose
/// name starts with TEST_RUNNER_, without that prefix.
struct PerformanceRunSettings: Equatable, Sendable {
    /// The variable that makes a busy Mac measure anyway.
    static let strictVariable = "TEXTMOUTH_PERFORMANCE_STRICT"
    /// The variable that records new baselines instead of comparing.
    static let recordVariable = "TEXTMOUTH_PERFORMANCE_RECORD"

    /// Whether a busy Mac measures anyway: `make check` asks for this, since
    /// it runs the tests right after building, and must not skip them.
    var isStrict: Bool
    /// Whether the run records new baselines rather than comparing.
    var isRecording: Bool

    /// The settings `environment` asks for: each variable must be exactly 1.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isStrict = environment[Self.strictVariable] == "1"
        isRecording = environment[Self.recordVariable] == "1"
    }
}

// MARK: - Errors

/// What can stop a measurement before it has a number.
enum PerformanceBaselineError: LocalizedError {
    /// performance-baselines.json could not be read.
    case unreadableBaselines(URL, Error)
    /// A fixture or step the measurement depends on went wrong.
    case fixture(String)

    var errorDescription: String? {
        switch self {
        case .unreadableBaselines(let url, let error):
            return "\(url.path) could not be read (\(error.localizedDescription)); "
                + "record baselines with make perf-baselines"
        case .fixture(let message):
            return message
        }
    }
}

// MARK: - A Run

/// One run of PerformanceBaselineTests: decides whether each test may
/// measure, measures, compares each number with its baseline or records it,
/// and, when recording, writes the new baselines once every measurement has
/// its number. The test process has one; the tests share it.
@MainActor
final class PerformanceBaselineRun {
    /// The run every test in this process shares.
    static let shared = PerformanceBaselineRun()

    /// How the run was asked to behave.
    let settings: PerformanceRunSettings
    /// The Mac it runs on.
    let machine: MachineIdentity
    /// The build configuration the tests were compiled in.
    let configuration: String
    /// Where the baselines are read from and, when recording, written to.
    let location: URL
    /// The longest a recording run waits for a busy Mac to quiet down
    /// before each test, in seconds.
    let quietWaitLimit: TimeInterval
    /// Where the run's lines go: the test log, unless a test of the run
    /// itself keeps them, so its pretend numbers never read as measurements.
    private let report: (String) -> Void

    /// The baselines, once read.
    private var baselines: PerformanceBaselineFile?
    /// The numbers measured so far in a recording run, by measurement name.
    private var recorded: [String: (measure: PerformanceMeasure, value: Double)] = [:]
    /// Whether this recording run has written its baselines.
    private var wroteBaselines = false
    /// Whether a test of this recording run gave up waiting for a quiet Mac.
    private var gaveUpWaiting = false

    /// A run of these settings, on this Mac, reading and writing the
    /// baselines at `location`, and printing its lines to the test log
    /// unless `report` takes them.
    init(
        settings: PerformanceRunSettings = PerformanceRunSettings(),
        machine: MachineIdentity = .current,
        configuration: String = performanceBuildConfiguration,
        location: URL = PerformanceBaselineFile.location,
        quietWaitLimit: TimeInterval = 300,
        report: @escaping (String) -> Void = { print($0) }
    ) {
        self.settings = settings
        self.machine = machine
        self.configuration = configuration
        self.location = location
        self.quietWaitLimit = quietWaitLimit
        self.report = report
    }

    // MARK: Before Each Test

    /// Readies a test to measure, or throws `XCTSkip` saying why it cannot:
    /// the baselines describe another Mac or configuration, or the Mac is
    /// busy and the run is not strict. A recording run compares nothing, so
    /// it never skips for another Mac, and it waits for a busy Mac to quiet
    /// down before it gives up. Missing or unreadable baselines fail the
    /// test, since they are committed.
    func prepareToMeasure() async throws {
        if !settings.isRecording {
            let file = try readBaselines()
            if let mismatch = PerformanceRules.mismatchReason(of: file, machine: machine, configuration: configuration) {
                throw skip(mismatch)
            }
        }
        if settings.isStrict {
            // Measured all the same, but a failure on a busy Mac is easier
            // to understand when the log says it was busy.
            if let busy = currentBusyReason() {
                report("PERFORMANCE: measuring anyway, since \(PerformanceRunSettings.strictVariable) is 1, although \(busy)")
            }
        } else if settings.isRecording {
            try await waitForAQuietMac()
        } else if let busy = currentBusyReason() {
            throw skip("\(busy); set TEST_RUNNER_\(PerformanceRunSettings.strictVariable)=1 to measure anyway")
        }
    }

    /// The baselines, read once.
    private func readBaselines() throws -> PerformanceBaselineFile {
        if let baselines { return baselines }
        do {
            let file = try PerformanceBaselineFile.read(from: location)
            baselines = file
            return file
        } catch {
            throw PerformanceBaselineError.unreadableBaselines(location, error)
        }
    }

    /// Why the Mac is too busy to measure on now, or nil when it is not.
    private func currentBusyReason() -> String? {
        guard let load = MachineLoad.oneMinuteAverage() else { return nil }
        return PerformanceRules.busyReason(loadAverage: load, cores: machine.cores)
    }

    /// Waits, checking every five seconds and saying so every thirty, until
    /// the Mac is no longer busy, for at most `quietWaitLimit` seconds, then
    /// skips the test. Once one test has given up, the rest skip at once:
    /// the recording can no longer be complete, so nothing will be written.
    private func waitForAQuietMac() async throws {
        guard !gaveUpWaiting else {
            throw skip("an earlier test gave up waiting for a quiet Mac, so nothing will be recorded")
        }
        let deadline = Date().addingTimeInterval(quietWaitLimit)
        var nextNotice = Date()
        while let busy = currentBusyReason() {
            guard Date() < deadline else {
                gaveUpWaiting = true
                throw skip("\(busy) after waiting \(Int(quietWaitLimit)) seconds; nothing was recorded")
            }
            if Date() >= nextNotice {
                report("PERFORMANCE: waiting to record until the Mac quiets down: \(busy)")
                nextNotice = Date().addingTimeInterval(30)
            }
            try await Task.sleep(for: .seconds(5))
        }
    }

    /// An XCTSkip for `reason`, printed first on a line of its own so a
    /// test log, and `make check`, can say why the tests did not measure.
    private func skip(_ reason: String) -> XCTSkip {
        report("PERFORMANCE SKIPPED: \(reason)")
        return XCTSkip("Performance baselines: \(reason)")
    }

    // MARK: Measuring

    /// Measures `measure` with `sample`, which runs the measured work once
    /// and returns its number, and checks or records the median of five
    /// runs, after a warm-up run that is not counted. Throws what `sample`
    /// throws, or XCTSkip when the Mac turned busy before a regression could
    /// be confirmed.
    func check(
        _ measure: PerformanceMeasure,
        file: StaticString = #filePath,
        line: UInt = #line,
        sample: () throws -> Double
    ) throws {
        try check([measure], file: file, line: line) { [try sample()] }
    }

    /// Measures every one of `measures` with `sample`, which runs the
    /// measured work once and returns a number for each, in order, and
    /// checks or records the median of five runs of each. A regression in
    /// any of them measures all of them five times more.
    func check(
        _ measures: [PerformanceMeasure],
        file: StaticString = #filePath,
        line: UInt = #line,
        sample: () throws -> [Double]
    ) throws {
        try requireCatalogued(measures)
        for _ in 0..<PerformanceRules.warmUpRuns {
            _ = try sample()
        }
        let first = try medians(of: (0..<PerformanceRules.runs).map { _ in try sample() }, for: measures)
        let second = try needsASecondLook(measures, medians: first)
            ? medians(of: (0..<PerformanceRules.runs).map { _ in try sample() }, for: measures)
            : nil
        try conclude(measures, first: first, second: second, file: file, line: line)
    }

    /// Measures `measure` with `sample`, which runs the measured work once,
    /// awaiting it, and returns its number, as `check(_:sample:)` does. Named
    /// apart from `check`, so an asynchronous test calling the synchronous
    /// one never has an overload chosen for it. `sample` runs on the main
    /// actor, as the tests do, so awaiting it crosses no isolation.
    func checkAwaiting(
        _ measure: PerformanceMeasure,
        file: StaticString = #filePath,
        line: UInt = #line,
        sample: @MainActor () async throws -> Double
    ) async throws {
        try requireCatalogued([measure])
        for _ in 0..<PerformanceRules.warmUpRuns {
            _ = try await sample()
        }
        let first = try medians(of: try await Self.runs(of: sample), for: [measure])
        var second: [Double]?
        if needsASecondLook([measure], medians: first) {
            second = try medians(of: try await Self.runs(of: sample), for: [measure])
        }
        try conclude([measure], first: first, second: second, file: file, line: line)
    }

    /// `PerformanceRules.runs` runs of `sample`, each awaited before the
    /// next begins, as `check` takes its runs.
    private static func runs(of sample: @MainActor () async throws -> Double) async rethrows -> [[Double]] {
        var runs: [[Double]] = []
        for _ in 0..<PerformanceRules.runs {
            runs.append([try await sample()])
        }
        return runs
    }

    /// Throws unless every one of `measures` is in `PerformanceMeasure.all`,
    /// the list a recording run must complete before it writes anything.
    private func requireCatalogued(_ measures: [PerformanceMeasure]) throws {
        for measure in measures where !PerformanceMeasure.all.contains(measure) {
            throw PerformanceBaselineError.fixture("\(measure.name) is not listed in PerformanceMeasure.all")
        }
    }

    /// The median of each measurement's numbers in `runs`, in the order of
    /// `measures`, each printed with the runs it came from.
    private func medians(of runs: [[Double]], for measures: [PerformanceMeasure]) throws -> [Double] {
        try measures.enumerated().map { index, measure in
            let samples = try runs.map { run -> Double in
                guard run.indices.contains(index), run[index].isFinite else {
                    throw PerformanceBaselineError.fixture("\(measure.name): a run returned no number")
                }
                return run[index]
            }
            guard let median = PerformanceRules.median(samples) else {
                throw PerformanceBaselineError.fixture("\(measure.name): no runs were made")
            }
            let load = MachineLoad.oneMinuteAverage().map { String(format: "%.2f", $0) } ?? "unknown"
            report(
                "PERFORMANCE: \(measure.name): median \(measure.unit.describe(median)) of "
                    + "\(samples.map { String(format: "%.3f", $0) }.joined(separator: ", ")) "
                    + "(load \(load) on \(machine.cores) cores)"
            )
            return median
        }
    }

    /// Whether any of `measures`, at these medians, regressed and so is
    /// measured again before a test fails. A recording run compares nothing.
    private func needsASecondLook(_ measures: [PerformanceMeasure], medians: [Double]) -> Bool {
        guard !settings.isRecording, let file = baselines else { return false }
        return zip(measures, medians).contains { measure, median in
            guard let baseline = file.baselines[measure.name], baseline.value > 0 else { return false }
            return PerformanceRules.verdict(value: median, baseline: baseline.value) == .regressed
        }
    }

    /// Records each measurement's number, or compares it with its baseline:
    /// the lower of its two medians when it was measured twice.
    private func conclude(
        _ measures: [PerformanceMeasure],
        first: [Double],
        second: [Double]?,
        file: StaticString,
        line: UInt
    ) throws {
        if settings.isRecording {
            for (measure, value) in zip(measures, first) {
                record(measure, value: value, file: file, line: line)
            }
            return
        }
        // A regression measured while the Mac turned busy says nothing; a
        // strict run fails it all the same.
        if second != nil, !settings.isStrict, let busy = currentBusyReason() {
            throw skip("\(busy), so a slower number could not be confirmed")
        }
        for (index, measure) in measures.enumerated() {
            let value = second.map { min(first[index], $0[index]) } ?? first[index]
            compare(measure, value: value, measuredTwice: second.map { (first[index], $0[index]) }, file: file, line: line)
        }
    }

    /// Compares `value` with `measure`'s baseline: fails above twice it,
    /// prints a warning at 1.5 times it, and a note at half of it or less.
    private func compare(
        _ measure: PerformanceMeasure,
        value: Double,
        measuredTwice: (Double, Double)?,
        file: StaticString,
        line: UInt
    ) {
        let rerecord = "If the change was deliberate, record new baselines with make perf-baselines."
        guard let baseline = baselines?.baselines[measure.name] else {
            XCTFail("\(measure.name) has no baseline in \(location.lastPathComponent). \(rerecord)", file: file, line: line)
            return
        }
        guard baseline.unit == measure.unit, baseline.value > 0 else {
            XCTFail(
                "\(measure.name)'s baseline, \(baseline.unit.describe(baseline.value)), cannot be compared with "
                    + "a number in \(measure.unit.rawValue). \(rerecord)",
                file: file,
                line: line
            )
            return
        }
        let ratio = value / baseline.value
        let comparison = "\(measure.unit.describe(value)), \(PerformanceRules.describeRatio(ratio)) "
            + "its baseline of \(measure.unit.describe(baseline.value))"
        switch PerformanceRules.verdict(value: value, baseline: baseline.value) {
        case .regressed:
            let twice = measuredTwice.map {
                " Measured twice: \(measure.unit.describe($0.0)), then \(measure.unit.describe($0.1))."
            } ?? ""
            XCTFail(
                "\(measure.name): \(comparison), more than twice it. \(measure.summary)\(twice) \(rerecord)",
                file: file,
                line: line
            )
        case .warning:
            report("PERFORMANCE WARNING: \(measure.name): \(comparison); the test fails above twice its baseline.")
        case .muchFaster:
            report("PERFORMANCE NOTE: \(measure.name): \(comparison); make perf-baselines would tighten the check.")
        case .within:
            report("PERFORMANCE: \(measure.name): \(comparison).")
        }
    }

    // MARK: Recording

    /// Keeps `value` as `measure`'s new baseline, and writes every new
    /// baseline once all of them have one.
    private func record(_ measure: PerformanceMeasure, value: Double, file: StaticString, line: UInt) {
        // A baseline of nothing could never be doubled: a number that rounds
        // to zero in its unit has to be measured over more work at once.
        let rounded = measure.unit.rounded(value)
        guard rounded > 0 else {
            XCTFail(
                "\(measure.name) measured \(measure.unit.describe(value)), which records as nothing",
                file: file,
                line: line
            )
            return
        }
        recorded[measure.name] = (measure, rounded)
        report("PERFORMANCE MEASURED: \(measure.name): \(measure.unit.describe(value))")
        let missing = PerformanceMeasure.all.filter { recorded[$0.name] == nil }
        guard missing.isEmpty, !wroteBaselines else { return }
        do {
            try writeRecordedBaselines()
            wroteBaselines = true
        } catch {
            XCTFail("The new baselines could not be written to \(location.path): \(error)", file: file, line: line)
        }
    }

    /// Writes the recorded numbers as the new baselines, printing each old
    /// and new number.
    private func writeRecordedBaselines() throws {
        let old = try? PerformanceBaselineFile.read(from: location)
        let new = PerformanceBaselineFile(
            about: PerformanceBaselineFile.aboutText,
            machine: machine,
            configuration: configuration,
            recorded: Self.today(),
            runsPerMeasurement: PerformanceRules.runs,
            baselines: recorded.mapValues {
                PerformanceBaselineFile.Baseline(value: $0.value, unit: $0.measure.unit, summary: $0.measure.summary)
            }
        )
        for (name, baseline) in new.baselines.sorted(by: { $0.key < $1.key }) {
            report("PERFORMANCE RECORDED: \(name): \(Self.change(from: old?.baselines[name], to: baseline))")
        }
        let removed = Set(old?.baselines.keys.map { $0 } ?? []).subtracting(new.baselines.keys)
        for name in removed.sorted() {
            report("PERFORMANCE RECORDED: \(name): removed, no longer measured")
        }
        if let old, old.machine != machine {
            report("PERFORMANCE RECORDED: the baselines move from \(old.machine.spoken) to \(machine.spoken)")
        }
        try new.encoded().write(to: location, options: .atomic)
        report(
            "PERFORMANCE BASELINES WRITTEN: \(location.path) for \(machine.spoken), "
                + "\(configuration) build, \(new.recorded)"
        )
    }

    /// An old and a new baseline in words, such as "from 9.700 to 10.123
    /// milliseconds, 1.04 times the old baseline".
    static func change(
        from old: PerformanceBaselineFile.Baseline?,
        to new: PerformanceBaselineFile.Baseline
    ) -> String {
        guard let old, old.unit == new.unit, old.value > 0 else {
            return "\(new.unit.describe(new.value)), new"
        }
        let ratio = PerformanceRules.describeRatio(new.value / old.value)
        return "from \(old.unit.describe(old.value)) to \(new.unit.describe(new.value)), \(ratio) the old baseline"
    }

    /// Today's date in this Mac's time zone, as YYYY-MM-DD.
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - Clocks

/// The clocks the measurements read.
enum PerformanceClock {
    /// Milliseconds since `start` on the continuous clock.
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(in: start.duration(to: .now))
    }

    /// `duration` in milliseconds.
    static func milliseconds(in duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    /// How many milliseconds `body` took on the continuous clock.
    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        return milliseconds(since: start)
    }

    /// The processor time the calling thread has used, in nanoseconds: on
    /// the main thread, how long it was kept busy, which neither waiting
    /// nor other processes add to.
    static func threadCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    /// The processor time every thread of this process has used, in
    /// nanoseconds: the work of something that hands its work to other
    /// threads, which a busy Mac's waits for those threads do not add to.
    static func processCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    }
}
