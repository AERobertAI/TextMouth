import XCTest
@testable import TextMouth

/// Where imports build the packages they publish (FR02, `ImportStaging`):
/// in this Mac's Import Staging folder while the data directory shares its
/// volume, so a cloud data directory never uploads a package being built and
/// another Mac's import never meets this Mac's; beside the destination
/// otherwise. A staged book finds its package wherever it is built, and each
/// staging sweeps this Mac's folder and, for earlier versions' leftovers,
/// the destination's library folder.
final class CloudMaintenanceStagingTests: CloudMaintenanceTestCase {

    /// A package for the library is staged in this Mac's folder when it
    /// shares the data directory's volume, and beside its destination
    /// otherwise; a destination outside the data directory is always staged
    /// beside, so its rename never crosses volumes.
    func testStagingFolderByVolume() {
        let destination = folderURL.appendingPathComponent("Atlas.tmb", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("Elsewhere/Atlas.tmb")

        XCTAssertEqual(
            ImportScratchSpace.stagingFolder(publishingTo: destination, onThisMac: true).path,
            MachineLocalPaths.importStaging.path
        )
        XCTAssertEqual(ImportScratchSpace.stagingFolder(publishingTo: destination, onThisMac: false).path, folderURL.path)
        XCTAssertEqual(
            ImportScratchSpace.stagingFolder(publishingTo: elsewhere, onThisMac: true).path,
            elsewhere.deletingLastPathComponent().path
        )
    }

    /// A package staged for the library is built in this Mac's Import
    /// Staging folder, under the hidden name, and a book staged in it finds
    /// its package there, until the package is published or discarded.
    func testStagedBookFindsItsPackageOnThisMac() throws {
        let destination = folderURL.appendingPathComponent("Atlas.tmb", isDirectory: true)

        let staging = try ImportStaging.makeEmpty(publishingTo: destination)
        let staged = Book(
            title: "Atlas",
            format: .txt,
            filePath: staging.directory.appendingPathComponent("atlas.txt").path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: staging.name
        )

        XCTAssertEqual(staging.directory.deletingLastPathComponent().path, MachineLocalPaths.importStaging.path)
        XCTAssertTrue(staging.name.hasPrefix(ImportStaging.namePrefix))
        XCTAssertEqual(staged.tmbDirectory, staging.directory)
        XCTAssertEqual(MarkdownCacheService.cacheURL(for: staged), staging.directory.appendingPathComponent("content.md"))
        XCTAssertNil(ImportStaging.directory(ofStagedPackage: "Atlas.tmb"))

        staging.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        XCTAssertNil(ImportStaging.directory(ofStagedPackage: staging.name))
        XCTAssertEqual(staged.tmbDirectory, folderURL.appendingPathComponent(staging.name, isDirectory: true))
    }

    /// An import stages on this Mac and publishes into the library with one
    /// rename: the package it works on while importing is in Import Staging,
    /// and afterwards exactly one package is in the library folder, holding
    /// the book and its text cache, and none is left staged.
    func testImportStagesOnThisMacAndPublishesIntoTheLibrary() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("Staged On This Mac \(UUID().uuidString).txt")
        try "A line to read.".write(to: source, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let packagesSeen = StagedPackageRecorder()

        let imported = try FileImportService.importFileWithReport(
            from: source,
            toFolder: folderPath,
            observer: { _, package in packagesSeen.record(package) }
        )

        XCTAssertFalse(packagesSeen.urls.isEmpty)
        for package in packagesSeen.urls {
            XCTAssertEqual(package.deletingLastPathComponent().path, MachineLocalPaths.importStaging.path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folderURL.path), [imported.book.tmbDirectoryName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.book.filePath))
        XCTAssertNotNil(contents(of: MarkdownCacheService.cacheURL(for: imported.book)))
        let staged = Set(packagesSeen.urls.map(\.lastPathComponent))
        let leftInStaging = (try? FileManager.default.contentsOfDirectory(atPath: MachineLocalPaths.importStaging.path)) ?? []
        XCTAssertTrue(staged.isDisjoint(with: leftInStaging), "\(leftInStaging)")
    }

    /// Staging removes what interrupted imports left in this Mac's Import
    /// Staging folder and, as before, in the destination's library folder,
    /// keeps a package still being built, and logs each removal by its path
    /// inside this Mac's folder or the data directory.
    func testStagingSweepsThisMacsFolderAndTheDestinationsLibraryFolder() throws {
        try ImportScratchSpace.prepareFolder(MachineLocalPaths.importStaging)
        let onThisMac = try makeLeftover(
            named: "\(ImportStaging.namePrefix)\(UUID().uuidString).tmb",
            in: MachineLocalPaths.importStaging
        )
        let inLibrary = try makeLeftover(named: "\(ImportStaging.namePrefix)\(UUID().uuidString).tmb", in: folderURL)
        let building = try ImportStaging.makeEmpty(publishingTo: folderURL.appendingPathComponent("First.tmb"))
        defer { building.discard() }

        let second = try ImportStaging.makeEmpty(publishingTo: folderURL.appendingPathComponent("Second.tmb"))
        defer { second.discard() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: onThisMac.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inLibrary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: building.directory.path))
        XCTAssertEqual(
            logLineCount("IMPORT_STAGING_REMOVED: Import Staging/\(onThisMac.lastPathComponent): left by an interrupted import"),
            1
        )
        XCTAssertEqual(
            logLineCount("IMPORT_STAGING_REMOVED: \(DiagnosticLog.loggablePath(inLibrary)): left by an interrupted import"),
            1
        )
    }
}

/// The packages an import's steps were told about, recorded from whichever
/// thread imports.
private final class StagedPackageRecorder: @unchecked Sendable {
    /// Guards `recorded`.
    private let lock = NSLock()
    /// The URLs recorded so far, in order.
    private var recorded: [URL] = []

    /// Records `url`.
    func record(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }

    /// The URLs recorded so far, in order.
    var urls: [URL] {
        lock.withLock { recorded }
    }
}
