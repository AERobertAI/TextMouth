import XCTest
@testable import TextMouth

/// Saving while the data directory is unavailable (FR02): library index
/// writes wait, without counting as failures, while the library model has
/// found the data directory unavailable; and a write that finds a custom
/// data directory's folder gone is reported as a failure, recreates
/// nothing, and tells the library model to check the data directory.
@MainActor
final class DataDirectoryPersistenceTests: XCTestCase {

    override func setUp() async throws {
        PersistenceFailureCenter.shared.reset()
    }

    override func tearDown() async throws {
        PersistenceFailureCenter.shared.reset()
    }

    /// While the gate is closed, a save writes nothing and reports nothing,
    /// and the debug log says why once; once it opens, saves write again.
    func testIndexWritesWaitWhileTheDataDirectoryIsUnavailable() throws {
        let root = try makeCurrentDataDirectory("ClosedGate")
        let index = root.appendingPathComponent("library.json")
        let marker = UUID().uuidString
        // A write that succeeds first, as the library's own do, so the hold
        // below is logged as a new one.
        LibraryPersistenceService.save(Library(folders: [BookFolder(name: "Before \(marker)")]))
        LibraryPersistenceService.flushPendingSave()
        let original = try Data(contentsOf: index)
        let skippedNote = "skipped writing the library index because the data directory isn't available"
        let notesBefore = debugLogLines(containing: skippedNote).count
        DataDirectoryGate.close(root)
        addTeardownBlock { DataDirectoryGate.open(root) }

        LibraryPersistenceService.save(Library(folders: [BookFolder(name: "Waiting \(marker)")]))
        LibraryPersistenceService.flushPendingSave()
        LibraryPersistenceService.save(Library(folders: [BookFolder(name: "Still Waiting \(marker)")]))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try Data(contentsOf: index), original, "an index was written while the library was unavailable")
        XCTAssertEqual(PersistenceFailureCenter.shared.outstandingFailures().count, 0)
        XCTAssertEqual(debugLogLines(containing: skippedNote).count - notesBefore, 1, "the skip was not logged once")

        DataDirectoryGate.open(root)
        LibraryPersistenceService.save(Library(folders: [BookFolder(name: "Saved \(marker)")]))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(try String(contentsOf: index, encoding: .utf8).contains("Saved \(marker)"))
    }

    /// A write that finds the custom data directory's folder gone fails,
    /// recreates nothing, stays listed for a retry, and tells the library
    /// model which data directory it found missing.
    func testAWriteThatFindsTheFolderGoneTellsTheLibraryModel() throws {
        let root = try makeCurrentDataDirectory("VanishedFolder")
        let reported = XCTNSNotificationExpectation(
            name: .dataDirectoryWriteFoundFolderMissing,
            object: nil,
            notificationCenter: .default
        )
        let path = root.path
        reported.handler = { note in
            note.userInfo?[DataDirectoryEvents.rootKey] as? String == path
        }
        try FileManager.default.removeItem(at: root)

        LibraryPersistenceService.save(Library())
        LibraryPersistenceService.flushPendingSave()

        wait(for: [reported], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "the write recreated the data directory")
        let failure = try XCTUnwrap(PersistenceFailureCenter.shared.outstandingFailures().first)
        XCTAssertEqual(failure.subsystem, .libraryIndex)
        XCTAssertEqual((failure.error as? DataDirectoryUnavailableError)?.root.path, root.path)
    }

    // MARK: - Fixtures

    /// A data directory of the test's own, with its folders, made the
    /// current one until the test ends.
    private func makeCurrentDataDirectory(_ label: String) throws -> URL {
        let root = try makeDataDirectoryMoveDestination(label)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        StorageBoundary.shared.publish(root: root)
        return root
    }
}
