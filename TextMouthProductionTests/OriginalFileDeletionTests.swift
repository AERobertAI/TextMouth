import XCTest
@testable import TextMouth

/// Deleting the original file of a book just imported honors "Move to Trash
/// instead of deleting" through the app's one deletion helper, and a
/// deletion that fails is reported with the file's path, in the words of
/// the mode in force, and with a retry (TODO S09). A file left behind is
/// not an unsaved change. Tests that let the real deletion run turn the
/// Trash off; with it on, the deletion is injected, so nothing reaches the
/// real Trash.
@MainActor
final class OriginalFileDeletionTests: XCTestCase {
    // MARK: - Failures

    /// A deletion that fails leaves the file, is reported with its path in
    /// the words of permanent deletion, and is no unsaved change: the book
    /// is already safe in the library.
    func testAFailedDeletionIsReportedWithTheFilesPath() throws {
        let center = cleanSharedFailureCenter()
        let (original, _) = try lockedOriginal("Locked Original.epub")
        let model = LibraryViewModel(initializeServices: false)

        withTrashPreference(movesToTrash: false) {
            model.deleteOriginalFile(at: original)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .originalFile(path: original.path, movesToTrash: false))
        XCTAssertEqual(failure.subsystem, .originalFileCleanup)
        XCTAssertEqual(failure.path, original.path)
        XCTAssertTrue(
            failure.sentence.hasPrefix("The original file “Locked Original.epub” could not be deleted: "),
            failure.sentence
        )
        XCTAssertFalse(center.hasUnsavedChanges, "a file left behind loses nothing")
    }

    /// Retry deletes the file once it can be deleted, and settles the
    /// failure; VoiceOver hears that it is removed.
    func testRetryDeletesTheFileAndSettlesTheFailure() throws {
        let center = cleanSharedFailureCenter()
        let (original, unlock) = try lockedOriginal("Retried Original.epub")
        let model = LibraryViewModel(initializeServices: false)
        withTrashPreference(movesToTrash: false) {
            model.deleteOriginalFile(at: original)
        }
        XCTAssertEqual(center.outstandingFailures().count, 1)

        unlock()
        let recorder = recordingAnnouncements {
            withTrashPreference(movesToTrash: false) {
                center.retry(.originalFileCleanup)
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(center.outstandingFailures().isEmpty)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Original files removed."])
    }

    /// "Delete After Import" deletes through the same path, so a failure
    /// there is reported too, not swallowed.
    func testDeleteAfterImportReportsAFailedDeletion() throws {
        let center = cleanSharedFailureCenter()
        let (original, _) = try lockedOriginal("Imported Original.epub")
        let model = LibraryViewModel(initializeServices: false)
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = .deleteAfterImport
        defer { config.config.importDeleteBehavior = previous }

        withTrashPreference(movesToTrash: false) {
            model.handleOriginalFileDeletion(url: original)
        }

        XCTAssertEqual(center.outstandingFailures().map(\.key), [.originalFile(original.path)])
        XCTAssertFalse(model.showError, "the failure goes to the banner, not the modal alert")
    }

    // MARK: - The Trash

    /// With the Trash preference on, the original goes through the Trash
    /// path of the app's deletion helper, never the permanent one.
    func testWithTheTrashOnTheOriginalGoesToTheTrash() throws {
        let center = cleanSharedFailureCenter()
        let original = try makeTestDirectory("TrashedOriginal").appendingPathComponent("Trashed Original.epub")
        try Data("original".utf8).write(to: original)
        let trashed = CallLog<URL>()
        let removed = CallLog<URL>()
        let model = LibraryViewModel(initializeServices: false)

        withTrashPreference(movesToTrash: true) {
            model.deleteOriginalFile(at: original) { url in
                try FileImportService.removeItemRespectingTrashSetting(
                    at: url,
                    trashItem: { trashed.record($0) },
                    removeItem: { removed.record($0) }
                )
            }
        }

        XCTAssertEqual(trashed.calls, [original])
        XCTAssertEqual(removed.calls, [])
        XCTAssertTrue(center.outstandingFailures().isEmpty)
    }

    /// A move to the Trash that fails is reported in the words of the
    /// Trash, which is where the file was going.
    func testAFailedMoveToTheTrashSaysSo() {
        let center = cleanSharedFailureCenter()
        let original = URL(fileURLWithPath: "/nonexistent/Trash Refused.epub")
        let model = LibraryViewModel(initializeServices: false)

        withTrashPreference(movesToTrash: true) {
            model.deleteOriginalFile(at: original) { _ in throw WriteRefused() }
        }

        XCTAssertEqual(
            center.outstandingFailures().first?.sentence,
            "The original file “Trash Refused.epub” could not be moved to the Trash: The volume is read-only."
        )
    }

    /// The failure sentence says where the file was going, and names it
    /// when its name is known.
    func testTheFailureSentenceSaysWhereTheFileWasGoing() {
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: true, fileName: "Notes.epub")
                .failureSentence(reason: "The disk is full."),
            "The original file “Notes.epub” could not be moved to the Trash: The disk is full."
        )
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: false).failureSentence(reason: "The disk is full."),
            "The original file could not be deleted: The disk is full."
        )
    }

    // MARK: - The Confirmation and Storage Settings

    /// The Delete Original File confirmation says where the file goes, in
    /// both modes: its title, its button, and its message, which names the
    /// file when it can.
    func testTheConfirmationSaysWhereTheFileGoes() {
        let trash = OriginalFileDeletionWording(movesToTrash: true, fileName: "Notes.epub")
        XCTAssertEqual(trash.confirmationTitle, "Move Original File to Trash?")
        XCTAssertEqual(trash.buttonTitle, "Move to Trash")
        XCTAssertEqual(
            trash.confirmationMessage,
            "The book has been imported successfully. Move the original file “Notes.epub” to the Trash? "
                + "You can recover it from the Trash until the Trash is emptied."
        )

        let permanent = OriginalFileDeletionWording(movesToTrash: false, fileName: "Notes.epub")
        XCTAssertEqual(permanent.confirmationTitle, "Delete Original File Permanently?")
        XCTAssertEqual(permanent.buttonTitle, "Delete Permanently")
        XCTAssertEqual(
            permanent.confirmationMessage,
            "The book has been imported successfully. Delete the original file “Notes.epub” permanently? "
                + "It cannot be recovered."
        )
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: false).confirmationMessage,
            "The book has been imported successfully. Delete the original file permanently? It cannot be recovered."
        )
    }

    /// Storage settings explain the import preference in the words of the
    /// Trash toggle beside it.
    func testStorageSettingsExplainTheImportPreferenceInTheWordsOfTheTrash() {
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: true).automaticDeletionExplanation,
            "The original file will be moved to the Trash after a successful import."
        )
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: false).automaticDeletionExplanation,
            "The original file will be permanently deleted after a successful import."
        )
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: true).askingExplanation,
            "You will be asked whether to move the original file to the Trash after each import."
        )
        XCTAssertEqual(
            OriginalFileDeletionWording(movesToTrash: false).askingExplanation,
            "You will be asked whether to delete the original file permanently after each import."
        )
    }

    /// The library's confirmation follows the Trash preference in force,
    /// which the deletion reads too, and names the file it asks about.
    func testTheLibrarysConfirmationFollowsThePreferenceAndNamesTheFile() {
        let model = LibraryViewModel(initializeServices: false)
        model.pendingOriginalURL = URL(fileURLWithPath: "/Downloads/Atlas.epub")

        withTrashPreference(movesToTrash: true) {
            XCTAssertEqual(
                model.pendingOriginalFileWording,
                OriginalFileDeletionWording(movesToTrash: true, fileName: "Atlas.epub")
            )
        }
        withTrashPreference(movesToTrash: false) {
            XCTAssertEqual(model.pendingOriginalFileWording.buttonTitle, "Delete Permanently")
        }
    }

    // MARK: - Helpers

    /// A file named `name` in a folder of the test's own made read-only, so
    /// the file cannot be deleted until the returned function gives back
    /// write permission.
    private func lockedOriginal(_ name: String) throws -> (URL, @Sendable () -> Void) {
        let directory = try makeTestDirectory("LockedOriginal")
        let original = directory.appendingPathComponent(name)
        try Data("original".utf8).write(to: original)
        return (original, makeReadOnly(directory))
    }
}
