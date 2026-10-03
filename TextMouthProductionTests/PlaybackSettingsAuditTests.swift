import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Verify effective reader settings without producing speech or changing the
/// user's saved global preferences.
@MainActor
final class PlaybackSettingsAuditTests: XCTestCase {
    /// Per-book speed and pitch must leave global defaults untouched.
    func testRuntimeSpeechSettingsDoNotPersistGlobalDefaults() {
        let defaults = makeSandboxedPreferences("speech-globals")
        defaults.set(200.0, forKey: "wordsPerMinute")
        defaults.set(1.0, forKey: "pitchMultiplier")
        let service = SpeechService(userDefaults: defaults)

        service.setSpeedRealtime(325)
        service.setPitchRealtime(1.4)

        XCTAssertEqual(service.wordsPerMinute, 325)
        XCTAssertEqual(service.pitchMultiplier, 1.4)
        XCTAssertEqual(defaults.double(forKey: "wordsPerMinute"), 200)
        XCTAssertEqual(defaults.double(forKey: "pitchMultiplier"), 1)
    }

    /// The shared keyboard, menu, and playback-bar operation moves audio by a
    /// tenth (not a 25x WPM step clamped to the maximum), landing on exact
    /// decimals instead of accumulating floating-point drift.
    func testAudioSpeedCommandsUseCoarseTenthSteps() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }

        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 1.1)
        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 1.2)
        XCTAssertEqual(reader.audioPlaybackService.playbackSpeed, 1.2)
        reader.stepSpeed(forward: false)
        reader.stepSpeed(forward: false)
        XCTAssertEqual(reader.audioSpeed, 1)
        XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.localWPM, 1)
    }

    /// The Increase/Decrease Speed menu items and keyboard shortcuts post
    /// these commands; an audio reader answers them with the coarse step.
    func testIncreaseAndDecreaseSpeedCommandsUseCoarseStep() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }

        NotificationCenter.default.post(name: .increaseSpeed, object: nil)
        XCTAssertEqual(reader.audioSpeed, 1.1)
        NotificationCenter.default.post(name: .decreaseSpeed, object: nil)
        XCTAssertEqual(reader.audioSpeed, 1)
    }

    /// Steps are relative: a legacy quarter-step speed keeps its offset and
    /// returns exactly to itself after one step each way.
    func testCoarseStepsFromLegacyQuarterSpeedAreSymmetric() {
        let reader = makeReader(format: .audio, localWPM: 1.25)
        defer { reader.close() }

        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 1.35)
        reader.stepSpeed(forward: false)
        XCTAssertEqual(reader.audioSpeed, 1.25)
    }

    /// At either bound a coarse step clamps instead of overshooting, and the
    /// played and saved speed stays exactly the bound.
    func testCoarseStepsClampAtBothBounds() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }

        reader.setAudioSpeed(3.95)
        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 4)
        reader.stepSpeed(forward: true)
        XCTAssertEqual(reader.audioSpeed, 4)

        reader.setAudioSpeed(0.3)
        reader.stepSpeed(forward: false)
        XCTAssertEqual(reader.audioSpeed, 0.25)
        reader.stepSpeed(forward: false)
        XCTAssertEqual(reader.audioSpeed, 0.25)
        XCTAssertEqual(reader.audioPlaybackService.playbackSpeed, 0.25)
        XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.localWPM, 0.25)
    }

    /// Walking the whole range with the arithmetic `adjustAudioSpeed` uses
    /// visits only exact tenths. Because steps are relative, the first step
    /// up from the 0.25 floor lands on 0.35.
    func testCoarseStepsWalkTheRangeWithoutDrift() {
        var speed = AudioSpeed.normal
        for tenths in 11...40 {
            speed = AudioSpeed.normalized(speed + AudioSpeed.coarseStep)
            XCTAssertEqual(speed, Double(tenths) / 10)
        }
        for tenths in stride(from: 39, through: 3, by: -1) {
            speed = AudioSpeed.normalized(speed - AudioSpeed.coarseStep)
            XCTAssertEqual(speed, Double(tenths) / 10)
        }
        speed = AudioSpeed.normalized(speed - AudioSpeed.coarseStep)
        XCTAssertEqual(speed, 0.25)
        XCTAssertEqual(AudioSpeed.normalized(speed + AudioSpeed.coarseStep), 0.35)
    }

    /// Both steps, both bounds, and normal speed must be whole numbers of
    /// fine steps; otherwise snapping would silently change a step's size.
    func testAudioSpeedStepsAndBoundsLieOnTheSnappingGrid() {
        XCTAssertEqual(AudioSpeed.coarseStep, 0.1)
        XCTAssertEqual(AudioSpeed.fineStep, 0.05)
        let values = [
            AudioSpeed.coarseStep, AudioSpeed.fineStep, AudioSpeed.normal,
            AudioSpeed.range.lowerBound, AudioSpeed.range.upperBound,
        ]
        for value in values {
            let fineSteps = value / AudioSpeed.fineStep
            XCTAssertEqual(fineSteps, fineSteps.rounded(), accuracy: 1e-9, "\(value)")
        }
    }

    /// The playback bar's tortoise and hare buttons state the real step in
    /// words, in each book's own unit.
    func testPlaybackBarSpeedButtonsStateTheirStepInWords() {
        let audio = makeReader(format: .audio)
        defer { audio.close() }
        XCTAssertEqual(audio.speedStepButtonLabel(forward: true), "Increase audio speed by 0.1 times")
        XCTAssertEqual(audio.speedStepButtonLabel(forward: false), "Decrease audio speed by 0.1 times")

        let text = makeReader(format: .txt)
        defer { text.close() }
        XCTAssertEqual(text.speedStepButtonLabel(forward: true), "Increase speed by 25 words per minute")
        XCTAssertEqual(text.speedStepButtonLabel(forward: false), "Decrease speed by 25 words per minute")
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

    /// Copying a book's settings to the global defaults applies them and
    /// says they were applied, not saved (TODO A09).
    func testSavingToGlobalSettingsSaysTheSettingsWereApplied() throws {
        let settings = try makeIsolatedSettings()
        let reader = makeReader(format: .txt, localWPM: 310, settingsViewModel: settings)
        defer { reader.close() }

        let recorder = recordingAnnouncements { reader.saveSettingsToGlobal() }

        XCTAssertEqual(settings.wordsPerMinute, 310)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Settings applied as global defaults"])
    }

    /// A save of those settings that fails is the settings model's to
    /// report, and it is: config.json's failure reaches the failure banner,
    /// which announces it on its own. The reader adds no second message.
    func testAFailedSettingsSaveIsLeftToTheFailureBanner() throws {
        let center = cleanSharedFailureCenter()
        let settings = try makeIsolatedSettings(configWrite: { _, _ in throw WriteRefused() })
        let reader = makeReader(format: .txt, localWPM: 310, settingsViewModel: settings)
        defer { reader.close() }

        let recorder = recordingAnnouncements { reader.saveSettingsToGlobal() }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Settings applied as global defaults"])
        XCTAssertEqual(center.outstandingFailures().map(\.subject), [.configuration])
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

    // MARK: - Per-book speed sheet

    /// The sheet's stepper and slider share one binding that moves by the
    /// fine step, lands on exact values, and updates the live player and the
    /// saved book immediately.
    func testSheetBindingMovesAudioSpeedByFineSteps() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }
        let speed = BookVoicePickerView(viewModel: reader).audioSpeedBinding

        speed.wrappedValue += AudioSpeed.fineStep
        XCTAssertEqual(reader.audioSpeed, 1.05)
        speed.wrappedValue += AudioSpeed.fineStep
        XCTAssertEqual(reader.audioSpeed, 1.1)
        speed.wrappedValue -= AudioSpeed.fineStep
        XCTAssertEqual(speed.wrappedValue, 1.05)
        XCTAssertEqual(reader.audioPlaybackService.playbackSpeed, 1.05)
        XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.localWPM, 1.05)
    }

    /// A slider position is lowerBound + k × step, which drifts in binary;
    /// the binding must still store the exact decimal for that position.
    func testSheetSliderPositionsLandOnExactSpeeds() {
        let reader = makeReader(format: .audio)
        defer { reader.close() }
        let speed = BookVoicePickerView(viewModel: reader).audioSpeedBinding

        let expectedSpeedByPosition: [Int: Double] = [0: 0.25, 15: 1, 17: 1.1, 35: 2, 75: 4]
        for (position, expected) in expectedSpeedByPosition {
            speed.wrappedValue = AudioSpeed.range.lowerBound + Double(position) * AudioSpeed.fineStep
            XCTAssertEqual(reader.audioSpeed, expected, "Slider position \(position)")
        }
    }

    /// The stepper and slider hints state the fine step in words.
    func testSheetControlHintStatesTheFineStep() {
        XCTAssertEqual(
            AudioSpeed.stepHint(AudioSpeed.fineStep),
            "Changes the speed in steps of 0.05 times"
        )
    }

    /// In the rendered sheet, VoiceOver finds both audio controls labelled
    /// "Audio speed", hears the spoken speed and the step, and its increment
    /// action moves by exactly the fine step.
    func testRenderedAudioSheetControlsAreLabelledAndMoveByFineStep() throws {
        let reader = makeReader(format: .audio, localWPM: 1.25)
        defer { reader.close() }

        try withHostedControls(BookVoicePickerView(viewModel: reader)) { controls in
            for role in [NSAccessibility.Role.incrementor, .slider] {
                let control = try XCTUnwrap(controls.first { $0.role == role }, role.rawValue)
                XCTAssertEqual(control.label, "Audio speed", role.rawValue)
                XCTAssertEqual(control.valueDescription, "1.25 times speed", role.rawValue)
                XCTAssertEqual(control.hint, "Changes the speed in steps of 0.05 times", role.rawValue)
            }

            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor })
            _ = stepper.element.accessibilityPerformIncrement()
            XCTAssertEqual(reader.audioSpeed, 1.3)
            // SwiftUI re-renders asynchronously; the spoken value must follow,
            // and the slider must receive 1.3 before it is adjusted.
            XCTAssertTrue(waitUntil { stepper.element.accessibilityValueDescription() == "1.3 times speed" })

            let slider = try XCTUnwrap(controls.first { $0.role == .slider })
            _ = slider.element.accessibilityPerformDecrement()
            XCTAssertEqual(reader.audioSpeed, 1.25)
        }
    }

    /// The toolbar button opening the sheet shows a speed gauge for audio
    /// books. A mistyped symbol name would silently draw nothing.
    func testBookSettingsToolbarSymbolsExist() {
        XCTAssertEqual(ReaderView.bookSettingsSymbol(isAudioBook: true), "gauge.with.needle")
        XCTAssertEqual(ReaderView.bookSettingsSymbol(isAudioBook: false), "person.wave.2")
        for isAudioBook in [true, false] {
            let name = ReaderView.bookSettingsSymbol(isAudioBook: isAudioBook)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    /// Only text books offer speech controls. The text sheet is checked too,
    /// proving the harness can see voice and WPM controls when they exist.
    func testRenderedSheetOffersSpeechControlsOnlyForTextBooks() {
        let text = makeReader(format: .txt)
        defer { text.close() }
        withHostedControls(BookVoicePickerView(viewModel: text)) { controls in
            XCTAssertTrue(controls.contains { $0.label == "Select voice for this book" })
            XCTAssertTrue(controls.contains { $0.valueDescription.hasSuffix("words per minute") })
        }

        let audio = makeReader(format: .audio)
        defer { audio.close() }
        withHostedControls(BookVoicePickerView(viewModel: audio)) { controls in
            let spoken = controls.map { "\($0.label) \($0.valueDescription)".lowercased() }
            for speechTerm in ["words per minute", "voice", "pitch"] {
                XCTAssertFalse(spoken.contains { $0.contains(speechTerm) }, speechTerm)
            }
            let popUps = controls.filter { $0.role == .popUpButton }.map(\.label)
            XCTAssertEqual(popUps, ["End of book behavior for this book"])
        }
    }

    // MARK: - Playback settings steppers

    /// VoiceOver hears each stepper in the Playback settings by its label,
    /// once, with its value in words. A stepper's own title is spoken before
    /// its accessibility label even when hidden, so a hidden "Seconds" would
    /// be heard as "Seconds, Minimum pause threshold".
    func testPlaybackSettingsSteppersSpeakTheirLabelsOnce() throws {
        let settings = try makeIsolatedSettings()
        // The pause threshold's stepper shows only for a smart rewind.
        settings.rewindOnResumeUnit = .sentence
        settings.rewindSmartMode = true
        settings.rewindSmartThreshold = 30
        settings.sleepFadeOutDuration = 3

        // A window tall enough to lay out every section at once.
        withHostedView(
            PlaybackSettingsView().environmentObject(settings),
            size: NSSize(width: 600, height: 1600),
            until: { steppers(in: $0).count == 2 }
        ) { hostingView in
            let found = steppers(in: hostingView)
            XCTAssertEqual(found.map(\.label), ["Minimum pause threshold", "Fade out duration"])
            XCTAssertEqual(found.map(\.valueDescription), ["30 seconds", "3 seconds"])
        }
    }

    /// The steppers VoiceOver finds in `view`, in the order it reads them.
    private func steppers(in view: NSView) -> [AccessibleControl] {
        accessibleControls(in: view).filter { $0.role == .incrementor }
    }

    // MARK: - Keeping audio multipliers out of speech WPM

    /// Opening an audio book must not push its saved multiplier into the
    /// speech engine, where 1.25 would clamp to 50 WPM and slow "Where Am I?".
    func testOpeningAudioBookLeavesSpeechSpeedAtGlobalDefault() {
        withGlobalSpeechSpeed(240) {
            let reader = makeReader(format: .audio, localWPM: 1.25)
            defer { reader.close() }

            XCTAssertEqual(reader.speechService.wordsPerMinute, 240)
            XCTAssertEqual(reader.audioSpeed, 1.25)
        }
    }

    /// Global speech-setting changes re-apply per-book overrides; for an
    /// audio book that must not include the multiplier stored in `localWPM`.
    func testSpeechSettingsChangeKeepsAudioMultiplierOutOfSpeechSpeed() {
        withGlobalSpeechSpeed(240) {
            let reader = makeReader(format: .audio, localWPM: 1.25)
            defer { reader.close() }

            NotificationCenter.default.post(name: .speechSettingsChanged, object: nil)

            XCTAssertEqual(reader.speechService.wordsPerMinute, 240)
            XCTAssertEqual(reader.audioSpeed, 1.25)
        }
    }

    /// Text books still apply their saved WPM when opened and after a global
    /// speech-setting change.
    func testTextBookStillAppliesItsSavedWPM() {
        withGlobalSpeechSpeed(240) {
            let reader = makeReader(format: .txt, localWPM: 300)
            defer { reader.close() }
            XCTAssertEqual(reader.speechService.wordsPerMinute, 300)

            NotificationCenter.default.post(name: .speechSettingsChanged, object: nil)

            XCTAssertEqual(reader.speechService.wordsPerMinute, 300)
        }
    }

    /// The audio write path must never store a multiplier in a text book's
    /// words-per-minute slot, even if a caller reaches it by mistake.
    func testSetAudioSpeedIgnoresTextBooks() {
        let reader = makeReader(format: .txt, localWPM: 300)
        defer { reader.close() }

        reader.setAudioSpeed(1.5)

        XCTAssertEqual(reader.book.localWPM, 300)
        XCTAssertEqual(reader.audioSpeed, 1)
    }

    // MARK: - Audio speed labels

    /// Visible text keeps hundredths only when present and always shows at
    /// least one decimal, so 1.25 is never displayed as 1.2 or 1.3.
    func testAudioSpeedVisibleLabels() {
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1), "1.0x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1.3), "1.3x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1.25), "1.25x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 0.25), "0.25x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 4), "4.0x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1.05), "1.05x")
    }

    /// VoiceOver and braille get the same number followed by "times speed".
    func testAudioSpeedSpokenLabels() {
        XCTAssertEqual(AudioSpeed.spokenLabel(for: 1), "1.0 times speed")
        XCTAssertEqual(AudioSpeed.spokenLabel(for: 1.3), "1.3 times speed")
        XCTAssertEqual(AudioSpeed.spokenLabel(for: 1.25), "1.25 times speed")
        XCTAssertEqual(AudioSpeed.spokenLabel(for: 0.25), "0.25 times speed")
        XCTAssertEqual(AudioSpeed.spokenLabel(for: 4), "4.0 times speed")
    }

    /// Labels name the speed that would actually play: drifted, raw, and
    /// damaged values are normalized before formatting.
    func testAudioSpeedLabelsDescribeNormalizedSpeed() {
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1.0 + 0.1), "1.1x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 1.2345), "1.25x")
        XCTAssertEqual(AudioSpeed.visibleLabel(for: 9), "4.0x")
        XCTAssertEqual(AudioSpeed.spokenLabel(for: .nan), "1.0 times speed")
    }

    /// Exhaustively, every supported speed shows a number that parses back to
    /// exactly that speed, and its spoken label carries the same number.
    func testEverySupportedSpeedHasLosslessMatchingLabels() {
        for gridIndex in 5...80 {
            let speed = Double(gridIndex) / 20
            let number = String(AudioSpeed.visibleLabel(for: speed).dropLast())

            XCTAssertEqual(Double(number), speed, "Visible label for \(speed)")
            XCTAssertEqual(AudioSpeed.spokenLabel(for: speed), "\(number) times speed")
        }
    }

    /// Run `body` with a known global speech speed so WPM assertions are
    /// exact, then restore the saved preference (removing it if it was unset).
    ///
    /// Unlike every other preference in the hosted tests, this one is still
    /// written to the standard store, the developer's own preferences: the
    /// reader builds its speech service with `SpeechService()`, whose global
    /// speed comes from there. Once that initializer reads
    /// `TextMouthRuntime.current.preferences` (TODO Q01 follow-up), this
    /// helper should write that store instead.
    private func withGlobalSpeechSpeed(_ wordsPerMinute: Double, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedSpeed = defaults.object(forKey: "wordsPerMinute")
        defer { defaults.set(savedSpeed, forKey: "wordsPerMinute") }
        defaults.set(wordsPerMinute, forKey: "wordsPerMinute")
        body()
    }

    /// Use an isolated notification center and a nonexistent file: these
    /// settings operations do not need parsing or an active audio device.
    /// `localWPM` holds words per minute for text books and the playback
    /// multiplier for audio books, matching the persisted schema. A test
    /// that changes the global settings passes a settings model of its own
    /// (`makeIsolatedSettings`).
    private func makeReader(
        format: BookFormat,
        localWPM: Double? = nil,
        audioDuration: TimeInterval? = nil,
        settingsViewModel: SettingsViewModel? = nil
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
            settingsViewModel: settingsViewModel ?? SettingsViewModel(
                notificationCenter: NotificationCenter(),
                initializeServices: false
            )
        )
    }

    /// A settings model of the test's own, so changing the global settings
    /// touches neither this process's preferences nor its config.json: the
    /// preferences are a sandboxed store, and config.json is a file in a
    /// folder of the test's, written with `configWrite`.
    private func makeIsolatedSettings(
        configWrite: @escaping @MainActor (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> SettingsViewModel {
        let configFile = try makeTestDirectory("GlobalSettings").appendingPathComponent("config.json")
        let configService = ConfigService(fileURL: configFile, fileOperations: ConfigService.FileOperations(
            write: configWrite,
            openForEvents: { _ in -1 },
            close: { _ in }
        ))
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("global-settings"),
            configService: configService
        )
    }
}
