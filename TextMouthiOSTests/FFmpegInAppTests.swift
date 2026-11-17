import os
import TextMouthFFmpegProtocol
import TextMouthFFmpegSession
import XCTest
@testable import TextMouth

/// FFmpeg's session in the iPhone app itself (FMT54), which only the iPhone
/// links and runs in its own process: where the bundled tool runs it, the
/// stop check its steps and FFmpeg's interrupt callback ask, a call that
/// hangs past its limit abandoned and every later call refused in the
/// engine's words, and the run's whole time and each call's, as the Mac's
/// watchdog allows its helper.
///
/// The shared FFmpeg tests (FFmpegImportRealTests, FFmpegImportConversionTests,
/// FFmpegHelperProtocolTests, and the rest) show that the iPhone makes the
/// same books, the same streams, and the same sentences as the Mac; these test
/// what is the iPhone's own. Every call goes through an engine of the test's
/// own, so the app's `FFmpegAudioConverter.sessionEngine` is never refused
/// for the tests after one; hung work waits on `makeGate()`, opened when the
/// test ends, so no thread is left stuck. Every file is a real sample: they
/// run on GitHub's simulator only, as every iPhone test does.
final class FFmpegInAppTests: XCTestCase {
    /// The engine the direct calls of the session go through.
    private let engine = InProcessEngine(name: "test-FFmpeg", work: "the audio conversion")

    // MARK: - Where the Session Runs

    /// The app's own tool runs the session in the app, on the FFmpeg engine,
    /// named so in the log and in its sentences: never missing, since it is
    /// linked into the app.
    func testTheBundledSessionRunsInTheAppOnItsOwnEngine() {
        XCTAssertEqual(FFmpegAudioConverter.locateBundled(), .inProcess)
        XCTAssertEqual(FFmpegAudioConverter.Tool.bundled.locate(), .inProcess)
        XCTAssertTrue(FFmpegAudioConverter.Tool.bundled.engine === FFmpegAudioConverter.sessionEngine)
        XCTAssertEqual(FFmpegAudioConverter.sessionEngine.name, "FFmpeg")
        XCTAssertEqual(FFmpegAudioConverter.sessionEngine.work, "the audio conversion")
        XCTAssertTrue(FFmpegAudioConverter.Located.inProcess.converts)
    }

    // MARK: - The Stop Check

    /// A stop check that counts its asks in the `Int32` its context points at,
    /// and says stop from the first.
    private static var stopAtOnce: tmff_stop_check {
        { context in
            context?.assumingMemoryBound(to: Int32.self).pointee += 1
            return 1
        }
    }

    /// A stop check that counts its asks, and never says stop.
    private static var neverStop: tmff_stop_check {
        { context in
            context?.assumingMemoryBound(to: Int32.self).pointee += 1
            return 0
        }
    }

    /// What opening `sample` with `demuxer` in a probe gave, on the test's
    /// engine, with a check that says stop at once when `stopping`, and never
    /// otherwise: the session's status and how often the check was asked
    /// while the file opened; the session, opened or not, is closed.
    private func open(_ sample: String, demuxer: String, stopping: Bool) throws -> (status: Int32, asks: Int32) {
        let path = try formatSampleURL(sample).path
        return try engine.run(limit: 30) { _ in
            let asks = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            asks.initialize(to: 0)
            defer { asks.deallocate() }
            let descriptor = tmff_open_regular_file(path)
            guard descriptor >= 0 else { return (TMFF_EXIT_UNREADABLE, 0) }
            defer { close(descriptor) }
            var status = TMFF_EXIT_DONE
            let check = stopping ? Self.stopAtOnce : Self.neverStop
            let session = tmff_session_open_checked(descriptor, demuxer, TMFF_SESSION_PROBE, check, asks, &status)
            tmff_session_close(session)
            return (status, asks.pointee)
        }
    }

    /// FFmpeg asks the session's stop check while it reads a file's header and
    /// finds its streams, through the session's interrupt callback: a check
    /// that says stop from its first ask ends the open itself with the
    /// session's stop (11), before any record, where nothing of the session's
    /// own asks; one that never says stop is asked and the file opens. So a
    /// call's time limit reaches FFmpeg's own reading, as the engine's
    /// `Call.stopCheck` does in the app.
    func testFFmpegsInterruptCallbackAsksTheStopCheckWhileTheFileOpens() throws {
        let stopped = try open("wma/tones-wma1.wma", demuxer: "asf", stopping: true)
        XCTAssertEqual(stopped.status, TMFF_EXIT_STOPPED, "a check that says stop did not stop the open")
        XCTAssertGreaterThan(stopped.asks, 0)
        let opened = try open("wma/tones-wma1.wma", demuxer: "asf", stopping: false)
        XCTAssertEqual(opened.status, TMFF_EXIT_DONE)
        XCTAssertGreaterThan(opened.asks, 0, "FFmpeg never asked the check while the file opened")
    }

    /// The session asks its check before each record of a decode, and a check
    /// that says stop stops it for good: its next record and every later one
    /// end with the stop (11), even once the check is taken off again. The
    /// records before are whole, HEAD first.
    func testTheSessionStopsForGoodOnceItsCheckSaysStop() throws {
        let path = try formatSampleURL("wma/tones-wma1.wma").path
        let outcome = try engine.run(limit: 30) { _ -> (head: String, statuses: [Int32]) in
            let asks = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            asks.initialize(to: 0)
            defer { asks.deallocate() }
            let descriptor = tmff_open_regular_file(path)
            guard descriptor >= 0 else { return ("", []) }
            defer { close(descriptor) }
            var status = TMFF_EXIT_DONE
            guard let session = tmff_session_open_checked(descriptor, "asf", TMFF_SESSION_DECODE, Self.neverStop, asks, &status) else {
                return ("", [status])
            }
            defer { tmff_session_close(session) }
            var bytes: UnsafePointer<UInt8>?
            var length = 0
            var statuses = [tmff_session_next(session, &bytes, &length)]
            let head = bytes.map { String(decoding: UnsafeBufferPointer(start: $0, count: min(4, length)), as: UTF8.self) } ?? ""
            tmff_session_set_stop_check(session, Self.stopAtOnce, asks)
            statuses.append(tmff_session_next(session, &bytes, &length))
            tmff_session_set_stop_check(session, nil, nil)
            statuses.append(tmff_session_next(session, &bytes, &length))
            return (head, statuses)
        }
        XCTAssertEqual(outcome.head, "HEAD")
        XCTAssertEqual(outcome.statuses, [TMFF_EXIT_DONE, TMFF_EXIT_STOPPED, TMFF_EXIT_STOPPED])
    }

    // MARK: - A Call That Hangs

    /// The tool of a test whose decode is stuck: the app's own session for
    /// the probe, a `StuckSession` for the decode, an engine with `grace`
    /// seconds before it abandons a call, and `seconds` for every limit.
    private func stuckDecodeTool(grace: TimeInterval, seconds: TimeInterval) -> FFmpegAudioConverter.Tool {
        let gate = makeGate()
        var tool = ffmpegTool(helper: try? bundledFFmpegHelper(), seconds: seconds)
        tool.engine = InProcessEngine(name: "test-FFmpeg-stuck", work: "the audio conversion", grace: grace)
        tool.openSession = { file, demuxer, mode, call -> (session: (any InProcessFFmpegSession)?, status: Int32) in
            if mode == .probe { return LinkedFFmpegSession.open(file, demuxer: demuxer, mode: mode, call: call) }
            return (session: StuckSession(gate: gate), status: TMFF_EXIT_DONE)
        }
        return tool
    }

    /// Whether `sentence` is the engine's for a call abandoned past its time,
    /// in whatever whole seconds it names (the call's limit is what the run
    /// had left).
    private func isAbandonedSentence(_ sentence: String?) -> Bool {
        guard let sentence else { return false }
        return sentence.hasPrefix("TextMouth stopped the audio conversion because it ran longer than ")
            && sentence.hasSuffix(", and won't try again until TextMouth is closed and opened again.")
    }

    /// A decode stuck past its limit and the engine's grace is abandoned: the
    /// conversion fails at once in the engine's sentence, nothing is left
    /// beside the source, and every later conversion on that engine is
    /// refused at once, in the engine's other sentence, until TextMouth is
    /// closed and opened again.
    func testACallStuckPastItsLimitIsAbandonedAndLaterConversionsRefused() async throws {
        let wma = try copyOfFormatSample("wma/tones-wma1.wma", named: "tones.wma")
        let tool = stuckDecodeTool(grace: 0.3, seconds: TestMachine.allowed(2))
        let started = Date()
        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: tool)
            XCTFail("a stuck decode was not abandoned")
        } catch let failure as InProcessEngine.Failure {
            guard case .abandoned(work: "the audio conversion", _) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(isAbandonedSentence(failure.errorDescription), failure.errorDescription ?? "no sentence")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(12), "the caller waited for the stuck call")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: wma.deletingLastPathComponent().path), ["tones.wma"])
        XCTAssertTrue(tool.engine.hasAbandonedACall)
        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: tool)
            XCTFail("a conversion after an abandoned call ran")
        } catch let failure as InProcessEngine.Failure {
            XCTAssertEqual(failure, .refused(work: "the audio conversion"))
            XCTAssertEqual(
                failure.errorDescription,
                "TextMouth stopped the audio conversion earlier because it took too long, "
                    + "and won't try again until TextMouth is closed and opened again."
            )
        }
    }

    /// Through the import's own path the listener hears the engine's sentence
    /// after the import's own words, and nothing is added to the library.
    func testAnImportWhoseDecodeIsStuckSaysTheEnginesSentence() throws {
        let wma = try copyOfFormatSample("wma/tones-wma1.wma", named: "tones.wma")
        let tool = stuckDecodeTool(grace: 0.3, seconds: TestMachine.allowed(2))
        let libraryBefore = try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path).sorted()
        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(tool) { try FileImportService.importFileWithReport(from: wma) }) { error in
            let sentence = (error as? ImportFailure)?.errorDescription ?? ""
            let start = "Could not import “tones.wma”. Converting its audio failed: "
            XCTAssertTrue(sentence.hasPrefix(start), sentence)
            XCTAssertTrue(isAbandonedSentence(String(sentence.dropFirst(start.count))), sentence)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path).sorted(), libraryBefore)
    }

    // MARK: - The Run's Time

    /// The run's whole time is the limit's, counted from its start by the
    /// tool's clock over every call and the reader's work between them, as
    /// the watchdog counts a helper's: each call may take no more than the
    /// run has left (25, 15, then 5 seconds, as each record moves the clock
    /// on 10), and once the time is spent the run ends as the watchdog's kill
    /// for running too long, in the Mac's words. The session is freed once.
    func testTheRunsTimeIsTheMacsCountedFromItsStart() async throws {
        let clock = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_000)
        let session = ClockSession(clock: clock, step: 10)
        var tool = ffmpegTool(helper: try bundledFFmpegHelper())
        tool.engine = engine
        tool.uptime = { clock.withLock { $0 } }
        tool.openSession = { _, _, _, _ in (session: session, status: TMFF_EXIT_DONE) }
        let limits = WatchedProcess.Limits(maximumSeconds: 25, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 60)
        let (ending, pieces) = try await FFmpegAudioConverter.runInProcess(
            .decode, of: try formatSampleURL("wma/tones-wma1.wma"), demuxer: "asf", limits: limits, using: tool
        ) { nextPiece -> Int in
            var count = 0
            while try await !nextPiece().isEmpty { count += 1 }
            return count
        }
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .killed(.tookTooLong(seconds: 25))))
        XCTAssertEqual(try pieces.get(), 3)
        XCTAssertEqual(session.limits.withLock { $0 }, [25, 15, 5])
        XCTAssertEqual(session.closes.withLock { $0 }, 1)
        let failure = FFmpegAudioConverter.failure(
            of: ending, read: pieces, fileName: "tones.wma", kind: "WMA", limits: limits, logTag: "AUDIO_CONVERSION_KILLED"
        )
        XCTAssertEqual(failure?.localizedDescription, "Converting tones.wma was stopped because it ran longer than 25 seconds.")
    }

    /// A call that gives no record for the stall limit is told to stop
    /// through its check (the stand-in asks it, as FFmpeg's reading does), and
    /// the run ends as the watchdog's kill for output that did not grow, long
    /// before the run's own time is spent.
    func testACallThatGivesNoRecordForTheStallIsStopped() async throws {
        var tool = ffmpegTool(helper: try bundledFFmpegHelper())
        tool.engine = engine
        tool.openSession = { _, _, _, _ in (session: HangingStandInSession(seconds: 30), status: TMFF_EXIT_DONE) }
        let limits = WatchedProcess.Limits(maximumSeconds: 120, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 0.3)
        let started = Date()
        let (ending, _) = try await FFmpegAudioConverter.runInProcess(
            .probe, of: try formatSampleURL("wma/tones-wma1.wma"), demuxer: "asf", limits: limits, using: tool
        ) { nextPiece in try await nextPiece() }
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .killed(.madeNoProgress(seconds: 0.3))))
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(5))
        XCTAssertFalse(engine.hasAbandonedACall, "a call that asks its check was abandoned")
    }
}

// MARK: - The Stand-In Sessions of These Tests

/// A stand-in session whose records never come and which never asks the stop
/// check, as FFmpeg would be stuck inside a decoder: it waits on `gate`, which
/// the test opens when it ends.
private final class StuckSession: InProcessFFmpegSession {
    let gate: DispatchSemaphore

    init(gate: DispatchSemaphore) {
        self.gate = gate
    }

    func next(asking call: InProcessEngine.Call) -> (status: Int32, record: [UInt8]) {
        _ = gate.wait(timeout: .now() + 30)
        return (TMFF_EXIT_DONE, [])
    }

    func close() {}
}

/// A stand-in session whose every record moves a scripted clock on by `step`
/// seconds, and which keeps each call's limit and counts its closes: a stream
/// of HEAD records, never ending by itself.
private final class ClockSession: InProcessFFmpegSession {
    let clock: OSAllocatedUnfairLock<TimeInterval>
    let step: TimeInterval
    let limits = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
    let closes = OSAllocatedUnfairLock(initialState: 0)

    init(clock: OSAllocatedUnfairLock<TimeInterval>, step: TimeInterval) {
        self.clock = clock
        self.step = step
    }

    func next(asking call: InProcessEngine.Call) -> (status: Int32, record: [UInt8]) {
        limits.withLock { $0.append(call.limit) }
        clock.withLock { $0 += step }
        return (TMFF_EXIT_DONE, FFmpegTestStream.head())
    }

    func close() { closes.withLock { $0 += 1 } }
}
