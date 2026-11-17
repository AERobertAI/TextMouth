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
        "flv/tones-aac.flv", "mkv/three-tones-flac.mkv", "mka/tones-5.1-ac3.mka", "mka/tones-2tracks.mka",
        "webm/tones-opus.webm", "webm/tones-vorbis.weba", "spx/tones.spx", "rm/tones.ra",
    ]

    /// The exit statuses of TextMouthFFmpegProtocol.h.
    private let protocolStatuses: Set<Int32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 70, 71]

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
                    let (ending, _) = try await WatchedProcess.runStreaming(
                        helper, arguments: [mode, container.demuxer, copy.path], watching: nil, limits: limits
                    ) { pipe -> Int in
                        var total = 0
                        while true {
                            let piece = try await pipe.read(upTo: 1 << 20)
                            if piece.isEmpty { return total }
                            total += piece.count
                        }
                    }
                    let name = "\(sample), \(damage), \(mode)"
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
