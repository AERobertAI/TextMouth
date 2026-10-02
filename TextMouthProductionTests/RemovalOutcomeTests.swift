import Combine
import SwiftUI
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

    /// The shared preferences model, which the library's views, its Remove
    /// Book dialog, and the menu bar word removal from, publishes when a
    /// removal preference changes and stays quiet when another setting does.
    func testSharedModelPublishesOnlyRemovalPreferenceChanges() {
        let service = ConfigService.shared
        let model = RemovalPreferencesModel.shared
        let savedBookID = service.config.lastOpenedBookID
        let savedTrash = service.config.moveToTrashInsteadOfDeleting
        defer {
            service.config.lastOpenedBookID = savedBookID
            service.config.moveToTrashInsteadOfDeleting = savedTrash
        }
        var published: [RemovalPreferences] = []
        let subscription = model.$preferences.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        service.config.lastOpenedBookID = UUID().uuidString
        XCTAssertTrue(published.isEmpty, "another setting publishes nothing")

        service.config.moveToTrashInsteadOfDeleting.toggle()
        XCTAssertEqual(published, [RemovalPreferences(service.config)])
        XCTAssertEqual(model.preferences, RemovalPreferences(service.config))
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

    // MARK: - Duplicate Finder

    /// With "Confirm before removing a book" on, the Duplicate Finder asks
    /// first, in the words of the deleting mode, and removes nothing until
    /// the user confirms; with it off, it removes at once.
    func testDuplicateFinderAsksFirstWhenThePreferenceIsOn() throws {
        let books = [unpackagedBook("Atlas"), unpackagedBook("Atlas, Second Copy")]

        XCTAssertEqual(
            DuplicateRemoval.firstStep(
                removing: books,
                preferences: RemovalPreferences(confirmsFirst: true, movesToTrash: true)
            ),
            .confirm(RemovalWording(.moveToTrash, books: books))
        )
        let permanent = DuplicateRemoval.firstStep(
            removing: books,
            preferences: RemovalPreferences(confirmsFirst: true, movesToTrash: false)
        )
        guard case .confirm(let wording) = permanent else {
            return XCTFail("Expected a confirmation, got \(permanent)")
        }
        XCTAssertEqual(wording.confirmationTitle, "Delete 2 Books Permanently?")
        XCTAssertEqual(wording.buttonTitle, "Delete 2 Books Permanently")
        XCTAssertEqual(
            DuplicateRemoval.firstStep(
                removing: books,
                preferences: RemovalPreferences(confirmsFirst: false, movesToTrash: true)
            ),
            .removeNow
        )
    }

    /// The Duplicate Finder removes through the library's Trash-aware path:
    /// with the Trash preference off, a real package is deleted permanently
    /// and the outcome says so, in place, with no library alert. Books that
    /// are no longer in the library are skipped.
    func testDuplicateFinderRemovesThroughTheTrashAwarePath() throws {
        try withRemovalPreferences(confirmsFirst: true, movesToTrash: false) {
            let book = try makePackagedBook("Twice Imported")
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library(books: [book])

            XCTAssertEqual(DuplicateRemoval.remove([UUID()], from: model), .success(nil))
            let outcome = DuplicateRemoval.remove([book.id], from: model)

            XCTAssertEqual(outcome, .success("Deleted “Twice Imported” permanently."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
            XCTAssertTrue(model.library.books.isEmpty)
            XCTAssertFalse(model.showError)
        }
    }

    /// VoiceOver hears each removal button say exactly what it does: the
    /// Duplicate Finder's and the library edit bar's. SwiftUI may build
    /// accessibility elements for its buttons only for a connected assistive
    /// app; when it exposes none here, the test is skipped, and the labels
    /// are still covered by the wording tests.
    func testRemovalButtonLabelsReachAccessibility() throws {
        let buttons = VStack {
            DuplicateRemovalButton(wording: RemovalWording(.moveToTrash, count: 2), action: {})
            EditModeBar(
                selectedCount: 2,
                totalCount: 5,
                removalPreferences: RemovalPreferences(confirmsFirst: false, movesToTrash: false),
                onSelectAll: {},
                onDeselectAll: {},
                onMove: {},
                onRemove: {},
                onDone: {}
            )
        }

        try withHostedControls(buttons) { controls in
            let labels = controls.filter { $0.role == .button }.map(\.label)
            guard !labels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertTrue(labels.contains("Move 2 selected books to the Trash"), "\(labels)")
            XCTAssertTrue(labels.contains("Delete 2 books permanently"), "\(labels)")
        }
    }

    // MARK: - Menu Bar

    /// The menu bar the running app draws titles its Remove command by the
    /// removal preferences, and retitles it when they change. Skipped when
    /// this run's menu bar has no Library menu with that command.
    func testMenuBarRemoveCommandFollowsThePreferences() throws {
        let combinations = [true, false].flatMap { confirmsFirst in
            [true, false].map { RemovalPreferences(confirmsFirst: confirmsFirst, movesToTrash: $0) }
        }
        let possibleTitles = Set(combinations.map { LibraryRemoveCommandWording.menuBarTitle(preferences: $0) })

        /// The Remove command's title in the Library menu, read afresh each
        /// time, after asking the menu to bring its items up to date as it
        /// does before it opens.
        func removeCommandTitle() -> String? {
            guard let libraryMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Library" })?.submenu else {
                return nil
            }
            libraryMenu.delegate?.menuNeedsUpdate?(libraryMenu)
            return libraryMenu.items.first { possibleTitles.contains($0.title) }?.title
        }
        guard removeCommandTitle() != nil else {
            throw XCTSkip("This run's menu bar has no Library menu with a Remove command")
        }

        for preferences in combinations {
            withRemovalPreferences(confirmsFirst: preferences.confirmsFirst, movesToTrash: preferences.movesToTrash) {
                let expected = LibraryRemoveCommandWording.menuBarTitle(preferences: preferences)
                XCTAssertTrue(
                    waitUntil(timeout: 3) { removeCommandTitle() == expected },
                    "Expected “\(expected)”; the menu shows “\(removeCommandTitle() ?? "nothing")”"
                )
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
