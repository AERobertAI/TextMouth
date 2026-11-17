import Foundation
import os

/// Runs the calls of one C library inside TextMouth's own process, one at a
/// time on a thread of its own, each within a time limit (DR34, November 16,
/// 2026).
///
/// The Mac runs untrusted C, such as liblouis, in a helper program under its
/// watchdog (`WatchedProcess`), so a hang or a crash costs one run of the
/// helper. iOS lets an app start no helper program, so the iPhone runs the
/// same C here, with what one process allows in place of the watchdog:
///
/// - **One call at a time.** liblouis is not thread-safe, nor are most C
///   libraries of its kind, so every call runs on the engine's one thread, in
///   the order the calls were made, never two at once. The thread has a stack
///   of `stackSize` bytes, by default the 8 MB of the main thread the helper
///   runs its C on, where a secondary thread would get 512 KB.
/// - **A time limit on each call.** A call's `Call.shouldStop` turns true once
///   its limit has passed since it started, or once its import is cancelled.
///   Work that asks it between its steps (the braille library asks before
///   each record) stops in time by itself.
/// - **Abandoned past its time.** A call still running `grace` seconds after
///   it should have stopped is abandoned: its thread cannot be killed, so it
///   is left where it is, and its caller gets `Failure.abandoned` at once.
/// - **Refused until TextMouth is opened again.** After an abandoned call the
///   library's state could be anything, and the thread is taken, so the
///   engine runs nothing more: the calls waiting behind it, and every call
///   made later, fail at once with `Failure.refused`, whose sentence says so
///   (`InProcessEngineWording`).
///
/// Each C library gets an engine of its own (braille's is
/// `BrailleTranslator.libraryEngine`), made with the phrase its sentences
/// name its work by. FFmpeg's iPhone half is to run its calls through another
/// one, passing `Call.stopCheck` and `Call.context` as its interrupt
/// callback, so nothing here is copied.
final class InProcessEngine: Sendable {
    // MARK: Failures

    /// Why a call gave no value.
    enum Failure: LocalizedError, Equatable {
        /// The call was still running `grace` seconds after its limit of
        /// `limit` seconds, or after its import's Cancel, so it was abandoned,
        /// and the engine refuses every call from now on. `work` is the
        /// engine's phrase for what its calls do.
        case abandoned(work: String, limit: TimeInterval)
        /// An earlier call of the engine was abandoned, so this one was not
        /// run.
        case refused(work: String)

        var errorDescription: String? {
            switch self {
            case let .abandoned(work, limit): return InProcessEngineWording.abandoned(work, seconds: limit)
            case let .refused(work): return InProcessEngineWording.refused(work)
            }
        }
    }

    // MARK: A Call

    /// One call, as its work on the engine's thread and its waiting caller
    /// share it: when it started, whether its import was cancelled, and how
    /// it ended.
    final class Call: Sendable {
        /// How long the work may run once it has started, in seconds.
        let limit: TimeInterval

        /// What has happened to the call so far.
        fileprivate struct State: Sendable {
            /// When the engine's thread began the work; nil while it waits.
            var started: DispatchTime?
            /// When its import was cancelled; nil until then.
            var cancelled: DispatchTime?
            /// Whether the work has returned.
            var finished = false
            /// Whether the caller gave up waiting, past its time.
            var abandoned = false
            /// Whether the call was refused before it ran.
            var refused = false
        }

        /// The state, which the engine's thread, the caller, and a Cancel
        /// change from their own threads.
        fileprivate let state = OSAllocatedUnfairLock(initialState: State())
        /// Signalled at every change of `state`, so the waiting caller looks
        /// again.
        fileprivate let changed = DispatchSemaphore(value: 0)

        /// A call allowed `limit` seconds once it starts.
        fileprivate init(limit: TimeInterval) {
            self.limit = limit
        }

        /// Whether the work should stop now: its limit has passed since it
        /// started, or its import was cancelled. Cheap enough to ask before
        /// every step of the work.
        var shouldStop: Bool {
            state.withLock { state in
                if state.cancelled != nil { return true }
                guard let started = state.started else { return false }
                return DispatchTime.now() >= started + limit
            }
        }

        /// This call as the context `stopCheck` is given, valid while the
        /// work runs: the work holds the call until it returns.
        var context: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        /// `shouldStop` as a C function: 1 to stop and 0 to go on, for the
        /// call whose `context` it is given, and 0 for none. It has the shape
        /// of the braille library's `should_stop` and of FFmpeg's interrupt
        /// callback, so a C library asks it between its steps.
        static var stopCheck: @convention(c) (UnsafeMutableRawPointer?) -> Int32 {
            { context in
                guard let context else { return 0 }
                return Unmanaged<Call>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
            }
        }

        /// Changes the state with `change` and wakes the waiting caller.
        fileprivate func update(_ change: @Sendable (inout State) -> Void) {
            state.withLock(change)
            changed.signal()
        }

        /// Records the import's Cancel, once: from now on the work should
        /// stop, and its caller waits only `grace` more.
        fileprivate func cancel() {
            update { state in
                if state.cancelled == nil { state.cancelled = .now() }
            }
        }
    }

    // MARK: The Engine

    /// The engine's name, for its thread and its log lines, such as
    /// "liblouis".
    let name: String
    /// What its calls do, as its sentences name it: "the braille
    /// translation".
    let work: String
    /// How long a call may go on past its limit, or past its import's Cancel,
    /// before it is abandoned, in seconds.
    let grace: TimeInterval
    /// The size of the engine's thread's stack, in bytes.
    let stackSize: Int

    /// One call waiting for the thread: its call, and the work, which keeps
    /// its own value.
    private struct Job: Sendable {
        let call: Call
        let run: @Sendable () -> Void
    }

    /// What the engine holds.
    private struct State: Sendable {
        /// Whether the thread has been started; it is started by the first call.
        var threadStarted = false
        /// Whether a call was abandoned, after which nothing more runs.
        var abandoned = false
        /// Whether the engine is gone, which ends its idle thread.
        var closed = false
        /// The calls not yet begun, in the order they were made.
        var queue: [Job] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled once for each call queued, and when the engine goes.
    private let jobsWaiting = DispatchSemaphore(value: 0)

    /// An engine named `name` whose calls do `work` (see the properties),
    /// with `grace` seconds after a call's time before it is abandoned and a
    /// thread of `stackSize` bytes of stack. Its thread starts with its first
    /// call.
    init(name: String, work: String, grace: TimeInterval = 5, stackSize: Int = 8 * 1_048_576) {
        self.name = name
        self.work = work
        self.grace = max(0, grace)
        self.stackSize = stackSize
    }

    /// Ends the engine's thread once it is idle. A thread taken by an
    /// abandoned call stays where it is.
    deinit {
        state.withLock { $0.closed = true }
        jobsWaiting.signal()
    }

    /// Whether a call was abandoned, so the engine now refuses every call.
    var hasAbandonedACall: Bool {
        state.withLock { $0.abandoned }
    }

    /// Runs `body` on the engine's thread, after every call made before it,
    /// and returns its value.
    ///
    /// `body` gets its `Call`, whose `shouldStop` turns true once `limit`
    /// seconds have passed since the work started, or once `cancellation` is
    /// cancelled; work that asks it between its steps stops in time and
    /// returns what it has, as the braille library ends with its status 8.
    /// The caller waits until the work returns, or until `grace` seconds
    /// after the work should have stopped: then the call is abandoned, and
    /// the engine refuses every call from then on. A call waiting behind
    /// another waits for its turn; its own time counts from its start.
    /// - Throws: `Failure.abandoned` for a call abandoned past its time, and
    ///   `Failure.refused` when an earlier call was abandoned, in which case
    ///   `body` never runs.
    func run<Value: Sendable>(
        limit: TimeInterval,
        cancelledBy cancellation: ImportCancellation? = nil,
        _ body: @escaping @Sendable (Call) -> Value
    ) throws -> Value {
        let call = Call(limit: max(0, limit))
        // The work's value, kept by the work before the thread marks the call
        // finished, so a finished call always has one.
        let value = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let job = Job(call: call) {
            let result = body(call)
            value.withLock { $0 = result }
        }
        // Queue the call unless the engine refuses, starting the thread for
        // the first.
        let startsThread: Bool? = state.withLock { engine in
            guard !engine.abandoned else { return nil }
            engine.queue.append(job)
            defer { engine.threadStarted = true }
            return !engine.threadStarted
        }
        guard let startsThread else { throw Failure.refused(work: work) }
        if startsThread { startThread() }
        jobsWaiting.signal()

        // Wait, telling the call when its import is cancelled meanwhile.
        let outcome: Outcome
        if let cancellation {
            outcome = cancellation.whileRunning({ call.cancel() }, then: { wait(for: call) })
        } else {
            outcome = wait(for: call)
        }
        switch outcome {
        case .finished:
            // The work kept its value before the call was marked finished.
            guard let result = value.withLock({ $0 }) else { throw Failure.refused(work: work) }
            return result
        case .refused:
            throw Failure.refused(work: work)
        case .abandoned:
            throw Failure.abandoned(work: work, limit: call.limit)
        }
    }

    // MARK: Waiting

    /// How a wait for a call ended.
    private enum Outcome {
        case finished, refused, abandoned
    }

    /// Waits for `call` to finish, to be refused, or to pass its time, and
    /// abandons it in the last case. A call not yet started has no time of
    /// its own to pass: it waits for the call before it, which itself
    /// finishes or is abandoned, refusing this one.
    private func wait(for call: Call) -> Outcome {
        while true {
            let now = call.state.withLock { $0 }
            if now.finished { return .finished }
            if now.refused { return .refused }
            var deadline = DispatchTime.distantFuture
            if let started = now.started {
                // The work should stop at its limit, or at the Cancel when that
                // is sooner (but never before it started), and it may take the
                // grace to return.
                var stopsAt = started + call.limit
                if let cancelled = now.cancelled { stopsAt = min(stopsAt, max(started, cancelled)) }
                deadline = stopsAt + grace
                if DispatchTime.now() >= deadline {
                    if abandon(call) { return .abandoned }
                    // It finished just then: look again.
                    continue
                }
            }
            _ = call.changed.wait(timeout: deadline)
        }
    }

    /// Abandons `call` unless it has finished: the engine is marked to refuse
    /// every call from now on, and the calls waiting behind it are refused at
    /// once. The call's finishing and the thread's taking the next call happen
    /// under the engine's lock too (`startThread`), so either the call is
    /// abandoned and nothing else ever runs, or it finished and this does
    /// nothing. Returns whether it abandoned the call.
    private func abandon(_ call: Call) -> Bool {
        let refused: [Job]? = state.withLock { engine in
            let stillRunning = call.state.withLock { callState in
                guard !callState.finished else { return false }
                callState.abandoned = true
                return true
            }
            guard stillRunning else { return nil }
            engine.abandoned = true
            let waiting = engine.queue
            engine.queue.removeAll()
            return waiting
        }
        guard let refused else { return false }
        for job in refused {
            job.call.update { $0.refused = true }
        }
        // The line names the engine and the limit, never what the call read.
        DiagnosticLog.event(
            .import,
            "IN_PROCESS_CALL_ABANDONED: \(name): a call ran past its limit of "
                + "\(CountWording.seconds(Int(call.limit.rounded(.up)))) and was abandoned, "
                + "\(refused.count) waiting refused; no more calls until TextMouth is opened again"
        )
        return true
    }

    // MARK: The Thread

    /// What the thread does next.
    private enum Next: Sendable {
        case run(Job)
        case idle
        case stop
    }

    /// Starts the engine's one thread, which runs the queued calls in turn
    /// for as long as the engine lives. Finishing a call and taking the next
    /// happen under one lock, which `abandon(_:)` takes too.
    private func startThread() {
        let thread = Thread { [state, jobsWaiting] in
            var finished: Call?
            while true {
                if finished == nil { jobsWaiting.wait() }
                let next: Next = state.withLock { [finished] engine in
                    // The call just run is marked finished here, under the
                    // engine's lock, before the next is taken.
                    finished?.state.withLock { $0.finished = true }
                    if engine.abandoned { return engine.closed ? .stop : .idle }
                    if !engine.queue.isEmpty { return .run(engine.queue.removeFirst()) }
                    return engine.closed ? .stop : .idle
                }
                // Wake the caller of the call just finished, outside the lock.
                finished?.changed.signal()
                finished = nil
                switch next {
                case .stop:
                    return
                case .idle:
                    continue
                case let .run(job):
                    job.call.update { $0.started = .now() }
                    job.run()
                    finished = job.call
                }
            }
        }
        thread.name = "TextMouth \(name)"
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
