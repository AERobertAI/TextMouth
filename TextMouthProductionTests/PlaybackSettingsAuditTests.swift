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

    /// Use an isolated notification center and a nonexistent file: these
    /// settings operations do not need parsing or an active audio device.
    private func makeReader(format: BookFormat) -> ReaderViewModel {
        let book = Book(
            title: "Playback Settings",
            format: format,
            filePath: "/tmp/\(UUID().uuidString).\(format.isAudio ? "wav" : "txt")",
            md5Hash: UUID().uuidString
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
