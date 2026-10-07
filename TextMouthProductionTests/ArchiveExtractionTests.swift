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

    /// Progress is told the entries done and the bytes written of their
    /// totals, from none to all: every entry's count in turn, and the bytes
    /// as they are written, never going back (FR10).
    func testProgressIsToldEntriesAndBytesDoneOfTheirTotals() throws {
        let archive = try makeArchive((1...4).map { TestZIPEntry("page\($0).txt", Data("Page \($0)".utf8)) })
        var reports: [ArchiveExtractionProgress] = []

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(), progress: { reports.append($0) })

        // Each page is "Page N", 6 bytes.
        XCTAssertEqual(reports.first, ArchiveExtractionProgress(entriesDone: 0, entries: 4, bytesDone: 0, bytes: 24))
        XCTAssertEqual(reports.last, ArchiveExtractionProgress(entriesDone: 4, entries: 4, bytesDone: 24, bytes: 24))
        XCTAssertEqual(Self.distinct(reports.map(\.entriesDone)), [0, 1, 2, 3, 4])
        XCTAssertEqual(reports.map(\.bytesDone), reports.map(\.bytesDone).sorted(), "the bytes went back")
        XCTAssertEqual(Set(reports.map(\.bytesDone)), [0, 6, 12, 18, 24])
    }

    /// A file of many chunks is told as it is written, so a large file is
    /// seen to move before its entry is done.
    func testALargeFilesBytesAreToldAsItIsWritten() throws {
        let size = 400_000
        let archive = try makeArchive([TestZIPEntry("lecture.wav", Data(repeating: 0x61, count: size))])
        var reports: [ArchiveExtractionProgress] = []

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(), progress: { reports.append($0) })

        let duringTheFile = reports.filter { $0.entriesDone == 0 && $0.bytesDone > 0 }
        XCTAssertGreaterThan(duringTheFile.count, 1, "the file was not seen to move: \(reports.map(\.bytesDone))")
        XCTAssertTrue(duringTheFile.allSatisfy { $0.bytesDone <= Int64(size) && $0.bytes == Int64(size) })
        XCTAssertEqual(reports.last, ArchiveExtractionProgress(entriesDone: 1, entries: 1, bytesDone: Int64(size), bytes: Int64(size)))
        XCTAssertLessThanOrEqual(reports.count, 102, "a report for each whole percent, at most")
    }

    /// A large archive tells its progress at most once per percent of its
    /// entries and once per percent of its bytes, from none to all, so the
    /// main thread is not flooded.
    func testProgressOfALargeArchiveIsToldAtMostOncePerPercent() throws {
        let archive = try makeArchive((1...500).map { TestZIPEntry("slip\($0).txt", Data("x".utf8)) })
        var reports: [ArchiveExtractionProgress] = []

        try ArchiveExtractor.extract(archiveAt: archive, into: destination, budget: Self.budget(), progress: { reports.append($0) })

        XCTAssertEqual(reports.first, ArchiveExtractionProgress(entriesDone: 0, entries: 500, bytesDone: 0, bytes: 500))
        XCTAssertEqual(reports.last, ArchiveExtractionProgress(entriesDone: 500, entries: 500, bytesDone: 500, bytes: 500))
        XCTAssertLessThanOrEqual(reports.count, 201)
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
                progress: { progress in
                    if progress.entriesDone == 2 { cancellation.cancel() }
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
    /// imports holds) with everything inside, logs each by its loggable path
    /// and never its absolute one, and leaves alone a directory in use,
    /// another running process's, anything else named, and a file named
    /// like one. It asks whether a directory's maker runs only for other
    /// processes' plain directories, telling it when each was made.
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

        // Each process the sweep asked about, with when its directory was made.
        var madeDates: [Int32: Date] = [:]

        let removed = ArchiveExtractionDirectory.removeLeftovers(in: parent) { process, made in
            madeDates[process] = made ?? .distantPast
            return process == runningProcess
        }

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Set(madeDates.keys), [stoppedProcess, runningProcess], "only other processes' directories are asked about")
        for (process, made) in madeDates {
            XCTAssertLessThan(abs(made.timeIntervalSinceNow), 600, "process \(process) was not told when its directory was made")
        }
        for gone in [stopped, ownAbandoned] {
            let named = DiagnosticLog.loggablePath(gone)
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent)
            XCTAssertEqual(
                debugLogLines(containing: "ARCHIVE_EXTRACTION_REMOVED: \(named): left by an interrupted import").count,
                1
            )
            XCTAssertEqual(debugLogLines(containing: gone.path), [], "the log named \(named) by its absolute path")
        }
        for kept in [inUse.directory, running, unrelated, malformed, fileNamedLikeOne] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
    }

    /// Process identifiers are reused (#652). An extraction directory named
    /// for a running process that started well after the directory was made
    /// was left by an earlier process with that identifier, which has ended:
    /// the sweep removes it, as the sandbox sweep removes such a sandbox.
    /// One made after its process started stays, and so does one made up to
    /// an hour before, which only a change of the clock explains.
    func testSweepRemovesADirectoryWhoseIdentifierALaterProcessTook() throws {
        // launchd, process 1, has run since the Mac started up, so a
        // directory named for process 1 that was made before then was made
        // by an earlier process 1: its recorded time does not match.
        let launchdStarted = try XCTUnwrap(TextMouthRuntime.startDate(ofProcess: 1))
        let hour: TimeInterval = 60 * 60
        let taken = try makeDirectory(
            "extract-1-\(UUID().uuidString)",
            holdingAFile: true,
            made: launchdStarted.addingTimeInterval(-2 * hour)
        )
        let madeBeforeAClockChange = try makeDirectory(
            "extract-1-\(UUID().uuidString)",
            holdingAFile: true,
            made: launchdStarted.addingTimeInterval(-0.5 * hour)
        )
        let madeByTheRunningProcess = try makeDirectory("extract-1-\(UUID().uuidString)", holdingAFile: true)

        let removed = ArchiveExtractionDirectory.removeLeftovers(in: parent)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: taken.path), "the leftover of an earlier process 1 stayed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: madeBeforeAClockChange.path),
            "a directory made within the hour before its process started was removed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: madeByTheRunningProcess.path),
            "the running process's own directory was removed"
        )
    }

    /// An abandoned extraction directory the sweep cannot remove, here
    /// because a folder inside it may not have its contents deleted, stays
    /// and is not counted, and its one log line names it by its loggable
    /// path, never its absolute one.
    func testSweepLogsADirectoryItCannotRemoveByItsLoggablePath() throws {
        try XCTSkipIf(getuid() == 0, "the superuser can delete what permissions forbid")
        let stuck = try makeDirectory("extract-4000001-\(UUID().uuidString)", holdingAFile: false)
        let locked = stuck.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("Departs at nine.".utf8).write(to: locked.appendingPathComponent("timetable.txt"))
        // Read and search only: the file inside cannot be deleted. The
        // permission is restored before the sandbox folder is removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        let named = DiagnosticLog.loggablePath(stuck)

        let removed = ArchiveExtractionDirectory.removeLeftovers(in: parent) { _, _ in false }

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
        XCTAssertEqual(debugLogLines(containing: "ARCHIVE_EXTRACTION_LEFT: \(named): could not be removed: ").count, 1)
        XCTAssertEqual(debugLogLines(containing: "ARCHIVE_EXTRACTION_REMOVED: \(named):"), [])
        XCTAssertEqual(debugLogLines(containing: stuck.path), [], "the log named \(named) by its absolute path")
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

    /// The sweep's real rule tells this running process from one that has
    /// exited, for a directory made just now.
    func testProcessCheckTellsARunningProcessFromAStoppedOne() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        XCTAssertTrue(TextMouthRuntime.isFolderMakerRunning(getpid(), folderMade: Date()))
        XCTAssertFalse(TextMouthRuntime.isFolderMakerRunning(process.processIdentifier, folderMade: Date()))
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
    /// `holdingAFile`, as an interrupted extraction leaves one, and recorded
    /// as made at `made` when one is given, rather than now.
    private func makeDirectory(_ name: String, holdingAFile: Bool, made: Date? = nil) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if holdingAFile {
            try Data("Departs at nine.".utf8).write(to: directory.appendingPathComponent("timetable.txt"))
        }
        if let made {
            try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: directory.path)
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

extension ArchiveExtractionTests {
    /// `values` with each run of equal values told once, in order.
    static func distinct(_ values: [Int]) -> [Int] {
        values.reduce(into: []) { kept, value in
            if kept.last != value { kept.append(value) }
        }
    }
}
