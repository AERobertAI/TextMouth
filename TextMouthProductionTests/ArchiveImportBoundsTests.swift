import XCTest
import ZIPFoundation
@testable import TextMouth

/// A ZIP batch extracts its archive, and the archives found inside it, within
/// one budget (TODO I05). An archive past the limits is refused before
/// anything of it is written, one whose sizes lie is stopped at its first
/// excess byte, and either way nothing is imported, the source is untouched,
/// and nothing is left extracted. An archive inside that cannot be searched,
/// or lies deeper than the batch unpacks, is reported, so the original is
/// kept. Each test imports into a library folder of its own, removed when it
/// ends, with small limits bound where it needs them.
final class ArchiveImportBoundsTests: XCTestCase {
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's archives are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        folderPath = "Archive Bounds \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("archive-bounds-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - Within the Budget

    /// A batch within the standard budget imports every book as before,
    /// those in the archive inside it included, reports nothing, and leaves
    /// nothing extracted.
    func testBatchWithinItsBudgetImportsEveryBook() throws {
        let inner = try makeArchive("Inner", [TestZIPEntry("Tides.txt", Self.notes("tides"))])
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Shelf/Knots.txt", Self.notes("knots")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(Set(result.books.map(\.title)), ["Rope Splicing", "Knots", "Tides"])
        XCTAssertEqual(result.failures, [])
        XCTAssertNil(result.failureSummary)
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    // MARK: - Refused Before Extraction

    /// An archive declaring more than the limit is refused whole, the reason
    /// stating its total and the limit.
    func testDeclaredTotalPastTheLimitRefusesTheBatch() throws {
        let archive = try makeArchive("Tide Tables", [
            TestZIPEntry("January.txt", Data(count: 800)),
            TestZIPEntry("February.txt", Data(count: 800))
        ])

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(other: 1_000),
            because: "The archive expands to \(ArchiveFigures.size(1_600)), more than the "
                + "\(ArchiveFigures.size(1_000)) TextMouth extracts from archives without audio."
        )
    }

    /// An archive holding more entries than the limit is refused whole, the
    /// reason stating its count and the limit.
    func testEntryCountPastTheLimitRefusesTheBatch() throws {
        let archive = try makeArchive("Pamphlets", (1...3).map { TestZIPEntry("Pamphlet \($0).txt", Self.notes("pamphlet \($0)")) })

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(entries: 2),
            because: "The archive holds 3 files and folders, more than the 2 TextMouth extracts in one import."
        )
    }

    /// An archive that would leave less than the reserve free on the disk
    /// holding the library is refused whole, the reason stating what it
    /// needs, what is free, and the reserve. The disk asked is the one the
    /// archive extracts to, in the data directory.
    func testShortageOfFreeSpaceRefusesTheBatch() throws {
        let archive = try makeArchive("Harbor Charts", [TestZIPEntry("Charts.txt", Data(count: 600))])
        let extractionFolder = ArchiveExtractionDirectory.defaultParent.path

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(reserve: 1_000, freeSpace: { $0.path.hasPrefix(extractionFolder) ? 1_500 : nil }),
            because: "The archive expands to \(ArchiveFigures.size(600)), but the disk holding the TextMouth library "
                + "has only \(ArchiveFigures.size(1_500)) free, and TextMouth keeps \(ArchiveFigures.size(1_000)) "
                + "of it free. Free up space, then import it again."
        )
    }

    /// Archives inside count toward the batch's totals: one that takes the
    /// total past the limit refuses the whole batch, before any book is
    /// imported.
    func testArchivesInsideCountTowardTheBatchBudget() throws {
        let inner = try makeArchive("Inner", [
            TestZIPEntry("Tides.txt", Data(count: 800)),
            TestZIPEntry("Currents.txt", Data(count: 800))
        ])
        let innerBytes = try Data(contentsOf: inner)
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Data(count: 300)),
            TestZIPEntry("Collection.zip", innerBytes)
        ])
        // The archive holds another, so the limit for archives holding
        // archives applies; it fits on its own, but not with what is inside.
        let total = Int64(300 + innerBytes.count + 1_600)
        let limit = total - 1

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(audio: limit),
            because: "Together with the archives inside it, the archive expands to \(ArchiveFigures.size(total)), "
                + "more than the \(ArchiveFigures.size(limit)) TextMouth extracts from archives holding audio or other archives."
        )
    }

    // MARK: - Stopped During Extraction

    /// An archive whose recorded size lies is stopped at the first excess
    /// chunk, naming the file, and the whole batch fails.
    func testLyingArchiveStopsTheBatch() throws {
        let archive = try makeArchive("Ferry Notes", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Flood.txt", Data(repeating: 0x61, count: 200_000))
        ], compression: .deflate)
        try setRecordedSize(of: "Flood.txt", in: archive, to: 10)

        assertBatchFails(
            archive,
            because: "The file “Flood.txt” in this archive is damaged or incomplete: it holds more than the "
                + "\(ArchiveFigures.size(10)) the archive records for it. Get a fresh copy of the archive, then import it again."
        )
    }

    /// An archive with a file whose path climbs out of it is refused whole,
    /// and nothing appears outside its extraction.
    func testArchiveLeadingOutsideIsRefusedAndNothingEscapes() throws {
        let escapeName = "escape-\(UUID().uuidString).txt"
        let archive = try makeArchive("Mixed Bag", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("../\(escapeName)", Self.notes("escape"))
        ])

        assertBatchFails(
            archive,
            because: "The archive holds a file whose path leads outside it, which is never extracted."
        )
        let extractionFolder = ArchiveExtractionDirectory.defaultParent
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractionFolder.appendingPathComponent(escapeName).path))
    }

    // MARK: - Archives Inside That Cannot Be Searched

    /// An archive more than one level inside is reported, not searched, so
    /// its books are never passed over in silence; the books above it import.
    func testArchivesDeeperThanTheNestingLimitAreReportedNotSearched() throws {
        let deepest = try makeArchive("Deepest", [TestZIPEntry("Currents.txt", Self.notes("currents"))])
        let middle = try makeArchive("Middle", [
            TestZIPEntry("Tides.txt", Self.notes("tides")),
            TestZIPEntry("Level Two.zip", try Data(contentsOf: deepest))
        ])
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Level One.zip", try Data(contentsOf: middle))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(Set(result.books.map(\.title)), ["Rope Splicing", "Tides"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Level Two.zip",
            message: "Not extracted: TextMouth extracts archives within an archive only 1 level deep."
        )])
        XCTAssertTrue(
            result.failureSummary?.contains("Level Two.zip: Not extracted: ") == true,
            result.failureSummary ?? "no summary"
        )
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    /// A damaged archive inside is reported by name while the other books
    /// import, where it was once passed over in silence.
    func testDamagedArchiveInsideIsReportedWhileTheOthersImport() throws {
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Torn Download.zip", Data("not a ZIP archive".utf8))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(result.books.map(\.title), ["Rope Splicing"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Torn Download.zip",
            message: "Extracting the archive failed: The archive is damaged, incomplete, or not a ZIP archive."
        )])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    /// An archive inside whose recorded size lies is stopped and reported by
    /// name, naming its file, while the other books import.
    func testLyingArchiveInsideIsReportedWhileTheOthersImport() throws {
        let inner = try makeArchive("Inner", [TestZIPEntry("Flood.txt", Data(repeating: 0x61, count: 200_000))], compression: .deflate)
        try setRecordedSize(of: "Flood.txt", in: inner, to: 10)
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(result.books.map(\.title), ["Rope Splicing"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Collection.zip",
            message: "Extracting the archive failed: The file “Flood.txt” in this archive is damaged or incomplete: "
                + "it holds more than the \(ArchiveFigures.size(10)) the archive records for it. "
                + "Get a fresh copy of the archive, then import it again."
        )])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    // MARK: - Fixtures

    /// A short note about `subject`, readable as a plain-text book.
    private static func notes(_ subject: String) -> Data {
        Data("Notes on \(subject): keep the line dry and coiled after use.".utf8)
    }

    /// An archive named `name`.zip holding `entries` in order, in this
    /// test's sources folder.
    private func makeArchive(_ name: String, _ entries: [TestZIPEntry], compression: CompressionMethod = .none) throws -> URL {
        let made = try makeTemporaryZip(prefix: "ArchiveImportBounds", orderedEntries: entries, compressionMethod: compression)
        let archive = sources.appendingPathComponent("\(name).zip")
        try FileManager.default.moveItem(at: made, to: archive)
        return archive
    }

    /// Imports the batch `archive` into this test's folder, with `limits`
    /// bound when given.
    private func importBatch(_ archive: URL, limits: ArchiveLimits? = nil) throws -> ZipImportResult {
        guard let limits else {
            return try FileImportService.importZip(from: archive, toFolder: folderPath)
        }
        return try ArchiveLimits.$current.withValue(limits) {
            try FileImportService.importZip(from: archive, toFolder: folderPath)
        }
    }

    /// Imports the batch `archive` and asserts that it fails while extracting
    /// because of `problem`: the failure names the archive and the step, the
    /// debug log records it once, nothing is left in the folder or extracted,
    /// and the archive keeps its bytes.
    @discardableResult
    private func assertBatchFails(
        _ archive: URL,
        limits: ArchiveLimits? = nil,
        because problem: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ImportFailure? {
        let bytes = try? Data(contentsOf: archive)
        let reason = "Extracting the archive failed: \(problem)"
        let logLine = "IMPORT_FAILED: \(archive.lastPathComponent): \(reason)"
        let logged = debugLogLines(containing: logLine).count
        var failure: ImportFailure?

        XCTAssertThrowsError(try importBatch(archive, limits: limits), file: file, line: line) { error in
            failure = error as? ImportFailure
        }

        XCTAssertEqual(failure?.fileName, archive.lastPathComponent, file: file, line: line)
        XCTAssertEqual(failure?.step, .extractingArchive, file: file, line: line)
        XCTAssertEqual(failure?.reason, reason, file: file, line: line)
        XCTAssertEqual(debugLogLines(containing: logLine).count, logged + 1, file: file, line: line)
        XCTAssertEqual((try? folderEntries()) ?? [], [], "left in the library", file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: archive), bytes, "the source must be untouched", file: file, line: line)
        XCTAssertEqual(leftoverExtractionDirectories(), [], "left extracted", file: file, line: line)
        return failure
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// The extraction directories this process has in the data directory:
    /// none once every batch has ended.
    private func leftoverExtractionDirectories() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ArchiveExtractionDirectory.defaultParent.path)) ?? []
        return names.filter { ArchiveExtractionDirectory.processIdentifier(inName: $0) == getpid() }
    }
}
