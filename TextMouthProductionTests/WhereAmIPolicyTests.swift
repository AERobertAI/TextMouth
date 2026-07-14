import XCTest
@testable import TextMouth

final class WhereAmIPolicyTests: XCTestCase {
    private let briefParts = [
        "My Book", "Chapter 5 of 20", "25 percent", "3 hours remaining",
    ]
    private let fullOnlyParts = [
        "Current heading: The Battle",
        "15 minutes remaining in this heading",
        "Total book time: 4 hours",
    ]

    func testBriefSummaryIsShorterThanFullSummary() {
        let brief = ReaderViewModel.fullWhereAmISummary(parts: briefParts)
        let full = ReaderViewModel.fullWhereAmISummary(parts: briefParts + fullOnlyParts)

        XCTAssertLessThan(brief.count, full.count)
        XCTAssertLessThan(briefParts.count, (briefParts + fullOnlyParts).count)
    }

    func testRepeatWithinThreeSecondsUsesFullDetail() {
        let last = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(ReaderViewModel.shouldUseFullWhereAmI(
            last: last, now: last.addingTimeInterval(2)
        ))
    }

    func testFirstPressAfterLongGapUsesBriefDetail() {
        XCTAssertFalse(ReaderViewModel.shouldUseFullWhereAmI(last: .distantPast, now: Date()))
    }

    func testPressAtExactlyThreeSecondsUsesBriefDetail() {
        let last = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(ReaderViewModel.shouldUseFullWhereAmI(
            last: last, now: last.addingTimeInterval(3)
        ))
    }

    func testBriefSummaryIncludesPercentageButNotHeadingDetail() {
        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "Book Title",
            headingTitle: nil,
            chapterTitle: "Chapter Three",
            chapterIndex: 2,
            chapterCount: 10,
            percentComplete: 30,
            timeRemaining: 7_200
        )

        XCTAssertTrue(summary.contains("30 percent"))
        XCTAssertTrue(summary.contains("Chapter 3 of 10"))
        XCTAssertFalse(summary.contains("Current heading"))
    }

    func testFullSummaryIncludesHeadingAndTotalTime() {
        let summary = ReaderViewModel.fullWhereAmISummary(parts: briefParts + fullOnlyParts)

        XCTAssertTrue(summary.contains("Current heading: The Battle"))
        XCTAssertTrue(summary.contains("Total book time"))
    }

    func testPlaybackToggleCancelsWithoutResumingBook() {
        XCTAssertTrue(WhereAmIInterruptionPolicy.blocksBookPlayback(isAnnouncementSpeaking: true))
        XCTAssertFalse(WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: true,
            reason: .playbackToggle
        ))
    }

    func testNavigationCancellationResumesPreviouslyPlayingBook() {
        XCTAssertTrue(WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: true,
            reason: .navigationOrRepeatedCommand
        ))
    }

    func testBookPlayIsBlockedWhileAnnouncementIsActive() {
        XCTAssertTrue(WhereAmIInterruptionPolicy.blocksBookPlayback(isAnnouncementSpeaking: true))
        XCTAssertFalse(WhereAmIInterruptionPolicy.blocksBookPlayback(isAnnouncementSpeaking: false))
    }

    func testNaturalCompletionResumesPreviouslyPlayingBook() {
        XCTAssertTrue(WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: true,
            reason: .naturalCompletion
        ))
    }

    func testNaturalCompletionDoesNotStartPreviouslyStoppedBook() {
        XCTAssertFalse(WhereAmIInterruptionPolicy.shouldResume(
            wasPlayingBeforeAnnouncement: false,
            reason: .naturalCompletion
        ))
    }
}
