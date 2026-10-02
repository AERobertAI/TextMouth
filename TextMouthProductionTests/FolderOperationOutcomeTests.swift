import XCTest
@testable import TextMouth

/// The folder edits and book moves the library's sheets start return what
/// actually happened, and present nothing themselves, so a sheet can stay
/// open with the reason after a refusal or a failed write (TODO A07). The
/// plain forms that other callers use still explain failures through the
/// library's error alert, in the same words. Fixtures live in the hosted
/// test root under unique names and are removed afterwards.
@MainActor
final class FolderOperationOutcomeTests: XCTestCase {
    // MARK: - The Outcome Type

    /// Each accessor reports its own part of an outcome, and a failure built
    /// from an error reads like the library's error alert.
    func testOutcomeAccessorsAndAlertStyleFailure() {
        XCTAssertTrue(OperationOutcome.success(nil).succeeded)
        XCTAssertNil(OperationOutcome.success(nil).message)
        XCTAssertEqual(OperationOutcome.success("Done.").message, "Done.")
        XCTAssertNil(OperationOutcome.success("Done.").failureMessage)

        let failure = OperationOutcome.failure("Could not move books", FolderOperationConflict.folderNotFound)
        XCTAssertFalse(failure.succeeded)
        XCTAssertEqual(failure.failureMessage, "Could not move books: " + FolderOperationConflict.folderNotFound.message)
        XCTAssertEqual(failure.message, failure.failureMessage)
    }

    /// A refused edit that would change nothing is a silent success, so a
    /// sheet simply closes; every other refusal is a failure that names it.
    func testRefusalsBecomeFailuresExceptAnUnchangedEdit() {
        XCTAssertEqual(LibraryViewModel.outcome(refusing: .unchanged, context: "Could not rename"), .success(nil))
        XCTAssertEqual(
            LibraryViewModel.outcome(refusing: .folderNotFound, context: "Could not rename \"Notes\""),
            .failure("Could not rename \"Notes\": " + FolderOperationConflict.folderNotFound.message)
        )
    }

    // MARK: - Rename

    /// A rename refused by a folder conflict returns the conflict, leaves the
    /// folders and their directories exactly as they were, and raises no
    /// library alert, which would otherwise appear behind the open sheet.
    func testRefusedRenameReturnsTheConflictAndChangesNothing() throws {
        let reports = uniqueFolder("Reports")
        let archive = uniqueFolder("Archive")
        let viewModel = try modelWithFolders([reports, archive])
        let before = viewModel.library.folders
        let folder = try XCTUnwrap(viewModel.library.folders.first { $0.fullPath == archive })

        let outcome = viewModel.renameFolderReturningOutcome(folder, to: reports)

        XCTAssertEqual(
            outcome,
            .failure("Could not rename \"\(archive)\": A folder named \"\(reports)\" already exists in Library Root.")
        )
        XCTAssertEqual(viewModel.library.folders, before)
        XCTAssertTrue(directoryExists(archive))
        XCTAssertFalse(viewModel.showError, "the sheet reports the failure, not the library alert")
        XCTAssertNil(viewModel.errorMessage)
    }

    /// A rename that works returns a success with nothing to say and renames
    /// the folder and its directory.
    func testRenameThatWorksReturnsSuccess() throws {
        let original = uniqueFolder("Original")
        let renamed = uniqueFolder("Renamed")
        let viewModel = try modelWithFolders([original])
        let folder = try XCTUnwrap(viewModel.library.folders.first)

        let outcome = viewModel.renameFolderReturningOutcome(folder, to: renamed)

        XCTAssertEqual(outcome, .success(nil))
        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), [renamed])
        XCTAssertTrue(directoryExists(renamed))
        XCTAssertFalse(directoryExists(original))
        XCTAssertFalse(viewModel.showError)
    }

    /// Renaming a folder to the name it already has changes nothing and is
    /// a silent success, as the plain form's silent no-op always was.
    func testRenamingToTheCurrentNameIsASilentSuccess() throws {
        let name = uniqueFolder("Same")
        let viewModel = try modelWithFolders([name])
        let folder = try XCTUnwrap(viewModel.library.folders.first)

        XCTAssertEqual(viewModel.renameFolderReturningOutcome(folder, to: "  \(name)  "), .success(nil))
        XCTAssertEqual(viewModel.library.folders, [folder])
        XCTAssertFalse(viewModel.showError)
    }

    /// The plain form still explains a refusal through the library's alert,
    /// in exactly the words the outcome carries.
    func testPlainRenameStillExplainsTheRefusalThroughTheAlert() throws {
        let reports = uniqueFolder("Reports")
        let archive = uniqueFolder("Archive")
        let viewModel = try modelWithFolders([reports, archive])
        let folder = try XCTUnwrap(viewModel.library.folders.first { $0.fullPath == archive })
        let expected = viewModel.renameFolderReturningOutcome(folder, to: reports).failureMessage

        viewModel.renameFolder(folder, to: reports)

        XCTAssertTrue(viewModel.showError)
        XCTAssertNotNil(expected)
        XCTAssertEqual(viewModel.errorMessage, expected)
    }

    // MARK: - Create

    /// Creating a folder whose name is taken returns the conflict and adds
    /// nothing.
    func testRefusedCreateReturnsTheConflict() throws {
        let reports = uniqueFolder("Reports")
        let viewModel = try modelWithFolders([reports])

        let outcome = viewModel.createFolderReturningOutcome(name: reports, parentPath: "")

        XCTAssertEqual(
            outcome,
            .failure("Could not create folder: A folder named \"\(reports)\" already exists in Library Root.")
        )
        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), [reports])
        XCTAssertFalse(viewModel.showError)
    }

    /// A directory that cannot be created, here because a file already has
    /// its name, fails with the file system's reason and publishes nothing.
    func testCreateBlockedByAFileFailsWithTheFileSystemReason() throws {
        let name = uniqueFolder("Blocked")
        try TextMouthPaths.ensureDirectoryStructure()
        let blocker = TextMouthPaths.libraryDir.appendingPathComponent(name)
        try Data("keep".utf8).write(to: blocker)
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library()

        let outcome = viewModel.createFolderReturningOutcome(name: name, parentPath: "")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.failureMessage?.hasPrefix("Could not create folder: ") == true, "\(outcome)")
        XCTAssertTrue(viewModel.library.folders.isEmpty)
        XCTAssertEqual(try String(contentsOf: blocker), "keep")
        XCTAssertFalse(viewModel.showError)
    }

    /// A folder created through the outcome form exists in the library and
    /// on disk.
    func testCreateThatWorksReturnsSuccess() throws {
        let name = uniqueFolder("Fresh")
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library()

        XCTAssertEqual(viewModel.createFolderReturningOutcome(name: name, parentPath: ""), .success(nil))
        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), [name])
        XCTAssertTrue(directoryExists(name))
    }

    // MARK: - Move Folder and Remove Moving Contents

    /// Moving a folder next to a sibling of the same name is refused with the
    /// conflict, and nothing moves.
    func testRefusedFolderMoveReturnsTheConflict() throws {
        let first = uniqueFolder("First")
        let second = uniqueFolder("Second")
        let viewModel = try modelWithFolders([first, second, "\(first)/Shared", "\(second)/Shared"])
        let before = viewModel.library.folders
        let moving = try XCTUnwrap(viewModel.library.folders.first { $0.fullPath == "\(first)/Shared" })

        let outcome = viewModel.moveFolderReturningOutcome(moving, toParent: second)

        XCTAssertEqual(
            outcome,
            .failure("Could not move \"Shared\": A folder named \"Shared\" already exists in \"\(second)\".")
        )
        XCTAssertEqual(viewModel.library.folders, before)
        XCTAssertFalse(viewModel.showError)
    }

    /// Removing a folder into one of its own subfolders is refused with the
    /// conflict, and the folder stays.
    func testRefusedRemovalMovingContentsReturnsTheConflict() throws {
        let parent = uniqueFolder("Parent")
        let viewModel = try modelWithFolders([parent, "\(parent)/Child"])
        let before = viewModel.library.folders
        let folder = try XCTUnwrap(viewModel.library.folders.first { $0.fullPath == parent })

        let outcome = viewModel.removeFolderMovingContentsReturningOutcome(folder, toPath: "\(parent)/Child")

        XCTAssertEqual(
            outcome,
            .failure("Could not delete \"\(parent)\" and move its contents: "
                + FolderOperationConflict.destinationInsideFolder(
                    folderPath: parent,
                    destinationPath: "\(parent)/Child"
                ).message)
        )
        XCTAssertEqual(viewModel.library.folders, before)
        XCTAssertFalse(viewModel.showError)
    }

    // MARK: - Moving Books

    /// A book move blocked by a package already at the destination returns
    /// the file system's reason, leaves the book and its package where they
    /// were, and does not remember the destination for the next move.
    func testFailedBookMoveReturnsTheReasonAndLeavesTheBook() throws {
        let source = uniqueFolder("Source")
        let destination = uniqueFolder("Destination")
        let viewModel = try modelWithFolders([source, destination])
        let book = try makeManagedBook(in: source)
        viewModel.library.books = [book]
        try FileManager.default.createDirectory(
            at: TextMouthPaths.tmbPath(folderPath: destination, tmbName: book.tmbDirectoryName),
            withIntermediateDirectories: true
        )

        let outcome = viewModel.moveBooksReturningOutcome([book], toFolder: destination)

        XCTAssertTrue(outcome.failureMessage?.hasPrefix("Could not move books: ") == true, "\(outcome)")
        XCTAssertEqual(viewModel.library.books.first?.folderPath, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertEqual(viewModel.lastMovedFolderPath, "")
        XCTAssertFalse(viewModel.showError)
    }

    /// A book move that works returns success and remembers the destination
    /// as the next move's default, as before.
    func testBookMoveThatWorksReturnsSuccess() throws {
        let source = uniqueFolder("Source")
        let destination = uniqueFolder("Destination")
        let viewModel = try modelWithFolders([source, destination])
        let book = try makeManagedBook(in: source)
        viewModel.library.books = [book]

        XCTAssertEqual(viewModel.moveBooksReturningOutcome([book], toFolder: destination), .success(nil))
        XCTAssertEqual(viewModel.library.books.first?.folderPath, destination)
        XCTAssertEqual(viewModel.lastMovedFolderPath, destination)
    }

    // MARK: - Sheets and Navigation

    /// A rename refused by a folder conflict leaves every window where it
    /// was, even one showing the folder or a folder inside it, and keeps the
    /// sheet open: the outcome is a failure, which the sheet shows labelled
    /// as an error and announces exactly once.
    func testRefusedRenameLeavesTheWindowAndKeepsTheSheetOpen() throws {
        let reports = uniqueFolder("Reports")
        let archive = uniqueFolder("Archive")
        let viewModel = try modelWithFolders([reports, archive, "\(archive)/Inner"])
        let folder = try XCTUnwrap(viewModel.library.folders.first { $0.fullPath == archive })
        var shown: String?

        let recorder = recordingAnnouncements {
            let outcome = viewModel.renameFolderReturningOutcome(folder, to: reports)
            XCTAssertFalse(outcome.succeeded, "a sheet closes only after a success")
            let pathAfter = viewModel.library.folders.first { $0.id == folder.id }?.fullPath
            for windowPath in [archive, "\(archive)/Inner", reports, ""] {
                XCTAssertEqual(
                    FolderSheetNavigation.folderPath(
                        showing: windowPath,
                        after: outcome,
                        folderMovedFrom: archive,
                        to: pathAfter
                    ),
                    windowPath
                )
            }
            shown = OperationFailureNotice.message(after: outcome)
        }

        let expected = "Could not rename \"\(archive)\": A folder named \"\(reports)\" already exists in Library Root."
        XCTAssertEqual(shown, expected)
        XCTAssertEqual(recorder.announcements.map(\.message), [expected])
        XCTAssertEqual(OperationFailureNotice.accessibilityLabel(for: expected), "Error: " + expected)
        XCTAssertFalse(viewModel.showError, "no second report through the library alert")
    }

    /// After a rename that works, a window showing the folder, or a folder
    /// inside it, follows it to its new path; every other window stays.
    func testWindowsInsideARenamedFolderFollowIt() {
        func path(_ current: String) -> String {
            FolderSheetNavigation.folderPath(
                showing: current,
                after: .success(nil),
                folderMovedFrom: "Work/Old",
                to: "Work/New"
            )
        }

        XCTAssertEqual(path("Work/Old"), "Work/New")
        XCTAssertEqual(path("Work/Old/Q1/Notes"), "Work/New/Q1/Notes")
        XCTAssertEqual(path("Work"), "Work")
        XCTAssertEqual(path("Work/Older"), "Work/Older", "a sibling that shares the prefix stays")
        XCTAssertEqual(path(""), "")
    }

    /// A folder moved under a new parent carries a window inside it along.
    func testWindowsInsideAMovedFolderFollowIt() {
        XCTAssertEqual(
            FolderSheetNavigation.folderPath(
                showing: "Inbox/Trip/Day 1",
                after: .success(nil),
                folderMovedFrom: "Inbox/Trip",
                to: "Archive/Trip"
            ),
            "Archive/Trip/Day 1"
        )
    }

    /// With nothing to follow, the window stays: the folder is gone, the
    /// edit failed, or the "folder" was the library root.
    func testWindowStaysWhenThereIsNothingToFollow() {
        XCTAssertEqual(
            FolderSheetNavigation.folderPath(showing: "Old", after: .success(nil), folderMovedFrom: "Old", to: nil),
            "Old"
        )
        XCTAssertEqual(
            FolderSheetNavigation.folderPath(
                showing: "Old/Sub",
                after: .failure("Could not rename \"Old\": The disk is full."),
                folderMovedFrom: "Old",
                to: "New"
            ),
            "Old/Sub"
        )
        XCTAssertEqual(
            FolderSheetNavigation.folderPath(showing: "Books", after: .success(nil), folderMovedFrom: "", to: "Other"),
            "Books"
        )
    }

    /// A sheet whose operation worked shows nothing and announces nothing
    /// as it closes.
    func testSuccessShowsAndAnnouncesNothing() {
        var shown: String? = "stale"

        let recorder = recordingAnnouncements {
            shown = OperationFailureNotice.message(after: .success(nil))
        }

        XCTAssertNil(shown)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    // MARK: - Fixtures

    /// A top-level folder name unique to this test. Whatever ends up at that
    /// name in the library directory, folder or file, is removed with
    /// everything inside it when the test ends.
    private func uniqueFolder(_ base: String) -> String {
        let name = "\(base)-\(UUID().uuidString)"
        let url = TextMouthPaths.libraryDir.appendingPathComponent(name, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return name
    }

    /// An inert model whose library holds `paths`, parents first, each
    /// created through the view model with its directory on disk.
    private func modelWithFolders(_ paths: [String]) throws -> LibraryViewModel {
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library()
        for path in paths {
            let outcome = viewModel.createFolderReturningOutcome(
                name: (path as NSString).lastPathComponent,
                parentPath: (path as NSString).deletingLastPathComponent
            )
            XCTAssertEqual(outcome, .success(nil), path)
        }
        XCTAssertEqual(Set(viewModel.library.folders.map(\.fullPath)), Set(paths))
        return viewModel
    }

    /// Whether the library folder at `path` has a directory on disk.
    private func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let url = TextMouthPaths.libraryDir.appendingPathComponent(path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A managed book with a real package and bookInfo.json in `folder`.
    private func makeManagedBook(in folder: String) throws -> Book {
        let packageName = "OutcomeFixture-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Outcome fixture".utf8).write(to: content)
        let book = Book(
            title: "Outcome Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: "outcome-\(UUID().uuidString)",
            folderPath: folder,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }
}
