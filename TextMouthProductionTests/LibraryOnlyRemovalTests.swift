import XCTest
@testable import TextMouth

/// Remove from Library Only takes a book out of the library for good while
/// its package and content file stay on disk for a later re-import (TODO
/// S06). A removedFromLibrary.json marker, written into the package before
/// the row is removed, is what keeps the book out. Tests use real packages
/// in the isolated test root and restore its library index afterwards.
final class LibraryOnlyRemovalTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Directories this test created, removed after it with everything inside.
    private var createdDirectories: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdDirectories = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
        for directory in createdDirectories {
            Self.forceRemove(directory)
        }
    }

    // MARK: - The Marker

    /// A marker retires the book it names and no other. One that cannot be
    /// read retires any book, because only a removal writes it. A package
    /// without one retires nothing.
    func testMarkerRetiresOnlyTheBookItNames() throws {
        let package = try makeScratchPackage()
        let removed = fixtureBook(title: "Named Removal")
        let neighbour = fixtureBook(title: "Shared Package Neighbour")
        XCTAssertFalse(RemovedFromLibraryMarker.retires(removed.id, in: package))

        try RemovedFromLibraryMarker(book: removed).write(into: package)
        XCTAssertTrue(RemovedFromLibraryMarker.retires(removed.id, in: package))
        XCTAssertFalse(RemovedFromLibraryMarker.retires(neighbour.id, in: package))

        try Data("not a marker".utf8).write(to: TextMouthPaths.removedFromLibraryMarkerPath(in: package))
        XCTAssertTrue(RemovedFromLibraryMarker.retires(removed.id, in: package))
        XCTAssertTrue(RemovedFromLibraryMarker.retires(neighbour.id, in: package))
    }

    /// The marker is a readable file beside bookInfo.json that names the
    /// book, its title and author, and when it was removed.
    func testMarkerRecordsTheBookAndWhenItWasRemoved() throws {
        let package = try makeScratchPackage()
        let book = fixtureBook(title: "Recorded Removal")
        let removedAt = Date(timeIntervalSince1970: 1_790_000_000)

        try RemovedFromLibraryMarker(book: book, removedAt: removedAt).write(into: package)

        let url = package.appendingPathComponent("removedFromLibrary.json")
        XCTAssertEqual(TextMouthPaths.removedFromLibraryMarkerPath(in: package), url)
        let marker = try RemovedFromLibraryMarker.read(in: package)
        XCTAssertEqual(marker.bookID, book.id)
        XCTAssertEqual(marker.title, "Recorded Removal")
        XCTAssertEqual(marker.author, "Test Fixture")
        XCTAssertEqual(marker.removedAt, removedAt)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(book.id.uuidString), text)
    }

    /// A record without a package name resolves to its folder rather than a
    /// package, so it is never retired, whatever that folder holds.
    func testRecordWithoutAPackageIsNeverRetired() throws {
        let folder = uniqueFolderName("Legacy Shelf")
        let folderDirectory = try makeFolder(folder)
        var legacy = fixtureBook(title: "Legacy Record")
        legacy.folderPath = folder
        legacy.tmbDirectoryName = ""
        try RemovedFromLibraryMarker(book: legacy).write(into: folderDirectory)

        XCTAssertTrue(RemovedFromLibraryMarker.retires(legacy.id, in: folderDirectory))
        XCTAssertFalse(RemovedFromLibraryMarker.retires(legacy))
    }

    // MARK: - Fixtures

    /// A folder name unique to this test, so leftovers in the shared test
    /// root cannot collide with it.
    private func uniqueFolderName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Creates a top-level folder directory in the test root's library and
    /// schedules it, with everything inside, for removal.
    @discardableResult
    private func makeFolder(_ folder: String) throws -> URL {
        let directory = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// A package directory outside the library, for checks of the marker
    /// on its own.
    private func makeScratchPackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryOnlyRemoval-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Scratch.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return package
    }

    /// A book record that no package on disk holds.
    private func fixtureBook(title: String) -> Book {
        Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: "/nonexistent/library-only-removal/\(UUID().uuidString).txt",
            md5Hash: "library-only-removal-\(UUID().uuidString)",
            tmbDirectoryName: "LibraryOnlyRemoval-\(UUID().uuidString).tmb"
        )
    }

    /// Removes `url` and everything inside it, first unlocking files and
    /// giving directories their write permission back, since some tests
    /// lock a record or make a package read-only.
    private static func forceRemove(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                try? fileManager.setAttributes([.immutable: false], ofItemAtPath: item.path)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    chmod(item.path, 0o755)
                }
            }
        }
        try? fileManager.removeItem(at: url)
    }
}
