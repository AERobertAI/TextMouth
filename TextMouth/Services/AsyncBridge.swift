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
        try waitForResult(timeLimit: nil, cancelledBy: nil, of: operation)
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
        try waitForResult(timeLimit: nil, cancelledBy: cancellation, of: operation)
    }

    /// As `waitForResult(cancelledBy:of:)`, and the wait ends after
    /// `timeLimit` (ST07): the detached task is cancelled, so work in it that
    /// follows its task's cancellation ends, and `TimeLimitExceeded` is
    /// thrown. Work that ignores cancellation is left to finish on its own
    /// and stores its late result where nobody reads it (the outcome is
    /// private to this call). A read of a file that never returns, through
    /// AVFoundation, would otherwise leave the waiting thread, and a reader
    /// on Loading or an import with no way to cancel, stuck for good. With a
    /// nil `timeLimit` the wait has no limit. A read of an audio file waits
    /// through `waitForResult(reading:timeLimit:abandoned:of:)` instead,
    /// which never starts a read of a file whose read was abandoned before.
    /// - Throws: `TimeLimitExceeded` after the limit, otherwise what the
    ///   operation throws.
    static func waitForResult<Value>(
        timeLimit: Duration?,
        cancelledBy cancellation: ImportCancellation? = nil,
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
        // Waits for the task to finish, or for the limit; true when the
        // limit came first.
        let wait: () -> Bool = {
            guard let timeLimit else {
                finished.wait()
                return false
            }
            return finished.wait(timeout: .now() + timeLimit.seconds) == .timedOut
        }
        let timedOut: Bool
        if let cancellation {
            // Cancelling the task is thread-safe and instant; the handler
            // is withdrawn once the wait is over.
            timedOut = cancellation.whileRunning({ task.cancel() }, then: wait)
        } else {
            timedOut = wait()
        }
        if timedOut, let timeLimit {
            task.cancel()
            // The line names no file or title: only that a read passed its limit.
            DiagnosticLog.event(
                .playback,
                "ASYNC_TIME_LIMIT: an audio read passed its limit of \(TimeLimitExceeded.spelling(of: timeLimit)) and was abandoned"
            )
            throw TimeLimitExceeded(limit: timeLimit)
        }
        // The task stores its result before it signals, so the wait cannot
        // end without one; this guard only satisfies the type checker.
        guard let result = outcome.result else { throw CancellationError() }
        return try result.get()
    }

    // MARK: - Time Limits (ST07)

    /// How long reading an audio file's tags may take: 30 seconds. A tag read
    /// opens the file and reads its metadata, which takes a moment even for a
    /// file in the cloud or on a slow disk; one that has not returned in half
    /// a minute is stuck. The callers' `try?` fall back to empty tags.
    static let audioTagsTimeLimit: Duration = .seconds(30)

    /// How long analyzing or parsing an audiobook's audio may take: 5
    /// minutes. It reads every track's duration and chapters, which takes
    /// seconds for a folder of hundreds of files; five minutes is far
    /// beyond that and still short of waiting for good. The error reaches
    /// the reader's or the import's failure message as any read error does.
    /// The bridge's other users (audio-edit renders, conversions, textutil)
    /// keep no limit: a render or conversion can honestly run for an hour,
    /// and each has its own cancel or watchdog.
    static let audioAnalysisTimeLimit: Duration = .seconds(300)

    /// The wait passed its time limit and was abandoned.
    struct TimeLimitExceeded: LocalizedError, Equatable {
        /// The limit that passed.
        let limit: Duration

        var errorDescription: String? {
            "Reading the audio took longer than \(Self.spelling(of: limit)), so TextMouth stopped waiting for it."
        }

        /// `limit` in words: whole minutes when it is a whole number of
        /// minutes ("5 minutes", "1 minute"), otherwise seconds ("30 seconds").
        static func spelling(of limit: Duration) -> String {
            let seconds = limit.seconds
            if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
                return CountWording.phrase(Int(seconds / 60), singular: "minute", plural: "minutes")
            }
            if seconds.truncatingRemainder(dividingBy: 1) == 0 {
                return CountWording.phrase(Int(seconds), singular: "second", plural: "seconds")
            }
            return "\(seconds) seconds"
        }
    }

    // MARK: - Reads Abandoned at Their Limit

    /// As `waitForResult(timeLimit:of:)`, for `operation`, a read through
    /// AVFoundation of the audio file or folder at `file`, which is
    /// remembered in `abandoned` once a read of it passes its limit: every
    /// later read of it is refused at once with `AbandonedEarlier`, and its
    /// operation never starts (stable020 review, finding 4). The limit
    /// cannot stop AVFoundation work that ignores cancellation, so without
    /// this a file that hangs AVFoundation would leave another stuck read
    /// running beside the first, with its thread and memory, each time its
    /// book was opened again or a launch check met it, the kind of pile-up
    /// that grew TextMouth to 34 GB on October 14, 2026.
    ///
    /// Only a read known to be stuck is remembered: reads of one file that
    /// start together, before either passes its limit, both run, and a read
    /// that fails with its own error is tried again next time.
    /// - Throws: `AbandonedEarlier` at once for a remembered file; otherwise
    ///   `TimeLimitExceeded` after the limit, or what the operation throws.
    static func waitForResult<Value>(
        reading file: URL,
        timeLimit: Duration,
        abandoned: AbandonedReads = .session,
        of operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        // The file as it is when the read starts: what is remembered should
        // the read pass its limit.
        let read = AbandonedReads.Read(of: file)
        if abandoned.contains(read) {
            // The line names no file or title, as the limit's own does.
            DiagnosticLog.event(
                .playback,
                "ASYNC_TIME_LIMIT: an audio read was refused at once, as an earlier read of the same file passed its limit"
            )
            throw AbandonedEarlier()
        }
        do {
            return try waitForResult(timeLimit: timeLimit, of: operation)
        } catch let exceeded as TimeLimitExceeded {
            abandoned.remember(read)
            throw exceeded
        }
    }

    /// A read refused at once, because an earlier read of the same file
    /// passed its limit while TextMouth was open
    /// (`waitForResult(reading:timeLimit:abandoned:of:)`). Its sentence
    /// reaches the reader's or the import's failure message as the limit's
    /// own does.
    struct AbandonedEarlier: LocalizedError, Equatable {
        var errorDescription: String? {
            "TextMouth stopped reading this audio earlier because it took too long, and won't try again until TextMouth is opened again."
        }
    }

    /// The files whose read passed its limit, kept until TextMouth quits.
    /// Reads wait on any background queue, so a lock guards the set.
    final class AbandonedReads: @unchecked Sendable {
        /// The app's: every reading wait remembers into it unless given
        /// another, as tests are.
        static let session = AbandonedReads()

        /// A file as a read found it: its path, size, and modification date,
        /// so the same file changed since, such as one written again, is
        /// read again. A folder of tracks has no size and date of its own
        /// here (`FileStamp`), so it is known by its path alone.
        struct Read: Hashable, Sendable {
            /// The file's path, standardized.
            let path: String
            /// Its size and modification time, or nil for a folder, or for
            /// a file that cannot be examined.
            let stamp: FileStamp?

            init(of file: URL) {
                path = file.standardizedFileURL.path
                stamp = FileStamp(of: file)
            }
        }

        private let lock = NSLock()
        private var reads: Set<Read> = []

        /// Whether a read of the file as `read` found it passed its limit.
        func contains(_ read: Read) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return reads.contains(read)
        }

        /// Remembers that a read of the file as `read` found it passed its
        /// limit.
        func remember(_ read: Read) {
            lock.lock()
            reads.insert(read)
            lock.unlock()
        }
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

private extension Duration {
    /// The duration in seconds, with its fraction.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
