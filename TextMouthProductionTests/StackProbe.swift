import Foundation

/// Measures how much stack code uses, without ever running out of it: the code
/// runs on a thread whose stack the probe made, 8 MiB of it, filled with a
/// pattern, and afterwards the deepest byte that no longer holds the pattern
/// says how far down the code went.
///
/// A test of a limit on recursion asks "did this recurse deeply?" and not "did
/// it survive?": code that recurses once for each level of a deep input, run
/// on an ordinary thread (a worker thread's stack is 512 KiB), would end the
/// test host if the guard that keeps it shallow ever broke. Here the same
/// regression fills in some hundreds of KiB of the 8 MiB, the test's
/// assertion fails, and nothing overflows. Keep every input a probe runs on to
/// a depth whose unguarded walk takes less than 8 MiB (a few thousand levels
/// at the most).
enum StackProbe {
    /// The size of the stack the probe makes.
    static let stackSize = 8 << 20

    /// The pattern the stack is filled with before the code runs.
    private static let pattern: UInt8 = 0xA5

    /// What a run found: what the code returned, and how deep it went.
    struct Outcome<Value> {
        /// What the code returned; nil when no thread could be made.
        let value: Value?
        /// The bytes of the stack, from its top, down to the deepest byte
        /// that was written: the most the code and the frames below it took.
        let bytesUsed: Int
    }

    /// What a thread started by `run` runs, held in a class so that its address
    /// can be handed through the C interface of `pthread_create`; written by
    /// the thread alone, before it ends, and read after it was joined.
    private final class Job {
        let body: () -> Void
        init(body: @escaping () -> Void) { self.body = body }
    }

    /// The thread's start routine: runs the job it was handed.
    private static let startJob: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { context in
        Unmanaged<Job>.fromOpaque(context).takeUnretainedValue().body()
        return nil
    }

    /// Runs `body` on a new thread with a stack of `stackSize` bytes of this
    /// probe's own, joins it, and says how much of the stack it used. The
    /// thread has the caller's quality of service, which the thread
    /// performance checker asks of a thread that is waited for.
    static func run<Value>(_ body: @escaping () -> Value) -> Outcome<Value> {
        // The stack: pages from the system, so that they are aligned as the thread asks.
        let failed = UnsafeMutableRawPointer(bitPattern: -1)
        guard let memory = mmap(nil, stackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              memory != failed else {
            return Outcome(value: nil, bytesUsed: 0)
        }
        defer { munmap(memory, stackSize) }
        memset(memory, Int32(pattern), stackSize)

        var value: Value?
        let job = Job { value = body() }
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstack(&attributes, memory, stackSize)
        pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)
        var thread: pthread_t?
        guard pthread_create(&thread, &attributes, startJob, Unmanaged.passUnretained(job).toOpaque()) == 0,
              let thread else {
            return Outcome(value: nil, bytesUsed: 0)
        }
        pthread_join(thread, nil)
        // The job was handed over as an address that holds no reference.
        withExtendedLifetime(job) {}
        return Outcome(value: value, bytesUsed: stackSize - lowestWrittenOffset(in: memory))
    }

    /// The offset from the bottom of the stack of its lowest byte that no
    /// longer holds the pattern, or the stack's size when none was written.
    private static func lowestWrittenOffset(in memory: UnsafeMutableRawPointer) -> Int {
        let words = memory.assumingMemoryBound(to: UInt64.self)
        let patternWord = UInt64(pattern) * 0x0101_0101_0101_0101
        for index in 0..<(stackSize / MemoryLayout<UInt64>.size) where words[index] != patternWord {
            // The first changed word, from the bottom: the lowest byte in it that changed.
            let bytes = memory.assumingMemoryBound(to: UInt8.self)
            let start = index * MemoryLayout<UInt64>.size
            return (start..<(start + 8)).first { bytes[$0] != pattern } ?? start
        }
        return stackSize
    }
}
