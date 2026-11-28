import Foundation
import os

/// Measures how much stack code uses, without ever running out of it: the code
/// runs on a thread of 8 MiB, whose unused stack the probe has filled with a
/// pattern, and afterwards the lowest byte that no longer holds the pattern
/// says whether the code went deeper than its margin.
///
/// A test of a limit on recursion asks "did this recurse deeply?" and not "did
/// it survive?": code that recurses once for each level of a deep input, run
/// on an ordinary thread (a worker thread's stack is 512 KiB), would end the
/// test host if the guard that keeps it shallow ever broke. Here the same
/// regression writes into the filled stack, the test's assertion fails, and
/// nothing overflows. Keep every input a probe runs on to a depth whose
/// unguarded walk takes less than 8 MiB (a few thousand levels at the most).
enum StackProbe {
    /// The size of the stack of the thread the probe runs the code on.
    static let stackSize = 8 << 20

    /// The pattern the unused stack is filled with before the code runs.
    private static let pattern: UInt8 = 0xA5

    /// The lowest bytes of the stack the probe leaves alone, in case the
    /// system keeps its guard page inside the size it reports.
    private static let untouchedAtTheBottom = 64 << 10

    /// What a run found.
    struct Outcome<Value: Sendable>: Sendable {
        /// What the code returned; nil when it did not end in time.
        let value: Value?
        /// How far below the code's start its lowest write reached, in bytes,
        /// when it wrote past the margin; nil when it stayed within it.
        let deepestWrite: Int?
    }

    /// Runs `body` on a new thread of `stackSize` bytes, and says whether it
    /// wrote more than `margin` bytes of stack below where it started. The
    /// thread runs at the priority of the thread that waits for it, which
    /// the thread performance checker asks of a wait.
    /// - Parameters:
    ///   - margin: The stack the code may use, in bytes, below its start.
    ///   - body: The code to measure.
    static func run<Value: Sendable>(
        margin: Int = 64 << 10,
        timeout: TimeInterval = 120,
        _ body: @escaping @Sendable () -> Value
    ) -> Outcome<Value> {
        let outcome = OSAllocatedUnfairLock<Outcome<Value>>(initialState: Outcome(value: nil, deepestWrite: nil))
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let measured = measure(margin: margin, body)
            outcome.withLock { $0 = measured }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = .userInteractive
        thread.start()
        guard done.wait(timeout: .now() + timeout) == .success else { return Outcome(value: nil, deepestWrite: nil) }
        return outcome.withLock { $0 }
    }

    /// Fills this thread's stack from its bottom to `margin` bytes below the
    /// frame this function is called from, runs `body`, and finds the lowest
    /// byte of what was filled that no longer holds the pattern.
    private static func measure<Value>(margin: Int, _ body: () -> Value) -> Outcome<Value> {
        // The address of a local of this frame: the code's frames are below it.
        var start = 0
        let startAddress = withUnsafeMutablePointer(to: &start) { UInt(bitPattern: $0) }
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let low = top - UInt(pthread_get_stacksize_np(pthread_self())) + UInt(untouchedAtTheBottom)
        // Frames of this function and of the code are above `filledEnd`, which is
        // 16-byte aligned and a margin below this frame, so no live frame is overwritten.
        let filledEnd = (startAddress - UInt(margin)) & ~UInt(15)
        guard filledEnd > low, let base = UnsafeMutableRawPointer(bitPattern: low) else {
            return Outcome(value: body(), deepestWrite: nil)
        }
        let length = Int(filledEnd - low)
        memset(base, Int32(pattern), length)

        let value = body()

        // The first byte, from the bottom, that is not the pattern.
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var index = 0
        while index < length, bytes[index] == pattern { index += 1 }
        return Outcome(value: value, deepestWrite: index < length ? Int(startAddress - (low + UInt(index))) : nil)
    }
}
