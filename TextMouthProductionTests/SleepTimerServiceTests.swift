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

    func testHeadingTimerExpiresOnSecondOwnerBoundary() {
        var expirations = 0
        start(.endOfHeading, onExpire: { expirations += 1 })

        service.notifyHeadingBoundary(by: owner)
        XCTAssertEqual(expirations, 0)
        XCTAssertTrue(service.isActive)

        service.notifyHeadingBoundary(by: owner)
        XCTAssertEqual(expirations, 1)
        XCTAssertFalse(service.isActive)
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
        service.stop()
        XCTAssertEqual(service.formattedRemaining, "")
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

    func testRestartResetsHeadingTrigger() {
        var expirations = 0
        start(.endOfHeading, onExpire: { expirations += 1 })
        service.notifyHeadingBoundary(by: owner)

        service.restart()
        service.notifyHeadingBoundary(by: owner)
        XCTAssertEqual(expirations, 0)
        service.notifyHeadingBoundary(by: owner)
        XCTAssertEqual(expirations, 1)
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
        service.notifyHeadingBoundary(by: owner)
        service.notifyHeadingBoundary(by: owner)
        XCTAssertFalse(service.isActive)
    }

    func testPauseDoesNotChangeChapterTimer() {
        start(.endOfChapter)

        service.pauseCountdown(by: owner)
        service.notifyDocumentEnd(by: owner)

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

    func testOnlyOwnerAdvancesHeadingTimer() {
        var expirations = 0
        start(.endOfHeading, onExpire: { expirations += 1 })

        service.notifyHeadingBoundary(by: UUID())
        service.notifyHeadingBoundary(by: owner)
        service.notifyHeadingBoundary(by: UUID())
        XCTAssertEqual(expirations, 0)
        service.notifyHeadingBoundary(by: owner)
        XCTAssertEqual(expirations, 1)
    }

    func testOnlyOwnerExpiresChapterTimer() {
        var expirations = 0
        start(.endOfChapter, onExpire: { expirations += 1 })

        service.notifyDocumentEnd(by: UUID())
        XCTAssertEqual(expirations, 0)
        service.notifyDocumentEnd(by: owner)
        XCTAssertEqual(expirations, 1)
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
        start(.endOfChapter)

        let restored = SleepTimerService(userDefaults: testDefaults)

        XCTAssertEqual(restored.lastUsedDuration, .endOfChapter)
        restored._resetForTesting()
    }

    /// A duration saved as "endOfDocument", before End of chapter took the
    /// place of End of document, restores End of chapter, so Restart Sleep
    /// Timer still arms the timer the listener last chose. The new name is
    /// what is saved from now on.
    func testSavedEndOfDocumentRestoresEndOfChapter() throws {
        let key = "sleepTimer.lastUsedDuration"
        testDefaults.set(Data(#"{"kind":"endOfDocument"}"#.utf8), forKey: key)

        let restored = SleepTimerService(userDefaults: testDefaults)
        defer { restored._resetForTesting() }

        XCTAssertEqual(restored.lastUsedDuration, .endOfChapter)
        restored.start(duration: try XCTUnwrap(restored.lastUsedDuration), onExpire: {})
        let saved = try XCTUnwrap(testDefaults.data(forKey: key))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: saved) as? [String: String],
            ["kind": "endOfChapter"]
        )
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
