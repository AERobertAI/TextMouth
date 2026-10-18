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

    /// A small file in the test's folder for a stand-in tool to be "asked
    /// about".
    private func makeFile() throws -> URL {
        let url = folder.appendingPathComponent("stand-in.bin")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
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
        let info = try await AudioFileInfo.read(try makeFile(), using: standIn("/bin/cat", [canned.path]))
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
