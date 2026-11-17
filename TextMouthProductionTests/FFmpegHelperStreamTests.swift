import XCTest
@testable import TextMouth

/// The reading of the FFmpeg session's stream (FMT50, `FFmpegHelperStream`)
/// and what it reports (`FFmpegReport`), from streams written by hand
/// (`FFmpegTestStream`): the records in their order, the samples of each form,
/// and every way a stream can break the protocol, each refused by name, so a
/// helper that writes nonsense costs a failed import, never the app.
final class FFmpegHelperStreamTests: XCTestCase {
    /// The report and the blocks of `bytes`, read through pieces of
    /// `pieceSize` bytes.
    private func readAll(_ bytes: [UInt8], pieceSize: Int = .max) async throws -> (FFmpegReport, [[Int32]], FFmpegHelperStream) {
        var offset = 0
        var stream = FFmpegHelperStream {
            let end = min(bytes.count, offset + min(pieceSize, bytes.count))
            defer { offset = end }
            return Array(bytes[offset..<end])
        }
        let report = try await stream.readReport()
        var blocks: [[Int32]] = []
        while let block = try await stream.nextBlock() {
            blocks.append(block)
        }
        return (report, blocks, stream)
    }

    /// The error reading all of `bytes` ends in.
    private func failure(of bytes: [UInt8]) async -> FFmpegHelperStream.StreamError? {
        do {
            _ = try await readAll(bytes)
            return nil
        } catch {
            return error as? FFmpegHelperStream.StreamError
        }
    }

    /// A decode's stream: two mono 16-bit blocks, with the file's tags, a
    /// stream tag, and two chapters.
    private var decodeStream: [UInt8] {
        let info = FFmpegTestStream.replacing("sample_format", with: "s16", in:
            FFmpegTestStream.replacing("bits", with: "16", in: FFmpegTestStream.wmaInfo))
        return FFmpegTestStream.head() + FFmpegTestStream.info(info)
            + FFmpegTestStream.tag("TITLE", "Three Tones") + FFmpegTestStream.tag("artist", "TextMouth Test")
            + FFmpegTestStream.tag("language", "eng", stream: true)
            + FFmpegTestStream.chapter(start: 0, end: 1.5, title: "Tone 440 Hz")
            + FFmpegTestStream.chapter(start: 1.5, title: "Tone 880 Hz (café)")
            + FFmpegTestStream.pcm16([1, -2, 3]) + FFmpegTestStream.pcm16([-32_768, 32_767])
            + FFmpegTestStream.end(frames: 5, refusedPackets: 2, refusedFrames: 1)
    }

    // MARK: - A Whole Stream

    /// A whole stream gives its report, then its blocks in order, then the
    /// end, with what END counted, the samples widened with their signs.
    func testAWholeStreamIsRead() async throws {
        let (report, blocks, stream) = try await readAll(decodeStream)

        XCTAssertEqual(report.formatName, "asf")
        XCTAssertEqual(report.codecName, "wmav1")
        XCTAssertEqual(report.sampleRate, 22_050)
        XCTAssertEqual(report.channels, 1)
        XCTAssertEqual(report.channelMask, 4)
        XCTAssertEqual(report.sampleFormat, .s16)
        XCTAssertEqual(report.duration, 3.999)
        XCTAssertEqual(report.tags, ["title": "Three Tones", "artist": "TextMouth Test"])
        XCTAssertEqual(report.streamTags, ["language": "eng"])
        XCTAssertEqual(report.chapters, [
            FFmpegReport.Chapter(start: 0, end: 1.5, title: "Tone 440 Hz"),
            FFmpegReport.Chapter(start: 1.5, end: nil, title: "Tone 880 Hz (café)"),
        ])
        XCTAssertEqual(blocks, [[1, -2, 3], [-32_768, 32_767]])
        XCTAssertTrue(stream.isFinished)
        XCTAssertEqual(stream.framesRead, 5)
        XCTAssertEqual([stream.refusedPackets, stream.refusedFrames], [2, 1])
    }

    /// The records are the same whatever pieces the bytes come in: one byte
    /// at a time, seven, or all at once (a pipe gives what it holds).
    func testPiecesOfAnySizeGiveTheSameStream() async throws {
        let (wholeReport, wholeBlocks, _) = try await readAll(decodeStream)
        for size in [1, 7, 4_096] {
            let (report, blocks, _) = try await readAll(decodeStream, pieceSize: size)
            XCTAssertEqual(report, wholeReport, "pieces of \(size)")
            XCTAssertEqual(blocks, wholeBlocks, "pieces of \(size)")
        }
    }

    /// A probe's stream has no samples: its first block is the end.
    func testAProbeEndsWithNoSamples() async throws {
        var stream = FFmpegHelperStream(data: Data(FFmpegTestStream.probe()))
        let report = try await stream.readReport()
        XCTAssertEqual(report.tags["album"], "Harbour Recordings")
        let block = try await stream.nextBlock()
        XCTAssertNil(block)
        XCTAssertTrue(stream.isFinished)
    }

    /// 32-bit whole numbers come as they are, and floats as their bit
    /// patterns, which the writer turns into whole numbers itself.
    func testThirtyTwoBitSamplesAndFloatsComeAsTheyAre() async throws {
        let floats = FFmpegTestStream.replacing("channels", with: "2", in: FFmpegTestStream.wmaInfo)
        let half = Float(0.5).bitPattern
        let stream = FFmpegTestStream.head() + FFmpegTestStream.info(floats)
            + FFmpegTestStream.pcm32([half, UInt32(bitPattern: Int32(-1))]) + FFmpegTestStream.end(frames: 1)
        let (_, blocks, _) = try await readAll(stream)
        XCTAssertEqual(blocks, [[Int32(bitPattern: half), -1]])
        let wide = FFmpegTestStream.replacing("sample_format", with: "s32", in:
            FFmpegTestStream.replacing("bits", with: "24", in: FFmpegTestStream.wmaInfo))
        let (report, wideBlocks, _) = try await readAll(FFmpegTestStream.head() + FFmpegTestStream.info(wide)
            + FFmpegTestStream.pcm32([UInt32(bitPattern: Int32(-8_388_608)), 8_388_607]) + FFmpegTestStream.end(frames: 2))
        XCTAssertEqual(report.bitsPerSample, 24)
        XCTAssertEqual(wideBlocks, [[-8_388_608, 8_388_607]])
    }

    // MARK: - The Largest PCM Record

    /// A stream of one mono 32-bit float PCM record of `samples` samples.
    private func streamOfOnePCMRecord(samples: Int) -> [UInt8] {
        FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
            + FFmpegTestStream.pcm32([UInt32](repeating: 0, count: samples)) + FFmpegTestStream.end(frames: UInt64(samples))
    }

    /// A PCM record of exactly the protocol's 1 MB (1,048,576 bytes, 262,144
    /// samples of 32 bits) is read whole, and one of a frame more is refused
    /// as damaged (FU-FFMPEG2): the limit is the protocol's, a record the
    /// session never writes longer, so a helper that does is not believed, and
    /// a made-up stream shows it with no helper. The refusal comes before the
    /// record's bytes are gathered: only its header is in the stream.
    func testAPCMRecordOverAMegabyteIsRefusedAsDamaged() async throws {
        let (_, blocks, stream) = try await readAll(streamOfOnePCMRecord(samples: 262_144))
        XCTAssertEqual(blocks.map(\.count), [262_144])
        XCTAssertEqual(stream.framesRead, 262_144)
        let tooLong = await failure(of: streamOfOnePCMRecord(samples: 262_145))
        XCTAssertEqual(tooLong, .damaged)
        // Only the header says the length: the reader refuses it without waiting for its bytes.
        let headerOnly = FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
            + Array("PCM ".utf8) + FFmpegTestStream.littleEndian(UInt32(1_048_580))
        let refusedAtOnce = await failure(of: headerOnly)
        XCTAssertEqual(refusedAtOnce, .damaged)
        // A record of another kind is held to the 64 KB of the others, not the PCM limit.
        let longTag = FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
            + Array("TAG ".utf8) + FFmpegTestStream.littleEndian(UInt32(65_537))
        let tagRefused = await failure(of: longTag)
        XCTAssertEqual(tagRefused, .damaged)
    }

    // MARK: - Broken Streams

    /// A stream of another protocol's version, or one that does not begin
    /// with HEAD, is refused as another protocol's: a helper built from other
    /// sources fails by name, never by misreading.
    func testAStreamOfAnotherVersionIsRefused() async {
        let rest = FFmpegTestStream.info(FFmpegTestStream.wmaInfo) + FFmpegTestStream.end(frames: 0)
        let wrongVersion = await failure(of: FFmpegTestStream.head(version: 2) + rest)
        XCTAssertEqual(wrongVersion, .otherProtocol)
        let noHead = await failure(of: rest)
        XCTAssertEqual(noHead, .otherProtocol)
    }

    /// Every way a stream breaks the protocol is refused as damaged: a
    /// record longer than its kind allows, a kind the protocol has not, a
    /// sample before INFO, samples that are not whole frames, a PCM record with
    /// no samples (the session never writes one), an END that
    /// counts other frames than came, a tag with no key's end, a chapter too
    /// short for its times, and more tags than the session writes.
    func testDamagedStreamsAreRefused() async {
        let head = FFmpegTestStream.head()
        let info = FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
        let stereo16 = FFmpegTestStream.info(FFmpegTestStream.replacing("channels", with: "2", in:
            FFmpegTestStream.replacing("sample_format", with: "s16", in: FFmpegTestStream.wmaInfo)))
        let oversize = Array("TAG ".utf8) + FFmpegTestStream.littleEndian(UInt32(70_000)) + [UInt8](repeating: 0, count: 70_000)
        let manyTags = (0...512).flatMap { FFmpegTestStream.tag("key\($0)", "value") }
        let cases: [(String, [UInt8])] = [
            ("a record past its limit", head + info + oversize + FFmpegTestStream.end(frames: 0)),
            ("an unknown kind", head + info + FFmpegTestStream.record("XYZW", []) + FFmpegTestStream.end(frames: 0)),
            ("samples before INFO", head + FFmpegTestStream.pcm16([1]) + info + FFmpegTestStream.end(frames: 1)),
            ("half a frame", head + stereo16 + FFmpegTestStream.pcm16([1, 2, 3]) + FFmpegTestStream.end(frames: 1)),
            ("an empty PCM record", head + info + FFmpegTestStream.pcm32([]) + FFmpegTestStream.end(frames: 0)),
            ("an empty PCM record between two", head + info + FFmpegTestStream.pcm32([7]) + FFmpegTestStream.pcm32([])
                + FFmpegTestStream.pcm32([8]) + FFmpegTestStream.end(frames: 2)),
            ("an END that counts wrong", head + info + FFmpegTestStream.pcm32([0, 0]) + FFmpegTestStream.end(frames: 3)),
            ("a tag with no end to its key", head + info + FFmpegTestStream.record("TAG ", Array("title".utf8)) + FFmpegTestStream.end(frames: 0)),
            ("a chapter too short", head + info + FFmpegTestStream.record("CHAP", [0, 0, 0]) + FFmpegTestStream.end(frames: 0)),
            ("a tag past the session's most", head + info + FFmpegTestStream.tag("title", String(repeating: "a", count: 5_000))
                + FFmpegTestStream.end(frames: 0)),
            ("a chapter title past the session's most", head + info
                + FFmpegTestStream.chapter(start: 0, title: String(repeating: "a", count: 5_000)) + FFmpegTestStream.end(frames: 0)),
            ("more tags than the session writes", head + info + manyTags + FFmpegTestStream.end(frames: 0)),
            ("an INFO that names no codec", head + FFmpegTestStream.info([("sample_rate", "8000"), ("channels", "1")]) + FFmpegTestStream.end(frames: 0)),
            ("a second INFO", head + info + info + FFmpegTestStream.end(frames: 0)),
        ]
        for (name, bytes) in cases {
            let found = await failure(of: bytes)
            XCTAssertEqual(found, .damaged, name)
        }
    }

    /// A stream cut short, inside a record or before END, ended early.
    func testAStreamCutShortEndedEarly() async {
        let whole = decodeStream
        for cut in [0, 5, 30, whole.count - 20, whole.count - 1] {
            let found = await failure(of: Array(whole.prefix(cut)))
            // Cut before the first record, nothing at all was written: that is no
            // stream, which the run's ending explains (an exit status), so it
            // too reads as ended early.
            XCTAssertEqual(found, .endedEarly, "cut at \(cut)")
        }
    }

    // MARK: - What the Report Believes

    /// Numbers a header can lie about are believed only when plausible: no
    /// rate above 768 kHz or of nothing, no channels past 64 or none, no
    /// length past a year or of nothing, no bit rate past 100 Mbit/s.
    func testOnlyPlausibleNumbersAreBelieved() throws {
        let lying = [
            ("sample_rate", "900000"), ("channels", "65"), ("duration", "999999999"),
            ("format_duration", "-1"), ("bit_rate", "200000000"), ("format_bit_rate", "0"),
        ].reduce(FFmpegTestStream.wmaInfo) { FFmpegTestStream.replacing($1.0, with: $1.1, in: $0) }
        let report = try XCTUnwrap(FFmpegReport(info: Dictionary(uniqueKeysWithValues: lying), fileTags: [], streamTags: [], chapters: []))
        XCTAssertNil(report.sampleRate)
        XCTAssertNil(report.channels)
        XCTAssertNil(report.duration)
        XCTAssertNil(report.bitRate)
        XCTAssertFalse(report.isUsableSound)
        XCTAssertNil(FFmpegReport(info: ["codec": "opus"], fileTags: [], streamTags: [], chapters: []))
    }

    /// Matroska says a stream's length and bit rate in mkvmerge's tags
    /// (DURATION, BPS, or with "-eng" after them), which stand in for the
    /// stream's own numbers; a file of sound alone shares its bit rate among
    /// its sound streams, and one with pictures has none of its own.
    func testMatroskaTagsAndTheFilesBitRate() throws {
        let bare = FFmpegTestStream.wmaInfo.filter { !["duration", "format_duration", "bit_rate"].contains($0.0) }
        let tagged = try XCTUnwrap(FFmpegReport(
            info: Dictionary(uniqueKeysWithValues: bare), fileTags: [],
            streamTags: [("DURATION-eng", "00:01:02.500000000"), ("BPS", "96000")], chapters: []))
        XCTAssertEqual(tagged.duration, 62.5)
        XCTAssertEqual(tagged.bitRate, 96_000)
        XCTAssertEqual(FFmpegReport.matroskaDuration("01:02:03.5"), 3_723.5)
        for text in ["", "3.5", "a:b:c", "-1:00:00"] {
            XCTAssertNil(FFmpegReport.matroskaDuration(text), text)
        }
        let shared = FFmpegTestStream.replacing("audio_streams", with: "2", in: bare)
        let twoTracks = try XCTUnwrap(FFmpegReport(info: Dictionary(uniqueKeysWithValues: shared), fileTags: [], streamTags: [], chapters: []))
        XCTAssertEqual(twoTracks.bitRate, 20_129)
        let video = FFmpegTestStream.replacing("more_than_sound", with: "1", in: bare)
        let withPictures = try XCTUnwrap(FFmpegReport(info: Dictionary(uniqueKeysWithValues: video), fileTags: [], streamTags: [], chapters: []))
        XCTAssertNil(withPictures.bitRate)
    }

    /// Tags are kept by their keys in lowercase, the first in key order of
    /// two that differ only in case; a value is cut at 4 KB, never inside a
    /// character; and a value that is empty, or holds U+FFFD (text that was
    /// not UTF-8), is missing (the TODO's FU-FFMPEG items).
    func testTagsAreLowercasedCutAndNoiseIsMissing() {
        let long = String(repeating: "é", count: 3_000)
        let tags = FFmpegReport.tags(from: [
            ("Title", "First"), ("TITLE", "Second"), ("artist", "Bad \u{FFFD} bytes"), ("album", ""), ("comment", long),
        ])
        XCTAssertEqual(tags["title"], "Second")
        XCTAssertNil(tags["artist"])
        XCTAssertNil(tags["album"])
        XCTAssertEqual(tags["comment"]?.utf8.count, 4_096)
        XCTAssertEqual(tags["comment"], String(repeating: "é", count: 2_048))
        XCTAssertEqual(FFmpegReport.cut("abc", toBytes: 2), "ab")
        XCTAssertEqual(FFmpegReport.cut("aé", toBytes: 2), "a")
    }

    /// A book takes the file's own tags; in Ogg alone a stream's fill the
    /// gaps (a Speex file's title is on its stream), while a Matroska
    /// track's name is no title. The artist is the artist, else the author
    /// (RealMedia's), else the album's artist; the date, else the year.
    func testTheTagsABookTakes() throws {
        func report(tags: [(String, String)], streamTags: [(String, String)]) throws -> FFmpegReport {
            try XCTUnwrap(FFmpegReport(info: Dictionary(uniqueKeysWithValues: FFmpegTestStream.wmaInfo),
                                       fileTags: tags, streamTags: streamTags, chapters: []))
        }
        let speex = try report(tags: [("artist", "A Speaker")], streamTags: [("title", "Field Notes"), ("artist", "Another")])
        XCTAssertEqual(speex.bookTags(in: .oggSpeex).title, "Field Notes")
        XCTAssertEqual(speex.bookTags(in: .oggSpeex).artist, "A Speaker")
        XCTAssertEqual(speex.bookTags(in: .matroska).title, "")
        XCTAssertTrue(FFmpegReport.streamTagsAreTheFiles(in: .ogg))
        XCTAssertEqual(FFmpegContainer.allCases.filter { FFmpegReport.streamTagsAreTheFiles(in: $0) }, [.oggSpeex, .ogg])
        let realMedia = try report(tags: [("title", "Talk"), ("author", "Only Author"), ("album_artist", "An Album's Artist"), ("year", "1999")],
                                   streamTags: [])
        let book = realMedia.bookTags(in: .realMedia)
        XCTAssertEqual([book.title, book.artist, book.date], ["Talk", "Only Author", "1999"])
        let albumOnly = try report(tags: [("album_artist", "An Album's Artist"), ("date", "2001"), ("year", "1999")], streamTags: [])
        XCTAssertEqual([albumOnly.bookTags(in: .asf).artist, albumOnly.bookTags(in: .asf).date], ["An Album's Artist", "2001"])
    }

    /// A chapter's title of noise is no title, and the marks a conversion
    /// keeps are the chapters with a start from zero on, in order.
    func testTheChaptersAConversionKeeps() async throws {
        let stream = FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
            + FFmpegTestStream.chapter(start: 2, title: "Second") + FFmpegTestStream.chapter(start: -1, title: "Before")
            + FFmpegTestStream.chapter(start: 0, title: "Bad \u{FFFD}") + FFmpegTestStream.end(frames: 0)
        let (report, _, _) = try await readAll(stream)
        XCTAssertEqual(report.chapterMarks, [
            NeroChapterReader.Chapter(title: "", start: 0), NeroChapterReader.Chapter(title: "Second", start: 2),
        ])
    }
}
