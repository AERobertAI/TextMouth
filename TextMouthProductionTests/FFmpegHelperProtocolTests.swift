import XCTest
@testable import TextMouth

/// The FFmpeg session the app carries (FMT50), read as the app reads it: the
/// stream it writes (TextMouthFFmpegProtocol.h), the exit status of each
/// refusal, the 4 KB cut of a tag, and the import's Stop, which ends it. On
/// the Mac the session runs in the helper, TextMouthFFmpeg; on the iPhone in
/// the app itself (FMT54), where each test reads the same stream and the same
/// statuses. Every file here is a real sample or no file at all: damaged
/// media, which could crash the session, are read only on GitHub
/// (`FFmpegHelperHostileFileTests`). Shared with the iPhone's unit bundle.
final class FFmpegHelperProtocolTests: XCTestCase {
    /// Runs the app's session as the helper's command line `arguments` asks,
    /// under limits of a few seconds, and returns how it ended and everything
    /// it wrote (`runFFmpegHelper`).
    private func runHelper(_ arguments: [String]) async throws -> (ending: WatchedProcess.Ending, bytes: [UInt8]) {
        let seconds = TestMachine.allowed(20)
        let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
        return try await runFFmpegHelper(try bundledFFmpegHelper(), arguments, limits: limits)
    }

    /// Once its file is open the helper confines itself (the pure-computation
    /// sandbox): the file it holds still reads, and the hosts file is not
    /// opened and no network connection is made, both refused by the sandbox
    /// (EPERM), and the processor features FFmpeg found before it (which its
    /// sysctl calls could not find after) are kept. The Debug helper's own proof of it (`confinement`, which a
    /// Release helper does not have) says so, and exits 0 only when all
    /// four are as they must be; the decode tests that follow it in this
    /// class and `FFmpegImportRealTests` show FFmpeg works confined.
    ///
    /// Fenced to the Mac: the confinement is the helper program's own
    /// (`sandbox_init`), and the iPhone runs the session inside the app,
    /// whose own sandbox iOS gives it (FMT54).
    #if os(macOS)
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
    #endif

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

    /// The mono floating-point samples the helper writes for `sample`, and the stream that was
    /// read (its END has been checked against the frames that came), with the helper's ending.
    private func decodedMonoFloat(_ sample: String) async throws -> (samples: [Float], stream: FFmpegHelperStream) {
        let run = try await runHelper(["decode", "matroska", try formatSampleURL(sample).path])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)), sample)
        var stream = FFmpegHelperStream(data: Data(run.bytes))
        let report = try await stream.readReport()
        XCTAssertEqual([report.sampleRate, report.channels.map(Double.init)], [22_050, 1], sample)
        XCTAssertEqual(report.sampleFormat, .f32, sample)
        var samples: [Float] = []
        while let block = try await stream.nextBlock() {
            samples += block.map { Float(bitPattern: UInt32(bitPattern: $0)) }
        }
        XCTAssertTrue(stream.isFinished, sample)
        // END counts the frames of the first form, which the reader checked against the frames it got.
        XCTAssertEqual(UInt64(samples.count), stream.framesRead, sample)
        XCTAssertEqual([stream.refusedPackets, stream.refusedFrames], [0, 0], sample)
        return (samples, stream)
    }

    /// The stretches of sound in `samples`: the first and last frame of each run of frames louder
    /// than 0.05, runs split by a silence of over 200 frames (the encoder's padding between the
    /// stretches of the joined samples is that long).
    private func loudRuns(_ samples: [Float]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var last = 0
        for (index, sample) in samples.enumerated() {
            if abs(sample) > 0.05 {
                start = start ?? index
                last = index
            } else if let first = start, index - last > 200 {
                runs.append(first...last)
                start = nil
            }
        }
        if let first = start { runs.append(first...last) }
        return runs
    }

    /// Whether each run of `found` begins and ends within `tolerance` frames of `expected`'s.
    private func runs(_ found: [ClosedRange<Int>], match expected: [ClosedRange<Int>], within tolerance: Int) -> Bool {
        found.count == expected.count && zip(found, expected).allSatisfy {
            abs($0.lowerBound - $1.lowerBound) <= tolerance && abs($0.upperBound - $1.upperBound) <= tolerance
        }
    }

    /// Sound that changes its form partway is converted to the first form,
    /// not refused (FU-FFMPEG2): `mka/mp3-form-changes.mka` is a second of
    /// 440 Hz in 22,050 Hz mono, a second of 880 Hz in 44,100 Hz stereo, and
    /// a second of 660 Hz in 22,050 Hz mono again, joined byte for byte. The
    /// helper ends with 0 and writes all of it in the first stretch's form
    /// (22,050 Hz, one channel, floating point), exactly as long as its
    /// stretches are (23,616 + 23,040 + 23,616 frames, the second at half
    /// its 46,080 frames), with every stretch at its own pitch and each
    /// stretch of sound beginning and ending at its measured frame. A resampler set
    /// for the old rate at a join (the first frame after it comes with the old
    /// rate), one that is not drained on the return to the first form, and a
    /// frame lost or repeated each move the length or the join by more than the
    /// few frames allowed here.
    func testSoundThatChangesItsFormIsConvertedToTheFirstOne() async throws {
        let (samples, stream) = try await decodedMonoFloat("mka/mp3-form-changes.mka")
        XCTAssertEqual(Double(samples.count), 70_272, accuracy: 2, "every stretch, and no frame more")
        XCTAssertEqual(Double(stream.framesRead), 70_272, accuracy: 2, "END's count")
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
        // Where each stretch of sound begins and ends, as the helper writes them (measured on
        // the session as it stands; the encoder's padding and the resampler's delay are in it):
        // a stretch played at the wrong rate, a frame lost or repeated, or a resampler not
        // drained moves a later one by 16 frames or more, past the 6 allowed.
        let expected = [1_109...23_151, 24_171...46_216, 47_764...69_808]
        XCTAssertTrue(runs(loudRuns(samples), match: expected, within: 6), "\(loudRuns(samples))")
    }

    /// Sound that ends in a stretch of another form than the first is converted to its last frame
    /// (FU-FFMPEG2): `ffmpeg-edge/mp3-ends-in-a-changed-form.mka` is the 22,050 Hz mono second
    /// and the 44,100 Hz stereo second only, so the resampler is drained at the end of the sound and
    /// not on a return to the first form. The helper writes exactly 23,616 + 23,040 frames.
    func testSoundThatEndsInAChangedFormIsConvertedToItsLastFrame() async throws {
        let (samples, stream) = try await decodedMonoFloat("ffmpeg-edge/mp3-ends-in-a-changed-form.mka")
        XCTAssertEqual(Double(samples.count), 46_656, accuracy: 2, "both stretches, whole")
        XCTAssertEqual(Double(stream.framesRead), 46_656, accuracy: 2, "END's count")
        // The two stretches of sound, the second to the same frame as in the whole sample, and
        // the last 0.4 s of the file are its padding: the resampler's last frames are not lost.
        let expected = [1_109...23_151, 24_171...46_216]
        XCTAssertTrue(runs(loudRuns(samples), match: expected, within: 6), "\(loudRuns(samples))")
    }

    /// The bounds of the conversion of sound that changes its form (FU-FFMPEG2), checked on frames
    /// made up in memory, no file read: the Debug helper's `formcheck` mode (which a Release helper
    /// does not have) runs each check and writes "name=status frames=N largest=B changes=C" (the
    /// status the check ended with, the frames it wrote, the most bytes one frame it wrote held,
    /// and how many resamplers it opened).
    /// - **The rate ratio:** 16 to 1 is converted, both ways, and 17 to 1 ends with 7 (the sentence
    ///   for sound that cannot be converted).
    /// - **The size of a converted frame:** a 65,535-frame frame of 32 channels at 48,000 Hz,
    ///   converted to 768,000 Hz (268 MB in all), is fed in slices, none holding over 16 MB, and all
    ///   1,048,560 of its frames (and the first frame's 16) come out.
    /// - **A held-back frame:** ten frames of 8 samples at twice the rate, each kept whole by the
    ///   resampler, all come out in the end, as 40 frames.
    /// - **The layout:** a frame of 6 channels in the layout 6.0 after one in 5.1 is another form
    ///   (a resampler is opened), and one in 5.1 again is not.
    /// - **The changes:** 1,000 changes away from the first form and back are converted; the
    ///   1,001st ends with 7.
    ///
    /// Fenced to the Mac: `formcheck` is the Debug helper program's mode, and the iPhone
    /// compiles the same session.c, whose conversion it checks, with no program to ask.
    #if os(macOS)
    func testTheBoundsOfTheConversionOnMadeUpFrames() async throws {
        let run = try await runHelper(["formcheck", "all", "-"])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        /// Each line's status, frames, largest, changes, and silence, by name.
        var checks: [String: (status: Int, frames: Int, largest: Int, changes: Int, silence: Int)] = [:]
        for line in String(decoding: run.bytes, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
            guard parts.count == 10, let status = Int(parts[1]), let frames = Int(parts[3]), let largest = Int(parts[5]),
                  let changes = Int(parts[7]), let silence = Int(parts[9]) else {
                XCTFail("a line that is not name=status frames=N largest=B changes=C silence=S: \(line)")
                continue
            }
            checks[parts[0]] = (status, frames, largest, changes, silence)
        }
        XCTAssertEqual(Set(checks.keys), ["ratio-up-16", "ratio-up-17", "ratio-down-16", "ratio-down-17", "cap", "held-back", "layout-same", "layout-other", "changes-1000", "changes-1001",
                                          "silence-timed", "silence-untimed", "silence-ends", "silence-none", "silence-absurd", "silence-at-bound", "silence-claimed", "silence-sums",
                                          "silence-backward", "silence-size"])
        for (name, status) in [("ratio-up-16", 0), ("ratio-up-17", 7), ("ratio-down-16", 0), ("ratio-down-17", 7)] {
            XCTAssertEqual(checks[name]?.status, status, name)
        }
        // 1,152 frames at 8,000 Hz, then 1,152 at 128,000 Hz (72 at 8,000) or the other way (18,432).
        XCTAssertEqual(Double(checks["ratio-up-16"]?.frames ?? 0), 1_152 + 72, accuracy: 4)
        XCTAssertEqual(Double(checks["ratio-down-16"]?.frames ?? 0), 1_152 + 18_432, accuracy: 4)
        let cap = try XCTUnwrap(checks["cap"])
        XCTAssertEqual(cap.status, 0)
        XCTAssertLessThanOrEqual(cap.largest, 16 * 1_024 * 1_024, "no converted frame holds over 16 MB")
        XCTAssertGreaterThan(cap.largest, 1_024 * 1_024, "the check made a long frame, fed in slices")
        XCTAssertEqual(Double(cap.frames), 16 + 1_048_560, accuracy: 64, "every frame comes out")
        let held = try XCTUnwrap(checks["held-back"])
        XCTAssertEqual(held.status, 0)
        XCTAssertEqual(Double(held.frames), 1_152 + 40, accuracy: 2, "the held-back frames come out in the end")
        XCTAssertEqual([checks["layout-same"]?.status, checks["layout-same"]?.changes], [0, 0], "5.1 again is the first form")
        XCTAssertEqual([checks["layout-other"]?.status, checks["layout-other"]?.changes], [0, 1], "6.0 after 5.1 is converted")
        let changes = try XCTUnwrap(checks["changes-1000"])
        XCTAssertEqual(changes.status, 0)
        // 1,152 first, then 1,000 pairs of 576 (converted) and 1,152.
        XCTAssertEqual(Double(changes.frames), 1_152 + 1_000 * (576 + 1_152), accuracy: 1_000)
        XCTAssertEqual(changes.changes, 1_000)
        XCTAssertEqual(checks["changes-1001"]?.status, 7)
    }

    /// Sound the decoder refuses is kept as silence (FU03), on made-up frames
    /// and refusals at 8,000 Hz in frames of 16 samples (2 ms), so the length
    /// and every later chapter mark hold, within the bounds. The numbers are
    /// written out, so changing a bound fails the check rather than moving it:
    /// - 900 packets refused between 100 and 400 good ones (the shape of
    ///   `flac-900-bad-packets.mka`) are filled by the frames' timestamps, the
    ///   1.8 s between them (14,400 frames): the sound's 8,000 frames and the
    ///   silence are the 22,400 of the 2.8 s file;
    /// - with no timestamps, by the refused packets' own lengths (8 ms, 64 frames);
    /// - at the start and the end of the sound as well (14 ms, 112 frames);
    /// - a file with no refused packet is given none, whatever its timestamps say;
    /// - a stretch past the bound (10 s here) is given no silence and the
    ///   decode goes on, as before FU03, the gap closing but for the refused
    ///   packets' own lengths (16 frames): the import is not refused for it; a
    ///   claim of a length past the ceiling owes none; stretches that add up
    ///   past the bound owe the first (6 s, 48,000 frames) and not the next;
    ///   one of exactly the bound is filled (80,000 frames);
    /// - a jump backward in the timestamps gives the packets' own lengths (48);
    /// - a file of 10 KB, which holds 81.92 s at 1 kbit/s, is given the
    ///   packet's own length (16 frames), not a gap of 100 s (800,000 frames).
    ///
    /// Fenced to the Mac like the check above: only made-up frames, no file.
    func testRefusedSoundIsKeptAsBoundedSilence() async throws {
        let run = try await runHelper(["formcheck", "all", "-"])
        XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        var checks: [String: (status: Int, frames: Int, silence: Int)] = [:]
        for line in String(decoding: run.bytes, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
            guard parts.count == 10, let status = Int(parts[1]), let frames = Int(parts[3]), let silence = Int(parts[9]) else { continue }
            checks[parts[0]] = (status, frames, silence)
        }
        for (name, frames, silence) in [
            ("silence-timed", 8_000, 14_400), ("silence-untimed", 96, 64), ("silence-ends", 48, 112), ("silence-none", 32, 0),
            ("silence-at-bound", 32, 80_000), ("silence-absurd", 32, 16), ("silence-claimed", 32, 0), ("silence-sums", 48, 48_000),
            ("silence-backward", 32, 48), ("silence-size", 32, 16),
        ] {
            XCTAssertEqual(checks[name]?.status, 0, "\(name): the decode goes on")
            XCTAssertEqual(checks[name]?.frames, frames, "\(name): the frames of sound")
            XCTAssertEqual(checks[name]?.silence, silence, "\(name): the frames of silence")
        }
    }
    #endif

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
    /// error (1). The iPhone's session in the app ends each of the first five
    /// as the helper does; the usage errors are of the helper's command line,
    /// which the iPhone has not, so they are the Mac's alone.
    func testEachRefusalHasItsExitStatus() async throws {
        let folder = try makeSandboxDirectory("FFmpegRefusals")
        let fifo = folder.appendingPathComponent("pipe.wma")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let wma = try formatSampleURL("wma/tones-wma1.wma").path
        var cases: [([String], Int32)] = [
            (["probe", "asf", folder.appendingPathComponent("missing.wma").path], 2),
            (["probe", "asf", folder.path], 2),
            (["decode", "asf", fifo.path], 2),
            (["probe", "nosuchdemuxer", wma], 10),
            (["probe", "asf", try formatSampleURL("mp3-chapters/three-tones.mp3").path], 3),
        ]
        #if os(macOS)
        cases += [(["play", "asf", wma], 1), (["probe", "asf"], 1), ([], 1)]
        #endif
        let started = Date()
        for (arguments, status) in cases {
            let run = try await runHelper(arguments)
            XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: status)), "\(arguments)")
            XCTAssertEqual(run.bytes, [], "\(arguments)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(20), "no refusal may wait")
    }

    /// The session's opener refuses a symbolic link as it refuses a file that
    /// cannot be opened (FU04): a link to a good sample is unreadable (2),
    /// with nothing written, in a probe and in a decode, where the sample
    /// itself is read. `O_NOFOLLOW` is what refuses it: the opener checks
    /// that what it opened is a regular file, which a link's target is.
    /// Shared with the iPhone, whose in-app run opens its file the same way.
    func testASymbolicLinkIsRefusedAsUnreadable() async throws {
        let folder = try makeSandboxDirectory("FFmpegLinks")
        let wma = try formatSampleURL("wma/tones-wma1.wma")
        let link = folder.appendingPathComponent("link.wma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wma)
        for mode in ["probe", "decode"] {
            let refused = try await runHelper([mode, "asf", link.path])
            XCTAssertEqual(refused.ending, WatchedProcess.Ending(outcome: .exited(status: 2)), "\(mode) of a link")
            XCTAssertEqual(refused.bytes, [], "\(mode) of a link")
        }
        // The sample itself, opened by its own path, is still read.
        let read = try await runHelper(["probe", "asf", wma.path])
        XCTAssertEqual(read.ending, WatchedProcess.Ending(outcome: .exited(status: 0)))
        XCTAssertFalse(read.bytes.isEmpty)
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
