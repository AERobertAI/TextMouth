import XCTest
@testable import TextMouth

/// Regression coverage for filesystem-first library move transactions.
final class LibraryMoveTransactionTests: XCTestCase {
    func testBookMoveCommitsModelPathAndBookInfoAfterDiskMove() throws {
        let sourceFolder = uniqueFolder("Source")
        let destinationFolder = uniqueFolder("Destination")
        var book = try makeManagedBook(folderPath: sourceFolder)
        defer { cleanup([sourceFolder, destinationFolder]) }
        let oldPackage = book.tmbDirectory
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book])

        viewModel.moveBooks([book], toFolder: destinationFolder)

        book = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(book.folderPath, destinationFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPackage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        let info = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(info.metadata.folderPath, destinationFolder)
    }

    func testBookMoveFailureLeavesModelAndSourcePackageUntouched() throws {
        let sourceFolder = uniqueFolder("Source")
        let destinationFolder = uniqueFolder("Destination")
        let book = try makeManagedBook(folderPath: sourceFolder)
        defer { cleanup([sourceFolder, destinationFolder]) }
        let collision = TextMouthPaths.tmbPath(
            folderPath: destinationFolder,
            tmbName: book.tmbDirectoryName
        )
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book])

        viewModel.moveBooks([book], toFolder: destinationFolder)

        let stored = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(stored.folderPath, sourceFolder)
        XCTAssertEqual(stored.filePath, book.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(viewModel.showError)
    }

    func testFolderRenamePersistsNewBookInfoLocation() throws {
        let oldName = uniqueFolder("Old")
        let newName = uniqueFolder("New")
        let folder = BookFolder(name: oldName)
        let book = try makeManagedBook(folderPath: oldName)
        defer { cleanup([oldName, newName]) }
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book], folders: [folder])

        viewModel.renameFolder(folder, to: newName)

        let moved = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(moved.folderPath, newName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.filePath))
        XCTAssertEqual(try BookInfo.load(from: moved.tmbDirectory).metadata.folderPath, newName)
    }

    func testFolderRemovalFailureDoesNotDeleteOrReassignBooks() throws {
        let folderPath = uniqueFolder("FolderToKeep")
        let folder = BookFolder(name: folderPath)
        let book = try makeManagedBook(folderPath: folderPath)
        defer { cleanup([folderPath]) }
        let rootCollision = TextMouthPaths.tmbPath(
            folderPath: "",
            tmbName: book.tmbDirectoryName
        )
        try FileManager.default.createDirectory(at: rootCollision, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootCollision) }
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book], folders: [folder])

        viewModel.removeFolderMovingContents(folder, toPath: "")

        XCTAssertEqual(viewModel.library.folders.map(\.id), [folder.id])
        XCTAssertEqual(viewModel.library.books.first?.folderPath, folderPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(viewModel.showError)
    }

    private func makeManagedBook(folderPath: String) throws -> Book {
        try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("move transaction".utf8).write(to: content)
        let book = Book(
            title: "Movable Book",
            format: .txt,
            filePath: content.path,
            md5Hash: try FileImportService.md5Hash(of: content),
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    private func uniqueFolder(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private func cleanup(_ folderPaths: [String]) {
        for path in folderPaths {
            let url = TextMouthPaths.libraryDir.appendingPathComponent(path, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
