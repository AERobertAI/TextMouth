import SwiftUI
import XCTest
@testable import TextMouth

/// The failure center keeps the latest failed write of each file, settles it
/// when a later write of the same file succeeds, says whether changes are
/// unsaved, runs a failed write again on request, and shows each subsystem
/// in the Library window's banner and to VoiceOver once (TODO S09). Every
/// test uses a center of its own, so the app's shared center is untouched.
@MainActor
final class PersistenceFailureCenterTests: XCTestCase {
    /// This test's center.
    private let center = PersistenceFailureCenter()

    /// A center whose waiting retries wait for the holds of a boundary of
    /// the test's own, and that boundary, so the app's storage work is never
    /// held.
    private func centerOverItsOwnBoundary() throws -> (PersistenceFailureCenter, StorageBoundary) {
        let boundary = StorageBoundary(root: try makeSandboxDirectory("FailureCenterBoundary"))
        return (PersistenceFailureCenter(boundary: boundary), boundary)
    }

    // MARK: - Keeping and Settling Failures

    /// A write that keeps failing holds one entry, the latest, with its
    /// path, reason, and time; a later success for the same file settles it.
    func testTheLatestFailureOfAFileIsKeptUntilAWriteOfItSucceeds() throws {
        let start = Date()
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: CocoaError(.fileWriteNoPermission))
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(center.outstandingFailures().count, 1)
        XCTAssertEqual(failure.subject, .libraryIndex)
        XCTAssertEqual(failure.subsystem, .libraryIndex)
        XCTAssertEqual(failure.path, "/data/library.json")
        XCTAssertEqual(failure.reason, "The volume is read-only.")
        XCTAssertGreaterThanOrEqual(failure.date, start)
        XCTAssertTrue(center.hasUnsavedChanges)

        center.recordSuccess(.libraryIndex)

        XCTAssertTrue(center.outstandingFailures().isEmpty)
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// Every book's record is a file of its own: saving one book settles
    /// only that book's failure.
    func testABookSavedSettlesOnlyItsOwnFailure() {
        let first = UUID()
        let second = UUID()
        center.recordFailure(.bookRecord(bookID: first, title: "First"), path: "/a", error: WriteRefused())
        center.recordFailure(.bookRecord(bookID: second, title: "Second"), path: "/b", error: WriteRefused())

        center.recordSuccess(.book(first))

        XCTAssertEqual(center.outstandingFailures().map(\.key), [.book(second)])
        XCTAssertTrue(center.hasUnsavedChanges, "the second book is still unsaved")
    }

    /// A failure withdrawn because nothing is left to save is gone, and a
    /// success or withdrawal for a file without a failure changes nothing.
    func testWithdrawingAFailureRemovesIt() {
        let book = UUID()
        center.recordFailure(.bookRecord(bookID: book, title: "Gone"), path: "/a", error: WriteRefused())

        center.withdraw(.book(book))
        center.withdraw(.book(book))
        center.recordSuccess(.statistics)

        XCTAssertTrue(center.outstandingFailures().isEmpty)
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// Every subsystem but original-file cleanup leaves changes only in
    /// memory when it fails; a file left behind after an import does not.
    func testEverySubsystemButOriginalFileCleanupHoldsUnsavedChanges() {
        XCTAssertEqual(
            PersistenceSubsystem.allCases.filter(\.holdsUnsavedChanges),
            [.libraryIndex, .bookRecord, .statistics, .configuration, .substitutions, .feedRecords]
        )
    }

    /// A retry asks whether its failure is still outstanding just before it
    /// writes: a later report for the same file, failure or success, means
    /// a newer write has run, so the older data must not be written.
    func testAFailureStopsBeingOutstandingOnceALaterReportSettlesItsFile() throws {
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        let first = try XCTUnwrap(center.outstandingFailures().first?.id)
        XCTAssertTrue(center.isOutstanding(first))

        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        let second = try XCTUnwrap(center.outstandingFailures().first?.id)
        XCTAssertGreaterThan(second, first)
        XCTAssertFalse(center.isOutstanding(first))
        XCTAssertTrue(center.isOutstanding(second))

        center.recordSuccess(.configuration)
        XCTAssertFalse(center.isOutstanding(second))
    }

    // MARK: - Retry

    /// Retry runs the failure's own retry, telling it which failure it
    /// retries; a retry that succeeds settles the row, and VoiceOver hears
    /// that the subsystem is saved.
    func testRetryRerunsTheFailedWriteAndSaysWhenItSucceeds() throws {
        let attempts = CallLog<PersistenceFailure.ID>()
        let center = self.center
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused()) { id in
            attempts.record(id)
            center.recordSuccess(.statistics)
        }
        let failureID = try XCTUnwrap(center.outstandingFailures().first?.id)
        recordingAnnouncements { center.publish() }

        let recorder = recordingAnnouncements { center.retry(.statistics) }

        XCTAssertEqual(attempts.calls, [failureID])
        XCTAssertTrue(center.failures.isEmpty)
        XCTAssertTrue(center.bannerRows.isEmpty)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Listening statistics saved."])
    }

    /// A retry that fails again keeps the row, which now names the newer
    /// reason, and VoiceOver hears that the retry did not succeed.
    func testRetryThatFailsAgainSaysSo() {
        let center = self.center
        center.recordFailure(.configuration, path: "/data/config.json", error: CocoaError(.fileWriteOutOfSpace)) { _ in
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        }
        recordingAnnouncements { center.publish() }

        let recorder = recordingAnnouncements { center.retry(.configuration) }

        let expected = "Settings could not be saved: The volume is read-only."
        XCTAssertEqual(center.bannerRows.map(\.text), [expected])
        XCTAssertEqual(recorder.announcements.map(\.message), ["Retry did not succeed. \(expected)"])
    }

    /// The prompt shown on quitting retries every failure that leaves
    /// changes unsaved, whatever its subsystem.
    func testRetryingUnsavedChangesRunsEveryUnsavedRetry() {
        let retried = CallLog<PersistenceSubsystem>()
        let center = self.center
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused()) { _ in
            retried.record(.libraryIndex)
            center.recordSuccess(.libraryIndex)
        }
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused()) { _ in
            retried.record(.substitutions)
        }

        recordingAnnouncements { center.retryUnsavedChanges() }

        XCTAssertEqual(retried.calls, [.libraryIndex, .substitutions])
        XCTAssertEqual(center.failures.map(\.subsystem), [.substitutions])
        XCTAssertTrue(center.hasUnsavedChanges)
    }

    // MARK: - Retries Waiting for Storage Work

    /// A retry that must wait for the storage work never runs while an
    /// operation holds it: its row says when the save comes, VoiceOver hears
    /// that, and the change is still unsaved. Once the operation ends, the
    /// retry runs by itself, for the failure outstanding then, and settles it.
    func testARetryThatWaitsForStorageWorkRunsOnlyOnceTheOperationEnds() async throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceFailure.ID>()
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused(), waitsForStorageWork: true) { id in
            attempts.record(id)
            center.recordSuccess(.statistics)
        }
        recordingAnnouncements { center.publish() }
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        defer { hold.release() }

        let pressed = recordingAnnouncements { center.retry(.statistics) }

        let waiting = "Listening statistics could not be saved: TextMouth saves them once the move of its data directory ends."
        XCTAssertEqual(attempts.calls, [], "the retry ran while a move held the storage work")
        XCTAssertEqual(center.bannerRows.map(\.text), [waiting])
        XCTAssertEqual(pressed.announcements.map(\.message), ["Retry did not succeed. \(waiting)"])
        XCTAssertTrue(center.hasUnsavedChanges, "a change waiting for the move was called saved")
        XCTAssertTrue(try XCTUnwrap(center.outstandingFailures().first).waitsForStorageWork)
        let kept = try XCTUnwrap(center.outstandingFailures().first?.id)

        hold.release()
        await waitForKeptRetries(of: center)

        XCTAssertEqual(attempts.calls, [kept], "the retry did not run once the move ended, for the failure outstanding then")
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// The kept retries are heard once they have run, in one announcement:
    /// each subsystem saved, or the rows of those that failed again, now
    /// with their own reason in place of the wait's. They run once only,
    /// however many times Retry was pressed while they waited.
    func testKeptRetriesAreHeardOnceTheyHaveRunAndRunOnce() async throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceSubsystem>()
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused(), waitsForStorageWork: true) { _ in
            attempts.record(.statistics)
            center.recordSuccess(.statistics)
        }
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused(), waitsForStorageWork: true) { _ in
            attempts.record(.configuration)
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused(), waitsForStorageWork: true)
        }
        recordingAnnouncements { center.publish() }
        let hold = try boundary.holdWork(for: .movingBooksBetweenFolders)
        defer { hold.release() }
        recordingAnnouncements {
            center.retry(.statistics)
            center.retry(.statistics)
            center.retry(.configuration)
        }

        hold.release()
        let ran = recordingAnnouncements { center.runRetriesKeptForStorageWork() }
        await waitForKeptRetries(of: center)

        XCTAssertEqual(attempts.calls, [.statistics, .configuration], "the kept retries did not each run once")
        XCTAssertEqual(ran.announcements.map(\.message), [
            "Retry did not succeed. Settings could not be saved: The volume is read-only.",
        ])
        XCTAssertEqual(center.failures.map(\.subsystem), [.configuration])
    }

    /// Storage settings' Retry Saving while a move copies the data directory
    /// keeps the retries that write into it, runs the rest at once, and says
    /// which wait; once the move ends, the kept ones run, heard together.
    func testRetryingUnsavedChangesKeepsOnlyTheRetriesThatWait() async throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let retried = CallLog<PersistenceSubsystem>()
        // The library index's retry never waits: its write is safe across a move.
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused()) { _ in
            retried.record(.libraryIndex)
            center.recordSuccess(.libraryIndex)
        }
        for (subsystem, subject, file) in [
            (PersistenceSubsystem.statistics, PersistenceFailure.Subject.statistics, "reading_stats.json"),
            (.configuration, .configuration, "config.json"),
            (.substitutions, .substitutions, "substitutions.json"),
        ] {
            center.recordFailure(subject, path: "/data/\(file)", error: WriteRefused(), waitsForStorageWork: true) { _ in
                retried.record(subsystem)
                center.recordSuccess(subject.key)
            }
        }
        recordingAnnouncements { center.publish() }
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        defer { hold.release() }

        let pressed = recordingAnnouncements { center.retryUnsavedChanges(announcing: true) }

        XCTAssertEqual(retried.calls, [.libraryIndex], "a retry ran across the move, or the index's did not run")
        let once = "TextMouth saves them once the move of its data directory ends."
        XCTAssertEqual(pressed.announcements.map(\.message), [
            "Retry did not succeed. Listening statistics could not be saved: \(once) "
                + "Settings could not be saved: \(once) Text substitution rules could not be saved: \(once)",
        ])

        hold.release()
        let ran = recordingAnnouncements { center.runRetriesKeptForStorageWork() }
        await waitForKeptRetries(of: center)

        XCTAssertEqual(retried.calls, [.libraryIndex, .statistics, .configuration, .substitutions])
        XCTAssertEqual(ran.announcements.map(\.message), [
            "Listening statistics saved. Settings saved. Text substitution rules saved.",
        ])
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// A retry that need not wait, such as a feed record's, whose store
    /// waits by itself, runs at once while storage work is held.
    func testARetryThatNeedNotWaitRunsWhileStorageWorkIsHeld() throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceFailure.ID>()
        let feedID = UUID()
        center.recordFailure(.feedRecord(feedID: feedID, title: "Tide Tables"), path: "/data/Feeds/a.json", error: WriteRefused()) { id in
            attempts.record(id)
        }
        let failureID = try XCTUnwrap(center.outstandingFailures().first?.id)
        let hold = try boundary.holdWork(for: .rebuildingDirectory)
        defer { hold.release() }

        recordingAnnouncements { center.retry(.feedRecords) }

        XCTAssertEqual(attempts.calls, [failureID])
        XCTAssertFalse(try XCTUnwrap(center.outstandingFailures().first).waitsForStorageWork)
    }

    /// An operation that takes the storage work before a kept retry's turn,
    /// as a second folder edit right after the first can, is waited for
    /// too, and the row then names it; the retry runs once that one ends.
    func testAnOperationThatTakesTheWorkBeforeTheKeptRetrysTurnIsWaitedForToo() async throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceFailure.ID>()
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused(), waitsForStorageWork: true) { id in
            attempts.record(id)
            center.recordSuccess(.substitutions)
        }
        let first = try boundary.holdWork(for: .movingBooksBetweenFolders)
        defer { first.release() }
        recordingAnnouncements { center.retry(.substitutions) }

        // In one turn of the main actor, as a second operation would.
        first.release()
        let second = try boundary.holdWork(for: .rebuildingDirectory)
        defer { second.release() }
        // The wait saw the first release; it returns having found the second
        // hold and kept the retry for it, which the row then says. Nothing
        // ran, so VoiceOver is told nothing: no "Retry did not succeed." for
        // a Retry nobody pressed. A hosted test's announcements are recorded.
        let heardBefore = VoiceOverAnnouncer.recordedAnnouncements.count
        await waitForKeptRetries(of: center)

        XCTAssertEqual(attempts.calls, [], "the kept retry ran while the second operation held the work")
        XCTAssertEqual(center.bannerRows.map(\.text), [
            "Text substitution rules could not be saved: TextMouth saves them once it has finished rebuilding its data directory.",
        ])
        let heardMeanwhile = VoiceOverAnnouncer.recordedAnnouncements.dropFirst(heardBefore).map(\.message)
        XCTAssertEqual(
            heardMeanwhile.filter { $0.contains("Text substitution rules") },
            [],
            "VoiceOver heard about the kept retry when the first operation ended"
        )

        second.release()
        await waitForKeptRetries(of: center)

        XCTAssertEqual(attempts.calls.count, 1, "the kept retry did not run once the second operation ended")
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// Reset drops the kept retries along with the failures: nothing runs
    /// when the operation ends.
    func testResetDropsTheKeptRetries() async throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceFailure.ID>()
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused(), waitsForStorageWork: true) { id in
            attempts.record(id)
        }
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        defer { hold.release() }
        recordingAnnouncements { center.retry(.configuration) }

        center.reset()
        hold.release()
        await waitForKeptRetries(of: center)
        recordingAnnouncements { center.runRetriesKeptForStorageWork() }

        XCTAssertEqual(attempts.calls, [], "a retry ran after the center was reset")
        XCTAssertTrue(center.outstandingFailures().isEmpty)
    }

    /// A kept retry whose failure is withdrawn, as a book that leaves the
    /// library withdraws its record's, runs nothing when the operation
    /// ends, and VoiceOver is not told it was saved: nothing was. It used to
    /// hear "Listening statistics saved."
    func testAWithdrawnFailuresKeptRetryIsNotHeardAsSaved() throws {
        let (center, boundary) = try centerOverItsOwnBoundary()
        let attempts = CallLog<PersistenceFailure.ID>()
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused(), waitsForStorageWork: true) { id in
            attempts.record(id)
        }
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        defer { hold.release() }
        recordingAnnouncements { center.retry(.statistics) }

        center.withdraw(.statistics)
        hold.release()
        let heard = recordingAnnouncements { center.runRetriesKeptForStorageWork() }

        XCTAssertEqual(attempts.calls, [], "the withdrawn failure's retry ran")
        XCTAssertEqual(heard.announcements.map(\.message), [], "VoiceOver was told a withdrawn change was saved")
    }

    /// What a kept retry's row says, for each operation that can hold the
    /// storage work and each thing a retry does: when it runs, or, for a
    /// switch of libraries, which ends with TextMouth opening again
    /// elsewhere, what stays as it is here. A stranded package is moved
    /// back; everything else is saved. The saving words are a feed record's
    /// for the same wait.
    func testAKeptRetrySaysWhenItRuns() {
        let said = StorageHoldReason.allCases.flatMap { operation in
            [StorageWorkWaitWording.Action.save, .moveBack].map {
                RetryWaitsForStorageWork(operation: operation, action: $0).localizedDescription
            }
        }

        XCTAssertEqual(said, [
            "TextMouth saves them once the move of its data directory ends.",
            "TextMouth moves them back once the move of its data directory ends.",
            "TextMouth saves them once it has finished rebuilding its data directory.",
            "TextMouth moves them back once it has finished rebuilding its data directory.",
            "TextMouth saves them once it has finished moving books between folders.",
            "TextMouth moves them back once it has finished moving books between folders.",
            "TextMouth is opening again on another library, so they stay unsaved in this one.",
            "TextMouth is opening again on another library, so they stay where they are in this one.",
        ])
        let stranded = PersistenceFailure.Subject.strandedPackage(bookID: UUID(), title: "Atlas", location: "/a", home: "/b")
        XCTAssertEqual(StorageWorkWaitWording.Action(for: stranded), .moveBack)
        XCTAssertEqual(StorageWorkWaitWording.Action(for: .statistics), .save)
        XCTAssertEqual(StorageWorkWaitWording.Action(for: .bookRecord(bookID: UUID(), title: "Atlas")), .save)
    }

    // MARK: - Publishing and VoiceOver

    /// A subsystem is announced once when it starts to fail, not on every
    /// repetition, and again when it fails anew after clearing.
    func testEachSubsystemIsAnnouncedOnceWhenItStartsToFail() {
        let recorder = recordingAnnouncements {
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
            center.publish()
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
            center.publish()
            center.recordSuccess(.configuration)
            center.publish()
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
            center.publish()
        }

        let announcement = "Settings could not be saved: The volume is read-only. "
            + "Details are at the top of the Library window."
        XCTAssertEqual(recorder.announcements.map(\.message), [announcement, announcement])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high])
    }

    /// Subsystems that start to fail together, as a full disk stops them,
    /// are announced in one announcement, so none cuts another short, and
    /// where to act is said once.
    func testSubsystemsThatFailTogetherAreAnnouncedTogether() {
        let recorder = recordingAnnouncements {
            center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused()) { _ in }
            center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
            center.publish()
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Library changes could not be saved: The volume is read-only. "
                + "Settings could not be saved: The volume is read-only. "
                + "Retry is at the top of the Library window."
        ])
    }

    /// Dismiss hides a row while its subsystem keeps failing, without
    /// saving anything; once the subsystem clears, its next failure is
    /// shown and announced again.
    func testDismissHidesARowUntilItsSubsystemClears() {
        let kept = UUID()
        let other = UUID()
        let recorder = recordingAnnouncements {
            center.recordFailure(.bookRecord(bookID: kept, title: "Kept"), path: "/a", error: WriteRefused())
            center.publish()
            center.dismiss(.bookRecord)
            XCTAssertTrue(center.bannerRows.isEmpty)
            XCTAssertTrue(center.hasUnsavedChanges, "dismissing saves nothing")

            center.recordFailure(.bookRecord(bookID: other, title: "Other"), path: "/b", error: WriteRefused())
            center.publish()
            XCTAssertTrue(center.bannerRows.isEmpty, "a dismissed subsystem stays hidden while it fails")

            center.recordSuccess(.book(kept))
            center.recordSuccess(.book(other))
            center.publish()
            XCTAssertTrue(center.failures.isEmpty)
            XCTAssertTrue(center.dismissedSubsystems.isEmpty)

            center.recordFailure(.bookRecord(bookID: kept, title: "Kept"), path: "/a", error: WriteRefused())
            center.publish()
        }

        XCTAssertEqual(center.bannerRows.map(\.subsystem), [.bookRecord])
        XCTAssertEqual(recorder.announcements.count, 2, "announced when it first failed and when it failed anew")
    }

    /// A report from another thread reaches the published failures on the
    /// main actor by itself.
    func testReportsFromAnyThreadArePublishedOnTheMainActor() {
        let center = self.center
        recordingAnnouncements {
            DispatchQueue.global().async {
                center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
            }
            XCTAssertTrue(waitUntil(timeout: 5) { !center.failures.isEmpty })
        }

        XCTAssertEqual(center.bannerRows.map(\.subsystem), [.configuration])
    }

    // MARK: - Banner Text

    /// Each subsystem's row names the subsystem and the reason in one
    /// sentence; a book's names the book, and a package that could not be
    /// moved back names where it is and where it belongs.
    func testBannerTextNamesTheSubsystemAndTheReason() {
        let book = UUID()
        let expectations: [(PersistenceFailure.Subject, String)] = [
            (.libraryIndex, "Library changes could not be saved: The volume is read-only."),
            (
                .bookRecord(bookID: book, title: "Moby-Dick"),
                "Changes to “Moby-Dick” could not be saved: The volume is read-only."
            ),
            (
                .strandedPackage(
                    bookID: book,
                    title: "Moby-Dick",
                    location: "/Library/New/Moby.tmb",
                    home: "/Library/Old/Moby.tmb"
                ),
                "“Moby-Dick” could not be moved back after a failed move, so its files are at "
                    + "/Library/New/Moby.tmb instead of /Library/Old/Moby.tmb: The volume is read-only."
            ),
            (.statistics, "Listening statistics could not be saved: The volume is read-only."),
            (.configuration, "Settings could not be saved: The volume is read-only."),
            (.substitutions, "Text substitution rules could not be saved: The volume is read-only."),
            (
                .feedRecord(feedID: book, title: "Ledger Lines"),
                "Changes to the feed “Ledger Lines” could not be saved: The volume is read-only."
            ),
        ]
        for (subject, expected) in expectations {
            let center = PersistenceFailureCenter()
            center.recordFailure(subject, path: "/data/file", error: WriteRefused())

            XCTAssertEqual(PersistenceBannerRow.rows(for: center.outstandingFailures()).map(\.text), [expected])
        }
    }

    /// Several books that failed share one row, led by the latest, which
    /// counts the others; the rows follow the subsystems' order.
    func testFailedBooksShareOneRowLedByTheLatest() {
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        for title in ["First", "Second", "Third"] {
            center.recordFailure(.bookRecord(bookID: UUID(), title: title), path: "/\(title)", error: WriteRefused())
        }

        let rows = PersistenceBannerRow.rows(for: center.outstandingFailures())

        XCTAssertEqual(rows.map(\.subsystem), [.bookRecord, .configuration])
        XCTAssertEqual(
            rows.first?.text,
            "Changes to “Third” could not be saved: The volume is read-only. "
                + "Changes to 2 other books could not be saved either."
        )
        XCTAssertEqual(
            PersistenceSubsystem.bookRecord.othersSentence(count: 1),
            "Changes to 1 other book could not be saved either."
        )
        XCTAssertEqual(
            PersistenceSubsystem.feedRecords.othersSentence(count: 2),
            "Changes to 2 other feeds could not be saved either."
        )
        XCTAssertEqual(PersistenceSubsystem.feedRecords.retryLabel, "Retry saving feed subscriptions")
        XCTAssertNil(PersistenceSubsystem.statistics.othersSentence(count: 0))
    }

    /// A row offers Retry only when one of its failures can be run again,
    /// and its announcement says where to act either way.
    func testARowOffersRetryOnlyWhenItCanRunAgain() {
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused()) { _ in }
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())

        let rows = PersistenceBannerRow.rows(for: center.outstandingFailures())

        XCTAssertEqual(rows.map(\.canRetry), [false, true])
        XCTAssertEqual(
            rows.last?.announcement,
            "Listening statistics could not be saved: The volume is read-only. "
                + "Retry is at the top of the Library window."
        )
    }

    /// A reason always ends as a sentence does.
    func testAReasonAlwaysEndsAsASentence() {
        XCTAssertEqual(PersistenceFailure.sentence("The disk is full"), "The disk is full.")
        XCTAssertEqual(PersistenceFailure.sentence("  The disk is full.\n"), "The disk is full.")
        XCTAssertEqual(PersistenceFailure.sentence("Is the disk full?"), "Is the disk full?")
        XCTAssertEqual(PersistenceFailure.sentence(""), "No reason was given.")
    }

    /// VoiceOver hears each banner button by the subsystem it acts on, and a
    /// row without a retry has no Retry button. SwiftUI may build the
    /// accessibility elements of its buttons only for a connected assistive
    /// app; when it exposes none here, the test is skipped, and the labels
    /// are still covered by the wording tests.
    func testTheBannersButtonsNameTheirSubsystem() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused()) { _ in }
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())
        recordingAnnouncements { center.publish() }

        try withHostedControls(PersistenceFailureBanner(center: center)) { controls in
            let labels = controls.filter { $0.role == .button }.map(\.label)
            guard !labels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertTrue(labels.contains("Retry saving settings"), "\(labels)")
            XCTAssertTrue(labels.contains("Dismiss the notice about library changes"), "\(labels)")
            XCTAssertFalse(labels.contains("Retry saving library changes"), "that failure has no retry: \(labels)")
        }
    }

    /// The banner takes room in the Library window only while it has a row:
    /// it appears with a failure and goes when the row is dismissed.
    func testTheBannerTakesRoomOnlyWhileItHasARow() {
        let hosting = NSHostingView(rootView: PersistenceFailureBanner(center: center))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, 0)

        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        recordingAnnouncements { center.publish() }
        XCTAssertTrue(waitUntil(timeout: 5) {
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height > 0
        }, "the banner did not appear")

        center.dismiss(.configuration)
        XCTAssertTrue(waitUntil(timeout: 5) {
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height == 0
        }, "the dismissed banner did not go")
    }

    /// The banner's buttons and announcements name their subsystem, so
    /// VoiceOver can tell one row's Retry from another's.
    func testButtonsAndAnnouncementsNameTheSubsystem() {
        XCTAssertEqual(PersistenceSubsystem.configuration.retryLabel, "Retry saving settings")
        XCTAssertEqual(PersistenceSubsystem.originalFileCleanup.retryLabel, "Retry removing original files")
        XCTAssertEqual(
            PersistenceSubsystem.bookRecord.dismissLabel,
            "Dismiss the notice about changes to books"
        )
        XCTAssertEqual(PersistenceSubsystem.libraryIndex.retriedAnnouncement, "Library changes saved.")
        XCTAssertEqual(PersistenceSubsystem.originalFileCleanup.retriedAnnouncement, "Original files removed.")
    }
}
