import XCTest
@testable import TextMouth

/// Data-directory maintenance started from Storage settings reports what
/// really happened (TODO A07): a refused rebuild or a blocked move returns
/// the reason, in the words of the library's error alert, and raises no
/// alert in the Library window behind Settings.
///
/// Safety: a move that went through would record the new data directory in
/// the preferences, which every test in the process shares (they are the
/// sandbox's, never the user's; see `TextMouthRuntime`). Every move here is
/// refused before anything is copied, at least twice over, and the
/// preferences are put back as each test found them regardless. Reset to
/// Default is never driven; its wording is checked through the shared
/// outcome rule.
@MainActor
final class StorageOperationOutcomeTests: XCTestCase {
    // MARK: - Refused While the Index Is Unreadable

    /// Rebuild Directory while the library index cannot be read returns the
    /// refusal and changes nothing, with no alert in the Library window.
    func testRebuildWhileTheIndexIsUnreadableReturnsTheRefusal() async throws {
        let sandbox = try captureIndexSandbox()
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        let outcome = await model.rebuildDirectoryReturningOutcome()

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
    func testMoveWhileTheIndexIsUnreadableReturnsTheRefusal() async throws {
        protectDataDirectoryPreferences()
        let sandbox = try captureIndexSandbox()
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination.directory)

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
    func testMoveIntoAFolderThatIsNotEmptyReturnsTheReason() async throws {
        protectDataDirectoryPreferences()
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertNil(model.indexRecovery)
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination.directory)

        let expected = "Failed to move directory: \(DataDirectoryMigrationError.destinationNotEmpty.localizedDescription)"
        XCTAssertEqual(outcome, .failure(expected))
        XCTAssertFalse(model.showError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.directory.path), ["keep.txt"])
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
        XCTAssertEqual(
            ConfigService.shared.config.dataDirectoryPath,
            ConfigService.AppConfig.currentDataDirectoryPath
        )

        await model.moveDataDirectory(to: destination.directory).value

        XCTAssertTrue(model.showError)
        XCTAssertEqual(model.errorMessage, expected)
    }

    // MARK: - Status Line

    /// After a rebuild refused while the library index is being recovered,
    /// the status line shows the refusal, word for word as the outcome
    /// carries it, as a failure; it never says "Done", and VoiceOver hears
    /// it exactly once.
    func testStatusAfterARefusedRebuild() async throws {
        let sandbox = try captureIndexSandbox()
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        var status: StorageStatus?
        let outcome = await model.rebuildDirectoryReturningOutcome()

        let recorder = recordingAnnouncements {
            status = .announced(after: outcome)
        }

        let expected = "Failed to rebuild directory: \(LibraryIndexRecoveryError.indexUnreadable.localizedDescription)"
        XCTAssertEqual(status, StorageStatus(message: expected, isFailure: true))
        XCTAssertEqual(recorder.announcements, [VoiceOverAnnouncement(message: expected, priority: .high)])
    }

    /// After a move blocked by a folder that is not empty, the status line
    /// shows why as a failure, and Change Location is available again to
    /// try another folder.
    func testStatusAfterABlockedMoveAllowsARetry() async throws {
        protectDataDirectoryPreferences()
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        let destination = try makeNonEmptyDestination()
        var status: StorageStatus?
        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination.directory)

        let recorder = recordingAnnouncements {
            status = .announced(after: outcome)
        }

        let expected = "Failed to move directory: \(DataDirectoryMigrationError.destinationNotEmpty.localizedDescription)"
        XCTAssertEqual(status, StorageStatus(message: expected, isFailure: true))
        XCTAssertEqual(recorder.announcements.map(\.message), [expected])
        XCTAssertFalse(
            StorageSettingsView.maintenanceUnavailable(isRecoveringIndex: model.indexRecovery != nil, isRunning: false),
            "the buttons are available for a retry"
        )
    }

    /// While an operation runs the status line names it and every location
    /// and rebuild button is unavailable; they stay unavailable while the
    /// library index cannot be read, and are available otherwise.
    func testStatusAndButtonsWhileAnOperationRuns() {
        XCTAssertEqual(StorageStatus.running(.rebuild), StorageStatus(message: "Rebuilding the data directory...", isFailure: false))
        XCTAssertEqual(StorageStatus.running(.resetToDefault).message, "Moving data to the default location...")
        XCTAssertEqual(
            StorageStatus.running(.move(to: URL(fileURLWithPath: "/Volumes/Archive/.TextMouth"))).message,
            "Moving data to /Volumes/Archive/.TextMouth..."
        )
        XCTAssertTrue(StorageSettingsView.maintenanceUnavailable(isRecoveringIndex: false, isRunning: true))
        XCTAssertTrue(StorageSettingsView.maintenanceUnavailable(isRecoveringIndex: true, isRunning: false))
        XCTAssertFalse(StorageSettingsView.maintenanceUnavailable(isRecoveringIndex: false, isRunning: false))
    }

    /// While a move waits for storage work to finish before it copies
    /// anything, the move's progress, which Storage settings show in the
    /// status line's place, says what it waits for (TODO S04), and VoiceOver
    /// hears each such status once (FR02).
    func testStatusWhileAMoveWaits() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Archive/.TextMouth"))
        var shown: [String] = []

        let recorder = recordingAnnouncements {
            for work in [StorageWork.importing, .importing, .textExtraction, .contentAnalysis] {
                move.wait(for: work)
                shown.append(move.statusText)
            }
        }

        XCTAssertEqual(shown, [
            "Waiting for the current import to finish...",
            "Waiting for the current import to finish...",
            "Waiting for text extraction to finish...",
            "Waiting for book analysis to finish...",
        ])
        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Waiting for the current import to finish...",
            "Waiting for text extraction to finish...",
            "Waiting for book analysis to finish...",
        ])
    }

    /// A move asked for while another is under way is refused before
    /// anything is copied, saying so, and the data directory stays where
    /// it is.
    func testASecondMoveIsRefusedWhileOneIsUnderWay() async throws {
        protectDataDirectoryPreferences()
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root
        let otherMove = try StorageBoundary.shared.holdWork(for: .movingDataDirectory)
        defer { otherMove.release() }

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination.directory)

        XCTAssertEqual(
            outcome,
            .failure("Failed to move directory: TextMouth is already moving its data directory. Try again once that move is done.")
        )
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.directory.path), ["keep.txt"])
    }

    /// A move asked for while books move between folders, a folder edit
    /// holding the storage work, is refused before anything is copied,
    /// saying what is happening rather than that a move is under way
    /// (#673), and the data directory stays where it is.
    func testAMoveIsRefusedWhileBooksMoveBetweenFolders() async throws {
        protectDataDirectoryPreferences()
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        let destination = try makeNonEmptyDestination()
        let rootBefore = TextMouthPaths.root
        let folderEdit = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        defer { folderEdit.release() }

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination.directory)

        XCTAssertEqual(
            outcome,
            .failure("Failed to move directory: TextMouth is moving books between folders. Try again when that finishes.")
        )
        XCTAssertFalse(model.showError, "the status line reports it, not an alert behind Settings")
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.directory.path), ["keep.txt"])
    }

    /// Rebuild Directory asked for while books move between folders is
    /// refused before it changes anything, saying what is happening rather
    /// than that a move is under way (#673).
    func testARebuildIsRefusedWhileBooksMoveBetweenFolders() async throws {
        _ = try captureIndexSandbox()
        let model = LibraryViewModel(initializeServices: false)
        let folderEdit = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        defer { folderEdit.release() }

        let outcome = await model.rebuildDirectoryReturningOutcome()

        XCTAssertEqual(
            outcome,
            .failure("Failed to rebuild directory: TextMouth is moving books between folders. Try again when that finishes.")
        )
        XCTAssertFalse(model.showError, "the status line reports it, not an alert behind Settings")
    }

    /// A success shows its own "Done" sentence, which is never shown as a
    /// failure; a success with nothing to say still reads "Done."
    func testStatusAfterSuccess() {
        XCTAssertEqual(
            StorageStatus.finished(.success("Done. 3 books in library.")),
            StorageStatus(message: "Done. 3 books in library.", isFailure: false)
        )
        XCTAssertEqual(StorageStatus.finished(.success(nil)), StorageStatus(message: "Done.", isFailure: false))
    }

    // MARK: - Outcome Wording

    /// An operation refused while another holds the storage work is told
    /// what that operation is doing (#673): a data-directory move, a
    /// rebuild, books moving between folders, or a switch to another library
    /// opening TextMouth again.
    func testABusyRefusalSaysWhatHoldsTheStorageWork() {
        XCTAssertEqual(
            StorageBusyError(reason: .movingDataDirectory).localizedDescription,
            "TextMouth is already moving its data directory. Try again once that move is done."
        )
        XCTAssertEqual(
            StorageBusyError(reason: .rebuildingDirectory).localizedDescription,
            "TextMouth is rebuilding its data directory. Try again when that finishes."
        )
        XCTAssertEqual(
            StorageBusyError(reason: .movingBooksBetweenFolders).localizedDescription,
            "TextMouth is moving books between folders. Try again when that finishes."
        )
        XCTAssertEqual(
            StorageBusyError(reason: .switchingLibraries).localizedDescription,
            "TextMouth is switching to another library and opening again on it."
        )
    }

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
    /// custom location in this process's preferences, which every test
    /// shares, and config.json's field.
    private func protectDataDirectoryPreferences() {
        let defaults = TextMouthRuntime.current.preferences
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
