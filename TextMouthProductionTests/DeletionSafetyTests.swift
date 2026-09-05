import XCTest
@testable import TextMouth

/// Regression coverage for non-destructive Trash failures.
@MainActor
final class DeletionSafetyTests: XCTestCase {
    /// A failed legacy migration must never turn Remove Book into deletion of
    /// Library or one of its folders. Validate without invoking Trash.
    func testLegacyBookWithoutPackageNameIsRejectedAsDeletionTarget() {
        var book = makeBook(title: "Legacy")
        book.tmbDirectoryName = ""
        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book))
        book.folderPath = "Essays"
        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book))
    }

    /// Traversal and unrelated content paths must fail the same production
    /// guard used immediately before deleting a package.
    func testDeletionRejectsTraversalAndMismatchedContent() {
        var book = makeBook(title: "Invalid Path")
        book.tmbDirectoryName = "../Outside.tmb"
        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book))
        book.tmbDirectoryName = "Book.tmb"
        book.folderPath = ".."
        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book))
        book.folderPath = ""
        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book))
    }

    /// A package symlink must not redirect deletion outside the managed root.
    func testDeletionRejectsPackageSymlinkOutsideLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("Library")
        let outside = root.appendingPathComponent("Outside.tmb")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = library.appendingPathComponent("Alias.tmb")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        var book = makeBook(title: "Alias")
        book.tmbDirectoryName = "Alias.tmb"
        book.filePath = alias.appendingPathComponent("book.txt").path

        XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(book, libraryDirectory: library))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// Ordinary managed packages retain their existing deletion path.
    func testDeletionAcceptsManagedPackage() throws {
        var book = makeBook(title: "Managed")
        book.filePath = book.tmbDirectory.appendingPathComponent("book.txt").path
        XCTAssertEqual(
            try FileImportService.managedPackageURLForDeletion(book),
            book.tmbDirectory.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testTrashFailureNeverFallsBackToPermanentDeletion() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep me".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = ConfigService.shared
        let previous = service.config.moveToTrashInsteadOfDeleting
        service.config.moveToTrashInsteadOfDeleting = true
        defer { service.config.moveToTrashInsteadOfDeleting = previous }
        var permanentRemovalCalled = false

        XCTAssertThrowsError(
            try FileImportService.removeItemRespectingTrashSetting(
                at: file,
                trashItem: { _ in throw SimulatedTrashError() },
                removeItem: { _ in permanentRemovalCalled = true }
            )
        )

        XCTAssertFalse(permanentRemovalCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFailedPackageDeletionKeepsBookInLibrary() {
        let book = makeBook(title: "Cannot Delete")
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [book])

        viewModel.performRemoveBooks(
            [book],
            deleteTMB: true,
            deletePackage: { _ in throw SimulatedTrashError() }
        )

        XCTAssertEqual(viewModel.library.books.map(\.id), [book.id])
        XCTAssertTrue(viewModel.showError)
        XCTAssertTrue(viewModel.errorMessage?.contains("remain in the library") == true)
    }

    func testPartialDeletionRemovesOnlySuccessfullyDeletedBooks() {
        let removable = makeBook(title: "Removed")
        let retained = makeBook(title: "Retained")
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [removable, retained])

        viewModel.performRemoveBooks(
            [removable, retained],
            deleteTMB: true,
            deletePackage: { book in
                if book.id == retained.id { throw SimulatedTrashError() }
            }
        )

        XCTAssertEqual(viewModel.library.books.map(\.id), [retained.id])
    }

    private func makeBook(title: String) -> Book {
        Book(
            title: title,
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString,
            tmbDirectoryName: "\(UUID().uuidString).tmb"
        )
    }
}

private struct SimulatedTrashError: Error {}
