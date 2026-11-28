import os
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

#if os(macOS)
/// What runs TextMouth's FFmpeg session in a test, on the Mac: the helper
/// program at this path, the app's own (`bundledFFmpegHelper()`) or a
/// stand-in script (`ffmpegHelperStandIn`).
typealias FFmpegTestHelper = URL
#else
/// What runs TextMouth's FFmpeg session in a test, on the iPhone, which runs
/// the session in the app itself (FMT54): what an in-process run opens, the
/// session linked into the app (`bundledFFmpegHelper()`) or a stand-in
/// (`ffmpegHelperStandIn`).
struct FFmpegTestHelper: Sendable {
    /// What the run opens on the engine.
    let open: InProcessSessionOpener
}
#endif

/// Why a test of the FFmpeg helper could not start.
enum FFmpegTestError: Error {
    /// The app holds no FFmpeg helper, which every build of it does.
    case noHelper
    /// The iPhone was asked for one of the helper's command lines that only
    /// its program reads (a usage error, or a Debug mode).
    case notASession([String])
    /// A test asked for an FLV tag of more samples than one holds (16,777,214)
    /// or of none.
    case tagTooLong(Int)
}

extension XCTestCase {
    /// TextMouth's own FFmpeg session, as the app runs it: on the Mac the
    /// helper the app carries (Contents/MacOS/TextMouthFFmpeg of the test
    /// host, which is the app), which every build has, on GitHub's runners
    /// too, so a test that finds none fails; on the iPhone the session
    /// linked into the app (FMT54).
    /// - Throws: `FFmpegTestError.noHelper` when the Mac's app has none.
    func bundledFFmpegHelper() throws -> FFmpegTestHelper {
        #if os(macOS)
        guard case let .found(helper) = FFmpegAudioConverter.locateBundled() else { throw FFmpegTestError.noHelper }
        return helper
        #else
        return FFmpegTestHelper(open: LinkedFFmpegSession.open)
        #endif
    }

    /// What a stand-in helper does when it is asked to probe or to decode.
    enum StandInAction: Sendable {
        /// Runs the app's own session, as the import would.
        case realHelper
        /// Writes these bytes and ends with this status: the helper's exit
        /// status, or on the iPhone the session's.
        case write([UInt8], status: Int32)
        /// Hangs, writing nothing, for this many seconds: the Mac's helper
        /// sleeps, which the watchdog's kill ends; the iPhone's session waits,
        /// asking the call's stop check as FFmpeg's reading asks the
        /// interrupt callback, and stops once told to.
        case hang(seconds: Int)
        #if os(macOS)
        /// Runs the app's own helper to its end, then hangs for this many
        /// seconds, as a helper that does not exit after writing its whole
        /// stream. The Mac's alone: in the iPhone app the session simply
        /// ends at END, with no program to outlive it.
        case realHelperThenHang(seconds: Int)
        /// Kills itself with SIGKILL, as a crash kills (SIGKILL makes no
        /// crash report, so it is safe on this Mac). The Mac's alone: a crash
        /// in the iPhone app ends the app.
        case killItself
        #endif
    }

    /// A stand-in for the FFmpeg session that does `probe` for the probe and
    /// `decode` for the decode, and appends "mode demuxer" (its first two
    /// arguments, as the helper's command line has them) to the log file it
    /// returns, so a test can see what was asked. On the Mac it is a shell
    /// script in this test's sandbox; on the iPhone, a session that an
    /// in-process run opens (FMT54).
    func ffmpegHelperStandIn(probe: StandInAction = .realHelper, decode: StandInAction = .realHelper)
        throws -> (helper: FFmpegTestHelper, log: URL)
    {
        let folder = try makeSandboxDirectory("FFmpegStandIn")
        let log = folder.appendingPathComponent("calls.log")
        try Data().write(to: log)
        #if os(macOS)
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
        #else
        let open: InProcessSessionOpener = { file, demuxer, mode, check in
            FFmpegStandInLog.append("\(mode.argument) \(demuxer)", to: log)
            let action = mode == .probe ? probe : decode
            switch action {
            case .realHelper:
                return LinkedFFmpegSession.open(file, demuxer: demuxer, mode: mode, check: check)
            case let .write(bytes, status):
                return (session: WrittenStandInSession(bytes: bytes, status: status), status: 0)
            case let .hang(seconds):
                return (session: HangingStandInSession(seconds: seconds), status: 0)
            }
        }
        return (FFmpegTestHelper(open: open), log)
        #endif
    }

    /// The calls a stand-in made, one "mode demuxer" line each.
    func standInCalls(_ log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// The FFmpeg tool with `helper` (none: a missing helper, which only a
    /// damaged Mac app has, but whose refusal both platforms share), the
    /// limits at `seconds` for everything when given, and a volume of
    /// `available` free bytes, or one that says nothing of its space (nil),
    /// so no test depends on the disk it runs on. On the iPhone each tool
    /// has an engine of its own, so a test that abandons a call refuses no
    /// other test's conversions.
    func ffmpegTool(helper: FFmpegTestHelper?, seconds: TimeInterval? = nil, available: Int64? = nil) -> FFmpegAudioConverter.Tool {
        var tool = FFmpegAudioConverter.Tool.bundled
        #if os(macOS)
        tool.locate = { helper.map { .found($0) } ?? .missing }
        #else
        let converts = helper != nil
        tool.locate = { converts ? .inProcess : .missing }
        if let helper { tool.openSession = helper.open }
        tool.engine = InProcessEngine(name: "FFmpeg test", work: FFmpegAudioConverter.sessionEngine.work)
        #endif
        if let seconds {
            let limits = WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
            tool.limits = { _ in limits }
            tool.probeLimits = { _ in limits }
        }
        tool.availableBytes = { _ in available }
        return tool
    }

    /// The tool with the app's own session, and a volume that says nothing
    /// of its space.
    func bundledFFmpegTool() throws -> FFmpegAudioConverter.Tool {
        ffmpegTool(helper: try bundledFFmpegHelper())
    }

    /// `tool`, and how many runs of the session it has started since, on
    /// either platform (the FMT54 review, finding 6): the helper's launches
    /// on the Mac (`WatchedProcess.launchCount`), and on the iPhone, which
    /// starts no program and counts no launch, the opens of the session in
    /// the app, through the tool.
    func countingSessionStarts(of tool: FFmpegAudioConverter.Tool) -> (tool: FFmpegAudioConverter.Tool, starts: @Sendable () -> Int) {
        #if os(macOS)
        let launchesBefore = WatchedProcess.launchCount
        return (tool, { WatchedProcess.launchCount - launchesBefore })
        #else
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let open = tool.openSession
        var counting = tool
        counting.openSession = { file, demuxer, mode, check in
            opens.withLock { $0 += 1 }
            return open(file, demuxer, mode, check)
        }
        return (counting, { opens.withLock { $0 } })
        #endif
    }

    /// Runs the session as the helper's command line asks, `[mode, demuxer,
    /// path]`, on `helper` under `limits`, and returns how it ended and every
    /// byte of its stream: on the Mac the helper program under the watchdog;
    /// on the iPhone the session in the app, on an engine of its own (FMT54),
    /// which ends as the helper would. The helper's other command lines (a
    /// usage error, a Debug mode) are its program's alone.
    /// - Throws: `FFmpegTestError.notASession` on the iPhone for those.
    func runFFmpegHelper(_ helper: FFmpegTestHelper, _ arguments: [String], limits: WatchedProcess.Limits) async throws
        -> (ending: WatchedProcess.Ending, bytes: [UInt8])
    {
        /// Reads every piece of the stream into one array.
        func everything(_ nextPiece: () async throws -> [UInt8]) async throws -> [UInt8] {
            var bytes: [UInt8] = []
            while true {
                let piece = try await nextPiece()
                if piece.isEmpty { return bytes }
                bytes += piece
            }
        }
        #if os(macOS)
        let (ending, read) = try await WatchedProcess.runStreaming(helper, arguments: arguments, watching: nil, limits: limits) { pipe in
            try await everything { try await pipe.read(upTo: 1 << 16) }
        }
        return (ending, try read.get())
        #else
        let modes: [String: FFmpegAudioConverter.SessionMode] = ["probe": .probe, "decode": .decode]
        guard arguments.count == 3, let mode = modes[arguments[0]] else { throw FFmpegTestError.notASession(arguments) }
        let (ending, read) = try await FFmpegAudioConverter.runInProcess(
            mode, of: URL(fileURLWithPath: arguments[2]), demuxer: arguments[1], limits: limits, using: ffmpegTool(helper: helper)
        ) { nextPiece in
            try await everything(nextPiece)
        }
        return (ending, try read.get())
        #endif
    }
}

// MARK: - Files Made by the Tests

extension XCTestCase {
    /// An FLV file of one audio tag of `samples` samples of mono sound, all
    /// silence, written as `name` to a sandbox folder of the test's own (FMT54
    /// review, finding 2): 8-bit PCM at 44,100 Hz, or, `aLaw`, G.711 A-law at
    /// 8,000 Hz, which decodes to twice its bytes. A file as long, or a frame
    /// as large, as a test needs, which FFmpeg's FLV demuxer and PCM decoders
    /// read. The layout is Adobe's (FLV version 1): the 9-byte header, then
    /// each tag after the size of the one before it, and an audio tag's data
    /// its sound's format byte followed by its samples, so one tag is one
    /// packet and one decoded frame. A tag holds at most 16,777,214 samples.
    /// - Throws: `FFmpegTestError.tagTooLong` for more, or for none.
    func flvOfOnePCMTag(samples: Int, aLaw: Bool = false, named name: String) throws -> URL {
        guard samples > 0, samples < (1 << 24) - 1 else { throw FFmpegTestError.tagTooLong(samples) }
        /// `value` as `count` big-endian bytes.
        func bigEndian(_ value: Int, bytes count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) }
        }
        let dataSize = 1 + samples
        var bytes: [UInt8] = Array("FLV".utf8) + [0x01, 0x04] + bigEndian(9, bytes: 4)  // version 1, audio only
        bytes += bigEndian(0, bytes: 4)  // the size of the tag before the first: none
        bytes += [0x08] + bigEndian(dataSize, bytes: 3) + bigEndian(0, bytes: 4) + bigEndian(0, bytes: 3)  // audio, time 0, stream 0
        // Linear PCM, little-endian (3), 44 kHz (3), 8 bits (0), mono (0); or G.711 A-law (7), 16 bits decoded (1).
        bytes.append(aLaw ? 0x72 : 0x3C)
        bytes += [UInt8](repeating: aLaw ? 0xD5 : 128, count: samples)
        bytes += bigEndian(11 + dataSize, bytes: 4)
        let file = try makeSandboxDirectory("FFmpegFLV").appendingPathComponent(name)
        try Data(bytes).write(to: file)
        return file
    }
}

extension XCTestCase {
    /// A Matroska file of one audio track of `channels` channels of 16-bit
    /// little-endian PCM at 48,000 Hz, holding one block of
    /// `framesPerChannel` sample frames, all silence, written as `name` to a
    /// sandbox folder of the test's own: one block is one packet and one
    /// decoded frame of `framesPerChannel` times `channels` samples, as large
    /// as a test needs, in as many channels (the check of the FMT54 review's
    /// fixes, item 1). The layout is Matroska's EBML: the EBML header, then a
    /// segment of its info, its track, and one cluster of one SimpleBlock,
    /// each element's size in eight bytes.
    func matroskaOfOnePCMBlock(channels: Int, framesPerChannel: Int, named name: String) throws -> URL {
        /// `value` as `count` big-endian bytes.
        func bigEndian(_ value: UInt64, bytes count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
        }
        /// An element: its ID, its size as an eight-byte EBML number, and `payload`.
        func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
            id + [0x01] + bigEndian(UInt64(payload.count), bytes: 7) + payload
        }
        /// An unsigned integer element of eight bytes.
        func unsigned(_ id: [UInt8], _ value: Int) -> [UInt8] { element(id, bigEndian(UInt64(value), bytes: 8)) }
        /// A string element.
        func string(_ id: [UInt8], _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }
        let header = element([0x1A, 0x45, 0xDF, 0xA3], unsigned([0x42, 0x86], 1) + unsigned([0x42, 0xF7], 1)
            + unsigned([0x42, 0xF2], 4) + unsigned([0x42, 0xF3], 8) + string([0x42, 0x82], "matroska")
            + unsigned([0x42, 0x87], 4) + unsigned([0x42, 0x85], 2))
        let info = element([0x15, 0x49, 0xA9, 0x66], unsigned([0x2A, 0xD7, 0xB1], 1_000_000)
            + string([0x4D, 0x80], "TextMouth tests") + string([0x57, 0x41], "TextMouth tests"))
        let audio = element([0xE1], element([0xB5], bigEndian(Double(48_000).bitPattern, bytes: 8))
            + unsigned([0x9F], channels) + unsigned([0x62, 0x64], 16))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], unsigned([0xD7], 1) + unsigned([0x73, 0xC5], 1)
            + unsigned([0x83], 2) + string([0x86], "A_PCM/INT/LIT") + audio))
        // Track 1, at time 0 of the cluster, a key frame; then the samples.
        let block = element([0xA3], [0x81, 0x00, 0x00, 0x80] + [UInt8](repeating: 0, count: framesPerChannel * channels * 2))
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], unsigned([0xE7], 0) + block)
        let file = try makeSandboxDirectory("FFmpegMatroska").appendingPathComponent(name)
        try Data(header + element([0x18, 0x53, 0x80, 0x67], info + tracks + cluster)).write(to: file)
        return file
    }
}

#if os(iOS)
// MARK: - The iPhone's Stand-In Sessions (FMT54)

/// The log of a stand-in session's calls, written as the Mac's stand-in
/// script appends to its own.
enum FFmpegStandInLog {
    /// Appends `line` and a line feed to the file at `log`.
    static func append(_ line: String, to log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// A stand-in session that gives `bytes`, all of it as one record, then ends
/// with `status`, as the Mac's stand-in script `cat`s its stream and exits
/// with it: 0 ends the stream cleanly, whatever it held.
final class WrittenStandInSession: InProcessFFmpegSession {
    private let bytes: [UInt8]
    private let status: Int32
    /// Whether the bytes have been given.
    private let given = OSAllocatedUnfairLock(initialState: false)

    init(bytes: [UInt8], status: Int32) {
        self.bytes = bytes
        self.status = status
    }

    /// The bytes first, when there are any, then the end with `status`.
    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        let first = given.withLock { given in
            defer { given = true }
            return !given
        }
        if first, !bytes.isEmpty { return (0, bytes) }
        return (status, [])
    }

    func close() {}
}

/// A stand-in session that hangs for `seconds`, writing nothing, but asks the
/// call's stop check every 10 milliseconds, as FFmpeg's reading asks the
/// session's interrupt callback, and ends with the session's stop (status 11)
/// once told to; one never told ends cleanly with nothing, as a helper's
/// `sleep` exits 0.
final class HangingStandInSession: InProcessFFmpegSession {
    private let seconds: Int

    init(seconds: Int) {
        self.seconds = seconds
    }

    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        let end = DispatchTime.now() + .seconds(seconds)
        while !check.shouldStop, DispatchTime.now() < end { usleep(10_000) }
        return (check.shouldStop ? 11 : 0, [])
    }

    func close() {}
}
#endif

// MARK: - The Converted File

/// What an .m4a's first sound track holds, read from its bytes: the codec of
/// its sample entry ("aac" for 'mp4a', "alac" for 'alac', as afinfo names
/// them, or the entry's four letters), its channels, and its sample rate.
/// The tests the iPhone shares may name no Apple audio framework
/// (Scripts/agents/ios_ui_tests.py), and the Mac's afinfo is a program the
/// iPhone has not, so the file's boxes are read (ISO 14496-12): moov, trak,
/// mdia (its hdlr names the sound track, its mdhd's time scale is the
/// rate), minf, stbl, stsd, and its first entry. An AudioSampleEntry's own
/// channel count need not be the sound's (the standard gives it a template
/// value of 2, and AVFoundation writes 2 for mono), so the channels come from
/// the codec's own configuration: AAC's AudioSpecificConfig, inside the esds
/// box's descriptors (ISO 14496-1 and 14496-3), and Apple Lossless's
/// ALACSpecificConfig, in its alac box.
struct M4ASampleEntry: Equatable {
    let codec: String
    let channels: Int
    let sampleRate: Double

    /// The entry of the first sound track ('soun') of the .m4a at `url`;
    /// nil when it has none, or its boxes are not what an .m4a holds.
    static func read(_ url: URL) throws -> M4ASampleEntry? {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard let movie = child("moov", of: bytes[...]) else { return nil }
        for track in children("trak", of: movie) {
            guard let media = child("mdia", of: track), let handler = child("hdlr", of: media),
                  handler.count >= 12, String(decoding: handler.dropFirst(8).prefix(4), as: UTF8.self) == "soun",
                  let rate = child("mdhd", of: media).flatMap(timeScale(ofMediaHeader:)),
                  let table = child("minf", of: media).flatMap({ child("stbl", of: $0) }),
                  let descriptions = child("stsd", of: table), descriptions.count >= 8 + 36 else { continue }
            // stsd: a version and flags (4 bytes) and the entry count (4), then the first entry: its size (4) and
            // type (4), 6 reserved bytes, a data reference index (2), and the AudioSampleEntry's 20 bytes, then
            // the entry's own boxes.
            let entry = descriptions.dropFirst(8)
            let size = Int(number(entry, at: 0, bytes: 4))
            let type = String(decoding: entry.dropFirst(4).prefix(4), as: UTF8.self)
            let boxes = entry.dropFirst(36).prefix(max(0, size - 36))
            switch type {
            case "mp4a":
                return M4ASampleEntry(codec: "aac", channels: child("esds", of: boxes).flatMap(aacChannels) ?? 0, sampleRate: rate)
            case "alac":
                return M4ASampleEntry(codec: "alac", channels: child("alac", of: boxes).flatMap(alacChannels) ?? 0, sampleRate: rate)
            default:
                return M4ASampleEntry(codec: type, channels: 0, sampleRate: rate)
            }
        }
        return nil
    }

    /// The time scale of an mdhd payload, the track's sample rate in an
    /// .m4a: after a version and flags (4 bytes), two times of 4 bytes, or of
    /// 8 in version 1.
    private static func timeScale(ofMediaHeader header: ArraySlice<UInt8>) -> Double? {
        let offset = header.first == 1 ? 20 : 12
        guard header.count >= offset + 4 else { return nil }
        return Double(number(header, at: offset, bytes: 4))
    }

    /// The channel configuration of the AudioSpecificConfig in an esds
    /// payload: after its version and flags, the ES descriptor (tag 3), its
    /// DecoderConfigDescriptor (tag 4), and that one's DecoderSpecificInfo (tag
    /// 5), whose first bits are the audio object type (5, or 11 when they say
    /// 31), the frequency index (4, and 24 more when it says 15), and the
    /// channel configuration (4).
    private static func aacChannels(_ esds: ArraySlice<UInt8>) -> Int? {
        var reader = DescriptorReader(bytes: Array(esds.dropFirst(4)))
        guard reader.enter(tag: 3) else { return nil }
        reader.skip(2)  // ES_ID
        guard let flags = reader.byte() else { return nil }
        if flags & 0x80 != 0 { reader.skip(2) }  // streamDependenceFlag: dependsOn_ES_ID
        if flags & 0x40 != 0 { reader.skip(Int(reader.byte() ?? 0)) }  // URL_Flag: a URL of that length
        if flags & 0x20 != 0 { reader.skip(2) }  // OCRstreamFlag: OCR_ES_Id
        guard reader.enter(tag: 4) else { return nil }
        reader.skip(13)  // objectTypeIndication, streamType, bufferSizeDB, maxBitrate, avgBitrate
        guard reader.enter(tag: 5) else { return nil }
        let config = (0..<8).reduce(UInt64(0)) { bits, _ in bits << 8 | UInt64(reader.byte() ?? 0) }
        var position = 5
        if config >> 59 == 31 { position += 6 }
        let frequencyIndex = (config >> (60 - position)) & 0xF
        position += 4
        if frequencyIndex == 15 { position += 24 }
        return Int((config >> (60 - position)) & 0xF)
    }

    /// The channels of an alac payload: after a version and flags (4 bytes),
    /// the ALACSpecificConfig's frame length (4), compatible version, bit
    /// depth, and three tuning bytes (5), then the channels (1).
    private static func alacChannels(_ alac: ArraySlice<UInt8>) -> Int? {
        alac.count >= 14 ? Int(number(alac, at: 13, bytes: 1)) : nil
    }

    /// Reads ISO 14496-1's descriptors one byte at a time.
    private struct DescriptorReader {
        let bytes: [UInt8]
        var position = 0

        /// The next byte, or nil past the end.
        mutating func byte() -> UInt8? {
            guard position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }

        /// Skips `count` bytes.
        mutating func skip(_ count: Int) {
            position += count
        }

        /// Enters the descriptor here, which must be of `tag`: its tag, then
        /// its size in one to four bytes of seven bits each, the high bit
        /// saying that another follows. False for another tag or a short read.
        mutating func enter(tag: UInt8) -> Bool {
            guard byte() == tag else { return false }
            for _ in 0..<4 {
                guard let next = byte() else { return false }
                if next & 0x80 == 0 { return true }
            }
            return true
        }
    }

    /// The big-endian number of `count` bytes at `offset` of `bytes` (counted from its start).
    private static func number(_ bytes: ArraySlice<UInt8>, at offset: Int, bytes count: Int) -> UInt64 {
        bytes.dropFirst(offset).prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The payloads of the boxes of type `type` among the boxes `bytes` holds,
    /// in order. A box's size is its first four bytes, or, when they say 1,
    /// the eight after its type (AVFoundation writes mdat so), or, when they
    /// say 0, the rest of what holds it.
    private static func children(_ type: String, of bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var found: [ArraySlice<UInt8>] = []
        var offset = bytes.startIndex
        while offset + 8 <= bytes.endIndex {
            var size = Int(number(bytes[offset...], at: 0, bytes: 4))
            var header = 8
            if size == 1 {
                guard offset + 16 <= bytes.endIndex else { break }
                size = Int(clamping: number(bytes[offset...], at: 8, bytes: 8))
                header = 16
            } else if size == 0 {
                size = bytes.endIndex - offset
            }
            guard size >= header, size <= bytes.endIndex - offset else { break }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == type {
                found.append(bytes[(offset + header)..<(offset + size)])
            }
            offset += size
        }
        return found
    }

    /// The payload of the first box of type `type` among those `bytes` holds.
    private static func child(_ type: String, of bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        children(type, of: bytes).first
    }
}
