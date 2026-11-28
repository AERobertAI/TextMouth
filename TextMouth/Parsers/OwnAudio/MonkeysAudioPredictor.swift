import Foundation

// TextMouth's own reader of Monkey's Audio files: the prediction that the
// decoder undoes. It follows the Monkey's Audio SDK 13.47 (NewPredictor.cpp,
// NNFilter.cpp, NNFilterGeneric.cpp, NNFilterCommon.h, RollBuffer.h,
// ScaledFirstOrderFilter.h, Interim.cpp), Copyright 2000-2026 Matthew T.
// Ashland, under its BSD 3-clause licence (see
// MonkeysAudioRangeDecoder.swift).

/// One of the adaptive filters of the compression levels above Fast: a
/// long filter whose weights follow the sign of each residual. It keeps the
/// last samples and their adaptation steps in buffers that roll back to
/// their start when full.
///
/// The arithmetic is the format's own, width for width, since an encoder
/// counts on every wrap: for files of up to 24 bits the samples and weights
/// are 16-bit numbers and the sums 32-bit; for 32-bit files (`isWide`) they
/// are 32-bit numbers and the sums 64-bit. One class serves both by keeping
/// 32-bit storage and narrowing each result to the file's width.
///
/// The buffers are unsafe pointers, for speed in the innermost loop of the
/// decoder; every index into them is made here from the filter's own
/// order, never from a file's bytes.
final class MonkeysAudioFilter {
    /// The samples a buffer holds beyond the filter's order before it rolls.
    private static let window = 512

    /// The filter's length, its output shift, and half of one output step.
    private let order: Int
    private let shift: Int64
    private let rounding: Int64
    /// Whether the file's samples are 32-bit numbers.
    private let isWide: Bool
    /// Whether this is the filter of the "interim" versions, whose sum does
    /// not wrap at 32 bits before it is shifted.
    private let isInterim: Bool
    /// The weights, the saturated samples, and their adaptation steps; the
    /// last two with `order` samples of history before `current`.
    private let weights: UnsafeMutablePointer<Int32>
    private let input: UnsafeMutablePointer<Int32>
    private let delta: UnsafeMutablePointer<Int32>
    private let weights16: UnsafeMutablePointer<Int16>
    private let input16: UnsafeMutablePointer<Int16>
    private let delta16: UnsafeMutablePointer<Int16>
    private var current: Int
    /// The running average of the outputs' sizes, which scales the steps.
    private var runningAverage: Int64 = 0

    /// A filter of `order` weights (16, or a multiple of 32) whose output
    /// is shifted down by `shift` bits.
    init(order: Int, shift: Int, isWide: Bool, isInterim: Bool) {
        self.order = order
        self.shift = Int64(shift)
        rounding = Int64(1) << Int64(shift - 1)
        self.isWide = isWide
        self.isInterim = isInterim
        let length = Self.window + order
        weights = .allocate(capacity: order)
        input = .allocate(capacity: length)
        delta = .allocate(capacity: length)
        weights16 = .allocate(capacity: order)
        input16 = .allocate(capacity: length)
        delta16 = .allocate(capacity: length)
        weights.initialize(repeating: 0, count: order)
        input.initialize(repeating: 0, count: length)
        delta.initialize(repeating: 0, count: length)
        weights16.initialize(repeating: 0, count: order)
        input16.initialize(repeating: 0, count: length)
        delta16.initialize(repeating: 0, count: length)
        current = order
    }

    deinit {
        weights.deallocate()
        input.deallocate()
        delta.deallocate()
        weights16.deallocate()
        input16.deallocate()
        delta16.deallocate()
    }

    /// The state every frame starts from: no weights and no history.
    func reset() {
        weights.update(repeating: 0, count: order)
        weights16.update(repeating: 0, count: order)
        input.update(repeating: 0, count: order + 1)
        delta.update(repeating: 0, count: order + 1)
        input16.update(repeating: 0, count: order + 1)
        delta16.update(repeating: 0, count: order + 1)
        current = order
        runningAverage = 0
    }

    /// `value` held inside a 16-bit number: the nearest end of its range
    /// when it does not fit.
    @inline(__always)
    private static func saturated(_ value: Int64) -> Int16 {
        Int16(exactly: value) ?? (value < 0 ? Int16.min : Int16.max)
    }

    /// Undoes the filter on `residual`: the sample, with the weights moved
    /// by the residual's sign and the history moved on.
    func decompress(_ residual: Int64) -> Int64 {
        let output = isWide ? decompressWide(residual) : decompressNarrow(residual)
        current += 1
        if current == Self.window + order {
            // Roll: the last `order` entries become the history at the start.
            if isWide {
                input.update(from: input + (current - order), count: order)
                delta.update(from: delta + (current - order), count: order)
            } else {
                input16.update(from: input16 + (current - order), count: order)
                delta16.update(from: delta16 + (current - order), count: order)
            }
            current = order
        }
        return output
    }

    /// The adaptation step of an output and the average's move, shared by
    /// both widths: larger for an output far above the running average.
    /// The step's sign is opposite to the output's.
    @inline(__always)
    private func step(for output: Int64) -> Int16 {
        let magnitude = isWide ? (output < 0 ? 0 &- output : output) : Int64(Int32(truncatingIfNeeded: output).magnitude)
        let step: Int16
        if magnitude > runningAverage &* 3 {
            step = Int16(((output >> 25) & 64) - 32)
        } else if magnitude > (runningAverage &* 4) / 3 {
            step = Int16(((output >> 26) & 32) - 16)
        } else if magnitude > 0 {
            step = Int16(((output >> 27) & 16) - 8)
        } else {
            step = 0
        }
        let moved = runningAverage &+ (magnitude &- runningAverage) / 16
        runningAverage = isWide ? moved : Int64(Int32(truncatingIfNeeded: moved))
        return step
    }

    /// The filter for files of up to 24 bits: 16-bit samples and weights,
    /// 32-bit sums.
    private func decompressNarrow(_ residual: Int64) -> Int64 {
        let history = input16 + (current - order)
        let steps = delta16 + (current - order)
        var product: Int32 = 0
        for index in 0..<order {
            product = product &+ Int32(history[index]) &* Int32(weights16[index])
        }
        let input32 = Int32(truncatingIfNeeded: residual)
        let output: Int32
        if isInterim {
            output = Int32(truncatingIfNeeded: Int64(input32) &+ ((Int64(product) &+ rounding) >> shift))
        } else {
            output = input32 &+ ((product &+ Int32(truncatingIfNeeded: rounding)) >> Int32(truncatingIfNeeded: shift))
        }
        // The weights follow the residual's sign.
        if input32 < 0 {
            for index in 0..<order { weights16[index] = weights16[index] &+ steps[index] }
        } else if input32 > 0 {
            for index in 0..<order { weights16[index] = weights16[index] &- steps[index] }
        }
        delta16[current] = step(for: Int64(output))
        delta16[current - 1] >>= 1
        delta16[current - 2] >>= 1
        delta16[current - 8] >>= 1
        input16[current] = Self.saturated(Int64(output))
        return Int64(output)
    }

    /// The filter for 32-bit files: 32-bit samples and weights, 64-bit sums
    /// of products that wrap at 32 bits.
    private func decompressWide(_ residual: Int64) -> Int64 {
        let history = input + (current - order)
        let steps = delta + (current - order)
        var product: Int64 = 0
        for index in 0..<order {
            product = product &+ Int64(history[index] &* weights[index])
        }
        let output = residual &+ ((product &+ rounding) >> shift)
        if residual < 0 {
            for index in 0..<order { weights[index] = weights[index] &+ steps[index] }
        } else if residual > 0 {
            for index in 0..<order { weights[index] = weights[index] &- steps[index] }
        }
        delta[current] = Int32(step(for: output))
        delta[current - 1] >>= 1
        delta[current - 2] >>= 1
        delta[current - 8] >>= 1
        input[current] = Int32(Self.saturated(output))
        return output
    }
}

/// A buffer of the predictor's last few values that rolls back to its start
/// when full: `self[0]` is the newest, `self[-1]` the one before.
private struct MonkeysAudioRollBuffer {
    /// The history kept behind the newest value, and the values written
    /// before the buffer rolls.
    static let history = 8
    static let window = 256

    private var values = [Int64](repeating: 0, count: window + history)
    private var current = history

    subscript(offset: Int) -> Int64 {
        get { values[current + offset] }
        set { values[current + offset] = newValue }
    }

    /// Moves on by one value.
    mutating func advance() { current += 1 }

    /// The last `history` values become the history at the start.
    mutating func roll() {
        for index in 0..<Self.history { values[index] = values[current - Self.history + index] }
        current = Self.history
    }

    /// Forgets everything.
    mutating func reset() {
        for index in 0...Self.history { values[index] = 0 }
        current = Self.history
    }
}

/// One channel's predictor, which turns a residual back into a sample: up
/// to three adaptive filters, by the compression level, then a small
/// adaptive predictor from this channel's last values and the other
/// channel's, then a first-order filter.
///
/// Every sum is narrowed to the file's width exactly where the format's
/// own decoder narrows it (`narrowed`), 32 bits for files of up to 24 bits
/// and 64 bits for 32-bit files.
struct MonkeysAudioPredictor {
    /// Whether the file's samples are 32-bit numbers.
    private let isWide: Bool
    /// The "interim" form: files of 24 bits written by a few versions that
    /// summed without narrowing.
    private let isInterim: Bool
    /// The adaptive filters, undone in this order.
    private let filters: [MonkeysAudioFilter]
    /// This channel's and the other channel's last values, and the signs
    /// that steer the weights.
    private var predictionA = MonkeysAudioRollBuffer()
    private var predictionB = MonkeysAudioRollBuffer()
    private var adaptA = MonkeysAudioRollBuffer()
    private var adaptB = MonkeysAudioRollBuffer()
    /// The weights of this channel's four values and the other's five.
    private var weightsA = [Int64](repeating: 0, count: 4)
    private var weightsB = [Int64](repeating: 0, count: 5)
    private var lastValue: Int64 = 0
    /// The first-order filters' last values, kept as 32-bit numbers.
    private var stage1A: Int32 = 0
    private var stage1B: Int32 = 0
    /// How many values the roll buffers hold since they last rolled.
    private var filled = 0

    /// The compression levels and the filters each uses, last undone first
    /// in the list: (order, shift).
    static func filterShapes(forLevel level: Int) -> [(order: Int, shift: Int)]? {
        switch level {
        case 1_000: return []
        case 2_000: return [(16, 11)]
        case 3_000: return [(64, 11)]
        case 4_000: return [(32, 10), (256, 13)]
        case 5_000: return [(16, 11), (256, 13), (1_280, 15)]
        default: return nil
        }
    }

    /// A predictor for a file of `level` and `bitsPerSample`; nil for a
    /// compression level the format does not define.
    init?(level: Int, bitsPerSample: Int, isInterim: Bool) {
        guard let shapes = Self.filterShapes(forLevel: level) else { return nil }
        let isWide = bitsPerSample >= 32
        self.isWide = isWide
        self.isInterim = isInterim
        filters = shapes.map { MonkeysAudioFilter(order: $0.order, shift: $0.shift, isWide: isWide, isInterim: isInterim) }
        reset()
    }

    /// `value` as the file's width holds it: wrapped to 32 bits unless the
    /// file is 32-bit.
    @inline(__always)
    private func narrowed(_ value: Int64) -> Int64 {
        isWide ? value : Int64(Int32(truncatingIfNeeded: value))
    }

    /// The state every frame starts from.
    mutating func reset() {
        for filter in filters { filter.reset() }
        predictionA.reset()
        predictionB.reset()
        adaptA.reset()
        adaptB.reset()
        weightsA = [360, 317, -109, 98]
        weightsB = [0, 0, 0, 0, 0]
        lastValue = 0
        stage1A = 0
        stage1B = 0
        filled = 0
    }

    /// The sign that steers a weight: 1 for a negative value, -1 for a
    /// positive one, 0 for zero.
    @inline(__always)
    private static func steer(_ value: Int64) -> Int64 {
        value != 0 ? ((value >> 30) & 2) - 1 : 0
    }

    /// The sample that `residual` stands for, given `other`, the other
    /// channel's value for this frame (0 where there is none).
    mutating func decompress(_ residual: Int64, other: Int64 = 0) -> Int32 {
        if filled == MonkeysAudioRollBuffer.window {
            predictionA.roll()
            predictionB.roll()
            adaptA.roll()
            adaptB.roll()
            filled = 0
        }
        var value = narrowed(residual)
        let otherValue = narrowed(other)
        for filter in filters { value = filter.decompress(value) }

        // This channel's last value and its change; the other channel's value, filtered, and its change.
        predictionA[0] = lastValue
        predictionA[-1] = narrowed(predictionA[0] &- predictionA[-1])
        let otherInput = Int32(truncatingIfNeeded: otherValue)
        predictionB[0] = narrowed(Int64(otherInput) &- (narrowed(Int64(stage1B) &* 31) >> 5))
        stage1B = otherInput
        predictionB[-1] = narrowed(predictionB[0] &- predictionB[-1])

        var sumA: Int64 = 0
        for index in 0..<4 { sumA = sumA &+ predictionA[-index] &* weightsA[index] }
        var sumB: Int64 = 0
        for index in 0..<5 { sumB = sumB &+ predictionB[-index] &* weightsB[index] }
        let current: Int64
        if isWide || isInterim {
            // The sums keep their 64 bits until after the shift.
            current = narrowed(value &+ narrowed((sumA &+ (sumB >> 1)) >> 10))
        } else {
            current = narrowed(value &+ (narrowed(narrowed(sumA) &+ (narrowed(sumB) >> 1)) >> 10))
        }

        adaptA[0] = Self.steer(predictionA[0])
        adaptA[-1] = Self.steer(predictionA[-1])
        adaptB[0] = Self.steer(predictionB[0])
        adaptB[-1] = Self.steer(predictionB[-1])
        let direction: Int64 = value < 0 ? 1 : (value > 0 ? -1 : 0)
        for index in 0..<4 { weightsA[index] = narrowed(weightsA[index] &+ adaptA[-index] &* direction) }
        for index in 0..<5 { weightsB[index] = narrowed(weightsB[index] &+ adaptB[-index] &* direction) }

        // The first-order filter: most of the last output is added back.
        stage1A = Int32(truncatingIfNeeded: current &+ (narrowed(Int64(stage1A) &* 31) >> 5))
        lastValue = current
        predictionA.advance()
        predictionB.advance()
        adaptA.advance()
        adaptB.advance()
        filled += 1
        return stage1A
    }
}
