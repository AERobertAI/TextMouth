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
            [.libraryIndex, .bookRecord, .statistics, .configuration, .substitutions]
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
