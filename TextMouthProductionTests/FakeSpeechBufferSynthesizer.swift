import AVFoundation
import os
@testable import TextMouth

/// A speech synthesizer for the speech export's tests (FMT43) that never
/// runs a real synthesizer and never makes a sound.
///
/// Each write records its utterance, then hands `onBuffer` a quiet 440 Hz
/// tone made in memory, `framesPerUnit` frames for every UTF-16 unit of the
/// utterance's text, mono, in buffers of `pieceFrameCount` frames, on the
/// calling thread, and returns `.finished`; or, for an utterance it
/// `refuses`, hands over nothing and returns `.refused`, as the speech
/// engine does with a text it will not speak.
///
/// Sendable without `@unchecked`: its configuration is constants of Sendable
/// types, and its record of utterances is kept in a lock.
final class FakeSpeechBufferSynthesizer: SpeechBufferSynthesizing {
    /// Why the fake could not make its tone.
    enum Failure: Error, Equatable {
        /// No buffer could be made of the requested kind and sample rate:
        /// the fake makes 32-bit float and 16-bit integer samples only, at
        /// a positive rate.
        case cannotMakeBuffer
    }

    /// The tone's frequency, in hertz.
    private static let toneFrequency = 440.0
    /// The tone's amplitude, a tenth of full scale: quiet, should anyone
    /// ever play a file a test made.
    private static let toneAmplitude = 0.1

    /// Frames of tone for each UTF-16 unit of an utterance's text.
    private let framesPerUnit: Int
    /// Frames in each buffer of a write but its last, which holds the rest.
    private let pieceFrameCount: Int
    /// The kind of samples every buffer holds.
    private let commonFormat: AVAudioCommonFormat
    /// The sample rate of an utterance's buffers.
    private let sampleRate: @Sendable (SpeechExportUtterance) -> Double
    /// Whether the speech engine refuses an utterance.
    private let refuses: @Sendable (SpeechExportUtterance) -> Bool
    /// Called as each write begins, once its utterance is recorded: where a
    /// test can press Stop at a chosen utterance, say.
    private let beforeWrite: @Sendable (SpeechExportUtterance) -> Void
    /// Every utterance handed to `write`, in order.
    private let record = OSAllocatedUnfairLock<[SpeechExportUtterance]>(initialState: [])

    /// - Parameters:
    ///   - framesPerUnit: Frames of tone for each UTF-16 unit of an
    ///     utterance's text; 0 for a voice that makes no sound.
    ///   - pieceFrameCount: Frames in each buffer but the last; at least 1.
    ///   - commonFormat: The kind of samples: `.pcmFormatFloat32`, as most
    ///     voices write, or `.pcmFormatInt16`.
    ///   - sampleRate: The sample rate of an utterance's buffers.
    ///   - refuses: Whether the speech engine refuses an utterance.
    ///   - beforeWrite: Called as each write begins.
    init(
        framesPerUnit: Int = 40,
        pieceFrameCount: Int = 2_205,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        sampleRate: @escaping @Sendable (SpeechExportUtterance) -> Double = { _ in 22_050 },
        refuses: @escaping @Sendable (SpeechExportUtterance) -> Bool = { _ in false },
        beforeWrite: @escaping @Sendable (SpeechExportUtterance) -> Void = { _ in }
    ) {
        self.framesPerUnit = framesPerUnit
        // A buffer of no frames would never move the write on.
        self.pieceFrameCount = max(1, pieceFrameCount)
        self.commonFormat = commonFormat
        self.sampleRate = sampleRate
        self.refuses = refuses
        self.beforeWrite = beforeWrite
    }

    /// Every utterance handed to `write` so far, in order, refused ones
    /// included.
    var written: [SpeechExportUtterance] {
        record.withLock { $0 }
    }

    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd {
        record.withLock { $0.append(utterance) }
        beforeWrite(utterance)
        if refuses(utterance) {
            return .refused
        }
        try cancellation.checkCancelled()

        let rate = sampleRate(utterance)
        guard rate > 0,
              let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: rate, channels: 1, interleaved: false) else {
            throw Failure.cannotMakeBuffer
        }
        let frameCount = utterance.text.utf16.count * framesPerUnit
        var made = 0
        while made < frameCount {
            // Stop is noticed before every buffer, as a real write notices
            // it between buffers.
            try cancellation.checkCancelled()
            let count = min(pieceFrameCount, frameCount - made)
            try onBuffer(Self.tone(frames: made..<(made + count), format: format))
            made += count
        }
        return .finished
    }

    /// A buffer of `format` holding the tone's frames `frames`, counted from
    /// the first frame of the write, so the tone runs on unbroken from one
    /// buffer to the next.
    private static func tone(frames: Range<Int>, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)) else {
            throw Failure.cannotMakeBuffer
        }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        let rate = format.sampleRate
        if let samples = buffer.floatChannelData?.pointee {
            for (index, frame) in frames.enumerated() {
                samples[index] = Float(toneSample(at: frame, rate: rate))
            }
        } else if let samples = buffer.int16ChannelData?.pointee {
            for (index, frame) in frames.enumerated() {
                samples[index] = Int16((toneSample(at: frame, rate: rate) * Double(Int16.max)).rounded())
            }
        } else {
            throw Failure.cannotMakeBuffer
        }
        return buffer
    }

    /// The tone's value at `frame` of a write at `rate` frames a second,
    /// from -0.1 to 0.1 of full scale.
    private static func toneSample(at frame: Int, rate: Double) -> Double {
        toneAmplitude * sin(2 * Double.pi * toneFrequency * Double(frame) / rate)
    }
}
