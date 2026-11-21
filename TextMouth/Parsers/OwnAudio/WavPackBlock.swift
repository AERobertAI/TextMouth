import Foundation

// TextMouth's own reader of WavPack files: the layout of a block.
//
// The WavPack reader (this file and the other WavPack files beside it)
// follows libwavpack 5.9.0, Copyright (c) 1998 - 2025 David Bryant, used
// under its BSD 3-clause licence, whose notice the app bundles
// (Licenses/WavPack), and the public format description in that release
// (doc/WavPack5FileFormat.pdf). No code of FFmpeg was read.

/// The bits of a WavPack block's flags.
enum WavPackFlags {
    /// The bytes a sample was stored in, less one (bits 0 and 1).
    static let bytesStoredMask: UInt32 = 3
    /// The block holds one channel.
    static let mono: UInt32 = 4
    /// Hybrid mode: a lossy stream that a correction stream makes lossless.
    static let hybrid: UInt32 = 8
    /// Stereo stored as a mid and a side channel.
    static let jointStereo: UInt32 = 0x10
    /// Hybrid: the channels are decorrelated across each other.
    static let crossDecorrelation: UInt32 = 0x20
    /// Hybrid: the lossy stream's noise is shaped.
    static let hybridShape: UInt32 = 0x40
    /// The samples are 32-bit floating-point numbers.
    static let floatData: UInt32 = 0x80
    /// The samples are whole numbers handled in two parts (more than 24
    /// bits, or with bits no sample uses).
    static let int32Data: UInt32 = 0x100
    /// Hybrid: the bit rate steers the noise.
    static let hybridBitrate: UInt32 = 0x200
    /// Hybrid stereo: the noise is balanced between the channels.
    static let hybridBalance: UInt32 = 0x400
    /// The first and the last block of the blocks that make one stretch of
    /// every channel.
    static let initialBlock: UInt32 = 0x800
    static let finalBlock: UInt32 = 0x1000
    /// How far every sample is shifted left at the end (five bits).
    static let shiftLSB: UInt32 = 13
    static let shiftMask: UInt32 = 0x1F << 13
    /// The most bits a sample's magnitude takes (five bits).
    static let magnitudeLSB: UInt32 = 18
    static let magnitudeMask: UInt32 = 0x1F << 18
    /// The index of the sample rate (four bits); 15 means it is stored
    /// in the block's metadata.
    static let sampleRateLSB: UInt32 = 23
    static let sampleRateMask: UInt32 = 0xF << 23
    /// The checksum of the block's bytes ends the block.
    static let hasChecksum: UInt32 = 0x1000_0000
    /// Hybrid: negative shaping uses the newer filter.
    static let newShaping: UInt32 = 0x2000_0000
    /// The block is flagged stereo and holds one channel, played in both.
    static let falseStereo: UInt32 = 0x4000_0000
    /// The block holds DSD (one-bit audio), which TextMouth refuses.
    static let dsd: UInt32 = 0x8000_0000
    /// One channel of data: a mono block, or false stereo.
    static let monoData: UInt32 = mono | falseStereo

    /// The sample rates the flags can name by index.
    static let sampleRates = [
        6_000, 8_000, 9_600, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200,
        96_000, 192_000,
    ]
}

/// The 32-byte header every WavPack block starts with.
struct WavPackHeader: Equatable {
    /// The header's length in bytes.
    static let length = 32
    /// The four bytes it starts with.
    static let signature = "wvpk"
    /// The largest block: its size field is under a megabyte.
    static let maximumBlockBytes = 1_048_576 + 8
    /// The stream versions read: 0x402 to 0x410.
    static let versions = 0x402...0x410

    /// The bytes of the whole block, header included.
    let blockBytes: Int
    /// The stream version.
    let version: Int
    /// The index of the block's first frame in the file (40 bits).
    let blockIndex: Int64
    /// The file's length in frames, or nil when the header does not know it.
    let totalFrames: Int64?
    /// The frames in the block; 0 for a block of metadata only.
    let blockSamples: Int
    /// The flags (`WavPackFlags`).
    let flags: UInt32
    /// The checksum of the block's decoded samples.
    let crc: UInt32

    /// The header in `bytes` at `offset`, or nil when the bytes there are
    /// not a header a decoder may trust: the signature, an even size from
    /// 24 bytes to under a megabyte, a version from 0x402 to 0x410, and
    /// fewer than 196,608 frames.
    init?(_ bytes: [UInt8], at offset: Int = 0) {
        guard OwnAudioLittleEndian.holds(bytes, Self.signature, at: offset),
              let size = OwnAudioLittleEndian.uint32(bytes, offset + 4),
              let version = OwnAudioLittleEndian.uint16(bytes, offset + 8),
              let total = OwnAudioLittleEndian.uint32(bytes, offset + 12),
              let index = OwnAudioLittleEndian.uint32(bytes, offset + 16),
              let samples = OwnAudioLittleEndian.uint32(bytes, offset + 20),
              let flags = OwnAudioLittleEndian.uint32(bytes, offset + 24),
              let crc = OwnAudioLittleEndian.uint32(bytes, offset + 28) else { return nil }
        guard size & 1 == 0, size >= 24, size < 1_048_576, Self.versions.contains(Int(version)),
              samples < 0x30000 else { return nil }
        blockBytes = Int(size) + 8
        self.version = Int(version)
        let indexHigh = Int64(bytes[offset + 10])
        let totalHigh = Int64(bytes[offset + 11])
        blockIndex = Int64(index) + indexHigh << 32
        // All ones in the low 32 bits mean the length is not known.
        totalFrames = total == UInt32.max ? nil : Int64(total) + totalHigh << 32 - totalHigh
        blockSamples = Int(samples)
        self.flags = flags
        self.crc = crc
    }

    /// Whether the block holds one channel of data (mono or false stereo).
    var isMonoData: Bool { flags & WavPackFlags.monoData != 0 }
    /// The channels the block gives: one, or two (false stereo included).
    var channels: Int { flags & WavPackFlags.mono != 0 ? 1 : 2 }
}

/// One piece of a block's metadata: its kind and where its bytes are.
struct WavPackMetadata {
    /// The kind: the six low bits of the identifier.
    let id: UInt8
    /// Where the data lies in the block's bytes.
    let range: Range<Int>

    /// The kinds a decoder reads.
    static let decorrelationTerms: UInt8 = 0x02
    static let decorrelationWeights: UInt8 = 0x03
    static let decorrelationSamples: UInt8 = 0x04
    static let entropyVariables: UInt8 = 0x05
    static let hybridProfile: UInt8 = 0x06
    static let shapingWeights: UInt8 = 0x07
    static let floatInfo: UInt8 = 0x08
    static let int32Info: UInt8 = 0x09
    static let mainBitstream: UInt8 = 0x0A
    static let correctionBitstream: UInt8 = 0x0B
    static let extraBitstream: UInt8 = 0x0C
    static let channelInfo: UInt8 = 0x0D
    static let dsdBlock: UInt8 = 0x0E
    /// A kind with this bit may be passed over by a decoder that does not
    /// know it.
    static let optional: UInt8 = 0x20
    static let sampleRate: UInt8 = 0x27
    static let newExtraBitstream: UInt8 = 0x2C
    static let blockChecksum: UInt8 = 0x2F
    /// The identifier's flags: the data is one byte shorter than its
    /// padded length, and the length takes three bytes.
    static let oddSize: UInt8 = 0x40
    static let large: UInt8 = 0x80

    /// The pieces of metadata in `block`, a whole block with its header,
    /// in order, and whether its checksum (when it has one) is right.
    /// - Parameter verifiesChecksum: whether the block's checksum must be
    ///   right; without it only the layout is checked.
    /// - Throws: `OwnAudioError.damaged` when the pieces do not fill the
    ///   block exactly, or the checksum is wrong or missing where the
    ///   flags promise one.
    static func pieces(of block: [UInt8], flags: UInt32, verifiesChecksum: Bool) throws -> [WavPackMetadata] {
        var pieces: [WavPackMetadata] = []
        var position = WavPackHeader.length
        var checksumPassed = false
        // Every piece takes at least two bytes, so the block bounds the loop.
        while block.count - position >= 2 {
            let start = position
            let identifier = block[position]
            var padded = Int(block[position + 1]) << 1
            position += 2
            if identifier & large != 0 {
                guard block.count - position >= 2 else { throw OwnAudioError.damaged }
                padded += Int(block[position]) << 9 + Int(block[position + 1]) << 17
                position += 2
            }
            guard block.count - position >= padded else { throw OwnAudioError.damaged }
            var length = padded
            if identifier & oddSize != 0 {
                guard padded > 0 else { throw OwnAudioError.damaged }
                length -= 1
            }
            let id = identifier & 0x3F
            if id == blockChecksum, verifiesChecksum {
                guard identifier & oddSize == 0, padded == 2 || padded == 4,
                      checksum(of: block, upTo: start, matches: position, length: padded) else {
                    throw OwnAudioError.damaged
                }
                checksumPassed = true
            }
            pieces.append(WavPackMetadata(id: id, range: position..<position + length))
            position += padded
        }
        guard position == block.count else { throw OwnAudioError.damaged }
        if verifiesChecksum, flags & WavPackFlags.hasChecksum != 0, !checksumPassed { throw OwnAudioError.damaged }
        return pieces
    }

    /// Whether the checksum stored in `block` at `position`, `length` (2
    /// or 4) bytes long, is the checksum of the block's bytes before
    /// `end`, taken two at a time as little-endian numbers.
    private static func checksum(of block: [UInt8], upTo end: Int, matches position: Int, length: Int) -> Bool {
        var sum = UInt32.max
        var index = 0
        while index + 1 < end {
            sum = sum &* 3 &+ UInt32(block[index]) &+ UInt32(block[index + 1]) << 8
            index += 2
        }
        if length == 4 { return OwnAudioLittleEndian.uint32(block, position) == sum }
        sum ^= sum >> 16
        return OwnAudioLittleEndian.uint16(block, position) == UInt16(truncatingIfNeeded: sum)
    }
}

/// Reads the bits of one of a block's bitstreams, least significant bit
/// first. Past the stream's end it gives 1 bits, which every code in the
/// format reads as its end.
struct WavPackBits {
    /// The block's bytes, and where the stream ends in them.
    private let bytes: [UInt8]
    private let end: Int
    /// The next byte to take.
    private var position: Int
    /// The bits taken and not yet used, lowest first, and their count.
    private var cache: UInt64 = 0
    private var count = 0
    /// Whether there is a stream at all.
    let isOpen: Bool

    /// No stream: the block has none of this kind.
    init() {
        bytes = []
        end = 0
        position = 0
        isOpen = false
    }

    /// The stream in `bytes[range]`; the range must lie inside the bytes.
    init(_ bytes: [UInt8], in range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
        isOpen = true
    }

    /// Tops the cache up to more than 56 bits, with 1 bits past the end.
    private mutating func refill() {
        while count <= 56 {
            let byte: UInt8
            if position < end {
                byte = bytes[position]
                position += 1
            } else {
                byte = 0xFF
            }
            cache |= UInt64(byte) << UInt64(count)
            count += 8
        }
    }

    /// The next bit.
    mutating func bit() -> UInt32 {
        if count == 0 { refill() }
        let value = UInt32(truncatingIfNeeded: cache) & 1
        cache >>= 1
        count -= 1
        return value
    }

    /// The next `width` bits (0 to 32) as a number, the first bit lowest.
    mutating func bits(_ width: Int) -> UInt32 {
        guard width > 0 else { return 0 }
        let wanted = min(width, 32)
        if count < wanted { refill() }
        let value = UInt32(truncatingIfNeeded: cache & (UInt64(1) << UInt64(wanted) - 1))
        cache >>= UInt64(wanted)
        count -= wanted
        return value
    }

    /// The next `width` bits (0 to 32) without using them up.
    mutating func peek(_ width: Int) -> UInt32 {
        guard width > 0 else { return 0 }
        let wanted = min(width, 32)
        if count < wanted { refill() }
        return UInt32(truncatingIfNeeded: cache & (UInt64(1) << UInt64(wanted) - 1))
    }

    /// Uses up `width` bits (0 to 32) that `peek` showed.
    mutating func skip(_ width: Int) {
        let wanted = min(max(width, 0), 32)
        if count < wanted { refill() }
        cache >>= UInt64(wanted)
        count -= wanted
    }

    /// How many 1 bits come next, up to `limit` of them (at most 33). The
    /// 1 bits are used up, and so is the 0 bit that ends fewer than `limit`.
    mutating func ones(upTo limit: Int) -> Int {
        if count < 40 { refill() }
        let run = min((~cache).trailingZeroBitCount, limit)
        if run < limit {
            cache >>= UInt64(run + 1)
            count -= run + 1
        } else {
            cache >>= UInt64(run)
            count -= run
        }
        return run
    }

    /// A number from 0 to `maximum`, each as likely as the others, in the
    /// fewest bits: a whole number of bits when the count of values is a
    /// power of two, and one bit more for the upper values otherwise.
    mutating func code(upTo maximum: UInt32) -> UInt32 {
        if maximum < 2 { return maximum != 0 ? bit() : 0 }
        let width = WavPackLog.bitCount(maximum)
        let extras = (width == 32 ? 0 : UInt32(1) << UInt32(width)) &- maximum &- 1
        let seen = peek(width)
        var value = seen & (UInt32(1) << UInt32(width - 1) &- 1)
        if value >= extras {
            value = (value << 1) &- extras &+ ((seen >> UInt32(width - 1)) & 1)
            skip(width)
        } else {
            skip(width - 1)
        }
        return value
    }
}
