import XCTest
@testable import TextMouth

/// Storage settings never say a thing is done or active while a failed write
/// leaves changes unsaved (TODO S09). Once the library's queued writes have
/// been made, an operation's success is reported as the failure it is,
/// naming what is unsaved, through the A07 outcome and status types; the
/// status line says "Changes not saved" with the reasons, and offers Retry.
@MainActor
final class StorageStatusHonestyTests: XCTestCase {
    /// A center of this test's own, for everything but the library model.
    private let center = PersistenceFailureCenter()

    // MARK: - Outcomes

    /// A success that leaves changes unsaved is reported as a failure: its
    /// message stays without "Done.", followed by what is not saved, and the
    /// status line shows it as a failure.
    func testASuccessThatLeavesChangesUnsavedIsAFailureWithoutDone() {
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())

        let outcome = OperationOutcome.success("Done. 3 books in library.").confirmingSaves(center.unsavedFailures())

        XCTAssertEqual(
            outcome,
            .failure(
                "3 books in library. Some changes are not saved. "
                    + "Library changes could not be saved: The volume is read-only."
            )
        )
        let status = StorageStatus.finished(outcome)
        XCTAssertTrue(status.isFailure)
        XCTAssertFalse(status.message.contains("Done"), status.message)
    }

    /// A success with no message of its own, which the status line would
    /// show as "Done.", says only what is unsaved.
    func testASuccessWithoutAMessageSaysOnlyWhatIsUnsaved() {
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())

        XCTAssertEqual(
            OperationOutcome.success(nil).confirmingSaves(center.unsavedFailures()),
            .failure("Some changes are not saved. Settings could not be saved: The volume is read-only.")
        )
    }

    /// A failure, and a success with nothing unsaved, claim nothing false,
    /// so they stay as they are.
    func testOutcomesThatClaimNothingFalseStayAsTheyAre() {
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused())
        let moved = OperationOutcome.success("Done. Data is now at /Volumes/Archive/.TextMouth.")

        XCTAssertEqual(
            OperationOutcome.failure("Could not move data: The disk is full.").confirmingSaves(center.unsavedFailures()),
            .failure("Could not move data: The disk is full.")
        )
        XCTAssertEqual(moved.confirmingSaves([]), moved)
    }

    /// The library model makes the queued writes before it judges an
    /// outcome, so an index write that fails just then is in the report.
    func testTheModelMakesQueuedWritesBeforeJudgingAnOutcome() throws {
        let sharedCenter = cleanSharedFailureCenter()
        let sandbox = try LibraryIndexSandbox.capture()
        let obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        addTeardownBlock {
            obstruction.clear()
            sandbox.restore()
        }
        let model = LibraryViewModel(initializeServices: false)
        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())

        let outcome = model.outcomeConfirmingSaves(.success("Done. 2 books in library."))

        XCTAssertTrue(sharedCenter.hasUnsavedChanges)
        let message = try XCTUnwrap(outcome.failureMessage)
        XCTAssertTrue(
            message.hasPrefix("2 books in library. Some changes are not saved. Library changes could not be saved: "),
            message
        )
    }

    /// An original file left behind loses nothing, so it leaves a success
    /// standing.
    func testAnOriginalFileLeftBehindLeavesASuccessStanding() {
        let sharedCenter = cleanSharedFailureCenter()
        sharedCenter.recordFailure(
            .originalFile(path: "/Downloads/Atlas.epub", movesToTrash: true),
            path: "/Downloads/Atlas.epub",
            error: WriteRefused()
        )
        let model = LibraryViewModel(initializeServices: false)

        XCTAssertEqual(model.outcomeConfirmingSaves(.success("Done.")), .success("Done."))
    }

    // MARK: - The Status Line

    /// The status says "Changes not saved" rather than "Active" or "Not
    /// Created" while changes are unsaved; an unreadable index still
    /// outranks it, and with nothing unsaved the status is as before.
    func testTheStatusDoesNotSayActiveWhileChangesAreUnsaved() {
        typealias Storage = StorageSettingsView
        XCTAssertEqual(
            Storage.statusText(isRecoveringIndex: false, directoryExists: true, hasUnsavedChanges: true),
            "Changes not saved"
        )
        XCTAssertEqual(
            Storage.statusText(isRecoveringIndex: false, directoryExists: false, hasUnsavedChanges: true),
            "Changes not saved"
        )
        XCTAssertEqual(
            Storage.statusText(isRecoveringIndex: true, directoryExists: true, hasUnsavedChanges: true),
            LibraryIndexRecoveryText.settingsStatus
        )
        XCTAssertEqual(
            Storage.statusText(isRecoveringIndex: false, directoryExists: true, hasUnsavedChanges: false),
            "Active"
        )
    }

    /// The explanation under the status names each unsaved subsystem and
    /// why, and leaves out an original file left behind.
    func testTheExplanationNamesEachUnsavedSubsystem() {
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused())
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())
        center.recordFailure(
            .originalFile(path: "/Downloads/Atlas.epub", movesToTrash: false),
            path: "/Downloads/Atlas.epub",
            error: WriteRefused()
        )
        recordingAnnouncements { center.publish() }

        XCTAssertEqual(
            StorageSettingsView.unsavedExplanation(center.unsavedRows),
            "Library changes could not be saved: The volume is read-only. "
                + "Listening statistics could not be saved: The volume is read-only."
        )
    }

    /// Dismissing a notice saves nothing, so the status still counts it.
    func testADismissedNoticeStillCountsAsUnsaved() {
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        recordingAnnouncements { center.publish() }

        center.dismiss(.configuration)

        XCTAssertTrue(center.bannerRows.isEmpty)
        XCTAssertEqual(center.unsavedRows.map(\.subsystem), [.configuration])
    }

    /// Retry Saving runs every unsaved write again and tells VoiceOver how
    /// it went: what still fails, or that everything retried is saved.
    func testRetrySavingTellsHowItWent() {
        let center = self.center
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused()) { _ in
            center.recordSuccess(.libraryIndex)
        }
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused()) { _ in }
        recordingAnnouncements { center.publish() }

        let partly = recordingAnnouncements { center.retryUnsavedChanges(announcing: true) }

        XCTAssertEqual(
            partly.announcements.map(\.message),
            ["Retry did not succeed. Settings could not be saved: The volume is read-only."]
        )

        let other = PersistenceFailureCenter()
        other.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused()) { _ in
            other.recordSuccess(.libraryIndex)
        }
        other.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused()) { _ in
            other.recordSuccess(.configuration)
        }

        let fully = recordingAnnouncements { other.retryUnsavedChanges(announcing: true) }

        XCTAssertEqual(fully.announcements.map(\.message), ["Library changes saved. Settings saved."])
    }
}
