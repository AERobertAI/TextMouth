import Foundation

// TextMouth's own reader of WavPack files: one block's metadata read and
// its samples unpacked. It follows libwavpack 5.9.0 (open_utils.c, unpack.c,
// unpack_floats.c, decorr_utils.c, entropy_utils.c), Copyright (c) 1998 -
// 2025 David Bryant, under its BSD 3-clause licence (see WavPackBlock.swift).

/// The words a listener hears about a WavPack file the reader refuses.
extension OwnAudioWording {
    /// A WavPack file of DSD (one-bit) audio.
    static let wavPackDSD = "it holds DSD audio, which TextMouth does not read" // l10n: no (a parser's damage reason: finishes "because …", question 3)
    /// A WavPack file from before version 4 (2004), which starts as a WAVE
    /// file does.
    static let wavPackOld = "it was made by a WavPack older than version 4, from before 2004" // l10n: no (a parser's damage reason: finishes "because …", question 3)
    /// A WavPack file whose channels or sample rate no encoder writes.
    static let wavPackShape = "its channels or sample rate are outside what TextMouth reads" // l10n: no (a parser's damage reason: finishes "because …", question 3)
}

/// One WavPack block, ready to unpack: everything its metadata says, and,
/// for a hybrid file read with its correction file, what the matching
/// correction block adds. A block decodes alone: nothing carries over from
/// the block before.
struct WavPackBlockDecoder {
    /// The header that rules: the correction block's once one is added,
    /// since its checksum is of the lossless samples.
    private(set) var header: WavPackHeader
    /// The prediction passes, in the order they are undone.
    private var passes: [WavPackDecorrelationPass] = []
    /// The entropy decoder's state.
    private var words = WavPackWords()
    /// Hybrid noise shaping, for each channel: the weight (16 fraction
    /// bits), how it changes a sample, and the last error.
    private var shapingAccumulator: (Int32, Int32) = (0, 0)
    private var shapingDelta: (Int32, Int32) = (0, 0)
    private var shapingError: (Int32, Int32) = (0, 0)
    /// Whole numbers in two parts: the low bits sent apart, and the low
    /// bits that are all zeros, all ones, or copies of the bit above.
    private var int32SentBits = 0
    private var int32Zeros = 0
    private var int32Ones = 0
    private var int32Duplicates = 0
    private var int32MaximumWidth = 0
    /// Floats: flags, the shift of every mantissa, the largest exponent,
    /// and the exponent that stands for 1.0.
    private var floatFlags: UInt8 = 0
    private var floatShift = 0
    private var floatMaximumExponent: Int32 = 0
    private(set) var floatNormalExponent = 127
    private var floatMaximumShiftedOnes = 0
    private var floatMinimumShiftedZeros = 0
    /// The three bitstreams: the residuals, the hybrid corrections, and the
    /// extra bits of floats and wide whole numbers, with that stream's
    /// stored checksum.
    private var main = WavPackBits()
    private var correction = WavPackBits()
    private var extra = WavPackBits()
    private var extraChecksum: UInt32 = 0
    /// Whether a correction block was added.
    private(set) var hasCorrection = false
    /// What the block says of the whole file, when it says it.
    private(set) var channelCount: Int?
    private(set) var channelMask: UInt32?
    private(set) var sampleRate: Int?

    /// The bits of the float flags.
    private static let floatShiftOnes: UInt8 = 1
    private static let floatShiftSame: UInt8 = 2
    private static let floatShiftSent: UInt8 = 4
    private static let floatZerosSent: UInt8 = 8
    private static let floatNegativeZeros: UInt8 = 0x10
    /// The most channels a file may name; the format's own limit.
    static let maximumChannels = 4_096

    /// Reads the metadata of `block`, a whole block whose header is `header`.
    /// - Throws: `OwnAudioError.damaged` for metadata no encoder writes,
    ///   and `.unsupported` for DSD audio.
    init(block: [UInt8], header: WavPackHeader, verifiesChecksums: Bool) throws {
        self.header = header
        guard header.flags & WavPackFlags.dsd == 0 else {
            throw OwnAudioError.unsupported(reason: OwnAudioWording.wavPackDSD)
        }
        // A block cannot be flagged both mono and false stereo.
        guard header.flags & WavPackFlags.monoData != WavPackFlags.monoData else { throw OwnAudioError.damaged }
        try read(block, verifiesChecksums: verifiesChecksums)
    }

    /// Adds `block`, the correction file's block for the same frames: its
    /// header takes the place of the lossy block's.
    mutating func addCorrection(block: [UInt8], header: WavPackHeader, verifiesChecksums: Bool) throws {
        self.header = header
        hasCorrection = true
        try read(block, verifiesChecksums: verifiesChecksums)
    }

    // MARK: - Metadata

    /// Reads every piece of metadata in `block` into this decoder.
    private mutating func read(_ block: [UInt8], verifiesChecksums: Bool) throws {
        for piece in try WavPackMetadata.pieces(of: block, flags: header.flags, verifiesChecksum: verifiesChecksums) {
            let data = Array(block[piece.range])
            switch piece.id {
            case 0: break
            case WavPackMetadata.decorrelationTerms: try readTerms(data)
            case WavPackMetadata.decorrelationWeights: try readWeights(data)
            case WavPackMetadata.decorrelationSamples: try readHistories(data)
            case WavPackMetadata.entropyVariables: try readEntropy(data)
            case WavPackMetadata.hybridProfile: try readHybridProfile(data)
            case WavPackMetadata.shapingWeights: try readShaping(data)
            case WavPackMetadata.floatInfo:
                guard data.count == 4 else { throw OwnAudioError.damaged }
                floatFlags = data[0]
                floatShift = Int(data[1] & 0x1F)
                floatMaximumExponent = Int32(data[2])
                floatNormalExponent = Int(data[3])
            case WavPackMetadata.int32Info:
                guard data.count == 4 else { throw OwnAudioError.damaged }
                int32SentBits = Int(data[0] & 0x1F)
                int32Zeros = Int(data[1] & 0x1F)
                int32Ones = Int(data[2] & 0x1F)
                int32Duplicates = Int(data[3] & 0x1F)
            case WavPackMetadata.mainBitstream:
                guard !data.isEmpty, data.count & 1 == 0 else { throw OwnAudioError.damaged }
                main = WavPackBits(block, in: piece.range)
            case WavPackMetadata.correctionBitstream:
                guard !data.isEmpty, data.count & 1 == 0 else { throw OwnAudioError.damaged }
                correction = WavPackBits(block, in: piece.range)
            case WavPackMetadata.extraBitstream, WavPackMetadata.newExtraBitstream:
                try openExtraBitstream(block, in: piece.range, isNew: piece.id == WavPackMetadata.newExtraBitstream)
            case WavPackMetadata.channelInfo: try readChannels(data)
            case WavPackMetadata.sampleRate:
                if data.count == 3 || data.count == 4 {
                    sampleRate = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16
                        | (data.count == 4 ? Int(data[3] & 0x7F) << 24 : 0)
                }
            case WavPackMetadata.dsdBlock:
                throw OwnAudioError.unsupported(reason: OwnAudioWording.wavPackDSD)
            default:
                // A kind this reader does not know may be passed over only when it is marked optional.
                guard piece.id & WavPackMetadata.optional != 0 else { throw OwnAudioError.damaged }
            }
        }
    }

    /// A stored 16-bit logarithm at `offset` of `data`, as its number.
    private static func stored(_ data: [UInt8], _ offset: Int, signed: Bool = true) -> Int32 {
        let raw = OwnAudioLittleEndian.uint16(data, offset) ?? 0
        return WavPackLog.exp2(signed ? Int32(Int16(bitPattern: raw)) : Int32(raw))
    }

    /// The passes' terms and deltas, one byte each, stored last pass first.
    private mutating func readTerms(_ data: [UInt8]) throws {
        guard data.count <= WavPackDecorrelationPass.maximumPasses else { throw OwnAudioError.damaged }
        passes = try data.reversed().map { byte in
            let term = Int32(byte & 0x1F) - 5
            guard WavPackDecorrelationPass.isValid(term: term, isMono: header.isMonoData) else {
                throw OwnAudioError.damaged
            }
            return WavPackDecorrelationPass(term: term, delta: Int32(byte >> 5) & 7)
        }
    }

    /// The passes' weights, one byte a channel, from the last pass back;
    /// passes without one start from zero.
    private mutating func readWeights(_ data: [UInt8]) throws {
        let perPass = header.isMonoData ? 1 : 2
        let count = data.count / perPass
        guard count <= passes.count else { throw OwnAudioError.damaged }
        for index in passes.indices {
            passes[index].weightA = 0
            passes[index].weightB = 0
        }
        for stored in 0..<count {
            let index = passes.count - 1 - stored
            passes[index].weightA = WavPackLog.restoredWeight(data[stored * perPass])
            if perPass == 2 { passes[index].weightB = WavPackLog.restoredWeight(data[stored * perPass + 1]) }
        }
    }

    /// The samples each pass starts from, as logarithms, from the last
    /// pass back: two for terms 17 and 18, one of each channel for a
    /// negative term, and as many as the term otherwise.
    private mutating func readHistories(_ data: [UInt8]) throws {
        let isMono = header.isMonoData
        for index in passes.indices {
            passes[index].samplesA = [Int32](repeating: 0, count: WavPackDecorrelationPass.historyLength)
            passes[index].samplesB = passes[index].samplesA
        }
        var position = 0
        // The oldest stream version kept hybrid mode's shaping errors here.
        if header.version == 0x402, header.flags & WavPackFlags.hybrid != 0 {
            guard data.count >= (isMono ? 2 : 4) else { throw OwnAudioError.damaged }
            shapingError.0 = Self.stored(data, 0)
            position = 2
            if !isMono {
                shapingError.1 = Self.stored(data, 2)
                position = 4
            }
        }
        var index = passes.count - 1
        while index >= 0, position < data.count {
            let term = passes[index].term
            if term > 8 {
                guard data.count - position >= (isMono ? 4 : 8) else { throw OwnAudioError.damaged }
                passes[index].samplesA[0] = Self.stored(data, position)
                passes[index].samplesA[1] = Self.stored(data, position + 2)
                position += 4
                if !isMono {
                    passes[index].samplesB[0] = Self.stored(data, position)
                    passes[index].samplesB[1] = Self.stored(data, position + 2)
                    position += 4
                }
            } else if term < 0 {
                guard data.count - position >= 4 else { throw OwnAudioError.damaged }
                passes[index].samplesA[0] = Self.stored(data, position)
                passes[index].samplesB[0] = Self.stored(data, position + 2)
                position += 4
            } else {
                for slot in 0..<Int(term) {
                    guard data.count - position >= (isMono ? 2 : 4) else { throw OwnAudioError.damaged }
                    passes[index].samplesA[slot] = Self.stored(data, position)
                    position += 2
                    if !isMono {
                        passes[index].samplesB[slot] = Self.stored(data, position)
                        position += 2
                    }
                }
            }
            index -= 1
        }
        guard position == data.count else { throw OwnAudioError.damaged }
    }

    /// The entropy decoder's medians: three a channel, as logarithms.
    private mutating func readEntropy(_ data: [UInt8]) throws {
        guard data.count == (header.isMonoData ? 6 : 12) else { throw OwnAudioError.damaged }
        words.channel0.median0 = UInt32(bitPattern: Self.stored(data, 0, signed: false))
        words.channel0.median1 = UInt32(bitPattern: Self.stored(data, 2, signed: false))
        words.channel0.median2 = UInt32(bitPattern: Self.stored(data, 4, signed: false))
        guard !header.isMonoData else { return }
        words.channel1.median0 = UInt32(bitPattern: Self.stored(data, 6, signed: false))
        words.channel1.median1 = UInt32(bitPattern: Self.stored(data, 8, signed: false))
        words.channel1.median2 = UInt32(bitPattern: Self.stored(data, 10, signed: false))
    }

    /// Hybrid mode's levels and bit rates: a level a channel when the bit
    /// rate steers the noise, then a bit rate a channel, then, when there
    /// is more, how each bit rate changes a sample.
    private mutating func readHybridProfile(_ data: [UInt8]) throws {
        let isMono = header.isMonoData
        let perField = isMono ? 2 : 4
        var position = 0
        if header.flags & WavPackFlags.hybridBitrate != 0 {
            guard data.count - position >= perField else { throw OwnAudioError.damaged }
            words.channel0.slowLevel = UInt32(bitPattern: Self.stored(data, position, signed: false))
            if !isMono { words.channel1.slowLevel = UInt32(bitPattern: Self.stored(data, position + 2, signed: false)) }
            position += perField
        }
        guard data.count - position >= perField else { throw OwnAudioError.damaged }
        words.bitrateAccumulator.0 = UInt32(OwnAudioLittleEndian.uint16(data, position) ?? 0) << 16
        if !isMono { words.bitrateAccumulator.1 = UInt32(OwnAudioLittleEndian.uint16(data, position + 2) ?? 0) << 16 }
        position += perField
        words.bitrateDelta = (0, 0)
        guard position < data.count else { return }
        guard data.count - position == perField else { throw OwnAudioError.damaged }
        words.bitrateDelta.0 = UInt32(bitPattern: Self.stored(data, position))
        if !isMono { words.bitrateDelta.1 = UInt32(bitPattern: Self.stored(data, position + 2)) }
    }

    /// Hybrid noise shaping: two weights as bytes, or, a channel, the last
    /// error and the weight as logarithms, with how the weight changes a
    /// sample when that follows.
    private mutating func readShaping(_ data: [UInt8]) throws {
        let isMono = header.isMonoData
        if data.count == 2 {
            shapingAccumulator.0 = WavPackLog.restoredWeight(data[0]) << 16
            shapingAccumulator.1 = WavPackLog.restoredWeight(data[1]) << 16
            return
        }
        guard data.count >= (isMono ? 4 : 8) else { throw OwnAudioError.damaged }
        shapingError.0 = Self.stored(data, 0)
        shapingAccumulator.0 = Self.stored(data, 2)
        var position = 4
        if !isMono {
            shapingError.1 = Self.stored(data, 4)
            shapingAccumulator.1 = Self.stored(data, 6)
            position = 8
        }
        guard data.count == (isMono ? 6 : 12) else { return }
        shapingDelta.0 = Self.stored(data, position)
        if !isMono { shapingDelta.1 = Self.stored(data, position + 2) }
    }

    /// The stream of extra bits: its checksum in four bytes, then the
    /// bits, which in the newer form start with one or two 5-bit numbers.
    private mutating func openExtraBitstream(_ block: [UInt8], in range: Range<Int>, isNew: Bool) throws {
        guard range.count > 4, range.count & 1 == 0,
              let checksum = OwnAudioLittleEndian.uint32(block, range.lowerBound) else { throw OwnAudioError.damaged }
        extraChecksum = checksum
        extra = WavPackBits(block, in: range.lowerBound + 4..<range.upperBound)
        guard isNew else { return }
        if header.flags & WavPackFlags.floatData != 0 {
            floatMinimumShiftedZeros = Int(extra.bits(5))
            floatMaximumShiftedOnes = Int(extra.bits(5))
        } else {
            int32MaximumWidth = Int(extra.bits(5))
        }
    }

    /// The file's channel count and which loudspeaker each is: a count and
    /// a mask of up to four bytes, or, in six or seven bytes, a 12-bit
    /// count, the count of blocks, and the mask.
    private mutating func readChannels(_ data: [UInt8]) throws {
        guard !data.isEmpty, data.count <= 7 else { throw OwnAudioError.damaged }
        var count: Int
        var mask: UInt32 = 0
        if data.count >= 6 {
            count = (Int(data[0]) | Int(data[2] & 0xF) << 8) + 1
            let streams = (Int(data[1]) | Int(data[2] & 0xF0) << 4) + 1
            guard count >= streams, count <= streams * 2 else { throw OwnAudioError.damaged }
            mask = UInt32(data[3]) | UInt32(data[4]) << 8 | UInt32(data[5]) << 16
            if data.count == 7 { mask |= UInt32(data[6]) << 24 }
        } else {
            count = Int(data[0])
            for (index, byte) in data.dropFirst().enumerated() { mask |= UInt32(byte) << UInt32(8 * index) }
        }
        guard count <= Self.maximumChannels, mask.nonzeroBitCount <= count else { throw OwnAudioError.damaged }
        // A count of none leaves the file's channels to its first block's flags.
        guard count >= 1 else { return }
        channelCount = count
        channelMask = mask
    }

    // MARK: - Unpacking

    /// The block's samples: one for each frame of a mono block, or left
    /// and right in turn (false stereo gives its one channel twice). Whole
    /// numbers are in the low bits; floats are bit patterns, scaled so that
    /// 1.0 is full scale.
    /// - Parameter verifiesChecksums: whether the samples' checksums must
    ///   be right.
    /// - Throws: `OwnAudioError.damaged` when the bits end early, a sample
    ///   is larger than the block allows, or a checksum is wrong.
    mutating func unpack(verifiesChecksums: Bool) throws -> [Int32] {
        let flags = header.flags
        let isMono = header.isMonoData
        let isHybrid = flags & WavPackFlags.hybrid != 0
        let frames = header.blockSamples
        guard main.isOpen else { throw OwnAudioError.damaged }
        // A correction block makes sense only beside a hybrid block.
        guard !hasCorrection || isHybrid else { throw OwnAudioError.damaged }
        let magnitude = Int64((flags & WavPackFlags.magnitudeMask) >> WavPackFlags.magnitudeLSB)
        var muteLimit = Int64(1) << magnitude + 2
        if isHybrid, !hasCorrection { muteLimit = muteLimit * 2 + 128 }
        var buffer = [Int32](repeating: 0, count: isMono ? frames : frames * 2)
        var checksum = UInt32.max

        if hasCorrection {
            checksum = isMono
                ? try unpackCorrectedMono(into: &buffer, muteLimit: muteLimit)
                : try unpackCorrectedStereo(into: &buffer, muteLimit: muteLimit)
        } else {
            checksum = try unpackPassByPass(into: &buffer, isMono: isMono, isHybrid: isHybrid, muteLimit: muteLimit)
        }
        if verifiesChecksums, checksum != header.crc { throw OwnAudioError.damaged }

        let extraSum = fixUp(&buffer)
        if verifiesChecksums, extra.isOpen, let extraSum, extraSum != extraChecksum { throw OwnAudioError.damaged }

        guard flags & WavPackFlags.falseStereo != 0 else { return buffer }
        // False stereo: the one channel goes to both.
        var doubled = [Int32](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            doubled[frame * 2] = buffer[frame]
            doubled[frame * 2 + 1] = buffer[frame]
        }
        return doubled
    }

    /// A lossless block, or a hybrid block read without its correction:
    /// every residual is read, then each pass is undone over the whole
    /// block, then joint stereo.
    /// - Returns: the checksum of the samples.
    private mutating func unpackPassByPass(
        into buffer: inout [Int32],
        isMono: Bool,
        isHybrid: Bool,
        muteLimit: Int64
    ) throws -> UInt32 {
        let flags = header.flags
        var checksum = UInt32.max
        var isSound = true
        try buffer.withUnsafeMutableBufferPointer { samples in
            if isHybrid {
                for index in 0..<samples.count {
                    guard let word = words.hybrid(
                        channel: isMono ? 0 : index & 1, flags: flags, from: &main, correction: &correction
                    ) else { throw OwnAudioError.damaged }
                    samples[index] = word.value
                }
            } else {
                guard words.lossless(into: samples, isMono: isMono, from: &main) == samples.count else {
                    throw OwnAudioError.damaged
                }
            }
            for index in passes.indices {
                if isMono {
                    passes[index].undoMono(samples)
                } else {
                    passes[index].undoStereo(samples)
                }
            }
            if isMono {
                for index in 0..<samples.count {
                    if !isHybrid, Int64(samples[index]).magnitude > muteLimit { isSound = false }
                    checksum = checksum &* 3 &+ UInt32(bitPattern: samples[index])
                }
            } else {
                let isJoint = flags & WavPackFlags.jointStereo != 0
                for frame in 0..<samples.count / 2 {
                    if isJoint {
                        // The side channel and the mid channel back to left and right.
                        samples[frame * 2 + 1] = samples[frame * 2 + 1] &- (samples[frame * 2] >> 1)
                        samples[frame * 2] = samples[frame * 2] &+ samples[frame * 2 + 1]
                    }
                    let left = UInt32(bitPattern: samples[frame * 2])
                    checksum = checksum &+ (checksum << 3) &+ (left << 1) &+ left &+ UInt32(bitPattern: samples[frame * 2 + 1])
                    // As the format's own decoder does, one frame in eight is checked for size.
                    if !isHybrid, frame & 7 == 0,
                       Int64(samples[frame * 2]).magnitude > muteLimit || Int64(samples[frame * 2 + 1]).magnitude > muteLimit {
                        isSound = false
                    }
                }
            }
        }
        guard isSound else { throw OwnAudioError.damaged }
        return checksum
    }

    /// The noise-shaping step of a hybrid block read with its correction:
    /// the lossless sample from the lossy one, `lossy`, and the lossless
    /// one before shaping, `exact`, with the channel's shaping state moved
    /// on.
    private static func shaped(
        exact: Int32,
        lossy: Int32,
        flags: UInt32,
        accumulator: inout Int32,
        delta: Int32,
        error: inout Int32
    ) -> Int32 {
        let difference = exact &- lossy
        accumulator = accumulator &+ delta
        let weight = accumulator >> 16
        var shaping = 0 &- WavPackWeight.apply(weight, error)
        if flags & WavPackFlags.newShaping != 0, weight < 0, shaping != 0 {
            if shaping == error { shaping = shaping < 0 ? shaping &+ 1 : shaping &- 1 }
            error = shaping &- difference
        } else {
            error = 0 &- difference
        }
        return exact &- shaping
    }

    /// A hybrid mono block read with its correction, a sample at a time
    /// through every pass.
    /// - Returns: the checksum of the samples.
    private mutating func unpackCorrectedMono(into buffer: inout [Int32], muteLimit: Int64) throws -> UInt32 {
        let flags = header.flags
        var checksum = UInt32.max
        var ring = 0
        for index in buffer.indices {
            guard let word = words.hybrid(channel: 0, flags: flags, from: &main, correction: &correction) else {
                throw OwnAudioError.damaged
            }
            var sample = word.value
            for pass in passes.indices {
                let term = passes[pass].term
                let predicted: Int32
                var slot = 0
                if term > 8 {
                    predicted = WavPackDecorrelationPass.extrapolated(
                        term: term, passes[pass].samplesA[0], passes[pass].samplesA[1])
                    passes[pass].samplesA[1] = passes[pass].samplesA[0]
                } else {
                    predicted = passes[pass].samplesA[ring]
                    slot = (ring + Int(term)) & 7
                }
                let undone = WavPackWeight.apply(passes[pass].weightA, predicted) &+ sample
                WavPackWeight.update(&passes[pass].weightA, delta: passes[pass].delta, source: predicted, result: sample)
                passes[pass].samplesA[slot] = undone
                sample = undone
            }
            ring = (ring + 1) & 7
            let exact = sample &+ word.correction
            if flags & WavPackFlags.hybridShape != 0 {
                sample = Self.shaped(
                    exact: exact, lossy: sample, flags: flags, accumulator: &shapingAccumulator.0,
                    delta: shapingDelta.0, error: &shapingError.0)
            } else {
                sample = exact
            }
            checksum = checksum &* 3 &+ UInt32(bitPattern: sample)
            guard Int64(sample).magnitude <= muteLimit else { throw OwnAudioError.damaged }
            buffer[index] = sample
        }
        return checksum
    }

    /// A hybrid stereo block read with its correction, a frame at a time
    /// through every pass.
    /// - Returns: the checksum of the samples.
    private mutating func unpackCorrectedStereo(into buffer: inout [Int32], muteLimit: Int64) throws -> UInt32 {
        let flags = header.flags
        let isJoint = flags & WavPackFlags.jointStereo != 0
        let isCross = flags & WavPackFlags.crossDecorrelation != 0
        var checksum = UInt32.max
        var ring = 0
        for frame in 0..<buffer.count / 2 {
            guard let first = words.hybrid(channel: 0, flags: flags, from: &main, correction: &correction),
                  let second = words.hybrid(channel: 1, flags: flags, from: &main, correction: &correction) else {
                throw OwnAudioError.damaged
            }
            var left = first.value
            var right = second.value
            var exactLeft: Int32 = 0
            var exactRight: Int32 = 0
            if isCross {
                // The lossless pair is predicted from the lossy channels' histories, before they move on.
                exactLeft = left &+ first.correction
                exactRight = right &+ second.correction
                for pass in passes.indices {
                    let term = passes[pass].term
                    if term > 8 {
                        exactLeft = exactLeft &+ WavPackWeight.apply(passes[pass].weightA, WavPackDecorrelationPass.extrapolated(
                            term: term, passes[pass].samplesA[0], passes[pass].samplesA[1]))
                        exactRight = exactRight &+ WavPackWeight.apply(passes[pass].weightB, WavPackDecorrelationPass.extrapolated(
                            term: term, passes[pass].samplesB[0], passes[pass].samplesB[1]))
                    } else if term > 0 {
                        exactLeft = exactLeft &+ WavPackWeight.apply(passes[pass].weightA, passes[pass].samplesA[ring])
                        exactRight = exactRight &+ WavPackWeight.apply(passes[pass].weightB, passes[pass].samplesB[ring])
                    } else if term == -1 {
                        exactLeft = exactLeft &+ WavPackWeight.apply(passes[pass].weightA, passes[pass].samplesA[0])
                        exactRight = exactRight &+ WavPackWeight.apply(passes[pass].weightB, exactLeft)
                    } else {
                        exactRight = exactRight &+ WavPackWeight.apply(passes[pass].weightB, passes[pass].samplesB[0])
                        exactLeft = exactLeft &+ WavPackWeight.apply(
                            passes[pass].weightA, term == -3 ? passes[pass].samplesA[0] : exactRight)
                    }
                }
                if isJoint {
                    exactRight = exactRight &- (exactLeft >> 1)
                    exactLeft = exactLeft &+ exactRight
                }
            }
            for pass in passes.indices {
                let term = passes[pass].term
                let delta = passes[pass].delta
                if term > 0 {
                    let predictedA: Int32
                    let predictedB: Int32
                    var slot = 0
                    if term > 8 {
                        predictedA = WavPackDecorrelationPass.extrapolated(
                            term: term, passes[pass].samplesA[0], passes[pass].samplesA[1])
                        predictedB = WavPackDecorrelationPass.extrapolated(
                            term: term, passes[pass].samplesB[0], passes[pass].samplesB[1])
                        passes[pass].samplesA[1] = passes[pass].samplesA[0]
                        passes[pass].samplesB[1] = passes[pass].samplesB[0]
                    } else {
                        predictedA = passes[pass].samplesA[ring]
                        predictedB = passes[pass].samplesB[ring]
                        slot = (ring + Int(term)) & 7
                    }
                    let undoneLeft = WavPackWeight.apply(passes[pass].weightA, predictedA) &+ left
                    let undoneRight = WavPackWeight.apply(passes[pass].weightB, predictedB) &+ right
                    WavPackWeight.update(&passes[pass].weightA, delta: delta, source: predictedA, result: left)
                    WavPackWeight.update(&passes[pass].weightB, delta: delta, source: predictedB, result: right)
                    left = undoneLeft
                    right = undoneRight
                    passes[pass].samplesA[slot] = left
                    passes[pass].samplesB[slot] = right
                } else if term == -1 {
                    let undoneLeft = left &+ WavPackWeight.apply(passes[pass].weightA, passes[pass].samplesA[0])
                    WavPackWeight.updateClipped(
                        &passes[pass].weightA, delta: delta, source: passes[pass].samplesA[0], result: left)
                    left = undoneLeft
                    let undoneRight = right &+ WavPackWeight.apply(passes[pass].weightB, undoneLeft)
                    WavPackWeight.updateClipped(&passes[pass].weightB, delta: delta, source: undoneLeft, result: right)
                    right = undoneRight
                    passes[pass].samplesA[0] = right
                } else {
                    var undoneRight = right &+ WavPackWeight.apply(passes[pass].weightB, passes[pass].samplesB[0])
                    WavPackWeight.updateClipped(
                        &passes[pass].weightB, delta: delta, source: passes[pass].samplesB[0], result: right)
                    right = undoneRight
                    if term == -3 {
                        undoneRight = passes[pass].samplesA[0]
                        passes[pass].samplesA[0] = right
                    }
                    let undoneLeft = left &+ WavPackWeight.apply(passes[pass].weightA, undoneRight)
                    WavPackWeight.updateClipped(&passes[pass].weightA, delta: delta, source: undoneRight, result: left)
                    left = undoneLeft
                    passes[pass].samplesB[0] = left
                }
            }
            ring = (ring + 1) & 7
            if !isCross {
                exactLeft = left &+ first.correction
                exactRight = right &+ second.correction
                if isJoint {
                    exactRight = exactRight &- (exactLeft >> 1)
                    exactLeft = exactLeft &+ exactRight
                }
            }
            if isJoint {
                right = right &- (left >> 1)
                left = left &+ right
            }
            if flags & WavPackFlags.hybridShape != 0 {
                left = Self.shaped(
                    exact: exactLeft, lossy: left, flags: flags, accumulator: &shapingAccumulator.0,
                    delta: shapingDelta.0, error: &shapingError.0)
                right = Self.shaped(
                    exact: exactRight, lossy: right, flags: flags, accumulator: &shapingAccumulator.1,
                    delta: shapingDelta.1, error: &shapingError.1)
            } else {
                left = exactLeft
                right = exactRight
            }
            guard Int64(left).magnitude <= muteLimit, Int64(right).magnitude <= muteLimit else {
                throw OwnAudioError.damaged
            }
            let leftBits = UInt32(bitPattern: left)
            checksum = checksum &+ (checksum << 3) &+ (leftBits << 1) &+ leftBits &+ UInt32(bitPattern: right)
            buffer[frame * 2] = left
            buffer[frame * 2 + 1] = right
        }
        return checksum
    }

    // MARK: - The Last Steps

    /// The steps after the passes: floats rebuilt, the low bits of wide
    /// whole numbers put back, lossy samples held inside their range, and
    /// the final shift.
    /// - Returns: the checksum of the extra bits' samples, when the extra
    ///   bitstream was read.
    private mutating func fixUp(_ buffer: inout [Int32]) -> UInt32? {
        let flags = header.flags
        let isLossy = flags & WavPackFlags.hybrid != 0 && !hasCorrection
        var shift = Int((flags & WavPackFlags.shiftMask) >> WavPackFlags.shiftLSB)
        if flags & WavPackFlags.floatData != 0 {
            return extra.isOpen ? rebuildFloats(&buffer) : rebuildFloatsWithoutExtraBits(&buffer)
        }
        var extraSum: UInt32?
        if flags & WavPackFlags.int32Data != 0 {
            var zeros = int32Zeros, ones = int32Ones, duplicates = int32Duplicates
            if extra.isOpen {
                extraSum = restoreLowBits(&buffer)
            } else if int32SentBits == 0, zeros + ones + duplicates != 0 {
                // A lossy 32-bit block moves what it can of these bits into the shift, which clips.
                while isLossy, flags & WavPackFlags.bytesStoredMask == 3, shift < 8 {
                    if zeros != 0 {
                        zeros -= 1
                    } else if ones != 0 {
                        ones -= 1
                    } else if duplicates != 0 {
                        duplicates -= 1
                    } else {
                        break
                    }
                    shift += 1
                }
                for index in buffer.indices {
                    buffer[index] = Self.widened(buffer[index], zeros: zeros, ones: ones, duplicates: duplicates)
                }
            } else {
                shift += zeros + int32SentBits + ones + duplicates
            }
        }
        shift &= 0x1F
        if isLossy {
            // A lossy sample may overshoot: hold it inside the range its bytes allow.
            let width = Int32((flags & WavPackFlags.bytesStoredMask) + 1) * 8
            let lowest = (Int32.min >> (32 - width)) >> Int32(shift)
            let highest = (Int32.max >> (32 - width)) >> Int32(shift)
            for index in buffer.indices {
                buffer[index] = min(max(buffer[index], lowest), highest) << Int32(shift)
            }
        } else if shift != 0 {
            for index in buffer.indices { buffer[index] <<= Int32(shift) }
        }
        return extraSum
    }

    /// A sample with the low bits no sample of the block uses put back:
    /// `zeros` zero bits, or `ones` one bits, or `duplicates` copies of
    /// its lowest bit.
    @inline(__always)
    private static func widened(_ sample: Int32, zeros: Int, ones: Int, duplicates: Int) -> Int32 {
        if zeros != 0 { return sample << Int32(zeros) }
        if ones != 0 { return ((sample &+ 1) << Int32(ones)) &- 1 }
        if duplicates != 0 { return ((sample &+ (sample & 1)) << Int32(duplicates)) &- (sample & 1) }
        return sample
    }

    /// Puts back the low bits of wide whole numbers, read from the extra
    /// bitstream, then the bits no sample uses.
    /// - Returns: the checksum of the samples.
    private mutating func restoreLowBits(_ buffer: inout [Int32]) -> UInt32 {
        var checksum = UInt32.max
        let sent = int32SentBits
        let mask = UInt32(1) << UInt32(sent) &- 1
        for index in buffer.indices {
            var sample = buffer[index]
            if sent != 0 {
                if int32MaximumWidth != 0 {
                    // A sample already as wide as the block's widest has fewer low bits sent.
                    let magnitude = UInt32(bitPattern: sample < 0 ? ~sample : sample)
                    let width = WavPackLog.bitCount(magnitude) + sent
                    var toRead = sent
                    if width > int32MaximumWidth { toRead -= width - int32MaximumWidth }
                    if toRead > 0 {
                        let low = extra.bits(toRead) & (UInt32(1) << UInt32(toRead) &- 1)
                        sample = Int32(bitPattern: (UInt32(bitPattern: sample) << UInt32(toRead) | low) << UInt32(sent - toRead))
                    } else {
                        sample = sample << Int32(sent)
                    }
                } else {
                    sample = Int32(bitPattern: UInt32(bitPattern: sample) << UInt32(sent) | (extra.bits(sent) & mask))
                }
            }
            sample = Self.widened(sample, zeros: int32Zeros, ones: int32Ones, duplicates: int32Duplicates)
            let bits = UInt32(bitPattern: sample)
            checksum = checksum &* 9 &+ (bits & 0xFFFF) &* 3 &+ (bits >> 16)
            buffer[index] = sample
        }
        return checksum
    }

    /// A float's bit pattern from its sign, exponent (0 to 255), and
    /// mantissa (23 bits).
    @inline(__always)
    private static func float(negative: Bool, exponent: Int32, mantissa: Int32) -> Int32 {
        Int32(bitPattern: (negative ? 0x8000_0000 : 0) | UInt32(exponent & 0xFF) << 23 | UInt32(bitPattern: mantissa) & 0x7F_FFFF)
    }

    /// The exponent's change that makes 1.0 full scale: nothing for a file
    /// whose floats already are (the usual case).
    private var floatExponentChange: Int32 { Int32(127 - floatNormalExponent) }

    /// `pattern` with its exponent moved by `change`: zero when that falls
    /// below the smallest, infinity above the largest.
    private static func normalized(_ pattern: Int32, by change: Int32) -> Int32 {
        guard change != 0 else { return pattern }
        let exponent = (pattern >> 23) & 0xFF
        if exponent == 0 || exponent + change <= 0 { return 0 }
        let negative = pattern < 0
        if exponent == 255 || exponent + change >= 255 { return float(negative: negative, exponent: 255, mantissa: 0) }
        return float(negative: negative, exponent: exponent + change, mantissa: pattern & 0x7F_FFFF)
    }

    /// Rebuilds floats exactly: each sample's whole-number part, shifted
    /// until its top bit is in place, with the bits shifted in and the
    /// special values read from the extra bitstream.
    /// - Returns: the checksum of the floats.
    private mutating func rebuildFloats(_ buffer: inout [Int32]) -> UInt32 {
        var checksum = UInt32.max
        let change = floatExponentChange
        for index in buffer.indices {
            var value = buffer[index]
            var exponent = floatMaximumExponent
            var negative = false
            var mantissa: Int32 = 0
            var storedExponent: Int32 = 0
            if value == 0 {
                if floatFlags & Self.floatZerosSent != 0 {
                    if extra.bit() != 0 {
                        mantissa = Int32(bitPattern: extra.bits(23))
                        if exponent >= 25 { storedExponent = Int32(bitPattern: extra.bits(8)) }
                        negative = extra.bit() != 0
                    } else if floatFlags & Self.floatNegativeZeros != 0 {
                        negative = extra.bit() != 0
                    }
                }
            } else {
                value = value << Int32(floatShift)
                if value < 0 {
                    value = 0 &- value
                    negative = true
                }
                if value == 0x100_0000 {
                    // An infinity, or a value that is not a number, with its mantissa sent.
                    if extra.bit() != 0 { mantissa = Int32(bitPattern: extra.bits(23)) }
                    storedExponent = 255
                } else {
                    var shifted = 0
                    if exponent != 0 {
                        // At most 255 steps: the exponent bounds the loop.
                        while value & 0x80_0000 == 0 {
                            exponent -= 1
                            if exponent == 0 { break }
                            shifted += 1
                            value = value << 1
                        }
                    }
                    shifted &= 0x1F
                    if shifted != 0 {
                        if floatFlags & Self.floatShiftOnes != 0
                            || (floatFlags & Self.floatShiftSame != 0 && extra.bit() != 0) {
                            value |= Int32(1) << Int32(shifted) &- 1
                        } else if floatFlags & Self.floatShiftSent != 0 {
                            let mask = Int32(1) << Int32(shifted) &- 1
                            var zeros = 0
                            if floatMaximumShiftedOnes != 0, shifted > floatMaximumShiftedOnes {
                                zeros = shifted - floatMaximumShiftedOnes
                            }
                            if floatMinimumShiftedZeros > zeros { zeros = min(floatMinimumShiftedZeros, shifted) }
                            let sent = shifted - zeros
                            if sent > 0 { value |= Int32(bitPattern: extra.bits(sent) << UInt32(zeros)) & mask }
                        }
                    }
                    mantissa = value
                    storedExponent = exponent
                }
            }
            let pattern = Self.float(negative: negative, exponent: storedExponent, mantissa: mantissa)
            let bits = UInt32(bitPattern: pattern)
            checksum = checksum &* 27 &+ (bits & 0x7F_FFFF) &* 9 &+ ((bits >> 23) & 0xFF) &* 3 &+ (bits >> 31)
            buffer[index] = Self.normalized(pattern, by: change)
        }
        return checksum
    }

    /// Rebuilds floats as nearly as the samples alone allow, for a block
    /// without extra bits (a lossy one).
    private mutating func rebuildFloatsWithoutExtraBits(_ buffer: inout [Int32]) -> UInt32? {
        let change = floatExponentChange
        for index in buffer.indices {
            var value = buffer[index]
            guard value != 0 else { continue }
            var exponent = floatMaximumExponent
            var negative = false
            value = value << Int32(floatShift)
            if value < 0 {
                value = 0 &- value
                negative = true
            }
            if value >= 0x100_0000 {
                // At most eight steps: the value is positive and under 2 to the 31st.
                while value & 0xF00_0000 != 0 {
                    value >>= 1
                    exponent += 1
                }
            } else if exponent != 0 {
                var shifted = 0
                while value & 0x80_0000 == 0 {
                    exponent -= 1
                    if exponent == 0 { break }
                    shifted += 1
                    value = value << 1
                }
                shifted &= 0x1F
                if shifted != 0, floatFlags & Self.floatShiftOnes != 0 { value |= Int32(1) << Int32(shifted) &- 1 }
            }
            buffer[index] = Self.normalized(Self.float(negative: negative, exponent: exponent, mantissa: value), by: change)
        }
        return nil
    }
}
