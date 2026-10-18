import Darwin
import os
import XCTest
@testable import TextMouth

/// The guards that keep a watched child from outliving its watcher (REV17a
/// findings 4 and 5): the cancellation that meets the child's start in
/// either order, the monotonic clock, the kernel's CPU limit, the reaper
/// that kills the child when TextMouth is gone, and `terminateAll()`.
/// Every child is a stand-in (`/bin/sleep`, `/bin/sh` loops); no test
/// touches a real Ogg file.
final class WatchedProcessSafetyTests: XCTestCase {
    private var folder: URL!
    /// Stand-in processes a test started; tearDown ends whatever is left.
    private var standIns: [Process] = []
    /// Run tasks a test started; tearDown cancels whatever is left.
    private var tasks: [Task<WatchedProcess.Outcome, Error>] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    /// Ends every child, reaper, and task the test left, whatever it did.
    override func tearDown() {
        for task in tasks { task.cancel() }
        tasks = []
        WatchedProcess.terminateAll()
        for process in standIns where process.isRunning { process.terminate() }
        standIns = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Helpers

    /// Limits that keep a test short: the watchdog looks every 0.1 second.
    private func limits(
        seconds: TimeInterval = 60, stalled: TimeInterval = 60, cpu: TimeInterval? = nil
    ) -> WatchedProcess.Limits {
        WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30,
            maximumStalledSeconds: stalled, pollInterval: 0.1, maximumCPUSeconds: cpu
        )
    }

    /// A shell child that appends to `output` ten times a second for ever.
    private func writer(to output: URL) -> (URL, [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", "while :; do echo x >> \"$0\"; sleep 0.1; done", output.path])
    }

    /// A stand-in process, started, with a semaphore that is signalled when
    /// it ends. tearDown ends it if the test did not.
    private func spawn(_ path: String, _ arguments: [String]) throws -> (process: Process, ended: DispatchSemaphore) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        standIns.append(process)
        return (process, ended)
    }

    /// Waits up to `timeout` seconds for `condition`, polling every 20 ms.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// The path of the executable running as `pid`, or nil.
    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// A gate whose kills are recorded instead of sent.
    private func recordingGate() -> (WatchedProcess.ChildGate, OSAllocatedUnfairLock<[pid_t]>) {
        let killed = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
        let gate = WatchedProcess.ChildGate(kill: { pid in killed.withLock { $0.append(pid) } })
        return (gate, killed)
    }

    // MARK: - The Cancel Race

    /// Cancelled after the child was published: the cancellation kills it.
    func testACancellationAfterThePublishKillsTheChild() {
        let (gate, killed) = recordingGate()
        XCTAssertFalse(gate.publish(4242))
        XCTAssertEqual(killed.withLock { $0 }, [])
        gate.cancel()
        XCTAssertEqual(killed.withLock { $0 }, [4242])
        XCTAssertTrue(gate.isCancelled)
    }

    /// Cancelled before the child was published: the publish kills it at
    /// once, which the old pid-only handler could not do.
    func testACancellationBeforeThePublishKillsTheChildAtOnce() {
        let (gate, killed) = recordingGate()
        gate.cancel()
        XCTAssertEqual(killed.withLock { $0 }, [], "No child yet, nothing to kill")
        XCTAssertTrue(gate.publish(4243))
        XCTAssertEqual(killed.withLock { $0 }, [4243])
    }

    /// Once the child has ended, a late cancellation signals nothing (its
    /// pid may belong to somebody else by then).
    func testACancellationAfterTheChildEndedKillsNothing() {
        let (gate, killed) = recordingGate()
        gate.publish(4244)
        gate.clear()
        gate.cancel()
        XCTAssertEqual(killed.withLock { $0 }, [])
    }

    /// A task cancelled before `run` begins throws and starts no child.
    func testATaskCancelledBeforeRunStartsNoChild() async throws {
        let before = WatchedProcess.runningChildCount
        let output = folder.appendingPathComponent("out")
        let (executable, arguments) = writer(to: output)
        let limits = limits()
        let task = Task { () -> WatchedProcess.Outcome in
            // Cancelled during this sleep, which then ends at once.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return try await WatchedProcess.run(executable, arguments: arguments, watching: output, limits: limits)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled task must throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(WatchedProcess.runningChildCount, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "The writer must never have started")
    }

    // MARK: - The Monotonic Clock

    /// A frozen clock never ages the child: one that runs 2 s in real time
    /// under a 1 s limit ends by itself, so no wall clock is read.
    func testAFrozenClockNeverKillsAChildForTakingTooLong() async throws {
        let outcome = try await WatchedProcess.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"],
            watching: folder.appendingPathComponent("out"), limits: limits(seconds: 1),
            uptime: { 5_000 }
        )
        XCTAssertEqual(outcome, .exited(status: 0))
    }

    /// A clock that jumps 100 s per reading ages a healthy writer past its
    /// limit at the first look: the loop reads the injected clock.
    func testAnAdvancingClockKillsAHealthyWriter() async throws {
        let output = folder.appendingPathComponent("out")
        let (executable, arguments) = writer(to: output)
        let readings = OSAllocatedUnfairLock(initialState: 0.0)
        let started = Date()
        let outcome = try await WatchedProcess.run(
            executable, arguments: arguments, watching: output, limits: limits(seconds: 60),
            uptime: { readings.withLock { $0 += 100; return $0 } }
        )
        XCTAssertEqual(outcome, .killed(.tookTooLong(seconds: 60)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - The CPU Limit

    /// A child that burns processor time is ended by the kernel at its CPU
    /// allowance, long before any wall-clock limit, and reported as such.
    func testABusyChildIsEndedByTheKernelAtItsCPULimit() async throws {
        let started = Date()
        let outcome = try await WatchedProcess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do :; done"],
            watching: folder.appendingPathComponent("out"), limits: limits(cpu: 1)
        )
        XCTAssertEqual(outcome, .killed(.usedTooMuchProcessorTime(seconds: 1)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    /// The reason is spoken in whole seconds, rounded up, and counted with
    /// `CountWording` like the other reasons, so one second reads "1 second".
    func testTheProcessorTimeReasonReadsAsWords() {
        XCTAssertEqual(
            WatchedProcess.KillReason.usedTooMuchProcessorTime(seconds: 240).words,
            "it used more than 240 seconds of processor time"
        )
        XCTAssertEqual(
            WatchedProcess.KillReason.usedTooMuchProcessorTime(seconds: 0.2).words,
            "it used more than 1 second of processor time"
        )
    }

    /// With no explicit allowance the CPU limit is four times the wall limit.
    func testTheDefaultCPUAllowanceIsFourTimesTheWallLimit() {
        XCTAssertEqual(limits(seconds: 62).effectiveMaximumCPUSeconds, 248)
        XCTAssertEqual(limits(seconds: 62, cpu: 5).effectiveMaximumCPUSeconds, 5)
    }

    /// A file that cannot be executed, or is a folder, is not started.
    func testAToolThatCannotBeExecutedCouldNotStart() async throws {
        let script = folder.appendingPathComponent("script.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let notExecutable = try await WatchedProcess.run(
            script, arguments: [], watching: folder.appendingPathComponent("out"), limits: limits()
        )
        XCTAssertEqual(notExecutable, .couldNotStart)
        let aFolder = try await WatchedProcess.run(
            folder, arguments: [], watching: folder.appendingPathComponent("out"), limits: limits()
        )
        XCTAssertEqual(aFolder, .couldNotStart)
        // The same file with its execute bit on does run.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let executable = try await WatchedProcess.run(
            script, arguments: [], watching: folder.appendingPathComponent("out"), limits: limits()
        )
        XCTAssertEqual(executable, .exited(status: 0))
    }

    /// The pid the watchdog measures is the tool's own, not the shell that
    /// set the limit: the shell replaced itself with the tool.
    func testTheWatchedPidIsTheToolItself() async throws {
        let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome = try await WatchedProcess.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
            watching: folder.appendingPathComponent("out"), limits: limits(seconds: 1.5),
            residentMemory: { pid in
                if let path = WatchedProcessSafetyTests.executablePath(of: pid) { paths.withLock { $0.append(path) } }
                return nil
            }
        )
        XCTAssertEqual(outcome, .killed(.tookTooLong(seconds: 1.5)))
        let seen = paths.withLock { $0 }
        XCTAssertTrue(seen.contains { $0.hasSuffix("/sleep") }, "Never measured the tool: \(seen)")
    }

    // MARK: - The Reaper

    /// The tool dies within seconds of its parent's end.
    func testTheReaperKillsTheToolWhenTheParentEnds() throws {
        let parent = try spawn("/bin/sleep", ["1"])
        let tool = try spawn("/bin/sleep", ["30"])
        let reaper = try XCTUnwrap(WatchedProcess.startReaper(watching: tool.process.processIdentifier, parent: parent.process.processIdentifier))
        standIns.append(reaper)
        XCTAssertEqual(tool.ended.wait(timeout: .now() + 6), .success, "The tool outlived its parent")
        XCTAssertEqual(tool.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(tool.process.terminationStatus, SIGKILL)
    }

    /// A tool that ends first lets the reaper end by itself, and the parent
    /// is left alone.
    func testTheReaperEndsWhenTheToolEndsFirst() throws {
        let parent = try spawn("/bin/sleep", ["30"])
        let tool = try spawn("/bin/sleep", ["1"])
        let reaper = try XCTUnwrap(WatchedProcess.startReaper(watching: tool.process.processIdentifier, parent: parent.process.processIdentifier))
        standIns.append(reaper)
        XCTAssertTrue(waitUntil(5) { !reaper.isRunning }, "The reaper outlived the tool")
        XCTAssertTrue(parent.process.isRunning, "The reaper must not touch the parent")
    }

    /// A reaper for a child that is already gone ends at once.
    func testTheReaperForAGoneChildEndsAtOnce() throws {
        let gone = try spawn("/usr/bin/true", [])
        XCTAssertEqual(gone.ended.wait(timeout: .now() + 5), .success)
        let reaper = try XCTUnwrap(WatchedProcess.startReaper(watching: gone.process.processIdentifier))
        standIns.append(reaper)
        XCTAssertTrue(waitUntil(2) { !reaper.isRunning }, "The reaper stayed for a child that was gone")
    }

    // MARK: - terminateAll

    /// Both running writers die within moments of the call, and the count of
    /// running children returns to what it was.
    func testTerminateAllKillsEveryRunningChild() async throws {
        let before = WatchedProcess.runningChildCount
        let limits = limits()
        for name in ["one", "two"] {
            let output = folder.appendingPathComponent(name)
            let (executable, arguments) = writer(to: output)
            tasks.append(Task {
                try await WatchedProcess.run(executable, arguments: arguments, watching: output, limits: limits)
            })
        }
        XCTAssertTrue(waitUntil(10) { WatchedProcess.runningChildCount == before + 2 }, "The writers never started")
        WatchedProcess.terminateAll()
        XCTAssertTrue(waitUntil(3) { WatchedProcess.runningChildCount == before }, "Children outlived terminateAll()")
        for task in tasks {
            let outcome = try await task.value
            XCTAssertEqual(outcome, .exited(status: SIGKILL))
        }
        tasks = []
    }

    /// With nothing running the call does nothing.
    func testTerminateAllWithNoChildrenDoesNothing() {
        let before = WatchedProcess.runningChildCount
        WatchedProcess.terminateAll()
        XCTAssertEqual(WatchedProcess.runningChildCount, before)
    }

    // MARK: - Capturing The Output (FMT09)

    /// How many hidden `.watched-output` files the temporary directory holds.
    private func capturedOutputFileCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return names.filter { $0.hasSuffix(".watched-output") }.count
    }

    /// What the child prints comes back, and its exit is reported.
    func testRunCapturingOutputReturnsWhatTheChildPrints() async throws {
        let result = try await WatchedProcess.runCapturingOutput(
            URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "there"], limits: limits()
        )
        XCTAssertEqual(result.outcome, .exited(status: 0))
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "hello there\n")
    }

    /// Only the first `maximumOutputBytes` bytes come back.
    func testRunCapturingOutputKeepsOnlyTheFirstBytes() async throws {
        let result = try await WatchedProcess.runCapturingOutput(
            URL(fileURLWithPath: "/bin/echo"), arguments: ["abcdefghij"], limits: limits(),
            maximumOutputBytes: 4
        )
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "abcd")
    }

    /// The hidden file is gone after an exit, a kill, and a failure to start.
    func testRunCapturingOutputLeavesNoFileBehind() async throws {
        let before = capturedOutputFileCount()
        _ = try await WatchedProcess.runCapturingOutput(
            URL(fileURLWithPath: "/bin/echo"), arguments: ["x"], limits: limits()
        )
        let killed = try await WatchedProcess.runCapturingOutput(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], limits: limits(seconds: 0.3)
        )
        XCTAssertEqual(killed.outcome, .killed(.tookTooLong(seconds: 0.3)))
        let missing = try await WatchedProcess.runCapturingOutput(
            folder.appendingPathComponent("no-such-tool"), arguments: [], limits: limits()
        )
        XCTAssertEqual(missing.outcome, .couldNotStart)
        XCTAssertTrue(missing.output.isEmpty)
        XCTAssertEqual(capturedOutputFileCount(), before)
    }

    /// A cancelled run throws, kills the child, and removes its file too.
    func testACancelledCapturingRunRemovesItsFile() async throws {
        let before = capturedOutputFileCount()
        let limits = limits()
        let task = Task { () -> Data in
            try await WatchedProcess.runCapturingOutput(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], limits: limits
            ).output
        }
        // Long enough for the child to have started.
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(capturedOutputFileCount(), before)
    }

    /// The stalled-output clock counts from the child's last output: a
    /// silent child is killed as making no progress.
    func testASilentCapturingChildIsKilledAsMakingNoProgress() async throws {
        let result = try await WatchedProcess.runCapturingOutput(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], limits: limits(stalled: 0.3)
        )
        XCTAssertEqual(result.outcome, .killed(.madeNoProgress(seconds: 0.3)))
    }
}
