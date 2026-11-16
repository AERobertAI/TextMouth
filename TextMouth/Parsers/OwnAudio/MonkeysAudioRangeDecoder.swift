import Foundation

// TextMouth's own reader of Monkey's Audio files: the range decoder.
//
// The Monkey's Audio reader (this file and the other Monkey's Audio files
// beside it) follows the Monkey's Audio SDK 13.47, Copyright 2000-2026
// Matthew T. Ashland, used under its BSD 3-clause licence, whose notice the
// app bundles (Licenses/MonkeysAudio). The format has no specification: the
// SDK is its definition. This file follows UnBitArray.cpp and
// UnBitArrayBase.cpp.

/// One channel's part of the residual coder: a running sum of the last
/// residuals, which sets the size of the next one's low part, and the step
/// the sum is at.
struct MonkeysAudioResidualState {
    var step: Int = 10
    var sum: UInt32 = 16_384

    /// The state every frame starts from.
    mutating func reset() {
        step = 10
        sum = 16_384
    }
}

/// Decodes the residuals of one Monkey's Audio frame (file versions 3.99
/// and later) from its bytes with a range coder.
///
/// A frame's bytes are read as 32-bit little-endian words, the highest
/// byte of each first, so the stream's byte `k` is the file's byte
/// `4 * (k / 4) + 3 - k % 4`. Every division is guarded and every read is
/// inside the frame: a damaged frame ends in an `OwnAudioError`.
struct MonkeysAudioRangeDecoder {
    /// The coder works on 32-bit numbers; its range is renewed whenever it
    /// falls to this value or below, a byte at a time.
    private static let bottomValue: UInt32 = 1 << 23
    /// The symbols of the overflow alphabet; the last one says that the
    /// overflow follows as a 32-bit number.
    private static let overflowSymbols = 64
    /// An overflow of this value, written in full, says the pivot is too
    /// small for the residual and is to be this one.
    private static let overflowSignal: UInt32 = 1
    private static let overflowPivot: UInt32 = 32_768

    /// The frame's bytes as the file holds them, and the next byte of the
    /// stream to take.
    private let bytes: [UInt8]
    private var position: Int
    /// The coder's interval and the last bytes read.
    private var low: UInt32 = 0
    private var range: UInt32 = 0
    private var buffer: UInt32 = 0

    /// A decoder of `bytes`, starting at the stream's byte `position` (a
    /// frame starts up to three bytes into its first word).
    init(_ bytes: [UInt8], startingAt position: Int) {
        self.bytes = bytes
        self.position = max(position, 0)
    }

    /// The next byte of the stream. The last byte the frame holds is never
    /// read, as in the format's own decoder: a stream that needs it has run
    /// past its end.
    /// - Throws: `OwnAudioError.damaged` past the frame's end.
    private mutating func byte() throws -> UInt32 {
        guard position + 1 < bytes.count else { throw OwnAudioError.damaged }
        let index = (position & ~3) + 3 - (position & 3)
        position += 1
        // A last word cut short reads as if filled with zeros.
        return index < bytes.count ? UInt32(bytes[index]) : 0
    }

    /// The next four bytes of the stream as one number, the first highest.
    /// - Throws: `OwnAudioError.damaged` past the frame's end.
    mutating func word() throws -> UInt32 {
        guard position + 4 < bytes.count else { throw OwnAudioError.damaged }
        var value: UInt32 = 0
        for _ in 0..<4 { value = value << 8 | (try byte()) }
        return value
    }

    /// Starts the range coder where the frame's residuals begin: one byte
    /// is passed over, and the next primes the coder.
    mutating func start() throws {
        _ = try byte()
        buffer = try byte()
        low = buffer >> 1
        range = 1 << 7
    }

    /// Renews the range from the stream's next bytes until it is above
    /// `bottomValue`.
    /// - Throws: `OwnAudioError.damaged` when the range has fallen to
    ///   nothing, which no encoder's stream does, or the bytes end.
    private mutating func renew() throws {
        guard range != 0 else { throw OwnAudioError.damaged }
        // At most four turns: each multiplies a range that is not zero by 256.
        while range <= Self.bottomValue {
            buffer = buffer << 8 | (try byte())
            low = low << 8 | ((buffer >> 1) & 0xFF)
            range <<= 8
        }
    }

    /// A number of `bits` bits (at most 16) read straight from the coder.
    private mutating func direct(bits: UInt32) throws -> UInt32 {
        try renew()
        range >>= bits
        guard range != 0 else { throw OwnAudioError.damaged }
        let value = low / range
        low %= range
        return value
    }

    /// A number from 0 to `count` - 1, each as likely as the others.
    private mutating func uniform(below count: UInt32) throws -> UInt32 {
        try renew()
        guard count != 0 else { throw OwnAudioError.damaged }
        range /= count
        guard range != 0 else { throw OwnAudioError.damaged }
        let value = low / range
        low %= range
        return value
    }

    /// The next residual's overflow: how many whole pivots it holds. A
    /// residual too large for its pivot signals so, and `pivot` becomes
    /// the larger one that its overflow is then counted in.
    private mutating func overflow(pivot: inout UInt32) throws -> UInt32 {
        // Each turn uses up bytes of the stream, whose end bounds the loop.
        while true {
            try renew()
            range >>= 16
            let total = low / range
            guard total < 65_536 else { throw OwnAudioError.damaged }
            // The symbol whose share of the range holds the total; the last total is 65,536.
            var symbol = 0
            while symbol < Self.overflowSymbols - 1, total >= MonkeysAudioTables.rangeTotals[symbol + 1] { symbol += 1 }
            low = low &- range &* MonkeysAudioTables.rangeTotals[symbol]
            range = range &* MonkeysAudioTables.rangeWidths[symbol]
            guard symbol == Self.overflowSymbols - 1 else { return UInt32(symbol) }
            // The overflow in full: two 16-bit halves.
            let high = try direct(bits: 16)
            let value = high << 16 | (try direct(bits: 16))
            guard value == Self.overflowSignal else { return value }
            pivot = Self.overflowPivot
        }
    }

    /// The next residual of the channel whose state is `state`, which
    /// moves on.
    /// - Throws: `OwnAudioError.damaged`.
    mutating func residual(_ state: inout MonkeysAudioResidualState) throws -> Int64 {
        var pivot = max(state.sum / 32, 1)
        let whole = try overflow(pivot: &pivot)
        let base: UInt32
        if pivot >= 1 << 16 {
            // A pivot too wide for one step is read in two: its upper part, then 2 to the power of the rest.
            let width = UInt32(32 - pivot.leadingZeroBitCount)
            let split = UInt32(1) << (width >= 16 ? width - 16 : 0)
            let upper = try uniform(below: pivot / split &+ 1)
            base = upper &* split &+ (try uniform(below: split))
        } else {
            base = try uniform(below: pivot)
        }
        let value = Int64(base) + Int64(whole) * Int64(pivot)

        // The sum follows the residuals, and the step follows the sum.
        state.sum = state.sum &+ UInt32(truncatingIfNeeded: (value + 1) / 2) &- ((state.sum &+ 16) >> 5)
        let boundaries = MonkeysAudioTables.sumBoundaries
        if state.step >= 0, state.step < boundaries.count, state.sum < boundaries[state.step] {
            state.step -= 1
        } else if state.step >= 0, state.step + 1 < boundaries.count, boundaries[state.step + 1] != 0,
                  state.sum >= boundaries[state.step + 1] {
            state.step += 1
        }
        // Odd numbers are the positive residuals, even ones zero and the negative.
        return value & 1 != 0 ? value >> 1 + 1 : -(value >> 1)
    }
}
