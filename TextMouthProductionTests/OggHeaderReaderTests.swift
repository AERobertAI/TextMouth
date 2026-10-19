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

    /// A whole Opus stream, like `vorbisStream`. `startOffset` is the granule
    /// the stream starts at: 0 for a normal stream, more for one cut from a
    /// longer recording (RFC 7845 4.5).
    static func opusStream(channels: UInt8 = 1, preSkip: UInt16 = 312, granule: Int64 = 96_312,
                           comments: [String] = [], commentPacket custom: [UInt8]? = nil,
                           serial: UInt32 = 1, perPage: Int = 255 * 254, startOffset: Int64 = 0) -> [UInt8] {
        let head = opusHead(channels: channels, preSkip: preSkip)
        let comment = custom ?? commentPacket(signature: opusSignature, comments: comments.map { Array($0.utf8) })
        var pages = [page(type: 0x02, granule: 0, serial: serial, sequence: 0,
                          lacing: [UInt8(head.count)], payload: head)]
        pages += self.pages(carrying: comment, perPage: perPage, serial: serial)
        pages += audioPages(serial: serial, firstSequence: UInt32(pages.count), granule: granule,
                            opusStartOffset: startOffset)
        return pages.flatMap { $0 }
    }

    /// Two audio pages: one in the middle of the stream, and a last one at
    /// `granule`. With `opusStartOffset` nil the packets are filler (a Vorbis
    /// stream's, which the reader does not decode). With it set they are one
    /// valid 20 ms Opus packet each (TOC 0xF8, 960 samples), and the first
    /// page's granule is what a real stream's is: the granule the stream
    /// starts at (0 for a normal stream) plus the 960 samples it holds.
    static func audioPages(serial: UInt32, firstSequence: UInt32, granule: Int64,
                           opusStartOffset: Int64? = nil) -> [[UInt8]] {
        let opusPacket = { (length: Int) in [UInt8(0xF8)] + [UInt8](repeating: 9, count: length - 1) }
        return [page(granule: opusStartOffset.map { $0 + 960 } ?? granule / 2, serial: serial, sequence: firstSequence,
                     lacing: [100], payload: opusStartOffset == nil ? [UInt8](repeating: 7, count: 100) : opusPacket(100)),
                page(type: 0x04, granule: granule, serial: serial, sequence: firstSequence + 1,
                     lacing: [50], payload: opusStartOffset == nil ? [UInt8](repeating: 9, count: 50) : opusPacket(50))]
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

    /// A granule that claims more than a year of audio is corrupt, and is
    /// refused: a crafted file must not give a length that later overflows
    /// `Int(seconds)` and traps. A hundred hours is audio.
    func testAGranuleClaimingMoreThanAYearGivesNoDuration() throws {
        XCTAssertNil(parse(Builder.vorbisStream(rate: 1, granule: Int64.max)))
        XCTAssertNil(parse(Builder.vorbisStream(rate: 22_050, granule: 22_050 * 31_536_001)))
        XCTAssertNil(parse(Builder.opusStream(granule: Int64.max)))
        let long = try XCTUnwrap(parse(Builder.vorbisStream(rate: 22_050, granule: 22_050 * 360_000)))
        XCTAssertEqual(long.duration, 360_000, accuracy: 0.5)
        XCTAssertEqual(OggHeaderReader.maximumDuration, 31_536_000)
    }

    /// The real fixtures prove the CRC and the page logic against real files.
    func testTheRealVorbisFixture() throws {
        let bytes = [UInt8](try Data(contentsOf: requireFile(OggTestFixtures.vorbis)))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: bytes, tail: bytes))
        XCTAssertEqual(header.codec, .vorbis)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 22_050)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.1)
        XCTAssertEqual(OggHeaderReader.streamStartOffset(inHead: bytes), 0)
    }

    func testTheRealOpusFixture() throws {
        let bytes = [UInt8](try Data(contentsOf: requireFile(OggTestFixtures.opus)))
        let header = try XCTUnwrap(OggHeaderReader.parse(head: bytes, tail: bytes))
        XCTAssertEqual(header.codec, .opus)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 48_000)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.1)
        XCTAssertEqual(OggHeaderReader.streamStartOffset(inHead: bytes), 0)
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

    // MARK: Streams among other streams

    /// A start-of-stream page of serial `serial` whose first packet is
    /// `signature` followed by filler (a Skeleton "fishead", a Theora header).
    private func startPage(serial: UInt32, signature: [UInt8]) -> [UInt8] {
        let payload = signature + [UInt8](repeating: 0, count: 20)
        return Builder.page(type: 0x02, granule: 0, serial: serial, lacing: [UInt8(payload.count)], payload: payload)
    }

    /// The Ogg Skeleton start page, serial 1.
    private var fishead: [UInt8] { startPage(serial: 1, signature: Array("fishead".utf8) + [0]) }

    /// A Theora start page, serial 5.
    private var theora: [UInt8] { startPage(serial: 5, signature: [0x80] + Array("theora".utf8)) }

    /// A later page of the Skeleton stream: a "fisbone", with `granule`.
    private func skeletonPage(granule: Int64 = 0) -> [UInt8] {
        Builder.page(granule: granule, serial: 1, lacing: [10], payload: [UInt8](repeating: 3, count: 10))
    }

    /// The pages of a Vorbis or Opus stream of serial 2 (title "Muxed", its
    /// comment packet on several pages, audio ending at 2 seconds), with the
    /// pages of other streams placed: `leading` ahead of its start page,
    /// `afterStart` right after it, `betweenComment` after the comment
    /// packet's first page, and `trailing` at the very end.
    private func multiplexed(opus: Bool, leading: [[UInt8]] = [], afterStart: [[UInt8]] = [],
                             betweenComment: [[UInt8]] = [], trailing: [[UInt8]] = []) -> [UInt8] {
        let identification = opus ? Builder.opusHead() : Builder.vorbisID()
        let signature = opus ? Builder.opusSignature : Builder.vorbisSignature
        let padding = Array(("PAD=" + String(repeating: "p", count: 700)).utf8)
        let comment = Builder.commentPacket(signature: signature, comments: [Array("TITLE=Muxed".utf8), padding])
            + (opus ? [] : [1])
        let start = Builder.page(type: 0x02, granule: 0, serial: 2, lacing: [UInt8(identification.count)],
                                 payload: identification)
        let commentPages = Builder.pages(carrying: comment, perPage: 255 * 2, serial: 2)
        XCTAssertGreaterThan(commentPages.count, 1, "the comment packet must span pages")
        let audio = Builder.audioPages(serial: 2, firstSequence: 9, granule: opus ? 96_312 : 44_100,
                                      opusStartOffset: opus ? 0 : nil)
        let pages: [[UInt8]] = leading + [start] + afterStart + commentPages.prefix(1) + betweenComment
            + commentPages.dropFirst() + audio + trailing
        return pages.flatMap { $0 }
    }

    /// A stream behind a Skeleton "fishead", with a "fisbone" after its
    /// start page, reads exactly as the same stream without the Skeleton.
    func testAStreamBehindASkeletonHeadReadsAsWithoutIt() throws {
        for opus in [false, true] {
            let plain = try XCTUnwrap(parse(multiplexed(opus: opus)), "opus \(opus)")
            let skeleton = try XCTUnwrap(parse(multiplexed(opus: opus, leading: [fishead],
                                                           afterStart: [skeletonPage()])), "opus \(opus)")
            XCTAssertEqual(skeleton, plain)
            XCTAssertEqual(skeleton.codec, opus ? .opus : .vorbis)
            XCTAssertEqual(skeleton.tags.title, "Muxed")
            XCTAssertEqual(skeleton.duration, 2.0, accuracy: 0.0001)
        }
    }

    /// A Theora start page, alone or with the Skeleton's, is passed over.
    func testATheoraStartPageBeforeTheAudioStreamIsPassedOver() throws {
        for leading in [[theora], [fishead, theora], [theora, fishead]] {
            for opus in [false, true] {
                let header = try XCTUnwrap(parse(multiplexed(opus: opus, leading: leading,
                                                             afterStart: [skeletonPage()])))
                XCTAssertEqual(header, parse(multiplexed(opus: opus)))
            }
        }
    }

    /// Leading start pages that hold no Vorbis or Opus stream give nil.
    func testSkeletonAndTheoraAloneGiveNoStream() {
        let audio = Builder.audioPages(serial: 1, firstSequence: 3, granule: 44_100).flatMap { $0 }
        XCTAssertNil(parse(fishead + theora + audio))
        XCTAssertNil(parse(fishead + audio))
    }

    /// A later page of the Skeleton stream with a larger granule than the
    /// audio's does not set the length: only the audio stream's serial does.
    func testALaterSkeletonPageWithALargerGranuleIsIgnoredForTheLength() throws {
        for opus in [false, true] {
            let stream = multiplexed(opus: opus, leading: [fishead], trailing: [skeletonPage(granule: 9_999_999)])
            XCTAssertEqual(try XCTUnwrap(parse(stream)).duration, 2.0, accuracy: 0.0001)
        }
    }

    /// A Skeleton page between the comment packet's pages is passed over.
    func testASkeletonPageBetweenCommentPagesIsPassedOver() throws {
        for opus in [false, true] {
            let stream = multiplexed(opus: opus, leading: [fishead], betweenComment: [skeletonPage()])
            XCTAssertEqual(try XCTUnwrap(parse(stream)).tags.title, "Muxed")
        }
    }

    /// Two start pages of one serial count once: the second is not tried, so
    /// a Vorbis packet on a repeated Skeleton serial is not taken for audio.
    func testTwoStartPagesOfOneSerialCountOnce() {
        let id = Builder.vorbisID()
        let repeated = Builder.page(type: 0x02, granule: 0, serial: 1, lacing: [UInt8(id.count)], payload: id)
        let audio = Builder.audioPages(serial: 1, firstSequence: 3, granule: 44_100).flatMap { $0 }
        XCTAssertNil(parse(fishead + repeated + audio))
    }

    /// A start page where no packet ends is passed over, and the walk goes on.
    func testAStartPageWithNoPacketEndingIsPassedOver() throws {
        let unfinished = Builder.page(type: 0x02, granule: 0, serial: 7, lacing: [255],
                                      payload: [UInt8](repeating: 1, count: 255))
        let header = try XCTUnwrap(parse(multiplexed(opus: false, leading: [unfinished, fishead])))
        XCTAssertEqual(header, parse(multiplexed(opus: false)))
    }

    /// A leading page that fails its CRC ends the walk, so the stream behind it is not found.
    func testACorruptStartPageEndsTheWalk() {
        var stream = multiplexed(opus: false, leading: [fishead])
        stream[fishead.count + 22] ^= 0xFF           // the audio stream's start page, second in the file
        XCTAssertNil(parse(stream))
    }

    /// Nothing but start pages, cut anywhere, never traps.
    func testAWalkOfStartPagesCutAnywhereNeverTraps() {
        let stream = multiplexed(opus: true, leading: [fishead, theora])
        for length in stride(from: 0, through: stream.count, by: 7) {
            _ = OggHeaderReader.parse(head: Array(stream[0..<length]), tail: stream)
        }
    }

    // MARK: A stream that starts at a nonzero granule

    /// Writes bits least significant first, as Vorbis packs them.
    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bitCount = 0

        /// Appends the low `bits` bits of `value`, least significant first.
        mutating func write(_ value: UInt32, bits: Int) {
            for index in 0..<bits {
                if bitCount % 8 == 0 { bytes.append(0) }
                if (value >> UInt32(index)) & 1 == 1 { bytes[bytes.count - 1] |= 1 << UInt8(bitCount % 8) }
                bitCount += 1
            }
        }

        /// Appends whole bytes.
        mutating func write(bytes values: [UInt8]) {
            for value in values { write(UInt32(value), bits: 8) }
        }
    }

    /// A Vorbis setup packet: `0x05 "vorbis"`, `filler` in place of the
    /// codebooks and the rest, then the modes as 4.2.4 ends the header (the
    /// count minus one in 6 bits, per mode a block flag, window type,
    /// transform type and mapping, then the framing bit). `longBlocks` gives
    /// each mode's block flag; the other parameters let a test break one field.
    private func vorbisSetup(longBlocks: [Bool], mappings: [UInt8]? = nil, filler: [UInt8] = [],
                             countField: UInt32? = nil, windowType: UInt32 = 0) -> [UInt8] {
        var writer = BitWriter()
        writer.write(bytes: [0x05] + Array("vorbis".utf8) + filler)
        writer.write(countField ?? UInt32(longBlocks.count - 1), bits: 6)
        for (index, isLong) in longBlocks.enumerated() {
            writer.write(isLong ? 1 : 0, bits: 1)
            writer.write(windowType, bits: 16)
            writer.write(0, bits: 16)
            writer.write(UInt32(mappings?[index] ?? 0), bits: 8)
        }
        writer.write(1, bits: 1)                      // the framing bit
        return writer.bytes
    }

    /// A Vorbis audio packet of mode `mode`, in a setup of `modeCount` modes:
    /// the packet type bit (0), then the mode number in `ilog(modeCount - 1)` bits.
    private func vorbisAudioPacket(mode: Int, of modeCount: Int) -> [UInt8] {
        let bits = (modeCount - 1).bitWidth - (modeCount - 1).leadingZeroBitCount
        XCTAssertTrue(mode >> bits == 0, "mode \(mode) needs more than \(bits) bits")
        return [UInt8(mode << 1)] + [UInt8](repeating: 0x55, count: 11)
    }

    /// An Opus packet: a TOC byte and `length - 1` bytes of frame data.
    private func opusPacket(toc: [UInt8], length: Int = 12) -> [UInt8] {
        toc + [UInt8](repeating: 0x21, count: max(0, length - toc.count))
    }

    /// One audio page: the packets it completes, and its granule position.
    private typealias AudioPage = (packets: [[UInt8]], granule: Int64)

    /// A whole stream like `Builder.vorbisStream`/`opusStream` (serial 1,
    /// title "Cut"), with the headers on their own pages, a Vorbis setup
    /// header (`setup`, default two modes), the given audio pages, and a last
    /// page at granule `last`. Every audio packet must be under 255 bytes.
    private func leadStream(opus: Bool, identification: [UInt8]? = nil, setup: [UInt8]? = nil,
                            setupPerPage: Int = 255 * 254, audio: [AudioPage], last: Int64) -> [UInt8] {
        let id = identification ?? (opus ? Builder.opusHead() : Builder.vorbisID())
        let comment = Builder.commentPacket(signature: opus ? Builder.opusSignature : Builder.vorbisSignature,
                                            comments: [Array("TITLE=Cut".utf8)]) + (opus ? [] : [1])
        var pages: [[UInt8]] = [Builder.page(type: 0x02, granule: 0, lacing: [UInt8(id.count)], payload: id)]
        pages += Builder.pages(carrying: comment, firstSequence: 1)
        if !opus {
            pages += Builder.pages(carrying: setup ?? vorbisSetup(longBlocks: [false, true]),
                                   perPage: setupPerPage, firstSequence: UInt32(pages.count))
        }
        for page in audio {
            pages.append(Builder.page(granule: page.granule, sequence: UInt32(pages.count),
                                      lacing: page.packets.map { UInt8($0.count) }, payload: page.packets.flatMap { $0 }))
        }
        pages.append(Builder.page(type: 0x04, granule: last, sequence: UInt32(pages.count), lacing: [10],
                                  payload: [UInt8](repeating: 9, count: 10)))
        return pages.flatMap { $0 }
    }

    /// The stream's offset as the reader finds it.
    private func offset(_ stream: [UInt8]) -> Int64 {
        OggHeaderReader.streamStartOffset(inHead: stream)
    }

    /// An hour of Vorbis samples at 22,050 Hz, and of Opus samples at 48,000 Hz.
    private let vorbisHour: Int64 = 3_600 * 22_050
    private let opusHour: Int64 = 3_600 * 48_000

    /// Vorbis cut an hour in, with a short (256) and a long (2,048) block mode
    /// and a mixed run of packets, reads its true length to the sample.
    func testAVorbisStreamCutAnHourInReadsItsTrueLength() throws {
        // Long, short, short, long, short, long: 576 + 128 + 576 + 576 + 576 = 2,432 samples after the first.
        let modes = [1, 0, 0, 1, 0, 1]
        let packets = modes.map { vorbisAudioPacket(mode: $0, of: 2) }
        let last = vorbisHour + 22_050 * 1_800 + 1_234
        let stream = leadStream(opus: false, audio: [(packets, vorbisHour + 2_432)], last: last)
        XCTAssertEqual(offset(stream), vorbisHour)
        let header = try XCTUnwrap(parse(stream))
        XCTAssertEqual(header.duration, Double(22_050 * 1_800 + 1_234) / 22_050, accuracy: 1e-9)
        XCTAssertEqual(header.tags.title, "Cut")
    }

    /// A stream whose first granule equals its own samples has offset 0 and
    /// the length of its last granule, as before.
    func testAVorbisStreamThatStartsAtZeroIsUnchanged() throws {
        let packets = [1, 0, 0, 1, 0, 1].map { vorbisAudioPacket(mode: $0, of: 2) }
        let stream = leadStream(opus: false, audio: [(packets, 2_432)], last: 44_100)
        XCTAssertEqual(offset(stream), 0)
        XCTAssertEqual(try XCTUnwrap(parse(stream)).duration, 2.0, accuracy: 0.0001)
    }

    /// A setup header of one mode reads its mode number in 0 bits.
    func testAOneModeSetupHeader() {
        for (isLong, samples) in [(false, Int64(3 * 128)), (true, Int64(3 * 1_024))] {
            let packets = (0..<4).map { _ in vorbisAudioPacket(mode: 0, of: 1) }
            let stream = leadStream(opus: false, setup: vorbisSetup(longBlocks: [isLong]),
                                    audio: [(packets, vorbisHour + samples)], last: vorbisHour + 44_100)
            XCTAssertEqual(offset(stream), vorbisHour, "long \(isLong)")
        }
    }

    /// Filler ahead of the modes, with a long run of zero bytes and a run of
    /// ones, and mappings that are not 0, does not mislead the mode search.
    func testASetupHeaderWithFillerAndAFalseZeroRun() {
        let filler = [UInt8](repeating: 0xFF, count: 9) + [UInt8](repeating: 0, count: 30) + [1, 0, 0, 0, 0, 0, 0]
        let setup = vorbisSetup(longBlocks: [true, false, true], mappings: [0, 1, 0], filler: filler)
        // Modes 0, 1, 2, 1: long, short, long, short: 3 x 576 samples after the first.
        let packets = [0, 1, 2, 1].map { vorbisAudioPacket(mode: $0, of: 3) }
        let stream = leadStream(opus: false, setup: setup, audio: [(packets, vorbisHour + 1_728)],
                                last: vorbisHour + 44_100)
        XCTAssertEqual(offset(stream), vorbisHour)
    }

    /// Two modes whose mappings are 0 also read as one mode (the count field
    /// before the last mode is 0): the larger count wins, so the first
    /// mode's block size is the one used.
    func testALargerModeCountWinsOverASmallerThatFitsByChance() {
        // Modes [short, long]: packets 0, 1, 0 = short, long, short = 576 + 576.
        let packets = [0, 1, 0].map { vorbisAudioPacket(mode: $0, of: 2) }
        let stream = leadStream(opus: false, audio: [(packets, vorbisHour + 1_152)], last: vorbisHour + 44_100)
        XCTAssertEqual(offset(stream), vorbisHour)
    }

    /// The most modes the 6-bit count allows, 64, with a 6-bit mode number.
    func testASetupHeaderOfSixtyFourModes() {
        let setup = vorbisSetup(longBlocks: (0..<64).map { $0 % 2 == 1 })
        // Modes 63 (long), 0 (short), 1 (long): 576 + 576 after the first.
        let packets = [63, 0, 1].map { vorbisAudioPacket(mode: $0, of: 64) }
        let stream = leadStream(opus: false, setup: setup, audio: [(packets, vorbisHour + 1_152)],
                                last: vorbisHour + 44_100)
        XCTAssertEqual(offset(stream), vorbisHour)
    }

    /// A first audio page with granule -1 (which the format does not allow)
    /// is counted in with the page after it that has a granule.
    func testAFirstAudioPageWithGranuleMinusOneIsCountedWithTheNext() {
        let first = [1, 0].map { vorbisAudioPacket(mode: $0, of: 2) }
        let second = [0, 1].map { vorbisAudioPacket(mode: $0, of: 2) }
        // Long, short, short, long: 576 + 128 + 576 after the first packet.
        let stream = leadStream(opus: false, audio: [(first, -1), (second, vorbisHour + 1_280)],
                                last: vorbisHour + 44_100)
        XCTAssertEqual(offset(stream), vorbisHour)
    }

    /// Opus cut an hour in reads its true length, and the same stream
    /// starting at 0 reads as before.
    func testAnOpusStreamCutAnHourInReadsItsTrueLength() throws {
        let cut = Builder.opusStream(granule: opusHour + 48_000 * 1_800 + 312, startOffset: opusHour)
        XCTAssertEqual(offset(cut), opusHour)
        XCTAssertEqual(try XCTUnwrap(parse(cut)).duration, 1_800, accuracy: 1e-9)

        let normal = Builder.opusStream()
        XCTAssertEqual(offset(normal), 0)
        XCTAssertEqual(try XCTUnwrap(parse(normal)).duration, 2.0, accuracy: 1e-9)
    }

    /// A code 3 packet of three frames and a code 1 packet of two are counted right.
    func testOpusFrameCountCodes() {
        let packets = [opusPacket(toc: [0xFB, 0x03]), opusPacket(toc: [0xF9], length: 11)]
        let stream = leadStream(opus: true, audio: [(packets, opusHour + 3 * 960 + 2 * 960)],
                                last: opusHour + 96_312)
        XCTAssertEqual(offset(stream), opusHour)
    }

    /// Frame sizes by TOC config (RFC 6716 3.1) and frame counts by code (3.2),
    /// each as the number of samples one packet holds.
    func testOpusSamplesPerPacket() {
        let cases: [(toc: [UInt8], samples: Int64)] = [
            ([0x00], 480), ([0x08], 960), ([0x10], 1_920), ([0x18], 2_880),          // SILK, config 0 to 3
            ([0x40], 480), ([0x58], 2_880),                                          // SILK, configs 8 and 11
            ([0x60], 480), ([0x68], 960), ([0x70], 480), ([0x78], 960),              // hybrid, configs 12 to 15
            ([0x80], 120), ([0x88], 240), ([0x90], 480), ([0x98], 960),              // CELT, configs 16 to 19
            ([0xE0], 120), ([0xE8], 240), ([0xF0], 480), ([0xF8], 960),              // CELT, configs 28 to 31
            ([0xFA], 1_920),                                                         // code 2: two frames
            ([0xFB, 0x01], 960), ([0xFB, 0x06], 5_760),                              // code 3: one and six frames
            ([0xFB, 0xC6], 5_760),                                                   // code 3 with the v and p flags set
        ]
        for testCase in cases {
            let stream = leadStream(opus: true, audio: [([opusPacket(toc: testCase.toc)], opusHour + testCase.samples)],
                                    last: opusHour + 96_312)
            XCTAssertEqual(offset(stream), opusHour, "TOC \(testCase.toc)")
        }
    }

    /// Packets that are not valid Opus (RFC 6716 3.4) give offset 0, the old length.
    func testInvalidOpusPacketsGiveOffsetZero() throws {
        let invalid: [[UInt8]] = [
            [],                                        // empty
            [0xFB],                                    // code 3 without its frame count byte
            [0xFB, 0x00],                              // code 3 of no frames
            [0xFB, 0x07],                              // 7 x 20 ms = 140 ms, over the 120 ms limit
            [0x1B, 0x03],                              // 3 x 60 ms = 180 ms
        ]
        for packet in invalid {
            let stream = leadStream(opus: true, audio: [([opusPacket(toc: [0xF8]), packet], opusHour + 1_920)],
                                    last: opusHour + 96_312)
            XCTAssertEqual(offset(stream), 0, "packet \(packet)")
            XCTAssertEqual(try XCTUnwrap(parse(stream)).duration, Double(opusHour + 96_000) / 48_000, accuracy: 1e-9)
        }
    }

    /// Whatever the reader cannot make sense of costs the offset only: it
    /// is 0, and the length is the old one, the last granule alone.
    func testEachVorbisFallbackGivesTheOldLength() throws {
        let good = [1, 0, 0].map { vorbisAudioPacket(mode: $0, of: 2) }
        let granule = vorbisHour + 1_280
        // A packet whose type bit is set is a header, not audio.
        let notAudio = [vorbisAudioPacket(mode: 1, of: 2), [0x01] + [UInt8](repeating: 0x55, count: 11),
                        vorbisAudioPacket(mode: 0, of: 2)]
        // An identification packet whose byte 28 (the block sizes) is changed.
        func identification(blockSizes: UInt8) -> [UInt8] { Array(Builder.vorbisID().prefix(28)) + [blockSizes, 1] }
        let badID = identification(blockSizes: 0x55)          // blocksize_0 = 2^5, below the minimum 2^6
        let inverted = identification(blockSizes: 0x8B)       // blocksize_0 = 2^11 above blocksize_1 = 2^8
        let zeroBits = [UInt8](repeating: 0, count: 90)
        let vorbisPrefix = [0x05] + Array("vorbis".utf8)
        // Three modes, so that mode number 3 (2 bits) is past the count.
        let threeModes = vorbisSetup(longBlocks: [false, true, false])
        let pastTheCount = good + [vorbisAudioPacket(mode: 3, of: 4)]
        // Mappings of 255 keep a smaller count from fitting by chance when the count field is wrong.
        let wrongCount = vorbisSetup(longBlocks: [false, true], mappings: [255, 255], countField: 5)

        /// A stream of one case: the identification, setup, and audio packets it changes.
        func stream(identification: [UInt8]? = nil, setup: [UInt8]? = nil, packets: [[UInt8]]? = nil) -> [UInt8] {
            leadStream(opus: false, identification: identification, setup: setup,
                       audio: [(packets ?? good, granule)], last: vorbisHour + 44_100)
        }
        let cases: [(name: String, stream: [UInt8])] = [
            ("a packet that is not audio", stream(packets: notAudio)),
            ("a mode number past the count", stream(setup: threeModes, packets: pastTheCount)),
            ("block sizes out of range", stream(identification: badID)),
            ("block sizes inverted", stream(identification: inverted)),
            ("a setup header of another kind", stream(setup: [0x01] + Array("vorbis".utf8) + [3, 4])),
            ("a setup header of no bits set", stream(setup: vorbisPrefix + zeroBits)),
            ("a setup header with no modes", stream(setup: vorbisPrefix + [1])),
            ("a wrong mode count field", stream(setup: wrongCount)),
            ("a mode with a window type", stream(setup: vorbisSetup(longBlocks: [false, true], windowType: 1))),
            ("no audio page after the setup header", leadStream(opus: false, audio: [], last: vorbisHour + 44_100)),
        ]
        for testCase in cases {
            XCTAssertEqual(offset(testCase.stream), 0, testCase.name)
            let header = try XCTUnwrap(parse(testCase.stream), testCase.name)
            XCTAssertEqual(header.duration, Double(vorbisHour + 44_100) / 22_050, accuracy: 1e-9, testCase.name)
        }
    }

    /// Pages that complete audio packets but never give a granule are read
    /// only so far: past the bound the offset is 0.
    func testPagesWithoutAGranuleAreReadOnlySoFar() {
        let packet = vorbisAudioPacket(mode: 0, of: 2)
        let withoutGranule: [AudioPage] = (0..<40).map { _ in ([packet, packet], Int64(-1)) }
        let late = withoutGranule + [([packet, packet], vorbisHour + 40_000)]
        XCTAssertEqual(offset(leadStream(opus: false, audio: late, last: vorbisHour + 44_100)), 0)
        // Within the bound the same run is counted: 8 pages of two short packets (15 x 128 = 1,920 samples).
        let near: [AudioPage] = (0..<7).map { _ in ([packet, packet], Int64(-1)) } + [([packet, packet], vorbisHour + 1_920)]
        XCTAssertEqual(offset(leadStream(opus: false, audio: near, last: vorbisHour + 44_100)), vorbisHour)
    }

    /// An offset past the last granule contradicts the file and is ignored.
    func testAnOffsetPastTheLastGranuleIsIgnored() throws {
        let packets = [1, 0, 0].map { vorbisAudioPacket(mode: $0, of: 2) }
        // Long, short, short: 576 + 128 = 704 samples after the first packet.
        let stream = leadStream(opus: false, audio: [(packets, vorbisHour + 704)], last: 44_100)
        XCTAssertEqual(offset(stream), vorbisHour)
        XCTAssertEqual(try XCTUnwrap(parse(stream)).duration, 2.0, accuracy: 1e-9)
    }

    /// A first audio page that does not lie wholly inside `head` costs the
    /// offset only; a setup header cut off by the end of `head` the same,
    /// with the tags and the header kept.
    func testAnAudioPageOrSetupHeaderBeyondTheHeadCostsOnlyTheOffset() throws {
        let packets = [1, 0, 0].map { vorbisAudioPacket(mode: $0, of: 2) }
        let stream = leadStream(opus: false, audio: [(packets, vorbisHour + 1_280)], last: vorbisHour + 44_100)
        let endPageLength = 27 + 1 + 10
        let audioStart = leadStream(opus: false, audio: [], last: 0).count - endPageLength
        let cutInAudio = Array(stream[0..<(audioStart + 5)])
        let header = try XCTUnwrap(OggHeaderReader.parse(head: cutInAudio, tail: stream))
        XCTAssertEqual(OggHeaderReader.streamStartOffset(inHead: cutInAudio), 0)
        XCTAssertEqual(header.tags.title, "Cut")
        XCTAssertEqual(header.duration, Double(vorbisHour + 44_100) / 22_050, accuracy: 1e-9)

        // A setup header of 1,000 bytes on pages of 510, cut inside its second page.
        let long = leadStream(opus: false, setup: vorbisSetup(longBlocks: [false, true], filler: [UInt8](repeating: 3, count: 1_000)),
                              setupPerPage: 255 * 2, audio: [(packets, vorbisHour + 1_280)], last: vorbisHour + 44_100)
        let setupStart = leadStream(opus: false, audio: [], last: 0).count - endPageLength
            - Builder.pages(carrying: vorbisSetup(longBlocks: [false, true]), firstSequence: 0).flatMap { $0 }.count
        let cutInSetup = Array(long[0..<(setupStart + 700)])
        let partial = try XCTUnwrap(OggHeaderReader.parse(head: cutInSetup, tail: long))
        XCTAssertEqual(OggHeaderReader.streamStartOffset(inHead: cutInSetup), 0)
        XCTAssertEqual(partial.tags.title, "Cut")
    }

    /// Randomly made headers, packets, and granules, in pages with valid
    /// CRCs so that the new paths are reached, never trap and never give a
    /// nonsensical length.
    func testRandomHeadersAndPacketsNeverTrap() {
        var generator = OggFuzzGenerator(seed: 20_261_017)
        let granules: [Int64] = [-1, 0, 1, 960, 1_234_567, Int64.max, Int64.min, Int64.max - 1]
        for round in 0..<400 {
            let opus = round % 2 == 0
            // A setup header that is valid, valid with changed bytes, or random.
            var setup = vorbisSetup(longBlocks: (0..<Int.random(in: 1...64, using: &generator)).map { _ in Bool.random(using: &generator) },
                                    filler: (0..<Int.random(in: 0...40, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                break
            case 1:
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    setup[Int.random(in: 0..<setup.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
            default:
                setup = [0x05] + Array("vorbis".utf8) + (0..<Int.random(in: 0...120, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            }
            var identification = opus ? Builder.opusHead() : Builder.vorbisID()
            if !opus && Bool.random(using: &generator) { identification[28] = UInt8.random(in: 0...255, using: &generator) }

            // One to three audio pages of random packets (up to 200 bytes: 255 would continue the packet).
            let pages: [AudioPage] = (0..<Int.random(in: 1...3, using: &generator)).map { _ in
                let packets = (0..<Int.random(in: 0...6, using: &generator)).map { _ in
                    (0..<Int.random(in: 0...200, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
                }
                return (packets, granules.randomElement(using: &generator) ?? 0)
            }
            let stream = leadStream(opus: opus, identification: identification, setup: setup, audio: pages,
                                    last: granules.randomElement(using: &generator) ?? 0)
            XCTAssertGreaterThanOrEqual(offset(stream), 0)
            if let header = parse(stream) {
                XCTAssertTrue(header.duration.isFinite && header.duration > 0
                                && header.duration <= OggHeaderReader.maximumDuration, "round \(round)")
            }
        }
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

// MARK: - Metadata readers

/// An Ogg file's tags and length reach the metadata readers through
/// `OggHeaderReader`, never through AVFoundation.
final class OggMetadataReadersTests: XCTestCase {
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

    /// Writes `bytes` to `name` in the test's folder and returns its URL.
    private func write(_ bytes: [UInt8], as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testAnOggFileGivesItsTagsAndDuration() async throws {
        let comments = ["TITLE=Chapter One", "ARTIST=A. Reader", "ALBUM=The Book", "GENRE=Audiobook", "DATE=2019"]
        let url = try write(Builder.vorbisStream(comments: comments), as: "book.ogg")
        let metadata = await AudioPlaybackService.extractFullMetadata(from: url)
        XCTAssertEqual(metadata.title, "Chapter One")
        XCTAssertEqual(metadata.artist, "A. Reader")
        XCTAssertEqual(metadata.album, "The Book")
        XCTAssertEqual(metadata.genre, "Audiobook")
        XCTAssertEqual(metadata.year, "2019")
        XCTAssertEqual(metadata.duration, "0:02")
        XCTAssertEqual(metadata.fileFormat, "OGG")
        let seconds = await AudioPlaybackService.getDuration(of: url)
        XCTAssertEqual(try XCTUnwrap(seconds), 2.0, accuracy: 0.0001)
    }

    func testAnOpusFileGivesItsTagsAndDuration() async throws {
        // 62 minutes 3 seconds, after the pre-skip.
        let granule = Int64(3_723 * 48_000 + 312)
        let url = try write(Builder.opusStream(granule: granule, comments: ["TITLE=Long", "PERFORMER=Voice"]),
                            as: "long.opus")
        let metadata = await AudioPlaybackService.extractFullMetadata(from: url)
        XCTAssertEqual(metadata.title, "Long")
        XCTAssertEqual(metadata.artist, "Voice")
        XCTAssertEqual(metadata.duration, "1:02:03")
        XCTAssertEqual(metadata.fileFormat, "OPUS")
        let seconds = await AudioPlaybackService.getDuration(of: url)
        XCTAssertEqual(try XCTUnwrap(seconds), 3_723, accuracy: 0.0001)
    }

    func testTheQuickTitleAndArtistReadComeFromTheSameTags() async throws {
        let url = try write(Builder.vorbisStream(comments: ["TITLE=Quick", "ARTIST=Reader"]), as: "q.oga")
        let quick = await AudioPlaybackService.extractMetadata(from: url)
        XCTAssertEqual(quick.title, "Quick")
        XCTAssertEqual(quick.artist, "Reader")
    }

    func testAnOggFileHasNoChapters() async throws {
        let url = try write(Builder.vorbisStream(comments: ["TITLE=No Chapters"]), as: "c.ogg")
        let chapters = await AudioPlaybackService.extractChapters(from: url)
        XCTAssertTrue(chapters.isEmpty)
    }

    /// A file named `.ogg` that is not Ogg gives empty values, not an error.
    func testAFileNamedOggThatIsNotOggGivesEmptyValues() async throws {
        let url = try write(Array("definitely not Ogg".utf8), as: "fake.ogg")
        let metadata = await AudioPlaybackService.extractFullMetadata(from: url)
        XCTAssertEqual(metadata.title, "")
        XCTAssertEqual(metadata.artist, "")
        XCTAssertEqual(metadata.duration, "")
        let seconds = await AudioPlaybackService.getDuration(of: url)
        XCTAssertNil(seconds)
    }

    /// The `h:mm:ss` and `m:ss` strings are those the other formats show.
    func testTheDurationStringIsFormattedLikeOtherFormats() async throws {
        let short = try write(Builder.vorbisStream(granule: 22_050 * 59), as: "short.ogg")
        let shortMetadata = await AudioPlaybackService.extractFullMetadata(from: short)
        XCTAssertEqual(shortMetadata.duration, "0:59")
        let long = try write(Builder.vorbisStream(granule: 22_050 * 600), as: "ten.ogg")
        let longMetadata = await AudioPlaybackService.extractFullMetadata(from: long)
        XCTAssertEqual(longMetadata.duration, "10:00")
    }
}

// MARK: - Ogg FLAC streams

/// Builds the packets of an Ogg FLAC stream (xiph.org/flac/ogg_mapping.html).
extension OggStreamBuilder {
    /// An Ogg FLAC identification packet: 0x7F "FLAC", the mapping's version,
    /// the count of header packets after it, "fLaC", the STREAMINFO block
    /// header, and STREAMINFO with its rate, channels, bits and total samples
    /// packed as the format has them (20, 3, 5, then 36 bits).
    static func flacID(rate: UInt32 = 22_050, channels: Int = 1, bits: Int = 16,
                       totalSamples: UInt64 = 88_200, major: UInt8 = 1, headerCount: UInt16 = 1,
                       magic: String = "fLaC", blockType: UInt8 = 0, blockLength: UInt8 = 34) -> [UInt8] {
        var bytes: [UInt8] = [0x7F] + Array("FLAC".utf8) + [major, 0]
        bytes += [UInt8(headerCount >> 8), UInt8(headerCount & 0xFF)] + Array(magic.utf8)
        bytes += [blockType, 0, 0, blockLength]
        // STREAMINFO: block sizes (2 x 16 bits) and frame sizes (2 x 24 bits), all unknown (0).
        bytes += [UInt8](repeating: 0, count: 10)
        // Then the packed word (rate, channels less one, bits less one, total samples) and the MD5.
        let packed = (UInt64(rate) << 44) | (UInt64(channels - 1) << 41) | (UInt64(bits - 1) << 36) | totalSamples
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: packed >> (8 * UInt64(7 - $0))) }
        bytes += [UInt8](repeating: 0, count: 16)
        return bytes
    }

    /// A FLAC metadata block as a header packet: its type (the high bit
    /// marks the last block), a 24-bit big-endian length (`declaredLength`
    /// when a test needs it to lie), and `body`.
    static func flacBlock(type: UInt8, last: Bool, body: [UInt8], declaredLength: Int? = nil) -> [UInt8] {
        let length = declaredLength ?? body.count
        return [type | (last ? 0x80 : 0), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF),
                UInt8(length & 0xFF)] + body
    }

    /// A VORBIS_COMMENT block (type 4): a Vorbis comment with no signature or framing bit.
    static func flacComments(_ comments: [String], last: Bool = true, declaredLength: Int? = nil) -> [UInt8] {
        flacBlock(type: 4, last: last, body: commentPacket(signature: [], comments: comments.map { Array($0.utf8) }),
                  declaredLength: declaredLength)
    }

    /// A whole Ogg FLAC stream: the identification page, one packet's pages
    /// for each of `headers` (by default one comment block carrying
    /// `comments`), an audio page, and a last page ending at `granule`.
    static func flacStream(id: [UInt8] = flacID(), headers: [[UInt8]]? = nil, granule: Int64 = 88_200,
                           comments: [String] = [], serial: UInt32 = 1) -> [UInt8] {
        var pages = [page(type: 0x02, granule: 0, serial: serial, sequence: 0, lacing: [UInt8(id.count)], payload: id)]
        for packet in headers ?? [flacComments(comments)] {
            pages += self.pages(carrying: packet, serial: serial, firstSequence: UInt32(pages.count))
        }
        pages += audioPages(serial: serial, firstSequence: UInt32(pages.count), granule: granule)
        return pages.flatMap { $0 }
    }
}

extension OggHeaderReaderTests {
    func testAnOggFlacStreamGivesItsFormatDurationAndTags() throws {
        let stream = Builder.flacStream(comments: ["TITLE=Three Tones", "ARTIST=A Test Rig"])
        let header = try XCTUnwrap(parse(stream))
        XCTAssertEqual(header.codec, .flac)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.sampleRate, 22_050)
        XCTAssertEqual(header.bitsPerSample, 16)
        XCTAssertEqual(header.duration, 4.0, accuracy: 0.0001)
        XCTAssertEqual(header.tags.title, "Three Tones")
        XCTAssertEqual(header.tags.artist, "A Test Rig")
    }

    func testVorbisAndOpusStreamsHaveNoBitsPerSample() throws {
        XCTAssertNil(try XCTUnwrap(parse(Builder.vorbisStream())).bitsPerSample)
        XCTAssertNil(try XCTUnwrap(parse(Builder.opusStream())).bitsPerSample)
    }

    /// The widest values each packed STREAMINFO field holds read back whole.
    func testStreamInfoFieldsAtTheirLimitsReadBackWhole() throws {
        let id = Builder.flacID(rate: 1_048_575, channels: 8, bits: 32, totalSamples: 0)
        let header = try XCTUnwrap(parse(Builder.flacStream(id: id, granule: 2_097_150)))
        XCTAssertEqual(header.sampleRate, 1_048_575)
        XCTAssertEqual(header.channels, 8)
        XCTAssertEqual(header.bitsPerSample, 32)
        XCTAssertEqual(header.duration, 2.0, accuracy: 0.0001)
        // The smallest depth, with total samples (needing 36 bits' low end) agreeing with the granule.
        let narrow = Builder.flacID(rate: 44_100, channels: 2, bits: 4, totalSamples: 44_100 * 100)
        let small = try XCTUnwrap(parse(Builder.flacStream(id: narrow, granule: 44_100 * 100)))
        XCTAssertEqual(small.bitsPerSample, 4)
        XCTAssertEqual(small.channels, 2)
    }

    func testAnUnknownTotalOfSamplesLeavesTheGranuleAlone() throws {
        let id = Builder.flacID(totalSamples: 0)
        XCTAssertEqual(try XCTUnwrap(parse(Builder.flacStream(id: id))).duration, 4.0, accuracy: 0.0001)
    }

    func testTotalSamplesWithinASecondOfTheGranuleAreBelieved() throws {
        // 0.9 seconds more than the granule says (19,845 samples at 22,050 Hz).
        let id = Builder.flacID(totalSamples: 88_200 + 19_845)
        let header = try XCTUnwrap(parse(Builder.flacStream(id: id)))
        XCTAssertEqual(header.duration, 4.0, accuracy: 0.0001)
    }

    // MARK: Refusals

    func testAnOggFlacStreamContradictingItselfIsRefused() {
        // Two seconds more, and two seconds fewer, than the granule says.
        for total: UInt64 in [88_200 + 44_100, 44_100] {
            XCTAssertNil(parse(Builder.flacStream(id: Builder.flacID(totalSamples: total))), "total \(total)")
        }
    }

    func testAnOggFlacIdentificationThatIsNotFlacIsRefused() {
        let bad: [(String, [UInt8])] = [
            ("major version 2", Builder.flacID(major: 2)),
            ("major version 0", Builder.flacID(major: 0)),
            ("no fLaC", Builder.flacID(magic: "fLaX")),
            ("a PADDING block first", Builder.flacID(blockType: 1)),
            ("a STREAMINFO of 33 bytes", Builder.flacID(blockLength: 33)),
            ("a sample rate of 0", Builder.flacID(rate: 0)),
            ("a STREAMINFO cut short", Array(Builder.flacID().prefix(50))),
        ]
        for (name, id) in bad {
            XCTAssertNil(parse(Builder.flacStream(id: id)), name)
        }
    }

    // MARK: Header packets

    func testAHeaderCountOfZeroEndsAtTheBlockMarkedLast() throws {
        // The comment block is the last header packet; the stream does not count them.
        let id = Builder.flacID(headerCount: 0)
        let stream = Builder.flacStream(id: id, comments: ["TITLE=Counted by the last flag"])
        XCTAssertEqual(try XCTUnwrap(parse(stream)).tags.title, "Counted by the last flag")
    }

    func testBlocksBeforeAndAfterTheCommentsArePassedOver() throws {
        // A SEEKTABLE (type 3), the comments (not last), then PADDING (type 1, last).
        let headers = [Builder.flacBlock(type: 3, last: false, body: [UInt8](repeating: 0, count: 18)),
                       Builder.flacComments(["ARTIST=Between Blocks"], last: false),
                       Builder.flacBlock(type: 1, last: true, body: [UInt8](repeating: 0, count: 40))]
        for count: UInt16 in [3, 0] {
            let stream = Builder.flacStream(id: Builder.flacID(headerCount: count), headers: headers)
            XCTAssertEqual(try XCTUnwrap(parse(stream)).tags.artist, "Between Blocks", "count \(count)")
        }
    }

    func testAStreamWithNoCommentBlockHasEmptyTags() throws {
        // STREAMINFO alone: no header packets follow, and the first audio packet is not a comment block.
        let id = Builder.flacID(headerCount: 0)
        let stream = Builder.flacStream(id: id, headers: [])
        XCTAssertEqual(try XCTUnwrap(parse(stream)).tags, OggHeaderReader.Tags())
    }

    func testACommentBlockLongerThanItsPacketGivesEmptyTags() throws {
        // The block declares 1,000 bytes more than the packet holds.
        let honest = Builder.flacComments(["TITLE=Cut Short"])
        let lying = Builder.flacComments(["TITLE=Cut Short"], declaredLength: honest.count - 4 + 1_000)
        let header = try XCTUnwrap(parse(Builder.flacStream(headers: [lying])))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags())
        // The stream's facts do not depend on its tags.
        XCTAssertEqual(header.duration, 4.0, accuracy: 0.0001)
    }

    func testOggFlacCutAnywhereNeverTraps() {
        let stream = Builder.flacStream(comments: ["TITLE=Cut"])
        for length in stride(from: 0, through: stream.count, by: 7) {
            _ = OggHeaderReader.parse(head: Array(stream[0..<length]), tail: stream)
        }
    }
}
