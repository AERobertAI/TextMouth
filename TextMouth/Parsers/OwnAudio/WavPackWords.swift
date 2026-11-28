import Foundation

// TextMouth's own reader of WavPack files: the entropy decoder. It follows
// libwavpack 5.9.0 (read_words.c and entropy_utils.c), Copyright (c) 1998 -
// 2025 David Bryant, under its BSD 3-clause licence (see WavPackBlock.swift).

/// One channel's part of the entropy decoder's state: three medians that
/// split the residuals into zones, each holding 3.5 times fewer than the
/// one before, and, in hybrid mode, the level and the error limit that set
/// how much of each residual the lossy stream keeps.
struct WavPackEntropy {
    var median0: UInt32 = 0
    var median1: UInt32 = 0
    var median2: UInt32 = 0
    var slowLevel: UInt32 = 0
    var errorLimit: UInt32 = 0

    /// A median without its four fraction bits, never under 1.
    var zone0: UInt32 { median0 >> 4 &+ 1 }
    var zone1: UInt32 { median1 >> 4 &+ 1 }
    var zone2: UInt32 { median2 >> 4 &+ 1 }

    /// Each median rises when a residual lies above it and falls when one
    /// lies below, so that it settles where two rise for every five that
    /// fall; the three follow at different speeds.
    mutating func raise0() { median0 = median0 &+ ((median0 &+ 128) / 128) &* 5 }
    mutating func lower0() { median0 = median0 &- ((median0 &+ 126) / 128) &* 2 }
    mutating func raise1() { median1 = median1 &+ ((median1 &+ 64) / 64) &* 5 }
    mutating func lower1() { median1 = median1 &- ((median1 &+ 62) / 64) &* 2 }
    mutating func raise2() { median2 = median2 &+ ((median2 &+ 32) / 32) &* 5 }
    mutating func lower2() { median2 = median2 &- ((median2 &+ 30) / 32) &* 2 }

    /// Forgets the medians, as a run of zeros does.
    mutating func clearMedians() {
        median0 = 0
        median1 = 0
        median2 = 0
    }

    /// The range of magnitudes that `ones` 1 bits name, from the medians,
    /// which move as they are used.
    mutating func range(forOnes ones: UInt32) -> (low: UInt32, high: UInt32) {
        var low: UInt32 = 0
        let high: UInt32
        if ones == 0 {
            high = zone0 &- 1
            lower0()
        } else {
            low = zone0
            raise0()
            if ones == 1 {
                high = low &+ zone1 &- 1
                lower1()
            } else {
                low = low &+ zone1
                raise1()
                if ones == 2 {
                    high = low &+ zone2 &- 1
                    lower2()
                } else {
                    low = low &+ (ones &- 2) &* zone2
                    high = low &+ zone2 &- 1
                    raise2()
                }
            }
        }
        return (low, high)
    }
}

/// The entropy decoder of one block: residuals read from the main
/// bitstream, with the hybrid mode's corrections read from the correction
/// bitstream beside it.
struct WavPackWords {
    /// The two channels' states; a mono block uses the first.
    var channel0 = WavPackEntropy()
    var channel1 = WavPackEntropy()
    /// Hybrid mode's bit rate for each channel and how it changes a sample.
    var bitrateDelta: (UInt32, UInt32) = (0, 0)
    var bitrateAccumulator: (UInt32, UInt32) = (0, 0)
    /// A 1 bit carried over from the last code, a run of zeros still to
    /// give, and a 0 bit carried over.
    var holdingOne: UInt32 = 0
    var zerosRun: UInt32 = 0
    var holdingZero = false

    /// The most 1 bits a code starts with before its count is written out
    /// as a number.
    static let limitOnes = 16
    /// The speed of the hybrid mode's level, and its rounding term.
    static let slowLevelShift: UInt32 = 8
    static let slowLevelRound: UInt32 = 1 << 7

    /// A count written as a run of 1 bits that gives its width, then its
    /// bits; nil when the run never ends, which is the stream's end.
    private static func writtenCount(from bits: inout WavPackBits) -> UInt32? {
        var width = bits.ones(upTo: 33)
        guard width < 33 else { return nil }
        if width < 2 { return UInt32(width) }
        var mask: UInt32 = 1
        var value: UInt32 = 0
        // One bit fewer than the width follows; the top bit is always set.
        width -= 1
        while width > 0 {
            if bits.bit() != 0 { value |= mask }
            mask <<= 1
            width -= 1
        }
        return value | mask
    }

    /// How many 1 bits the next code starts with: counted up to
    /// `limitOnes`, and written out as a number past that; nil at the
    /// stream's end.
    private static func onesCount(from bits: inout WavPackBits) -> UInt32? {
        let run = bits.ones(upTo: limitOnes + 1)
        guard run >= limitOnes else { return UInt32(run) }
        guard run == limitOnes, let more = writtenCount(from: &bits) else { return nil }
        return more &+ UInt32(limitOnes)
    }

    /// Fills `buffer` with the residuals of a lossless block, the two
    /// channels of a stereo block taking turns.
    /// - Returns: how many residuals were read; fewer than `buffer.count`
    ///   when the stream ended first.
    mutating func lossless(
        into buffer: UnsafeMutableBufferPointer<Int32>,
        isMono: Bool,
        from bits: inout WavPackBits
    ) -> Int {
        var index = 0
        let count = buffer.count
        while index < count {
            var second = !isMono && index & 1 != 0
            if holdingZero {
                // The 0 bit carried over names the lowest zone.
                holdingZero = false
                let low: UInt32
                if second {
                    low = bits.code(upTo: channel1.zone0 &- 1)
                    channel1.lower0()
                } else {
                    low = bits.code(upTo: channel0.zone0 &- 1)
                    channel0.lower0()
                }
                buffer[index] = Int32(bitPattern: bits.bit() != 0 ? ~low : low)
                index += 1
                if index == count { break }
                second = !isMono && index & 1 != 0
            }
            // With both first medians at their floor, zeros come in counted runs.
            if channel0.median0 < 2, holdingOne == 0, channel1.median0 < 2 {
                if zerosRun != 0 {
                    zerosRun -= 1
                    if zerosRun != 0 {
                        buffer[index] = 0
                        index += 1
                        continue
                    }
                } else {
                    guard let run = Self.writtenCount(from: &bits) else { break }
                    zerosRun = run
                    if zerosRun != 0 {
                        channel0.clearMedians()
                        channel1.clearMedians()
                        buffer[index] = 0
                        index += 1
                        continue
                    }
                }
            }
            guard var ones = Self.onesCount(from: &bits) else { break }
            // Each code's last bit belongs to the next code.
            let carried = holdingOne
            holdingOne = ones & 1
            holdingZero = ones & 1 == 0
            ones = ones >> 1 &+ carried
            let range = second ? channel1.range(forOnes: ones) : channel0.range(forOnes: ones)
            let low = range.low &+ bits.code(upTo: range.high &- range.low)
            buffer[index] = Int32(bitPattern: bits.bit() != 0 ? ~low : low)
            index += 1
        }
        return index
    }

    /// The next residual of channel `channel` (0 or 1) of a hybrid block,
    /// and, when `correction` is an open stream, what must be added to the
    /// lossy value to make it the lossless one; nil at the stream's end.
    mutating func hybrid(
        channel: Int,
        flags: UInt32,
        from bits: inout WavPackBits,
        correction: inout WavPackBits
    ) -> (value: Int32, correction: Int32)? {
        guard bits.isOpen else { return nil }
        let second = channel != 0
        if channel0.median0 & ~1 == 0, !holdingZero, holdingOne == 0, channel1.median0 & ~1 == 0 {
            var isZero = false
            if zerosRun != 0 {
                zerosRun -= 1
                isZero = zerosRun != 0
            } else {
                guard let run = Self.writtenCount(from: &bits) else { return nil }
                zerosRun = run
                if zerosRun != 0 {
                    isZero = true
                    channel0.clearMedians()
                    channel1.clearMedians()
                }
            }
            if isZero {
                decaySlowLevel(second: second)
                return (0, 0)
            }
        }
        var ones: UInt32 = 0
        if holdingZero {
            holdingZero = false
        } else {
            guard let read = Self.onesCount(from: &bits) else { return nil }
            ones = holdingOne != 0 ? read >> 1 &+ 1 : read >> 1
            holdingOne = read & 1
            holdingZero = holdingOne == 0
        }
        if flags & WavPackFlags.hybrid != 0, !second { updateErrorLimits(flags: flags) }

        var range = second ? channel1.range(forOnes: ones) : channel0.range(forOnes: ones)
        range.low &= 0x7FFF_FFFF
        range.high &= 0x7FFF_FFFF
        if range.low > range.high { range.high = range.low }
        var low = range.low
        var high = range.high
        var mid = (high &+ low &+ 1) >> 1
        let limit = second ? channel1.errorLimit : channel0.errorLimit
        if limit == 0 {
            mid = bits.code(upTo: high &- low) &+ low
        } else {
            // Halve the range, a bit at a time, until it is inside the limit.
            while high &- low > limit {
                if bits.bit() != 0 {
                    low = mid
                } else {
                    high = mid &- 1
                }
                mid = (high &+ low &+ 1) >> 1
            }
        }
        let isNegative = bits.bit() != 0
        var difference: Int32 = 0
        if correction.isOpen, limit != 0 {
            let exact = correction.code(upTo: high &- low) &+ low
            difference = Int32(bitPattern: isNegative ? mid &- exact : exact &- mid)
        }
        if flags & WavPackFlags.hybridBitrate != 0 {
            decaySlowLevel(second: second)
            let gain = UInt32(bitPattern: WavPackLog.log2(mid))
            if second {
                channel1.slowLevel = channel1.slowLevel &+ gain
            } else {
                channel0.slowLevel = channel0.slowLevel &+ gain
            }
        }
        return (Int32(bitPattern: isNegative ? ~mid : mid), difference)
    }

    /// Lets one channel's level fall by a 256th.
    private mutating func decaySlowLevel(second: Bool) {
        if second {
            channel1.slowLevel = channel1.slowLevel &- (channel1.slowLevel &+ Self.slowLevelRound) >> Self.slowLevelShift
        } else {
            channel0.slowLevel = channel0.slowLevel &- (channel0.slowLevel &+ Self.slowLevelRound) >> Self.slowLevelShift
        }
    }

    /// The error limit a level and a bit rate give: none when the level is
    /// far below the rate.
    private static func errorLimit(level: Int32, bitrate: Int32) -> UInt32 {
        let above = level &- bitrate
        return above > -0x100 ? UInt32(bitPattern: WavPackLog.exp2(above &+ 0x100)) : 0
    }

    /// Moves the hybrid mode's bit rates on by one sample and sets each
    /// channel's error limit: how far the lossy stream's value may lie
    /// from the residual.
    private mutating func updateErrorLimits(flags: UInt32) {
        bitrateAccumulator.0 = bitrateAccumulator.0 &+ bitrateDelta.0
        var bitrate0 = Int32(bitrateAccumulator.0 >> 16)
        let usesLevels = flags & WavPackFlags.hybridBitrate != 0
        let level0 = Int32(bitPattern: (channel0.slowLevel &+ Self.slowLevelRound) >> Self.slowLevelShift)
        if flags & WavPackFlags.monoData != 0 {
            channel0.errorLimit = usesLevels
                ? Self.errorLimit(level: level0, bitrate: bitrate0) : UInt32(bitPattern: WavPackLog.exp2(bitrate0))
            return
        }
        bitrateAccumulator.1 = bitrateAccumulator.1 &+ bitrateDelta.1
        var bitrate1 = Int32(bitrateAccumulator.1 >> 16)
        guard usesLevels else {
            channel0.errorLimit = UInt32(bitPattern: WavPackLog.exp2(bitrate0))
            channel1.errorLimit = UInt32(bitPattern: WavPackLog.exp2(bitrate1))
            return
        }
        let level1 = Int32(bitPattern: (channel1.slowLevel &+ Self.slowLevelRound) >> Self.slowLevelShift)
        if flags & WavPackFlags.hybridBalance != 0 {
            // The louder channel is given more of the two channels' bits.
            let balance = (level1 &- level0 &+ bitrate1 &+ 1) >> 1
            if balance > bitrate0 {
                bitrate1 = bitrate0 &* 2
                bitrate0 = 0
            } else if 0 &- balance > bitrate0 {
                bitrate0 = bitrate0 &* 2
                bitrate1 = 0
            } else {
                bitrate1 = bitrate0 &+ balance
                bitrate0 = bitrate0 &- balance
            }
        }
        channel0.errorLimit = Self.errorLimit(level: level0, bitrate: bitrate0)
        channel1.errorLimit = Self.errorLimit(level: level1, bitrate: bitrate1)
    }
}
