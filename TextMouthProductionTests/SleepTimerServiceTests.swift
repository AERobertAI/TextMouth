import XCTest
@testable import TextMouth

@MainActor
final class SleepTimerServiceTests: XCTestCase {
    private var service: SleepTimerService!
    private var owner: UUID!
    private var testDefaults: UserDefaults!

    /// Set-up and tear-down are the asynchronous overrides, which run on the
    /// main actor this class is isolated to, as the service and these
    /// properties require; XCTest's synchronous ones are nonisolated.
    override func setUp() async throws {
        try await super.setUp()
        // A preferences store of the test's own, kept in the sandbox and
        // emptied when the test ends, so fixture cleanup never deletes a
        // `sleepTimer.lastUsedDuration` value saved anywhere else.
        testDefaults = makeSandboxedPreferences("sleep-timer")
        service = SleepTimerService(userDefaults: testDefaults)
        service._resetForTesting()
        owner = UUID()
    }

    override func tearDown() async throws {
        service._resetForTesting()
        service = nil
        owner = nil
        testDefaults = nil
        try await super.tearDown()
    }

    /// Starts a timer with inert callbacks unless a test supplies behavior.
    private func start(
        _ duration: SleepTimerDuration,
        ownerID: UUID? = nil,
        fade: TimeInterval = 0,
        onExpire: @escaping () -> Void = {}
    ) {
        service.start(
            duration: duration,
            ownerID: ownerID ?? owner,
            onExpire: onExpire,
            fadeOutDuration: fade
        )
    }

    func testReadingPositionDefaults() {
        let position = ReadingPosition()

        XCTAssertEqual(position.chapterIndex, 0)
        XCTAssertNil(position.headingIndex)
        XCTAssertEqual(position.characterOffset, 0)
        XCTAssertNil(position.globalCharacterOffset)
    }

    func testBookEstimateRequiresCounts() {
        let book = Book(title: "Test", format: .txt, filePath: "test.txt", md5Hash: "hash")

        XCTAssertNil(book.estimatedTimeRemaining(wpm: 200))
    }

    func testBookEstimateUsesReadingPosition() {
        let book = Book(
            title: "Test",
            format: .txt,
            filePath: "test.txt",
            md5Hash: "hash",
            readingPosition: ReadingPosition(globalCharacterOffset: 25_000),
            totalWordCount: 10_000,
            totalCharacterCount: 50_000
        )

        XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), 1_500)
    }

    func testBookEstimateAtStartAndEnd() {
        var book = Book(
            title: "Test",
            format: .txt,
            filePath: "test.txt",
            md5Hash: "hash",
            readingPosition: ReadingPosition(globalCharacterOffset: 0),
            totalWordCount: 10_000,
            totalCharacterCount: 50_000
        )
        XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), 3_000)

        book.readingPosition = ReadingPosition(globalCharacterOffset: 50_000)
        XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), 0)
    }

    func testLibraryAndReaderTextEstimatesUseSameSnapshot() {
        let totalWords = 12_000
        let totalCharacters = 60_000
        let cursor = 18_000
        let wpm = 240.0
        let totalDuration = Double(totalWords) / wpm * 60
        let book = Book(
            title: "Test",
            format: .txt,
            filePath: "test.txt",
            md5Hash: "hash",
            readingPosition: ReadingPosition(globalCharacterOffset: cursor),
            totalWordCount: totalWords,
            totalCharacterCount: totalCharacters
        )
        let readerEstimate = ReadingTimeEstimator.remaining(
            totalDuration: totalDuration,
            globalOffset: cursor,
            totalCharacterCount: totalCharacters
        )

        XCTAssertEqual(book.estimatedTimeRemaining(wpm: wpm), readerEstimate)
    }

    func testAudioEstimateUsesAnalyzedDurationInsteadOfPlaceholderRounding() {
        let analyzedDuration: TimeInterval = 7_321.75
        let totalCharacters = 73_200
        let cursor = 18_300
        let book = Book(
            title: "Audio",
            format: .audio,
            filePath: "audio.m4b",
            md5Hash: "hash",
            readingPosition: ReadingPosition(globalCharacterOffset: cursor),
            totalCharacterCount: totalCharacters,
            localWPM: 1.25,
            audioDuration: analyzedDuration
        )
        let readerEstimate = ReadingTimeEstimator.remaining(
            totalDuration: analyzedDuration / 1.25,
            globalOffset: cursor,
            totalCharacterCount: totalCharacters
        )

        XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), readerEstimate)
    }

    func testMinuteCountdownExpiresAtZero() {
        var expirations = 0
        start(.minutes(1), onExpire: { expirations += 1 })

        for _ in 0..<59 { service._advanceCountdownForTesting() }
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.remainingSeconds, 1)

        service._advanceCountdownForTesting()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(expirations, 1)
    }

    /// Finding #787: a timer for the end of a heading ends at the first end
    /// of its heading its owner reaches, once, not at the second. As at a
    /// chapter's end, the owner stops playback there and says so itself, so
    /// no expiry callback runs, and the duration stays for Restart Sleep
    /// Timer.
    func testAHeadingTimerEndsAtItsOwnersFirstHeadingEnd() {
        var expirations = 0
        start(.endOfHeading, onExpire: { expirations += 1 })
        XCTAssertTrue(service.waitsForHeadingEnd(ownedBy: owner))

        XCTAssertTrue(service.expireAtHeadingEnd(by: owner))

        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.duration)
        XCTAssertNil(service.ownerID)
        XCTAssertEqual(expirations, 0, "The expiry callback was called at the heading's end")
        XCTAssertEqual(service.lastUsedDuration, .endOfHeading)
        XCTAssertEqual(service.lastOwnerID, owner)
        XCTAssertFalse(service.waitsForHeadingEnd(ownedBy: owner))
        XCTAssertFalse(service.expireAtHeadingEnd(by: owner), "An ended timer ended again")
    }

    /// Only a timer for the end of a heading ends where a heading does: one
    /// counting minutes, or waiting for a chapter's or the book's end, goes
    /// on, and nothing happens with no timer at all.
    func testOnlyAHeadingTimerEndsWhereAHeadingEnds() {
        XCTAssertFalse(service.expireAtHeadingEnd(by: owner), "No timer ended")
        for duration: SleepTimerDuration in [.minutes(10), .endOfChapter, .endOfBook] {
            start(duration)
            XCTAssertFalse(service.waitsForHeadingEnd(ownedBy: owner), duration.displayName)
            XCTAssertFalse(service.expireAtHeadingEnd(by: owner), duration.displayName)
            XCTAssertTrue(service.isActive, duration.displayName)
            XCTAssertEqual(service.duration, duration)
        }
    }

    func testFormattedRemainingForEveryDuration() {
        start(.minutes(5))
        XCTAssertEqual(service.formattedRemaining, "5:00")
        for _ in 0..<235 { service._advanceCountdownForTesting() }
        XCTAssertEqual(service.formattedRemaining, "1:05")

        start(.endOfHeading)
        XCTAssertEqual(service.formattedRemaining, "End of heading")
        start(.endOfChapter)
        XCTAssertEqual(service.formattedRemaining, "End of chapter")
        start(.endOfBook)
        XCTAssertEqual(service.formattedRemaining, "End of book")
        service.stop()
        XCTAssertEqual(service.formattedRemaining, "")
    }

    /// VoiceOver reads the timer's status as the time left, or as where a
    /// timer set for a place in the book stops playback, never as "End of
    /// heading remaining"; and as fading out while a fade runs. The sheet
    /// and the reader's indicators read it named as the sleep timer's.
    func testSpokenStatusSaysWhereTheTimerStopsPlayback() {
        XCTAssertEqual(service.spokenStatus, "")
        XCTAssertEqual(service.spokenLabel, "")

        start(.minutes(5))
        service._advanceCountdownForTesting()
        XCTAssertEqual(service.spokenStatus, "4:59 remaining")
        XCTAssertEqual(service.spokenLabel, "Sleep timer: 4:59 remaining")

        let places: [(duration: SleepTimerDuration, status: String)] = [
            (.endOfHeading, "stops at the end of this heading"),
            (.endOfChapter, "stops at the end of this chapter"),
            (.endOfBook, "stops at the end of the book"),
        ]
        for place in places {
            start(place.duration)
            XCTAssertEqual(service.spokenStatus, place.status, place.duration.displayName)
            XCTAssertEqual(service.spokenLabel, "Sleep timer: \(place.status)", place.duration.displayName)
        }

        start(.minutes(1), fade: 30)
        service._expireForTesting()
        XCTAssertEqual(service.spokenLabel, "Sleep timer: fading out")
    }

    func testAutoCloseDefaultsTrue() {
        XCTAssertTrue(ConfigService.AppConfig().sleepTimerAutoClose)
    }

    func testAutoCloseRoundTripsThroughJSON() throws {
        var config = ConfigService.AppConfig()
        config.sleepTimerAutoClose = false

        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertFalse(decoded.sleepTimerAutoClose)
    }

    func testMissingAutoCloseSettingDefaultsTrue() throws {
        let data = try XCTUnwrap(#"{"sleepFadeOutDuration":5}"#.data(using: .utf8))

        XCTAssertTrue(
            try JSONDecoder().decode(ConfigService.AppConfig.self, from: data).sleepTimerAutoClose
        )
    }

    func testRestartRestoresFullMinuteDuration() {
        start(.minutes(15))
        for _ in 0..<300 { service._advanceCountdownForTesting() }
        XCTAssertEqual(service.remainingSeconds, 600)

        service.restart()
        XCTAssertEqual(service.remainingSeconds, 900)
        XCTAssertEqual(service.duration, .minutes(15))
    }

    /// A heading timer restarted still waits for its owner's heading end,
    /// and ends at the first.
    func testRestartKeepsAHeadingTimerWaitingForItsOwner() {
        start(.endOfHeading)

        service.restart()

        XCTAssertTrue(service.waitsForHeadingEnd(ownedBy: owner))
        XCTAssertTrue(service.expireAtHeadingEnd(by: owner))
        XCTAssertFalse(service.isActive)
    }

    func testRestartWithoutActiveTimerIsNoOp() {
        service.restart()

        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.duration)
    }

    func testStartSetsActiveDurationOwnerAndSeconds() {
        start(.minutes(30))

        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.duration, .minutes(30))
        XCTAssertEqual(service.ownerID, owner)
        XCTAssertEqual(service.remainingSeconds, 1_800)
    }

    func testStopClearsActiveStateAndCallbacks() {
        start(.minutes(10))

        service.stop()

        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.duration)
        XCTAssertNil(service.ownerID)
        XCTAssertNil(service.onTimerExpired)
        XCTAssertEqual(service.remainingSeconds, 0)
    }

    func testCancelThenResetStartsCleanly() {
        start(.minutes(10))
        service.stop()

        start(.minutes(45))

        XCTAssertEqual(service.duration, .minutes(45))
        XCTAssertEqual(service.remainingSeconds, 2_700)
        XCTAssertTrue(service.isActive)
    }

    func testPauseHoldsRemainingTime() {
        start(.minutes(2))
        service._advanceCountdownForTesting()
        service.pauseCountdown(by: owner)

        for _ in 0..<60 { service._advanceCountdownForTesting() }

        XCTAssertEqual(service.remainingSeconds, 119)
    }

    func testResumeContinuesFromHeldTime() {
        start(.minutes(5))
        for _ in 0..<10 { service._advanceCountdownForTesting() }
        service.pauseCountdown(by: owner)
        for _ in 0..<1_000 { service._advanceCountdownForTesting() }

        service.resumeCountdown(by: owner)
        service._advanceCountdownForTesting()

        XCTAssertEqual(service.remainingSeconds, 289)
    }

    func testPauseDoesNotChangeHeadingTimer() {
        start(.endOfHeading)

        service.pauseCountdown(by: owner)

        XCTAssertTrue(service.isActive)
        XCTAssertTrue(service.expireAtHeadingEnd(by: owner))
        XCTAssertFalse(service.isActive)
    }

    func testPauseDoesNotChangeChapterTimer() {
        start(.endOfChapter)

        service.pauseCountdown(by: owner)
        XCTAssertTrue(service.isActive)
        XCTAssertTrue(service.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: false, ownedBy: owner))
        service.expireAtChapterEnd(endingTheHeading: false, endingTheBook: false, by: owner)

        XCTAssertFalse(service.isActive)
    }

    func testResumeWithoutPauseDoesNotDuplicateCountdown() {
        start(.minutes(10))

        service.resumeCountdown(by: owner)
        service._advanceCountdownForTesting()

        XCTAssertEqual(service.remainingSeconds, 599)
    }

    func testResumeWithoutActiveTimerDoesNothing() {
        service.resumeCountdown(by: owner)

        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.remainingSeconds, 0)
    }

    func testPauseDoesNotInterruptActiveFade() {
        start(.minutes(1), fade: 30)
        service._expireForTesting()
        XCTAssertTrue(service.isFadingOut)

        service.pauseCountdown(by: owner)

        XCTAssertTrue(service.isFadingOut)
        XCTAssertTrue(service.isActive)
    }

    func testStoppingActiveFadeInvokesCancellationCleanupOnce() {
        var cancellationCount = 0
        service.start(
            duration: .minutes(1),
            ownerID: owner,
            onExpire: {},
            onFadeCancelled: { cancellationCount += 1 },
            fadeOutDuration: 30
        )
        service._expireForTesting()

        service.stop()
        service.stop()

        XCTAssertEqual(cancellationCount, 1)
    }

    func testReplacingActiveFadeCleansUpPreviousOwner() {
        var previousOwnerCleanups = 0
        service.start(
            duration: .minutes(1),
            ownerID: owner,
            onExpire: {},
            onFadeCancelled: { previousOwnerCleanups += 1 },
            fadeOutDuration: 30
        )
        service._expireForTesting()

        start(.minutes(5), ownerID: UUID())

        XCTAssertEqual(previousOwnerCleanups, 1)
        XCTAssertTrue(service.isActive)
        XCTAssertFalse(service.isFadingOut)
    }

    func testOrdinaryTimerStopDoesNotInvokeFadeCancellationCleanup() {
        var cancellationCount = 0
        service.start(
            duration: .minutes(10),
            ownerID: owner,
            onExpire: {},
            onFadeCancelled: { cancellationCount += 1 },
            fadeOutDuration: 30
        )

        service.stop()

        XCTAssertEqual(cancellationCount, 0)
    }

    func testStopClearsPausedStateForNextTimer() {
        start(.minutes(10))
        service.pauseCountdown(by: owner)
        service.stop()

        start(.minutes(5))
        service._advanceCountdownForTesting()

        XCTAssertEqual(service.remainingSeconds, 299)
    }

    func testLongBreakDoesNotConsumePausedCountdown() {
        start(.minutes(10))
        for _ in 0..<5 { service._advanceCountdownForTesting() }
        service.pauseCountdown(by: owner)
        for _ in 0..<(30 * 60) { service._advanceCountdownForTesting() }
        XCTAssertEqual(service.remainingSeconds, 595)

        service.resumeCountdown(by: owner)
        for _ in 0..<5 { service._advanceCountdownForTesting() }
        XCTAssertEqual(service.remainingSeconds, 590)
    }

    func testNewOwnerReplacesExistingTimer() {
        let firstOwner = UUID()
        start(.minutes(20), ownerID: firstOwner)

        start(.minutes(5), ownerID: owner)

        XCTAssertEqual(service.ownerID, owner)
        XCTAssertEqual(service.duration, .minutes(5))
        XCTAssertEqual(service.remainingSeconds, 300)
    }

    func testNonOwnerCannotPauseCountdown() {
        start(.minutes(10))

        service.pauseCountdown(by: UUID())
        service._advanceCountdownForTesting()

        XCTAssertEqual(service.remainingSeconds, 599)
    }

    func testNonOwnerCannotResumeCountdown() {
        start(.minutes(10))
        service.pauseCountdown(by: owner)

        service.resumeCountdown(by: UUID())
        service._advanceCountdownForTesting()

        XCTAssertEqual(service.remainingSeconds, 600)
    }

    /// Another reader's heading end, even one of the same book, ends no
    /// heading timer; the owner's first one does.
    func testOnlyTheOwnersHeadingEndEndsAHeadingTimer() {
        start(.endOfHeading)
        let otherReader = UUID()

        XCTAssertFalse(service.waitsForHeadingEnd(ownedBy: otherReader))
        XCTAssertFalse(service.expireAtHeadingEnd(by: otherReader))
        XCTAssertTrue(service.isActive, "Another reader's heading end ended the timer")

        XCTAssertTrue(service.expireAtHeadingEnd(by: owner))
        XCTAssertFalse(service.isActive)
    }

    /// Only the owner's chapter end ends a timer set for the end of the
    /// chapter. Ending it there calls no expiry callback, since the owner
    /// has already stopped at the chapter's end and says so itself; the
    /// timer ends as a stop ends it, keeping the duration for Restart Sleep
    /// Timer.
    func testOnlyOwnerExpiresChapterTimer() {
        var expirations = 0
        start(.endOfChapter, onExpire: { expirations += 1 })

        XCTAssertFalse(service.expireAtChapterEnd(endingTheHeading: false, endingTheBook: false, by: UUID()))
        XCTAssertTrue(service.isActive, "Another owner's chapter end ended the timer")
        XCTAssertTrue(service.expireAtChapterEnd(endingTheHeading: false, endingTheBook: false, by: owner))

        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.duration)
        XCTAssertNil(service.ownerID)
        XCTAssertEqual(expirations, 0, "The expiry callback was called at the chapter's end")
        XCTAssertEqual(service.lastUsedDuration, .endOfChapter)
        XCTAssertEqual(service.lastOwnerID, owner)
        XCTAssertFalse(
            service.expireAtChapterEnd(endingTheHeading: false, endingTheBook: false, by: owner),
            "An ended timer ended again"
        )
    }

    /// Which timers stop playback where a chapter ends: the owner's, while
    /// in effect, when set for the end of the chapter, at every chapter's
    /// end, the book's last included; when set for the end of a heading,
    /// where that heading ends too and where the book ends (finding #787);
    /// and when set for the end of the book, at the last chapter's end only.
    /// A timer counting minutes stops at none, and neither does another
    /// owner's or one that has ended.
    func testOnlyTheOwnersEndOfChapterTimerStopsPlaybackAtAChaptersEnd() {
        let otherOwner = UUID()
        let cases: [(
            name: String, duration: SleepTimerDuration?, asker: UUID,
            endingTheHeading: Bool, endingTheBook: Bool, stops: Bool
        )] = [
            ("end of chapter, a chapter before the last", .endOfChapter, owner, false, false, true),
            ("end of chapter, the book's last chapter", .endOfChapter, owner, false, true, true),
            ("end of chapter, asked by another owner", .endOfChapter, otherOwner, false, false, false),
            ("end of book, a chapter before the last", .endOfBook, owner, false, false, false),
            ("end of book, a chapter ending a heading", .endOfBook, owner, true, false, false),
            ("end of book, the book's last chapter", .endOfBook, owner, false, true, true),
            ("end of book, asked by another owner", .endOfBook, otherOwner, false, true, false),
            ("end of a heading, a chapter the heading goes on after", .endOfHeading, owner, false, false, false),
            ("end of a heading, a chapter ending it", .endOfHeading, owner, true, false, true),
            ("end of a heading, the book's last chapter", .endOfHeading, owner, false, true, true),
            ("end of a heading, asked by another owner", .endOfHeading, otherOwner, true, false, false),
            ("minutes", .minutes(30), owner, false, false, false),
            ("minutes, a chapter ending a heading", .minutes(30), owner, true, false, false),
            ("minutes, the book's last chapter", .minutes(30), owner, false, true, false),
            ("no timer", nil, owner, true, true, false),
        ]
        for timer in cases {
            service.stop()
            if let duration = timer.duration {
                start(duration)
            }
            XCTAssertEqual(
                service.stopsPlaybackAtChapterEnd(
                    endingTheHeading: timer.endingTheHeading,
                    endingTheBook: timer.endingTheBook,
                    ownedBy: timer.asker
                ),
                timer.stops,
                timer.name
            )
        }

        start(.endOfChapter)
        service._expireForTesting()
        XCTAssertFalse(
            service.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: false, ownedBy: owner),
            "A timer that has run out stops playback at a chapter's end"
        )
    }

    func testStopClearsOwnershipBeforeFreshStart() {
        start(.minutes(10))
        service.stop()
        XCTAssertNil(service.ownerID)

        let replacement = UUID()
        start(.minutes(5), ownerID: replacement)
        XCTAssertEqual(service.ownerID, replacement)
    }

    func testReplacementDoesNotInheritPausedState() {
        let firstOwner = UUID()
        start(.minutes(20), ownerID: firstOwner)
        service.pauseCountdown(by: firstOwner)

        start(.minutes(5), ownerID: owner)
        service.pauseCountdown(by: firstOwner)
        service._advanceCountdownForTesting()
        XCTAssertEqual(service.remainingSeconds, 299)

        service.pauseCountdown(by: owner)
        service._advanceCountdownForTesting()
        XCTAssertEqual(service.remainingSeconds, 299)
    }

    /// A reader that closes forgets itself as the last owner only when it
    /// set the most recent timer; the duration is kept either way, for
    /// Restart Sleep Timer in another reader.
    func testForgettingTheLastOwnerKeepsTheDuration() {
        start(.minutes(20))
        service.stop()

        service.forgetLastOwner(UUID())
        XCTAssertEqual(service.lastOwnerID, owner, "Another reader's closing forgot the last owner")

        service.forgetLastOwner(owner)
        XCTAssertNil(service.lastOwnerID)
        XCTAssertEqual(service.lastUsedDuration, .minutes(20))
    }

    func testLastUsedDurationSurvivesStop() {
        start(.minutes(20))

        service.stop()

        XCTAssertNil(service.duration)
        XCTAssertEqual(service.lastUsedDuration, .minutes(20))
    }

    func testLastOwnerSurvivesStop() {
        start(.minutes(20))

        service.stop()

        XCTAssertNil(service.ownerID)
        XCTAssertEqual(service.lastOwnerID, owner)
    }

    func testNewStartOverwritesLastUsedDuration() {
        start(.minutes(10))

        start(.minutes(30))

        XCTAssertEqual(service.lastUsedDuration, .minutes(30))
    }

    func testLastUsedDurationPersistsAcrossServiceInstances() {
        for duration: SleepTimerDuration in [.endOfHeading, .endOfBook, .minutes(25)] {
            start(duration)

            let restored = SleepTimerService(userDefaults: testDefaults)

            XCTAssertEqual(restored.lastUsedDuration, duration)
        }
    }

    /// Every saved kind of place-based timer besides End of book restores
    /// End of heading, the one such timer since October 6, 2026, so that
    /// Restart Sleep Timer arms the timer the listener last chose: "endOfHeading",
    /// its own name, which is what is saved from then on; "endOfChapter",
    /// saved while the sheet offered End of chapter, which folded into End
    /// of heading; and "endOfDocument", saved while it offered End of
    /// document, which End of chapter had replaced.
    func testEverySavedPlaceBasedKindRestoresEndOfHeading() throws {
        let key = "sleepTimer.lastUsedDuration"
        for savedKind in ["endOfHeading", "endOfChapter", "endOfDocument"] {
            testDefaults.set(Data(#"{"kind":"\#(savedKind)"}"#.utf8), forKey: key)

            let restored = SleepTimerService(userDefaults: testDefaults)
            defer { restored._resetForTesting() }

            XCTAssertEqual(restored.lastUsedDuration, .endOfHeading, "A saved \(savedKind) did not restore End of heading")
            restored.start(duration: try XCTUnwrap(restored.lastUsedDuration), onExpire: {})
            let saved = try XCTUnwrap(testDefaults.data(forKey: key))
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: saved) as? [String: String],
                ["kind": "endOfHeading"],
                "Restarting a saved \(savedKind) did not save End of heading"
            )
        }
    }

    /// The restored duration is editable with `defaults write`. Minutes above
    /// the sheet's range are clamped, so re-arming the timer cannot overflow
    /// converting them to seconds; zero or negative minutes restore nothing.
    func testRestoredMinutesAreLimitedToTheSupportedRange() throws {
        let key = "sleepTimer.lastUsedDuration"
        testDefaults.set(Data(#"{"kind":"minutes","minutes":9223372036854775807}"#.utf8), forKey: key)
        let restored = SleepTimerService(userDefaults: testDefaults)
        defer { restored._resetForTesting() }

        XCTAssertEqual(restored.lastUsedDuration, .minutes(480))
        restored.start(duration: try XCTUnwrap(restored.lastUsedDuration), onExpire: {})
        XCTAssertEqual(restored.remainingSeconds, 480 * 60)

        for minutes in [0, -5] {
            testDefaults.set(Data(#"{"kind":"minutes","minutes":\#(minutes)}"#.utf8), forKey: key)
            XCTAssertNil(SleepTimerService(userDefaults: testDefaults).lastUsedDuration, "\(minutes)")
        }
        testDefaults.set(Data(#"{"kind":"minutes","minutes":45}"#.utf8), forKey: key)
        XCTAssertEqual(SleepTimerService(userDefaults: testDefaults).lastUsedDuration, .minutes(45))
    }

    func testFixturePersistenceDoesNotTouchStandardDefaults() {
        let key = "sleepTimer.lastUsedDuration"
        let standardValueBeforeTest = UserDefaults.standard.data(forKey: key)

        start(.minutes(45))
        XCTAssertNotNil(testDefaults.data(forKey: key))
        service._resetForTesting()

        XCTAssertNil(testDefaults.data(forKey: key))
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), standardValueBeforeTest)
    }

    func testFadeReachesZeroBeforeExpiryCallback() {
        let expired = expectation(description: "fade expires")
        var steps: [Float] = []
        var volumeAtExpiry: Float?
        service.start(
            duration: .minutes(1),
            ownerID: owner,
            onExpire: {
                volumeAtExpiry = steps.last
                expired.fulfill()
            },
            onFadeStep: { steps.append($0) },
            fadeOutDuration: 0.05
        )

        service._expireForTesting()
        wait(for: [expired], timeout: 1)

        XCTAssertEqual(volumeAtExpiry, 0)
        XCTAssertFalse(service.isActive)
        XCTAssertFalse(service.isFadingOut)
    }

    func testFadeCompletionLatchIsOneShot() {
        let expired = expectation(description: "fade expires")
        start(.minutes(1), fade: 0.05, onExpire: { expired.fulfill() })
        service._expireForTesting()
        wait(for: [expired], timeout: 1)

        XCTAssertTrue(service.consumePendingFadeCompletion())
        XCTAssertFalse(service.consumePendingFadeCompletion())
    }

    func testStopClearsUnconsumedFadeCompletion() {
        let expired = expectation(description: "fade expires")
        start(.minutes(1), fade: 0.05, onExpire: { expired.fulfill() })
        service._expireForTesting()
        wait(for: [expired], timeout: 1)

        service.stop()

        XCTAssertFalse(service.consumePendingFadeCompletion())
    }

    // MARK: - The Timer's Log

    /// A timer's session events, such as its start and stop, are always
    /// written to the timer's own log. The countdown's progress, written
    /// every minute and through the last ten seconds, is trace: it appears
    /// only while tracing is on (TODO Q07).
    func testTimerLogKeepsSessionEventsAndTracesCountdownProgress() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()

        setAppTracing(false)
        let quiet = logLines(in: .sleepTimer) { runOneMinuteOfAFiveMinuteTimer() }
        setAppTracing(true)
        let traced = logLines(in: .sleepTimer) { runOneMinuteOfAFiveMinuteTimer() }

        for lines in [quiet, traced] {
            XCTAssertTrue(lines.contains { $0.contains(": START kind=minutes requestedMinutes=5 ") }, "\(lines)")
            XCTAssertTrue(lines.contains { $0.contains(": STOP reason=requested ") }, "\(lines)")
        }
        XCTAssertFalse(quiet.contains { $0.contains("COUNTDOWN_PROGRESS") }, "\(quiet)")
        XCTAssertTrue(
            traced.contains {
                $0.contains(": TRACE playback: COUNTDOWN_PROGRESS active=true ") && $0.contains(" remaining=240 ")
            },
            "\(traced)"
        )
    }

    /// A timer set for a place in the book names that place in its START
    /// event: end-of-heading for the one place-based timer any document
    /// has, and end-of-book; no timer is logged as end-of-chapter.
    func testTimerLogNamesThePlaceAPlaceBasedTimerWaitsFor() throws {
        try TextMouthPaths.ensureDirectoryStructure()

        let lines = logLines(in: .sleepTimer) {
            start(.endOfHeading)
            start(.endOfBook)
            service.stop()
        }

        XCTAssertTrue(lines.contains { $0.contains(": START kind=end-of-heading ") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains(": START kind=end-of-book ") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("end-of-chapter") }, "\(lines)")
    }

    /// Start a five-minute timer, count down its first minute without
    /// waiting for it, and stop it.
    private func runOneMinuteOfAFiveMinuteTimer() {
        start(.minutes(5))
        for _ in 0..<60 {
            service._advanceCountdownForTesting()
        }
        service.stop()
    }
}
