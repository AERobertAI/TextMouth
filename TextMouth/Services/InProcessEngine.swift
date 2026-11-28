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
///   each record) stops in time by itself. The time is the engine's `clock`'s,
///   which counts only the time TextMouth runs (`RunningClock`, B18): a call
///   frozen while iOS keeps the app suspended has spent none of it. The
///   waiting caller alone judges it, reading the clock afresh each time it
///   looks, so the work, which may resume first, never stops on a stale one.
/// - **Abandoned past its time.** A call still running `grace` seconds after
///   it should have stopped is abandoned: its thread cannot be killed, so it
///   is left where it is, at the lowest priority, so that the rest of the app
///   (a book's audio playing in the background among it) goes first; and its
///   caller gets `Failure.abandoned` at once.
/// - **Refused until TextMouth is closed and opened again.** After an
///   abandoned call the library's state could be anything, and the thread is
///   taken, so the engine runs nothing more: the calls waiting behind it, and
///   every call made later, fail at once with `Failure.refused`, whose
///   sentence says so (`InProcessEngineWording`). Only a new process clears
///   that, which an iPhone app gets when it is closed, not when it is only
///   switched back to.
///
/// Each C library gets an engine of its own, made with the phrase its
/// sentences name its work by: braille's is
/// `BrailleTranslator.libraryEngine`, and FFmpeg's is
/// `FFmpegAudioConverter.sessionEngine` (FMT54), whose session asks a check
/// of its own (`SessionStopCheck`), the call's `shouldStop` and a floor under
/// the app's free memory, before every read of its file and each of its
/// steps. A caller in Swift concurrency, as FFmpeg's
/// import is, uses `runForTask(limit:_:)`, which waits off the cooperative
/// threads and follows the task's cancellation.
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
        /// How long the work may run once it has started, in seconds of the
        /// engine's clock.
        let limit: TimeInterval
        /// The engine's clock, which a Cancel is timed by.
        fileprivate let clock: RunningClock

        /// What has happened to the call so far, timed by the engine's clock.
        fileprivate struct State: Sendable {
            /// When the engine's thread began the work; nil while it waits.
            var started: TimeInterval?
            /// When its import was cancelled; nil until then.
            var cancelled: TimeInterval?
            /// Whether the waiting caller found the call's time spent and told
            /// the work to stop (B18).
            var stopAsked = false
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

        /// A call allowed `limit` seconds of `clock` once it starts.
        fileprivate init(limit: TimeInterval, clock: RunningClock) {
            self.limit = limit
            self.clock = clock
        }

        /// Whether the work should stop now: the waiting caller found its
        /// limit passed since it started, or its import was cancelled. It
        /// reads no clock, so the waiter alone judges the call's time (B18):
        /// work resuming after a suspension, before its waiter has looked,
        /// cannot find its time spent by a clock that counted the suspension.
        /// Cheap enough to ask before every step of the work.
        var shouldStop: Bool {
            state.withLock { $0.cancelled != nil || $0.stopAsked }
        }

        /// This call as the context `stopCheck` is given, valid while the
        /// work runs: the work holds the call until it returns.
        var context: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        /// `shouldStop` as a C function: 1 to stop and 0 to go on, for the
        /// call whose `context` it is given, and 0 for none. It has the shape
        /// of the braille library's `should_stop`, so the library asks it
        /// between its steps (FFmpeg's session asks a check of its own that
        /// asks `shouldStop`, `SessionStopCheck`).
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
            let now = clock.now()
            update { state in
                if state.cancelled == nil { state.cancelled = now }
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
    /// The clock every call's time is counted by: the app's, which counts
    /// only the time TextMouth runs (`RunningClock.app`, B18), unless a test
    /// scripts its own.
    let clock: RunningClock

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
        /// The engine's thread, as the bit pattern of its pthread, once it
        /// runs (0 before): `abandon(_:)` lowers its priority by it.
        var thread: UInt = 0
        /// The calls not yet begun, in the order they were made.
        var queue: [Job] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled once for each call queued, and when the engine goes.
    private let jobsWaiting = DispatchSemaphore(value: 0)

    /// An engine named `name` whose calls do `work` (see the properties),
    /// with `grace` seconds after a call's time before it is abandoned, a
    /// thread of `stackSize` bytes of stack, and every time counted by
    /// `clock`. Its thread starts with its first call.
    init(
        name: String,
        work: String,
        grace: TimeInterval = 5,
        stackSize: Int = 8 * 1_048_576,
        clock: RunningClock = .app
    ) {
        self.name = name
        self.work = work
        self.grace = max(0, grace)
        self.stackSize = stackSize
        self.clock = clock
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
        let call = Call(limit: max(0, limit), clock: clock)
        // The work's value, kept by the work before the thread marks the call
        // finished, so a finished call always has one.
        let value = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let job = Job(call: call) {
            let result = body(call)
            value.withLock { $0 = result }
        }
        // A cancellation that has happened already is told to the call before it is queued, so the work finds `shouldStop`
        // true from its first step. Told only by `whileRunning` below, after the queueing, the engine's thread could start the
        // work and read `shouldStop` first (the iPhone's InProcessEngineTests.testACallFromACancelledTaskStillRunsToldToStop
        // failed that way once, in train 1124-2049). Telling twice is harmless: the first time counts.
        if cancellation?.isCancelled == true { call.cancel() }
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

    /// `run(limit:cancelledBy:_:)` for a caller in Swift concurrency (FMT54:
    /// FFmpeg's session, which the iPhone's import reads from a task).
    ///
    /// - **The wait.** The caller is waited for on a dispatch thread, never
    ///   on one of Swift's cooperative threads, which a call that runs to its
    ///   limit and its grace would otherwise hold all that time.
    /// - **The task's cancellation.** It stands for an import's Cancel: once
    ///   the task is cancelled, `shouldStop` turns true and the call has its
    ///   grace to return before it is abandoned.
    /// - **A task cancelled already.** The call still runs, told to stop from
    ///   its first step, so work that only frees what an earlier call made
    ///   still runs.
    /// - Throws: `Failure.abandoned` and `Failure.refused`, as
    ///   `run(limit:cancelledBy:_:)` does; never `CancellationError`, since
    ///   the work decides what a stopped call gives back.
    func runForTask<Value: Sendable>(
        limit: TimeInterval,
        _ body: @escaping @Sendable (Call) -> Value
    ) async throws -> Value {
        // The task's cancellation, in the form `run` takes an import's.
        let cancellation = ImportCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.run(limit: limit, cancelledBy: cancellation, body) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: Waiting

    /// How a wait for a call ended.
    private enum Outcome {
        case finished, refused, abandoned
    }

    /// The longest a waiting caller sleeps between two looks at its running
    /// call's time, in seconds of the system's own: each look reads the
    /// engine's clock afresh, so a look made late by a suspension finds only
    /// the time the clock counted (B18).
    private static let lookEvery: TimeInterval = 0.25

    /// Waits for `call` to finish, to be refused, or to pass its time, and
    /// abandons it in the last case. A call not yet started has no time of
    /// its own to pass: it waits for the call before it, which itself
    /// finishes or is abandoned, refusing this one. Once a started call's
    /// time is spent by the engine's clock, the wait tells the work to stop
    /// (`Call.shouldStop`), and abandons it the grace later: the one judge of
    /// a call's time. The clock is held meanwhile, so its heartbeat counts
    /// the time the app runs whole.
    private func wait(for call: Call) -> Outcome {
        clock.hold()
        defer { clock.release() }
        while true {
            let now = call.state.withLock { $0 }
            if now.finished { return .finished }
            if now.refused { return .refused }
            var timeout = DispatchTime.distantFuture
            if let started = now.started {
                // The work should stop at its limit, or at the Cancel when that
                // is sooner (but never before it started), and it may take the
                // grace to return.
                var stopsAt = started + call.limit
                if let cancelled = now.cancelled { stopsAt = min(stopsAt, max(started, cancelled)) }
                let time = clock.now()
                if time >= stopsAt + grace {
                    if abandon(call) { return .abandoned }
                    // It finished just then: look again.
                    continue
                }
                if time >= stopsAt, !now.stopAsked {
                    call.update { $0.stopAsked = true }
                    continue
                }
                // Look again when the next of the two times comes, and no later
                // than `lookEvery`, the clock read anew.
                let untilNext = (time < stopsAt ? stopsAt : stopsAt + grace) - time
                timeout = .now() + min(max(0, untilNext), Self.lookEvery)
            }
            _ = call.changed.wait(timeout: timeout)
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
            // The thread is still in the call, and cannot leave it without
            // this lock, so its pthread is valid here.
            Self.lowerToTheLowestPriority(engine.thread)
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
                + "\(refused.count) waiting refused, its thread at the lowest priority; "
                + "no more calls until TextMouth is closed and opened again"
        )
        return true
    }

    /// Lowers the thread whose pthread has the bit pattern `thread` to the
    /// lowest priority of its scheduling policy, the documented minimum
    /// (`sched_get_priority_min`): an abandoned call may spin inside its
    /// library for as long as the app runs, and must not take a core from
    /// anything else. A thread's QoS can be set only by the thread itself,
    /// and macOS refuses the background policy for another thread
    /// (`THREAD_BACKGROUND_POLICY`, KERN_INVALID_ARGUMENT, measured on
    /// November 16, 2026), so the priority is set through its pthread, which
    /// takes it out of its QoS class as well. Nothing happens for 0.
    private static func lowerToTheLowestPriority(_ thread: UInt) {
        guard let pthread = pthread_t(bitPattern: thread) else { return }
        var parameters = sched_param()
        parameters.sched_priority = sched_get_priority_min(SCHED_OTHER)
        _ = pthread_setschedparam(pthread, SCHED_OTHER, &parameters)
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
        let thread = Thread { [state, jobsWaiting, clock] in
            // Its pthread, for `abandon(_:)`, before any call is taken.
            let me = UInt(bitPattern: pthread_self())
            state.withLock { $0.thread = me }
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
                    let startedAt = clock.now()
                    job.call.update { $0.started = startedAt }
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
