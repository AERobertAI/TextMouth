import XCTest
@testable import TextMouth

/// The FFmpeg helper the app carries, TextMouthFFmpeg (FMT50), read as the
/// app reads it: the stream it writes (TextMouthFFmpegProtocol.h), the exit
/// status of each refusal, the 4 KB cut of a tag, and the import's Stop,
/// which kills it. Every file here is a real sample or no file at all:
/// damaged media, which could crash the helper, are read only on GitHub
/// (`FFmpegHelperHostileFileTests`).
final class FFmpegHelperProtocolTests: XCTestCase {
    /// Runs the app's helper with `arguments`, under limits of a few seconds,
    /// and returns how it ended and everything it wrote.
    private func runHelper(_ arguments: [String]) async throws -> (ending: WatchedProcess.Ending, bytes: [UInt8]) {
        let helper = try bundledFFmpegHelper()
        let seconds = TestMachine.allowed(20)
        let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
        let (ending, read) = try await WatchedProcess.runStreaming(helper, arguments: arguments, watching: nil, limits: limits) { pipe in
            var bytes: [UInt8] = []
            while true {
                let piece = try await pipe.read(upTo: 1 << 16)
                if piece.isEmpty { return bytes }
                bytes += piece
            }
        }
        return (ending, try read.get())
    }

    /// The decoder is opened with one thread, set before `avcodec_open2`: FFmpeg's
    /// default is one too, but only a line of the session's own keeps it so, and
    /// the helper's signal guard covers the thread it decodes on. No decoder of
    /// this build shows its thread count to a test, so the session's source is
    /// read: the setting comes first, then the call that starts the threads.
    func testTheDecoderIsOpenedWithOneThread() throws {
        let path = AppSourceFile.folder.deletingLastPathComponent().appendingPathComponent("TextMouthFFmpeg/Session/session.c")
        let source = try String(contentsOf: path, encoding: .utf8)
        let setting = try XCTUnwrap(source.range(of: "decoder->thread_count = 1;"), "the decoder's thread count is not set")
        let opening = try XCTUnwrap(source.range(of: "avcodec_open2("), "the decoder is not opened")
        XCTAssertLessThan(setting.lowerBound, opening.lowerBound, "the thread count must be set before the decoder opens")
    }

    /// The probe of a WMA file is the protocol's stream: HEAD of version 1,
    /// INFO of the file's one WMA 1 stream, its tags and three chapters, and
    /// an END of no frames; the helper exits 0.
    func testTheProbeWritesTheProtocolsStream() async throws {
        let wma = try formatSampleURL("wma/tones-wma1.wma")
        let run = try await runHelper(["probe", "asf", wma.path])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        // HEAD, as its four letters, then its length, then the version 1, is the first record.
        XCTAssertEqual(Array(run.bytes.prefix(4)), Array("HEAD".utf8))
        XCTAssertEqual(Array(run.bytes.dropFirst(8).prefix(4)), [1, 0, 0, 0])
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        let report = try await stream.readReport()
        XCTAssertEqual(report.formatName, "asf")
        XCTAssertEqual(report.codecName, "wmav1")
        XCTAssertEqual([report.sampleRate, report.channels.map(Double.init)], [22_050, 1])
        XCTAssertEqual(report.tags["title"], "Three Tones")
        XCTAssertEqual(report.chapters.map(\.title), ["Tone 440 Hz", "Tone 660 Hz - second", "Tone 880 Hz (café)"])
        let block = try await stream.nextBlock()
        XCTAssertNil(block)
        XCTAssertTrue(stream.isFinished)
    }

    /// A decode hands over every frame it decodes, and its END counts them
    /// (which the reader checks): four seconds of WMA at 22,050 Hz.
    func testADecodeCountsEveryFrameItWrites() async throws {
        let wma = try formatSampleURL("wma/tones-wma1.wma")
        let run = try await runHelper(["decode", "asf", wma.path])
        XCTAssertEqual(run.ending.outcome, .exited(status: 0))
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        _ = try await stream.readReport()
        var samples = 0
        while let block = try await stream.nextBlock() {
            samples += block.count
        }
        XCTAssertEqual(UInt64(samples), stream.framesRead)
        XCTAssertEqual(Double(stream.framesRead) / 22_050, 4, accuracy: 0.1)
        XCTAssertEqual([stream.refusedPackets, stream.refusedFrames], [0, 0])
    }

    /// Each refusal is the protocol's exit status, with nothing written: a
    /// missing file, a folder, and a FIFO (never waited on) are unreadable
    /// (2); a demuxer this build has not is 10; a file of another container
    /// is not recognized (3); a wrong mode or count of arguments is a usage
    /// error (1).
    func testEachRefusalHasItsExitStatus() async throws {
        let folder = try makeSandboxDirectory("FFmpegRefusals")
        let fifo = folder.appendingPathComponent("pipe.wma")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let wma = try formatSampleURL("wma/tones-wma1.wma").path
        let cases: [([String], Int32)] = [
            (["probe", "asf", folder.appendingPathComponent("missing.wma").path], 2),
            (["probe", "asf", folder.path], 2),
            (["decode", "asf", fifo.path], 2),
            (["probe", "nosuchdemuxer", wma], 10),
            (["probe", "asf", try formatSampleURL("mp3-chapters/three-tones.mp3").path], 3),
            (["play", "asf", wma], 1),
            (["probe", "asf"], 1),
            ([], 1),
        ]
        let started = Date()
        for (arguments, status) in cases {
            let run = try await runHelper(arguments)
            XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: status)), "\(arguments)")
            XCTAssertEqual(run.bytes, [], "\(arguments)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(20), "no refusal may wait")
    }

    /// A tag longer than 4 KB is cut at 4 KB, between two characters (the
    /// TODO's FU-FFMPEG item): the sample's title of "Long" and 3,000 "é"
    /// (6,004 bytes) comes back as its first 4,096 bytes.
    func testALongTagIsCutAtFourKilobytes() async throws {
        let sample = try formatSampleURL("mka/tones-long-title.mka")
        let run = try await runHelper(["probe", "matroska", sample.path])
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        let report = try await stream.readReport()
        let title = try XCTUnwrap(report.tags["title"])
        XCTAssertEqual(title.utf8.count, 4_096)
        XCTAssertEqual(title, "Long" + String(repeating: "é", count: 2_046))
        XCTAssertEqual(report.tags["artist"], "TextMouth Test")
    }

    /// The import's Stop kills a helper that is decoding: the conversion
    /// ends in a cancellation at once, no helper is left running, and
    /// nothing is left beside the source.
    @MainActor
    func testStopKillsTheHelperAndLeavesNothingBehind() async throws {
        let wma = try copyOfFormatSample("wma/tones-wma1.wma", named: "tones.wma")
        let (helper, log) = try ffmpegHelperStandIn(decode: .hang(seconds: 60))
        let tool = ffmpegTool(helper: helper, seconds: 120)
        let started = Date()
        let conversion = Task { try await FFmpegAudioConverter.convert(wma, using: tool) }
        // Stopped once the decode has started.
        let deadline = Date().addingTimeInterval(TestMachine.allowed(20))
        while try standInCalls(log).count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try standInCalls(log), ["probe asf", "decode asf"])
        conversion.cancel()
        do {
            _ = try await conversion.value
            XCTFail("a stopped conversion must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(30))
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: wma.deletingLastPathComponent().path), ["tones.wma"])
    }
}
