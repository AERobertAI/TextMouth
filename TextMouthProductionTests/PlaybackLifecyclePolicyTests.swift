import AVFoundation
import XCTest
@testable import TextMouth

@MainActor
final class PlaybackLifecyclePolicyTests: XCTestCase {
    func testLiveUtteranceFinishIsAccepted() {
        let utterance = AVSpeechUtterance(string: "live")
        XCTAssertTrue(SpeechService.isLiveDirectUtterance(utterance, liveUtterance: utterance))
    }

    func testStaleUtteranceFinishIsRejectedAfterReplacement() {
        let stale = AVSpeechUtterance(string: "stale")
        let current = AVSpeechUtterance(string: "current")
        XCTAssertFalse(SpeechService.isLiveDirectUtterance(stale, liveUtterance: current))
    }

    func testDuplicateFinishIsRejectedAfterLiveMarkerClears() {
        let utterance = AVSpeechUtterance(string: "once")
        XCTAssertFalse(SpeechService.isLiveDirectUtterance(utterance, liveUtterance: nil))
    }

    func testMissingOldFinishDoesNotInvalidateNewUtterance() {
        let replacement = AVSpeechUtterance(string: "replacement")
        XCTAssertTrue(SpeechService.isLiveDirectUtterance(replacement, liveUtterance: replacement))
    }

    func testPositionPublishIsDroppedAfterSeekGenerationChange() {
        XCTAssertFalse(SpeechService.shouldPublishPosition(capturedGeneration: 0, currentGeneration: 1))
    }

    func testPositionPublishLandsWithoutGenerationChange() {
        XCTAssertTrue(SpeechService.shouldPublishPosition(capturedGeneration: 4, currentGeneration: 4))
    }

    func testPositionPublishIsDroppedAfterStopGenerationChange() {
        XCTAssertFalse(SpeechService.shouldPublishPosition(capturedGeneration: 7, currentGeneration: 8))
    }

    func testPositionRestartEstablishesFreshGeneration() {
        XCTAssertTrue(SpeechService.shouldPublishPosition(capturedGeneration: 9, currentGeneration: 9))
        XCTAssertFalse(SpeechService.shouldPublishPosition(capturedGeneration: 8, currentGeneration: 9))
    }

    func testGenerationMustBumpBeforeLatePublishCheck() {
        let captured = 12
        let bumpedBeforeInvalidation = 13
        XCTAssertFalse(SpeechService.shouldPublishPosition(
            capturedGeneration: captured, currentGeneration: bumpedBeforeInvalidation
        ))
    }

    func testPauseWhilePlayingPersistsStoppedState() {
        XCTAssertTrue(ReaderViewModel.wasActivelyPlaying(isPlaying: true, isPaused: false))
    }

    func testPauseWhileAlreadyPausedDoesNotPersistStoppedState() {
        XCTAssertFalse(ReaderViewModel.wasActivelyPlaying(isPlaying: true, isPaused: true))
    }

    func testPauseWhileStoppedDoesNotPersistStoppedState() {
        XCTAssertFalse(ReaderViewModel.wasActivelyPlaying(isPlaying: false, isPaused: false))
    }

    func testNoOpPauseCannotQualifyForTimestampOverwrite() {
        XCTAssertFalse(ReaderViewModel.wasActivelyPlaying(isPlaying: false, isPaused: true))
    }

    func testSmallChapterAlwaysRefreshesVisibleText() {
        XCTAssertTrue(refresh(length: 100, chapter: 0, offset: 50, cachedChapter: 0, start: 0, end: 100))
    }

    func testMissingVisibleWindowCacheRequiresRefresh() {
        XCTAssertTrue(refresh(length: 40_000, chapter: 0, offset: 20_000, cachedChapter: nil, start: nil, end: nil))
    }

    func testPositionInsideGuardBandKeepsVisibleWindowStable() {
        XCTAssertFalse(refresh(length: 40_000, chapter: 0, offset: 10_000, cachedChapter: 0, start: 0, end: 20_000))
    }

    func testLeavingGuardBandOrChangingChapterRefreshesVisibleWindow() {
        XCTAssertTrue(refresh(length: 40_000, chapter: 0, offset: 1_000, cachedChapter: 0, start: 0, end: 20_000))
        XCTAssertTrue(refresh(length: 40_000, chapter: 1, offset: 10_000, cachedChapter: 0, start: 0, end: 20_000))
    }

    func testHeadingIdentityChangesOnlyAtHeadingBoundaries() {
        let headings = [
            Heading(level: 1, text: "One", characterOffset: 0),
            Heading(level: 1, text: "Two", characterOffset: 350),
            Heading(level: 1, text: "Three", characterOffset: 700),
        ]
        var previousID: String? = nil
        var changes = 0
        for offset in 0..<1_000 {
            let currentID = ReaderViewModel.currentHeading(
                in: headings, chapterIndex: 0, characterOffset: offset
            )?.id
            if currentID != previousID {
                previousID = currentID
                changes += 1
            }
        }
        XCTAssertEqual(changes, 3)
    }

    private func refresh(
        length: Int,
        chapter: Int,
        offset: Int,
        cachedChapter: Int?,
        start: Int?,
        end: Int?
    ) -> Bool {
        VisibleTextWindowPolicy.shouldRefresh(
            chapterTextLength: length,
            maximumDisplayLength: 20_000,
            cachedChapterIndex: cachedChapter,
            windowStart: start,
            windowEnd: end,
            chapterIndex: chapter,
            offset: offset,
            guardFraction: 0.25
        )
    }
}
