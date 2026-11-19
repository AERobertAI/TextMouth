import Foundation

// TextMouth's own reader of Monkey's Audio files: the file as a whole. It
// follows the Monkey's Audio SDK 13.47 (APEHeader.cpp, APEInfo.cpp,
// APEDecompress.cpp, APEDecompressCore.cpp, Prepare.cpp, FloatTransform.cpp),
// Copyright 2000-2026 Matthew T. Ashland, under its BSD 3-clause licence
// (see MonkeysAudioRangeDecoder.swift).

/// The words a listener hears about a Monkey's Audio file the reader refuses.
extension OwnAudioWording {
    /// A file written before version 3.99 (April 2004), whose residuals are
    /// coded another way.
    static let monkeysAudioOld = "it was made by a Monkey's Audio older than version 3.99, from before 2004" // l10n: no (a parser's damage reason: finishes "because …", question 3)
    /// A file whose channels, bit depth, sample rate, or compression level
    /// no encoder writes, or whose frames are too large to hold in memory.
    static let monkeysAudioShape = "its channels, bit depth, sample rate, or compression level are outside what TextMouth reads" // l10n: no (a parser's damage reason: finishes "because …", question 3)
}

/// TextMouth's own Monkey's Audio decoder, for files of version 3.99 and
/// later (every file written since April 2004): all five compression
/// levels, 8, 16, 24, and 32 bits, 32-bit floats, and one to 32 channels.
/// Older files are refused: they code their residuals another way, and no
/// encoder at hand writes one to prove a reader with.
///
/// A file is frames of up to a few seconds, each decoded alone and checked
/// against its own CRC before any of it is handed over.
struct MonkeysAudioDecoder: OwnAudioDecoder {
    /// The four bytes a file starts with; a file of floats ends them in "F".
    static let signature = "MAC "
    static let floatSignature = "MACF"
    /// The oldest version read, times 1,000.
    static let oldestVersion = 3_990
    /// The most channels the format allows.
    static let maximumChannels = 32
    /// The highest sample rate read, in hertz.
    static let maximumSampleRate = 10_000_000
    /// The most samples (frames times channels) one frame may hold: more
    /// than the largest any encoder writes at eight channels, and little
    /// enough to keep a crafted header from asking for gigabytes.
    static let maximumSamplesPerFrame = 24_000_000

    /// The most frames of audio one frame of the file may hold at the
    /// compression level `level`, as the SDK itself refuses more: a million,
    /// and ten million at Insane, whose frames are the longest. A silent
    /// frame takes no bytes, so without this a file of a few thousand bytes
    /// could declare a year of audio for the import to write out.
    static func mostFramesPerFrame(forLevel level: Int) -> Int {
        level >= 5_000 ? 10_000_000 : 1_000_000
    }
    /// The descriptor's and the header's least lengths in bytes.
    private static let descriptorLength = 52
    private static let headerLength = 24

    /// The bits of the header's format flags that change what is decoded.
    private static let floatFlag = 1 << 12

    /// The bits of a frame's special codes.
    private static let leftSilence: UInt32 = 1
    private static let rightSilence: UInt32 = 2
    private static let pseudoStereo: UInt32 = 4

    let stream: OwnAudioStream

    /// The file, and whether every frame's CRC is verified (the fuzzers
    /// turn that off).
    private let bytes: OwnAudioBytes
    private let verifiesChecksums: Bool
    /// The compression level (1,000 to 5,000).
    private let level: Int
    /// The frames in a full frame, and in the last one.
    private let framesPerBlock: Int
    private let finalFrames: Int
    /// Where each frame starts in the file.
    private let seekTable: [Int]
    /// One predictor and one residual state a channel.
    private var predictors: [MonkeysAudioPredictor]
    private var states: [MonkeysAudioResidualState]
    /// Whether a frame has failed its CRC as decoded the usual way and
    /// passed in the interim way, which the rest of the file then uses.
    private var isInterim = false
    /// The next frame to decode.
    private var nextFrame = 0

    /// Opens `bytes` as a Monkey's Audio file, reading its descriptor,
    /// header, and seek table. An ID3v2 tag ahead of the descriptor is
    /// passed over.
    /// - Throws: `OwnAudioError`.
    init(_ bytes: OwnAudioBytes, verifiesChecksums: Bool = true) throws {
        let start = OwnAudioLeadingTag.id3v2Length(in: bytes.readUpTo(at: 0, count: 10))
        let descriptor = bytes.readUpTo(at: start, count: Self.descriptorLength)
        guard OwnAudioLittleEndian.holds(descriptor, Self.signature, at: 0)
            || OwnAudioLittleEndian.holds(descriptor, Self.floatSignature, at: 0),
            let version = OwnAudioLittleEndian.uint16(descriptor, 4) else { throw OwnAudioError.notThisFormat }
        guard Int(version) >= Self.oldestVersion else {
            throw OwnAudioError.unsupported(reason: OwnAudioWording.monkeysAudioOld)
        }
        guard descriptor.count == Self.descriptorLength,
              let descriptorBytes = OwnAudioLittleEndian.uint32(descriptor, 8),
              let headerBytes = OwnAudioLittleEndian.uint32(descriptor, 12),
              let seekTableBytes = OwnAudioLittleEndian.uint32(descriptor, 16),
              Int(descriptorBytes) >= Self.descriptorLength, Int(headerBytes) >= Self.headerLength else {
            throw OwnAudioError.damaged
        }
        let headerStart = start + Int(descriptorBytes)
        let header = try bytes.read(at: headerStart, count: Self.headerLength)
        guard let level = OwnAudioLittleEndian.uint16(header, 0),
              let flags = OwnAudioLittleEndian.uint16(header, 2),
              let framesPerBlock = OwnAudioLittleEndian.uint32(header, 4),
              let finalFrames = OwnAudioLittleEndian.uint32(header, 8),
              let totalBlocks = OwnAudioLittleEndian.uint32(header, 12),
              let bits = OwnAudioLittleEndian.uint16(header, 16),
              let channels = OwnAudioLittleEndian.uint16(header, 18),
              let rate = OwnAudioLittleEndian.uint32(header, 20) else { throw OwnAudioError.damaged }

        let isFloat = Int(flags) & Self.floatFlag != 0
        guard (1...Self.maximumChannels).contains(Int(channels)), [8, 16, 24, 32].contains(Int(bits)),
              (1...Self.maximumSampleRate).contains(Int(rate)), !isFloat || bits == 32,
              MonkeysAudioPredictor.filterShapes(forLevel: Int(level)) != nil,
              Int(framesPerBlock) <= Self.mostFramesPerFrame(forLevel: Int(level)),
              Int(framesPerBlock) * Int(channels) <= Self.maximumSamplesPerFrame else {
            throw OwnAudioError.unsupported(reason: OwnAudioWording.monkeysAudioShape)
        }
        // A file with no frame (one never finished), no frames in a block,
        // or a last block longer than a full one, is damage.
        guard totalBlocks > 0, framesPerBlock > 0, finalFrames > 0, finalFrames <= framesPerBlock else {
            throw OwnAudioError.damaged
        }

        // The seek table: where each frame starts, as 32-bit numbers that
        // wrap past four gigabytes. It must lie inside the file before any
        // of it is read, and hold an entry for every frame.
        let elements = Int(seekTableBytes) / 4
        guard elements >= Int(totalBlocks) else { throw OwnAudioError.damaged }
        let table = try bytes.read(at: headerStart + Int(headerBytes), count: Int(totalBlocks) * 4)
        var offsets: [Int] = []
        offsets.reserveCapacity(Int(totalBlocks))
        var wrapped = 0
        var previous: UInt32 = 0
        for index in 0..<Int(totalBlocks) {
            let entry = OwnAudioLittleEndian.uint32(table, index * 4) ?? 0
            if entry < previous { wrapped += 1 << 32 }
            previous = entry
            offsets.append(start + wrapped + Int(entry))
        }
        // Each frame starts after the one before, inside the file.
        guard offsets.first.map({ $0 >= headerStart }) == true, offsets.last.map({ $0 < bytes.count }) == true,
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else { throw OwnAudioError.damaged }

        let frames = (Int(totalBlocks) - 1) * Int(framesPerBlock) + Int(finalFrames)
        stream = OwnAudioStream(
            sampleRate: Int(rate), channels: Int(channels), bitsPerSample: Int(bits), isFloat: isFloat, frames: frames
        )
        self.bytes = bytes
        self.verifiesChecksums = verifiesChecksums
        self.level = Int(level)
        self.framesPerBlock = Int(framesPerBlock)
        self.finalFrames = Int(finalFrames)
        seekTable = offsets
        predictors = try Self.predictors(level: Int(level), stream: stream, isInterim: false)
        states = [MonkeysAudioResidualState](repeating: MonkeysAudioResidualState(), count: Int(channels))
    }

    /// A predictor for each channel of `stream`.
    private static func predictors(level: Int, stream: OwnAudioStream, isInterim: Bool) throws -> [MonkeysAudioPredictor] {
        try (0..<stream.channels).map { _ in
            guard let predictor = MonkeysAudioPredictor(
                level: level, bitsPerSample: stream.bitsPerSample, isInterim: isInterim
            ) else { throw OwnAudioError.unsupported(reason: OwnAudioWording.monkeysAudioShape) }
            return predictor
        }
    }

    // MARK: - Frames

    mutating func nextBlock() throws -> [Int32]? {
        guard nextFrame < seekTable.count else { return nil }
        let frame = nextFrame
        let frames = frame == seekTable.count - 1 ? finalFrames : framesPerBlock
        // A frame's bits start where the frame before stopped inside a
        // 32-bit word, so it is read from the word's start, and four bytes
        // past its end, which the coder looks ahead by.
        let skipped = (seekTable[frame] - seekTable[0]) % 4
        let start = seekTable[frame] - skipped
        let end = frame + 1 < seekTable.count ? seekTable[frame + 1] + 4 : bytes.count
        // No frame takes far more room than its samples would unpacked, so
        // a crafted seek table cannot ask for the whole file at once.
        let most = frames * stream.channels * (stream.bitsPerSample / 8) * 2 + 65_536
        let data = bytes.readUpTo(at: start, count: min(end - start, most))

        var samples: [Int32]
        do {
            samples = try decode(data, skipping: skipped, frames: frames)
        } catch OwnAudioError.damaged where verifiesChecksums && !isInterim && stream.bitsPerSample == 24 {
            // A few versions wrote 24-bit files whose sums do not wrap at
            // 32 bits. A frame that fails the usual way is tried that way,
            // and the rest of the file follows it.
            isInterim = true
            predictors = try Self.predictors(level: level, stream: stream, isInterim: true)
            samples = try decode(data, skipping: skipped, frames: frames)
        }
        if stream.isFloat {
            for index in samples.indices { samples[index] = Self.floatPattern(of: samples[index]) }
        }
        nextFrame += 1
        return samples
    }

    /// The float a stored 32-bit number stands for, as a bit pattern: the
    /// encoder moves a float's bits about so that it predicts as a whole
    /// number does, and this moves them back.
    static func floatPattern(of stored: Int32) -> Int32 {
        let input = UInt32(bitPattern: stored)
        var output = input & 0xC3FF_FFFF
        output |= ~(input & 0x3C00_0000) ^ 0xC3FF_FFFF
        if output & 0x8000_0000 != 0 { output = ~output | 0x8000_0000 }
        return Int32(bitPattern: output)
    }

    /// The `frames` frames of audio in `data`, one frame's bytes read from
    /// its word's start, whose first `skipped` bytes belong to the frame
    /// before: interleaved by channel.
    /// - Throws: `OwnAudioError.damaged` when the bytes end early, a 16-bit
    ///   sample does not fit, or the frame's CRC is wrong.
    private mutating func decode(_ data: [UInt8], skipping skipped: Int, frames: Int) throws -> [Int32] {
        var decoder = MonkeysAudioRangeDecoder(data, startingAt: skipped)
        var storedChecksum = try decoder.word()
        var special: UInt32 = 0
        // The top bit says that special codes follow: silence, or stereo that is one channel twice.
        if storedChecksum & 0x8000_0000 != 0 { special = try decoder.word() }
        storedChecksum &= 0x7FFF_FFFF
        for index in predictors.indices { predictors[index].reset() }
        for index in states.indices { states[index].reset() }
        try decoder.start()

        let channels = stream.channels
        var output = [Int32](repeating: 0, count: frames * channels)
        if channels > 2 {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    output[frame * channels + channel] = predictors[channel].decompress(
                        try decoder.residual(&states[channel]))
                }
                try Self.undoPairs(in: &output, at: frame * channels, channels: channels, bits: stream.bitsPerSample)
            }
        } else if channels == 2 {
            if special & Self.leftSilence != 0, special & Self.rightSilence != 0 {
                // Both channels are silent: the frame holds no residuals.
            } else if special & Self.pseudoStereo != 0 {
                for frame in 0..<frames {
                    let value = predictors[0].decompress(try decoder.residual(&states[0]))
                    output[frame * 2] = value
                    output[frame * 2 + 1] = value
                }
            } else {
                var lastX: Int32 = 0
                for frame in 0..<frames {
                    // The second channel's residual comes first; each channel predicts from the other.
                    let residualY = try decoder.residual(&states[1])
                    let residualX = try decoder.residual(&states[0])
                    let y = predictors[1].decompress(residualY, other: Int64(lastX))
                    let x = predictors[0].decompress(residualX, other: Int64(y))
                    lastX = x
                    output[frame * 2] = x
                    output[frame * 2 + 1] = y
                    try Self.undoPairs(in: &output, at: frame * 2, channels: 2, bits: stream.bitsPerSample)
                }
            }
        } else if special & Self.leftSilence == 0 {
            // Mono; with the silence code the frame holds no residuals.
            for frame in 0..<frames {
                output[frame] = predictors[0].decompress(try decoder.residual(&states[0]))
            }
        }
        Self.wrap(&output, toBits: stream.bitsPerSample)
        if verifiesChecksums {
            let checksum = Self.checksum(of: output, bits: stream.bitsPerSample)
            guard checksum >> 1 == storedChecksum else { throw OwnAudioError.damaged }
        }
        return output
    }

    /// Which channels are stored as a pair (the first as the mean of the
    /// two, the second as their difference), by the channel count and the
    /// bit depth, as the format's encoder pairs them: the first two of a
    /// stereo file at any depth; at 16 and 24 bits the first two and the
    /// next two of four channels, and of six or more the first two, the
    /// fifth and sixth, and (of eight or more) the seventh and eighth.
    static func pairedChannels(channels: Int, bits: Int) -> [Int] {
        if channels == 2 { return [0] }
        guard bits == 16 || bits == 24 else { return [] }
        if channels == 4 { return [0, 2] }
        if channels >= 8 { return [0, 4, 6] }
        if channels >= 6 { return [0, 4] }
        return []
    }

    /// Turns the pairs among the `channels` values of `output` at `offset`
    /// back into their two channels: the first is the mean less half the
    /// difference (halved towards zero, as the format halves it), the
    /// second that plus the difference.
    /// - Throws: `OwnAudioError.damaged` when a 16-bit value does not fit,
    ///   which the format's own decoder refuses too.
    @inline(__always)
    private static func undoPairs(in output: inout [Int32], at offset: Int, channels: Int, bits: Int) throws {
        for first in pairedChannels(channels: channels, bits: bits) {
            let mean = output[offset + first]
            let difference = output[offset + first + 1]
            let one = mean &- difference / 2
            let other = one &+ difference
            if bits == 16, Int32(Int16(truncatingIfNeeded: one)) != one || Int32(Int16(truncatingIfNeeded: other)) != other {
                throw OwnAudioError.damaged
            }
            output[offset + first] = one
            output[offset + first + 1] = other
        }
    }

    /// Keeps of every sample only the low `bits` bits, sign-extended, as
    /// writing it into that many bytes does.
    private static func wrap(_ samples: inout [Int32], toBits bits: Int) {
        guard bits < 32 else { return }
        let shift = Int32(32 - bits)
        for index in samples.indices { samples[index] = (samples[index] << shift) >> shift }
    }

    /// The CRC-32 of `samples` as the bytes a WAVE file stores them in:
    /// 8-bit samples unsigned, wider ones little-endian.
    private static func checksum(of samples: [Int32], bits: Int) -> UInt32 {
        let width = bits / 8
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * width)
        for sample in samples {
            if width == 1 {
                bytes.append(UInt8(truncatingIfNeeded: sample &+ 128))
            } else {
                for byte in 0..<width { bytes.append(UInt8(truncatingIfNeeded: sample >> Int32(8 * byte))) }
            }
        }
        return OwnAudioCRC32.checksum(bytes, in: 0..<bytes.count)
    }
}
