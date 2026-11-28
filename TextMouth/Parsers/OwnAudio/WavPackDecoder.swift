import Foundation

// TextMouth's own reader of WavPack files: the file as a whole. It follows
// libwavpack 5.9.0 (open_utils.c, unpack_utils.c), Copyright (c) 1998 - 2025
// David Bryant, under its BSD 3-clause licence (see WavPackBlock.swift).

/// TextMouth's own WavPack decoder, for files of WavPack 4 and 5: lossless
/// files, hybrid files read alone (lossy) or with their correction file
/// (lossless), whole numbers of 8 to 32 bits, 32-bit floats, and one to 32
/// channels. DSD audio and files from before WavPack 4 are refused.
///
/// A file is a run of blocks, each decoded alone. A block holds one or two
/// channels, so a stretch of a file of more channels is several blocks,
/// from one marked initial to one marked final. Where the format's own
/// decoder plays silence over a damaged block, this one gives the file up:
/// an import should not keep a book with a hole in it.
struct WavPackDecoder: OwnAudioDecoder {
    /// The four bytes a block starts with.
    static let signature = WavPackHeader.signature
    /// The most channels read. The format allows 4,096; a block of that
    /// many channels would take gigabytes, and no audiobook has them.
    static let maximumChannels = 32
    /// The highest sample rate read, in hertz.
    static let maximumSampleRate = 10_000_000
    /// How far past a block's end the next block is looked for before the
    /// audio is taken to have ended: other data may lie between blocks.
    static let maximumGapBytes = 1_048_576
    /// The bytes read at a time while looking for a block.
    private static let searchWindow = 65_536

    let stream: OwnAudioStream

    /// The file, its correction file when one is used, and whether every
    /// checksum is verified (the fuzzers turn that off).
    private let bytes: OwnAudioBytes
    private let correction: OwnAudioBytes?
    private let verifiesChecksums: Bool
    /// Where the next block is looked for, in the file and in the
    /// correction file.
    private var offset: Int
    private var correctionOffset = 0
    /// The index the file's first frame has in its blocks' headers, which
    /// is not 0 for a piece cut from a longer file.
    private let initialIndex: Int64
    /// How many empty low bits the file left out of every sample (the
    /// header's shift): 0 for floats and for samples that fill their bytes.
    private let headerShift: Int32
    /// The frames handed over so far.
    private var delivered = 0

    /// Opens `bytes` as a WavPack file, reading as far as its first block
    /// of audio.
    /// - Parameter correction: the bytes of the correction file (.wvc) of a
    ///   hybrid file, when there is one; it is used only by a hybrid file.
    /// - Throws: `OwnAudioError`.
    init(_ bytes: OwnAudioBytes, correction: OwnAudioBytes? = nil, verifiesChecksums: Bool = true) throws {
        var position = OwnAudioLeadingTag.id3v2Length(in: bytes.readUpTo(at: 0, count: 10))
        guard OwnAudioLittleEndian.holds(bytes.readUpTo(at: position, count: 4), Self.signature, at: 0) else {
            throw OwnAudioError.notThisFormat
        }
        // The first block with audio says what the audio is; blocks before
        // it may hold only metadata, such as the sample rate.
        var channelCount: Int?
        var channelMask: UInt32?
        var sampleRate: Int?
        var first: WavPackHeader?
        var firstOffset = position
        while first == nil {
            firstOffset = position
            guard let read = try Self.readBlock(in: bytes, from: &position) else { throw OwnAudioError.damaged }
            let block = try WavPackBlockDecoder(block: read.block, header: read.header, verifiesChecksums: verifiesChecksums)
            channelCount = channelCount ?? block.channelCount
            channelMask = channelMask ?? block.channelMask
            sampleRate = sampleRate ?? block.sampleRate
            if read.header.blockSamples > 0 { first = read.header }
        }
        guard let first else { throw OwnAudioError.damaged }
        let flags = first.flags
        let rateIndex = Int((flags & WavPackFlags.sampleRateMask) >> WavPackFlags.sampleRateLSB)
        let rate = sampleRate ?? (rateIndex < WavPackFlags.sampleRates.count ? WavPackFlags.sampleRates[rateIndex] : 44_100)
        let channels = channelCount ?? first.channels
        guard (1...Self.maximumChannels).contains(channels), (1...Self.maximumSampleRate).contains(rate) else {
            throw OwnAudioError.unsupported(reason: OwnAudioWording.wavPackShape)
        }
        let isFloat = flags & WavPackFlags.floatData != 0
        let storedBits = Int((flags & WavPackFlags.bytesStoredMask) + 1) * 8
        // Samples of fewer bits than their bytes hold (12 in 16, 20 in 24, 24
        // in 32) are stored without their empty low bits: the header's shift.
        let shift = isFloat ? 0 : Int((flags & WavPackFlags.shiftMask) >> WavPackFlags.shiftLSB)
        let bits = isFloat ? 32 : storedBits - shift
        guard (1...32).contains(bits) else { throw OwnAudioError.damaged }
        headerShift = Int32(shift)

        // The header knows the length unless the file was written to a pipe
        // or cut from a longer one; then the last block's end gives it.
        var total = first.totalFrames
        if total == nil || first.blockIndex != 0 {
            total = Self.finalIndex(in: bytes, from: firstOffset).map { $0 - first.blockIndex }
        }
        guard let total, total > 0 else { throw OwnAudioError.damaged }

        let isHybrid = flags & WavPackFlags.hybrid != 0
        let usesCorrection = isHybrid && (correction?.count ?? 0) > 0
        // More than two channels have a layout only when the file names one.
        let mask = channels > 2 ? (channelMask ?? 0) : 0
        stream = OwnAudioStream(
            sampleRate: rate, channels: channels, bitsPerSample: bits, isFloat: isFloat,
            isLossless: !isHybrid || usesCorrection, frames: Int(clamping: total), channelMask: mask != 0 ? mask : nil
        )
        self.bytes = bytes
        self.correction = usesCorrection ? correction : nil
        self.verifiesChecksums = verifiesChecksums
        offset = firstOffset
        initialIndex = first.blockIndex
    }

    // MARK: - Finding Blocks

    /// The next block header in `bytes` at or after `offset`, and where it
    /// starts; nil when none starts within `maximumGapBytes`.
    private static func nextHeader(in bytes: OwnAudioBytes, from offset: Int) -> (header: WavPackHeader, offset: Int)? {
        // Nearly always the next block starts right here.
        if let header = WavPackHeader(bytes.readUpTo(at: offset, count: WavPackHeader.length)) { return (header, offset) }
        var position = offset
        var skipped = 0
        // Each turn moves on by at least one byte, and the gap bounds the turns.
        while skipped <= maximumGapBytes {
            let window = bytes.readUpTo(at: position, count: searchWindow + WavPackHeader.length - 1)
            guard window.count >= WavPackHeader.length else { return nil }
            let candidates = window.count - WavPackHeader.length + 1
            for index in 0..<candidates where window[index] == 0x77 {
                if let header = WavPackHeader(window, at: index) { return (header, position + index) }
            }
            position += candidates
            skipped += candidates
        }
        return nil
    }

    /// The next block of `bytes` at or after `offset`, whole, with its
    /// header; `offset` moves past it. Nil when no block follows.
    /// - Throws: `OwnAudioError.truncated` when the file ends inside it.
    private static func readBlock(
        in bytes: OwnAudioBytes,
        from offset: inout Int
    ) throws -> (header: WavPackHeader, block: [UInt8])? {
        guard let found = nextHeader(in: bytes, from: offset) else { return nil }
        let block = try bytes.read(at: found.offset, count: found.header.blockBytes)
        offset = found.offset + found.header.blockBytes
        return (found.header, block)
    }

    /// The index of the frame after the last one in `bytes`, from the
    /// headers of every block from `offset` on, each read without its
    /// body; nil when no block there holds audio.
    private static func finalIndex(in bytes: OwnAudioBytes, from offset: Int) -> Int64? {
        var position = offset
        var final: Int64?
        // Every block is at least 32 bytes, so the file's size bounds the loop.
        while let found = nextHeader(in: bytes, from: position) {
            if found.header.blockSamples > 0 { final = found.header.blockIndex + Int64(found.header.blockSamples) }
            position = found.offset + found.header.blockBytes
        }
        return final
    }

    /// Where a block stands in its stretch of channels: -1 for the first,
    /// 1 for the last, 0 for one between or one that is both.
    private static func place(of header: WavPackHeader) -> Int {
        (header.flags & WavPackFlags.finalBlock != 0 ? 1 : 0) - (header.flags & WavPackFlags.initialBlock != 0 ? 1 : 0)
    }

    /// The correction file's block for the same frames and channels as
    /// the block with `header`. Blocks before it are passed over.
    /// - Throws: `OwnAudioError.damaged` when the correction file has no
    ///   such block, and `.truncated` when it ends first.
    private mutating func correctionBlock(matching header: WavPackHeader) throws -> (header: WavPackHeader, block: [UInt8]) {
        guard let correction else { throw OwnAudioError.damaged }
        // Each turn reads one block of the correction file, whose size bounds the loop.
        while true {
            guard let read = try Self.readBlock(in: correction, from: &correctionOffset) else {
                throw OwnAudioError.truncated
            }
            let candidate = read.header
            guard candidate.blockSamples > 0 else { continue }
            if candidate.blockIndex == header.blockIndex, candidate.blockSamples == header.blockSamples {
                if candidate.flags == header.flags { return read }
                // The same frames, another block of the stretch: an earlier one is passed over.
                if Self.place(of: candidate) < Self.place(of: header) { continue }
                throw OwnAudioError.damaged
            }
            guard candidate.blockIndex < header.blockIndex else { throw OwnAudioError.damaged }
        }
    }

    // MARK: - Decoding

    mutating func nextBlock() throws -> [Int32]? {
        guard delivered < stream.frames else { return nil }
        // The next block with audio; blocks of metadata alone are passed over.
        var current: (header: WavPackHeader, block: [UInt8])
        repeat {
            guard let read = try Self.readBlock(in: bytes, from: &offset) else { throw OwnAudioError.truncated }
            current = read
        } while current.header.blockSamples == 0
        let first = current.header
        guard first.flags & WavPackFlags.initialBlock != 0,
              first.blockIndex - initialIndex == Int64(delivered) else { throw OwnAudioError.damaged }

        let frames = first.blockSamples
        let channels = stream.channels
        var output = [Int32](repeating: 0, count: frames * channels)
        var filled = 0
        // One block for each channel or pair of channels, from the initial one to the final one.
        while true {
            var decoder = try WavPackBlockDecoder(
                block: current.block, header: current.header, verifiesChecksums: verifiesChecksums)
            if correction != nil {
                // Whatever is wrong in finding or reading the correction
                // file's block is that file's fault, and is said so.
                do {
                    let matching = try correctionBlock(matching: current.header)
                    try decoder.addCorrection(
                        block: matching.block, header: matching.header, verifiesChecksums: verifiesChecksums)
                } catch is OwnAudioError {
                    throw OwnAudioError.companionDamaged
                }
            }
            let samples = try decoder.unpack(verifiesChecksums: verifiesChecksums)
            let blockChannels = current.header.channels
            guard filled + blockChannels <= channels, samples.count == frames * blockChannels else {
                throw OwnAudioError.damaged
            }
            for frame in 0..<frames {
                for channel in 0..<blockChannels {
                    output[frame * channels + filled + channel] = samples[frame * blockChannels + channel]
                }
            }
            filled += blockChannels
            if current.header.flags & WavPackFlags.finalBlock != 0 { break }
            guard let next = try Self.readBlock(in: bytes, from: &offset), next.header.blockSamples == frames,
                  next.header.blockIndex == first.blockIndex,
                  next.header.flags & WavPackFlags.initialBlock == 0 else { throw OwnAudioError.damaged }
            current = next
        }
        guard filled == channels else { throw OwnAudioError.damaged }
        // A block's samples come back as wide as their bytes, as libwavpack
        // gives them: the shift is taken out again, which loses nothing (the
        // bits it drops are the zeros the unpacking put in), so every sample
        // is `stream.bitsPerSample` wide, as the other readers' are.
        if headerShift != 0 {
            for index in output.indices { output[index] >>= headerShift }
        }

        // No more is handed over than the header promised.
        let kept = min(frames, stream.frames - delivered)
        if kept < frames { output.removeLast((frames - kept) * channels) }
        delivered += kept
        return output
    }
}
