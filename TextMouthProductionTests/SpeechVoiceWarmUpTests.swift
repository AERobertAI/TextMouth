import AVFoundation
import os
import XCTest
@testable import TextMouth

/// A voice is loaded into the system synthesizer ahead of the first Play by
/// rendering one silent word with it (PERF03): a text reader asks for its
/// voice when it opens and whenever the voice changes, the render queue
/// writes each voice once, in its turn, and never speaks.
///
/// The coordinator's closures are `@Sendable`, so what they record lives in
/// `OSAllocatedUnfairLock`s. The readers here ask a recording stand-in, so
/// nothing is synthesized; only the two opt-in benchmarks use the system
/// synthesizer, muted.
@MainActor
final class SpeechVoiceWarmUpTests: XCTestCase {

    // MARK: - The render queue

    /// Each voice, the system's default voice among them, is written once,
    /// however often it is asked for, in the order first asked.
    func testEachVoiceIsWarmedOnce() throws {
        let (first, second) = try twoVoices()
        let coordinator = SpeechRenderCoordinator()
        let written = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let write: @MainActor @Sendable (AVSpeechSynthesisVoice?, @escaping @Sendable (Bool) -> Void) -> Void = { voice, finished in
            written.withLock { $0.append(voice?.identifier) }
            finished(true)
        }

        for voice in [first, first, second, nil, first, second, nil] {
            coordinator.warmUp(voice, writing: write)
        }

        XCTAssertTrue(waitUntil(timeout: 5) { written.withLock { $0.count } == 3 }, "not every voice was warmed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(written.withLock { $0 }, [first.identifier, second.identifier, nil])
    }

    /// A warm-up takes its turn on the render queue: it waits for a render
    /// under way, so the two never use the synthesizer at once.
    func testAWarmUpWaitsForTheRenderUnderWay() {
        let coordinator = SpeechRenderCoordinator()
        let finishRender = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        coordinator.enqueue(
            textLength: 10,
            shouldStart: { true },
            start: { finish in finishRender.withLock { $0 = finish } },
            completion: { _ in }
        )
        let written = OSAllocatedUnfairLock(initialState: 0)

        coordinator.warmUp(nil) { _, finished in
            written.withLock { $0 += 1 }
            finished(true)
        }

        XCTAssertTrue(waitUntil(timeout: 5) { finishRender.withLock { $0 } != nil }, "the render never started")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(written.withLock { $0 }, 0, "the warm-up wrote while a render was under way")
        finishRender.withLock { $0 }?(true)
        XCTAssertTrue(waitUntil(timeout: 5) { written.withLock { $0 } == 1 }, "the warm-up never had its turn")
    }

    /// A warm-up reports its end once: the synthesizer's last buffer and the
    /// timeout race to report it, and only the first counts.
    func testAWarmUpReportsItsEndOnce() {
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let report = VoiceWarmUp.reportingOnce { finished in
            reports.withLock { $0.append(finished) }
        }

        report(true)
        report(false)
        report(true)

        XCTAssertEqual(reports.withLock { $0 }, [true])
    }

    /// The warm-up's buffer callback runs safely on any thread (board #732):
    /// made outside the main actor, it carries no main-actor check, so the
    /// synthesizer may call it from a thread of its own. Made and called
    /// here on a detached task's thread, as the synthesizer would call it: a
    /// buffer holding audio reports nothing, the last, empty buffer reports
    /// the warm-up finished, and a second last buffer counts for nothing.
    /// The synthesizer it keeps alive is never asked to write anything.
    func testTheWarmUpsBufferCallbackRunsOnAnyThread() async throws {
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let report = VoiceWarmUp.reportingOnce { finished in
            reports.withLock { $0.append(finished) }
        }

        let calledOnTheMainThread = try await Task.detached { () throws -> Bool in
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
            let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            audio.frameLength = 16
            let last = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            let callback = VoiceWarmUp.lastBufferReporter(keepingAlive: AVSpeechSynthesizer(), report: report)

            callback(audio)
            XCTAssertTrue(reports.withLock { $0.isEmpty }, "A buffer holding audio reported the warm-up finished")
            callback(last)
            callback(last)
            return pthread_main_np() != 0
        }.value

        XCTAssertFalse(calledOnTheMainThread, "The callback was not called from another thread")
        XCTAssertEqual(reports.withLock { $0 }, [true])
    }

    // MARK: - Readers

    /// A text book's reader asks for its voice to be warmed when it opens.
    func testOpeningATextBookWarmsItsVoice() throws {
        try withReader(format: .txt) { reader, recorder in
            XCTAssertFalse(recorder.warmedVoices.isEmpty)
            XCTAssertEqual(recorder.warmedVoices.last, reader.speechService.currentVoice?.identifier)
        }
    }

    /// An audiobook speaks no chapters, so its reader warms nothing.
    func testOpeningAnAudiobookWarmsNothing() throws {
        try withReader(format: .audio) { _, recorder in
            XCTAssertTrue(recorder.warmedVoices.isEmpty)
        }
    }

    /// A voice chosen for the book, or in Settings, is warmed.
    func testAChosenVoiceIsWarmed() throws {
        let (first, second) = try twoVoices()
        try withReader(format: .txt) { reader, recorder in
            reader.setLocalVoice(first)
            XCTAssertEqual(recorder.warmedVoices.last, first.identifier)

            reader.resetToGlobalSettings()
            reader.speechService.currentVoice = second
            reader.notificationCenter.post(name: .speechSettingsChanged, object: nil)
            XCTAssertEqual(recorder.warmedVoices.last, second.identifier)
        }
    }

    // MARK: - Benchmarks

    /// The first word of a session's first utterance, as Play spoke it
    /// before PERF03: the voice loads first. The review measured 3.1 to
    /// 4.5 s.
    ///
    /// Opt-in, since it uses the system synthesizer (muted), and meaningful
    /// only alone in a process of its own: pass
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` and this one test to
    /// `-only-testing`.
    func testBenchmarkTheFirstWordInAColdProcess() throws {
        guard largeBenchmarksRequested else {
            throw XCTSkip("Uses the synthesizer; set TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1 and run it alone")
        }
        let voice = SpeechService(userDefaults: makeSandboxedPreferences("voice-warm-up-cold")).currentVoice
        let firstWord = try XCTUnwrap(mutedFirstWordMilliseconds(Self.firstChunk, voice: voice), "no word was spoken")

        reportBenchmark("PERF03 first word", [
            "voice": voice?.identifier ?? "default",
            "warmedUp": false,
            "firstWordMilliseconds": firstWord,
        ])
    }

    /// The first word of a session's first utterance once the reader has
    /// warmed its voice, as it does when it opens, before Play.
    ///
    /// Opt-in and alone in its process, as
    /// `testBenchmarkTheFirstWordInAColdProcess` is.
    func testBenchmarkTheFirstWordAfterAWarmUp() throws {
        guard largeBenchmarksRequested else {
            throw XCTSkip("Uses the synthesizer; set TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1 and run it alone")
        }
        let voice = SpeechService(userDefaults: makeSandboxedPreferences("voice-warm-up-warm")).currentVoice
        let warmed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let warmUp = benchmarkTiming {
            VoiceWarmUp.writeOneWord(in: voice) { finished in warmed.withLock { $0 = finished } }
            return waitUntil(timeout: 40) { warmed.withLock { $0 } != nil }
        }
        XCTAssertTrue(warmUp.value, "the warm-up never ended")
        XCTAssertEqual(warmed.withLock { $0 }, true, "the warm-up timed out")
        let firstWord = try XCTUnwrap(mutedFirstWordMilliseconds(Self.firstChunk, voice: voice), "no word was spoken")

        reportBenchmark("PERF03 first word", [
            "voice": voice?.identifier ?? "default",
            "warmedUp": true,
            "warmUpMillisecondsOffTheMainThread": warmUp.milliseconds,
            "firstWordMilliseconds": firstWord,
        ])
    }

    // MARK: - Helpers

    /// What direct speech hands the synthesizer first, as Play does today.
    private static var firstChunk: String {
        var prose = BenchmarkProse(seed: 53)
        let text = prose.text(utf16Length: 5_000)
        return String(text[..<text.index(atUTF16Offset: 5_000)])
    }

    /// Milliseconds from handing `text` to a new synthesizer, muted, in
    /// `voice`, until its first word is about to be spoken; nil when no word
    /// came within 15 seconds. Nothing is heard: the volume is 0, and the
    /// utterance is stopped at once.
    private func mutedFirstWordMilliseconds(_ text: String, voice: AVSpeechSynthesisVoice?) -> Double? {
        let synthesizer = AVSpeechSynthesizer()
        let probe = FirstWordProbe()
        synthesizer.delegate = probe
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = SpeechService.rateForWPM(500)
        utterance.volume = 0
        utterance.prefersAssistiveTechnologySettings = false
        let start = ContinuousClock.now

        synthesizer.speak(utterance)
        _ = waitUntil(timeout: 15) { probe.firstWord != nil }
        synthesizer.stopSpeaking(at: .immediate)
        // Let the stop settle before the synthesizer goes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        synthesizer.delegate = nil

        return probe.firstWord.map { firstWord in
            let elapsed = start.duration(to: firstWord)
            return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        }
    }

    /// Two installed voices, or a skip on a Mac with only one.
    private func twoVoices() throws -> (AVSpeechSynthesisVoice, AVSpeechSynthesisVoice) {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard voices.count >= 2 else { throw XCTSkip("Needs two installed voices") }
        return (voices[0], voices[1])
    }

    /// Run `body` with a reader of a book in `format` whose warm-ups go to a
    /// recording stand-in, then close it. The book's files do not exist, so
    /// nothing loads; the reader asks for its voice as it is made.
    private func withReader(
        format: BookFormat,
        _ body: (ReaderViewModel, WarmUpRecorder) throws -> Void
    ) throws {
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("voice-warm-up")
        )
        let book = Book(
            title: "Warm Voices",
            format: format,
            filePath: "/tmp/\(UUID().uuidString)-warm-voices",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let recorder = WarmUpRecorder()
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: []),
            notificationCenter: NotificationCenter(),
            renderScheduler: recorder
        )
        defer { reader.close() }
        try recordingAnnouncements {
            try body(reader, recorder)
        }
    }
}

// MARK: - Test doubles

/// Records the voices a reader asks to warm up, and renders nothing.
@MainActor
private final class WarmUpRecorder: SpeechRenderScheduling {
    /// The voices asked for, in order, by identifier; nil is the system's
    /// default voice.
    private(set) var warmedVoices: [String?] = []

    /// Keeps nothing: these tests never render.
    func render(
        _ request: SpeechRenderRequest,
        engine: AudioEngineService,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {}

    func warmUp(_ voice: AVSpeechSynthesisVoice?) {
        warmedVoices.append(voice?.identifier)
    }
}

/// Hears, on whatever thread the synthesizer calls it, when the first word
/// of an utterance is about to be spoken.
private final class FirstWordProbe: NSObject, AVSpeechSynthesizerDelegate {
    /// When the first word came, kept under this lock.
    private let firstWordTime = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    /// When the first word came, if it has.
    var firstWord: ContinuousClock.Instant? {
        firstWordTime.withLock { $0 }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let now = ContinuousClock.now
        firstWordTime.withLock { if $0 == nil { $0 = now } }
    }
}
