import XCTest
@testable import TextMouth

final class WhereAmIPolicyTests: XCTestCase {
    /// A position inside the fifth of twenty headings, as the headings panel
    /// would number it.
    private var fifthOfTwentyHeadings: HeadingPosition {
        let headings = (0..<20).map { Heading(level: 2, text: "Part \($0 + 1)", characterOffset: $0 * 100) }
        return HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 450)
    }

    /// Brief announcement for the shared fixture position.
    private func briefSummary(locationTitle: String? = "The Battle") -> String {
        ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: locationTitle,
            headingPosition: fifthOfTwentyHeadings,
            percentComplete: 25,
            timeRemaining: 10_800
        )
    }

    /// Full announcement for the shared fixture position.
    private func fullSummary(timeRemainingInHeading: TimeInterval? = 900) -> String {
        ReaderViewModel.fullWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: "The Battle",
            headingPosition: fifthOfTwentyHeadings,
            percentComplete: 25,
            timeRemaining: 10_800,
            timeRemainingInHeading: timeRemainingInHeading,
            totalTime: 14_400
        )
    }

    func testBriefSummaryIsShorterThanFullSummary() {
        XCTAssertLessThan(briefSummary().count, fullSummary().count)
    }

    func testBriefSummaryNamesTheHeadingThenItsNumber() {
        XCTAssertEqual(
            briefSummary(),
            "My Book. The Battle. Heading 5 of 20. 25 percent. 3 hours remaining."
        )
    }

    /// The full summary names the heading once (never both a content unit
    /// title and a separate "current heading"), then adds time detail.
    func testFullSummaryNamesTheHeadingOnceThenAddsTimeDetail() {
        let summary = fullSummary()

        XCTAssertEqual(
            summary,
            "My Book. The Battle. Heading 5 of 20. 25 percent through the book. "
                + "3 hours remaining. 15 minutes remaining in this heading. Total book time: 4 hours."
        )
        XCTAssertEqual(summary.components(separatedBy: "The Battle").count - 1, 1)
    }

    func testFullSummaryOmitsHeadingTimeWhenItCannotBeMeasured() {
        XCTAssertFalse(fullSummary(timeRemainingInHeading: nil).contains("remaining in this heading"))
    }

    func testSummariesNeverMentionChapters() {
        XCTAssertFalse(briefSummary().localizedCaseInsensitiveContains("chapter"))
        XCTAssertFalse(fullSummary().localizedCaseInsensitiveContains("chapter"))
    }

    /// Before the first heading there is no heading to name; the label says
    /// where the listener is instead.
    func testSummaryBeforeTheFirstHeadingSaysSo() {
        let headings = [Heading(level: 1, text: "Opening", characterOffset: 100)]
        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: nil,
            headingPosition: HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 20),
            percentComplete: 1,
            timeRemaining: 60
        )

        XCTAssertEqual(summary, "My Book. Before heading 1 of 1. 1 percent. 1 minute remaining.")
    }

    /// A book without headings has no heading number to speak, and no empty
    /// field turns into an audible pause.
    func testSummaryForABookWithoutHeadingsOmitsHeadingFields() {
        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: nil,
            headingPosition: HeadingPosition(in: [], chapterIndex: 0, characterOffset: 20),
            percentComplete: 50,
            timeRemaining: 120
        )

        XCTAssertEqual(summary, "My Book. 50 percent. 2 minutes remaining.")
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

    func testBriefSummaryIncludesPercentageButNotHeadingTimeDetail() {
        let summary = briefSummary()

        XCTAssertTrue(summary.contains("25 percent"))
        XCTAssertTrue(summary.contains("Heading 5 of 20"))
        XCTAssertFalse(summary.contains("remaining in this heading"))
        XCTAssertFalse(summary.contains("Total book time"))
    }

    func testFullSummaryIncludesHeadingAndTotalTime() {
        let summary = fullSummary()

        XCTAssertTrue(summary.contains("The Battle"))
        XCTAssertTrue(summary.contains("Heading 5 of 20"))
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
