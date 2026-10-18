import XCTest
@testable import TextMouth

/// What `afinfo` says about an audio file (FMT09): the parser on canned XML
/// in the shapes afinfo prints, and `read` on every audio sample in
/// `TestData/format-samples`, asked of the real `/usr/bin/afinfo` in a
/// watched child process. A hang or a failure is tested with stand-in tools
/// (`/bin/sleep`, `/bin/sh`, `/bin/echo`). Nothing is played, and no test
/// opens a sample with Apple's audio frameworks.
final class AudioFileInfoTests: XCTestCase {
    private var folder: URL! // lint-ok: made in setUpWithError before every test

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Helpers

    /// The samples' folder in the source tree: `TestData/format-samples`.
    private static let samplesFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestData/format-samples", isDirectory: true)

    /// afinfo's XML around `tracks`, for a file named `fileName` of the given
    /// `fileType` (printed with quotes, as afinfo does).
    private func xml(tracks: String, fileType: String = "caff", fileName: String = "tones.caf") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF8"?>
        <audio_info xmlns="http://apple.com/core_audio/audio_info">
        \t<audio_file audio_file_id="0">
        \t\t<file_name>\(fileName)</file_name>
        \t\t<file_type>'\(fileType)'</file_type>
        \t\t<tracks>
        \(tracks)
        \t\t</tracks>
        \t</audio_file>
        </audio_info>
        """.utf8)
    }

    /// A track as afinfo prints it; `extra` goes after the duration.
    private func track(
        channels: String = "1", rate: String = "22050", format: String = "lpcm",
        bitDepth: String? = "16", duration: String = "3.000000", extra: String = ""
    ) -> String {
        var lines = [
            "<num_channels>\(channels)</num_channels>",
            "<channel_layout>NA</channel_layout>",
            "<sample_rate units=\"Hz\">\(rate)</sample_rate>",
            "<format_type>\(format)</format_type>",
        ]
        if let bitDepth { lines.append("<bit_depth units=\"bits\">\(bitDepth)</bit_depth>") }
        lines.append("<duration units=\"sec\">\(duration)</duration>")
        return "\t\t\t<track track_id=\"1\">\n"
            + (lines + [extra]).map { "\t\t\t\t" + $0 }.joined(separator: "\n")
            + "\n\t\t\t</track>"
    }

    /// The `pcm_info` block of integer or float linear PCM.
    private func pcmInfo(_ dataType: String) -> String {
        "<pcm_info><endianness>little</endianness><data_type>\(dataType)</data_type></pcm_info>"
    }

    /// A stand-in tool running `executable` with `arguments`, under tight
    /// limits of one second.
    private func standIn(_ executable: String, _ arguments: [String]) -> AudioFileInfo.Tool {
        AudioFileInfo.Tool(
            command: { _ in (URL(fileURLWithPath: executable), arguments) },
            limits: { _ in
                WatchedProcess.Limits(
                    maximumSeconds: 1, maximumResidentBytes: 1 << 30,
                    maximumStalledSeconds: 1, pollInterval: 0.1
                )
            },
            residentMemory: { _ in nil }
        )
    }

    /// A file in the test's folder for a stand-in tool to be "asked about".
    /// It is `bytes` long: large enough to hold the length the canned XML of
    /// a test claims (the plausibility bound compares the two).
    private func makeFile(bytes: Int = 4) throws -> URL {
        let url = folder.appendingPathComponent("stand-in.bin")
        try Data(count: bytes).write(to: url)
        return url
    }

    /// A mono 16-bit PCM CAF at 8,000 Hz holding `seconds` of silence, whose
    /// data chunk claims `claimedDataBytes` bytes (the real size when nil):
    /// the shape of the review's lying file. CAF numbers are big-endian.
    private func makeCAF(seconds: Int, claimedDataBytes: Int64? = nil) throws -> URL {
        func big<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
        let samples = Data(count: seconds * 8_000 * 2)
        var bytes = Array("caff".utf8) + big(UInt16(1)) + big(UInt16(0))
        // The 'desc' chunk: rate (Float64), format, flags (little-endian
        // samples), bytes and frames a packet, channels, bits a channel.
        bytes += Array("desc".utf8) + big(Int64(32)) + big(Double(8_000).bitPattern)
        bytes += Array("lpcm".utf8) + big(UInt32(2)) + big(UInt32(2)) + big(UInt32(1))
        bytes += big(UInt32(1)) + big(UInt32(16))
        // The 'data' chunk: a 4-byte edit count, then the samples.
        bytes += Array("data".utf8) + big(claimedDataBytes ?? Int64(4 + samples.count)) + big(UInt32(0))
        let url = folder.appendingPathComponent("tones-\(claimedDataBytes ?? 0).caf")
        try (Data(bytes) + samples).write(to: url)
        return url
    }

    /// The facts of a 16-bit mono 22,050 Hz PCM track (or other codec) of
    /// `duration` seconds, for the plausibility bound.
    private func info(
        format: String = "lpcm", channels: Int = 1, rate: Double = 22_050, bits: Int? = 16,
        isFloat: Bool = false, duration: TimeInterval
    ) -> AudioFileInfo {
        AudioFileInfo(
            fileType: "caff", formatID: format, channels: channels, sampleRate: rate,
            duration: duration, bitsPerSample: bits, isFloat: isFloat
        )
    }

    // MARK: - Parsing

    /// 16-bit linear PCM in a CAF: its own depth counts, and it is lossless.
    func testParsesSixteenBitPCM() throws {
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(extra: pcmInfo("integer") + "<source_info><data_type>integer</data_type><bit_depth>16</bit_depth></source_info>")
        )))
        XCTAssertEqual(info.fileType, "caff")
        XCTAssertEqual(info.formatID, "lpcm")
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 22050)
        XCTAssertEqual(info.duration, 3, accuracy: 0.0001)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertFalse(info.isFloat)
        XCTAssertTrue(info.isLossless)
    }

    /// ALAC prints no `bit_depth` of its own: the source's depth is used.
    func testParsesALACWithItsSourceDepth() throws {
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(
                format: "alac", bitDepth: nil,
                extra: "<source_info><data_type>integer</data_type><bit_depth>16</bit_depth></source_info>"
            )
        )))
        XCTAssertEqual(info.formatID, "alac")
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertFalse(info.isFloat)
        XCTAssertTrue(info.isLossless)
    }

    /// Floating-point PCM has no bit depth worth keeping, and says so.
    func testParsesFloatPCMWithNoBitDepth() throws {
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(bitDepth: "32", extra: pcmInfo("float"))
        )))
        XCTAssertNil(info.bitsPerSample)
        XCTAssertTrue(info.isFloat)
        XCTAssertTrue(info.isLossless)
    }

    /// AC-3 nests a `format_list` whose `format` elements have their own
    /// channels and sample rate (changed here to be told apart): the
    /// track's own are the ones taken. A lossy codec has no bit depth.
    func testIgnoresTheFormatsNestedInATrack() throws {
        let nested = """
        <format_list><format format_id="0"><num_channels>6</num_channels>\
        <sample_rate units="Hz">48000</sample_rate><format_type>xxxx</format_type>\
        <bit_depth units="bits">24</bit_depth></format></format_list>
        """
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(rate: "32000", format: "ac-3", bitDepth: "0", duration: "3.024000", extra: nested),
            fileType: "ac-3", fileName: "tones.ac3"
        )))
        XCTAssertEqual(info.fileType, "ac-3")
        XCTAssertEqual(info.formatID, "ac-3")
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 32000)
        XCTAssertEqual(info.duration, 3.024, accuracy: 0.0001)
        XCTAssertNil(info.bitsPerSample)
        XCTAssertFalse(info.isLossless)
    }

    /// A codec's four characters keep their spaces ("aac "), and a file name
    /// with an ampersand ("&amp;") does not upset the parser.
    func testKeepsTheSpacesOfAFormatAndReadsEscapedFileNames() throws {
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(rate: "44100", format: "aac "), fileType: "3gpp", fileName: "Tom &amp; Jerry.3gp"
        )))
        XCTAssertEqual(info.formatID, "aac ")
        XCTAssertEqual(info.fileType, "3gpp")
        XCTAssertFalse(info.isLossless)
    }

    /// Only the first track of the first file counts.
    func testReadsOnlyTheFirstTrack() throws {
        let info = try XCTUnwrap(AudioFileInfo.parse(xml: xml(
            tracks: track(channels: "2") + "\n" + track(channels: "6", format: "alac")
        )))
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.formatID, "lpcm")
    }

    /// Anything afinfo should not print gives nil, never a guess.
    func testRefusesOutputThatIsNotAUsableTrack() {
        let malformed = Data("<audio_info><audio_file><tracks><track><num_channels>1".utf8)
        XCTAssertNil(AudioFileInfo.parse(xml: malformed), "malformed XML")
        XCTAssertNil(AudioFileInfo.parse(xml: Data()), "empty output")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: "")), "no track")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(channels: "0"))), "zero channels")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(channels: "one"))), "channels not a number")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(rate: "0"))), "zero sample rate")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(rate: "nan"))), "sample rate not finite")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(rate: "inf"))), "sample rate infinite")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(duration: "0.000000"))), "zero duration")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(duration: "-1"))), "negative duration")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(duration: "inf"))), "infinite duration")
        XCTAssertNil(AudioFileInfo.parse(xml: xml(tracks: track(format: ""))), "empty format")
    }

    /// Elements outside the first track (a file's other fields, a second
    /// file) never stand in for a missing one.
    func testAMissingFactIsNotTakenFromElsewhere() {
        let data = Data("""
        <audio_info><audio_file><file_type>'caff'</file_type><num_channels>2</num_channels>\
        <tracks><track><format_type>lpcm</format_type><sample_rate>8000</sample_rate>\
        <duration>1</duration></track></tracks></audio_file></audio_info>
        """.utf8)
        XCTAssertNil(AudioFileInfo.parse(xml: data))
    }

    // MARK: - Reading Every Sample

    /// What afinfo reports for one sample, measured in a shell on October 18,
    /// 2026.
    private struct Expected {
        let path: String
        let fileType: String
        let formatID: String
        let channels: Int
        let sampleRate: Double
        let duration: TimeInterval
        let bitsPerSample: Int?
        let isLossless: Bool
    }

    private static let expectations: [Expected] = [
        Expected(path: "ac3/tones.ac3", fileType: "ac-3", formatID: "ac-3", channels: 1, sampleRate: 32000, duration: 3.024, bitsPerSample: nil, isLossless: false),
        Expected(path: "eac3/tones.ec3", fileType: "ec-3", formatID: "ec-3", channels: 1, sampleRate: 32000, duration: 3.024, bitsPerSample: nil, isLossless: false),
        Expected(path: "amr/tones.amr", fileType: "amrf", formatID: "samr", channels: 1, sampleRate: 8000, duration: 3.02, bitsPerSample: nil, isLossless: false),
        Expected(path: "3gp/tones-aac.3gp", fileType: "3gpp", formatID: "aac ", channels: 1, sampleRate: 22050, duration: 3.0, bitsPerSample: nil, isLossless: false),
        Expected(path: "3gp/tones-amr.3gp", fileType: "3gpp", formatID: "samr", channels: 1, sampleRate: 8000, duration: 3.00625, bitsPerSample: nil, isLossless: false),
        Expected(path: "mp2/tones.mp2", fileType: "MPG2", formatID: ".mp2", channels: 1, sampleRate: 22050, duration: 3.030204, bitsPerSample: nil, isLossless: false),
        Expected(path: "au/tones.au", fileType: "NeXT", formatID: "lpcm", channels: 1, sampleRate: 22050, duration: 3.0, bitsPerSample: 16, isLossless: true),
        Expected(path: "aifc/tones-ima4.aifc", fileType: "AIFC", formatID: "ima4", channels: 1, sampleRate: 22050, duration: 3.001179, bitsPerSample: nil, isLossless: false),
        Expected(path: "aifc/tones-ulaw.aifc", fileType: "AIFC", formatID: "ulaw", channels: 1, sampleRate: 8000, duration: 3.0, bitsPerSample: nil, isLossless: false),
        Expected(path: "caf/tones-pcm.caf", fileType: "caff", formatID: "lpcm", channels: 1, sampleRate: 22050, duration: 3.0, bitsPerSample: 16, isLossless: true),
        Expected(path: "caf/tones-alac.caf", fileType: "caff", formatID: "alac", channels: 1, sampleRate: 22050, duration: 3.0, bitsPerSample: 16, isLossless: true),
        Expected(path: "caf/tones-opus.caf", fileType: "caff", formatID: "opus", channels: 1, sampleRate: 24000, duration: 3.0, bitsPerSample: nil, isLossless: false),
        Expected(path: "w64/tones.w64", fileType: "W64f", formatID: "lpcm", channels: 1, sampleRate: 22050, duration: 3.000091, bitsPerSample: 16, isLossless: true),
        Expected(path: "rf64/tones.rf64.wav", fileType: "RF64", formatID: "lpcm", channels: 1, sampleRate: 22050, duration: 3.0, bitsPerSample: 16, isLossless: true),
        Expected(path: "bwf/tones-bwf.wav", fileType: "WAVE", formatID: "lpcm", channels: 1, sampleRate: 11025, duration: 2.999909, bitsPerSample: 16, isLossless: true),
        Expected(path: "wav-variants/alaw.wav", fileType: "WAVE", formatID: "alaw", channels: 1, sampleRate: 8000, duration: 3.0, bitsPerSample: nil, isLossless: false),
        Expected(path: "wav-variants/extensible-24bit.wav", fileType: "WAVE", formatID: "lpcm", channels: 1, sampleRate: 8000, duration: 3.0, bitsPerSample: 24, isLossless: true),
        Expected(path: "wav-variants/ms-adpcm.wav", fileType: "WAVE", formatID: "ms..", channels: 1, sampleRate: 8000, duration: 3.054, bitsPerSample: nil, isLossless: false),
    ]

    /// Real afinfo, in a watched child, on a copy of every audio sample in
    /// the test's own folder.
    func testReadsEverySampleThroughTheRealAfinfo() async throws {
        for expected in Self.expectations {
            let source = Self.samplesFolder.appendingPathComponent(expected.path)
            let copy = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copy)
            let info = try await AudioFileInfo.read(copy)
            let found = try XCTUnwrap(info, "\(expected.path) gave no facts")
            XCTAssertEqual(found.fileType, expected.fileType, expected.path)
            XCTAssertEqual(found.formatID, expected.formatID, expected.path)
            XCTAssertEqual(found.channels, expected.channels, expected.path)
            XCTAssertEqual(found.sampleRate, expected.sampleRate, expected.path)
            XCTAssertEqual(found.duration, expected.duration, accuracy: 0.05, expected.path)
            XCTAssertEqual(found.bitsPerSample, expected.bitsPerSample, expected.path)
            XCTAssertEqual(found.isLossless, expected.isLossless, expected.path)
            XCTAssertFalse(found.isFloat, expected.path)
            try FileManager.default.removeItem(at: copy)
        }
    }

    // MARK: - The Bound On A Claimed Length (review item 4)

    /// Linear PCM has exactly one bit rate: three seconds of 16-bit mono at
    /// 22,050 Hz is 132,300 bytes, and the bound has one percent and one
    /// second of slack above that.
    func testPCMLengthIsBoundedByItsExactBitRate() {
        let claim = info(duration: 3)
        XCTAssertEqual(claim.lowestPlausibleBitRate, 352_800)
        XCTAssertTrue(claim.isPlausible(inFileOfBytes: 132_300))
        // One second of slack: 3 s fits 88,200 bytes (2 s) plus 1%.
        XCTAssertTrue(claim.isPlausible(inFileOfBytes: 89_100))
        XCTAssertFalse(claim.isPlausible(inFileOfBytes: 80_000))
        XCTAssertFalse(claim.isPlausible(inFileOfBytes: 0))
    }

    /// Floating-point PCM counts 32 bits a sample, whatever else is said.
    func testFloatPCMCountsThirtyTwoBitsASample() {
        let claim = info(channels: 2, rate: 48_000, bits: nil, isFloat: true, duration: 10)
        XCTAssertEqual(claim.lowestPlausibleBitRate, 48_000 * 2 * 32)
        XCTAssertTrue(claim.isPlausible(inFileOfBytes: 3_840_000))
        XCTAssertFalse(claim.isPlausible(inFileOfBytes: 3_000_000))
    }

    /// Other codecs use the table by their format ID, the packed ones the
    /// sample rate and channels too.
    func testTheLowestBitRatesOfTheCodecs() {
        let table: [(format: String, rate: Double)] = [
            ("samr", 4_750), ("sawb", 6_600), ("opus", 6_000), ("aac ", 8_000), ("aach", 8_000),
            (".mp3", 8_000), (".mp2", 8_000), (".mp1", 32_000), ("ac-3", 32_000), ("ec-3", 32_000),
            ("alac", 1_000), ("flac", 1_000), ("ms..", 1_000),
        ]
        for entry in table {
            XCTAssertEqual(info(format: entry.format, bits: nil, duration: 1).lowestPlausibleBitRate, entry.rate, entry.format)
        }
        XCTAssertEqual(info(format: "ima4", channels: 2, rate: 44_100, bits: nil, duration: 1).lowestPlausibleBitRate, 352_800)
        XCTAssertEqual(info(format: "ulaw", channels: 1, rate: 8_000, bits: nil, duration: 1).lowestPlausibleBitRate, 64_000)
        XCTAssertEqual(info(format: "alaw", channels: 2, rate: 8_000, bits: nil, duration: 1).lowestPlausibleBitRate, 128_000)
    }

    /// A table codec's length may not exceed the file's bits over the rate
    /// (AC-3: 100 seconds needs 400,000 bytes), with no slack.
    func testATableCodecsLengthIsBoundedByItsLowestRate() {
        let claim = info(format: "ac-3", bits: nil, duration: 100)
        XCTAssertTrue(claim.isPlausible(inFileOfBytes: 400_000))
        XCTAssertFalse(claim.isPlausible(inFileOfBytes: 399_999))
    }

    /// Whatever the size, a length of more than a year is not believed.
    func testNoLengthOverAYearIsBelieved() {
        let year: TimeInterval = 365 * 24 * 3_600
        XCTAssertEqual(AudioFileInfo.maximumPlausibleDuration, year)
        let huge: Int64 = 1 << 50
        XCTAssertTrue(info(format: "flac", bits: 16, duration: year).isPlausible(inFileOfBytes: huge))
        XCTAssertFalse(info(format: "flac", bits: 16, duration: year + 1).isPlausible(inFileOfBytes: huge))
    }

    /// The log line names the file, the claimed seconds (whole), and the
    /// size, and never a path.
    func testTheImplausibleLengthLogLine() {
        XCTAssertEqual(
            AudioFileInfo.implausibleLogLine(file: "lie.caf", duration: 25_769_803_776.4, bytes: 136_000),
            "AUDIO_INFO_IMPLAUSIBLE: lie.caf: claims 25769803776 seconds in 136000 bytes"
        )
    }

    /// A CAF whose data chunk claims 2^50 bytes is refused by the real
    /// afinfo's reading; a real short CAF is not.
    func testACAFThatClaimsAnAbsurdLengthIsRefused() async throws {
        let honest = try makeCAF(seconds: 2)
        let honestInfo = try await AudioFileInfo.read(honest)
        XCTAssertEqual(try XCTUnwrap(honestInfo).duration, 2, accuracy: 0.05)
        let lie = try makeCAF(seconds: 2, claimedDataBytes: 1 << 50)
        let lieInfo = try await AudioFileInfo.read(lie)
        XCTAssertNil(lieInfo)
    }

    // MARK: - Stand-In Tools

    /// A file that is not there gives nil without starting anything.
    func testAMissingFileGivesNil() async throws {
        let info = try await AudioFileInfo.read(folder.appendingPathComponent("missing.ac3"))
        XCTAssertNil(info)
    }

    /// A tool that prints good XML and exits 0 gives the facts (`cat` of a
    /// canned file).
    func testAToolThatPrintsGoodXMLGivesTheFacts() async throws {
        let canned = folder.appendingPathComponent("canned.xml")
        try xml(tracks: track()).write(to: canned)
        let info = try await AudioFileInfo.read(
            try makeFile(bytes: 1_000_000), using: standIn("/bin/cat", [canned.path])
        )
        XCTAssertEqual(info?.formatID, "lpcm")
        XCTAssertEqual(info?.channels, 1)
    }

    /// A hang ends at the watchdog's limit, with nil.
    func testAToolThatHangsGivesNilWithinSeconds() async throws {
        let started = Date()
        let info = try await AudioFileInfo.read(try makeFile(), using: standIn("/bin/sleep", ["30"]))
        XCTAssertNil(info)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A tool that exits with a failure gives nil, even if it printed XML.
    func testAToolThatFailsGivesNil() async throws {
        let info = try await AudioFileInfo.read(try makeFile(), using: standIn("/bin/sh", ["-c", "exit 3"]))
        XCTAssertNil(info)
    }

    /// Output that is not XML gives nil.
    func testOutputThatIsNotXMLGivesNil() async throws {
        let info = try await AudioFileInfo.read(try makeFile(), using: standIn("/bin/echo", ["hello"]))
        XCTAssertNil(info)
    }

    /// A tool that cannot start gives nil.
    func testAToolThatCannotStartGivesNil() async throws {
        let info = try await AudioFileInfo.read(
            try makeFile(), using: standIn(folder.appendingPathComponent("no-such-tool").path, [])
        )
        XCTAssertNil(info)
    }

    /// The real tool's limits: 30 seconds and one second per 20 MB, half a
    /// gigabyte of memory, and a stall allowance equal to the whole run's.
    func testTheAfinfoToolsLimits() {
        let tool = AudioFileInfo.Tool.afinfo
        let small = tool.limits(0)
        XCTAssertEqual(small.maximumSeconds, 30)
        XCTAssertEqual(small.maximumStalledSeconds, 30)
        XCTAssertEqual(small.maximumResidentBytes, 536_870_912)
        XCTAssertEqual(tool.limits(200_000_000).maximumSeconds, 40)
        let command = tool.command(URL(fileURLWithPath: "/tmp/a b.ac3"))
        XCTAssertEqual(command.executable.path, "/usr/bin/afinfo")
        XCTAssertEqual(command.arguments, ["-x", "-r", "/tmp/a b.ac3"])
    }
}
