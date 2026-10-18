import Foundation

/// Lets synchronous code wait for Swift concurrency work and use its result
/// (TODO Q08).
///
/// Parsing and content analysis run on ordinary background queues, yet some
/// of the work they need, such as reading an audio book's tracks through
/// AVFoundation, exists only as `async` functions. Each such caller used to
/// carry its own copy of the same bridge: a detached task, a semaphore, and
/// a locked box for the result. They now share this one.
///
/// Waiting blocks the calling thread until the work finishes, so call it
/// from a background queue. Never wait on the main thread for work that
/// needs the main actor, which would deadlock, and never wait from inside
/// Swift concurrency, where a blocked thread is one fewer for the work being
/// waited for.
enum AsyncBridge {
    /// Runs `operation` in a detached task, blocks the calling thread until
    /// it finishes, and returns its value or throws its error unchanged.
    ///
    /// The task is detached, so it inherits neither the caller's actor nor
    /// its task-local values, as each copy of the bridge did before. It runs
    /// at the waiting thread's priority (`Task.currentPriority`, which
    /// outside a task is the thread's own), and never below the default it
    /// ran at before (`waitPriority(for:)`): a thread blocked on it, the
    /// main thread included, then never waits on lower-priority work. The
    /// main thread once waited on work at the default priority, a priority
    /// inversion the Thread Performance Checker reported for every silent
    /// audiobook a hosted test made (board #1581).
    static func waitForResult<Value>(
        of operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        try waitForResult(cancelledBy: nil, of: operation)
    }

    /// As `waitForResult(of:)`, and the detached task is cancelled when
    /// `cancellation` is, so work in it that follows its task's cancellation
    /// (a watched child process, which is killed) ends at once instead of
    /// running to its end while the thread waits. An import's Cancel does
    /// this for its conversions. With a nil `cancellation` it is
    /// `waitForResult(of:)`.
    /// - Throws: what the operation throws, which for work that follows its
    ///   task's cancellation is `CancellationError`.
    static func waitForResult<Value>(
        cancelledBy cancellation: ImportCancellation?,
        of operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let outcome = Outcome<Value>()
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: waitPriority(for: Task.currentPriority)) {
            do {
                outcome.store(.success(try await operation()))
            } catch {
                outcome.store(.failure(error))
            }
            finished.signal()
        }
        if let cancellation {
            // Cancelling the task is thread-safe and instant; the handler
            // is withdrawn once the wait is over.
            cancellation.whileRunning({ task.cancel() }, then: { finished.wait() })
        } else {
            finished.wait()
        }
        // The task stores its result before it signals, so the wait cannot
        // end without one; this guard only satisfies the type checker.
        guard let result = outcome.result else { throw CancellationError() }
        return try result.get()
    }

    /// The priority the work runs at for a waiter whose priority is
    /// `waiting`: the waiter's, so that it never waits on lower-priority
    /// work, but never below `.medium`, the default the work ran at before,
    /// so that work waited for from a background queue runs no slower than
    /// it did.
    static func waitPriority(for waiting: TaskPriority) -> TaskPriority {
        max(waiting, .medium)
    }

    /// The result the detached task hands to the waiting thread. The lock
    /// makes the hand-over safe on its own terms, whatever order the
    /// semaphore already guarantees.
    private final class Outcome<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<Value, Error>?

        /// The stored result, or nil before the task has finished.
        var result: Result<Value, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }

        /// Keeps `result` for the waiting thread.
        func store(_ result: Result<Value, Error>) {
            lock.lock()
            storedResult = result
            lock.unlock()
        }
    }
}
