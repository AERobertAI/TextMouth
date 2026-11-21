import AVFoundation
import os
import XCTest
@testable import TextMouth

/// The layer beneath the speech export's renderer that drives the Mac's
/// synthesizer (FMT43): `SpeechBufferDelivery`, which hands each buffer on
/// until the write ends, and `SystemSpeechBufferSynthesizer`'s wait for a
/// write, driven here through a finish, a refusal, a Stop, and a stall by a
/// scripted synthesizer and short limits.
///
/// Nothing here speaks: the scripted synthesizer makes its buffers in memory
/// and is never the Mac's. A real installed voice stands in only as the
/// voice an utterance names, and it is never asked to speak; a Personal Voice
/// is a flag of the test's own, never one the Mac has. Every write ends within
/// seconds, and each wait for one has a limit.
final class SpeechBufferSynthesizerTests: XCTestCase {

    // MARK: - The Delivery

    /// Buffers are handed on until the write ends, and never after, even
    /// when the synthesizer calls back late.
    func testNothingIsHandedOnAfterTheWriteEnds() throws {
        let handedOn = Counter()
        let delivery = SpeechBufferDelivery(onBuffer: { _ in handedOn.add() }, waking: DispatchSemaphore(value: 0))

        delivery.deliver(try Self.buffer(frames: 100))
        delivery.end()
        delivery.deliver(try Self.buffer(frames: 100))

        XCTAssertEqual(handedOn.value, 1)
    }

    /// An empty buffer, the synthesizer's last, wakes the waiting thread and
    /// is not handed on.
    func testAnEmptyBufferWakesTheWait() throws {
        let handedOn = Counter()
        let wake = DispatchSemaphore(value: 0)
        let delivery = SpeechBufferDelivery(onBuffer: { _ in handedOn.add() }, waking: wake)

        delivery.deliver(try Self.buffer(frames: 0))

        XCTAssertEqual(wake.wait(timeout: .now()), .success, "the last buffer did not wake the wait")
        XCTAssertEqual(handedOn.value, 0)
    }

    /// What `onBuffer` throws is kept, wakes the wait, and ends the write.
    func testAFailureOfOnBufferIsKeptAndWakesTheWait() throws {
        let wake = DispatchSemaphore(value: 0)
        let handedOn = Counter()
        let delivery = SpeechBufferDelivery(onBuffer: { _ in
            handedOn.add()
            throw CocoaError(.fileWriteOutOfSpace)
        }, waking: wake)

        delivery.deliver(try Self.buffer(frames: 100))
        delivery.deliver(try Self.buffer(frames: 100))

        XCTAssertEqual(wake.wait(timeout: .now()), .success, "the failure did not wake the wait")
        XCTAssertEqual((delivery.failure as? CocoaError)?.code, .fileWriteOutOfSpace)
        XCTAssertEqual(handedOn.value, 1, "a buffer was handed on after the failure")
    }

    /// A write stalls only past its limit: the first buffer's until the
    /// first comes, then the one between buffers. A stalled write has ended.
    func testAWriteStallsOnlyPastItsLimit() throws {
        let handedOn = Counter()
        let delivery = SpeechBufferDelivery(onBuffer: { _ in handedOn.add() }, waking: DispatchSemaphore(value: 0))

        XCTAssertFalse(delivery.endIfStalled(firstBufferLimit: 60, betweenBuffersLimit: 0), "the between limit applied before a buffer")
        delivery.deliver(try Self.buffer(frames: 100))
        XCTAssertFalse(delivery.endIfStalled(firstBufferLimit: 0, betweenBuffersLimit: 60), "the first buffer's limit applied after one")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(delivery.endIfStalled(firstBufferLimit: 60, betweenBuffersLimit: 0.01))

        delivery.deliver(try Self.buffer(frames: 100))
        XCTAssertEqual(handedOn.value, 1, "a stalled write handed a buffer on")
    }

    // MARK: - The Limits

    /// The first buffer is waited for in proportion to the text, never less
    /// than three minutes, and each later one for a minute.
    func testTheStallLimits() {
        let limits = SystemSpeechBufferSynthesizer.StallLimits.standard
        XCTAssertEqual(limits.firstBuffer(forUnits: 100_000), 200, accuracy: 0.000_1)
        XCTAssertEqual(limits.firstBuffer(forUnits: 1_000), 180)
        XCTAssertEqual(limits.firstBuffer(forUnits: 0), 180)
        XCTAssertEqual(limits.betweenBuffers, 60)
    }

    // MARK: - A Write

    /// Buffers come, then the empty last one: the write finishes, having
    /// handed each buffer on in order, and a buffer the synthesizer sends
    /// late, after the write returned, is never handed on.
    func testAWriteFinishesWithEveryBuffer() async throws {
        let writer = ScriptedBufferWriter(.finish(buffers: 3))
        let handedOn = Counter()

        let end = try await write(with: writer, onBuffer: { _ in handedOn.add() })

        XCTAssertEqual(end, .finished)
        XCTAssertEqual(handedOn.value, 3)
        writer.callBackLate()
        XCTAssertEqual(handedOn.value, 3, "a buffer sent after the write returned was handed on")
        XCTAssertEqual(writer.stops, 0)
    }

    /// The synthesizer cancelling the utterance on its own, with no buffer,
    /// as the speech engine does with a text it refuses, is a refusal, which
    /// the renderer then tries again with every bracket silent.
    func testACancelWithNoBufferIsARefusal() async throws {
        let writer = ScriptedBufferWriter(.refuse)

        let end = try await write(with: writer)

        XCTAssertEqual(end, .refused)
    }

    /// Stop pressed while the synthesizer is silent ends the write within a
    /// moment: it throws `CancellationError`, stops the synthesizer, and
    /// hands on nothing the synthesizer sends as it stops.
    ///
    /// Stop is pressed a moment after the write has *started*, not a moment after the test began: the test finds a
    /// stand-in voice before the write can start, and on a slow machine that took longer than the 0.3 seconds the
    /// test used to wait (full run 42902376383: the write began after Stop, ended at its first check with no
    /// synthesizer made, and `writer.stops` was 0).
    func testStopEndsAWriteAtOnce() async throws {
        let writer = ScriptedBufferWriter(.nothing, callsBackAsItStops: true)
        let handedOn = Counter()
        let cancellation = BookExportCancellation()
        let pressedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        DispatchQueue.global().async {
            // Waits for the write to begin (a minute at the most, so the test cannot hang), then for the synthesizer
            // to have been silent a while.
            let giveUp = Date().addingTimeInterval(60)
            while !writer.hasStarted && Date() < giveUp { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.3)
            pressedAt.withLock { $0 = .now }
            cancellation.cancel()
        }

        let error = await failure(of: writer, cancellation: cancellation, onBuffer: { _ in handedOn.add() })

        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        let pressed = try XCTUnwrap(pressedAt.withLock { $0 }, "Stop was never pressed")
        XCTAssertLessThan(pressed.duration(to: .now), .seconds(2), "Stop waited for the stall limit")
        XCTAssertEqual(writer.stops, 1)
        XCTAssertEqual(handedOn.value, 0, "a buffer sent as the synthesizer stopped was handed on")
    }

    /// Stop pressed before the write has started ends it at its first check, with no synthesizer made and so none
    /// to stop: the outcome that the test above used to meet by chance on a slow machine.
    func testStopPressedBeforeTheWriteStartsEndsItWithNothingToStop() async throws {
        let writer = ScriptedBufferWriter(.nothing, callsBackAsItStops: true)
        let cancellation = BookExportCancellation()
        cancellation.cancel()

        let error = await failure(of: writer, cancellation: cancellation)

        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertFalse(writer.hasStarted, "a synthesizer was started for a write that was stopped before it began")
        XCTAssertEqual(writer.stops, 0)
    }

    /// A synthesizer that sends nothing stalls the write at the first
    /// buffer's limit, and not before it: the write throws `stalled` and
    /// stops the synthesizer.
    func testASilentSynthesizerStallsAtTheFirstBuffersLimit() async throws {
        let writer = ScriptedBufferWriter(.nothing, callsBackAsItStops: true)
        let handedOn = Counter()
        let limits = SystemSpeechBufferSynthesizer.StallLimits(firstBufferFloor: 1.2, firstBufferPerUnit: 0, betweenBuffers: 0.3)
        let started = ContinuousClock.now

        let error = await failure(of: writer, limits: limits, onBuffer: { _ in handedOn.add() })

        XCTAssertEqual(error as? SpeechWriteFailure, .stalled)
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(1.2), "the between limit applied before the first buffer")
        XCTAssertLessThan(elapsed, .seconds(4))
        XCTAssertEqual(writer.stops, 1)
        XCTAssertEqual(handedOn.value, 0, "a buffer sent as the synthesizer stopped was handed on")
    }

    /// A synthesizer that sends one buffer and then nothing stalls the write
    /// at the limit between buffers, well before the first buffer's.
    func testASynthesizerThatStopsSendingStallsAtTheLimitBetweenBuffers() async throws {
        let writer = ScriptedBufferWriter(.oneThenNothing)
        let limits = SystemSpeechBufferSynthesizer.StallLimits(firstBufferFloor: 30, firstBufferPerUnit: 0, betweenBuffers: 0.3)
        let started = ContinuousClock.now

        let error = await failure(of: writer, limits: limits)

        XCTAssertEqual(error as? SpeechWriteFailure, .stalled)
        XCTAssertLessThan(started.duration(to: .now), .seconds(4), "the first buffer's limit applied after a buffer")
        XCTAssertEqual(writer.stops, 1)
    }

    /// A Personal Voice, which speaks aloud rather than into buffers, is
    /// refused before any synthesizer is made; so is a voice not installed.
    func testAPersonalVoiceOrNoVoiceIsRefusedBeforeASynthesizerIsMade() async throws {
        for (personal, found) in [(true, true), (false, false)] {
            let made = Counter()
            let writer = ScriptedBufferWriter(.finish(buffers: 1))
            let synthesizer = SystemSpeechBufferSynthesizer(
                stallLimits: Self.shortLimits,
                makeWriter: {
                    made.add()
                    return writer
                },
                findVoice: { _ in found ? Self.standInVoice() : nil },
                isPersonalVoice: { _ in personal }
            )
            if found {
                try XCTSkipIf(Self.standInVoice() == nil, "No installed voice to stand in for the utterance's voice")
            }

            let error = await failure(of: synthesizer)

            XCTAssertEqual(error as? SpeechWriteFailure, .unusableVoice, "personal \(personal), found \(found)")
            XCTAssertEqual(made.value, 0, "a synthesizer was made for a voice that can't write")
        }
    }

    // MARK: - Running a Write

    /// Short limits, so that a write the test does not end still ends within
    /// seconds.
    private static let shortLimits = SystemSpeechBufferSynthesizer.StallLimits(
        firstBufferFloor: 3,
        firstBufferPerUnit: 0,
        betweenBuffers: 3
    )

    /// An installed voice that is neither a Personal Voice nor a novelty one,
    /// to stand in as the voice an utterance names. It is never spoken with:
    /// the scripted synthesizer ignores it.
    private static func standInVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { voice in
            !voice.voiceTraits.contains(.isPersonalVoice) && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
    }

    /// The Mac's synthesizer over `writer`, with `limits`, the stand-in voice,
    /// and no Personal Voice.
    private func synthesizer(over writer: ScriptedBufferWriter, limits: SystemSpeechBufferSynthesizer.StallLimits) throws -> SystemSpeechBufferSynthesizer {
        try XCTSkipIf(Self.standInVoice() == nil, "No installed voice to stand in for the utterance's voice")
        return SystemSpeechBufferSynthesizer(
            stallLimits: limits,
            makeWriter: { writer },
            findVoice: { _ in Self.standInVoice() },
            isPersonalVoice: { _ in false }
        )
    }

    /// How a write over `writer` ends, run off the main thread as the
    /// renderer runs it.
    private func write(
        with writer: ScriptedBufferWriter,
        limits: SystemSpeechBufferSynthesizer.StallLimits = shortLimits,
        cancellation: BookExportCancellation = BookExportCancellation(),
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void = { _ in }
    ) async throws -> SpeechWriteEnd {
        try await run(synthesizer(over: writer, limits: limits), cancellation: cancellation, onBuffer: onBuffer)
    }

    /// What a write over `writer` throws, or nil when it ends without
    /// throwing.
    private func failure(
        of writer: ScriptedBufferWriter,
        limits: SystemSpeechBufferSynthesizer.StallLimits = shortLimits,
        cancellation: BookExportCancellation = BookExportCancellation(),
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void = { _ in }
    ) async -> Error? {
        do {
            _ = try await run(synthesizer(over: writer, limits: limits), cancellation: cancellation, onBuffer: onBuffer)
            return nil
        } catch {
            return error
        }
    }

    /// What a write with `synthesizer` throws, or nil when it ends without
    /// throwing.
    private func failure(of synthesizer: SystemSpeechBufferSynthesizer) async -> Error? {
        do {
            _ = try await run(synthesizer, cancellation: BookExportCancellation(), onBuffer: { _ in })
            return nil
        } catch {
            return error
        }
    }

    /// Runs one write of a sentence with `synthesizer` on a queue of its own,
    /// off the main thread, and gives how it ended. It waits ten seconds at
    /// the most: past that the test fails, and the write is stopped, so even
    /// a write that would never end ends.
    private func run(
        _ synthesizer: SystemSpeechBufferSynthesizer,
        cancellation: BookExportCancellation,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void
    ) async throws -> SpeechWriteEnd {
        let utterance = SpeechExportUtterance(text: "Nothing is said.", voiceIdentifier: "stand-in", rate: 0.5, pitchMultiplier: 1)
        let outcome = OSAllocatedUnfairLock<Result<SpeechWriteEnd, Error>?>(initialState: nil)
        let ended = expectation(description: "the write ended")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try synthesizer.write(utterance, cancellation: cancellation, onBuffer: onBuffer) }
            outcome.withLock { $0 = result }
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 10)
        cancellation.cancel()
        guard let result = outcome.withLock({ $0 }) else {
            XCTFail("the write did not end within ten seconds")
            throw WriteDidNotEnd()
        }
        return try result.get()
    }

    /// A write that did not end within its test's limit.
    private struct WriteDidNotEnd: Error {}

    /// A buffer of `frames` frames of a quiet tone, mono at 22,050 Hz.
    private static func buffer(frames: Int) throws -> AVAudioPCMBuffer {
        try ScriptedBufferWriter.makeBuffer(frames: frames)
    }
}

// MARK: - Test Doubles

/// A count kept from any thread.
private final class Counter: Sendable {
    /// The count, behind a lock.
    private let count = OSAllocatedUnfairLock(initialState: 0)

    /// The count so far.
    var value: Int {
        count.withLock { $0 }
    }

    /// Adds one.
    func add() {
        count.withLock { $0 += 1 }
    }
}

/// A synthesizer for one write that does what its test scripts, and never
/// speaks: it makes its buffers in memory.
///
/// `@unchecked Sendable`, in this test file only: its mutable state is read
/// and written only under `lock`, and a write's test hands it to the write's
/// queue.
private final class ScriptedBufferWriter: SpeechBufferWriting, @unchecked Sendable {
    /// What the synthesizer does once the write starts it.
    enum Script {
        /// Hands on `buffers` buffers of tone, then the empty last one.
        case finish(buffers: Int)
        /// Cancels the utterance with no buffer, as the speech engine does
        /// with a text it refuses.
        case refuse
        /// Sends nothing, as a voice that has stopped.
        case nothing
        /// Hands on one buffer, then sends nothing.
        case oneThenNothing
    }

    /// Guards every property below.
    private let lock = NSLock()
    /// What it does.
    private let script: Script
    /// Whether it sends one more buffer as it is stopped, as a synthesizer
    /// can.
    private let callsBackAsItStops: Bool
    /// The write's buffer callback, kept so that it can be called late.
    private var onBuffer: ((AVAudioBuffer) -> Void)?
    /// How many times the write stopped it.
    private var stopCount = 0

    /// A synthesizer doing `script`.
    init(_ script: Script, callsBackAsItStops: Bool = false) {
        self.script = script
        self.callsBackAsItStops = callsBackAsItStops
    }

    /// How many times the write stopped it.
    var stops: Int {
        lock.withLock { stopCount }
    }

    /// Whether the write has started it.
    var hasStarted: Bool {
        lock.withLock { onBuffer != nil }
    }

    func start(_ utterance: AVSpeechUtterance, onBuffer: @escaping (AVAudioBuffer) -> Void, onCancel: @escaping @Sendable () -> Void) {
        lock.withLock { self.onBuffer = onBuffer }
        switch script {
        case .finish(let count):
            for _ in 0..<count {
                onBuffer(Self.tone)
            }
            onBuffer(Self.empty)
        case .refuse:
            onCancel()
        case .nothing:
            break
        case .oneThenNothing:
            onBuffer(Self.tone)
        }
    }

    func stop() {
        let callback = lock.withLock { () -> ((AVAudioBuffer) -> Void)? in
            stopCount += 1
            return callsBackAsItStops ? onBuffer : nil
        }
        callback?(Self.tone)
    }

    /// Sends one more buffer to the write, as a synthesizer can after the
    /// write has ended.
    func callBackLate() {
        let callback = lock.withLock { onBuffer }
        callback?(Self.tone)
    }

    /// A buffer of a quiet tone.
    private static var tone: AVAudioBuffer {
        (try? makeBuffer(frames: 441)) ?? AVAudioBuffer()
    }

    /// The empty buffer that ends a write.
    private static var empty: AVAudioBuffer {
        (try? makeBuffer(frames: 0)) ?? AVAudioBuffer()
    }

    /// A buffer of `frames` frames of a quiet tone, mono at 22,050 Hz.
    static func makeBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let samples = buffer.floatChannelData?.pointee else {
            throw CocoaError(.featureUnsupported)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            samples[index] = Float(0.1 * sin(2 * Double.pi * 440 * Double(index) / 22_050))
        }
        return buffer
    }
}
