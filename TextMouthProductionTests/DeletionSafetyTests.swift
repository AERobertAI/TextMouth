import XCTest
@testable import TextMouth

/// Regression coverage for non-destructive Trash failures.
final class DeletionSafetyTests: XCTestCase {
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
