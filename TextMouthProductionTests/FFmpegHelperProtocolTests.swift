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

    /// Once its file is open the helper confines itself (the pure-computation
    /// sandbox): the file it holds still reads, and the hosts file is not
    /// opened and no network connection is made, both refused by the sandbox
    /// (EPERM), and the processor features FFmpeg found before it (which its
    /// sysctl calls could not find after) are kept. The Debug helper's own proof of it (`confinement`, which a
    /// Release helper does not have) says so, and exits 0 only when all
    /// four are as they must be; the decode tests that follow it in this
    /// class and `FFmpegImportRealTests` show FFmpeg works confined.
    func testTheHelperConfinesItselfOnceItsFileIsOpen() async throws {
        let wma = try formatSampleURL("wma/tones-wma1.wma")
        let run = try await runHelper(["confinement", "asf", wma.path])
        XCTAssertEqual(String(decoding: run.bytes, as: UTF8.self), "input=readable\nhosts=refused\nsocket=refused\ncpu=kept\n")
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        // It opens its file first: a file that cannot be opened is unreadable, not unconfined.
        let missing = try makeSandboxDirectory("FFmpegConfinement").appendingPathComponent("missing.wma")
        let refused = try await runHelper(["confinement", "asf", missing.path])
        XCTAssertEqual(refused.ending, WatchedProcess.Ending(outcome: .exited(status: 2)))
        XCTAssertEqual(refused.bytes, [])
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

    /// The times a signal crosses zero in `samples`: the sign changes, which a
    /// pure tone has twice for each cycle, so they tell its pitch.
    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        var count = 0
        var previous: Float?
        for sample in samples where sample != 0 {
            if let previous, (previous < 0) != (sample < 0) { count += 1 }
            previous = sample
        }
        return count
    }

    /// Sound that changes its form partway is converted to the first form,
    /// not refused (FU-FFMPEG2): `mka/mp3-form-changes.mka` is a second of
    /// 440 Hz in 22,050 Hz mono, a second of 880 Hz in 44,100 Hz stereo, and
    /// a second of 660 Hz in 22,050 Hz mono again, joined byte for byte. The
    /// helper ends with 0 and writes all of it in the first stretch's form
    /// (22,050 Hz, one channel, floating point): the length is the stretches'
    /// own, the reader's END count agrees (it checks), and each stretch keeps
    /// its pitch, so the middle one was resampled and mixed down, not dropped
    /// or played at the wrong speed.
    func testSoundThatChangesItsFormIsConvertedToTheFirstOne() async throws {
        let sample = try formatSampleURL("mka/mp3-form-changes.mka")
        let run = try await runHelper(["decode", "matroska", sample.path])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        let report = try await stream.readReport()
        XCTAssertEqual(report.sampleRate, 22_050)
        XCTAssertEqual(report.channels, 1)
        XCTAssertEqual(report.sampleFormat, .f32)
        var samples: [Float] = []
        while let block = try await stream.nextBlock() {
            samples += block.map { Float(bitPattern: UInt32(bitPattern: $0)) }
        }
        XCTAssertTrue(stream.isFinished)
        XCTAssertEqual(UInt64(samples.count), stream.framesRead, "END counts the frames of the first form")
        // The stretches decode to 23,616, 23,040 (46,080 frames at 44,100 Hz), and 23,616 frames at
        // 22,050 Hz: 70,272 in all, and the resampler's own delay is under 0.03 s.
        XCTAssertEqual(Double(samples.count), 70_272, accuracy: 700, "every stretch is there")
        // 440, 880, and 660 Hz cross zero 880, 1,760, and 1,320 times a second; each stretch's
        // middle (about 0.9 s) is read, clear of the joins, with a margin of 8 %.
        let pitches: [(name: String, span: Range<Int>, hertz: Double)] = [
            ("first", 1_000..<22_000, 440), ("second", 25_000..<45_000, 880), ("third", 48_000..<69_000, 660),
        ]
        for pitch in pitches {
            let expected = pitch.hertz * 2 * Double(pitch.span.count) / 22_050
            let found = Double(zeroCrossings(samples[pitch.span]))
            XCTAssertEqual(found, expected, accuracy: expected * 0.08, "the \(pitch.name) stretch")
            XCTAssertGreaterThan(samples[pitch.span].map { abs($0) }.max() ?? 0, 0.05, "the \(pitch.name) stretch is sound")
        }
        XCTAssertEqual([stream.refusedPackets, stream.refusedFrames], [0, 0])
    }

    /// One decoded frame past a PCM record's 1 MB is split across records and
    /// read back whole (FU-FFMPEG2): `ffmpeg-edge/flac-7.1-24bit-65535.mka` is
    /// FLAC in blocks of 65,535 samples, 8 channels, 24 bits, so each full block
    /// decodes to 2,097,120 bytes in the session's 32-bit form. Every record the
    /// reader takes is within the protocol's 1 MB (it refuses a longer one), the
    /// records are whole frames, and every one of the 132,000 frames has each
    /// channel's own constant in its own place, so a split that dropped,
    /// repeated, or shifted a sample would show.
    func testAFrameOverAMegabyteIsSplitAcrossRecordsAndReadBackWhole() async throws {
        let sample = try formatSampleURL("ffmpeg-edge/flac-7.1-24bit-65535.mka")
        let run = try await runHelper(["decode", "matroska", sample.path])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        let report = try await stream.readReport()
        XCTAssertEqual(report.channels, 8)
        XCTAssertEqual(report.bitsPerSample, 24)
        XCTAssertEqual(report.sampleFormat, .s32)
        // Each channel's constant: its number (1 to 8) times 0.01 of 24-bit full scale, truncated.
        let constants: [Int32] = [83_886, 167_772, 251_658, 335_544, 419_430, 503_316, 587_202, 671_088]
        var blocks = 0
        var wrong = 0
        while let block = try await stream.nextBlock() {
            blocks += 1
            XCTAssertLessThanOrEqual(block.count * 4, 1_048_576, "a record is within the protocol's 1 MB")
            XCTAssertEqual(block.count % 8, 0, "a record holds whole frames")
            for (index, sample) in block.enumerated() where sample != constants[index % 8] {
                wrong += 1
            }
        }
        XCTAssertEqual(wrong, 0, "samples out of their place or changed")
        XCTAssertEqual(stream.framesRead, 132_000)
        // Two blocks of 2 MB, each in at least two records, and the 930 frames left over.
        XCTAssertGreaterThanOrEqual(blocks, 5)
        XCTAssertTrue(stream.isFinished)
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
