import XCTest
@testable import TextMouth

/// The content decides, not the extension (review item 3 of the audiofmt
/// team): what a file holds, told from its first bytes
/// (`AudioContentSniffer`), the import's rule by content, and the guard that
/// refuses a misnamed Ogg file. The sniffer's tests write a few bytes and use
/// no audio API; the import tests copy a fixture into their own folder,
/// rename it, and import it, and only `afinfo` and `afconvert` (child
/// processes) ever read a source. Nothing is played.
final class AudioContentTests: XCTestCase {
    private var folder: URL! // lint-ok: made in setUpWithError before every test
    /// Imported book packages, removed when a test ends.
    private var importedPackages: [URL] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Byte Builders

    /// An ID3v2.3 tag whose body is `size` zero bytes, with the size as four
    /// synchsafe bytes (seven bits each).
    private func id3Tag(size: Int) -> [UInt8] {
        let synchsafe = (0..<4).map { UInt8((size >> (7 * (3 - $0))) & 0x7F) }
        return Array("ID3".utf8) + [3, 0, 0] + synchsafe + [UInt8](repeating: 0, count: size)
    }

    /// An MPEG 1 audio frame of `layerBits` (3 is layer I, 2 is II, 1 is
    /// III) at 44.1 kHz, its bit rate index `rateIndex`, with the length the
    /// header implies, its body zero.
    private func mpegFrame(layerBits: UInt8, rateIndex: UInt8, length: Int) -> [UInt8] {
        let header: [UInt8] = [0xFF, 0xF8 | (layerBits << 1) | 1, rateIndex << 4, 0x00]
        return header + [UInt8](repeating: 0, count: length - header.count)
    }

    /// A layer III frame at 128 kbit/s, 44.1 kHz: 417 bytes.
    private var mp3Frame: [UInt8] { mpegFrame(layerBits: 1, rateIndex: 9, length: 417) }

    /// A layer II frame at 160 kbit/s, 44.1 kHz: 522 bytes.
    private var mp2Frame: [UInt8] { mpegFrame(layerBits: 2, rateIndex: 9, length: 522) }

    /// An ADTS frame of `length` bytes (AAC-LC, 44.1 kHz, stereo).
    private func adtsFrame(length: Int) -> [UInt8] {
        let header: [UInt8] = [
            0xFF, 0xF1, 0x50, 0x80 | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF), UInt8((length & 0x07) << 5) | 0x1F, 0xFC,
        ]
        return header + [UInt8](repeating: 0, count: length - header.count)
    }

    /// An MP4 `ftyp` box with `brand`.
    private func ftyp(_ brand: String) -> [UInt8] {
        [0, 0, 0, 0x14] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0] + Array("isom".utf8)
    }

    private func bytes(_ text: String, then more: [UInt8] = [UInt8](repeating: 0, count: 16)) -> [UInt8] {
        Array(text.utf8) + more
    }

    // MARK: - The Sniffer's Kinds

    /// The containers announce themselves in their first bytes.
    func testTheContainersAreToldByTheirFirstBytes() {
        let kind: ([UInt8]) -> AudioContentSniffer.Kind = AudioContentSniffer.kind(of:)
        XCTAssertEqual(kind(bytes("OggS")), .ogg)
        XCTAssertEqual(kind([0x0B, 0x77, 0x3C, 0x4D]), .ac3)
        XCTAssertEqual(kind(bytes("caff")), .caf)
        XCTAssertEqual(kind(bytes("FORM", then: [0, 0, 0, 0] + Array("AIFC".utf8))), .aifc)
        XCTAssertEqual(kind(bytes("FORM", then: [0, 0, 0, 0] + Array("AIFF".utf8))), .aiff)
        XCTAssertEqual(kind(bytes("FORM", then: [0, 0, 0, 0] + Array("8SVX".utf8))), .unknown)
        XCTAssertEqual(kind(bytes(".snd")), .au)
        XCTAssertEqual(kind(bytes("#!AMR\n")), .amr)
        XCTAssertEqual(kind(bytes("fLaC")), .flac)
        for riff in ["RIFF", "RF64", "BW64"] {
            XCTAssertEqual(kind(bytes(riff, then: [0, 0, 0, 0] + Array("WAVE".utf8))), .wave, riff)
        }
        XCTAssertEqual(kind(bytes("RIFF", then: [0, 0, 0, 0] + Array("AVI ".utf8))), .unknown)
        let wave64: [UInt8] = [0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00]
        XCTAssertEqual(kind(wave64 + [0, 0, 0, 0]), .wave64)
    }

    /// MPEG-4 and QuickTime: 3GPP by its brand, the rest by an `ftyp` box
    /// of any other brand or by the first box a movie file may start with.
    func testMPEG4AndThreeGPPAreToldByTheirBoxes() {
        let kind: ([UInt8]) -> AudioContentSniffer.Kind = AudioContentSniffer.kind(of:)
        XCTAssertEqual(kind(ftyp("3gp4")), .threeGPP)
        XCTAssertEqual(kind(ftyp("3g2a")), .threeGPP)
        for brand in ["M4A ", "M4B ", "mp42", "isom", "qt  "] {
            XCTAssertEqual(kind(ftyp(brand)), .mpeg4, brand)
        }
        for box in ["moov", "mdat", "wide", "free", "skip"] {
            XCTAssertEqual(kind([0, 0, 0, 8] + Array(box.utf8) + [0, 0, 0, 0]), .mpeg4, box)
        }
        XCTAssertEqual(kind([0, 0, 0, 8] + Array("abcd".utf8)), .unknown)
    }

    /// An MP3 frame pair after an ID3v2 tag is layer III; the tag's size is
    /// a synchsafe integer (here 300, which needs two size bytes).
    func testAnMP3FramePairAfterAnID3TagIsLayerIII() {
        let file = id3Tag(size: 300) + mp3Frame + mp3Frame
        XCTAssertEqual(AudioContentSniffer.kind(of: file), .mpegLayerIII)
        XCTAssertEqual(AudioContentSniffer.kind(of: mp3Frame + mp3Frame), .mpegLayerIII)
    }

    /// A layer II pair is MP2, and a layer I pair is MP1.
    func testLayerIAndLayerIIPairsAreTold() {
        XCTAssertEqual(AudioContentSniffer.kind(of: mp2Frame + mp2Frame), .mpegLayerII)
        let layer1 = mpegFrame(layerBits: 3, rateIndex: 6, length: (12 * 192_000 / 44_100) * 4)
        XCTAssertEqual(AudioContentSniffer.kind(of: layer1 + layer1), .mpegLayerI)
    }

    /// ADTS AAC is told by its sync and layer bits 00, confirmed by the next
    /// frame.
    func testAnADTSFramePairIsADTS() {
        XCTAssertEqual(AudioContentSniffer.kind(of: adtsFrame(length: 100) + adtsFrame(length: 90)), .adts)
    }

    /// A lone 0xFFE sync that no second header confirms is unknown, as is a
    /// header whose frame length points at nothing; an empty file and a
    /// three-byte file are unknown too.
    func testAStraySyncAnEmptyFileAndAShortFileAreUnknown() {
        XCTAssertEqual(AudioContentSniffer.kind(of: mp3Frame + [UInt8](repeating: 0, count: 600)), .unknown)
        XCTAssertEqual(AudioContentSniffer.kind(of: Array(mp3Frame.prefix(200))), .unknown)
        XCTAssertEqual(AudioContentSniffer.kind(of: [UInt8]()), .unknown)
        XCTAssertEqual(AudioContentSniffer.kind(of: [0xFF, 0xFB, 0x90]), .unknown)
        XCTAssertEqual(AudioContentSniffer.kind(of: Array("hello, this is text".utf8)), .unknown)
    }

    /// A frame pair that begins deep in other data is not an MP3 file: the
    /// search runs a few thousand bytes past the audio's start and no more.
    func testAFramePairFarFromTheStartIsNotFound() {
        let near = [UInt8](repeating: 0, count: 1_000) + mp3Frame + mp3Frame
        let far = [UInt8](repeating: 0, count: AudioContentSniffer.frameSearchLength + 100) + mp3Frame + mp3Frame
        XCTAssertEqual(AudioContentSniffer.kind(of: near), .mpegLayerIII)
        XCTAssertEqual(AudioContentSniffer.kind(of: far), .unknown)
    }

    /// Whatever the bytes are, the sniffer returns and never traps: every
    /// prefix of a tag claiming a huge size, of a frame pair, and of
    /// pseudo-random data.
    func testTruncatedAndRandomBytesNeverTrap() {
        var generator = SeededGenerator(state: 12_345)
        let random = (0..<4_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        let hugeTag: [UInt8] = Array("ID3".utf8) + [3, 0, 0x10, 0x7F, 0x7F, 0x7F, 0x7F]
        let badSize: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF] + mp3Frame
        for sample in [hugeTag + mp3Frame, badSize, mp2Frame + mp2Frame, random, adtsFrame(length: 9) + adtsFrame(length: 7)] {
            for length in 0...min(sample.count, 700) {
                _ = AudioContentSniffer.kind(of: Array(sample.prefix(length)))
            }
            _ = AudioContentSniffer.kind(of: sample)
        }
    }

    /// A small deterministic generator, so the random bytes are the same on
    /// every run.
    private struct SeededGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }

    /// What the import does about each kind from the bytes alone: convert
    /// the formats whose decoders stay out of the app, leave the ones
    /// TextMouth plays, ask afinfo about MPEG-4 and the unknown.
    func testTheVerdictOfEachKind() {
        let kinds: [(AudioContentSniffer.Kind, AudioContentSniffer.Verdict)] = [
            (.ogg, .convert), (.ac3, .convert), (.caf, .convert), (.aifc, .convert), (.au, .convert),
            (.wave64, .convert), (.amr, .convert), (.threeGPP, .convert), (.mpegLayerI, .convert),
            (.mpegLayerII, .convert),
            (.mpegLayerIII, .leave), (.adts, .leave), (.wave, .leave), (.aiff, .leave), (.flac, .leave),
            (.mpeg4, .askAfinfo), (.unknown, .askAfinfo),
        ]
        for (kind, verdict) in kinds {
            XCTAssertEqual(AudioContentSniffer.verdict(for: kind), verdict, "\(kind)")
        }
    }

    // MARK: - Reading a File

    /// A file is read from disk by its bytes: a tag with cover art that
    /// runs past the first 64 KiB window still ends in an MP3 frame pair,
    /// found in a second window; a missing file, an empty one, and a FIFO
    /// named like an audio file are unknown, and the FIFO is not waited on.
    func testReadingFilesFromDisk() throws {
        let big = folder.appendingPathComponent("with-art.mp3")
        try Data(id3Tag(size: AudioContentSniffer.windowLength + 5_000) + mp3Frame + mp3Frame).write(to: big)
        XCTAssertEqual(AudioContentSniffer.kind(of: big), .mpegLayerIII)

        let empty = folder.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        XCTAssertEqual(AudioContentSniffer.kind(of: empty), .unknown)
        XCTAssertEqual(AudioContentSniffer.kind(of: folder.appendingPathComponent("missing.m4a")), .unknown)

        let fifo = folder.appendingPathComponent("pipe.m4a")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "Could not create the named pipe")
        XCTAssertEqual(AudioContentSniffer.kind(of: fifo), .unknown)
        XCTAssertFalse(AudioContentSniffer.isOgg(at: fifo))
        XCTAssertNil(AudioContentSniffer.firstBytes(of: folder, upTo: 4), "a folder is not a regular file")
    }

    /// Reading from an offset returns the bytes that start there, fewer when
    /// the file ends, and none past its end.
    func testFirstBytesStartWhereTheOffsetSays() throws {
        let file = folder.appendingPathComponent("ten.bin")
        try Data((0..<10).map { UInt8($0) }).write(to: file)
        XCTAssertEqual(AudioContentSniffer.firstBytes(of: file, upTo: 4), [0, 1, 2, 3])
        XCTAssertEqual(AudioContentSniffer.firstBytes(of: file, upTo: 4, from: 8), [8, 9])
        XCTAssertEqual(AudioContentSniffer.firstBytes(of: file, upTo: 4, from: 10), [])
        XCTAssertEqual(AudioContentSniffer.firstBytes(of: file, upTo: 4, from: -1), [])
    }

    // MARK: - What afinfo Says

    /// A file afinfo describes plays as it is when it is AAC, Apple
    /// Lossless, or MP3 in a container that holds it, and is converted when
    /// the codec or the container is another.
    func testWhatPlaysAsItIsByCodecAndContainer() {
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: "aac ", fileType: "m4af"))
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: "aach", fileType: "mp4f"))
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: "aacp", fileType: "m4bf"))
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: "alac", fileType: "m4af"))
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: ".mp3", fileType: "MPG3"))
        XCTAssertTrue(ImportAudioConverter.playsAsIs(formatID: "aac ", fileType: nil))
        for codec in ["ac-3", "ec-3", "opus", "flac", "samr", "lpcm", ".mp2", "ima4", "ulaw"] {
            XCTAssertFalse(ImportAudioConverter.playsAsIs(formatID: codec, fileType: "m4af"), codec)
            XCTAssertFalse(ImportAudioConverter.playsAsIs(formatID: codec, fileType: nil), codec)
        }
        XCTAssertFalse(ImportAudioConverter.playsAsIs(formatID: "aac ", fileType: "caff"))
        XCTAssertFalse(ImportAudioConverter.playsAsIs(formatID: "alac", fileType: "caff"))
        XCTAssertFalse(ImportAudioConverter.playsAsIs(formatID: ".mp3", fileType: "WAVE"))
    }

    // MARK: - Fixtures for the Import

    /// One second of a 440 Hz tone as MPEG layer II (MP2), mono at 44.1 kHz
    /// and 64 kbit/s, made on this Mac with
    /// `ffmpeg -f lavfi -i "sine=frequency=440:duration=1:sample_rate=44100" -ac 1 -c:a mp2 -b:a 64k tone.mp2`
    /// (`/opt/homebrew/bin/ffmpeg`). It stands in for a feed episode served
    /// as audio/mpeg and saved as .mp3.
    private static let mp2Fixture = "audio/tone.mp2"

    /// Runs the Mac's tool at `path` (afconvert) with `arguments` in a child
    /// process, failing the test when it does not end in success.
    private func runTool(_ path: String, _ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)", file: file, line: line)
    }

    /// A WAVE file of one second of silence at `name`, made by the test.
    private func makeWave(named name: String) throws -> URL {
        let wave = folder.appendingPathComponent(name)
        try AudioTestFixtures.writeSilence(to: wave, duration: 1)
        return wave
    }

    /// An AIFC file of IMA4 ADPCM at `name`, made with afconvert from a
    /// WAVE file.
    private func makeIMA4(named name: String) throws -> URL {
        let wave = try makeWave(named: "ima4-source.wav")
        let aifc = folder.appendingPathComponent(name)
        try runTool("/usr/bin/afconvert", ["-f", "AIFC", "-d", "ima4", wave.path, aifc.path])
        return aifc
    }

    /// A copy of the fixture `fixture` (under `TestData`) in `directory`
    /// (the test's folder by default) named `name`.
    @discardableResult
    private func copyFixture(_ fixture: String, as name: String, into directory: URL? = nil) throws -> URL {
        try OggTestFixtures.copy(fixture, to: directory ?? folder, as: name)
    }

    /// The codec of the first audio track of the file at `url`, by afinfo in
    /// a child process.
    private func codec(of url: URL) async throws -> String? {
        try await AudioFileInfo.read(url)?.formatID
    }

    // MARK: - Misnamed Files Are Converted

    /// Which of the files among `files` the import converts.
    private func converted(among files: [URL]) async throws -> [String] {
        try await ImportAudioConverter.needsConversion(among: files).map(\.lastPathComponent)
    }

    /// An MP2 file named .mp3, an IMA4 AIFC file named .aiff, and an Ogg
    /// file named .m4a or .flac are all converted, whatever their names.
    func testMisnamedFilesAreToBeConverted() async throws {
        let mp2 = try copyFixture(Self.mp2Fixture, as: "episode.mp3")
        let aifc = try makeIMA4(named: "episode.aiff")
        let ogg = try copyFixture(OggTestFixtures.vorbis, as: "elegy.m4a")
        let flacNamed = try copyFixture(OggTestFixtures.vorbis, as: "elegy.flac")

        let names = try await converted(among: [mp2, aifc, ogg, flacNamed])

        XCTAssertEqual(names, ["episode.mp3", "episode.aiff", "elegy.m4a", "elegy.flac"])
    }

    /// An afinfo stand-in: a child process (`/bin/cat`) that prints the XML
    /// afinfo prints for a file whose first track holds `codec` in a
    /// `container` ("ac-3" in 'm4af'), or fails when `codec` is nil.
    private func standInAfinfo(codec: String?, container: String = "m4af") throws -> AudioFileInfo.Tool {
        let xml = codec.map { """
            <audio_info><audio_file><file_type>'\(container)'</file_type><tracks><track>\
            <num_channels>2</num_channels><sample_rate>44100</sample_rate>\
            <format_type>\($0)</format_type><duration>1.0</duration></track></tracks></audio_file></audio_info>
            """ } ?? ""
        let output = folder.appendingPathComponent("afinfo-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: output)
        let path = output.path
        let command = codec == nil ? ("/usr/bin/false", [String]()) : ("/bin/cat", [path])
        return AudioFileInfo.Tool(
            command: { _ in (URL(fileURLWithPath: command.0), command.1) },
            limits: AudioFileInfo.Tool.afinfo.limits,
            residentMemory: AudioFileInfo.Tool.afinfo.residentMemory
        )
    }

    /// An MPEG-4 file (an `ftyp` box, named .m4a) is settled by what afinfo
    /// says its first audio track holds: converted for AC-3, Opus, FLAC, or
    /// PCM; left for AAC, Apple Lossless, or MP3; left when afinfo cannot
    /// read it. Unrecognized content is settled the same way.
    func testAnMPEG4FileIsSettledByWhatItsFirstTrackHolds() async throws {
        let mpeg4 = folder.appendingPathComponent("movie.m4a")
        try Data(ftyp("M4A ")).write(to: mpeg4)
        let unknown = folder.appendingPathComponent("odd.m4a")
        try Data(Array("no known signature here".utf8)).write(to: unknown)
        for file in [mpeg4, unknown] {
            for codec in ["ac-3", "ec-3", "opus", "flac", "lpcm", "samr"] {
                let tool = try standInAfinfo(codec: codec)
                let names = try await ImportAudioConverter.needsConversion(among: [file], using: tool)
                XCTAssertEqual(names.count, 1, "\(file.lastPathComponent) holding \(codec)")
            }
            for codec in ["aac ", "aach", "aacp", "alac", ".mp3"] {
                let tool = try standInAfinfo(codec: codec)
                let names = try await ImportAudioConverter.needsConversion(among: [file], using: tool)
                XCTAssertEqual(names, [], "\(file.lastPathComponent) holding \(codec)")
            }
            let unreadable = try standInAfinfo(codec: nil)
            let none = try await ImportAudioConverter.needsConversion(among: [file], using: unreadable)
            XCTAssertEqual(none, [], "\(file.lastPathComponent) that afinfo cannot read")
        }
        // Another container than MPEG-4 is converted though the codec is AAC.
        let inCAF = try standInAfinfo(codec: "aac ", container: "caff")
        let other = try await ImportAudioConverter.needsConversion(among: [mpeg4], using: inCAF)
        XCTAssertEqual(other.count, 1)
    }

    /// A file the bytes already settle is never put to afinfo: an Ogg file
    /// is converted and a real MP3 left, whatever the stand-in would say.
    func testTheBytesThatSettleAFileKeepItFromAfinfo() async throws {
        let ogg = try copyFixture(OggTestFixtures.vorbis, as: "a.m4a")
        let mp3 = try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "b.m4a")
        let saysAAC = try standInAfinfo(codec: "aac ")
        let saysAC3 = try standInAfinfo(codec: "ac-3")
        let first = try await ImportAudioConverter.needsConversion(among: [ogg, mp3], using: saysAAC)
        let second = try await ImportAudioConverter.needsConversion(among: [ogg, mp3], using: saysAC3)
        XCTAssertEqual(first.map(\.lastPathComponent), ["a.m4a"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["a.m4a"])
    }

    /// The real files stay as they are: an MP3, an AAC .m4a, a WAVE, an
    /// AIFF, and a FLAC are not converted, and neither is a file afinfo
    /// cannot read at all (an .m4a of text).
    func testRealFilesAreLeftAsTheyAre() async throws {
        let mp3 = try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "a.mp3")
        let m4a = try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: "b.m4a")
        let wave = try makeWave(named: "c.wav")
        let aiff = folder.appendingPathComponent("d.aiff")
        try runTool("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI16", wave.path, aiff.path])
        let flac = try copyFixture("format-samples/flac-chapters/three-tones.flac", as: "e.flac")
        let text = folder.appendingPathComponent("f.m4a")
        try Data("not audio at all".utf8).write(to: text)

        let names = try await converted(among: [mp3, m4a, wave, aiff, flac, text])

        XCTAssertEqual(names, [])
    }

    /// A folder lists the tracks to convert by content too, and keeps their
    /// order.
    func testAFolderOfTracksListsTheOnesToConvert() async throws {
        let tracks = folder.appendingPathComponent("Book", isDirectory: true)
        try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: "01.m4a", into: tracks)
        try copyFixture(OggTestFixtures.vorbis, as: "02.m4a", into: tracks)
        try copyFixture(Self.mp2Fixture, as: "03.mp3", into: tracks)
        try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "04.mp3", into: tracks)
        try copyFixture("format-samples/ac3/tones.ac3", as: "05.ac3", into: tracks)

        // The bytes alone settle the ones they can: the synchronous list.
        XCTAssertEqual(ImportAudioConverter.filesToConvert(in: tracks).map(\.lastPathComponent), ["02.m4a", "03.mp3", "05.ac3"])
        let all = try await ImportAudioConverter.tracksNeedingConversion(in: tracks)
        XCTAssertEqual(all.map(\.lastPathComponent), ["02.m4a", "03.mp3", "05.ac3"])
    }

    /// What asking afinfo adds to an import of 50 AAC .m4a tracks: they are
    /// not converted, and the time taken (about half a second on the
    /// developer's Mac) is printed.
    func testAskingAfinfoAboutFiftyM4ATracksIsQuickAndConvertsNothing() async throws {
        let tracks = folder.appendingPathComponent("Fifty", isDirectory: true)
        for number in 1...50 {
            try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: String(format: "%02d.m4a", number), into: tracks)
        }
        let started = Date()

        let all = try await ImportAudioConverter.tracksNeedingConversion(in: tracks)

        let seconds = Date().timeIntervalSince(started)
        print("AUDIOCONTENT_AFINFO_50_M4A_SECONDS \(seconds)")
        XCTAssertEqual(all, [])
        XCTAssertLessThan(seconds, 60)
    }

    // MARK: - Misnamed Files Import Converted

    /// Imports `source` as a single file and returns the book's file, which
    /// must be an .m4a of AAC. The package is removed when the test ends.
    @discardableResult
    private func importConverted(_ source: URL) async throws -> URL {
        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)
        let file = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(file.pathExtension, "m4a", source.lastPathComponent)
        let foundCodec = try await codec(of: file)
        XCTAssertEqual(foundCodec, "aac ", source.lastPathComponent)
        return file
    }

    /// An MP2 file named .mp3 imports converted: an .m4a of AAC, named for
    /// the source's stem.
    func testAnMP2FileNamedMP3ImportsAsAAC() async throws {
        let source = try copyFixture(Self.mp2Fixture, as: "Episode.mp3")

        let file = try await importConverted(source)

        XCTAssertEqual(file.lastPathComponent, "Episode.m4a")
    }

    /// An AIFC file of IMA4 named .aiff imports converted.
    func testAnIMA4AIFCFileNamedAIFFImportsAsAAC() async throws {
        let source = try makeIMA4(named: "Episode.aiff")

        let file = try await importConverted(source)

        XCTAssertEqual(file.lastPathComponent, "Episode.m4a")
    }

    /// An Ogg Vorbis file named .m4a imports converted and keeps its name:
    /// "Elegy.m4a", never "Elegy 2.m4a", and the package holds one .m4a.
    func testAnOggFileNamedM4AImportsAsAACAndKeepsItsName() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try copyFixture(OggTestFixtures.vorbis, as: "Elegy.m4a")

        let file = try await importConverted(source)

        XCTAssertEqual(file.lastPathComponent, "Elegy.m4a")
        let inPackage = OggTestFixtures.names(in: file.deletingLastPathComponent()).filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(inPackage, ["Elegy.m4a"])
        XCTAssertEqual(AudioContentSniffer.kind(of: file), .mpeg4, "what is there now is MPEG-4, not Ogg")
    }

    /// A folder of tracks, one named .m4a that holds Ogg and one named .mp3
    /// that holds MP2, imports with every track an AAC .m4a: the Ogg track
    /// under its source's own name (never "02 2.m4a"), the MP2 track as
    /// "03.m4a", and the manifest's tracks renamed as the files are. The
    /// folder imported from is untouched.
    func testAFolderWithMisnamedTracksImportsWithItsNamesAndManifestKept() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let book = folder.appendingPathComponent("Radio", isDirectory: true)
        try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: "01.m4a", into: book)
        try copyFixture(OggTestFixtures.vorbis, as: "02.m4a", into: book)
        try copyFixture(Self.mp2Fixture, as: "03.mp3", into: book)
        let manifestJSON = Data(#"{"tracks": ["03.mp3", "02.m4a", "01.m4a"]}"#.utf8)
        try manifestJSON.write(to: book.appendingPathComponent("manifest.json"))

        let imported = try FileImportService.importAudioFolderWithReport(from: book)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio).sorted(), ["01.m4a", "02.m4a", "03.m4a"])
        for name in ["02.m4a", "03.m4a"] {
            let trackCodec = try await codec(of: audio.appendingPathComponent(name))
            XCTAssertEqual(trackCodec, "aac ", name)
        }
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: audio.appendingPathComponent("manifest.json")))
        XCTAssertEqual((written as? [String: Any])?["tracks"] as? [String], ["03.m4a", "02.m4a", "01.m4a"])
        XCTAssertEqual(OggTestFixtures.names(in: book), ["01.m4a", "02.m4a", "03.mp3", "manifest.json"])
        XCTAssertEqual(try Data(contentsOf: book.appendingPathComponent("manifest.json")), manifestJSON)
    }

    /// A feed episode reaches the same rule as a single file: an MP2 file
    /// the server served as audio/mpeg, kept as .mp3, imports as an .m4a of
    /// AAC through `FeedEpisodeImporter.importEpisode`.
    func testAFeedEpisodeOfMP2NamedMP3IsConverted() async throws {
        let feed = Feed(
            feedURL: try XCTUnwrap(URL(string: "https://example.com/harbour-radio.xml")),
            folderID: UUID(),
            subscribedDate: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let item = FeedItem(
            id: "episode-9",
            title: "Episode 9: The Slipway",
            firstSeen: Date(timeIntervalSince1970: 1_790_000_000),
            author: "Harbour Radio"
        )
        let download = try copyFixture(Self.mp2Fixture, as: "download.mp3")
        addTeardownBlock { try? FileManager.default.removeItem(at: FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)) }

        let imported = try FeedEpisodeImporter.importEpisode(
            download, named: "Episode 9.mp3", item: item, of: feed, dateAdded: Date()
        )
        importedPackages.append(imported.book.tmbDirectory)

        let file = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(file.pathExtension, "m4a")
        let fileCodec = try await codec(of: file)
        XCTAssertEqual(fileCodec, "aac ")
    }

    /// Real files import as they are: an MP3 stays an MP3, an AAC .m4a an
    /// .m4a (same name, same bytes).
    func testRealFilesImportAsTheyAre() throws {
        let mp3 = try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "Song.mp3")
        let m4a = try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: "Tale.m4a")
        for source in [mp3, m4a] {
            let sourceBytes = try Data(contentsOf: source)
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)

            let file = URL(fileURLWithPath: imported.book.filePath)
            XCTAssertEqual(file.lastPathComponent, source.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: file), sourceBytes, source.lastPathComponent)
        }
    }

    // MARK: - The Plan

    /// The plan follows the content: an MP2 file named .mp3 is converted to
    /// AAC; a real MP3 is left; a path that does not exist is judged by its
    /// extension alone.
    func testThePlanFollowsTheContent() throws {
        let info = ImportAudioConverter.SourceInfo(
            sampleRate: 44_100, channels: 1, duration: 1, formatID: ".mp2", bitsPerSample: nil, isLossless: false
        )
        let mp2 = try copyFixture(Self.mp2Fixture, as: "x.mp3")
        let mp3 = try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "y.mp3")
        XCTAssertEqual(ImportAudioConverter.plan(for: mp2, info: info), .convertToAAC)
        XCTAssertEqual(ImportAudioConverter.plan(for: mp3, info: info), .leaveAsItIs)
        XCTAssertEqual(ImportAudioConverter.plan(for: folder.appendingPathComponent("missing.mp3"), info: info), .leaveAsItIs)
        XCTAssertEqual(ImportAudioConverter.plan(for: folder.appendingPathComponent("missing.ac3"), info: info), .convertToAAC)
    }

    // MARK: - The Guard Refuses a Misnamed Ogg File

    /// An Ogg file is never decoded in the app, whatever it is named (an old
    /// book's misnamed Ogg file is refused by the probe, the player,
    /// transcription, and the editor); a real .m4a, a real .mp3, a text
    /// file, and a missing file are not refused.
    func testTheGuardRefusesAnOggFileWhateverItIsNamed() throws {
        for name in ["a.m4a", "b.flac", "c.mp3", "d.wav", "e.caf", "f.OGG", "g.noextension"] {
            let ogg = try copyFixture(OggTestFixtures.vorbis, as: name)
            XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(ogg), name)
        }
        let m4a = try copyFixture("format-samples/m4b-chapters/three-tones.m4b", as: "real.m4a")
        let mp3 = try copyFixture("format-samples/mp3-chapters/three-tones.mp3", as: "real.mp3")
        let text = folder.appendingPathComponent("words.m4a")
        try Data("Ogg is a word, but this is text".utf8).write(to: text)
        let short = folder.appendingPathComponent("short.m4a")
        try Data("Ogg".utf8).write(to: short)
        for url in [m4a, mp3, text, short, folder.appendingPathComponent("missing.m4a")] {
            XCTAssertFalse(ImportAudioConverter.isNeverDecodedInApp(url), url.lastPathComponent)
        }
        // The extension still decides first, as it did.
        XCTAssertTrue(ImportAudioConverter.isNeverDecodedInApp(folder.appendingPathComponent("missing.ogg")))
        XCTAssertFalse(ImportAudioConverter.isNeverDecodedInApp(folder.appendingPathComponent("missing.caf")))
    }

    /// A named pipe called x.m4a is not a file to read: the guard answers at
    /// once (it opens non-blocking and checks the file type before it reads),
    /// where a blocking open would wait for a writer for ever.
    func testTheGuardDoesNotWaitOnAPipeNamedLikeAudio() {
        let fifo = folder.appendingPathComponent("x.m4a")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "Could not create the named pipe")
        let started = Date()

        let refused = ImportAudioConverter.isNeverDecodedInApp(fifo)

        XCTAssertFalse(refused)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
