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
}
