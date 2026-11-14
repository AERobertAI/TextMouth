import AVFoundation
import XCTest
@testable import TextMouth

/// The speech engine is made the first time speech needs one, at its first
/// render or the first chapter played from audio rendered ahead, and never
/// for an audiobook (PERF08). Everything that only asks about the engine, or
/// stops or quiets it, leaves it unmade.
///
/// Direct speech here goes to a recorder standing in for the synthesizer,
/// and speech a test starts is stopped before the main run loop turns, so
/// nothing is heard. Only the opt-in benchmark makes an engine cold.
@MainActor
final class SpeechEngineCreationTests: XCTestCase {

    // MARK: - The speech service

    /// A new speech service makes no engine, and changing its speed, pitch,
    /// or voice, asking where it is, stopping, pausing, resuming, seeking,
    /// restoring its volume, or releasing it with nothing played makes none
    /// either.
    func testNothingButARenderOrRenderedPlaybackMakesTheEngine() {
        let speech = makeSpeech()
        defer { speech.stop() }

        speech.setSpeedRealtime(300)
        speech.setPitchRealtime(1.3)
        speech.currentVoice = nil
        _ = speech.currentCharOffset()
        speech.pause()
        speech.resume()
        speech.seek(toCharOffset: 10)
        speech.restoreEngineVolume()
        speech.cancelSleepTimerFade()
        speech.stop()
        speech.releaseSpeech()

        XCTAssertFalse(speech.hasAudioEngine)
    }

    /// Direct speech of a text too long to render, and its seeks, make no
    /// engine: nothing is rendered.
    func testDirectSpeechOfALongTextMakesNoEngine() {
        let speech = makeSpeech()
        defer { speech.stop() }

        speech.speak(Self.longText)
        speech.seek(toCharOffset: 5_000)

        XCTAssertTrue(speech.isSpeaking)
        XCTAssertFalse(speech.hasAudioEngine)
    }

    /// Speaking a text short enough to render makes the engine, to render it
    /// in the background.
    func testSpeakingARenderableTextMakesTheEngine() {
        let speech = makeSpeech()
        defer { speech.stop() }

        speech.speak("The ferry left the quay at noon.")

        XCTAssertTrue(speech.hasAudioEngine)
    }

    /// Playing a chapter from audio rendered ahead makes the engine, which
    /// takes that audio.
    func testPlayingRenderedAudioMakesTheEngine() {
        let speech = makeSpeech()
        defer { speech.stop() }
        let text = "Lamps came on along the pier."
        let rendered = AudioEngineService()
        // Stand-in audio: silence, carrying the text's signature.
        rendered._installRenderedAudioForTesting(
            signature: SpeechRenderRequest(text: text, voice: speech.currentVoice).signature
        )

        speech.usePreRenderedEngine(rendered, text: text)
        let adopted = speech.audioEngine.renderedSignature
        speech.stop()

        XCTAssertTrue(speech.hasAudioEngine)
        XCTAssertEqual(adopted, SpeechRenderRequest(text: text, voice: speech.currentVoice).signature)
    }

    /// Releasing speech forgets the text it was speaking and discards the
    /// engine's rendered audio, and makes no engine when there is none.
    func testReleasingSpeechLetsGoOfTheTextAndTheRenderedAudio() {
        let speech = makeSpeech()
        defer { speech.stop() }
        speech.speak(Self.longText)
        speech.stop()
        XCTAssertFalse(speech.currentText.isEmpty, "a stopped service keeps its text for a later resume")

        speech.releaseSpeech()
        XCTAssertTrue(speech.currentText.isEmpty)
        XCTAssertFalse(speech.hasAudioEngine)

        speech.audioEngine._installRenderedAudioForTesting(signature: nil)
        XCTAssertTrue(speech.audioEngine.hasRenderedAudio)
        speech.releaseSpeech()
        XCTAssertFalse(speech.audioEngine.hasRenderedAudio)
    }

    // MARK: - The engine's graph (audit C8)

    /// A service that only renders, lends its audio, is stopped, set to a
    /// speed, pitch, or volume, seeked, or discarded builds no engine graph:
    /// the look-ahead is such a service.
    func testAServiceThatNeverPlaysBuildsNoEngineGraph() {
        let lookAhead = AudioEngineService()
        lookAhead._installRenderedAudioForTesting(signature: nil)
        let taker = AudioEngineService()

        lookAhead.setSpeed(wpm: 300)
        lookAhead.setPitch(multiplier: 1.2)
        lookAhead.setVolume(0.5)
        lookAhead.restoreVolume()
        lookAhead.seek(toCharOffset: 0)
        lookAhead.stop()
        taker.adoptRenderedAudio(from: lookAhead)
        _ = lookAhead.outputVolume
        _ = lookAhead.discardRenderedAudio()

        XCTAssertEqual(lookAhead._engineBuildCountForTesting, 0)
        XCTAssertEqual(taker._engineBuildCountForTesting, 0)
        XCTAssertTrue(taker.hasRenderedAudio, "the audio was adopted all the same")
    }

    /// The first play builds the graph, once, and what was set before it
    /// (speed, pitch, volume) holds: the graph's setup must not reset them.
    func testThePlayBuildsTheGraphOnceAndKeepsWhatWasSetBeforeIt() {
        let service = AudioEngineService()
        service._refusesToStartForTesting = true
        service._installRenderedAudioForTesting(signature: nil, lasting: 1)
        service.setSpeed(wpm: 600)
        service.setPitch(multiplier: 1.5)
        service.setVolume(0.4)
        let rate = service.playbackRate
        let pitch = service.playbackPitchCents

        service.play()
        service.play()

        XCTAssertEqual(service._engineBuildCountForTesting, 1)
        XCTAssertEqual(service.playbackRate, rate)
        XCTAssertEqual(service.playbackPitchCents, pitch)
        XCTAssertEqual(service.outputVolume, 0.4, accuracy: 0.001)
        service.stop()
    }

    /// A chapter taken from the look-ahead builds no graph in the look-ahead.
    func testAdoptingTheLookAheadsAudioBuildsNothingInTheLookAhead() {
        let speech = makeSpeech()
        defer { speech.stop() }
        let text = "Gulls circled the cranes."
        let rendered = AudioEngineService()
        rendered._installRenderedAudioForTesting(
            signature: SpeechRenderRequest(text: text, voice: speech.currentVoice).signature
        )

        speech.usePreRenderedEngine(rendered, text: text)
        speech.stop()

        XCTAssertEqual(rendered._engineBuildCountForTesting, 0)
    }

    /// The speech service's own engine has its graph built as it is made,
    /// once, so that no seek or resume waits for it; a look-ahead's does not.
    func testTheSpeechServicesEngineBuildsItsGraphWhenMade() {
        let speech = makeSpeech()
        defer { speech.stop() }
        let lookAhead = AudioEngineService()

        XCTAssertEqual(speech.audioEngine._engineBuildCountForTesting, 1)
        XCTAssertEqual(speech.audioEngine._engineBuildCountForTesting, 1, "reading it again builds nothing more")
        XCTAssertEqual(lookAhead._engineBuildCountForTesting, 0)
    }

    // MARK: - Play after Stop (audit C9)

    /// Speaking the text the engine holds rendered audio of, in the same
    /// voice, keeps that audio: no discard and no new render.
    func testPlayAfterStopOnTheSameTextKeepsTheRender() {
        let speech = makeSpeech()
        defer { speech.stop() }
        let text = "The ferry left the quay at noon."
        let signature = SpeechRenderRequest(text: text, voice: speech.currentVoice).signature
        speech.audioEngine._installRenderedAudioForTesting(signature: signature)

        speech.stop()
        speech.speak(text)

        XCTAssertTrue(speech.audioEngine.hasRenderedAudio)
        XCTAssertEqual(speech.audioEngine.renderedSignature, signature)
        XCTAssertTrue(speech.isSpeaking, "speech starts directly, as ever")
        // A render request would have set this, and cleared the audio.
        XCTAssertFalse(speech.audioEngine.isRendering, "no render was requested")
    }

    /// Other text still discards the held audio, as a seek or resume must
    /// not play another chapter's.
    func testSpeakingOtherTextStillDiscardsTheRender() {
        let speech = makeSpeech()
        defer { speech.stop() }
        let signature = SpeechRenderRequest(text: "The ferry left the quay at noon.", voice: speech.currentVoice).signature
        speech.audioEngine._installRenderedAudioForTesting(signature: signature)

        // Too long to render, so nothing is rendered afresh.
        speech.speak(Self.longText)

        XCTAssertFalse(speech.audioEngine.hasRenderedAudio)
    }

    // MARK: - Readers

    /// An audiobook's reader never makes a speech engine: opening, stopping,
    /// and closing it leave none.
    func testAnAudiobookReaderMakesNoSpeechEngine() throws {
        try withReader(format: .audio) { reader in
            reader.stop()
            reader.pause()
            XCTAssertFalse(reader.speechService.hasAudioEngine)
            reader.close()
            XCTAssertFalse(reader.speechService.hasAudioEngine)
        }
    }

    /// A text book's reader makes no speech engine to open, stop, or pause.
    func testATextReaderMakesNoSpeechEngineToOpenOrStop() throws {
        try withReader(format: .txt) { reader in
            reader.stop()
            reader.pause()
            XCTAssertFalse(reader.speechService.hasAudioEngine)
        }
    }

    // MARK: - Benchmark

    /// What opening a reader paid for its speech engine before PERF08: the
    /// session's first engine, cold. The review measured 142 ms, and once
    /// 2.5 s with the audio system cold. Times a text reader's initializer,
    /// which makes none now, and then the first engine.
    ///
    /// Opt-in and meaningful only alone in a process of its own: pass
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` and this one test to
    /// `-only-testing`.
    func testBenchmarkTheFirstEngineInAColdProcess() throws {
        guard largeBenchmarksRequested else {
            throw XCTSkip("Makes the session's first engine; set TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1 and run it alone")
        }
        var readerInit = 0.0
        try withReader(format: .txt, timingInitializer: { readerInit = $0 }) { reader in
            XCTAssertFalse(reader.speechService.hasAudioEngine)
        }
        // An engine's cost is its graph, built by `prepareGraph()` as speech
        // makes its engine; the bare initializer builds none (audit C8).
        let firstEngine = benchmarkTiming { let engine = AudioEngineService(); engine.prepareGraph(); return engine }
        let secondEngine = benchmarkTiming { let engine = AudioEngineService(); engine.prepareGraph(); return engine }
        withExtendedLifetime((firstEngine.value, secondEngine.value)) {}

        reportBenchmark("PERF08 speech engine", [
            "newTextReaderInitMilliseconds": readerInit,
            "oldFirstEngineMilliseconds": firstEngine.milliseconds,
            "laterEngineMilliseconds": secondEngine.milliseconds,
        ])
    }

    // MARK: - Helpers

    /// A text longer than the render limit, so speech never renders it.
    private static let longText: String = {
        var prose = BenchmarkProse(seed: 73)
        return prose.text(utf16Length: SpeechRenderCoordinator.maximumTextLength + 10_000)
    }()

    /// A speech service with preferences of its own whose direct utterances
    /// go to a recorder that drops them instead of to the synthesizer.
    private func makeSpeech() -> SpeechService {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("engine-creation"))
        speech._directUtteranceRecorderForTesting = { _ in }
        return speech
    }

    /// Run `body` with a reader of a book in `format` whose files do not
    /// exist, so nothing loads, then close it. `timingInitializer`, when
    /// given, hears how many milliseconds the reader's initializer took.
    private func withReader(
        format: BookFormat,
        timingInitializer: ((Double) -> Void)? = nil,
        _ body: (ReaderViewModel) throws -> Void
    ) throws {
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("engine-creation-reader")
        )
        let book = Book(
            title: "Quiet Engines",
            format: format,
            filePath: "/tmp/\(UUID().uuidString)-quiet-engines",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let made = benchmarkTiming {
            ReaderViewModel(
                book: book,
                libraryViewModel: library,
                settingsViewModel: settings,
                substitutionService: TextSubstitutionService(rules: []),
                notificationCenter: NotificationCenter(),
                renderScheduler: HeldRenderQueue()
            )
        }
        timingInitializer?(made.milliseconds)
        let reader = made.value
        defer { reader.close() }
        try recordingAnnouncements {
            try body(reader)
        }
    }
}
