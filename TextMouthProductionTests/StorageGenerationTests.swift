import XCTest
@testable import TextMouth

/// The storage generation (TODO S04): the one place that says where the
/// data directory is, which changes only when a data-directory move
/// publishes its copy.
@MainActor
final class StorageGenerationTests: XCTestCase {

    // MARK: - One Generation

    /// Every path in the data directory is built from the current
    /// generation's root.
    func testTheDataDirectoryIsTheCurrentGenerationsRoot() {
        let generation = StorageBoundary.shared.current

        XCTAssertEqual(TextMouthPaths.root.path, generation.root.path)
        XCTAssertEqual(TextMouthPaths.libraryDir.path, generation.root.appendingPathComponent("Library").path)
        XCTAssertEqual(TextMouthPaths.libraryIndexFile.path, generation.root.appendingPathComponent("library.json").path)
    }

    /// A move that publishes its copy starts the next generation at the new
    /// location, and every path follows it.
    func testAPublishedMoveStartsTheNextGenerationAtItsDestination() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        // Settled files only: no write may land in the data directory
        // while it is copied.
        LibraryPersistenceService.flushPendingSave()
        TextMouthPaths.flushLogs()
        let before = StorageBoundary.shared.current
        let destination = try makeDataDirectoryMoveDestination("GenerationMove")
        var library = Library()

        try TextMouthPaths.moveDataDirectory(to: destination, library: &library)

        let after = StorageBoundary.shared.current
        XCTAssertEqual(after.number, before.number + 1)
        XCTAssertEqual(after.root.path, destination.path)
        XCTAssertEqual(TextMouthPaths.libraryIndexFile.path, destination.appendingPathComponent("library.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.libraryIndexFile.path))
    }

    /// A move refused before anything is copied keeps the generation: the
    /// same number and the same root.
    func testARefusedMoveKeepsTheGeneration() throws {
        let before = StorageBoundary.shared.current
        let destination = try makeSandboxDirectory("GenerationRefused")
        try Data("keep".utf8).write(to: destination.appendingPathComponent("keep.txt"))
        var library = Library()

        XCTAssertThrowsError(try TextMouthPaths.moveDataDirectory(to: destination, library: &library))

        XCTAssertEqual(StorageBoundary.shared.current, before)
    }

    /// Recording a location in the preferences starts no generation: the
    /// data directory stays where it is until a move publishes a copy.
    func testRecordingALocationStartsNoGeneration() throws {
        preservePreferences(["textMouthDataDirectory"])
        let before = StorageBoundary.shared.current

        TextMouthPaths.setCustomRoot(try makeSandboxDirectory("GenerationChosen"))
        XCTAssertEqual(StorageBoundary.shared.current, before)
        TextMouthPaths.setCustomRoot(nil)

        XCTAssertEqual(StorageBoundary.shared.current, before)
    }

    /// A boundary numbers its generations in the order they are published,
    /// each at its own root, starting from 0.
    func testGenerationsAreNumberedInTheOrderTheyArePublished() throws {
        let first = try makeSandboxDirectory("GenerationFirst")
        let second = try makeSandboxDirectory("GenerationSecond")
        let boundary = StorageBoundary(root: first)
        let start = boundary.current
        XCTAssertEqual(start.number, 0)
        XCTAssertEqual(start.root.path, first.path)

        let moved = boundary.publish(root: second)
        let back = boundary.publish(root: first)

        XCTAssertEqual(moved.number, 1)
        XCTAssertEqual(moved.root.path, second.path)
        XCTAssertEqual(back.number, 2)
        XCTAssertEqual(boundary.current, back)
        XCTAssertNotEqual(back, start, "returning to a root is a new generation")
    }
}
