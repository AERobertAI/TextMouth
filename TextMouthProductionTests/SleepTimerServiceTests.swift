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
        XCTAssertFalse(service.waitsForHeadingEnd(ownedBy: owner))
        XCTAssertFalse(service.expireAtHeadingEnd(by: owner), "An ended timer ended again")
    }

    /// Only a timer for the end of a heading ends where a heading does: one
    /// counting minutes, or waiting for the book's end, goes on, and nothing
    /// happens with no timer at all.
    func testOnlyAHeadingTimerEndsWhereAHeadingEnds() {
        XCTAssertFalse(service.expireAtHeadingEnd(by: owner), "No timer ended")
        for duration: SleepTimerDuration in [.minutes(10), .endOfBook] {
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

    /// Pausing playback leaves a timer waiting for the book's end waiting,
    /// since it counts no time; the book's end then ends it.
    func testPauseDoesNotChangeBookTimer() {
        start(.endOfBook)

        service.pauseCountdown(by: owner)
        XCTAssertTrue(service.isActive)
        XCTAssertTrue(service.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: true, ownedBy: owner))
        service.expireAtChapterEnd(endingTheHeading: false, endingTheBook: true, by: owner)

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
    /// heading where the chapter ends the heading. Ending it there calls no
    /// expiry callback, since the owner has already stopped at the chapter's
    /// end and says so itself; the timer ends as a stop ends it, keeping the
    /// duration for Restart Sleep Timer.
    func testOnlyTheOwnersChapterEndEndsAHeadingTimerTheChapterEnds() {
        var expirations = 0
        start(.endOfHeading, onExpire: { expirations += 1 })

        XCTAssertFalse(service.expireAtChapterEnd(endingTheHeading: true, endingTheBook: false, by: UUID()))
        XCTAssertTrue(service.isActive, "Another owner's chapter end ended the timer")
        XCTAssertTrue(service.expireAtChapterEnd(endingTheHeading: true, endingTheBook: false, by: owner))

        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.duration)
        XCTAssertNil(service.ownerID)
        XCTAssertEqual(expirations, 0, "The expiry callback was called at the chapter's end")
        XCTAssertEqual(service.lastUsedDuration, .endOfHeading)
        XCTAssertFalse(
            service.expireAtChapterEnd(endingTheHeading: true, endingTheBook: false, by: owner),
            "An ended timer ended again"
        )
    }

    /// Which timers stop playback where a chapter ends: the owner's, while
    /// in effect, when set for the end of a heading, where that heading ends
    /// too and where the book ends (finding #787); and when set for the end
    /// of the book, at the last chapter's end only. A timer counting minutes
    /// stops at none, and neither does another owner's or one that has
    /// ended. No timer stops at every chapter's end: End of chapter folded
    /// into End of heading (October 6, 2026).
    func testOnlyTheOwnersTimerStopsPlaybackAtAChaptersEndWhereItEnds() {
        let otherOwner = UUID()
        let cases: [(
            name: String, duration: SleepTimerDuration?, asker: UUID,
            endingTheHeading: Bool, endingTheBook: Bool, stops: Bool
        )] = [
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

        start(.endOfHeading)
        service._expireForTesting()
        XCTAssertFalse(
            service.stopsPlaybackAtChapterEnd(endingTheHeading: true, endingTheBook: false, ownedBy: owner),
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

    func testLastUsedDurationSurvivesStop() {
        start(.minutes(20))

        service.stop()

        XCTAssertNil(service.duration)
        XCTAssertNil(service.ownerID)
        XCTAssertEqual(service.lastUsedDuration, .minutes(20))
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

    // MARK: - Handing the Timer to the Next Book's Reader (0.2.5)

    /// Counts the running countdown down by `seconds` without waiting.
    private func tick(_ seconds: Int) {
        for _ in 0..<seconds {
            service._advanceCountdownForTesting()
        }
    }

    /// A hand-over changes the owner and nothing else: the time left, the
    /// duration, and the running countdown are the same.
    func testAHandOverKeepsTheCountdownAndChangesTheOwner() {
        let next = UUID()
        start(.minutes(30))
        tick(5)
        let before = service.remainingSeconds

        let moved = service.transferOwnership(from: owner, to: next, onExpire: {})

        XCTAssertTrue(moved)
        XCTAssertEqual(service.ownerID, next)
        XCTAssertEqual(service.remainingSeconds, before, "the hand-over reset the countdown")
        XCTAssertEqual(service.duration, .minutes(30))
        XCTAssertTrue(service.isActive)
        tick(1)
        XCTAssertEqual(service.remainingSeconds, before - 1, "the countdown stopped running")
    }

    /// The previous owner can no longer pause the timer, and the new owner can.
    func testThePreviousOwnerLosesTheTimerAndTheNewOwnerGetsIt() {
        let next = UUID()
        start(.minutes(30))
        service.transferOwnership(from: owner, to: next, onExpire: {})

        service.pauseCountdown(by: owner)
        let running = service.remainingSeconds
        tick(1)
        XCTAssertEqual(service.remainingSeconds, running - 1, "the previous owner paused a timer it no longer owns")

        service.pauseCountdown(by: next)
        let paused = service.remainingSeconds
        tick(3)
        XCTAssertEqual(service.remainingSeconds, paused, "the new owner could not pause it")
    }

    /// A countdown the previous owner's pause halted stays halted through the
    /// hand-over, and the new owner's play resumes it.
    func testAHaltedCountdownStaysHaltedUntilTheNewOwnerPlays() {
        let next = UUID()
        start(.minutes(30))
        tick(2)
        service.pauseCountdown(by: owner)
        let halted = service.remainingSeconds

        service.transferOwnership(from: owner, to: next, onExpire: {})
        tick(3)
        XCTAssertEqual(service.remainingSeconds, halted, "the hand-over resumed a halted countdown")

        service.resumeCountdown(by: next)
        service._advanceCountdownForTesting()
        XCTAssertEqual(service.remainingSeconds, halted - 1)
    }

    /// Only the new owner's callbacks run when the timer runs out, and what
    /// it was set for, an end of the heading or of the book, goes with it.
    func testOnlyTheNewOwnersCallbacksRunWhenTheTimerExpires() {
        let next = UUID()
        var previousExpired = false
        var nextExpired = false
        start(.minutes(1), onExpire: { previousExpired = true })
        service.transferOwnership(from: owner, to: next, onExpire: { nextExpired = true })

        service._expireForTesting()

        XCTAssertTrue(nextExpired)
        XCTAssertFalse(previousExpired, "the previous owner paused a book it no longer owns")

        let placeOwner = UUID()
        start(.endOfBook, ownerID: placeOwner)
        XCTAssertTrue(service.transferOwnership(from: placeOwner, to: next, onExpire: {}))
        XCTAssertEqual(service.duration, .endOfBook)
        XCTAssertFalse(service.waitsForHeadingEnd(ownedBy: next), "an end-of-book timer waits for no heading")
        XCTAssertTrue(service.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: true, ownedBy: next))
        XCTAssertFalse(service.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: true, ownedBy: placeOwner))
    }

    /// Nothing changes hands unless the timer runs, belongs to the previous
    /// owner, and is not fading out.
    func testNothingIsHandedOverUnlessTheTimerRunsUnderThePreviousOwner() {
        let next = UUID()
        XCTAssertFalse(service.transferOwnership(from: owner, to: next, onExpire: {}), "no timer")
        XCTAssertNil(service.ownerID)

        start(.minutes(30))
        XCTAssertFalse(service.transferOwnership(from: UUID(), to: next, onExpire: {}), "another owner's")
        XCTAssertEqual(service.ownerID, owner)

        service.stop()
        start(.minutes(1), fade: 5)
        service._expireForTesting()
        XCTAssertTrue(service.isFadingOut)
        XCTAssertFalse(service.transferOwnership(from: owner, to: next, onExpire: {}), "fading out")
        XCTAssertEqual(service.ownerID, owner)
    }

    /// A timer is held for a book from the announcement of a move: it stays
    /// the previous owner's, runs on, is passed on to another book by a move
    /// that comes before the first book takes it, and changes hands only when
    /// the book it is held for takes it.
    func testAHeldTimerStaysTheOwnersUntilTheBookTakesIt() {
        let first = UUID()
        let second = UUID()
        let taker = UUID()
        start(.minutes(30))

        XCTAssertTrue(service.hold(forBook: first, from: owner))
        XCTAssertTrue(service.isHeld(forBook: first))
        XCTAssertTrue(service.isHeld(from: owner))
        XCTAssertEqual(service.ownerID, owner, "Exactly one owner while held")

        XCTAssertTrue(service.passOnHold(fromBook: first, toBook: second))
        XCTAssertFalse(service.isHeld(forBook: first))
        XCTAssertTrue(service.isHeld(forBook: second))
        XCTAssertFalse(service.passOnHold(fromBook: first, toBook: second), "a hold passed on twice")

        XCTAssertFalse(
            service.adoptHeld(forBook: first, as: taker, onExpire: {}), "a book it is not held for took it"
        )
        XCTAssertFalse(
            service.adoptHeld(forBook: second, as: taker, onExpire: {}), "a book took the timer before it was asked for"
        )
        service.markAsked(forBook: second)
        XCTAssertTrue(service.isAsked(forBook: second))
        XCTAssertTrue(service.adoptHeld(forBook: second, as: taker, onExpire: {}))
        XCTAssertEqual(service.ownerID, taker)
        XCTAssertFalse(service.isHeld(forBook: second), "the hold outlived the take")
        XCTAssertFalse(service.isHeld(from: owner))
    }

    /// Only a carriable timer is held: not another owner's, not one fading out.
    func testOnlyACarriableTimerIsHeld() {
        let book = UUID()
        XCTAssertFalse(service.hold(forBook: book, from: owner), "no timer")
        start(.minutes(30))
        XCTAssertFalse(service.hold(forBook: book, from: UUID()), "another owner's")
        XCTAssertTrue(service.isCarriable(by: owner))
        XCTAssertFalse(service.isCarriable(by: UUID()))

        service.stop()
        start(.minutes(1), fade: 5)
        service._expireForTesting()
        XCTAssertFalse(service.isCarriable(by: owner), "fading out")
        XCTAssertFalse(service.hold(forBook: book, from: owner))
        XCTAssertTrue(service.endedListening(ownedBy: owner), "a fading timer has ended listening")
    }

    /// A hold is returned where it was even while the timer fades out: a new
    /// carry of a fading timer is refused, but putting back the hold a
    /// cancelled move made is a return, and a timer that has stopped has no hold
    /// to return.
    func testAHoldIsReturnedEvenWhileTheTimerFadesOut() {
        let first = UUID()
        let second = UUID()
        start(.minutes(1), fade: 5)
        XCTAssertTrue(service.hold(forBook: first, from: owner))
        XCTAssertTrue(service.passOnHold(fromBook: first, toBook: second))
        service._expireForTesting()
        XCTAssertTrue(service.isFadingOut)

        XCTAssertFalse(service.passOnHold(fromBook: second, toBook: first), "a new carry of a fading timer")
        XCTAssertTrue(service.isHeld(forBook: second))
        XCTAssertTrue(service.passOnHold(fromBook: second, toBook: first, returning: true), "a return")
        XCTAssertTrue(service.isHeld(forBook: first))
        XCTAssertTrue(service.isFadingOut, "the return ended the fade")

        service.stop()
        XCTAssertFalse(service.passOnHold(fromBook: first, toBook: second, returning: true), "nothing left held")
    }

    /// A timer held for a book that ran out before the book took it is
    /// remembered for that book, once; stopping or starting a timer ends the
    /// hold.
    func testAHeldTimerThatRanOutIsRememberedForItsBook() {
        let book = UUID()
        start(.minutes(1))
        service.hold(forBook: book, from: owner)

        service._expireForTesting()

        XCTAssertFalse(service.isHeld(forBook: book), "an expired timer was still held")
        XCTAssertTrue(service.consumeExpiredWhileHeld(forBook: book))
        XCTAssertFalse(service.consumeExpiredWhileHeld(forBook: book), "asked twice")

        start(.minutes(5))
        service.hold(forBook: book, from: owner)
        service.stop()
        XCTAssertFalse(service.isHeld(forBook: book), "a stopped timer was still held")
    }

    /// An expiry is counted: a timer that ran out before a move or a wait
    /// began ended nothing after it, whatever the clock does.
    func testAnExpiryIsCountedForTheWaitsThatBeganBefore() {
        start(.minutes(1))
        let before = service.expiryCount

        service._expireForTesting()

        XCTAssertEqual(service.expiryCount, before + 1)
        XCTAssertTrue(service.didExpire(whileOwnedBy: owner, sinceExpiry: before))
        XCTAssertFalse(
            service.didExpire(whileOwnedBy: owner, sinceExpiry: service.expiryCount),
            "an expiry before the wait ended it"
        )
        XCTAssertTrue(service.endedListening(ownedBy: owner, sinceExpiry: before))
        XCTAssertFalse(service.endedListening(ownedBy: owner, sinceExpiry: service.expiryCount))
    }

    /// Releasing the timer held for a book that will not open stops it and
    /// says so after current speech; a timer held for another book is left.
    func testReleasingAHeldTimerStopsItAndSaysSoAfterCurrentSpeech() {
        let book = UUID()
        start(.minutes(30))
        service.hold(forBook: book, from: owner)
        XCTAssertFalse(service.releaseHeld(forBook: UUID()))
        XCTAssertTrue(service.isActive)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(service.releaseHeld(forBook: book))
        }

        XCTAssertFalse(service.isActive)
        XCTAssertEqual(
            recorder.announcements,
            [VoiceOverAnnouncement(message: SleepTimerHandOverWording.noBook, priority: .medium)]
        )
    }

    /// A timer that ran out is remembered with its owner until another starts
    /// or changes hands, so the reader the book goes on to can tell.
    func testATimerThatRanOutIsRememberedUntilAnotherStarts() {
        start(.minutes(1))
        XCTAssertFalse(service.didExpire(whileOwnedBy: owner))

        service._expireForTesting()
        XCTAssertTrue(service.didExpire(whileOwnedBy: owner))
        XCTAssertFalse(service.didExpire(whileOwnedBy: UUID()))

        start(.minutes(5))
        XCTAssertFalse(service.didExpire(whileOwnedBy: owner), "a new timer left the old expiry")
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

// MARK: - Every Window's Timer (November 13, 2026)

/// The registry of every window's sleep timer, and the take of a timer held
/// for a book from another window's timer (November 13, 2026: "I want each
/// sleep timer to be refactored to be per book view window not global").
/// Each test has a registry and preferences of its own, so the app's timers
/// are never touched, and nothing waits on a clock: countdowns are advanced
/// by hand.
@MainActor
final class SleepTimerRegistryTests: XCTestCase {
    private var registry: SleepTimerRegistry!
    private var defaults: UserDefaults!
    /// The reader that owns the timer a test starts first.
    private let owner = UUID()
    /// The reader of the next book, in another window.
    private let taker = UUID()
    /// The book the timer goes on to.
    private let nextBook = UUID()

    override func setUp() async throws {
        try await super.setUp()
        registry = SleepTimerRegistry()
        defaults = makeSandboxedPreferences("sleep-timer-registry")
    }

    override func tearDown() async throws {
        registry._stopEveryTimerForTesting()
        registry = nil
        defaults = nil
        try await super.tearDown()
    }

    /// A window's timer, in the test's registry.
    private func makeWindowTimer() -> SleepTimerService {
        SleepTimerService(userDefaults: defaults, registry: registry)
    }

    /// A window's timer running `duration` for `owner`, held for the next
    /// book and asked for, as a move that opened it in another window leaves
    /// it.
    private func makeTimerAskedForTheNextBook(_ duration: SleepTimerDuration, fade: TimeInterval = 0) -> SleepTimerService {
        let timer = makeWindowTimer()
        timer.start(duration: duration, ownerID: owner, onExpire: {}, fadeOutDuration: fade)
        XCTAssertTrue(timer.hold(forBook: nextBook, from: owner), "The timer could not be held")
        timer.markAsked(forBook: nextBook)
        return timer
    }

    /// Counts `timer`'s countdown down by `seconds` without waiting.
    private func tick(_ timer: SleepTimerService, _ seconds: Int) {
        for _ in 0..<seconds {
            timer._advanceCountdownForTesting()
        }
    }

    /// The timer held for a book is found in whichever window holds it, and
    /// nothing is found for a book none is held for.
    func testATimerHeldForABookIsFoundInWhicheverWindowHoldsIt() {
        let first = makeWindowTimer()
        let second = makeWindowTimer()
        second.start(duration: .minutes(30), ownerID: owner, onExpire: {})

        XCTAssertTrue(second.hold(forBook: nextBook, from: owner))

        XCTAssertTrue(registry.timer(heldForBook: nextBook) === second, "The held timer was not found")
        XCTAssertTrue(registry.isHeld(forBook: nextBook))
        XCTAssertNil(registry.timer(heldForBook: UUID()), "A timer was found for a book none is held for")
        XCTAssertFalse(first.isHeld(forBook: nextBook))
        XCTAssertEqual(registry.timers.count, 2)
    }

    /// Taken into another window, a counting timer keeps its duration, its
    /// time left, and its fade-out time, goes on counting there for the new
    /// owner, and the window it came from stops it, with its hold, so that
    /// window shows it no more and its callback never runs.
    func testATakeFromAnotherWindowMovesTheRunningTimerAndStopsItThere() {
        var oldExpiries = 0
        var newExpiries = 0
        let old = makeWindowTimer()
        old.start(duration: .minutes(30), ownerID: owner, onExpire: { oldExpiries += 1 })
        tick(old, 90)
        XCTAssertTrue(old.hold(forBook: nextBook, from: owner))
        old.markAsked(forBook: nextBook)
        let window = makeWindowTimer()

        let taken = window.take(heldForBook: nextBook, from: old, as: taker, onExpire: { newExpiries += 1 })

        XCTAssertTrue(taken)
        XCTAssertEqual(window.ownerID, taker)
        XCTAssertEqual(window.duration, .minutes(30))
        XCTAssertEqual(window.remainingSeconds, 30 * 60 - 90, "The countdown was reset or lost time")
        XCTAssertTrue(window.isActive)
        XCTAssertFalse(old.isActive, "The window it came from still shows it")
        XCTAssertFalse(old.isHolding)
        XCTAssertNil(registry.timer(heldForBook: nextBook), "The hold outlived the take")
        XCTAssertFalse(registry.isRetainingForAHold(old))

        tick(window, 1)
        XCTAssertEqual(window.remainingSeconds, 30 * 60 - 91, "The countdown stopped counting")
        window.remainingSeconds = 1
        tick(window, 1)
        XCTAssertEqual(newExpiries, 1, "The new owner's timer did not run out once")
        XCTAssertEqual(oldExpiries, 0, "The old window's callback ran")
    }

    /// The fade-out time a timer was armed with goes with it to the window
    /// that takes it.
    func testATakenTimerKeepsItsFadeOutTime() {
        let old = makeTimerAskedForTheNextBook(.minutes(30), fade: 4)
        let window = makeWindowTimer()

        XCTAssertTrue(window.take(heldForBook: nextBook, from: old, as: taker, onExpire: {}))

        XCTAssertEqual(window.fadeOutDuration, 4)
    }

    /// A countdown the previous owner's pause halted stays halted in the new
    /// window until the new owner plays: no time is spent while nothing plays,
    /// and the old owner can no longer resume it.
    func testATakenCountdownHaltedByAPauseStaysHaltedUntilTheNewOwnerPlays() {
        let old = makeTimerAskedForTheNextBook(.minutes(15))
        tick(old, 20)
        old.pauseCountdown(by: owner)
        let window = makeWindowTimer()

        XCTAssertTrue(window.take(heldForBook: nextBook, from: old, as: taker, onExpire: {}))
        tick(window, 5)
        XCTAssertEqual(window.remainingSeconds, 15 * 60 - 20, "A halted countdown counted in the new window")
        window.resumeCountdown(by: owner)
        tick(window, 5)
        XCTAssertEqual(window.remainingSeconds, 15 * 60 - 20, "The old owner resumed the timer it gave away")

        window.resumeCountdown(by: taker)
        tick(window, 5)
        XCTAssertEqual(window.remainingSeconds, 15 * 60 - 25, "The new owner's play did not resume it")
    }

    /// The timer listening goes on with replaces a timer of the window's own:
    /// the window ends up with one timer, the one carried to it.
    func testATakeReplacesTheWindowsOwnTimer() {
        let old = makeTimerAskedForTheNextBook(.minutes(30))
        let window = makeWindowTimer()
        var replacedExpiries = 0
        window.start(duration: .minutes(10), ownerID: taker, onExpire: { replacedExpiries += 1 })

        XCTAssertTrue(window.take(heldForBook: nextBook, from: old, as: taker, onExpire: {}))

        XCTAssertEqual(window.duration, .minutes(30))
        XCTAssertEqual(window.remainingSeconds, 30 * 60)
        window._expireForTesting()
        XCTAssertEqual(replacedExpiries, 0, "The replaced timer's callback ran")
    }

    /// A timer for the end of a heading is taken as it waits, for the new
    /// owner's heading; one for the end of the book likewise.
    func testATimerForAPlaceIsTakenWaitingForItsPlace() {
        for duration in [SleepTimerDuration.endOfHeading, .endOfBook] {
            let old = makeTimerAskedForTheNextBook(duration)
            let window = makeWindowTimer()

            XCTAssertTrue(window.take(heldForBook: nextBook, from: old, as: taker, onExpire: {}), "\(duration)")

            XCTAssertEqual(window.duration, duration)
            XCTAssertEqual(window.waitsForHeadingEnd(ownedBy: taker), duration == .endOfHeading, "\(duration)")
            XCTAssertTrue(
                window.stopsPlaybackAtChapterEnd(endingTheHeading: true, endingTheBook: true, ownedBy: taker),
                "\(duration): the taken timer stops nothing for its new owner"
            )
            XCTAssertFalse(old.isActive, "\(duration)")
        }
    }

    /// Nothing is taken before the book is asked for, nor a timer fading out,
    /// which is putting the listener to sleep; either stays where it was.
    func testATakeWaitsForTheAskAndNeverTakesAFade() {
        let unasked = makeWindowTimer()
        unasked.start(duration: .minutes(30), ownerID: owner, onExpire: {})
        XCTAssertTrue(unasked.hold(forBook: nextBook, from: owner))
        let window = makeWindowTimer()
        XCTAssertFalse(window.take(heldForBook: nextBook, from: unasked, as: taker, onExpire: {}), "taken before the ask")
        XCTAssertTrue(unasked.isHeld(forBook: nextBook))
        XCTAssertFalse(window.isActive)
        unasked.stop()

        let fading = makeTimerAskedForTheNextBook(.minutes(1), fade: 5)
        fading._expireForTesting()
        XCTAssertTrue(fading.isFadingOut)
        XCTAssertFalse(window.take(heldForBook: nextBook, from: fading, as: taker, onExpire: {}), "a fade was taken")
        XCTAssertTrue(fading.isFadingOut, "The refused take ended the fade")
        XCTAssertFalse(window.isActive)
    }

    /// Taken from itself, after a switch in place, the window's timer changes
    /// its owner and nothing else, as `adoptHeld` does.
    func testATakeFromTheWindowsOwnTimerChangesOnlyItsOwner() {
        let window = makeTimerAskedForTheNextBook(.minutes(30))
        tick(window, 30)

        XCTAssertTrue(window.take(heldForBook: nextBook, from: window, as: taker, onExpire: {}))

        XCTAssertEqual(window.ownerID, taker)
        XCTAssertEqual(window.remainingSeconds, 30 * 60 - 30)
        XCTAssertFalse(window.isHolding)
        tick(window, 1)
        XCTAssertEqual(window.remainingSeconds, 30 * 60 - 31, "The countdown stopped in place")
    }

    /// One timer goes on to each book: a hold for a book another window's
    /// timer is held for stops that one.
    func testOnlyOneTimerIsHeldForABook() {
        let first = makeTimerAskedForTheNextBook(.minutes(30))
        let second = makeWindowTimer()
        let secondOwner = UUID()
        second.start(duration: .minutes(10), ownerID: secondOwner, onExpire: {})

        XCTAssertTrue(second.hold(forBook: nextBook, from: secondOwner))

        XCTAssertFalse(first.isActive, "Two timers were left going on to one book")
        XCTAssertTrue(registry.timer(heldForBook: nextBook) === second)
    }

    /// Every timer's asks are told by the registry, so a reader in any window
    /// hears that a timer is asked for its book.
    func testAnAskOfAnyWindowsTimerIsToldByTheRegistry() {
        var asked: [UUID] = []
        let subscription = registry.asksMade.sink { asked.append($0) }
        defer { subscription.cancel() }

        _ = makeTimerAskedForTheNextBook(.minutes(30))

        XCTAssertEqual(asked, [nextBook])
    }

    /// The registry keeps a held timer alive after its window has let it go,
    /// and lets it go once its hold ends.
    func testTheRegistryKeepsAHeldTimerAliveUntilItsHoldEnds() {
        weak var weakTimer: SleepTimerService?
        do {
            let timer = makeTimerAskedForTheNextBook(.minutes(30))
            weakTimer = timer
        }
        XCTAssertNotNil(weakTimer, "A held timer went with its window")
        XCTAssertTrue(registry.isHeld(forBook: nextBook))

        registry.cancelHeld(forBook: nextBook)

        XCTAssertNil(weakTimer, "The registry kept a timer whose hold had ended")
        XCTAssertFalse(registry.isHeld(forBook: nextBook))
    }

    /// Released through the registry, the timer held for a book stops and the
    /// listener is told; cancelled, it stops without a word; and the mark
    /// that a timer ran out for a book is forgotten whichever timer keeps it.
    func testTheRegistryReleasesCancelsAndForgetsForTheTimerHeldForTheBook() {
        let released = makeTimerAskedForTheNextBook(.minutes(30))
        let recorder = recordingAnnouncements {
            XCTAssertTrue(registry.releaseHeld(forBook: nextBook))
        }
        XCTAssertFalse(released.isActive)
        XCTAssertEqual(
            recorder.announcements,
            [VoiceOverAnnouncement(message: SleepTimerHandOverWording.noBook, priority: .medium)]
        )
        XCTAssertFalse(registry.releaseHeld(forBook: nextBook), "Released twice")

        let cancelled = makeTimerAskedForTheNextBook(.minutes(30))
        let silent = recordingAnnouncements { registry.cancelHeld(forBook: nextBook) }
        XCTAssertFalse(cancelled.isActive)
        XCTAssertTrue(silent.announcements.isEmpty, "The cancel said something")

        let ranOut = makeTimerAskedForTheNextBook(.minutes(1))
        ranOut._expireForTesting()
        XCTAssertTrue(registry.consumeExpiredWhileHeld(forBook: nextBook), "The run-out mark was not found")
        XCTAssertFalse(registry.consumeExpiredWhileHeld(forBook: nextBook), "The mark was found twice")
    }

    /// The duration last used is one preference for every window: a timer
    /// started in one window is what another window's Restart Sleep Timer
    /// repeats.
    func testTheDurationLastUsedIsOneForEveryWindow() {
        let first = makeWindowTimer()
        let second = makeWindowTimer()

        first.start(duration: .minutes(45), ownerID: owner, onExpire: {})

        XCTAssertEqual(second.lastUsedDuration, .minutes(45))
        second.start(duration: .endOfBook, ownerID: taker, onExpire: {})
        XCTAssertEqual(first.lastUsedDuration, .endOfBook)
    }
}
