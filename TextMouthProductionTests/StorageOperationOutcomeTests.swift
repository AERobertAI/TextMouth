import XCTest
@testable import TextMouth

/// Data-directory maintenance started from Storage settings reports what
/// really happened (TODO A07): a refused rebuild or a blocked move returns
/// the reason, in the words of the library's error alert, and raises no
/// alert in the Library window behind Settings.
///
/// Safety: the hosted app shares the real app's preferences, where a move
/// that went through would record the new data directory. Every move here
/// is refused before anything is copied, at least twice over, and the
/// preferences are put back as each test found them regardless. Reset to
/// Default is never driven, because its destination is the real
/// ~/.TextMouth; its wording is checked through the shared outcome rule.
@MainActor
final class StorageOperationOutcomeTests: XCTestCase {
    // MARK: - Refused While the Index Is Unreadable

    /// Rebuild Directory while the library index cannot be read returns the
    /// refusal and changes nothing, with no alert in the Library window.
    func testRebuildWhileTheIndexIsUnreadableReturnsTheRefusal() throws {
        let sandbox = try captureIndexSandbox()
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        let outcome = model.rebuildDirectoryReturningOutcome()

        XCTAssertEqual(
            outcome,
            .failure("Failed to rebuild directory: \(LibraryIndexRecoveryError.indexUnreadable.localizedDescription)")
        )
        XCTAssertFalse(model.showError, "the status line reports it, not an alert behind Settings")
        XCTAssertNotNil(model.indexRecovery)
        XCTAssertFalse(model.isExtracting, "no maintenance may start")
        XCTAssertEqual(try Data(contentsOf: sandbox.indexURL), damagedBytes)
    }

    /// Change Location while the library index cannot be read returns the
    /// refusal before anything is copied.
    func testMoveWhileTheIndexIsUnreadableReturnsTheRefusal() throws {
        protectDataDirectoryPreferences()
        let sandbox = try captureIndexSandbox()
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root

        let outcome = model.moveDataDirectoryReturningOutcome(to: destination.directory)

        XCTAssertEqual(
            outcome,
            .failure("Failed to move directory: \(LibraryIndexRecoveryError.indexUnreadable.localizedDescription)")
        )
        XCTAssertFalse(model.showError)
        XCTAssertEqual(try String(contentsOf: destination.sentinel), "keep")
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
    }

    // MARK: - Blocked Move

    /// A move into a folder that already holds files is blocked: the outcome
    /// says so, the folder and the data directory stay as they were, and
    /// config.json keeps naming the directory in use. The plain form, used
    /// for a location edited in config.json, still explains the same
    /// failure, in the same words, through the library's error alert.
    func testMoveIntoAFolderThatIsNotEmptyReturnsTheReason() throws {
        protectDataDirectoryPreferences()
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertNil(model.indexRecovery)
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root

        let outcome = model.moveDataDirectoryReturningOutcome(to: destination.directory)

        let expected = "Failed to move directory: \(DataDirectoryMigrationError.destinationNotEmpty.localizedDescription)"
        XCTAssertEqual(outcome, .failure(expected))
        XCTAssertFalse(model.showError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.directory.path), ["keep.txt"])
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
        XCTAssertEqual(
            ConfigService.shared.config.dataDirectoryPath,
            ConfigService.AppConfig.currentDataDirectoryPath
        )

        model.moveDataDirectory(to: destination.directory)

        XCTAssertTrue(model.showError)
        XCTAssertEqual(model.errorMessage, expected)
    }

    // MARK: - Outcome Wording

    /// "Done" carries the books the legacy migration could not move after a
    /// blank line, so the status line says what needs attention; a failure
    /// reads like the library's error alert.
    func testMaintenanceOutcomeWording() throws {
        let done = "Done. Data is now at /Volumes/Archive/.TextMouth."
        let issues = LegacyMigrationReport(failures: [.init(title: "Old Notes", reason: "The file is missing.")])
        let summary = try XCTUnwrap(issues.userSummary)

        XCTAssertEqual(
            LibraryViewModel.maintenanceOutcome(.success(nil), failureContext: "Failed to rebuild to default", done: done),
            .success(done)
        )
        XCTAssertEqual(
            LibraryViewModel.maintenanceOutcome(
                .success(LegacyMigrationReport()),
                failureContext: "Failed to rebuild to default",
                done: done
            ),
            .success(done),
            "a migration with nothing to report adds nothing"
        )
        XCTAssertEqual(
            LibraryViewModel.maintenanceOutcome(.success(issues), failureContext: "Failed to rebuild to default", done: done),
            .success(done + "\n\n" + summary)
        )
        XCTAssertEqual(
            LibraryViewModel.maintenanceOutcome(
                .failure(DataDirectoryMigrationError.destinationNotEmpty),
                failureContext: "Failed to rebuild to default",
                done: done
            ),
            .failure("Failed to rebuild to default: The selected data directory is not empty. Choose an empty location.")
        )
    }

    // MARK: - Fixtures

    /// Records both library index locations and puts them back, with index
    /// writes resumed, when the test ends.
    private func captureIndexSandbox() throws -> LibraryIndexSandbox {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        return sandbox
    }

    /// Puts the data-directory preferences back as the test found them: the
    /// custom location in the shared preferences, and config.json's field.
    private func protectDataDirectoryPreferences() {
        let defaults = UserDefaults.standard
        // TextMouthPaths' private key for a custom data directory.
        let key = "textMouthDataDirectory"
        let savedLocation = defaults.string(forKey: key)
        let config = ConfigService.shared
        let savedConfigPath = config.config.dataDirectoryPath
        addTeardownBlock {
            if let savedLocation {
                defaults.set(savedLocation, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if config.config.dataDirectoryPath != savedConfigPath {
                config.config.dataDirectoryPath = savedConfigPath
                config.saveToDisk()
            }
        }
    }

    /// A temporary folder outside the data directory that already holds a
    /// file, so a migration into it is refused before anything is copied.
    private func makeNonEmptyDestination() throws -> (directory: URL, sentinel: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageOutcome-\(UUID().uuidString)", isDirectory: true)
        let directory = base.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let sentinel = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        return (directory, sentinel)
    }
}
