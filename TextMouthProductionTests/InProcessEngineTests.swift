import os
import XCTest
@testable import TextMouth

/// Tests of `InProcessEngine` (DR34), the iPhone's way of running a C library
/// inside the app, with plain Swift work standing in for the library: one
/// call at a time on one thread with the helper's stack, each call's limit
/// and its import's Cancel told through `shouldStop` and its C form, a call
/// past its time abandoned at the lowest priority, and every call refused
/// after it until TextMouth is closed and opened again; and the same from a
/// task (`runForTask`, FMT54), which waits off Swift's cooperative threads and
/// follows the task's cancellation. Shared with the iPhone's unit bundle.
///
/// Every wait has a limit: each call runs on a queue of its own and is waited
/// for at most 30 seconds, and work made to hang waits on a gate that the
/// test opens when it ends (`makeGate()`), so no thread is left stuck.
final class InProcessEngineTests: XCTestCase {
    /// The phrase the test engines name their work by.
    private let work = "the test work"

    // MARK: - Helpers

    /// An engine for one test, with `grace` seconds before a call past its
    /// time is abandoned.
    private func makeEngine(grace: TimeInterval = 5) -> InProcessEngine {
        InProcessEngine(name: "test", work: work, grace: grace)
    }

    /// What `body` gave, run on a queue of its own and waited for at most
    /// `seconds`; nil, with a failure, when it took longer.
    private func outcome<Value: Sendable>(
        within seconds: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @Sendable () throws -> Value
    ) -> Result<Value, Error>? {
        let box = OSAllocatedUnfairLock<Result<Value, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try body() }
            box.withLock { $0 = result }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("the call did not return within \(seconds) seconds", file: file, line: line)
            return nil
        }
        return box.withLock { $0 }
    }

    /// What `task` ended with, waited for on this thread for at most
    /// `seconds`; nil, with a failure, when it took longer.
    private func value<Value: Sendable>(
        of task: Task<Value, Error>,
        within seconds: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<Value, Error>? {
        let box = OSAllocatedUnfairLock<Result<Value, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let result = await task.result
            box.withLock { $0 = result }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("the task did not end within \(seconds) seconds", file: file, line: line)
            return nil
        }
        return box.withLock { $0 }
    }

    /// The kernel's ID of the thread that calls it.
    private static func threadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// The scheduling priority of the thread that calls it.
    private static func ownPriority() -> Int32 {
        var policy: Int32 = 0
        var parameters = sched_param()
        pthread_getschedparam(pthread_self(), &policy, &parameters)
        return parameters.sched_priority
    }

    /// The seconds since `start`.
    private static func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    // MARK: - One Call at a Time, on One Thread

    /// Calls made from eight threads at once run one at a time, all on one
    /// thread that is none of the callers', each giving back its own value.
    func testCallsFromManyThreadsRunOneAtATimeOnOneThread() throws {
        let engine = makeEngine()
        struct Seen: Sendable {
            var inside = 0
            var mostInside = 0
            var threads: Set<UInt64> = []
            var callers: Set<UInt64> = []
            var values: [Int] = []
        }
        let seen = OSAllocatedUnfairLock(initialState: Seen())
        let result = outcome {
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                seen.withLock { _ = $0.callers.insert(Self.threadID()) }
                let value = try? engine.run(limit: 30) { _ in
                    seen.withLock { seen in
                        seen.inside += 1
                        seen.mostInside = max(seen.mostInside, seen.inside)
                        seen.threads.insert(Self.threadID())
                    }
                    usleep(20_000)
                    seen.withLock { $0.inside -= 1 }
                    return index
                }
                seen.withLock { $0.values.append(value ?? -1) }
            }
        }
        XCTAssertNoThrow(try result?.get())
        let final = seen.withLock { $0 }
        XCTAssertEqual(final.mostInside, 1, "two calls ran at once")
        XCTAssertEqual(final.threads.count, 1, "the calls ran on \(final.threads.count) threads")
        XCTAssertTrue(final.threads.isDisjoint(with: final.callers), "a call ran on its caller's thread")
        XCTAssertEqual(final.values.sorted(), Array(0..<8), "each call gives back its own value")
    }

    /// Calls made one after another run in that order.
    func testCallsRunInTheOrderTheyWereMade() throws {
        let engine = makeEngine()
        let order = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let result = outcome {
            for index in 0..<5 {
                try engine.run(limit: 30) { _ in order.withLock { $0.append(index) } }
            }
        }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(order.withLock { $0 }, [0, 1, 2, 3, 4])
    }

    /// The engine's thread has the 8 MB stack of the main thread the Mac's
    /// helper runs liblouis on, and the engine's name.
    func testTheThreadHasTheHelpersStackAndTheEnginesName() throws {
        let engine = makeEngine()
        let result = outcome {
            try engine.run(limit: 30) { _ in (Thread.current.stackSize, Thread.current.name ?? "") }
        }
        let (stack, name) = try XCTUnwrap(try result?.get())
        XCTAssertEqual(stack, 8 * 1_048_576)
        XCTAssertEqual(name, "TextMouth test")
    }

    /// An engine that goes away ends its idle thread, so engines made and
    /// dropped leave no thread behind.
    func testAnEngineThatGoesEndsItsThread() throws {
        let thread = OSAllocatedUnfairLock<Thread?>(uncheckedState: nil)
        let result = outcome {
            let engine = InProcessEngine(name: "brief", work: "the brief work")
            try engine.run(limit: 30) { _ in
                // The thread's own object, kept to be asked later whether it ended.
                let current = Thread.current
                thread.withLockUnchecked { $0 = current }
            }
        }
        XCTAssertNoThrow(try result?.get())
        let ran = try XCTUnwrap(thread.withLockUnchecked { $0 }, "the call did not run")
        let deadline = Date().addingTimeInterval(TestMachine.allowed(5))
        while !ran.isFinished, Date() < deadline { usleep(10_000) }
        XCTAssertTrue(ran.isFinished, "the thread of an engine that went away is still running")
    }

    // MARK: - Values, Limits, and Cancel

    /// A call gives back what its work returns.
    func testACallGivesBackItsWorksValue() throws {
        let engine = makeEngine()
        let result = outcome { try engine.run(limit: 30) { _ in "forty-two" } }
        XCTAssertEqual(try result?.get(), "forty-two")
    }

    /// `shouldStop` turns true once the limit has passed since the work
    /// started, so work that asks it stops by itself, and its call returns
    /// what it gave.
    func testShouldStopTurnsTrueAtTheLimit() throws {
        let engine = makeEngine()
        let result = outcome {
            try engine.run(limit: 0.3) { call in
                let start = DispatchTime.now()
                let stoppedAtOnce = call.shouldStop
                while !call.shouldStop, Self.seconds(since: start) < 10 { usleep(1_000) }
                return (stoppedAtOnce, Self.seconds(since: start))
            }
        }
        let (stoppedAtOnce, elapsed) = try XCTUnwrap(try result?.get())
        XCTAssertFalse(stoppedAtOnce, "shouldStop was true as the work began")
        XCTAssertGreaterThanOrEqual(elapsed, 0.29, "the work was told to stop before its limit")
        XCTAssertLessThan(elapsed, 0.3 + TestMachine.allowed(2), "the work was told to stop long after its limit")
    }

    /// The C form of `shouldStop`, which a library asks with the call's
    /// context, answers 0 before the limit and 1 after it, and 0 for no
    /// context at all.
    func testTheCCheckAnswersAsShouldStop() throws {
        let engine = makeEngine()
        let result = outcome {
            try engine.run(limit: 0.2) { call in
                let check = InProcessEngine.Call.stopCheck
                let before = check(call.context)
                let start = DispatchTime.now()
                while !call.shouldStop, Self.seconds(since: start) < 10 { usleep(1_000) }
                return [before, check(call.context), check(nil)]
            }
        }
        XCTAssertEqual(try result?.get(), [0, 1, 0])
    }

    /// The import's Cancel tells the work to stop at once, long before its
    /// limit, and the call returns what the work gave.
    func testCancelTellsTheWorkToStop() throws {
        let engine = makeEngine()
        let cancellation = ImportCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let result = outcome {
            try engine.run(limit: 60, cancelledBy: cancellation) { call in
                let start = DispatchTime.now()
                while !call.shouldStop, Self.seconds(since: start) < 20 { usleep(1_000) }
                return Self.seconds(since: start)
            }
        }
        let elapsed = try XCTUnwrap(try result?.get())
        XCTAssertLessThan(elapsed, TestMachine.allowed(5), "Cancel did not reach the work")
        XCTAssertFalse(engine.hasAbandonedACall)
    }

    /// A call made after its import was cancelled still runs, told to stop
    /// from its first step, and is not abandoned for the Cancel that came
    /// before it started.
    func testACallCancelledBeforeItStartsIsToldToStopAndNotAbandoned() throws {
        let engine = makeEngine(grace: 0.2)
        let cancellation = ImportCancellation()
        cancellation.cancel()
        let result = outcome {
            try engine.run(limit: 60, cancelledBy: cancellation) { call in call.shouldStop }
        }
        XCTAssertEqual(try result?.get(), true)
        XCTAssertFalse(engine.hasAbandonedACall)
    }

    // MARK: - Abandoned, Then Refused

    /// Work that hangs past its limit and the grace is abandoned: the call
    /// throws at once, naming the work and its limit, rather than waiting for
    /// the work.
    func testACallPastItsLimitIsAbandoned() throws {
        let engine = makeEngine(grace: 0.2)
        let gate = makeGate()
        let start = DispatchTime.now()
        let result = outcome {
            try engine.run(limit: 0.2) { _ in _ = gate.wait(timeout: .now() + 30) }
        }
        let elapsed = Self.seconds(since: start)
        XCTAssertThrowsError(try result?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .abandoned(work: work, limit: 0.2))
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.39, "the call was abandoned before its limit and the grace")
        XCTAssertLessThan(elapsed, TestMachine.allowed(5), "the caller waited for the hung work")
        XCTAssertTrue(engine.hasAbandonedACall)
    }

    /// Work that hangs after its import's Cancel is abandoned the grace after
    /// the Cancel, not after its long limit.
    func testACancelledCallThatHangsIsAbandonedTheGraceAfterTheCancel() throws {
        let engine = makeEngine(grace: 0.3)
        let gate = makeGate()
        let cancellation = ImportCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let start = DispatchTime.now()
        let result = outcome {
            try engine.run(limit: 60, cancelledBy: cancellation) { _ in _ = gate.wait(timeout: .now() + 30) }
        }
        XCTAssertThrowsError(try result?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .abandoned(work: work, limit: 60))
        }
        XCTAssertLessThan(Self.seconds(since: start), TestMachine.allowed(5), "the caller waited out the limit")
    }

    /// Once a call has been abandoned, every later call is refused at once,
    /// and its work never runs, even after the hung work has ended.
    func testAfterAnAbandonedCallEveryCallIsRefusedUntilTheAppIsClosedAndOpenedAgain() throws {
        let engine = makeEngine(grace: 0.1)
        let gate = makeGate()
        let ranLater = OSAllocatedUnfairLock(initialState: false)
        let first = outcome { try engine.run(limit: 0.1) { _ in _ = gate.wait(timeout: .now() + 30) } }
        XCTAssertThrowsError(try first?.get())

        let start = DispatchTime.now()
        let refused = outcome { try engine.run(limit: 30) { _ in ranLater.withLock { $0 = true } } }
        XCTAssertThrowsError(try refused?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .refused(work: work))
        }
        XCTAssertLessThan(Self.seconds(since: start), TestMachine.allowed(1), "a refusal waited")

        // The hung work ends; the engine refuses still.
        gate.signal()
        usleep(100_000)
        let stillRefused = outcome { try engine.run(limit: 30) { _ in ranLater.withLock { $0 = true } } }
        XCTAssertThrowsError(try stillRefused?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .refused(work: work))
        }
        XCTAssertFalse(ranLater.withLock { $0 }, "work ran after a call was abandoned")
    }

    /// A call waiting its turn behind a call that is abandoned is refused as
    /// soon as that call is abandoned, and its work never runs.
    func testACallWaitingBehindAnAbandonedCallIsRefused() throws {
        let engine = makeEngine(grace: 0.2)
        let gate = makeGate()
        let started = DispatchSemaphore(value: 0)
        let waitingRan = OSAllocatedUnfairLock(initialState: false)
        // The first call runs on a queue of its own, so the test can queue a
        // second behind it while it hangs.
        let firstDone = DispatchSemaphore(value: 0)
        let firstResult = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
        DispatchQueue.global().async {
            let result = Result {
                try engine.run(limit: 0.3) { _ in
                    started.signal()
                    _ = gate.wait(timeout: .now() + 30)
                }
            }
            firstResult.withLock { $0 = result }
            firstDone.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the first call never started")
        let waiting = outcome { try engine.run(limit: 30) { _ in waitingRan.withLock { $0 = true } } }
        XCTAssertThrowsError(try waiting?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .refused(work: work))
        }
        XCTAssertEqual(firstDone.wait(timeout: .now() + 30), .success)
        XCTAssertThrowsError(try firstResult.withLock({ $0 })?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .abandoned(work: work, limit: 0.3))
        }
        XCTAssertFalse(waitingRan.withLock { $0 }, "the waiting call's work ran")
    }

    /// An abandoned call's thread, which may spin inside its library for as
    /// long as the app runs, drops to the lowest priority of its policy the
    /// moment it is abandoned, from the priority it ran at before.
    func testAnAbandonedCallsThreadDropsToTheLowestPriority() throws {
        let engine = makeEngine(grace: 0.1)
        let gate = makeGate()
        let seen = OSAllocatedUnfairLock<(before: Int32, after: Int32)?>(initialState: nil)
        let reported = DispatchSemaphore(value: 0)
        let first = outcome {
            try engine.run(limit: 0.1) { _ in
                let before = Self.ownPriority()
                _ = gate.wait(timeout: .now() + 30)
                seen.withLock { $0 = (before, Self.ownPriority()) }
                reported.signal()
            }
        }
        XCTAssertThrowsError(try first?.get()) { error in
            XCTAssertEqual(error as? InProcessEngine.Failure, .abandoned(work: work, limit: 0.1))
        }
        // The hung work ends now and says what it saw of its own thread.
        gate.signal()
        XCTAssertEqual(reported.wait(timeout: .now() + 30), .success, "the abandoned work never ended")
        let priorities = try XCTUnwrap(seen.withLock { $0 })
        let lowest = sched_get_priority_min(SCHED_OTHER)
        XCTAssertGreaterThan(priorities.before, lowest, "the engine's thread began at the lowest priority")
        XCTAssertEqual(priorities.after, lowest, "the abandoned call's thread kept priority \(priorities.after)")
    }

    /// A call's time counts from its own start, not from when it was made:
    /// one that waits behind a long call longer than its own limit and the
    /// grace still runs, and is not abandoned.
    func testAWaitingCallsTimeCountsFromItsOwnStart() throws {
        let engine = makeEngine(grace: 0.2)
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? engine.run(limit: 30) { _ in
                started.signal()
                usleep(700_000)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the first call never started")
        let result = outcome { try engine.run(limit: 0.2) { _ in "ran" } }
        XCTAssertEqual(try result?.get(), "ran")
        XCTAssertFalse(engine.hasAbandonedACall)
    }

    // MARK: - Only the Time TextMouth Runs (B18)

    /// A call frozen while iOS keeps TextMouth suspended has spent none of
    /// its time there: with the engine's clock scripted, five minutes of
    /// uptime pass in one jump, as while the listener is in another app, and
    /// the call is neither told to stop nor abandoned; it returns its own
    /// value once its work ends.
    func testACallSuspendedPastItsLimitIsNeitherToldToStopNorAbandoned() throws {
        let uptime = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_000)
        let clock = RunningClock(uptime: { uptime.withLock { $0 } }, longestStep: 1, tick: nil)
        let engine = InProcessEngine(name: "test", work: work, grace: 1, clock: clock)
        let gate = makeGate()
        let started = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<Bool, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let outcome = Result {
                try engine.run(limit: 10) { call -> Bool in
                    started.signal()
                    // The work runs until the gate opens, noting whether it was ever told to stop.
                    var toldToStop = false
                    while gate.wait(timeout: .now() + 0.01) == .timedOut {
                        toldToStop = toldToStop || call.shouldStop
                    }
                    return toldToStop || call.shouldStop
                }
            }
            result.withLock { $0 = outcome }
            done.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the call never started")
        uptime.withLock { $0 += 300 }
        // The waiter looks every quarter second: give it several looks at the clock.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(engine.hasAbandonedACall, "a suspended call was abandoned")
        gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "the call never returned")
        XCTAssertEqual(try result.withLock { $0 }?.get(), false, "a suspended call was told to stop")
    }

    /// `shouldStop` reads no clock: the waiter alone judges a call's time, so
    /// work that resumes before its waiter has looked cannot find its time
    /// spent by a clock that counted a suspension. Ten thousand asks of the
    /// work read the engine's clock no more than the waiter's few looks do.
    func testShouldStopReadsNoClockSoTheWaiterAloneJudgesTime() throws {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        let clock = RunningClock(
            uptime: { readings.withLock { $0 += 1 }; return ProcessInfo.processInfo.systemUptime },
            longestStep: 1,
            tick: nil
        )
        let engine = InProcessEngine(name: "test", work: work, clock: clock)
        let result = outcome {
            try engine.run(limit: 30) { call -> Int in
                let before = readings.withLock { $0 }
                for _ in 0..<10_000 where call.shouldStop { break }
                return readings.withLock { $0 } - before
            }
        }
        let readDuringTheAsks = try XCTUnwrap(try result?.get())
        XCTAssertLessThan(readDuringTheAsks, 100, "shouldStop read the clock")
    }

    // MARK: - From a Task (FMT54)

    /// A call from a task runs its work on the engine's thread, with its name,
    /// and gives back the work's value.
    func testACallFromATaskRunsOnTheEnginesThreadAndGivesBackItsValue() async throws {
        let engine = makeEngine()
        let (name, value) = try await engine.runForTask(limit: 30) { _ in (Thread.current.name ?? "", 42) }
        XCTAssertEqual(name, "TextMouth test")
        XCTAssertEqual(value, 42)
    }

    /// Cancelling the task tells the work to stop at once, long before its
    /// limit, and the call gives back what the work gave, unabandoned.
    func testCancellingTheTaskTellsTheWorkToStop() throws {
        let engine = makeEngine()
        let started = DispatchSemaphore(value: 0)
        // The work, made outside the task: the seconds it ran before it was told to stop.
        let work: @Sendable (InProcessEngine.Call) -> TimeInterval = { call in
            started.signal()
            let start = DispatchTime.now()
            while !call.shouldStop, Self.seconds(since: start) < 20 { usleep(1_000) }
            return Self.seconds(since: start)
        }
        let task = Task { try await engine.runForTask(limit: 60, work) }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the work never started")
        task.cancel()
        let elapsed = try XCTUnwrap(try value(of: task)?.get())
        XCTAssertLessThan(elapsed, TestMachine.allowed(5), "the task's cancellation did not reach the work")
        XCTAssertFalse(engine.hasAbandonedACall)
    }

    /// A task cancelled already still runs its call, so work that frees what
    /// an earlier call made still runs, told to stop from its first step.
    func testACallFromACancelledTaskStillRunsToldToStop() async throws {
        let engine = makeEngine(grace: 0.2)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.runForTask(limit: 60) { call in call.shouldStop }
        }
        let stoppedAtOnce = try await task.value
        XCTAssertTrue(stoppedAtOnce)
        XCTAssertFalse(engine.hasAbandonedACall)
    }

    /// Work that hangs past its limit and the grace is abandoned for a task as
    /// for a thread, and the engine refuses the next call.
    func testACallFromATaskPastItsLimitIsAbandonedAndTheNextRefused() async throws {
        let engine = makeEngine(grace: 0.2)
        let gate = makeGate()
        do {
            _ = try await engine.runForTask(limit: 0.2) { _ in gate.wait(timeout: .now() + 30) == .success }
            XCTFail("a call past its limit and the grace returned")
        } catch {
            XCTAssertEqual(error as? InProcessEngine.Failure, .abandoned(work: work, limit: 0.2))
        }
        do {
            _ = try await engine.runForTask(limit: 30) { _ in true }
            XCTFail("a call after an abandoned one ran")
        } catch {
            XCTAssertEqual(error as? InProcessEngine.Failure, .refused(work: work))
        }
    }

    /// Calls from many more tasks than the machine has cores, each waiting for
    /// the one engine thread, hold none of Swift's cooperative threads: a task
    /// started after them all still runs at once. A wait on a cooperative
    /// thread would starve it until the calls ended.
    func testCallsFromTasksWaitOffTheCooperativeThreads() throws {
        let engine = makeEngine()
        let gate = makeGate()
        let started = DispatchSemaphore(value: 0)
        let waiting = 4 * ProcessInfo.processInfo.activeProcessorCount
        let tasks = (0..<waiting).map { index in
            Task {
                try await engine.runForTask(limit: 60) { _ in
                    // Whichever call the engine takes first says so: the tasks queue their calls in no set order.
                    started.signal()
                    _ = gate.wait(timeout: .now() + 30)
                    return index
                }
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "no call ever started")
        let ran = DispatchSemaphore(value: 0)
        Task { ran.signal() }
        XCTAssertEqual(ran.wait(timeout: .now() + TestMachine.allowed(5)), .success, "a task was starved by calls waiting")
        // Every call runs once the gate opens: one signal for each, as each takes the thread in turn.
        for _ in 0..<waiting { gate.signal() }
        let values = tasks.map { (try? value(of: $0)?.get()) ?? -1 }
        XCTAssertEqual(values, Array(0..<waiting), "the calls did not all end with their own values")
    }

    // MARK: - The Words

    /// Each failure's sentence names the engine's work, the limit in whole
    /// seconds rounded up, and that nothing is tried again until TextMouth is
    /// closed and opened again: an iPhone app only switched back to keeps its
    /// process, and so its abandoned call.
    func testTheSentencesNameTheWorkAndTheLimit() {
        XCTAssertEqual(
            InProcessEngine.Failure.abandoned(work: "the braille translation", limit: 10.2).errorDescription,
            "TextMouth stopped the braille translation because it ran longer than 11 seconds, "
                + "and won't try again until TextMouth is closed and opened again."
        )
        // Rounded up, and never "0 seconds", even for a call whose time was spent before it began.
        for limit: TimeInterval in [0.5, 0] {
            XCTAssertEqual(
                InProcessEngine.Failure.abandoned(work: "the braille translation", limit: limit).errorDescription,
                "TextMouth stopped the braille translation because it ran longer than 1 second, "
                    + "and won't try again until TextMouth is closed and opened again.", "limit \(limit)"
            )
        }
        XCTAssertEqual(
            InProcessEngine.Failure.refused(work: "the braille translation").errorDescription,
            "TextMouth stopped the braille translation earlier because it took too long, "
                + "and won't try again until TextMouth is closed and opened again."
        )
    }

    /// AsyncBridge's refusal of an audio read uses the engine's own remedy,
    /// "closed and opened again", on both platforms (B17): this test also
    /// runs in the iPhone's unit bundle, where only switching back to the
    /// app does not clear an abandoned read.
    func testTheAudioReadRefusalSharesTheEnginesRemedy() {
        let sentence = "TextMouth stopped reading this audio earlier because it took too long, "
            + "and won't try again until TextMouth is closed and opened again."
        XCTAssertEqual(AsyncBridgeWording.abandonedEarlier, sentence)
        XCTAssertEqual(AsyncBridge.AbandonedEarlier().errorDescription, sentence)
        XCTAssertEqual(InProcessEngineWording.refused("reading this audio"), sentence)
    }
}
