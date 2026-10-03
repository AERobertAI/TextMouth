import XCTest
import ZIPFoundation
@testable import TextMouth

/// Imports extract archives entry by entry through `ArchiveExtractor`, in
/// place of ZIPFoundation's `unzipItem` (TODO I05): every path must lead
/// inside the destination, every file is held to its recorded size and
/// checksum, a cancellation stops it between entries and between chunks,
/// and extraction directories carry recognizable names that a sweep at
/// startup clears when no import is using them. The ZIP-slip probes record
/// what the pinned ZIPFoundation itself does, rather than assuming it.
final class ArchiveExtractionTests: XCTestCase {
    /// This test's own folder in the sandbox, removed when it ends.
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = try makeSandboxDirectory("archive-extraction")
    }

    // MARK: - Extracting

    /// An honest archive extracts whole: folders, files inside folders, and
    /// compressed files, every byte charged to the budget.
    func testHonestArchiveExtractsEveryEntry() throws {
        let fares = String(repeating: "Half fare on winter crossings. ", count: 500)
        let archive = try makeArchive([
            .folder("Ferry/"),
            TestZIPEntry("Ferry/timetable.txt", Data("Departs at nine.".utf8)),
            TestZIPEntry("Ferry/Fares/winter.txt", Data(fares.utf8)),
            TestZIPEntry("notes.txt", Data("Bring a coat.".utf8))
        ], compression: .deflate)
        let budget = Self.budget()

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: budget)

        XCTAssertEqual(try text(at: "Ferry/timetable.txt"), "Departs at nine.")
        XCTAssertEqual(try text(at: "Ferry/Fares/winter.txt"), fares)
        XCTAssertEqual(try text(at: "notes.txt"), "Bring a coat.")
        XCTAssertEqual(budget.extractedTotal, budget.declaredTotal)
        XCTAssertEqual(budget.admittedArchives, 1)
    }

    /// Progress is told the entries done of the total, from none to all.
    func testProgressIsToldEntriesDoneOfTheTotal() throws {
        let archive = try makeArchive((1...4).map { TestZIPEntry("page\($0).txt", Data("Page \($0)".utf8)) })
        var reports: [[Int]] = []

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(), progress: { done, total in
            reports.append([done, total])
        })

        XCTAssertEqual(reports, [[0, 4], [1, 4], [2, 4], [3, 4], [4, 4]])
    }

    /// A large archive tells its progress at most once per percent, from
    /// none to all, so the main thread is not flooded.
    func testProgressOfALargeArchiveIsToldAtMostOncePerPercent() throws {
        let archive = try makeArchive((1...500).map { TestZIPEntry("slip\($0).txt", Data("x".utf8)) })
        var reports: [[Int]] = []

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(), progress: { done, total in
            reports.append([done, total])
        })

        XCTAssertEqual(reports.first, [0, 500])
        XCTAssertEqual(reports.last, [500, 500])
        XCTAssertLessThanOrEqual(reports.count, 101)
    }

    /// An archive is admitted to its budget before anything is written: one
    /// past the limit leaves the destination uncreated.
    func testRefusedArchiveWritesNothing() throws {
        let archive = try makeArchive([TestZIPEntry("notes.txt", Data(count: 2_000))])

        XCTAssertThrowsError(
            try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(other: 1_000))
        ) { error in
            XCTAssertEqual(
                error as? ArchiveBudgetError,
                .expandsPastLimit(declared: 2_000, limit: 1_000, holdsAudioOrArchives: false, withNestedArchives: false)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// An archive whose recorded size lies, tiny on record but large once
    /// inflated, stops at the first excess chunk: nothing past the recorded
    /// size is written or charged, and the file is named.
    func testLyingArchiveIsStoppedBeforeWritingPastItsRecordedSize() throws {
        let archive = try makeArchive(
            [TestZIPEntry("flood.txt", Data(repeating: 0x61, count: 200_000))],
            compression: .deflate
        )
        try setRecordedSize(of: "flood.txt", in: archive, to: 10)
        let budget = Self.budget()

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: budget)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastDeclaredSize(path: "flood.txt", declared: 10))
        }
        let written = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("flood.txt").path)
        XCTAssertLessThanOrEqual((written[.size] as? Int) ?? .max, 10)
        XCTAssertLessThanOrEqual(budget.extractedTotal, 10)
    }

    /// A file whose data does not match the checksum the archive stores is
    /// told in plain words, as unzipItem's checksum error was.
    func testChecksumMismatchIsToldAsADamagedArchive() throws {
        let archive = try makeArchive([TestZIPEntry("notes.txt", Data("Bring a coat.".utf8))])
        try setRecordedChecksum(of: "notes.txt", in: archive, to: 0xDEAD_BEEF)

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget())) { error in
            XCTAssertEqual(error.localizedDescription, "The archive is damaged, incomplete, or not a ZIP archive.")
        }
    }

    /// A file that is not an archive is told in plain words, and a missing
    /// one as missing.
    func testUnreadableAndMissingArchivesAreToldPlainly() throws {
        let notAnArchive = workspace.appendingPathComponent("torn.zip")
        try Data("not a ZIP archive".utf8).write(to: notAnArchive)
        let missing = workspace.appendingPathComponent("missing.zip")

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: notAnArchive, into: destination, budget: Self.budget())) { error in
            XCTAssertEqual(error.localizedDescription, "The archive is damaged, incomplete, or not a ZIP archive.")
        }
        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: missing, into: destination, budget: Self.budget())) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    // MARK: - Paths and Links

    /// ZIP-slip probe, recording what the pinned ZIPFoundation (0.9.20)
    /// does itself: its writer keeps an entry path that climbs out of the
    /// archive exactly as given, and its `unzipItem` refuses that entry
    /// with Cocoa's invalid-file-name error before writing it, so nothing
    /// appears outside the destination.
    func testZIPFoundationRefusesAnEntryLeadingOutside() throws {
        let escapeName = "escape-\(UUID().uuidString).txt"
        let archive = try makeArchive([TestZIPEntry("../\(escapeName)", Data("outside".utf8))])
        XCTAssertEqual(try Archive(url: archive, accessMode: .read).map(\.path), ["../\(escapeName)"])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FileManager.default.unzipItem(at: archive, to: destination)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadInvalidFileName)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(escapeName).path))
    }

    /// ZIP-slip probe: ZIPFoundation's `unzipItem` places an entry whose
    /// path starts with a slash inside the destination, not at the root of
    /// the disk.
    func testZIPFoundationPlacesARootedPathInside() throws {
        let name = "rooted-\(UUID().uuidString).txt"
        let archive = try makeArchive([TestZIPEntry("/\(name)", Data("inside".utf8))])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try FileManager.default.unzipItem(at: archive, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/\(name)"))
    }

    /// TextMouth's extraction refuses the entry that climbs out, in plain
    /// words, writing nothing outside; a rooted path lands inside, as with
    /// ZIPFoundation.
    func testExtractionRefusesAnEntryLeadingOutside() throws {
        let escapeName = "escape-\(UUID().uuidString).txt"
        let climbing = try makeArchive([TestZIPEntry("../\(escapeName)", Data("outside".utf8))])
        let rooted = try makeArchive([TestZIPEntry("/rooted.txt", Data("inside".utf8))])

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: climbing, into: destination, budget: Self.budget())) { error in
            guard case .archivePathOutside? = error as? FileImportError else {
                return XCTFail("Expected a path leading outside, got \(error)")
            }
            XCTAssertEqual(
                error.localizedDescription,
                "The archive holds a file whose path leads outside it, which is never extracted."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(escapeName).path))

        try ArchiveExtractor.extract(archiveAt: rooted, into: destination, budget: Self.budget())
        XCTAssertEqual(try text(at: "rooted.txt"), "inside")
    }

    /// Paths resolve within the destination: "." and repeated slashes are
    /// ignored and ".." inside is followed, but a ".." that climbs above the
    /// destination refuses the path, even when it would come back inside.
    func testPathsResolveWithinTheDestination() {
        let directory = URL(fileURLWithPath: "/private/tmp/out", isDirectory: true)
        /// Where the entry at `path` would go, as a path; nil when refused.
        func resolved(_ path: String) -> String? {
            ArchiveExtractor.containedDestination(of: path, in: directory)?.path
        }

        XCTAssertEqual(resolved("Ferry//Fares/./winter.txt"), "/private/tmp/out/Ferry/Fares/winter.txt")
        XCTAssertEqual(resolved("Ferry/../notes.txt"), "/private/tmp/out/notes.txt")
        XCTAssertEqual(resolved("/rooted.txt"), "/private/tmp/out/rooted.txt")
        XCTAssertNil(resolved("../notes.txt"))
        XCTAssertNil(resolved("Ferry/../../notes.txt"))
        XCTAssertNil(resolved("../out/notes.txt"))
    }

    /// A link pointing outside its own folder is refused, as unzipItem
    /// refused it, in plain words.
    func testLinkPointingOutsideIsRefused() throws {
        let archive = try makeArchive([.link("shortcut", to: "../../outside.txt")])

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget())) { error in
            guard case .archiveLinksOutside? = error as? FileImportError else {
                return XCTFail("Expected a link leading outside, got \(error)")
            }
        }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("shortcut").path))
    }

    /// A link pointing inside its own folder is made, as ZIPFoundation
    /// makes it.
    func testLinkPointingInsideIsMade() throws {
        let archive = try makeArchive([
            TestZIPEntry("Ferry/timetable.txt", Data("Departs at nine.".utf8)),
            .link("Ferry/latest.txt", to: "timetable.txt")
        ])

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget())

        let link = destination.appendingPathComponent("Ferry/latest.txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "timetable.txt")
    }

    /// A second entry of the same path is refused, as unzipItem refused it,
    /// rather than replacing the first.
    func testSecondEntryOfTheSamePathIsRefused() throws {
        let archive = try makeArchive([
            TestZIPEntry("notes.txt", Data("first".utf8)),
            TestZIPEntry("notes.txt", Data("second".utf8))
        ])

        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget())) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try text(at: "notes.txt"), "first")
    }

    // MARK: - Cancellation

    /// Cancelling between entries stops before the next one.
    func testCancellationStopsBetweenEntries() throws {
        let archive = try makeArchive((1...5).map { TestZIPEntry("page\($0).txt", Data("Page \($0)".utf8)) })
        let cancellation = ImportCancellation()

        XCTAssertThrowsError(
            try ArchiveExtractor.extract(
                archiveAt: archive,
                into: destination,
                budget: Self.budget(),
                isCancelled: cancellation.check,
                progress: { done, _ in
                    if done == 2 { cancellation.cancel() }
                }
            )
        ) { error in
            XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["page1.txt", "page2.txt"])
    }

    /// Cancelling stops a large file between its chunks, not only between
    /// entries.
    func testCancellationStopsALargeFileBetweenChunks() throws {
        let size = 400_000
        let archive = try makeArchive([TestZIPEntry("lecture.wav", Data(repeating: 0x61, count: size))])
        // The check is asked before the entry, then before each chunk; it
        // answers "stop" from its fourth asking on.
        let checks = CheckCounter()

        XCTAssertThrowsError(
            try ArchiveExtractor.extract(
                archiveAt: archive,
                into: destination,
                budget: Self.budget(),
                isCancelled: { checks.next() > 3 }
            )
        ) { error in
            XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
        }
        let written = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("lecture.wav").path)
        let writtenSize = try XCTUnwrap(written[.size] as? Int)
        XCTAssertGreaterThan(writtenSize, 0)
        XCTAssertLessThan(writtenSize, size)
    }

    /// Cancelling one cancellation stops the imports sharing it, and only them.
    func testCancellationReachesOnlyTheImportsSharingIt() {
        let first = ImportCancellation()
        let second = ImportCancellation()
        let check = first.check

        XCTAssertFalse(check())
        first.cancel()

        XCTAssertTrue(check())
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
    }

    // MARK: - Extraction Directories

    /// An extraction directory is named for this process, made in the folder
    /// given, and removed with everything inside it; removing it again does
    /// nothing.
    func testExtractionDirectoryIsNamedForItsProcessAndRemovedWhole() throws {
        let made = try ArchiveExtractionDirectory.make(in: parent)
        try FileManager.default.createDirectory(at: made.archiveDirectory, withIntermediateDirectories: true)
        try Data("Departs at nine.".utf8).write(to: made.archiveDirectory.appendingPathComponent("timetable.txt"))

        XCTAssertEqual(made.directory.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
        XCTAssertEqual(ArchiveExtractionDirectory.processIdentifier(inName: made.name), getpid())
        made.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory.path))
        made.remove()
    }

    /// The sweep removes the extraction directories no import is using
    /// (those of stopped processes, and this process's own that none of its
    /// imports holds) with everything inside, logs each, and leaves alone a
    /// directory in use, another running process's, anything else named,
    /// and a file named like one.
    func testSweepRemovesOnlyAbandonedExtractionDirectories() throws {
        let stoppedProcess: Int32 = 4_000_001
        let runningProcess: Int32 = 4_000_002
        let inUse = try ArchiveExtractionDirectory.make(in: parent)
        defer { inUse.remove() }
        let stopped = try makeDirectory("extract-\(stoppedProcess)-\(UUID().uuidString)", holdingAFile: true)
        let ownAbandoned = try makeDirectory("extract-\(getpid())-\(UUID().uuidString)", holdingAFile: false)
        let running = try makeDirectory("extract-\(runningProcess)-\(UUID().uuidString)", holdingAFile: true)
        let unrelated = try makeDirectory("Notes", holdingAFile: true)
        let malformed = try makeDirectory("extract-12ab-\(UUID().uuidString)", holdingAFile: false)
        let fileNamedLikeOne = parent.appendingPathComponent("extract-\(stoppedProcess)-\(UUID().uuidString)")
        try Data().write(to: fileNamedLikeOne)

        let removed = ArchiveExtractionDirectory.removeLeftovers(in: parent) { $0 == runningProcess }

        XCTAssertEqual(removed, 2)
        for gone in [stopped, ownAbandoned] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent)
            XCTAssertEqual(
                debugLogLines(containing: "ARCHIVE_EXTRACTION_REMOVED: \(gone.path): left by an interrupted import").count,
                1
            )
        }
        for kept in [inUse.directory, running, unrelated, malformed, fileNamedLikeOne] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
    }

    /// Only an extraction directory's name gives a process identifier.
    func testProcessIdentifierIsReadOnlyFromExtractionDirectoryNames() {
        let uuid = UUID().uuidString
        /// The process identifier the name `name` gives, if any.
        func process(_ name: String) -> Int32? {
            ArchiveExtractionDirectory.processIdentifier(inName: name)
        }

        XCTAssertEqual(process("extract-412-\(uuid)"), 412)
        XCTAssertNil(process("extract-0-\(uuid)"))
        XCTAssertNil(process("extract--5-\(uuid)"))
        XCTAssertNil(process("extract-+5-\(uuid)"))
        XCTAssertNil(process("extract-412-not-a-uuid"))
        XCTAssertNil(process("Extract-412-\(uuid)"))
        XCTAssertNil(process(".import-\(uuid).tmb"))
    }

    /// The real process check tells this running process from one that has
    /// exited.
    func testProcessCheckTellsARunningProcessFromAStoppedOne() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        XCTAssertTrue(ArchiveExtractionDirectory.isProcessRunning(getpid()))
        XCTAssertFalse(ArchiveExtractionDirectory.isProcessRunning(process.processIdentifier))
    }

    // MARK: - Fixtures

    /// Where tests extract to; not made until extraction makes it.
    private var destination: URL {
        workspace.appendingPathComponent("extracted", isDirectory: true)
    }

    /// Where tests make extraction directories.
    private var parent: URL {
        workspace.appendingPathComponent(ArchiveExtractionDirectory.folderName, isDirectory: true)
    }

    /// A budget with small limits and plenty of free space, unless `other`
    /// says otherwise for archives without audio.
    private static func budget(other: Int64 = 5_000_000) -> ArchiveBudget {
        ArchiveBudget(limits: ArchiveBudgetTests.limits(audio: 10_000_000, other: other, entries: 1_000))
    }

    /// An archive holding `entries` in order. Its file is removed when the
    /// test ends.
    private func makeArchive(_ entries: [TestZIPEntry], compression: CompressionMethod = .none) throws -> URL {
        let url = try makeTemporaryZip(prefix: "ArchiveExtractionTests", orderedEntries: entries, compressionMethod: compression)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The text of the extracted file at `path` inside the destination.
    private func text(at path: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    /// A directory named `name` in `parent`, holding a file when
    /// `holdingAFile`, as an interrupted extraction leaves one.
    private func makeDirectory(_ name: String, holdingAFile: Bool) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if holdingAFile {
            try Data("Departs at nine.".utf8).write(to: directory.appendingPathComponent("timetable.txt"))
        }
        return directory
    }
}

/// Counts how often a cancellation check is asked, from any thread.
private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Counts one more asking and returns the count so far.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
