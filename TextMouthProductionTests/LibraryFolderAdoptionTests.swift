import XCTest
@testable import TextMouth

/// When the library index cannot be read, folder rows are rebuilt from the
/// folders on disk, so books stay reachable from the Folders view and Rebuild
/// Library Index keeps the folder structure the disk still records (TODO S01).
/// Every test works inside a disposable temporary library directory.
final class LibraryFolderAdoptionTests: XCTestCase {
    private var root: URL!
    private var libraryDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthFolderAdoption-\(UUID().uuidString)", isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Folder directories become rows, parents before children, while
    /// packages, their contents, hidden staging directories, and paths deeper
    /// than a folder row can be are left out.
    func testFolderDirectoriesBecomeRowsParentsFirst() throws {
        try makeDirectories([
            "Fiction/Space Opera/Voyage.tmb/cachedAudio",
            "Empty Shelf",
            "Deep/A/B/C/D",
            ".import-staging.tmb",
            "Fiction/.textmouth-rename-staging"
        ])
        try Data("not a folder".utf8).write(to: libraryDirectory.appendingPathComponent("Fiction/notes.txt"))
        var library = Library()

        let added = FileImportService.adoptLibraryFolders(library: &library, libraryDirectory: libraryDirectory)

        let expected: Set<String> = [
            "Fiction", "Fiction/Space Opera", "Empty Shelf", "Deep", "Deep/A", "Deep/A/B", "Deep/A/B/C"
        ]
        XCTAssertEqual(Set(library.folders.map(\.fullPath)), expected)
        XCTAssertEqual(added, expected.count)
        var earlierPaths: Set<String> = [""]
        for folder in library.folders {
            XCTAssertTrue(earlierPaths.contains(folder.parentPath), "\(folder.fullPath) precedes its parent")
            earlierPaths.insert(folder.fullPath)
        }
    }

    /// A folder a book lives in gets a row, with its ancestors, even without
    /// a directory of its own.
    func testFoldersNamedByBooksGetRowsWithTheirAncestors() {
        var library = Library(books: [
            Book(title: "Nested", format: .txt, filePath: "/nonexistent/nested.txt",
                 md5Hash: "nested", folderPath: "Archive/Letters")
        ])

        FileImportService.adoptLibraryFolders(library: &library, libraryDirectory: libraryDirectory)

        XCTAssertEqual(library.folders.map(\.fullPath), ["Archive", "Archive/Letters"])
    }

    /// Left to the folders books name, as the startup repair of a library
    /// whose index records its folders asks, a book's folder gets a row with
    /// its ancestors, while the folder directories no book is in, at the top
    /// of the library or below the book's folder, stay out.
    func testOnlyTheFoldersBooksNameGetRowsWhenTheFoldersOnDiskDoNotCount() throws {
        try makeDirectories(["Deleted Shelf", "Archive/Letters/Drafts"])
        var library = Library(books: [
            Book(title: "Nested", format: .txt, filePath: "/nonexistent/nested.txt",
                 md5Hash: "nested", folderPath: "Archive/Letters")
        ])

        let added = FileImportService.adoptLibraryFolders(
            library: &library,
            libraryDirectory: libraryDirectory,
            includingFoldersOnDisk: false
        )

        XCTAssertEqual(library.folders.map(\.fullPath), ["Archive", "Archive/Letters"])
        XCTAssertEqual(added, 2)
    }

    /// Existing rows keep their identity, and a second run adds nothing.
    func testExistingRowsAreKeptAndASecondRunAddsNothing() throws {
        try makeDirectories(["Fiction/Space Opera"])
        let existing = BookFolder(name: "Fiction")
        var library = Library(folders: [existing])

        XCTAssertEqual(
            FileImportService.adoptLibraryFolders(library: &library, libraryDirectory: libraryDirectory),
            1
        )
        XCTAssertEqual(library.folders.first?.id, existing.id)
        XCTAssertEqual(library.folders.map(\.fullPath), ["Fiction", "Fiction/Space Opera"])
        XCTAssertEqual(
            FileImportService.adoptLibraryFolders(library: &library, libraryDirectory: libraryDirectory),
            0
        )
    }

    /// Creates each relative directory path under the library directory.
    private func makeDirectories(_ relativePaths: [String]) throws {
        for path in relativePaths {
            try FileManager.default.createDirectory(
                at: libraryDirectory.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
