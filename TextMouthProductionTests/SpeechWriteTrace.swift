import AVFoundation
import Foundation
import os
@testable import TextMouth

// MARK: - A Recorded Write

/// What one write of `AVSpeechSynthesizer.write(_:toBufferCallback:)` did, as a
/// description and not as audio: the buffers' frame counts, the empty buffers
/// that end its segments, the word ranges it announced, and how it ended.
/// A scripted writer (`ScriptedTraceWriter`) replays it through the callbacks
/// the real synthesizer uses, so that a test of any path that writes speech
/// (the engine's render, the speech export, the voice warm-up) meets what a
/// real macOS does without a voice, a sound, or the operating system.
///
/// It exists because of B31: on macOS 27 a write sends an empty buffer after
/// each of its segments (about a sentence), and `didFinish` after the last,
/// while macOS 26 sends one empty buffer at the end. Every test of the
/// render's end had scripted the macOS 26 behavior by hand, so the suite stayed
/// green while the app skipped chapters. The traces below are the probe of
/// November 28, 2026 (research/SPEECH-TESTS-PLAN-2026-11-28.md), shrunk to
/// numbers: Samantha at the render's rate on macOS 27.2.1.
struct SpeechWriteTrace: Codable, Equatable, Sendable {
    /// One thing the synthesizer did, in the order it did it.
    enum Event: Codable, Equatable, Sendable {
        /// A buffer holding `frames` frames of audio.
        case audio(frames: Int)
        /// A buffer holding no frames: the end of one segment of the write,
        /// on macOS 27, and the end of the whole write, on macOS 26.
        case emptyBuffer
        /// The delegate's `willSpeakRangeOfSpeechString`, a word about to be
        /// spoken, as a range of UTF-16 units of the text.
        case word(location: Int, length: Int)
        /// The delegate's `didFinish`: the last buffer has been delivered.
        case didFinish
        /// The delegate's `didCancel`: the speech engine refused the text,
        /// or the write was stopped where a stop is honored.
        case didCancel
    }

    /// What the trace records, for a failure's message.
    var name: String
    /// The operating system it was recorded on, such as "macOS 27.2.1".
    var system: String
    /// The audio's frames a second.
    var sampleRate: Double
    /// The length of the text written, in UTF-16 units.
    var textLength: Int
    /// Whether `stopSpeaking(at:)` stops the write. On macOS 27 it does not:
    /// it returned false and the buffers went on to the utterance's end, with
    /// `didFinish`, not `didCancel` (probed November 28, 2026).
    var stopIsHonored: Bool
    /// Everything the synthesizer did, in order.
    var events: [Event]

    // MARK: Reading a Trace

    /// The frames of audio the write delivers in all.
    var audioFrames: Int {
        events.reduce(0) { total, event in
            if case .audio(let frames) = event { return total + frames }
            return total
        }
    }

    /// How many empty buffers the write sends.
    var emptyBufferCount: Int {
        events.filter { $0 == .emptyBuffer }.count
    }

    /// The word ranges the write announces, in order.
    var wordRanges: [NSRange] {
        events.compactMap { event in
            if case .word(let location, let length) = event { return NSRange(location: location, length: length) }
            return nil
        }
    }

    /// How many times the write says it finished.
    var finishCount: Int { events.filter { $0 == .didFinish }.count }

    /// How many times the write says it cancelled.
    var cancelCount: Int { events.filter { $0 == .didCancel }.count }

    /// The events cut into the runs the synthesizer delivers together: each
    /// ends with an empty buffer, with the finish or cancel that follows the
    /// last one kept in its run, since the synthesizer sends them together.
    /// A trace that ends with no empty buffer ends its last run at its end.
    var segments: [[Event]] {
        var runs: [[Event]] = []
        var current: [Event] = []
        for (index, event) in events.enumerated() {
            current.append(event)
            let next = events.indices.contains(index + 1) ? events[index + 1] : nil
            let nextEndsTheWrite = next == .didFinish || next == .didCancel
            if event == .emptyBuffer && !nextEndsTheWrite {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: Making a Trace

    /// The most frames in one buffer of a generated trace: a synthesizer
    /// delivers its audio in buffers of a few hundred to a few thousand frames.
    static let bufferFrames = 4_096

    /// The frames a second of the render's rate, 0.7, in Samantha, which the
    /// probe measured: 22,050.
    static let sampleRate = 22_050.0

    /// A trace of a write cut into `segmentEnds.count` segments, the way
    /// macOS 27's synthesizer cuts a text: segment `i` speaks the text up to
    /// `segmentEnds[i]` UTF-16 units, announces its words, delivers
    /// `framesPerUnit` frames of audio for each unit, and ends with an empty
    /// buffer; after the last comes `didFinish`.
    ///
    /// - Parameters:
    ///   - segmentEnds: Where each segment ends in the text, rising; the last
    ///     is the text's length.
    ///   - framesPerUnit: Frames of audio for each unit of the text.
    ///   - stopIsHonored: Whether a stop ends the write.
    static func segmented(
        name: String,
        system: String,
        segmentEnds: [Int],
        framesPerUnit: Int,
        stopIsHonored: Bool
    ) -> SpeechWriteTrace {
        var events: [Event] = []
        var start = 0
        for end in segmentEnds {
            // Words of five units and a space, as far as the segment goes.
            var location = start
            while location < end {
                // The last word of a segment runs to its end, so the final
                // range ends at the text's end, as the probe found.
                events.append(.word(location: location, length: location + 6 >= end ? end - location : 5))
                location += 6
            }
            // The segment's audio in buffers, the last one the remainder.
            var remaining = (end - start) * framesPerUnit
            while remaining > 0 {
                let frames = min(remaining, bufferFrames)
                events.append(.audio(frames: frames))
                remaining -= frames
            }
            events.append(.emptyBuffer)
            start = end
        }
        events.append(.didFinish)
        return SpeechWriteTrace(
            name: name,
            system: system,
            sampleRate: sampleRate,
            textLength: segmentEnds.last ?? 0,
            stopIsHonored: stopIsHonored,
            events: events
        )
    }

    /// The write of "Ready.", one word, which the probe found to give one
    /// empty buffer and then `didFinish` in every voice, on both systems.
    static func oneWord(system: String) -> SpeechWriteTrace {
        segmented(name: "one word", system: system, segmentEnds: [6], framesPerUnit: 1_000, stopIsHonored: system == "macOS 26")
    }

    /// Five sentences, 350 units, on macOS 27: two segments, the first ending
    /// after three sentences at 57% of the audio (4.87 s of Samantha's 8.53 s).
    static let fiveSentencesOnMacOS27 = segmented(
        name: "five sentences",
        system: "macOS 27.2.1",
        segmentEnds: [200, 350],
        framesPerUnit: 537,
        stopIsHonored: false
    )

    /// Forty sentences, 2,807 units, on macOS 27: 14 segments, each ending at a
    /// sentence's end, at the offsets the probe measured; 68.3 s of audio.
    static let fortySentencesOnMacOS27 = segmented(
        name: "forty sentences",
        system: "macOS 27.2.1",
        segmentEnds: [199, 422, 627, 837, 1_052, 1_252, 1_475, 1_680, 1_890, 2_105, 2_305, 2_528, 2_733, 2_807],
        framesPerUnit: 536,
        stopIsHonored: false
    )

    /// The same five sentences as macOS 26 wrote them: all the audio, then
    /// one empty buffer, then `didFinish`; and a stop that stops the write.
    static let fiveSentencesOnMacOS26 = segmented(
        name: "five sentences",
        system: "macOS 26",
        segmentEnds: [350],
        framesPerUnit: 537,
        stopIsHonored: true
    )

    /// A write the speech engine refuses: no buffer, only `didCancel`, as the
    /// probe of a text with a tag in it found (SpeechMarkupGuard).
    static let refused = SpeechWriteTrace(
        name: "refused",
        system: "macOS 27.2.1",
        sampleRate: sampleRate,
        textLength: 350,
        stopIsHonored: false,
        events: [.didCancel]
    )

    /// Every trace of a whole text, for a test to go through each.
    static let allWholeTexts = [fiveSentencesOnMacOS27, fortySentencesOnMacOS27, fiveSentencesOnMacOS26]

    /// A text of exactly `textLength` units, plain letters and spaces, so that
    /// the markup guard leaves it as it is and a render's frame map is the
    /// trace's.
    var text: String {
        let sentence = "Tide tables for the outer harbour. "
        let repeated = String(repeating: sentence, count: textLength / sentence.count + 1)
        return String(repeated.prefix(textLength))
    }
}

// MARK: - The Scripted Writer

/// A `SpeechBufferWriting` that replays a `SpeechWriteTrace`, never speaking:
/// its buffers are tone made in memory, and nothing is synthesized.
///
/// It delivers as the Mac's synthesizer does:
/// - every buffer and callback on the **main thread**, although the write is
///   asked for off it;
/// - a segment at a time, with a pause (`segmentGap`) between segments, so
///   that a path that takes the first empty buffer for the end is seen to
///   leave while the rest is still to come (a single block of events would
///   let it leave and still receive them, and hide the bug);
/// - the empty buffers and `didFinish` of the trace;
/// - a **stop** that ends the write only if the trace's system honors it
///   (`SpeechWriteTrace.stopIsHonored`): the remaining segments are dropped
///   and `didCancel` follows. On macOS 27 a stop is counted and ignored.
///
/// `@unchecked Sendable`, in this test file only: every variable is read and
/// written only under `lock`, and the replay runs on the main queue.
final class ScriptedTraceWriter: SpeechBufferWriting, @unchecked Sendable {
    /// Guards every variable below.
    private let lock = NSLock()
    /// What it replays.
    let trace: SpeechWriteTrace
    /// The trace's segments, cut once.
    private let segments: [[SpeechWriteTrace.Event]]
    /// The pause between one segment and the next, in seconds.
    private let segmentGap: TimeInterval
    /// The segment the replay waits before until `release()`, or nil.
    private let holdBeforeSegment: Int?
    /// Hears each word range, on the main thread.
    private let onWord: (@Sendable (NSRange) -> Void)?

    /// The write's callbacks, kept from `start`.
    private var onBuffer: ((AVAudioBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onCancel: (@Sendable () -> Void)?
    /// How many times the write was stopped.
    private var stopCount = 0
    /// Whether a stop that is honored has come.
    private var stopped = false
    /// How many segments have been delivered.
    private var deliveredSegments = 0
    /// The frames of audio delivered so far.
    private var deliveredFrames = 0
    /// Whether every delivery so far came on the main thread.
    private var allOnMainThread = true
    /// Whether the replay is waiting for `release()`.
    private var isHeld = false
    /// Whether the replay has delivered everything it will.
    private var isDone = false
    /// How many word ranges were announced.
    private var wordCount = 0

    /// A writer replaying `trace`.
    ///
    /// - Parameters:
    ///   - segmentGap: Seconds between segments.
    ///   - holdBeforeSegment: Holds the replay before this segment, counted
    ///     from 0, until `release()`: a test's way to act mid-write.
    ///   - onWord: Called with each word range as it is announced.
    init(
        _ trace: SpeechWriteTrace,
        segmentGap: TimeInterval = 0.03,
        holdBeforeSegment: Int? = nil,
        onWord: (@Sendable (NSRange) -> Void)? = nil
    ) {
        self.trace = trace
        segments = trace.segments
        self.segmentGap = segmentGap
        self.holdBeforeSegment = holdBeforeSegment
        self.onWord = onWord
    }

    // MARK: Observing

    /// How many times the write stopped it.
    var stops: Int { lock.withLock { stopCount } }
    /// How many segments it has delivered.
    var segmentsDelivered: Int { lock.withLock { deliveredSegments } }
    /// The frames of audio it has delivered.
    var framesDelivered: Int { lock.withLock { deliveredFrames } }
    /// Whether every buffer and callback came on the main thread.
    var deliveredOnTheMainThread: Bool { lock.withLock { allOnMainThread } }
    /// Whether it is waiting for `release()`.
    var isWaitingForRelease: Bool { lock.withLock { isHeld } }
    /// Whether it has delivered everything it will.
    var isFinished: Bool { lock.withLock { isDone } }
    /// How many word ranges it has announced.
    var wordsAnnounced: Int { lock.withLock { wordCount } }

    // MARK: SpeechBufferWriting

    func start(
        _ utterance: AVSpeechUtterance,
        onBuffer: @escaping (AVAudioBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            self.onBuffer = onBuffer
            self.onFinish = onFinish
            self.onCancel = onCancel
        }
        // The first segment comes after `start` returns, as the real
        // synthesizer's first buffer does.
        DispatchQueue.main.async { self.deliverSegment(0) }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            if trace.stopIsHonored { stopped = true }
        }
    }

    /// Lets a replay held before a segment go on.
    func release() {
        let next: Int? = lock.withLock {
            guard isHeld else { return nil }
            isHeld = false
            return deliveredSegments
        }
        if let next { DispatchQueue.main.async { self.deliverSegment(next) } }
    }

    // MARK: Replaying

    /// On the main queue: deliver segment `index`, then arrange the next.
    private func deliverSegment(_ index: Int) {
        // A stop that is honored ends the write with a cancel, once.
        if lock.withLock({ stopped }) {
            endWithCancel()
            return
        }
        guard index < segments.count else {
            lock.withLock { isDone = true }
            return
        }
        for event in segments[index] {
            deliver(event)
        }
        lock.withLock { deliveredSegments = index + 1 }
        guard index + 1 < segments.count else {
            lock.withLock { isDone = true }
            return
        }
        let next = index + 1
        if holdBeforeSegment == next {
            lock.withLock { isHeld = true }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + segmentGap) { self.deliverSegment(next) }
    }

    /// On the main queue: the end of a write a stop ended.
    private func endWithCancel() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            isDone = true
            return onCancel
        }
        callback?()
    }

    /// On the main queue: hand on one event through the callbacks.
    private func deliver(_ event: SpeechWriteTrace.Event) {
        let callbacks = lock.withLock { () -> (((AVAudioBuffer) -> Void)?, (@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            if pthread_main_np() == 0 { allOnMainThread = false }
            return (onBuffer, onFinish, onCancel)
        }
        switch event {
        case .audio(let frames):
            if let buffer = try? Self.makeBuffer(frames: frames, sampleRate: trace.sampleRate) {
                lock.withLock { deliveredFrames += frames }
                callbacks.0?(buffer)
            }
        case .emptyBuffer:
            if let buffer = try? Self.makeBuffer(frames: 0, sampleRate: trace.sampleRate) {
                callbacks.0?(buffer)
            }
        case .word(let location, let length):
            lock.withLock { wordCount += 1 }
            onWord?(NSRange(location: location, length: length))
        case .didFinish:
            callbacks.1?()
        case .didCancel:
            callbacks.2?()
        }
    }

    /// A buffer of `frames` frames of a quiet tone, mono at `sampleRate`.
    static func makeBuffer(frames: Int, sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let samples = buffer.floatChannelData?.pointee else {
            throw CocoaError(.featureUnsupported)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            samples[index] = Float(0.1 * sin(2 * Double.pi * 440 * Double(index) / sampleRate))
        }
        return buffer
    }
}
