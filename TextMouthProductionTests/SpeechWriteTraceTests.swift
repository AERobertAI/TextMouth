import AVFoundation
import os
import XCTest
@testable import TextMouth

/// Every path that writes speech into buffers, replayed against recorded
/// traces of what a real write does on macOS 27 and on macOS 26
/// (`SpeechWriteTrace`), with no voice and no sound (Q20, layer 1 of
/// research/SPEECH-TESTS-PLAN-2026-11-28.md).
///
/// B31 is what these would have caught: on macOS 27 a write sends an empty
/// buffer after each of its segments and `didFinish` after the last, and the
/// engine's render and the speech export took the first empty buffer for the
/// end, so a chapter's audio held its first sentence. Each test below that
/// replays a multi-segment trace fails on that code: the replay delivers its
/// segments apart in time (`ScriptedTraceWriter.segmentGap`), so a write that
/// ends at the first empty buffer has left before the second segment comes.
///
/// Every wait here has a limit, nothing calls `speak`, and no audio engine is
/// started (a render only fills memory).
@MainActor
final class SpeechWriteTraceTests: XCTestCase {

    // MARK: - The Traces Themselves

    /// The traces say what the probe found, so a trace edited by mistake
    /// can't quietly stop guarding what it was made for.
    func testTheTracesHoldWhatTheProbeFound() {
        let five = SpeechWriteTrace.fiveSentencesOnMacOS27
        XCTAssertEqual(five.emptyBufferCount, 2, "two segments, each ended by an empty buffer")
        XCTAssertEqual(five.segments.count, 2)
        XCTAssertEqual(five.textLength, 350)
        XCTAssertFalse(five.stopIsHonored)

        let forty = SpeechWriteTrace.fortySentencesOnMacOS27
        XCTAssertEqual(forty.emptyBufferCount, 14)
        XCTAssertEqual(forty.segments.count, 14)
        XCTAssertEqual(forty.textLength, 2_807)

        let old = SpeechWriteTrace.fiveSentencesOnMacOS26
        XCTAssertEqual(old.emptyBufferCount, 1, "macOS 26 sends one empty buffer, at the end")
        XCTAssertTrue(old.stopIsHonored)

        for trace in SpeechWriteTrace.allWholeTexts + [SpeechWriteTrace.oneWord(system: "macOS 27.2.1"), SpeechWriteTrace.oneWord(system: "macOS 26")] {
            let label = "\(trace.system) \(trace.name)"
            XCTAssertEqual(trace.finishCount, 1, label)
            XCTAssertEqual(trace.cancelCount, 0, label)
            XCTAssertEqual(trace.events.last, .didFinish, "\(label): the finish is the write's last event")
            XCTAssertEqual(trace.events.dropLast().last, .emptyBuffer, "\(label): the finish follows the last empty buffer")
            XCTAssertGreaterThan(trace.audioFrames, 0, label)
            // The words rise through the text and the last reaches its end.
            let ranges = trace.wordRanges
            XCTAssertEqual(ranges.map(\.location), ranges.map(\.location).sorted(), label)
            XCTAssertEqual(ranges.last.map { $0.location + $0.length }, trace.textLength, "\(label): the last word ends at the text's end")
            XCTAssertEqual(trace.text.utf16.count, trace.textLength, label)
        }
        XCTAssertEqual(SpeechWriteTrace.refused.cancelCount, 1)
        XCTAssertEqual(SpeechWriteTrace.refused.audioFrames, 0)
    }

    /// A trace is data: it is written and read as JSON and comes back equal.
    func testATraceSurvivesBeingWrittenAndRead() throws {
        for trace in SpeechWriteTrace.allWholeTexts + [SpeechWriteTrace.refused] {
            let data = try JSONEncoder().encode(trace)
            XCTAssertEqual(try JSONDecoder().decode(SpeechWriteTrace.self, from: data), trace)
        }
    }

    // MARK: - The Scripted Writer

    /// The writer replays a trace as the synthesizer does: every buffer, the
    /// empty buffer of each segment, every word range, and one finish, on the
    /// main thread, in the trace's order.
    func testTheWriterReplaysATraceThroughTheSynthesizersCallbacks() {
        let trace = SpeechWriteTrace.fiveSentencesOnMacOS27
        let words = OSAllocatedUnfairLock<[NSRange]>(initialState: [])
        let writer = ScriptedTraceWriter(trace, onWord: { range in words.withLock { $0.append(range) } })
        let counts = CallbackCounts()

        counts.start(writer)

        XCTAssertTrue(waitUntil(timeout: 10) { counts.finishes > 0 }, "the replay never finished")
        XCTAssertEqual(counts.audioFrames, trace.audioFrames)
        XCTAssertEqual(counts.emptyBuffers, 2)
        XCTAssertEqual(counts.finishes, 1)
        XCTAssertEqual(counts.cancels, 0)
        XCTAssertEqual(words.withLock { $0 }, trace.wordRanges)
        XCTAssertTrue(writer.deliveredOnTheMainThread)
    }

    /// A stop is counted and ignored on macOS 27, where the write goes on to
    /// its `didFinish`, and honored on macOS 26, where the rest is dropped and
    /// the write ends with `didCancel`.
    func testAStopIsIgnoredOnMacOS27AndHonoredOnMacOS26() {
        for trace in [SpeechWriteTrace.fortySentencesOnMacOS27, SpeechWriteTrace.fiveSentencesOnMacOS26.withTwoSegments()] {
            let writer = ScriptedTraceWriter(trace, holdBeforeSegment: 1)
            let counts = CallbackCounts()
            counts.start(writer)
            XCTAssertTrue(waitUntil(timeout: 10) { writer.isWaitingForRelease }, "\(trace.system): the replay never reached its hold")

            writer.stop()
            writer.release()

            XCTAssertTrue(waitUntil(timeout: 10) { counts.finishes + counts.cancels > 0 }, "\(trace.system): the write never ended")
            XCTAssertEqual(writer.stops, 1)
            if trace.stopIsHonored {
                XCTAssertEqual(counts.cancels, 1, "\(trace.system): a stop that works ends the write with a cancel")
                XCTAssertEqual(counts.finishes, 0)
                XCTAssertLessThan(counts.audioFrames, trace.audioFrames)
            } else {
                XCTAssertEqual(counts.finishes, 1, "\(trace.system): a stop that does nothing leaves the write to its finish")
                XCTAssertEqual(counts.cancels, 0)
                XCTAssertEqual(counts.audioFrames, trace.audioFrames)
            }
        }
    }

    // MARK: - The Engine's Render

    /// A render keeps every frame the synthesizer writes, whichever way the
    /// system cuts the write: the audio it installs holds the trace's frames
    /// to the last, the frame map ends at them, and nothing is cut short at
    /// an empty buffer. This is B31: rendered at the first empty buffer,
    /// macOS 27's 350 units gave 200's worth of audio, and 14 segments of 40
    /// sentences gave one.
    func testARenderKeepsEveryFrameOfEveryTrace() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        for trace in SpeechWriteTrace.allWholeTexts {
            let engine = AudioEngineService(makeWriter: { ScriptedTraceWriter(trace) })
            defer { engine.discardRenderedAudio() }
            let request = SpeechRenderRequest(text: trace.text, voice: nil)

            let installed = render(request, with: engine)

            let label = "\(trace.system) \(trace.name)"
            XCTAssertEqual(installed, true, "\(label): the render did not install its audio")
            XCTAssertEqual(
                engine._frameForCharOffsetForTesting(trace.textLength),
                AVAudioFramePosition(trace.audioFrames),
                "\(label): the render kept \(engine._frameForCharOffsetForTesting(trace.textLength)) of the write's \(trace.audioFrames) frames"
            )
            XCTAssertEqual(engine.renderedSignature, request.signature, label)
            XCTAssertFalse(engine.isRendering, label)
        }
    }

    /// A render let go of mid-write (Stop, a seek, a voice change) ends its
    /// wait at once, although the synthesizer ignores the stop on macOS 27 and
    /// goes on to the end of the chapter: the render reports failed within
    /// seconds while the write is still held back, nothing is installed, and
    /// the writer was told to stop. On macOS 26 the stop works and the write
    /// ends with a cancel; the render reports the same.
    func testARenderLetGoMidWriteEndsAtOnce() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        for trace in [SpeechWriteTrace.fortySentencesOnMacOS27, SpeechWriteTrace.fiveSentencesOnMacOS26.withTwoSegments()] {
            let writers = WriterLog()
            let engine = AudioEngineService(makeWriter: { writers.add(ScriptedTraceWriter(trace, holdBeforeSegment: 1)) })
            defer { engine.discardRenderedAudio() }
            let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            engine.render(SpeechRenderRequest(text: trace.text, voice: nil)) { installed in
                outcome.withLock { $0 = installed }
            }
            let label = "\(trace.system) \(trace.name)"
            XCTAssertTrue(waitUntil(timeout: 10) { writers.first?.isWaitingForRelease == true }, "\(label): the write never reached its hold")
            let writer = try XCTUnwrap(writers.first)
            let letGoAt = ContinuousClock.now

            engine.cancelRender()

            XCTAssertTrue(waitUntil(timeout: 5) { outcome.withLock { $0 } != nil }, "\(label): a let-go render never reported")
            XCTAssertLessThan(letGoAt.duration(to: .now), .seconds(3), "\(label): the render waited for the write")
            XCTAssertEqual(outcome.withLock { $0 }, false, "\(label): a let-go render reported audio installed")
            XCTAssertEqual(writer.stops, 1, "\(label): the writer was not told to stop")
            XCTAssertFalse(writer.isFinished, "\(label): the write had ended by itself, so the render was not let go mid-write")

            // The synthesizer's late buffers change nothing.
            writer.release()
            XCTAssertTrue(waitUntil(timeout: 10) { writer.isFinished }, "\(label): the held write never ended")
            XCTAssertFalse(engine.hasRenderedAudio, "\(label): a late buffer installed audio")
            XCTAssertFalse(engine.isRendering, label)
        }
    }

    /// A text the speech engine refuses (`didCancel` and no buffer) is written
    /// once more with every bracket silent, on a writer of its own; when that
    /// is refused too nothing is installed, and when it is written whole, on
    /// macOS 27's segments, all of it is.
    func testARefusedRenderIsWrittenAgainOnAFreshWriter() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let whole = SpeechWriteTrace.fortySentencesOnMacOS27
        let cases: [(name: String, traces: [SpeechWriteTrace], installs: Bool)] = [
            ("refused twice", [.refused, .refused], false),
            ("refused once, then whole", [.refused, whole], true),
        ]
        for scenario in cases {
            let writers = WriterLog()
            let engine = AudioEngineService(makeWriter: {
                let index = writers.count
                return writers.add(ScriptedTraceWriter(scenario.traces[min(index, scenario.traces.count - 1)]))
            })
            defer { engine.discardRenderedAudio() }
            let request = SpeechRenderRequest(text: whole.text, voice: nil)

            let installed = render(request, with: engine)

            XCTAssertEqual(installed, scenario.installs, scenario.name)
            XCTAssertEqual(writers.count, 2, "\(scenario.name): a refused text is written once more, and only once")
            XCTAssertEqual(engine.hasRenderedAudio, scenario.installs, scenario.name)
            if scenario.installs {
                XCTAssertEqual(engine._frameForCharOffsetForTesting(whole.textLength), AVAudioFramePosition(whole.audioFrames), scenario.name)
            }
        }
    }

    /// Renders `request` on `engine`, which writes through its scripted
    /// writer, spinning the main thread (where the writer delivers) until the
    /// engine reports; nil when it never does.
    private func render(_ request: SpeechRenderRequest, with engine: AudioEngineService, timeout: TimeInterval = 30) -> Bool? {
        let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        engine.render(request) { installed in outcome.withLock { $0 = installed } }
        _ = waitUntil(timeout: timeout) { outcome.withLock { $0 } != nil }
        return outcome.withLock { $0 }
    }

    // MARK: - The Speech Export

    /// The export's write keeps every frame of every trace: the chapter's file
    /// holds all the audio, not the first segment's. The chapter is written
    /// through the same `SystemSpeechBufferSynthesizer` the app exports with,
    /// over a scripted writer, off the main thread as the export runs it.
    func testTheExportWritesEveryFrameOfEveryTrace() async throws {
        for trace in SpeechWriteTrace.allWholeTexts {
            let url = try makeSandboxDirectory("SpeechWriteTraceTests").appendingPathComponent("chapter.caf")

            let rendered = try await renderChapter(of: trace, to: url)

            let label = "\(trace.system) \(trace.name)"
            XCTAssertEqual(rendered.frameCount, Int64(trace.audioFrames), "\(label): the chapter lost frames")
            XCTAssertEqual(rendered.sampleRate, trace.sampleRate, label)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, Int64(trace.audioFrames), "\(label): the file lost frames")
        }
    }

    /// Stop ends an export's write within a moment even where the synthesizer
    /// ignores it (macOS 27): the write throws `CancellationError`, tells the
    /// writer to stop, and hands on nothing the writer sends after it.
    func testStopEndsAnExportWriteThatTheSynthesizerIgnores() async throws {
        try XCTSkipIf(Self.standInVoice() == nil, "No installed voice to stand in for the utterance's voice")
        let trace = SpeechWriteTrace.fortySentencesOnMacOS27
        let writer = ScriptedTraceWriter(trace, holdBeforeSegment: 2)
        let handedOn = OSAllocatedUnfairLock(initialState: 0)
        let cancellation = BookExportCancellation()
        let synthesizer = Self.synthesizer(over: writer)
        let outcome = OSAllocatedUnfairLock<Result<SpeechWriteEnd, Error>?>(initialState: nil)
        let ended = expectation(description: "the write ended")
        ended.assertForOverFulfill = false
        DispatchQueue.global().async {
            let utterance = SpeechExportUtterance(text: trace.text, voiceIdentifier: "stand-in", rate: 0.5, pitchMultiplier: 1)
            let result = Result {
                try synthesizer.write(utterance, cancellation: cancellation) { _ in handedOn.withLock { $0 += 1 } }
            }
            outcome.withLock { $0 = result }
            ended.fulfill()
        }
        let reachedHold = await eventually(timeout: 10) { writer.isWaitingForRelease }
        XCTAssertTrue(reachedHold, "the write never reached its hold")
        let pressedAt = ContinuousClock.now

        cancellation.cancel()
        await fulfillment(of: [ended], timeout: 10)

        XCTAssertLessThan(pressedAt.duration(to: .now), .seconds(3), "Stop waited for the rest of the chapter")
        if case .failure(let error)? = outcome.withLock({ $0 }) {
            XCTAssertTrue(error is CancellationError, "\(error)")
        } else {
            XCTFail("the stopped write did not throw")
        }
        XCTAssertEqual(writer.stops, 1)
        // The synthesizer, which ignores the stop, goes on; nothing is handed on after.
        let handedOnAtStop = handedOn.withLock { $0 }
        writer.release()
        let replayEnded = await eventually(timeout: 10) { writer.isFinished }
        XCTAssertTrue(replayEnded, "the held replay never ended")
        XCTAssertEqual(handedOn.withLock { $0 }, handedOnAtStop, "a buffer was handed on after the write ended")
    }

    /// Waits, yielding the main actor, until `condition` holds or `timeout`
    /// seconds pass, and says whether it held. An async test cannot spin the
    /// main run loop (`waitUntil`): it runs as a block of the main queue, and
    /// the writer's deliveries, which are main-queue blocks too, would wait
    /// behind it for as long as it spun.
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Writes `trace`'s text into a CAF at `url` as an export chapter, on a
    /// queue off the main thread, which the writer's callbacks need free.
    private func renderChapter(of trace: SpeechWriteTrace, to url: URL) async throws -> RenderedSpeechChapter {
        try XCTSkipIf(Self.standInVoice() == nil, "No installed voice to stand in for the utterance's voice")
        let synthesizer = Self.synthesizer(over: ScriptedTraceWriter(trace))
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try SpeechChapterRenderer.render(
                        title: "Trace",
                        texts: [trace.text],
                        voiceIdentifier: "stand-in",
                        wordsPerMinute: 250,
                        pitch: 1,
                        trailingSilence: 0,
                        to: url,
                        synthesizer: synthesizer,
                        cancellation: BookExportCancellation()
                    )
                })
            }
        }
    }

    /// The Mac's synthesizer over `writer`, with short limits, the stand-in
    /// voice, and no Personal Voice: it never reaches a real voice.
    private nonisolated static func synthesizer(over writer: ScriptedTraceWriter) -> SystemSpeechBufferSynthesizer {
        SystemSpeechBufferSynthesizer(
            stallLimits: SystemSpeechBufferSynthesizer.StallLimits(firstBufferFloor: 10, firstBufferPerUnit: 0, betweenBuffers: 10),
            makeWriter: { writer },
            findVoice: { _ in standInVoice() },
            isPersonalVoice: { _ in false }
        )
    }

    /// An installed voice to stand in as the voice an utterance names: the
    /// scripted writer ignores it, and it is never spoken with.
    private nonisolated static func standInVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - The Voice Warm-Up

    /// The warm-up writes one word and is done at its one empty buffer, once,
    /// on either system's trace: there is no second segment to wait for, and
    /// the write's finish that follows does not report it again.
    func testTheWarmUpReportsAtTheOneWordsEmptyBuffer() {
        for system in ["macOS 27.2.1", "macOS 26"] {
            let trace = SpeechWriteTrace.oneWord(system: system)
            let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
            let writer = ScriptedTraceWriter(trace)

            VoiceWarmUp.writeOneWord(in: nil, makeWriter: { writer }) { finished in
                reports.withLock { $0.append(finished) }
            }

            XCTAssertTrue(waitUntil(timeout: 10) { writer.isFinished }, "\(system): the replay never finished")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(reports.withLock { $0 }, [true], "\(system): the warm-up must report its end once, as finished")
            XCTAssertEqual(writer.framesDelivered, trace.audioFrames)
        }
    }

    /// A word the engine refuses (`didCancel`, no buffer) is not reported by
    /// the warm-up: it ends at its 30-second limit, which a test does not wait
    /// for, so only that nothing was reported at the cancel is checked.
    func testTheWarmUpDoesNotReportARefusedWord() {
        let writer = ScriptedTraceWriter(.refused)
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        VoiceWarmUp.writeOneWord(in: nil, makeWriter: { writer }) { finished in
            reports.withLock { $0.append(finished) }
        }

        XCTAssertTrue(waitUntil(timeout: 10) { writer.isFinished })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(reports.withLock { $0.isEmpty }, "a refused word was reported before the limit")
    }
}

// MARK: - Helpers

/// The callbacks one scripted write makes, counted from any thread.
private final class CallbackCounts: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (frames: 0, empties: 0, finishes: 0, cancels: 0))

    /// Starts `writer` on this object's counters.
    func start(_ writer: ScriptedTraceWriter) {
        writer.start(
            AVSpeechUtterance(string: "unused"),
            onBuffer: { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // Read outside the lock's closure, which must not capture the buffer.
                let frames = Int(pcm.frameLength)
                state.withLock {
                    if frames == 0 { $0.empties += 1 } else { $0.frames += frames }
                }
            },
            onFinish: { [self] in state.withLock { $0.finishes += 1 } },
            onCancel: { [self] in state.withLock { $0.cancels += 1 } }
        )
    }

    var audioFrames: Int { state.withLock { $0.frames } }
    var emptyBuffers: Int { state.withLock { $0.empties } }
    var finishes: Int { state.withLock { $0.finishes } }
    var cancels: Int { state.withLock { $0.cancels } }
}

/// The writers an engine made, in order, kept under a lock.
private final class WriterLog: Sendable {
    private let writers = OSAllocatedUnfairLock<[ScriptedTraceWriter]>(initialState: [])

    /// Keeps `writer` and gives it back.
    func add(_ writer: ScriptedTraceWriter) -> ScriptedTraceWriter {
        writers.withLock { $0.append(writer) }
        return writer
    }

    /// How many were made.
    var count: Int { writers.withLock { $0.count } }
    /// The first made, or nil.
    var first: ScriptedTraceWriter? { writers.withLock { $0.first } }
}

private extension SpeechWriteTrace {
    /// This trace cut into two segments at its middle, for a test of a stop
    /// that works, which needs a segment to hold the write before.
    func withTwoSegments() -> SpeechWriteTrace {
        SpeechWriteTrace.segmented(
            name: name,
            system: system,
            segmentEnds: [textLength / 2, textLength],
            framesPerUnit: audioFrames / max(textLength, 1),
            stopIsHonored: stopIsHonored
        )
    }
}
