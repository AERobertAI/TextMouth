import XCTest
@testable import TextMouth

final class WhereAmIPolicyTests: XCTestCase {
    /// A position inside the fifth of twenty headings, as the headings panel
    /// would number it.
    private var fifthOfTwentyHeadings: HeadingPosition {
        let headings = (0..<20).map { Heading(level: 2, text: "Part \($0 + 1)", characterOffset: $0 * 100) }
        return HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 450)
    }

    /// Brief announcement for the shared fixture position, quoting
    /// `heardSentence` as a transcribed audiobook's.
    private func briefSummary(locationTitle: String? = "The Battle", heardSentence: String? = nil) -> String {
        ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: locationTitle,
            headingPosition: fifthOfTwentyHeadings,
            percentComplete: 25,
            timeRemaining: 10_800,
            heardSentence: heardSentence
        )
    }

    /// Full announcement for the shared fixture position, quoting
    /// `heardSentence` as a transcribed audiobook's.
    private func fullSummary(timeRemainingInHeading: TimeInterval? = 900, heardSentence: String? = nil) -> String {
        ReaderViewModel.fullWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: "The Battle",
            headingPosition: fifthOfTwentyHeadings,
            percentComplete: 25,
            timeRemaining: 10_800,
            timeRemainingInHeading: timeRemainingInHeading,
            totalTime: 14_400,
            heardSentence: heardSentence
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

    /// A transcribed audiobook's sentence being heard is quoted after the
    /// times, as it is, with its own punctuation, in both announcements.
    func testSummariesQuoteTheSentenceHeardAfterTheTimes() {
        let heard = "The salt road bends east."

        XCTAssertEqual(
            briefSummary(heardSentence: heard),
            "My Book. The Battle. Heading 5 of 20. 25 percent. 3 hours remaining. The salt road bends east."
        )
        XCTAssertEqual(
            fullSummary(heardSentence: heard),
            "My Book. The Battle. Heading 5 of 20. 25 percent through the book. "
                + "3 hours remaining. 15 minutes remaining in this heading. Total book time: 4 hours. "
                + "The salt road bends east."
        )
    }

    /// Without a sentence to quote, or with an empty one, the
    /// announcements end with their times, as before.
    func testSummariesWithoutASentenceEndWithTheTimes() {
        XCTAssertEqual(briefSummary(heardSentence: ""), briefSummary())
        XCTAssertTrue(briefSummary().hasSuffix("3 hours remaining."))
        XCTAssertTrue(fullSummary().hasSuffix("Total book time: 4 hours."))
    }

    /// A quoted sentence is read as one line, its words one space apart, as
    /// a sentence wrapped across lines is read, and a run-on sentence stops
    /// at the word limit with an ellipsis. A sentence of no words is not
    /// quoted.
    func testAQuotedSentenceIsOneLineAndStopsAtTheWordLimit() {
        XCTAssertEqual(
            ReaderViewModel.whereAmIQuote(of: "  Tide tables\nhang  in the\toffice. "),
            "Tide tables hang in the office."
        )
        XCTAssertNil(ReaderViewModel.whereAmIQuote(of: " \n "))

        let limit = ReaderViewModel.whereAmIQuoteWordLimit
        let atLimit = (1...limit).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(ReaderViewModel.whereAmIQuote(of: atLimit), atLimit)
        let runOn = (1...(limit + 5)).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(ReaderViewModel.whereAmIQuote(of: runOn), atLimit + "…")
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
