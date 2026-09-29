import XCTest
@testable import TextMouth

/// Regression coverage for filesystem-first library move transactions.
@MainActor
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

    // MARK: - Refused Folder Removal

    /// A subfolder name already used at the destination refuses the whole
    /// removal before anything moves, and the message names the clash.
    func testRefusedRemovalForDuplicateSubfolderNameLeavesModelAndDiskUntouched() throws {
        let old = uniqueFolder("Old")
        let target = uniqueFolder("Target")
        defer { cleanup([old, target]) }

        let message = try refusedRemovalMessage(
            folders: [old, "\(old)/Sub", target, "\(target)/Sub"],
            bookIn: "\(old)/Sub",
            removing: old,
            into: target
        )

        XCTAssertEqual(
            message,
            "Could not delete \"\(old)\" and move its contents: "
                + "A folder named \"Sub\" already exists in \"\(target)\"."
        )
    }

    /// Choosing the removed folder's own subfolder as the destination is
    /// refused without touching the model or the disk.
    func testRefusedRemovalIntoItsOwnSubfolderLeavesModelAndDiskUntouched() throws {
        let old = uniqueFolder("Old")
        defer { cleanup([old]) }

        let message = try refusedRemovalMessage(
            folders: [old, "\(old)/Sub"],
            bookIn: "\(old)/Sub",
            removing: old,
            into: "\(old)/Sub"
        )

        XCTAssertEqual(
            message,
            "Could not delete \"\(old)\" and move its contents: Choose a destination outside "
                + "\"\(old)\". \"\(old)/Sub\" is that folder or one of its subfolders."
        )
    }

    /// Contents that would end up deeper than the folder limit are refused
    /// without touching the model or the disk.
    func testRefusedRemovalBeyondTheDepthLimitLeavesModelAndDiskUntouched() throws {
        let old = uniqueFolder("Old")
        let deep = uniqueFolder("Deep")
        defer { cleanup([old, deep]) }

        let message = try refusedRemovalMessage(
            folders: [old, "\(old)/B", "\(old)/B/C", deep, "\(deep)/Y", "\(deep)/Y/Z"],
            bookIn: "\(old)/B/C",
            removing: old,
            into: "\(deep)/Y/Z"
        )

        XCTAssertEqual(
            message,
            "Could not delete \"\(old)\" and move its contents: That would place "
                + "\"\(deep)/Y/Z/B/C\" 5 levels deep, but folders can be nested at most 4 levels."
        )
    }

    /// Creates `folderPaths` as real folders through the view model, files one
    /// managed book in `bookFolder`, asks to remove `removed` into
    /// `destination`, and asserts the refusal left folders, books, sort
    /// settings, directories, and package files exactly as they were.
    /// Returns the error message shown to the user.
    private func refusedRemovalMessage(
        folders folderPaths: [String],
        bookIn bookFolder: String,
        removing removed: String,
        into destination: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String? {
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library()
        for path in folderPaths {
            viewModel.createFolder(
                name: (path as NSString).lastPathComponent,
                parentPath: (path as NSString).deletingLastPathComponent
            )
        }
        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), folderPaths, file: file, line: line)
        viewModel.library.books = [try makeManagedBook(folderPath: bookFolder)]
        let folder = try XCTUnwrap(
            viewModel.library.folders.first { $0.fullPath == removed },
            file: file,
            line: line
        )
        let topLevelFolders = Set(folderPaths.map { $0.components(separatedBy: "/")[0] })
        let modelBefore = viewModel.library
        let diskBefore = diskSnapshot(of: topLevelFolders)

        viewModel.removeFolderMovingContents(folder, toPath: destination)

        XCTAssertTrue(viewModel.showError, file: file, line: line)
        XCTAssertEqual(viewModel.library.folders, modelBefore.folders, file: file, line: line)
        XCTAssertEqual(viewModel.library.books, modelBefore.books, file: file, line: line)
        XCTAssertEqual(
            viewModel.library.folderSortSettings,
            modelBefore.folderSortSettings,
            file: file,
            line: line
        )
        XCTAssertEqual(diskSnapshot(of: topLevelFolders), diskBefore, file: file, line: line)
        return viewModel.errorMessage
    }

    /// Every directory and file below the given top-level library folders,
    /// keyed by relative path, with file contents (directories map to empty
    /// data). Equal snapshots prove an edit neither moved, created, deleted,
    /// nor rewrote anything there.
    private func diskSnapshot(of folderPaths: Set<String>) -> [String: Data] {
        let fileManager = FileManager.default
        var snapshot: [String: Data] = [:]
        for folderPath in folderPaths {
            let root = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(atPath: root.path) else { continue }
            snapshot[folderPath] = Data()
            while let relative = enumerator.nextObject() as? String {
                let url = root.appendingPathComponent(relative)
                snapshot[folderPath + "/" + relative] = fileManager.contents(atPath: url.path) ?? Data()
            }
        }
        return snapshot
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
