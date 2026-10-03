import XCTest
import ZIPFoundation
@testable import TextMouth

/// An import's archives are measured from their central directories before
/// anything is extracted, and held to documented limits on their declared
/// total, their entries, and the disk's free space; what extraction then
/// writes is charged against what they declared (TODO I05). Tests use tiny
/// limits and a free-space figure of their own.
final class ArchiveBudgetTests: XCTestCase {

    // MARK: - Limits

    /// The documented limits: 8 GB for archives holding audio or other
    /// archives, 2 GB for the rest, 10,000 entries, one level of archives
    /// inside the archive, and 1 GB kept free.
    func testStandardLimitsAreTheDocumentedOnes() {
        let limits = ArchiveLimits.standard

        XCTAssertEqual(limits.audioArchiveExpansion, 8_000_000_000)
        XCTAssertEqual(limits.otherArchiveExpansion, 2_000_000_000)
        XCTAssertEqual(limits.maximumEntries, 10_000)
        XCTAssertEqual(limits.maximumNestingDepth, 1)
        XCTAssertEqual(limits.freeSpaceReserve, 1_000_000_000)
        XCTAssertEqual(ArchiveFigures.size(limits.audioArchiveExpansion), ArchiveFigures.size(8_000_000_000))
    }

    /// Free space is reported for a location that does not exist yet, from
    /// the volume of its nearest existing folder.
    func testFreeSpaceIsReportedForALocationNotYetMade() throws {
        let existing = try makeSandboxDirectory("archive-budget-free-space")
        let notYetMade = existing.appendingPathComponent("extract/archive/inner", isDirectory: true)

        let free = try XCTUnwrap(ArchiveLimits.volumeFreeSpace(at: notYetMade))

        XCTAssertGreaterThan(free, 0)
        XCTAssertNotNil(ArchiveLimits.standard.freeSpace(notYetMade))
    }

    // MARK: - Inspection

    /// Inspection counts every entry, folders included, and adds up the
    /// sizes they declare, without extracting anything.
    func testInspectionCountsEntriesAndDeclaredSizes() throws {
        let archive = try openArchive([
            .folder("Ferry/"),
            TestZIPEntry("Ferry/timetable.txt", Data(count: 100)),
            TestZIPEntry("Ferry/fares.txt", Data(count: 200)),
            TestZIPEntry("notes.txt", Data(count: 300))
        ])

        XCTAssertEqual(
            ArchiveInspection(of: archive),
            ArchiveInspection(entryCount: 4, declaredSize: 600, holdsAudioOrArchives: false)
        )
    }

    /// An archive holding an audio file, or another archive, which may hold
    /// audio, is recognized as such, whatever the case of its extension.
    func testInspectionNoticesAudioAndArchivesInside() throws {
        let cases: [(entries: [String], holdsAudioOrArchives: Bool)] = [
            (["notes.txt", "Tide Tables/part1.MP3"], true),
            (["notes.txt", "Collection.ZIP"], true),
            (["notes.txt", "chapter.xhtml"], false)
        ]
        for (names, expected) in cases {
            let archive = try openArchive(names.map { TestZIPEntry($0, Data(count: 10)) })
            XCTAssertEqual(ArchiveInspection(of: archive).holdsAudioOrArchives, expected, "\(names)")
        }
    }

    // MARK: - Admission

    /// An archive within every limit is admitted, and its figures counted.
    func testArchiveWithinEveryLimitIsAdmitted() throws {
        let budget = ArchiveBudget(limits: Self.limits())

        try budget.admit(Self.inspection(entries: 3, size: 900), extractingInto: Self.destination)

        XCTAssertEqual(budget.entryTotal, 3)
        XCTAssertEqual(budget.declaredTotal, 900)
        XCTAssertEqual(budget.admittedArchives, 1)
    }

    /// An archive declaring more than the limit is refused, the message
    /// stating its total and the limit.
    func testDeclaredTotalPastTheLimitIsRefusedWithTheFigures() {
        let budget = ArchiveBudget(limits: Self.limits(other: 1_000))

        XCTAssertThrowsError(try budget.admit(Self.inspection(size: 1_500), extractingInto: Self.destination)) { error in
            XCTAssertEqual(
                error as? ArchiveBudgetError,
                .expandsPastLimit(declared: 1_500, limit: 1_000, holdsAudioOrArchives: false, withNestedArchives: false)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The archive expands to \(ArchiveFigures.size(1_500)), more than the "
                    + "\(ArchiveFigures.size(1_000)) TextMouth extracts from archives without audio."
            )
        }
    }

    /// An archive holding audio or archives is held to the larger limit.
    func testArchiveHoldingAudioIsHeldToTheAudioLimit() throws {
        let limits = Self.limits(audio: 2_000, other: 1_000)

        try ArchiveBudget(limits: limits).admit(
            Self.inspection(size: 1_500, holdsAudioOrArchives: true),
            extractingInto: Self.destination
        )
        XCTAssertThrowsError(
            try ArchiveBudget(limits: limits).admit(
                Self.inspection(size: 2_500, holdsAudioOrArchives: true),
                extractingInto: Self.destination
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The archive expands to \(ArchiveFigures.size(2_500)), more than the "
                    + "\(ArchiveFigures.size(2_000)) TextMouth extracts from archives holding audio or other archives."
            )
        }
    }

    /// An archive holding more entries than the limit is refused, the
    /// message stating its count and the limit.
    func testEntryCountPastTheLimitIsRefusedWithTheFigures() {
        let budget = ArchiveBudget(limits: Self.limits(entries: 3))

        XCTAssertThrowsError(try budget.admit(Self.inspection(entries: 4), extractingInto: Self.destination)) { error in
            XCTAssertEqual(error as? ArchiveBudgetError, .tooManyEntries(count: 4, limit: 3, withNestedArchives: false))
            XCTAssertEqual(
                error.localizedDescription,
                "The archive holds 4 files and folders, more than the 3 TextMouth extracts in one import."
            )
        }
    }

    /// Archives found inside the archive count toward the same totals, and
    /// a refusal then says so.
    func testArchivesInsideCountTowardTheSameTotals() throws {
        let budget = ArchiveBudget(limits: Self.limits(other: 1_000, entries: 5))
        try budget.admit(Self.inspection(entries: 2, size: 600), extractingInto: Self.destination)

        XCTAssertThrowsError(
            try budget.admit(Self.inspection(entries: 2, size: 600), extractingInto: Self.destination, nestedArchive: "Inner.zip")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Together with the archives inside it, the archive expands to \(ArchiveFigures.size(1_200)), "
                    + "more than the \(ArchiveFigures.size(1_000)) TextMouth extracts from archives without audio."
            )
        }
        XCTAssertThrowsError(
            try budget.admit(Self.inspection(entries: 4, size: 10), extractingInto: Self.destination, nestedArchive: "Inner.zip")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Together with the archives inside it, the archive holds 6 files and folders, "
                    + "more than the 5 TextMouth extracts in one import."
            )
        }
    }

    /// An archive inside that holds audio or archives raises the import's
    /// limit to the audio one.
    func testArchiveInsideHoldingAudioRaisesTheLimit() throws {
        let budget = ArchiveBudget(limits: Self.limits(audio: 2_000, other: 1_000))
        try budget.admit(Self.inspection(size: 600), extractingInto: Self.destination)

        try budget.admit(
            Self.inspection(size: 900, holdsAudioOrArchives: true),
            extractingInto: Self.destination,
            nestedArchive: "Lectures.zip"
        )

        XCTAssertEqual(budget.declaredTotal, 1_500)
        XCTAssertTrue(budget.holdsAudioOrArchives)
    }

    /// An archive that would leave less than the reserve free on the disk it
    /// extracts to is refused, the message stating what it needs, what is
    /// free, and the reserve; the disk is asked about the destination.
    func testShortageOfFreeSpaceIsRefusedWithTheFigures() {
        let destination = Self.destination
        let budget = ArchiveBudget(limits: Self.limits(reserve: 1_000, freeSpace: { $0 == destination ? 1_500 : nil }))

        XCTAssertThrowsError(try budget.admit(Self.inspection(size: 600), extractingInto: destination)) { error in
            XCTAssertEqual(
                error as? ArchiveBudgetError,
                .notEnoughSpace(nestedArchive: nil, needed: 600, available: 1_500, reserve: 1_000)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The archive expands to \(ArchiveFigures.size(600)), but the disk holding the TextMouth library "
                    + "has only \(ArchiveFigures.size(1_500)) free, and TextMouth keeps "
                    + "\(ArchiveFigures.size(1_000)) of it free. Free up space, then import it again."
            )
        }
        XCTAssertNoThrow(try budget.admit(Self.inspection(size: 500), extractingInto: destination))
    }

    /// A shortage met by an archive found inside the archive names it.
    func testShortageOfFreeSpaceForAnArchiveInsideNamesIt() throws {
        let budget = ArchiveBudget(limits: Self.limits(reserve: 100, freeSpace: { _ in 500 }))
        try budget.admit(Self.inspection(size: 300), extractingInto: Self.destination)

        XCTAssertThrowsError(
            try budget.admit(Self.inspection(size: 450), extractingInto: Self.destination, nestedArchive: "Inner.zip")
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.hasPrefix("The archive “Inner.zip” inside it expands to "),
                error.localizedDescription
            )
        }
    }

    /// When the system cannot say how much space is free, nothing is refused
    /// for lack of it.
    func testUnknownFreeSpaceRefusesNothing() {
        let budget = ArchiveBudget(limits: Self.limits(freeSpace: { _ in nil }))

        XCTAssertNoThrow(try budget.admit(Self.inspection(size: 900), extractingInto: Self.destination))
    }

    /// A refused archive changes nothing: a smaller one is still admitted
    /// against the same totals.
    func testRefusalLeavesTheBudgetUnchanged() throws {
        let budget = ArchiveBudget(limits: Self.limits(other: 1_000))
        try budget.admit(Self.inspection(entries: 1, size: 400), extractingInto: Self.destination)

        XCTAssertThrowsError(try budget.admit(Self.inspection(entries: 1, size: 700), extractingInto: Self.destination))
        XCTAssertEqual(budget.declaredTotal, 400)
        XCTAssertEqual(budget.entryTotal, 1)

        XCTAssertNoThrow(try budget.admit(Self.inspection(entries: 1, size: 600), extractingInto: Self.destination))
        XCTAssertEqual(budget.declaredTotal, 1_000)
    }

    // MARK: - Charging

    /// Extraction may write what the admitted archives declare and no more:
    /// the first byte past it stops extraction, and the refusal is kept.
    func testChargesPastTheDeclaredTotalAreRefused() throws {
        let budget = ArchiveBudget(limits: Self.limits())
        try budget.admit(Self.inspection(size: 100), extractingInto: Self.destination)

        try budget.charge(60)
        try budget.charge(40)
        XCTAssertNil(budget.violation)
        XCTAssertThrowsError(try budget.charge(1)) { error in
            XCTAssertEqual(error as? ArchiveBudgetError, .extractedPastDeclaredSize(declared: 100))
            XCTAssertEqual(
                error.localizedDescription,
                "The archive holds more than the \(ArchiveFigures.size(100)) it declares, so extraction stopped. "
                    + "Get a fresh copy of the archive, then import it again."
            )
        }
        XCTAssertEqual(budget.violation as? ArchiveBudgetError, .extractedPastDeclaredSize(declared: 100))
    }

    /// The first refusal recorded is the one kept.
    func testFirstRecordedViolationIsKept() {
        let budget = ArchiveBudget(limits: Self.limits())

        budget.record(ArchiveEntryOverflow.pastDeclaredSize(path: "first.wav", declared: 1))
        budget.record(ArchiveEntryOverflow.pastDeclaredSize(path: "second.wav", declared: 1))

        XCTAssertEqual(budget.violation as? ArchiveEntryOverflow, .pastDeclaredSize(path: "first.wav", declared: 1))
    }

    /// A budget made without limits takes the current ones, which a test
    /// can bind.
    func testBudgetTakesTheCurrentLimits() {
        let limits = Self.limits(entries: 7)

        let budget = ArchiveLimits.$current.withValue(limits) { ArchiveBudget() }

        XCTAssertEqual(budget.limits.maximumEntries, 7)
        XCTAssertEqual(ArchiveBudget().limits.maximumEntries, ArchiveLimits.standard.maximumEntries)
    }

    // MARK: - Fixtures

    /// Where admitted archives are said to extract to.
    private static let destination = URL(fileURLWithPath: "/private/tmp/archive-budget-tests", isDirectory: true)

    /// Small limits for a test: `audio` and `other` expansion limits, an
    /// entry limit, one level of nesting, a reserve, and the free space the
    /// disk reports, plenty unless a test says otherwise.
    static func limits(
        audio: Int64 = 10_000,
        other: Int64 = 5_000,
        entries: Int = 100,
        depth: Int = 1,
        reserve: Int64 = 0,
        freeSpace: @escaping @Sendable (URL) -> Int64? = { _ in 1_000_000 }
    ) -> ArchiveLimits {
        ArchiveLimits(
            audioArchiveExpansion: audio,
            otherArchiveExpansion: other,
            maximumEntries: entries,
            maximumNestingDepth: depth,
            freeSpaceReserve: reserve,
            freeSpace: freeSpace
        )
    }

    /// An archive's figures as inspection would report them.
    private static func inspection(entries: Int = 1, size: Int64 = 10, holdsAudioOrArchives: Bool = false) -> ArchiveInspection {
        ArchiveInspection(entryCount: entries, declaredSize: size, holdsAudioOrArchives: holdsAudioOrArchives)
    }

    /// An archive holding `entries` in order, opened for reading. Its file
    /// is removed when the test ends.
    private func openArchive(_ entries: [TestZIPEntry]) throws -> Archive {
        let url = try makeTemporaryZip(prefix: "ArchiveBudgetTests", orderedEntries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Archive(url: url, accessMode: .read)
    }
}
