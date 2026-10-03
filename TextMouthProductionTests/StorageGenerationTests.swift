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

    // MARK: - Relocating Paths

    /// A path inside a location keeps its place inside the destination,
    /// whether it spells the location by its name or by the folder a link
    /// leads to; a path elsewhere, even one beginning with the same letters,
    /// is not inside it and is not moved.
    func testAPathKeepsItsPlaceInsideTheNewLocation() {
        let linked = DataDirectoryLocation(
            named: URL(fileURLWithPath: "/Users/reader/Data", isDirectory: true),
            real: URL(fileURLWithPath: "/Volumes/Archive/.TextMouth", isDirectory: true)
        )
        let destination = URL(fileURLWithPath: "/Volumes/New/.TextMouth", isDirectory: true)

        XCTAssertEqual(
            linked.relocating("/Users/reader/Data/Library/Shelf/A.tmb/a.txt", to: destination),
            "/Volumes/New/.TextMouth/Library/Shelf/A.tmb/a.txt"
        )
        XCTAssertEqual(
            linked.relocating("/Volumes/Archive/.TextMouth/Library/A.tmb/a.txt", to: destination),
            "/Volumes/New/.TextMouth/Library/A.tmb/a.txt"
        )
        XCTAssertEqual(linked.relocating("/Users/reader/Data", to: destination), "/Volumes/New/.TextMouth")
        XCTAssertNil(linked.relocating("/Users/reader/Database/a.txt", to: destination))
        XCTAssertNil(linked.relocating("/Users/reader/Books/a.txt", to: destination))
        XCTAssertTrue(linked.contains("/Volumes/Archive/.TextMouth/library.json"))
        XCTAssertFalse(linked.contains("/Volumes/Archive/.TextMouthOld/library.json"))
    }

    // MARK: - Paths Captured Before a Move

    /// Until a move publishes, every path is kept as it is: there is no
    /// earlier data directory for it to have been captured in.
    func testPathsAreKeptUntilAMovePublishes() throws {
        let root = try makeSandboxDirectory("RebaseNoMove")
        let boundary = StorageBoundary(root: root)
        let inside = root.appendingPathComponent("Library/A.tmb/a.txt").path

        XCTAssertEqual(boundary.rebasedToCurrent(inside), inside)
        XCTAssertEqual(boundary.rebasedToCurrent("/Users/reader/Books/a.txt"), "/Users/reader/Books/a.txt")
    }

    /// After a move, a path captured in the old data directory moves to the
    /// same place in the new one; a path already in the new one, or outside
    /// both, is kept.
    func testAPathCapturedBeforeAMoveMovesToTheNewDataDirectory() throws {
        let old = try makeSandboxDirectory("RebaseOld")
        let new = try makeSandboxDirectory("RebaseNew")
        let boundary = StorageBoundary(root: old)
        boundary.publish(root: new)

        XCTAssertEqual(
            boundary.rebasedToCurrent(old.appendingPathComponent("Library/Shelf/A.tmb/a.txt").path),
            new.appendingPathComponent("Library/Shelf/A.tmb/a.txt").path
        )
        let alreadyThere = new.appendingPathComponent("Library/B.tmb/b.txt").path
        XCTAssertEqual(boundary.rebasedToCurrent(alreadyThere), alreadyThere)
        XCTAssertEqual(boundary.rebasedToCurrent("/Users/reader/Books/a.txt"), "/Users/reader/Books/a.txt")
    }

    /// A path spelled through the folder an old data directory's link led to
    /// moves too.
    func testAPathSpelledThroughTheOldLinkMovesToo() throws {
        let scratch = try makeSandboxDirectory("RebaseLink")
        let real = scratch.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let new = scratch.appendingPathComponent("New", isDirectory: true)
        let boundary = StorageBoundary(root: link)
        boundary.publish(root: new)

        let throughLink = real.resolvingSymlinksInPath().appendingPathComponent("Library/A.tmb/a.txt").path
        XCTAssertEqual(boundary.rebasedToCurrent(throughLink), new.appendingPathComponent("Library/A.tmb/a.txt").path)
    }

    /// Moving away and back: a path captured in the folder moved away to
    /// returns to the first one, and a path in the first one is kept.
    func testAPathFollowsTheDataDirectoryBack() throws {
        let first = try makeSandboxDirectory("RebaseFirst")
        let second = try makeSandboxDirectory("RebaseSecond")
        let boundary = StorageBoundary(root: first)
        boundary.publish(root: second)
        boundary.publish(root: first)

        XCTAssertEqual(
            boundary.rebasedToCurrent(second.appendingPathComponent("Library/A.tmb/a.txt").path),
            first.appendingPathComponent("Library/A.tmb/a.txt").path
        )
        let inFirst = first.appendingPathComponent("Library/B.tmb/b.txt").path
        XCTAssertEqual(boundary.rebasedToCurrent(inFirst), inFirst)
    }

    /// A book captured before a move gets its file path in the new data
    /// directory and keeps everything else; a library's books move
    /// together, and the count says how many did.
    func testBooksAndALibraryCapturedBeforeAMoveMove() throws {
        let old = try makeSandboxDirectory("RebaseLibraryOld")
        let new = try makeSandboxDirectory("RebaseLibraryNew")
        let boundary = StorageBoundary(root: old)
        let inOld = Book(
            title: "Harbor Pilot Notes",
            format: .txt,
            filePath: old.appendingPathComponent("Library/Shelf/A.tmb/a.txt").path,
            md5Hash: "a",
            folderPath: "Shelf",
            tmbDirectoryName: "A.tmb"
        )
        let elsewhere = Book(title: "Loose Notes", format: .txt, filePath: "/Users/reader/Books/b.txt", md5Hash: "b")
        var library = Library()
        library.books = [inOld, elsewhere]
        boundary.publish(root: new)

        let rebased = boundary.rebasedToCurrent(inOld)
        let moved = boundary.rebaseToCurrent(&library)

        XCTAssertEqual(rebased.filePath, new.appendingPathComponent("Library/Shelf/A.tmb/a.txt").path)
        var expected = inOld
        expected.filePath = rebased.filePath
        XCTAssertEqual(rebased, expected, "only the file path changes")
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(library.books.map(\.filePath), [rebased.filePath, elsewhere.filePath])
    }
}
