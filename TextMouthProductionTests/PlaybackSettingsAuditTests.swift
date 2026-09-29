import XCTest
@testable import TextMouth

/// Verify effective reader settings without producing speech or changing the
/// user's saved global preferences.
@MainActor
final class PlaybackSettingsAuditTests: XCTestCase {
    /// Per-book speed and pitch must leave global defaults untouched.
    func testRuntimeSpeechSettingsDoNotPersistGlobalDefaults() {
        let defaults = UserDefaults.standard
        let savedSpeed = defaults.object(forKey: "wordsPerMinute")
        let savedPitch = defaults.object(forKey: "pitchMultiplier")
        defer {
            defaults.set(savedSpeed, forKey: "wordsPerMinute")
            defaults.set(savedPitch, forKey: "pitchMultiplier")
        }
        defaults.set(200.0, forKey: "wordsPerMinute")
        defaults.set(1.0, forKey: "pitchMultiplier")
        let service = SpeechService()

        service.setSpeedRealtime(325)
        service.setPitchRealtime(1.4)

        XCTAssertEqual(service.wordsPerMinute, 325)
        XCTAssertEqual(service.pitchMultiplier, 1.4)
        XCTAssertEqual(defaults.double(forKey: "wordsPerMinute"), 200)
        XCTAssertEqual(defaults.double(forKey: "pitchMultiplier"), 1)
    }

    /// The shared keyboard/button operation increments audio by a quarter,
    /// rather than immediately clamping a 25x increase to the maximum.
    func testAudioSpeedCommandsUseQuarterSteps() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }

        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 1.25)
        reader.stepSpeed(forward: false)
        XCTAssertEqual(reader.audioSpeed, 1)
        XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.localWPM, 1)
    }

    /// Preserve the existing 25 WPM increment for text books.
    func testTextSpeedCommandsKeepWPMUnits() {
        let reader = makeReader(format: .txt)
        defer { reader.close() }
        reader.speechService.setSpeedRealtime(200)

        reader.stepSpeed(forward: true)

        XCTAssertEqual(reader.speechService.wordsPerMinute, 225)
        XCTAssertEqual(reader.book.localWPM, 225)
    }

    /// Reset must update the running audio service as well as saved state.
    func testAudioResetRestoresNormalRuntimeSpeed() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }
        reader.adjustAudioSpeed(delta: 1)

        reader.resetToGlobalSettings()

        XCTAssertNil(reader.book.localWPM)
        XCTAssertEqual(reader.audioSpeed, 1)
        XCTAssertEqual(reader.audioPlaybackService.playbackSpeed, 1)
    }

    /// An audio multiplier must never replace a speech WPM preference, even
    /// if an older UI or a future command calls this method directly.
    func testAudioCannotSaveMultiplierAsGlobalWPM() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }
        let oldSpeed = reader.settingsViewModel.wordsPerMinute
        reader.book.localWPM = 1.5

        reader.saveSettingsToGlobal()

        XCTAssertEqual(reader.settingsViewModel.wordsPerMinute, oldSpeed)
    }

    // MARK: - Audio speed snapping and clamping

    /// Quarter steps saved by earlier releases, including both range bounds,
    /// must survive normalization unchanged so existing books keep their speed.
    func testLegacyAudioSpeedsStayExactOnTheGrid() {
        for legacy in [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.75, 4] {
            XCTAssertEqual(AudioSpeed.normalized(legacy), legacy)
        }
    }

    /// Floating-point drift and hand-edited values snap to the nearest 0.05,
    /// producing exactly the Double a decimal literal would.
    func testAudioSpeedSnapsDriftAndOffGridValuesToNearestFineStep() {
        XCTAssertEqual(AudioSpeed.normalized(1.0 + 0.1), 1.1)
        XCTAssertEqual(AudioSpeed.normalized(1.0 + 0.1 + 0.1), 1.2)
        XCTAssertEqual(AudioSpeed.normalized(0.25 + 17 * 0.05), 1.1)
        XCTAssertEqual(AudioSpeed.normalized(1.2345), 1.25)
        XCTAssertEqual(AudioSpeed.normalized(1.12), 1.1)
        XCTAssertEqual(AudioSpeed.normalized(1.13), 1.15)
    }

    /// Out-of-range values clamp to the nearest bound; damaged non-finite
    /// values fall back to normal speed instead of either extreme.
    func testAudioSpeedClampsOutOfRangeAndRejectsNonFiniteValues() {
        for belowRange in [-1, 0, 0.1, 0.24] {
            XCTAssertEqual(AudioSpeed.normalized(belowRange), 0.25, "\(belowRange)")
        }
        for aboveRange in [4.01, 4.2, 99] {
            XCTAssertEqual(AudioSpeed.normalized(aboveRange), 4, "\(aboveRange)")
        }
        // In-range values within half a fine step of a bound snap onto it.
        XCTAssertEqual(AudioSpeed.normalized(0.26), 0.25)
        XCTAssertEqual(AudioSpeed.normalized(3.99), 4)
        for damaged in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(AudioSpeed.normalized(damaged), 1, "\(damaged)")
        }
    }

    /// The player itself applies the normalized value, so its rate always
    /// equals the speed the reader shows and saves.
    func testAudioPlayerAppliesNormalizedSpeed() {
        let playback = AudioPlaybackService()

        playback.setSpeed(1.0 + 0.1)

        XCTAssertEqual(playback.playbackSpeed, 1.1)
    }

    /// Every write through the reader is snapped before it reaches the
    /// player, the reader's published value, or the saved library.
    func testAudioSpeedWritesAreSnappedBeforeSaving() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }

        reader.setAudioSpeed(1.0 + 0.1 + 0.1)

        XCTAssertEqual(reader.audioSpeed, 1.2)
        XCTAssertEqual(reader.audioPlaybackService.playbackSpeed, 1.2)
        XCTAssertEqual(reader.book.localWPM, 1.2)
        XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.localWPM, 1.2)
    }

    /// A drifted or hand-edited saved multiplier is restored snapped, and the
    /// reader's total time agrees with the library row's estimate for it.
    func testRestoredAudioSpeedIsSnappedAndMatchesLibraryEstimate() throws {
        let reader = makeReader(format: .audio, localWPM: 1.2345, audioDuration: 120)
        defer { reader.close() }

        XCTAssertEqual(reader.audioSpeed, 1.25)
        let libraryEstimate = try XCTUnwrap(reader.book.estimatedTimeRemaining(wpm: 200))
        XCTAssertEqual(reader.totalEstimatedTime, libraryEstimate)
    }

    /// Use an isolated notification center and a nonexistent file: these
    /// settings operations do not need parsing or an active audio device.
    /// `localWPM` holds words per minute for text books and the playback
    /// multiplier for audio books, matching the persisted schema.
    private func makeReader(
        format: BookFormat,
        localWPM: Double? = nil,
        audioDuration: TimeInterval? = nil
    ) -> ReaderViewModel {
        let book = Book(
            title: "Playback Settings",
            format: format,
            filePath: "/tmp/\(UUID().uuidString).\(format.isAudio ? "wav" : "txt")",
            md5Hash: UUID().uuidString,
            localWPM: localWPM,
            audioDuration: audioDuration
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(
                notificationCenter: NotificationCenter(),
                initializeServices: false
            )
        )
    }
}
