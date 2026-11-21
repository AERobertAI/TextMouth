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

    /// `frames` frames of a 440 Hz tone at three tenths of full scale, at
    /// `sampleRate`: compressed audio to decode, whose every sample differs
    /// from its neighbours, so a sample missing or out of place shows.
    static func tone(frames: Int, sampleRate: Double) -> [Float] {
        (0..<frames).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url`
    /// as an MP3 at `kilobitsPerSecond`, with the LAME built in, as TextMouth
    /// writes an MP3 book's file: its ID3 tag titled "Canal Survey" and its
    /// gapless records.
    static func writeToneMP3(to url: URL, frames: Int = 24_000, sampleRate: Double = 8_000, kilobitsPerSecond: Int = 32) throws {
        let encoder = try MP3Encoder(
            writingTo: url,
            settings: MP3EncoderSettings(sampleRate: Int(sampleRate), channels: 1, kilobitsPerSecond: kilobitsPerSecond),
            tag: MP3Tag(title: "Canal Survey")
        )
        try tone(frames: frames, sampleRate: sampleRate).withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
        try encoder.finish()
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url`
    /// as AAC in an MPEG-4 audio file, at the bit rate Core Audio chooses.
    static func writeToneAAC(to url: URL, frames: Int = 24_000, sampleRate: Double = 8_000) throws {
        try writeTone(to: url, frames: frames, sampleRate: sampleRate, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC])
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url`
    /// through AVAudioFile, stored as `settings` say beside the rate and
    /// the one channel (Apple Lossless, FLAC, big-endian PCM, ...), in a
    /// file of the type the extension names.
    static func writeTone(to url: URL, frames: Int, sampleRate: Double, settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for (index, sample) in tone(frames: frames, sampleRate: sampleRate).enumerated() {
            channel[index] = sample
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings.merging([AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]) { _, new in new },
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// a WAVE file of 64-bit floating-point samples (format tag 3), the
    /// header written here byte by byte: the depth AVAudioFile and
    /// AVAssetWriter won't write a WAVE file in, and AVAssetReader's
    /// outputs, which take 8, 16, 24, and 32 bits only, refuse to be given.
    static func writeToneFloat64WAVE(to url: URL, frames: Int, sampleRate: Double) throws {
        try writeToneWAVE(to: url, frames: frames, sampleRate: sampleRate, bits: 64, isFloat: true)
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// a WAVE file of `bits`-bit samples, floating-point (format tag 3) or
    /// integer (tag 1), the header and every sample written here byte by byte:
    /// a depth, such as 64 or 48 bits, that no AVFoundation writer makes. A
    /// float of a depth but 32 and 64 (a 16-bit float, which only some Macs
    /// have a Swift type for) holds silence: such a file is meant to be
    /// refused by its header, whose samples are never read.
    static func writeToneWAVE(to url: URL, frames: Int, sampleRate: Double, bits: Int, isFloat: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let samples = toneSamples(frames: frames, sampleRate: sampleRate, bits: bits, isFloat: isFloat)
        let bytesPerFrame = (bits + 7) / 8
        // The "fmt " chunk: 16 bytes, as a float WAVE file of one or two
        // channels needs no more.
        var format = Data()
        format.append(littleEndianBytes(UInt16(isFloat ? 3 : 1)))     // IEEE floating point, or integer PCM
        format.append(littleEndianBytes(UInt16(1)))                   // one channel
        format.append(littleEndianBytes(UInt32(sampleRate)))          // frames a second
        format.append(littleEndianBytes(UInt32(sampleRate) * UInt32(bytesPerFrame))) // bytes a second
        format.append(littleEndianBytes(UInt16(bytesPerFrame)))       // bytes a frame
        format.append(littleEndianBytes(UInt16(bits)))                // bits a sample
        var file = Data("RIFF".utf8)
        file.append(littleEndianBytes(UInt32(4 + 8 + format.count + 8 + samples.count)))
        file.append(Data("WAVEfmt ".utf8))
        file.append(littleEndianBytes(UInt32(format.count)))
        file.append(format)
        file.append(Data("data".utf8))
        file.append(littleEndianBytes(UInt32(samples.count)))
        file.append(samples)
        try file.write(to: url)
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// a CAF file of 64-bit samples, floats or integers (little-endian, a
    /// full-scale integer being 2^63), written byte by byte: AVAudioFile
    /// wrote a file of 64-bit floats as 32-bit floats, and refused one of
    /// 64-bit integers.
    static func writeToneCAF64(to url: URL, frames: Int, sampleRate: Double, isFloat: Bool) throws {
        try writeToneCAF(to: url, frames: frames, sampleRate: sampleRate, bits: 64, isFloat: isFloat)
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// a CAF file of `bits`-bit samples, floats or integers (little-endian, a
    /// full-scale integer being 2^(bits-1)), written byte by byte. As for
    /// `writeToneWAVE(to:frames:sampleRate:bits:isFloat:)`, a float of a
    /// depth but 32 and 64 holds silence.
    static func writeToneCAF(to url: URL, frames: Int, sampleRate: Double, bits: Int, isFloat: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let samples = toneSamples(frames: frames, sampleRate: sampleRate, bits: bits, isFloat: isFloat)
        let bytesPerFrame = (bits + 7) / 8
        // The "desc" chunk: the stream description, big-endian as every
        // CAF field is, flagged little-endian (2) and float (1) or neither.
        var description = Data()
        description.append(bigEndianBytes(sampleRate.bitPattern))
        description.append(Data("lpcm".utf8))
        description.append(bigEndianBytes(UInt32(isFloat ? 3 : 2)))
        description.append(bigEndianBytes(UInt32(bytesPerFrame)))     // bytes a packet
        description.append(bigEndianBytes(UInt32(1)))                 // frames a packet
        description.append(bigEndianBytes(UInt32(1)))                 // one channel
        description.append(bigEndianBytes(UInt32(bits)))              // bits a sample
        var file = Data("caff".utf8)
        file.append(bigEndianBytes(UInt16(1)))                        // version
        file.append(bigEndianBytes(UInt16(0)))                        // flags
        file.append(Data("desc".utf8))
        file.append(bigEndianBytes(Int64(description.count)))
        file.append(description)
        file.append(Data("data".utf8))
        file.append(bigEndianBytes(Int64(4 + samples.count)))         // the edit count and the samples
        file.append(bigEndianBytes(UInt32(0)))
        file.append(samples)
        try file.write(to: url)
    }

    /// The samples of `tone(frames:sampleRate:)` as `bits`-bit little-endian
    /// numbers, one after another: 32 and 64-bit floats as they are, any other
    /// float as silence, and integers scaled so that full scale is
    /// 2^(bits-1), in as many bytes as the depth needs.
    private static func toneSamples(frames: Int, sampleRate: Double, bits: Int, isFloat: Bool) -> Data {
        let bytesPerSample = (bits + 7) / 8
        var samples = Data()
        for sample in tone(frames: frames, sampleRate: sampleRate) {
            if isFloat {
                switch bits {
                case 32: samples.append(littleEndianBytes(sample.bitPattern))
                case 64: samples.append(littleEndianBytes(Double(sample).bitPattern))
                default: samples.append(Data(count: bytesPerSample))
                }
            } else {
                // The low bytes of the two's-complement integer are its samples' bytes, least significant first.
                let scaled = Int64(Double(sample) * pow(2, Double(bits - 1)))
                samples.append(littleEndianBytes(scaled).prefix(bytesPerSample))
            }
        }
        return samples
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// an AIFF-C file of 64-bit floating-point samples (compression type
    /// "fl64"), written byte by byte: the only way a 64-bit float AIFF file
    /// comes about. `sampleRate` must be a whole number of hertz.
    static func writeToneFloat64AIFC(to url: URL, frames: Int, sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var samples = Data()
        for sample in tone(frames: frames, sampleRate: sampleRate) {
            samples.append(bigEndianBytes(Double(sample).bitPattern))
        }
        // The sample rate as AIFF holds it, an 80-bit extended float: a
        // 15-bit exponent biased by 16,383, and a mantissa whose top bit is 1.
        let rate = UInt64(sampleRate)
        let exponent = 63 - rate.leadingZeroBitCount
        var extended = bigEndianBytes(UInt16(16_383 + exponent))
        extended.append(bigEndianBytes(rate << UInt64(63 - exponent)))
        let name = "64-bit floating point"
        var common = Data()
        common.append(bigEndianBytes(Int16(1)))                       // one channel
        common.append(bigEndianBytes(UInt32(frames)))
        common.append(bigEndianBytes(Int16(64)))                      // bits a sample
        common.append(extended)
        common.append(Data("fl64".utf8))
        common.append(UInt8(name.utf8.count))                         // a Pascal string, 22 bytes in all
        common.append(Data(name.utf8))
        var version = Data()
        version.append(bigEndianBytes(UInt32(0xA280_5140)))           // AIFF-C version 1
        var sound = Data()
        sound.append(bigEndianBytes(UInt32(0)))                       // offset
        sound.append(bigEndianBytes(UInt32(0)))                       // block size
        sound.append(samples)
        var chunks = Data("AIFC".utf8)
        for (id, body) in [("FVER", version), ("COMM", common), ("SSND", sound)] {
            chunks.append(Data(id.utf8))
            chunks.append(bigEndianBytes(UInt32(body.count)))
            chunks.append(body)
        }
        var file = Data("FORM".utf8)
        file.append(bigEndianBytes(UInt32(chunks.count)))
        file.append(chunks)
        try file.write(to: url)
    }

    /// The bytes of `value`, least significant first, as WAVE headers and
    /// samples store integers.
    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// The bytes of `value`, most significant first, as CAF and AIFF files
    /// store their integers.
    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Writes `frames` frames of `tone(frames:sampleRate:)`, mono, to `url` as
    /// Apple Lossless of a 24-bit source (flag 3 after `alac/`, as the import
    /// makes such files), by `afconvert` in a child process from a 24-bit CAF
    /// tone made beside it: AVAudioFile's own Apple Lossless takes only a
    /// hint of the depth. The Mac's own tool, so no sound is made.
    static func writeToneAppleLossless24(to url: URL, frames: Int, sampleRate: Double) throws {
        let source = url.deletingLastPathComponent().appendingPathComponent(".alac-source.caf")
        try writeTone(to: source, frames: frames, sampleRate: sampleRate, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "alac/3", source.path, url.path]
        try process.run()
        process.waitUntilExit()
        // A file that is not there fails the test that asked for it.
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
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

    /// One stretch of a test signal: `seconds` long, a sine of `frequency`
    /// hertz at peak `amplitude`, or, at frequency 0, a steady level of
    /// `amplitude` (0 for silence).
    struct Tone {
        let seconds: Double
        let frequency: Double
        let amplitude: Float

        /// Silence lasting `seconds`.
        static func silence(_ seconds: Double) -> Tone {
            Tone(seconds: seconds, frequency: 0, amplitude: 0)
        }
    }

    /// Writes `tones`, one after another, to `url` as 32-bit float linear
    /// PCM, mono, at `sampleRate`: a signal whose levels and frequencies a
    /// filter's effect can be measured on.
    static func writeTones(_ tones: [Tone], to url: URL, sampleRate: Double = 8_000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for tone in tones {
            let frames = Int((tone.seconds * sampleRate).rounded())
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))))
            buffer.frameLength = AVAudioFrameCount(frames)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<frames {
                samples[index] = tone.frequency == 0
                    ? tone.amplitude
                    : tone.amplitude * Float(sin(2 * Double.pi * tone.frequency * Double(index) / sampleRate))
            }
            try file.write(from: buffer)
        }
    }

    /// The largest magnitude among `samples`.
    static func peak<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// The root mean square of `samples`.
    static func rms<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    /// Every sample of the first channel of the audio file at `url`, as
    /// 32-bit floats: for the short files of these tests only. Read a piece
    /// at a time to the end, since one read of AVAudioFile can return fewer
    /// frames than asked (it returned 15,360 of 16,000 from a float WAVE file).
    static func floatSamples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Every sample of the first channel of the audio file at `url`, as
    /// 16-bit integers, read a piece at a time to the end.
    static func int16Samples(of url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channel = try XCTUnwrap(buffer.int16ChannelData)[0]
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

extension Array {
    /// The element at `index`, or nil when there is none, so a test reading
    /// a sample its audio turned out not to have fails instead of stopping
    /// the test host.
    subscript(checked index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
