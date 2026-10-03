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
    /// its priority, exactly as each copy of the bridge did before.
    static func waitForResult<Value>(
        of operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let outcome = Outcome<Value>()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                outcome.store(.success(try await operation()))
            } catch {
                outcome.store(.failure(error))
            }
            finished.signal()
        }
        finished.wait()
        // The task stores its result before it signals, so the wait cannot
        // end without one; this guard only satisfies the type checker.
        guard let result = outcome.result else { throw CancellationError() }
        return try result.get()
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
