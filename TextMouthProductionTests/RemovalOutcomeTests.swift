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

    // MARK: - Remove & Delete

    /// Remove & Delete reports what it did in the words of the mode in
    /// force, and raises no alert of its own.
    func testRemoveAndDeleteReportsTheModesCompletion() {
        for movesToTrash in [true, false] {
            withRemovalPreferences(confirmsFirst: true, movesToTrash: movesToTrash) {
                let books = [unpackagedBook("Atlas"), unpackagedBook("Bestiary")]
                let model = LibraryViewModel(initializeServices: false)
                model.library = Library(books: books)
                var deleted: [UUID] = []

                let outcome = model.removeBooksAndDeleteReturningOutcome(books) { deleted.append($0.id) }

                XCTAssertEqual(
                    outcome,
                    .success(movesToTrash ? "Moved 2 books to the Trash." : "Deleted 2 books permanently.")
                )
                XCTAssertEqual(deleted, books.map(\.id))
                XCTAssertTrue(model.library.books.isEmpty)
                XCTAssertFalse(model.showError)
            }
        }
    }

    /// When some books stay, the report says what was removed and then which
    /// books stayed and why. The plain form, which the library's Remove &
    /// Delete uses, shows the same words through the library's alert.
    func testRemoveAndDeleteReportsTheBooksThatStayed() {
        withRemovalPreferences(confirmsFirst: true, movesToTrash: true) {
            let removable = unpackagedBook("Kept Out")
            let stuck = unpackagedBook("Stuck")
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library(books: [removable, stuck])
            let refusingStuck: (Book) throws -> Void = { book in
                if book.id == stuck.id { throw DeletionRefused() }
            }

            let outcome = model.removeBooksAndDeleteReturningOutcome([removable, stuck], deletePackage: refusingStuck)

            let stayed = "This book could not be moved to the Trash and remains in the library:\n"
                + "Stuck: The volume is read-only."
            XCTAssertEqual(outcome, .failure("Moved “Kept Out” to the Trash.\n\n" + stayed))
            XCTAssertEqual(model.library.books.map(\.id), [stuck.id])
            XCTAssertFalse(model.showError)

            model.performRemoveBooks([stuck], deleteTMB: true, deletePackage: refusingStuck)

            XCTAssertTrue(model.showError)
            XCTAssertEqual(model.errorMessage, stayed)
        }
    }

    /// With the Trash preference off, Remove & Delete deletes a real package
    /// permanently through the library's Trash-aware deletion path, and says
    /// so. (With it on, that path would use the real Trash, so it is not
    /// driven; the wording tests cover what it says.)
    func testRemoveAndDeleteDeletesARealPackagePermanentlyWhenTrashIsOff() throws {
        try withRemovalPreferences(confirmsFirst: true, movesToTrash: false) {
            let book = try makePackagedBook("Ephemeral Notes")
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library(books: [book])

            let outcome = model.removeBooksAndDeleteReturningOutcome([book])

            XCTAssertEqual(outcome, .success("Deleted “Ephemeral Notes” permanently."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
            XCTAssertTrue(model.library.books.isEmpty)
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

    /// A managed book with a real package at the top of the test root's
    /// library, removed when the test ends if it is still there.
    private func makePackagedBook(_ title: String) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "RemovalFixture-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let content = package.appendingPathComponent("book.txt")
        try Data("Removal fixture".utf8).write(to: content)
        let book = Book(
            title: title,
            format: .txt,
            filePath: content.path,
            md5Hash: "removal-\(UUID().uuidString)",
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }
}

/// A deletion failure with a fixed reason, so messages compare word for word.
private struct DeletionRefused: LocalizedError {
    var errorDescription: String? { "The volume is read-only." }
}
