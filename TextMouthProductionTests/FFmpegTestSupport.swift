import XCTest
@testable import TextMouth

// MARK: - Streams Written by Hand

/// Streams of TextMouth's FFmpeg session (FMT50) written by hand, for tests
/// of what reads them. The records' letters and the protocol's numbers are
/// spelled out here, from TextMouthFFmpegProtocol.h's comment, rather than
/// taken from the header, so a change to the header that the comment does not
/// follow fails these tests.
enum FFmpegTestStream {
    /// A record of `kind` (four ASCII letters) with `payload`.
    static func record(_ kind: String, _ payload: [UInt8]) -> [UInt8] {
        Array(kind.utf8) + littleEndian(UInt32(payload.count)) + payload
    }

    /// `value` as four little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// `value` as eight little-endian bytes.
    static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// HEAD of protocol `version` (1, the one the app reads).
    static func head(version: UInt32 = 1) -> [UInt8] {
        record("HEAD", littleEndian(version) + Array("9.0.2".utf8))
    }

    /// INFO of `pairs`, one "key=value" line each.
    static func info(_ pairs: [(String, String)]) -> [UInt8] {
        record("INFO", Array(pairs.map { "\($0.0)=\($0.1)\n" }.joined().utf8))
    }

    /// A tag of the file (TAG) or, with `stream`, of the chosen stream (STAG).
    static func tag(_ key: String, _ value: String, stream: Bool = false) -> [UInt8] {
        record(stream ? "STAG" : "TAG ", Array(key.utf8) + [0] + Array(value.utf8))
    }

    /// A chapter from `start` to `end` seconds (no end: not a number) titled `title`.
    static func chapter(start: Double, end: Double = .nan, title: String) -> [UInt8] {
        record("CHAP", littleEndian(start.bitPattern) + littleEndian(end.bitPattern) + Array(title.utf8))
    }

    /// A PCM record of 16-bit samples.
    static func pcm16(_ samples: [Int16]) -> [UInt8] {
        record("PCM ", samples.flatMap { sample in
            [UInt8(truncatingIfNeeded: UInt16(bitPattern: sample)), UInt8(truncatingIfNeeded: UInt16(bitPattern: sample) >> 8)]
        })
    }

    /// A PCM record of 32-bit samples (whole numbers, or floats' patterns).
    static func pcm32(_ samples: [UInt32]) -> [UInt8] {
        record("PCM ", samples.flatMap(littleEndian))
    }

    /// END, counting `frames`, and the packets and frames the decoder refused.
    static func end(frames: UInt64, refusedPackets: UInt32 = 0, refusedFrames: UInt32 = 0) -> [UInt8] {
        record("END ", littleEndian(frames) + littleEndian(refusedPackets) + littleEndian(refusedFrames))
    }

    /// The INFO of wma/tones-wma1.wma as the helper writes it in a probe:
    /// one WMA 1 stream of four seconds, mono at 22,050 Hz, 32 kbit/s.
    static let wmaInfo: [(String, String)] = [
        ("format", "asf"), ("codec", "wmav1"), ("stream", "0"), ("streams", "1"), ("audio_streams", "1"),
        ("more_than_sound", "0"), ("default", "0"), ("sample_rate", "22050"), ("channels", "1"), ("channel_mask", "4"),
        ("sample_format", "f32"), ("bits", "32"), ("duration", "3.999000"), ("format_duration", "3.999000"),
        ("bit_rate", "32000"), ("format_bit_rate", "40258"),
    ]

    /// `pairs` with the value of `key` replaced, or, for a nil value, left out.
    static func replacing(_ key: String, with value: String?, in pairs: [(String, String)]) -> [(String, String)] {
        pairs.compactMap { pair in
            guard pair.0 == key else { return pair }
            return value.map { (key, $0) }
        }
    }

    /// A whole probe of a file: HEAD, INFO of `info`, the file's tags, the
    /// stream's tags, the chapters, and END of no frames.
    static func probe(
        info: [(String, String)] = wmaInfo,
        tags: [(String, String)] = [("TITLE", "Three Tones"), ("artist", "TextMouth Test"), ("album", "Harbour Recordings")],
        streamTags: [(String, String)] = [],
        chapters: [(Double, String)] = []
    ) -> [UInt8] {
        var bytes: [UInt8] = head()
        bytes += self.info(info)
        for (key, value) in tags {
            bytes += tag(key, value)
        }
        for (key, value) in streamTags {
            bytes += tag(key, value, stream: true)
        }
        for (start, title) in chapters {
            bytes += chapter(start: start, title: title)
        }
        bytes += end(frames: 0)
        return bytes
    }
}

// MARK: - The Helper, Real and Stood In

/// Why a test of the FFmpeg helper could not start.
enum FFmpegTestError: Error {
    /// The app holds no FFmpeg helper, which every build of it does.
    case noHelper
}

extension XCTestCase {
    /// The FFmpeg helper the app carries (Contents/MacOS/TextMouthFFmpeg of
    /// the test host, which is the app). Every build of the app has it, on
    /// GitHub's runners too, so a test that finds none fails.
    /// - Throws: `FFmpegTestError.noHelper` when there is none.
    func bundledFFmpegHelper() throws -> URL {
        guard case let .found(helper) = FFmpegAudioConverter.locateBundled() else { throw FFmpegTestError.noHelper }
        return helper
    }

    /// What a stand-in helper does when it is asked to probe or to decode.
    enum StandInAction {
        /// Runs the app's own helper, as the import would.
        case realHelper
        /// Writes these bytes and exits with this status.
        case write([UInt8], status: Int32)
        /// Runs the app's own helper to its end, then hangs for this many
        /// seconds, as a helper that does not exit after writing its whole
        /// stream.
        case realHelperThenHang(seconds: Int)
        /// Hangs, writing nothing, for this many seconds.
        case hang(seconds: Int)
        /// Kills itself with SIGKILL, as a crash kills (SIGKILL makes no
        /// crash report, so it is safe on this Mac).
        case killItself
    }

    /// A stand-in for the FFmpeg helper: a shell script in this test's
    /// sandbox that does `probe` for the helper's probe and `decode` for its
    /// decode, and appends its first two arguments (the mode and the
    /// demuxer) to the log file it returns, so a test can see what was asked.
    func ffmpegHelperStandIn(probe: StandInAction = .realHelper, decode: StandInAction = .realHelper) throws -> (helper: URL, log: URL) {
        let folder = try makeSandboxDirectory("FFmpegStandIn")
        let log = folder.appendingPathComponent("calls.log")
        try Data().write(to: log)
        /// The shell lines that do `action`, writing its bytes to a file of
        /// their own named for `mode`.
        func lines(_ action: StandInAction, mode: String) throws -> String {
            switch action {
            case .realHelper:
                return "exec '\(try bundledFFmpegHelper().path)' \"$@\""
            case let .realHelperThenHang(seconds):
                // exec: the sleep is then the process the watchdog follows and ends.
                return "'\(try bundledFFmpegHelper().path)' \"$@\"; exec /bin/sleep \(seconds)"
            case let .write(bytes, status):
                let output = folder.appendingPathComponent("\(mode).stream")
                try Data(bytes).write(to: output)
                return "cat '\(output.path)'; exit \(status)"
            case let .hang(seconds):
                // exec: the sleep is the helper's own process, which the watchdog's kill ends.
                return "exec /bin/sleep \(seconds)"
            case .killItself:
                return "kill -9 $$"
            }
        }
        let script = """
        #!/bin/sh
        echo "$1 $2" >> '\(log.path)'
        case "$1" in
        probe) \(try lines(probe, mode: "probe")) ;;
        decode) \(try lines(decode, mode: "decode")) ;;
        esac
        exit 1
        """
        let helper = folder.appendingPathComponent("TextMouthFFmpeg")
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (helper, log)
    }

    /// The calls a stand-in made, one "mode demuxer" line each.
    func standInCalls(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The FFmpeg tool with `helper` (none: a missing helper), the
    /// watchdog's limits at `seconds` for everything when given, and a volume
    /// of `available` free bytes, or one that says nothing of its space
    /// (nil), so no test depends on the disk it runs on.
    func ffmpegTool(helper: URL?, seconds: TimeInterval? = nil, available: Int64? = nil) -> FFmpegAudioConverter.Tool {
        var tool = FFmpegAudioConverter.Tool.bundled
        tool.locate = { helper.map { .found($0) } ?? .missing }
        if let seconds {
            let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
            tool.limits = { _ in limits }
            tool.probeLimits = { _ in limits }
        }
        tool.availableBytes = { _ in available }
        return tool
    }

    /// The tool with the app's own helper, and a volume that says nothing of
    /// its space.
    func bundledFFmpegTool() throws -> FFmpegAudioConverter.Tool {
        ffmpegTool(helper: try bundledFFmpegHelper())
    }
}
