import os
import XCTest
@testable import TextMouth

/// The watched run whose child writes to a pipe the app reads as it runs
/// (`WatchedProcess.runStreaming`, FMT50: the FFmpeg helper's stream of
/// samples). Every child here is a system program: a shell, `head`, `yes`,
/// `sleep`. None can crash: a child that ends by a signal is killed with
/// SIGKILL, which makes no crash report.
final class WatchedProcessStreamingTests: XCTestCase {
    /// Limits of `seconds` for everything.
    private func limits(_ seconds: TimeInterval) -> WatchedProcess.Limits {
        WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
    }

    /// Reads everything `pipe` gives, to its end.
    private static func readAll(_ pipe: WatchedProcess.PipeReader) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while true {
            let piece = try await pipe.read(upTo: 65_536)
            if piece.isEmpty { return bytes }
            bytes += piece
        }
    }

    /// A shell running `script`.
    private let shell = URL(fileURLWithPath: "/bin/sh")

    /// Everything a child writes is read, more than a pipe holds at once,
    /// and the reader sees the end when the child ends.
    func testEverythingAChildWritesIsRead() async throws {
        let (ending, read) = try await WatchedProcess.runStreaming(
            URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "3000000", "/dev/zero"], watching: nil,
            limits: limits(TestMachine.allowed(30))
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        XCTAssertEqual(try read.get().count, 3_000_000)
    }

    /// A child that cannot start ends the read at once, with nothing read:
    /// the pipe's write end is closed for it.
    func testAChildThatCannotStartEndsTheReadAtOnce() async throws {
        let started = Date()
        let (ending, read) = try await WatchedProcess.runStreaming(
            URL(fileURLWithPath: "/nonexistent/helper"), arguments: [], watching: nil, limits: limits(30)
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(ending.outcome, .couldNotStart)
        XCTAssertEqual(try read.get(), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(5))
    }

    /// A child ended by a signal is told from one that exits with the same
    /// number: the signal is named.
    func testASignalIsToldFromAnExit() async throws {
        let (killed, _) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "kill -9 $$"], watching: nil, limits: limits(30)
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(killed, WatchedProcess.Ending(outcome: .exited(status: SIGKILL), signal: SIGKILL))
        let (exited, _) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "exit 9"], watching: nil, limits: limits(30)
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(exited, WatchedProcess.Ending(outcome: .exited(status: 9)))
    }

    /// A reader that gives up kills a child that would write without end,
    /// at once, and what it threw comes back.
    func testAReaderThatGivesUpKillsTheChild() async throws {
        struct GaveUp: Error {}
        let started = Date()
        let (ending, read) = try await WatchedProcess.runStreaming(
            URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], watching: nil, limits: limits(60)
        ) { pipe -> Int in
            _ = try await pipe.read(upTo: 4_096)
            throw GaveUp()
        }
        XCTAssertEqual(ending.signal, SIGKILL)
        XCTAssertThrowsError(try read.get()) { XCTAssertTrue($0 is GaveUp) }
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(10))
    }

    /// The stall clock follows the bytes read: a child that writes a little
    /// every third of a second runs past a one-second stall limit, and one
    /// that writes nothing is killed at it.
    func testTheStallClockFollowsTheBytesRead() async throws {
        var steady = limits(TestMachine.allowed(30))
        steady.maximumStalledSeconds = 1
        let (writing, read) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "i=0; while [ $i -lt 8 ]; do printf x; sleep 0.3; i=$((i+1)); done"], watching: nil, limits: steady
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(writing.outcome, .exited(status: 0))
        XCTAssertEqual(try read.get(), Array("xxxxxxxx".utf8))

        let (silent, _) = try await WatchedProcess.runStreaming(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], watching: nil, limits: steady
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(silent.outcome, .killed(.madeNoProgress(seconds: 1)))
    }

    /// The output cap follows the watched file the reader writes, not the
    /// pipe: a reader whose file passes the cap has its child killed, as a
    /// converter whose output grows too large is.
    func testTheOutputCapFollowsTheWatchedFile() async throws {
        let output = try makeSandboxDirectory("StreamingCap").appendingPathComponent("written.m4a")
        var capped = limits(TestMachine.allowed(30))
        capped.maximumOutputBytes = 1_000
        let (ending, _) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "printf x; exec /bin/sleep 30"], watching: output, limits: capped
        ) { pipe in
            _ = try await pipe.read(upTo: 16)
            try Data(count: 10_000).write(to: output)
            return try await Self.readAll(pipe)
        }
        XCTAssertEqual(ending.outcome, .killed(.wroteTooMuch(bytes: 1_000)))
    }

    /// A reader that returns while its child runs on (a helper that hangs
    /// after the stream's END) has the child ended once the grace is over,
    /// by a signal and not by the watchdog, long before the stall limit; a
    /// child that ends by itself within the grace is left to.
    func testAChildThatRunsOnAfterTheReaderReturnsIsEndedAfterTheGrace() async throws {
        let started = Date()
        // The stall limit would end the sleeping child at 5 seconds, as a failure.
        let (hung, hungRead) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "printf done; exec /bin/sleep 30"], watching: nil,
            limits: limits(TestMachine.allowed(5)), endGraceSeconds: 0.3
        ) { pipe in try await pipe.read(upTo: 4) }
        XCTAssertEqual(try hungRead.get(), Array("done".utf8))
        XCTAssertEqual(hung.signal, SIGKILL, "the child must be ended, by a signal that is not the watchdog's")
        if case .killed = hung.outcome { XCTFail("the watchdog's kill would fail the import: \(hung)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(3), "the stall limit ended it, not the grace")
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)

        // A child that ends within the grace ends as it chose, with its own status.
        let (finishing, _) = try await WatchedProcess.runStreaming(
            shell, arguments: ["-c", "printf done; sleep 0.2; exit 3"], watching: nil, limits: limits(30), endGraceSeconds: 20
        ) { pipe in try await pipe.read(upTo: 4) }
        XCTAssertEqual(finishing, WatchedProcess.Ending(outcome: .exited(status: 3)))
    }

    /// The watchdog reads the child's memory four times a second by default
    /// (a runaway decode is seen sooner), as a count of the reads in a run of
    /// a little over a second shows: once a second would read it once.
    func testTheMemoryIsReadFourTimesASecond() async throws {
        XCTAssertEqual(limits(30).pollInterval, 0.25)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let (ending, _) = try await WatchedProcess.runStreaming(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["1.3"], watching: nil, limits: limits(TestMachine.allowed(30)),
            residentMemory: { _ in
                reads.withLock { $0 += 1 }
                return 1
            }
        ) { pipe in try await Self.readAll(pipe) }
        XCTAssertEqual(ending.outcome, .exited(status: 0))
        XCTAssertGreaterThanOrEqual(reads.withLock { $0 }, 3)
    }

    /// Cancelling the task kills the child at once: the task ends in a
    /// cancellation, and no child is left running.
    func testCancellingKillsTheChild() async throws {
        let started = Date()
        let long = limits(60)
        let task = Task {
            try await WatchedProcess.runStreaming(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], watching: nil, limits: long
            ) { pipe in try await WatchedProcessStreamingTests.readAll(pipe) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(10))
    }
}
