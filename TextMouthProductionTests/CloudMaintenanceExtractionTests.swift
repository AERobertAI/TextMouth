import XCTest
@testable import TextMouth

/// Where ZIP imports extract archives (FR02, `ImportScratchSpace`): in this
/// Mac's Archive Extraction folder while the data directory shares its
/// volume, so a cloud data directory never uploads an archive being
/// extracted; in the data directory's own folder otherwise. The startup sweep
/// cleans this Mac's folder and the data directory's old one.
final class CloudMaintenanceExtractionTests: CloudMaintenanceTestCase {

    // MARK: - Locations by Volume

    /// The folders are on this Mac exactly when the volume comparison says
    /// the data directory shares a volume with this Mac's folder.
    func testFoldersAreOnThisMacOnlyWhenTheVolumesMatch() {
        let dataDirectory = URL(fileURLWithPath: "/Volumes/Archive/TextMouth", isDirectory: true)
        let thisMac = URL(fileURLWithPath: "/Users/someone/Library/Application Support/com.textmouth.TextMouth")
        var compared: [(URL, URL)] = []

        let same = ImportScratchSpace.isOnThisMac(dataDirectory: dataDirectory, machineLocalRoot: thisMac) {
            compared.append(($0, $1))
            return true
        }
        let other = ImportScratchSpace.isOnThisMac(dataDirectory: dataDirectory, machineLocalRoot: thisMac) { _, _ in false }

        XCTAssertTrue(same)
        XCTAssertFalse(other)
        XCTAssertEqual(compared.map(\.0), [dataDirectory])
        XCTAssertEqual(compared.map(\.1), [thisMac])
    }

    /// Archives are extracted in this Mac's folder when it shares the data
    /// directory's volume, and in the data directory's own folder otherwise.
    func testExtractionFolderByVolume() {
        XCTAssertEqual(
            ImportScratchSpace.archiveExtractionFolder(onThisMac: true).path,
            MachineLocalPaths.archiveExtraction.path
        )
        XCTAssertEqual(
            ImportScratchSpace.archiveExtractionFolder(onThisMac: false).path,
            TextMouthPaths.root.appendingPathComponent("Archive Extraction", isDirectory: true).path
        )
    }

    /// The real comparison finds the hosted test's data directory and its
    /// folders on this Mac's volume, a folder that does not exist yet by the
    /// nearest folder above it that does, so archives are extracted on this
    /// Mac here.
    func testRealComparisonFindsTheTestRootOnThisMacsVolume() {
        let notYetMade = MachineLocalPaths.root.appendingPathComponent("Not Yet \(UUID().uuidString)/Inside")

        XCTAssertTrue(ImportScratchSpace.areOnSameVolume(TextMouthPaths.root, MachineLocalPaths.root))
        XCTAssertTrue(ImportScratchSpace.areOnSameVolume(folderURL, notYetMade))
        XCTAssertTrue(ImportScratchSpace.isOnThisMac())
        XCTAssertEqual(ArchiveExtractionDirectory.defaultParent.path, MachineLocalPaths.archiveExtraction.path)
    }

    // MARK: - The Startup Sweep

    /// The startup sweep removes the extraction directories stopped imports
    /// left in this Mac's folder and in the data directory's old one, names
    /// each by its path inside its folder, and removes the old folder once
    /// nothing is left in it; an old folder still holding something stays.
    func testStartupSweepCleansThisMacsFolderAndTheOldOneInTheDataDirectory() throws {
        let stopped = try stoppedProcess()
        let oldFolder = ImportScratchSpace.inLibraryArchiveExtraction
        try ImportScratchSpace.prepareFolder(MachineLocalPaths.archiveExtraction)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: oldFolder) }
        let name = { "\(ArchiveExtractionDirectory.namePrefix)\(stopped)-\(UUID().uuidString)" }
        let onThisMac = try makeLeftover(named: name(), in: MachineLocalPaths.archiveExtraction)
        let inOldFolder = try makeLeftover(named: name(), in: oldFolder)

        ArchiveExtractionDirectory.removeLeftovers()

        XCTAssertFalse(FileManager.default.fileExists(atPath: onThisMac.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inOldFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path), "the emptied old folder stayed")
        for leftover in [onThisMac, inOldFolder] {
            XCTAssertEqual(
                logLineCount("ARCHIVE_EXTRACTION_REMOVED: Archive Extraction/\(leftover.lastPathComponent): left by"),
                1,
                leftover.lastPathComponent
            )
        }

        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: oldFolder.appendingPathComponent("Notes.txt"))
        ArchiveExtractionDirectory.removeLeftovers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("Notes.txt").path))
    }

    // MARK: - Fixtures

    /// The identifier of a process that has exited.
    private func stoppedProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
