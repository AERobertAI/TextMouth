import XCTest
@testable import TextMouth

@MainActor
final class PlaybackPolicyProductionTests: XCTestCase {
    /// Oversized input should report an ordinary validation error rather than
    /// trapping while converting a valid Int number of hours into seconds.
    func testJumpHoursCannotOverflowBeforeLengthValidation() {
        let result = JumpInputValidator.time(
            hours: String(Int.max), minutes: "0", seconds: "0", bookLength: 3_600
        )
        XCTAssertEqual(result, .error("Time exceeds book length. Maximum is 1 hour."))
    }

    /// Invalid metadata must remain safe for visual and spoken duration labels.
    func testInvalidDurationsHaveAccessibleUnknownLabels() {
        for duration in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(TimeFormatting.format(duration), "Unknown")
            XCTAssertEqual(TimeFormatting.spoken(duration), "Unknown duration")
        }
        XCTAssertEqual(TimeFormatting.format(-1), "0:00")
        XCTAssertEqual(TimeFormatting.spoken(65.9), "1 minute, 5 seconds")
    }

    /// Library estimates must agree with the player's clamping and snapping
    /// for restored data, including a zero multiplier that used to produce an
    /// infinite duration and off-grid values left by drift or hand edits.
    func testAudioEstimatesUseTheSameSpeedNormalizationAsPlayback() {
        for speed in [0.0, -1, 99, .infinity, .nan, 0.26, 1.1000000000000001, 1.2345, 3.99] {
            let book = Book(title: "Audio", format: .audio, filePath: "audio.wav", md5Hash: "audio",
                            localWPM: speed, audioDuration: 120)
            let playback = AudioPlaybackService()
            playback.setSpeed(speed)
            XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), 120 / playback.playbackSpeed, "\(speed)")
        }
    }

    /// The estimate divides by the snapped speed, not the raw saved value.
    func testAudioEstimateDividesBySnappedSpeed() {
        let book = Book(title: "Audio", format: .audio, filePath: "audio.wav", md5Hash: "audio",
                        localWPM: 1.2345, audioDuration: 120)

        XCTAssertEqual(book.estimatedTimeRemaining(wpm: 200), 96)
    }

    func testPercentValidationRejectsEmptyInput() {
        XCTAssertEqual(JumpInputValidator.percent(""), .error("Enter a percent."))
        XCTAssertEqual(JumpInputValidator.percent("   "), .error("Enter a percent."))
    }

    func testPercentValidationRejectsNonNumericInput() {
        XCTAssertEqual(JumpInputValidator.percent("abc"), .error("\"abc\" is not a number."))
    }

    func testPercentValidationRejectsOutOfRangeInput() {
        XCTAssertEqual(JumpInputValidator.percent("-1"), .error("Percent must be between 0 and 100."))
        XCTAssertEqual(JumpInputValidator.percent("101"), .error("Percent must be between 0 and 100."))
    }

    func testPercentValidationAcceptsDecimalsAndEdges() {
        XCTAssertEqual(JumpInputValidator.percent("0"), .value(0))
        XCTAssertEqual(JumpInputValidator.percent("100"), .value(100))
        XCTAssertEqual(JumpInputValidator.percent(" 47.5 "), .value(47.5))
    }

    func testTimeValidationTreatsEmptyFieldsAsZero() {
        XCTAssertEqual(time("", "", "", length: 3_600), .value(0))
        XCTAssertEqual(time("", "5", "", length: 3_600), .value(300))
    }

    func testTimeValidationRejectsNonNumericHours() {
        XCTAssertEqual(time("abc", "0", "0", length: 3_600), .error("Hours must be a whole number."))
    }

    func testTimeValidationRejectsNonNumericMinutesAndSeconds() {
        XCTAssertEqual(time("0", "5x", "0", length: 3_600), .error("Minutes must be a whole number."))
        XCTAssertEqual(time("0", "0", "..", length: 3_600), .error("Seconds must be a whole number."))
    }

    func testTimeValidationRejectsMinutesOverFiftyNine() {
        XCTAssertEqual(time("0", "60", "0", length: 999_999), .error("Minutes must be less than 60."))
    }

    func testTimeValidationRejectsSecondsOverFiftyNine() {
        XCTAssertEqual(time("0", "0", "75", length: 999_999), .error("Seconds must be less than 60."))
    }

    func testTimeValidationRejectsTimeBeyondBookEnd() {
        guard case .error(let message) = time("2", "0", "0", length: 3_600) else {
            return XCTFail("Expected error")
        }
        XCTAssertTrue(message.hasPrefix("Time exceeds book length"))
    }

    func testTimeValidationAcceptsEndAndOrdinaryValues() {
        XCTAssertEqual(time("1", "0", "0", length: 3_600), .value(3_600))
        XCTAssertEqual(time("1", "30", "45", length: 7_200), .value(5_445))
    }

    func testSpeechRateTableInterpolatesDirectModeRate() {
        let middle = SpeechService.rateForWPM(250)
        XCTAssertGreaterThan(middle, SpeechService.rateForWPM(200))
        XCTAssertLessThan(middle, SpeechService.rateForWPM(300))
    }

    func testSpeechRateTableClampsBelowMinimum() {
        XCTAssertEqual(SpeechService.rateForWPM(-100), 0)
    }

    func testSpeechRateTableClampsAboveMaximum() {
        XCTAssertEqual(SpeechService.rateForWPM(10_000), 1)
    }

    /// The speech engine reads the global speed and pitch from the store
    /// directly, so it validates them with the same rules as Settings: an
    /// injected extreme is clamped at launch, and a non-finite or missing
    /// value reloads as the default.
    func testSpeechServiceValidatesStoredGlobalSpeedAndPitch() throws {
        let defaults = makeSandboxedPreferences("speech-defaults")
        defaults.set(1e308, forKey: "wordsPerMinute")
        defaults.set(-2.0, forKey: "pitchMultiplier")

        let service = SpeechService(userDefaults: defaults)

        XCTAssertEqual(service.wordsPerMinute, 650)
        XCTAssertEqual(service.pitchMultiplier, 0.5)

        defaults.set(Double.nan, forKey: "wordsPerMinute")
        defaults.set(Double.infinity, forKey: "pitchMultiplier")
        service.reloadSettings()
        XCTAssertEqual(service.wordsPerMinute, 200)
        XCTAssertEqual(service.pitchMultiplier, 1)

        defaults.set(425.0, forKey: "wordsPerMinute")
        defaults.removeObject(forKey: "pitchMultiplier")
        service.reloadSettings()
        XCTAssertEqual(service.wordsPerMinute, 425)
        XCTAssertEqual(service.pitchMultiplier, 1)

        // A stored 0 has always meant "not chosen yet" to the speech engine.
        defaults.set(0.0, forKey: "wordsPerMinute")
        service.reloadSettings()
        XCTAssertEqual(service.wordsPerMinute, 200)
    }

    func testAudioEngineSpeedRatioUsesProductionMultiplier() {
        XCTAssertEqual(AudioEngineService.speedMultiplier(wpm: 300, renderWPM: 200), 1.5)
    }

    func testSegmentedLayoutWinsOverChapterFiles() {
        XCTAssertEqual(layout(files: true, segments: true, chapters: 3), .segmented)
    }

    func testMultiFileLayoutUsesChapterFiles() {
        XCTAssertEqual(layout(files: true, segments: false, chapters: 3), .multiFile)
    }

    func testMultipleChaptersWithoutFilesUsesEmbeddedChapterLayout() {
        XCTAssertEqual(layout(files: false, segments: false, chapters: 3), .chaptersInOneFile)
    }

    func testSingleChapterWithoutFilesUsesSingleFileLayout() {
        XCTAssertEqual(layout(files: false, segments: false, chapters: 1), .singleFile)
    }

    func testSegmentedChapterStartUsesSegmentMetadata() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.segmented.chapterStartTime(
            chapterIndex: 1, chapterUTF16Lengths: [100, 100], segmentStartTimes: [10, 30]
        ), 30)
    }

    func testEmbeddedChapterStartSumsPrecedingDurations() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.chaptersInOneFile.chapterStartTime(
            chapterIndex: 2, chapterUTF16Lengths: [600, 1_200, 300], segmentStartTimes: []
        ), 180)
    }

    func testMultiFileChapterStartsAtZero() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.multiFile.chapterStartTime(
            chapterIndex: 1, chapterUTF16Lengths: [100, 100], segmentStartTimes: []
        ), 0)
    }

    func testInvalidChapterStartReturnsZero() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.segmented.chapterStartTime(
            chapterIndex: 9, chapterUTF16Lengths: [100], segmentStartTimes: [10]
        ), 0)
    }

    func testSegmentedPositionUpdateSubtractsSegmentStart() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.segmented.relativeCharacterOffset(
            playerTime: 35, chapterStartTime: 30
        ), 50)
    }

    func testMultiFilePositionUpdateStoresChapterRelativeTime() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.multiFile.relativeCharacterOffset(
            playerTime: 5, chapterStartTime: 30
        ), 50)
    }

    func testSegmentedPositionClampsBeforeClipStart() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.segmented.relativeCharacterOffset(
            playerTime: 20, chapterStartTime: 30
        ), 0)
    }

    func testSegmentedSeekAddsClipStart() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.segmented.absoluteSeekTime(
            characterOffset: 50, chapterStartTime: 30
        ), 35)
    }

    func testEmbeddedChapterSeekAddsChapterStart() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.chaptersInOneFile.absoluteSeekTime(
            characterOffset: 150, chapterStartTime: 60
        ), 75)
    }

    func testMultiFileSeekDoesNotAddChapterStart() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.multiFile.absoluteSeekTime(
            characterOffset: 150, chapterStartTime: 60
        ), 15)
    }

    func testSingleFileSeekUsesAbsoluteCharacterTime() {
        XCTAssertEqual(ReaderViewModel.AudioLayout.singleFile.absoluteSeekTime(
            characterOffset: 1_234, chapterStartTime: 0
        ), 123.4)
    }

    func testCurrentPlaybackGenerationAcceptsMatchingGeneration() {
        XCTAssertTrue(ReaderViewModel.isCurrentPlaybackGeneration(captured: 4, current: 4))
    }

    func testCurrentPlaybackGenerationRejectsStaleGeneration() {
        XCTAssertFalse(ReaderViewModel.isCurrentPlaybackGeneration(captured: 3, current: 4))
    }

    func testSkipDebounceRejectsRapidDuplicate() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReaderViewModel.shouldAcquireSkipToken(
            lastSkipTime: last, now: last.addingTimeInterval(0.1)
        ))
    }

    func testSkipDebounceRejectsExactWindowBoundary() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReaderViewModel.shouldAcquireSkipToken(
            lastSkipTime: last, now: last.addingTimeInterval(ReaderViewModel.skipDebounceWindow)
        ))
    }

    func testSkipDebounceAcceptsDeliberateLaterPress() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ReaderViewModel.shouldAcquireSkipToken(
            lastSkipTime: last, now: last.addingTimeInterval(0.401)
        ))
    }

    func testSkipDebounceAllowsFirstPress() {
        XCTAssertTrue(ReaderViewModel.shouldAcquireSkipToken(lastSkipTime: .distantPast, now: Date()))
    }

    func testRewindUnitContainsAllCases() {
        XCTAssertEqual(Set(RewindUnit.allCases), Set([.none, .sentence, .paragraph, .heading]))
    }

    func testRewindUnitRawValuesRoundTrip() {
        for unit in RewindUnit.allCases { XCTAssertEqual(RewindUnit(rawValue: unit.rawValue), unit) }
    }

    func testRewindUnitNoneIsDefaultValue() {
        XCTAssertEqual(RewindUnit.none.rawValue, "None")
    }

    func testFadeStepHelperHasSafeLowerBound() {
        XCTAssertEqual(SleepTimerService.fadeStepCount(duration: 0), 1)
        XCTAssertEqual(SleepTimerService.fadeVolume(step: 1, totalSteps: 1), 0)
    }

    func testOneSecondFadeProducesTenSteps() {
        XCTAssertEqual(SleepTimerService.fadeStepCount(duration: 1), 10)
    }

    func testFadeVolumeDecreasesMonotonicallyToZero() {
        let count = SleepTimerService.fadeStepCount(duration: 1)
        let values = (1...count).map { SleepTimerService.fadeVolume(step: $0, totalSteps: count) }
        XCTAssertEqual(values.last, 0)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testFiveSecondFadeProducesFiftySteps() {
        XCTAssertEqual(SleepTimerService.fadeStepCount(duration: 5), 50)
    }

    func testTenSecondFadeProducesOneHundredSteps() {
        XCTAssertEqual(SleepTimerService.fadeStepCount(duration: 10), 100)
    }

    func testBluetoothSettingsDefaultToEnabled() {
        XCTAssertTrue(ConfigService.AppConfig().bluetoothMonitoringEnabled)
    }

    func testBluetoothDelayDefaultsToTwoSeconds() {
        XCTAssertEqual(ConfigService.AppConfig().bluetoothDisconnectDelay, 2)
    }

    func testBluetoothSettingsRoundTripThroughConfig() throws {
        var config = ConfigService.AppConfig()
        config.bluetoothMonitoringEnabled = false
        config.bluetoothDisconnectDelay = 7
        let decoded = try JSONDecoder().decode(ConfigService.AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(decoded.bluetoothMonitoringEnabled)
        XCTAssertEqual(decoded.bluetoothDisconnectDelay, 7)
    }

    func testMissingBluetoothSettingsUseDefaults() throws {
        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(decoded.bluetoothMonitoringEnabled)
        XCTAssertEqual(decoded.bluetoothDisconnectDelay, 2)
    }

    func testHeadingIDStaysWithinCurrentHeading() {
        let list = positionedHeadings()
        XCTAssertEqual(ReaderViewModel.currentHeading(in: list, chapterIndex: 0, characterOffset: 10)?.text, "First")
        XCTAssertEqual(ReaderViewModel.currentHeading(in: list, chapterIndex: 0, characterOffset: 90)?.text, "First")
    }

    func testHeadingIDChangesAfterCrossingBoundary() {
        XCTAssertEqual(ReaderViewModel.currentHeading(in: positionedHeadings(), chapterIndex: 0, characterOffset: 100)?.text, "Second")
    }

    func testChapterChangeKeepsLastSeenHeadingWhenNewChapterHasNone() {
        XCTAssertEqual(ReaderViewModel.currentHeading(in: positionedHeadings(), chapterIndex: 1, characterOffset: 20)?.text, "Second")
    }

    func testPositionBeforeFirstHeadingHasNoCurrentID() {
        let list = [Heading(level: 1, text: "First", chapterIndex: 0, characterOffset: 10)]
        XCTAssertNil(ReaderViewModel.currentHeading(in: list, chapterIndex: 0, characterOffset: 0))
    }

    private func time(_ h: String, _ m: String, _ s: String, length: TimeInterval) -> JumpInputValidator.TimeResult {
        JumpInputValidator.time(hours: h, minutes: m, seconds: s, bookLength: length)
    }

    private func layout(files: Bool, segments: Bool, chapters: Int) -> ReaderViewModel.AudioLayout {
        ReaderViewModel.AudioLayout.determine(
            hasChapterFiles: files, hasSegments: segments, chapterCount: chapters
        )
    }

    private func positionedHeadings() -> [Heading] {
        [
            Heading(level: 1, text: "First", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "Second", chapterIndex: 0, characterOffset: 100),
        ]
    }
}
