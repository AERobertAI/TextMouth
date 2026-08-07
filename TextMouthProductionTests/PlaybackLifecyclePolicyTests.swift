import AVFoundation
import XCTest
@testable import TextMouth

@MainActor
final class PlaybackLifecyclePolicyTests: XCTestCase {
    func testActivePlaybackPersistsImmediatelyWithoutEarlierCheckpoint() {
        XCTAssertTrue(PlaybackCheckpointPolicy.shouldPersist(
            isActivelyPlaying: true,
            lastCheckpoint: nil,
            now: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func testActivePlaybackWaitsForThirtySecondCheckpointInterval() {
        let last = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(PlaybackCheckpointPolicy.shouldPersist(
            isActivelyPlaying: true,
            lastCheckpoint: last,
            now: last.addingTimeInterval(29.999)
        ))
        XCTAssertTrue(PlaybackCheckpointPolicy.shouldPersist(
            isActivelyPlaying: true,
            lastCheckpoint: last,
            now: last.addingTimeInterval(30)
        ))
    }

    func testStoppedReaderNeverCreatesPeriodicCheckpoint() {
        XCTAssertFalse(PlaybackCheckpointPolicy.shouldPersist(
            isActivelyPlaying: false,
            lastCheckpoint: nil,
            now: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func testLivePositionUpdatesSharedLibrarySnapshot() {
        let book = Book(
            title: "Live Position",
            format: .txt,
            filePath: "/tmp/live-position.txt",
            md5Hash: UUID().uuidString
        )
        let libraryViewModel = LibraryViewModel()
        libraryViewModel.library = Library(books: [book])
        let position = ReadingPosition(
            chapterIndex: 2,
            characterOffset: 75,
            globalCharacterOffset: 1_275
        )

        libraryViewModel.updateLiveReadingPosition(bookID: book.id, position: position)

        XCTAssertEqual(libraryViewModel.bookByID(book.id)?.readingPosition, position)
    }

    func testClosingStoppedReaderPersistsLatestCursor() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        try Data("First chapter\nSecond chapter".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let book = Book(
            title: "Close Checkpoint",
            format: .txt,
            filePath: sourceURL.path,
            md5Hash: UUID().uuidString
        )
        let libraryViewModel = LibraryViewModel()
        libraryViewModel.library = Library(books: [book])
        let settingsViewModel = SettingsViewModel(initializeServices: false)
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: libraryViewModel,
            settingsViewModel: settingsViewModel
        )
        reader.content = DocumentContent(
            title: book.title,
            author: book.author,
            chapters: [
                Chapter(title: "One", text: "First chapter"),
                Chapter(title: "Two", text: "Second chapter"),
            ]
        )
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 6

        reader.close()

        let stored = try XCTUnwrap(libraryViewModel.bookByID(book.id)?.readingPosition)
        XCTAssertEqual(stored.chapterIndex, 1)
        XCTAssertEqual(stored.characterOffset, 6)
        XCTAssertEqual(stored.globalCharacterOffset, "First chapter".utf16.count + 6)
        XCTAssertFalse(libraryViewModel.openBookIDs.contains(book.id))
    }

    func testPausedDirectSpeechWithoutLiveSynthRestartsAtCurrentOffset() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: true,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: false,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: false,
                currentOffset: 417,
                hasText: true
            ),
            .restartDirect(offset: 417)
        )
    }

    func testPausedDirectSpeechContinuesWhenSynthesizerStillOwnsUtterance() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: true,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: false,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: true,
                currentOffset: 24,
                hasText: true
            ),
            .continueDirect(offset: 24)
        )
    }

    func testRenderedEngineTakesPriorityOverPausedDirectSynthesizer() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: true,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: true,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: true,
                currentOffset: 88,
                hasText: true
            ),
            .switchToEngine(offset: 88)
        )
    }

    func testPendingSeekUsesDirectRestartUntilRenderIsReady() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: true,
                pendingDirectSeekOffset: 901,
                engineHasRenderedAudio: false,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: false,
                currentOffset: 100,
                hasText: true
            ),
            .restartDirect(offset: 901)
        )
    }

    func testEnginePauseUsesEngineResume() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: false,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: true,
                engineIsPaused: true,
                engineIsPlaying: false,
                directSynthIsPaused: false,
                currentOffset: 72,
                hasText: true
            ),
            .resumeEngine(offset: 72)
        )
    }

    func testBackendlessStateWithTextColdStartsDirectSpeech() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: false,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: false,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: false,
                currentOffset: 333,
                hasText: true
            ),
            .restartDirect(offset: 333)
        )
    }

    func testBackendlessStateWithoutTextReportsUnavailable() {
        XCTAssertEqual(
            SpeechResumePolicy.action(
                usingDirectMode: false,
                pendingDirectSeekOffset: nil,
                engineHasRenderedAudio: false,
                engineIsPaused: false,
                engineIsPlaying: false,
                directSynthIsPaused: false,
                currentOffset: 0,
                hasText: false
            ),
            .unavailable
        )
    }

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

    func testIdleDirectSpeechRecoveryRequiresEverySafetyCondition() {
        XCTAssertTrue(SpeechService.shouldRecoverIdleDirectSpeech(
            appIsSpeaking: true,
            appIsPaused: false,
            usingDirectMode: true,
            synthesizerIsSpeaking: false,
            synthesizerIsPaused: false,
            hasLiveUtterance: true
        ))

        let unsafeStates: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, true, false, false, true),  // App is stopped.
            (true, true, true, false, true, true),     // Playback is paused.
            (true, false, false, false, false, true),  // Audio engine owns playback.
            (true, false, true, true, false, true),    // Synthesizer is still speaking.
            (true, false, true, false, true, true),    // Synthesizer reports a pause.
            (true, false, true, false, false, false),  // No current utterance exists.
        ]
        for state in unsafeStates {
            XCTAssertFalse(SpeechService.shouldRecoverIdleDirectSpeech(
                appIsSpeaking: state.0,
                appIsPaused: state.1,
                usingDirectMode: state.2,
                synthesizerIsSpeaking: state.3,
                synthesizerIsPaused: state.4,
                hasLiveUtterance: state.5
            ))
        }
    }

    func testGenerationMustBumpBeforeLatePublishCheck() {
        let captured = 12
        let bumpedBeforeInvalidation = 13
        XCTAssertFalse(SpeechService.shouldPublishPosition(
            capturedGeneration: captured, currentGeneration: bumpedBeforeInvalidation
        ))
    }

    func testDirectSleepFadeBuildsDescendingPreconfiguredVolumes() throws {
        let text = "one two three four five six seven eight nine ten eleven twelve"
        let segments = DirectSpeechFadePlanner.segments(
            in: text,
            fromUTF16Offset: 0,
            duration: 2,
            wordsPerMinute: 240
        )

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments.first?.volume, 0.875)
        XCTAssertEqual(segments.last?.volume, 0.125)
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertGreaterThan(pair.0.volume, pair.1.volume)
            XCTAssertEqual(pair.0.endUTF16Offset, pair.1.baseUTF16Offset)
        }
    }

    func testDirectSleepFadePreservesAbsoluteUnicodeOffsets() throws {
        let text = "Preface 🎙️ café one two three four five six"
        let requestedOffset = (text as NSString).range(of: "café").location
        let segments = DirectSpeechFadePlanner.segments(
            in: text,
            fromUTF16Offset: requestedOffset,
            duration: 2,
            wordsPerMinute: 120
        )

        let first = try XCTUnwrap(segments.first)
        XCTAssertEqual(first.baseUTF16Offset, requestedOffset)
        XCTAssertTrue(first.text.hasPrefix("café"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(segments.last).endUTF16Offset, text.utf16.count)
    }

    func testDirectSleepFadeScalesEverySegmentFromCurrentTimerVolume() throws {
        let segments = DirectSpeechFadePlanner.segments(
            in: "one two three four five six seven eight",
            fromUTF16Offset: 0,
            duration: 2,
            wordsPerMinute: 200,
            startingVolume: 0.4
        )

        XCTAssertEqual(try XCTUnwrap(segments.first).volume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(segments.last).volume, 0.05, accuracy: 0.0001)
    }

    func testDirectSleepFadeQueueExhaustionContinuesBeforeTextEnd() {
        XCTAssertEqual(
            DirectSpeechFadePlanner.completionAction(
                queueEndOffset: 250,
                textUTF16Length: 1_000
            ),
            .continueFade(offset: 250)
        )
    }

    func testDirectSleepFadeQueueExhaustionFinishesAtTextEnd() {
        XCTAssertEqual(
            DirectSpeechFadePlanner.completionAction(
                queueEndOffset: 1_000,
                textUTF16Length: 1_000
            ),
            .finishChapter
        )
        XCTAssertEqual(
            DirectSpeechFadePlanner.completionAction(
                queueEndOffset: 1_001,
                textUTF16Length: 1_000
            ),
            .finishChapter
        )
    }

    func testDirectSleepFadeHandlesPunctuationOnlyTail() throws {
        let text = "Words already spoken ..."
        let punctuationOffset = (text as NSString).range(of: "...").location
        let segment = try XCTUnwrap(DirectSpeechFadePlanner.segments(
            in: text,
            fromUTF16Offset: punctuationOffset,
            duration: 2,
            wordsPerMinute: 200
        ).first)

        XCTAssertEqual(segment.baseUTF16Offset, punctuationOffset)
        XCTAssertEqual(segment.text, "...")
        XCTAssertEqual(segment.volume, 0.5)
    }

    func testDirectSleepFadePunctuationContinuationCannotBecomeLouder() throws {
        let segment = try XCTUnwrap(DirectSpeechFadePlanner.segments(
            in: "...",
            fromUTF16Offset: 0,
            duration: 2,
            wordsPerMinute: 200,
            startingVolume: 0.1
        ).first)

        XCTAssertEqual(segment.volume, 0.05, accuracy: 0.0001)
    }

    func testDirectSleepFadeRejectsEmptyOrCompletedInput() {
        XCTAssertTrue(DirectSpeechFadePlanner.segments(
            in: "",
            fromUTF16Offset: 0,
            duration: 2,
            wordsPerMinute: 200
        ).isEmpty)
        XCTAssertTrue(DirectSpeechFadePlanner.segments(
            in: "done",
            fromUTF16Offset: 4,
            duration: 2,
            wordsPerMinute: 200
        ).isEmpty)
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
