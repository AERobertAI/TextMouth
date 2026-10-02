import XCTest
@testable import TextMouth

/// What the library's removals say they did matches what they did to the
/// files, in the mode the Trash preference chooses (TODO A08). Removals that
/// must fail are refused by the deletion guard before anything on disk is
/// touched, so no test here ever sends a file to the real Trash.
@MainActor
final class RemovalOutcomeTests: XCTestCase {
    // MARK: - Preferences

    /// The model reads both removal preferences from config.json's fields.
    func testModelReadsTheRemovalPreferences() {
        withRemovalPreferences(confirmsFirst: false, movesToTrash: true) {
            XCTAssertEqual(
                LibraryViewModel(initializeServices: false).removalPreferences,
                RemovalPreferences(confirmsFirst: false, movesToTrash: true)
            )
        }
    }

    // MARK: - Delete Everything

    /// Delete Everything names what stayed in the library in the words of
    /// the mode in force: not moved to the Trash, or not deleted.
    func testDeleteEverythingFailureSpeaksInTheModeInForce() {
        for movesToTrash in [true, false] {
            withRemovalPreferences(confirmsFirst: true, movesToTrash: movesToTrash) {
                let folder = BookFolder(name: "Shelf-\(UUID().uuidString)")
                let book = unpackagedBook("Loose Pages", in: folder.fullPath)
                let model = LibraryViewModel(initializeServices: false)
                model.library = Library(books: [book], folders: [folder])

                model.removeFolderAndEverything(folder)

                let heading = movesToTrash
                    ? "This item could not be moved to the Trash and remains in the library:"
                    : "This item could not be deleted and remains in the library:"
                XCTAssertTrue(model.showError)
                XCTAssertEqual(model.errorMessage, heading + "\nLoose Pages: " + deletionRefusal(of: book))
                XCTAssertEqual(model.library.books.map(\.id), [book.id], "the book stays")
                XCTAssertEqual(model.library.folders.map(\.id), [folder.id], "so does its folder")
            }
        }
    }

    // MARK: - Fixtures

    /// Runs `body` with the two removal preferences set as given, then puts
    /// back the values it found.
    private func withRemovalPreferences(
        confirmsFirst: Bool,
        movesToTrash: Bool,
        _ body: () throws -> Void
    ) rethrows {
        let service = ConfigService.shared
        let previous = RemovalPreferences(service.config)
        service.config.confirmBeforeDelete = confirmsFirst
        service.config.moveToTrashInsteadOfDeleting = movesToTrash
        defer {
            service.config.confirmBeforeDelete = previous.confirmsFirst
            service.config.moveToTrashInsteadOfDeleting = previous.movesToTrash
        }
        try body()
    }

    /// A book with no package name, which the deletion guard refuses before
    /// anything on disk is touched.
    private func unpackagedBook(_ title: String, in folderPath: String = "") -> Book {
        Book(
            title: title,
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: ""
        )
    }

    /// The reason the deletion guard gives for refusing `book`.
    private func deletionRefusal(of book: Book) -> String {
        do {
            _ = try FileImportService.managedPackageURLForDeletion(book)
        } catch {
            return error.localizedDescription
        }
        XCTFail("The deletion guard accepted \(book.title), which has no package name")
        return ""
    }
}
