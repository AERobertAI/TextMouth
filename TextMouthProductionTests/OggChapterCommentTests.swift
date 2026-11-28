import XCTest
@testable import TextMouth

/// An Ogg file's CHAPTERnnn comments read as its chapters by TextMouth's own
/// header reader (FMT17, `OggHeaderReader.chapters(in:)`), in Vorbis and Opus
/// streams built here, and handed to the import's converter with the
/// source's facts (`ImportAudioConverter.inspect`). No Ogg file is decoded,
/// and none reaches an Apple audio API.
final class OggChapterCommentTests: XCTestCase {
    private typealias Builder = OggStreamBuilder

    /// A Vorbis stream and an Opus stream with the same chapter comments give
    /// the same chapters: each start paired with the name of its number, in
    /// the numbers' order, a start with no name keeping an empty title and a
    /// name with no start naming nothing.
    func testChapterCommentsAreTheStreamsChapters() throws {
        let comments = [
            "CHAPTER002NAME=Storm", "CHAPTER001=00:00:00.000", "CHAPTER001NAME=Prologue",
            "CHAPTER002=00:01:30.500", "chapter3=1:02:03.25", "CHAPTER004NAME=Nameless", "TITLE=Tides",
        ]
        let expected = [
            NeroChapterReader.Chapter(title: "Prologue", start: 0),
            NeroChapterReader.Chapter(title: "Storm", start: 90.5),
            NeroChapterReader.Chapter(title: "", start: 3_723.25),
        ]
        for stream in [Builder.vorbisStream(comments: comments), Builder.opusStream(comments: comments)] {
            let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
            XCTAssertEqual(header.tags.chapters, expected)
            XCTAssertEqual(header.tags.title, "Tides")
        }
    }

    /// A stream without chapter comments has none, and its other tags read
    /// as they always have.
    func testAStreamWithoutChapterCommentsHasNone() throws {
        let stream = Builder.vorbisStream(comments: ["TITLE=Plain", "CHAPTERS=not a chapter", "CHAPTER=nor this"])
        let header = try XCTUnwrap(OggHeaderReader.parse(head: stream, tail: stream))
        XCTAssertEqual(header.tags, OggHeaderReader.Tags(title: "Plain"))
    }

    /// A chapter's time is HH:MM:SS with an optional fraction, the hours in
    /// any count of digits, or MM:SS; anything else is no time.
    func testChapterTimes() {
        let times: [(String, TimeInterval?)] = [
            ("00:00:00.000", 0), ("00:01:30.500", 90.5), ("1:02:03.25", 3_723.25), ("100:00:00", 360_000),
            ("05:07", 307), ("05:07.5", 307.5), (" 00:00:01.000 ", 1), ("00:00:01.1234567891", 1.123456789),
            ("00:60:00", nil), ("00:00:60", nil), ("1:2:3:4", nil), ("12", nil), ("", nil), ("aa:00:00", nil),
            ("00:00:01.", nil), ("00:00:01.5x", nil), ("-1:00:00", nil), ("00:00:01,5", nil),
        ]
        var mismatches: [String] = []
        for (text, expected) in times {
            let found = OggHeaderReader.chapterStart(text)
            let matches: Bool
            switch (found, expected) {
            case (nil, nil): matches = true
            case let (found?, expected?): matches = abs(found - expected) < 1e-9
            default: matches = false
            }
            if !matches { mismatches.append("\"\(text)\": \(String(describing: found)), not \(String(describing: expected))") }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The converter's look at an Ogg file, from its own bytes, carries the
    /// file's chapters, which the import then keeps (`SourceInfo.chapters`).
    func testTheConvertersLookAtAnOggFileCarriesItsChapters() async throws {
        let folder = try makeSandboxDirectory("ogg-chapters")
        let file = folder.appendingPathComponent("radio.ogg")
        try Data(Builder.vorbisStream(comments: ["CHAPTER01=00:00:00", "CHAPTER01NAME=News", "CHAPTER02=00:00:01.5"])).write(to: file)

        let inspected = try await ImportAudioConverter.inspect(file)
        let info = try XCTUnwrap(inspected)

        XCTAssertEqual(info.chapters, [
            NeroChapterReader.Chapter(title: "News", start: 0),
            NeroChapterReader.Chapter(title: "", start: 1.5),
        ])
    }
}
