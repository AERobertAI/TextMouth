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
        // Its run and its engine count only the time TextMouth runs (B18), by the app's one clock.
        XCTAssertTrue(FFmpegAudioConverter.Tool.bundled.clock === RunningClock.app)
        XCTAssertTrue(FFmpegAudioConverter.sessionEngine.clock === RunningClock.app)
    }

    // MARK: - The Stop Check

    /// A call of the test's engine whose work has ended, which never says
    /// stop: the call a `SessionStopCheck` of the test's own is made for.
    private func finishedCall() throws -> InProcessEngine.Call {
        try engine.run(limit: 600) { call in call }
    }


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

    /// A stop check that counts its asks in the first of the two `Int32`s its
    /// context points at, and says stop from the ask the second one names
    /// (0: never).
    private static var stopAtAsk: tmff_stop_check {
        { context in
            guard let counts = context?.assumingMemoryBound(to: Int32.self) else { return 0 }
            counts[0] += 1
            return counts[1] > 0 && counts[0] >= counts[1] ? 1 : 0
        }
    }

    /// What opening the file at `file` with `demuxer` in a probe gave, on the
    /// test's engine, with a check that says stop from its `stopAt`th ask (0:
    /// never): the session's status, how often the check was asked, and how
    /// far into the file the session had read, the descriptor's offset; the
    /// session, opened or not, is closed.
    private func open(_ file: URL, demuxer: String, stopAt: Int32) throws -> (status: Int32, asks: Int32, offset: off_t) {
        let path = file.path
        return try engine.run(limit: 30) { _ in
            let counts = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
            counts.initialize(repeating: 0, count: 2)
            counts[1] = stopAt
            defer { counts.deallocate() }
            let descriptor = tmff_open_regular_file(path)
            guard descriptor >= 0 else { return (TMFF_EXIT_UNREADABLE, 0, -1) }
            defer { close(descriptor) }
            var status = TMFF_EXIT_DONE
            let session = tmff_session_open_checked(descriptor, demuxer, TMFF_SESSION_PROBE, Self.stopAtAsk, counts, &status)
            let offset = lseek(descriptor, 0, SEEK_CUR)
            tmff_session_close(session)
            return (status, counts[0], offset)
        }
    }

    /// The session's check is asked as a file opens, and its answer ends the
    /// open: one that says stop from its first ask ends it with the session's
    /// stop (11), before any record, and one that never says stop is asked
    /// more than once, and the file opens. Besides the session's own asks,
    /// FFmpeg asks it through the interrupt callback at its own checkpoints,
    /// and the session asks once more once FFmpeg has found the streams, since
    /// FFmpeg can finish a step it was told to stop (train 1117-1406). A
    /// call's time limit reaches FFmpeg's own reading, as the engine's
    /// `Call.stopCheck` does in the app.
    func testTheStopCheckIsAskedAsTheFileOpens() throws {
        let file = try formatSampleURL("wma/tones-wma1.wma")
        let stopped = try open(file, demuxer: "asf", stopAt: 1)
        XCTAssertEqual(stopped.status, TMFF_EXIT_STOPPED, "a check that says stop did not stop the open")
        XCTAssertGreaterThan(stopped.asks, 0)
        let opened = try open(file, demuxer: "asf", stopAt: 0)
        XCTAssertEqual(opened.status, TMFF_EXIT_DONE)
        XCTAssertGreaterThan(opened.asks, 1)
    }

    /// The session asks its check before every read of the file (review
    /// finding 2): FFmpeg never asks its interrupt callback on a read through
    /// the session's own I/O, so without the session's own ask a header read
    /// for long, or a packet read across a stream it discards, could be ended
    /// only by abandoning its call. In a file of one 1 MB packet (an FLV of
    /// one PCM tag), a check that says stop from its first ask leaves the
    /// file unread, and one that says stop from its second leaves it read
    /// once at most, a 64 KB buffer, where a check left to say go lets the
    /// open read the whole packet.
    func testTheSessionAsksItsCheckBeforeEachReadOfTheFile() throws {
        let file = try flvOfOnePCMTag(samples: 1_000_000, named: "one-packet.flv")
        let unread = try open(file, demuxer: "flv", stopAt: 1)
        XCTAssertEqual(unread.status, TMFF_EXIT_STOPPED)
        XCTAssertEqual(unread.offset, 0, "the session read the file before asking its check")
        let readOnce = try open(file, demuxer: "flv", stopAt: 2)
        XCTAssertEqual(readOnce.status, TMFF_EXIT_STOPPED)
        XCTAssertLessThanOrEqual(readOnce.offset, 65_536, "the session read on after its check said stop")
        let whole = try open(file, demuxer: "flv", stopAt: 0)
        XCTAssertEqual(whole.status, TMFF_EXIT_DONE)
        XCTAssertGreaterThan(whole.offset, 1_000_000, "the open did not read the packet: the file is too short to show the asks")
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
        tool.openSession = { file, demuxer, mode, check -> (session: (any InProcessFFmpegSession)?, status: Int32) in
            if mode == .probe { return LinkedFFmpegSession.open(file, demuxer: demuxer, mode: mode, check: check) }
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

    /// A call abandoned past its time is told by the limit that cut it (the
    /// FMT54 review, finding 5): by a scripted clock, two records spend 20 of
    /// a run's 20.5 seconds, and the third call, allowed what is left, half a
    /// second, hangs: its sentence names the run's time, rounded up to 21
    /// seconds, not the half second that cut it. A call that hangs with the
    /// run's time to spare is told by the stall, the most one call may take.
    func testAnAbandonedCallIsToldByTheLimitThatCutIt() async throws {
        /// How a decode of a session that hangs at its `stuckAt`th record, each
        /// record before it spending `step` seconds of the run's clock, ends
        /// under `limits`, on an engine of its own with a grace of 0.3 seconds.
        func abandonment(limits: WatchedProcess.Limits, step: TimeInterval, stuckAt: Int) async throws -> InProcessEngine.Failure? {
            let clock = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_000)
            let session = ClockThenStuckSession(clock: clock, step: step, stuckAt: stuckAt, gate: makeGate())
            var tool = ffmpegTool(helper: try bundledFFmpegHelper())
            tool.engine = InProcessEngine(name: "test-FFmpeg-cut", work: "the audio conversion", grace: 0.3)
            tool.clock = RunningClock(countingWhole: { clock.withLock { $0 } })
            tool.openSession = { _, _, _, _ in (session: session, status: TMFF_EXIT_DONE) }
            let (_, read) = try await FFmpegAudioConverter.runInProcess(
                .decode, of: try formatSampleURL("wma/tones-wma1.wma"), demuxer: "asf", limits: limits, using: tool
            ) { nextPiece -> Int in
                var count = 0
                while try await !nextPiece().isEmpty { count += 1 }
                return count
            }
            guard case let .failure(error) = read else { return nil }
            return error as? InProcessEngine.Failure
        }
        let cut = try await abandonment(
            limits: WatchedProcess.Limits(maximumSeconds: 20.5, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 60),
            step: 10, stuckAt: 3
        )
        XCTAssertEqual(cut, .abandoned(work: "the audio conversion", limit: 20.5))
        XCTAssertEqual(
            cut?.errorDescription,
            "TextMouth stopped the audio conversion because it ran longer than 21 seconds, "
                + "and won't try again until TextMouth is closed and opened again."
        )
        let stalled = try await abandonment(
            limits: WatchedProcess.Limits(maximumSeconds: 120, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 0.4),
            step: 0, stuckAt: 1
        )
        XCTAssertEqual(stalled, .abandoned(work: "the audio conversion", limit: 0.4))
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

    // MARK: - The Memory Floor

    /// A megabyte, in bytes.
    private static let megabyte = 1_048_576

    /// A decode of the sample `sample` in the app, on the test's engine, with
    /// the app's memory as `available` says it, by a floor of 512 MB: how it
    /// ended, and how many records it gave.
    private func decode(
        _ sample: URL,
        demuxer: String,
        memory available: @escaping @Sendable () -> Int
    ) async throws -> (ending: WatchedProcess.Ending, read: Result<Int, any Error>, limits: WatchedProcess.Limits) {
        var tool = ffmpegTool(helper: try bundledFFmpegHelper())
        tool.engine = engine
        tool.memoryFloor = SessionMemoryFloor(bytes: 512 * Self.megabyte, available: available)
        let limits = WatchedProcess.Limits(maximumSeconds: 60, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 60)
        let (ending, read) = try await FFmpegAudioConverter.runInProcess(
            .decode, of: sample, demuxer: demuxer, limits: limits, using: tool
        ) { nextPiece -> Int in
            var count = 0
            while try await !nextPiece().isEmpty { count += 1 }
            return count
        }
        return (ending, read, limits)
    }

    /// The memory a scripted system says the app has left: `atStart` as the
    /// run begins, its first reading, and `after` from then on.
    private static func memory(atStart: Int, after: Int) -> @Sendable () -> Int {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        return {
            readings.withLock { count -> Int in
                count += 1
                return count == 1 ? atStart : after
            }
        }
    }

    /// A floor under the app's free memory (the FMT54 review, finding 4) is
    /// crossed only when the system says how much is left and it is less than
    /// the run's floor: the simulator sets the app no limit (0 left), which
    /// never stops a session. The app's floor is 512 MB, read from the system.
    func testTheMemoryFloorIsCrossedOnlyBelowItWithALimit() throws {
        let megabyte = Self.megabyte
        for (left, crossed) in [(0, false), (100 * megabyte, true), (511 * megabyte, true), (512 * megabyte, false), (2_000 * megabyte, false)] {
            let memory = SessionMemoryFloor(bytes: 512 * megabyte, available: { left }).run(beganWith: 4_000 * megabyte)
            let check = SessionStopCheck(call: try finishedCall(), memory: memory)
            XCTAssertEqual(check.shouldStop, crossed, "\(left / megabyte) MB left")
            XCTAssertEqual(check.memoryLeftWhenStopped, crossed ? left : nil)
        }
        XCTAssertEqual(SessionMemoryFloor.app.bytes, 512 * megabyte)
        XCTAssertEqual(FFmpegAudioConverter.Tool.bundled.memoryFloor.bytes, 512 * megabyte)
    }

    /// The system's 0 means no limit only in the simulator, where the
    /// iPhone's tests run; on an iPhone it means the app is over its limit
    /// already, which stops a session at its first ask, even in a run that
    /// began with nothing left (the check of the FMT54 review's fixes, item
    /// 3). The app's floor knows which it is.
    func testZeroLeftStopsASessionOnAnIPhoneAndNotInTheSimulator() throws {
        let megabyte = Self.megabyte
        let phone = SessionMemoryFloor(bytes: 512 * megabyte, available: { 0 }, zeroMeansNoLimit: false)
        let simulator = SessionMemoryFloor(bytes: 512 * megabyte, available: { 0 }, zeroMeansNoLimit: true)
        XCTAssertEqual(phone.left, 0)
        XCTAssertNil(simulator.left)
        for (floor, stops) in [(phone, true), (simulator, false)] {
            for start in [4_000 * megabyte, 0] {
                let check = SessionStopCheck(call: try finishedCall(), memory: floor.run(beganWith: start))
                XCTAssertEqual(check.shouldStop, stops, "zero means no limit: \(floor.zeroMeansNoLimit), \(start / megabyte) MB at the start")
            }
        }
        XCTAssertTrue(SessionMemoryFloor.onSimulator, "the iPhone's tests run in the simulator")
        XCTAssertEqual(SessionMemoryFloor.app.zeroMeansNoLimit, SessionMemoryFloor.onSimulator)
    }

    /// A run keeps 512 MB free, or half of what the app had left as it began
    /// when that is less, and holds FFmpeg to allocations of half its floor,
    /// never more than 256 MB (the check of the FMT54 review's fixes, item
    /// 2): so a phone that begins short of memory still converts an ordinary
    /// file, and no allocation between two asks crosses from above the floor
    /// to the app's limit. A run with no limit known keeps the app's.
    func testARunKeepsHalfOfWhatItBeganWithWhenThatIsLess() {
        let megabyte = Self.megabyte
        let floor = SessionMemoryFloor(bytes: 512 * megabyte, available: { 0 })
        let plans = [nil, 4_000, 1_024, 600, 100].map { (megabytes: Int?) -> [Int] in
            let run = floor.run(beganWith: megabytes.map { $0 * megabyte })
            return [run.floor / megabyte, run.allocationCap / megabyte, run.beganShort ? 1 : 0]
        }
        XCTAssertEqual(plans, [[512, 256, 0], [512, 256, 0], [512, 256, 0], [300, 150, 1], [50, 25, 1]])
    }

    /// A session that leaves the app less memory than its run's floor is
    /// stopped, asked as it reads the file, and the run says what the app's
    /// memory grew by since it began, the import's other conversions counted
    /// with it: by a scripted system that has 2,000 MB left as the run begins
    /// and 300 MB from the session's first ask on, "Converting tones.wma was
    /// stopped because the app's memory grew by more than 1700 MB while it
    /// ran."
    func testASessionThatLeavesTooLittleMemorySaysWhatTheAppsMemoryGrewBy() async throws {
        let megabyte = Self.megabyte
        let (ending, read, limits) = try await decode(
            try formatSampleURL("wma/tones-wma1.wma"), demuxer: "asf",
            memory: Self.memory(atStart: 2_000 * megabyte, after: 300 * megabyte)
        )
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .killed(.memoryGrew(bytes: Int64(1_700 * megabyte)))))
        XCTAssertEqual(try read.get(), 0, "the session gave a record past the floor")
        let failure = FFmpegAudioConverter.failure(
            of: ending, read: read, fileName: "tones.wma", kind: "WMA", limits: limits, logTag: "AUDIO_CONVERSION_KILLED"
        )
        XCTAssertEqual(failure?.localizedDescription, "Converting tones.wma was stopped because the app's memory grew by more than 1700 MB while it ran.")
    }

    /// A phone that begins a conversion short of memory, 400 MB free, keeps
    /// half of it (the check of the FMT54 review's fixes, item 2): with 300 MB
    /// left all along the file converts, where the app's floor of 512 MB
    /// would have stopped it at the first ask; with 150 MB left it is stopped,
    /// in its own words: "Converting tones.wma was stopped because the iPhone
    /// had only 400 MB of memory free when it began, and TextMouth keeps half
    /// of that free."
    func testARunThatBeginsShortOfMemoryKeepsHalfOfIt() async throws {
        let megabyte = Self.megabyte
        let wma = try formatSampleURL("wma/tones-wma1.wma")
        let converted = try await decode(wma, demuxer: "asf", memory: Self.memory(atStart: 400 * megabyte, after: 300 * megabyte))
        XCTAssertEqual(converted.ending, WatchedProcess.Ending(outcome: .exited(status: TMFF_EXIT_DONE)))
        XCTAssertGreaterThan(try converted.read.get(), 0)
        let (ending, read, limits) = try await decode(wma, demuxer: "asf", memory: Self.memory(atStart: 400 * megabyte, after: 150 * megabyte))
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .killed(.beganShortOfMemory(freeBytes: Int64(400 * megabyte)))))
        let failure = FFmpegAudioConverter.failure(
            of: ending, read: read, fileName: "tones.wma", kind: "WMA", limits: limits, logTag: "AUDIO_CONVERSION_KILLED"
        )
        XCTAssertEqual(
            failure?.localizedDescription,
            "Converting tones.wma was stopped because the iPhone had only 400 MB of memory free when it began, "
                + "and TextMouth keeps half of that free."
        )
    }

    /// A run that began short of memory holds FFmpeg to allocations of half
    /// its floor: begun with 40 MB free (a floor of 20 MB), FFmpeg may take
    /// only 10 MB at once, so a file whose one packet of 6 MB of A-law decodes
    /// to a frame of 12 MB stops with the session's status for an allocation
    /// refused (9), where a roomy run decodes it whole.
    func testARunThatBeganShortHoldsFFmpegToSmallerAllocations() async throws {
        let megabyte = Self.megabyte
        let file = try flvOfOnePCMTag(samples: 6_000_000, aLaw: true, named: "twelve-megabytes-decoded.flv")
        let short = try await decode(file, demuxer: "flv", memory: { 40 * megabyte })
        XCTAssertEqual(short.ending, WatchedProcess.Ending(outcome: .exited(status: TMFF_EXIT_MEMORY)))
        let roomy = try await decode(file, demuxer: "flv", memory: { 4_000 * megabyte })
        XCTAssertEqual(roomy.ending, WatchedProcess.Ending(outcome: .exited(status: TMFF_EXIT_DONE)))
    }

    // MARK: - The Run's Time

    /// A run frozen while iOS keeps TextMouth suspended has spent none of its
    /// whole time there (B18): five minutes of uptime pass in one jump after
    /// its second record, as while the listener is in another app, and the
    /// run of a 25-second limit still reads to its end, where the system's
    /// uptime would have stopped it as running too long.
    func testARunSuspendedBetweenItsCallsIsNotStoppedForTime() async throws {
        let uptime = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_000)
        let session = SuspendingSession(uptime: uptime, records: 4, suspendedAfter: 2)
        var tool = ffmpegTool(helper: try bundledFFmpegHelper())
        tool.engine = engine
        tool.clock = RunningClock(uptime: { uptime.withLock { $0 } }, longestStep: 1, tick: nil)
        tool.openSession = { _, _, _, _ in (session: session, status: TMFF_EXIT_DONE) }
        let limits = WatchedProcess.Limits(maximumSeconds: 25, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 60)
        let (ending, pieces) = try await FFmpegAudioConverter.runInProcess(
            .decode, of: try formatSampleURL("wma/tones-wma1.wma"), demuxer: "asf", limits: limits, using: tool
        ) { nextPiece -> Int in
            var count = 0
            while try await !nextPiece().isEmpty { count += 1 }
            return count
        }
        XCTAssertEqual(ending, WatchedProcess.Ending(outcome: .exited(status: TMFF_EXIT_DONE)))
        XCTAssertEqual(try pieces.get(), 4)
    }

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
        tool.clock = RunningClock(countingWhole: { clock.withLock { $0 } })
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

    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
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

    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        let limit = check.call.limit
        limits.withLock { $0.append(limit) }
        clock.withLock { $0 += step }
        return (TMFF_EXIT_DONE, FFmpegTestStream.head())
    }

    func close() { closes.withLock { $0 += 1 } }
}

/// A stand-in session of `records` HEAD records and then END, which moves a
/// scripted uptime on by five minutes as it gives its `suspendedAfter`th
/// record, as a suspension between two calls would (B18).
private final class SuspendingSession: InProcessFFmpegSession {
    let uptime: OSAllocatedUnfairLock<TimeInterval>
    let records: Int
    let suspendedAfter: Int
    private let given = OSAllocatedUnfairLock(initialState: 0)

    init(uptime: OSAllocatedUnfairLock<TimeInterval>, records: Int, suspendedAfter: Int) {
        self.uptime = uptime
        self.records = records
        self.suspendedAfter = suspendedAfter
    }

    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        let number = given.withLock { count -> Int in
            count += 1
            return count
        }
        if number == suspendedAfter { uptime.withLock { $0 += 300 } }
        return number <= records ? (TMFF_EXIT_DONE, FFmpegTestStream.head()) : (TMFF_EXIT_DONE, [])
    }

    func close() {}
}

/// A stand-in session whose records before its `stuckAt`th each move a
/// scripted clock on by `step` seconds, and which then never gives one, nor
/// asks its check, as FFmpeg stuck inside a decoder: it waits on `gate`, which
/// the test opens when it ends.
private final class ClockThenStuckSession: InProcessFFmpegSession {
    let clock: OSAllocatedUnfairLock<TimeInterval>
    let step: TimeInterval
    let stuckAt: Int
    let gate: DispatchSemaphore
    private let given = OSAllocatedUnfairLock(initialState: 0)

    init(clock: OSAllocatedUnfairLock<TimeInterval>, step: TimeInterval, stuckAt: Int, gate: DispatchSemaphore) {
        self.clock = clock
        self.step = step
        self.stuckAt = stuckAt
        self.gate = gate
    }

    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        let number = given.withLock { count -> Int in
            count += 1
            return count
        }
        guard number < stuckAt else {
            _ = gate.wait(timeout: .now() + 30)
            return (TMFF_EXIT_DONE, [])
        }
        clock.withLock { $0 += step }
        return (TMFF_EXIT_DONE, FFmpegTestStream.head())
    }

    func close() {}
}
