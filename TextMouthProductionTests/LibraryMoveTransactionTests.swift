import XCTest
@testable import TextMouth

/// Regression coverage for filesystem-first library move transactions.
@MainActor
final class LibraryMoveTransactionTests: XCTestCase {
    func testBookMoveCommitsModelPathAndBookInfoAfterDiskMove() async throws {
        let sourceFolder = uniqueFolder("Source")
        let destinationFolder = uniqueFolder("Destination")
        var book = try makeManagedBook(folderPath: sourceFolder)
        defer { cleanup([sourceFolder, destinationFolder]) }
        let oldPackage = book.tmbDirectory
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book])

        await viewModel.moveBooks([book], toFolder: destinationFolder).value

        book = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(book.folderPath, destinationFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPackage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        let info = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(info.metadata.folderPath, destinationFolder)
    }

    func testBookMoveFailureLeavesModelAndSourcePackageUntouched() async throws {
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

        await viewModel.moveBooks([book], toFolder: destinationFolder).value

        let stored = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(stored.folderPath, sourceFolder)
        XCTAssertEqual(stored.filePath, book.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(viewModel.showError)
    }

    func testFolderRenamePersistsNewBookInfoLocation() async throws {
        let oldName = uniqueFolder("Old")
        let newName = uniqueFolder("New")
        let folder = BookFolder(name: oldName)
        let book = try makeManagedBook(folderPath: oldName)
        defer { cleanup([oldName, newName]) }
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book], folders: [folder])

        await viewModel.renameFolder(folder, to: newName).value

        let moved = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(moved.folderPath, newName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.filePath))
        XCTAssertEqual(try BookInfo.load(from: moved.tmbDirectory).metadata.folderPath, newName)
    }

    func testFolderRemovalFailureDoesNotDeleteOrReassignBooks() async throws {
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

        await viewModel.removeFolderMovingContents(folder, toPath: "").value

        XCTAssertEqual(viewModel.library.folders.map(\.id), [folder.id])
        XCTAssertEqual(viewModel.library.books.first?.folderPath, folderPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(viewModel.showError)
    }

    // MARK: - Spelling-Only Folder Renames

    /// A capitalization-only rename renames the folder's directory in place:
    /// the listing shows the new spelling, the package and subfolder stay
    /// inside it, and the book's path and package record follow. The case-
    /// insensitive rule is forced so the in-place path runs on any volume.
    func testCaseOnlyFolderRenameRespellsTheDirectoryOnDisk() async throws {
        let token = UUID().uuidString
        let oldName = "archive-\(token)"
        let newName = "Archive-\(token)"
        defer { cleanup([oldName, newName]) }
        let folder = BookFolder(name: oldName)
        let book = try makeManagedBook(folderPath: oldName)
        try TextMouthPaths.ensureLibrarySubfolder("\(oldName)/Sub")
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library(
            books: [book],
            folders: [folder, BookFolder(name: "Sub", parentPath: oldName)]
        )

        await FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
            await viewModel.renameFolder(folder, to: newName).value
        }

        XCTAssertFalse(viewModel.showError, viewModel.errorMessage ?? "")
        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), [newName, "\(newName)/Sub"])
        let listing = try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
        XCTAssertTrue(listing.contains(newName))
        XCTAssertFalse(listing.contains(oldName))
        XCTAssertFalse(listing.contains { $0.hasPrefix(".textmouth-rename-") })
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(newName).path
        )
        XCTAssertEqual(Set(contents), [book.tmbDirectoryName, "Sub"])

        let renamedBook = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertEqual(renamedBook.folderPath, newName)
        XCTAssertTrue(renamedBook.filePath.contains("/\(newName)/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedBook.filePath))
        XCTAssertEqual(try BookInfo.load(from: renamedBook.tmbDirectory).metadata.folderPath, newName)
    }

    /// Renaming a folder saved with a decomposed name to its composed
    /// spelling keeps one directory and leaves the package where it is.
    func testNormalizationOnlyFolderRenameKeepsThePackageInPlace() async throws {
        let token = UUID().uuidString
        let decomposed = "Cafe\u{301}-\(token)"
        let composed = "Caf\u{E9}-\(token)"
        defer { cleanup([composed]) }
        let folder = BookFolder(name: decomposed)
        let book = try makeManagedBook(folderPath: decomposed)
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library(books: [book], folders: [folder])

        await viewModel.renameFolder(folder, to: composed).value

        XCTAssertFalse(viewModel.showError, viewModel.errorMessage ?? "")
        XCTAssertTrue(BookFolder.spellingsMatch(try XCTUnwrap(viewModel.library.folders.first).name, composed))
        let renamedBook = try XCTUnwrap(viewModel.library.books.first)
        XCTAssertTrue(BookFolder.spellingsMatch(renamedBook.folderPath, composed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedBook.filePath))
        let listing = try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
        XCTAssertEqual(listing.filter { $0 == composed }.count, 1)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(composed).path
        )
        XCTAssertEqual(contents, [book.tmbDirectoryName])
    }

    /// When a package record cannot be rewritten, a capitalization-only
    /// rename is rolled back: the directory gets its old spelling again and
    /// the library keeps the old name.
    func testFailedCaseOnlyRenameRestoresTheDirectorySpelling() async throws {
        let token = UUID().uuidString
        let oldName = "ledger-\(token)"
        let newName = "Ledger-\(token)"
        defer { cleanup([oldName, newName]) }
        let folder = BookFolder(name: oldName)
        let book = try makeManagedBook(folderPath: oldName)
        // A directory where bookInfo.json belongs makes the rewrite fail.
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library(books: [book], folders: [folder])

        await FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
            await viewModel.renameFolder(folder, to: newName).value
        }

        XCTAssertTrue(viewModel.showError)
        XCTAssertEqual(viewModel.library.folders.map(\.name), [oldName])
        XCTAssertEqual(viewModel.library.books.first?.folderPath, oldName)
        let listing = try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
        XCTAssertTrue(listing.contains(oldName))
        XCTAssertFalse(listing.contains(newName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
    }

    /// The two-step fallback reaches the new spelling through a hidden
    /// temporary name, keeps the directory's contents, and leaves nothing
    /// behind.
    func testTwoStepRespellingFallbackRenamesTheDirectory() throws {
        let token = UUID().uuidString
        let oldName = "draft-\(token)"
        let newName = "Draft-\(token)"
        defer { cleanup([oldName, newName]) }
        try TextMouthPaths.ensureLibrarySubfolder("\(oldName)/Inner")

        XCTAssertTrue(try TextMouthPaths.respellLibrarySubfolder(
            from: oldName,
            to: newName,
            tryingDirectRenameFirst: false
        ))

        let listing = try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
        XCTAssertTrue(listing.contains(newName))
        XCTAssertFalse(listing.contains(oldName))
        XCTAssertFalse(listing.contains { $0.hasPrefix(".textmouth-rename-") })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent("\(newName)/Inner").path
        ))
    }

    /// The respelling helper leaves a missing directory alone rather than
    /// creating one, and refuses unsafe paths.
    func testRespellingHelperSkipsMissingDirectoriesAndRejectsUnsafePaths() throws {
        let missing = uniqueFolder("missing")
        XCTAssertFalse(try TextMouthPaths.respellLibrarySubfolder(from: missing, to: missing.uppercased()))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(missing).path
        ))
        XCTAssertThrowsError(try TextMouthPaths.respellLibrarySubfolder(from: "..", to: "Anything"))
        XCTAssertThrowsError(try TextMouthPaths.respellLibrarySubfolder(from: "", to: "Anything"))
    }

    // MARK: - Refused Folder Removal

    /// A subfolder name already used at the destination refuses the whole
    /// removal before anything moves, and the message names the clash.
    func testRefusedRemovalForDuplicateSubfolderNameLeavesModelAndDiskUntouched() async throws {
        let old = uniqueFolder("Old")
        let target = uniqueFolder("Target")
        defer { cleanup([old, target]) }

        let message = try await refusedRemovalMessage(
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
    func testRefusedRemovalIntoItsOwnSubfolderLeavesModelAndDiskUntouched() async throws {
        let old = uniqueFolder("Old")
        defer { cleanup([old]) }

        let message = try await refusedRemovalMessage(
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
    func testRefusedRemovalBeyondTheDepthLimitLeavesModelAndDiskUntouched() async throws {
        let old = uniqueFolder("Old")
        let deep = uniqueFolder("Deep")
        defer { cleanup([old, deep]) }

        let message = try await refusedRemovalMessage(
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
    ) async throws -> String? {
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

        await viewModel.removeFolderMovingContents(folder, toPath: destination).value

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
