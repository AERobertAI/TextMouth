import Foundation

// TextMouth's own reader of WavPack files: the prediction that the decoder
// undoes. It follows libwavpack 5.9.0 (unpack.c, decorr_utils.c, and the
// weight macros of wavpack_local.h), Copyright (c) 1998 - 2025 David Bryant,
// under its BSD 3-clause licence (see WavPackBlock.swift).

/// The arithmetic every prediction pass shares. Each line gives the same
/// 32-bit result as the format's own decoder for every input, wrapping
/// where that wraps, since an encoder counts on it.
enum WavPackWeight {
    /// The most a weight between the two channels may reach.
    static let clip: Int32 = 1_024

    /// `sample` scaled by `weight` over 1,024, rounded: a short product for
    /// a sample of 16 bits, and one in two halves, which cannot overflow,
    /// for a wider one.
    @inline(__always)
    static func apply(_ weight: Int32, _ sample: Int32) -> Int32 {
        if sample == Int32(Int16(truncatingIfNeeded: sample)) {
            return (weight &* sample &+ 512) >> 10
        }
        return ((((sample & 0xFFFF) &* weight) >> 9) &+ (((sample & ~0xFFFF) >> 9) &* weight) &+ 1) >> 1
    }

    /// Moves `weight` by `delta` towards agreement: up when the predicted
    /// sample and the residual have the same sign, down when they differ,
    /// and not at all when either is zero.
    @inline(__always)
    static func update(_ weight: inout Int32, delta: Int32, source: Int32, result: Int32) {
        guard source != 0, result != 0 else { return }
        let sign = (source ^ result) >> 31
        weight = (delta ^ sign) &+ (weight &- sign)
    }

    /// As `update`, for a weight between the two channels, which is held
    /// inside -1,024 to 1,024.
    @inline(__always)
    static func updateClipped(_ weight: inout Int32, delta: Int32, source: Int32, result: Int32) {
        guard source != 0, result != 0 else { return }
        let sign = (source ^ result) >> 31
        var moved = (weight ^ sign) &+ (delta &- sign)
        if moved > clip { moved = clip }
        weight = (moved ^ sign) &- sign
    }
}

/// One prediction pass of a block: which earlier samples it predicts from
/// (its term), how fast its weights adapt (its delta), the weights, and
/// the samples it starts from.
struct WavPackDecorrelationPass {
    /// The most passes a block has, and the longest history a pass keeps.
    static let maximumPasses = 16
    static let historyLength = 8

    /// 1 to 8: the sample that many back. 17 and 18: a line through the
    /// last two. -1 to -3: the other channel.
    var term: Int32 = 0
    var delta: Int32 = 0
    var weightA: Int32 = 0
    var weightB: Int32 = 0
    var samplesA = [Int32](repeating: 0, count: historyLength)
    var samplesB = [Int32](repeating: 0, count: historyLength)

    /// Whether `term` is one the format defines for a block of `isMono`
    /// data: a mono block has no other channel to predict from.
    static func isValid(term: Int32, isMono: Bool) -> Bool {
        switch term {
        case 1...8, 17, 18: return true
        case -3 ... -1: return !isMono
        default: return false
        }
    }

    /// The prediction of terms 17 and 18 from the last two samples: the
    /// line through them carried on one step (17), or half a step (18).
    @inline(__always)
    static func extrapolated(term: Int32, _ last: Int32, _ before: Int32) -> Int32 {
        term & 1 != 0 ? 2 &* last &- before : (3 &* last &- before) >> 1
    }

    /// The same prediction as the format's decoder writes it for a stereo
    /// block that is decoded a pass at a time: term 18 as the last sample
    /// plus half its rise. The two forms agree wherever nothing wraps.
    @inline(__always)
    static func extrapolatedInStereoPass(term: Int32, _ last: Int32, _ before: Int32) -> Int32 {
        term & 1 != 0 ? 2 &* last &- before : last &+ ((last &- before) >> 1)
    }

    /// Undoes this pass over `buffer`, the residuals of a mono block,
    /// which become samples.
    mutating func undoMono(_ buffer: UnsafeMutableBufferPointer<Int32>) {
        var weight = weightA
        let delta = self.delta
        let term = self.term
        samplesA.withUnsafeMutableBufferPointer { history in
            if term > 8 {
                for index in 0..<buffer.count {
                    let predicted = Self.extrapolated(term: term, history[0], history[1])
                    history[1] = history[0]
                    let residual = buffer[index]
                    history[0] = WavPackWeight.apply(weight, predicted) &+ residual
                    WavPackWeight.update(&weight, delta: delta, source: predicted, result: residual)
                    buffer[index] = history[0]
                }
            } else {
                // The history is a ring: the sample `term` back is read where a new one is written.
                var read = 0
                var write = Int(term) & 7
                for index in 0..<buffer.count {
                    let predicted = history[read]
                    let residual = buffer[index]
                    history[write] = WavPackWeight.apply(weight, predicted) &+ residual
                    WavPackWeight.update(&weight, delta: delta, source: predicted, result: residual)
                    buffer[index] = history[write]
                    read = (read + 1) & 7
                    write = (write + 1) & 7
                }
            }
        }
        weightA = weight
    }

    /// Undoes this pass over `buffer`, the residuals of a stereo block,
    /// left and right in turn.
    mutating func undoStereo(_ buffer: UnsafeMutableBufferPointer<Int32>) {
        var weightA = self.weightA
        var weightB = self.weightB
        let delta = self.delta
        let term = self.term
        let frames = buffer.count / 2
        samplesA.withUnsafeMutableBufferPointer { historyA in
            samplesB.withUnsafeMutableBufferPointer { historyB in
                switch term {
                case 17, 18:
                    for frame in 0..<frames {
                        var predicted = Self.extrapolatedInStereoPass(term: term, historyA[0], historyA[1])
                        historyA[1] = historyA[0]
                        var residual = buffer[frame * 2]
                        historyA[0] = WavPackWeight.apply(weightA, predicted) &+ residual
                        WavPackWeight.update(&weightA, delta: delta, source: predicted, result: residual)
                        buffer[frame * 2] = historyA[0]
                        predicted = Self.extrapolatedInStereoPass(term: term, historyB[0], historyB[1])
                        historyB[1] = historyB[0]
                        residual = buffer[frame * 2 + 1]
                        historyB[0] = WavPackWeight.apply(weightB, predicted) &+ residual
                        WavPackWeight.update(&weightB, delta: delta, source: predicted, result: residual)
                        buffer[frame * 2 + 1] = historyB[0]
                    }
                case -1:
                    // The left from the last right, then the right from that left.
                    for frame in 0..<frames {
                        let left = buffer[frame * 2] &+ WavPackWeight.apply(weightA, historyA[0])
                        WavPackWeight.updateClipped(&weightA, delta: delta, source: historyA[0], result: buffer[frame * 2])
                        buffer[frame * 2] = left
                        historyA[0] = buffer[frame * 2 + 1] &+ WavPackWeight.apply(weightB, left)
                        WavPackWeight.updateClipped(&weightB, delta: delta, source: left, result: buffer[frame * 2 + 1])
                        buffer[frame * 2 + 1] = historyA[0]
                    }
                case -2:
                    // The right from the last left, then the left from that right.
                    for frame in 0..<frames {
                        let right = buffer[frame * 2 + 1] &+ WavPackWeight.apply(weightB, historyB[0])
                        WavPackWeight.updateClipped(&weightB, delta: delta, source: historyB[0], result: buffer[frame * 2 + 1])
                        buffer[frame * 2 + 1] = right
                        historyB[0] = buffer[frame * 2] &+ WavPackWeight.apply(weightA, right)
                        WavPackWeight.updateClipped(&weightA, delta: delta, source: right, result: buffer[frame * 2])
                        buffer[frame * 2] = historyB[0]
                    }
                case -3:
                    // Each channel from the other's last sample.
                    for frame in 0..<frames {
                        let left = buffer[frame * 2] &+ WavPackWeight.apply(weightA, historyA[0])
                        WavPackWeight.updateClipped(&weightA, delta: delta, source: historyA[0], result: buffer[frame * 2])
                        let right = buffer[frame * 2 + 1] &+ WavPackWeight.apply(weightB, historyB[0])
                        WavPackWeight.updateClipped(&weightB, delta: delta, source: historyB[0], result: buffer[frame * 2 + 1])
                        historyB[0] = left
                        buffer[frame * 2] = left
                        historyA[0] = right
                        buffer[frame * 2 + 1] = right
                    }
                default:
                    var read = 0
                    var write = Int(term) & 7
                    for frame in 0..<frames {
                        var predicted = historyA[read]
                        var residual = buffer[frame * 2]
                        historyA[write] = WavPackWeight.apply(weightA, predicted) &+ residual
                        WavPackWeight.update(&weightA, delta: delta, source: predicted, result: residual)
                        buffer[frame * 2] = historyA[write]
                        predicted = historyB[read]
                        residual = buffer[frame * 2 + 1]
                        historyB[write] = WavPackWeight.apply(weightB, predicted) &+ residual
                        WavPackWeight.update(&weightB, delta: delta, source: predicted, result: residual)
                        buffer[frame * 2 + 1] = historyB[write]
                        read = (read + 1) & 7
                        write = (write + 1) & 7
                    }
                }
            }
        }
        self.weightA = weightA
        self.weightB = weightB
    }
}
