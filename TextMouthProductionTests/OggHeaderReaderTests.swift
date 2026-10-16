import XCTest
@testable import TextMouth

/// The metadata readers never hand an Ogg file to AVFoundation (the rule of
/// October 14, 2026): `AudioPlaybackService.metadataAsset(for:)` is their one
/// funnel, and it refuses Ogg by extension. No test here opens a real Ogg
/// file with an Apple API.
final class OggMetadataGuardTests: XCTestCase {
    /// A folder of the test's own, removed when the test ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The funnel refuses every Ogg extension, in any case.
    func testTheFunnelRefusesOggExtensions() {
        for name in ["a.ogg", "a.OGA", "a.opus", "A.Ogg"] {
            XCTAssertNil(AudioPlaybackService.metadataAsset(for: URL(fileURLWithPath: "/tmp/\(name)")),
                         "\(name) must not be opened")
        }
    }

    /// The funnel opens every other audio extension.
    func testTheFunnelOpensOtherFormats() {
        for name in ["a.m4a", "a.mp3", "a.wav"] {
            XCTAssertNotNil(AudioPlaybackService.metadataAsset(for: URL(fileURLWithPath: "/tmp/\(name)")),
                            "\(name) must be opened")
        }
    }

    /// Real, playable audio copied under an Ogg name gives no chapters, no
    /// tags, and no duration, while the same bytes named `.wav` give a
    /// duration: the guard refuses, not a failing decode.
    func testPlayableAudioNamedOggIsNeverProbed() async throws {
        let ogg = folder.appendingPathComponent("x.ogg")
        let wav = folder.appendingPathComponent("x.wav")
        // AVAudioFile infers its format from the extension, so the audio is
        // written as a WAVE file and the same bytes copied under the Ogg name.
        try AudioTestFixtures.writeSilence(to: wav, duration: 2)
        try FileManager.default.copyItem(at: wav, to: ogg)

        let chapters = await AudioPlaybackService.extractChapters(from: ogg)
        XCTAssertTrue(chapters.isEmpty)
        let metadata = await AudioPlaybackService.extractFullMetadata(from: ogg)
        XCTAssertEqual(metadata.fileFormat, "OGG")
        XCTAssertEqual(metadata.title, "")
        XCTAssertEqual(metadata.artist, "")
        XCTAssertEqual(metadata.duration, "")
        let oggDuration = await AudioPlaybackService.getDuration(of: ogg)
        XCTAssertNil(oggDuration)

        let wavDuration = await AudioPlaybackService.getDuration(of: wav)
        XCTAssertEqual(try XCTUnwrap(wavDuration), 2, accuracy: 0.1)
    }
}

// MARK: - Test-side Ogg writer

/// Builds valid Ogg pages and whole streams in memory, using the reader's own
/// `crc(of:)`; the real fixtures separately prove that CRC against real files.
enum OggStreamBuilder {
    /// One page. `lacing` and `payload` must agree; the CRC is filled in.
    static func page(type: UInt8 = 0, granule: Int64 = -1, serial: UInt32 = 1, sequence: UInt32 = 0,
                     lacing: [UInt8], payload: [UInt8], version: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = Array("OggS".utf8) + [version, type]
        bytes += le(UInt64(bitPattern: granule), 8) + le(UInt64(serial), 4) + le(UInt64(sequence), 4)
        bytes += [0, 0, 0, 0]                       // the CRC field, zero while the CRC is taken
        bytes += [UInt8(lacing.count)] + lacing + payload
        let crc = OggHeaderReader.crc(of: bytes)
        bytes.replaceSubrange(22..<26, with: le(UInt64(crc), 4))
        return bytes
    }

    /// `value` as `size` little-endian bytes.
    static func le(_ value: UInt64, _ size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// The pages that carry `packet` alone, `perPage` bytes of it on each
    /// (a multiple of 255, and at most 255 * 254 so the last page's lacing
    /// fits). Continued pages are flagged 0x01; `granuleOnLast` is the granule
    /// of the page that ends the packet.
    static func pages(carrying packet: [UInt8], perPage: Int = 255 * 254, serial: UInt32 = 1,
                      firstSequence: UInt32 = 1, granuleOnLast: Int64 = 0) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var start = 0
        repeat {
            let end = min(start + perPage, packet.count)
            let isLast = end == packet.count
            let chunk = Array(packet[start..<end])
            // 255 for every full segment; the last page ends with the short remainder (maybe 0).
            var lacing = [UInt8](repeating: 255, count: chunk.count / 255)
            if isLast { lacing.append(UInt8(chunk.count % 255)) }
            result.append(page(type: start == 0 ? 0 : 0x01, granule: isLast ? granuleOnLast : -1,
                               serial: serial, sequence: firstSequence + UInt32(result.count),
                               lacing: lacing, payload: chunk))
            start = end
        } while start < packet.count
        return result
    }

    /// A Vorbis identification packet.
    static func vorbisID(channels: UInt8 = 2, rate: UInt32 = 22_050) -> [UInt8] {
        // 0x01 "vorbis", version, channels, sample rate, three bitrates, block sizes, framing.
        var bytes: [UInt8] = [0x01] + Array("vorbis".utf8)
        bytes += le(0, 4)
        bytes += [channels]
        bytes += le(UInt64(rate), 4)
        bytes += le(0, 12)
        bytes += [0xB8, 0x01]
        return bytes
    }

    /// An Opus identification packet.
    static func opusHead(channels: UInt8 = 1, preSkip: UInt16 = 312) -> [UInt8] {
        // "OpusHead", version 1, channels, pre-skip, input rate, gain, mapping family 0.
        var bytes: [UInt8] = Array("OpusHead".utf8)
        bytes += [1, channels]
        bytes += le(UInt64(preSkip), 2)
        bytes += le(44_100, 4)
        bytes += le(0, 2)
        bytes += [0]
        return bytes
    }

    /// A comment packet: `signature`, the vendor, and the raw `comments`.
    static func commentPacket(signature: [UInt8], comments: [[UInt8]], vendor: String = "test vendor",
                              declaredCount: UInt32? = nil) -> [UInt8] {
        var bytes = signature + le(UInt64(vendor.utf8.count), 4) + Array(vendor.utf8)
        bytes += le(UInt64(declaredCount ?? UInt32(comments.count)), 4)
        for comment in comments { bytes += le(UInt64(comment.count), 4) + comment }
        return bytes
    }

    /// The comment signatures.
    static let vorbisSignature: [UInt8] = [0x03] + Array("vorbis".utf8)
    static let opusSignature: [UInt8] = Array("OpusTags".utf8)

    /// A whole Vorbis stream: the identification page, the comment packet
    /// (ended by the Vorbis framing byte) on as many pages as `perPage` needs,
    /// and an audio page and a last page ending at `granule`.
    static func vorbisStream(channels: UInt8 = 2, rate: UInt32 = 22_050, granule: Int64 = 44_100,
                             comments: [String] = [], commentPacket custom: [UInt8]? = nil,
                             serial: UInt32 = 1, perPage: Int = 255 * 254) -> [UInt8] {
        let id = vorbisID(channels: channels, rate: rate)
        let comment = custom ?? commentPacket(signature: vorbisSignature, comments: comments.map { Array($0.utf8) }) + [1]
        var pages = [page(type: 0x02, granule: 0, serial: serial, sequence: 0,
                          lacing: [UInt8(id.count)], payload: id)]
        pages += self.pages(carrying: comment, perPage: perPage, serial: serial)
        pages += audioPages(serial: serial, firstSequence: UInt32(pages.count), granule: granule)
        return pages.flatMap { $0 }
    }

    /// A whole Opus stream, like `vorbisStream`.
    static func opusStream(channels: UInt8 = 1, preSkip: UInt16 = 312, granule: Int64 = 96_312,
                           comments: [String] = [], commentPacket custom: [UInt8]? = nil,
                           serial: UInt32 = 1, perPage: Int = 255 * 254) -> [UInt8] {
        let head = opusHead(channels: channels, preSkip: preSkip)
        let comment = custom ?? commentPacket(signature: opusSignature, comments: comments.map { Array($0.utf8) })
        var pages = [page(type: 0x02, granule: 0, serial: serial, sequence: 0,
                          lacing: [UInt8(head.count)], payload: head)]
        pages += self.pages(carrying: comment, perPage: perPage, serial: serial)
        pages += audioPages(serial: serial, firstSequence: UInt32(pages.count), granule: granule)
        return pages.flatMap { $0 }
    }

    /// Two audio pages: one in the middle of the stream, and a last one at `granule`.
    static func audioPages(serial: UInt32, firstSequence: UInt32, granule: Int64) -> [[UInt8]] {
        [page(granule: granule / 2, serial: serial, sequence: firstSequence,
              lacing: [100], payload: [UInt8](repeating: 7, count: 100)),
         page(type: 0x04, granule: granule, serial: serial, sequence: firstSequence + 1,
              lacing: [50], payload: [UInt8](repeating: 9, count: 50))]
    }
}

/// A repeatable pseudo-random byte source (SplitMix64) for fuzz tests.
struct OggFuzzGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Stream facts

/// The reader's codec, format and duration facts, on streams built in memory
/// and on the two committed fixtures (their bytes only: never decoded).
final class OggHeaderReaderTests: XCTestCase {
    private typealias Builder = OggStreamBuilder

    /// A folder of the test's own, removed when the test ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A header parsed from `stream` for both windows.
    private func parse(_ stream: [UInt8]) -> OggHeaderReader.Header? {
        OggHeaderReader.parse(head: stream, tail: stream)
    }

    /// The two audio pages that end a Vorbis stream at 2 seconds.
    private func endPages(firstSequence: UInt32 = 9, granule: Int64 = 44_100) -> [UInt8] {
        Builder.audioPages(serial: 1, firstSequence: firstSequence, granule: granule).flatMap { $0 }
    }

    func testAVorbisStreamGivesItsFormatAndDuration() throws {
        let header = try XCTUnwrap(parse(Builder.vorbisStream()))
        XCTAssertEqual(header.codec, .vorbis)
        XCTAssertEqual(header.channels, 2)
        XCTAssertEqual(header.sampleRate, 22_050)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    func testAnOpusStreamGivesItsFormatAndDurationAfterThePreSkip() throws {
        let header = try XCTUnwrap(parse(Builder.opusStream()))
        XCTAssertEqual(header.codec, .opus)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 48_000)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    func testMonoStereoAndFiveChannelStreams() throws {
        for channels: UInt8 in [1, 2, 5] {
            let vorbis = try XCTUnwrap(parse(Builder.vorbisStream(channels: channels)))
            let opus = try XCTUnwrap(parse(Builder.opusStream(channels: channels)))
            XCTAssertEqual(vorbis.channels, Int(channels))
            XCTAssertEqual(opus.channels, Int(channels))
        }
    }

    /// An Opus stream that ends inside its pre-skip has no length.
    func testAnOpusStreamShorterThanItsPreSkipHasNoDuration() {
        XCTAssertNil(parse(Builder.opusStream(preSkip: 312, granule: 312)))
        XCTAssertNil(parse(Builder.opusStream(preSkip: 312, granule: 100)))
    }

    func testAZeroGranuleGivesNoDuration() {
        XCTAssertNil(parse(Builder.vorbisStream(granule: 0)))
    }

    /// The real fixtures prove the CRC and the page logic against real files.
    func testTheRealVorbisFixture() throws {
        let bytes = [UInt8](try Data(contentsOf: requireFile(OggTestFixtures.vorbis)))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: bytes, tail: bytes))
        XCTAssertEqual(header.codec, .vorbis)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 22_050)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.1)
    }

    func testTheRealOpusFixture() throws {
        let bytes = [UInt8](try Data(contentsOf: requireFile(OggTestFixtures.opus)))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: bytes, tail: bytes))
        XCTAssertEqual(header.codec, .opus)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 48_000)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.1)
    }

    // MARK: Refusals

    func testAWrongCRCOnTheFirstPageIsRefused() {
        var stream = Builder.vorbisStream()
        stream[22] ^= 0xFF
        XCTAssertNil(parse(stream))
    }

    /// A last page that fails its CRC is skipped, so the page before it,
    /// at half the length, sets the duration.
    func testAWrongCRCOnTheLastPageFallsBackToThePageBefore() throws {
        var stream = Builder.vorbisStream()
        stream[stream.count - 1] ^= 0xFF
        XCTAssertEqual(try XCTUnwrap(parse(stream)).duration, 1.0, accuracy: 0.0001)
    }

    func testPageVersionOneIsRefused() {
        let id = Builder.vorbisID()
        let first = Builder.page(type: 0x02, granule: 0, lacing: [UInt8(id.count)], payload: id, version: 1)
        let stream = first + endPages()
        XCTAssertNil(parse(stream))
    }

    func testAPageWithNoSegmentsIsRefused() {
        let first = Builder.page(type: 0x02, granule: 0, lacing: [], payload: [])
        XCTAssertNil(parse(first + endPages()))
    }

    func testALacingTablePromisingMoreThanTheBufferHoldsIsRefused() {
        let stream = Builder.vorbisStream()
        // The first page is 28 header bytes and 30 payload bytes: cut inside the payload.
        XCTAssertNil(OggHeaderReader.parse(head: Array(stream[0..<40]), tail: stream))
    }

    func testAFirstPageCutOffMidHeaderIsRefused() {
        let stream = Builder.vorbisStream()
        for length in [0, 3, 4, 26, 27, 28] {
            XCTAssertNil(OggHeaderReader.parse(head: Array(stream[0..<length]), tail: stream),
                         "head of \(length) bytes")
        }
    }

    func testOtherCodecsInOggAreRefused() {
        let flac = [0x7F] + Array("FLAC".utf8) + [UInt8](repeating: 0, count: 30)
        let speex = Array("Speex   ".utf8) + [UInt8](repeating: 1, count: 60)
        for id in [flac, speex] {
            let first = Builder.page(type: 0x02, granule: 0, lacing: [UInt8(id.count)], payload: id)
            XCTAssertNil(parse(first + endPages()))
        }
    }

    func testNonsenseInIdentificationHeadersIsRefused() {
        // Vorbis: nonzero version, zero channels, zero rate. Opus: zero channels, version 16.
        var badVersion = Builder.vorbisID()
        badVersion[7] = 1
        var noChannels = Builder.vorbisID()
        noChannels[11] = 0
        var opusNoChannels = Builder.opusHead()
        opusNoChannels[9] = 0
        var opusVersion = Builder.opusHead()
        opusVersion[8] = 0x10
        for id in [badVersion, noChannels, Builder.vorbisID(rate: 0), opusNoChannels, opusVersion] {
            let first = Builder.page(type: 0x02, granule: 0, lacing: [UInt8(id.count)], payload: id)
            XCTAssertNil(parse(first + endPages(granule: 96_000)))
        }
    }

    func testAFirstPageWithoutTheFirstPageFlagIsRefused() {
        let id = Builder.vorbisID()
        let first = Builder.page(type: 0, granule: 0, lacing: [UInt8(id.count)], payload: id)
        XCTAssertNil(parse(first + endPages()))
    }

    // MARK: The last page

    /// A last page with granule -1 is ignored in favour of the page before.
    func testALastPageWithGranuleMinusOneIsIgnored() throws {
        let stream = Builder.vorbisStream()
        let extra = Builder.page(type: 0x04, granule: -1, lacing: [10], payload: [UInt8](repeating: 1, count: 10))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream + extra))
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    /// A page of another stream, with another serial, does not set the duration.
    func testAPageOfAnotherStreamIsIgnored() throws {
        let stream = Builder.vorbisStream()
        let other = Builder.page(type: 0x04, granule: 999_999, serial: 77, lacing: [10],
                                 payload: [UInt8](repeating: 1, count: 10))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream + other))
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    /// A tail that begins in garbage holding stray "OggS" bytes still finds
    /// the real last page.
    func testAStrayOggSBeforeTheRealLastPageCostsNothing() throws {
        let stream = Builder.vorbisStream()
        let garbage = [UInt8](repeating: 0x4F, count: 50) + Array("OggS".utf8) + [0, 0, 5, 1, 2]
            + Array("OggS".utf8) + [UInt8](repeating: 0x33, count: 400)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: garbage + endPages()))
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    /// Bytes that only look like the start of "OggS" are passed over without
    /// counting against the bound on failed candidates.
    func testManyOByteLookalikesDoNotExhaustTheSearch() throws {
        let stream = Builder.vorbisStream()
        let tail = [UInt8](repeating: 0x4F, count: 20_000) + endPages()
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: tail))
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    // MARK: Robustness

    func testSeededRandomBytesNeverTrapAndGiveNil() {
        var generator = OggFuzzGenerator(seed: 20_261_016)
        for _ in 0..<300 {
            let length = Int.random(in: 0...3_000, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertNil(OggHeaderReader.parse(head: bytes, tail: bytes))
        }
    }

    /// Valid streams with a few random bytes changed, and cut short, never trap.
    func testCorruptedStreamsNeverTrap() {
        var generator = OggFuzzGenerator(seed: 42)
        let stream = Builder.vorbisStream(comments: ["TITLE=a", "ARTIST=b"])
        for _ in 0..<300 {
            var copy = stream
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let index = Int.random(in: 0..<copy.count, using: &generator)
                copy[index] = UInt8.random(in: 0...255, using: &generator)
            }
            let cut = Int.random(in: 0...copy.count, using: &generator)
            _ = OggHeaderReader.parse(head: Array(copy[0..<cut]), tail: copy)
        }
    }

    // MARK: Reading a file

    func testReadingAFileGivesItsHeader() throws {
        let url = folder.appendingPathComponent("a.ogg")
        try Data(Builder.vorbisStream()).write(to: url)
        let header = try XCTUnwrap(OggHeaderReader.read(at: url))
        XCTAssertEqual(header.channels, 2)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    /// A file longer than both windows together still gives its length from its end.
    func testReadingALongFileUsesItsEnd() throws {
        let url = folder.appendingPathComponent("long.opus")
        // The start of a stream, filler pages of one unfinished packet, then the end pages.
        let start = Builder.opusStream().dropLast(
            Builder.audioPages(serial: 1, firstSequence: 0, granule: 96_312).flatMap { $0 }.count)
        let filler = Builder.page(granule: 1_000, lacing: [UInt8](repeating: 255, count: 200),
                                  payload: [UInt8](repeating: 5, count: 200 * 255))
        var file = Array(start)
        for _ in 0..<12 { file += filler }
        file += Builder.audioPages(serial: 1, firstSequence: 99, granule: 96_312).flatMap { $0 }
        XCTAssertGreaterThan(file.count, OggHeaderReader.headLength + OggHeaderReader.tailLength)
        try Data(file).write(to: url)
        XCTAssertEqual(try XCTUnwrap(OggHeaderReader.read(at: url)).duration, 2.0, accuracy: 0.0001)
    }

    func testReadingUnreadableThingsGivesNil() throws {
        XCTAssertNil(OggHeaderReader.read(at: folder.appendingPathComponent("missing.ogg")))
        let empty = folder.appendingPathComponent("empty.ogg")
        try Data().write(to: empty)
        XCTAssertNil(OggHeaderReader.read(at: empty))
        XCTAssertNil(OggHeaderReader.read(at: folder))
        let text = folder.appendingPathComponent("text.ogg")
        try Data("this is not an Ogg file at all".utf8).write(to: text)
        XCTAssertNil(OggHeaderReader.read(at: text))
    }
}

// MARK: - Tags

/// The reader's tags: the comment packet's fields, its framing across pages,
/// and the limits that keep a hostile or oversized packet harmless.
final class OggHeaderTagTests: XCTestCase {
    private typealias Builder = OggStreamBuilder

    /// The tags of a Vorbis stream and of an Opus stream carrying `comments`;
    /// both must agree, so each test checks the codecs together.
    private func tags(_ comments: [String], file: StaticString = #filePath, line: UInt = #line)
        throws -> OggHeaderReader.Tags {
        let vorbis = Builder.vorbisStream(comments: comments)
        let opus = Builder.opusStream(comments: comments)
        let vorbisTags = try XCTUnwrap(OggHeaderReader.parse(head: vorbis, tail: vorbis), file: file, line: line).tags
        let opusTags = try XCTUnwrap(OggHeaderReader.parse(head: opus, tail: opus), file: file, line: line).tags
        XCTAssertEqual(vorbisTags, opusTags, "Vorbis and Opus disagree", file: file, line: line)
        return vorbisTags
    }

    func testAllFiveFields() throws {
        let tags = try tags(["TITLE=A Title", "ARTIST=An Artist", "ALBUM=An Album", "GENRE=Drama", "DATE=2020-05-01"])
        XCTAssertEqual(tags, OggHeaderReader.Tags(title: "A Title", artist: "An Artist", album: "An Album",
                                                  genre: "Drama", date: "2020-05-01"))
    }

    func testNamesMatchInAnyCase() throws {
        let tags = try tags(["title=Low", "ArTiSt=Mixed", "Album=Cap", "genre=lower", "Date=2001"])
        XCTAssertEqual(tags.title, "Low")
        XCTAssertEqual(tags.artist, "Mixed")
        XCTAssertEqual(tags.album, "Cap")
        XCTAssertEqual(tags.genre, "lower")
        XCTAssertEqual(tags.date, "2001")
    }

    func testPerformerIsTheArtistWhenThereIsNoArtist() throws {
        XCTAssertEqual(try tags(["PERFORMER=Reader"]).artist, "Reader")
        XCTAssertEqual(try tags(["PERFORMER=Reader", "ARTIST=Author"]).artist, "Author")
        XCTAssertEqual(try tags(["ARTIST=", "PERFORMER=Reader"]).artist, "Reader")
    }

    func testACommentWithNoEqualsSignIsSkipped() throws {
        let tags = try tags(["JUST SOME TEXT", "TITLE=Kept"])
        XCTAssertEqual(tags.title, "Kept")
    }

    func testAnEmptyValueIsEmpty() throws {
        let tags = try tags(["TITLE=", "ARTIST=Someone"])
        XCTAssertEqual(tags.title, "")
        XCTAssertEqual(tags.artist, "Someone")
    }

    func testTheFirstOfADuplicatedNameWins() throws {
        XCTAssertEqual(try tags(["TITLE=First", "title=Second"]).title, "First")
    }

    func testValuesAreTrimmedAndKeepTheirUnicode() throws {
        let tags = try tags(["TITLE=  Café 日本 \n", "ALBUM=a=b"])
        XCTAssertEqual(tags.title, "Café 日本")
        XCTAssertEqual(tags.album, "a=b")      // only the first "=" splits
    }

    func testNoCommentsGivesEmptyTags() throws {
        XCTAssertEqual(try tags([]), OggHeaderReader.Tags())
    }

    // MARK: Packets across pages

    /// A comment packet carried by two pages and by three, with lacing tables
    /// of 255-valued segments and pages flagged as continued.
    func testACommentPacketSpanningPages() throws {
        for (length, pageCount) in [(600, 2), (1_000, 3)] {
            let title = String(repeating: "x", count: length)
            let packet = Builder.commentPacket(signature: Builder.opusSignature,
                                               comments: [Array("TITLE=\(title)".utf8), Array("ARTIST=Late".utf8)])
            XCTAssertGreaterThanOrEqual(Builder.pages(carrying: packet, perPage: 255 * 2).count, pageCount)
            let stream = Builder.opusStream(commentPacket: packet, perPage: 255 * 2)
            let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
            XCTAssertEqual(header.tags.title, title)
            XCTAssertEqual(header.tags.artist, "Late")
        }
    }

    /// A Vorbis comment packet whose length is exactly a multiple of 255 ends
    /// with a zero lacing value on its last page.
    func testAPacketExactlyFillingItsSegmentsStillEnds() throws {
        let signature = Builder.vorbisSignature
        let base = Builder.commentPacket(signature: signature, comments: [Array("TITLE=".utf8)]).count + 1
        let title = String(repeating: "y", count: 765 - base)
        let packet = Builder.commentPacket(signature: signature, comments: [Array("TITLE=\(title)".utf8)]) + [1]
        XCTAssertEqual(packet.count, 765)
        let stream = Builder.vorbisStream(commentPacket: packet, perPage: 255)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags.title, title)
    }

    /// A page of another stream between the pages of the comment packet is passed over.
    func testAnotherStreamsPageBetweenCommentPagesIsSkipped() throws {
        let padded = Builder.commentPacket(signature: Builder.opusSignature,
                                           comments: [Array("TITLE=Muxed".utf8), Array(("PAD=" + String(repeating: "p", count: 700)).utf8)])
        let head = Builder.opusHead()
        let comment = Builder.pages(carrying: padded, perPage: 255 * 2)
        let other = Builder.page(serial: 9, lacing: [5], payload: [1, 2, 3, 4, 5])
        let stream = (Builder.page(type: 0x02, granule: 0, lacing: [UInt8(head.count)], payload: head)
            + comment[0] + other + comment.dropFirst().flatMap { $0 }
            + Builder.audioPages(serial: 1, firstSequence: 9, granule: 96_312).flatMap { $0 })
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags.title, "Muxed")
    }

    /// A page that should continue the comment packet but is not flagged as
    /// doing so gives empty tags, and the header stays.
    func testAnUnflaggedContinuationGivesEmptyTags() throws {
        let head = Builder.opusHead()
        let first = Builder.page(type: 0x02, granule: 0, lacing: [UInt8(head.count)], payload: head)
        let partial = Builder.page(lacing: [255], payload: [UInt8](repeating: 1, count: 255))
        let unflagged = Builder.page(type: 0, lacing: [10], payload: [UInt8](repeating: 1, count: 10))
        let stream = first + partial + unflagged
            + Builder.audioPages(serial: 1, firstSequence: 9, granule: 96_312).flatMap { $0 }
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags())
    }

    // MARK: Limits

    /// A cover-art sized packet (over 256 KiB) gives empty tags and still a header.
    func testAPacketOver256KiBGivesEmptyTagsAndAHeader() throws {
        let art = String(repeating: "A", count: 300_000)
        let packet = Builder.commentPacket(signature: Builder.opusSignature,
                                           comments: [Array("TITLE=Hidden".utf8), Array("METADATA_BLOCK_PICTURE=\(art)".utf8)])
        let stream = Builder.opusStream(commentPacket: packet)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags())
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    /// A comment packet that runs past the end of `head` gives empty tags, never a failure.
    func testACommentPacketNotWhollyInHeadGivesEmptyTags() throws {
        let stream = Builder.vorbisStream(comments: ["TITLE=\(String(repeating: "z", count: 2_000))"], perPage: 255 * 2)
        // Cut the head inside the comment packet's pages: only the identification page and one more fit.
        let head = Array(stream[0..<1_000])
        let header = try XCTUnwrap(OggHeaderReader.parse(head: head, tail: stream))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags())
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
    }

    func testADeclaredLengthOfFFFFFFFFStopsReadingButKeepsWhatWasRead() throws {
        // The count says two comments; the second declares 0xFFFFFFFF bytes.
        let kept = Array("TITLE=Kept".utf8)
        let packet = Builder.commentPacket(signature: Builder.opusSignature, comments: [], declaredCount: 2)
            + Builder.le(UInt64(kept.count), 4) + kept
            + Builder.le(0xFFFF_FFFF, 4) + Array("ARTIST=Lost".utf8)
        let stream = Builder.opusStream(commentPacket: packet)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags.title, "Kept")
        XCTAssertEqual(header.tags.artist, "")
    }

    func testAVendorLengthOfFFFFFFFFGivesEmptyTags() throws {
        let packet = Builder.opusSignature + Builder.le(0xFFFF_FFFF, 4) + Array("vendor".utf8)
        let stream = Builder.opusStream(commentPacket: packet)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags())
    }

    func testACountOfFFFFFFFFReadsOnlyTheCommentsThatAreThere() throws {
        let packet = Builder.commentPacket(signature: Builder.opusSignature,
                                           comments: [Array("TITLE=One".utf8), Array("ALBUM=Two".utf8)],
                                           declaredCount: 0xFFFF_FFFF)
        let stream = Builder.opusStream(commentPacket: packet)
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags.title, "One")
        XCTAssertEqual(header.tags.album, "Two")
    }

    /// Only the first 1,000 comments are read.
    func testOnlyTheFirstThousandCommentsAreRead() throws {
        var comments = (0..<1_200).map { "X\($0)=v" }
        comments[999] = "ALBUM=Last Read"
        comments[1_000] = "TITLE=Too Late"
        let tags = try tags(comments)
        XCTAssertEqual(tags.album, "Last Read")
        XCTAssertEqual(tags.title, "")
    }

    func testAWrongSignatureGivesEmptyTags() throws {
        // An Opus comment signature in a Vorbis stream, and the reverse.
        let opusTags = Builder.commentPacket(signature: Builder.opusSignature, comments: [Array("TITLE=No".utf8)])
        let vorbisTags = Builder.commentPacket(signature: Builder.vorbisSignature, comments: [Array("TITLE=No".utf8)])
        let inVorbis = Builder.vorbisStream(commentPacket: opusTags)
        let inOpus = Builder.opusStream(commentPacket: vorbisTags)
        XCTAssertEqual(try XCTUnwrap(OggHeaderReader.parse(head: inVorbis, tail: inVorbis)).tags, OggHeaderReader.Tags())
        XCTAssertEqual(try XCTUnwrap(OggHeaderReader.parse(head: inOpus, tail: inOpus)).tags, OggHeaderReader.Tags())
    }

    /// The real fixtures carry an encoder's vendor and few comments; reading
    /// their bytes must at least give a header and never trap on the tags.
    func testTheRealFixturesGiveTagsWithoutTrouble() throws {
        for fixture in [OggTestFixtures.vorbis, OggTestFixtures.opus] {
            let bytes = [UInt8](try Data(contentsOf: requireFile(fixture)))
            XCTAssertNotNil(OggHeaderReader.parse(head: bytes, tail: bytes))
        }
    }
}
