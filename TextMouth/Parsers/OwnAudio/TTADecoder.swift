import Foundation

// TextMouth's own reader of True Audio (TTA1) files.
//
// The decoding follows the TTA Hardware Players Library 1.2 (ttadec.c and
// filter.h), Copyright (c) 2004 True Audio Software (Alexander Djourik and
// Pavel Zhilin), used under its BSD 3-clause licence, whose notice the app
// bundles (Licenses/TrueAudio). The file layout is the public TTA1 format
// description (tta.sourceforge.net/en/tta-format-description). No code of
// libtta 2.x or of FFmpeg was read.

/// Reads the bits of one True Audio frame, least significant bit first.
struct TTABitReader {
    /// The frame's bytes, and where its audio ends inside them.
    private let bytes: [UInt8]
    private let end: Int
    /// The next byte to take.
    private var position: Int
    /// The bits taken from the bytes and not yet used, lowest first.
    private var cache: UInt64 = 0
    /// How many bits the cache holds.
    private var count = 0

    /// The longest run of 1 bits a residual may start with. Real audio
    /// stays far below it; a longer run is a damaged frame.
    static let maximumUnary: UInt32 = 1 << 20

    /// A reader of `bytes[range]`; the range must lie inside the bytes.
    init(_ bytes: [UInt8], in range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    /// Tops the cache up while bytes remain and a whole byte fits.
    private mutating func refill() {
        while count <= 56, position < end {
            cache |= UInt64(bytes[position]) << UInt64(count)
            position += 1
            count += 8
        }
    }

    /// The number of 1 bits before the next 0 bit, which is used up too.
    /// - Throws: `OwnAudioError.truncated` when the bits end first, and
    ///   `.damaged` for a run past `maximumUnary`.
    mutating func unary() throws -> UInt32 {
        var value: UInt32 = 0
        while true {
            if count < 32 { refill() }
            if count == 0 { throw OwnAudioError.truncated }
            let ones = (~cache).trailingZeroBitCount
            if ones < count {
                cache >>= UInt64(ones + 1)
                count -= ones + 1
                value &+= UInt32(ones)
                guard value <= Self.maximumUnary else { throw OwnAudioError.damaged }
                return value
            }
            // Every bit held is a 1: count them all and read on.
            value &+= UInt32(count)
            cache = 0
            count = 0
            guard value <= Self.maximumUnary else { throw OwnAudioError.damaged }
        }
    }

    /// The next `bits` bits (at most 24) as a number.
    /// - Throws: `OwnAudioError.truncated` when the bits end first.
    mutating func binary(_ bits: UInt32) throws -> UInt32 {
        if count < Int(bits) { refill() }
        guard count >= Int(bits), bits <= 24 else { throw OwnAudioError.truncated }
        let value = UInt32(truncatingIfNeeded: cache) & ((1 << bits) &- 1)
        cache >>= UInt64(bits)
        count -= Int(bits)
        return value
    }
}

/// One channel's state inside a True Audio frame: the adaptive Rice coder's
/// two parameters and sums, the adaptive filter of order 8, and the last
/// sample for the fixed first-order predictor. A frame starts from a fresh
/// state, so any frame decodes alone.
struct TTAChannelState {
    /// The Rice parameters of a plain and of an escaped residual.
    var k0: UInt32 = 10
    var k1: UInt32 = 10
    /// The running sums the parameters follow.
    var sum0: UInt32 = 1 << 14
    var sum1: UInt32 = 1 << 14
    /// The filter's shift and its rounding term, set by the sample width.
    let shift: Int32
    let round: Int32
    /// The last residual, whose sign steers the weights.
    var error: Int32 = 0
    /// The filter's weights, steps, and history. Each has nine entries: the
    /// ninth is the current sample's, shifted down after it is used.
    var weights = [Int32](repeating: 0, count: 9)
    var steps = [Int32](repeating: 0, count: 9)
    var history = [Int32](repeating: 0, count: 9)
    /// The last sample this channel gave.
    var last: Int32 = 0

    /// A fresh state for samples of `byteSize` bytes (1, 2, or 3).
    init(byteSize: Int) {
        shift = byteSize == 2 ? 9 : 10
        round = 1 << (shift - 1)
    }

    /// The adaptive filter: `residual` plus the filter's prediction, with
    /// the weights and the history moved on.
    mutating func filter(_ residual: Int32) -> Int32 {
        var sum = round
        let error = self.error
        let shift = self.shift
        var output: Int32 = 0
        weights.withUnsafeMutableBufferPointer { weights in
            steps.withUnsafeMutableBufferPointer { steps in
                history.withUnsafeMutableBufferPointer { history in
                    // The weights move by the steps, the way the last error points.
                    if error < 0 {
                        for index in 0..<8 { weights[index] &-= steps[index] }
                    } else if error > 0 {
                        for index in 0..<8 { weights[index] &+= steps[index] }
                    }
                    for index in 0..<8 { sum &+= history[index] &* weights[index] }
                    steps[8] = ((history[7] >> 30) | 1) << 2
                    steps[7] = ((history[6] >> 30) | 1) << 1
                    steps[6] = ((history[5] >> 30) | 1) << 1
                    steps[5] = (history[4] >> 30) | 1
                    output = residual &+ (sum >> shift)
                    history[8] = output
                    history[7] = history[8] &- history[7]
                    history[6] = history[7] &- history[6]
                    history[5] = history[6] &- history[5]
                    for index in 0..<8 {
                        history[index] = history[index + 1]
                        steps[index] = steps[index + 1]
                    }
                }
            }
        }
        self.error = residual
        return output
    }

    /// The next residual of this channel, read from `reader` with the
    /// adaptive Rice code: a unary part, then `k` binary bits; a code that
    /// starts with a 1 bit is an escaped one, coded with the second
    /// parameter above the first one's range.
    /// - Throws: `OwnAudioError` when the bits end or hold no audio.
    mutating func residual(from reader: inout TTABitReader) throws -> Int32 {
        var unary = try reader.unary()
        let escaped = unary != 0
        if escaped { unary -= 1 }
        let k = escaped ? k1 : k0
        var value = unary
        if k != 0 { value = (unary << k) &+ (try reader.binary(k)) }
        if escaped {
            sum1 &+= value &- (sum1 >> 4)
            if k1 > 0, sum1 < UInt32(1) << (k1 + 4) {
                k1 -= 1
            } else if k1 < 24, sum1 > UInt32(1) << (k1 + 5) {
                k1 += 1
            }
            value &+= UInt32(1) << k0
        }
        sum0 &+= value &- (sum0 >> 4)
        if k0 > 0, sum0 < UInt32(1) << (k0 + 4) {
            k0 -= 1
        } else if k0 < 24, sum0 > UInt32(1) << (k0 + 5) {
            k0 += 1
        }
        // Odd codes are positive residuals, even ones negative or zero.
        let signed = Int32(bitPattern: value)
        return signed & 1 != 0 ? (signed &+ 1) >> 1 : (0 &- signed) >> 1
    }
}

/// TextMouth's own True Audio decoder: 8 to 24 bits, one to eight channels,
/// any sample rate. A password-protected file (format 2) is refused.
struct TTADecoder: OwnAudioDecoder {
    /// The four bytes a TTA1 file's header starts with.
    static let signature = "TTA1"
    /// The header's length: the signature, five fields, and their CRC.
    static let headerLength = 22
    /// The most channels read; the format's own tools write up to six.
    static let maximumChannels = 8
    /// The highest sample rate read, in hertz.
    static let maximumSampleRate = 768_000

    let stream: OwnAudioStream

    /// The file, and whether each checksum in it is verified. Only the
    /// fuzzers turn that off, so that changed bytes reach the decoder.
    private let bytes: OwnAudioBytes
    private let verifiesChecksums: Bool
    /// Each frame's length in bytes, from the seek table.
    private let frameLengths: [UInt32]
    /// How many frames of audio one True Audio frame holds: 256/245 of a
    /// second, the last one fewer.
    private let framesPerBlock: Int
    /// The bytes of one sample: 1, 2, or 3.
    private let byteSize: Int
    /// The next frame to decode, where it starts in the file, and the
    /// frames of audio still to hand over.
    private var nextFrame = 0
    private var offset: Int
    private var remaining: Int

    /// Opens `bytes` as a True Audio file, reading its header and seek
    /// table. An ID3v2 tag ahead of the header is passed over.
    /// - Throws: `OwnAudioError`.
    init(_ bytes: OwnAudioBytes, verifiesChecksums: Bool = true) throws {
        let start = OwnAudioLeadingTag.id3v2Length(in: bytes.readUpTo(at: 0, count: 10))
        let header = bytes.readUpTo(at: start, count: Self.headerLength)
        guard header.count == Self.headerLength, OwnAudioLittleEndian.holds(header, Self.signature, at: 0),
              let format = OwnAudioLittleEndian.uint16(header, 4),
              let channels = OwnAudioLittleEndian.uint16(header, 6),
              let bits = OwnAudioLittleEndian.uint16(header, 8),
              let rate = OwnAudioLittleEndian.uint32(header, 10),
              let length = OwnAudioLittleEndian.uint32(header, 14),
              let headerCRC = OwnAudioLittleEndian.uint32(header, 18) else {
            throw OwnAudioError.notThisFormat
        }
        if verifiesChecksums, OwnAudioCRC32.checksum(header, in: 0..<18) != headerCRC {
            throw OwnAudioError.damaged
        }
        // Format 1 is whole-number PCM; 2 is the password-protected form.
        guard format == 1 else {
            throw OwnAudioError.unsupported(reason: format == 2 ? OwnAudioWording.ttaPassword : OwnAudioWording.ttaForm)
        }
        guard (1...Self.maximumChannels).contains(Int(channels)), (8...24).contains(Int(bits)),
              (1...Self.maximumSampleRate).contains(Int(rate)) else {
            throw OwnAudioError.unsupported(reason: OwnAudioWording.ttaShape)
        }
        guard length > 0 else { throw OwnAudioError.damaged }
        stream = OwnAudioStream(
            sampleRate: Int(rate), channels: Int(channels), bitsPerSample: Int(bits), frames: Int(length)
        )
        byteSize = (Int(bits) + 7) / 8
        framesPerBlock = 256 * Int(rate) / 245
        let frameCount = (Int(length) + framesPerBlock - 1) / framesPerBlock

        // The seek table: each frame's length, then the table's own CRC. It
        // must lie inside the file before any of it is read, so a header
        // that promises a huge file costs no memory.
        let tableStart = start + Self.headerLength
        let tableLength = frameCount * 4
        let table = try bytes.read(at: tableStart, count: tableLength + 4)
        if verifiesChecksums,
           OwnAudioCRC32.checksum(table, in: 0..<tableLength) != OwnAudioLittleEndian.uint32(table, tableLength) {
            throw OwnAudioError.damaged
        }
        frameLengths = (0..<frameCount).map { OwnAudioLittleEndian.uint32(table, $0 * 4) ?? 0 }
        self.bytes = bytes
        self.verifiesChecksums = verifiesChecksums
        offset = tableStart + tableLength + 4
        remaining = Int(length)
    }

    /// The most bytes a frame of `frames` frames may take: twice its
    /// samples' own size, and 8 kB a channel for the long codes a frame can
    /// start with while its Rice parameters still adapt. An adaptive Rice
    /// code never grows audio far past its own size, so a longer frame is
    /// damage, and refusing it keeps a crafted table from asking for the
    /// whole file at once.
    private func maximumFrameBytes(holding frames: Int) -> Int {
        frames * stream.channels * byteSize * 2 + stream.channels * 8_192 + 1_024
    }

    mutating func nextBlock() throws -> [Int32]? {
        guard remaining > 0, nextFrame < frameLengths.count else { return nil }
        let frames = min(framesPerBlock, remaining)
        let length = Int(frameLengths[nextFrame])
        // Every sample takes at least one bit, so a frame too short for its
        // samples is damage, found before any room is made for them.
        guard length >= 4, length <= maximumFrameBytes(holding: frames),
              (length - 4) * 8 >= frames * stream.channels else { throw OwnAudioError.damaged }
        let frame = try bytes.read(at: offset, count: length)
        if verifiesChecksums,
           OwnAudioCRC32.checksum(frame, in: 0..<length - 4) != OwnAudioLittleEndian.uint32(frame, length - 4) {
            throw OwnAudioError.damaged
        }
        let block = try decode(frame, frames: frames)
        nextFrame += 1
        offset += length
        remaining -= frames
        return block
    }

    /// The `frames` frames of audio in `frame`, one True Audio frame whose
    /// last four bytes are its CRC, interleaved by channel.
    private func decode(_ frame: [UInt8], frames: Int) throws -> [Int32] {
        let channels = stream.channels
        var reader = TTABitReader(frame, in: 0..<frame.count - 4)
        var states = [TTAChannelState](repeating: TTAChannelState(byteSize: byteSize), count: channels)
        // The fixed predictor keeps 15/16 of the last sample at 8 bits, and 31/32 above.
        let predictorShift: Int64 = byteSize == 1 ? 4 : 5
        var output = [Int32](repeating: 0, count: frames * channels)
        try output.withUnsafeMutableBufferPointer { output in
            try states.withUnsafeMutableBufferPointer { states in
                for frame in 0..<frames {
                    let base = frame * channels
                    for channel in 0..<channels {
                        let residual = try states[channel].residual(from: &reader)
                        var sample = states[channel].filter(residual)
                        let last = Int64(states[channel].last)
                        sample &+= Int32(truncatingIfNeeded: ((last << predictorShift) - last) >> predictorShift)
                        states[channel].last = sample
                        output[base + channel] = sample
                    }
                    // Channels are stored as differences from their neighbours.
                    if channels > 1 {
                        let top = base + channels - 1
                        output[top] &+= output[top - 1] / 2
                        for index in stride(from: top - 1, through: base, by: -1) {
                            output[index] = output[index + 1] &- output[index]
                        }
                    }
                }
            }
        }
        return output
    }
}
