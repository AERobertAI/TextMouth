import XCTest
@testable import TextMouth

/// Damaged copies of every sample of the formats only FFmpeg reads, read by
/// the FFmpeg helper the app carries (FMT50): cut short, with bytes flipped,
/// with a stretch zeroed, and with a stretch repeated. Each run must end by
/// the protocol (an exit status of TextMouthFFmpegProtocol.h, or the
/// watchdog's kill), never by a signal the helper did not catch, and the
/// import of each copy must end in a conversion or a failure by name, with
/// nothing left behind.
///
/// A damaged file can crash the helper, and a crash on the development Mac
/// puts macOS's crash report on the user's screen (the helper ends itself
/// with _exit on a fatal signal, which should prevent one, but that is not
/// tried there). So these tests never run on the development Mac:
/// `TestMachine.skipUnlessGitHubRunner` skips them there, and every GitHub
/// train runs them (docs/developer/testing.md).
///
/// The iPhone runs the same session in the app itself (FMT54), where a crash
/// ends the app, its test host here, and a hang is abandoned by the engine:
/// so on the iPhone these tests show, on GitHub alone (where the iPhone's
/// tests always run), that no damaged copy crashes or hangs the session in
/// the app, and that each ends by the protocol's statuses or its limits.
/// Shared with the iPhone's unit bundle.
final class FFmpegHelperHostileFileTests: XCTestCase {
    /// Skips every test off GitHub's runners: damaged media may crash the
    /// FFmpeg helper, and a crash on the development Mac puts a crash report
    /// on the user's screen.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestMachine.skipUnlessGitHubRunner("Damaged media may crash the FFmpeg helper")
    }

    /// The samples damaged here.
    private let samples = [
        "wma/tones.wma", "wma/tones-wma1.wma", "wma/three-tones-chapters.wma", "wmv/tones.wmv", "avi/tones-mp3.avi",
        "flv/tones-aac.flv", "mkv/three-tones-flac.mkv", "mka/tones-5.1-ac3.mka", "mka/tones-aac.mka", "mka/tones-2tracks.mka",
        "webm/tones-opus.webm", "webm/tones-vorbis.weba", "spx/tones.spx", "rm/tones.ra",
    ]

    /// The exit statuses of TextMouthFFmpegProtocol.h.
    private let protocolStatuses: Set<Int32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 70, 71]

    /// A random number generator with a seed, so a failure names a copy that
    /// can be made again (xorshift64*).
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// The damaged copies of `bytes`, by name: cut at a quarter, a half, and
    /// three quarters; 32 bytes flipped past the first kilobyte, with five
    /// seeds; a kilobyte zeroed in the middle; and a stretch of 4 KB
    /// repeated.
    private func damagedCopies(of bytes: [UInt8]) -> [(String, [UInt8])] {
        var copies: [(String, [UInt8])] = []
        for fraction in [4, 2] {
            copies.append(("cut to 1/\(fraction)", Array(bytes.prefix(bytes.count / fraction))))
        }
        copies.append(("cut to 3/4", Array(bytes.prefix(bytes.count * 3 / 4))))
        for seed in UInt64(1)...5 {
            var generator = SeededGenerator(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
            var flipped = bytes
            for _ in 0..<32 where flipped.count > 1_024 {
                let index = Int.random(in: 1_024..<flipped.count, using: &generator)
                flipped[index] ^= UInt8.random(in: 1...255, using: &generator)
            }
            copies.append(("32 bytes flipped, seed \(seed)", flipped))
        }
        var zeroed = bytes
        let middle = zeroed.count / 2
        for index in middle..<min(middle + 1_024, zeroed.count) {
            zeroed[index] = 0
        }
        copies.append(("a kilobyte zeroed", zeroed))
        let start = bytes.count / 3
        let stretch = Array(bytes.dropFirst(start).prefix(4_096))
        copies.append(("4 KB repeated", Array(bytes.prefix(start)) + stretch + stretch + Array(bytes.dropFirst(start))))
        return copies
    }

    /// Every damaged copy's probe and decode end by the protocol, never by
    /// an uncaught signal; the copies that crashed the helper (its own
    /// status 70) are named in the log, as the helper's guard caught them.
    func testEveryDamagedCopyEndsByTheProtocol() async throws {
        let helper = try bundledFFmpegHelper()
        let seconds = TestMachine.allowed(20)
        let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
        let folder = try makeSandboxDirectory("FFmpegHostile")
        var unexpected: [String] = []
        var crashed: [String] = []
        for sample in samples {
            let original = try formatSampleURL(sample)
            let container = try XCTUnwrap(FFmpegContainer.of(fileAt: original), sample)
            for (damage, bytes) in damagedCopies(of: Array(try Data(contentsOf: original))) {
                let copy = folder.appendingPathComponent("copy." + original.pathExtension)
                try Data(bytes).write(to: copy)
                for mode in ["probe", "decode"] {
                    let name = "\(sample), \(damage), \(mode)"
                    let ending: WatchedProcess.Ending
                    do {
                        ending = try await runFFmpegHelper(helper, [mode, container.demuxer, copy.path], limits: limits).ending
                    } catch {
                        // The iPhone's engine abandoned a call that hung past its limit: not an ending by the protocol.
                        unexpected.append("\(name): \(error)")
                        continue
                    }
                    switch ending.outcome {
                    case .killed:
                        break
                    case let .exited(status) where ending.signal == nil && protocolStatuses.contains(status):
                        if status == 70 { crashed.append(name) }
                    default:
                        unexpected.append("\(name): \(ending)")
                    }
                }
            }
        }
        // Worded without "crash": the run's summary reads a line holding that word as the test host's crash.
        print("FFMPEG_HOSTILE: \(crashed.count) copies ended in the helper's signal guard (status 70): \(crashed)")
        XCTAssertEqual(unexpected, [])
    }

    /// What the helper makes of the sample `name` of `ffmpeg-edge`: how it ended and, when it
    /// wrote a whole stream, what the reader says of it (frames and the refusals END counts).
    private func decodeEdgeSample(_ name: String) async throws -> (ending: WatchedProcess.Ending, frames: UInt64?, refused: [UInt32]) {
        try await decode(try formatSampleURL("ffmpeg-edge/\(name)"), demuxer: "matroska")
    }

    /// What the helper makes of the file at `file`, read by `demuxer`: as `decodeEdgeSample`.
    private func decode(_ file: URL, demuxer: String) async throws -> (ending: WatchedProcess.Ending, frames: UInt64?, refused: [UInt32]) {
        let helper = try bundledFFmpegHelper()
        let seconds = TestMachine.allowed(20)
        let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
        let (ending, bytes) = try await runFFmpegHelper(helper, ["decode", demuxer, file.path], limits: limits)
        var stream = FFmpegHelperStream(data: Data(bytes))
        do {
            _ = try await stream.readReport()
            while try await stream.nextBlock() != nil {}
        } catch {
            return (ending, nil, [])
        }
        return (ending, stream.framesRead, [stream.refusedPackets, stream.refusedFrames])
    }

    /// The decoder's error bound (FU-FFMPEG2, MAX_ERRORS_IN_A_ROW = 1,000 in
    /// session.c), tried with two samples of FLAC in Matroska (1,400 packets
    /// of 16 samples) whose packets from the 101st on are refused by the
    /// decoder (their sync code is zeroed): 900 of them in one, 1,200 in the
    /// other. Both end with status 0, with the 500 or the 200 good packets'
    /// sound whole and each refused packet counted in END, the 1,200 as well as
    /// the 900: the bound counts the errors the decoder gives for a frame
    /// with no packet between (a decoder that would be asked for ever), and a
    /// damaged packet is refused when it is sent, so a run of them, of any
    /// length, never reaches it, and the file is converted all the same
    /// (the comment of `FFmpegHelperStream`: damaged sound is converted). The
    /// run of November 17, 2026 (train 1117-0431) showed both. What they refuse
    /// is kept as silence by the packets' timestamps (FU03), so the whole
    /// 2.8 s of the file, 22,400 frames, is written, to within two frames,
    /// where the packets that decode are 8,000 or 3,200 of them.
    func testAnyRunOfRefusedPacketsStillGivesTheSoundAroundIt() async throws {
        for (name, refused) in [("flac-900-bad-packets.mka", 900), ("flac-1200-bad-packets.mka", 1_200)] {
            let result = try await decodeEdgeSample(name)
            XCTAssertEqual(result.ending, WatchedProcess.Ending(outcome: .exited(status: 0)), name)
            XCTAssertEqual(Double(result.frames ?? 0), 22_400, accuracy: 32, "\(name): the packets that decode, and silence for the rest")
            XCTAssertEqual(result.refused, [UInt32(refused), 0], "\(name): every refused packet counted")
        }
    }

    /// The import of a file with refused packets lasts as long as the file
    /// does, and its chapter marks hold (FU03): 900 refused packets between
    /// 100 and 400 that decode would close up to 1.0 s of 2.8, which the
    /// import's length check refused ("it lasts 1.0 seconds, not 2.8"), and
    /// every later chapter mark would land late. The import now succeeds with
    /// the whole 2.8 s, the sound's own first 0.2 s, and silence after it.
    func testAFileWithRefusedPacketsImportsAtItsWholeLength() async throws {
        for name in ["flac-900-bad-packets.mka", "flac-1200-bad-packets.mka"] {
            let copy = try copyOfFormatSample("ffmpeg-edge/\(name)")
            let conversion = try await FFmpegAudioConverter.convert(copy, using: try bundledFFmpegTool())
            XCTAssertEqual(conversion.duration, 2.8, accuracy: 0.05, name)
            XCTAssertTrue(conversion.partlyDecoded, "\(name): the listener is told part could not be decoded")
        }
    }

    /// No decoded frame holds more than 16,777,216 samples over all its
    /// channels (`MAX_DECODED_SAMPLES` in session.c; the FMT54 review,
    /// finding 2, and its check, item 1): FFmpeg refuses a larger one before
    /// allocating it, so one crafted packet cannot make one decoder call take
    /// hundreds of megabytes, which nothing could stop until the call
    /// returned. The bound counts every channel: in Matroska made by the
    /// test, one PCM block of exactly that many samples in stereo (8,388,608
    /// a channel) and in eight channels (2,097,152 a channel) decodes whole,
    /// and one of a sample frame more ends the decode with status 13, a frame
    /// too large, said in its own sentence, not as a damaged packet whose
    /// loss the length check would blame on the file. A minute of 48 kHz
    /// stereo in one chunk (5.76 million) is well within it.
    func testNoDecodedFrameHoldsMoreSamplesThanTheBound() async throws {
        for channels in [2, 8] {
            let atTheBound = 16_777_216 / channels
            let whole = try await decode(
                try matroskaOfOnePCMBlock(channels: channels, framesPerChannel: atTheBound, named: "at-the-bound-\(channels).mka"),
                demuxer: "matroska"
            )
            XCTAssertEqual(whole.ending, WatchedProcess.Ending(outcome: .exited(status: 0)), "\(channels) channels")
            XCTAssertEqual(whole.frames, UInt64(atTheBound), "\(channels) channels: the frame at the bound was not decoded whole")
            let pastIt = try await decode(
                try matroskaOfOnePCMBlock(channels: channels, framesPerChannel: atTheBound + 1, named: "past-the-bound-\(channels).mka"),
                demuxer: "matroska"
            )
            XCTAssertEqual(pastIt.ending, WatchedProcess.Ending(outcome: .exited(status: 13)), "\(channels) channels: a frame past the bound was not told as such")
            XCTAssertNil(pastIt.frames, "\(channels) channels")
        }
        // The conversion says so in its own sentence.
        let copy = try matroskaOfOnePCMBlock(channels: 2, framesPerChannel: 8_388_609, named: "Long Chunk.mka")
        do {
            _ = try await FFmpegAudioConverter.convert(copy, using: try bundledFFmpegTool())
            XCTFail("a frame past the bound was converted")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .frameTooLarge(fileName: "Long Chunk.mka"))
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth can't convert “Long Chunk.mka”: part of its sound is in one piece too large to decode."
            )
        }
    }

    /// The helper's signal guard (FU-FFMPEG2): a write through a null pointer,
    /// an abort, a stack overflow, and a double free each end the helper with
    /// 70 as the guard's own `_exit`, not by the signal (which would leave a
    /// crash report on the Mac), and with nothing written. The Debug helper's
    /// `signalcheck` mode crashes on purpose, so this runs on GitHub only (the
    /// class skips elsewhere), fenced to the Mac, where the helper is a
    /// program; a Release helper has no such mode and answers 1.
    #if os(macOS)
    func testEachFatalSignalEndsTheHelperWithItsOwnStatus() async throws {
        let helper = try bundledFFmpegHelper()
        let seconds = TestMachine.allowed(20)
        let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
        for kind in ["segfault", "abort", "overflow", "doublefree"] {
            let run = try await runFFmpegHelper(helper, ["signalcheck", kind, "-"], limits: limits)
            XCTAssertEqual(run.ending, WatchedProcess.Ending(outcome: .exited(status: 70)), kind)
            XCTAssertNil(run.ending.signal, "\(kind): the helper ended by the signal itself")
            XCTAssertEqual(run.bytes, [], kind)
        }
        // A kind the helper does not know is a usage error, not a crash.
        let unknown = try await runFFmpegHelper(helper, ["signalcheck", "nothing", "-"], limits: limits)
        XCTAssertEqual(unknown.ending, WatchedProcess.Ending(outcome: .exited(status: 1)))
    }
    #endif

    /// A file in which no packet decodes (`flac-all-bad-packets.mka`: every one of its 1,400
    /// packets has its sync code zeroed) ends with the helper's status 6, damaged, and the import
    /// says it is damaged, not that it holds no sound (FU-FFMPEG2): the listener hears that the
    /// file is broken. Skipping the refused packets of a file that has others is the rule; a file
    /// with none has nothing to keep.
    func testAFileOfOnlyRefusedPacketsEndsAsDamaged() async throws {
        let result = try await decodeEdgeSample("flac-all-bad-packets.mka")
        XCTAssertEqual(result.ending, WatchedProcess.Ending(outcome: .exited(status: 6)))
        let copy = try copyOfFormatSample("ffmpeg-edge/flac-all-bad-packets.mka")
        do {
            _ = try await FFmpegAudioConverter.convert(copy, using: try bundledFFmpegTool())
            XCTFail("a file with no sound was imported")
        } catch let failure as ImportAudioConverter.Failure {
            XCTAssertEqual(failure, .notRead(fileName: "flac-all-bad-packets.mka", problem: .damaged))
        }
    }

    /// The import of every damaged copy ends in a conversion or a failure by
    /// name, and leaves nothing behind but the copy and, after a conversion,
    /// its .m4a.
    func testTheImportOfEveryDamagedCopyEndsByName() async throws {
        let tool = try bundledFFmpegTool()
        var unexpected: [String] = []
        for sample in samples {
            let original = try formatSampleURL(sample)
            for (damage, bytes) in damagedCopies(of: Array(try Data(contentsOf: original))) {
                let folder = try makeSandboxDirectory("FFmpegHostileImport")
                let copy = folder.appendingPathComponent(original.lastPathComponent)
                try Data(bytes).write(to: copy)
                do {
                    _ = try await FFmpegAudioConverter.convert(copy, using: tool)
                } catch is FFmpegAudioConverter.Failure {
                } catch is ImportAudioConverter.Failure {
                } catch {
                    unexpected.append("\(sample), \(damage): \(error)")
                }
                let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasSuffix(".m4a") }
                if left != [original.lastPathComponent] {
                    unexpected.append("\(sample), \(damage): left \(left)")
                }
            }
        }
        XCTAssertEqual(unexpected, [])
    }
}
