import AVFoundation
import XCTest
@testable import TextMouth

/// Audio files for the audio editor's tests (FR04), kept with the other
/// fixture writers (`AudioTestFixtures`), so each kind of fixture has one
/// writer.
///
/// The editor must place every sample exactly, so these files say where
/// each of their samples came from, the research prototype's method: in an
/// identity ramp, sample n of a book's audio holds (n + 1) / 2^24 and sample
/// n of a take holds -(n + 1) / 2^24. A 32-bit float holds those values
/// exactly, so reading an edited result back as floats names the source
/// and the frame of every sample, and silence reads as 0, which no ramp
/// sample is.
extension AudioTestFixtures {
    /// The scale of an identity ramp: one step per frame.
    static let rampStep = 1.0 / 16_777_216.0

    /// Which source an identity ramp stands for.
    enum RampSource: Equatable {
        /// The book's own audio: positive samples.
        case book
        /// A punch-in's take: negative samples.
        case take
    }

    /// What a sample of an edited identity ramp turns out to be.
    enum RampSample: Equatable, CustomStringConvertible {
        /// Frame `frame` of `source`.
        case frame(RampSource, Int)
        /// Silence.
        case silence

        var description: String {
            switch self {
            case .frame(let source, let frame): return "\(source)[\(frame)]"
            case .silence: return "silence"
            }
        }
    }

    /// Writes `frames` frames of an identity ramp for `source` to `url` as
    /// 32-bit float linear PCM, mono, at `sampleRate`; the file type follows
    /// the extension (".caf", ".wav").
    static func writeIdentityRamp(
        to url: URL,
        frames: Int,
        sampleRate: Double = 8_000,
        source: RampSource = .book
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sign: Float = source == .book ? 1 : -1
        let chunk = 65_536
        var written = 0
        while written < frames {
            let count = min(chunk, frames - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<count {
                samples[index] = sign * Float(Double(written + index + 1) * rampStep)
            }
            try file.write(from: buffer)
            written += count
        }
    }

    /// What `sample`, read from an edited identity ramp, is.
    static func rampSample(_ sample: Float) -> RampSample {
        if sample == 0 { return .silence }
        let frame = Int((Double(abs(sample)) / rampStep).rounded()) - 1
        return .frame(sample > 0 ? .book : .take, frame)
    }

    /// Writes `frames` frames of 16-bit integer PCM, mono, at `sampleRate`,
    /// to `url`, each sample a different value from its neighbours
    /// (frame n holds n × 31 + 7, wrapping), so a lossless copy can be told
    /// from a lossy one sample by sample.
    static func writeInt16Pattern(to url: URL, frames: Int, sampleRate: Double = 8_000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
        for index in 0..<frames {
            samples[index] = Int16(truncatingIfNeeded: index &* 31 &+ 7)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }

    /// Every sample of the first channel of the audio file at `url`, as
    /// 32-bit floats, read whole: for the short files of these tests only.
    static func floatSamples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    /// Every sample of the first channel of the audio file at `url`, as
    /// 16-bit integers, read whole.
    static func int16Samples(of url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}
