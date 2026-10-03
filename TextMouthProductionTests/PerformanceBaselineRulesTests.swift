import XCTest
@testable import TextMouth

/// The rules and files behind PerformanceBaselineTests (TODO Q05), checked
/// without measuring anything, so they hold on every Mac, busy or not:
/// medians, the verdicts at twice and 1.5 times a baseline, when the Mac
/// counts as busy or the baselines as another Mac's, the settings the
/// environment gives, comparing and confirming a regression, recording new
/// baselines, the list of measurements, and the committed rules and
/// baselines files.
@MainActor
final class PerformanceBaselineRulesTests: XCTestCase {

    // MARK: - Medians

    /// The median is the middle number of an odd count, whatever the order,
    /// and the mean of the two middle ones of an even count.
    func testTheMedianIsTheMiddleRun() {
        XCTAssertEqual(PerformanceRules.median([5, 1, 4, 2, 3]), 3)
        XCTAssertEqual(PerformanceRules.median([9, 1, 1, 1, 9]), 1, "two slow runs leave the median alone")
        XCTAssertEqual(PerformanceRules.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(PerformanceRules.median([7]), 7)
        XCTAssertNil(PerformanceRules.median([]))
    }

    // MARK: - Verdicts

    /// A number fails only above twice its baseline; exactly twice warns.
    func testOnlyMoreThanTwiceTheBaselineFails() {
        XCTAssertEqual(PerformanceRules.verdict(value: 20.01, baseline: 10), .regressed)
        XCTAssertEqual(PerformanceRules.verdict(value: 20, baseline: 10), .warning)
        XCTAssertEqual(PerformanceRules.verdict(value: 1_000, baseline: 10), .regressed)
    }

    /// A warning starts at exactly 1.5 times the baseline.
    func testAWarningStartsAtOneAndAHalfTimesTheBaseline() {
        XCTAssertEqual(PerformanceRules.verdict(value: 15, baseline: 10), .warning)
        XCTAssertEqual(PerformanceRules.verdict(value: 14.99, baseline: 10), .within)
        XCTAssertEqual(PerformanceRules.verdict(value: 10, baseline: 10), .within)
    }

    /// Half the baseline or less earns a note that new baselines would
    /// tighten the check.
    func testHalfTheBaselineOrLessIsMuchFaster() {
        XCTAssertEqual(PerformanceRules.verdict(value: 5, baseline: 10), .muchFaster)
        XCTAssertEqual(PerformanceRules.verdict(value: 0, baseline: 10), .muchFaster)
        XCTAssertEqual(PerformanceRules.verdict(value: 5.01, baseline: 10), .within)
    }

    // MARK: - When to Measure

    /// The Mac is busy only while its one-minute load average is above its
    /// number of cores, and the reason names both.
    func testTheMacIsBusyAboveOneRunnableThreadPerCore() {
        XCTAssertNil(PerformanceRules.busyReason(loadAverage: 8, cores: 8))
        XCTAssertNil(PerformanceRules.busyReason(loadAverage: 0.4, cores: 8))
        let reason = PerformanceRules.busyReason(loadAverage: 8.5, cores: 8)
        XCTAssertEqual(reason?.contains("8.50"), true, reason ?? "no reason")
        XCTAssertEqual(reason?.contains("8 cores"), true, reason ?? "no reason")
    }

    /// Baselines apply only to the Mac model and build configuration they
    /// were recorded with; the chip, cores, and memory are only described.
    func testBaselinesApplyOnlyToTheirMacModelAndConfiguration() {
        let file = Self.baselineFile(values: [:])
        var sameModel = file.machine
        sameModel.memoryGigabytes = 16
        XCTAssertNil(PerformanceRules.mismatchReason(of: file, machine: sameModel, configuration: file.configuration))

        var otherModel = file.machine
        otherModel.model = "VirtualMac2,1"
        let mismatch = PerformanceRules.mismatchReason(of: file, machine: otherModel, configuration: file.configuration)
        XCTAssertEqual(mismatch?.contains("VirtualMac2,1"), true, mismatch ?? "no reason")
        XCTAssertEqual(mismatch?.contains("make perf-baselines"), true, mismatch ?? "no reason")

        let other = file.configuration == "Debug" ? "Release" : "Debug"
        let otherConfiguration = PerformanceRules.mismatchReason(of: file, machine: file.machine, configuration: other)
        XCTAssertEqual(otherConfiguration?.contains(other), true, otherConfiguration ?? "no reason")
    }

    /// Strict and recording runs are asked for with variables set to
    /// exactly 1; anything else leaves them off.
    func testTheEnvironmentAsksForStrictAndRecordingRunsWithOne() {
        let neither = PerformanceRunSettings(environment: [:])
        XCTAssertFalse(neither.isStrict)
        XCTAssertFalse(neither.isRecording)

        let both = PerformanceRunSettings(environment: [
            PerformanceRunSettings.strictVariable: "1",
            PerformanceRunSettings.recordVariable: "1",
        ])
        XCTAssertTrue(both.isStrict)
        XCTAssertTrue(both.isRecording)

        let other = PerformanceRunSettings(environment: [
            PerformanceRunSettings.strictVariable: "yes",
            PerformanceRunSettings.recordVariable: "0",
        ])
        XCTAssertFalse(other.isStrict)
        XCTAssertFalse(other.isRecording)
    }

    /// This Mac describes itself with a model and at least one core.
    func testThisMacHasAModelAndCores() {
        let machine = MachineIdentity.current
        XCTAssertFalse(machine.model.isEmpty)
        XCTAssertNotEqual(machine.model, "unknown")
        XCTAssertGreaterThan(machine.cores, 0)
        XCTAssertNotNil(MachineLoad.oneMinuteAverage())
    }

    // MARK: - Units

    /// Bytes are recorded whole and everything else to the thousandth, and
    /// each unit is written out in full.
    func testUnitsRoundAndReadInFull() {
        XCTAssertEqual(PerformanceUnit.bytes.rounded(838.6), 839)
        XCTAssertEqual(PerformanceUnit.milliseconds.rounded(12.34567), 12.346)
        XCTAssertEqual(PerformanceUnit.bytes.describe(838), "838 bytes")
        XCTAssertEqual(PerformanceUnit.megabytes.describe(43.5), "43.500 megabytes")
        XCTAssertEqual(PerformanceUnit.microseconds.describe(4.25), "4.250 microseconds")
    }

    // MARK: - Before Measuring

    /// Baselines recorded on another Mac model skip the tests, saying so on
    /// a line `make check` repeats, in a strict run too: there is nothing
    /// to compare with.
    func testBaselinesOfAnotherMacSkipTheTests() async throws {
        let lines = ReportedLines()
        var otherMac = MachineIdentity.current
        otherMac.model = "VirtualMac2,1"
        let run = try makeRun(
            settings: [PerformanceRunSettings.strictVariable: "1"],
            baselines: Self.baselineFile(values: [:], machine: otherMac),
            reportingTo: lines
        )
        do {
            try await run.prepareToMeasure()
            XCTFail("baselines of another Mac did not skip the test")
        } catch is XCTSkip {
            XCTAssertTrue(
                lines.all.contains { $0.hasPrefix("PERFORMANCE SKIPPED: the baselines were recorded on a VirtualMac2,1") },
                lines.all.joined(separator: "\n")
            )
        }
    }

    /// A recording run measures on any Mac: recording is how a Mac gets
    /// baselines of its own.
    func testARecordingRunMeasuresOnAnotherMac() async throws {
        var otherMac = MachineIdentity.current
        otherMac.model = "VirtualMac2,1"
        let run = try makeRun(
            settings: [PerformanceRunSettings.strictVariable: "1", PerformanceRunSettings.recordVariable: "1"],
            baselines: Self.baselineFile(values: [:], machine: otherMac),
            reportingTo: ReportedLines()
        )
        try await run.prepareToMeasure()
    }

    /// Baselines that cannot be read fail the test rather than skip it:
    /// the file is committed, so its loss is a mistake to see.
    func testUnreadableBaselinesFailRatherThanSkip() async throws {
        let location = try makeSandboxDirectory("Performance Missing").appendingPathComponent("baselines.json")
        let run = PerformanceBaselineRun(
            settings: PerformanceRunSettings(environment: [PerformanceRunSettings.strictVariable: "1"]),
            location: location,
            report: ReportedLines().append
        )
        do {
            try await run.prepareToMeasure()
            XCTFail("missing baselines let the test measure")
        } catch is XCTSkip {
            XCTFail("missing baselines skipped the test instead of failing it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("make perf-baselines"), error.localizedDescription)
        }
    }

    // MARK: - Comparing

    /// A number within its baseline passes after a warm-up run and five
    /// counted runs, saying how it compared; the work is not measured again.
    func testANumberWithinItsBaselinePassesAfterFiveRuns() async throws {
        let lines = ReportedLines()
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: lines)
        var samples = 0
        try run.check(.launch) {
            samples += 1
            return 11
        }
        XCTAssertEqual(samples, PerformanceRules.warmUpRuns + PerformanceRules.runs)
        XCTAssertTrue(
            lines.all.contains("PERFORMANCE: launch: 11.000 milliseconds, 1.10 times its baseline of 10.000 milliseconds."),
            lines.all.joined(separator: "\n")
        )
    }

    /// The warm-up run is not counted: however slow it is, the median of
    /// the five runs after it decides.
    func testTheWarmUpRunIsNotCounted() async throws {
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: ReportedLines())
        var samples = 0
        try run.check(.launch) {
            samples += 1
            return samples <= PerformanceRules.warmUpRuns ? 2_500 : 10
        }
        XCTAssertEqual(samples, PerformanceRules.warmUpRuns + PerformanceRules.runs, "a slow warm-up was measured again")
    }

    /// A number at 1.5 times its baseline passes with a warning line, which
    /// `make check` repeats.
    func testANumberAtOneAndAHalfTimesItsBaselineWarns() async throws {
        let lines = ReportedLines()
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: lines)
        try run.check(.launch) { 16 }
        XCTAssertTrue(
            lines.all.contains(
                "PERFORMANCE WARNING: launch: 16.000 milliseconds, 1.60 times its baseline of 10.000 milliseconds; "
                    + "the test fails above twice its baseline."
            ),
            lines.all.joined(separator: "\n")
        )
    }

    /// A number at half its baseline or less passes with a note that new
    /// baselines would tighten the check.
    func testANumberAtHalfItsBaselineOrLessEarnsANote() async throws {
        let lines = ReportedLines()
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: lines)
        try run.check(.launch) { 4 }
        XCTAssertTrue(
            lines.all.contains(
                "PERFORMANCE NOTE: launch: 4.000 milliseconds, 0.40 times its baseline of 10.000 milliseconds; "
                    + "make perf-baselines would tighten the check."
            ),
            lines.all.joined(separator: "\n")
        )
    }

    /// A number more than twice its baseline is measured five times more,
    /// and the lower median counts: a passing second look passes.
    func testARegressionIsMeasuredAgainAndTheLowerMedianCounts() async throws {
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: ReportedLines())
        var samples = 0
        try run.check(.launch) {
            samples += 1
            return samples <= PerformanceRules.warmUpRuns + PerformanceRules.runs ? 25 : 9
        }
        XCTAssertEqual(
            samples,
            PerformanceRules.warmUpRuns + 2 * PerformanceRules.runs,
            "the regression was not measured again"
        )
    }

    /// A number still more than twice its baseline after the second look
    /// fails its test.
    func testAConfirmedRegressionFails() async throws {
        let run = try await comparingRun(baselines: [PerformanceMeasure.launch.name: 10], reportingTo: ReportedLines())
        var samples = 0
        XCTExpectFailure("25 is more than twice the baseline of 10") {
            try? run.check(.launch) {
                samples += 1
                return 25
            }
        }
        XCTAssertEqual(samples, PerformanceRules.warmUpRuns + 2 * PerformanceRules.runs)
    }

    /// A measurement whose baseline is missing fails, asking for new
    /// baselines.
    func testAMissingBaselineFails() async throws {
        let run = try await comparingRun(baselines: [:], reportingTo: ReportedLines())
        XCTExpectFailure("launch has no baseline") {
            try? run.check(.launch) { 1 }
        }
    }

    /// A measurement not listed in `PerformanceMeasure.all` is refused
    /// before it is measured, since a recording run would never complete.
    func testAMeasurementMustBeCatalogued() async throws {
        let run = try await comparingRun(baselines: [:], reportingTo: ReportedLines())
        let stray = PerformanceMeasure(name: "stray", summary: "Nothing.", unit: .milliseconds)
        var samples = 0
        XCTAssertThrowsError(try run.check(stray) {
            samples += 1
            return 1
        })
        XCTAssertEqual(samples, 0)
    }

    // MARK: - Recording

    /// A recording run writes its baselines only once every measurement has
    /// its number, with this Mac, the configuration, the date, and each
    /// number rounded in its unit, and says what it wrote.
    func testARecordingRunWritesOnceEveryMeasurementHasItsNumber() throws {
        let lines = ReportedLines()
        let location = try makeSandboxDirectory("Performance Recording").appendingPathComponent("baselines.json")
        let run = PerformanceBaselineRun(
            settings: PerformanceRunSettings(environment: [PerformanceRunSettings.recordVariable: "1"]),
            location: location,
            report: lines.append
        )
        for (number, measure) in PerformanceMeasure.all.enumerated() {
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.path), "written before \(measure.name)")
            try run.check(measure) { Double(number + 1) + 0.12345 }
        }

        let written = try PerformanceBaselineFile.read(from: location)
        XCTAssertEqual(written.machine, .current)
        XCTAssertEqual(written.configuration, performanceBuildConfiguration)
        XCTAssertEqual(written.runsPerMeasurement, PerformanceRules.runs)
        XCTAssertEqual(written.recorded.count, 10, "a YYYY-MM-DD date")
        XCTAssertEqual(Set(written.baselines.keys), Set(PerformanceMeasure.all.map(\.name)))
        for (number, measure) in PerformanceMeasure.all.enumerated() {
            let baseline = try XCTUnwrap(written.baselines[measure.name])
            XCTAssertEqual(baseline.unit, measure.unit, measure.name)
            XCTAssertEqual(baseline.summary, measure.summary, measure.name)
            XCTAssertEqual(baseline.value, measure.unit.rounded(Double(number + 1) + 0.12345), measure.name)
        }
        // Written as pretty-printed JSON with sorted keys, ending a line.
        let text = String(decoding: try Data(contentsOf: location), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("}\n"))
        let about = try XCTUnwrap(text.range(of: "\"about\""))
        let baselines = try XCTUnwrap(text.range(of: "\"baselines\""))
        XCTAssertLessThan(about.lowerBound, baselines.lowerBound, "keys are sorted")
        // One line for each new number, then where they went.
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("PERFORMANCE RECORDED: ") }.count, PerformanceMeasure.all.count)
        XCTAssertEqual(lines.all.last?.hasPrefix("PERFORMANCE BASELINES WRITTEN: \(location.path)"), true)
    }

    /// A recording run refuses a number of nothing.
    func testARecordingRunRefusesNothing() throws {
        let location = try makeSandboxDirectory("Performance Recording Zero").appendingPathComponent("baselines.json")
        let run = PerformanceBaselineRun(
            settings: PerformanceRunSettings(environment: [PerformanceRunSettings.recordVariable: "1"]),
            location: location,
            report: ReportedLines().append
        )
        XCTExpectFailure("a measurement of zero cannot be a baseline") {
            try? run.check(.checkpointBytes) { 0 }
        }
    }

    /// An old and a new baseline read as a change, and a new one as new.
    func testRecordingDescribesEachChange() {
        let old = PerformanceBaselineFile.Baseline(value: 10, unit: .milliseconds, summary: "")
        let new = PerformanceBaselineFile.Baseline(value: 12.5, unit: .milliseconds, summary: "")
        XCTAssertEqual(
            PerformanceBaselineRun.change(from: old, to: new),
            "from 10.000 milliseconds to 12.500 milliseconds, 1.25 times the old baseline"
        )
        XCTAssertEqual(PerformanceBaselineRun.change(from: nil, to: new), "12.500 milliseconds, new")
    }

    // MARK: - The Catalogue

    /// Every measurement has a name of its own.
    func testEveryMeasurementHasANameOfItsOwn() {
        let names = PerformanceMeasure.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two measurements share a name")
    }

    // MARK: - The Committed Files

    /// The developer's rules fixture holds the 16 rules, every one enabled
    /// and with an ID of its own, and they change prose as the developer's
    /// rules do: titles spelled out, footnote marks dropped, em dashes
    /// spaced, and an OCR'd bar read as "I".
    func testTheDevelopersRulesFixtureHoldsSixteenRules() throws {
        let rules = try PerformanceFixtures.developerSubstitutionRules()
        XCTAssertEqual(rules.count, 16)
        XCTAssertTrue(rules.allSatisfy(\.isEnabled))
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count)
        XCTAssertEqual(rules.last?.name, "| OCR error to I")

        let transformed = TextSubstitutionService(rules: rules).transform("Mr. Varga met Dr. Okafor — see [12] | then left.")
        XCTAssertEqual(transformed.modifiedText, "Mister Varga met Doctor Okafor  —  see  I then left.")
    }

    /// performance-baselines.json holds a baseline above zero, in the right
    /// unit, for exactly the measurements the tests make, so a measurement
    /// added without recording its baseline is noticed on every Mac.
    func testTheCommittedBaselinesCoverEveryMeasurement() throws {
        let file = try PerformanceBaselineFile.read()
        XCTAssertEqual(Set(file.baselines.keys), Set(PerformanceMeasure.all.map(\.name)))
        for measure in PerformanceMeasure.all {
            let baseline = try XCTUnwrap(file.baselines[measure.name], measure.name)
            XCTAssertEqual(baseline.unit, measure.unit, measure.name)
            XCTAssertGreaterThan(baseline.value, 0, measure.name)
        }
        XCTAssertEqual(file.runsPerMeasurement, PerformanceRules.runs)
        XCTAssertFalse(file.machine.model.isEmpty)
    }

    // MARK: - Support

    /// A run with the settings `environment` asks for, against `baselines`
    /// written in a sandbox folder this test removes, keeping its lines in
    /// `lines` rather than the test log, where its pretend numbers would
    /// read as measurements.
    private func makeRun(
        settings environment: [String: String],
        baselines: PerformanceBaselineFile,
        reportingTo lines: ReportedLines
    ) throws -> PerformanceBaselineRun {
        let location = try makeSandboxDirectory("Performance Rules").appendingPathComponent("baselines.json")
        try baselines.encoded().write(to: location)
        return PerformanceBaselineRun(
            settings: PerformanceRunSettings(environment: environment),
            location: location,
            report: lines.append
        )
    }

    /// A strict comparing run, ready to measure, against baselines of
    /// `values` (milliseconds, by measurement name) recorded on this Mac in
    /// this configuration. Strict, so a busy Mac never skips these tests.
    private func comparingRun(
        baselines values: [String: Double],
        reportingTo lines: ReportedLines
    ) async throws -> PerformanceBaselineRun {
        let run = try makeRun(
            settings: [PerformanceRunSettings.strictVariable: "1"],
            baselines: Self.baselineFile(values: values),
            reportingTo: lines
        )
        try await run.prepareToMeasure()
        return run
    }

    /// A baselines file recorded on `machine` in this configuration, holding
    /// `values` as baselines in milliseconds.
    private static func baselineFile(
        values: [String: Double],
        machine: MachineIdentity = .current
    ) -> PerformanceBaselineFile {
        PerformanceBaselineFile(
            about: PerformanceBaselineFile.aboutText,
            machine: machine,
            configuration: performanceBuildConfiguration,
            recorded: "2026-10-03",
            runsPerMeasurement: PerformanceRules.runs,
            baselines: values.mapValues { .init(value: $0, unit: .milliseconds, summary: "A test baseline.") }
        )
    }
}

/// The lines a run reported, kept in order for a test to read.
private final class ReportedLines {
    /// Every line, in the order reported.
    private(set) var all: [String] = []

    /// Keeps `line`.
    func append(_ line: String) {
        all.append(line)
    }
}
