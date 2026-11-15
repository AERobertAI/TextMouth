import Foundation

/// The arithmetic between one of TextMouth's own audio readers and the
/// encoder that writes its samples: floating-point samples made whole
/// numbers, more than two channels mixed to stereo, and samples packed
/// into the bytes the encoder takes. Pure functions of their numbers, with
/// nothing that can trap on any sample.
enum OwnAudioSamples {
    /// The bits floating-point samples become: 24, the depth TextMouth
    /// writes for every floating-point source.
    static let bitsForFloats = 24

    /// `block`, the bit patterns of 32-bit floats from -1 to 1, as signed
    /// 24-bit whole numbers: scaled, rounded, and held inside the range. A
    /// sample that is not a number becomes silence.
    static func wholeNumbers(fromFloats block: [Int32]) -> [Int32] {
        let scale = Float(1 << (bitsForFloats - 1))
        return block.map { pattern in
            let value = Float(bitPattern: UInt32(bitPattern: pattern)) * scale
            guard value.isFinite else { return value.isNaN ? 0 : (value < 0 ? -(1 << 23) : (1 << 23) - 1) }
            return Int32(max(-scale, min(scale - 1, value.rounded())))
        }
    }

    /// How much of each channel goes to the left and to the right ear in a
    /// stereo mix, by the channel's bit in a WAVE channel mask: front left
    /// and right keep their sides, the centre and anything overhead go to
    /// both 3 dB down, the back and side pairs keep their sides 3 dB down,
    /// and the low-frequency channel is left out, as the ITU mix leaves it.
    static func stereoGains(forSpeakerBit bit: Int) -> (left: Double, right: Double) {
        let down = 0.5.squareRoot()
        switch bit {
        case 0: return (1, 0)          // front left
        case 1: return (0, 1)          // front right
        case 2: return (down, down)    // front centre
        case 3: return (0, 0)          // low frequency
        case 4, 9: return (down, 0)    // back left, side left
        case 5, 10: return (0, down)   // back right, side right
        case 6: return (0.866, 0.5)    // front left of centre
        case 7: return (0.5, 0.866)    // front right of centre
        default: return (0.5, 0.5)     // back centre and the speakers overhead
        }
    }

    /// The left and right gains of each of `channels` channels laid out as
    /// `mask` says (its set bits, lowest first, name the channels in
    /// order; a channel past the mask's bits goes to both ears), scaled so
    /// that neither ear can clip: each side's gains sum to at most 1.
    static func stereoGains(channels: Int, mask: UInt32) -> [(left: Double, right: Double)] {
        let bits = (0..<32).filter { mask & (UInt32(1) << UInt32($0)) != 0 }
        var gains = (0..<max(channels, 0)).map { index in
            index < bits.count ? stereoGains(forSpeakerBit: bits[index]) : (left: 0.5, right: 0.5)
        }
        let loudest = max(gains.reduce(0) { $0 + $1.left }, gains.reduce(0) { $0 + $1.right }, 1)
        for index in gains.indices {
            gains[index].left /= loudest
            gains[index].right /= loudest
        }
        return gains
    }

    /// `block`, frames of `gains.count` channels, mixed to stereo by
    /// `gains` (`stereoGains(channels:mask:)`), each sum rounded to a whole
    /// number. A block that is not whole frames loses its last part frame.
    static func stereo(_ block: [Int32], gains: [(left: Double, right: Double)]) -> [Int32] {
        let channels = gains.count
        guard channels > 0 else { return [] }
        let frames = block.count / channels
        var mixed = [Int32](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            var left = 0.0, right = 0.0
            for channel in 0..<channels {
                let sample = Double(block[frame * channels + channel])
                left += sample * gains[channel].left
                right += sample * gains[channel].right
            }
            mixed[frame * 2] = Int32(clamping: Int64(left.rounded()))
            mixed[frame * 2 + 1] = Int32(clamping: Int64(right.rounded()))
        }
        return mixed
    }

    /// `block`, samples of `bits` bits, as the little-endian bytes of
    /// whole numbers `container` bits wide (16 or 32), each sample moved up
    /// to the container's top bits, so a 20-bit sample in 32 bits keeps its
    /// value in the upper 20. A sample wider than its `bits` (only a
    /// damaged file gives one) loses its upper bits rather than trapping.
    static func packed(_ block: [Int32], bits: Int, container: Int) -> [UInt8] {
        let shift = Int32(max(container - bits, 0))
        var bytes = [UInt8]()
        bytes.reserveCapacity(block.count * container / 8)
        for sample in block {
            let moved = sample << shift
            bytes.append(UInt8(truncatingIfNeeded: moved))
            bytes.append(UInt8(truncatingIfNeeded: moved >> 8))
            if container == 32 {
                bytes.append(UInt8(truncatingIfNeeded: moved >> 16))
                bytes.append(UInt8(truncatingIfNeeded: moved >> 24))
            }
        }
        return bytes
    }
}
